//  PopopxSendRedPacketSheet.swift
//
//  【第五阶段 · 7】发一个算力点红包：本机扣点 → 签一张卡片 → 把它送进当前会话。
//
//  ### 面额只有四档，份数只有约数
//  苹果 3.1.1 对虚拟货币赠予的读法很硬：**随机金额带赌博属性**。所以这一页从头到尾
//  不存在"输入金额"的入口，只有 `PopopxCommerceLimits.redPacketAmounts` 那四个档。
//  份数同理不放开自由输入：它只列**面额的约数**，于是每份天然是整数点，
//  而 `PopopxCreditsManager.sendRedPacket` 里那条 `amount % recipientCount == 0` 判据
//  在本面板这一侧就不可达——不会出现一个只能报错的按钮。
//
//  ### 群聊均分为什么必须往载荷里加一个字段
//  规范写的 URI 是 `popopx://redpacket?id=&amount=&note=&sig=`。这四个字段能表达单聊红包
//  （`amount` 就是那一份），表达不了群聊均分：领取端只有这张卡片可看，它必须知道自己那一份
//  是多少。要么让收件人自己除以"他以为的人数"（谁都能改），要么把人数塞进 `note`
//  （那是用户文本，不是账目）。所以载荷多一个 `n`，并且**进签名原文**：
//  改份数与改金额同样是"验签失败"。这一处偏离规范已写进 `Docs/app-store-review-notes.md`。
//
//  ### 发不出去不退款，只重发
//  点数在 `sendRedPacket` 那一步就扣了。SMP 发送失败时钱已经在这一单里，
//  此刻退钱再让用户重发 = 同一条 packetId 可能被两次扣款、或者第一份被领走而第二份又发出去。
//  所以这一页把失败的单子留着：载荷不变、packetId 不变，"再发一次"只是重投同一条消息。
//  真正的兜底在 `refundSettledPackets`：领满即退，或宽限期（`packetClaimGraceSeconds`）到点退余款。
//
//  ### 这一层不能保证的事，界面上也不假称
//  没有服务端账本，**领取端的防重放只存在于领取者自己的账本里**（同一个 packetId 只入账一次）。
//  发送方收到的回执只用来算退款，不是确权。因此：
//  - 群红包的回执按成员去重（`recordClaim(packetId:memberKey:)`），一个人重投不会挤掉别人的份数；
//  - 这一页承诺的只有"发出"与"没人领会退回"，不承诺"对方一定收到"。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI

// MARK: - 落点

/// 红包发到哪儿，以及那儿最多能分给几个人。
///
/// 三个字段全是标量：宿主从 `ChatInfo` 算好交进来，本面板因此不认识 SMP 的会话类型
/// （`ChatInfo` 是带关联值的 enum，在这里 pattern-match 会把这个文件钉死在 POPOPXChat 上，
/// 也让预览必须造一个真会话）。
struct PopopxPacketDestination: Hashable {
    let displayName: String
    let target: PopopxCommerceTarget
    /// 这个会话最多能收几份。单聊恒为 1；群聊是成员数减自己。
    let recipientCap: Int

    static func contact(id: Int64, name: String) -> PopopxPacketDestination {
        PopopxPacketDestination(displayName: name, target: .contact(id), recipientCap: 1)
    }

    /// `memberCount` 含自己。**减一是因为自己是发的人**；拿不到成员数时按 1 处理，
    /// 宁可发成一个单份红包，也不要发出一份没人领得完、要悬三十天的单子。
    ///
    /// 2026-11-19 裁定后，**发送入口不再给群聊造落点**（`ComposeView` 的 `popopxPacketDestination`
    /// 只认单聊，理由写在那一格的注释里：没有服务端账本，群里并发拆开最坏会多到账）。
    /// 这一支保留有两个原因，都不是"以后可能用得上"：
    /// ① 份数这一族账目仍然要被读懂 —— 别人那台设备铸出的 `n>1` 卡片会进来，
    ///    `PopopxPendingRedPacket.recipientCount` 与退款判据按它算，删掉这一段就等于把收到的红包算错；
    /// ② 预览用它展示"均分 N 份"那一格，否则那一格在 CI 的版面证据里永远不会出现。
    static func group(id: Int64, name: String, memberCount: Int) -> PopopxPacketDestination {
        PopopxPacketDestination(
            displayName: name,
            target: .group(id),
            recipientCap: max(1, min(memberCount - 1, PopopxCommerceLimits.maximumPacketRecipients))
        )
    }

