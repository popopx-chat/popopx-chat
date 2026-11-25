//  PopopxCreditsStoreView.swift
//
//  [Phase 6 · 1] Compute Credits hub: balance, cash-pack top-up, uses table, ledger — plus the gift-card segment (buy / mint / hold).
//
//  ### This page has exactly one product: POPOPX compute credits themselves (real-device round 8 · task 3)
//  On screen are four things — **balance**, **the four cash-pack tiers 100 / 500 / 2000 / 5000**, **where credits can be spent**, **the ledger**.
//  Badge subscriptions, one-off passes and gift badge vouchers are all off this page (they belong to `PopopxBadgePaywallView`,
//  and that page in turn no longer draws any top-up price list). Before this, each of the two screens showed both the "membership" and "credits" products at the same time,
//  a user reading them in one list would buy the wrong thing: that is a monetisation P0, not a layout preference.
//  The only "badge-related" thing this page keeps is the **spend an existing balance** path (the first row of the uses table and the footer's
//  `light up a badge with compute credits`, both open `PopopxBadgeCreditExchangeSheet`): it is the exit for that family of spending scenarios on this page,
//  not a card that sells badges — it takes no money, it only spends credits the user has already paid for once.
//
//  ### Two segments, still one product
//  `PopopxCreditsStoreTab` splits the page by **who receives the credits**, not by product: `Recharge` puts them on this device,
//  `Gift Credits` cuts the same three denominations into transferable cards. The tiers, the face values and the list prices are the same
//  table on both sides (`PopopxCreditPlan.packs` / `.giftPacks`), so the "one page, one product" rule above is untouched — what moved is the
//  sentence that says where the money goes, which is precisely the sentence that must never be shared between the two halves.
//  The gift half is kept off the badge paywall for the same reason the cash packs were: the paywall page owns badge time, this page owns credits.
//  The two halves differ in their witness of "did my purchase land": a top-up is verified by the balance moving, a gift card by a new row
//  in `PopopxP2PVoucherVault` (its money never touches the balance), so each has its own `buy` and they are not interchangeable.
//  The footer carries the code door (`enter a code or scan`) permanently, outside the segments: a code in hand does not care which half
//  of the page was on screen, and the same door has always sat in the paywall footer with the same word on it.
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
//  `PopopxCreditsEntry.note` is the localised sentence written at the moment of the debit/credit (`PopopxCreditsCopy`),
//  so this page needs no second "category → copy" mapping; `kind.sign` gives the direction, `kind.isIncome` the colour,
//  and both are defined in that one place only.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.

import SwiftUI
import POPOPXChat

