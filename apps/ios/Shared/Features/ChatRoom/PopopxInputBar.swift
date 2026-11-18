//
//  PopopxInputBar.swift
//  POPOPX (iOS)
//
//  【第五阶段 · 会话输入条】磨砂玻璃底的弹起式输入条 + "智能路由"接缝。
//
//  这是一个**宿主所有（host-owned）**的图层，不是 `ComposeView` 的替代品。今天会话页把 composer
//  挂在 `Shared/Views/Chat/ChatView.swift:237`-`:245`，实传 7 个入参（`chat`、`im`、
//  `$composeState`、`$showCommandsMenu`、`$keyboardVisible`、`$keyboardHiddenDate`、`$selectedRange`），
//  而 `ComposeView.swift` 有 2253 行、`Shared/Views/Chat/ComposeMessage/` 目录内共 13 个文件；
//  真正的文本框是 `NativeTextEditor`（`SendMessageView.swift:67`，结构体在 :16，由
//  `ComposeView.swift:1095 sendMessageView(_:placeholder:sendToConnect:)` 造出来）。多选态下会话页
//  还会把它换成 `SelectedItemsBottomToolbar`（`ChatView.swift:247`）。所以本文件：
//  ① 不 import 也不改写 `ComposeState`，只吃宿主折算进来的值；② 不改任何既有 initializer；
//  ③ 所有副作用一律走闭包递出去。**"替换还是并挂"由人来裁定，本条两边都能接。**
//
//  ── 宿主必须接的五根线 ────────────────────────────────────────────────────────────
//  1. `text`：宿主自己的草稿绑定（`composeState.message` 也行）。
//  2. `context`：把 `ComposeState` 的九个前提折算成 `PopopxComposerContext`（见该结构体的字段注释，
//     对应 `ComposeView.swift:1806` mentions、`:1811`-`:1827` contextItem 四支、`:1829`-`:1834` preview 三支）。
//  3. `ttlSeconds` / `onTTLChange`：阅后即焚。**真值在宿主那里**，本条只读只报，不存第二份。
//  4. `onSend`：拿到 `PopopxComposerSend`，其中 `dispatch` 已经分好支：
//     · `.routeViaMesh(message)` → 宿主做 `await PopopxMeshRuntime.shared.router.send(message)`
//       （`PopopxMeshKit/…/Router/PopopxMessageRouter.swift:627`），返回的 `PopopxRoutedMessage`
//       （:241）交给模块 7 的时间线；本条**自己不发**，也不碰 `router.start()`/`stop()`——那是保险丝的
//       事（`Shared/Model/POPOPXAPI.swift:3752` 把 router 注册进 killSwitch）。
//     · `.hostShouldSend(reason)` → 宿主走原链路（`ComposeView.swift:1793 sendMessage(ttl:sign:)` →
//       `:1723 sendMessageAsync` → `:1752 send(.text…)` → `:1931`/`:1940 send(_ msgs:)` →
//       `apiSendMessages`（`POPOPXAPI.swift:577`）→ `processSendMessageCmd`（:582）→ `chatApiSendCmd`）。
//  5. 键盘避让、safe area、`keyboardVisible` 归宿主：本条只画自己那一条，不读屏幕常量。
//
//  ── 为什么必须存在 `hostShouldSend` 这一支（TTL / sign 限制，红线级事实）────────────
//  模块 5 的公网腿**就是 app 自己的发送**：`PopopxSMPSendRequest`（`PopopxMessageRouter.swift:36`）只有
//  `messageId / contactId / text / sentAt` 四个字段，app 侧的实现把 `.text(request.text)` 组成
//  `ComposedMessage` 后调 `apiSendMessages(type: .direct, id: contactId, …)` 并自己 `addChatItem`
//  （`POPOPXAPI.swift:3461`-`:3480`）。所以路由一条直聊纯文本**不会分叉出第二条网线**；
//  但那条腿上**没有 `ttl` 也没有 `sign`**（`apiSendMessages` 的这两个入参在 `POPOPXAPI.swift:577`），
//  且只支持 `.direct` 的 contactId。于是"全部交给路由"会静默丢掉阅后即焚、签名、群组 scope、引用、
//  附件、@提及与 live 消息。这个限制因此被写进判定表，而不是藏在视图代码里。
//
//  ── 判定表（`PopopxComposerRouting.dispatch`，纯函数，可单测）───────────────────────
//  | 输入 | 结论 | 为什么 |
//  |---|---|---|
//  | 草稿全空白、且没挂附件 | `.ignoreEmptyDraft` | 既不发也不交回，宿主不会被叫两次；挂了附件的空文本框照发（`.richContent` → 交回宿主） |
//  | `ttlSeconds != nil` | `.hostShouldSend(.timedMessage)` | 路由腿不带 ttl，阅后即焚会被丢掉 |
//  | `requiresSignature` | `.hostShouldSend(.signedMessage)` | 同上，腿上没有 sign |
//  | 非直聊联系人（群 / 本机笔记 / 待接受 / 无效 / 非 active） | `.hostShouldSend(.notDirectContact)` | `PopopxRouteTarget`（:99）只有 `.contactId` 能被公网写到；群的 scope/sendAsGroup 在请求体里没有位置 |
//  | 引用 / 编辑 / 转发 / 举报 | `.hostShouldSend(.quotedOrEditing)` | 这些都不在 `.text` 那一条消息里 |
//  | 附件 / 链接预览 / @提及 / live | `.hostShouldSend(.richContent)` | 同上 |
//  | 厢语总闸关 | `.hostShouldSend(.meshFuseOff)` | 整条网格是关的，不该把消息交给网格的路由器 |
//  | 绑定表还没读完 | `.hostShouldSend(.bindingUnknown)` | 不替用户猜通道 |
//  | 没有厢语绑定 | `.hostShouldSend(.contactNotBoundToMesh)` | 路由只会得出 `.notBound` 再回到 SMP，白多一跳 |
//  | 射频不可用 | `.hostShouldSend(.radioUnavailable)` | 同上：`.radioUnavailable` 时没有 mesh 可发 |
//  | 邻居超窗 | `.hostShouldSend(.peerOutOfRange)` | 唯一能带走它的还是宿主那条 SMP |
//  | 以上全不成立：纯文本 + 直聊 + 已绑定 + 射频开 + 邻居可达 | `.routeViaMesh(message)` | 这一刻 mesh 真能带走，而只有模块 5 知道"公网 3 秒不 ACK 就并发补发""送达失败按原 id 重路由""两条都不通进离线兜底队列" |
//
//  ── 通道配色（`Docs/popopx-brand-spec.md` §1.1，一个控件里靛紫与青绿永不对等并存）──────
//  `PopopxComposerChannel` 三取一：`.smp` = `brand` + `lock.shield.fill`；`.mesh` = `mesh` 底 +
//  `onMesh` 字（发丝级青绿做字要用 `meshInk`）；`.undetermined` = `labelSecondary` 灰且**不给图标**。
//  灰 `clock` 只表示厢语中继积压（`待中继 N`，数字来自 `router.pendingMessageCount`，
//  `PopopxMessageRouter.swift:860`）。阅后即焚在这里只有字、没有图形：会话气泡那侧已经占了
//  `timer` 这个符号（`Shared/Views/Chat/ChatItem/CIMetaView.swift:135`），本条不抢它第二份语义。
//  绿色不在这个条上出现——它是一次性的回执色。
//  「+」面板里唯一出现的强调色是靛紫的"选中态"（沿用 `PopopxCheckbox` 自己的 tint），面板内不出现青绿。
//
//  ── 读网格事实的时机（不许逐键、逐行 await）────────────────────────────────────────
//  `PopopxInputBarModel.refresh(contactId:)` 一次批量读四样：`IdentityMappingStore
//  .meshPublicKeyHexes(forContactId:)`（`Identity/IdentityMappingStore.swift:182`）、
//  `PopopxBluetoothHealthJudge` 的 `radioState` 与 `isPeerReachable`（`PopopxMessageRouter.swift:388`，
//  判定的先后次序与模块 5 自己的 `predictBluetooth`（:1051-:1060）逐行对齐，超时同取
//  `PopopxMeshConfig.default.peerReachabilityTimeout`），以及 `NetworkStateMonitor.shared.currentPath()`
//  （`Router/NetworkStateMonitor.swift:362`，nil = 未报，**不猜成"在线"**）。结果缓存成
//  `PopopxMeshEligibility` 值；刷新时机 = 打开会话 + 总闸翻转 + 5 秒一跳（跳数从已观察的
//  `PopopxMeshStateSource.state` 同步读，不产生 hop）。
//
//  设计取值全部来自 Shared/Theme/PopopxTheme.swift，控件来自 Shared/Components/；本文件没有裸色值、
//  没有 AppTheme 样式、没有自造按钮样式，也没有裸 `UIScreen` 常量。
//
//  ⚠️ Xcode 工程集成：本文件需人工拖入 POPOPX (iOS) target（铁律禁止脚本改 project.pbxproj）。
//

