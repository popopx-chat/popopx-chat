//  PopopxCreditsStoreView.swift
//
//  [Phase 6 · 1] Compute Credits hub: balance, cash-pack top-up, uses table, ledger.
//
//  ### This page has exactly one product: POPOPX compute credits themselves (real-device round 8 · task 3)
//  On screen are four things — **balance**, **the three cash-pack tiers 100 / 500 / 2000**, **where credits can be spent**, **the ledger**.
//  Badge subscriptions, one-off passes and gift badge vouchers are all off this page (they belong to `PopopxBadgePaywallView`,
//  and that page in turn no longer draws any top-up price list). Before this, each of the two screens showed both the "membership" and "credits" products at the same time,
//  a user reading them in one list would buy the wrong thing: that is a monetisation P0, not a layout preference.
//  The only "badge-related" thing this page keeps is the **spend an existing balance** path (the first row of the uses table and the footer's
//  `light up a badge with compute credits`, both open `PopopxBadgeCreditExchangeSheet`): it is the exit for that family of spending scenarios on this page,
//  not a card that sells badges — it takes no money, it only spends credits the user has already paid for once.
//
//  ### Why top-up hangs on this page rather than one level up
//  It has two doors in: the "Me · compute credits wallet" row, and the paywall footer's `creditsName` button.
//  Before the move, the reason for "not a cent is taken here" was "entering from the paywall draws a second identical price list one level down, and the two levels of comments
//  diverge as soon as either is rewritten". Now cash packs appear only on this page, and that upper level with the identical price list does not exist at all,
//  so the possibility of divergence went with it — therefore credit purchases land right here: the user sees balance and price list on one screen,
//  and immediately after buying sees the balance grow on the same screen; this flow has no second price list to take wrong.
//  Booking goes through `PopopxCreditsManager.apply(storeReceipt:)`: that is the **same** entry the background delivery flow uses,
//  face value, ledger row, replay prevention (`entryId = receipt.digest`) and the "write the ledger first, then `finish`" ordering all live in that one place,
//  so this page does not write its own second add-money logic.
//  The path that unconditionally opens the badge paywall still belongs to the "Me" row (`PopopxMeView`'s `badgeSheet = .paywall`).
//  ⚠️ The `purchaseCredits` row on that same page ("Top up Compute Credits") still points to
//  `.paywall`, while the paywall no longer sells cash packs — it should be changed to open this page (`showsCreditsStore`).
//  `PopopxMeView.swift` and `PopopxBadgeCreditExchangeSheet.swift` (the same defect behind "go top up")
//  are both outside this round's file ownership, so it is left to the owner to close off; this round first guarantees that **inside the page** there is no second product.
//
//  ### Balance and ledger must each admit their own unreliability
//  `PopopxCreditsWallet.needsReconcile` is set true by `verifyLedgerConsistency()` when the balance and the summed ledger disagree
//  (the ledger is capped at 240 rows, so dropped old entries do not count as inconsistency — see the comment there). This page shows that state
//  instead of showing a "looks fine" number: silently spending an untrusted balance is the worse outcome.
//
//  ### Every number in the uses table and the top-up table comes from the one already in the code
//  Cash-pack face values come from `PopopxCreditPlan` (derived from `PopopxNodeBadgeSku.creditedAmount`,
//  that is the very number that is actually booked); 600/4500 come from `PopopxNodeBadgePeriod.creditsCost`, 20 from
//  `PopopxCommerceLimits.extendedSecureWindowCost`, 150 from `PopopxCosmetic.cost`,
//  red-packet face values come from `PopopxCommerceLimits.redPacketAmounts`. This page may not contain a fourth "how many credits" literal:
//  a table price diverging from the real debit is the only fatal bug for a page like this.
//  There are exactly two exceptions and they must be exceptions: the channel subscription price and the profile-card unlock price are set by the peer itself, so the page writes no number, only "set by the other side".
//
//  ### Only the two cosmetic rows in the uses table can be pressed
//  Cosmetics are this page's only one-step "credits → on-device effect": one tier, one price, one debit, no next step,
//  so making it a button needs no new sheet. Badges need a period chosen, red packets a number of shares and a destination,
//  and the channel and profile-card thresholds are set by the other side — those four each have their own panel; from this page you can only enter, not settle them here.
//  An already-unlocked row is no longer a button: pressing it again only yields "you already own this", the most useless feedback in that family.
//
//  ### Ledger rows only read the note that was stored in
//  `PopopxCreditsEntry.note` is the Chinese sentence written at the moment of the debit/credit (`PopopxCreditsCopy`),
//  so this page needs no second "category → copy" mapping; `kind.sign` gives the direction, `kind.isIncome` the colour,
//  and both are defined in that one place only.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.

