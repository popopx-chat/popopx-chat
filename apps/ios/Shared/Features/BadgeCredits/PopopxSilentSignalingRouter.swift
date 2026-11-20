//  PopopxSilentSignalingRouter.swift
//
//  不可见信令的唯一出入口：`::popopx_sys::` 的收发、一次性 SMP 连接的建与删、
//  以及"兑换"这件事在端到端形态下的完整一次往返。
//
//  ### 信令就是普通 SMP 文本（本轮裁定的落地形态）
//  提示词要求"加密信令通道对 UI 完全隐身"。这个 app 的 `MsgContent` 只有可见档，
//  `CIContent` 的控制档全部由 Haskell 核心产生，Swift 侧没有"发一条不进时间线的消息"的接口。
//  所以信令是一条**普通文本消息**，隐身由三层达成，也止步于三层：
//  1. 渲染抑制：三处闸共用 `PopopxSysMarker.isSignalText`（判据只有那一份，见
//     `PopopxBadgeCreditsModels.swift` 的 marker 一节）——会话里的行 `ChatView.swift:2318-2325`、
//     会话列表预览 `ChatPreviewView.swift:301-307`、通知横幅 `NtfManager.swift:254-262`。
//     通知这一处必须单独闸：横幅是在删行的 `Task` 之前同步发出的，只靠"用完即删"赶不上；
//  2. 落库后删除：ACK 完成后调 `apiDeleteChatItems(mode: .cidmInternal)`，本地不留行
//     （删除后的模型更新抄 `Shared/Features/PersonalProfile/ProfileReaderView.swift:756-773`）；
//  3. 临时连接整体删除：一次性兑换用的那条 contact 走完 ACK 就 `apiDeleteContact(.full(notify: false))`。
//  残留的两条如实写明，不假称干净：`.cidmInternal` 只删本机这一份（对方不广播删除，
//  消息本身早已到达对方并留在对方库里），而**装了别的客户端（桌面版 SimpleX）的那一侧不认识
//  `::popopx_sys::`**，会把它显示成普通文本、也照常通知——这三处闸只保护跑本 app 的设备。
//  要真正消除这两条，需要核心侧加一个专用消息类型或新的 `CIDeleteMode`，
//  那是 Haskell 层的改动，不在本轮范围内。
//
//  ### 时序（为什么 REQ 不在连接建立的那一步就发）
//  收件方 `apiConnect` 之后，自己这一侧只是 `PendingContactConnection`；
//  赠方 accept 之后**双方**才各有一个 direct contact，而收件方的 `contactConnected` 事件
//  正是"对方已经 accept"的信号。所以 REQ 挂在收件方的 `.contactConnected` 上发（挂载点
//  `Shared/Model/POPOPXAPI.swift:2651` 那条 case 旁边，与 `ProfileAutoSender` 同一形状）。
//  早一步发是发不出去的：那条连接此刻还不能承载消息。
//
//  ### 为什么兑换只可能回到铸券的那台设备
//  一次性链接指向赠方那条 connection，只有持券者能 accept。防双花的状态机在
//  `PopopxP2PVoucherVault.authorizeRedemption` 里（actor 串行，先翻 `redeemed` 再签名），
//  这一层只负责"把那条判据的结果原样回给对方"。
//
//  ### ACK 必须配得上一次发起
//  验签只证明"有人签了"，不证明"这枚徽章是给你的"。所以每一笔 ACK 都要对上本机等它的
//  那一次发起（`awaitingAcks`），对不上就整条丢弃、连删除都不做（不替别人清理时间线）。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import Foundation
import os
import POPOPXChat

// MARK: - 落点

/// 频道门槛卡片的发布资格，判据只有一份：本机的成员记录在这个群里确实是管理员及以上。
/// `memberCurrent` 那一半不能省——被降下来的管理员手里还留着旧会话，那一支也该挡住。
/// 形状照 `GroupInfo.canAddMembers`（ChatTypes.swift:3083-3085）。
/// 频道信息页那一格（`PopopxGroupChatInfoView`）与 `sendChannelAccess` 的守卫都走它。
extension GroupInfo {
    var popopxCanPublishChannelThreshold: Bool {
        isChannel && membership.memberRole >= .admin && membership.memberCurrent
    }
}

