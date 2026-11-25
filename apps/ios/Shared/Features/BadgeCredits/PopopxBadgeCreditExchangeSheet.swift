//  PopopxBadgeCreditExchangeSheet.swift
//
//  [Phase 5 · 6b] Compute credits → badge: 600 points / 30 days and 4500 points / 365 days, both tiers written in this one file.
//
//  ### This leg does not go through Apple, so it must be the most honest
//  Credits can only come from "a top-up already paid through Apple", so the exchange itself creates no new IAP:
//  from a review standpoint this is "spending an existing balance", not "a new revenue entry". Therefore the panel hangs off the **secondary action** when entered from the paywall,
//  and this page carries no "better value" or "limited time" sales copy either (the same criterion as the header of `PopopxBadgePaywallView.swift`).
//
//  ### Debiting points and lighting the badge have exactly one atomic order, and it is not in this file
//  `PopopxCreditsManager.exchangeCreditsForBadge(period:)` debits first, then lights the badge, refunding the full amount if lighting fails
//  (that comment explains why the order cannot be reversed). This panel therefore **never** writes `.badgeRecord` itself
//  and never calls `debit` itself: with two places each writing their own copy you could get "points spent, badge not lit" or "badge lit, points not debited".
//  The view here does only three things: supply the chosen tier, call that one function, and state the result truthfully.
//
//  ### The stacking semantics must be written next to the button
//  `PopopxBadgeManager.activate` takes "the later expiry" rather than "the later issue date": redeeming a year while 200 days remain
//  does not wipe those 200 days. If this sentence is not written where the decision happens, the user can only find out by trial.
//  At the same time it does not promise "expiry = today + N days": with existing remainder the real expiry is later, so the page gives `remainingDescription` directly.
//
//  ### When the balance is short, the user gets the difference, not a bare "insufficient balance"
//  Both numbers of `insufficientCredits(balance:required:)` are in the error, and the page turns them into "N points short",
//  pointing the way out at the paywall's top-up tier — dismiss this one and it is visible; no second sheet is stacked (that would cover the price just seen).
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts modifying project.pbxproj.

import SwiftUI
import POPOPXChat

struct PopopxBadgeCreditExchangeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var credits = PopopxCreditsManager.shared
    @State private var badge = PopopxBadgeManager.shared

    @State private var period: PopopxNodeBadgePeriod = .monthly
    @State private var busy = false
    @State private var result: PopopxCreditExchangeResult?
    /// The paywall this mounts for itself when the points are not enough; see the comment on the `Copy.topUp` branch in the footer for the reason.
    @State private var showsPaywall = false

    var body: some View {
        PopopxSheetContainer(Copy.title, subtitle: Copy.subtitle) {
            content
        } footer: {
            footer
        }
        .sheet(isPresented: $showsPaywall) { PopopxBadgePaywallView() }
        .task { credits.loadIfNeeded() }
    }

    // MARK: Layout

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                balanceCard

                PopopxSectionCard(Copy.tiersTitle, footnote: Copy.stackFootnote) {
                    VStack(spacing: 0) {
                        PopopxRadioRow(Copy.tierTitle(period: .monthly),
                                       note: Copy.tierNote(period: .monthly),
                                       selected: period == .monthly) {
                            choose(.monthly)
                        }
                        Divider().overlay(PopopxPalette.separator)
                        PopopxRadioRow(Copy.tierTitle(period: .annual),
                                       note: Copy.tierNote(period: .annual),
                                       selected: period == .annual) {
                            choose(.annual)
                        }
                    }
                }

                if let result {
                    resultCard(result)
                }

                if badge.phase.isLit, let remaining = badge.remainingDescription {
                    PopopxSectionCard(Copy.currentTitle) {
                        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                            Text(verbatim: remaining)
                                .font(PopopxType.secondary)
                                .foregroundStyle(PopopxPalette.label)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: Copy.currentFootnote(period.days))
                                .font(PopopxType.microTag)
                                .foregroundStyle(PopopxPalette.labelHint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                boundaries
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    private var balanceCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            Text(PopopxCommerceCopy.creditsBalance)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelHint)
            Spacer()
            Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance))
                .font(PopopxType.display)
                .foregroundStyle(affordable ? PopopxPalette.label : PopopxPalette.dangerInk)
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.cardHigh, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
    }

    private func resultCard(_ result: PopopxCreditExchangeResult) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: result.success ? "checkmark.seal" : "exclamationmark.circle")
                    .font(PopopxType.secondary)
                    .foregroundStyle(result.success ? PopopxPalette.successInk : PopopxPalette.dangerInk)
                Text(verbatim: result.headline)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(result.success ? PopopxPalette.successInk : PopopxPalette.dangerInk)
            }
            Text(verbatim: result.detail)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }

    private var boundaries: some View {
        PopopxSectionCard(Copy.boundariesTitle, footnote: Copy.boundariesFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                bullet(Copy.boundaryOne)
                bullet(Copy.boundaryTwo)
                bullet(Copy.boundaryThree)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: "circle")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelHint)
                .frame(width: PopopxMetrics.spaceL, alignment: .leading)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            PopopxButton(Copy.exchange(period: period, cost: period.creditsCost),
                         systemImage: "sparkles",
                         isLoading: busy) {
                await exchange()
            }
            .disabled(busy)

            if !affordable, let shortfall {
                PopopxButton(Copy.topUp(shortfall), systemImage: "plus.circle", role: .ghost) {
                    // What used to be written here was "dismiss it and the top-up tier is on the page underneath" — that premise holds only half the time:
                    // this page has two ways in. On the paywall → credit centre → this page route, dismissing does land back on the top-up tier;
                    // but on the Me → credit centre → this page route, dismissing leaves no top-up tier at all,
                    // and the user holds nothing but "200 points short". So this branch mounts a paywall of its own.
                    // Opening another instance of the same type does not fork the prices: the tiers, the order and the sentences all live in
                    // `PopopxPaywallPlan` and `PopopxCommerceCopy`, and not one word is copied here.
                    showsPaywall = true
                }
            }
            PopopxButton(Copy.close, role: .ghost) { dismiss() }
        }
    }

    // MARK: Criteria

    private var affordable: Bool { credits.balance >= period.creditsCost }

    /// The shortfall is computed once, here: the sentence on the button and the sentence on the result card both come from the same number.
    private var shortfall: Int? {
        affordable ? nil : period.creditsCost - credits.balance
    }

    // MARK: Actions

    private func choose(_ next: PopopxNodeBadgePeriod) {
        guard next != period else { return }
        period = next
        result = nil
        PopopxHaptics.selection()
    }

    private func exchange() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let chosen = period
        do {
            try credits.exchangeCreditsForBadge(period: chosen)
            PopopxHaptics.notice(.success)
            // The expiry time takes the post-exchange value rather than "today + N days": with existing remainder the two differ.
            result = PopopxCreditExchangeResult(
                success: true,
                headline: Copy.exchanged(chosen),
                detail: badge.remainingDescription ?? Copy.exchangedDetail(chosen)
            )
        } catch let error as PopopxBadgeCreditsError {
            PopopxHaptics.notice(.error)
            result = PopopxCreditExchangeResult(
                success: false,
                headline: error.errorDescription ?? Copy.genericFailure,
                detail: Copy.reversedDetail(chosen)
            )
        } catch {
            PopopxHaptics.notice(.error)
            result = PopopxCreditExchangeResult(
                success: false,
                headline: PopopxBadgeCreditsError.keychainUnavailable.errorDescription ?? Copy.genericFailure,
                detail: Copy.reversedDetail(chosen)
            )
        }
    }
}

