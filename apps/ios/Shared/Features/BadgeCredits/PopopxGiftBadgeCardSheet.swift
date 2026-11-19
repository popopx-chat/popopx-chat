//  PopopxGiftBadgeCardSheet.swift
//
//  【第五阶段 · 5】礼品徽章：把一枚徽章变成一张可以递出去的券，再把券变成 `PPX1-…` 码。
//
//  ### 两条来源，一个券包
//  - **Apple 礼品档**（`com.popopx.gift.*`）：钱由 Apple 收，交付回调里铸券
//    （`PopopxCreditsManager.apply(storeReceipt:)`），本面板只负责把已经存在的券出码；
//  - **算力点兑换**：`exchangeCreditsForVoucher(period:quantity:)` 同步扣点铸券。
//  两条腿都只在本地留一份 `PopopxNodeVoucher`，没有"券服务器"，所以界面与文案都不承诺
//  挂失、远程作废、送达回执——能被兑一次的判据是赠方设备上那一格 `state`
//  （`PopopxP2PVoucherVault.authorizeRedemption`）。这句写进"对方怎么用"下面，不藏在脚注里。
//
//  ### 出码 = 一次性 SMP 邀请链接 + 券号 + 赠方签名
//  `router.mintCode(for:)` 每次调用都新建一条 incognito connection（一条链接只能被 accept 一次），
//  所以"重新生成"会得到新码、作废旧码。列表里的按钮就叫"生成兑换码"，脚注把代价说清楚。
//
//  ### QR 位图为什么自己画、为什么是白底黑码
//  仓库里的 `POPOPXLinkQRCode`（Shared/Views/NewChat/QRCode.swift:37）把二维码画成一整块带 logo、
//  圆角内衬和分享按钮的视图，尺寸配色都归它自己管。礼品卡上的 QR 是**卡面的一部分**，
//  需要与券面同一个圆角、并且整卡可被截图/分享，所以这里用 `CIFilter.qrCodeGenerator()` 画纯位图。
//  配色刻意保持黑码白底：`CIQRCodeGenerator` 只能出黑码，要染色得再走一层 mask 合成，
//  而翻拍/低光下"深底浅码"的识读率明显低于纸质白底黑码 —— 券是拿给对方扫的，
//  这里不为配色牺牲识读。整数倍放大（10 倍）后再 `createCGImage`，边缘不发虚。
//  纠错档 M：码里含 base64url 的 JSON，S 档在翻拍时容错不够。
//
//  ### 分享走系统面板，不发任何服务器
//  `showShareSheet(items:)`（Shared/Views/Helpers/ShareSheet.swift:27）分享的是本地图与本地文本；
//  复制走 `UIPasteboard.general.string`，与 `PopopxQRCardSheet.swift:201` 同一做法。
//  本文件不出现任何上传、短链、二维码托管。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit
import POPOPXChat

struct PopopxGiftBadgeCardSheet: View {
    /// 从付费墙买完礼品档进来时预填的档位；从券包直接进来时只是默认值。
    var period: PopopxNodeBadgePeriod = .monthly
    /// 从某个会话里进来时带上联系人：这时多一个"在会话里发出"的出口，其余仍走系统分享。
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

    // MARK: 版面

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
                Text(verbatim: PopopxGiftBadgeCardSheet.Copy.voucherTitle(voucher.period.days))
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
            .accessibilityLabel(Text(verbatim: "\(PopopxGiftBadgeCardSheet.Copy.generate) \(voucher.period.days) 天券"))
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

    // MARK: 动作

    private func load() async {
        credits.loadIfNeeded()
        await store.loadProducts()
        await reloadVouchers()
    }

    private func reloadVouchers() async {
        let vault = PopopxP2PVoucherVault.shared
        pendingVouchers = await vault.vouchers(state: .unused).filter { $0.period == period }
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
            // 券在 StoreKit 交付回调里铸，回调可能略晚于这次返回。轮询几次只为"把刚出现的这张直接摊开"；
            // 读不到也不假装成功，交给下面的列表刷新后由用户自己点。
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
            card = PopopxMintedGiftCard(voucher: voucher, note: note)
            await reloadVouchers()
        } else {
            failure = PopopxBadgeCreditsError.connectionUnavailable.errorDescription
        }
    }
}

// MARK: - 工作态

/// 三件事共用一个"正在忙"字段：用 `enum` 而不是三个布尔，是为了让"同时忙两件事"这种状态不存在。
enum PopopxBadgeCardSheetWork: Hashable {
    case credits
    case apple
    case code(String)
}

/// 已经出好码的一张卡。`Identifiable` 是给 `.sheet(item:)` 用的。
struct PopopxMintedGiftCard: Identifiable, Hashable {
    let voucher: PopopxNodeVoucher
    let note: String
    var id: String { voucher.voucherId }
}

// MARK: - 卡面

/// 一张礼品卡的呈现：QR + 分组码 + 复制 / 分享 /（可选）在会话里发出。
struct PopopxGiftCardPresenter: View {
    let card: PopopxMintedGiftCard
    let contactId: Int64?

    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var message: String?
    @State private var busySending = false
    @State private var toast = PopopxToastModel()

