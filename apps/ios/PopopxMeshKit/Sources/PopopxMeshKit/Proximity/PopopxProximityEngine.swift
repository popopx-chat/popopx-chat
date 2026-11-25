//
//  PopopxProximityEngine.swift
//  PopopxMeshKit  —  module 8 (stage 3: in-person dual-engine physical near-field friending)
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Two phones, two screens apart, no server, no Wi-Fi, no QR code to photograph. Engine A is the
//  physical half: MultipeerConnectivity carries the bytes and, on a U1/U2 device, NearbyInteraction
//  measures how far apart the two hands are. Engine B is not here — TapDrop needs a
//  `UIActivityViewController`, which is UIKit and therefore belongs to the view layer; this file
//  exposes `stopProximityLinkEngine()` for it and nothing else about it.
//
//  Three properties the rest of the module depends on:
//
//  1. Radio mutual exclusion is real, not a flag. `start()` awaits the host's `suspend` hook before it opens a
//     single MC object, and `stop()` awaits `resume` after it has torn its own objects down. What
//     the hook reaches in this app is `PopopxBLETransport.shutDown()`, which calls
//     `centralManager?.stopScan()` (BLE/PopopxBLETransport.swift:262) and
//     `peripheralManager?.stopAdvertising()` (:266) — the mesh radio is off the channel while the
//     pairing screen owns it. `radio` deliberately has no default value: a silent `{}` here would
//     ship a screen that pre-empts the mesh and looks fine in a preview.
//
//  2. One-way sending. Both devices advertise, browse and exchange handshakes — that traffic creates
//     nothing. Exactly one of them mints an invite link, and which one is decided by the
//     lexicographically larger peer display name (mesh key breaks an equal-name tie, which two
//     devices with no nickname would otherwise produce forever). The other side stays silent until
//     the payload lands and then does the accept itself. Two `/_connect` calls for one pairing would
//     leave a pending contact on both sides pointing at each other's pending contact, i.e. two
//     half-connections instead of one friendship.
//
//  3. The payload is validated before it enters the core. `PopopxProximityFrame.parse` refuses a wrong prefix, an oversized frame or
//     a decode failure before anything is called, and the mesh key and the link are re-validated
//     against module 1's canonical form and `PopopxOfflineBridge.normalizedInviteLink` before
//     `acceptOfflineInviteLink` sees them. A peer's bytes never reach `chat_send_cmd_retry` unescaped.
//
//  MultipeerConnectivity is still what stage 3 specifies, even though the SDK stamps the whole
//  framework `API_DEPRECATED("Use Network Framework instead", ios(7.0, 27.0))`: `NWConnection` has no
//  advertiser/browser half-handshake, no `MCPeerID.displayName` for the lexicographic arbitration to
//  read, and no `NIDiscoveryToken` exchange, so replacing it here would delete the two facts this
//  state machine is built on. That deprecation range ends at 27.0, so this file compiles without a
//  single deprecation warning — re-measure with `grep -E ':[0-9]+: warning:' <gate log>` if the SDK
//  ever includes the current version. Moving to Network.framework is a Phase 5 decision.
//
//  Everything below `#if os(iOS)` is hardware-facing and therefore iOS-only: the package still
//  builds for the macOS host (`Package.swift:14`), where the payload types and the arbitration
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
    /// Our X25519 mesh public key, in module 1's canonical (lower-case hex) spelling.
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

    /// Stage 3 fixed the literal. It is on the wire, not in a comment: a receiver that cannot see
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
    /// "the peer sent abnormal data" instead of pretending the peer never spoke.
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

