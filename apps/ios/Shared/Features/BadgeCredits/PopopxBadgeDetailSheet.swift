//  PopopxBadgeDetailSheet.swift
//
//  [phase five · 3] The detail of a lit-up badge: on what grounds this device says its traffic rides the dynamic relay,
//  and the only legal exit for the subscription tier inside the app ("Manage subscriptions").
//
//  ### Why this panel has no "refresh status" or "connection test" button
//  This badge's truth comes in only two copies: the `PopopxBadgeRecord` row in the Keychain, and the entitlement StoreKit reports
//  (`PopopxBadgeManager.subscriptionSnapshot`). There is no server anywhere to ask. So this only presents,
//  and never pretends to probe — a "test node connectivity" button either really goes and tests (this layer has no testable object),
//  or it is decoration, and decoration is what compliance asks about.
//
//  ### The reconciliation digest is not decoration
//  `receiptDigest` is a short digest of the source credential (the subscription JWS text / the redemption record). The range it can match is one thing only:
//  which credential this badge record on this device **at the time** came from. It contains no credential text and cannot be reverse-looked-up,
//  so displaying it is safe; when a user checks it against their own App purchase records it is more useful than the empty sentence "source: Apple subscription".
//
//  ### The two hard constraints on the subscription tier (review stance)
//  - Renewal state is only read from `Transaction`/`Product.SubscriptionInfo.Status`, never written and never guessed;
//    if it cannot be read, say plainly "cannot be read right now" and do not show "renewed" (`PopopxSubscriptionRenewalState.unknown`).
//  - Cancelling a renewal can only go through `AppStore.showManageSubscriptions` (`PopopxStoreKitManager.manageSubscriptions()`),
//    the app builds no cancel entry of its own and no refund entry of its own. Restore-purchase likewise goes through `AppStore.sync()`, on the paywall page.
//
//  ### This page's first button is "renew or switch tier", not "close"
//  The subtitle line is already reporting the days left, and after reading it there are only two next steps: continue this stretch, or take another path.
//  So when `onOpenPaywall` is supplied it ranks first, and **regardless of source** (subscription / pass / voucher / credit redemption / trial are all the same);
//  the constraint above about "only Apple's management page" governs **cancelling and refunds**, which is a different thing from "buy one more tier",
//  so "Manage subscriptions" stays in the second row and neither of the two gives way.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts modifying project.pbxproj.

import SwiftUI
import POPOPXChat

