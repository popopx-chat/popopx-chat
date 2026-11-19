//
//  PopopxCabinView.swift
//  POPOPX (iOS)
//
//  第四阶段 Tab 3「厢语」—— `PopopxMeshKit` 本地蓝牙状态的 app 侧重写版，用来替代包内
//  `PopopxMeshUI/MeshPlazaView.swift` 那一屏（包内那份保留不动，`SettingsView.swift` 的
//  「Offline mesh」段与 `PopopxAddFriendView.swift:121` 两个挂载点照旧能编能跑）。这一页只讲
//  物理射程内的事：广播流、周边节点、总闸；没有公网、没有 relay、没有 SMP。
//
//  三条数据来源，全是包里的真对象，本文件不写第二条传输路径：
//  1. `PopopxMeshStateSource.shared.state` —— `radioState / peers / broadcasts / latestBroadcastAt`。
//     `@ObservedObject` 直接看这份镜像；body 里不 `await` 任何东西。
//  2. `BluetoothHealthMonitor`（actor）—— `allNodes()` 是节点表与跳数徽章的唯一来源，在线判定用
//     `PopopxPeerReachability.isReachable(now:radioOn:timeout:)`，窗口引模块 4 自己的常量
//     `PopopxMeshConfig.default.peerReachabilityTimeout`（15 秒；`BluetoothHealthMonitor.swift:63`
//     的 `defaultReachabilityTimeout` 就是它的别名）。actor 读数只在 `.task` 轮询与动作之后做。
//  3. `ManualPairingManager` + `IdentityMappingStore`（两个 actor）—— `allStates()` /
//     `pendingRequests()` / `initiatePairing(with:incognito:)` 给配对事实，`allMappings()` 给「已绑定」事实。
//
//  发包路径逐字照抄 `MeshPlazaView`：广播 = `PopopxMeshOutbound.sendBroadcast(text:)`，对象是
//  `PopopxMeshRuntime.shared.engineBackend`（`Shared/Model/POPOPXAPI.swift:3648`），也就是
//  `PopopxAddFriendView.swift:121-125` 挂载广场时传进去的同一个 backend；截断/上限/本机回声/去重的
//  规则照抄 `PopopxMeshPlazaModel.broadcastDraft()`（`MeshPlazaView.swift:168-186`）、
//  `rebuildPosts(from:)`（`:213-232`）与 `deduped(_:)`（`:255-265`）。昵称写入口 =
//  `PopopxMeshKillSwitch.setNickname(_:)`（包内 `saveNickname()` 最终也就是它）。
//  「点击直接开启蓝牙私聊」= `initiatePairing(with:incognito:)` 发一次离线建联邀请（这是唯一能让一条
//  Noise 私聊会话存在的动作），然后 push 包里那条私聊面 `PopopxMeshPrivateChatView`，四个依赖全部显式
//  给真对象——它的默认参数是 `PopopxMeshEngine.shared` / `.shared` 单例，会让总闸关着的一页顺手把引擎
//  与射频建出来（`POPOPXAPI.swift:3557` 之后那段注释说的就是这件事），所以一个默认值都不走。
//
//  频道命名（裁定；包内是英文 `#mesh`，全仓 `Shared/` 里 `#mesh` 出现 0 次）：
//  - 公共广播频道 = 「#厢语大厅」。保留 `#`：它是「一个频道」的视觉记号，不是 `#mesh` 这个词；
//    这条频道是无加密洪泛，只在蓝牙射程内，不经服务器，也不回显给发送者。
//  - 「本地加密频道」= 本机与单个蓝牙邻居已经建立的 Noise_XX 1:1 会话集合（判据 = 模块 1 有映射行，
//    或模块 3 报 `.paired`）。它走的是 mesh 而不是 SMP，所以整行只有青绿，不出现靛紫（§1.1）。
//
//  颜色纪律：青绿只出现在 mesh 事实的行上；`PopopxToggleRow` 的开关实底是原子库写死的
//  `PopopxPalette.brand`（`PopopxControls.swift:400`），所以总闸那一行不放青色徽标——同一控件里
//  紫青并存就是 §1.1 违规。青色徽章一律带跳数数字（§1.4 第 3 条）。本页那个 120% 签名细节是
//  附近节点的雷达；Reduce Motion 下退化成静态环 + 数字跳数，一次循环动画都不启动（§5）。
//
//  顶栏与设置中心（离线组网入口收口，四个决定）：
//  1. 左上角「附近厢语广场」= `path.append(.hall)`，进的是本页已有的 #厢语大厅，不新开第二份广场；
//  2. 右上角「离线组网设置」= `PopopxCabinMeshSettingsSheet`，三张卡依次是总闸与配对策略、节点身份与
//     真实运行态、离线数据与清除。这四件事原先散在「我」页的离线组网分组与「全部设置」页的厢语卡片里，
//     摘除时逐条等效搬来：`requestFuse(_:)` / `setPairingPolicy(_:)` / `verifiedActivitySnapshot()` /
//     `emergencyWipeAllMappings()`，绑定一个都没换来源，也没有新增第二套状态存储；
//  3. 设置中心的视图内聚在本文件末尾，零新增文件、零 `project.pbxproj` 改动（铁律：不脚本改工程文件）；
//  4. 栈由本页自己持有：`NavigationStack(path: $path)` 在这里，`MainTabView` 只放裸的 `PopopxCabinView()`。
//     `path` 若不是绑定在栈上的那一份，四处 `path.append` 一次也推不动，见 `PopopxCabinRoute` 上面那段。
//
//  本地化：设置中心新增的源文是英文原句即 Key，与 16 个译本目录的约定见下面 `Copy` 里那一节；
//  本页其余字面量是 Phase 4 的中文直写，本次不动，整页转 Key 另立一轮。
//

import Foundation
import SwiftUI
import PopopxMeshKit
import PopopxMeshUI

// MARK: - Push routes

/// 栈由本页自己持有：`path` 必须是**绑定在栈上**的那一份。
/// 2026-11-20 之前它挂在 `@State` 上、栈却由 `MainTabView` 裸包一层，四处 `path.append`
/// 因此一次也推不动（绑定不存在）；把栈移进来才接上，第四阶段"消息栏自带栈"是同一写法。
private enum PopopxCabinRoute: Hashable {
    /// 「#厢语大厅」：完整广播流 + 广播输入 + 本机临时昵称。
    case hall
    /// 本地加密频道：本机已与蓝牙邻居建立的 1:1 加密会话清单。
    case encryptedChannels
    /// 与某一个 mesh 公钥的私聊（包内 `PopopxMeshPrivateChatView`）。
    case privateChat(peerMeshPublicKeyHex: String)
}

// MARK: - Label

/// 公钥的读法：与包内横幅/私聊页同一规则，超过 16 位取前 16 位加省略号
/// （`PopopxMeshBannerModel.shorten`，`ManualPairingBannerView.swift:355`；`PopopxMeshPrivateChatModel
/// .peerLabel` 只是转发到它）。包内那两个宿主都是 `@MainActor` 类，非隔离的值类型里不能同步调，
/// 所以这里逐字复刻同一规则，保证全仓一个公钥只有一种拼法。
private enum PopopxCabinLabel {
    static func abbreviate(_ hex: String) -> String {
        hex.count > 16 ? "\(hex.prefix(16))…" : hex
    }
}

// MARK: - Node snapshot

/// 一个周边节点在这一页上的全部事实：模块 4 的可达性 + 镜像的昵称/RSSI + 模块 1 的绑定 + 模块 3 的配对。
/// 值类型，`refresh()` 一次算完；行视图只读它，不再碰 actor。
private struct PopopxCabinNode: Identifiable, Hashable {
    /// 绑定事实的三档，直接来自 `PopopxMeshContactMapping` 的字段。
    enum Binding: Hashable {
        /// `contactId != nil`：这条 mesh 公钥背后是一个真的 POPOPX 联系人。
        case contact
        /// `contactId == nil` 且 `isPending`：离线建联已发出，还没成为联系人。
        case pending
        /// 映射表里没有这一行。
        case none
    }

    let peerIDHex: String
    /// announce 或握手解析出来的 64 位十六进制公钥；nil 时这一台还无法寻址，只能听到它的洪泛。
    let meshPublicKeyHex: String?
    let nickname: String?
    let hopCount: Int
    let lastSeenAt: Date
    let rssi: Int8?
    let isDirect: Bool
    let isReachable: Bool
    let binding: Binding
    let pairingState: MeshPairingState

    var id: String { peerIDHex }

    /// 名字的取法与包内私聊页一致：announce 昵称 → 公钥缩写 → 8 字节线 id 前缀。
    var label: String {
        if let nickname {
            let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        if let meshPublicKeyHex { return PopopxCabinLabel.abbreviate(meshPublicKeyHex) }
        return String(peerIDHex.prefix(8))
    }

    /// 能不能开私聊：没有公钥就组不出会话，`SYS_POPOPX_*` 帧无处可去。
    var canOpenChat: Bool { meshPublicKeyHex != nil }
    var isBound: Bool { binding == .contact }
    var isPaired: Bool {
        if case .paired = pairingState { return true }
        return false
    }
    /// 「本地加密频道」的判据 = 包内私聊页允许发一条消息的判据，逐字同源：模块 3 报 `.paired`
    /// 或者模块 1 里有这一行（`PopopxMeshPrivateChatView.swift:311-314` 的 `peerIsPaired`）。
    var hasEncryptedChannel: Bool { isBound || binding == .pending || isPaired }
}

// MARK: - Tab page

@MainActor
struct PopopxCabinView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 熔断真值与四个 actor 句柄都在 runtime 上；`PopopxMeshStateSource` 是包里的镜像单例。
    @ObservedObject private var meshRuntime: PopopxMeshRuntime
    @ObservedObject private var meshState: PopopxMeshStateSource

    @State private var toast = PopopxToastModel()
    @State private var path: [PopopxCabinRoute] = []
    @State private var nodes: [PopopxCabinNode] = []
    @State private var pendingRequests: [PopopxPairingRequest] = []
    /// 本机发出去的广播：mesh 不会把洪泛回声给发送者，所以这一份要自己留着（包内同款）。
    @State private var localBroadcasts: [PopopxMeshPlazaPost] = []
    @State private var nicknameText = ""
    @State private var showsPairingRequests = false
    /// 「厢语离线组网设置中心」——全 app 唯一一处离线组网设置（2026-11-20 收口裁定）。
    @State private var showsMeshSettings = false
    /// 正在开私聊的那一台的 `peerIDHex`：只让那一行显示进度，不把整页变灰。
    @State private var openingNodeID: String?