/// Lexicographic one-way-sending arbitration. Display names first, because that is what stage 3 specifies and what a user
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
/// the ones the system gave us. The view turns these into Chinese copy; nothing here guesses a cause.
public enum PopopxProximityFailure: Hashable, Sendable {
    /// Bluetooth permission denied or restricted (`CBManager.authorization`). This is the only failure that can be told apart for certain: MC returns the same for "permission not granted" and
    /// "Bluetooth turned off", namely `MCErrorUnavailable`, while local-network permission is not queryable in TCC at all.
    case permissionDenied
    /// Advertiser and browser both failed to start, or the radio is off.
    case discoveryUnavailable(reason: String)
    /// The link dropped before the payload arrived.
    case linkFailed(reason: String)
    case remoteClosed
    /// No device nearby within 30 seconds — the UI should switch to recommending "Scan" or "TapDrop".
    case nobodyFound
    /// The link is established, but the peer does not send the invite within `exchangeTimeout`.
    case exchangeTimeout
    /// The frame from the peer is not our protocol, or it exceeds `maxWireBytes`.
    case unrecognizedFrame(byteCount: Int)
    /// The frame decodes, but the mesh public key or the invite link fails validation.
    case payloadRejected(reason: String)
    /// `/_connect incognito=…` failed on our side, the link was never generated at all.
    case inviteMintFailed(reason: String)
    /// We accepted the link, but the core returned no pending connection.
    case acceptFailed(reason: String)
    /// Two devices with the same name and the same key: this device was taken for the peer.
    case duplicateIdentity
    /// This device cannot get a mesh identity, so in-person friending has nothing to bind to.
    case localIdentityUnavailable
}

#if os(iOS)
import CoreBluetooth
import MultipeerConnectivity
import NearbyInteraction

// MARK: - Radio handover

/// The two hooks that make radio mutual exclusion real. `suspend` runs before any MC object exists, `resume` after
/// every one of ours is gone, and only `resume` is conditional — the host decides whether the mesh
/// should come back at all, which is how "provided the master switch is on" is honoured without this module owning a
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

/// Tunables, all of them stage 3's numbers, none of them magic.
///
/// `TimeInterval`, not `Duration`: this value type is not availability-gated (the fuse and the
/// settings page read it), and `Duration` is iOS 16 while the package floor is iOS 15
/// (`Package.swift:13`). The engine converts at the `Task.sleep(for:)` call sites, which do live
/// inside the `@available(iOS 17.0, *)` type.
public struct PopopxProximityConfig: Hashable, Sendable {
    /// MC service type. Bonjour publishes it as `_popopx-uwb._tcp`, which is the entry
    /// `NSBonjourServices` needs; MC itself wants the name without the underscore and the suffix.
    public var serviceType: String
    /// The time before the no-discovery fallback hint.
    public var discoveryTimeout: TimeInterval
    /// The time the link stays established while the peer delays sending.
    public var exchangeTimeout: TimeInterval
    /// Ranging persistently beyond this distance pauses UWB and makes "TapDrop" the primary action.
    public var farDistanceMeters: Double
    /// Only after this long without a single near sample does it count as "far away".
    public var farDistanceGrace: TimeInterval
    /// Falling below this distance triggers one heavy haptic (executed by the view as `PopopxHaptics.impact(.heavy)`, see the comment below).
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
    /// 15 centimetres: the distance when the two are held together.
    public static let preciseThresholdMeters = 0.15
    /// `MCPeerID.displayName` is capped at 63 bytes, trimmed by UTF-8 bytes rather than by characters.
    public static let maxPeerDisplayNameBytes = 63
    /// MC invitations time out; 30 seconds matches the browse window we give the user anyway.
    public static let invitationTimeout: TimeInterval = 30

