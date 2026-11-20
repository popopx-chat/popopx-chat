//  PopopxCommerceCards.swift
//
//  【第六阶段 · 1】会话流里的三张卡片：礼品卡、红包与频道门槛。它们是这套生态唯一"会被点到第二次"的入口，
//  所以判据一律读模型层，不在视图里留任何一份可自行改写的状态。
//
//  ### 卡片自带表面，不吃气泡的墨色
//  与 `ProfileCardBubbleView` / `PopopxSecureBubbleMount` 同一处理
//  （见 `Shared/Features/ChatRoom/PopopxMessageBubble.swift:426-444` 那两支的注释）：
//  一条"能点的东西"必须和周围的普通文本明显不同，所以它自己带底色与细描边，
//  而不是跟着气泡的收发两侧换字色——换了就跟气泡长在一起、看不出是个控件。
//
//  ### 状态从哪儿来
//  - 礼品卡：`PopopxCreditsManager.hasRedeemed(voucherId:)` 是本机核销过的长期事实；
//    这一程的终态从 `PopopxSilentSignalingRouter.outcomesByVoucher[voucherId]` 读，
//    **不**读全局那一份 `lastOutcome`——两张券同时挂在两个会话里时，全局那一份会串台。
//  - 红包：`hasClaimed(packetId:)` 与 `pendingPacket(packetId:)` 都在账本里。
//    前者是"我拆过了"，后者是"这一单是我发的"。
//
//  ### 自己发出去的红包不能自己拆
//  发送时点数已经扣过。如果本机的时间线上那张卡片还能点"拆开"，同一个人就能既扣一次又入一份——
//  这一条判据必须在视图这一层也存在，虽然 `claimRedPacket` 的重放保护也会挡住同一 packetId。
//
//  ### 回执是尽力而为
//  拆开后本机立刻入账（那份点数是拆的人的），随后补一条静默回执给发送方，只用来算退款。
//  回执没送到时这一格会在本进程里留着"补发回执"的按钮；重启后不再提示，
//  因为"回执是否送达"没有本地可持久化的判据——宁可少一次提示，也不假装知道。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI

// MARK: - 上下文与选路

/// 卡片需要的会话上下文，由挂载方一次给全。
struct PopopxCommerceCardContext: Hashable {
    /// 卡片所在会话的落点。nil 时礼品卡与红包只读：兑换与拆开都要往这个会话里回一条消息。
    let target: PopopxCommerceTarget?
    /// 卡片是不是对方发过来的那一边。
    let incoming: Bool
    /// 门槛卡片要给它所在会话签一张本机凭证，所以挂载方把会话的显示键与名字一起带下来。
    /// 这两个字段只有 `channel` 那一支会读（礼品卡与红包不使用），默认空串是为了不惊动既有构造点。
    let chatId: String
    let chatTitle: String
    /// 这个会话是不是频道。门槛卡片只有落在频道里才作数：判据与频道信息页那一格同一个数
    /// （`GroupInfo.isChannel`），挂载方从 `chat.chatInfo.groupInfo` 原样搬。
    /// 默认 false 是为了让"挂载方没给上下文"那一条兜底路径继续停在它原来那一格——
    /// 那条路径的 `chatId` 也是空串，先被"这里只能看"挡住，轮不到这一条说话。
    let isChannel: Bool

    init(target: PopopxCommerceTarget?, incoming: Bool, chatId: String = "", chatTitle: String = "",
         isChannel: Bool = false) {
        self.target = target
        self.incoming = incoming
        self.chatId = chatId
        self.chatTitle = chatTitle
        self.isChannel = isChannel
    }
}

/// 一条文本消息在会话流里应当渲染成哪张卡片。
enum PopopxCommerceContent: Hashable {
    case gift(PopopxGiftCardPayload)
    case packet(PopopxRedPacketPayload)
    case channel(PopopxChannelAccessPayload)

    /// 气泡选路用的一次判定：三个都不像就返回 nil，让这条消息走普通文本那一支。
    /// 顺序无涉正确性（三个 host 互不相同），频道放在最后是因为它最不像"一条要点的卡片"。
    static func detect(in text: String) -> PopopxCommerceContent? {
        if let packet = PopopxRedPacketPayload.parse(from: text) { return .packet(packet) }
        if let gift = PopopxGiftCardPayload.parse(from: text) { return .gift(gift) }
        if let channel = PopopxChannelAccessPayload.parse(from: text) { return .channel(channel) }
        return nil
    }

