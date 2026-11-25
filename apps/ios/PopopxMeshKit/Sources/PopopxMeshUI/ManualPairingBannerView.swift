//
//  ManualPairingBannerView.swift
//  PopopxMeshUI
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Module 3's top overlay. In manual-confirm mode an inbound `SYS_POPOPX_REQ:` does nothing but raise this
//  banner (red line: nothing reaches the FFI until the user says so); in auto-silent mode the exchange
//  completes on its own and the banner only reports what happened. The second job it has is the
//  radio: module 4's "Bluetooth unreachable" and module 5's "public card not yet exchanged" copy belongs here, at the top of the
//  chat, because that is where the user is about to press send.
//
//  Zero breakage: the banner is a sibling of the chat list, never a rewrite of it, and `host(_:)` /
//  `popopxMeshBanner(_:)` mount it through the safe area so the wrapped view's own code does not
//  change by a line. When there is nothing to say it draws nothing at all.
//

import Combine
import Foundation
import PopopxMeshKit
import SwiftUI

// MARK: - Contract with module 3

/// What the banner needs from module 3, and nothing more: the queue the user is being asked about, the
/// state of one peer, and the two answers. `ManualPairingManager` already has exactly these methods,
/// so the conformance below is the whole binding — no core file is edited and no singleton assumed
/// (module 3 has none; the host builds one and hands it here).
public protocol PopopxMeshPairingControlling: Sendable {
    func pendingRequests() async -> [PopopxPairingRequest]

    func state(for peerMeshPublicKeyHex: String) async -> MeshPairingState

    @discardableResult
    func approve(_ request: PopopxPairingRequest) async throws(PopopxPairingError) -> PopopxOfflineAcceptance

    func decline(_ request: PopopxPairingRequest) async
}

// `approve` needs a witness: module 3's method takes `incognito:` with a default, and a defaulted
// parameter does not satisfy a protocol requirement. Nothing else here adds behaviour.
extension ManualPairingManager: PopopxMeshPairingControlling {
    public func approve(_ request: PopopxPairingRequest) async throws(PopopxPairingError) -> PopopxOfflineAcceptance {
        try await approve(request, incognito: false)
    }
}

// MARK: - Content

/// Which banner is showing, decided by the view model rather than by `body`, so the rule is testable.
public enum PopopxMeshBannerContent: Hashable, Sendable {
    /// Nothing to report.
    case silent

    /// Manual confirm: one peer is waiting on the user, and `waitingPeers` more behind it. The invite link
    /// is deliberately absent — it lives in module 3's queue and only the manager may hand it to module 2.
    case awaitingConfirmation(PopopxPairingRequest, waitingPeers: Int)

    /// Auto-silent: a pairing completed without asking, said once so the user is not surprised by a
    /// contact they never added.
    case autoPaired(peerMeshPublicKeyHex: String)

    /// The radio cannot carry a message: Bluetooth off / not authorized / resetting.
    case radioUnavailable(PopopxBluetoothState)

    /// Bluetooth unreachable: reported by the host when a send to this peer could not leave the device.
    case peerOutOfRange(peerMeshPublicKeyHex: String, hasPublicRoute: Bool)

    /// True when the banner is asking something, as opposed to informing.
    public var isAwaitingUser: Bool {
        if case .awaitingConfirmation = self { return true }
        return false
    }
}

/// The banner, as a value: what to show, in what words, with what actions. Everything the view draws
/// and everything the tests assert comes from here.
public struct PopopxMeshBannerPresentation: Hashable, Sendable {
    public enum Action: String, Hashable, Sendable {
        case approve
        case decline
        case dismiss
    }

    public let content: PopopxMeshBannerContent
    public let title: String
    public let detail: String?
    /// Which peer key the decision belongs to, so a stale banner can never answer for a newer one.
    public let peerMeshPublicKeyHex: String?
    public let actions: [Action]

    public init(
        content: PopopxMeshBannerContent,
        title: String,
        detail: String?,
        peerMeshPublicKeyHex: String?,
        actions: [Action]
    ) {
        self.content = content
        self.title = title
        self.detail = detail
        self.peerMeshPublicKeyHex = peerMeshPublicKeyHex
        self.actions = actions
    }
}

