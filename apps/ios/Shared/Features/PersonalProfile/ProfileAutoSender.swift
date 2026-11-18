//
//  ProfileAutoSender.swift
//  POPOPX (iOS)
//
//  【加密个人主页 · 模块四】双模智能感知与自动推送引擎。
//
//  这个文件只做一件事：把一份 `PopopxProfileManifest` 变成网络上真实的一条消息，并且说清楚
//  它最终走了哪条路、丢了什么。它不画界面、不读相册、不碰磁盘布局（那三件分别归
//  `ProfileBuilderView`、`ProfileStorageManager`、`PersonalProfileModel`）。
//
//  ### 两个触发源，一条发送链
//  1. **触发源 B（聊天内手动）**：`ProfileSendModeSheet` 的 `onSend` 回调 → `send(_:to:)`
//     （ProfileBuilderView.swift:818-836 交出 manifest，ComposeView 那一侧由 lead engineer 接线）。
//  2. **触发源 A（扫码自动）**：连接事件总线 → `handleContactConnected(contactId:)`
//     （现网点位 `Shared/Model/POPOPXAPI.swift:2640`-`:2665` 的 `case let .contactConnected(user, contact, _)`，
//     lead engineer 在那里加一行调用）。没有武装场景时这个函数第一个 `guard` 就返回，
//     不留日志、不建 Task、不读盘 —— 一次扫码都不该发生的事，不能在每一次建连时都发生一遍。
//
//  ### 为什么 `scene=personal_profile` 不在 URI 里（已定裁定，一句话版）
//  `apiAddContact` 铸出来的串归 Rust 核心，Swift 侧没有往邀请链接里追加查询键的先例
//  （`POPOPXAPI.swift:1039` 交回 `CreatedConnLink`，`APITypes.swift:185` 只做前缀替换）；
//  `popopxChatLink()` 会把 `popopx:/` 前缀改写成 `https://popopx.chat/`；
//  而离线那条 `PopopxOfflineBridge.forbiddenLinkCharacters`（:101）明令禁止 `$ \` " '`。
//  所以这个标记只能是**本机武装元数据**，由已经在场的 `contactConnected` 事件消费 ——
//  标记进 URI 要改协议，进本机状态只需要改这一个文件。
//
//  ### 送达方式不是用户选的，是链路决定的
//  `deliveryMode` 在草稿里恒为 `.fullMedia`（ProfileBuilderView.swift:22-24 那条裁定）。本文件在
//  发送那一刻问现网的决策器（`PopopxComposerRouting`，`Shared/Features/ChatRoom/PopopxInputBar.swift:325`）：
//  它说蓝牙是唯一通路时，才做 `.meshTextOnly` 降级并写 `omittedMediaCount`。自己数信号强度、
//  自己判 `NWPathMonitor`、自己猜邻居，都会在模块 5 之外多出第二张判定表 —— 那张表漂移一次，
//  界面上"下一条会走哪条通道"和真正走的那条就从此各说各话。
//
//  判定表对"带媒体的内容"的结论永远是 `.richContent`（PopopxInputBar.swift:359-:361），所以本文件
//  把 `hasAttachments` 如实报进去（一份挂着媒体原件的主页确实带不动），要降级时**先用
//  `manifest.textOnly` 投影过一遍再重问一次判定表**，mesh 分支发出去的是降级后的纯文字索引载荷本身。
//
//  `data=<base64url(JSON)>` 是**混淆**，不是加密：这一段清单自己不带任何密钥，保密的是传输 ——
//  公网那一条 SMP 端到端，蓝牙那一条厢语在 Noise 通道上跑，两者都不是这里能加的东西。
//
//  ### 媒体原件走的是普通 XFTP 附件
//  索引载荷（那行 `popopx://profile?…`）先到，图片/视频随后按 manifest 的顺序逐条发。每条附件的
//  文件名带上可关联回 profile 的标识（见 `attachmentFileName`）：**接收端靠这个文件名把已送达的
//  附件归到 `profileId` 下**。⚠️ 发送端自定义的文件名能否原样出现在接收端的 `CIFile.fileName` 上，
//  本文件未做端到端验证（依据只是 `fileName` 是网络上的一项且 `CIFile: Decodable`，
//  `POPOPXChat/ChatTypes.swift:5181`），详见交付报告。
//
//  ### 后台那一扇约 30 秒的窗
//  APNs 静默推送与 `beginBGTask`（`POPOPXAPI.swift:71`-`:91`）给到的续作窗口按系统惯例只有约 30 秒，
//  而且随时可能被 `expirationHandler` 提前掐掉。所以媒体队列每一发之前都问一次
//  `UIApplication.shared.backgroundTimeRemaining`，窗不够就停手，把已经送达的 mediaId 记进
//  `pendingMedia`（内存表，键 = profileId + contactId），下一次同一份主页再发给同一个人时跳过它们。
//  这张表**不落盘**：`ProfileStorageManager` 已经是这个特性唯一的存储路径，为一次没发完的队列再开
//  一条持久化通道，代价是"用户发过哪些媒体"在备份里留下一份索引副本。**重启即忘**，
//  这是本实现的真实边界，不假称自己有断点续传。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import POPOPXChat
import PopopxMeshKit
import SwiftUI
import UIKit

// MARK: - 发送结果