    /// VoiceOver 的那一句由本文件拥有：措辞和卡片上写出来的那几个数必须同源，
    /// 否则气泡与卡片会各说一套（`PopopxMessageBubble.swift:211-217` 那两支同一条理由）。
    /// 只报名额与份数，不报签名、不报券号——那些串读出来只会变成噪音。
    var spokenText: String {
        switch self {
        case let .gift(payload):
            payload.note.isEmpty
                ? String(format: NSLocalizedString("Badge gift card, %lld days, tap to redeem.", comment: "POPOPX commerce VoiceOver"), payload.period.days)
                : String(format: NSLocalizedString("Badge gift card, %1$lld days, message: %2$@. Tap to redeem.", comment: "POPOPX commerce VoiceOver"), payload.period.days, payload.note)
        case let .packet(payload):
            payload.recipients > 1
                ? String(format: NSLocalizedString("Compute Credits red packet, %1$lld credits split %2$lld ways. Tap to open.", comment: "POPOPX commerce VoiceOver"), payload.amount, payload.recipients)
                : String(format: NSLocalizedString("Compute Credits red packet, %lld credits. Tap to open.", comment: "POPOPX commerce VoiceOver"), payload.amount)
        case let .channel(payload):
            String(format: NSLocalizedString("Channel subscription threshold, %lld Compute Credits per period. Tap to subscribe.", comment: "POPOPX commerce VoiceOver"), payload.price)
        }
    }
}

// MARK: - 卡片表面

/// 这几张卡片共用的那一层：卡片底、细描边、左对齐的内容列。
private struct PopopxCommerceCardSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            content
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }
}

private struct PopopxCommerceCardHeader: View {
    let systemImage: String
    let title: String
    let caption: String
    let ink: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            Image(systemName: systemImage)
                .font(PopopxType.emphasis)
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(verbatim: title)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                Text(verbatim: caption)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PopopxMetrics.spaceS)
        }
    }
}

/// 拒绝态那一行：一个图标加一句话，不做大面积红色块——卡片里最常见的失败是"过期/已用"，
/// 那不是一个错误，用 danger 底会把普通状态喊成事故。
private struct PopopxCommerceCardNote: View {
    let systemImage: String
    let text: String
    let ink: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: systemImage)
                .font(PopopxType.microTag)
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 礼品卡

/// 会话里收到的一张徽章礼品卡。点"兑换"发出的是 `CHAT_REDEEM_REQ`，终态等 ACK。
struct PopopxGiftCardBubble: View {
    let payload: PopopxGiftCardPayload
    let context: PopopxCommerceCardContext

    @State private var credits = PopopxCreditsManager.shared
    @State private var router = PopopxSilentSignalingRouter.shared
    @State private var opening = false
    /// 只装"当场就失败"那几种（验签不过、发不出去）。发起成功时它是 nil，
    /// 于是终态一律来自 `outcomesByVoucher`，两个来源不会互相盖住对方。
    @State private var immediate: PopopxRedemptionOutcome?

    var body: some View {
        PopopxCommerceCardSurface {
            PopopxCommerceCardHeader(
                systemImage: "giftcard.fill",
                title: Copy.title(payload.period.days),
                caption: payload.note.isEmpty ? Copy.caption : Copy.note(payload.note),
                ink: PopopxPalette.meshInk
            )
            Divider().overlay(PopopxPalette.separator)
            state
        }
        .onAppear { credits.loadIfNeeded() }
    }

