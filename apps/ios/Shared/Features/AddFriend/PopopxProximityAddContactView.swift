//
//  PopopxProximityAddContactView.swift
//  POPOPX (iOS)
//
//  【第三阶段 · 3】面对面双引擎物理近场加友页面。
//
//  引擎 A（自动）：`PopopxProximityEngine` 用 MultipeerConnectivity 发现并建链，握手时交换
//  `NIDiscoveryToken` 后开启 UWB 精确测距；距离 < 0.15 m 触发 `.heavy` 震动，字典序单向发包仲裁，
//  静默的一方收到链接后直接写 `IdentityMappingStore` 完成加友并自动关闭本页。
//  引擎 B（手动兜底）：「轻触密传」—— 先 `stopProximityLinkEngine()` 让出测距，再用系统分享面板
//  （`UIActivityViewController`，隔空投送）递出一次性连接链接，随后 `resume`。
//
//  射频互斥是真做的：`onAppear` 挂起 mesh 总闸（`PopopxMeshKillSwitch.setEnabled(false)` →
//  `startEverything`/`stopEverything` 一路到 `PopopxBLETransport` 的 `stopScan()` / `stopAdvertising()`，
//  PopopxMeshKit/BLE/PopopxBLETransport.swift:259、:263），`onDisappear` 里**只有进来之前总闸本来就是开的**
//  才恢复。挂起之后再用 `verifiedActivitySnapshot().isRadioQuiet` 复核，并把结论直接显示在页面上 ——
//  红线要的是"射频真的安静了"，不是"我们调用了一个方法"。
//
//  设计取值全部来自 Shared/Theme/PopopxTheme.swift，控件来自 Shared/Components/；本文件没有裸色值、
//  裸字号，也没有自造按钮。
//
//  ⚠️ 可用性：`PopopxProximityEngine` 在包里标了 `@available(iOS 17.0, *)`（裁定 A：Package.swift 保持
//  .iOS(.v15)），所以本页同样带闸门；工程用 `$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)`，不能假设 ≥17。
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target（铁律禁止脚本改 project.pbxproj）。
//

import SwiftUI
import PopopxMeshKit
import PopopxMeshUI

// MARK: - 视图模型

/// 持有近场引擎，并负责 BLE 的让出与归还。
///
/// 两个射频闭包刻意不捕获 `PopopxMeshKillSwitch` 实例：`PopopxProximityRadioHooks` 的闭包是
/// `@Sendable () async -> Void`，少捕获一个引用就少一处 Sendable 论证，所以在 `@MainActor` 的方法里
/// 现取 `PopopxMeshRuntime.shared`。
@available(iOS 17.0, *)
@MainActor
final class PopopxProximitySheetModel: ObservableObject {
    /// 挂起后复核到的"射频已安静"结论。nil = 当前没有挂起过（还没进来，或已经归还）。
    @Published private(set) var radioYielded: Bool?
    /// 「轻触密传」正在让出测距并生成链接。
    @Published private(set) var isPreparingTapDrop = false
    @Published private(set) var tapDropError: String?

    /// `lazy` 是为了让路闭包能捕获 `self`：`init` 里 `self.engine` 还没初始化完时不允许捕获 self。
    /// 首次访问发生在视图 `init` 取出引擎时（见 `PopopxProximityAddContactView.init`），仍是主线程。
    lazy var engine: PopopxProximityEngine = PopopxProximityEngine(
        bridge: PopopxMeshRuntime.shared.bridge,
        radio: PopopxProximityRadioHooks(
            suspend: { [weak self] in await self?.yieldMeshRadio() },
            resume: { [weak self] in await self?.returnMeshRadio() }
        )
    )
    let nickname: String?

    private var meshWasOn = false

    init(nickname: String?) {
        self.nickname = nickname
    }

    func begin() async {
        await engine.start(nickname: nickname)
        await reportProximity(true)
    }

    func finish() async {
        await engine.stop()
        await reportProximity(false)
    }

    func retry() async {
        await engine.stop()
        await engine.start(nickname: nickname)
        await reportProximity(true)
    }

