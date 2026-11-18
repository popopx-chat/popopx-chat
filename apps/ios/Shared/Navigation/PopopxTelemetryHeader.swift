//
//  PopopxTelemetryHeader.swift
//  POPOPX (iOS)
//
//  【第三阶段 · 1】顶部三段式导航。
//
//  左：身份切换胶囊 + 品牌标记（连点三次 = 恐慌清除的第二入口）。
//  中：网络 / 蓝牙 双模状态胶囊。
//  右：微信式「+」菜单 —— 添加朋友、发起群聊或加密频道、扫一扫、生成一次性连接链接。
//
//  这一层只负责呈现与分派：真实的清场、建连、URL 规划都在被调用方里，本文件不碰。
//  设计取值一律来自 Shared/Theme/PopopxTheme.swift（PopopxPalette / PopopxMetrics / PopopxType /
//  PopopxMaterial），此文件内没有任何裸色值或裸字号。
//
//  恐慌清除不重复实现：三击判定、确认弹窗与抹除顺序都在 `PopopxPanicWipeArming`
//  （PopopxMeshKit/Sources/PopopxMeshUI/PanicWipeManager.swift:355）里，app 根部已经用
//  `PopopxMeshPanicWipeMount`（Shared/Model/POPOPXAPI.swift:3947）挂载过一次。本文件的标记只是
//  **第二个入口**：把点击转发进同一台状态机，确认弹窗仍只由根部那一处呈现 —— 不会出现两个 alert
//  抢同一次武装。
//
//  网络档位刻意不读 `UserNetworkInfo.networkType`：那个枚举在 POPOPXChat/ChatTypes.swift 里标了
//  `@available(*, deprecated, 4.0)`，而且第一个 case 自己写着 "should not happen"。这里用包里的
//  `NetworkStateMonitor`（PopopxMeshKit/Router/NetworkStateMonitor.swift:287）—— 它是 NWPath 的真值
//  来源，`PopopxNetworkPath.displayText` 已经是中文，不需要第二套措辞。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。铁律禁止脚本修改 project.pbxproj。
//

import SwiftUI
import PopopxMeshKit
import PopopxMeshUI
import POPOPXChat

// MARK: - 状态档位

/// 中间胶囊的语义档位，以及那张判定表。
enum PopopxHeaderSignal: Hashable {
    /// 还没有任何一次路径读数：中性点，不替用户猜。
    case unknown
    /// 公网可用，且路径干净（Wi-Fi／有线）。
    case online
    /// 公网可用，但打了折扣：蜂窝、受限（低数据模式）或个人热点。
    case degraded(reason: String)
    /// 只剩 BLE 近场 —— 在线通道断了也照实说。
    case meshOnly(note: String)
    /// 两头都不通。
    case offline

    var label: String {
        switch self {
        case .unknown: "状态未知"
        case .online: "在线"
        case let .degraded(reason): "在线 · \(reason)"
        case let .meshOnly(note): note
        case .offline: "离线"
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "questionmark"
        case .online: "wifi"
        case .degraded: "wifi"
        case .meshOnly: "antenna.radiowaves.left.and.right"
        case .offline: "wifi.slash"
        }
    }

    /// 色只承载通道语义（§1.1）：在线与降质都是 SMP，同用 `brand`，"蜂窝/受限"由文字区分；
    /// §1.4 第 4 条禁止绿色常驻，故在线档不用 `successInk`，也不存在 warning 色。
    var tint: Color {
        switch self {
        case .unknown: PopopxPalette.labelHint
        case .online: PopopxPalette.brand
        case .degraded: PopopxPalette.brand
        case .meshOnly: PopopxPalette.meshInk
        case .offline: PopopxPalette.labelSecondary
        }
    }

    /// 只有"近场"这一档呼吸：它是降级态，需要被注意到；其余档位是静态事实。
    var isBreathing: Bool {
        if case .meshOnly = self { return true }
        return false
    }