    @Published public private(set) var phase: PopopxProximityPhase = .idle
    /// Whether this device has precise ranging (U1/U2). When false the UI hides the radar and enlarges "TapDrop" into the main button.
    @Published public private(set) var supportsPreciseDistance = false
    @Published public private(set) var senderRole: PopopxProximitySenderRole?
    @Published public private(set) var peerDisplayName: String?
    @Published public private(set) var peerNickname: String?
    /// nil = no distance in this sampling cycle. `Float` converted to `Double`, with no smoothing at all: the radar plots system readings, not our estimate.
    @Published public private(set) var distanceMeters: Double?
    /// Set once the distance stays above `config.farDistanceMeters`; UWB is paused, waiting for one `resumeRanging()`.
    @Published public private(set) var rangingPausedForDistance = false
    /// Marker for the first fall below 0.15 m. The view reads it so the vibration sounds only once: haptics are the presentation layer's business, and this module does not import UIKit.
    @Published public private(set) var didCrossPreciseThreshold = false
    /// What both sides can see after success: the peer's invite link and mesh public key.
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
    /// Once our token has been read by the peer, this device is the target of the ranging pair; it cannot be changed after `run`.
    private var localDiscoveryTokenData: Data?
    /// Peers already invited. Browsing reports `foundPeer` over and over; without recording it we would keep inviting, and MC would treat each one as a new handshake.
    private var invitedPeers: Set<MCPeerID> = []
    private var peerMeshPublicKeyHex: String?
    /// This device's name in MC, which is also the nickname carried in the handshake and in the payload. Kept once to avoid three places each going to
    /// `session?.myPeerID.displayName`, while session is nil after `stopProximityLinkEngine()`.
    private var localDisplayName = "POPOPX"
    private var radioSuspended = false
    private var didPair = false
    private var discoveryWatchdog: Task<Void, Never>?
    private var exchangeWatchdog: Task<Void, Never>?
    private var distanceWatchdog: Task<Void, Never>?
    /// The moment of the most recent "near enough" sample; `farDistanceGrace` is compared against it.
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

    /// Suspend the mesh radio → build MC advertising and browsing → start UWB. `nickname` is used only for the peer display name and the lexicographic arbitration,
    /// when missing it degrades to an empty string: arbitration falls through to the mesh public key tier, and both users can still friend normally.
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
        // Encryption is a hard requirement: the payload carries a usable invite link. `.required` makes MC refuse any unencrypted session.
        let mc = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        mc.delegate = self
        let ad = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: config.serviceType)
        ad.delegate = self
        let br = MCNearbyServiceBrowser(peer: peer, serviceType: config.serviceType)
        br.delegate = self

        if supportsPreciseDistance {
            let ni = NISession()
            ni.delegate = self
            // `delegateQueue` left empty: the documentation guarantees nil means main, consistent with `@MainActor`.
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

    /// Page `onDisappear`: destroy our MC/NI objects, then restore the mesh radio (whether it is restored is decided by the host's hooks).
    public func stop() async {
        guard phase != .stopped else { return }
        await teardown()
        phase = .stopped
        PopopxMeshLog.offline.notice("🛑 proximity engine stopped")
    }

    /// Pre-action for engine B (stage 3 item 3.): really stop and destroy UWB and the `MCSession`, so the two channels never send at the same time.
    /// The only difference from `stop()` is one thing: it does **not** return the radio, because the share panel it then brings up still needs Bluetooth,
    /// and `resumeRanging()` / `start(nickname:)` rebuild everything on their own.
    public func stopProximityLinkEngine() async {
        await shutdownLink()
        phase = .stopped
        PopopxMeshLog.offline.notice("📴 proximity link engine destroyed for TapDrop")
    }

    /// Back to engine A after the share panel closes: rebuild MC and NI. Here we do **not** return the radio first, and we do **not** fear suspending once more:
    /// `stopScan()`/`stopAdvertising()` (BLE/PopopxBLETransport.swift:262, :266) are themselves idempotent,
    /// and `shutDown()` first sets `wantsToRun = false`, so coming in a second time only repeats a teardown that is already complete.
    public func resume(nickname: String?) async {
        guard phase == .stopped || phase == .failed else { return }
        await start(nickname: nickname)
    }

    /// The pause triggered by the distance rule: `pause()` rather than `invalidate()`, so the radar can run again at any time with the same token.
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
        // `runRanging` itself returns on `proximitySession == nil`, so no optional binding is repeated here.
        runRanging(with: token)
        scheduleDistanceWatchdog()
    }

    /// The token from the peer's handshake; ranging needs it in order to `run`.
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

    /// Pause after `farDistanceGrace` straight without a near sample: pausing on a single reading would flicker like a switch between two samples.
    private func scheduleDistanceWatchdog() {
        guard distanceWatchdog == nil, config.farDistanceMeters > 0 else { return }
        let grace = config.farDistanceGrace
        let far = config.farDistanceMeters
        // Counted from a moment that "just counted as near", otherwise the very first tick would pause the radar while there was no sample at all.
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

    /// MC link ready: send the handshake immediately. Both sides send, so either one can get the peer's key and token.
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
        // Who speaks is decided only after both handshakes are complete: deciding earlier would leave the two sides with an inconsistent understanding of "who the peer is".
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
            // Silence. Stage 3 requires the smaller side not to send, only to wait; the connection is set up by the sending side's pending connection.
            PopopxMeshLog.offline.notice("👂 proximity role: waiting for the peer's invite payload")
        case .sender:
            Task { await self.mintAndSend(to: peer) }
        }
    }

    private func mintAndSend(to peer: MCPeerID) async {
        guard let peerKey = peerMeshPublicKeyHex else { return }
        let invite: PopopxOfflineInvite
        do {
            // Reusing module 2: `/_connect <userId> incognito=on` generates a one-time invite link in a purely offline state and binds the
            // pending connection to the peer's mesh public key.
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
            // One call completes three things: `/_connect` creates the pending connection, `IdentityMappingStore.bind` writes down
            // "this mesh public key = this connection", so friending and offline identity binding are the same action, not two steps one after the other.
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

    /// Ranging is symmetric both ways: each side uses its own token to become visible to the peer, then each runs with its own `NINearbyPeerConfiguration`
    /// (Apple's requirement: "Both devices must call runWithConfiguration:", NISession.h:90).
    private func runRanging(with token: NIDiscoveryToken) {
        guard let proximitySession else { return }
        let configuration = NINearbyPeerConfiguration(peerToken: token)
        proximitySession.run(configuration)
    }

    // MARK: - Token coding

    private static func archivedToken(_ token: NIDiscoveryToken) -> Data? {
        // `requiringSecureCoding` is the floor for the peer's bytes: an untrusted device should not be able to slip in an executable archive.
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func unarchivedToken(_ data: Data) -> NIDiscoveryToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data)
    }

    /// 63 bytes is `MCPeerID`'s hard limit; trimming by bytes is what keeps a Chinese nickname from being cut into illegal UTF-8.
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
// Every callback happens on main (MC has no configurable delegate queue), so `@preconcurrency` merely writes down the rule that "ObjC protocols
// default to nonisolated" together with the runtime fact that already holds; it is not a piece of make-do code.

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
        // Accept both: an invite is not the payload, and two simultaneous invites are just MC choosing one internally. The real one-way constraint lives in `decide`.
        peerDisplayName = peerID.displayName
        invitationHandler(true, session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: (any Error)) {
        reportStartFailure(error, what: "advertiser")
    }
}