import Combine
import SwiftUI
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - 宿主折算进来的发送前提

/// 「这一条将要发出去的东西」除文本以外的全部前提。
///
/// 故意不做成 `ComposeState` 的包装：那个结构体（`ComposeView.swift:47`）带着 `parsedMessage`、
/// `preview`、`contextItem`、`voiceMessageRecordingState` 等一整套只有旧 composer 才懂的东西，
/// 本条只想知道"能不能交给模块 5"。
struct PopopxComposerContext: Hashable {
    /// 直聊联系人的 SMP 地址。`nil` = 这条会话没有 contactId（群 / 本机笔记 / 待接受的联系 / 无效数据）。
    var contactId: Int64?
    /// `ChatInfo.direct(contact:)` 且联系人 `active`（`POPOPXChat/ChatTypes.swift:1995`）——
    /// 只有这种会话在服务端有队列可写。
    var isDirectContact = false
    /// 草稿挂了附件（图片 / 文件 / 语音 / 多媒体）。
    var hasAttachments = false
    /// `composeState.preview != .noPreview`（`ComposeView.swift:1829`-`:1834`）：链接预览也是消息体的一部分。
    var hasLinkPreview = false
    /// `contextItem` 是 quoted / editing / forwarding / reported 四支之一（`ComposeView.swift:1811`-`:1827`）。
    var carriesContextItem = false
    /// `composeState.memberMentions` 非空（`ComposeView.swift:1806`）。
    var hasMentions = false
    /// 即时消息（live），`ComposeView.swift:1807`-`:1809`。
    var isLiveMessage = false
    /// 需要签名，`ComposeView.swift:1793` 的 `send(sign:)`。
    var requiresSignature = false

