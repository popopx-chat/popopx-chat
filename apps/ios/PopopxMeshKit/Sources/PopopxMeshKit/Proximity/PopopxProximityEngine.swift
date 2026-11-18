//
//  PopopxProximityEngine.swift
//  PopopxMeshKit  —  模块 8（第三阶段：面对面双引擎物理近场加友）
//
//  Two phones, two screens apart, no server, no Wi-Fi, no QR code to photograph. Engine A is the
//  physical half: MultipeerConnectivity carries the bytes and, on a U1/U2 device, NearbyInteraction
//  measures how far apart the two hands are. Engine B is not here — TapDrop needs a
//  `UIActivityViewController`, which is UIKit and therefore belongs to the view layer; this file
//  exposes `stopProximityLinkEngine()` for it and nothing else about it.
//
//  Three properties the rest of the module depends on:
//
//  1. 射频互斥是真的，不是标志位。`start()` awaits the host's `suspend` hook before it opens a
//     single MC object, and `stop()` awaits `resume` after it has torn its own objects down. What
//     the hook reaches in this app is `PopopxBLETransport.shutDown()`, which calls
//     `centralManager?.stopScan()` (BLE/PopopxBLETransport.swift:259) and
//     `peripheralManager?.stopAdvertising()` (:263) — the mesh radio is off the channel while the
//     pairing screen owns it. `radio` deliberately has no default value: a silent `{}` here would
//     ship a screen that pre-empts the mesh and looks fine in a preview.
//
//  2. 单向发包。Both devices advertise, browse and exchange handshakes — that traffic creates
//     nothing. Exactly one of them mints an invite link, and which one is decided by the
//     lexicographically larger peer display name (mesh key breaks an equal-name tie, which two
//     devices with no nickname would otherwise produce forever). The other side stays silent until
//     the payload lands and then does the accept itself. Two `/_connect` calls for one pairing would
//     leave a pending contact on both sides pointing at each other's pending contact, i.e. two
//     half-connections instead of one friendship.
//
//  3. 载荷先验证后进核心。`PopopxProximityFrame.parse` refuses a wrong prefix, an oversized frame or
//     a decode failure before anything is called, and the mesh key and the link are re-validated
//     against 模块 1's canonical form and `PopopxOfflineBridge.normalizedInviteLink` before
//     `acceptOfflineInviteLink` sees them. A peer's bytes never reach `chat_send_cmd_retry` unescaped.
//
//  MultipeerConnectivity is still what 第三阶段 specifies, even though the SDK stamps the whole
//  framework `API_DEPRECATED("Use Network Framework instead", ios(7.0, 27.0))`: `NWConnection` has no
//  advertiser/browser half-handshake, no `MCPeerID.displayName` for the lexicographic arbitration to
//  read, and no `NIDiscoveryToken` exchange, so replacing it here would delete the two facts this
//  state machine is built on. That deprecation range ends at 27.0, so this file compiles without a
//  single deprecation warning — re-measure with `grep -E ':[0-9]+: warning:' <gate log>` if the SDK
//  ever includes the current version. Moving to Network.framework is a Phase 5 decision.
//
//  Everything below `#if os(iOS)` is hardware-facing and therefore iOS-only: the package still
//  builds for the macOS host (`Package.swift:10`), where the payload types and the arbitration
//  function above it are compiled, tested and used exactly as written here.
//

import Foundation

// MARK: - Wire payload

/// The invite the sender hands over: a one-time connection link plus the mesh identity that link
/// belongs to. One pair of facts, because the link alone would leave the mesh key unmapped and the
/// key alone would leave nothing to connect over.
public struct PopopxProximityExchange: Codable, Hashable, Sendable {
    /// Bumped only by a change both builds must agree about; an unknown version is refused rather
    /// than guessed at, because guessing here means building a connection from a misread link.
    public static let payloadVersion = 1

    public let version: Int
    /// Our X25519 mesh public key, in 模块 1's canonical (lower-case hex) spelling.
    public let meshPublicKeyHex: String
    /// Canonical `popopx:/…` form, already through `normalizedInviteLink` on the way out.
    public let inviteLink: String
    /// The plaza nickname we advertise, if the user ever chose one. Display only: nothing keys off
    /// it, and the receiver's mesh binding is keyed by `meshPublicKeyHex`.
    public let nickname: String?

    public init(
        meshPublicKeyHex: String,
        inviteLink: String,
        nickname: String? = nil,
        version: Int = Self.payloadVersion
    ) {
        self.version = version
        self.meshPublicKeyHex = meshPublicKeyHex
        self.inviteLink = inviteLink
        self.nickname = nickname
    }
}