    var body: some View {
        PopopxSheetContainer(PopopxGiftCardPresenter.Copy.cardTitle(card.voucher.period.days),
                             subtitle: PopopxGiftCardPresenter.Copy.subtitle(code != nil)) {
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
                if !card.note.isEmpty {
                    Text(verbatim: PopopxGiftCardPresenter.Copy.noteLine(card.note))
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
        .task { await mint() }
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
                // 位图生成失败时不给一张假图，也不给空白：明说读不出来，让用户改用下面那串文本码。
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
            Text(verbatim: PopopxGiftCardPresenter.Copy.codeFootnote)
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

    private func mint() async {
        guard code == nil else { return }
        let minted = await PopopxSilentSignalingRouter.shared.mintCode(for: card.voucher)
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
        guard let payload = PopopxGiftCardPayload.make(voucherId: card.voucher.voucherId,
                                                      period: card.voucher.period,
                                                      note: card.note,
                                                      mintedAtMs: card.voucher.mintedAtMs) else {
            message = PopopxGiftCardPresenter.Copy.signFailed
            return
        }
        if await PopopxSilentSignalingRouter.shared.sendGiftCard(payload, note: card.note, contactId: contactId) {
            toast.show(PopopxGiftCardPresenter.Copy.sent, kind: .encrypted)
            dismiss()
        } else {
            message = PopopxGiftCardPresenter.Copy.sendFailed
        }
    }
}

// MARK: - QR

/// 卡面用的纯位图 QR。整数倍缩放 + `CIContext` 直出，保证翻拍时边缘不虚。
/// 刻意黑码白底，理由见文件头。
enum PopopxCommerceQR {
    /// 显示边长：48 的倍数，正好落进 `PopopxMetrics` 的节奏（192 = 4 × space2XL）。
    static let side: CGFloat = PopopxMetrics.space2XL * 4
    /// 每个模块放大 10 像素。5 倍在 3x 屏上会糊，20 倍只是把体积白给一倍。
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

// MARK: - 文案

extension PopopxGiftBadgeCardSheet {
    /// 一次最多出 10 张：券包本身的上限是 200（`maximumVouchers`），但"一次点 200 张"
    /// 既没有真实用法，也会把下面的列表顶到屏幕外。
    static let quantityCap = 10

    enum Copy {
        static let title = "送出一枚徽章"
        static func subtitle(_ days: Int) -> String { "一张 \(days) 天的券，对方凭码兑换。" }
        static let sourceTitle = "得到这张券"
        static let sourceFootnote = "券只存在这台设备的 Keychain 里，能被兑一次的判据也在本机。没有券服务器，所以没有挂失、远程作废或送达回执。"
        static let quantityTitle = "份数"
        static let noteTitle = "留言"
        static let notePrompt = "随券带一句话"
        static let noteHint = "留言最多 60 字，超出会被截断"
        static func mintWithCredits(period: PopopxNodeBadgePeriod, quantity: Int, cost: Int) -> String {
            "用算力点兑换 \(quantity) 张 · \(period.days) 天 · \(cost) 点"
        }
        static func buyWithApple(price: String) -> String { "用 Apple 购买礼品券 · \(price)" }
        static func pendingTitle(quantity: Int) -> String { "待出码的券 · \(quantity)" }
        static let pendingFootnote = "每次出码都会新建一条一次性连接，旧码同时失效；一张券只能兑一次。"
        static func voucherTitle(_ days: Int) -> String { "\(days) 天徽章券" }
        static let generate = "生成兑换码"
        static let emptyTitle = "这个档位还没有券"
        static let emptyFootnote = "先用上面任一方式得到一张券。"
        static let appleDelivering = "付款已完成，券正在到账。稍后回到这一页，它会出现在下面的列表里。"
        static let applePending = "等待 Apple 确认这笔购买，确认后券会自动到账。"
        static let howTitle = "对方怎么用"
        static let howOne = "把码或二维码交给对方：面对面扫码、截图、聊天里发文本都可以。"
        static let howTwo = "对方在 app 里输入这串码或扫码，本机自动建一条一次性 SMP 连接。"
        static let howThree = "对方接受后，本机确认这张券还没被兑过，签一份授权送回去。"
        static let howFour = "这条一次性连接随后删除，双方都不留下联系人记录。"
        static let close = "关闭"
        static let genericFailure = "这次没有完成。"
    }
}

extension PopopxGiftCardPresenter {
    enum Copy {
        static func cardTitle(_ days: Int) -> String { "\(days) 天徽章券" }
        static func subtitle(_ ready: Bool) -> String {
            ready ? "把这串码交给对方即可" : "正在生成兑换码…"
        }
        static let codeLabel = "兑换码"
        static let codeFootnote = "对方在「兑换徽章券」里粘贴这一串即可：分段只为了好读，空格无所谓，但大小写敏感 —— 请粘贴或扫码，不要逐字符抄。"
        static let qrLabel = "兑换码二维码"
        static let qrUnreadable = "二维码读不出来，请改用下面的兑换码文本"
        static let qrWaiting = "兑换码生成中"
        static let copy = "复制"
        static let share = "分享"
        static let sendToContact = "在会话里发出"
        static let copied = "已复制"
        static let sent = "已发出"
        static let close = "完成"
        static let mintFailed = "兑换码没能生成：这条一次性连接没建起来。关掉重开可以再试一次。"
        static let signFailed = "这张券的签名没能生成：本机签名密钥不可用。"
        static let sendFailed = "消息没发出去：这条会话连接当前不可用。"
        static func noteLine(_ note: String) -> String { "留言：\(note)" }
    }
}

// MARK: - Previews
//
// 卡面（`PopopxGiftCardPresenter`）刻意不给预览：它一进来就调 `router.mintCode(for:)`，
// 那条路会 `apiAddContact` 打到未初始化的 SMP 后端。预览只出这一页——它读的全是 Keychain 与 StoreKit。

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