    /// 最常用的一支：一个 active 的直聊联系人，纯文本，无 TTL、无签名。
    static func directContact(_ contactId: Int64) -> PopopxComposerContext {
        var context = PopopxComposerContext()
        context.contactId = contactId
        context.isDirectContact = true
        return context
    }

    /// 会话不是 active 直聊（群、本机笔记、待接受的联系、读不懂的数据）。
    static let outsideDirectContact = PopopxComposerContext()
}

// MARK: - 网格事实的快照

/// 一次批量读出来的网格事实。值类型，判定表只读它，视图不在渲染路径上 await 它。
struct PopopxMeshEligibility: Equatable {
    /// 厢语总闸（`PopopxMeshRuntime.isFuseOn`，`POPOPXAPI.swift:3634`）。
    var fuseOn = false
    /// 绑定表读完没有。没读完时任何通道结论都为时过早。
    var bindingLoaded = false
    /// 这个联系人的厢语公钥（多条绑定时取第一条，与模块 5 的 `resolveBinding` 同一个取法）。
    var meshPublicKeyHex: String?
    /// 本机射频，模块 4 的结论。
    var radioState: PopopxBluetoothState = .unknown
    /// 事前预判 —— 与模块 5 `predictBluetooth` 同一条规则的结论。
    var prediction: PopopxBluetoothPrediction = .notBound
    /// 公网：`true` 连通、`false` 断开、`nil` = `NWPathMonitor` 还没报过（模块 5 也不猜"在线"）。
    var networkConnected: Bool?
    /// 已进离线兜底队列、还没等到 ACK 的条数 —— 灰 `clock` 的唯一数据来源。
    var queuedCount = 0

    /// 这一刻蓝牙能不能带走一条消息。
    var isMeshCapable: Bool {
        if case .reachable = prediction { return true }
        return false
    }

    /// 预判点名的那颗邻居公钥（`.reachable` / `.peerOutOfRange` 都带，`peerKey` 在 :208）。
    var reachableMeshKey: String? { prediction.peerKey }

    static let notLoaded = PopopxMeshEligibility()
}

// MARK: - 判定结果

/// 交回宿主的理由。每条都对应模块 5 的公网腿上真实缺的一个入参，或者一个真实的网格事实。
enum PopopxHostSendReason: Hashable {
    /// 阅后即焚：`apiSendMessages` 的 `ttl`（`POPOPXAPI.swift:577`）在 `PopopxSMPSendRequest` 里没有位置。
    case timedMessage(seconds: Int)
    /// 签名消息：同上，腿上没有 `sign`。
    case signedMessage
    /// 不是 active 直聊联系人：只有 `.contactId` 这一个地址能被公网写到。
    case notDirectContact
    /// 引用 / 编辑 / 转发 / 举报。
    case quotedOrEditing
    /// 附件 / 链接预览 / @提及 / live 消息。
    case richContent
    /// 厢语总闸关着。
    case meshFuseOff
    /// 绑定表尚未读完。
    case bindingUnknown
    /// 这个联系人没有厢语绑定。
    case contactNotBoundToMesh
    /// 本机射频不可用。
    case radioUnavailable(PopopxBluetoothState)
    /// 绑定了，但 15 秒窗口内没听到过邻居。
    case peerOutOfRange

    /// 只给用户看得懂的那两条附一句解释；其余是内部结论，不打扰。
    var explanation: String? {
        switch self {
        case let .timedMessage(seconds): return "阅后即焚 · \(PopopxComposerRouting.durationText(seconds))"
        case .richContent: return "附件与预览不经蓝牙 Mesh"
        case .quotedOrEditing: return "引用与改写不经蓝牙 Mesh"
        case .signedMessage: return "签名消息不经蓝牙 Mesh"
        case .meshFuseOff, .bindingUnknown, .contactNotBoundToMesh, .radioUnavailable, .peerOutOfRange, .notDirectContact:
            return nil
        }
    }
}

/// 一次发送最终归谁。这个枚举就是"接缝"本身：判定与副作用分开，判定可单测。
enum PopopxComposerDispatch: Hashable {
    /// 交给模块 5：宿主 `await router.send(message)`（`PopopxMessageRouter.swift:627`）。
    case routeViaMesh(PopopxOutboundMessage)
    /// 原样交回宿主，并说明为什么不能路由。
    case hostShouldSend(reason: PopopxHostSendReason)
    /// 空草稿：什么都不做。
    case ignoreEmptyDraft

    var isRouted: Bool {
        if case .routeViaMesh = self { return true }
        return false
    }

    /// 交回宿主时的理由；其余两支为 nil。
    var hostReason: PopopxHostSendReason? {
        if case let .hostShouldSend(reason) = self { return reason }
        return nil
    }
}

/// 下一条消息会被哪条通道带走 —— 发送键唯一的强调色来源。
enum PopopxComposerChannel: Hashable {
    /// 公网 SMP（靛紫）。
    case smp
    /// 厢语蓝牙（青绿）。`hops` 是网格测到的跳数，nil = 还不知道跳数。
    case mesh(hops: Int?)
    /// 公网状态未报，且蓝牙已是候选 —— 不替用户猜。
    case undetermined
}