/// Sent by *both* sides as soon as the MC link is up. It is not the invitation: it creates no
/// connection, binds nothing, and only tells the peer who it is talking to and how to range them.
/// Public because it is the associated value of a public `PopopxProximityFrame` case.
public struct PopopxProximityHandshake: Codable, Hashable, Sendable {
    public let meshPublicKeyHex: String
    public let nickname: String?
    /// Our `NIDiscoveryToken`, securely archived. nil on a device with no UWB chip, which is the
    /// normal case on iPhone 13 and earlier and on every Mac.
    public let discoveryTokenData: Data?

    public init(meshPublicKeyHex: String, nickname: String?, discoveryTokenData: Data?) {
        self.meshPublicKeyHex = meshPublicKeyHex
        self.nickname = nickname
        self.discoveryTokenData = discoveryTokenData
    }
}

/// The one framing of the whole exchange. A frame is the prefix string followed by one JSON object,
/// so a stray byte stream from another app on the same service type is refused on the prefix alone.
public enum PopopxProximityFrame: Codable, Hashable, Sendable {
    case handshake(PopopxProximityHandshake)
    case exchange(PopopxProximityExchange)

    /// 第三阶段 fixed the literal. It is on the wire, not in a comment: a receiver that cannot see
    /// it decodes nothing.
    public static let prefix = "POPOPX_PROXIMITY:"

    /// A full contact invitation is ~200 bytes; a frame that needs more than this is a flood or a
    /// different protocol, and it is dropped before `JSONDecoder` allocates for it.
    public static let maxWireBytes = 8_192

    public func wireData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var payload = try encoder.encode(self)
        let header = Data(Self.prefix.utf8)
        payload.insert(contentsOf: header, at: 0)
        return payload
    }

    /// nil for anything we do not recognise: wrong prefix, oversized frame, invalid UTF-8, a JSON
    /// document that is not an array of the two fields `Codable` produces for this enum, or an
    /// unknown version. Never a thrown error — a pairing screen must be able to shrug at a stranger.
    public static func parse(_ data: Data) -> PopopxProximityFrame? {
        guard data.count <= Self.maxWireBytes else { return nil }
        let header = Array(Self.prefix.utf8)
        guard data.count > header.count else { return nil }
        guard Array(data.prefix(header.count)) == header else { return nil }
        guard let frame = try? JSONDecoder().decode(Self.self, from: data.dropFirst(header.count)) else {
            return nil
        }
        if case let .exchange(payload) = frame, payload.version != PopopxProximityExchange.payloadVersion {
            return nil
        }
        return frame
    }

    /// Too big to be one of ours. Reported separately from `parse` returning nil so the UI can say
    /// "对端发送了异常数据" instead of pretending the peer never spoke.
    public static func isOversized(_ data: Data) -> Bool {
        data.count > Self.maxWireBytes
    }
}

// MARK: - Arbitration

/// Who speaks. Pure, so the rule that prevents a double connection can be tested without two radios.
public enum PopopxProximitySenderRole: String, Hashable, Sendable {
    /// We mint the invite link and send it; the peer accepts.
    case sender
    /// We say nothing and wait to receive; the accept happens here.
    case receiver
    /// The two sides are indistinguishable by name *and* by mesh key, which means we are looking at
    /// our own device or a replay of it. Nobody speaks, and the UI says why.
    case duplicateIdentity
}

/// 字典序单向发包仲裁. Display names first, because that is what 第三阶段 specifies and what a user
/// can read and change; the mesh key second, because `PopopxMeshNicknameStore.defaultNickname` is
/// the same string on every device that never set one, and name-only arbitration would freeze the
/// pairing at `duplicateIdentity` for exactly the two users who most need it to work.
public func popopxProximitySenderRole(
    myDisplayName: String,
    remoteDisplayName: String,
    myMeshPublicKeyHex: String,
    remoteMeshPublicKeyHex: String
) -> PopopxProximitySenderRole {
    if myDisplayName != remoteDisplayName {
        return myDisplayName > remoteDisplayName ? .sender : .receiver
    }
    if myMeshPublicKeyHex != remoteMeshPublicKeyHex {
        return myMeshPublicKeyHex > remoteMeshPublicKeyHex ? .sender : .receiver
    }
    return .duplicateIdentity
}

// MARK: - State reported to the view

/// What stage the exchange is at, in the order a successful run visits them.
public enum PopopxProximityPhase: String, Hashable, Sendable {
    case idle
    /// The mesh radio is being handed over and the MC objects are being built.
    case starting
    /// Advertising and browsing; nobody found yet.
    case searching
    /// MC link up, handshakes in flight, UWB about to start.
    case linking
    /// The decided role is doing its work: one side mints, the other waits.
    case exchanging
    /// The link is created and the mesh identity is bound.
    case paired
    case stopped
    /// Something refused; the reason is in `failure`.
    case failed
}