    // 设置中心要的三份事实，全部是 actor 读出来的，页面不自己猜：
    // 模块 7 亲口回答的运行态快照、本机 mesh 静态公钥、绑定表与离线队列的行数。
    @State private var verifiedSnapshot: PopopxMeshActivitySnapshot?
    @State private var localKeyHex = ""
    @State private var bindingCount = 0
    @State private var queuedCount = 0

    /// 轮询节奏：模块 4 的静默窗口是 15 秒，2 秒一次足够让「最近听到」这类读数不撒谎，
    /// 又不会把三个 actor 的 hop 变成每秒几十次。
    private static let refreshInterval: Duration = .seconds(2)
    /// 雷达一屏最多画这么多个点；多出来的仍然全列在下面的行里，一个都不藏。
    private static let radarMarkerLimit = 12

    @MainActor init() {
        _meshRuntime = ObservedObject(wrappedValue: PopopxMeshRuntime.shared)
        _meshState = ObservedObject(wrappedValue: PopopxMeshStateSource.shared)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    header
                    statusCard
                    channelsCard
                    nearbyCard
                }
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.top, PopopxMetrics.spaceS)
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PopopxPalette.base)
            .navigationTitle(Copy.tabTitle)
            .toolbar {
                // 左上角 = 附近厢语广场，右上角 = 离线组网设置中心。两个入口都只在这一栏出现：
                // 工具条项属于声明它的这一层内容，推进大厅或私聊页就由那一页自己的条接管。
                ToolbarItem(placement: .topBarLeading) { plazaEntry }
                ToolbarItem(placement: .topBarTrailing) { meshSettingsEntry }
            }
            .navigationDestination(for: PopopxCabinRoute.self) { route in
                switch route {
                case .hall:
                    PopopxCabinHallView(
                        fuseOn: meshRuntime.isFuseOn,
                        radioUsable: radioUsable,
                        nickname: $nicknameText,
                        posts: mergedBroadcastPosts,
                        onBroadcast: { text in await sendBroadcast(text) },
                        onSaveNickname: { await saveNickname() },
                        onTurnOnFuse: {
                            await meshRuntime.setFuse(true)
                            await refresh()
                        }
                    )
                    .navigationTitle(Copy.hallRow)

                case .encryptedChannels:
                    PopopxCabinChannelsView(
                        fuseOn: meshRuntime.isFuseOn,
                        nodes: nodes,
                        openingNodeID: openingNodeID,
                        pendingCount: pendingRequests.count,
                        onOpenChat: { node in await openBluetoothChat(with: node) },
                        onShowPending: { showsPairingRequests = true }
                    )
                    .navigationTitle(Copy.encryptedChannelsRow)

                case let .privateChat(peerMeshPublicKeyHex):
                    // 包里唯一的那条 1:1 离线私聊面。四个依赖全给真对象，一个默认值都不走：默认值是
                    // `PopopxMeshEngine.shared` / `PopopxMeshKillSwitch.shared`，总闸关着时也会被建出来。
                    PopopxMeshPrivateChatView(
                        peerMeshPublicKeyHex: peerMeshPublicKeyHex,
                        outbound: meshRuntime.engineBackend,
                        source: meshRuntime.stateSource,
                        store: meshRuntime.mappingStore,
                        killSwitch: meshRuntime.killSwitch
                    )
                    .navigationTitle(Copy.privateChatTitle)
                }
            }
            .sheet(isPresented: $showsPairingRequests) {
                PopopxCabinPairingRequestsSheet(
                    requests: pendingRequests,
                    nodes: nodes,
                    onApprove: { request in await approve(request) },
                    onDecline: { request in await decline(request) }
                )
            }
            .sheet(isPresented: $showsMeshSettings) {
                PopopxCabinMeshSettingsSheet(
                    fuseOn: meshRuntime.isFuseOn,
                    pairingPolicy: meshRuntime.pairingPolicy,
                    snapshot: verifiedSnapshot,
                    nodes: nodes,
                    localKeyHex: localKeyHex,
                    bindingCount: bindingCount,
                    queuedCount: queuedCount,
                    onToggleFuse: { meshRuntime.requestFuse($0) },
                    onSelectPolicy: { meshRuntime.setPairingPolicy($0) },
                    onVerify: { await refreshVerification(waitingForSettle: false) },
                    onWipe: { await clearOfflineIdentity() },
                    onClose: { showsMeshSettings = false }
                )
            }
            .popopxToast(toast)
            .task {
                // 只有总闸开着才订阅镜像：`PopopxMeshStateSource` 是 kill switch 的组件，关着时由它启停；
                // 本页在关闭态去 `start()` 会留下「开关关着但有人在订阅」的状态。
                if meshRuntime.isFuseOn { meshState.start() }
                nicknameText = currentNickname()
                await refresh()
                await refreshIdentityFacts()
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.refreshInterval)
                    if Task.isCancelled { break }
                    await refresh()
                    // 设置中心开着时，身份三格必须跟页面同一个节奏；关着就不问，省三次 actor hop。
                    if showsMeshSettings { await refreshIdentityFacts() }
                }
            }
            // 总闸一翻就重算：OFF 要清掉节点表（模块 4 的表在 stop 之后仍然留着旧数据，继续显示就是撒谎），
            // ON 要立刻订阅并读一次，不等下一个 2 秒。
            .onChange(of: meshRuntime.isFuseOn) { _, isOn in
                nicknameText = currentNickname()
                Task { @MainActor in
                    if isOn { meshState.start() }
                    await refresh()
                    await refreshIdentityFacts()
                }
            }
            // 射频刚翻面时镜像里只有广播，可达性还没算出来；补一次 actor 读数。
            .onChange(of: meshState.state.radioState) { _, _ in
                Task { @MainActor in await refresh() }
            }
            // 打开设置中心先补一次核验：熔断镜像的 phase 与真在跑的组件数只有问了 模块 7 才是当下的事实。
            .onChange(of: showsMeshSettings) { _, opened in
                guard opened else { return }
                Task { @MainActor in
                    await refreshIdentityFacts()
                    await refreshVerification(waitingForSettle: false)
                }
            }
        }
    }

    // MARK: 顶栏两个入口

    /// 「附近厢语广场」：直达本页的大厅（同一条洪泛流、同一个输入框），不新开第二份广场。
    private var plazaEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            path.append(.hall)
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                Text(Copy.plazaEntry)
                    .font(PopopxType.meta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(PopopxPalette.onMesh)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(verbatim: Copy.plazaHint))
        .accessibilityIdentifier("popopx.cabin.plaza")
    }

    /// 「离线组网设置」：那颗点是运行态，不是装饰 —— 熔断关着就换成中性色，与设置中心第一张卡说的同一句话。
    private var meshSettingsEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            showsMeshSettings = true
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "slider.horizontal.3")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.meshInk)
                    .accessibilityHidden(true)
                Circle()
                    .fill(meshRuntime.isFuseOn ? PopopxPalette.mesh : PopopxPalette.labelHint)
                    .frame(width: PopopxMetrics.spaceXS, height: PopopxMetrics.spaceXS)
                    .accessibilityHidden(true)
                Text(Copy.meshSettingsEntry)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityValue(Text(verbatim: meshRuntime.isFuseOn ? Copy.meshRowOn : Copy.meshRowFusedOff))
        .accessibilityIdentifier("popopx.cabin.meshSettings")
    }

    // MARK: 派生事实（纯计算，不碰 actor）

    /// 跳数上限：引 `PopopxMeshConfig` 的常量，不写死 7（§1.1 记的就是这条出处）。
    private var relayHopCap: Int { Int(PopopxMeshConfig.default.fragmentRelayTtlCap) }
    /// 广播实际用的 TTL 上限，同样是常量；密集网络下收紧到的那个数也来自配置。
    private var broadcastTTL: Int { Int(PopopxMeshConfig.default.ttlDefault) }
    private var denseHopCap: Int { Int(PopopxMeshConfig.default.denseBroadcastTtlCap) }
    private var highDegreeThreshold: Int { PopopxMeshConfig.default.highDegreeThreshold }
    /// 在线判定的静默窗口，模块 4 的同一个常量。
    private var reachabilityWindow: TimeInterval { PopopxMeshConfig.default.peerReachabilityTimeout }

    private var radioState: PopopxBluetoothState { meshState.state.radioState }
    private var radioUsable: Bool { meshState.state.radioState.isUsable }
    private var directPeerCount: Int { meshState.state.peers.filter(\.isDirect).count }

    /// 大厅的一屏流：mesh 收到的广播 + 本机发出去的回声，按全局 `messageId` 严格去重、旧的在前。
    /// 字段映射照抄 `PopopxMeshPlazaModel.rebuildPosts(from:)`，去重规则照抄 `deduped(_:)`。
    private var mergedBroadcastPosts: [PopopxMeshPlazaPost] {
        var incoming: [PopopxMeshPlazaPost] = []
        incoming.reserveCapacity(meshState.state.broadcasts.count + localBroadcasts.count)
        for message in meshState.state.broadcasts where !message.isControlSignal {
            incoming.append(
                PopopxMeshPlazaPost(
                    id: message.messageID,
                    text: message.text,
                    timestamp: message.timestamp,
                    author: .neighbour(
                        nickname: message.senderNickname,
                        peerIDHex: message.senderPeerIDHex ?? message.messageID
                    ),
                    hopCount: message.channel.hopCount ?? 0
                )
            )
        }
        incoming.append(contentsOf: localBroadcasts)

        var seen: Set<String> = []
        var kept: [PopopxMeshPlazaPost] = []
        for post in incoming where seen.insert(post.id).inserted {
            kept.append(post)
        }
        return kept.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }

    // MARK: 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(Copy.pageTitle)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.label)
            Text(Copy.pageExplainer(relayHopCap, broadcastTTL))
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 总闸 + 射频 + 最近一次在本机射程内听到广播的时间。三行都是事实，没有装饰。
    private var statusCard: some View {
        PopopxSectionCard(
            Copy.statusTitle,
            footnote: meshRuntime.isFuseOn
                ? Copy.statusFootnote(Int(reachabilityWindow))
                : Copy.fuseOffFootnote
        ) {
            // 这一行不放青色徽标：`PopopxToggleRow` 的开关实底是原子库写死的 brand（紫），
            // 同控件里紫青并存就是 §1.1 违规。mesh 的青色语义在下面两行与雷达上说话。
            PopopxToggleRow(
                Copy.fuseRowTitle,
                note: meshRuntime.isFuseOn ? Copy.fuseOnNote : Copy.fuseOffNote,
                isOn: fuseBinding
            )
            rowSeparator
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxIconBadgeView(
                    systemName: radioUsable ? "antenna.radiowaves.left.and.right" : "wifi.slash",
                    tint: radioUsable ? .mesh : .neutral
                )
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.radioWords(radioState))
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                    Text(radioFootnote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .padding(.vertical, PopopxMetrics.spaceXS)
            .popopxAnimation(PopopxSpring.fluid, value: radioState, reduceMotion: reduceMotion)
        }
    }

    private var radioFootnote: String {
        guard meshRuntime.isFuseOn else { return Copy.fuseOffRadioNote }
        guard let latest = meshState.state.latestBroadcastAt else { return Copy.noBroadcastYet }
        return Copy.lastBroadcastWords(PopopxCabinClock.since(latest))
    }

    /// 熔断只有一个落点：`killSwitch.setEnabled(_:)`（POPOPXAPI.swift:3783 的 `setFuse` 是它唯一的生产调用者）。
    /// Binding 的 setter 不能 await，所以开关一律走同步的 `requestFuse(_:)`（:3771，它转手起一个 `setFuse`）；
    /// 而本页两个"开启总闸"按钮（:181、:417）本来就在 async 上下文里，直接 `await setFuse(true)` 再刷新。
    /// 两条路都不是本页自己写 `UserDefaults`，否则会出现「开关是关的但蓝牙还在跑」或者反过来。
    private var fuseBinding: Binding<Bool> {
        Binding(
            get: { meshRuntime.isFuseOn },
            set: { meshRuntime.requestFuse($0) }
        )
    }

    // MARK: 两个频道入口

    private var channelsCard: some View {
        PopopxSectionCard(Copy.channelsTitle, footnote: Copy.channelsFootnote) {
            PopopxPickerRow(
                Copy.hallRow,
                value: hallRowValue,
                systemImage: "bubble.left.and.bubble.right.fill",
                tint: .mesh
            ) {
                path.append(.hall)
            }
            rowSeparator
            PopopxPickerRow(
                Copy.encryptedChannelsRow,
                value: Copy.encryptedChannelsValue(channelNodes.count),
                systemImage: "lock.circle.fill",
                tint: .mesh
            ) {
                path.append(.encryptedChannels)
            }
        }
    }

    private var hallRowValue: String {
        guard meshRuntime.isFuseOn else { return Copy.fuseOffValue }
        let posts = mergedBroadcastPosts.count
        return posts == 0 ? Copy.hallEmpty : Copy.hallCount(posts)
    }

    private var channelNodes: [PopopxCabinNode] { nodes.filter(\.hasEncryptedChannel) }
    private var strangerNodes: [PopopxCabinNode] { nodes.filter { !$0.hasEncryptedChannel } }

    // MARK: 周边节点（本页唯一的 120% 细节）

    private var nearbyCard: some View {
        PopopxSectionCard(Copy.nearbyTitle(relayHopCap), footnote: nearbyFootnote) {
            PopopxCabinRadar(
                nodes: nodes,
                hopCap: relayHopCap,
                markerLimit: Self.radarMarkerLimit,
                scanning: meshRuntime.isFuseOn && radioUsable
            )
            .padding(.bottom, nodes.count > Self.radarMarkerLimit ? PopopxMetrics.spaceXS : PopopxMetrics.spaceM)
            if nodes.count > Self.radarMarkerLimit {
                Text(Copy.radarOverflow(nodes.count, Self.radarMarkerLimit))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, PopopxMetrics.spaceXS)
            }

            if !meshRuntime.isFuseOn {
                // 总闸关着就老实说没有扫描：这一屏只剩一个真的、能干活的开启按钮。
                PopopxButton(Copy.fuseTurnOn, systemImage: "antenna.radiowaves.left.and.right") {
                    await meshRuntime.setFuse(true)
                    await refresh()
                }
            } else if nodes.isEmpty {
                emptyNearbyBlock
            } else {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    PopopxCabinNodeRow(
                        node: node,
                        busy: openingNodeID == node.id,
                        open: { await self.openBluetoothChat(with: node) }
                    )
                    if index < nodes.count - 1 { rowSeparator }
                }
            }
        }
    }

    private var emptyNearbyBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            Text(radioUsable ? Copy.nearbyEmptyScanning : Copy.radioWords(radioState))
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PopopxButton(Copy.rescan, systemImage: "arrow.clockwise", role: .secondary, fullWidth: false) {
                PopopxHaptics.impact(.light)
                await refresh()
            }
        }
    }

    private var nearbyFootnote: String {
        guard meshRuntime.isFuseOn else { return Copy.fuseOffFootnote }
        if directPeerCount > highDegreeThreshold {
            return Copy.denseNetworkNote(highDegreeThreshold, denseHopCap)
        }
        return Copy.nearbyFootnote(
            Int(reachabilityWindow),
            Int(PopopxMeshReachEstimate.metresPerHop),
            broadcastTTL,
            PopopxCabinClock.metres(PopopxMeshReachEstimate.metres(hops: broadcastTTL))
        )
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }

    // MARK: - actor 读数

    /// 把三个 actor 的读数折成一屏值。只在 `.task` / `onChange` / 动作之后调用，绝不在 body 里。
    @MainActor private func refresh() async {
        guard meshRuntime.isFuseOn else {
            // 总闸关闭：不扫描、不广播、不中继，所以这一页也不许留任何「看起来还活着」的旧表。
            nodes = []
            pendingRequests = []
            return
        }
        let observed = await meshRuntime.healthMonitor.allNodes()
        let radioOn = await meshRuntime.healthMonitor.isRadioUsable
        let states = await meshRuntime.pairing.allStates()
        let requests = await meshRuntime.pairing.pendingRequests()
        let mappings = await meshRuntime.mappingStore.allMappings()

        var pairingByHex: [String: MeshPairingState] = [:]
        pairingByHex.reserveCapacity(states.count)
        for entry in states { pairingByHex[entry.peerMeshPublicKeyHex] = entry.state }

        var bindingByHex: [String: PopopxCabinNode.Binding] = [:]
        bindingByHex.reserveCapacity(mappings.count)
        for row in mappings {
            if row.contactId != nil {
                bindingByHex[row.meshPublicKeyHex] = .contact
            } else if row.isPending {
                bindingByHex[row.meshPublicKeyHex] = .pending
            } else {
                bindingByHex[row.meshPublicKeyHex] = PopopxCabinNode.Binding.none
            }
        }

        // 镜像的 peers 表按 8 字节线 id 提供昵称与 RSSI；模块 4 的表才是跳数与在线的裁判。
        var peerByID: [String: PopopxMeshPeer] = [:]
        for peer in meshState.state.peers { peerByID[peer.peerID.hex] = peer }

        let window = PopopxMeshConfig.default.peerReachabilityTimeout
        var built: [PopopxCabinNode] = []
        built.reserveCapacity(observed.count)
        for entry in observed {
            let peer = peerByID[entry.peerIDHex]
            let hex = entry.meshPublicKeyHex ?? peer?.meshPublicKey?.popopxHex
            built.append(
                PopopxCabinNode(
                    peerIDHex: entry.peerIDHex,
                    meshPublicKeyHex: hex,
                    nickname: peer?.nickname,
                    hopCount: entry.hopCount,
                    lastSeenAt: entry.lastSeenAt,
                    rssi: peer?.rssi,
                    isDirect: entry.isDirect,
                    isReachable: entry.isReachable(now: .now, radioOn: radioOn, timeout: window),
                    binding: hex.flatMap { bindingByHex[$0] } ?? PopopxCabinNode.Binding.none,
                    pairingState: hex.flatMap { pairingByHex[$0] } ?? .unlinked
                )
            )
        }
        // 模块 4 没记到的邻居也要出现：镜像的 `peers` 表是连接层的真值。在线判定用与包内私聊页
        // `peerIsInRange`（`PopopxMeshPrivateChatView.swift:317-321`）完全相同的公式——射频可用、
        // 且静默不超过同一个窗口；跳数与静默时长按镜像自己的读数说（本机持有链路时 hopCount = 0）。
        var listed: Set<String> = Set(observed.map(\.peerIDHex))
        for peer in meshState.state.peers where !listed.contains(peer.peerID.hex) {
            listed.insert(peer.peerID.hex)
            let hex = peer.meshPublicKey?.popopxHex
            built.append(
                PopopxCabinNode(
                    peerIDHex: peer.peerID.hex,
                    meshPublicKeyHex: hex,
                    nickname: peer.nickname,
                    hopCount: peer.hopCount,
                    lastSeenAt: peer.lastSeenAt,
                    rssi: peer.rssi,
                    isDirect: peer.isDirect,
                    isReachable: radioOn && Date.now.timeIntervalSince(peer.lastSeenAt) <= window,
                    binding: hex.flatMap { bindingByHex[$0] } ?? PopopxCabinNode.Binding.none,
                    pairingState: hex.flatMap { pairingByHex[$0] } ?? .unlinked
                )
            )
        }
        nodes = Self.sortedForDisplay(built)
        pendingRequests = requests
    }

    /// 在线的在前，然后跳数近的，最后按听到的时间。`allNodes()` 里被 `sweep()` 清掉之前的旧行不会
    /// 消失，所以每行都还要过一次 `isReachable`，用「超出射程」明说，而不是假装它不在了。
    private static func sortedForDisplay(_ nodes: [PopopxCabinNode]) -> [PopopxCabinNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isReachable != rhs.isReachable { return lhs.isReachable }
            if lhs.hopCount != rhs.hopCount { return lhs.hopCount < rhs.hopCount }
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.peerIDHex < rhs.peerIDHex
        }
    }

    // MARK: - 动作

    /// 「点击直接开启蓝牙私聊」的全部含义：先经模块 3 发一次离线建联邀请（唯一能让一条 Noise 私聊
    /// 会话存在的动作），再把包里那条私聊页压进栈。每条失败都有中文实话说出来；只有「这个公钥还
    /// 解析不出来」和「邀请链接本身不合法」两种情况不进私聊页——那里除了失败说明没有别的东西。
    @MainActor private func openBluetoothChat(with node: PopopxCabinNode) async {
        guard meshRuntime.isFuseOn else {
            PopopxHaptics.notice(.warning)
            toast.show(Copy.fuseOffToast, kind: .danger)
            return
        }
        guard let hex = node.meshPublicKeyHex else {
            PopopxHaptics.notice(.warning)
            toast.show(Copy.noKeyToast(node.label), kind: .danger)
            return
        }
        guard openingNodeID == nil else { return }
        openingNodeID = node.id
        defer { openingNodeID = nil }

        if node.isPaired {
            // 模块 3 已经证明配对：不再重发邀请（`initiatePairing` 对已配对会抛 `.alreadyPaired`），直接进会话。
            path.append(.privateChat(peerMeshPublicKeyHex: hex))
            return
        }

        var refusedWithoutSession = false
        do {
            _ = try await meshRuntime.pairing.initiatePairing(with: hex, incognito: false)
            PopopxHaptics.notice(.success)
            toast.show(Copy.pairingSentToast(node.label), kind: .mesh)
        } catch let pairingError {
            PopopxHaptics.notice(.error)
            toast.show(Copy.pairingWords(for: pairingError, label: node.label), kind: .danger)
            switch pairingError {
            case .peerKeyRejected, .inviteLinkRejected:
                refusedWithoutSession = true
            case .alreadyPaired, .declinedRecently, .requestUnknown, .requestSuperseded,
                 .sendFailed, .offlineBridge, .mappingStoreFailed:
                // 会话仍然值得打开：私聊页自己会重读绑定与配对证据，并把发不出去的原因逐条说清楚。
                break
            }
        }
        await refresh()
        guard !refusedWithoutSession else { return }
        path.append(.privateChat(peerMeshPublicKeyHex: hex))
    }

    /// 大厅的发送。语义逐字照抄 `PopopxMeshPlazaModel.broadcastDraft()`：先截断到上限，
    /// 无论成败本机都留一行（洪泛不回声给发送者），失败只把一句话交回大厅显示。
    @MainActor private func sendBroadcast(_ raw: String) async -> PopopxMeshSendFailure? {
        let text = String(raw.prefix(PopopxMeshPlazaModel.maxDraftCharacters))
        var failure: PopopxMeshSendFailure?
        do {
            try await meshRuntime.engineBackend.sendBroadcast(text: text)
        } catch let sendError {
            PopopxMeshLog.route.warning(
                "📡 厢语大厅广播被拒: \(String(describing: sendError.failure), privacy: .public)"
            )
            failure = sendError.failure
        }
        appendLocalBroadcast(text)
        return failure
    }

    private func appendLocalBroadcast(_ text: String) {
        guard !text.isEmpty else { return }
        var posts = localBroadcasts
        posts.append(
            PopopxMeshPlazaPost(
                id: "local:\(UUID().uuidString.lowercased())",
                text: text,
                timestamp: .now,
                author: .local,
                hopCount: 0
            )
        )
        // 上限与包内状态镜像同一个常量，超出的从头部丢。
        if posts.count > PopopxMeshStateSource.defaultCapacity {
            posts.removeFirst(posts.count - PopopxMeshStateSource.defaultCapacity)
        }
        localBroadcasts = posts
    }

    private func currentNickname() -> String {
        meshRuntime.killSwitch.nickname
            ?? PopopxMeshNicknameStore().read()
            ?? ""
    }

    /// 昵称唯一写入口 = 熔断开关自己（它 clamp、写沙盒文件、发布 `nickname`，开着时顺带重启本机 mesh）。
    @MainActor private func saveNickname() async {
        await meshRuntime.killSwitch.setNickname(nicknameText)
        nicknameText = currentNickname()
        PopopxHaptics.notice(.success)
        toast.show(Copy.nicknameSavedToast, kind: .mesh)
    }

    @MainActor private func approve(_ request: PopopxPairingRequest) async {
        let label = PopopxCabinLabel.abbreviate(request.peerMeshPublicKeyHex)
        do {
            _ = try await meshRuntime.pairing.approve(request, incognito: false)
            PopopxHaptics.notice(.success)
            toast.show(Copy.approveToast, kind: .mesh)
        } catch let pairingError {
            PopopxHaptics.notice(.error)
            toast.show(Copy.pairingWords(for: pairingError, label: label), kind: .danger)
        }
        await refresh()
    }

    @MainActor private func decline(_ request: PopopxPairingRequest) async {
        // `decline` 不抛：它只把请求丢掉并记下 60 秒冷却（`ManualPairingManager.swift:229-235`）。
        await meshRuntime.pairing.decline(request)
        PopopxHaptics.impact(.light)
        toast.show(Copy.declineToast, kind: .mesh)
        await refresh()
    }

    // MARK: - 设置中心的事实与危险动作

    /// 设置中心那三格身份事实：绑定表行数、离线队列条数、本机 mesh 静态公钥。三次 actor hop，
    /// 只在进出设置中心、翻闸、抹除之后与设置中心开着的那 2 秒一拍里做，body 一次都不问。
    @MainActor private func refreshIdentityFacts() async {
        bindingCount = await meshRuntime.mappingStore.allMappings().count
        queuedCount = await meshRuntime.router.pendingMessageCount
        // 引擎没起来时这一格是空串（`PopopxMeshEngineBackend` 不替谁造引擎），而空串不是
        // "公钥没了"——它只是"这台机器还没答过"。所以只在读到真东西时改写，抹除也不动它：
        // 抹除删的是 模块 1 的绑定表与缓存文件，本机自己的静态密钥在 Keychain 的另一个 service 里
        // （`PopopxMeshEngine.swift:102-121`），删了它反而会让对方下次认不出这台。
        let hex = await meshRuntime.engineBackend.localMeshPublicKeyHex
        if !hex.isEmpty { localKeyHex = hex }
    }

    /// 核验一次真实运行态。`waitingForSettle` 时给过渡态最多 5 × 250 ms 的等待窗口：
    /// `starting`/`stopping` 期间拿到的快照说的是"上一刻"，等它落到 on/off 才算答案。
    /// 逐字承接「我」页原来那块核验（`PopopxMeView.swift` 迁移前 :601-610），事实来源没换过。
    @MainActor private func refreshVerification(waitingForSettle: Bool) async {
        var snapshot = await meshRuntime.killSwitch.verifiedActivitySnapshot()
        if waitingForSettle {
            for _ in 0..<5 where snapshot.phase == .starting || snapshot.phase == .stopping {
                try? await Task.sleep(for: .milliseconds(250))
                snapshot = await meshRuntime.killSwitch.verifiedActivitySnapshot()
            }
        }
        verifiedSnapshot = snapshot
    }

    /// 清除离线身份绑定与本机 mesh 缓存。唯一一次调用是 模块 1 的 `emergencyWipeAllMappings()`：
    /// 它逐行清 Keychain 绑定、删两个开关偏好，并 `removeMeshCacheFiles()` 删掉
    /// `Documents/popopx_mesh/` 里的每一个文件 —— 未确认队列（`unacknowledged_mesh.json`）、
    /// 发件箱与本机昵称都在里面。包里没有任何"只清队列"的公开 API，所以这一格说的是整包删除，
    /// 不假装能只删一半；报告里 `failures` 非空就照实报数，绝不粉饰成"已清除干净"。
    @MainActor private func clearOfflineIdentity() async {
        // 顺序照包内 `MeshPrivacySettingsView.swift:211-214`：先拉闸再删。反过来会让还在跑的
        // 组件把手上的队列重新写回磁盘，那一格"已清除"就是假话。
        if meshRuntime.isFuseOn { await meshRuntime.setFuse(false) }
        let report = await meshRuntime.mappingStore.emergencyWipeAllMappings()
        await refresh()
        await refreshIdentityFacts()
        await refreshVerification(waitingForSettle: true)
        if report.isClean {
            PopopxHaptics.notice(.success)
            toast.show(Copy.wipeCleanToast, kind: .mesh)
        } else {
            PopopxHaptics.notice(.error)
            toast.show(Copy.wipeFailedToast(report.failures.count), kind: .danger)
        }
    }
}