    /// 判定优先级：近场链路 > 无读数 > 不可用 > 打折的在线 > 干净的在线。
    ///
    /// - Parameter proximityActive: 由挂载方报告"近场引擎当前在跑"。刻意不编一条全局信号总线：
    ///   `PopopxProximityEngine` 是面对面页自己持有的 `ObservableObject`，头部拿不到也不该猜，
    ///   所以这个档位只能由持有两端的宿主在页面上／下场时调 `PopopxTelemetryModel.update(proximityActive:)`。
    ///   接线已在第四阶段完成：`PopopxProximitySheetModel.begin()`/`finish()`（:64/:69）与
    ///   `shareByTapDrop()`（:101 让出测距期间）写的就是 `PopopxTelemetryModel.shared`。
    /// - Parameter path: nil = 还没读到过任何一次 NWPath。
    static func resolve(proximityActive: Bool, directPeerCount: Int, path: PopopxNetworkPath?) -> PopopxHeaderSignal {
        if proximityActive {
            return .meshOnly(note: directPeerCount > 0 ? "近场 · \(directPeerCount) 个节点" : "仅近场")
        }
        guard let path else { return .unknown }
        if !path.isConnected {
            return directPeerCount > 0 ? .meshOnly(note: "离线 · \(directPeerCount) 个节点") : .offline
        }
        if path.isExpensive || path.isConstrained || path.interface == .cellular {
            return .degraded(reason: degradedReason(path))
        }
        return .online
    }

    private static func degradedReason(_ path: PopopxNetworkPath) -> String {
        if path.isConstrained { return "低数据模式" }
        switch path.interface {
        case .cellular: return "蜂窝网络"
        case .wifi: return "个人热点"
        default: return "受限"
        }
    }
}

// MARK: - 状态来源

/// 把三个真实来源拧成一个档位：`NetworkStateMonitor`（公网路径）、`BluetoothHealthMonitor`（射频）、
/// `PopopxMeshStateSource`（直连节点数），外加宿主报告"近场引擎在跑"。
///
/// 纯判定在 `PopopxHeaderSignal.resolve` 里，这个类只做订阅与缓存，所以那张表能脱离 SwiftUI 单独验证。
@MainActor
@Observable
final class PopopxTelemetryModel {
    /// 顶栏档位的全进程唯一实例。存在的理由只有一个：报告"近场在跑"的那一端（面对面页）和渲染顶栏的那一端
    /// （消息页）不是同一个宿主 —— 消息页 `ChatsListView.swift:166` 渲染它，`PopopxProximityAddContactView`
    /// 的 `begin()`/`finish()` 写它。给它单独再编一条总线才是多余，`resolve` 注释要的"持有两端的宿主"
    /// 因此就是这一个对象。`start()` 幂等（`pathStream == nil` 才订阅），所以重复挂载不会双订阅。
    static let shared = PopopxTelemetryModel()

    private(set) var signal: PopopxHeaderSignal = .unknown
    private(set) var radioState: PopopxBluetoothState = .unknown

    private var path: PopopxNetworkPath?
    private var proximityActive = false
    private var directPeerCount = 0
    private var pathStream: Task<Void, Never>?

    /// 写在方法体而不是默认参数上：`= .shared` 按非隔离上下文求值，会命中 `@MainActor` 的 Swift 6 隔离错误。
    private var mesh: PopopxMeshRuntime { .shared }

    /// 订阅公网路径变化。幂等：已经在订阅就直接返回，避免一条流被消费两次。
    func start(runtime: PopopxMeshRuntime? = nil) async {
        guard pathStream == nil else { return }
        let runtime = runtime ?? mesh
        pathStream = Task { [weak self] in
            for await path in await NetworkStateMonitor.shared.pathChanges() {
                self?.apply(path: path)
            }
        }
        await refresh(runtime: runtime)
    }

    func stop() {
        pathStream?.cancel()
        pathStream = nil
    }

    /// 近场档位入口：由同时持有顶栏与面对面页的宿主在页面上／下场时调用（见 `resolve` 的说明）。
    func update(proximityActive: Bool, runtime: PopopxMeshRuntime? = nil) async {
        self.proximityActive = proximityActive
        await refresh(runtime: runtime)
    }

