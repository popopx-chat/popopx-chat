//  PopopxGiftBadgeCardSheet.swift
//
//  [Phase 5 · 5] Gift badges: turn a badge into a voucher you can hand over, then turn the voucher into a `PPX1-…` code.
//
//  ### Two sources, one voucher wallet
//  - **Apple gift tiers** (`com.popopx.gift.*`): Apple collects the money, the voucher is minted in the delivery callback
//    (`PopopxCreditsManager.apply(storeReceipt:)`), so this panel only issues codes for vouchers that already exist;
//  - **Compute-credit exchange**: `exchangeCreditsForVoucher(period:quantity:)` deducts credits and mints the voucher synchronously.
//  Both legs keep only one local copy of a `PopopxNodeVoucher`; there is no "voucher server", so neither the UI nor the copy promises
//  reporting a loss, remote revocation or a delivery receipt — the criterion for a voucher that can be redeemed once is the `state` cell
//  on the giver's device (`PopopxP2PVoucherVault.authorizeRedemption`). That sentence goes under "How the other side redeems it", not hidden in a footnote.
//
//  ### Minting a code = one-time SMP invite link + voucher number + giver's signature
//  Every `router.mintCode(for:)` call creates a new incognito connection (a link can only be accepted once),
//  so "regenerate" yields a new code and voids the old one. The button in the list is called "Generate redemption code", and the footnote states the price plainly.
//
//  ### Why we draw the QR bitmap ourselves, and why it is black on white
//  The repository's `POPOPXLinkQRCode` (Shared/Views/NewChat/QRCode.swift:37) draws the QR code as one whole view with a logo,
//  rounded inner padding and a share button, and it manages its own size and colours. The QR on a gift card is **part of the card face**,
//  it has to carry the same corner radius as the voucher face and the whole card must be screenshot/share-able, so here a pure bitmap is drawn with `CIFilter.qrCodeGenerator()`.
//  The palette is deliberately kept black code on white: `CIQRCodeGenerator` can only emit black codes, tinting them would need another mask-compositing layer,
//  and under re-photographing / low light the read rate of "light code on dark ground" is clearly lower than paper-style black-on-white — the voucher is handed over for the other side to scan,
//  so readability is not sacrificed for colour here. Integer-multiple upscaling (10x) before `createCGImage` keeps the edges from going soft.
//  Error-correction level M: the code carries base64url JSON; level S does not tolerate enough damage when re-photographed.
//
//  ### Sharing goes through the system sheet, nothing is sent to any server
//  `showShareSheet(items:)` (Shared/Views/Helpers/ShareSheet.swift:27) shares a local image and local text;
//  copying uses `UIPasteboard.general.string`, the same approach as `PopopxQRCardSheet.swift:201`.
//  This file contains no upload, no short link, no QR hosting.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.

import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit
import POPOPXChat

struct PopopxGiftBadgeCardSheet: View {
    /// The tier prefilled when coming in after buying a gift tier from the paywall; coming straight from the voucher wallet it is only a default value.
    var period: PopopxNodeBadgePeriod = .monthly
    /// When coming in from a conversation the contact comes along: then there is one extra "send in the conversation" exit, everything else still goes through the system share sheet.
    var contactId: Int64? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var credits = PopopxCreditsManager.shared
    @State private var store = PopopxStoreKitManager.shared
    @State private var router = PopopxSilentSignalingRouter.shared

    @State private var pendingVouchers: [PopopxNodeVoucher] = []
    @State private var quantity = 1
    @State private var note = ""
    @State private var busy: PopopxBadgeCardSheetWork?
    @State private var notice: String?
    @State private var failure: String?
    @State private var card: PopopxMintedGiftCard?

    var body: some View {
        PopopxSheetContainer(PopopxGiftBadgeCardSheet.Copy.title,
                             subtitle: PopopxGiftBadgeCardSheet.Copy.subtitle(period.days)) {
            content
        } footer: {
            footer
        }
        .sheet(item: $card) { minted in
            PopopxGiftCardPresenter(card: minted, contactId: contactId)
        }
        .task { await load() }
    }