// MARK: - 雷达（本页的签名细节）

/// 周边节点的同心雷达。静态部分是「环 + 数字跳数」，动的那圈只是一道由内向外的青色脉冲。
/// Reduce Motion 下只画静止环与数字，一次循环动画都不启动（§5 对雷达/脉冲类动画的明确要求）。
@MainActor
private struct PopopxCabinRadar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let nodes: [PopopxCabinNode]
    let hopCap: Int
    let markerLimit: Int
    let scanning: Bool

    @State private var pulseOutward = false

    /// 尺寸只用 token 表达：一边 = 48 × 3。
    private static let side: CGFloat = PopopxMetrics.space2XL * 3
    private static let dotSide: CGFloat = PopopxMetrics.spaceM + PopopxMetrics.space2XS

    var body: some View {
        ZStack {
            rings
            if scanning && !reduceMotion {
                pulse
            }
            markers
            core
        }
        .frame(width: Self.side, height: Self.side)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.radarLabel(onlineCount, nodes.count))
        .popopxAnimation(PopopxSpring.fluid, value: nodes.count, reduceMotion: reduceMotion)
        .onAppear { startPulse() }
        .onChange(of: scanning) { _, isScanning in
            if isScanning {
                startPulse()
            } else {
                pulseOutward = false
            }
        }
    }

    private var onlineCount: Int { nodes.filter(\.isReachable).count }
    private var shownNodes: [PopopxCabinNode] { Array(nodes.prefix(markerLimit)) }

    /// 三圈同心环：线宽用 §4 的 `stroke`（1.5pt），越外圈越实，最外一圈就是跳数上限那一圈。
    private var rings: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .strokeBorder(
                        PopopxPalette.mesh.opacity(0.16 + Double(index) * 0.10),
                        lineWidth: PopopxMetrics.stroke
                    )
                    .padding(Self.side * (0.055 + 0.135 * CGFloat(2 - index)))
            }
        }
    }

    private var pulse: some View {
        Circle()
            .strokeBorder(PopopxPalette.mesh, lineWidth: PopopxMetrics.stroke)
            .scaleEffect(pulseOutward ? 1 : 0.18)
            .opacity(pulseOutward ? 0.06 : 0.6)
    }

    /// 点的位置只由两个真数决定：半径 = 跳数 / 上限，角度 = 序号均分。没有任何假数据。
    private var markers: some View {
        ZStack {
            ForEach(Array(shownNodes.enumerated()), id: \.element.id) { index, node in
                marker(node: node, index: index)
            }
        }
    }

    /// 位置只由两个真数决定：半径 = 跳数 / 上限（0 跳的那一台落在最内圈），角度 = 序号在圆上均分。
    /// 三角函数一律在 `Double` 上算，再显式转回 `CGFloat`：不依赖任何隐式转换。
    private func marker(node: PopopxCabinNode, index: Int) -> some View {
        let hops = Double(min(max(node.hopCount, 0), max(hopCap, 1)))
        let radius = Double(Self.side / 2) * (0.18 + 0.74 * (hops / Double(max(hopCap, 1))))
        let degrees = Double(index) / Double(max(shownNodes.count, 1)) * 360 - 90
        let radians = degrees * .pi / 180
        return PopopxCabinHopDot(hops: node.hopCount, online: node.isReachable)
            .offset(
                x: CGFloat(radius * cos(radians)),
                y: CGFloat(radius * sin(radians))
            )
    }

    /// 中心是本机：青色 `meshInk` 描的语义（本机自己在 mesh 里），不是 SMP 的紫。
    private var core: some View {
        ZStack {
            Circle()
                .fill(PopopxPalette.meshInk.opacity(0.16))
                .frame(
                    width: Self.dotSide + PopopxMetrics.spaceXS,
                    height: Self.dotSide + PopopxMetrics.spaceXS
                )
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.meshInk)
        }
    }

    private func startPulse() {
        guard scanning, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
            pulseOutward = true
        }
    }
}