/// Every way this can go wrong, with the reason kept as a string because the reasons that matter are
/// the ones the system gave us. The view turns these into 中文 copy; nothing here guesses a cause.
public enum PopopxProximityFailure: Hashable, Sendable {
    /// 蓝牙权限被拒或受限（`CBManager.authorization`）。这是唯一能确定区分的失败：MC 对「权限没给」和
    /// 「蓝牙关了」返回同一个 `MCErrorUnavailable`，而本地网络权限在 TCC 里根本不可查询。
    case permissionDenied
    /// Advertiser and browser both failed to start, or the radio is off.
    case discoveryUnavailable(reason: String)
    /// 链接在载荷送达前断开。
    case linkFailed(reason: String)
    case remoteClosed
    /// 30 秒内附近没有任何设备 —— UI 应改口推荐「扫一扫」或「轻触密传」。
    case nobodyFound
    /// 链接已建立，但对端没有在 `exchangeTimeout` 内把邀请发来。
    case exchangeTimeout
    /// 对端发来的帧不是我们的协议，或者超过了 `maxWireBytes`。
    case unrecognizedFrame(byteCount: Int)
    /// 帧能解码，但 mesh 公钥或邀请链接没有通过校验。
    case payloadRejected(reason: String)
    /// `/_connect incognito=…` 在我们这一侧就失败了，链接压根没生成。
    case inviteMintFailed(reason: String)
    /// 我们接受了链接，核心却没有返回 pending connection。
    case acceptFailed(reason: String)
    /// 两个设备既同名又同密钥：把本机当成了对端。
    case duplicateIdentity
    /// 本机拿不到 mesh 身份，面对面加友无从绑定。
    case localIdentityUnavailable
}

#if os(iOS)
import CoreBluetooth
import MultipeerConnectivity
import NearbyInteraction

// MARK: - Radio handover

/// The two hooks that make 射频互斥 real. `suspend` runs before any MC object exists, `resume` after
/// every one of ours is gone, and only `resume` is conditional — the host decides whether the mesh
/// should come back at all, which is how「前提是总开关开启」is honoured without this module owning a
/// second copy of the fuse.
public struct PopopxProximityRadioHooks: Sendable {
    public let suspend: @Sendable () async -> Void
    public let resume: @Sendable () async -> Void

    public init(suspend: @Sendable @escaping () async -> Void, resume: @Sendable @escaping () async -> Void) {
        self.suspend = suspend
        self.resume = resume
    }

    /// For previews, tests and any host that has no mesh radio. Named for what it is, so calling it
    /// is a decision somebody wrote down rather than a missing argument.
    public static let noMeshRadio = PopopxProximityRadioHooks(suspend: {}, resume: {})
}

/// Tunables, all of them 第三阶段's numbers, none of them magic.
///
/// `TimeInterval`, not `Duration`: this value type is not availability-gated (the fuse and the
/// settings page read it), and `Duration` is iOS 16 while the package floor is iOS 15
/// (`Package.swift:9`). The engine converts at the `Task.sleep(for:)` call sites, which do live
/// inside the `@available(iOS 17.0, *)` type.
public struct PopopxProximityConfig: Hashable, Sendable {
    /// MC service type. Bonjour publishes it as `_popopx-uwb._tcp`, which is the entry
    /// `NSBonjourServices` needs; MC itself wants the name without the underscore and the suffix.
    public var serviceType: String
    /// 无发现自动回退提示的时间。
    public var discoveryTimeout: TimeInterval
    /// 链接已建立、对端迟迟不发包的时间。
    public var exchangeTimeout: TimeInterval
    /// 测距持续超过这个距离就暂停 UWB，并让「轻触密传」成为主行动。
    public var farDistanceMeters: Double
    /// 连续这么久而没有一次近距样本，才算「远离」。
    public var farDistanceGrace: TimeInterval
    /// 跌破这个距离触发一次重击触觉（由视图执行 `PopopxHaptics.impact(.heavy)`，见下面注释）。
    public var preciseThresholdMeters: Double

    public init(
        serviceType: String = "popopx-uwb",
        discoveryTimeout: TimeInterval = 30,
        exchangeTimeout: TimeInterval = 20,
        farDistanceMeters: Double = 0.5,
        farDistanceGrace: TimeInterval = 5,
        preciseThresholdMeters: Double = 0.15
    ) {
        self.serviceType = serviceType
        self.discoveryTimeout = discoveryTimeout
        self.exchangeTimeout = exchangeTimeout
        self.farDistanceMeters = farDistanceMeters
        self.farDistanceGrace = farDistanceGrace
        self.preciseThresholdMeters = preciseThresholdMeters
    }
}