    /// 重读射频与直连节点数。
    ///
    /// `directPeerCount` 只在这里与路径变化时刷新：`PopopxMeshStateSource.state` 虽然是可观察的，
    /// 但为一个胶囊再挂一层订阅会让整棵视图树跟着失效，不划算。
    /// `BluetoothHealthMonitor` 是 actor（`:59`），所以这里必须 async。
    func refresh(runtime: PopopxMeshRuntime? = nil) async {
        let runtime = runtime ?? mesh
        radioState = await runtime.healthMonitor.currentRadioState
        directPeerCount = runtime.stateSource.state.peers.filter(\.isDirect).count
        recompute()
    }

    private func apply(path: PopopxNetworkPath) {
        self.path = path
        recompute()
    }

    private func recompute() {
        signal = .resolve(proximityActive: proximityActive, directPeerCount: directPeerCount, path: path)
    }
}

// MARK: - 左：身份切换

/// 身份切换胶囊：一个纯 `Picker`，只把选中的 userId 写回宿主的绑定。
///
/// 刻意不在这里调 `changeActiveUserAsync_`：切换当前用户会让 api 层重载会话并重建整棵聊天视图树，
/// 那是宿主的职责。`identities` 传 `chatModel.users.map(\.user)`。
struct PopopxIdentitySwitcher: View {
    @Binding var userId: Int64?
    var identities: [User] = []

    var body: some View {
        Picker(selection: $userId) {
            ForEach(identities) { user in
                Text(verbatim: user.displayName).tag(Optional(user.userId))
            }
        } label: {
            HStack(spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "person.crop.circle")
                    .font(PopopxType.secondary)
                Text(verbatim: currentName)
                    .font(PopopxType.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(PopopxType.microTag)
                    .opacity(0.7)
            }
            .foregroundStyle(PopopxPalette.label)
            .padding(.horizontal, PopopxMetrics.spaceM)
            .frame(height: PopopxMetrics.space2XL)
            .background(PopopxPalette.card, in: .capsule)
            .overlay {
                Capsule().strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            }
            .contentShape(.capsule)
        }
        .pickerStyle(.menu)
        .accessibilityLabel("切换身份")
        .accessibilityValue(currentName)
    }

    private var currentName: String {
        identities.first { $0.userId == userId }?.displayName ?? "未选择"
    }
}

// MARK: - 中：胶囊

/// 单个状态胶囊。也单独复用，例如蓝牙健康页拿它显示射频档位。
struct PopopxStatusPill: View {
    let symbol: String
    let text: String
    let tint: Color
    var pulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Circle()
                .fill(tint)
                .frame(width: PopopxMetrics.spaceXS, height: PopopxMetrics.spaceXS)
                .opacity(dimmed ? 0.45 : 1)
                .scaleEffect(dimmed ? 0.8 : 1)
            Image(systemName: symbol)
                .font(PopopxType.microTag)
                .symbolRenderingMode(.hierarchical)
            if !text.isEmpty {
                Text(verbatim: text)
                    .font(PopopxType.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, text.isEmpty ? 0 : PopopxMetrics.spaceM)
        .frame(height: PopopxMetrics.space2XL)
        .frame(minWidth: text.isEmpty ? PopopxMetrics.space2XL : 0)
        .background(PopopxPalette.card, in: .capsule)
        .overlay {
            Capsule().strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        }
        .onAppear { restart() }
        .onChange(of: pulsing) { _, _ in restart() }
        .onChange(of: text) { _, _ in restart() }
    }

    /// 呼吸只在"确实需要被注意"时开：Reduce Motion 下彻底静止，而不是缩短。
    private func restart() {
        guard pulsing, !reduceMotion else {
            dimmed = false
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dimmed = true }
    }
}

/// 网络胶囊 + 蓝牙胶囊。窄屏靠 `ViewThatFits` 退回"只留圆点"的版本，**不截断中文**。
struct PopopxDualStatusCapsule: View {
    let network: PopopxHeaderSignal
    let bluetooth: PopopxStatusPill
    let bluetoothSpoken: String