/// 青色节点点一律打印跳数数字（§1.4 第 3 条）：掉线的点退成灰圈，数字还在。
@MainActor
private struct PopopxCabinHopDot: View {
    let hops: Int
    let online: Bool

    var body: some View {
        Text("\(hops)")
            .font(PopopxType.metricSmall)
            .foregroundStyle(online ? PopopxPalette.onMesh : PopopxPalette.labelSecondary)
            .frame(width: PopopxMetrics.spaceM + PopopxMetrics.space2XS,
                   height: PopopxMetrics.spaceM + PopopxMetrics.space2XS)
            .background(online ? PopopxPalette.mesh : Color.clear, in: Circle())
            .overlay(
                Circle().strokeBorder(
                    online ? Color.clear : PopopxPalette.labelHint,
                    lineWidth: PopopxMetrics.stroke
                )
            )
            .accessibilityHidden(true)
    }
}

// MARK: - 徽章与节点行

/// 跳数徽章：`mesh` 实底 + `onMesh` 数字，永远带「N 跳」两个字（§2.2）。
@MainActor
private struct PopopxCabinHopBadge: View {
    let hops: Int

    var body: some View {
        Text(Copy.hopsWords(hops))
            .font(PopopxType.metricSmall)
            .foregroundStyle(PopopxPalette.onMesh)
            .padding(.horizontal, PopopxMetrics.space2XS)
            .padding(.vertical, PopopxMetrics.space2XS / 2)
            .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            .accessibilityHidden(true)
    }
}