    @ViewBuilder private var state: some View {
        if !payload.isSignatureValid {
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.rejected, ink: PopopxPalette.dangerInk)
        } else if credits.hasRedeemed(voucherId: payload.voucherId) {
            PopopxCommerceCardNote(systemImage: "checkmark.seal.fill", text: Copy.redeemedHere, ink: PopopxPalette.successInk)
        } else if !context.incoming {
            PopopxCommerceCardNote(systemImage: "arrow.up.right", text: Copy.sentByYou, ink: PopopxPalette.labelSecondary)
        } else {
            switch context.target {
            case .none:
                PopopxCommerceCardNote(systemImage: "eye", text: Copy.readOnly, ink: PopopxPalette.labelSecondary)
            case .some(.group):
                // 礼品卡的 ACK 按 chatId 记账，群里的第二个人会把别人那一笔判掉，所以路由在入口就不放行。
                PopopxCommerceCardNote(systemImage: "person.2", text: Copy.groupUnsupported, ink: PopopxPalette.labelSecondary)
            case .some(.contact):
                awaitingOrAction
            }
        }
    }

    @ViewBuilder private var awaitingOrAction: some View {
        switch resolvedOutcome {
        case .some(.redeemed(let period, _)):
            PopopxCommerceCardNote(systemImage: "checkmark.seal.fill",
                                   text: Copy.redeemed(period.days),
                                   ink: PopopxPalette.successInk)
        case let .some(.failed(error)):
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: gloss(error), ink: PopopxPalette.dangerInk)
        case .some(.initiated), .none:
            PopopxButton(opening ? Copy.sending : Copy.redeem,
                         systemImage: opening ? nil : "key.fill",
                         role: .secondary,
                         fullWidth: true,
                         isLoading: opening) {
                await redeem()
            }
        }
    }

    private var resolvedOutcome: PopopxRedemptionOutcome? {
        immediate ?? router.outcomesByVoucher[payload.voucherId]
    }

    private func redeem() async {
        guard case let .contact(contactId) = context.target else { return }
        opening = true
        immediate = nil
        let outcome = await router.redeemInChat(payload, contactId: contactId)
        if case .initiated = outcome {
            PopopxHaptics.notice(.warning)
        } else {
            immediate = outcome
            PopopxHaptics.notice(.error)
        }
        opening = false
    }

    private func gloss(_ error: PopopxBadgeCreditsError) -> String {
        switch error {
        case .connectionUnavailable: Copy.glossUnreachable
        case .voucherAlreadyRedeemed: Copy.glossAlready
        case .signalRejected: Copy.rejected
        default: error.errorDescription ?? Copy.glossGeneric
        }
    }
}

// MARK: - 红包

/// 会话里的一个算力点红包。自己发出去的那一张显示份数，别人发来的那一张才给"拆开"。
struct PopopxRedPacketBubble: View {
    let payload: PopopxRedPacketPayload
    let context: PopopxCommerceCardContext

    @State private var credits = PopopxCreditsManager.shared
    @State private var router = PopopxSilentSignalingRouter.shared
    @State private var opening = false
    @State private var receiptStuck = false

    var body: some View {
        PopopxCommerceCardSurface {
            PopopxCommerceCardHeader(
                systemImage: context.incoming ? "gift.fill" : "giftcard.fill",
                title: Copy.title,
                caption: payload.note.isEmpty ? Copy.caption : Copy.note(payload.note),
                ink: PopopxPalette.danger
            )
            amountLine
            Divider().overlay(PopopxPalette.separator)
            state
        }
        .onAppear { credits.loadIfNeeded() }
    }

    private var amountLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, payload.amount))
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.label)
            Text(verbatim: Copy.split(payload.recipients))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Spacer(minLength: PopopxMetrics.spaceS)
        }
    }

    @ViewBuilder private var state: some View {
        if !payload.isSelfSignatureValid || !payload.isAmountAuthorized || payload.amountPerRecipient == nil {
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.rejected, ink: PopopxPalette.dangerInk)
        } else if credits.hasClaimed(packetId: payload.packetId) {
            claimedRow
        } else if !context.incoming {
            senderRow
        } else if context.target == nil {
            PopopxCommerceCardNote(systemImage: "eye", text: Copy.readOnly, ink: PopopxPalette.labelSecondary)
        } else {
            PopopxButton(Copy.open, systemImage: "gift", role: .secondary,
                         fullWidth: true, isLoading: opening) {
                await open()
            }
        }
    }

    /// 已拆开那一格：金额来自载荷本身，不是本机临时记的一份数——重启后也要说得出一样的数。
    private var claimedRow: some View {
        Group {
            PopopxCommerceCardNote(
                systemImage: "checkmark.circle.fill",
                text: Copy.claimed(payload.amountPerRecipient ?? 0),
                ink: PopopxPalette.successInk
            )
            if receiptStuck {
                PopopxButton(Copy.resendReceipt, systemImage: "arrow.clockwise", role: .ghost,
                             fullWidth: false) {
                    await resendReceipt()
                }
            }
        }
    }

    /// 发送方视角：份数只在"这一单是我本机发的"时才显示，别人的 packetId 在这里没有意义。
    @ViewBuilder private var senderRow: some View {
        if let packet = credits.pendingPacket(packetId: payload.packetId) {
            PopopxCommerceCardNote(
                systemImage: packet.isFullyClaimed ? "checkmark.seal" : "hourglass",
                text: Copy.sent(packet.claimedCount, packet.recipientCount),
                ink: PopopxPalette.labelSecondary
            )
        } else {
            PopopxCommerceCardNote(systemImage: "arrow.up.right", text: Copy.sentByYou, ink: PopopxPalette.labelSecondary)
        }
    }

    // MARK: 动作

    private func open() async {
        guard let share = payload.amountPerRecipient else {
            opening = false
            return
        }
        opening = true
        do {
            // 先入账再发回执：那份点数是拆的人的，回执只影响发送方退多少，不该反过来决定这一笔能不能到账。
            let credited = try credits.claimRedPacket(
                packetId: payload.packetId, amountPerRecipient: share, note: payload.note
            )
            if credited {
                PopopxHaptics.notice(.success)
                let delivered = await sendReceipt()
                receiptStuck = !delivered
            } else {
                // 重放保护挡下的（同一条 packetId 已经入过账）：显示已拆开，不再重复发回执。
                PopopxHaptics.notice(.warning)
            }
        } catch {
            PopopxHaptics.notice(.error)
        }
        opening = false
    }

    private func resendReceipt() async {
        let delivered = await sendReceipt()
        receiptStuck = !delivered
        PopopxHaptics.notice(receiptStuck ? .error : .success)
    }

    private func sendReceipt() async -> Bool {
        guard let target = context.target else { return false }
        return await router.sendRedPacketReceipt(packetId: payload.packetId, to: target)
    }
}

