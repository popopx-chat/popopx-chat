//  PopopxBadgePaywallView.swift
//
//  [Phase 5 · 4] The paywall: the badge's two payment paths + gift badge vouchers. This page sells only badges.
//
//  ### This page has only one kind of product (device round 8 · task three)
//  The compute-point cash packs (100 / 500 / 2000) moved as a whole group to the "POPOPX compute points" page
//  (`PopopxCreditsStoreView`, the tier table is now `PopopxCreditPlan`). Before the move this screen displayed at the same time
//  two conflicting products, "subscription/pass" (charges again or grants a period) and "top-up pack" (converts into spendable points),
//  and users reading them in the same list would buy the wrong thing — that is a monetization P0 incident, not an aesthetics problem.
//  This page keeps only one path involving compute points: **exchange existing compute points for a badge** (the footer's
//  `paywallUseCredits` → `PopopxBadgeCreditExchangeSheet`). It is the exit for spending an existing balance,
//  not a money-in entry, so it always sits in the secondary-action slot; a separate `creditsName` button only sends the user to
//  the compute-points page to top up, and this page draws not a single top-up price table.
//
//  ### The page skeleton is this module's property, not an accessory of StoreKit
//  The structure the prompt specified is "title + subtitle + segmented cards + benefit points + price rows + CTA + secondary action",
//  and it explicitly forbids the `if storeKitManager.products.isEmpty { ForEach(…) }` style of "using the products array as the page skeleton".
//  So the layout here is first written as the fixed table `PopopxPaywallPlan.sections(tab:)` (tiers, order, titles, notes
//  are all decided by code), and StoreKit only answers a price string; `PopopxNodeBadgeSku.allCases` appears in this file
//  not even once.
//  When the store is not ready yet (offline, StoreKit failure, first load in flight), cards are still drawn and buttons still disabled,
//  and the price slot shows each SKU's own `fallbackPriceText` — that is a **known list price**, not a guess:
//  it equals the face value configured in App Store Connect, and once a real price is fetched it is displaced by `displayPrice`.
//  This way the two common failures, "a completely blank page" or "a button that taps but does nothing", cannot occur.
//
//  ### Three things that must be said clearly, none of them allowed to be vague
//  1. **Auto-renewal**: `PopopxCommerceCopy.renewalStatement` (the full 3.1.2(c) wording) appears only on subscription tiers,
//     attached as the tier footnote, not stuffed under the CTA as decoration. One-time duration tiers give, in the **same slot**,
//     `PopopxCommerceCopy.oneTimePurchaseStatement` (paid once, never auto-renews): these two payment paths have
//     opposite renewal facts, so each must say its own or they read as one and the same thing; that is why the "POPOPX badge" section also groups by these two.
//  2. **Zero bonuses**: `PopopxCommerceCopy.noGiftBackStatement` now lives permanently in the **compute-points page**'s top-up card footnote
//     (see `PopopxCreditsStoreView`); this page no longer has a top-up tier to attach it to, and there is no "get X extra compute points" text anywhere
//     (the prompt's "pure top-up" red line).
//  3. **Virtual currency does not cross platforms**: compute points can only be consumed inside this app, with no form of external transfer
//     (the gift card is a badge voucher, not a compute-point transfer; red packets are compute points, but split equally only within the two parties' conversation).
//
//  ### The semantics of restoring purchases
//  `AppStore.sync()` lets Apple show its own confirmation, and this layer only counts "what was actually restored this time";
//  （`PopopxRestoreOutcome`：`restored(Int)` / `nothingToRestore` / `cancelled`）。
//  numbers use `%lld` (`String(format:)`), never `%d`: the width of NSInteger/Int changes on 32-bit devices.
//
//  ### Why "exchange compute points for a badge" stays on this page
//  It is the only badge-acquisition path that does not go through Apple (the funding source is points already paid for and exchanged),
//  so it must go through `PopopxBadgeManager.activate(withCredits:)`, the single entry that writes `.badgeRecord`,
//  and be covered by the gate together with it. It sits in the **secondary action** slot: it is the exit for "spending an existing balance",
//  not the entry for "new revenue", and presenting it as the main CTA would mislead users into thinking compute points can be gained out of thin air.
//
//  ### The Debug settlement (no second button anywhere on this screen)
//  The `.storekit` configuration file is injected only through Xcode's scheme; a package installed onto a real device with `xcrun devicectl device install app`
//  and launched from the home screen does not carry it, so `Product.products(for:)` hits the real store. Measured on device: 7 of the 12 SKUs
//  `PopopxNodeBadgeSku` declares come back, the 5 newest ones (the two one-time passes and the three credit gift cards) do not exist in App Store Connect yet,
//  and their tiers answered the main CTA with "this product is temporarily unavailable (…)".
//  To walk the commercial main path on a real device — pay → light up → land in Keychain → still present after a restart —
//  **the tier's own buy button** goes through `PopopxStoreKitManager.purchase(_:)`, which under `#if DEBUG` settles a SKU the store does not
//  carry by `purchaseSimulated(_:)`: a locally minted receipt → the **same** `settle` → the same `grantPass → PopopxBadgeManager.activate`.
//  There was once a dashed "Sandbox purchase" button under each card; it is deleted on purpose, because a side button means the tested tap
//  and the shipped tap are two different pieces of code. The whole block is wrapped in `#if DEBUG`,
//  so in the Release archive these symbols do not exist at all (only `Debug.xcconfig` has `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`)
//  and `.productNotFound` is the answer again.
//  What Release and Debug share character for character: the tier copy, the price line, the CTA's own slot and label, and the whole booking path
//  after the result comes back. Two things differ, both by one line: `canPurchase` lets the button through in Debug even when the store answered
//  nothing, and the toast says "this charge was not real" — read from the minted receipt (`PopopxStoreReceipt.isSimulatedSettlement`),
//  never volunteered by the caller.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.