/// 关系徽章：只说绑定/配对事实，一律中性色，不与青色的跳数语义抢色。
@MainActor
private struct PopopxCabinStateBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PopopxType.microTag)
            .foregroundStyle(PopopxPalette.labelSecondary)
            .padding(.horizontal, PopopxMetrics.space2XS)
            .padding(.vertical, PopopxMetrics.space2XS / 2)
            .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
    }
}

@MainActor
private struct PopopxCabinNodeRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: PopopxCabinNode
    let busy: Bool
    let open: () async -> Void

    var body: some View {
        Button(action: { Task { await open() } }) {
            HStack(spacing: PopopxMetrics.spaceS) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            node.isReachable ? PopopxPalette.mesh : PopopxPalette.labelHint,
                            lineWidth: PopopxMetrics.stroke
                        )
                        .frame(width: PopopxMetrics.spaceM, height: PopopxMetrics.spaceM)
                    if node.isReachable {
                        Circle()
                            .fill(PopopxPalette.mesh)
                            .frame(
                                width: PopopxMetrics.space2XS,
                                height: PopopxMetrics.space2XS
                            )
                    }
                }
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(node.label)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(1)
                    Text(detail)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                VStack(alignment: .trailing, spacing: PopopxMetrics.space2XS) {
                    PopopxCabinHopBadge(hops: node.hopCount)
                    if let relationshipWords {
                        PopopxCabinStateBadge(text: relationshipWords)
                    }
                }
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PopopxPalette.meshInk)
                } else {
                    Image(systemName: "chevron.right")
                        .font(PopopxType.microTag)
                        .imageScale(.medium)
                        .foregroundStyle(PopopxPalette.labelHint)
                }
            }
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(busy)
        .opacity(node.canOpenChat ? 1 : 0.72)
        .popopxAnimation(PopopxSpring.fluid, value: node.isReachable, reduceMotion: reduceMotion)
        .accessibilityLabel(Copy.rowLabel(node.label, detail, relationshipWords))
    }

    /// 一行里的每个数字都来自模块 4 或镜像：直连/中继、静默时长、RSSI，以及「超出射程」这种难听话。
    private var detail: String {
        var parts: [String] = [
            node.isDirect ? Copy.directLink : Copy.relayLink,
            Copy.lastSeenWords(node.lastSeenAt)
        ]
        if let rssi = node.rssi { parts.append(Copy.rssiWords(Int(rssi))) }
        if !node.isReachable { parts.append(Copy.outOfRangeMark) }
        if !node.canOpenChat { parts.append(Copy.noKeyMark) }
        return parts.joined(separator: " · ")
    }

    private var relationshipWords: String? {
        switch node.binding {
        case .contact: return Copy.boundBadge
        case .pending: return Copy.pendingBadge
        case .none:
            switch node.pairingState {
            case .unlinked: return nil
            case .requestSent, .requestReceived, .paired: return Copy.pairingStateWords(node.pairingState)
            }
        }
    }
}

// MARK: - #厢语大厅

/// 「#厢语大厅」整屏：完整广播流 + 广播输入 + 本机临时昵称。总闸关着时这一屏只读，
/// 并给出一个真的开启按钮，不画任何看起来能发的输入框。
@MainActor
private struct PopopxCabinHallView: View {
    let fuseOn: Bool
    let radioUsable: Bool
    @Binding var nickname: String
    let posts: [PopopxMeshPlazaPost]
    let onBroadcast: (String) async -> PopopxMeshSendFailure?
    let onSaveNickname: () async -> Void
    let onTurnOnFuse: () async -> Void

    @State private var draft = ""
    @State private var failureNote: String?

    private var trimmedDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                PopopxSectionCard(Copy.hallChannel(posts.count), footnote: Copy.hallFootnote) {
                    feed
                }

                if fuseOn {
                    composer
                    nicknameCard
                } else {
                    PopopxSectionCard(Copy.fuseOffHeadline, footnote: Copy.fuseOffFootnote) {
                        PopopxButton(Copy.fuseTurnOn, systemImage: "antenna.radiowaves.left.and.right") {
                            await onTurnOnFuse()
                        }
                    }
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
    }