/// 一次发送最终成了什么。四个分支互斥：发了全媒体、发了降级文字、被规则拒了、链路自己失败了。
enum PopopxProfileSendOutcome: Hashable, Sendable {
    /// 公网 SMP 那一支：索引载荷交进了发送链路，媒体随后排队。
    /// - `indexSent`: 索引载荷那一条有没有被服务端收走（false = 一条都没出去，媒体自然也没发）。
    /// - `mediaQueued`: 这一次实际排出去几件媒体原件。**不含**上一轮后台窗口里已送达的件数
    ///   （那些被 `pendingMedia` 跳过，理由见文件头"30 秒窗"那一节）。
    case sentFullMedia(indexSent: Bool, mediaQueued: Int)
    /// 蓝牙 Mesh 那一支：只送了纯文字索引载荷。`omittedMediaCount` 取自降级后的清单。
    case sentMeshTextOnly(omittedMediaCount: Int)
    /// 规则层面的拒绝：内容没问题，但这次发送根本不该发生（会话不对、没保存主页、字节超预算…）。
    case refused(PopopxProfileSendRefusal)
    /// 链路层面的失败：该发的都尝试了，是网络或核心没接住。`reason` 是给用户看的一行中文。
    case failed(reason: String)
}

/// 拒绝的原因。每一条都能被界面直接念出来，所以它自带一句话；`nil` = 这一条不该由这里说。
enum PopopxProfileSendRefusal: Hashable, Sendable, CustomStringConvertible {
    /// 本机没有已保存的主页（扫码自动那条路唯一可能的拒绝）。
    case noSavedProfile
    /// 会话当前不允许发送（`ChatInfo.sendMsgEnabled` 为 false，ChatTypes.swift:2260）。
    case sendDisabled
    /// 目标不是 1:1 直聊联系人：群、频道、本机笔记、待接受的连接都不行。
    case notDirectContact
    /// 降级后的纯文字名片仍超出 Mesh 单条消息的字节预算。
    case payloadTooLarge(bytes: Int)
    /// 公网不通且蓝牙也带不走（`reason` 抄自现网决策器，不是本文件自己猜的）。
    case meshUnavailable(reason: String)
    /// 宿主侧还没准备好（本机没有可用身份 / 载荷空得反常）。
    case hostNotReady(reason: String)

    /// 一行中文，可直接进 `PopopxToast`。`nil` 表示这句话由别的界面负责说。
    var explanation: String? {
        switch self {
        case .noSavedProfile:
            return SenderCopy.refusalNoSavedProfile
        case .sendDisabled:
            // 宿主对这一条已经有原话（ComposeView.swift:1375-1376 弹的就是「会话未就绪」），
            // 同一次点击叠两层提示只会让用户以为是两件不同的事坏了。
            return nil
        case .notDirectContact:
            return SenderCopy.refusalNotDirectContact
        case let .payloadTooLarge(bytes):
            return String(
                format: SenderCopy.refusalTooLargeFormat,
                bytes,
                PopopxProfileMeshBudget.maximumMessageBytes
            )
        case let .meshUnavailable(reason):
            return String(format: SenderCopy.refusalMeshUnavailableFormat, reason)
        case let .hostNotReady(reason):
            return String(format: SenderCopy.refusalHostNotReadyFormat, reason)
        }
    }

    /// 日志用的稳定标识。永远不进界面：界面只读 `explanation`（这也是"不要 print 用户可见错误"
    /// 这条要求在本文件里的落点 —— 用户听得见的那几句全部走返回值，`logger` 里只有这一列标识）。
    var description: String {
        switch self {
        case .noSavedProfile: return "noSavedProfile"
        case .sendDisabled: return "sendDisabled"
        case .notDirectContact: return "notDirectContact"
        case let .payloadTooLarge(bytes): return "payloadTooLarge(bytes: \(bytes))"
        case let .meshUnavailable(reason): return "meshUnavailable(reason: \(reason))"
        case let .hostNotReady(reason): return "hostNotReady(reason: \(reason))"
        }
    }
}

// MARK: - 武装场景

/// 扫码建连之后要自动推送哪一档主页。它是**本机状态**，不是网络上的一部分（理由见文件头）。
struct PopopxArmedProfileScene: Hashable, Sendable {
    let mode: PopopxProfileSendMode
    /// 秒。`mode == .standard` 时恒为 0（协议那一侧的要求，PersonalProfileModel.swift:399-406）。
    let ttlSeconds: Int
    /// 这次武装什么时候作废。过期即清：不能留一个"随时可能因为一次毫不相干的建连而突然发出名片"的开关。
    let expiresAt: Date
}

// MARK: - 引擎

/// 单例线程安全的方式和这个特性的其它 UI 侧对象一致：`@MainActor final class`。
///
/// 主 actor 上**没有**任何阻塞 I/O：读原件全部 `await` 到 `ProfileStorageManager`（那是 actor），
/// 把字节变成待发附件那一次落盘放在 `Task.detached` 里（见 `stage(_:profileId:)`），
/// 网络那侧本来就全是 async。
@MainActor
final class ProfileAutoSender {
    static let shared = ProfileAutoSender()

    /// 武装场景的有效期。给 15 分钟：扫码 → 对方确认 → SMP 建连握手 → `contactConnected`，
    /// 慢链路走完这四步用不了这么久，但对方在确认页上停几分钟完全正常。超过这个时间还没建连，
    /// 说明那次扫码已经作废（用户退出、对方没按、网断了）—— 留着它只会在一次毫不相干的建连上
    /// 突然发出一份名片，那比"没发出去"严重得多。
    static let armingWindowSeconds: TimeInterval = 900