    // MARK: Layout

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                PopopxSectionCard(PopopxGiftBadgeCardSheet.Copy.sourceTitle,
                                  footnote: PopopxGiftBadgeCardSheet.Copy.sourceFootnote) {
                    VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                        stepperRow
                        noteField
                        balanceRow
                    }
                }

                if let failure {
                    inlineNote(failure, danger: true)
                }
                if let notice {
                    inlineNote(notice, danger: false)
                }

                mintButtons

                voucherList
                howItWorks
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    private func inlineNote(_ text: String, danger: Bool) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: danger ? "exclamationmark.triangle" : "info.circle")
                .font(PopopxType.caption)
                .foregroundStyle(danger ? PopopxPalette.dangerInk : PopopxPalette.labelHint)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(danger ? PopopxPalette.dangerInk : PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((danger ? PopopxPalette.danger : PopopxPalette.separator).opacity(0.14),
                    in: .rect(cornerRadius: PopopxMetrics.radiusControl))
    }

    private var giftSku: PopopxNodeBadgeSku { period == .annual ? .giftAnnual : .giftMonthly }

    private var totalCost: Int { period.creditsCost * quantity }

    private var stepperRow: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Text(verbatim: PopopxGiftBadgeCardSheet.Copy.quantityTitle)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.label)
            Spacer()
            Stepper(value: $quantity, in: 1...PopopxGiftBadgeCardSheet.quantityCap) {
                Text(verbatim: "\(quantity)")
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
                    .frame(minWidth: PopopxMetrics.spaceL, alignment: .trailing)
            }
            .labelsHidden()
            .accessibilityLabel(PopopxGiftBadgeCardSheet.Copy.quantityTitle)
        }
    }

    private var noteField: some View {
        PopopxTextField(PopopxGiftBadgeCardSheet.Copy.noteTitle,
                        prompt: PopopxGiftBadgeCardSheet.Copy.notePrompt,
                        text: $note)
            .accessibilityHint(PopopxGiftBadgeCardSheet.Copy.noteHint)
    }

    private var balanceRow: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Text(PopopxCommerceCopy.creditsBalance)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelHint)
            Spacer()
            Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance))
                .font(PopopxType.metric)
                .foregroundStyle(affordable ? PopopxPalette.successInk : PopopxPalette.dangerInk)
        }
    }

    private var affordable: Bool { credits.balance >= totalCost }

    private var mintButtons: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            PopopxButton(PopopxGiftBadgeCardSheet.Copy.mintWithCredits(period: period,
                                                                       quantity: quantity,
                                                                       cost: totalCost),
                         systemImage: "sparkles",
                         isLoading: busy == .credits) {
                await mintWithCredits()
            }
            .disabled(!affordable || busy != nil)

            PopopxButton(PopopxGiftBadgeCardSheet.Copy.buyWithApple(
                             price: store.priceText(for: giftSku, periodSuffix: false)),
                         systemImage: "gift",
                         role: .secondary,
                         isLoading: busy == .apple) {
                await buyWithApple()
            }
            .disabled(busy != nil || !store.isStoreReady)
            .opacity(store.isStoreReady ? 1 : 0.5)
        }
    }

    @ViewBuilder private var voucherList: some View {
        if pendingVouchers.isEmpty {
            PopopxSectionCard(PopopxGiftBadgeCardSheet.Copy.emptyTitle,
                              footnote: PopopxGiftBadgeCardSheet.Copy.emptyFootnote) {
                Text(verbatim: " ")
                    .font(PopopxType.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
        } else {
            PopopxSectionCard(PopopxGiftBadgeCardSheet.Copy.pendingTitle(quantity: pendingVouchers.count),
                              footnote: PopopxGiftBadgeCardSheet.Copy.pendingFootnote) {
                VStack(spacing: PopopxMetrics.spaceXS) {
                    ForEach(pendingVouchers) { voucher in
                        voucherRow(voucher)
                        if voucher.id != pendingVouchers.last?.id {
                            Divider().overlay(PopopxPalette.separator)
                        }
                    }
                }
            }
        }
    }

    private func voucherRow(_ voucher: PopopxNodeVoucher) -> some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: PopopxGiftBadgeCardSheet.Copy.voucherTitle(voucher.badgeDays))
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.label)
                Text(verbatim: PopopxCommerceFormat.date(voucher.mintedAtMs))
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelHint)
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            Button {
                Task { await generateCode(for: voucher) }
            } label: {
                HStack(spacing: PopopxMetrics.space2XS) {
                    if busy == .code(voucher.voucherId) {
                        ProgressView()
                    } else {
                        Text(verbatim: PopopxGiftBadgeCardSheet.Copy.generate)
                    }
                    Image(systemName: "chevron.right")
                }
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.brand)
                .frame(minHeight: PopopxMetrics.minHitTarget)
            }
            .disabled(busy != nil)
            .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("%1$@ — %2$lld-day voucher", comment: "POPOPX gift badge sheet: generate button"), PopopxGiftBadgeCardSheet.Copy.generate, voucher.badgeDays)))
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
    }

    private var howItWorks: some View {
        PopopxSectionCard(PopopxGiftBadgeCardSheet.Copy.howTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                step("1", PopopxGiftBadgeCardSheet.Copy.howOne)
                step("2", PopopxGiftBadgeCardSheet.Copy.howTwo)
                step("3", PopopxGiftBadgeCardSheet.Copy.howThree)
                step("4", PopopxGiftBadgeCardSheet.Copy.howFour)
            }
        }
    }

    private func step(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Text(verbatim: index)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.onBrand)
                .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                .background(PopopxPalette.brand, in: .circle)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        PopopxButton(PopopxGiftBadgeCardSheet.Copy.close, role: .secondary) {
            dismiss()
        }
    }

    // MARK: Actions

    private func load() async {
        credits.loadIfNeeded()
        await store.loadProducts()
        await reloadVouchers()
    }

    private func reloadVouchers() async {
        let vault = PopopxP2PVoucherVault.shared
        pendingVouchers = await vault.badgeVouchers(state: .unused).filter { $0.period == period }
    }

    private func mintWithCredits() async {
        busy = .credits
        defer { busy = nil }
        notice = nil
        failure = nil
        do {
            let minted = try await credits.exchangeCreditsForVoucher(period: period, quantity: quantity)
            PopopxHaptics.notice(.success)
            await reloadVouchers()
            // The whole batch carries the one message typed above, and it is stored for every id now: only the first card opens this
            // sheet, so waiting for `resolveNote()` would leave the other rows with a message nobody ever wrote down.
            if !note.isEmpty {
                await PopopxP2PVoucherVault.shared.recordNote(note, forVoucherIds: minted.map(\.voucherId))
            }
            if let first = minted.first {
                card = PopopxMintedGiftCard(voucher: first, note: note)
            }
        } catch let error as PopopxBadgeCreditsError {
            failure = error.errorDescription ?? PopopxGiftBadgeCardSheet.Copy.genericFailure
        } catch {
            failure = PopopxBadgeCreditsError.keychainUnavailable.errorDescription
        }
    }

    private func buyWithApple() async {
        busy = .apple
        defer { busy = nil }
        notice = nil
        failure = nil
        let before = Set(pendingVouchers.map(\.voucherId))
        switch await store.purchase(giftSku) {
        case .success(.purchased):
            // The voucher is minted in the StoreKit delivery callback, which may land slightly after this call returns. Polling a few times only serves to "lay out the card that just appeared";
            // if it cannot be read we do not pretend success — the list refresh below leaves the user to tap it themselves.
            for _ in 0..<4 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await reloadVouchers()
                if let fresh = pendingVouchers.first(where: { !before.contains($0.voucherId) }) {
                    card = PopopxMintedGiftCard(voucher: fresh, note: note)
                    return
                }
            }
            notice = PopopxGiftBadgeCardSheet.Copy.appleDelivering
        case .success(.pending):
            notice = PopopxGiftBadgeCardSheet.Copy.applePending
        case .success(.cancelled):
            break
        case let .failure(error):
            failure = error.errorDescription ?? PopopxGiftBadgeCardSheet.Copy.genericFailure
        }
    }

    private func generateCode(for voucher: PopopxNodeVoucher) async {
        busy = .code(voucher.voucherId)
        defer { busy = nil }
        failure = nil
        if await router.mintCode(for: voucher) != nil {
            PopopxHaptics.notice(.success)
            // A voucher that already went out with a message keeps it: this row's code is being re-issued, and the text field above
            // belongs to whatever the user is doing now, so letting it overwrite would rewrite what the other side already received.
            // With nothing stored the typed text is the card's message, and it is written before the card face opens.
            let stored = await PopopxP2PVoucherVault.shared.note(forVoucherId: voucher.voucherId)
            if stored.isEmpty {
                await PopopxP2PVoucherVault.shared.recordNote(note, forVoucherIds: [voucher.voucherId])
            }
            card = PopopxMintedGiftCard(voucher: voucher, note: stored.isEmpty ? note : stored)
            await reloadVouchers()
        } else {
            failure = PopopxBadgeCreditsError.connectionUnavailable.errorDescription
        }
    }
}