/// 一条商业消息要发到哪个会话。只带 id：`Contact` / `GroupInfo` 都不是 Sendable，
/// 而且本类型出现的每一处都只需要"上哪儿找这个会话"，不需要会话的内容。
///
/// `.group` 服务红包与频道那两支（卡片、回执）；兑换信令一律 `.contact`——`awaitingAcks` 按 chatId 记账，
/// 群里的第二个人会把别人那一笔判掉（入群判据：`PopopxCommerceSignalKind.acceptedInGroup`）。
enum PopopxCommerceTarget: Hashable, Sendable {
    case contact(Int64)
    case group(Int64)

    var chatId: Int64 {
        switch self {
        case let .contact(id): id
        case let .group(id): id
        }
    }

    /// 从会话信息取落点。非 direct / group 的会话（备注、联系人请求、频道）返回 nil：
    /// 那些会话里没有"对面这个人"可以收钱。
    static func commerceTarget(chatType: ChatType, chatId: Int64) -> PopopxCommerceTarget? {
        switch chatType {
        case .direct: .contact(chatId)
        case .group: .group(chatId)
        default: nil
        }
    }
}

// MARK: - 结果

/// 一次兑换对用户说出口的结果。失败带的是那一份已有措辞的错误，不是这里另编一句。
enum PopopxRedemptionOutcome: Hashable, Sendable {
    /// 已发起，等对方确认。收件方在 ACK 到达前拿到的就是这个，UI 显示"等待对方确认"。
    /// 终态之后会写进 `PopopxSilentSignalingRouter.lastOutcome`。
    case initiated
    /// 已经点亮（ACK 验签通过、且对得上本机的发起、徽章写入成功）。
    case redeemed(period: PopopxNodeBadgePeriod, expiresAtMs: Int64)
    /// 明确失败。
    case failed(PopopxBadgeCreditsError)

    var announcementText: String {
        switch self {
        case .initiated: PopopxSignalingCopy.waitingForPeer
        case let .redeemed(period, _): PopopxSignalingCopy.redeemed(period.days)
        case let .failed(error): error.errorDescription ?? PopopxSignalingCopy.genericFailure
        }
    }
}

// MARK: - 路由器

@MainActor
@Observable
final class PopopxSilentSignalingRouter {
    static let shared = PopopxSilentSignalingRouter()

    /// 最近一次兑换结果，供兑换面板订阅。一次性链接的 ACK 是异步到达的，
    /// 面板点"兑换"时不可能在同一次调用里返回终态，所以终态写在这里而不是返回值里。
    private(set) var lastOutcome: PopopxRedemptionOutcome?

    /// voucherId → 那一张礼品卡的结果，供会话流里的气泡订阅。
    /// 只靠 `lastOutcome` 会串台：两台聊天里各有一张券时，后到的那一份终态会同时点亮两张卡。
    /// 不持久化：它只是"这一程 UI 要看的结果"，真正留下的是 `PopopxBadgeManager` 的那条徽章记录。
    private(set) var outcomesByVoucher: [String: PopopxRedemptionOutcome] = [:]

    /// 写终态。两份必须同一次写完，否则面板与卡片会各说一种话。
    /// `voucherId` 可为 nil：一条解不开的 ACK 只知道"失败了"，不知道是哪枚券的。
    private func record(_ outcome: PopopxRedemptionOutcome, voucherId: String?) {
        lastOutcome = outcome
        guard let voucherId else { return }
        // 那 64 格的上限只为防涨。还在等 ACK 的绝不能被清掉——那是唯一还会变的那几笔。
        if outcomesByVoucher.count >= 64 {
            let inflight = Set(awaitingAcks.values.map(\.voucherId))
            outcomesByVoucher = outcomesByVoucher.filter { inflight.contains($0.key) }
        }
        outcomesByVoucher[voucherId] = outcome
    }