// MARK: - View model

/// Polls module 3's queue and mirrors module 4's radio, and turns both into one presentation.
///
/// Polling rather than observing `ManualPairingManager.bannerNotification` is a deliberate choice,
/// and the reason is in module 3's own comment: the notification's `userInfo` carries only the peer key
/// and the arrival time, because the invite link must stay inside the manager. A listener that woke
/// on the notification would still have to ask the manager for the request, so the notification could
/// only ever be a hint; this reads the truth on a fixed interval instead, and two seconds is
/// invisible for a request the user is waiting on and cheap enough to leave running while the fuse is
/// on. The interval is also why `refresh()` is public: a host that knows something changed can ask
/// immediately instead of waiting for the next tick.
@MainActor
public final class PopopxMeshBannerModel: ObservableObject {
    /// How often the queue is re-read while the banner is mounted.
    public static let pollInterval: TimeInterval = 2

    /// How long an auto-silent confirmation stays up: long enough to read, short enough that a banner the
    /// user ignored cannot hide a pairing request that arrives after it.
    public static let informativeLifetime: TimeInterval = 8

    @Published public private(set) var presentation: PopopxMeshBannerPresentation?

    /// The last queue read from module 3, exposed for the settings page's diagnostics and for tests.
    @Published public private(set) var requests: [PopopxPairingRequest] = []

    @Published public private(set) var policy: MeshPairingPolicy = .manualConfirm

    @Published public private(set) var radioState: PopopxBluetoothState = .unknown

    private let pairing: any PopopxMeshPairingControlling
    private let binding: any PopopxMeshBindingObserving
    private let routing: any PopopxMeshRoutingObserving
    private let source: PopopxMeshStateSource
    private var pumpTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var autoPairedPeer: String?
    private var autoPairedAt: Date?
    /// Peers module 3 reported as paired on the previous poll, so "newly paired" is a fact rather than
    /// a guess. Module 3's own `markPaired` is synchronous and un-notified, and the app may be
    /// backgrounded when an ACK lands.
    private var knownPairedPeers: Set<String> = []

    public init(
        pairing: any PopopxMeshPairingControlling,
        binding: any PopopxMeshBindingObserving,
        routing: any PopopxMeshRoutingObserving = PopopxMeshNoRoutingObserver(),
        source: PopopxMeshStateSource = .shared
    ) {
        self.pairing = pairing
        self.binding = binding
        self.routing = routing
        self.source = source
    }