// MARK: - 频道订阅门槛

/// 频道主在频道里发布的那一条门槛。成员看到的是价与"订阅"，频道主看到的是"你发布的门槛"。
///
/// 三件事在这张卡上是真的：价取自载荷、验签用载荷里带的公钥、扣点走
/// `PopopxCreditsManager.subscribeToChannel`（判据 `1…maximumCreditsThreshold` 在那一侧也再查一遍）。
/// 一件事不是：这张卡**不改变频道能广播给谁**（SimpleX 的频道是单向广播，Swift 侧没有按人过滤的接口），
/// 所以它是本机的准入闸门，那句话写在订阅面板的边界条目里，这里不重复承诺。
///
/// ### 防冒充能做到的是哪两半，做不到的是哪一半
/// 做得到：卡片落在非频道的会话里就不作数（`context.isChannel`，这一支排在扣点之前），
/// 以及"本机上一次付费记下的那把钥匙"与这一条的签名公钥对不上时不给订阅（`channelIssuerConflict`）。
/// 做不到：**在这一条消息上认出"发它的人是不是这个频道的管理员"**。频道消息在成员侧的方向是
/// `CIDirection.channelRcv`，那一个档不带 `GroupMember`（`ChatTypes.swift:4421-4422`，
/// `groupMemberId` 对它是 nil：:4440-4442），核心也没把作者的权威公钥交给 Swift，
/// 而本模块的签名密钥是另一套 P256 钥匙，两边没有可比的数。
/// 所以角色只能判在发布侧那一半（`sendChannelAccess`），第一次付费之前的伪造窗口是记录在案的残留风险。
struct PopopxChannelAccessBubble: View {
    let payload: PopopxChannelAccessPayload
    let context: PopopxCommerceCardContext

    @State private var credits = PopopxCreditsManager.shared
    @State private var showSubscribe = false

    var body: some View {
        PopopxCommerceCardSurface {
            PopopxCommerceCardHeader(
                systemImage: context.incoming ? "lock.fill" : "lock.open.fill",
                title: Copy.channelHeadline,
                caption: Copy.caption(PopopxCommerceFormat.date(payload.publishedAtMs)),
                ink: PopopxPalette.brand
            )
            priceLine
            Divider().overlay(PopopxPalette.separator)
            state
        }
        .onAppear { credits.loadIfNeeded() }
        .sheet(isPresented: $showSubscribe) {
            // 面板自己查旧票、自己叠天数（`subscribeToChannel` 在到期时间之上再加一格），
            // 所以这里只把"这个会话 + 这个价"交下去，不多带一个状态。
            PopopxChannelSubscriptionSheet(
                channelId: context.chatId,
                channelTitle: context.chatTitle,
                price: payload.price,
                issuerPublicKeyBase64URL: payload.issuerPublicKeyBase64URL,
                receiptTarget: context.target
            )
            .presentationDetents([.large])
        }
    }