/// `onSend` 的载荷：判定结果 + 判定时的前提，宿主拿它可以原样复现这次结论。
struct PopopxComposerSend: Hashable {
    let text: String
    let context: PopopxComposerContext
    let ttlSeconds: Int?
    let dispatch: PopopxComposerDispatch
    let channel: PopopxComposerChannel
}

/// 阅后即焚的一档。做成结构体而不是带标签的元组：`ForEach(…, id: \.seconds)` 的键路径取不了元组成员。
struct PopopxComposerDurationOption: Hashable, Identifiable {
    let seconds: Int
    let title: String

    var id: Int { seconds }
}

// MARK: - 判定表（纯函数）

/// 没有状态、没有副作用：整张判定表住在这里，视图只负责把它画出来。
enum PopopxComposerRouting {
    /// 阅后即焚的档位，与旧 composer 发送键菜单里那三档一致（`SendMessageView.swift:199`-`:201`）。
    static let durationOptions: [PopopxComposerDurationOption] = [
        .init(seconds: 30, title: "30 秒"),
        .init(seconds: 60, title: "1 分钟"),
        .init(seconds: 300, title: "5 分钟")
    ]

    /// 宿主没选过时的默认档，直接取 app 已有的那个持久化值（`SettingsView.swift:230`）。
    static var fallbackDurationSeconds: Int {
        customDisappearingMessageTimeDefault.get()
    }

    static func durationText(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return "\(seconds / 86_400) 天" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600) 小时" }
        if seconds % 60 == 0 { return "\(seconds / 60) 分钟" }
        return "\(seconds) 秒"
    }

    /// 判定表的核心：这一刻这条草稿能不能交给模块 5。`nil` = 能。
    ///
    /// 它和 `dispatch` 分开是有原因的：通道条每次重绘都要问一遍，而铸造 `messageId` 只该发生在
    /// 真的要把一条消息交出去的时候。
    static func hostReason(
        context: PopopxComposerContext,
        eligibility: PopopxMeshEligibility,
        ttlSeconds: Int?
    ) -> PopopxHostSendReason? {
        if let ttlSeconds {
            return .timedMessage(seconds: ttlSeconds)
        }
        if context.requiresSignature {
            return .signedMessage
        }
        guard context.isDirectContact, context.contactId != nil else {
            return .notDirectContact
        }
        if context.carriesContextItem {
            return .quotedOrEditing
        }
        if context.hasAttachments || context.hasLinkPreview || context.hasMentions || context.isLiveMessage {
            return .richContent
        }
        guard eligibility.fuseOn else {
            return .meshFuseOff
        }
        guard eligibility.bindingLoaded else {
            return .bindingUnknown
        }
        switch eligibility.prediction {
        case .notBound: return .contactNotBoundToMesh
        case let .radioUnavailable(state): return .radioUnavailable(state)
        case .peerOutOfRange: return .peerOutOfRange
        case .reachable: return nil
        }
    }

    /// 判定。**顺序是有意义的**：先排除"路由会静默丢东西"的（TTL、签名、非直聊、富内容），
    /// 再看网格本身的事实。反过来排会让一条阅后即焚的消息先进 mesh 队列。
    static func dispatch(
        text: String,
        context: PopopxComposerContext,
        eligibility: PopopxMeshEligibility,
        ttlSeconds: Int?,
        messageId: String = PopopxOutboundMessage.newMessageId()
    ) -> PopopxComposerDispatch {
        let blankDraft = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 空草稿不等于"没东西可发"：挂了附件（图片 / 文件 / 语音）的草稿文本框本来就是空的，
        // 而旧链路的 `ComposeState.sendEnabled` 对这几支都返回 true。一律 ignore 的话，
        // 这条接缝上永远发不出不带文字的附件。
        if blankDraft && !context.hasAttachments {
            return .ignoreEmptyDraft
        }
        if let reason = hostReason(context: context, eligibility: eligibility, ttlSeconds: ttlSeconds) {
            return .hostShouldSend(reason: reason)
        }
        // `hostReason` 已经确认过 contactId 非空，这里只是把可选值落地，不是一条新分支。
        guard let contactId = context.contactId else {
            return .hostShouldSend(reason: .notDirectContact)
        }
        return .routeViaMesh(
            PopopxOutboundMessage(
                messageId: messageId,
                target: .contactId(contactId),
                text: text
            )
        )
    }

    /// 通道结论。注意它比 `dispatch` 宽：草稿为空时也要能回答"这一刻发出去会走哪条"，
    /// 因为这条信息是状态，不是对某一条消息的判定。
    static func channel(eligibility: PopopxMeshEligibility, ttlSeconds: Int?, hops: Int?) -> PopopxComposerChannel {
        guard ttlSeconds == nil, eligibility.fuseOn, eligibility.isMeshCapable else { return .smp }
        switch eligibility.networkConnected {
        case true: return .smp
        case false: return .mesh(hops: hops)
        case nil: return .undetermined
        }
    }
}

// MARK: - 批量读取网格事实