    /// Starts mirroring the mesh and watching the queue. Idempotent.
    public func start() {
        guard pumpTask == nil else { return }
        source.start()
        let stateStream = source.observeState()
        pumpTask = Task { @MainActor [weak self] in
            for await state in stateStream {
                if Task.isCancelled { break }
                self?.radioState = state.radioState
                self?.recompute()
            }
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        pollTask?.cancel()
        pollTask = nil
        presentation = nil
    }

    /// Reads the queue, the policy and the peer states once, now.
    public func refresh() async {
        let queue = await pairing.pendingRequests()
        let currentPolicy = await binding.pairingPolicy()
        requests = queue
        policy = currentPolicy
        if currentPolicy == .autoSilent {
            await detectAutoPairedPeers()
        }
        recompute()
    }

    /// The user said yes. Module 3 does the FFI work; the banner only decides what replaces it.
    public func approve() async {
        guard let request = requestAwaitingAnswer else { return }
        do {
            _ = try await pairing.approve(request)
        } catch {
            PopopxMeshLog.pairing.error(
                "❌ banner approve failed: \(String(describing: error), privacy: .public)"
            )
        }
        await refresh()
    }

    public func decline() async {
        guard let request = requestAwaitingAnswer else { return }
        await pairing.decline(request)
        await refresh()
    }

    /// Closes an informative banner — the auto-pair note, the radio note, the out-of-range note —
    /// without deciding anything.
    public func dismiss() {
        autoPairedPeer = nil
        autoPairedAt = nil
        presentation = nil
    }

    /// The host calls this when a send to a peer could not leave the device, which is module 5's
    /// moment to say "Bluetooth disconnected, public card not yet exchanged". It is an input rather than something this model
    /// detects, because only the router knows whether a send was attempted.
    public func noteOutboundBlocked(peerMeshPublicKeyHex: String) async {
        let hasPublicRoute = await routing.isPublicNetworkAvailable()
        let bound = await routing.isContactBound(forMeshPublicKeyHex: peerMeshPublicKeyHex)
        let detail: String
        if bound && hasPublicRoute {
            detail = "Bluetooth is down; this message goes over the POPOPX public network instead."
        } else if bound {
            detail = "Bluetooth is down and there is no network — move closer to continue sending."
        } else {
            detail = NSLocalizedString("Bluetooth is down and no POPOPX public-network card has been exchanged yet — move closer to continue sending.", comment: "POPOPX mesh pairing banner")
        }
        presentation = PopopxMeshBannerPresentation(
            content: .peerOutOfRange(
                peerMeshPublicKeyHex: peerMeshPublicKeyHex,
                hasPublicRoute: hasPublicRoute
            ),
            title: "Peer out of Bluetooth range",
            detail: detail,
            peerMeshPublicKeyHex: peerMeshPublicKeyHex,
            actions: [.dismiss]
        )
    }

    /// The one banner module 3 can announce directly: a pairing that completed without asking. Reading
    /// the peer table for it (see `detectAutoPairedPeers`) is the fallback, and the worse one — module 3
    /// knows the moment it happened, the mirror only knows the fact afterwards, and a fact noticed two
    /// seconds late is a banner that says "paired" about a peer the user already wondered about.
    public func noteAutoPaired(peerMeshPublicKeyHex: String) {
        autoPairedPeer = peerMeshPublicKeyHex
        autoPairedAt = .now
        knownPairedPeers.insert(peerMeshPublicKeyHex)
        recompute()
    }

    /// The request the current banner is about, if any — public so a host driving the banner from a
    /// keyboard shortcut or a widget can read it without rendering anything.
    public var requestAwaitingAnswer: PopopxPairingRequest? {
        if case let .awaitingConfirmation(request, _) = presentation?.content { return request }
        return nil
    }

    // MARK: - The one rule the view depends on

    /// Priority: a request the user owes an answer to, then an auto-pairing note, then the radio.
    /// Mixing them would mean dismissing two banners to get to the one that matters.
    private func recompute() {
        if policy == .manualConfirm, let pending = requests.first {
            presentation = PopopxMeshBannerPresentation(
                content: .awaitingConfirmation(pending, waitingPeers: requests.count),
                title: "Peer wants to pair over Bluetooth",
                detail: "\(Self.shorten(pending.peerMeshPublicKeyHex)) — approving binds this mesh key to a POPOPX contact",
                peerMeshPublicKeyHex: pending.peerMeshPublicKeyHex,
                actions: [.approve, .decline]
            )
            return
        }
        if let note = autoPairedNote() {
            presentation = note
            return
        }
        if radioIsBlocked, requests.isEmpty {
            presentation = PopopxMeshBannerPresentation(
                content: .radioUnavailable(radioState),
                title: Self.radioTitle(radioState),
                detail: "Offline mesh is paused until Bluetooth is available.",
                peerMeshPublicKeyHex: nil,
                actions: [.dismiss]
            )
            return
        }
        presentation = nil
    }

    /// Bluetooth unavailable as a fact, not as "not yet known". `.unknown` is the state before the engine has
    /// published anything — a mesh that was never switched on — and a banner that complains about it is
    /// a banner that lies about the radio at launch.
    private var radioIsBlocked: Bool {
        switch radioState {
        case .poweredOff, .unauthorized, .resetting, .unsupported: true
        case .poweredOn, .unknown: false
        }
    }

    private func autoPairedNote() -> PopopxMeshBannerPresentation? {
        guard policy == .autoSilent, let peer = autoPairedPeer, let at = autoPairedAt else {
            return nil
        }
        guard Date.now.timeIntervalSince(at) < Self.informativeLifetime else {
            autoPairedPeer = nil
            autoPairedAt = nil
            return nil
        }
        return PopopxMeshBannerPresentation(
            content: .autoPaired(peerMeshPublicKeyHex: peer),
            title: "Paired automatically",
            detail: "Silent pairing is on — \(Self.shorten(peer)) was bound without asking.",
            peerMeshPublicKeyHex: peer,
            actions: [.dismiss]
        )
    }

    private func detectAutoPairedPeers() async {
        var nowPaired: Set<String> = []
        for peer in source.state.peers {
            guard let hex = peer.meshPublicKey?.popopxHex else { continue }
            if case .paired = await pairing.state(for: hex) { nowPaired.insert(hex) }
        }
        if let newcomer = nowPaired.subtracting(knownPairedPeers).sorted().first {
            autoPairedPeer = newcomer
            autoPairedAt = .now
        }
        knownPairedPeers = nowPaired
    }

    static func radioTitle(_ state: PopopxBluetoothState) -> String {
        switch state {
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access not granted"
        case .resetting: "Bluetooth is resetting"
        case .unsupported: "This device has no Bluetooth mesh"
        case .poweredOn, .unknown: "Bluetooth unavailable"
        }
    }

    /// A 64-character key is not readable in a banner; the first 16 are what module 3's own logs quote.
    static func shorten(_ hex: String) -> String {
        hex.count > 16 ? "\(hex.prefix(16))…" : hex
    }
}

// MARK: - View

/// The top overlay itself, drawn through the safe area so the chat under it keeps its own scroll
/// behaviour and its own code.
@MainActor
public struct ManualPairingBannerView: View {
    @ObservedObject private var model: PopopxMeshBannerModel