/// The face-to-face pairing state machine.
///
/// `@MainActor` rather than an actor, and it is also the MC/NI delegate: MultipeerConnectivity has
/// no `delegateQueue` to choose and delivers on the main queue, and `NISession.delegateQueue` is
/// documented to default to the main queue, so the callbacks and the isolation already agree — that
/// is a property of the frameworks, not a trick, and it is why nothing here needs a lock. The price
/// is that a payload is decoded on the main thread; it is 200 bytes of ASCII and it buys a state
/// machine SwiftUI can observe without a mirror.
@available(iOS 17.0, *)
@MainActor
public final class PopopxProximityEngine: NSObject, ObservableObject {
    public static let defaultServiceType = "popopx-uwb"
    /// 15 厘米：贴在一起的距离。
    public static let preciseThresholdMeters = 0.15
    /// `MCPeerID.displayName` 的上限是 63 字节，按 UTF-8 字节裁剪，而不是按字符。
    public static let maxPeerDisplayNameBytes = 63
    /// MC invitations time out; 30 seconds matches the browse window we give the user anyway.
    public static let invitationTimeout: TimeInterval = 30

    @Published public private(set) var phase: PopopxProximityPhase = .idle
    /// 本机是否具备精确测距（U1/U2）。false 时 UI 隐藏雷达，把「轻触密传」放大为主按钮。
    @Published public private(set) var supportsPreciseDistance = false
    @Published public private(set) var senderRole: PopopxProximitySenderRole?
    @Published public private(set) var peerDisplayName: String?
    @Published public private(set) var peerNickname: String?
    /// nil = 这个采样周期没有距离。`Float` 转 `Double`，不做任何平滑：雷达画的系统读数，不是我们的估计。
    @Published public private(set) var distanceMeters: Double?
    /// 距离持续超过 `config.farDistanceMeters` 后置真，UWB 已暂停，等一次 `resumeRanging()`。
    @Published public private(set) var rangingPausedForDistance = false
    /// 首次跌破 0.15 m 的标记。视图读它来决定震动只响一次：触觉是呈现层的事，而这个模块不 import UIKit。
    @Published public private(set) var didCrossPreciseThreshold = false
    /// 成功后双方都能看到的东西：对端的邀请链接与 mesh 公钥。
    @Published public private(set) var exchange: PopopxProximityExchange?
    @Published public private(set) var failure: PopopxProximityFailure?

    private let bridge: PopopxOfflineBridge
    private let localMeshPublicKeyHex: @Sendable () async -> String
    private let radio: PopopxProximityRadioHooks
    public let config: PopopxProximityConfig

    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var proximitySession: NISession?
    /// 我们的 token 一旦被对端读走，本机就是这个测距对的 target；`run` 之后不能再换。
    private var localDiscoveryTokenData: Data?
    /// 已邀请过的对端。browse 会反复 `foundPeer`，不记就反复发邀请，MC 会把它们当成新的握手。
    private var invitedPeers: Set<MCPeerID> = []
    private var peerMeshPublicKeyHex: String?
    /// 本机在 MC 里的名字，同时也是握手与载荷里带的昵称。留一份，避免三处各自去
    /// `session?.myPeerID.displayName` 取，而 session 在 `stopProximityLinkEngine()` 之后是 nil。
    private var localDisplayName = "POPOPX"
    private var radioSuspended = false
    private var didPair = false
    private var discoveryWatchdog: Task<Void, Never>?
    private var exchangeWatchdog: Task<Void, Never>?
    private var distanceWatchdog: Task<Void, Never>?
    /// 最近一次「够近」的采样时刻，`farDistanceGrace` 与它比较。
    private var lastNearSample: ContinuousClock.Instant?

    public init(
        bridge: PopopxOfflineBridge,
        radio: PopopxProximityRadioHooks,
        localMeshPublicKeyHex: @Sendable @escaping () async -> String = { PopopxMeshEngine.shared.localMeshPublicKeyHex },
        config: PopopxProximityConfig = PopopxProximityConfig()
    ) {
        self.bridge = bridge
        self.radio = radio
        self.localMeshPublicKeyHex = localMeshPublicKeyHex
        self.config = config
        super.init()
    }

    // MARK: - Lifecycle

    /// 挂起 mesh 射频 → 建 MC 广告与浏览 → 起 UWB。`nickname` 只用于 peer display name 与字典序仲裁，
    /// 缺失时退化成空串：仲裁会落到 mesh 公钥那一档，两个用户都能正常加友。
    public func start(nickname: String?) async {
        guard phase == .idle || phase == .stopped || phase == .failed else { return }
        reset()
        phase = .starting
        supportsPreciseDistance = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement

        await radio.suspend()
        radioSuspended = true

        let myKey = await localMeshPublicKeyHex()
        guard IdentityMappingStore.canonicalMeshPublicKeyHex(myKey) != nil else {
            PopopxMeshLog.offline.error("🚫 proximity start refused: no canonical local mesh identity")
            await teardown()
            failure = .localIdentityUnavailable
            phase = .failed
            return
        }

        let peer = MCPeerID(displayName: Self.clampedDisplayName(nickname))
        localDisplayName = peer.displayName
        // 加密是硬要求：载荷里有一条可用的邀请链接。`.required` 让 MC 拒绝任何不加密的会话。
        let mc = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        mc.delegate = self
        let ad = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: config.serviceType)
        ad.delegate = self
        let br = MCNearbyServiceBrowser(peer: peer, serviceType: config.serviceType)
        br.delegate = self