    /// 后台窗口低于这个秒数就不再开新的一发：一次 XFTP 上传 + SMP ACK 用不了 5 秒，但**开始**
    /// 一发然后在中途被系统掐掉，会让用户看到一条永远停在"传输中"的附件。
    static let backgroundResumeFloorSeconds: TimeInterval = 5

    /// 武装的档位。`nil` = 没武装，`handleContactConnected` 因此可以直接返回。
    private(set) var armedProfileScene: PopopxArmedProfileScene?

    private let store = ProfileStorageManager.shared

    /// 这次武装的时长是不是"绑给对方"的。见 `armProfileScene(mode:ttlSeconds:ttlIsBoundToContact:)`。
    private var armedTTLIsBoundToContact = false

    /// 上一轮（可能被后台窗口掐断的）媒体队列里**已经送达**的 mediaId。
    /// 键 = profileId + contactId：同一份主页发给另一个人必须重新发全套，跳过只发生在同一个人身上。
    private var pendingMedia: [MediaKey: Set<String>] = [:]

    /// 已送达记录的主键。独立类型而不是 `"profileId:contactId"` 拼串：拼串那一侧要自己保证
    /// 分隔符不会出现在成员里，而这里两个成员的类型已经把它们关死了。
    private struct MediaKey: Hashable {
        let profileId: String
        let contactId: Int64
    }

    private init() {}

    // MARK: 武装与取消

    /// 武装"扫码建连后自动推送"。标记存在本机而不是塞进邀请 URI —— 理由见文件头那一节
    /// （`apiAddContact` 无追加查询键的先例、`popopxChatLink` 会改写前缀、离线桥禁 `$ \` " '`）。
    ///
    /// - Parameter ttlIsBoundToContact: true = 这一次选的时长就是将来那个人拿到的时长；
    ///   false = 只带模式，时长沿用已保存主页自己的那一格。`PopopxArmedProfileScene` 的三格是
    ///   契约定死的（mode/ttlSeconds/expiresAt），所以这一格只能存在本类里，不进那个结构。
    func armProfileScene(mode: PopopxProfileSendMode, ttlSeconds: Int, ttlIsBoundToContact: Bool) {
        let effectiveTTL: Int
        switch mode {
        case .standard:
            effectiveTTL = 0
        case .ephemeral:
            // 越界的时长在这一格就收进协议允许的区间，而不是把 0 或 3000 交出去、
            // 让 `PopopxProfilePayload.make` 在一次用户看不见的自动发送里拒掉它
            // （PersonalProfileModel.swift:389-411）：武装那一刻没有人在等一个错误，夹住值是唯一
            // 有意义的处理。三档 UI 取值本来就落在区间内，这条 clamp 兜的是别处传进来的野值。
            effectiveTTL = min(
                max(ttlSeconds, PopopxProfilePayload.minimumTTLSeconds),
                PopopxProfilePayload.maximumTTLSeconds
            )
        }
        armedTTLIsBoundToContact = ttlIsBoundToContact
        armedProfileScene = PopopxArmedProfileScene(
            mode: mode,
            ttlSeconds: effectiveTTL,
            expiresAt: Date().addingTimeInterval(Self.armingWindowSeconds)
        )
        logger.notice("POPOPX profile: 已武装扫码自动推送（\(mode.rawValue, privacy: .public), ttl=\(effectiveTTL, privacy: .public), boundToContact=\(ttlIsBoundToContact, privacy: .public)）")
    }

    /// 取消武装。幂等：没武装时调用什么都不会发生。
    func cancelArmedProfileScene() {
        guard armedProfileScene != nil else { return }
        armedProfileScene = nil
        armedTTLIsBoundToContact = false
        logger.notice("POPOPX profile: 已取消扫码自动推送的武装")
    }

    // MARK: 触发源 A：扫码建连后自动推送

    /// 由连接事件总线调用（现网点位 `POPOPXAPI.swift:2640`-`:2665`）。
    ///
    /// 三个硬要求，都写在这几行里：
    /// 1. 没武装 → 第一个 `guard` 就返回：不读盘、不建 Task、不打日志。这条函数在**每一次**
    ///    建连上都会被调用，把它变成一次副作用的起点等于给所有普通加好友的动作加一次静默发名片的机会。
    /// 2. 武装过期 → 就地清掉再返回，不带着一个已经作废的档位继续走下去。
    /// 3. 找到会话才发。找不到会话时**保留**武装（等有效期那一格自己收）：`contactConnected` 里
    ///    `ChatModel.updateContact` 与这次调用在同一批主线程工作中，这次没排上未必下次也没有。
    ///
    /// 自动那一支的结果只进日志、不弹界面：这一条路径上没有用户在等答案，一次成功的推送本来就该
    /// 只是聊天流里多出一张名片；要给它加回执的位置在事件总线那一侧（lead engineer 接线处）。
    func handleContactConnected(contactId: Int64) async {
        guard let scene = armedProfileScene else { return }
        guard scene.expiresAt > Date() else {
            cancelArmedProfileScene()
            logger.notice("POPOPX profile: 武装已过期，自动推送取消")
            return
        }
        guard let chat = ChatModel.shared.getContactChat(contactId) else { return }
        guard let saved = await store.loadEditable() else {
            cancelArmedProfileScene()
            logger.notice("POPOPX profile: 本机没有已保存的主页，自动推送取消（\(PopopxProfileSendRefusal.noSavedProfile.description, privacy: .public)）")
            return
        }
        // 一次扫码一次推送：不管结果如何都不留武装。失败了也不重试 —— 重试的时机（下一次建连）
        // 根本不是同一次扫码的语义。
        cancelArmedProfileScene()
        let outcome = await send(applyScene(scene, to: saved), to: chat)
        switch outcome {
        case let .sentFullMedia(indexSent, mediaQueued):
            logger.notice("POPOPX profile: 扫码自动推送走公网（索引送达=\(indexSent, privacy: .public)，媒体 \(mediaQueued, privacy: .public) 件）")
        case let .sentMeshTextOnly(omitted):
            logger.notice("POPOPX profile: 扫码自动推送走厢语纯文字（省去 \(omitted, privacy: .public) 件媒体）")
        case let .refused(refusal):
            logger.error("POPOPX profile: 扫码自动推送被拒（\(refusal.description, privacy: .public)）")
        case let .failed(reason):
            logger.error("POPOPX profile: 扫码自动推送失败（\(reason, privacy: .public)）")
        }
    }