import SwiftUI
import POPOPXChat

// MARK: - Layout model

/// One tier of the paywall. Deliberately without a price field: the price belongs to the runtime, the tier belongs to the design.
///
/// There is no `.credits` family here anymore (device round 8 · task three): if the badge page's layout model could still hold a
/// top-up pack, then "this page sells only badges" would be just a comment rather than a type constraint. After deleting the case,
/// any writing that tries to move the price table back will not compile at the `switch`.
struct PopopxPaywallSection: Identifiable, Hashable {
    enum Kind: Hashable {
        case subscription(PopopxNodeBadgePeriod)
        /// One-time duration pack: pay once, get `period.days` days, **never auto-renews**.
        /// It is a separate case from `.subscription` (rather than a bool on the subscription) because these two families'
        /// renewal wording, restore semantics and accounting paths all differ — only distinguishing them by type makes a missing branch a compile error.
        case oneTimePass(PopopxNodeBadgePeriod)
        case giftCard(PopopxNodeBadgePeriod)
    }

    let kind: Kind
    let title: String
    let note: String?
    let badge: String?
    let sku: PopopxNodeBadgeSku

    var id: String { sku.productId }

    var period: PopopxNodeBadgePeriod? {
        switch kind {
        case let .subscription(period): period
        case let .oneTimePass(period): period
        case let .giftCard(period): period
        }
    }

    /// The button verb is chosen per tier: subscription is "light up", the pass is "buy one duration", the gift is "buy one voucher".
    /// Three actions are three different things for the user, and sharing one "buy now" would make "buy for someone else" read as "buy for yourself".
    /// The pass slot goes through a localization key: it is a **new payment path**, and cannot borrow any of the Chinese constants above
    /// (those three are this page's existing copy; closing them off into keys would mean touching all 16 directories, beyond this round's scope).
    var actionTitle: String {
        switch kind {
        case .subscription: NSLocalizedString("Light up", comment: "")
        case .oneTimePass: PopopxCommerceCopy.passActionTitle
        case .giftCard: NSLocalizedString("Buy gift voucher", comment: "")
        }
    }
}

/// The paywall's **tier groups**: one group title + the cards under it.
///
/// The badge section is split into two groups because that one screen holds two payment paths at once, and their renewal facts are **opposite**:
/// a subscription charges again automatically when it expires, a pass ends after one payment. Mixed in one untitled list, users easily read
/// "light up yearly" and "365-day pass" as two spellings of the same thing, and only discover otherwise when a second charge appears on the bill.
/// The group title says only this one thing that needs saying, while the card footnotes (`renewalStatement` /
/// `oneTimePurchaseStatement`) still repeat it once inside each card — the title governs "grouping", the footnote governs "this card".
struct PopopxPaywallGroup: Identifiable {
    let id: String
    /// `nil` = this group needs no title (the gift tab is one family throughout the group, and a title would be noise).
    let title: String?
    let sections: [PopopxPaywallSection]
}