// // MARK: - Working state

/// Three things share one "busy" field: an `enum` is used rather than three booleans so that a state like "busy with two things at once" cannot exist.
enum PopopxBadgeCardSheetWork: Hashable {
    case credits
    case apple
    case code(String)
}

/// A card whose code has already been minted. `Identifiable` is there for `.sheet(item:)`.
struct PopopxMintedGiftCard: Identifiable, Hashable {
    let voucher: PopopxNodeVoucher
    let note: String
    var id: String { voucher.voucherId }
}

// // MARK: - Card face

/// The presentation of one gift card: QR + grouped code + copy / share / (optionally) send in the conversation.
///
/// **One view serves both card families.** The face is the same object for a badge voucher and for a compute-credit voucher —
/// one code, one QR, one set of exits — and the three places that genuinely differ (which mint function runs, which sentence titles the card,
/// which payload a "send in this chat" signs) branch on `PopopxNodeVoucher.isCreditVoucher`, the same flag the vault filters its two lists by.
/// Writing a second presenter would have meant two QR paths that can drift apart on rotation, error-correction level or the paste format,
/// which are exactly the details nobody re-reads after the copy review.
struct PopopxGiftCardPresenter: View {
    let card: PopopxMintedGiftCard
    let contactId: Int64?

    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var message: String?
    @State private var busySending = false
    @State private var toast = PopopxToastModel()
    /// The message this card shows and signs, settled once at the top of `.task` by `resolveNote()`: the text the caller handed over
    /// when it handed one over, otherwise the text the vault kept the last time this very card was opened.
    /// It is a second value rather than a read-through of `card.note`: a caller that typed the text in its own sheet hands it over, while a card
    /// reopened from the wallet list arrives with an empty one, and both the message line and the signed `n=` field would then drop a sentence
    /// the giver had already sent with the card.
    @State private var note = ""