        if supportsPreciseDistance {
            let ni = NISession()
            ni.delegate = self
            // `delegateQueue` 留空：文档保证 nil 即 main，与 `@MainActor` 一致。
            self.proximitySession = ni
            self.localDiscoveryTokenData = ni.discoveryToken.flatMap(Self.archivedToken)
        }

        self.session = mc
        self.advertiser = ad
        self.browser = br
        ad.startAdvertisingPeer()
        br.startBrowsingForPeers()
        phase = .searching
        PopopxMeshLog.offline.notice(
            "🤝 proximity engine up: uwb=\(self.supportsPreciseDistance, privacy: .public) token=\(self.localDiscoveryTokenData != nil, privacy: .public)"
        )
        scheduleDiscoveryWatchdog()
    }

    /// 页面 `onDisappear`：销毁我们的 MC/NI 对象，然后恢复 mesh 射频（恢复与否由 host 的钩子决定）。
    public func stop() async {
        guard phase != .stopped else { return }
        await teardown()
        phase = .stopped
        PopopxMeshLog.offline.notice("🛑 proximity engine stopped")
    }

    /// 引擎 B 的前置动作（第三阶段 3.）：把 UWB 与 `MCSession` 真的停掉并销毁，避免两条通道同时发包。
    /// 与 `stop()` 的区别只有一件事：它**不**归还射频，因为随后调起的分享面板仍要用蓝牙，
    /// 而 `resumeRanging()` / `start(nickname:)` 会自己重新建一切。
    public func stopProximityLinkEngine() async {
        await shutdownLink()
        phase = .stopped
        PopopxMeshLog.offline.notice("📴 proximity link engine destroyed for TapDrop")
    }

    /// 分享面板关闭后回到引擎 A：重新建 MC 与 NI。这里**不**先归还射频，也**不**怕再挂起一次：
    /// `stopScan()`/`stopAdvertising()`（BLE/PopopxBLETransport.swift:259、:263）本身是幂等的，
    /// 而 `shutDown()` 会先落 `wantsToRun = false`，第二次进来只是重复一次已经完成的拆卸。
    public func resume(nickname: String?) async {
        guard phase == .stopped || phase == .failed else { return }
        await start(nickname: nickname)
    }

    /// 距离规则触发的暂停：`pause()` 而不是 `invalidate()`，雷达随时可以用同一份 token 再跑起来。
    public func pauseRanging() {
        guard let proximitySession else { return }
        proximitySession.pause()
        rangingPausedForDistance = true
        distanceMeters = nil
        distanceWatchdog?.cancel()
        distanceWatchdog = nil
    }

    public func resumeRanging() {
        rangingPausedForDistance = false
        guard let token = peerDiscoveryToken else { return }
        lastNearSample = .now
        // `runRanging` 自己对 `proximitySession == nil` 返回，这里不再重复一次可选绑定。
        runRanging(with: token)
        scheduleDistanceWatchdog()
    }

    /// 对端握手里的 token，测距要用它来 `run`。
    private var peerDiscoveryToken: NIDiscoveryToken?

    // MARK: - Teardown

    private func teardown() async {
        await shutdownLink()
        if radioSuspended {
            radioSuspended = false
            await radio.resume()
        }
    }

    private func shutdownLink() async {
        discoveryWatchdog?.cancel()
        discoveryWatchdog = nil
        exchangeWatchdog?.cancel()
        exchangeWatchdog = nil
        distanceWatchdog?.cancel()
        distanceWatchdog = nil
        proximitySession?.invalidate()
        proximitySession = nil
        localDiscoveryTokenData = nil
        peerDiscoveryToken = nil
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
        invitedPeers.removeAll()
        peerMeshPublicKeyHex = nil
    }

    private func reset() {
        failure = nil
        exchange = nil
        senderRole = nil
        peerNickname = nil
        peerDisplayName = nil
        distanceMeters = nil
        didCrossPreciseThreshold = false
        rangingPausedForDistance = false
        didPair = false
    }

    // MARK: - Watchdogs

    private func scheduleDiscoveryWatchdog() {
        discoveryWatchdog?.cancel()
        let limit = config.discoveryTimeout
        discoveryWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self else { return }
            guard self.phase == .searching else { return }
            self.failure = .nobodyFound
            self.phase = .failed
            PopopxMeshLog.offline.notice("⏱ proximity discovery timed out — UI should offer the fallback path")
        }
    }

    private func scheduleExchangeWatchdog() {
        exchangeWatchdog?.cancel()
        let limit = config.exchangeTimeout
        exchangeWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self else { return }
            guard self.phase == .linking || self.phase == .exchanging else { return }
            self.failure = .exchangeTimeout
            self.phase = .failed
        }
    }

    /// 连续 `farDistanceGrace` 没有近距样本就暂停：靠单次读数暂停会在两次采样之间抖成开关。
    private func scheduleDistanceWatchdog() {
        guard distanceWatchdog == nil, config.farDistanceMeters > 0 else { return }
        let grace = config.farDistanceGrace
        let far = config.farDistanceMeters
        // 从一个「刚刚算近」的时刻起算，否则第一拍就会在没有采样时立刻暂停雷达。
        lastNearSample = .now
        distanceWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard !self.rangingPausedForDistance, self.phase == .linking || self.phase == .exchanging else { return }
                if let at = self.lastNearSample, at.duration(to: .now) < .seconds(grace) { continue }
                self.pauseRanging()
                PopopxMeshLog.offline.notice(
                    "📏 proximity idle beyond \(far, privacy: .public) m for \(grace, privacy: .public) s — UWB paused"
                )
                return
            }
        }
    }

    // MARK: - The exchange

    /// MC 链接就绪：立刻发握手。两边都发，因此任何一侧都能拿到对端的 key 与 token。
    private func linkReady(with peer: MCPeerID) {
        guard !didPair, phase == .searching || phase == .starting || phase == .linking else { return }
        peerDisplayName = peer.displayName
        discoveryWatchdog?.cancel()
        discoveryWatchdog = nil
        phase = .linking
        scheduleExchangeWatchdog()
        Task { await self.sendHandshake(to: peer) }
    }

    private func sendHandshake(to peer: MCPeerID) async {
        let key = await localMeshPublicKeyHex()
        guard let canonical = IdentityMappingStore.canonicalMeshPublicKeyHex(key) else {
            failure = .localIdentityUnavailable
            phase = .failed
            return
        }
        let hello = PopopxProximityHandshake(
            meshPublicKeyHex: canonical,
            nickname: localDisplayName,
            discoveryTokenData: localDiscoveryTokenData
        )
        send(.handshake(hello), to: peer)
    }

    private func handle(_ frame: PopopxProximityFrame, from peer: MCPeerID) {
        switch frame {
        case let .handshake(hello):
            receive(hello, from: peer)
        case let .exchange(payload):
            Task { await self.receive(payload, from: peer) }
        }
    }

    private func receive(_ hello: PopopxProximityHandshake, from peer: MCPeerID) {
        guard !didPair else { return }
        guard let canonical = IdentityMappingStore.canonicalMeshPublicKeyHex(hello.meshPublicKeyHex) else {
            failure = .payloadRejected(reason: "malformed peer mesh key")
            phase = .failed
            return
        }
        peerMeshPublicKeyHex = canonical
        if let data = hello.discoveryTokenData, let token = Self.unarchivedToken(data) {
            peerDiscoveryToken = token
            if !rangingPausedForDistance {
                runRanging(with: token)
                scheduleDistanceWatchdog()
            }
        }
        // 双方都握手完成之后才决定谁说话：更早决定会让两侧对「对端是谁」的理解不一致。
        guard phase != .exchanging, phase != .paired else { return }
        let keyProvider = localMeshPublicKeyHex
        Task {
            let mine = await keyProvider()
            let decision = popopxProximitySenderRole(
                myDisplayName: self.localDisplayName,
                remoteDisplayName: peer.displayName,
                myMeshPublicKeyHex: IdentityMappingStore.canonicalMeshPublicKeyHex(mine) ?? mine,
                remoteMeshPublicKeyHex: canonical
            )
            self.decide(decision, peer: peer)
        }
    }

    private func decide(_ role: PopopxProximitySenderRole, peer: MCPeerID) {
        guard senderRole != role else { return }
        senderRole = role
        phase = .exchanging
        switch role {
        case .duplicateIdentity:
            failure = .duplicateIdentity
            phase = .failed
            PopopxMeshLog.offline.error("🪞 proximity peer is indistinguishable from us — nothing sent")
        case .receiver:
            // 静默。第三阶段要求小的一方不发包，只等；建连由发信方的 pending connection 触发。
            PopopxMeshLog.offline.notice("👂 proximity role: waiting for the peer's invite payload")
        case .sender:
            Task { await self.mintAndSend(to: peer) }
        }
    }

    private func mintAndSend(to peer: MCPeerID) async {
        guard let peerKey = peerMeshPublicKeyHex else { return }
        let invite: PopopxOfflineInvite
        do {
            // 复用模块 2：`/_connect <userId> incognito=on` 在纯离线状态下生成一次性邀请链接，并把
            // pending connection 绑定到对端的 mesh 公钥。
            invite = try await bridge.generateOfflineInviteLink(meshPublicKeyHex: peerKey, incognito: true)
        } catch {
            failure = .inviteMintFailed(reason: String(describing: error))
            phase = .failed
            PopopxMeshLog.offline.error("❌ proximity invite mint failed: \(String(describing: error), privacy: .public)")
            return
        }
        let payload = PopopxProximityExchange(
            meshPublicKeyHex: await localMeshPublicKeyHex(),
            inviteLink: invite.inviteLink,
            nickname: localDisplayName
        )
        guard PopopxOfflineBridge.normalizedInviteLink(payload.inviteLink) != nil else {
            failure = .inviteMintFailed(reason: "core returned a link that fails our own prefix rules")
            phase = .failed
            return
        }
        send(.exchange(payload), to: peer)
        exchangeWatchdog?.cancel()
        exchangeWatchdog = nil
        exchange = payload
        phase = .paired
        didPair = true
        PopopxMeshLog.offline.notice(
            "📨 proximity invite sent to \(peerKey.prefix(8), privacy: .public) on pending :\(invite.tempConnId, privacy: .public)"
        )
    }

    private func receive(_ payload: PopopxProximityExchange, from peer: MCPeerID) async {
        guard !didPair else { return }
        guard payload.version == PopopxProximityExchange.payloadVersion else {
            failure = .payloadRejected(reason: "exchange version \(payload.version)")
            phase = .failed
            return
        }
        guard let peerKey = IdentityMappingStore.canonicalMeshPublicKeyHex(payload.meshPublicKeyHex) else {
            failure = .payloadRejected(reason: "malformed mesh key in payload")
            phase = .failed
            return
        }
        guard PopopxOfflineBridge.normalizedInviteLink(payload.inviteLink) != nil else {
            failure = .payloadRejected(reason: "invite link rejected before the FFI")
            phase = .failed
            return
        }
        peerNickname = payload.nickname
        do {
            // 一次调用完成三件事：`/_connect` 建 pending connection、`IdentityMappingStore.bind` 写下
            // 「这个 mesh 公钥 = 这条连接」，于是加友与离线身份绑定是同一个动作，不是一先一后两步。
            let acceptance = try await bridge.acceptOfflineInviteLink(
                payload.inviteLink,
                meshPublicKeyHex: peerKey,
                incognito: true
            )
            exchange = payload
            phase = .paired
            didPair = true
            exchangeWatchdog?.cancel()
            exchangeWatchdog = nil
            PopopxMeshLog.offline.notice(
                "🤝 proximity accept \(acceptance.kind.rawValue, privacy: .public) on pending :\(acceptance.tempConnId, privacy: .public)"
            )
        } catch {
            failure = .acceptFailed(reason: String(describing: error))
            phase = .failed
            PopopxMeshLog.offline.error("❌ proximity accept failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func send(_ frame: PopopxProximityFrame, to peer: MCPeerID) {
        guard let session else { return }
        guard let data = try? frame.wireData() else {
            PopopxMeshLog.offline.error("🚫 proximity frame could not be encoded")
            return
        }
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            failure = .linkFailed(reason: String(describing: error))
            phase = .failed
            PopopxMeshLog.offline.error("❌ proximity send failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - UWB

    /// 测距是双向对称的：两侧都用自己的 token 让对端可见，然后各自以 `NINearbyPeerConfiguration`
    /// 跑起来（Apple 的要求：「Both devices must call runWithConfiguration:」，NISession.h:90）。
    private func runRanging(with token: NIDiscoveryToken) {
        guard let proximitySession else { return }
        let configuration = NINearbyPeerConfiguration(peerToken: token)
        proximitySession.run(configuration)
    }

    // MARK: - Token coding

    private static func archivedToken(_ token: NIDiscoveryToken) -> Data? {
        // `requiringSecureCoding` 是对端字节的底线：一个不可信的设备不该能塞进一个可执行的归档。
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func unarchivedToken(_ data: Data) -> NIDiscoveryToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data)
    }

    /// 63 字节是 `MCPeerID` 的硬限制，按字节裁剪才不会把一个中文昵称切成非法 UTF-8。
    static func clampedDisplayName(_ raw: String?) -> String {
        let base = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "POPOPX"
        let candidate = base.isEmpty ? fallback : base
        guard candidate.utf8.count > maxPeerDisplayNameBytes else { return candidate }
        var kept = ""
        for character in candidate {
            guard (kept.utf8.count + String(character).utf8.count) <= maxPeerDisplayNameBytes else { break }
            kept.append(character)
        }
        return kept.isEmpty ? fallback : kept
    }
}

// MARK: - MultipeerConnectivity delegates
//
// 每个回调都发生在 main（MC 没有可配置的 delegate 队列），所以 `@preconcurrency` 只是把「ObjC 协议
// 默认 nonisolated」这条规则与已经成立的运行时事实写下来，不是一段将就跑的代码。

@available(iOS 17.0, *)
extension PopopxProximityEngine: @preconcurrency MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            linkReady(with: peerID)
        case .connecting:
            peerDisplayName = peerID.displayName
        case .notConnected:
            guard !didPair else { return }
            invitedPeers.remove(peerID)
            if phase == .linking || phase == .exchanging {
                failure = .remoteClosed
                phase = .failed
            }
        @unknown default:
            failure = .linkFailed(reason: "unknown MC session state")
            phase = .failed
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let frame = PopopxProximityFrame.parse(data) else {
            if PopopxProximityFrame.isOversized(data) {
                failure = .unrecognizedFrame(byteCount: data.count)
                phase = .failed
            }
            return
        }
        handle(frame, from: peerID)
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}
}