struct PopopxBadgeDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var badge = PopopxBadgeManager.shared
    @State private var statusBusy = false
    @State private var statusFailure: String?

    /// Where the main action of the "tiers and prices" row goes, supplied by the host (`PopopxBadgeSheetHost`).
    /// If it cannot be supplied the whole row is omitted: a button that can only raise an error is worse than no button, for the same reason as in `PopopxTrialWelcomeModal`.
    var onOpenPaywall: (() -> Void)? = nil

    var body: some View {
        PopopxSheetContainer(Copy.title, subtitle: badge.remainingDescription ?? Copy.dormantSubtitle) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                    statusCard
                    if let record = badge.record {
                        provenance(record)
                        if record.source == .appleSubscription {
                            subscriptionCard
                        }
                        rotationCard(record)
                    }
                    boundaries
                }
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.bottom, PopopxMetrics.spaceL)
            }
        } footer: {
            footerRow
        }
        .task { await refreshSubscription() }
    }

    // MARK: State

    private var statusCard: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            PopopxBadgeCapsule(phase: badge.phase, rotationIndex: badge.record?.rotationIndex ?? 0) {}
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(verbatim: Copy.stateTitle(badge.phase.capsuleState))
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                if let description = badge.remainingDescription {
                    Text(verbatim: description)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PopopxMetrics.spaceS)
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }

    /// Source and expiry. Everything comes from this device's own record, and not one network request is made.
    private func provenance(_ record: PopopxBadgeRecord) -> some View {
        PopopxSectionCard(Copy.provenanceTitle) {
            VStack(spacing: PopopxMetrics.spaceXS) {
                row(Copy.sourceRow, record.source.displayName)
                row(Copy.periodRow, Copy.period(record))
                row(Copy.issuedRow, PopopxCommerceFormat.date(record.issuedAtMs))
                row(Copy.expiresRow, PopopxCommerceFormat.date(record.expiresAtMs))
                if let digest = record.receiptDigest {
                    row(Copy.digestRow, digest, monospaced: true)
                }
            }
        }
    }

    private func rotationCard(_ record: PopopxBadgeRecord) -> some View {
        PopopxSectionCard(Copy.rotationTitle, footnote: Copy.rotationFootnote) {
            VStack(spacing: PopopxMetrics.spaceXS) {
                row(Copy.rotationCountRow, "\(record.rotationIndex)")
                row(Copy.rotationEveryRow,
                    String(format: NSLocalizedString("≥ %lld s", comment: ""), Int(PopopxCommerceLimits.nodeRotationSeconds)))
            }
        }
    }

    // MARK: Subscription

    @ViewBuilder private var subscriptionCard: some View {
        let snapshot = badge.subscriptionSnapshot
        PopopxSectionCard(Copy.subscriptionTitle, footnote: Copy.subscriptionFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                row(Copy.renewalRow, renewalWords(snapshot?.state))
                if let snapshot {
                    row(Copy.autoRenewRow, snapshot.willAutoRenew ? Copy.yes : Copy.no)
                    if let expiresAtMs = snapshot.expiresAtMs {
                        row(Copy.renewsAtRow, PopopxCommerceFormat.date(expiresAtMs))
                    }
                }
                if let statusFailure {
                    Text(verbatim: statusFailure)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var boundaries: some View {
        PopopxSectionCard(Copy.boundaryTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                note(Copy.boundaryLocal)
                note(Copy.boundaryFallback)
                note(Copy.boundaryNoProbe)
            }
        }
    }

    @ViewBuilder private var footerRow: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            // The main action: enter the paywall to "renew or switch tier". This one does **not fork by source** (subscription / pass / gift voucher /
            // credit redemption / trial all get it), because this page's subtitle already reports the days left and "what to do next"
            // is the same question across all five sources: either continue this stretch, or take another path.
            // This page used to have only a "close" button for non-subscription sources — no next step at all after reading "3 days left".
            if let onOpenPaywall {
                PopopxButton(PopopxCommerceCopy.renewOrChangePlanAction,
                             systemImage: "arrow.triangle.2.circlepath") {
                    onOpenPaywall()
                }
            }
            if badge.record?.source == .appleSubscription {
                // The auto-renewal family's "turn it off / change tier" lives on Apple's side, so this stays in the second row instead of becoming the main action:
                // cancelling a renewal and switching plans are two different things, the first needs no new payment, and merging them into one sentence misleads.
                PopopxButton(Copy.manageSubscriptions, systemImage: "creditcard",
                             role: .secondary, isLoading: statusBusy) {
                    await PopopxStoreKitManager.shared.manageSubscriptions()
                }
            } else {
                PopopxButton(Copy.close, role: .secondary) {
                    dismiss()
                }
            }
        }
    }

    // MARK: Building blocks

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Text(verbatim: label)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Spacer(minLength: PopopxMetrics.spaceS)
            Text(verbatim: value)
                .font(monospaced ? PopopxType.metricSmall : PopopxType.secondary)
                .foregroundStyle(PopopxPalette.label)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "checkmark.seal")
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.successInk)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The renewal tier in plain words. `unknown` is not "not renewed", it is "not read this time", and the wording must keep them apart.
    private func renewalWords(_ state: PopopxSubscriptionRenewalState?) -> String {
        switch state ?? .unknown {
        case .renewing: Copy.renewing
        case .cancelled: Copy.cancelledAtPeriodEnd
        case .billingRetry: Copy.billingRetry
        case .ended: Copy.ended
        case .unknown: Copy.unknown
        }
    }

    private func refreshSubscription() async {
        guard badge.record?.source == .appleSubscription else { return }
        statusBusy = true
        defer { statusBusy = false }
        await badge.refreshSubscriptionStatus()
        // Even when it reads back nil it is still said clearly: failure on this leg is not an error, it is "cannot be read right now".
        statusFailure = badge.subscriptionSnapshot == nil ? Copy.statusUnavailable : nil
    }
}

// MARK: - Display names of the sources

private extension PopopxBadgeSource {
    /// The wording of the five source tiers. The criteria correspond one-to-one with what `PopopxBadgeManager` writes; no sixth phrasing is invented.
    /// The pass cell goes through `PopopxCommerceCopy`: it is a source added this round, and this round's red line forbids new bare Chinese literals in code
    /// (the four cells above are existing copy; closing them up into keys would also require touching 16 catalogues, which is out of this round's scope).
    var displayName: String {
        switch self {
        case .pioneerTrial: NSLocalizedString("Pioneer Node Trial badge", comment: "")
        case .appleSubscription: NSLocalizedString("App Store subscription", comment: "")
        case .storePass: PopopxCommerceCopy.passSourceName
        case .creditsExchange: NSLocalizedString("Compute Credits exchange", comment: "")
        case .giftedVoucher: NSLocalizedString("Received gift card", comment: "")
        }
    }
}

// MARK: - Copy