    /// The two families cannot be minted by the same call: `mintCode` signs a `period` into a `PPX1-` envelope, `mintCreditCode` an amount into `PPXC1-`.
    /// Branching here rather than passing a flag down means a credit voucher can never be handed to the badge mint by forgetting an argument.
    private var isCreditCard: Bool { card.voucher.isCreditVoucher }

    var body: some View {
        PopopxSheetContainer(cardTitle, subtitle: PopopxGiftCardPresenter.Copy.subtitle(code != nil)) {
            VStack(spacing: PopopxMetrics.spaceM) {
                if let code {
                    cardFace(code: code)
                    codeBlock(code)
                } else {
                    waitingFace
                }
                if let message {
                    Text(verbatim: message)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !note.isEmpty {
                    Text(verbatim: PopopxGiftCardPresenter.Copy.noteLine(note))
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        } footer: {
            actions
        }
        .popopxToast(toast)
        .task {
            await resolveNote()
            await mint()
        }
    }

    /// The card face names the thing it holds, because the two families are named after different numbers: a badge says how long, a credit card says how much.
    /// The optional **is** the family flag (`PopopxNodeVoucher.isCreditVoucher` is exactly `creditsAmount != nil`), so unwrapping here titles the card
    /// from the same fact the vault filtered by — no `?? 0` fallback that could print a face value of zero.
    private var cardTitle: String {
        if let amount = card.voucher.creditsAmount {
            return PopopxCommerceCopy.creditsGiftCardTitle(amount)
        }
        return PopopxGiftCardPresenter.Copy.cardTitle(card.voucher.badgeDays)
    }

    private func cardFace(code: String) -> some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            if let image = PopopxCommerceQR.image(for: code) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: PopopxCommerceQR.side, height: PopopxCommerceQR.side)
                    .accessibilityLabel(PopopxGiftCardPresenter.Copy.qrLabel)
            } else {
                // When bitmap generation fails we show neither a fake image nor a blank: say plainly that it cannot be read and point the user to the textual code below.
                Text(verbatim: PopopxGiftCardPresenter.Copy.qrUnreadable)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .multilineTextAlignment(.center)
                    .frame(width: PopopxCommerceQR.side, height: PopopxCommerceQR.side)
                    .background(PopopxPalette.separator.opacity(0.5),
                                in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            }
        }
        .padding(PopopxMetrics.spaceM)
        .background(PopopxPalette.base, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
    }

    private var waitingFace: some View {
        RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
            .fill(PopopxPalette.separator.opacity(0.5))
            .frame(width: PopopxCommerceQR.side + PopopxMetrics.spaceM * 2,
                   height: PopopxCommerceQR.side + PopopxMetrics.spaceM * 2)
            .overlay { ProgressView() }
            .accessibilityLabel(PopopxGiftCardPresenter.Copy.qrWaiting)
    }

    private func codeBlock(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(verbatim: PopopxGiftCardPresenter.Copy.codeLabel)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelHint)
            Text(verbatim: PopopxRedeemCode.grouped(code))
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.label)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: isCreditCard
                    ? PopopxCommerceCopy.creditsGiftCodeFootnote
                    : PopopxGiftCardPresenter.Copy.codeFootnote)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelHint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            if let code {
                HStack(spacing: PopopxMetrics.spaceS) {
                    PopopxButton(PopopxGiftCardPresenter.Copy.copy, systemImage: "doc.on.doc",
                                 role: .secondary, fullWidth: true) {
                        UIPasteboard.general.string = PopopxRedeemCode.clipboardValue(code)
                        toast.show(PopopxGiftCardPresenter.Copy.copied, kind: .success)
                    }
                    PopopxButton(PopopxGiftCardPresenter.Copy.share, systemImage: "square.and.arrow.up",
                                 role: .secondary, fullWidth: true) {
                        share(code)
                    }
                }
                if let contactId {
                    PopopxButton(PopopxGiftCardPresenter.Copy.sendToContact, systemImage: "paperplane",
                                 isLoading: busySending) {
                        await sendToContact(contactId)
                    }
                }
            }
            PopopxButton(PopopxGiftCardPresenter.Copy.close, role: .ghost) {
                dismiss()
            }
        }
    }

    /// Settle the card's message before the code is minted, in both directions, from the one table the vault keeps.
    ///
    /// Empty handover → read back: the wallet list hands over a voucher row and nothing else, so without this the reopened card
    /// would show no message line and would sign an empty `n=` field into a link whose first send had the giver's sentence in it.
    /// Non-empty handover → store first: the badge sheet's "Generate redemption code" and "buy" paths type the text in a field that
    /// dies with the sheet, so a message that was only ever displayed would be unrecoverable at the next launch.
    /// The store is best-effort here and does not fail the card: if secure storage is unavailable the message still shows and still
    /// goes out — it just may have to be typed again, which is a smaller lie than a card face that refuses to open.
    private func resolveNote() async {
        guard note.isEmpty else { return }
        let vault = PopopxP2PVoucherVault.shared
        if card.note.isEmpty {
            note = await vault.note(forVoucherId: card.voucher.voucherId)
        } else {
            note = card.note
            await vault.recordNote(card.note, forVoucherIds: [card.voucher.voucherId])
        }
    }

    private func mint() async {
        guard code == nil else { return }
        let router = PopopxSilentSignalingRouter.shared
        // The family picks the mint, and each mint refuses a row of the other family on its own guard (`period` vs `creditsAmount`),
        // so a wrong branch here yields "no code", never a code that redeems the wrong thing.
        let minted = isCreditCard
            ? await router.mintCreditCode(for: card.voucher)
            : await router.mintCode(for: card.voucher)
        if let minted {
            code = minted
        } else {
            message = PopopxGiftCardPresenter.Copy.mintFailed
        }
    }

    private func share(_ code: String) {
        var items: [Any] = [PopopxRedeemCode.clipboardValue(code)]
        if let image = PopopxCommerceQR.image(for: code) {
            items.insert(image, at: 0)
        }
        showShareSheet(items: items)
    }

    private func sendToContact(_ contactId: Int64) async {
        busySending = true
        defer { busySending = false }
        // Each family signs its own value into its own payload: the credit one signs an amount, the badge one a period, and both makers
        // refuse a row that does not carry theirs. The unwrap is the lock, not a nicety — it is what keeps a compute-credit card from
        // ever being sent as a badge card, the same lock `mintCode`/`mintCreditCode` apply at the code side.
        let delivered: Bool
        if isCreditCard {
            guard let creditsAmount = card.voucher.creditsAmount,
                  let payload = PopopxCreditGiftPayload.make(voucherId: card.voucher.voucherId,
                                                             creditsAmount: creditsAmount,
                                                             note: note,
                                                             mintedAtMs: card.voucher.mintedAtMs) else {
                message = PopopxGiftCardPresenter.Copy.signFailed
                return
            }
            delivered = await PopopxSilentSignalingRouter.shared.sendCreditGiftCard(payload, contactId: contactId)
        } else {
            guard let period = card.voucher.period,
                  let payload = PopopxGiftCardPayload.make(voucherId: card.voucher.voucherId,
                                                           period: period,
                                                           note: note,
                                                           mintedAtMs: card.voucher.mintedAtMs) else {
                message = PopopxGiftCardPresenter.Copy.signFailed
                return
            }
            delivered = await PopopxSilentSignalingRouter.shared.sendGiftCard(payload, contactId: contactId)
        }
        if delivered {
            toast.show(PopopxGiftCardPresenter.Copy.sent, kind: .encrypted)
            dismiss()
        } else {
            message = PopopxGiftCardPresenter.Copy.sendFailed
        }
    }
}