    /// 把武装档位盖到已保存的主页上。改的只有这一次发送的两格，草稿一动不动
    /// （`ProfileSendModeSheet` 同一条规矩，ProfileBuilderView.swift:813-816）。
    private func applyScene(_ scene: PopopxArmedProfileScene, to saved: PopopxProfileManifest) -> PopopxProfileManifest {
        var target = saved
        target.sendMode = scene.mode
        switch scene.mode {
        case .standard:
            target.ttlSeconds = 0
        case .ephemeral:
            if armedTTLIsBoundToContact {
                target.ttlSeconds = scene.ttlSeconds
            } else {
                // 不绑对方时沿用草稿自己那一格；草稿的 0（常驻档留下的）不能带进隐私档，
                // 否则 `make` 会以 `invalidTTL(0)` 拒掉整次发送。
                target.ttlSeconds = saved.ttlSeconds >= PopopxProfilePayload.minimumTTLSeconds
                    ? min(saved.ttlSeconds, PopopxProfilePayload.maximumTTLSeconds)
                    : PopopxProfilePayload.ttlOptions.isEmpty
                        ? PopopxProfilePayload.minimumTTLSeconds
                        : PopopxProfilePayload.ttlOptions[PopopxProfilePayload.ttlOptions.count / 2]
            }
        }
        return target
    }

    // MARK: 触发源 B：聊天内手动发送

    /// 把一份主页发给这个会话。`ProfileSendModeSheet` 交回来的 manifest 就是它的入参
    /// （`onSend: (PopopxProfileManifest) -> Void`，ProfileBuilderView.swift:822）。
    func send(_ manifest: PopopxProfileManifest, to chat: Chat) async -> PopopxProfileSendOutcome {
        // 会话形状：只有 1:1 直聊联系人在服务端有队列可写，也没有别的地址能把一条消息递过去。
        guard let contactId = chat.chatInfo.contact?.contactId else {
            return .refused(.notDirectContact)
        }
        guard chat.chatInfo.sendMsgEnabled else {
            return .refused(.sendDisabled)
        }
        guard ChatModel.shared.currentUser != nil else {
            return .refused(.hostNotReady(reason: SenderCopy.hostNoActiveUser))
        }

        // 两份载荷一次铸好：公网那份带全媒体，蓝牙那份是 `textOnly` 投影。两者都过 `make` 那道门
        // （先验后规范化，PersonalProfileModel.swift:389-411），所以 `delivery=mesh` 那一条
        // 落到网络上时 `omittedMediaCount` 与块表一定自洽。
        let fullPayload: PopopxProfilePayload
        let meshPayload: PopopxProfilePayload
        do {
            fullPayload = try PopopxProfilePayload.make(manifest)
            meshPayload = try PopopxProfilePayload.make(manifest.textOnly)
        } catch let failure as PopopxProfileError {
            // 载荷层的原话已经是中文、已经带上具体数字（PersonalProfileModel.swift:329-350），
            // 这里不另造第二套句子。
            return .failed(reason: failure.reasonText)
        } catch let failure as PopopxProfileMediaError {
            return .failed(reason: failure.reasonText)
        } catch {
            return .failed(reason: String(format: SenderCopy.unexpectedFormat, error.localizedDescription))
        }

        switch await route(contactId: contactId, fullPayload: fullPayload, meshPayload: meshPayload) {
        case let .viaMesh(message, omittedMediaCount):
            return await sendViaMesh(message, omittedMediaCount: omittedMediaCount)
        case let .viaSMP(eligibility):
            return await sendViaSMP(fullPayload, to: chat, contactId: contactId, eligibility: eligibility)
        case let .refused(refusal):
            return .refused(refusal)
        }
    }

    // MARK: 路由决策

    /// 本文件对链路的全部判断。两个分支都真实存在，而判定全部借现网那张表。
    private enum RouteChoice {
        /// 公网 SMP：索引载荷 + 媒体原件。快照只用于失败时说清是哪一条规则把蓝牙挡在门外的。
        case viaSMP(PopopxMeshEligibility)
        /// 蓝牙 Mesh：交给路由器的那条消息，文本必须是**降级后的纯文字索引载荷**
        /// （`meshPayload.messageContent`，`delivery=mesh`），不是原始那份。
        case viaMesh(PopopxOutboundMessage, omittedMediaCount: Int)
        /// 两条路都不通，或者超预算。
        case refused(PopopxProfileSendRefusal)
    }