import SwiftUI
import POPOPXChat

struct PopopxCreditsStoreView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var credits = PopopxCreditsManager.shared
    /// The cash packs' price and product table. The read side of the `@Observable` is this page: until prices load, a row shows
    /// the SKU's own `fallbackPriceText` (the face value in App Store Connect), and the button is disabled at the same time,
    /// so neither the "whole page blank" nor the "pressed and nothing happened" failure reaches the user (same standard as the paywall).
    @State private var store = PopopxStoreKitManager.shared
    @State private var showsExchange = false
    /// The cash pack currently going through StoreKit. Only one at a time is allowed, otherwise the arrival order of two cannot be explained to the user.
    @State private var busySkuId: String?
    /// The cosmetic tier awaiting confirmation. The dialog's visibility derives from it (the Binding below), so there is no
    /// "dialog still open but nobody is being confirmed" intermediate frame — same shape as the profile-card unlock elsewhere.
    @State private var pendingCosmetic: PopopxCosmetic?
    /// The result of the last credit action (top-up or cosmetic unlock), one sentence only. It is not called a "toast" and it does not auto-dismiss: this page is a ledger page,
    /// the user needs to see "those 150 credits really were booked" and "the 500 credits just bought really did arrive", and a sentence that removes itself equals no sentence at all.
    @State private var spendNote: String?

    var body: some View {
        PopopxSheetContainer(Copy.title, subtitle: PopopxCommerceCopy.nodeClusterTerm) {
            content
        } footer: {
            footer
        }
        .sheet(isPresented: $showsExchange) { PopopxBadgeCreditExchangeSheet() }
        .alert(Copy.unlockTitle, isPresented: unlockPrompt) {
            if let cosmetic = pendingCosmetic {
                Button(Copy.unlockConfirm(cosmetic)) { purchase(cosmetic) }
                Button(Copy.unlockCancel, role: .cancel) { pendingCosmetic = nil }
            }
        } message: {
            if let cosmetic = pendingCosmetic {
                Text(verbatim: Copy.unlockMessage(cosmetic: cosmetic, balance: credits.balance))
            }
        }
        .task {
            credits.loadIfNeeded()
            await store.loadProducts()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                balanceCard

                if credits.wallet.needsReconcile {
                    reconcileNote
                }

                topUpCard

                usesCard

                if let spendNote {
                    spendLine(spendNote)
                }

                pendingCard

                PopopxSectionCard(Copy.ledgerTitle, footnote: Copy.ledgerFootnote) {
                    VStack(spacing: 0) {
                        let entries = credits.recentEntries
                        if entries.isEmpty {
                            Text(verbatim: Copy.ledgerEmpty)
                                .font(PopopxType.caption)
                                .foregroundStyle(PopopxPalette.labelHint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, PopopxMetrics.spaceS)
                        } else {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                ledgerRow(entry)
                                if index < entries.count - 1 {
                                    Divider().overlay(PopopxPalette.separator)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    // // MARK: Balance

    private var balanceCard: some View {
        // On the brand background only the onBrand family is used: `label` is that deep ink, and pressed on brand its contrast drops to unreadable.
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(PopopxCommerceCopy.creditsBalance)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.onBrand.opacity(0.80))
            Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance))
                .font(PopopxType.display)
                .foregroundStyle(PopopxPalette.onBrand)
            Text(verbatim: Copy.updated(PopopxCommerceFormat.date(credits.wallet.updatedAtMs)))
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.onBrand.opacity(0.70))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PopopxMetrics.spaceM)
        .background(PopopxPalette.brand, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
    }

    private var reconcileNote: some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "exclamationmark.triangle")
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.dangerInk)
            Text(verbatim: Copy.reconcileBody)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.dangerInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.danger.opacity(0.12), in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .accessibilityElement(children: .combine)
    }

    // // MARK: Top-up (compute-credit cash packs)

    /// Three cash-pack tiers: 100 / 500 / 2000. This card is the only place on the page that takes money, and it sells exactly one thing —
    /// compute credits themselves. The tier table is `PopopxCreditPlan` (face value derived from the SKU's `creditedAmount`),
    /// and prices come from StoreKit, so between "the face value written on the row" and "the face value actually booked" there is no third place that can say something different.
    /// The footnote "never any bonus credit" (`noGiftBackStatement`) used to live permanently on the paywall's top-up tiers; after moving the whole group it moved along.
    private var topUpCard: some View {
        PopopxSectionCard(PopopxCommerceCopy.creditsTopUpTitle,
                          footnote: PopopxCommerceCopy.noGiftBackStatement) {
            VStack(spacing: 0) {
                if !store.isStoreReady {
                    // Store unreadable: the tiers are still drawn (face value is this module's fact), the price slot shows the SKU's own listed price,
                    // and the button is disabled. This sentence reuses `PopopxCommerceCopy.errorStoreUnavailable` —
                    // the 16 catalogues already have a translation for it, so no new source string is started.
                    Text(PopopxCommerceCopy.errorStoreUnavailable)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .padding(.bottom, PopopxMetrics.spaceXS)
                }
                ForEach(Array(PopopxCreditPlan.packs.enumerated()), id: \.element.id) { index, pack in
                    if index > 0 { divider }
                    packRow(pack)
                }
            }
        }
    }

    private func packRow(_ pack: PopopxCreditPack) -> some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Text(verbatim: pack.title)
                .font(PopopxType.emphasis)
                .foregroundStyle(PopopxPalette.label)
            Spacer(minLength: PopopxMetrics.spaceS)
            Button {
                Task { await buy(pack) }
            } label: {
                HStack(spacing: PopopxMetrics.space2XS) {
                    if busySkuId == pack.sku.productId {
                        ProgressView()
                    } else {
                        Text(verbatim: store.priceText(for: pack.sku, periodSuffix: false))
                        Image(systemName: "chevron.right")
                    }
                }
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.brand)
                .frame(minHeight: PopopxMetrics.minHitTarget)
            }
            .disabled(!store.isStoreReady || busySkuId != nil)
            .opacity(store.isStoreReady ? 1 : 0.5)
            .accessibilityLabel(Text(verbatim: pack.title))
            .accessibilityValue(Text(verbatim: store.priceText(for: pack.sku, periodSuffix: false)))
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
    }

    /// Buy one cash-pack tier. **Adding money is not written on this page**: once the receipt is obtained it is handed to `PopopxCreditsManager.apply(storeReceipt:)` —
    /// that is the **same** entry the StoreKit background delivery flow uses; face value, ledger row, replay prevention (`entryId = receipt.digest`)
    /// and the "write the ledger first, then `finish`" ordering all live in that one place, and writing another set here would be a second source of truth that diverges from re-delivery.
    /// Why this foreground transaction has to call it directly here: `PopopxStoreKitManager.purchase(_:)` has already recorded the transaction id into
    /// the "already settled this session" set, so the later `Transaction.updates` delivery is blocked by dedup — not booking here
    /// leaves the user seeing "money paid, balance unchanged, nothing at all", and one level down there is no second party who will come and make it up.
    private func buy(_ pack: PopopxCreditPack) async {
        guard busySkuId == nil else { return }
        busySkuId = pack.sku.productId
        defer { busySkuId = nil }
        let before = credits.balance
        switch await store.purchase(pack.sku) {
        case let .success(.purchased(receipt)):
            await credits.apply(storeReceipt: receipt)
            if credits.balance != before {
                PopopxHaptics.notice(.success)
                spendNote = String(format: PopopxCommerceCopy.creditsTopUpGrantedFormat, pack.amount)
            } else {
                // Payment succeeded but nothing was written on this device (Keychain write failed, or the balance was already at the cap and got blocked).
                // This must be said out loud rather than left silent: the transaction was not finished, and the next re-delivery will add the credits.
                PopopxHaptics.notice(.error)
                spendNote = PopopxCommerceCopy.creditsTopUpNotCredited
            }
        case .success(.pending):
            // Ask to Buy / family approval: no money has been taken. Saying "credited" is a lie, and saying "failed" is a lie too.
            spendNote = PopopxCommerceCopy.creditsTopUpPending
        case .success(.cancelled):
            // Cancellation is not an error: no haptic, no red, and no "failed" sentence left on the ledger page.
            break
        case let .failure(error):
            PopopxHaptics.notice(.error)
            // The truth is said as it is (the `PopopxBadgeCreditsError` sentence already was localised and already carries the shortfall).
            spendNote = error.errorDescription ?? PopopxCommerceCopy.errorStoreUnavailable
        }
    }

    // // MARK: Uses table

    private var usesCard: some View {
        PopopxSectionCard(Copy.usesTitle, footnote: Copy.usesFootnote) {
            VStack(spacing: 0) {
                useRow("sparkles", Copy.useBadgeTitle,
                       Copy.useBadgeNote,
                       amount: "\(PopopxNodeBadgePeriod.monthly.creditsCost) / \(PopopxNodeBadgePeriod.annual.creditsCost)")
                divider
                useRow("gift", Copy.useVoucherTitle, Copy.useVoucherNote,
                       amount: "\(PopopxNodeBadgePeriod.monthly.creditsCost) / \(PopopxNodeBadgePeriod.annual.creditsCost)")
                divider
                useRow("envelope", Copy.usePacketTitle, Copy.usePacketNote,
                       amount: PopopxCommerceLimits.redPacketAmounts
                           .map(String.init)
                           .joined(separator: " / "))
                divider
                useRow("number", Copy.useChannelTitle, Copy.useChannelNote, amount: nil)
                divider
                useRow("person.crop.circle.badge.checkmark", Copy.useProfileTitle, Copy.useProfileNote, amount: nil)
                divider
                useRow("eye.slash", Copy.useWindowTitle, Copy.useWindowNote,
                       amount: "\(PopopxCommerceLimits.extendedSecureWindowCost)")
                divider
                // Dividers are drawn per row rather than "prepend one to every row": adding a new cosmetic tier will not leave a dangling divider here.
                ForEach(Array(PopopxCosmetic.allCases.enumerated()), id: \.element.id) { index, cosmetic in
                    if index > 0 { divider }
                    if credits.owns(cosmetic) {
                        useRow(cosmetic.symbol, cosmetic.displayName, Copy.owned, amount: "\(cosmetic.cost)")
                    } else {
                        // Only the not-yet-unlocked row is a button: pressing an unlocked tier again only yields "you already own this",
                        // and a button whose only answer is a refusal is one of the most annoying things in this app.
                        Button { pendingCosmetic = cosmetic } label: {
                            useRow(cosmetic.symbol, cosmetic.displayName, cosmetic.effectNote,
                                   amount: "\(cosmetic.cost)")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text(verbatim: Copy.unlockHint(cosmetic)))
                    }
                }
            }
        }
    }

    private var divider: some View { Divider().overlay(PopopxPalette.separator) }

    /// The dialog's on/off state derives only from `pendingCosmetic`. No separate `showsUnlock` boolean is kept:
    /// two sources of truth part ways sooner or later, and the shape afterwards is "the dialog asks about one tier, the press debits another".
    private var unlockPrompt: Binding<Bool> {
        Binding(
            get: { pendingCosmetic != nil },
            set: { shown in if !shown { pendingCosmetic = nil } }
        )
    }

    /// The cosmetic's credit debit: happens only after the user nods, and both success and failure leave a sentence behind.
    ///
    /// This page is a ledger page, and a spend that leaves no sentence means the user has to leaf through the ledger to check whether those 150 credits were booked.
    /// What makes the UI take effect after the unlock is not stated here: `owns(cosmetic)` is the one flag both render sites read,
    /// and the ledger row plus the uses-table row turning to "unlocked" already express everything "it took effect" means.
    private func purchase(_ cosmetic: PopopxCosmetic) {
        pendingCosmetic = nil
        do {
            try credits.purchase(cosmetic)
            PopopxHaptics.notice(.success)
            spendNote = Copy.unlockDone(cosmetic)
        } catch {
            PopopxHaptics.notice(.error)
            // The insufficient-credits sentence comes from `PopopxBadgeCreditsError.errorDescription` (it carries the shortfall in the sentence),
            // so no balance is appended here: when two sentences each state a number, the user does not know which one to trust.
            spendNote = Copy.unlockFailed(error.localizedDescription)
        }
    }

    /// The result of the previous spend. Deliberately does not reuse `reconcileNote`'s red: that path says "the books do not add up",
    /// while this sentence says "it was booked", and sharing one layout between two colours leaves people unable to tell which line is the important one.
    private func spendLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "checkmark.circle")
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.successInk)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func useRow(_ symbol: String, _ title: String, _ note: String, amount: String?) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: symbol)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.brand)
                .frame(width: PopopxMetrics.spaceXL)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.label)
                Text(verbatim: note)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            if let amount {
                Text(verbatim: amount)
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            } else {
                Text(verbatim: Copy.setByPeer)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelHint)
            }
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .accessibilityElement(children: .combine)
    }

    // // MARK: Red packets not fully claimed

    @ViewBuilder private var pendingCard: some View {
        let total = credits.pendingPacketTotal
        if total > 0 {
            PopopxSectionCard(Copy.pendingTitle, footnote: Copy.pendingFootnote) {
                HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                    Text(verbatim: Copy.pendingCount(credits.pendingPackets.filter { !$0.settled }.count))
                        .font(PopopxType.secondary)
                        .foregroundStyle(PopopxPalette.label)
                    Spacer()
                    Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, total))
                        .font(PopopxType.metric)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
                .padding(.vertical, PopopxMetrics.spaceXS)
            }
        }
    }

    // // MARK: Ledger

    private func ledgerRow(_ entry: PopopxCreditsEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: entry.note)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: PopopxMetrics.spaceXS) {
                    Text(verbatim: PopopxCommerceFormat.date(entry.timestampMs))
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.labelHint)
                    if let after = entry.balanceAfter {
                        Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, after))
                            .font(PopopxType.microTag)
                            .foregroundStyle(PopopxPalette.labelHint)
                    }
                }
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            Text(verbatim: signedAmount(entry))
                .font(PopopxType.metric)
                .foregroundStyle(entry.kind.isIncome ? PopopxPalette.successInk : PopopxPalette.label)
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .accessibilityElement(children: .combine)
    }

    /// The sign has one source only: `kind.sign`. An `adjustment` carries its own sign, so that row goes by `amount`'s positive or negative.
    /// The minus always uses U+2212 (the typographic minus sign), never a hyphen: with two ledger rows side by side the two "minus signs" have different widths.
    private func signedAmount(_ entry: PopopxCreditsEntry) -> String {
        guard let sign = entry.kind.sign else {
            return entry.amount >= 0 ? "+\(entry.amount)" : "−\(abs(entry.amount))"
        }
        return "\(sign > 0 ? "+" : "−")\(abs(entry.amount))"
    }

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            PopopxButton(Copy.exchange, systemImage: "sparkles", role: .secondary) {
                showsExchange = true
            }
            PopopxButton(Copy.close, role: .ghost) { dismiss() }
        }
    }
}