    /// 顶栏「仅近场」档位的唯一写入点。报的是引擎的真实状态而不是页面的在场状态：
    /// 进来 `start()` 成功后才 true，离场 `stop()` 之后才 false，让出测距期间也是 false。
    /// 写的是 `PopopxTelemetryModel.shared` —— 渲染顶栏的是消息页，两端共用这一个对象，
    /// 否则就得再编一条全局总线（`resolve` 的注释里明确拒绝过）。
    private func reportProximity(_ active: Bool) async {
        await PopopxTelemetryModel.shared.update(proximityActive: active)
    }

    /// 引擎 B：让出测距 → 生成一次性链接 → 交给系统分享面板 → 恢复近场。
    ///
    /// 顺序是硬要求：分享面板弹起时如果还在测距，UWB 会话会和面板抢时间片，而用户往往要在上面停留很久，
    /// 那期间这台机器等于白占着射频。`defer` 保证分享失败也不会把近场永久停掉。
    ///
    /// 链接是**本人名片**链接（`incognito: false`）：隔空投送是点对点的物理递交，对方要连的就是这台机器
    /// 当前这个身份，匿名链接在这里只会让双方都认错人。
    func shareByTapDrop() async {
        guard !isPreparingTapDrop else { return }
        isPreparingTapDrop = true
        tapDropError = nil
        defer { isPreparingTapDrop = false }

        await engine.stopProximityLinkEngine()
        await reportProximity(false)
        defer {
            Task {
                await self.engine.resume(nickname: self.nickname)
                await self.reportProximity(true)
            }
        }

        guard let invite = await PopopxInviteLink.mintOneTime(incognito: false) else {
            tapDropError = PopopxProximityCopy.tapDropMintFailed
            return
        }
        showShareSheet(items: [invite.uri])
    }

    private func yieldMeshRadio() async {
        let fuse = PopopxMeshRuntime.shared.killSwitch
        meshWasOn = fuse.isEnabled
        guard meshWasOn else {
            // 总闸本来就是关的：不需要挂起，但也不谎称"已让出"。
            radioYielded = fuse.isActiveSnapshot.isRadioQuiet
            return
        }
        await fuse.setEnabled(false)
        radioYielded = (await fuse.verifiedActivitySnapshot()).isRadioQuiet
    }

    private func returnMeshRadio() async {
        defer { radioYielded = nil }
        guard meshWasOn else { return }
        await PopopxMeshRuntime.shared.killSwitch.setEnabled(true)
    }
}

// MARK: - 页面