    private func route(
        contactId: Int64,
        fullPayload: PopopxProfilePayload,
        meshPayload: PopopxProfilePayload
    ) async -> RouteChoice {
        let eligibility = await PopopxInputBarModel.resolveFromRuntime(contactId: contactId)
        var context = PopopxComposerContext.directContact(contactId)
        // 把"这份主页挂着媒体原件"如实报给判定表：带媒体的内容不该交给蓝牙
        // （PopopxInputBar.swift:359-:361 那条 `.richContent`），于是第一次 dispatch 的答复
        // 只反映"这份完整的名片能不能走蓝牙"，答案对带媒体的那份永远是"不能"。
        context.hasAttachments = fullPayload.manifest.mediaCount > 0

        switch PopopxComposerRouting.dispatch(
            text: fullPayload.messageContent,
            context: context,
            eligibility: eligibility,
            ttlSeconds: nil
        ) {
        case let .routeViaMesh(message):
            // 一份只有文字的主页，判定表直接放行蓝牙。发出去仍然要用降级投影：它唯一的变化是
            // `delivery=mesh` 那一格，而阅读器要靠这一格画出厢语那条青绿横幅。判定表铸好的那条
            // 消息带着原始文本，这里换掉文本、留下 id 与地址 —— 重试幂等靠的就是那个 id。
            return meshChoice(eligibility: eligibility, from: message, payload: meshPayload)

        case .hostShouldSend:
            // 只有"公网确实断了"（`false`；`nil` = NWPathMonitor 还没报过，不猜成在线也不猜成断）
            // 才值得降级重问一次。有网或状态未知都交回宿主那条正常链路（SMP + XFTP 媒体原件）。
            guard eligibility.networkConnected == false else {
                return .viaSMP(eligibility)
            }
            var degradedContext = PopopxComposerContext.directContact(contactId)
            degradedContext.hasAttachments = false
            switch PopopxComposerRouting.dispatch(
                text: meshPayload.messageContent,
                context: degradedContext,
                eligibility: eligibility,
                ttlSeconds: nil
            ) {
            case let .routeViaMesh(message):
                return meshChoice(eligibility: eligibility, from: message, payload: meshPayload)
            case let .hostShouldSend(meshRefusal):
                // 判定表在降级之后仍然把消息退回宿主 = 蓝牙也带不走。这时**不**假装 SMP 还能发：
                // 断网状态下 `apiSendMessages` 只会以一次超时失败收尾，说清原因比试一次有用。
                return .refused(.meshUnavailable(reason: Self.meshBlockText(meshRefusal)))
            case .ignoreEmptyDraft:
                return .refused(.hostNotReady(reason: SenderCopy.hostEmptyPayload))
            }

        case .ignoreEmptyDraft:
            // `messageContent` 恒为非空（degradeLine 至少带 "👤 [加密个人主页]"，
            // PersonalProfileModel.swift:441-:443）。走到这里只可能是载荷契约被改坏了，
            // 按"宿主没准备好"报出去，不静默。
            return .refused(.hostNotReady(reason: SenderCopy.hostEmptyPayload))
        }
    }

    /// 把判定表放行的一份降级载荷收进 mesh 分支：先量字节，超预算就在这里拒掉，
    /// 不把一条注定刷爆中继的名片交出去。
    ///
    /// 交给路由器的是判定表铸好的那条消息的**同一 id / 同一地址**，只有文本换成降级后的载荷 ——
    /// id 是路由器去重与重试幂等的唯一依据（`PopopxMessageRouter.swift:627-:640`），换一个 id
    /// 等于让对方收到两张一模一样的名片。
    private func meshChoice(
        eligibility: PopopxMeshEligibility,
        from message: PopopxOutboundMessage,
        payload: PopopxProfilePayload
    ) -> RouteChoice {
        guard eligibility.fuseOn else {
            // 熔断关着时绝不走 mesh。判定表在 `fuseOn == false` 时已经退回宿主，所以这一条
            // 正常到不了；留着它是因为"fuse 关了不许走蓝牙"是硬要求，该在代码里有一道看得见的门，
            // 而不是只在注释里。
            return .refused(.meshUnavailable(reason: SenderCopy.meshFuseOff))
        }
        let text = payload.messageContent
        let bytes = text.utf8.count
        guard bytes <= PopopxProfileMeshBudget.maximumMessageBytes else {
            return .refused(.payloadTooLarge(bytes: bytes))
        }
        return .viaMesh(
            PopopxOutboundMessage(messageId: message.messageId, target: message.target, text: text, sentAt: message.sentAt),
            omittedMediaCount: payload.manifest.omittedMediaCount
        )
    }

    /// 降级之后仍然退回宿主时，那一条理由怎么说给用户听。
    ///
    /// 判定表的 `explanation`（PopopxInputBar.swift:183-:192）故意只给"内容本身不该走蓝牙"那几条
    /// 附一句人话，网格事实那几条返回 nil。这里把 nil 的那几条补全，是因为**断网 + 蓝牙带不走**
    /// 是本文件独有的场景：宿主正常发送时用户不会关心总闸开没开，而在这里用户必须知道是哪一格
    /// 拦住了这次推送，否则他只会看到一张没有动静的名片。
    private static func meshBlockText(_ reason: PopopxHostSendReason) -> String {
        switch reason {
        case .meshFuseOff: return SenderCopy.meshFuseOff
        case .bindingUnknown: return SenderCopy.meshBindingUnknown
        case .contactNotBoundToMesh: return SenderCopy.meshNotBound
        case .radioUnavailable: return SenderCopy.meshRadioOff
        case .peerOutOfRange: return SenderCopy.meshPeerOutOfRange
        case .notDirectContact: return SenderCopy.meshNotDirectContact
        default: return reason.explanation ?? SenderCopy.meshReasonUnknown
        }
    }