/// 输入条的状态层：只干两件事 —— 一次批量读网格事实并缓存，以及把结论交给判定表。
///
/// 可测性在这里：把 `resolver` 换成一个闭包就能喂任意快照，不需要射频、不需要会话、不需要路由器。
@MainActor
final class PopopxInputBarModel: ObservableObject {
    /// 缓存下来的那一份网格事实。
    @Published private(set) var eligibility = PopopxMeshEligibility.notLoaded
    /// 正在读表（只用于把「通道待定」画出来，不参与判定 —— 判定看 `bindingLoaded`）。
    @Published private(set) var isResolving = false

    /// 注入点。`nil` = 用真运行时（`resolveFromRuntime`）。
    var resolver: (@MainActor (Int64?) async -> PopopxMeshEligibility)?

    /// 5 秒一跳，只为了把"邻居静默超窗"这件事自己褪下去；和消息列表页同一个节奏
    /// （`Shared/Features/Chats/ChatsListView.swift:414`-`:421`）。
    static let pollIntervalSeconds: Double = 5

    func refresh(contactId: Int64?) async {
        isResolving = true
        let next: PopopxMeshEligibility
        if let resolver {
            next = await resolver(contactId)
        } else {
            next = await Self.resolveFromRuntime(contactId: contactId)
        }
        eligibility = next
        isResolving = false
    }

    /// 反复刷新，直到这次 `Task` 被取消（换了会话、总闸翻了、输入条离开了屏幕）。
    func poll(contactId: Int64?) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
            guard !Task.isCancelled else { break }
            await refresh(contactId: contactId)
        }
    }

    /// 一次批量读，四跳封顶，只在打开会话与 5 秒一跳时发生 —— 不在按键路径上。
    ///
    /// 判定的先后次序照抄模块 5 的 `predictBluetooth`（`PopopxMessageRouter.swift:1051`-`:1060`）：
    /// 没绑定 → `.notBound`；射频不可用 → `.radioUnavailable`；逐个问可达性，问到第一个真的可达就收；
    /// 全不可达 → `.peerOutOfRange(第一条)`。用的也是**同一个 judge 与同一个超时**，
    /// 所以这条接缝的结论不会和路由器自己的结论各说各话。
    static func resolveFromRuntime(contactId: Int64?) async -> PopopxMeshEligibility {
        let runtime = PopopxMeshRuntime.shared
        var snapshot = PopopxMeshEligibility()
        snapshot.fuseOn = runtime.isFuseOn
        guard runtime.isFuseOn, let contactId else {
            // 总闸关着或这条会话没有联系人：绑定表不去读，`bindingLoaded` 保持 false。
            return snapshot
        }
        let judge = PopopxBluetoothHealthJudge(monitor: runtime.healthMonitor)
        let hexes = await runtime.mappingStore.meshPublicKeyHexes(forContactId: contactId)
        snapshot.bindingLoaded = true
        snapshot.meshPublicKeyHex = hexes.first
        let radio = await judge.radioState
        snapshot.radioState = radio
        if hexes.isEmpty {
            snapshot.prediction = .notBound
        } else if !radio.isUsable {
            snapshot.prediction = .radioUnavailable(radio)
        } else {
            var answer = PopopxBluetoothPrediction.peerOutOfRange(peerMeshPublicKeyHex: hexes[0])
            let timeout = PopopxMeshConfig.default.peerReachabilityTimeout
            for hex in hexes where await judge.isPeerReachable(publicKey: hex, timeout: timeout) {
                answer = .reachable(peerMeshPublicKeyHex: hex)
                break
            }
            snapshot.prediction = answer
        }
        // nil 原样留着：那是"还没报"，不是"断开"。
        snapshot.networkConnected = await NetworkStateMonitor.shared.currentPath()?.isConnected
        snapshot.queuedCount = await runtime.router.pendingMessageCount
        return snapshot
    }
}

// MARK: - 「+」面板的动作

/// 微信式功能面板里的格子。本条只负责"哪一种被按下"，实现全在宿主。
enum PopopxPlusAction: String, CaseIterable, Identifiable {
    case photo
    case camera
    case file
    case location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return "相册"
        case .camera: return "拍摄"
        case .file: return "文件"
        case .location: return "位置"
        }
    }

    var symbolName: String {
        switch self {
        case .photo: return "photo.on.rectangle.angled"
        case .camera: return "camera.fill"
        case .file: return "folder.fill"
        case .location: return "location.fill"
        }
    }
}

// MARK: - 输入条