// MARK: - QR

/// A pure bitmap QR for the card face. Integer-multiple scaling + direct `CIContext` output, so edges stay sharp when re-photographed.
/// Deliberately black code on white; the reason is in the file header.
enum PopopxCommerceQR {
    /// Display side length: a multiple of 48, which lands exactly in `PopopxMetrics`' rhythm (192 = 4 × space2XL).
    static let side: CGFloat = PopopxMetrics.space2XL * 4
    /// Each module enlarged by 10 pixels. 5x goes soft on 3x screens, 20x just gives away twice the size for nothing.
    static let moduleScale: CGFloat = 10

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let scaled = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: moduleScale, y: moduleScale)),
              let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// // MARK: - Copy

extension PopopxGiftBadgeCardSheet {
    /// At most 10 codes at a time: the voucher wallet itself caps at 200 (`maximumVouchers`), but "tapping for 200 at once"
    /// has no real use case and would push the list below off the screen.
    static let quantityCap = 10

    enum Copy {
        static let title = NSLocalizedString("Send a badge", comment: "POPOPX gift badge sheet")
        static func subtitle(_ days: Int) -> String { String(format: NSLocalizedString("A %lld-day voucher the recipient redeems with a code.", comment: "POPOPX gift badge sheet"), days) }
        static let sourceTitle = NSLocalizedString("How to get this voucher", comment: "POPOPX gift badge sheet")
        static let sourceFootnote = NSLocalizedString("The voucher lives in this device's Keychain, and the check that it can be redeemed only once is on this device too. There is no voucher server, so there is no loss report, no remote revocation and no delivery receipt.", comment: "POPOPX gift badge sheet")
        static let quantityTitle = NSLocalizedString("Quantity", comment: "POPOPX gift badge sheet")
        static let noteTitle = NSLocalizedString("Message", comment: "POPOPX gift badge sheet")
        static let notePrompt = NSLocalizedString("Add a line to go with the voucher", comment: "POPOPX gift badge sheet")
        static let noteHint = NSLocalizedString("The message is up to 60 characters; anything longer is cut off.", comment: "POPOPX gift badge sheet")
        static func mintWithCredits(period: PopopxNodeBadgePeriod, quantity: Int, cost: Int) -> String {
            String(format: NSLocalizedString("Redeem with Compute Credits · %1$lld vouchers · %2$lld days each · %3$lld credits", comment: "POPOPX gift badge sheet"), quantity, period.days, cost)
        }
        static func buyWithApple(price: String) -> String { String(format: NSLocalizedString("Buy a gift voucher with Apple · %@", comment: "POPOPX gift badge sheet"), price) }
        static func pendingTitle(quantity: Int) -> String { String(format: NSLocalizedString("Vouchers waiting for a code · %lld", comment: "POPOPX gift badge sheet"), quantity) }
        static let pendingFootnote = NSLocalizedString("Every new code creates a fresh one-time connection and invalidates the old one at the same time; a voucher can be redeemed only once.", comment: "POPOPX gift badge sheet")
        static func voucherTitle(_ days: Int) -> String { String(format: NSLocalizedString("%lld-day badge voucher", comment: "POPOPX gift badge sheet"), days) }
        static let generate = NSLocalizedString("Generate a redemption code", comment: "POPOPX gift badge sheet")
        static let emptyTitle = NSLocalizedString("No vouchers in this tier yet", comment: "POPOPX gift badge sheet")
        static let emptyFootnote = NSLocalizedString("Get a voucher first with either option above.", comment: "POPOPX gift badge sheet")
        static let appleDelivering = NSLocalizedString("Payment is complete and the voucher is on its way. Come back to this page later and it will be in the list below.", comment: "POPOPX gift badge sheet")
        static let applePending = NSLocalizedString("Waiting for Apple to confirm this purchase; once it is confirmed the voucher arrives by itself.", comment: "POPOPX gift badge sheet")
        static let howTitle = NSLocalizedString("How the recipient uses it", comment: "POPOPX gift badge sheet")
        static let howOne = NSLocalizedString("Give the code or the QR image to the other person: scan it face to face, send a screenshot, or paste the text in a chat.", comment: "POPOPX gift badge sheet")
        static let howTwo = NSLocalizedString("They type this code into the app or scan it, and this device creates a one-time SMP connection by itself.", comment: "POPOPX gift badge sheet")
        static let howThree = NSLocalizedString("Once they accept, this device checks that the voucher has not been redeemed yet and signs an authorization back.", comment: "POPOPX gift badge sheet")
        static let howFour = NSLocalizedString("The one-time connection is deleted right after; neither device keeps a contact record.", comment: "POPOPX gift badge sheet")
        static let close = NSLocalizedString("Close", comment: "POPOPX gift badge sheet")
        static let genericFailure = NSLocalizedString("This did not complete.", comment: "POPOPX gift badge sheet")
    }
}