    // MARK: 分支 B：蓝牙 Mesh（厢语）

    private func sendViaMesh(
        _ message: PopopxOutboundMessage,
        omittedMediaCount: Int
    ) async -> PopopxProfileSendOutcome {
        let bytes = message.text.utf8.count
        logger.notice("POPOPX profile: 交给厢语蓝牙（\(bytes, privacy: .public) 字节 ≈ \(PopopxProfileMeshBudget.fragmentCount(forBytes: bytes), privacy: .public) 个分片，省去 \(omittedMediaCount, privacy: .public) 件媒体）")
        // 不抛、不返回 nil：`PopopxMessageRouter.send(_:)` 交回一个带结论的 `PopopxRoutedMessage`
        // （PopopxMessageRouter.swift:626-:686），全部可能都在这一个返回值里。
        let routed = await PopopxMeshRuntime.shared.router.send(message)
        switch routed.outcome {
        case let .smpAcknowledged(contactId):
            // 路由器自己选了公网（有网时它的策略就是 SMP 优先，`PopopxMessageRouter.swift:650`-:657）。
            // 交出去的那一条是纯文字投影，媒体原件一件都没排队 —— 按"只送了文字"报，不按
            // "全媒体已发"报。⚠️ 结果枚举（契约定死的四支）里没有"文字走公网"这一支，通道这里
            // 记在日志、用户能读到的那一支只说"文字出去了"，细节见交付报告。
            logger.notice("POPOPX profile: 判定放行蓝牙，路由器仍按 SMP 优先送达（contact :\(contactId, privacy: .public)；媒体未排队）")
            return .sentMeshTextOnly(omittedMediaCount: omittedMediaCount)
        case let .smpUnacknowledgedMeshParallel(contactId, peerMeshPublicKeyHex):
            logger.notice("POPOPX profile: 公网未在时限内 ACK，蓝牙并发补发（contact :\(contactId, privacy: .public) / 邻居 \(peerMeshPublicKeyHex.prefix(8), privacy: .public)）")
            return .sentMeshTextOnly(omittedMediaCount: omittedMediaCount)
        case let .smpUnacknowledgedNoMesh(contactId):
            // 公网未确认、又没有第二条腿。这条尝试还在路由器手里飞行，之后可能进兜底队列。
            logger.error("POPOPX profile: 公网未 ACK 且无蓝牙可补（contact :\(contactId, privacy: .public)）")
            return .failed(reason: SenderCopy.smpUnacknowledged)
        case let .meshSent(peerMeshPublicKeyHex):
            logger.notice("POPOPX profile: 厢语已送达（邻居 \(peerMeshPublicKeyHex.prefix(8), privacy: .public)）")
            return .sentMeshTextOnly(omittedMediaCount: omittedMediaCount)
        case let .queuedOffline(reason):
            // 进了离线兜底队列，等邻居重新出现时由路由器补发同一 id。按"已送达纯文字"报出，
            // 但队列那一侧才是真相 —— 已在交付说明里如实标为口径弱点。
            logger.notice("POPOPX profile: 两条路都不通，名片进了厢语兜底队列（\(reason.rawValue, privacy: .public)）")
            return .sentMeshTextOnly(omittedMediaCount: omittedMediaCount)
        case .refusedUnboundStranger:
            return .refused(.meshUnavailable(reason: SenderCopy.meshUnboundStranger))
        case let .duplicate(messageId):
            return .failed(reason: String(format: SenderCopy.failedDuplicateFormat, messageId))
        case let .nothingToReroute(messageId):
            return .failed(reason: String(format: SenderCopy.failedNothingToRerouteFormat, messageId))
        }
    }

    // MARK: 分支 A：公网 SMP

    private func sendViaSMP(
        _ payload: PopopxProfilePayload,
        to chat: Chat,
        contactId: Int64,
        eligibility: PopopxMeshEligibility
    ) async -> PopopxProfileSendOutcome {
        // 索引载荷：形状照 `popopxSendPlainViaSMP`（ComposeView.swift:1492-1507）——
        // `apiSendMessages` + 把返回的 ChatItem 交回时间线。`apiSendMessages` 自己不抛错、
        // 自己弹网络错误框（POPOPXAPI.swift:577-:613），所以这里不叠第二层提示。
        //
        // `ttl` 一律传 nil：主页那一档"阅后即焚"是**收件方屏幕上**的销毁计时，不是 SMP 服务器上
        // 消息的存活时间。把 300 塞进 `ttl` 会让索引消息从服务器消失，而"收件方读没读过"这件事
        // 归 `ProfileStorageManager.readState` 那把钟管，两者混成一个参数就是两份语义互相覆盖。
        let indexItems = await apiSendMessages(
            type: chat.chatInfo.chatType,
            id: chat.chatInfo.apiId,
            scope: chat.chatInfo.groupChatScope(),
            sendAsGroup: chat.chatInfo.sendAsGroup,
            live: false,
            ttl: nil,
            sign: false,
            composedMessages: [ComposedMessage(msgContent: .text(payload.messageContent))]
        )
        guard let indexItems, !indexItems.isEmpty else {
            logger.error("POPOPX profile: 索引载荷没进公网（contact :\(contactId, privacy: .public)，厢语预判=\(String(describing: eligibility.prediction), privacy: .public)）")
            return .failed(reason: SenderCopy.smpIndexFailed)
        }
        for item in indexItems {
            ChatModel.shared.addChatItem(chat.chatInfo, item)
        }
        let queued = await pushMedia(payload.manifest, to: chat, contactId: contactId)
        return .sentFullMedia(indexSent: true, mediaQueued: queued)
    }