    /// connId → 待发的 REQ。落 Keychain（`ephemeralConnections` 格）是为了进程被杀之后
    /// 用户还能重新走一遍；不落盘的话，一次后台终止就会让那条码永久停在"已连接、未请求"。
    /// 键是 `PendingContactConnection.pccConnId`（`POPOPXChat/ChatTypes.swift:2912`，Int64）。
    private var pendingRequestsByConnection: [Int64: PopopxPendingRedeem] = [:]
    /// contactId → 已发出 REQ、等 ACK 的那一笔。`deletesContactAfterAck` 区分两种兑换：
    /// 一次性链接那次要连联系人一起删（不留痕），会话内礼品卡那次绝不能删，那是好友本身。
    private var awaitingAcks: [Int64: PopopxInflightRedeem] = [:]

    private var loaded = false
    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "signaling")

    private init() {}

    // MARK: 载入

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        pendingRequestsByConnection = PopopxCommerceKeychain.decode([Int64: PopopxPendingRedeem].self, .ephemeralConnections) ?? [:]
    }

    private func savePendingRequests() {
        _ = PopopxCommerceKeychain.encode(pendingRequestsByConnection, .ephemeralConnections)
    }

    // MARK: 挂载点 1 · 收件方连接建成

    /// 由 `POPOPXAPI` 的 `.contactConnected` 分支调用。只传标量：`Contact` 不是 Sendable，
    /// 把它带进这个隔离域会直接撞上严格并发告警，`ProfileAutoSender` 同一处理方式。
    func contactConnected(connectionId: Int64, contactId: Int64) {
        loadIfNeeded()
        guard let pending = pendingRequestsByConnection[connectionId] else { return }
        pendingRequestsByConnection.removeValue(forKey: connectionId)
        savePendingRequests()
        awaitingAcks[contactId] = PopopxInflightRedeem(voucherId: pending.voucherId, deletesContactAfterAck: true)
        Task {
            if await send(text: pending.signalWire, to: .contact(contactId)) == false {
                awaitingAcks.removeValue(forKey: contactId)
                record(.failed(.connectionUnavailable), voucherId: pending.voucherId)
            }
        }
    }

    // MARK: 挂载点 2 · 收到消息

    /// 兑换信令只认 direct：群里的一条会把"谁兑了这张券"广播给所有成员。
    /// 群会话唯一放行的是红包回执——那是群红包的份数来源，且 `memberId` 能把它记到人头上
    /// （`CIDirection.groupMemberId`，`POPOPXChat/ChatTypes.swift:4440`）。
    /// 判据放在最前面，是为了让误投进群的其他信令连解析都不做。
    func observeIncoming(chatType: ChatType, chatId: Int64, itemId: Int64,
                         memberId: Int64? = nil, text: String) {
        guard chatType == .direct || chatType == .group,
              let signal = PopopxSysMarker.parse(wholeText: text) else { return }
        if chatType == .group, !signal.kind.acceptedInGroup { return }
        Task { await handle(signal, chatId: chatId, itemId: itemId, memberId: memberId, wire: text) }
    }

    private func handle(_ signal: PopopxCommerceSignal, chatId: Int64,
                        itemId: Int64, memberId: Int64?, wire: String) async {
        switch signal.kind {
        case .externalRedeemRequest, .chatRedeemRequest:
            await answerRedeemRequest(signal, chatId: chatId, itemId: itemId, wire: wire)
        case .externalRedeemAcknowledge, .chatRedeemAcknowledge:
            await applyRedeemAcknowledgement(signal, chatId: chatId, itemId: itemId)
        case .redPacketClaimed:
            // `memberId` 只有群消息才有。direct 传 nil：那一侧的防重放本来就在领取方的账本里
            // （同一条 packetId 只入账一次），发送方这里只是记账份数。
            PopopxCreditsManager.shared.recordClaim(packetId: signal.payload, memberKey: memberId.map { "\($0)" })
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
        case .profileUnlocked:
            // 名片主人这一侧只做一件事：删掉那一行。它不记账、不弹提示、也不在气泡上留痕——
            // "谁在什么时候看了你的主页"一旦变成能回看的记录，这条信令就不叫静默了。
            // 日志里留一句是为了让用户自己问的时候答得上来（它确实进过这台设备）。
            log.info("signaling: profile unlock receipt from chat \(chatId, privacy: .public)")
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
        case .channelSubscriptionAcknowledge:
            // 与名片解锁回执同一处理：删本机那一行，不记账、不动界面。
            // 为什么不能记账：载荷里的 `chatInfoId` 是**发的那台设备**的行号（`ChatInfo.id` =
            // `"#" + 本机 groupId`，ChatTypes.swift:3059），收到的一侧跟它没有任何对应关系；
            // 而频道消息的 `chatDir` 是 `.channelRcv`，不带成员对象（:4421-4422、:4440-4442），
            // 所以"谁核销的"在 Swift 层根本无从判定。留这一句日志是唯一的实证痕迹。
            log.info("signaling: channel subscription receipt in chat \(chatId, privacy: .public)")
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
        }
    }

    // MARK: 赠方 · 应答兑换请求

    private func answerRedeemRequest(_ signal: PopopxCommerceSignal, chatId: Int64, itemId: Int64, wire: String) async {
        guard signal.isRequest else { return }
        // 券不是本机的、或已经兑过 → 一次都不签。这一句本身就是答案：它不泄漏
        // "这张券存不存在"之外的信息，因为券号是用户自己交出来的。
        guard let grant = await PopopxP2PVoucherVault.shared.authorizeRedemption(voucherId: signal.payload, codeDigestSource: wire) else {
            log.info("signaling: redeem request rejected — unknown or already redeemed voucher")
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
            return
        }
        guard let encoded = PopopxSilentSignalingRouter.encoded(grant) else {
            // 授权已落盘但编码失败：本地 bug 级状态，绝不能回一句"成功"。
            // 券停在 redeemed 比让对方拿到一份假授权好，用户可以从券列表里把它作废。
            log.error("signaling: grant could not be encoded")
            return
        }
        let acknowledged = await send(
            text: PopopxSysMarker.wireString(for: PopopxCommerceSignal(kind: .externalRedeemAcknowledge, payload: encoded)),
            to: .contact(chatId)
        )
        guard acknowledged else {
            log.error("signaling: ACK could not be sent; voucher stays redeemed")
            return
        }
        _ = await deleteSignal(chatId: chatId, itemId: itemId)
    }

    // MARK: 收件方 · 应用授权

    private func applyRedeemAcknowledgement(_ signal: PopopxCommerceSignal, chatId: Int64, itemId: Int64) async {
        guard let grant = PopopxSilentSignalingRouter.decodedGrant(signal.payload) else {
            record(.failed(.codeMalformed), voucherId: nil)
            return
        }
        guard let inflight = awaitingAcks[chatId], inflight.voucherId == grant.voucherId else {
            log.info("signaling: acknowledgement for a redemption this device never requested")
            return
        }
        awaitingAcks.removeValue(forKey: chatId)
        guard await PopopxP2PVoucherVault.shared.record(grant) else {
            record(.failed(.signalRejected), voucherId: grant.voucherId)
            return
        }
        do {
            let badge = try PopopxBadgeManager.shared.activate(grant: grant)
            // 先记下"这枚券本机兑过了"，再写终态：中间万一进程被杀，重启后气泡看到的也是已核销，
            // 而不是一个还能再点一次的按钮。
            PopopxCreditsManager.shared.markRedeemed(voucherId: grant.voucherId)
            record(.redeemed(period: badge.period, expiresAtMs: badge.expiresAtMs), voucherId: grant.voucherId)
        } catch {
            record(.failed(.keychainUnavailable), voucherId: grant.voucherId)
            return
        }
        _ = await deleteSignal(chatId: chatId, itemId: itemId)
        if inflight.deletesContactAfterAck {
            // 一次性兑换连接：整条删掉，通知也不发——对方已经拿到 ACK，
            // 再多一条"某某删除了你"只是把这次交易又写回双方时间线。
            _ = try? await apiDeleteContact(id: chatId, chatDeleteMode: .full(notify: false))
        }
    }

    // MARK: 出站 · 由 UI 调用

    /// 收件方用一条 `PPX1-…` 码发起一次性兑换。
    ///
    /// 返回 `.initiated` 不等于兑换成功：那只是"连接已建、REQ 会在 `contactConnected` 时发出"。
    /// 终态由 `lastOutcome` 给出，面板订阅它。
    func startExternalRedeem(code: String) async -> PopopxRedemptionOutcome {
        loadIfNeeded()
        guard let envelope = PopopxRedeemCode.decode(code) else { return .failed(.codeMalformed) }
        guard envelope.isSignatureValid else { return .failed(.signalRejected) }
        let connLink = CreatedConnLink(connFullLink: envelope.inviteLink, connShortLink: nil)
        guard let (_, connection) = await apiConnect(incognito: true, connLink: connLink) else {
            return .failed(.connectionUnavailable)
        }
        let wire = PopopxSysMarker.wireString(
            for: PopopxCommerceSignal(kind: .externalRedeemRequest, payload: envelope.voucherId)
        )
        pendingRequestsByConnection[connection.pccConnId] = PopopxPendingRedeem(voucherId: envelope.voucherId, signalWire: wire)
        savePendingRequests()
        record(.initiated, voucherId: envelope.voucherId)
        return .initiated
    }

    /// 会话内礼品卡：已有联系人，REQ 直接发，ACK 到达后**不删联系人**。
    func redeemInChat(_ payload: PopopxGiftCardPayload, contactId: Int64) async -> PopopxRedemptionOutcome {
        guard payload.isSignatureValid else { return .failed(.signalRejected) }
        let wire = PopopxSysMarker.wireString(
            for: PopopxCommerceSignal(kind: .chatRedeemRequest, payload: payload.voucherId)
        )
        guard await send(text: wire, to: .contact(contactId)) else { return .failed(.connectionUnavailable) }
        awaitingAcks[contactId] = PopopxInflightRedeem(voucherId: payload.voucherId, deletesContactAfterAck: false)
        record(.initiated, voucherId: payload.voucherId)
        return .initiated
    }

    /// 铸一张券的可兑换码：`PPX1-…`（一次性 SMP 邀请链接 + 券号 + 赠方签名 + checksum）。
    ///
    /// 前置条件只有这一个：券已经在本地券包里（Apple 礼品档或算力点兑换都会先铸券）。
    /// 每次调用都会新建一条一次性 connection —— 这是**必要**的代价，不是装饰：
    /// 一条链接只能被 accept 一次，重复用同一条会出现"第二个人扫码、第一个人还没兑"的双花窗口。
    /// 因此同一张券点"重新生成"会得到新 nonce 与新链接，旧码随之失效（`codeDigest` 只留最新那一份）。
    func mintCode(for voucher: PopopxNodeVoucher) async -> String? {
        guard voucher.state == .unused else { return nil }
        guard let (link, _) = await apiAddContact(incognito: true) else { return nil }
        let publicKey = PopopxCommerceSignature.localPublicKeyBase64URL()
        guard !publicKey.isEmpty else { return nil }
        let seed = PopopxRedeemEnvelope(
            inviteLink: link.connFullLink,
            voucherId: voucher.voucherId,
            period: voucher.period,
            mintedAtMs: voucher.mintedAtMs,
            nonce: Self.nonce(),
            giverPublicKey: publicKey,
            signature: ""
        )
        guard let signature = PopopxCommerceSignature.signatureBase64URL(for: seed.canonicalBytes) else { return nil }
        let envelope = PopopxRedeemEnvelope(
            inviteLink: seed.inviteLink,
            voucherId: seed.voucherId,
            period: seed.period,
            mintedAtMs: seed.mintedAtMs,
            nonce: seed.nonce,
            giverPublicKey: seed.giverPublicKey,
            signature: signature
        )
        // 自检一次再交出去：签名串与原文的对应关系由同一个 `canonicalBytes` 算出，
        // 但 Keychain 里的私钥可能在这一拍被清场流程换掉，出码前验一次比让对方扫码后报"信令被拒"便宜。
        guard envelope.isSignatureValid, let code = PopopxRedeemCode.encode(envelope) else { return nil }
        await PopopxP2PVoucherVault.shared.recordCodeDigest(
            PopopxCommerceSignature.shortDigest(code), forVoucherId: voucher.voucherId
        )
        return code
    }

    /// 16 字节随机数。Swift 的 `SystemRandomNumberGenerator` 在 Apple 平台上由
    /// `getrandom(2)` 供种，这里是够用的；它进的是公开码文，不是密钥材料。
    private static func nonce() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).popopxBase64URL
    }

    /// 发一张礼品卡（可见行 + 机器行）。这是气泡里那张卡片的来源。
    func sendGiftCard(_ payload: PopopxGiftCardPayload, note: String, contactId: Int64) async -> Bool {
        await send(text: PopopxCommerceCardText.messageText(gift: payload, note: note), to: .contact(contactId))
    }

    /// 发一个红包。`PopopxCreditsManager.sendRedPacket` 已经扣过点，这里只负责把它送出去。
    /// 一对一与群组的差别只在"上哪儿找这个会话"，发送参数全部来自 `chatInfo`，所以是一条路径。
    func sendRedPacket(_ payload: PopopxRedPacketPayload, to target: PopopxCommerceTarget) async -> Bool {
        await send(text: PopopxCommerceCardText.messageText(packet: payload), to: target)
    }

    /// 领取红包后回给发送方的回执。群里回到群里、单聊回到单聊——它跟的是那张卡片，
    /// 不是"发送方这个人"，所以参数与 `sendRedPacket` 同一个落点。
    func sendRedPacketReceipt(packetId: String, to target: PopopxCommerceTarget) async -> Bool {
        await send(
            text: PopopxSysMarker.wireString(for: PopopxCommerceSignal(kind: .redPacketClaimed, payload: packetId)),
            to: target
        )
    }

    /// 名片解锁回执。载荷只有 `profileId`：这条信令唯一要回答的是"哪张名片被开了"，
    /// 而"谁开的"由 SMP 连接自己给出，"付了多少"只在付的那台设备的账本里有意义——
    /// 主人那边没有任何一个字段会因为它而改变，所以这里不多带一个字。
    ///
    /// `contactId` 必须是**单聊**的那个联系人：`PopopxProfileReadKey.chatId` 在群里装的是群号，
    /// 拿它当 contactId 会把回执发给一个毫不相干的人，所以调用方要先确认这一行来自单聊。
    func sendProfileUnlockReceipt(profileId: String, contactId: Int64) async -> Bool {
        await send(
            text: PopopxSysMarker.wireString(
                for: PopopxCommerceSignal(kind: .profileUnlocked, payload: profileId)
            ),
            to: .contact(contactId)
        )
    }

    /// 谁能发（产品裁定的发布侧那一半）：本机的成员记录在这个群里确实是管理员及以上
    /// （`memberRole >= .admin` 且 `memberCurrent`，形状照 `GroupInfo.canAddMembers`，
    /// ChatTypes.swift:3083-3085）。门槛卡片是"频道主定的价"，所以普通成员没有签发的资格。
    ///
    /// 这一条判据只有一份：发布页的按钮（`PopopxChannelThresholdView.canPublish`）与
    /// `sendChannelAccess` 的守卫都走它，界面与出口不可能各说一套。
    /// 它挡住的是"本机自己的界面"；别人伪造的那一半在渲染侧，见 `PopopxChannelAccessBubble`。
    static func canPublishChannelThreshold(groupId: Int64) -> Bool {
        ChatModel.shared.getGroupChat(groupId)?.chatInfo.groupInfo?.popopxCanPublishChannelThreshold == true
    }

    /// 频道主发布订阅门槛。与礼品卡、红包同一形状：一行给人看、一行给机器看，
    /// 但**这一条不删、不隐藏**——它是成员那一侧唯一的价目来源（见
    /// `PopopxChannelAccessPayload` 顶部"为什么必须走消息"那一节），藏起来就是让成员对看不见的数付钱。
    /// 落点只有群组/频道那一支：频道在模型里就是 `useRelays` 的群会话。
    func sendChannelAccess(_ payload: PopopxChannelAccessPayload, to target: PopopxCommerceTarget) async -> Bool {
        guard case .group(let groupId) = target, Self.canPublishChannelThreshold(groupId: groupId) else {
            log.info("signaling: channel threshold publication refused — this device is not an active admin here")
            return false
        }
        return await send(text: PopopxCommerceCardText.messageText(channel: payload), to: target)
    }

    /// 成员扣点签票之后回给频道的那一条核销回执。
    ///
    /// 它是**尽力而为**的：票据已经写进钥匙串了，回执发不出去绝不回滚那一笔点数，也不向用户报错——
    /// 报错会让一个已经成立的订阅看起来像失败了。频道里"订阅者能不能发言"由核心的群设置决定，
    /// Swift 侧没有这个判据（`ChatInfo.sendAsGroup` 只对 `memberRole >= .owner` 为真，:2405-2415），
    /// 所以订阅者那一条很可能在核心那里就被挡掉；挡掉就只留这一行日志。
    func sendChannelSubscriptionAck(chatInfoId: String, expiresAtMs: Int64, to target: PopopxCommerceTarget) async -> Bool {
        let delivered = await send(
            text: PopopxSysMarker.wireString(for: PopopxCommerceSignal(
                kind: .channelSubscriptionAcknowledge,
                payload: "\(chatInfoId)::\(expiresAtMs)"
            )),
            to: target
        )
        if !delivered {
            log.info("signaling: channel subscription receipt not delivered — ticket stands")
        }
        return delivered
    }

    // MARK: 收发原语

    /// 一条 SMP 文本消息。调用形状照 `ProfileAutoSender.sendViaSMP`
    /// （`Shared/Features/PersonalProfile/ProfileAutoSender.swift:511-527`）：
    /// `apiSendMessages` 自己不抛，失败会在 app 层弹提示，所以这里把"返回 nil 或空数组"当失败——
    /// 信令没有别的回执，调用方必须知道它没出去，否则会出现"UI 以为已发出、对端从没收到"的死局。
    private func send(text: String, to target: PopopxCommerceTarget) async -> Bool {
        let chat: Chat?
        switch target {
        case let .contact(id): chat = ChatModel.shared.getContactChat(id)
        case let .group(id): chat = ChatModel.shared.getGroupChat(id)
        }
        guard let chat else {
            log.error("signaling: chat :\(target.chatId, privacy: .public) not found")
            return false
        }
        let items = await apiSendMessages(
            type: chat.chatInfo.chatType,
            id: chat.chatInfo.apiId,
            scope: chat.chatInfo.groupChatScope(),
            sendAsGroup: chat.chatInfo.sendAsGroup,
            live: false,
            ttl: nil,
            sign: false,
            composedMessages: [ComposedMessage(msgContent: .text(text))]
        )
        guard let items, !items.isEmpty else {
            log.error("signaling: send returned no chat item")
            return false
        }
        for item in items {
            ChatModel.shared.addChatItem(chat.chatInfo, item)
        }
        return true
    }

    /// 删掉本机这一行信令。`.cidmInternal` 是唯一正确的档：
    /// `.cidmBroadcast` 会让对方看到"消息被删除"，那等于把信令的存在又写回对方时间线；
    /// `.cidmHistory` 连历史一起改，跨端语义更吵。删除成功后必须把模型也改掉，
    /// 否则这一行还会活在内存里的时间线上（判据只挡住了重绘，没挡住已加载的那一条）。
    private func deleteSignal(chatId: Int64, itemId: Int64) async -> Bool {
        let model = ChatModel.shared
        guard let chat = model.chats.first(where: { $0.chatInfo.apiId == chatId }) else {
            log.error("signaling: no chat for apiId :\(chatId, privacy: .public); the row stays in memory")
            return false
        }
        do {
            let deletions = try await apiDeleteChatItems(
                type: chat.chatInfo.chatType,
                id: chat.chatInfo.apiId,
                scope: chat.chatInfo.groupChatScope(),
                itemIds: [itemId],
                mode: .cidmInternal
            )
            for deletion in deletions {
                if let toItem = deletion.toChatItem {
                    _ = model.upsertChatItem(chat.chatInfo, toItem.chatItem)
                } else {
                    model.removeChatItem(chat.chatInfo, deletion.deletedChatItem.chatItem)
                }
                model.updateChatInfo(deletion.deletedChatItem.chatInfo)
            }
            return true
        } catch {
            log.error("signaling: internal delete failed; the row stays suppressed but present")
            return false
        }
    }

    // MARK: 授权原文编解码

    /// 长度上限与 `PopopxSilentSignalingRouter.decodedGrant` 共用同一档：
    /// 一条信令不该长过一屏可读的范围，超限直接拒收，不进入解码。
    static func encoded(_ grant: PopopxBadgeGrant) -> String? {
        guard let data = try? JSONEncoder().encode(grant),
              data.count <= PopopxCommerceLimits.maximumSignalPayloadCharacters else { return nil }
        return data.popopxBase64URL
    }

    static func decodedGrant(_ payload: String) -> PopopxBadgeGrant? {
        guard payload.count <= PopopxCommerceLimits.maximumSignalPayloadCharacters,
              let data = Data(popopxBase64URL: payload),
              let grant = try? JSONDecoder().decode(PopopxBadgeGrant.self, from: data),
              grant.isSignatureValid
        else { return nil }
        return grant
    }
}