    init(network: PopopxHeaderSignal, radio: PopopxBluetoothState, radioNote: String? = nil) {
        self.network = network
        let words = PopopxDualStatusCapsule.words(for: radio)
        self.bluetoothSpoken = radioNote ?? words
        self.bluetooth = PopopxStatusPill(
            symbol: radio.isUsable ? "radiowaves.right" : "antenna.radiowaves.left.and.right.slash",
            text: words,
            tint: radio.isUsable ? PopopxPalette.meshInk : PopopxPalette.labelHint
        )
    }

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            PopopxStatusPill(symbol: network.symbol, text: network.label, tint: network.tint,
                             pulsing: network.isBreathing)
                .accessibilityLabel("网络 \(network.label)")
            ViewThatFits(in: .horizontal) {
                bluetooth
                PopopxStatusPill(symbol: bluetooth.symbol, text: "", tint: bluetooth.tint)
            }
            .accessibilityLabel("蓝牙 \(bluetoothSpoken)")
        }
    }

    /// 射频档位说人话。`unknown` 与 `resetting` 还不能下结论，所以不给危险色。
    static func words(for radio: PopopxBluetoothState) -> String {
        switch radio {
        case .poweredOn: "蓝牙"
        case .poweredOff: "蓝牙已关"
        case .unauthorized: "蓝牙未授权"
        case .unsupported: "本机不支持"
        case .resetting: "蓝牙重置中"
        case .unknown: "蓝牙未知"
        }
    }
}

// MARK: - 右：一次性链接

/// 一次性连接链接。
struct PopopxMintedInvite: Hashable {
    let uri: String
}

/// 生成一次性连接链接。
enum PopopxInviteLink {
    /// 走 app 的真实接口 `apiAddContact(incognito:)` 建一条一次性连接，再套上本 app 的路由前缀。
    ///
    /// 刻意不调 `PopopxOfflineBridge.normalizedInviteLink`：它只校验与规范化，不生成链接。
    /// - Returns: nil = 建连失败（`apiAddContact` 自己吞掉错误并返回 nil，不抛）。调用方必须给出可见反馈，不得伪造链接。
    static func mintOneTime(incognito: Bool) async -> PopopxMintedInvite? {
        guard let (link, _) = await apiAddContact(incognito: incognito) else { return nil }
        return PopopxMintedInvite(uri: popopxChatLink(link.popopxChatUri(short: true)))
    }
}

/// 「+」菜单。四项全部实名：需要宿主上下文的两项由闭包注入，未接线时**禁用**，
/// 不摆一个看起来能点的空按钮。
struct PopopxPlusMenu: View {
    var onAddFriend: (() -> Void)? = nil
    var onStartGroupChat: (() -> Void)? = nil
    var onScan: (() -> Void)? = nil

    @State private var invite: PopopxMintedInvite?
    @State private var showsInvite = false
    @State private var showsFailure = false
    @State private var isMinting = false

    var body: some View {
        Menu {
            Button("添加朋友", systemImage: "person.badge.plus") { onAddFriend?() }
                .disabled(onAddFriend == nil)
            Button("发起群聊或加密频道", systemImage: "person.3") { onStartGroupChat?() }
                .disabled(onStartGroupChat == nil)
            Button("扫一扫", systemImage: "qrcode.viewfinder") { onScan?() }
                .disabled(onScan == nil)
            Divider()
            Button {
                Task { await mint() }
            } label: {
                if isMinting {
                    Label("正在生成…", systemImage: "hourglass")
                } else {
                    Label("生成一次性连接链接", systemImage: "link")
                }
            }
            .disabled(isMinting)
        } label: {
            Image(systemName: "plus")
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .contentShape(.circle)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("更多操作")
        .sheet(isPresented: $showsInvite, onDismiss: { invite = nil }) {
            if let invite {
                PopopxQRCardSheet(uri: invite.uri, identityName: "一次性连接链接")
            }
        }
        .alert("链接生成失败", isPresented: $showsFailure) {
            Button("好", role: .cancel) {}
        } message: {
            Text("未建立连接：请检查网络或稍后重试。")
        }
    }

    private func mint() async {
        guard !isMinting else { return }
        isMinting = true
        defer { isMinting = false }
        guard let minted = await PopopxInviteLink.mintOneTime(incognito: true) else {
            showsFailure = true
            return
        }
        invite = minted
        showsInvite = true
        PopopxHaptics.notice(.success)
    }
}

// MARK: - 品牌标记（恐慌清除第二入口）

/// 连点三次把点击转发进恐慌清除状态机；本身不做任何抹除。
///
/// 命中三击只补一次 `.heavy` 强震动作为"已武装"的确认，真正的清除必须等用户在根部的确认弹窗里按下
/// destructive 按钮（那条路径归 `PopopxPanicWipeGate`）。保险丝断开时不转发 —— 那时根部没挂确认框，
/// 武装会变成一个没有出口的中间态。
struct PopopxPanicWipeTrigger: View {
    /// 只在保险丝打开时才是入口。
    var isArmed: Bool = PopopxMeshRuntime.shared.isFuseOn