    /// 按 manifest 的顺序逐件推送媒体原件。返回这一次实际排出去的件数。
    private func pushMedia(_ manifest: PopopxProfileManifest, to chat: Chat, contactId: Int64) async -> Int {
        let media = manifest.blocks.compactMap { $0.media }
        guard !media.isEmpty else { return 0 }
        let key = MediaKey(profileId: manifest.profileId, contactId: contactId)
        var delivered = pendingMedia[key] ?? []
        var queued = 0
        // 后台保活：整段队列包在 `beginBGTask` 里（POPOPXAPI.swift:71-:91），`defer` 保证
        // 无论走到哪一支都会把这次后台任务交回去 —— 漏一次 endTask 等于把 app 的后台额度长期占住。
        let endTask = beginBGTask(nil)
        defer { endTask() }

        for item in media {
            guard !delivered.contains(item.mediaId) else { continue }
            if UIApplication.shared.backgroundTimeRemaining < Self.backgroundResumeFloorSeconds {
                pendingMedia[key] = delivered
                logger.error("POPOPX profile: 后台窗口用完，媒体队列停在已送达 \(delivered.count, privacy: .public) 件之后（profile \(manifest.profileId.prefix(8), privacy: .public)）；这张表不落盘，重启后不认得这些件")
                return queued
            }
            guard let staged = await stage(item, profileId: manifest.profileId) else { continue }
            let items = await apiSendMessages(
                type: chat.chatInfo.chatType,
                id: chat.chatInfo.apiId,
                scope: chat.chatInfo.groupChatScope(),
                sendAsGroup: chat.chatInfo.sendAsGroup,
                live: false,
                ttl: nil,
                sign: false,
                composedMessages: [ComposedMessage(
                    fileSource: staged.file,
                    msgContent: .file(attachmentLine(profileId: manifest.profileId, media: item))
                )]
            )
            guard let items, !items.isEmpty else {
                // `apiSendMessages` 已经把这一次的失败弹给用户了；这一件不进 delivered，
                // 于是同一份主页下次发送时还会再试一次。
                logger.error("POPOPX profile: 媒体原件没发出去（media \(item.mediaId.prefix(8), privacy: .public)）")
                continue
            }
            for chatItem in items {
                ChatModel.shared.addChatItem(chat.chatInfo, chatItem)
            }
            delivered.insert(item.mediaId)
            queued += 1
        }
        // 这一份主页的全部媒体都在对方手里了就把这条记录抹掉：留着会让"再发一次"变成"一件都没发"。
        if delivered.isSuperset(of: Set(media.map { $0.mediaId })) {
            pendingMedia[key] = nil
        } else {
            pendingMedia[key] = delivered
        }
        return queued
    }

    // MARK: 媒体 → 待发附件

    /// 一件媒体在本机的原件，和它作为待发附件的样子。
    private struct StagedMedia {
        let file: CryptoFile
    }

    /// 把沙盒里的主页原件变成一条待发附件。**这一段是整条链上唯一的重 I/O**：读最多 15 MB 的字节
    /// 并写进 XFTP 的暂存目录，所以整块放在 `Task.detached` 里，主 actor 只 `await`。
    ///
    /// 暂存用的是 app 已有的 `saveFile(_:fileName:encrypted:)`（`POPOPXChat/FileUtils.swift:271`）——
    /// 那正是 `saveImage`/`saveFileFromURL` 底下的同一个函数（ImageUtils.swift:97-:104、:218-:241），
    /// 所以主页没有新增第二条存储路径（红线：这个特性的原件存储只有 `ProfileStorageManager` 那一处，
    /// 这里写的是发送侧的临时附件区，和用户在聊天里发一张图完全同一条路）。
    private func stage(_ media: PopopxProfileMedia, profileId: String) async -> StagedMedia? {
        let load = await store.loadMedia(media, profileId: profileId)
        let url: URL
        switch load {
        case let .loaded(loaded):
            url = loaded
        case let .missing(mediaId):
            logger.error("POPOPX profile: 本机没有这件媒体的原件（media \(mediaId.prefix(8), privacy: .public)），已跳过")
            return nil
        case let .unreadable(mediaId, reason):
            logger.error("POPOPX profile: 本机原件读不得（media \(mediaId.prefix(8), privacy: .public)：\(reason, privacy: .public)），已跳过")
            return nil
        }
        let wireName = Self.attachmentFileName(profileId: profileId, media: media, url: url)
        let encrypted = privacyEncryptLocalFilesGroupDefault.get()
        let staged: CryptoFile? = await Task.detached(priority: .utility) { () -> CryptoFile? in
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return saveFile(data, wireName, encrypted: encrypted)
        }.value
        guard let staged else {
            logger.error("POPOPX profile: 原件没能暂存成待发附件（media \(media.mediaId.prefix(8), privacy: .public)）")
            return nil
        }
        return StagedMedia(file: staged)
    }