/// 面对面加友页面。作为 sheet 内容呈现，关闭按钮由自己负责。
@available(iOS 17.0, *)
struct PopopxProximityAddContactView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var model: PopopxProximitySheetModel
    /// 引擎自己就是 ObservableObject：只有 model 会被 SwiftUI 观察，所以两个都要持有。
    @ObservedObject private var engine: PopopxProximityEngine
    @State private var toast = PopopxToastModel()
    @State private var dismissTask: Task<Void, Never>?

    init(nickname: String?) {
        let created = PopopxProximitySheetModel(nickname: nickname)
        _model = StateObject(wrappedValue: created)
        _engine = ObservedObject(wrappedValue: created.engine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXL) {
            header
            stage
            statusBlock
            Spacer(minLength: PopopxMetrics.spaceM)
            tapDrop
        }
        .padding(PopopxMetrics.spaceXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PopopxPalette.base)
        .popopxToast(toast)
        .onAppear {
            Task { await model.begin() }
        }
        .onDisappear {
            dismissTask?.cancel()
            Task { await model.finish() }
        }
        .onChange(of: engine.didCrossPreciseThreshold) { _, crossed in
            // 引擎只在第一次跨过 0.15 m 时置位，所以这里天然不会每帧震一下。
            guard crossed else { return }
            PopopxHaptics.impact(.heavy)
        }
        .onChange(of: engine.phase) { _, phase in
            switch phase {
            case .paired:
                PopopxHaptics.notice(.success)
                toast.show(PopopxProximityCopy.paired, kind: .success)
                dismissTask = Task {
                    try? await Task.sleep(for: PopopxProximityCopy.autoCloseDelay)
                    guard !Task.isCancelled else { return }
                    dismiss()
                }
            case .failed:
                PopopxHaptics.notice(.error)
            default:
                break
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: 标题

    private var header: some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceM) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(PopopxProximityCopy.title)
                    .font(PopopxType.title)
                    .foregroundStyle(PopopxPalette.label)
                    .accessibilityAddTraits(.isHeader)
                Text(PopopxProximityCopy.subtitle)
                    .font(PopopxType.body)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PopopxMetrics.spaceM)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                    .contentShape(.circle)
            }
            .accessibilityLabel(PopopxProximityCopy.close)
        }
    }

    // MARK: 雷达台

    @ViewBuilder
    private var stage: some View {
        if engine.supportsPreciseDistance {
            preciseStage
        } else {
            coarseStage
        }
    }

    /// 支持 UWB：同心环 + 对方按真实距离落在正上方，靠近 = 向上收拢。
    private var preciseStage: some View {
        GeometryReader { proxy in
            let reach = min(proxy.size.width, proxy.size.height) / 2
            ZStack {
                ForEach(Array(PopopxProximityCopy.ringScales.enumerated()), id: \.offset) { index, scale in
                    Circle()
                        .strokeBorder(PopopxPalette.mesh.opacity(PopopxProximityCopy.ringOpacity(index: index)),
                                      lineWidth: PopopxMetrics.hairline)
                        .frame(width: reach * 2 * CGFloat(scale), height: reach * 2 * CGFloat(scale))
                }
                Circle()
                    .fill(PopopxPalette.meshInk)
                    .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                if let ratio = peerRatio {
                    PeerMarker(label: peerLabel)
                        // 不做平面外推：只有正上方一条轴，距离映射成半径比例。
                        .offset(y: -reach * ratio)
                        .popopxAnimation(PopopxSpring.fluid, value: ratio, reduceMotion: reduceMotion)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(stageAccessibilityLabel)
    }

    /// 不支持精确测距（U1 以前的机型、模拟器）：不给假距离，只给"正在找"的确定感。
    private var coarseStage: some View {
        VStack(spacing: PopopxMetrics.spaceL) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(PopopxType.display)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                .foregroundStyle(PopopxPalette.meshInk)
            Text(PopopxProximityCopy.coarseHint)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PopopxMetrics.space2XL)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous))
        .accessibilityLabel(PopopxProximityCopy.coarseHint)
    }

    /// 真实距离 → 环半径比例。超出 `farDistanceMeters` 就贴边显示，不假装更近或更远。
    private var peerRatio: CGFloat? {
        guard let distance = engine.distanceMeters else { return nil }
        let limit = max(engine.config.farDistanceMeters, PopopxProximityCopy.minimumReachMeters)
        return min(max(CGFloat(distance / limit), 0), 1)
    }

    private var peerLabel: String {
        engine.peerNickname ?? engine.peerDisplayName ?? PopopxProximityCopy.nearbyPeer
    }

    private var stageAccessibilityLabel: String {
        guard let distance = engine.distanceMeters else { return PopopxProximityCopy.searching }
        return String(format: PopopxProximityCopy.distanceFormat, peerLabel, distance)
    }

    // MARK: 状态区

    private var statusBlock: some View {
        PopopxSectionCard(
            footnote: engine.exchange.map { _ in PopopxProximityCopy.exchangeDone }
        ) {
            StatusRow(symbol: engine.phase.popopxStageSymbol,
                      title: phaseWords,
                      note: roleWords,
                      tint: phaseTint)
            StatusRow(symbol: "antenna.radiowaves.left.and.right",
                      title: radioWords,
                      note: rangingNote,
                      tint: radioTint)
            if let failure = engine.failure {
                StatusRow(symbol: "exclamationmark.triangle.fill",
                          title: PopopxProximityCopy.failureHeadline,
                          note: failureWords(failure),
                          tint: .danger)
                PopopxButton(PopopxProximityCopy.retry, systemImage: "arrow.clockwise",
                             role: .secondary, fullWidth: false) {
                    await model.retry()
                }
                .padding(.top, PopopxMetrics.spaceS)
            }
            if let tapDropError = model.tapDropError {
                StatusRow(symbol: "square.and.arrow.up.trianglebadge.exclamationmark",
                          title: PopopxProximityCopy.tapDropErrorHeadline,
                          note: tapDropError,
                          tint: .danger)
            }
        }
        .popopxAnimation(PopopxSpring.snappy, value: phaseWords, reduceMotion: reduceMotion)
    }

    private var phaseWords: String {
        switch engine.phase {
        case .idle: PopopxProximityCopy.idle
        case .starting: PopopxProximityCopy.starting
        case .searching: PopopxProximityCopy.searching
        case .linking: String(format: PopopxProximityCopy.linking, engine.peerDisplayName ?? PopopxProximityCopy.nearbyPeer)
        case .exchanging: PopopxProximityCopy.exchanging
        case .paired: PopopxProximityCopy.paired
        case .stopped: PopopxProximityCopy.stopped
        case .failed: PopopxProximityCopy.failed
        }
    }

    private var phaseTint: PopopxIconTint {
        switch engine.phase {
        case .paired: .success
        case .failed: .danger
        case .linking, .exchanging: .mesh
        default: .neutral
        }
    }

    /// 谁发包。"本机静默接收"必须说清楚，否则用户会以为卡住了并反复重开。
    private var roleWords: String? {
        switch engine.senderRole {
        case .some(.receiver): PopopxProximityCopy.roleReceiver
        case .some(.sender): PopopxProximityCopy.roleSender
        case .some(.duplicateIdentity), .none: nil
        }
    }

    /// 测距因距离过远而暂停 —— 引擎里有这个状态，页面上就必须说。
    private var rangingNote: String? {
        engine.rangingPausedForDistance ? PopopxProximityCopy.rangingPaused : nil
    }

    private var radioWords: String {
        switch model.radioYielded {
        case .some(true): PopopxProximityCopy.radioYielded
        case .some(false): PopopxProximityCopy.radioYieldUnconfirmed
        case .none: PopopxProximityCopy.radioIdle
        }
    }

    private var radioTint: PopopxIconTint {
        switch model.radioYielded {
        case .some(true): .mesh
        case .some(false): .danger
        case .none: .neutral
        }
    }

    private func failureWords(_ failure: PopopxProximityFailure) -> String {
        switch failure {
        case .permissionDenied: PopopxProximityCopy.fPermission
        case let .discoveryUnavailable(reason): PopopxProximityCopy.fDiscovery(reason)
        case let .linkFailed(reason): PopopxProximityCopy.fLink(reason)
        case .remoteClosed: PopopxProximityCopy.fRemoteClosed
        case .nobodyFound: PopopxProximityCopy.fNobody
        case .exchangeTimeout: PopopxProximityCopy.fExchangeTimeout
        case let .unrecognizedFrame(byteCount): PopopxProximityCopy.fFrame(byteCount)
        case let .payloadRejected(reason): PopopxProximityCopy.fPayload(reason)
        case let .inviteMintFailed(reason): PopopxProximityCopy.fMint(reason)
        case let .acceptFailed(reason): PopopxProximityCopy.fAccept(reason)
        case .duplicateIdentity: PopopxProximityCopy.fDuplicate
        case .localIdentityUnavailable: PopopxProximityCopy.fLocalIdentity
        }
    }

    // MARK: 引擎 B

    private var tapDrop: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            PopopxButton(
                model.isPreparingTapDrop ? PopopxProximityCopy.tapDropBusy : PopopxProximityCopy.tapDrop,
                systemImage: "shareplay",
                role: .secondary,
                isLoading: model.isPreparingTapDrop
            ) {
                await model.shareByTapDrop()
            }
            Text(PopopxProximityCopy.tapDropFootnote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelHint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 雷达上的对方标记

@available(iOS 17.0, *)
private struct PeerMarker: View {
    let label: String

    var body: some View {
        VStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: "person.crop.circle.fill")
                .font(PopopxType.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PopopxPalette.brand)
            Text(verbatim: label)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .lineLimit(1)
                .padding(.horizontal, PopopxMetrics.spaceXS)
                .background(PopopxPalette.card.opacity(0.9), in: .capsule)
        }
        .accessibilityHidden(true)
    }
}