private extension PopopxBadgeDetailSheet {
    enum Copy {
        static let title = PopopxCommerceCopy.badgeProductName
        static let dormantSubtitle = key("Currently using the free public SMP nodes.")

        static func stateTitle(_ state: PopopxBadgeCapsuleState) -> String {
            switch state {
            case .trialPulsing: key("On trial")
            case .activeLit: key("Badge lit")
            case .dormant: key("Not lit")
            }
        }

        static let provenanceTitle = key("This device's record")
        static let sourceRow = key("Source")
        static let periodRow = key("Plan")

        /// The value of the "tier" cell. The source text is an English sentence and the English sentence is the Key (written the same way as
        /// `PopopxBadgeCapsuleCopy` in `PopopxBadgeCapsuleView.swift`): `en.lproj` is not written by convention, and the 16 translation catalogues each write their own.
        ///
        /// The criterion uses the source rather than the day count —— `PopopxBadgeManager.swift:152` writes the `period` of the pioneer trial as
        /// `.monthly` (the trial merely borrows the monthly tier's shape for registration, its expiry moment is computed separately from `PopopxCommerceLimits.trialSeconds`
        /// ), so printing `record.period.days` would describe a 3-day trial as 30 days, and that is exactly the cell reported on real-device round 5.
        /// The day count is computed on the spot from `trialSeconds`, the same basis as the expiry moment, so no second number is introduced.
        static func period(_ record: PopopxBadgeRecord) -> String {
            if record.source == .pioneerTrial {
                let trialDays = max(1, Int(ceil(PopopxCommerceLimits.trialSeconds / 86_400)))
                return String(format: key("%lld days (Pioneer Trial)"), trialDays)
            }
            return String(format: key("%lld days"), record.period.days)
        }

        private static func key(_ value: String) -> String {
            NSLocalizedString(value, comment: "POPOPX badge detail")
        }
        static let issuedRow = key("Issued")
        static let expiresRow = key("Expires")
        static let digestRow = key("Reconciliation digest")

        static let rotationTitle = key("Node status panel")
        static let rotationFootnote = key("This row is only a count kept on this device: while the badge is lit it increases once per fixed interval, and no relay node changes because of it.")
        static let rotationCountRow = key("Local count")
        static let rotationEveryRow = key("Interval")

        static let subscriptionTitle = key("Subscription")
        static let subscriptionFootnote = PopopxCommerceCopy.renewalStatement
        static let renewalRow = key("Renewal state")
        static let autoRenewRow = key("Auto-renew")
        static let renewsAtRow = key("Next")
        static let renewing = key("Auto-renewing")
        static let cancelledAtPeriodEnd = key("Cancelled, no renewal after this period ends")
        static let billingRetry = key("Payment awaiting a retry")
        static let ended = key("Ended")
        static let unknown = key("Not readable right now")
        static let yes = key("On")
        static let no = key("Off")
        static let statusUnavailable = key("Apple's renewal status could not be read this time; the plan below is shown from this device's own record.")
        static let manageSubscriptions = key("Manage subscriptions")

        static let boundaryTitle = key("The boundaries of this badge")
        static let boundaryLocal = key("Badges, vouchers and Compute Credits exist only on this device; no server can look them up or revoke them.")
        static let boundaryFallback = key("When it expires the app drops back to the free public SMP nodes; contacts and message history stay untouched.")
        static let boundaryNoProbe = key("This page runs no connectivity test: there is no server to ask, so there is no decorative check button either.")

        static let close = key("Close")
    }
}

// MARK: - Time format

/// Times on the detail page always go down to the day and carry no seconds: what a user wants to check here is "which day it expires", not "at what minute".
/// The formatter for the same purpose in `PopopxBadgeManager` is private, and this module does not share one mutable formatter,
/// so each view file keeps its own read-only copy (`DateFormatter` is not a hotspot here, at most a few rows render per day).
enum PopopxCommerceFormat {
    private static let dayMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func date(_ milliseconds: Int64) -> String {
        dayMonth.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }

    /// Countdown down to the minute. Used where a red packet or voucher has to show "how much is left" on the spot.
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = total % 86_400 / 3_600
        let minutes = total % 3_600 / 60
        if days > 0 { return String(format: NSLocalizedString("%1$d d %2$d h", comment: ""), days, hours) }
        if hours > 0 { return String(format: NSLocalizedString("%1$d h %2$d min", comment: ""), hours, minutes) }
        return String(format: NSLocalizedString("%d min", comment: ""), minutes)
    }
}

// MARK: - Previews

struct PopopxBadgeDetailDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeDetailSheet()
            .preferredColorScheme(.dark)
    }
}

struct PopopxBadgeDetailLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeDetailSheet()
            .preferredColorScheme(.light)
    }
}