/// That fixed table.
enum PopopxPaywallPlan {
    /// The single source for the grouped view. `sections(tab:)` is its flattened version, kept for readings that only care about which tiers exist.
    static func groups(tab: PopopxPaywallTab) -> [PopopxPaywallGroup] {
        switch tab {
        case .badge:
            [
                // First group: the two tiers that charge automatically when they expire.
                PopopxPaywallGroup(id: "recurring",
                                   title: PopopxCommerceCopy.paywallAutoRenewGroupTitle,
                                   sections: [
                                       PopopxPaywallSection(kind: .subscription(.monthly),
                                                            title: NSLocalizedString("Light up monthly", comment: ""),
                                                            note: nil,
                                                            badge: nil,
                                                            sku: .subscriptionMonthly),
                                       PopopxPaywallSection(kind: .subscription(.annual),
                                                            title: NSLocalizedString("Light up annually", comment: ""),
                                                            note: NSLocalizedString("One annual tier; renew any time before it expires", comment: ""),
                                                            badge: nil,
                                                            sku: .subscriptionAnnual)
                                   ]),
                // Second group: the two tiers that end after one payment. Its title is the opposite of the first group's, and so is the card footnote (see `tierCard`).
                // The durations share the subscription group's cycle (30/365 days) and the prices are the same tiers $6.99 / $49.99 —
                // the two paths differ only in "will it charge again", not in what you get.
                PopopxPaywallGroup(id: "oneTime",
                                   title: PopopxCommerceCopy.paywallOneTimeGroupTitle,
                                   sections: [
                                       passSection(.monthly, .pass30Days),
                                       passSection(.annual, .pass365Days)
                                   ])
            ]
        case .giftCard:
            [
                PopopxPaywallGroup(id: "gift", title: nil, sections: [
                    PopopxPaywallSection(kind: .giftCard(.monthly),
                                         title: NSLocalizedString("Send a 30-day badge voucher", comment: ""),
                                         note: NSLocalizedString("A voucher is created; they redeem it with the code, and it stays valid until it is redeemed.", comment: ""),
                                         badge: nil,
                                         sku: .giftMonthly),
                    PopopxPaywallSection(kind: .giftCard(.annual),
                                         title: NSLocalizedString("Send a 365-day badge voucher", comment: ""),
                                         note: NSLocalizedString("Each voucher can be redeemed once; the redemption is confirmed on their own device.", comment: ""),
                                         badge: nil,
                                         sku: .giftAnnual)
                ])
            ]
        }
    }

    /// The pass tier card: the title is generated from a localized format string ("30-day pass" / "365-day pass"),
    /// and the day count has only one source, `PopopxNodeBadgePeriod`, so what the row writes and what is actually granted cannot diverge.
    private static func passSection(_ period: PopopxNodeBadgePeriod, _ sku: PopopxNodeBadgeSku) -> PopopxPaywallSection {
        PopopxPaywallSection(kind: .oneTimePass(period),
                             title: String(format: PopopxCommerceCopy.passTierTitleFormat, period.days),
                             note: nil,
                             badge: nil,
                             sku: sku)
    }

    static func sections(tab: PopopxPaywallTab) -> [PopopxPaywallSection] {
        groups(tab: tab).flatMap(\.sections)
    }

    // The compute-point cash pack table used to live in `PopopxPaywallPlan` itself (`creditPacks` / `creditsPack(_:_:)`).
    // Device round 8 · task three moved the whole group to the compute-points page, and its home is now `PopopxCreditPlan`
    // (`PopopxBadgeCreditsModels.swift`): keeping another set of top-up tiers in the badge page's model
    // is the starting point of the next "two products on one screen".
}

/// The paywall's two segments. The names follow the product, not "for whom":
/// `.badge` buys a badge for this device, `.giftCard` buys a voucher to give to somebody else.
/// The old case was named `myself` with the title "For myself" — on screen it explained neither what was sold
/// nor who owns what was bought, and device round 8 · task three closed it off together with the top-up tiers.
enum PopopxPaywallTab: String, CaseIterable, Hashable {
    case badge
    case giftCard

    var label: String {
        switch self {
        case .badge: PopopxCommerceCopy.paywallBadgeTab
        case .giftCard: PopopxCommerceCopy.paywallGiftTab
        }
    }
}

// MARK: - Panel