struct PopopxCreditsStoreView: View {
    /// Set when the page is opened **from a conversation** (the "+" panel's `creditsGiftCard` cell). It changes exactly two things:
    /// the page opens on the gift segment rather than the recharge one, and the card face grown from the wallet list draws its
    /// "send in this conversation" button. Nothing else here reads it — the balance, the ledger and the price tables belong to this device
    /// no matter who opened the page, and a chat must not be able to change what a top-up costs.
    var contactId: Int64? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var credits = PopopxCreditsManager.shared
    /// The cash packs' price and product table. The read side of the `@Observable` is this page: until prices load, a row shows
    /// the SKU's own `fallbackPriceText` (the face value in App Store Connect), and the button is disabled at the same time,
    /// so neither the "whole page blank" nor the "pressed and nothing happened" failure reaches the user (same standard as the paywall).
    @State private var store = PopopxStoreKitManager.shared
    @State private var showsExchange = false
    /// The permanent "I have a code" door. It sits in the footer rather than inside a segment because a code in hand does not
    /// care which half of the page the user was reading, and because the badge paywall's footer has always had this same door —
    /// two pages, one word for it (`paywallRedeemEntry`), so the review sees one entry pattern instead of two.
    @State private var showsRedeem = false
    /// The cash pack currently going through StoreKit. Only one at a time is allowed, otherwise the arrival order of two cannot be explained to the user.
    @State private var busySkuId: String?
    /// Which half of the page is on screen: buying credits for this device, or buying a gift card for somebody else.
    @State private var tab: PopopxCreditsStoreTab = .recharge
    /// Unused credit gift cards held in this device's vault. Read from `PopopxP2PVoucherVault`, which is the only place that knows
    /// whether a card still exists — a locally cached "count" would be a second source of truth for a thing the user can spend elsewhere.
    @State private var giftCards: [PopopxNodeVoucher] = []
    /// How many gift cards to mint in the pay-with-credits path. Capped by the badge page's same `quantityCap`, so one number governs both families.
    @State private var giftQuantity = 1
    /// The message typed for the cards on this half of the page. One field serves both ways of getting a card — bought with Apple or cut from
    /// the balance — and it is stored per voucher id the moment a card exists, so the wallet list below shows the same line on the second look.
    /// A batch takes the one text on purpose: the sentence belongs to the purchase, and nothing here invents a different one per card.
    @State private var giftNote = ""
    @State private var exchanging = false
    /// A card whose face is open: the code, the QR, copy / share. `PopopxGiftCardPresenter` is the badge page's own card face and serves
    /// both families, so this page presents the very same view rather than a second QR path that could drift.
    @State private var openCard: PopopxMintedGiftCard?
    /// The cosmetic tier awaiting confirmation. The dialog's visibility derives from it (the Binding below), so there is no
    /// "dialog still open but nobody is being confirmed" intermediate frame — same shape as the profile-card unlock elsewhere.
    @State private var pendingCosmetic: PopopxCosmetic?
    /// The result of the last credit action (top-up or cosmetic unlock), one sentence only. It is not called a "toast" and it does not auto-dismiss: this page is a ledger page,
    /// the user needs to see "those 150 credits really were booked" and "the 500 credits just bought really did arrive", and a sentence that removes itself equals no sentence at all.
    @State private var spendNote: String?

    /// The explicit init exists for one line of behaviour: coming in from a conversation, the segment the user lands on is the one they came for.
    /// `@State` stays the right storage for it — the page owns the choice afterwards, and tapping back to `Recharge` mid-gift is legitimate.
    init(contactId: Int64? = nil) {
        self.contactId = contactId
        _tab = State(initialValue: contactId == nil ? .recharge : .gift)
    }