extension PopopxGiftCardPresenter {
    enum Copy {
        static func cardTitle(_ days: Int) -> String { String(format: NSLocalizedString("%lld-day badge voucher", comment: "POPOPX gift card"), days) }
        static func subtitle(_ ready: Bool) -> String {
            ready ? NSLocalizedString("Hand this code to the other person", comment: "POPOPX gift card") : NSLocalizedString("Generating a redemption code…", comment: "POPOPX gift card")
        }
        static let codeLabel = NSLocalizedString("Redemption code", comment: "POPOPX gift card")
        static let codeFootnote = NSLocalizedString("Paste this whole string where the app asks for a badge voucher code: the grouping is only for readability and spaces make no difference, but it is case-sensitive — paste or scan it, do not retype it character by character.", comment: "POPOPX gift card")
        static let qrLabel = NSLocalizedString("Redemption code QR", comment: "POPOPX gift card")
        static let qrUnreadable = NSLocalizedString("The QR image could not be read; use the redemption code text below instead.", comment: "POPOPX gift card")
        static let qrWaiting = NSLocalizedString("Redemption code being generated", comment: "POPOPX gift card")
        static let copy = NSLocalizedString("Copy", comment: "POPOPX gift card")
        static let share = NSLocalizedString("Share", comment: "POPOPX gift card")
        static let sendToContact = NSLocalizedString("Send in this chat", comment: "POPOPX gift card")
        static let copied = NSLocalizedString("Copied", comment: "POPOPX gift card")
        static let sent = NSLocalizedString("Sent", comment: "POPOPX gift card")
        static let close = NSLocalizedString("Done", comment: "POPOPX gift card")
        static let mintFailed = NSLocalizedString("No redemption code was created: the one-time connection could not be established. Close this card and open it again to try once more.", comment: "POPOPX gift card")
        static let signFailed = NSLocalizedString("The signature for this voucher was not created: this device's signing key is unavailable.", comment: "POPOPX gift card")
        static let sendFailed = NSLocalizedString("The message was not sent: this chat connection is not available right now.", comment: "POPOPX gift card")
        static func noteLine(_ note: String) -> String { String(format: NSLocalizedString("Message: %@", comment: "POPOPX gift card"), note) }
    }
}

// MARK: - Previews
//
// The card face (`PopopxGiftCardPresenter`) deliberately has no preview: as soon as it appears it calls `router.mintCode(for:)`,
// and that path reaches `apiAddContact` against an uninitialised SMP backend. The preview only shows this page — everything it reads is Keychain and StoreKit.

struct PopopxGiftBadgeCardSheetDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxGiftBadgeCardSheet()
            .preferredColorScheme(.dark)
    }
}

struct PopopxGiftBadgeCardSheetLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxGiftBadgeCardSheet(period: .annual)
            .preferredColorScheme(.light)
    }
}