    private var priceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, payload.price))
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.label)
            Text(verbatim: Copy.perPeriod(PopopxCommerceLimits.channelTicketSeconds / 86_400))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Spacer(minLength: PopopxMetrics.spaceS)
        }
    }

    @ViewBuilder private var state: some View {
        if !payload.isPriceAuthorized {
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.priceRejected, ink: PopopxPalette.dangerInk)
        } else if !payload.isIssuerSignatureValid {
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.channelRejected, ink: PopopxPalette.dangerInk)
        } else if !context.incoming {
            // 频道主自己那一条：这一支不扣自己的点，也没有票可看。
            PopopxCommerceCardNote(systemImage: "arrow.up.right", text: Copy.published, ink: PopopxPalette.labelSecondary)
        } else if context.chatId.isEmpty {
            // 挂载方没给会话键（默认那一条兜底路径）。这时"订阅"会签出一张键为空串的凭证，
            // 而空串在所有频道之间是同一个键——扣一次点，别处也显示已订阅。宁可只读。
            PopopxCommerceCardNote(systemImage: "eye", text: Copy.readOnlyChannel, ink: PopopxPalette.labelSecondary)
        } else if !context.isChannel {
            // 门槛卡片落在非频道的会话里（单聊、私人 group、转发的截图）。
            // 这一支必须排在扣点之前：伪造一张 `popopx://channel` 粘进单聊，本来能在这里扣掉点数的。
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.notAChannel, ink: PopopxPalette.dangerInk)
        } else if credits.channelIssuerConflict(channelId: context.chatId,
                                                issuerPublicKeyBase64URL: payload.issuerPublicKeyBase64URL) {
            // 与本机上一次付费记下的发布者不是同一把钥匙。覆盖面与判据都在
            // `PopopxCreditsManager.channelIssuerConflict` 那一节，这里不重复承诺。
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.issuerMismatch, ink: PopopxPalette.dangerInk)
        } else if let ticket = credits.ticket(forChannelId: context.chatId) {
            PopopxCommerceCardNote(
                systemImage: "checkmark.seal.fill",
                text: Copy.activeUntil(PopopxCommerceFormat.date(ticket.expiresAtMs)),
                ink: PopopxPalette.successInk
            )
            PopopxButton(Copy.renew, systemImage: "arrow.clockwise", role: .secondary,
                         fullWidth: true) {
                showSubscribe = true
            }
        } else {
            PopopxButton(Copy.subscribe, systemImage: "lock.open", role: .primary,
                         fullWidth: true) {
                showSubscribe = true
            }
        }
    }
}

// MARK: - 文案

private enum Copy {
    // 礼品卡
    static func title(_ days: Int) -> String { String(format: NSLocalizedString("%1$lld-day %2$@", comment: "POPOPX gift card bubble title"), days, PopopxCommerceCopy.badgeProductName) }
    static let caption = NSLocalizedString("A badge voucher sent by the other person", comment: "POPOPX gift card bubble")
    static func note(_ text: String) -> String { String(format: NSLocalizedString("Message: %@", comment: "POPOPX commerce card note"), text) }
    static let redeem = NSLocalizedString("Redeem", comment: "POPOPX gift card bubble")
    static let sending = NSLocalizedString("Waiting for the other side…", comment: "POPOPX gift card bubble")
    static let redeemedHere = NSLocalizedString("This voucher has already been redeemed on this device.", comment: "POPOPX gift card bubble")
    static let sentByYou = NSLocalizedString("This is the one you sent.", comment: "POPOPX commerce card")
    static let readOnly = NSLocalizedString("Read only here: redeeming has to happen in the chat with this contact.", comment: "POPOPX commerce card")
    static let groupUnsupported = NSLocalizedString("Badge vouchers can only be redeemed in a one-to-one chat.", comment: "POPOPX commerce card")
    static let rejected = NSLocalizedString("The signature does not verify: this is not the voucher that was issued.", comment: "POPOPX commerce card")
    static func redeemed(_ days: Int) -> String { String(format: NSLocalizedString("Badge lit for %lld days.", comment: "POPOPX gift card bubble"), days) }
    static let glossUnreachable = NSLocalizedString("Cannot reach the other device: the link may already have expired.", comment: "POPOPX commerce card")
    static let glossAlready = NSLocalizedString("This voucher has already been redeemed.", comment: "POPOPX commerce card")
    static let glossGeneric = NSLocalizedString("This did not complete; you can try again later.", comment: "POPOPX commerce card")