    var body: some View {
        PopopxSheetContainer(Copy.title, subtitle: PopopxCommerceCopy.nodeClusterTerm) {
            content
        } footer: {
            footer
        }
        .sheet(isPresented: $showsExchange) { PopopxBadgeCreditExchangeSheet() }
        .sheet(isPresented: $showsRedeem) { PopopxVoucherRedeemSheet() }
        .sheet(item: $openCard) { minted in
            // The badge page's own card face, unchanged. `contactId` is nil whenever this page was opened from "Me", and the presenter
            // draws no "send in this conversation" button in that case — the copy / share exits stay, so nothing depends on the chat.
            PopopxGiftCardPresenter(card: minted, contactId: contactId)
        }
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
            await loadGiftCards()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                balanceCard

                if credits.wallet.needsReconcile {
                    reconcileNote
                }

                PopopxSegmentedControl(
                    PopopxCreditsStoreTab.allCases.map { .init(selection: $0, title: $0.label) },
                    title: { $0.label },
                    selection: $tab
                )

                #if DEBUG
                if showsSandboxStrip {
                    sandboxStrip()
                }
                #endif

                if tab == .recharge {
                    topUpCard

                    usesCard
                } else {
                    giftNoteField

                    giftBuyCard

                    giftExchangeCard

                    giftWalletCard
                }

                if let spendNote {
                    spendLine(spendNote)
                }

                if tab == .recharge {
                    pendingCard

                    ledgerCard
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

    /// Whether the two purchase tiers may be tapped, and whether the "store is not available" line belongs on screen.
    /// Release asks the store; Debug additionally accepts "the store has nothing, but `purchase(_:)` can still settle it locally" —
    /// a Debug build installed without a `.storekit` configuration would otherwise disable exactly the buttons that still have a working path behind them.
    /// The same rule drives both the button and that sentence, so the page can never show "unavailable" over a live buy button.
    private var canPurchase: Bool {
        #if DEBUG
        if PopopxStoreKitManager.simulatedSettlementEnabled { return true }
        #endif
        return store.isStoreReady
    }

    /// Four cash-pack tiers: 100 / 500 / 2000 / 5000. This card is the only place on the page that takes money, and it sells exactly one thing —
    /// compute credits themselves. The rows are `PopopxCreditPlan.packs` in a `ForEach`, so a tier added to that table draws itself here;
    /// there is no second list of denominations on this page to forget. The tier table is `PopopxCreditPlan` (face value derived from the SKU's `creditedAmount`),
    /// and prices come from StoreKit, so between "the face value written on the row" and "the face value actually booked" there is no third place that can say something different.
    /// The footnote "never any bonus credit" (`noGiftBackStatement`) used to live permanently on the paywall's top-up tiers; after moving the whole group it moved along.
    private var topUpCard: some View {
        PopopxSectionCard(PopopxCommerceCopy.creditsTopUpTitle,
                          footnote: PopopxCommerceCopy.noGiftBackStatement) {
            VStack(spacing: 0) {
                if !canPurchase {
                    // Store unreadable: the tiers are still drawn (face value is this module's fact), the price slot shows the SKU's own listed price,
                    // and the button is disabled. The same `canPurchase` decides both, so this sentence can never sit above a live buy button —
                    // in Debug, where the local settlement is armed, neither the sentence nor the grey state appears.
                    // This sentence reuses `PopopxCommerceCopy.errorStoreUnavailable` —
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
            .disabled(!canPurchase || busySkuId != nil)
            .opacity(canPurchase ? 1 : 0.5)
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
        // One call for both worlds: `purchase(_:)` asks Apple when the store carries the SKU and, in Debug only, settles it locally when it does not.
        // Everything after the result — booking, verifying, phrasing — is the same code either way, so a sandbox walk cannot pass on a path the real one lacks.
        let result = await store.purchase(pack.sku)
        switch result {
        case let .success(.purchased(receipt)):
            await credits.apply(storeReceipt: receipt)
            if credits.balance != before {
                PopopxHaptics.notice(.success)
                spendNote = withSettlementNote(String(format: PopopxCommerceCopy.creditsTopUpGrantedFormat, pack.amount), receipt: receipt)
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

    /// A result line that has to say when the charge was not real.
    ///
    /// The money fact rides the **receipt**, not a page-top note: the note only appears once a product load has answered
    /// (`isMissingFromStore`), while this line is on screen at the moment the entitlement appears. It is also the reason the Debug settlement
    /// needs no button of its own — a second button was one way to say "not a real purchase", and this sentence says it wherever the
    /// real-looking result line appears.
    ///
    /// Compiles to a passthrough in Release: no receipt Apple handed over can carry the mark, and the mark's own definition is Debug-only.
    private func withSettlementNote(_ text: String?, receipt: PopopxStoreReceipt) -> String? {
        #if DEBUG
        if receipt.isSimulatedSettlement, let text {
            return "\(text) · \(PopopxCommerceCopy.sandboxPurchaseGranted)"
        }
        #endif
        return text
    }

    // // MARK: Gift segment · buying a credit gift card with Apple

    /// The message that goes with a card made on this half of the page. One field, both ways of getting a card, because a text that
    /// only existed under one of the two strips would be a card whose message depends on which button was pressed.
    /// It reuses the badge gift sheet's own three keys — same label, same prompt, same 60-character hint — so the two pages say
    /// one thing in all 16 catalogues instead of carrying two translations of the same idea.
    private var giftNoteField: some View {
        PopopxTextField(PopopxGiftBadgeCardSheet.Copy.noteTitle,
                        prompt: PopopxGiftBadgeCardSheet.Copy.notePrompt,
                        text: $giftNote)
            .accessibilityHint(PopopxGiftBadgeCardSheet.Copy.noteHint)
            .accessibilityIdentifier("popopx.credits.giftNote")
    }

    /// Attach the typed message to the cards that just appeared, then show the first one face-up: the same two steps the badge gift
    /// sheet runs, so buying a credit card here ends on the card face (QR, grouped code, copy / share) and not on the price list
    /// with one line of text under it. The wallet list is already refreshed by the caller before this runs.
    /// Storing comes before opening: a poster that showed a message the Keychain never received is a message that disappears at the
    /// next launch, and the card would then be re-shared with an empty `n=` field although the first recipient read a sentence.
    /// A failed write is not announced here — the text still shows and still goes out now; what it costs is only the second look.
    private func attachNoteAndOpen(_ cards: [PopopxNodeVoucher]) async {
        guard let first = cards.first else { return }
        if !giftNote.isEmpty {
            await PopopxP2PVoucherVault.shared.recordNote(giftNote, forVoucherIds: cards.map(\.voucherId))
        }
        openCard = PopopxMintedGiftCard(voucher: first, note: giftNote)
    }

    /// The three gift-card tiers. Same face values and the same list prices as the top-up tiers above — only the receiver differs,
    /// and the row says so in its footnote: **nothing lands on this balance**. That sentence is the whole reason this segment exists
    /// separately from `topUpCard`; a tier table that silently credits someone else would be the most expensive misreading on this page.
    /// Booking goes through the same `PopopxCreditsManager.apply(storeReceipt:)` entry, which for a `.creditGiftCard` receipt mints
    /// exactly one voucher into the vault instead of adding to the balance — the two outcomes are chosen by the SKU's own `kind`,
    /// so this page cannot turn a gift into a top-up by forgetting an argument.
    private var giftBuyCard: some View {
        PopopxSectionCard(PopopxCommerceCopy.creditsGiftAction,
                          footnote: PopopxCommerceCopy.creditsGiftPackFootnote) {
            VStack(spacing: 0) {
                if !canPurchase {
                    Text(PopopxCommerceCopy.errorStoreUnavailable)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .padding(.bottom, PopopxMetrics.spaceXS)
                }
                ForEach(Array(PopopxCreditPlan.giftPacks.enumerated()), id: \.element.id) { index, pack in
                    if index > 0 { divider }
                    giftPackRow(pack)
                }
            }
        }
    }

    /// A gift row carries the price in the title column and the action word in the button, which is the opposite of a top-up row:
    /// there, the button *is* the price. A gift is not "spend X to get X" for the person tapping it, so the button has to say who it is for.
    private func giftPackRow(_ pack: PopopxCreditPack) -> some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: pack.title)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                Text(verbatim: store.priceText(for: pack.sku, periodSuffix: false))
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelHint)
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            Button {
                Task { await buyGift(pack) }
            } label: {
                HStack(spacing: PopopxMetrics.space2XS) {
                    if busySkuId == pack.sku.productId {
                        ProgressView()
                    } else {
                        Text(verbatim: PopopxCommerceCopy.creditsGiftAction)
                        Image(systemName: "chevron.right")
                    }
                }
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.brand)
                .frame(minHeight: PopopxMetrics.minHitTarget)
            }
            .disabled(!canPurchase || busySkuId != nil)
            .opacity(canPurchase ? 1 : 0.5)
            .accessibilityLabel(Text(verbatim: pack.title))
            .accessibilityValue(Text(verbatim: store.priceText(for: pack.sku, periodSuffix: false)))
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
    }

    /// Buy one gift-card tier. **The verification is not the top-up's**: the balance does not move here, so `credits.balance != before`
    /// would answer "not created" for every successful purchase. The honest witness is a voucher id the vault did not have a moment ago,
    /// read back through `loadGiftCards()` — the ids, not their count, because the card that just appeared is also the card to open.
    /// Same book-first rule as `buy(_:)` above, and the same reason: `purchase(_:)` already marked this id as settled for the session,
    /// so the background `Transaction.updates` leg will not come, and if nothing happens here the payment has no second party to make it up.
    private func buyGift(_ pack: PopopxCreditPack) async {
        guard busySkuId == nil else { return }
        busySkuId = pack.sku.productId
        defer { busySkuId = nil }
        let before = Set(giftCards.map(\.voucherId))
        let result = await store.purchase(pack.sku)
        switch result {
        case let .success(.purchased(receipt)):
            await credits.apply(storeReceipt: receipt)
            await loadGiftCards()
            let fresh = giftCards.filter { !before.contains($0.voucherId) }
            if !fresh.isEmpty {
                PopopxHaptics.notice(.success)
                spendNote = withSettlementNote(PopopxCommerceCopy.creditsGiftCreated(pack.amount), receipt: receipt)
                await attachNoteAndOpen(fresh)
            } else {
                // Paid, and no card in the vault. The transaction was not finished, so `Transaction.unfinished` will mint it next launch.
                PopopxHaptics.notice(.error)
                spendNote = PopopxCommerceCopy.creditsGiftNotCreated
            }
        case .success(.pending):
            spendNote = PopopxCommerceCopy.creditsGiftPending
        case .success(.cancelled):
            break
        case let .failure(error):
            PopopxHaptics.notice(.error)
            spendNote = error.errorDescription ?? PopopxCommerceCopy.errorStoreUnavailable
        }
    }

    // // MARK: Gift segment · minting a card from the balance

    /// The credit twin of the badge gift sheet's "two sources, one wallet": a card can be bought with Apple **or** cut from credits
    /// already paid for. Without this section `exchangeCreditsForCreditVoucher` has no caller at all, and with it the user who already
    /// holds 2,000 credits does not have to pay Apple a second time to hand part of them to somebody else.
    /// The three denominations are drawn from `PopopxCreditPlan.giftPacks`, which is the same table the Apple rows above use, so a
    /// card's face value cannot be anything that is not also purchasable — there is no free-typed amount anywhere in this family.
    private var giftExchangeCard: some View {
        PopopxSectionCard(PopopxCommerceCopy.creditsGiftFromBalanceTitle,
                          footnote: PopopxCommerceCopy.noGiftBackStatement) {
            VStack(spacing: 0) {
                HStack(spacing: PopopxMetrics.spaceS) {
                    Text(PopopxGiftBadgeCardSheet.Copy.quantityTitle)
                        .font(PopopxType.secondary)
                        .foregroundStyle(PopopxPalette.label)
                    Spacer()
                    Stepper(value: $giftQuantity, in: 1...PopopxGiftBadgeCardSheet.quantityCap) {
                        Text(verbatim: "\(giftQuantity)")
                            .font(PopopxType.metric)
                            .foregroundStyle(PopopxPalette.label)
                            .frame(minWidth: PopopxMetrics.spaceL, alignment: .trailing)
                    }
                    .labelsHidden()
                    .accessibilityLabel(PopopxGiftBadgeCardSheet.Copy.quantityTitle)
                }
                .padding(.vertical, PopopxMetrics.spaceXS)
                Divider().overlay(PopopxPalette.separator)
                ForEach(Array(PopopxCreditPlan.giftPacks.enumerated()), id: \.element.id) { index, pack in
                    if index > 0 { divider }
                    giftExchangeRow(pack)
                }
            }
        }
    }

    private func giftExchangeRow(_ pack: PopopxCreditPack) -> some View {
        let cost = pack.amount * giftQuantity
        return HStack(spacing: PopopxMetrics.spaceS) {
            Text(verbatim: pack.title)
                .font(PopopxType.emphasis)
                .foregroundStyle(PopopxPalette.label)
            Spacer(minLength: PopopxMetrics.spaceS)
            Button {
                Task { await exchange(pack) }
            } label: {
                HStack(spacing: PopopxMetrics.space2XS) {
                    if exchanging {
                        ProgressView()
                    } else {
                        Text(verbatim: PopopxCommerceCopy.creditsGiftFromBalance(giftQuantity, pack.amount, cost))
                        Image(systemName: "chevron.right")
                    }
                }
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.brand)
                .multilineTextAlignment(.trailing)
                .frame(minHeight: PopopxMetrics.minHitTarget)
            }
            // Refusing by disabling, not by an error sentence: the shortfall is already readable in the balance line above,
            // and a button that only ever answers "not enough credits" is the same anti-pattern as the already-owned cosmetic row.
            .disabled(credits.balance < cost || exchanging)
            .opacity(credits.balance < cost ? 0.5 : 1)
            .accessibilityLabel(Text(verbatim: pack.title))
            .accessibilityValue(Text(verbatim: PopopxCommerceCopy.creditsGiftFromBalance(giftQuantity, pack.amount, cost)))
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
    }

    /// Cut gift cards out of the balance. The debit, the refund-on-failed-mint and the ledger row all live in
    /// `PopopxCreditsManager.exchangeCreditsForCreditVoucher(pack:quantity:)`; this page only reloads the vault list afterwards
    /// and then hands the minted rows to `attachNoteAndOpen`, so a batch bought here with credits behaves like the Apple one:
    /// message stored for every card in it, and the first card face-up on the screen.
    /// A thrown error is passed on as its own sentence — `insufficientCredits` already carries both numbers, so nothing is appended here.
    private func exchange(_ pack: PopopxCreditPack) async {
        guard exchanging == false else { return }
        exchanging = true
        defer { exchanging = false }
        let before = giftCards.count
        do {
            let minted = try await credits.exchangeCreditsForCreditVoucher(pack: pack, quantity: giftQuantity)
            await loadGiftCards()
            if giftCards.count > before {
                PopopxHaptics.notice(.success)
                spendNote = PopopxCommerceCopy.creditsGiftFromBalanceCreated(giftQuantity, pack.amount)
                await attachNoteAndOpen(minted)
            } else {
                // The balance moved and no card appeared. Same class of incident as `creditsGiftNotCreated`, and it must be said out loud.
                PopopxHaptics.notice(.error)
                spendNote = PopopxCommerceCopy.creditsGiftFromBalanceNotCreated
            }
        } catch {
            PopopxHaptics.notice(.error)
            spendNote = error.localizedDescription
        }
    }

    // // MARK: Gift segment · the cards this device holds

    /// Unused credit gift cards. This list is the vault's, not a copy: `creditVouchers(state:)` filters by the family flag, so a badge
    /// voucher can never appear here and a credit card never appears in the badge page's list.
    /// A card is spent (its code minted) only when the user opens it, and minting is idempotent — reopening the same card yields the same
    /// code, so a second look costs nothing and cannot hand out a second voucher.
    private var giftWalletCard: some View {
        PopopxSectionCard(PopopxCommerceCopy.creditsGiftWalletTitle) {
            VStack(spacing: 0) {
                if giftCards.isEmpty {
                    Text(verbatim: PopopxCommerceCopy.creditsGiftWalletEmpty)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelHint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, PopopxMetrics.spaceS)
                } else {
                    ForEach(Array(giftCards.enumerated()), id: \.element.voucherId) { index, voucher in
                        if index > 0 { divider }
                        giftWalletRow(voucher)
                    }
                }
            }
        }
    }

    private func giftWalletRow(_ voucher: PopopxNodeVoucher) -> some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: PopopxCommerceCopy.creditsGiftCardTitle(voucher.creditFaceValue))
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.label)
                Text(verbatim: PopopxCommerceFormat.date(voucher.mintedAtMs))
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelHint)
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            Button {
                // The message is deliberately not read here: this list holds the vault's rows, and the card face asks the vault for the
                // text stored against this id (`PopopxGiftCardPresenter.resolveNote`). Handing over a value cached by this page would
                // put a second source of truth on one sentence.
                openCard = PopopxMintedGiftCard(voucher: voucher, note: "")
            } label: {
                HStack(spacing: PopopxMetrics.space2XS) {
                    Text(verbatim: PopopxGiftBadgeCardSheet.Copy.generate)
                    Image(systemName: "chevron.right")
                }
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.brand)
                .frame(minHeight: PopopxMetrics.minHitTarget)
            }
            .accessibilityLabel(Text(verbatim: PopopxGiftBadgeCardSheet.Copy.generate))
            .accessibilityValue(Text(verbatim: PopopxCommerceCopy.creditsGiftCardTitle(voucher.creditsAmount ?? 0)))
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
    }

    private func loadGiftCards() async {
        giftCards = await PopopxP2PVoucherVault.shared.creditVouchers(state: .unused)
    }

    // // MARK: Debug settlement note (only Debug builds compile this whole section)

    #if DEBUG
    /// Why this page shows the paywall's Debug note too: the `.storekit` configuration is injected only by Xcode's scheme, so a Debug build
    /// installed with `devicectl` receives the products App Store Connect carries and nothing else. On the top-up half that used to mean
    /// "cannot buy here"; on the gift half it meant the whole family was unwalkable — a card that cannot be purchased never reaches the vault,
    /// never grows a code face, and therefore can never be sent into a chat or redeemed.
    ///
    /// The walk now runs on the tiers' own buttons (`purchase(_:)` settles a missing SKU locally in Debug), so this strip carries no button at all:
    /// it says why a tap may settle on the device, and prints the load verdict verbatim.
    /// Kept as one strip rather than a line inside each row so the reviewed rows stay byte-for-byte what Release draws.
    private var showsSandboxStrip: Bool {
        (PopopxCreditPlan.packs + PopopxCreditPlan.giftPacks).contains { store.isMissingFromStore($0.sku) }
    }

    private func sandboxStrip() -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "hammer.fill")
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.meshInk)
                Text(PopopxCommerceCopy.sandboxPaywallNote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Verbatim troubleshooting line, no catalogue, selectable: pasting "3/12 loaded · missing: …" into a ticket beats restating "temporarily unavailable".
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

    private var storeDiagnostics: String {
        if let error = store.lastLoadError { return "load error: \(error)" }
        var line = "\(store.products.count)/\(PopopxNodeBadgeSku.productIds.count) loaded"
        let missing = store.missingProductIDs
        if !missing.isEmpty { line += " · missing: \(missing.joined(separator: ", "))" }
        return line
    }
    #endif

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

    /// The ledger stays on the recharge segment only. A gift-card purchase does not move this device's balance, and the rows it does
    /// write (`.creditGiftSent`) describe a deduction from a wallet the gift segment is not about — reading them next to the gift tiers
    /// invites exactly the "did I just pay twice?" question the two-segment split exists to remove.
    private var ledgerCard: some View {
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
            HStack(spacing: PopopxMetrics.spaceS) {
                // The code door, and it is outside the segments: whoever is holding a `PPXC1-` string should not have to know
                // which half of this page sells the thing it redeems into. Same word as the paywall's footer button.
                PopopxButton(PopopxCommerceCopy.paywallRedeemEntry, systemImage: "qrcode.viewfinder",
                             role: .secondary, fullWidth: true) {
                    showsRedeem = true
                }
                PopopxButton(Copy.exchange, systemImage: "sparkles", role: .secondary, fullWidth: true) {
                    showsExchange = true
                }
            }
            PopopxButton(Copy.close, role: .ghost) { dismiss() }
        }
    }
}

// // MARK: - Segments

/// The two halves of the compute-credits page. `PopopxPaywallTab`'s twin, and the split is by **who receives the value**, which is the
/// only distinction a user can act on here: the tiers, the prices and the face values are identical on both sides.
///
/// The labels are deliberately short — `PopopxSegmentedControl` puts the pills on one line, and a long product name in a pill gets
/// truncated or squeezes its neighbour (the round-10 top-bar lesson). The full product name stays in the page title and the card headers.
enum PopopxCreditsStoreTab: String, CaseIterable, Hashable {
    case recharge
    case gift

    var label: String {
        switch self {
        case .recharge: PopopxCommerceCopy.creditsRechargeTab
        case .gift: PopopxCommerceCopy.creditsGiftTab
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