// // MARK: - Cosmetic-row glyph and effect sentence

/// Name and price both come from `PopopxCosmetic` itself; this only adds the "how the page draws it" layer,
/// because that is this view's presentation detail and should not be written into a value type.
private extension PopopxCosmetic {
    var symbol: String {
        switch self {
        case .auroraShieldAvatarFrame: "theatermasks"
        case .darkGoldQRCardSkin: "qr"
        }
    }

    var effectNote: String {
        switch self {
        case .auroraShieldAvatarFrame: NSLocalizedString("Applied to this device's avatar rendering; nothing is uploaded.", comment: "cosmetic effect")
        case .darkGoldQRCardSkin: NSLocalizedString("Applied to this device's QR card face; nothing is uploaded.", comment: "cosmetic effect")
        }
    }
}

// // MARK: - Copy

private extension PopopxCreditsStoreView {
    enum Copy {
        static let title = PopopxCommerceCopy.creditsName
        static func updated(_ date: String) -> String { String(format: NSLocalizedString("Updated at %@", comment: "credits wallet stamp"), date) }
        static let reconcileBody = NSLocalizedString("The ledger and the balance on this device do not add up. The balance is still the sum of the ledger, but hold off on large exchanges until a reconciliation has run.", comment: "credits store")
        static let usesTitle = NSLocalizedString("What Compute Credits can be spent on", comment: "credits store")
        static let usesFootnote = NSLocalizedString("Every price comes from the one place the code already defines it, so this page keeps no second copy. Channel and profile-card thresholds are set by the other side, so no number is shown for them.", comment: "credits store")
        static let setByPeer = NSLocalizedString("Set by the other side", comment: "credits store")
        static let useBadgeTitle = NSLocalizedString("Light up a badge", comment: "credits store")
        static let useBadgeNote = NSLocalizedString("Two tiers, 30 days and 365 days; whichever expires later wins over the time you already have.", comment: "credits store")
        static let useVoucherTitle = NSLocalizedString("Exchange for a gift voucher", comment: "credits store")
        static let useVoucherNote = NSLocalizedString("The same price turned into a voucher you can send away; exchange several at once if you want.", comment: "credits store")
        static let usePacketTitle = NSLocalizedString("Send a Compute Credits red packet", comment: "credits store")
        static let usePacketNote = NSLocalizedString("Fixed amounts only, split evenly between whoever claims them; anything unclaimed comes back on its own.", comment: "credits store")
        static let useChannelTitle = NSLocalizedString("Subscribe to a channel", comment: "credits store")
        static let useChannelNote = NSLocalizedString("Every channel is priced by its own owner.", comment: "credits store")
        static let useProfileTitle = NSLocalizedString("Unlock an encrypted profile card", comment: "credits store")
        static let useProfileNote = NSLocalizedString("The threshold is set by the owner on their profile card; the unlock keeps a receipt on this device.", comment: "credits store")
        static let useWindowTitle = NSLocalizedString("Extend a top-secret message's viewing window", comment: "credits store")
        static let useWindowNote = NSLocalizedString("Extends the default viewing window by 1 hour; changes only how this device renders it.", comment: "credits store")
        static let owned = NSLocalizedString("Unlocked — active on this device", comment: "credits store")
        static let unlockTitle = NSLocalizedString("Unlock this look", comment: "credits store")
        static func unlockConfirm(_ cosmetic: PopopxCosmetic) -> String { String(format: NSLocalizedString("Spend %lld Compute Credits", comment: "credits store unlock button"), cosmetic.cost) }
        static let unlockCancel = NSLocalizedString("Cancel", comment: "credits store")
        /// Price, balance and effect are said in one row, because this is the only chance to explain before "spend" is pressed.
        /// `effectNote` comes from the private extension below ("takes effect on this device, never uploaded"), the same sentence as the one in the list.
        static func unlockMessage(cosmetic: PopopxCosmetic, balance: Int) -> String {
            String(format: NSLocalizedString("%1$@: %2$@ Current balance %3$lld Compute Credits; unlocking costs %4$lld credits once, with no refund.", comment: "credits store unlock alert"), cosmetic.displayName, cosmetic.effectNote, balance, cosmetic.cost)
        }
        static func unlockHint(_ cosmetic: PopopxCosmetic) -> String { String(format: NSLocalizedString("Unlock this look for %lld Compute Credits", comment: "credits store"), cosmetic.cost) }
        static func unlockDone(_ cosmetic: PopopxCosmetic) -> String { String(format: NSLocalizedString("%@ is unlocked on this device.", comment: "credits store"), cosmetic.displayName) }
        static func unlockFailed(_ reason: String) -> String { String(format: NSLocalizedString("Not unlocked: %@", comment: "credits store"), reason) }
        static let ledgerTitle = NSLocalizedString("Ledger", comment: "credits store")
        static let ledgerFootnote = NSLocalizedString("The 240 most recent entries; older ones are dropped, the balance itself is not.", comment: "credits store")
        static let ledgerEmpty = NSLocalizedString("No entries yet.", comment: "credits store")
        static let pendingTitle = NSLocalizedString("Red packets nobody finished claiming", comment: "credits store")
        static let pendingFootnote = NSLocalizedString("These credits are still recorded in your name; whatever is unclaimed when a packet expires goes back to your balance.", comment: "credits store")
        static func pendingCount(_ n: Int) -> String { String(format: NSLocalizedString("%lld red packets", comment: "credits store"), n) }
        static let exchange = NSLocalizedString("Light up a badge with Compute Credits", comment: "credits store")
        static let close = NSLocalizedString("Close", comment: "credits store")
    }
}

// MARK: - Previews

struct PopopxCreditsStoreDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxCreditsStoreView()
            .preferredColorScheme(.dark)
    }
}

struct PopopxCreditsStoreLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxCreditsStoreView()
            .preferredColorScheme(.light)
    }
}