/// 磨砂玻璃底的会话输入条：语音键 · 自增高文本框 · 表情 · 「+」功能面板（内含阅后即焚）· 发送键。
struct PopopxInputBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @Binding private var text: String
    @FocusState private var isFocused: Bool

    @StateObject private var model: PopopxInputBarModel
    @ObservedObject private var runtime: PopopxMeshRuntime
    @ObservedObject private var meshState: PopopxMeshStateSource

    private let context: PopopxComposerContext
    private let ttlSeconds: Int?
    private let isSendEnabled: Bool
    private let placeholder: String
    private let onSend: (PopopxComposerSend) -> Void
    private let onVoiceTap: (Bool) -> Void
    private let onHoldToTalk: () -> Void
    private let onPlusTap: (PopopxPlusAction) -> Void
    private let onTTLChange: (Int?) -> Void

    @State private var showsPlusPanel = false
    @State private var showsEmojiTray = false
    @State private var isVoiceMode = false

    /// 文本框最多长到几行，再长就自己滚。
    private static let maxComposerLines = 5

    /// `@MainActor` 是为了在 init 里取那两个 `@MainActor` 单例（`PopopxMeshRuntime.shared`
    /// `POPOPXAPI.swift:3626`、`PopopxMeshStateSource.shared` `PopopxMeshStateSource.swift:158`）——
    /// 和第四阶段那几页同一个写法（`Shared/Features/Chats/ChatsListView.swift:160`）。
    @MainActor
    init(
        text: Binding<String>,
        context: PopopxComposerContext = .outsideDirectContact,
        ttlSeconds: Int? = nil,
        isSendEnabled: Bool = true,
        placeholder: String = "发消息…",
        onSend: @escaping (PopopxComposerSend) -> Void,
        onVoiceTap: @escaping (Bool) -> Void = { _ in },
        onHoldToTalk: @escaping () -> Void = {},
        onPlusTap: @escaping (PopopxPlusAction) -> Void = { _ in },
        onTTLChange: @escaping (Int?) -> Void = { _ in }
    ) {
        _text = text
        _model = StateObject(wrappedValue: PopopxInputBarModel())
        _runtime = ObservedObject(wrappedValue: PopopxMeshRuntime.shared)
        _meshState = ObservedObject(wrappedValue: PopopxMeshStateSource.shared)
        self.context = context
        self.ttlSeconds = ttlSeconds
        self.isSendEnabled = isSendEnabled
        self.placeholder = placeholder
        self.onSend = onSend
        self.onVoiceTap = onVoiceTap
        self.onHoldToTalk = onHoldToTalk
        self.onPlusTap = onPlusTap
        self.onTTLChange = onTTLChange
    }

    var body: some View {
        VStack(spacing: PopopxMetrics.space2XS) {
            channelStrip
            inputRow
            if showsEmojiTray { emojiTray }
            if showsPlusPanel { plusPanel }
        }
        .padding(.top, PopopxMetrics.spaceXS)
        .padding(.bottom, PopopxMetrics.space2XS)
        .padding(.horizontal, PopopxMetrics.spaceS)
        .background(PopopxMaterial.bar, in: .rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .popopxCardElevation(colorScheme: colorScheme)
        .popopxAnimation(PopopxSpring.snappy, value: showsPlusPanel, reduceMotion: reduceMotion)
        .popopxAnimation(PopopxSpring.snappy, value: showsEmojiTray, reduceMotion: reduceMotion)
        .popopxAnimation(PopopxSpring.fluid, value: channel, reduceMotion: reduceMotion)
        // 打开会话读一次；总闸翻转时重开这一对 task（`refresh` 自己会先把旧结论清成未读）。
        .task(id: context.contactId) { await model.refresh(contactId: context.contactId) }
        .task(id: runtime.isFuseOn) { await model.poll(contactId: context.contactId) }
    }

    // MARK: 通道条

    private var channel: PopopxComposerChannel {
        PopopxComposerRouting.channel(
            eligibility: model.eligibility,
            ttlSeconds: ttlSeconds,
            hops: currentHops
        )
    }

    /// 跳数从已观察的网格快照同步读，不产生 actor hop（`peer(withHex:)` 在 PopopxMeshStateSource.swift:53）。
    private var currentHops: Int? {
        guard let hex = model.eligibility.reachableMeshKey else { return nil }
        return meshState.state.peer(withHex: hex)?.hopCount
    }

    /// 通道条每次重绘都要问的那一半判定（不铸造 messageId —— 还没有"这一条消息"）。
    private var hostSendReason: PopopxHostSendReason? {
        PopopxComposerRouting.hostReason(
            context: context,
            eligibility: model.eligibility,
            ttlSeconds: ttlSeconds
        )
    }

    /// 发送键的图形只跟着**通道**走，不跟着"归谁发"走：这个产品里青绿的意思从来都是"蓝牙带走了这条"，
    /// 而不是"模块 5 拿到了它"（判定结果在 `onSend` 的 `dispatch` 里，宿主自己看）。
    private var sendSymbolName: String {
        if case .mesh = channel { return "antenna.radiowaves.left.and.right" }
        return "arrow.up"
    }

    @ViewBuilder private var channelStrip: some View {
        let note = stripNote
        if note != nil || model.eligibility.queuedCount > 0 {
            HStack(spacing: PopopxMetrics.spaceXS) {
                channelBadge
                if model.eligibility.queuedCount > 0 {
                    // 灰 clock 只说一件事：厢语中继积压。
                    Label("待中继 \(model.eligibility.queuedCount)", systemImage: "clock")
                        .font(PopopxType.metricSmall)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .accessibilityLabel("厢语中继积压 \(model.eligibility.queuedCount) 条")
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .padding(.leading, PopopxMetrics.space2XS)
        }
    }

    @ViewBuilder private var channelBadge: some View {
        switch channel {
        case .smp:
            Label("在线加密 · SMP", systemImage: "lock.shield.fill")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.brand)
        case let .mesh(hops):
            Label(hops.map { "厢语离线 · \($0) 跳" } ?? "厢语离线", systemImage: "antenna.radiowaves.left.and.right")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.meshInk)
        case .undetermined:
            // 不替用户猜通道，所以这里刻意不给图标、不给强调色。
            Text(model.isResolving ? "正在读取厢语绑定" : "通道待定")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
    }

    /// 强调色之外的那句解释（灰色，绝不与强调色抢同一个控件里的第二把颜色）。
    private var stripNote: String? {
        if let reason = hostSendReason { return reason.explanation }
        switch channel {
        case .smp:
            // 公网在、蓝牙也能直达时，说清 mesh 只是补发/兜底（模块 5 的 3 秒规则）。
            return model.eligibility.isMeshCapable && model.eligibility.networkConnected == true
                ? "公网 3 秒未确认时同时经蓝牙补发"
                : nil
        case .mesh:
            return "无公网，这条将由蓝牙中继"
        case .undetermined:
            return nil
        }
    }

    // MARK: 主行

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: PopopxMetrics.spaceXS) {
            PopopxBarKey(
                symbol: isVoiceMode ? "keyboard" : "mic",
                label: isVoiceMode ? "切回键盘输入" : "切换语音输入",
                active: isVoiceMode
            ) {
                isVoiceMode.toggle()
                closeTrays()
                PopopxHaptics.selection()
                onVoiceTap(isVoiceMode)
            }

            if isVoiceMode {
                holdToTalkBar
            } else {
                composerField
            }

            PopopxBarKey(
                symbol: "face.smiling",
                label: "表情",
                active: showsEmojiTray
            ) {
                showsPlusPanel = false
                showsEmojiTray.toggle()
                if showsEmojiTray { isFocused = false }
                PopopxHaptics.selection()
            }

            PopopxBarKey(
                symbol: showsPlusPanel ? "xmark" : "plus",
                label: showsPlusPanel ? "收起功能面板" : "更多功能",
                active: showsPlusPanel
            ) {
                showsEmojiTray = false
                showsPlusPanel.toggle()
                if showsPlusPanel { isFocused = false }
                PopopxHaptics.selection()
            }
            .accessibilityIdentifier("popopx.inputBar.plusButton")

            sendKey
        }
    }

    private var composerField: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .font(PopopxType.body)
            .foregroundStyle(PopopxPalette.label)
            .lineLimit(1...Self.maxComposerLines)
            .focused($isFocused)
            .submitLabel(.send)
            .onSubmit(send)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .padding(.vertical, PopopxMetrics.space2XS)
            .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(
                        isFocused ? PopopxPalette.hairlineInner : Color.clear,
                        lineWidth: PopopxMetrics.hairline
                    )
            )
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier("popopx.inputBar.textField")
    }

    /// 录音不归本条所有：这里只把"按住说话"这个面切换出来，并把按下这件事递出去。
    private var holdToTalkBar: some View {
        Button(action: onHoldToTalk) {
            Text("按住 说话")
                .font(PopopxType.emphasis)
                .foregroundStyle(PopopxPalette.label)
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget)
                .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                .contentShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: .medium))
        .accessibilityHint("交给宿主的录音链路；本输入条不拥有录音器")
    }

    private var sendKey: some View {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canFire = isSendEnabled && (!blank || context.hasAttachments)
        return Button(action: send) {
            Image(systemName: sendSymbolName)
                .font(PopopxType.emphasis)
                .foregroundStyle(sendAccent.ink)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .background(sendAccent.fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .disabled(!canFire)
        .opacity(canFire ? 1 : 0.45)
        .accessibilityLabel("发送")
        .accessibilityValue(sendAccessoryLabel)
        .accessibilityIdentifier("popopx.inputBar.sendButton")
    }

    /// 一个控件里只可能有一把强调色：靛紫（SMP）或青绿（mesh），或两者都不是的中性灰。
    private var sendAccent: (fill: Color, ink: Color) {
        switch channel {
        case .smp: (PopopxPalette.brand, PopopxPalette.onBrand)
        case .mesh: (PopopxPalette.mesh, PopopxPalette.onMesh)
        case .undetermined: (PopopxPalette.separator, PopopxPalette.labelSecondary)
        }
    }

    private var sendAccessoryLabel: String {
        switch channel {
        case .smp: return "将由在线加密 SMP 发送"
        case .mesh: return "将由厢语蓝牙发送"
        case .undetermined: return "发送通道待定"
        }
    }

    // MARK: 表情托盘

    private var emojiTray: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: PopopxMetrics.space2XL), spacing: PopopxMetrics.spaceXS)],
            spacing: PopopxMetrics.space2XS
        ) {
            ForEach(Self.quickEmoji, id: \.self) { glyph in
                Button {
                    text += glyph
                    PopopxHaptics.impact(.soft)
                } label: {
                    Text(glyph)
                        .font(PopopxType.title)
                        .frame(minWidth: PopopxMetrics.minHitTarget, minHeight: PopopxMetrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PopopxPressButtonStyle(feedback: nil))
                .accessibilityLabel("插入表情 \(glyph)")
            }
            Button {
                if !text.isEmpty { text.removeLast() }
                PopopxHaptics.impact(.light)
            } label: {
                Image(systemName: "delete.left")
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(minWidth: PopopxMetrics.minHitTarget, minHeight: PopopxMetrics.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle(feedback: nil))
            .accessibilityLabel("删除前一个字符")
        }
        .padding(.top, PopopxMetrics.space2XS)
    }

    /// 常用 24 枚。要更全的表情归系统的表情键盘（切回键盘即可），本条不自建第二套选表器 ——
    /// 旧 composer 的 `ElegantEmojiPicker` 只在列表页选标签图标时挂过（`TagListView.swift:250`）。
    private static let quickEmoji: [String] = [
        "😀", "😄", "😂", "🥰", "😍", "😉",
        "😊", "😎", "🤔", "😴", "😭", "😱",
        "👍", "👎", "👏", "🙏", "💪", "🤝",
        "❤️", "🔥", "🎉", "✨", "🌙", "⚡️"
    ]

    // MARK: 「+」功能面板

    private var plusPanel: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            Rectangle()
                .fill(PopopxPalette.separator)
                .frame(height: PopopxMetrics.divider)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: PopopxMetrics.space2XL), spacing: PopopxMetrics.spaceS)],
                spacing: PopopxMetrics.spaceXS
            ) {
                ForEach(PopopxPlusAction.allCases) { action in
                    Button {
                        closeTrays()
                        onPlusTap(action)
                    } label: {
                        VStack(spacing: PopopxMetrics.space2XS) {
                            Image(systemName: action.symbolName)
                                .font(PopopxType.sectionHeader)
                                .foregroundStyle(PopopxPalette.label)
                                .frame(
                                    minWidth: PopopxMetrics.minHitTarget,
                                    minHeight: PopopxMetrics.minHitTarget
                                )
                                .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                            Text(action.title)
                                .font(PopopxType.microTag)
                                .foregroundStyle(PopopxPalette.labelSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PopopxPressButtonStyle(feedback: .light))
                    .accessibilityLabel(action.title)
                }
            }

            disappearingBlock

            Text("阅后即焚、附件与引用不由蓝牙中继，仍按原样从公网发送。")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, PopopxMetrics.space2XS)
    }

    @ViewBuilder private var disappearingBlock: some View {
        PopopxCheckbox(
            "阅后即焚",
            note: "开启后这条只走在线加密，不经蓝牙中继",
            isOn: disappearingSwitch
        )
        if ttlSeconds != nil {
            HStack(spacing: PopopxMetrics.spaceXS) {
                ForEach(PopopxComposerRouting.durationOptions) { option in
                    let isSelected = ttlSeconds == option.seconds
                    Button {
                        PopopxHaptics.selection()
                        onTTLChange(option.seconds)
                    } label: {
                        Text(option.title)
                            .font(PopopxType.meta)
                            .foregroundStyle(isSelected ? PopopxPalette.onBrand : PopopxPalette.labelSecondary)
                            .lineLimit(1)
                            .frame(minWidth: PopopxMetrics.space2XL, minHeight: PopopxMetrics.minHitTarget)
                            .background(
                                isSelected ? PopopxPalette.brand : Color.clear,
                                in: .rect(cornerRadius: PopopxMetrics.radiusChip)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: PopopxMetrics.radiusChip)
                                    .strokeBorder(
                                        isSelected ? Color.clear : PopopxPalette.labelHint,
                                        lineWidth: PopopxMetrics.hairline
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PopopxPressButtonStyle(feedback: nil))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            // 三档就是旧发送键菜单里的那三档（`SendMessageView.swift:199`-`:201`），这里不另立时长。
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("阅后即焚时长"))
        }
    }

    /// 只有一份真值：读进来的 `ttlSeconds`，写出去的 `onTTLChange`。本条不存"上一次选的时长"。
    private var disappearingSwitch: Binding<Bool> {
        Binding(
            get: { ttlSeconds != nil },
            set: { turnedOn in
                PopopxHaptics.impact(.light)
                guard turnedOn else {
                    onTTLChange(nil)
                    return
                }
                onTTLChange(ttlSeconds ?? PopopxComposerRouting.fallbackDurationSeconds)
            }
        )
    }

    // MARK: 动作

    private func closeTrays() {
        showsPlusPanel = false
        showsEmojiTray = false
    }

    private func send() {
        let dispatch = PopopxComposerRouting.dispatch(
            text: text,
            context: context,
            eligibility: model.eligibility,
            ttlSeconds: ttlSeconds
        )
        // 空草稿：不发，也不叫宿主。
        if case .ignoreEmptyDraft = dispatch { return }
        PopopxHaptics.impact(dispatch.isRouted ? .medium : .light)
        onSend(
            PopopxComposerSend(
                text: text,
                context: context,
                ttlSeconds: ttlSeconds,
                dispatch: dispatch,
                channel: channel
            )
        )
        // 只有路由这一支由本条负责清草稿：模块 5 的 SMP 腿自己把行插进时间线
        // （`POPOPXAPI.swift:3461`-`:3480`），除了这里没有第二个人会清 `text`。
        // 交回宿主的那一支沿用宿主原有的清空时机（`SendMessageView.swift:152`），本条不去动它，
        // 否则宿主的失败回填、改写草稿会被抹掉。
        if dispatch.isRouted { text = "" }
        closeTrays()
    }
}

// MARK: - 键位（44pt 起跳，全部走原子控件）

/// 输入条上的一个图标键。选中态用墨色 + 一层卡片底，**不用靛紫也不用青绿**：
/// 那两把颜色在这个产品里是传输通道的语义，不能被"面板开着"这种事借用。
private struct PopopxBarKey: View {
    let symbol: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(active ? PopopxPalette.label : PopopxPalette.labelSecondary)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .background(
                    active ? PopopxPalette.card : Color.clear,
                    in: .rect(cornerRadius: PopopxMetrics.radiusControl)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: .light))
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