struct PopopxBadgePaywallView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var store = PopopxStoreKitManager.shared
    /// The pass accounting needs it (`activate` is the entry that is "the single place writing `.badgeRecord`"),
    /// and it also lets this page read the new phase immediately after lighting up — the read side of `@Observable` is this page itself.
    @State private var badge = PopopxBadgeManager.shared
    @State private var toast = PopopxToastModel()

    @State private var tab: PopopxPaywallTab = .badge
    @State private var busySkuId: String?
    @State private var showsRedeem = false
    @State private var showsCreditExchange = false
    @State private var showsWallet = false
    /// The page the gift tier automatically goes to after purchase, plus the tier that page should prefill (so the user need not choose again).
    @State private var showsGiftQueue = false
    @State private var giftQueuePeriod: PopopxNodeBadgePeriod = .monthly
    @State private var isRestoring = false

    var body: some View {
        PopopxSheetContainer(PopopxCommerceCopy.paywallTitle,
                             subtitle: PopopxCommerceCopy.nodeClusterTerm) {
            content
        } footer: {
            footer
        }
        .popopxToast(toast)
        .sheet(isPresented: $showsRedeem) { PopopxVoucherRedeemSheet() }
        .sheet(isPresented: $showsCreditExchange) { PopopxBadgeCreditExchangeSheet() }
        .sheet(isPresented: $showsWallet) { PopopxCreditsStoreView() }
        .sheet(isPresented: $showsGiftQueue) { PopopxGiftBadgeCardSheet(period: giftQueuePeriod) }
        .task { await store.loadProducts() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                PopopxSegmentedControl(
                    PopopxPaywallTab.allCases.map { .init(selection: $0, title: $0.label) },
                    title: { $0.label },
                    selection: $tab
                )

                if !canPurchase {
                    // The same rule as the CTA's: this sentence and a live buy button must not appear together.
                    storeUnavailableNote
                }

                #if DEBUG
                if showsSandboxStrip {
                    sandboxStrip
                }
                #endif

                ForEach(PopopxPaywallPlan.groups(tab: tab)) { group in
                    if let title = group.title {
                        groupHeader(title)
                    }
                    ForEach(group.sections) { section in
                        tierCard(section)
                    }
                }

                benefitStrip
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    // MARK: Tier cards

    /// The group title. Deliberately **not** inside `PopopxSectionCard`: that one is for "a few rows inside a light card",
    /// and stuffing two brand-colored tier cards into a light card would add another layer of rounded corners, reading like a settings page rather than a price list.
    /// Here it does one thing only — lift the "will it charge again" family distinction above the cards, so the scanning order meets it first.
    private func groupHeader(_ title: String) -> some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Text(verbatim: title)
                .font(PopopxType.emphasis)
                .foregroundStyle(PopopxPalette.label)
            Spacer(minLength: PopopxMetrics.spaceS)
        }
        .padding(.top, PopopxMetrics.spaceXS)
        .accessibilityAddTraits(.isHeader)
    }

    /// Whether a tier's buy button may be tapped. Release asks the store, and an unloaded store greys the CTA out — that is the honest answer.
    /// Debug additionally accepts "the store has nothing, but `purchase(_:)` can still settle it locally": a build installed without a
    /// `.storekit` configuration would otherwise disable exactly the buttons that still have a working path behind them.
    /// Turning the settlement off with the environment variable puts the button back under the same rule as Release, which is the point of the switch.
    private var canPurchase: Bool {
        #if DEBUG
        if PopopxStoreKitManager.simulatedSettlementEnabled { return true }
        #endif
        return store.isStoreReady
    }

    private func tierCard(_ section: PopopxPaywallSection) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(verbatim: section.title)
                        .font(PopopxType.title)
                        .foregroundStyle(PopopxPalette.onBrand)
                    if let note = section.note {
                        Text(verbatim: note)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.onBrand.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: PopopxMetrics.spaceS)
                if let badge = savingBadge(for: section) {
                    Text(verbatim: badge)
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.onBrand)
                        .padding(.horizontal, PopopxMetrics.spaceXS)
                        .padding(.vertical, PopopxMetrics.space2XS)
                        .background(PopopxPalette.onBrand.opacity(0.18), in: .capsule)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                // The price and the "/mo · /yr" suffix come at once from `priceText(for:periodSuffix:)`:
                // `suffix(for:)` is a private method of PopopxStoreKitManager, and this panel does not copy its wording.
                Text(verbatim: store.priceText(for: section.sku, periodSuffix: section.sku.isSubscription))
                    .font(PopopxType.display)
                    .foregroundStyle(PopopxPalette.onBrand)
                Spacer(minLength: PopopxMetrics.spaceS)
                Button {
                    Task { await buy(section.sku) }
                } label: {
                    Text(verbatim: busySkuId == section.sku.productId ? Copy.working : section.actionTitle)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.brand)
                        .padding(.horizontal, PopopxMetrics.spaceM)
                        .frame(height: PopopxMetrics.minHitTarget)
                        .background(PopopxPalette.card, in: .capsule)
                }
                .disabled(!canPurchase || busySkuId != nil)
                .opacity(canPurchase ? 1 : 0.5)
                .accessibilityLabel(Text(verbatim: "\(section.actionTitle) \(section.title)"))
            }

            if let statement = renewalStatement(for: section) {
                Text(verbatim: statement)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.onBrand.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.brand, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
    }

    /// The card's one slot for "does this tier really charge again". Two sentences occupy **the same position** with the same typography,
    /// so when the two payment paths are scanned side by side the only difference is that sentence itself — that is the shape 3.1.2(c) asks for.
    /// Exhaustive over `kind` rather than asking `sku.isSubscription`: when another family is added later, the compiler forces this place to take a position.
    private func renewalStatement(for section: PopopxPaywallSection) -> String? {
        switch section.kind {
        case .subscription: PopopxCommerceCopy.renewalStatement
        case .oneTimePass: PopopxCommerceCopy.oneTimePurchaseStatement
        case .giftCard: nil
        }
    }

    /// The discount badge. The annual tier's "save X%" is **computed from two live prices**, not a fixed number:
    /// once prices change, a fixed "33%" immediately becomes a false statement (the current configuration 6.99×12 vs 49.99 is actually 40%),
    /// and "how much is saved" is a statement that both review and advertising check. While prices have not been read the badge is simply not shown — missing rather than false.
    /// The subscription annual tier and the **pass annual tier** go through the same algorithm (see `percentSaved`): both families are
    /// "twelve monthly buys" against "one buy covering a whole year", the baseline is the same, so the badge's wording must be the same too.
    private func savingBadge(for section: PopopxPaywallSection) -> String? {
        switch section.kind {
        case .subscription(.annual):
            percentSaved(monthly: .subscriptionMonthly, annual: .subscriptionAnnual)
        case .oneTimePass(.annual):
            percentSaved(monthly: .pass30Days, annual: .pass365Days)
        default:
            section.badge
        }
    }

    /// The percentage saved by "buying monthly 12 times" against "buying one year at once". `months` is fixed at 12:
    /// both SKUs have cycles of 30 days and 365 days, and 30×12=360 days is slightly fewer than 365 days,
    /// so this statement is **conservative** (counting the extra 5 days into "saved" is the usual convention for this kind of comparison, not an exaggeration).
    private func percentSaved(monthly monthlySku: PopopxNodeBadgeSku, annual annualSku: PopopxNodeBadgeSku) -> String? {
        guard let monthly = store.product(for: monthlySku)?.price,
              let annual = store.product(for: annualSku)?.price,
              monthly > 0 else { return nil }
        let fullPrice = monthly * 12
        let saved = fullPrice - annual
        guard saved > 0 else { return nil }
        let percent = NSDecimalNumber(decimal: saved / fullPrice).doubleValue * 100
        guard percent >= 1 else { return nil }
        return String(format: PopopxCommerceCopy.savePercentFormat, Int(percent.rounded()))
    }

    /// Five benefit lines, each corresponding to something this module actually built: the badge capsule (`PopopxBadgeCapsule`),
    /// the node status panel (`PopopxBadgeDetailSheet`), gift cards and red packets (`PopopxCommerceCards` / the router).
    /// Two wording red lines: no encrypted-tunnel vocabulary may appear, and **no unshipped benefit may appear either**
    /// ("high-concurrency priority scheduling", "dynamic IP rotation" and "1GB dedicated large files" were withdrawn in the 2026-11-19 product ruling —
    /// the criterion and residual risk are in the table at `Docs/app-store-review-notes.md` section 1).
    private var benefitStrip: some View {
        PopopxSectionCard(Copy.benefitsTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                benefit("seal.fill", Copy.benefitBadge)
                benefit("chart.bar.xaxis", Copy.benefitStatusPanel)
                benefit("qrcode", Copy.benefitCards)
                benefit("lock.shield", Copy.benefitNoRead)
                benefit("person.2.slash", Copy.benefitNoAccount)
            }
        }
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: symbol)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.brand)
                .frame(width: PopopxMetrics.spaceXL)
            Text(verbatim: text)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Store not ready

    private var storeUnavailableNote: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "wifi.slash").foregroundStyle(PopopxPalette.labelHint)
            Text(verbatim: Copy.storeUnavailable).font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
        .padding(PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.separator.opacity(0.5), in: .rect(cornerRadius: PopopxMetrics.radiusControl))
    }

    // MARK: Debug settlement note (only Debug builds compile this whole section)

    #if DEBUG
    /// The explanation line at the top, drawn when at least one tier of the segment on screen has no product.
    /// It is a **note, not an entry point**: since `purchase(_:)` took over the local settlement there is nothing extra to tap here,
    /// and the sentence exists so that the tap the user already makes is not read as an Apple transaction.
    /// Judged over the current segment's tiers: this line appears if any item in either family failed to come back — it explains "why the products cannot be read",
    /// which is independent of which particular item; explaining item by item would turn this segment into a log dump.
    /// The CTA's own enablement does **not** read this (`canPurchase` answers that), and the two are deliberately out of step for one moment:
    /// while the first product load is still in flight the button is already live in Debug and the note is not yet on screen.
    /// Tying the button to the note would put the tap behind a label; tying the label to the button would hide the explanation exactly when
    /// the store is slowest to answer, which is the case the sentence exists for.
    private var showsSandboxStrip: Bool {
        PopopxPaywallPlan.sections(tab: tab).contains { store.isMissingFromStore($0.sku) }
    }

    private var sandboxStrip: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "hammer.fill")
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.meshInk)
                Text(PopopxCommerceCopy.sandboxPaywallNote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The diagnostic line is not copy, it is an identifier for whoever is troubleshooting, so it renders verbatim, goes into no directory,
            // and allows long-press select and copy — pasting it into a ticket is far more useful than restating "temporarily unavailable".
            Text(verbatim: storeDiagnostics)
                .font(PopopxType.metricSmall)
                .foregroundStyle(PopopxPalette.labelHint)
                .textSelection(.enabled)
                .accessibilityHidden(true)
        }
        .padding(PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay {
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(PopopxPalette.meshInk.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    /// The conclusion of this product load, spread verbatim on screen. The three causes must be tellable apart face to face on a real device:
    /// `0/12 loaded` = the store gave nothing for the whole batch (no configuration file attached, offline), `7/12 · missing: …pass.30d, …pass.365d`
    /// = only some families failed to come back (those identifiers do not exist in ASC yet), `load error: …` = Apple threw an error.
    /// The denominator is read from `PopopxNodeBadgeSku.productIds`, so adding a SKU cannot leave this line claiming a different total than the app asked for.
    /// Troubleshooting from `missingProductIDs` alone (that one log line) needs Console, which is unrealistic on a real device.
    private var storeDiagnostics: String {
        if let error = store.lastLoadError { return "load error: \(error)" }
        var line = "\(store.products.count)/\(PopopxNodeBadgeSku.productIds.count) loaded"
        let missing = store.missingProductIDs
        if !missing.isEmpty { line += " · missing: \(missing.joined(separator: ", "))" }
        return line
    }
    #endif

    // MARK: Secondary actions

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxButton(PopopxCommerceCopy.paywallRedeemEntry, systemImage: "qrcode.viewfinder",
                             role: .secondary, fullWidth: true) {
                    showsRedeem = true
                }
                PopopxButton(PopopxCommerceCopy.paywallUseCredits, systemImage: "sparkles",
                             role: .secondary, fullWidth: true) {
                    showsCreditExchange = true
                }
            }
            HStack(spacing: PopopxMetrics.spaceL) {
                Link(Copy.privacyPolicy, destination: URL(string: "https://popopx.chat/privacy")!)
                Link(Copy.termsOfUse, destination: URL(string: "https://popopx.chat/terms")!)
            }
            .font(PopopxType.caption)
            .foregroundStyle(PopopxPalette.labelSecondary)
            HStack(spacing: PopopxMetrics.spaceL) {
                Button(PopopxCommerceCopy.paywallRestore) {
                    Task { await restore() }
                }
                .disabled(isRestoring)
                // This button is this page's only entry to the "POPOPX compute points" page, so it uses the product's full name rather than the bare
                // "compute points" phrase: the name is character-for-character the same as that page's title, so users know which screen they will land on.
                // The cash price list itself is not on this page (device round 8 · task three).
                Button(PopopxCommerceCopy.creditsName) { showsWallet = true }
                Button(Copy.close) { dismiss() }
            }
            .font(PopopxType.caption)
            .foregroundStyle(PopopxPalette.brand)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Actions

    /// The tier's one and only buy path, in Debug and in Release alike: hand the SKU to `PopopxStoreKitManager.purchase(_:)` and settle whatever comes back.
    /// This page asks nothing about whether the store carries that product — who answers (Apple, or the Debug local settlement) is the manager's decision.
    /// There used to be a second entry point here for the sandbox; it is gone on purpose, because a side button means the tap tested on a device
    /// is not the tap that ships.
    private func buy(_ sku: PopopxNodeBadgeSku) async {
        guard busySkuId == nil else { return }
        busySkuId = sku.productId
        defer { busySkuId = nil }
        let result = await store.purchase(sku)
        await settle(result, for: sku)
    }

    /// The on-screen close-off of one purchase (a real one, or the Debug settlement of a SKU the store does not carry).
    ///
    /// How the credit line is said is read from the **receipt** (`isSimulatedSettlement`), not from an argument: "this charge was not real"
    /// is a money fact, and a fact that depends on every caller volunteering it correctly is one that goes missing at the first call site added in a hurry.
    /// Letting a tester read a local simulation on a real device as an Apple transaction is worse than reading nothing at all.
    /// The three steps of accounting, haptic, and jumping to the gift queue after success are the same code for both sources.
    private func settle(_ result: Result<PopopxStorePurchaseOutcome, PopopxBadgeCreditsError>,
                        for sku: PopopxNodeBadgeSku) async {
        switch result {
        case let .success(.purchased(receipt)):
            // The one-time duration pack **must be lit on this transaction's return path, in the moment**. The criterion is this family's delivery path itself:
            // neither of the manager's two accounting legs accepts it (`PopopxBadgeManager.apply(storeReceipt:)` filters by
            // `isSubscription`, and `PopopxCreditsManager.apply(storeReceipt:)` returns directly for `.oneTimePass`),
            // and the restore flow also excludes it from re-granting (Apple gives no "restore" semantics for non-renewing subscriptions,
            // and re-granting by duration would simply give a period away). In other words: once this money is paid, nothing but here will light it.
            // Waiting for a callback that does not exist = the user paid for nothing, and that is this module's original sin, reviewed three times.
            // Lighting up still goes only through the single entry `PopopxBadgeManager.activate`; here the job is only to compute the expiry moment (see `grantPass`).
            if let period = sku.oneTimePassPeriod, await grantPass(period, receipt: receipt) == false {
                return
            }
            PopopxHaptics.notice(.success)
            #if DEBUG
            if receipt.isSimulatedSettlement {
                toast.show(Copy.sandboxPurchased(sku), kind: .encrypted)
            } else {
                toast.show(Copy.purchased(sku), kind: .encrypted)
            }
            #else
            toast.show(Copy.purchased(sku), kind: .encrypted)
            #endif
            if case let .giftCard(period) = sku.kind {
                // The gift tier: the voucher is minted in the delivery callback, and this page takes the user directly to the page where it can be seen.
                giftQueuePeriod = period
                showsGiftQueue = true
            }
        case .success(.pending):
            toast.show(Copy.pending, kind: .success)
        case .success(.cancelled):
            break
        case let .failure(error):
            // Cancellation is not an error: no haptic, no red marking; only a real failure says `PopopxBadgeCreditsError`'s sentence exactly as it is.
            toast.show(error.errorDescription ?? Copy.genericFailure, kind: .danger)
        }
    }

    /// The duration pack's accounting. **The only entry writing `.badgeRecord` remains `PopopxBadgeManager.activate`**;
    /// this layer is responsible only for the expiry moment: `badge.stackedExpiryMs(period:)` = `max(now, this device's current expiry) + period.days`.
    /// Taking `max(now, current expiry)` instead of starting from `now` is so that a pass always **stacks** on top of the remaining time —
    /// with 200 days left on the badge, buying a 30-day pass expires at 230 days, not at 30.
    /// This formula exists exactly once in the project: the pass, the compute-point exchange and the gift voucher legs all call it
    /// (`PopopxBadgeManager.stackedExpiryMs`), and the UI's "add N days" and the accounting use the same number.
    /// (the merge semantics of the `max(incoming, existing)` line inside `activate` are not changed by a word; what is passed here is an already computed moment,
    /// so two maxes stacked can only yield the same result and never count the time twice.)
    /// The order is this module's only defence against "money paid but nothing happened": **light up first, then `finish`**.
    /// If lighting up fails there is no finish, the transaction stays on Apple's side, and the user can get it again next time.
    private func grantPass(_ period: PopopxNodeBadgePeriod, receipt: PopopxStoreReceipt) async -> Bool {
        do {
            try badge.activate(period: period, source: .storePass,
                               expiresAtMs: badge.stackedExpiryMs(period: period),
                               receiptDigest: receipt.digest)
        } catch {
            // Say the truth exactly as it is (Keychain cannot be written, and the clock was set to the past, are two different sentences).
            // The `catch` binding is `any Error`, so `errorDescription` can only be reached through `LocalizedError`;
            // the two `case let .failure(error)` places above need no such detour because Result's failure type is already concrete.
            PopopxHaptics.notice(.error)
            toast.show((error as? LocalizedError)?.errorDescription ?? Copy.genericFailure, kind: .danger)
            return false
        }
        await store.finish(receipt)
        return true
    }

    private func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        switch await store.restorePurchases() {
        case let .success(outcome):
            // The count is only used to pick the tone: `restored(Int)` uses the "restored" copy,
            // and a zero restore and a user cancellation each say their own thing, never merged into one "done".
            if case .restored = outcome {
                toast.show(outcome.announcementText, kind: .encrypted)
            } else {
                toast.show(outcome.announcementText, kind: .success)
            }
        case let .failure(error):
            toast.show(error.errorDescription ?? Copy.genericFailure, kind: .danger)
        }
    }
}