    // 红包
    static let open = NSLocalizedString("Open the packet", comment: "POPOPX red packet button")
    static let title = NSLocalizedString("Compute Credits red packet", comment: "POPOPX red packet card")
    static func split(_ count: Int) -> String { count > 1 ? String(format: NSLocalizedString("Split evenly %lld ways", comment: "POPOPX red packet card"), count) : NSLocalizedString("Single recipient", comment: "POPOPX red packet card") }
    static func claimed(_ share: Int) -> String { String(format: NSLocalizedString("Opened · %lld credits credited", comment: "POPOPX red packet card"), share) }
    static func sent(_ claimed: Int, _ total: Int) -> String { String(format: NSLocalizedString("Claimed %1$lld of %2$lld shares", comment: "POPOPX red packet card"), claimed, total) }
    static let resendReceipt = NSLocalizedString("Send the receipt again", comment: "POPOPX red packet card")

    // 频道订阅门槛
    static let channelHeadline = NSLocalizedString("Channel subscription threshold", comment: "POPOPX channel card")
    static func caption(_ date: String) -> String { String(format: NSLocalizedString("Published by the channel owner on %@", comment: "POPOPX channel card"), date) }
    static func perPeriod(_ days: Int) -> String { String(format: NSLocalizedString("/ %lld days", comment: "POPOPX channel card price suffix"), days) }
    static let subscribe = NSLocalizedString("Subscribe", comment: "POPOPX channel card")
    static let renew = NSLocalizedString("Renew", comment: "POPOPX channel card")
    static func activeUntil(_ date: String) -> String { String(format: NSLocalizedString("Access valid until %@", comment: "POPOPX channel card"), date) }
    static let published = NSLocalizedString("This is the threshold you published: credits are charged only when a member taps it.", comment: "POPOPX channel card")
    static let channelRejected = NSLocalizedString("The signature does not verify: this is not the entry published by the channel owner.", comment: "POPOPX channel card")
    static let notAChannel = NSLocalizedString("This is not in a channel: a threshold card only counts inside a channel, so no credits are charged here.", comment: "POPOPX channel card")
    static let issuerMismatch = NSLocalizedString("The signing key does not match the publisher recorded on this device from your last payment: either someone forwarded this card, or the channel owner changed devices.", comment: "POPOPX channel card")
    static let priceRejected = NSLocalizedString("This threshold is outside the allowed range (from 1 to the maximum; free needs no published threshold).", comment: "POPOPX channel card")
    static let readOnlyChannel = NSLocalizedString("Read only here: this entry could not be matched to the channel it is in, so credits have to be charged in that channel.", comment: "POPOPX channel card")
}

// MARK: - Previews

/// 预览里的签名一律是假串：卡片因此停在"验不过"那一格。
/// 这一族卡片的状态全部来自钥匙串账本与运行时签名，预览造不出可信的那一份，
/// 所以留这一格给眼睛看，其余状态在真机上验（见 `Docs/app-store-review-notes.md` 的自测清单）。
struct PopopxCommerceCardsDark_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
            PopopxGiftCardBubble(
                payload: PopopxGiftCardPayload(voucherId: "voucher.preview", period: .monthly,
                                               note: "Shielding you for a month", mintedAtMs: 0, signature: "invalid"),
                context: PopopxCommerceCardContext(target: .contact(1), incoming: true)
            )
            PopopxRedPacketBubble(
                payload: PopopxRedPacketPayload(packetId: "packet.preview", amount: 50, recipients: 5,
                                                note: "Happy new year", signature: "invalid"),
                context: PopopxCommerceCardContext(target: .group(2), incoming: true)
            )
            PopopxChannelAccessBubble(
                payload: PopopxChannelAccessPayload(price: 200, publishedAtMs: 0,
                                                    issuerPublicKeyBase64URL: "preview", signature: "invalid"),
                context: PopopxCommerceCardContext(target: .group(2), incoming: true,
                                                   chatId: "#2", chatTitle: "Night flight notes", isChannel: true)
            )
        }
        .padding(PopopxMetrics.gutter)
        .background(PopopxPalette.base)
        .preferredColorScheme(.dark)
    }
}