    @ViewBuilder private var feed: some View {
        if posts.isEmpty {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Text(Copy.hallEmptyHeadline)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Text(Copy.hallEmptyDetail)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PopopxMetrics.spaceXS)
        } else {
            let shown = Array(posts.suffix(60))
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, post in
                bubble(post)
                if index < shown.count - 1 { rowSeparator }
            }
        }
    }

    private func bubble(_ post: PopopxMeshPlazaPost) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                HStack(spacing: PopopxMetrics.space2XS) {
                    Text(authorWords(post))
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.label)
                    // 本机自己发的没有跳数可言；收到的每一条都必须带上它走了几跳。
                    if case .neighbour = post.author {
                        PopopxCabinHopBadge(hops: post.hopCount)
                    }
                }
                Text(post.text)
                    .font(PopopxType.body)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            Text(PopopxCabinClock.clock(post.timestamp))
                .font(PopopxType.metricSmall)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
        .padding(.vertical, PopopxMetrics.space2XS)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.bubbleLabel(authorWords(post), post.text, post.hopCount))
    }

    /// 包内 `PopopxMeshPlazaPost.Author.displayName` 是英文的 "You"；这一页的中文自己说。
    private func authorWords(_ post: PopopxMeshPlazaPost) -> String {
        switch post.author {
        case .local:
            return Copy.localAuthor
        case let .neighbour(nickname, peerIDHex):
            if let nickname {
                let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return clean }
            }
            return PopopxCabinLabel.abbreviate(peerIDHex)
        }
    }

    private var composer: some View {
        PopopxSectionCard(
            radioUsable ? Copy.composerTitle : Copy.composerTitleRadioOff,
            footnote: Copy.composerFootnote(PopopxMeshPlazaModel.maxDraftCharacters)
        ) {
            PopopxTextArea(Copy.composerField, prompt: Copy.composerPrompt, text: $draft)
            HStack(spacing: PopopxMetrics.spaceXS) {
                Text(Copy.draftCount(draft.count, PopopxMeshPlazaModel.maxDraftCharacters))
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(
                        draft.count > PopopxMeshPlazaModel.maxDraftCharacters
                            ? PopopxPalette.dangerInk
                            : PopopxPalette.labelSecondary
                    )
                Spacer(minLength: PopopxMetrics.spaceXS)
                PopopxButton(Copy.broadcastSend, systemImage: "paperplane.fill", fullWidth: false) {
                    await send()
                }
                .disabled(!trimmedDraft)
            }
            if let failureNote {
                Text(failureNote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, PopopxMetrics.space2XS)
            }
            if !radioUsable {
                Text(Copy.composerRadioNote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, PopopxMetrics.space2XS)
            }
        }
    }

    private var nicknameCard: some View {
        PopopxSectionCard(
            Copy.nicknameTitle,
            footnote: Copy.nicknameFootnote(
                PopopxMeshNicknameStore.defaultNickname,
                PopopxMeshNicknameStore.maxCharacters
            )
        ) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                PopopxTextField(
                    Copy.nicknameField,
                    prompt: Copy.nicknamePrompt,
                    text: $nickname,
                    systemImage: "person.text.rectangle"
                )
                PopopxButton(Copy.nicknameSave, role: .secondary, fullWidth: false) {
                    await onSaveNickname()
                }
            }
        }
    }

    /// 发送：清空草稿、交给 runtime 的 backend；失败只把一句话留在卡上（不吞、不重试、不假装成功）。
    @MainActor private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let failure = await onBroadcast(text)
        if let failure {
            failureNote = Copy.broadcastWords(for: failure)
            PopopxHaptics.notice(.error)
        } else {
            failureNote = nil
            PopopxHaptics.notice(.success)
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - 本地加密频道

/// 本机已经与蓝牙邻居建立的 1:1 加密会话。未绑定的邻居另开一段，说清楚点它会发生什么。
@MainActor
private struct PopopxCabinChannelsView: View {
    let fuseOn: Bool
    let nodes: [PopopxCabinNode]
    let openingNodeID: String?
    let pendingCount: Int
    let onOpenChat: (PopopxCabinNode) async -> Void
    let onShowPending: () -> Void

    private var channels: [PopopxCabinNode] { nodes.filter(\.hasEncryptedChannel) }
    private var strangers: [PopopxCabinNode] { nodes.filter { !$0.hasEncryptedChannel } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                PopopxSectionCard(Copy.channelListTitle(channels.count), footnote: Copy.channelFootnote(fuseOn)) {
                    if channels.isEmpty {
                        Text(Copy.channelEmpty(fuseOn))
                            .font(PopopxType.meta)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, PopopxMetrics.spaceXS)
                    } else {
                        rows(channels)
                    }
                }

                if fuseOn, !strangers.isEmpty {
                    PopopxSectionCard(Copy.strangerTitle(strangers.count), footnote: Copy.strangerFootnote) {
                        rows(strangers)
                    }
                }

                PopopxSectionCard(Copy.pendingTitle, footnote: Copy.pendingFootnote) {
                    PopopxPickerRow(
                        Copy.pendingRow,
                        value: Copy.pendingValue(pendingCount),
                        systemImage: "envelope.badge.fill",
                        tint: .mesh,
                        action: onShowPending
                    )
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
    }

    private func rows(_ list: [PopopxCabinNode]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, node in
            PopopxCabinNodeRow(node: node, busy: openingNodeID == node.id) {
                await onOpenChat(node)
            }
            if index < list.count - 1 { rowSeparator }
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - 待决定的建联

/// 收到的建联请求：同意/拒绝都直接落到模块 3 的真方法上，与包内顶部横幅共用同一份状态，
/// 两处决定互相看得见。
@MainActor
private struct PopopxCabinPairingRequestsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let requests: [PopopxPairingRequest]
    let nodes: [PopopxCabinNode]
    let onApprove: (PopopxPairingRequest) async -> Void
    let onDecline: (PopopxPairingRequest) async -> Void

    var body: some View {
        PopopxSheetContainer(Copy.pendingSheetTitle, subtitle: Copy.pendingSheetSubtitle) {
            if requests.isEmpty {
                Text(Copy.pendingSheetEmpty)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(requests) { request in
                    PopopxSectionCard(
                        label(request),
                        footnote: Copy.pendingSince(PopopxCabinClock.since(request.receivedAt))
                    ) {
                        Text(Copy.pendingInviteHint)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: PopopxMetrics.spaceS) {
                            PopopxButton(Copy.approve, systemImage: "checkmark.seal.fill") {
                                await onApprove(request)
                            }
                            PopopxButton(Copy.decline, systemImage: "xmark.circle.fill", role: .secondary, fullWidth: false) {
                                await onDecline(request)
                            }
                        }
                        .padding(.top, PopopxMetrics.spaceS)
                    }
                }
            }
        } footer: {
            PopopxButton(Copy.close, role: .secondary) { dismiss() }
                .padding(PopopxMetrics.spaceM)
        }
        .presentationDragIndicator(.visible)
    }

    private func label(_ request: PopopxPairingRequest) -> String {
        if let node = nodes.first(where: { $0.meshPublicKeyHex == request.peerMeshPublicKeyHex }) {
            return node.label
        }
        return PopopxCabinLabel.abbreviate(request.peerMeshPublicKeyHex)
    }
}

// MARK: - 厢语离线组网设置中心

/// 「我」页的离线组网分组与「全部设置」页的厢语卡片整块搬进这里，四个落点一个都不换来源：
/// 总闸 = `PopopxMeshRuntime.requestFuse(_:)`、配对策略 = `MeshPairingPolicy` 的两个 case 经
/// `setPairingPolicy(_:)` 写进 `IdentityMappingStore`、运行态 = `PopopxMeshKillSwitch.verifiedActivitySnapshot()`、
/// 清除 = `IdentityMappingStore.emergencyWipeAllMappings()`。本视图只读宿主算好的事实、只回调，
/// 自己一次 actor 都不碰 —— 这样这张卡开着的时候，页面那份 2 秒节奏仍然是唯一的读数来源。
@MainActor
private struct PopopxCabinMeshSettingsSheet: View {
    let fuseOn: Bool
    let pairingPolicy: MeshPairingPolicy
    let snapshot: PopopxMeshActivitySnapshot?
    let nodes: [PopopxCabinNode]
    let localKeyHex: String
    let bindingCount: Int
    let queuedCount: Int
    let onToggleFuse: (Bool) -> Void
    let onSelectPolicy: (MeshPairingPolicy) -> Void
    let onVerify: () async -> Void
    let onWipe: () async -> Void
    let onClose: () -> Void

    @State private var confirmsWipe = false

    var body: some View {
        PopopxSheetContainer(Copy.meshSettingsEntry, subtitle: Copy.sheetSubtitle) {
            switchCard
            identityCard
            dangerCard
        } footer: {
            PopopxButton(Copy.close, role: .secondary) { onClose() }
                .padding(PopopxMetrics.spaceM)
        }
        .presentationDragIndicator(.visible)
        .confirmationDialog(Copy.wipeQuestion, isPresented: $confirmsWipe, titleVisibility: .visible) {
            Button(Copy.wipeAction, role: .destructive) {
                confirmsWipe = false
                Task { @MainActor in await onWipe() }
            }
            Button(Copy.cancel, role: .cancel) { confirmsWipe = false }
        } message: {
            Text(Copy.wipeDetail)
        }
    }

    // MARK: 卡 1 · 总闸与配对策略

    private var switchCard: some View {
        PopopxSectionCard(Copy.cardSwitch, footnote: Copy.meshFootnote) {
            // 这一行同样不给青色徽标：`PopopxToggleRow` 的开关实底是原子库写死的 brand 紫，
            // 同一控件里紫青并存就是 §1.1 违规（与本页状态卡那行同一个理由）。
            PopopxToggleRow(
                Copy.fuseRow,
                note: Copy.fuseRowNote,
                isOn: Binding(get: { fuseOn }, set: { onToggleFuse($0) })
            )
            // 开关的回执归调用方：原子库那枚 `Toggle` 里没有触觉，翻闸这种动作必须有手感。
            .onChange(of: fuseOn) { _, _ in PopopxHaptics.selection() }
            rowSeparator
            Text(Copy.pairingPolicy)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
                .padding(.bottom, PopopxMetrics.space2XS)
            // 只枚举 `MeshPairingPolicy` 真实存在的两个 case（IdentityMappingStore.swift:24-30）；
            // 内联单选而不是再开一张表：这一层已经是一张表了。
            ForEach(Array(MeshPairingPolicy.allCases.enumerated()), id: \.element) { _, policy in
                PopopxRadioRow(
                    policyTitle(policy),
                    note: policyNote(policy),
                    selected: pairingPolicy == policy
                ) {
                    PopopxHaptics.selection()
                    onSelectPolicy(policy)
                }
            }
        }
    }

    // MARK: 卡 2 · 节点身份与真实运行态

    private var identityCard: some View {
        PopopxSectionCard(Copy.cardIdentity, footnote: Copy.keyFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(Copy.localKeyRow)
                    .font(PopopxType.body)
                    .foregroundStyle(PopopxPalette.label)
                // 整串 64 位十六进制照原样写出来并可选中：指纹要能拿到别的信道上去比对，
                // 缩写过的串比对不出任何东西。空串说的是"这台机器还没跑过厢语"，不是"密钥丢了"。
                Text(localKeyHex.isEmpty ? Copy.localKeyAbsent : localKeyHex)
                    .font(PopopxType.metric)
                    .foregroundStyle(localKeyHex.isEmpty ? PopopxPalette.labelHint : PopopxPalette.labelSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PopopxMetrics.space2XS)
            .accessibilityElement(children: .combine)
            rowSeparator
            // 五行数字是同一张账，行内不再画分隔线；只在与上面那串十六进制、下面那块核验之间画。
            VStack(spacing: PopopxMetrics.space2XS) {
                factRow(Copy.bindingRow, "\(bindingCount)")
                factRow(Copy.queueRow, "\(queuedCount)")
                factRow(Copy.inReachRow, "\(onlineCount) / \(nodes.count)")
                factRow(Copy.relayRow, "\(relayedCount)")
                factRow(Copy.farthestRow, "\(farthestHop) / \(relayHopCap)")
            }
            .padding(.vertical, PopopxMetrics.space2XS)
            rowSeparator
            verificationBlock
        }
    }

    /// 射程内 / 经中继 / 最远跳：全部由页面已经折好的 `PopopxCabinNode` 现算，不再问任何 actor。
    /// 判据与本页雷达与节点行完全同一份（`isReachable` 是模块 4 的 `PopopxPeerReachability` 结论）。
    private var onlineCount: Int { nodes.filter(\.isReachable).count }
    private var relayedCount: Int { nodes.filter { $0.isReachable && !$0.isDirect }.count }
    private var farthestHop: Int { nodes.filter(\.isReachable).map(\.hopCount).max() ?? 0 }
    /// 跳数上限引配置常量，不写死 7（与本页 `relayHopCap` 同一出处）。
    private var relayHopCap: Int { Int(PopopxMeshConfig.default.fragmentRelayTtlCap) }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            Text(title)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.label)
            Spacer(minLength: PopopxMetrics.spaceXS)
            Text(value)
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
    }

    /// 熔断开关只是"意愿"。这一块写的是运行态：phase、真在跑的蓝牙/界面组件数、事件订阅数，
    /// 全部来自 `PopopxMeshKillSwitch.verifiedActivitySnapshot()`（包里唯一的权威答案）。
    /// 逐字承接「我」页原来那一块，事实来源与说法都没改。
    private var verificationBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "waveform.path")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.meshInk)
                    .accessibilityHidden(true)
                Text(Copy.verifyHeadline)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                PopopxButton(Copy.verifyAgain, systemImage: "arrow.clockwise", role: .ghost, fullWidth: false) {
                    await onVerify()
                }
            }
            Text(verifiedSentence)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PopopxMetrics.space2XS)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Copy.verifyHeadline))
    }

    /// 开关说的话与蓝牙真实状态的关系，全在这里说清楚：宁可写"仍在运行"也不粉饰。
    private var verifiedSentence: String {
        guard let snapshot else { return Copy.verifyPending }
        var text: String
        switch snapshot.phase {
        case .off: text = Copy.phaseOff
        case .starting: text = Copy.phaseStarting
        case .on: text = Copy.phaseOn
        case .stopping: text = Copy.phaseStopping
        }
        if snapshot.isActive {
            text += String(
                format: Copy.busySuffixFormat,
                snapshot.runningRadioWork.count,
                snapshot.runningInterfaceWork.count
            )
        } else {
            text += Copy.quietSuffix
        }
        if let subscribers = snapshot.eventHubSubscribers {
            text += String(format: Copy.subscribersSuffixFormat, subscribers)
        }
        // 磁盘开关说"开"而 phase 不是 on（或反过来）就是一次没走完的启停，也可能是崩在中间。
        if snapshot.persistedSwitch != (snapshot.phase == .on) {
            text += Copy.mismatchSuffix
        }
        return text
    }

    // MARK: 卡 3 · 离线数据与清除

    private var dangerCard: some View {
        PopopxSectionCard(Copy.cardDanger, footnote: Copy.wipeDetail) {
            // 按钮只做一件事：把二次确认抬起来。删除在那之后由宿主执行，结果由宿主的 toast 说。
            // 这里不写"已清除"，也不在取消时说任何话；`PopopxButton` 那一下绿色回执是原子库按
            // "这次 async 动作跑完了"给的，改不了（红线文件），而它被同一帧抬起来的确认框盖住。
            PopopxButton(Copy.wipeAction, systemImage: "trash", role: .destructive) {
                confirmsWipe = true
            }
        }
    }

    // MARK: 策略文案

    private func policyTitle(_ policy: MeshPairingPolicy) -> String {
        switch policy {
        case .manualConfirm: return Copy.policyManual
        case .autoSilent: return Copy.policyAuto
        }
    }

    private func policyNote(_ policy: MeshPairingPolicy) -> String {
        switch policy {
        case .manualConfirm: return Copy.policyManualNote
        case .autoSilent: return Copy.policyAutoNote
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - 时间

/// 时间只有两种说法：气泡上的 `HH:mm`（模板与包内 plaza 一致）与说明行里的相对时间。
private enum PopopxCabinClock {
    /// 每次现建一个 formatter：`DateFormatter` 不是 `Sendable`，包内 `MeshPlazaView.clock(_:)`
    /// （`MeshPlazaView.swift:417-422`）就是同样写法，这一页不把它变成 static 存属性。
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }

    private static func dated(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("M月d日 HH:mm")
        return formatter.string(from: date)
    }

    static func since(_ date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return "刚刚"
        case ..<60: return "\(seconds) 秒前"
        case ..<3_600: return "\(seconds / 60) 分钟前"
        case ..<86_400: return "\(seconds / 3_600) 小时前"
        default: return dated(date)
        }
    }

    /// 米说一遍：公里以上换单位，跟包内 `PopopxMeshReachEstimate.radius` 同一分界。
    static func metres(_ value: Int) -> String {
        value >= 1_000 ? String(format: "%.1f 公里", Double(value) / 1_000) : "\(value) 米"
    }
}