    /// 可选份数：面额的约数、且不超过这个会话的人数上限。升序，第一个总是 1。
    func recipientOptions(for amount: Int) -> [Int] {
        guard amount > 0 else { return [1] }
        let ceiling = max(1, min(recipientCap, PopopxCommerceLimits.maximumPacketRecipients))
        var options: [Int] = []
        for count in 1...ceiling where amount % count == 0 {
            options.append(count)
        }
        return options
    }
}

// MARK: - 面板

struct PopopxSendRedPacketSheet: View {
    let destination: PopopxPacketDestination

    @Environment(\.dismiss) private var dismiss

    @State private var credits = PopopxCreditsManager.shared
    @State private var router = PopopxSilentSignalingRouter.shared
    @State private var amount = PopopxCommerceLimits.redPacketAmounts[0]
    @State private var recipients = 1
    @State private var note = ""
    @State private var stage: PopopxPacketStage = .idle

    var body: some View {
        PopopxSheetContainer(PopopxCommerceCopy.redPacketTitle, subtitle: Copy.subtitle(destination.displayName)) {
            content
        } footer: {
            footer
        }
        .task { credits.loadIfNeeded() }
    }

    // MARK: 版面

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                balanceCard
                amountCard
                if recipientOptions.count > 1 {
                    recipientsCard
                }
                noteCard
                statusCard
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
        .onChange(of: amount) { _, newValue in
            // 换档要把份数收回合法域：原来选的 5 份在 50 点这一档还成立，在 10 点那档就不成立了。
            let options = destination.recipientOptions(for: newValue)
            recipients = options.contains(recipients) ? recipients : 1
        }
    }

    private var balanceCard: some View {
        PopopxSectionCard(Copy.balanceTitle, footnote: Copy.balanceFootnote) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: PopopxCommerceCopy.creditsBalance)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Spacer(minLength: PopopxMetrics.spaceS)
                Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
            }
            if credits.balance < amount {
                Divider().overlay(PopopxPalette.separator)
                Text(verbatim: String(format: PopopxCommerceCopy.errorInsufficientCreditsFormat, amount, credits.balance))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var amountCard: some View {
        PopopxSectionCard(Copy.amountTitle, footnote: PopopxCommerceCopy.redPacketFixedAmountsStatement) {
            PopopxSegmentedControl(
                PopopxCommerceLimits.redPacketAmounts.map { .init(selection: $0, title: "\($0)") },
                title: { Copy.tierTitle($0) },
                selection: $amount
            )
        }
    }

    private var recipientsCard: some View {
        PopopxSectionCard(Copy.recipientsTitle, footnote: Copy.recipientsFootnote) {
            VStack(spacing: PopopxMetrics.space2XS) {
                ForEach(recipientOptions, id: \.self) { count in
                    PopopxRadioRow(
                        Copy.splitTitle(count),
                        note: Copy.splitNote(amount / count),
                        selected: recipients == count
                    ) {
                        recipients = count
                        PopopxHaptics.selection()
                    }
                }
            }
        }
    }

    private var noteCard: some View {
        PopopxSectionCard(Copy.noteTitle, footnote: Copy.noteFootnote) {
            PopopxTextField(Copy.noteLabel, prompt: Copy.notePrompt, text: $note, systemImage: "text.badge.plus")
                .onChange(of: note) { _, value in
                    let limit = PopopxCommerceLimits.maximumNoteCharacters
                    if value.count > limit { note = String(value.prefix(limit)) }
                }
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch stage {
        case .idle, .busy:
            boundariesCard
        case let .sent(packet):
            resultCard(
                symbol: "giftcard.fill",
                color: PopopxPalette.successInk,
                headline: Copy.sentHeadline(packet.amount, packet.recipientCount),
                detail: Copy.sentDetail(packet.recipientCount, packet.claimedCount)
            )
        case .undelivered:
            resultCard(
                symbol: "exclamationmark.arrow.triangle.2.circlepath",
                color: PopopxPalette.dangerInk,
                headline: Copy.undeliveredHeadline,
                detail: Copy.undeliveredDetail
            )
        case let .refused(error):
            resultCard(
                symbol: "xmark.circle",
                color: PopopxPalette.dangerInk,
                headline: Copy.refusedHeadline,
                detail: gloss(error)
            )
        }
    }

    private func resultCard(symbol: String, color: Color, headline: String, detail: String) -> some View {
        PopopxSectionCard {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                    Image(systemName: symbol)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(color)
                    Text(verbatim: headline)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(color)
                }
                Text(verbatim: detail)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var boundariesCard: some View {
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

    // MARK: 底栏

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            if case let .undelivered(_, payload) = stage {
                PopopxButton(Copy.retry, systemImage: "arrow.clockwise", isLoading: false) {
                    await resend(payload)
                }
            } else if case .sent = stage {
                PopopxButton(Copy.again, systemImage: "plus", role: .secondary) { reset() }
            } else {
                PopopxButton(Copy.send(total), systemImage: "giftcard.fill",
                             isLoading: stage == .busy) {
                    await send()
                }
                .disabled(!canSend)
            }
            PopopxButton(Copy.close, role: .ghost) { dismiss() }
        }
    }

    // MARK: 动作

    private var recipientOptions: [Int] { destination.recipientOptions(for: amount) }
    private var total: Int { amount }
    private var canSend: Bool {
        stage != .busy && credits.balance >= amount && recipientOptions.contains(recipients)
    }

    private func send() async {
        guard canSend else { return }
        stage = .busy
        let packet: PopopxPendingRedPacket
        do {
            packet = try credits.sendRedPacket(amount: amount, recipientCount: recipients, note: note)
        } catch let error as PopopxBadgeCreditsError {
            stage = .refused(error)
            PopopxHaptics.notice(.error)
            return
        } catch {
            stage = .refused(.keychainUnavailable)
            PopopxHaptics.notice(.error)
            return
        }
        // 载荷造不出来＝本机签名密钥这会儿取不到。点数已经扣了，绝不能把这一单忘掉：
        // 它留在 `pendingPackets` 里，宽限期到点由 `refundSettledPackets` 退回。
        guard let payload = PopopxRedPacketPayload.make(
            packetId: packet.packetId, amount: packet.amount,
            recipients: packet.recipientCount, note: packet.note
        ) else {
            stage = .refused(.verificationFailed)
            PopopxHaptics.notice(.error)
            return
        }
        await deliver(packet, payload)
    }

    /// 重投同一条载荷：不重新扣点，也不换 packetId。
    private func resend(_ payload: PopopxRedPacketPayload) async {
        guard case let .undelivered(packet, _) = stage else { return }
        stage = .busy
        await deliver(packet, payload)
    }

    private func deliver(_ packet: PopopxPendingRedPacket, _ payload: PopopxRedPacketPayload) async {
        if await router.sendRedPacket(payload, to: destination.target) {
            stage = .sent(packet)
            PopopxHaptics.notice(.success)
        } else {
            stage = .undelivered(packet, payload)
            PopopxHaptics.notice(.warning)
        }
    }

    private func reset() {
        stage = .idle
        note = ""
        recipients = 1
    }

    private func gloss(_ error: PopopxBadgeCreditsError) -> String {
        switch error {
        case let .insufficientCredits(balance, required): Copy.glossShortfall(required, balance)
        case .keychainUnavailable: Copy.glossKeychain
        case .verificationFailed: Copy.glossSigning
        default: error.errorDescription ?? Copy.glossGeneric
        }
    }
}

// MARK: - 阶段

/// 「已发出」与「已被领」是两件事，所以 `.sent` 带的是本地那一单，而不是一个勾。
enum PopopxPacketStage: Hashable {
    case idle
    case busy
    case sent(PopopxPendingRedPacket)
    /// 扣了点、消息没出去：留着载荷等用户重投。
    case undelivered(PopopxPendingRedPacket, PopopxRedPacketPayload)
    case refused(PopopxBadgeCreditsError)
}

// MARK: - 文案

private extension PopopxSendRedPacketSheet {
    enum Copy {
        static func subtitle(_ name: String) -> String { "把算力点作为红包发给「\(name)」。面额固定，等额均分。" }
        static let balanceTitle = "本机余额"
        static let balanceFootnote = "点数只存在这台设备上，扣与退都记在本机流水里。"
        static let amountTitle = "面额（总额）"
        static func tierTitle(_ value: Int) -> String { "\(value) 点" }
        static let recipientsTitle = "分给几个人"
        static let recipientsFootnote = "只列出能整除面额的份数，每份都是整数点。"
        static func splitTitle(_ count: Int) -> String { count == 1 ? "不拆分，一份" : "均分 \(count) 份" }
        static func splitNote(_ each: Int) -> String { "每人 \(each) 点" }
        static let noteTitle = "留言"
        static let noteLabel = "祝福语"
        static let notePrompt = "恭喜发财"
        static var noteFootnote: String { "最多 \(PopopxCommerceLimits.maximumNoteCharacters) 个字，会跟着红包一起发出去。" }
        static let boundariesTitle = "这几点先说清"
        static var boundariesFootnote: String {
            String(format: PopopxCommerceCopy.redPacketRefundStatementFormat,
                   PopopxCommerceLimits.packetClaimGraceSeconds / 86_400)
        }
        static let boundaryOne = "只有固定面额，没有随机金额；这一页不提供自填金额的入口。"
        static let boundaryTwo = "红包要发到对方那台设备：没送达时点数仍挂在你的流水里，可原样重发。"
        static var boundaryThree: String {
            "没有人领的余款在 \(PopopxCommerceLimits.packetClaimGraceSeconds / 86_400) 天后自动退回你的余额。"
        }
        static let close = "关闭"
        static let again = "再发一个"
        static let retry = "再发一次"
        static func send(_ value: Int) -> String { "发出 \(value) 点红包" }
        static func sentHeadline(_ value: Int, _ count: Int) -> String { "已发出 \(value) 点 · \(count) 份" }
        static func sentDetail(_ count: Int, _ claimed: Int) -> String {
            "已领 \(claimed)/\(count) 份。份数随回执更新，关掉这一页也会继续记。"
        }
        static let undeliveredHeadline = "这一单没有送达"
        static let undeliveredDetail = "点数已扣在这一单上，没有另开第二单。可以原样重发，也可以稍后再试。"
        static let refusedHeadline = "这一单没有成立"
        static func glossShortfall(_ required: Int, _ balance: Int) -> String {
            "还差 \(required - balance) 点。先去充值，充完再回这一页。"
        }
        static let glossKeychain = "本机安全存储取不到，点数没有动过。"
        static let glossSigning = "签名没能取到：点数留在这一单里，宽限期到点会自动退回。"
        static let glossGeneric = "这次没有完成，点数没有被扣走。"
    }
}

// MARK: - Previews

struct PopopxSendRedPacketSheetDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxSendRedPacketSheet(destination: .contact(id: 1, name: "阿巡"))
            .preferredColorScheme(.dark)
    }
}

struct PopopxSendRedPacketSheetLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxSendRedPacketSheet(destination: .group(id: 2, name: "周末骑行", memberCount: 9))
            .preferredColorScheme(.light)
    }
}