private extension PopopxBadgePaywallView {
    enum Copy {
        static let working = NSLocalizedString("Working…", comment: "")
        static let close = NSLocalizedString("Close", comment: "")
        static let privacyPolicy = NSLocalizedString("Privacy Policy", comment: "")
        static let termsOfUse = NSLocalizedString("Terms of Use", comment: "")
        static let benefitsTitle = NSLocalizedString("After you light it up", comment: "")
        static let benefitBadge = NSLocalizedString("The top bar shows this badge: it appears only while the badge is active and is withdrawn when it expires.", comment: "")
        static let benefitStatusPanel = NSLocalizedString("Badge details is a local node status panel: tier, expiry, reconciliation summary, local counts. Read-only, never uploaded.", comment: "")
        static let benefitCards = NSLocalizedString("A badge can be turned into a QR-code gift card and passed peer to peer; Compute Credits go to a friend as a red packet they open on their own device.", comment: "")
        static let benefitNoRead = NSLocalizedString("Relay nodes only move ciphertext: they cannot see chat content and cannot get your contact list.", comment: "")
        static let benefitNoAccount = NSLocalizedString("No account and no central ledger: badges, vouchers and Compute Credits all live in this device's Keychain.", comment: "")
        // There used to be two more lines here, `wallet = "compute points"` and `creditsTitle = creditsName`, serving the top-up cards;
        // after the whole top-up group moved away they had no readers (leaving an unread Chinese constant in `Copy` is the source of the next round's missing translations).
        static let storeUnavailable = NSLocalizedString("The store cannot be read right now: cards still show their list prices, and buying works again once the network is back.", comment: "")
        static let pending = NSLocalizedString("Apple is still confirming this purchase; the badge lights up automatically once it is approved.", comment: "")
        static let genericFailure = NSLocalizedString("That did not complete.", comment: "")
        static func purchased(_ sku: PopopxNodeBadgeSku) -> String {
            switch sku.kind {
            case let .subscription(period):
                String(format: NSLocalizedString("Purchased · badge lit for %lld days", comment: ""), period.days)
            case let .oneTimePass(period):
                // The pass credit line goes through a localization key (a new sentence, not added to that group of Chinese constants above).
                String(format: PopopxCommerceCopy.passGrantedFormat, period.days)
            case let .giftCard(period):
                String(format: NSLocalizedString("Gift voucher created · %lld days", comment: ""), period.days)
            case let .credits(amount), let .creditGiftCard(amount):
                // Neither credit tier is sold on this page, so this branch is unreachable under the current layout; it stays because the `switch`
                // must be exhaustive over `PopopxNodeBadgeSkuKind` — the sentence for a real credit lives on the compute-points page
                // (`PopopxCreditsStoreView.topUpCard`), and it reads a localization key, not this one.
                String(format: PopopxCommerceCopy.creditsTopUpGrantedFormat, amount)
            }
        }
        #if DEBUG
        /// The sandbox credit line. **Every sentence carries "no money was charged"**: this toast slot looks exactly like a real transaction,
        /// and the sentence itself is the only thing that separates the two, so it must not be shortened to "purchased".
        /// The pass sentence carries the day count (the same source as `purchased(_:)`: `PopopxNodeBadgePeriod.days`),
        /// while the other two families do not credit "days", so they only say "a test purchase was recorded on this device".
        static func sandboxPurchased(_ sku: PopopxNodeBadgeSku) -> String {
            guard let period = sku.oneTimePassPeriod else { return PopopxCommerceCopy.sandboxPurchaseGranted }
            return String(format: PopopxCommerceCopy.sandboxPassGrantedFormat, period.days)
        }
        #endif
    }
}

// MARK: - Previews

struct PopopxBadgePaywallDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgePaywallView()
            .preferredColorScheme(.dark)
    }
}

struct PopopxBadgePaywallLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgePaywallView()
            .preferredColorScheme(.light)
    }
}