// MARK: - 图标徽章

/// `PopopxIconBadge` 是 `PopopxControls.swift:315` 里的 `private` 类型，页面外拿不到；
/// 这里按同一套 token 逐字复刻（32pt 方块 / `radiusChip` / `microTag` + `imageScale(.medium)` / `.ink`），
/// 不另立第三种画法。
@MainActor
private struct PopopxIconBadgeView: View {
    let systemName: String
    let tint: PopopxIconTint

    var body: some View {
        Image(systemName: systemName)
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(tint.ink)
            .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
            .background(tint.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            .accessibilityHidden(true)
    }
}

// MARK: - Copy

/// 这一页的每一句中文只在这里出现一次；失败路径的每一条都有实话，穷尽三个枚举的全部 case。
private enum Copy {
    static let tabTitle = "厢语"
    static let pageTitle = "厢语 · 本地蓝牙"

    static func pageExplainer(_ hopCap: Int, _ ttl: Int) -> String {
        "这一页只有本机蓝牙射程内的事：广播在 #厢语大厅 里不加密地散开，私聊走与邻居的 Noise 加密链路。广播最多走 \(ttl) 跳，中继的跳数上限 \(hopCap) 跳，全程不经公网。"
    }

    static let statusTitle = "总闸与射频"
    static let fuseRowTitle = "厢语离线组网"
    static let fuseOnNote = "开启后本机会扫描、广播，并替别台中继"
    static let fuseOffNote = "关闭后不扫描、不广播、不中继，下面所有数字都是空的"
    static let fuseOffFootnote = "总闸关闭：本机没有向蓝牙发出过一个字节。"
    static let fuseOffRadioNote = "总闸关着时射频不启动，这一行不会有读数。"
    static let fuseOffValue = "总闸关闭"
    static let fuseTurnOn = "开启厢语"
    static let noBroadcastYet = "还没有在本机射程内听到任何广播。"
    static func lastBroadcastWords(_ words: String) -> String { "最近一次听到广播：\(words)" }
    static func statusFootnote(_ window: Int) -> String {
        "在线 = 最近 \(window) 秒内听到过这台设备。总闸只写它的真值来源，这一页不自己存状态。"
    }

    static let channelsTitle = "频道"
    static let channelsFootnote = "大厅是不加密的洪泛；本地加密频道是本机与单个邻居的 Noise 链路，两条都不经服务器。"
    static let hallRow = "#厢语大厅"
    static let hallEmpty = "暂无广播"
    static func hallCount(_ posts: Int) -> String { "\(posts) 条广播" }
    static let encryptedChannelsRow = "本地加密频道"
    static func encryptedChannelsValue(_ count: Int) -> String { "\(count) 条已建立" }

    static func nearbyTitle(_ hopCap: Int) -> String { "周边 1–\(hopCap) 跳活跃设备" }
    static func nearbyFootnote(_ window: Int, _ metresPerHop: Int, _ ttl: Int, _ radius: String) -> String {
        "跳数 = 发送时的上限减去收到时的剩余值；\(window) 秒静默即判离线。一圈按每跳约 \(metresPerHop) 米估算，\(ttl) 跳最远约 \(radius)。"
    }
    static func denseNetworkNote(_ threshold: Int, _ cap: Int) -> String {
        "直连邻居已超过 \(threshold) 台：广播的跳数上限自动收紧为 \(cap) 跳，覆盖范围随之变小。"
    }
    static let nearbyEmptyScanning = "射程内暂时没有可听到的设备。走近一台已开启厢语的设备，再重新扫描。"
    static let rescan = "重新扫描"
    static func radarLabel(_ online: Int, _ total: Int) -> String {
        "雷达图：\(total) 台已知设备，\(online) 台在线；每个点里的数字是它的跳数。"
    }

    static let directLink = "直连"
    static let relayLink = "中继"
    static func lastSeenWords(_ date: Date) -> String { "最近听到 \(PopopxCabinClock.since(date))" }
    static func rssiWords(_ value: Int) -> String { "\(value) dBm" }
    static let outOfRangeMark = "已超出射程"
    static let noKeyMark = "公钥未解析"
    static let boundBadge = "已绑定"
    static let pendingBadge = "待确认"

    static let privateChatTitle = "蓝牙私聊"

    // #厢语大厅
    static func hallChannel(_ posts: Int) -> String { "#厢语大厅 · \(posts) 条" }
    static let hallFootnote = "洪泛不加密、不确认、只在蓝牙射程内；同一段文字被几台中继多次也只显示一次。"
    static let hallEmptyHeadline = "射程内还没有人说话。"
    static let hallEmptyDetail = "这里发出去的内容只洪泛给同一张 mesh 里的设备，不经过服务器，也不会留在公网。"
    static let localAuthor = "本机"
    static let composerTitle = "对这一屋子人喊话"
    static let composerTitleRadioOff = "喊话（射频当前不可用）"
    static let composerField = "广播内容"
    static let composerPrompt = "说点什么，只发给蓝牙射程内"
    static let broadcastSend = "广播"
    static func composerFootnote(_ limit: Int) -> String {
        "超过 \(limit) 字的部分会被截断。洪泛没有回执：发送成功只表示内容已经交给 mesh，不表示有人收到。"
    }
    static func draftCount(_ current: Int, _ limit: Int) -> String { "\(current) / \(limit)" }
    static let composerRadioNote = "射频不可用：内容不会离开本机，但仍会作为本机记录出现在上面那屏里。"
    static let fuseOffHeadline = "总闸关闭，大厅只读"

    static let nicknameTitle = "本机临时昵称"
    static let nicknameField = "昵称"
    static let nicknamePrompt = "广播气泡上显示的名字"
    static let nicknameSave = "保存"
    static func nicknameFootnote(_ fallback: String, _ limit: Int) -> String {
        "存在 mesh 沙盒目录里，不是密钥；留空就用默认名 \(fallback)，最长 \(limit) 字。改名会重启本机 mesh。"
    }
    /// 徽章永远带数字（§1.4 第 3 条）；0 跳就是本机持有这条链路，把「直连」一起写出来。
    static func hopsWords(_ hops: Int) -> String { hops == 0 ? "0 跳 · 直连" : "\(hops) 跳" }
    static func radarOverflow(_ total: Int, _ drawn: Int) -> String {
        "雷达一屏只画 \(drawn) 个点；下面 \(total) 行一台不少。"
    }
    static func bubbleLabel(_ author: String, _ text: String, _ hops: Int) -> String {
        "\(author)，第 \(hops) 跳收到：\(text)"
    }

    // 本地加密频道
    static func channelListTitle(_ count: Int) -> String { "已建立的私聊 · \(count)" }
    static func channelFootnote(_ fuseOn: Bool) -> String {
        fuseOn
            ? "一条频道 = 本机的绑定表里有这一行，或配对状态报已配对。点一行直接进入蓝牙私聊。"
            : "总闸关闭时不读绑定表，也不列出任何频道。"
    }
    static func channelEmpty(_ fuseOn: Bool) -> String {
        fuseOn
            ? "本机还没有与任何蓝牙邻居建立加密频道。到「周边 1–7 跳活跃设备」里点一台，就会发出离线建联邀请。"
            : "总闸关着，这一页没有任何可打开的会话。"
    }
    static func strangerTitle(_ count: Int) -> String { "未绑定的邻居 · \(count)" }
    static let strangerFootnote = "这些设备只是在射程内被听到，背后还没有联系人；点一行的结果是先发一次离线建联邀请，再进私聊页。"
    static let pendingTitle = "待你决定的建联"
    static let pendingRow = "收到的建联请求"
    static func pendingValue(_ count: Int) -> String { count == 0 ? "无" : "\(count) 条待通过" }
    static let pendingFootnote = "与顶部那条建联横幅读的是同一份配对状态，两处的决定互相看得见。"
    static let pendingSheetTitle = "收到的建联请求"
    static let pendingSheetSubtitle = "通过之后这条 mesh 公钥才会绑成离线联系人；拒绝后 60 秒内不再重复打扰。"
    static let pendingSheetEmpty = "暂时没有等待你决定的请求。"
    static let pendingInviteHint = "同意 = 接受这条邀请链接并绑定对方公钥；拒绝 = 只丢掉请求，不删任何已有联系人。"
    static func pendingSince(_ words: String) -> String { "收到于 \(words)" }
    static let approve = "同意"
    static let decline = "拒绝"
    static let close = "关闭"
    static let approveToast = "已通过建联，对方成为离线联系人"
    static let declineToast = "已拒绝这条建联请求"