// MARK: - 本地状态

/// 等 `contactConnected` 的那一笔。`signalWire` 存整串而不是重新拼：
/// 拼一次就多一处可能与发出时不一致的地方，而这两条必须逐字节相同。
struct PopopxPendingRedeem: Codable, Hashable, Sendable {
    let voucherId: String
    let signalWire: String
}

/// 已发出 REQ、等 ACK 的那一笔。
struct PopopxInflightRedeem: Hashable, Sendable {
    let voucherId: String
    let deletesContactAfterAck: Bool
}

private enum PopopxSignalingCopy {
    static let waitingForPeer = NSLocalizedString("Redeem request sent — waiting for the other side to confirm", comment: "signaling toast")
    static let genericFailure = NSLocalizedString("Redemption did not complete", comment: "signaling fallback")
    static func redeemed(_ days: Int) -> String { String(format: NSLocalizedString("Redeemed · badge lit for %lld days", comment: "signaling toast"), days) }
}

/// 出站文本里的那一句人话。卡片本身的渲染在 `PopopxCommerceCards.swift`（第 9 项），
/// 这里只负责"发出去的那条消息"：一行给人看，一行给机器看，两者用换行分开，
/// 于是收件方既能读懂，`PopopxGiftCardPayload.parse(from:)` 也能逐 token 把它拆出来。
enum PopopxCommerceCardText {
    static func messageText(gift payload: PopopxGiftCardPayload, note: String) -> String {
        let line = note.isEmpty
            ? String(format: NSLocalizedString("🎁 [Gift badge] %lld days", comment: "outgoing gift card line"), payload.period.days)
            : String(format: NSLocalizedString("🎁 [Gift badge] %1$lld days · %2$@", comment: "outgoing gift card line with note"), payload.period.days, note)
        return line + "\n" + payload.wireString
    }

    static func messageText(packet payload: PopopxRedPacketPayload) -> String {
        // 人类那一行必须与机器那一行说同一个数：份数写在卡片上，拆开时才对得上账。
        let head = payload.recipients > 1
            ? String(format: NSLocalizedString("🧧 [Compute Credits packet] %1$lld · split equally into %2$lld shares", comment: "outgoing red packet line"), payload.amount, payload.recipients)
            : String(format: NSLocalizedString("🧧 [Compute Credits packet] %lld", comment: "outgoing red packet line"), payload.amount)
        return payload.note.isEmpty ? head + "\n" + payload.wireString : head + " · " + payload.note + "\n" + payload.wireString
    }

    /// 门槛卡片的人话那一行。天数直接取 `channelTicketSeconds`，与成员那边扣点后写进凭证的
    /// 时长同源：这里写"30 天"、那边签出别的天数，就是两张嘴说一个价。
    static func messageText(channel payload: PopopxChannelAccessPayload) -> String {
        let days = PopopxCommerceLimits.channelTicketSeconds / 86_400
        return String(format: NSLocalizedString("🔒 [Channel subscription] %1$lld Compute Credits / %2$lld days", comment: "outgoing channel gate line"), payload.price, days) + "\n" + payload.wireString
    }
}