@available(iOS 17.0, *)
extension PopopxProximityEngine: @preconcurrency MCNearbyServiceAdvertiserDelegate {
    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // 都接受：邀请不是载荷，两边同时邀请也只是 MC 内部二选一。真正的单向约束在 `decide`。
        peerDisplayName = peerID.displayName
        invitationHandler(true, session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: (any Error)) {
        reportStartFailure(error, what: "advertiser")
    }
}

@available(iOS 17.0, *)
extension PopopxProximityEngine: @preconcurrency MCNearbyServiceBrowserDelegate {
    /// 这个 SDK 里 `discoveryInfo` 是 `[String: String]?`（MCNearbyServiceBrowser.h:82），不再是早年
    /// 文档里的 `String?`：广告方传的字典。我们发 nil，因此只用来做同类型设备的过滤依据。
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard !didPair, let session else { return }
        peerDisplayName = peerID.displayName
        guard !invitedPeers.contains(peerID) else { return }
        invitedPeers.insert(peerID)
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: Self.invitationTimeout)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        invitedPeers.remove(peerID)
        if peerDisplayName == peerID.displayName, !didPair, phase == .searching {
            peerDisplayName = nil
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: (any Error)) {
        reportStartFailure(error, what: "browser")
    }

    /// MC 对「权限没给」和「蓝牙关了」返回同一个错误，所以先问 CoreBluetooth：它是这里唯一能确定
    /// 区分两者的信号。分开报，UI 才能决定是引导去「设置」还是改推「扫一扫」。
    private func reportStartFailure(_ error: (any Error), what: String) {
        PopopxMeshLog.offline.error("📡 proximity \(what, privacy: .public) failed to start: \(String(describing: error), privacy: .public)")
        switch CBManager.authorization {
        case .denied, .restricted:
            failure = .permissionDenied
        default:
            failure = .discoveryUnavailable(reason: String(describing: error))
        }
        phase = .failed
    }
}

