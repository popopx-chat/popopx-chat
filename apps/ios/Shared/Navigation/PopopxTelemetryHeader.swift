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
//  （PopopxMeshKit/Sources/PopopxMeshUI/PanicWipeManager.swift:357）里，app 根部已经用
//  `PopopxMeshPanicWipeMount`（Shared/Model/POPOPXAPI.swift:4053）挂载过一次。本文件的标记只是
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
        case .unknown: PopopxTelemetryCopy.unknown
        case .online: PopopxTelemetryCopy.online
        case let .degraded(reason): PopopxTelemetryCopy.onlineDegraded(reason)
        case let .meshOnly(note): note
        case .offline: PopopxTelemetryCopy.offline
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
            return .meshOnly(note: directPeerCount > 0
                ? PopopxTelemetryCopy.nearby(directPeerCount)
                : PopopxTelemetryCopy.nearbyOnly)
        }
        guard let path else { return .unknown }
        if !path.isConnected {
            return directPeerCount > 0 ? .meshOnly(note: PopopxTelemetryCopy.meshOnly(directPeerCount)) : .offline
        }
        if path.isExpensive || path.isConstrained || path.interface == .cellular {
            return .degraded(reason: degradedReason(path))
        }
        return .online
    }

    private static func degradedReason(_ path: PopopxNetworkPath) -> String {
        if path.isConstrained { return PopopxTelemetryCopy.lowDataMode }
        switch path.interface {
        case .cellular: return PopopxTelemetryCopy.cellular
        case .wifi: return PopopxTelemetryCopy.personalHotspot
        default: return PopopxTelemetryCopy.restricted
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
    /// （消息页）不是同一个宿主 —— 消息页 `ChatsListView.swift:178` 渲染它，`PopopxProximityAddContactView`
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
                Text(verbatim: user.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tag(Optional(user.userId))
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
        .accessibilityLabel(PopopxTelemetryCopy.switchIdentity)
        .accessibilityValue(currentName)
    }

    private var currentName: String {
        identities.first { $0.userId == userId }?.displayName ?? PopopxTelemetryCopy.noIdentity
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
                // 顶栏被长昵称挤窄时，`frame(width:height:)` 只会夹到更小的提案，8×8 的圆点
                // 于是被压成横向椭圆（真机第 3 轮：网络/蓝牙两枚的"外圈变形"）。
                // `fixedSize` 只锁这一颗点，整簇仍按原规则让步 —— 见本文件顶栏那行
                // 「中簇整体不 fixedSize」与 `PopopxDualStatusCapsule.body` 里的两条推论。
                .fixedSize()
                .opacity(dimmed ? 0.45 : 1)
                .scaleEffect(dimmed ? 0.8 : 1)
            Image(systemName: symbol)
                .font(PopopxType.microTag)
                .symbolRenderingMode(.hierarchical)
                .fixedSize()
            if !text.isEmpty {
                Text(verbatim: text)
                    .font(PopopxType.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, text.isEmpty ? 0 : PopopxMetrics.spaceM)
        .frame(height: PopopxMetrics.space2XL)
        // 圆点档的最小宽度是 32 不是 48：这一枚不是按钮，宽度上不承载命中区，
        // 高度 48 才是。顶栏第一行多出品牌标记之后，这 16pt 是"在线"那两个字能不能留下的差额。
        .frame(minWidth: text.isEmpty ? PopopxMetrics.spaceXL : 0)
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
        // 三档：两端全文字 → 射频退回圆点 → 两端都退回圆点。降级靠换档，不靠截断中文。
        // 2026-11-20 顶栏并到第一行后重算过占有：全文字档 206、混合档 141、双圆点档 76，
        // 而 393pt 留给这一簇的只有 76 那档（整行明细见 `PopopxTelemetryHeader` 文件头），
        // 所以 iPhone 竖屏恒定停在双圆点 —— 这不是这三档白写，宽屏与 iPad 会升档。
        // 调用方不能再对它 `.fixedSize()`：那会把 proposal 变成 nil，三档永远停在最宽一档，
        // 溢出的 HStack 以中心对齐，于是两端同时被推出安全区（T0 就是先在这里红的）。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PopopxMetrics.spaceS) { networkPill; bluetooth }
            HStack(spacing: PopopxMetrics.spaceS) { networkPill; bluetoothDot }
            HStack(spacing: PopopxMetrics.spaceS) { networkDot; bluetoothDot }
        }
    }

    private var networkPill: some View {
        PopopxStatusPill(symbol: network.symbol, text: network.label, tint: network.tint,
                         pulsing: network.isBreathing)
            .accessibilityLabel(PopopxTelemetryCopy.networkSpoken(network.label))
    }

    private var networkDot: some View {
        PopopxStatusPill(symbol: network.symbol, text: "", tint: network.tint,
                         pulsing: network.isBreathing)
            .accessibilityLabel(PopopxTelemetryCopy.networkSpoken(network.label))
    }

    private var bluetoothDot: some View {
        PopopxStatusPill(symbol: bluetooth.symbol, text: "", tint: bluetooth.tint)
            .accessibilityLabel(PopopxTelemetryCopy.bluetoothSpoken(bluetoothSpoken))
    }

    /// 射频档位说人话。`unknown` 与 `resetting` 还不能下结论，所以不给危险色。
    static func words(for radio: PopopxBluetoothState) -> String {
        switch radio {
        case .poweredOn: PopopxTelemetryCopy.radioOn
        case .poweredOff: PopopxTelemetryCopy.radioOff
        case .unauthorized: PopopxTelemetryCopy.radioUnauthorized
        case .unsupported: PopopxTelemetryCopy.radioUnsupported
        case .resetting: PopopxTelemetryCopy.radioResetting
        case .unknown: PopopxTelemetryCopy.radioUnknown
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
            Button(PopopxTelemetryCopy.addFriends, systemImage: "person.badge.plus") { onAddFriend?() }
                .disabled(onAddFriend == nil)
            Button(PopopxTelemetryCopy.startGroup, systemImage: "person.3") { onStartGroupChat?() }
                .disabled(onStartGroupChat == nil)
            Button(PopopxTelemetryCopy.scan, systemImage: "qrcode.viewfinder") { onScan?() }
                .disabled(onScan == nil)
            Divider()
            Button {
                Task { await mint() }
            } label: {
                if isMinting {
                    Label(PopopxTelemetryCopy.minting, systemImage: "hourglass")
                } else {
                    Label(PopopxTelemetryCopy.mintLink, systemImage: "link")
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
        .accessibilityLabel(PopopxTelemetryCopy.moreActions)
        .sheet(isPresented: $showsInvite, onDismiss: { invite = nil }) {
            if let invite {
                PopopxQRCardSheet(uri: invite.uri, identityName: PopopxTelemetryCopy.oneTimeLink)
            }
        }
        .alert(PopopxTelemetryCopy.mintFailedTitle, isPresented: $showsFailure) {
            Button(PopopxTelemetryCopy.dismiss, role: .cancel) {}
        } message: {
            Text(PopopxTelemetryCopy.mintFailedBody)
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
                // 24 视觉 + 44 命中。上一版写的是 48 视觉套 44 命中：外层给 44，内层仍按 48 排版，
                // 标记会左右各溢出 2pt 挤进行间距里，而这一行的行间距只有 4。
                .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("POPOPX")
        .accessibilityHint(PopopxTelemetryCopy.panicHint)
    }
}

// MARK: - 三段式头部

/// 顶部三段式导航。放在宿主的 `NavigationStack` 里（或任何工具栏位置）使用。
///
/// 2026-11-20 真机第 2 轮：这一条就是消息页的**第一行**（原先占一行的「消息」标题与
/// `.searchable` 抽屉一起撤掉，见 `ChatsListView.swift` 的 `chrome`），所以宽度按 iPhone 15 Pro 的
/// 393pt 逐件算过一遍，口径是"取各件的最小档，最长的身份名按 3 个汉字算"：
/// 内边距 16×2 = 32，标记 44，身份 104（`headerIdentityMaxWidth` 120 是上限不是占有），
/// 徽章 48（`compact` 档 = 12+24+12，符号片自己 24），双模胶囊 76（两枚圆点档 32 + 内间距 12），
/// 「+」44，六处行间距 4×6 = 24，两处 `Spacer(minLength: 4)` = 8 —— **合计 380，留 13pt 余量**。
///
/// 三条推论，都是这一版刻意的设计而不是妥协：
/// 1. 顶栏第一行**放不下任何一句状态文字**：带"在线"两个字要再 +65（445），徽章带文字要再 +96（476），
///    393pt 都不够。所以状态一律走"符号 + 颜色 + 描边 + 光晕"四重线索，文字在点开的详情页里；
///    宽屏（iPad／横屏）由 `ViewThatFits` 自动升回带字的档位，这条降级就是徽章那两档。
/// 2. 唯一可压缩的是身份名（它有 `lineLimit(1)` + 尾部省略），所以 `.layoutPriority(1)` 只给「+」
///    那一枚 44 的命中区，不给身份胶囊。上一版把优先级给身份，在 375pt 上整行溢出、两端同时被推出
///    安全区（`PopopxDualStatusCapsule` 的注释记着 T0 那次同样的翻法）。
/// 3. 行内间距从 `spaceS`(12) 降到 `space2XS`(4)、页边距从 `spaceL`(24) 收到 `gutter`(16)、
///    两处 `Spacer` 的下限同步降到 4：这三笔一共腾出 76pt，正好抵掉新加的品牌标记那 52pt
///    （同一口径算上一版无标记的那一行是 404：393 从来就不够，缺口当时被身份名的截断吃掉了，看不出来）。
///    16 还恰好和下面筛选条的 `gutter` 对齐，第一行不再比列表内容缩进 8pt。
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
        HStack(spacing: PopopxMetrics.space2XS) {
            // 紫色品牌标记 = 恐慌清除的第二入口。三击判定与确认弹窗都在状态机那一侧，
            // 保险丝断开时它只是个图案（`PopopxPanicWipeTrigger.isArmed` 的判据）。
            PopopxPanicWipeTrigger()
                .accessibilityIdentifier("popopx.header.mark")
            // 不给 `layoutPriority`：这一行里唯一该被压缩的就是身份名（`lineLimit(1)` + 尾部省略）。
            // 优先级给了它会换来整行溢出、两端被推出安全区，见上面第 2 条推论。
            PopopxIdentitySwitcher(userId: $currentUserId, identities: identities)
                .frame(maxWidth: PopopxMetrics.headerIdentityMaxWidth, alignment: .leading)
                .accessibilityIdentifier("popopx.header.identity")
            Spacer(minLength: PopopxMetrics.space2XS)
            // 中簇整体不 fixedSize：把剩余宽度真的报给两枚胶囊，它们的档位才有得选。
            // 徽章两档：带字那档要 144（短到"体验 3d 4h"也是），393pt 装不下，于是 iPhone 上恒定
            // 退到只留符号的 48；iPad／横屏自动升回带字档。状态语义由实心色片 + 描边 + 光晕承载，
            // 见 `PopopxBadgeCapsuleView` 文件头。
            ViewThatFits(in: .horizontal) {
                PopopxBadgeCapsuleView(compact: false)
                PopopxBadgeCapsuleView(compact: true)
            }
            .accessibilityIdentifier("popopx.header.badge")
            PopopxDualStatusCapsule(network: signal, radio: radioState)
            Spacer(minLength: PopopxMetrics.space2XS)
            PopopxPlusMenu(onAddFriend: onAddFriend, onStartGroupChat: onStartGroupChat, onScan: onScan)
                .fixedSize()
                .layoutPriority(1)
                .accessibilityIdentifier("popopx.header.plus")
        }
        // 16 而不是 24：与下面筛选条的 `gutter` 对齐，同时把 8pt 还给状态那一簇。
        .padding(.horizontal, PopopxMetrics.gutter)
        // 两枚胶囊自己要 48：原来按 44 夹，画出来只剩 34，点按热区跟着缩水。
        .frame(height: PopopxMetrics.space2XL)
        .background(PopopxMaterial.bar)
        .accessibilityElement(children: .contain)
    }

    private var signal: PopopxHeaderSignal { telemetry?.signal ?? network }

    private var radioState: PopopxBluetoothState {
        guard let telemetry else { return radio }
        return telemetry.radioState
    }
}

// MARK: - 文案

/// 顶栏的全部措辞。源文是英文原句，英文原句就是 Key（写法同 `PopopxCabinView.swift` 的 `key(_:)`）：
/// `en.lproj` 按约定不写，读不到词条就回落 Key 本身，那正好是英文；16 个译本目录各写各的译法。
///
/// 2026-11-20 真机第 2 轮对"中文残留"的裁定是**只翻顶栏这一处**，所以本文件与
/// `PopopxBadgeCapsuleView.swift` 里顶栏会用到的短句走词条，BadgeCredits 其余模块的中文 Copy 保持原样。
///
/// 带数字的句子一律只给一个占位符（`%@` 或 `%d`）；确实需要两个的写成 `%1$d … %2$d`。
/// 16 种语序不同，靠出现顺序排参数会在某一语种里把"3 天 2 小时"念成"2 小时 3 天"。
enum PopopxTelemetryCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX telemetry header")
    }

    private static func fmt(_ value: String, _ argument: CVarArg) -> String {
        String(format: key(value), argument)
    }

    static let unknown = key("Status unknown")
    static let online = key("Online")
    static let offline = key("Offline")
    static func onlineDegraded(_ reason: String) -> String { fmt("Online · %@", reason) }
    static let lowDataMode = key("Low data mode")
    static let cellular = key("Cellular")
    static let personalHotspot = key("Personal hotspot")
    static let restricted = key("Restricted")
    static func nearby(_ nodes: Int) -> String { fmt("Nearby · %d nodes", nodes) }
    static let nearbyOnly = key("Nearby only")
    static func meshOnly(_ nodes: Int) -> String { fmt("Offline · %d nodes", nodes) }

    static let radioOn = key("Bluetooth")
    static let radioOff = key("Bluetooth off")
    static let radioUnauthorized = key("Bluetooth not allowed")
    static let radioUnsupported = key("Not supported here")
    static let radioResetting = key("Bluetooth resetting")
    static let radioUnknown = key("Bluetooth unknown")

    static func networkSpoken(_ label: String) -> String { fmt("Network: %@", label) }
    static func bluetoothSpoken(_ label: String) -> String { fmt("Bluetooth: %@", label) }

    static let switchIdentity = key("Switch identity")
    static let noIdentity = key("No identity selected")
    static let panicHint = key("Tap three times to clear local nearby data")

    static let addFriends = key("Add friends")
    static let startGroup = key("Start a group chat or an encrypted channel")
    static let scan = key("Scan")
    static let minting = key("Generating…")
    static let mintLink = key("Create a one-time connection link")
    static let oneTimeLink = key("One-time connection link")
    static let moreActions = key("More actions")
    static let mintFailedTitle = key("The link could not be created")
    static let mintFailedBody = key("Not connected: check the network or try again later.")
    /// 复用既有词条：`"OK"` 在 17 个目录里都已经有译法，不再新造一句
    /// （口径同 `PopopxCabinView.swift` 里直接 `NSLocalizedString("Cancel", …)` 的复用行）。
    static let dismiss = NSLocalizedString("OK", comment: "Telemetry: dismissing the failed invite link")
}

// MARK: - Previews

struct PopopxTelemetryHeaderOnline_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTelemetryHeader(
            currentUserId: .constant(1),
            network: .online,
            radio: .poweredOn
        )
        .padding(.vertical, PopopxMetrics.spaceS)
        .background(PopopxPalette.base)
        .preferredColorScheme(.dark)
    }
}

struct PopopxTelemetryHeaderCellular_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTelemetryHeader(
            currentUserId: .constant(1),
            network: .resolve(proximityActive: false, directPeerCount: 0,
                              path: PopopxNetworkPath(isConnected: true, interface: .cellular, isExpensive: true)),
            radio: .poweredOn
        )
        .padding(.vertical, PopopxMetrics.spaceS)
        .background(PopopxPalette.base)
    }
}

struct PopopxTelemetryHeaderProximityOnly_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTelemetryHeader(
            currentUserId: .constant(1),
            network: .resolve(proximityActive: true, directPeerCount: 2, path: .unknown),
            radio: .poweredOn
        )
        .padding(.vertical, PopopxMetrics.spaceS)
        .background(PopopxPalette.base)
    }
}

struct PopopxTelemetryHeaderBluetoothOff_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTelemetryHeader(
            currentUserId: .constant(1),
            network: .offline,
            radio: .unauthorized
        )
        .padding(.vertical, PopopxMetrics.spaceS)
        .background(PopopxPalette.base)
    }
}