/// Shared/Components 里的行标签是 `private`，所以本页自带一个同规格的行：
/// 同样的图标尺寸、同样的三段间距，不新造视觉语言。
@available(iOS 17.0, *)
private struct StatusRow: View {
    let symbol: String
    let title: String
    var note: String?
    let tint: PopopxIconTint

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.spaceS) {
                Image(systemName: symbol)
                    .font(PopopxType.secondary)
                    .foregroundStyle(tint.ink)
                    .frame(width: PopopxMetrics.spaceXL)
                Text(verbatim: title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(verbatim: note)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .padding(.leading, PopopxMetrics.spaceXL + PopopxMetrics.spaceS)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 阶段图标

extension PopopxProximityPhase {
    /// 阶段对应的 SF Symbol。放在 app 侧而不是包里：包只负责状态机，图标是这一版视觉语言的决定。
    fileprivate var popopxStageSymbol: String {
        switch self {
        case .idle: "circle"
        case .starting: "rays"
        case .searching: "magnifyingglass"
        case .linking: "link"
        case .exchanging: "envelope.closed.fill"
        case .paired: "checkmark.circle.fill"
        case .stopped: "stop.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}

// MARK: - 文案与几何

private enum PopopxProximityCopy {
    static let title = "面对面加友"
    static let subtitle = "靠近自动感应，或底部轻触连接"
    static let close = "关闭"
    static let nearbyPeer = "附近的人"
    static let searching = "正在寻找附近的 POPOPX"
    static let distanceFormat = "%1$@，距离约 %2$.2f 米"
    static let coarseHint = "本机不支持精确测距：请保持在 1 米内，连上后会自动交换名片"
    static let autoCloseDelay = Duration.seconds(1.4)

    static let idle = "准备中"
    static let starting = "正在开启近场"
    static let linking = "已连上 %@"
    static let exchanging = "正在交换加密名片"
    static let paired = "已加为好友"
    static let stopped = "近场已停止"
    static let failed = "未能完成"
    static let exchangeDone = "名片已交换"

    static let roleSender = "由本机发出邀请"
    static let roleReceiver = "本机静默接收，无需操作"
    static let rangingPaused = "距离过远，测距已暂停"

    static let radioIdle = "蓝牙未被本页占用"
    static let radioYielded = "蓝牙已让出给近场加友"
    static let radioYieldUnconfirmed = "蓝牙让出未确认：若长时间无反应，请关闭本页重试"

    static let failureHeadline = "近场加友未完成"
    static let retry = "重试"
    static let tapDrop = "轻触密传"
    static let tapDropBusy = "正在生成链接…"
    static let tapDropErrorHeadline = "轻触密传未发出"
    static let tapDropMintFailed = "未能生成连接链接，请检查网络后重试"
    static let tapDropFootnote = "距离太远，或对方机型不支持近场时：用系统分享面板（隔空投送）把链接直接递给对方"

    static let fPermission = "缺少蓝牙权限：请到「设置 › 隐私与安全 › 蓝牙」开启后重试"
    static func fDiscovery(_ reason: String) -> String { "近场发现不可用：\(reason)" }
    static func fLink(_ reason: String) -> String { "近场链路未能建立：\(reason)" }
    static let fRemoteClosed = "对方已退出近场"
    static let fNobody = "没有找到其他开启近场的 POPOPX"
    static let fExchangeTimeout = "名片交换超时，请重新靠近一次"
    static func fFrame(_ byteCount: Int) -> String { "收到无法识别的数据（\(byteCount) 字节），已丢弃" }
    static func fPayload(_ reason: String) -> String { "名片内容被拒绝：\(reason)" }
    static func fMint(_ reason: String) -> String { "链接生成失败：\(reason)" }
    static func fAccept(_ reason: String) -> String { "接受邀请失败：\(reason)" }
    static let fDuplicate = "对方与本机是同一身份"
    static let fLocalIdentity = "本机身份不可用，请先在设置里开启厢语"

    /// 环的半径比例（外 / 中 / 内），以及由外的。
    static let ringScales: [Double] = [1.0, 0.66, 0.33]

    /// 越靠内的环越实：读起来是"距离刻度"，不是装饰。
    static func ringOpacity(index: Int) -> Double { 0.3 + Double(index) * 0.2 }

    /// `farDistanceMeters` 被配成 0 时的下限，避免比例除零。
    static let minimumReachMeters = 0.01
}

// MARK: - Preview

/// 页面本体带 iOS 17 闸门，预览不能直接构造它：这里放一个非闸门的外壳，运行时再判。
#if DEBUG
struct PopopxProximityPreviewHost_Previews: PreviewProvider {
    static var previews: some View {
        PopopxProximityPreviewHost()
    }
}

private struct PopopxProximityPreviewHost: View {
    var body: some View {
        if #available(iOS 17.0, *) {
            PopopxProximityAddContactView(nickname: nil)
        } else {
            Text("需要 iOS 17 以上")
                .font(PopopxType.body)
                .padding(PopopxMetrics.spaceXL)
        }
    }
}
#endif