    // 动作回执
    static func pairingSentToast(_ label: String) -> String { "已向 \(label) 发出离线建联邀请" }
    static func noKeyToast(_ label: String) -> String { "\(label) 的公钥还没解析出来，本机暂时无法与它私聊" }
    static let fuseOffToast = "厢语总闸关闭中，不会向蓝牙发出任何内容"
    static let nicknameSavedToast = "昵称已写入本机 mesh 沙盒"

    static func rowLabel(_ name: String, _ detail: String, _ relationship: String?) -> String {
        if let relationship { return "\(name)，\(detail)，\(relationship)" }
        return "\(name)，\(detail)"
    }

    /// 射频六态，穷尽 `PopopxBluetoothState`。
    static func radioWords(_ state: PopopxBluetoothState) -> String {
        switch state {
        case .unknown: return "蓝牙状态未知"
        case .resetting: return "蓝牙正在重置"
        case .unsupported: return "这台设备没有可用的蓝牙 Mesh"
        case .unauthorized: return "蓝牙权限未授予"
        case .poweredOff: return "蓝牙已关闭"
        case .poweredOn: return "蓝牙已开启，正在监听射程内"
        }
    }

    /// 配对四态，穷尽 `MeshPairingState`。
    static func pairingStateWords(_ state: MeshPairingState) -> String {
        switch state {
        case .unlinked: return "未配对"
        case .requestSent: return "已发出邀请，等对方通过"
        case .requestReceived: return "对方请求建联"
        case .paired: return "已配对"
        }
    }

    /// 洪泛失败六态，穷尽 `PopopxMeshSendFailure`（包内 `MeshPlazaView.words(for:)` 是 internal 且英文的，
    /// 这里说中文，事实一致）。
    static func broadcastWords(for failure: PopopxMeshSendFailure) -> String {
        switch failure {
        case .noLinkToPeer: return "没有链路可走：射程内没有设备接住这条广播"
        case .linkDropped: return "链路中断：内容没能放到蓝牙上"
        case .ttlExhausted: return "跳数用尽：这条广播走完了 TTL 还没被接住"
        case let .oversized(payloadBytes, limitBytes):
            return "超过单帧上限（\(payloadBytes) > \(limitBytes) 字节），这段内容没被分片发出去"
        case .noSessionWithPeer: return "与这台设备还没有加密会话，私聊内容发不出去"
        case let .radioUnavailable(state): return "射频不可用：\(radioWords(state))"
        }
    }

    /// 建联九态全给出路，穷尽 `PopopxPairingError`。`requestUnknown` / `requestSuperseded` 只有
    /// `approve` 会抛（`ManualPairingManager.swift:189-215`），发邀请那条路只会遇到前七种。
    static func pairingWords(for error: PopopxPairingError, label: String) -> String {
        switch error {
        case .peerKeyRejected:
            return "这条 mesh 公钥不合法，本机不会向它发任何东西"
        case .alreadyPaired:
            return "\(label) 已经是绑定过的联系人，直接进私聊就行"
        case .declinedRecently:
            return "刚刚拒绝过 \(label) 的建联，60 秒冷却期内不再重复邀请"
        case .requestUnknown:
            return "这条请求已经不在等待列表里了"
        case .requestSuperseded:
            return "对方换了一条新的邀请链接，旧的那条不会被绑定"
        case .inviteLinkRejected:
            return "邀请链接不符合本机离线门的格式，已丢弃"
        case let .sendFailed(failure):
            return "邀请已生成，但没能放到蓝牙上：\(broadcastWords(for: failure))"
        case let .offlineBridge(reason):
            return "本机离线邀请生成失败：\(reason)"
        case let .mappingStoreFailed(reason):
            return "绑定表写入失败：\(reason)；会话已经存在，但本机暂时认不出它是谁的"
        }
    }

    // MARK: 顶栏两个入口与离线组网设置中心
    //
    // 上面这一段仍是本页原有的中文直写字面量（Phase 4 那一版的写法，本次不动它，见文件头）。
    // 从这里起是新增的入口与设置中心：源文是英文原句，英文原句就是 Key，16 个译本目录里各写各的
    // 译法，`en.lproj` 按约定不写（读不到词条就回落 Key 本身，那就是英文）。
    // 从「我」页整块迁来的那几行刻意复用「我」页早已发布的同一批 Key：同一个 Key 由目录里已有的
    // 译法决定说法，两处永远同一句，这也是这次迁移唯一能保证「摘掉的那行与留下的那行说的是同一件事」的办法。
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX cabin offline mesh settings")
    }

    static let plazaEntry = key("Nearby mesh plaza")
    static let plazaHint = key("Opens the broadcast hall and the channels within Bluetooth reach")
    static let meshSettingsEntry = key("Offline mesh settings")
    static let meshRowOn = key("Fuse is open")
    static let meshRowFusedOff = key("Closed by the fuse")
    static let sheetSubtitle = key("The switch, the pairing policy, this device's mesh identity and the data it keeps, in one place.")
    /// 复用既有词条：这个 Key 在 16 个目录里都已经有译法（口径同 `PopopxMeView.swift` 的 `"Settings"`）。
    static let cancel = NSLocalizedString("Cancel", comment: "Cabin: cancelling the offline mesh wipe")

    static let cardSwitch = key("Mesh switch and pairing")
    static let meshFootnote = key("Closing the master switch stops Bluetooth scanning, advertising and relaying all at once; the other rows on this page stay readable but start no Bluetooth object.")
    static let fuseRow = key("Offline mesh master switch")
    static let fuseRowNote = key("Switching this off is the fuse: every mesh component stops together.")
    static let pairingPolicy = key("Nearby pairing policy")
    static let policyManual = key("Ask me before pairing")
    static let policyManualNote = key("A nearby pairing request shows a confirmation; nothing connects until you tap it.")
    static let policyAuto = key("Pair silently")
    static let policyAutoNote = key("Pairing completes on its own once the private Bluetooth session is up, without asking.")

    static let cardIdentity = key("Node identity and actual state")
    static let localKeyRow = key("This device's mesh key")
    static let localKeyAbsent = key("Not created on this device yet")
    static let bindingRow = key("Bound offline contacts")
    static let queueRow = key("Messages queued for a link")
    static let inReachRow = key("In reach now")
    static let relayRow = key("Reached through a relay")
    static let farthestRow = key("Farthest hop in use")
    static let keyFootnote = key("The fingerprint is this device's Noise static public key: 64 hex characters held in the keychain from the first time mesh ran on this device, unchanged by restarts. It is not your POPOPX address.")
    static let verifyHeadline = key("Actual Bluetooth state")
    static let verifyAgain = key("Verify actual state")
    static let verifyPending = key("Not verified yet in this run. Tap Verify to read the real state.")
    static let phaseOff = key("Stopped")
    static let phaseStarting = key("Starting")
    static let phaseOn = key("Running")
    static let phaseStopping = key("Stopping")
    static let quietSuffix = key(", with no component running")
    static let busySuffixFormat = NSLocalizedString(", still running %1$d Bluetooth component(s) and %2$d interface component(s)", comment: "Cabin: verified activity counts")
    static let subscribersSuffixFormat = NSLocalizedString(", %d event subscriptions", comment: "Cabin: verified event hub subscribers")
    static let mismatchSuffix = key("; the switch and the running state do not agree yet")

    static let cardDanger = key("Offline data and clearing")
    static let wipeAction = key("Clear offline bindings and cache")
    static let wipeQuestion = key("Clear offline bindings and cache on this device?")
    static let wipeDetail = key("Removes this device's offline contact bindings, both mesh switches and every file in the mesh cache folder, including the queue waiting for a link and the local nickname. This device's own mesh key stays, so neighbours already paired with it still recognise it.")
    static let wipeCleanToast = key("Offline bindings and mesh cache cleared")
    static func wipeFailedToast(_ count: Int) -> String {
        String(format: NSLocalizedString("%d items could not be cleared", comment: "Cabin: mesh wipe report failures"), count)
    }
}

// MARK: - Previews

#if DEBUG
// mesh 的类型（`PopopxMeshPeer`、`PopopxPeerReachability`）没有 public init，伪造不出数据；
// 下面每个预览都挂真单例，`bootstrap()` 就是 `Shared/POPOPXApp.swift` 启动时走的那条路径。
struct PopopxCabinView_Previews: PreviewProvider {
    static var previews: some View {
        // 栈由本页自己持有（文件头决定 4），这里再包一层就是第二个栈，`path.append` 会推到错的上面去。
        PopopxCabinView()
            .task { await PopopxMeshRuntime.shared.bootstrap() }
    }
}

// Reduce Motion 那条预览删了：`EnvironmentValues.accessibilityReduceMotion` 在这个 SDK 里是只读的
// （SwiftUICore.swiftinterface:23758 `public var … : Bool { get }`），`.environment(\.…)` 要的是
// WritableKeyPath，写不进去，也没有受支持的替身。本页三处雷达/徽章动效都读同一个环境值
// （:127、:690、:856），要验证静态雷达就把系统的开关打开：设置 → 辅助功能 → 动态效果 → 减少动态效果。

struct PopopxCabinHallView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxCabinHallView(
                fuseOn: true,
                radioUsable: true,
                nickname: .constant(PopopxMeshNicknameStore().read() ?? ""),
                posts: [],
                onBroadcast: { _ in nil },
                onSaveNickname: {},
                onTurnOnFuse: {}
            )
            .navigationTitle(Copy.hallRow)
        }
        .task { await PopopxMeshRuntime.shared.bootstrap() }
    }
}

struct PopopxCabinChannelsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxCabinChannelsView(
                fuseOn: PopopxMeshRuntime.shared.isFuseOn,
                nodes: [],
                openingNodeID: nil,
                pendingCount: 0,
                onOpenChat: { _ in },
                onShowPending: {}
            )
            .navigationTitle(Copy.encryptedChannelsRow)
        }
        .task { await PopopxMeshRuntime.shared.bootstrap() }
    }
}
#endif