@available(iOS 17.0, *)
extension PopopxProximityEngine: @preconcurrency MCNearbyServiceBrowserDelegate {
    /// In this SDK `discoveryInfo` is `[String: String]?` (MCNearbyServiceBrowser.h:82), no longer the
    /// `String?` of the older documentation: it is the dictionary the advertiser passes. We send nil, so it only serves as the basis for filtering same-type devices.
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

    /// MC returns the same error for "permission not granted" and "Bluetooth off", so ask CoreBluetooth first: it is the only signal here that can
    /// tell the two apart. Reported separately, the UI can decide whether to guide the user to "Settings" or switch to recommending "Scan".
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
        // `distance` is `float` + `NS_REFINED_FOR_SWIFT` in the header (NINearbyObject.h:76), and the refined form
        // is provided by the ARKit cross-import overlay, while this project does not link ARKit, so we read the raw name. 0 means the algorithm has not converged yet,
        // it is not "held together", so it is discarded along with the negatives.
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
        // After a pause Apple requires calling `runWithConfiguration:` again (NISession.h:202): the same session, the same token.
        runRanging(with: token)
    }

    public func session(_ session: NISession, didInvalidateWith error: (any Error)) {
        PopopxMeshLog.offline.error("📡 UWB session invalidated: \(String(describing: error), privacy: .public)")
        distanceMeters = nil
        // Ranging failure does not affect friending: MC is the carrier of the payload, the radar is only the gauge of "near enough or not".
    }
}
#endif