    var body: some View {
        Button {
            guard isArmed else { return }
            if PopopxMeshRuntime.shared.panicWipe.tap() {
                PopopxHaptics.impact(.heavy)
            }
        } label: {
            Image(PopopxBrandAsset.mark)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: PopopxMetrics.space2XL, height: PopopxMetrics.space2XL)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("POPOPX")
        .accessibilityHint("连点三次可清除本地近场数据")
    }
}

// MARK: - 三段式头部

/// 顶部三段式导航。放在宿主的 `NavigationStack` 里（或任何工具栏位置）使用。
struct PopopxTelemetryHeader: View {
    @Binding var currentUserId: Int64?
    var identities: [User] = []
    /// 给了 `telemetry` 就完全由它驱动；`network`／`radio` 是脱离运行时单测与预览用的显式入口。
    var telemetry: PopopxTelemetryModel? = nil
    var network: PopopxHeaderSignal = .unknown
    var radio: PopopxBluetoothState = .unknown
    var onAddFriend: (() -> Void)? = nil
    var onStartGroupChat: (() -> Void)? = nil
    var onScan: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            PopopxIdentitySwitcher(userId: $currentUserId, identities: identities)
                .fixedSize()
                .accessibilityIdentifier("popopx.header.identity")
            Spacer(minLength: PopopxMetrics.spaceS)
            PopopxDualStatusCapsule(network: signal, radio: radioState)
                .fixedSize()
            Spacer(minLength: PopopxMetrics.spaceS)
            PopopxPlusMenu(onAddFriend: onAddFriend, onStartGroupChat: onStartGroupChat, onScan: onScan)
                .accessibilityIdentifier("popopx.header.plus")
        }
        .padding(.horizontal, PopopxMetrics.spaceL)
        .frame(height: PopopxMetrics.minHitTarget)
        .background(PopopxMaterial.bar)
        .accessibilityElement(children: .contain)
    }

    private var signal: PopopxHeaderSignal { telemetry?.signal ?? network }

    private var radioState: PopopxBluetoothState {
        guard let telemetry else { return radio }
        return telemetry.radioState
    }
}

// MARK: - Previews

#Preview("三段式头部 · 干净在线") {
    PopopxTelemetryHeader(
        currentUserId: .constant(1),
        network: .online,
        radio: .poweredOn
    )
    .padding(.vertical, PopopxMetrics.spaceS)
    .background(PopopxPalette.base)
    .preferredColorScheme(.dark)
}

#Preview("三段式头部 · 蜂窝降级") {
    PopopxTelemetryHeader(
        currentUserId: .constant(1),
        network: .resolve(proximityActive: false, directPeerCount: 0,
                          path: PopopxNetworkPath(isConnected: true, interface: .cellular, isExpensive: true)),
        radio: .poweredOn
    )
    .padding(.vertical, PopopxMetrics.spaceS)
    .background(PopopxPalette.base)
}

#Preview("三段式头部 · 仅近场") {
    PopopxTelemetryHeader(
        currentUserId: .constant(1),
        network: .resolve(proximityActive: true, directPeerCount: 2, path: .unknown),
        radio: .poweredOn
    )
    .padding(.vertical, PopopxMetrics.spaceS)
    .background(PopopxPalette.base)
}

#Preview("三段式头部 · 蓝牙未授权") {
    PopopxTelemetryHeader(
        currentUserId: .constant(1),
        network: .offline,
        radio: .unauthorized
    )
    .padding(.vertical, PopopxMetrics.spaceS)
    .background(PopopxPalette.base)
}