// MARK: - Result

/// The one-sentence result of an exchange. `detail` is the second sentence, "what happens next" — never a bare "failed".
struct PopopxCreditExchangeResult: Hashable {
    let success: Bool
    let headline: String
    let detail: String
}

// MARK: - Copy

private extension PopopxBadgeCreditExchangeSheet {
    enum Copy {
        static let title = NSLocalizedString("Light up a badge with Compute Credits", comment: "")
        static let subtitle = NSLocalizedString("Compute Credits spent on this page turn into an active encrypted relay route.", comment: "")
        static let tiersTitle = NSLocalizedString("Which tier to exchange for", comment: "")
        static let stackFootnote = NSLocalizedString("Remaining time is never erased: after an exchange the expiry is the later of the two.", comment: "")
        static func tierTitle(period: PopopxNodeBadgePeriod) -> String {
            String(format: NSLocalizedString("%1$lld days · %2$lld Compute Credits", comment: ""), period.days, period.creditsCost)
        }
        static func tierNote(period: PopopxNodeBadgePeriod) -> String {
            switch period {
            case .monthly: String(format: NSLocalizedString("Counted as %lld days; you can exchange again any time before expiry.", comment: ""), period.days)
            case .annual: String(format: NSLocalizedString("Counted as %lld days; this also merges with any remaining time.", comment: ""), period.days)
            }
        }
        static let currentTitle = NSLocalizedString("Current badge", comment: "")
        static func currentFootnote(_ days: Int) -> String { String(format: NSLocalizedString("Exchanging this tier again adds %lld days instead of restarting from today.", comment: ""), days) }
        static func exchange(period: PopopxNodeBadgePeriod, cost: Int) -> String {
            String(format: NSLocalizedString("Spend %1$lld Compute Credits · light up %2$lld days", comment: ""), cost, period.days)
        }
        static func topUp(_ shortfall: Int) -> String { String(format: NSLocalizedString("%lld Compute Credits short · go to top up", comment: ""), shortfall) }
        static let close = NSLocalizedString("Close", comment: "")
        static func exchanged(_ period: PopopxNodeBadgePeriod) -> String { String(format: NSLocalizedString("Lit up %lld days", comment: ""), period.days) }
        static func exchangedDetail(_ period: PopopxNodeBadgePeriod) -> String {
            NSLocalizedString("The credits were deducted and the badge was written to this device's Keychain.", comment: "")
        }
        static func reversedDetail(_ period: PopopxNodeBadgePeriod) -> String {
            String(format: NSLocalizedString("This exchange did not take effect; %lld Compute Credits were refunded exactly, and the balance is unchanged.", comment: ""), period.creditsCost)
        }
        static let genericFailure = NSLocalizedString("That did not complete.", comment: "")
        static let boundariesTitle = NSLocalizedString("What this screen promises, and what it does not", comment: "")
        static let boundariesFootnote = NSLocalizedString("Exchanges do not go through Apple, so this page has to say things more plainly than any advertisement.", comment: "")
        static let boundaryOne = NSLocalizedString("Compute Credits can only be spent inside this app — they cannot be gifted, cashed out or moved to another device.", comment: "")
        static let boundaryTwo = NSLocalizedString("Credits are not refundable once exchanged; if lighting up fails, the code refunds the full amount, and this page never charges a second time on its own.", comment: "")
        static let boundaryThree = NSLocalizedString("When a badge expires you only fall back to the free public relay: contacts, conversation history, groups and channels are all kept.", comment: "")
    }
}

// MARK: - Previews

struct PopopxBadgeCreditExchangeDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeCreditExchangeSheet()
            .preferredColorScheme(.dark)
    }
}

struct PopopxBadgeCreditExchangeLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeCreditExchangeSheet()
            .preferredColorScheme(.light)
    }
}