// MARK: - NearbyInteraction delegate

@available(iOS 17.0, *)
extension PopopxProximityEngine: @preconcurrency NISessionDelegate {
    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let object = nearbyObjects.first else { return }
        // `distance` 在头文件里是 `float` + `NS_REFINED_FOR_SWIFT`（NINearbyObject.h:76），refined 形态
        // 由 ARKit cross-import overlay 提供，而本工程不链接 ARKit，所以读原始名。0 表示算法还没收敛，
        // 不是「贴在一起」，因此和负数一起丢掉。
        let raw = Double(object.__distance)
        guard raw > 0 else { return }
        distanceMeters = raw
        guard raw <= config.farDistanceMeters else { return }
        lastNearSample = .now
        guard !didCrossPreciseThreshold, raw <= config.preciseThresholdMeters else { return }
        didCrossPreciseThreshold = true
        PopopxMeshLog.offline.notice(
            "🎯 proximity closed to \(raw, privacy: .public) m — view fires one heavy haptic here"
        )
    }

    public func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard !didCrossPreciseThreshold else { return }
        distanceMeters = nil
    }

    public func sessionWasSuspended(_ session: NISession) {
        distanceMeters = nil
    }

    public func sessionSuspensionEnded(_ session: NISession) {
        guard let token = peerDiscoveryToken, !rangingPausedForDistance else { return }
        // 挂起之后 Apple 要求重新 `runWithConfiguration:`（NISession.h:202）：同一个 session、同一份 token。
        runRanging(with: token)
    }

    public func session(_ session: NISession, didInvalidateWith error: (any Error)) {
        PopopxMeshLog.offline.error("📡 UWB session invalidated: \(String(describing: error), privacy: .public)")
        distanceMeters = nil
        // 测距失败不影响加友：MC 才是载荷的载体，雷达只是「够不够近」的仪表。
    }
}
#endif