    /// 附件文件名：`popopx-profile-<profileId>-<mediaId>.<ext>`。
    ///
    /// **接收端靠这个文件名把已送达的附件归到 `profileId` 下** —— `data=` 那段清单里只有编排骨架和
    /// 字节数，媒体原件是普通 XFTP 附件，两者在网络上再无别的连接点。扩展名取自本机路径
    /// （`ProfileStorageManager.mediaURL` 只可能给出 `jpg`/`mp4`，ProfileStorageManager.swift:167-:172、:373-:376），
    /// 于是这里既不必复制那张扩展名表，也不可能拼出一个对端没见过的后缀。
    ///
    /// `profileId`/`mediaId` 都是 `UUID().uuidString.lowercased()`（PersonalProfileModel.swift:116-:118、:177），
    /// 字符集是 `[a-z0-9-]`，直接进文件名是安全的。⚠️ 与 `saveFileFromURL` 那条不同，这里不经过
    /// `uniqueCombine`：撞名会原地覆盖同名附件，而 UUID 级的 mediaId 决定它撞不上；
    /// 真撞上了（同一份主页重发）覆盖的也是同样的字节。
    static func attachmentFileName(profileId: String, media: PopopxProfileMedia, url: URL) -> String {
        "popopx-profile-\(profileId)-\(media.mediaId).\(url.pathExtension)"
    }

    /// 附件那一条消息的可见文本。恒为一行（会话列表与通知横幅取的就是这一行），并且把关联标识
    /// **也**写进文本：万一发送端自定义的文件名在对端被改写，这一行仍然能把附件认回它的主页。
    private func attachmentLine(profileId: String, media: PopopxProfileMedia) -> String {
        let head = "👤 [加密个人主页 · 附件] profile=\(profileId) media=\(media.mediaId)"
        guard let caption = media.caption else { return head }
        let oneLine = caption.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return oneLine.isEmpty ? head : "\(head) · \(oneLine)"
    }
}

// MARK: - Mesh 字节预算

/// 蓝牙那条路的字节上限，全部取自现网真实常量，本文件不新造任何一个数字。
///
/// - `PopopxProximityFrame.maxWireBytes = 8_192`（`PopopxProximityEngine.swift:110`）是 PopopxMeshKit
///   里唯一公开的"一条载荷进核心之前能有多大"的上限。⚠️ 它写在**近场交换帧**的定义上，BLE 中继
///   那一条并没有公开的等价常量（`PopopxMeshEngine` 会按链路的 `usablePayloadBytes` 自动分片，
///   PopopxMeshEngine.swift:446-:455）。这里是**借用**，不是"BLE 真有这个硬上限"。借的理由：
///   一份 6 KB 的清单 JSON 会被切成十几个 469 字节的分片，在 TTL 7 的洪泛里等于给自己制造一次
///   广播风暴，而名片的文字量本来用不到那个量级 —— 超了就该让用户删字，而不是让中继替他扛。
/// - `fragmentSize = 469` / `maxMTU = 512`（`PopopxMeshConfig.swift:27`、`:29`）只用来把"这份名片
///   会切成几片"算出来写进日志，不参与拒绝判定。
enum PopopxProfileMeshBudget {
    /// 单条 mesh 名片消息（含给人看的那一行）允许的 UTF-8 字节上限。
    static let maximumMessageBytes = PopopxProximityFrame.maxWireBytes

    /// 按真实分片尺寸估算片数。只用于日志，不用于判定：判定只看 `maximumMessageBytes`。
    static func fragmentCount(forBytes bytes: Int) -> Int {
        let fragment = PopopxMeshConfig.default.fragmentSize
        guard fragment > 0 else { return 1 }
        return (bytes + fragment - 1) / fragment
    }
}

// MARK: - 文案

/// 本文件里所有会被用户听见的中文，只在这一处出现一次（`ProfileBuilderView.swift:1283` 那条
/// `private enum Copy` 的规矩；这里因为要跨类型边界被 `PopopxProfileSendRefusal.explanation` 读，
/// 所以是文件内可见的 `enum` 而不是某个类型里的私有成员）。
private enum SenderCopy {
    static let refusalNoSavedProfile = "本机还没有保存过的主页。先在「我 → 加密个人主页」里做好并保存，再扫码或发送。"
    static let refusalNotDirectContact = "加密个人主页只能发给 1 对 1 的联系人。"
    static let refusalTooLargeFormat = "降级后的纯文字名片有 %d 字节，超出蓝牙 Mesh 单条 %d 字节的上限，请删减文字后重试。"
    static let refusalMeshUnavailableFormat = "当前没有公网，厢语蓝牙也带不走这份名片：%@"
    static let refusalHostNotReadyFormat = "暂时发不了这份主页：%@"
    static let hostNoActiveUser = "本机还没有可用的身份"
    static let hostEmptyPayload = "这份主页的内容是空的"
    static let smpIndexFailed = "名片没有进入公网，请检查网络后重试。"
    static let smpUnacknowledged = "名片已交进发送队列，但公网没有在时限内确认收走；网络恢复后厢语会自动补发。"
    static let meshFuseOff = "厢语总闸是关着的"
    static let meshBindingUnknown = "厢语绑定表还没读完"
    static let meshNotBound = "这个联系人还没有厢语绑定"
    static let meshRadioOff = "本机蓝牙当前不可用"
    static let meshPeerOutOfRange = "对方的设备太久没出现在厢语里"
    static let meshNotDirectContact = "这个会话不是 1 对 1 直聊"
    static let meshUnboundStranger = "对方还没有和你的设备交换过厢语名片，先靠近一次或走公网"
    static let meshReasonUnknown = "蓝牙当前不可用"
    static let failedDuplicateFormat = "这张名片（%@）已经在中继队列里，这一次没有重复提交。"
    static let failedNothingToRerouteFormat = "这张名片（%@）的投递记录已不在路由器里，请重新发送一次。"
    static let unexpectedFormat = "这份主页发不出去：%@"
}