    public init(model: PopopxMeshBannerModel) {
        self.model = model
    }

    public var body: some View {
        if let presentation = model.presentation {
            banner(presentation)
        } else {
            EmptyView()
        }
    }

    private func banner(_ presentation: PopopxMeshBannerPresentation) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: symbol(for: presentation.content))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(tint(for: presentation.content))
                    .frame(width: 24, height: 24, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(presentation.title))
                        .font(.subheadline.weight(.semibold))
                    if let detail = presentation.detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                controls(presentation)
            }
            .padding(12)
            .frame(minHeight: 54)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
        }
    }

    @ViewBuilder
    private func controls(_ presentation: PopopxMeshBannerPresentation) -> some View {
        if presentation.actions.contains(.approve) {
            HStack(spacing: 12) {
                Button("Decline") {
                    Task { await model.decline() }
                }
                Button("Approve") {
                    Task { await model.approve() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            Button {
                model.dismiss()
            } label: {
                Image(systemName: "multiply")
            }
            .tint(.primary)
        }
    }

    private func symbol(for content: PopopxMeshBannerContent) -> String {
        switch content {
        case .silent: "circle"
        case .awaitingConfirmation: "link"
        case .autoPaired: "checkmark.seal"
        case .radioUnavailable: "exclamationmark.wrench"
        case .peerOutOfRange: "wifi.slash"
        }
    }

    private func tint(for content: PopopxMeshBannerContent) -> Color {
        switch content {
        case .awaitingConfirmation: .accentColor
        case .autoPaired: .green
        case .radioUnavailable, .peerOutOfRange: .orange
        case .silent: .gray
        }
    }
}

public extension ManualPairingBannerView {
    /// The `host()`-style entry point: the only thing a mount site has to name.
    static func host(_ model: PopopxMeshBannerModel) -> ManualPairingBannerView {
        ManualPairingBannerView(model: model)
    }
}

public extension View {
    /// Zero-breakage mount — one line, and `self` is not touched:
    ///
    /// ```swift
    /// ExistingChatView().popopxMeshBanner(bannerModel)
    /// ```
    ///
    /// `edge: .bottom` puts it above the compose bar, which is where module 5's "cannot deliver" line
    /// belongs; `.top` is the default, matching where `ChatView` puts its own status strips.
    func popopxMeshBanner(
        _ model: PopopxMeshBannerModel,
        edge: VerticalEdge = .top
    ) -> some View {
        safeAreaInset(edge: edge, spacing: 0) { ManualPairingBannerView.host(model) }
    }
}
