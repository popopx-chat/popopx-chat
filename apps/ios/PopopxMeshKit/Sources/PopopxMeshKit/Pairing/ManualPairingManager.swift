//
//  ManualPairingManager.swift
//  PopopxMeshKit  —  module 3
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Turns a Bluetooth neighbour into a POPOPX contact. Two policies, chosen in module 1: manual
//  confirmation (the default — an inbound request only raises the chat banner and nothing is bound
//  until the user approves) and auto-silent (the exchange completes on its own once the Bluetooth
//  private session exists).
//

import Foundation

public enum MeshPairingState: Hashable, Sendable {
    case unlinked
    /// We sent our invite link and are waiting for the peer to accept it.
    case requestSent(inviteLink: String)
    /// The peer sent us its invite link; the argument is that link, verbatim, so the banner can
    /// quote exactly what will be bound if the user approves.
    case requestReceived(inviteLink: String)
    case paired
}

/// A request waiting on the user. Keyed by peer, because a peer re-sending the same request must
/// not stack a second banner.
public struct PopopxPairingRequest: Hashable, Sendable, Identifiable {
    public let peerMeshPublicKeyHex: String
    public let inviteLink: String
    public let receivedAt: Date

    public init(peerMeshPublicKeyHex: String, inviteLink: String, receivedAt: Date = .now) {
        self.peerMeshPublicKeyHex = peerMeshPublicKeyHex
        self.inviteLink = inviteLink
        self.receivedAt = receivedAt
    }

    public var id: String { peerMeshPublicKeyHex }
}

public enum PopopxPairingError: Error, Hashable, Sendable {
    case peerKeyRejected
    case alreadyPaired(peerMeshPublicKeyHex: String)
    case declinedRecently(peerMeshPublicKeyHex: String)
    case requestUnknown(peerMeshPublicKeyHex: String)
    case requestSuperseded(peerMeshPublicKeyHex: String)
    /// The link inside the frame failed module 2's prefix rules; that keeps it out of the FFI.
    case inviteLinkRejected
    case sendFailed(PopopxMeshSendFailure)
    case offlineBridge(String)
    /// The pairing itself succeeded but the mapping table refused the write (a malformed key, or a
    /// Keychain that would not take it). Kept distinct because the user's answer is different: the
    /// contact link exists either way, the mesh just cannot remember whose it is.
    case mappingStoreFailed(String)
}

public actor ManualPairingManager {
    // No `shared`: this type needs module 2, and module 2 needs the app's chat core, which only the host
    // target can supply. Phase 2 constructs one and hands it to the UI and to the event pump.

    /// Posted when a manual-mode request needs the user. The banner (phase 2) observes it; the
    /// `userInfo` carries only the peer key and the arrival time — the link itself is fetched from
    /// `pendingRequests()` by whoever is allowed to show it.
    public static let bannerNotification = Notification.Name("chat.popopx.mesh.pairingRequest")

    /// A declined peer is not asked again for this long, so a stationary neighbour cannot keep the
    /// banner up forever after the user said no.
    public static let declineCooldown: TimeInterval = 60

    private struct PeerLink {
        var state: MeshPairingState
        var declinedAt: Date?
    }

    private let outbound: any PopopxMeshOutbound
    private let bridge: PopopxOfflineBridge
    private let store: IdentityMappingStore
    private let hub: PopopxMeshEventHub

    private var peers: [String: PeerLink] = [:]
    private var pending: [String: PopopxPairingRequest] = [:]
    private var observationTask: Task<Void, Never>?

    public init(
        outbound: any PopopxMeshOutbound,
        bridge: PopopxOfflineBridge,
        store: IdentityMappingStore = .shared,
        hub: PopopxMeshEventHub = .shared
    ) {
        self.outbound = outbound
        self.bridge = bridge
        self.store = store
        self.hub = hub
    }

    // MARK: - Lifecycle

    public func startObserving() async {
        guard observationTask == nil else { return }
        let stream = await hub.subscribe()
        observationTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                await self?.handle(event)
            }
        }
        PopopxMeshLog.pairing.info("▶️ pairing manager started")
    }

    public func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        pending.removeAll()
        PopopxMeshLog.pairing.info("⏹ pairing manager stopped")
    }

    // MARK: - State surface for the UI layer

    public func state(for peerMeshPublicKeyHex: String) -> MeshPairingState {
        peers[peerMeshPublicKeyHex]?.state ?? .unlinked
    }

    public func pendingRequests() -> [PopopxPairingRequest] {
        pending.values.sorted { $0.receivedAt < $1.receivedAt }
    }

    public func allStates() -> [(peerMeshPublicKeyHex: String, state: MeshPairingState)] {
        peers.map { ($0.key, $0.value.state) }.sorted { $0.peerMeshPublicKeyHex < $1.peerMeshPublicKeyHex }
    }

    // MARK: - Outbound: we ask

    /// Generates our offline invite link, binds it to the peer's key, and sends it.
    @discardableResult
    public func initiatePairing(with peerMeshPublicKeyHex: String, incognito: Bool = false)
        async throws(PopopxPairingError) -> PopopxOfflineInvite
    {
        guard PopopxMeshControlFrame.isMeshPublicKey(peerMeshPublicKeyHex) else {
            throw .peerKeyRejected
        }
        if case .paired = peers[peerMeshPublicKeyHex]?.state {
            throw .alreadyPaired(peerMeshPublicKeyHex: peerMeshPublicKeyHex)
        }
        // The durable check: an app restart clears `peers`, not the mapping table. A peer that is
        // still only pending is not paired yet, and asking again is how a lost request recovers.
        if await store.mapping(forMeshPublicKeyHex: peerMeshPublicKeyHex)?.contactId != nil {
            throw .alreadyPaired(peerMeshPublicKeyHex: peerMeshPublicKeyHex)
        }
        try rejectIfRecentlyDeclined(peerMeshPublicKeyHex)

        let invite: PopopxOfflineInvite
        do {
            invite = try await bridge.generateOfflineInviteLink(
                meshPublicKeyHex: peerMeshPublicKeyHex,
                incognito: incognito
            )
        } catch {
            throw .offlineBridge(String(describing: error))
        }
        // Recorded before the frame goes out: the peer may answer before this call returns, and an
        // answer with nothing to match it against is a pairing that silently does not exist.
        do {
            try await store.bind(
                tempConnId: invite.tempConnId,
                meshPublicKeyHex: peerMeshPublicKeyHex,
                nickname: nil
            )
        } catch {
            throw .mappingStoreFailed(String(describing: error))
        }
        do {
            try await outbound.send(
                control: .pairingRequest(inviteLink: invite.inviteLink),
                to: peerMeshPublicKeyHex
            )
        } catch {
            throw .sendFailed(error.failure)
        }
        peers[peerMeshPublicKeyHex, default: PeerLink(state: .unlinked)].state =
            .requestSent(inviteLink: invite.inviteLink)
        PopopxMeshLog.pairing.notice(
            "⬆️ pairing request sent to \(peerMeshPublicKeyHex.prefix(8), privacy: .public)"
        )
        return invite
    }

    // MARK: - Inbound: the user decides

    /// Approving is the only path that reaches module 2 in manual mode: the link becomes a pending
    /// contact, then the peer is told which key accepted it.
    @discardableResult
    public func approve(_ request: PopopxPairingRequest, incognito: Bool = false)
        async throws(PopopxPairingError) -> PopopxOfflineAcceptance
    {
        guard let recorded = pending[request.id] else {
            throw .requestUnknown(peerMeshPublicKeyHex: request.peerMeshPublicKeyHex)
        }
        guard recorded.inviteLink == request.inviteLink else {
            // The peer offered a different link since the banner appeared; the stale one must not
            // be bound.
            throw .requestSuperseded(peerMeshPublicKeyHex: request.peerMeshPublicKeyHex)
        }
        guard let normalized = PopopxOfflineBridge.normalizedInviteLink(request.inviteLink) else {
            pending[request.id] = nil
            peers[request.id]?.state = .unlinked
            throw .inviteLinkRejected
        }
        let acceptance: PopopxOfflineAcceptance
        do {
            acceptance = try await bridge.acceptOfflineInviteLink(
                normalized,
                meshPublicKeyHex: request.peerMeshPublicKeyHex,
                incognito: incognito
            )
        } catch {
            throw .offlineBridge(String(describing: error))
        }
        pending[request.id] = nil
        do {
            try await acknowledge(pairingWith: request.peerMeshPublicKeyHex)
        } catch {
            // The contact is bound locally; a lost ACK only means the peer asks again, which is
            // recoverable, so the approval is not rolled back.
            PopopxMeshLog.pairing.error(
                "❌ pairing ack lost for \(request.peerMeshPublicKeyHex.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        return acceptance
    }

    public func decline(_ request: PopopxPairingRequest) {
        pending[request.id] = nil
        peers[request.peerMeshPublicKeyHex] = PeerLink(state: .unlinked, declinedAt: .now)
        PopopxMeshLog.pairing.notice(
            "🚫 pairing declined by user for \(request.peerMeshPublicKeyHex.prefix(8), privacy: .public)"
        )
    }

    /// The engine calls this when it has proof the peer holds our key — a `SYS_POPOPX_ACK` naming
    /// us, or a contact whose Noise session is established.
    public func markPaired(_ peerMeshPublicKeyHex: String) {
        peers[peerMeshPublicKeyHex] = PeerLink(state: .paired)
        pending[peerMeshPublicKeyHex] = nil
    }

    /// Dropping a peer also drops the durable binding, or a restart would resurrect a mapping the
    /// user just removed and `initiatePairing`'s durable check would refuse that peer forever.
    public func forget(_ peerMeshPublicKeyHex: String) async {
        peers[peerMeshPublicKeyHex] = nil
        pending[peerMeshPublicKeyHex] = nil
        do {
            _ = try await store.unbind(meshPublicKeyHex: peerMeshPublicKeyHex)
        } catch {
            PopopxMeshLog.pairing.error(
                "❌ mapping for \(peerMeshPublicKeyHex.prefix(8), privacy: .public) survived a forget: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Event handling

    private func handle(_ event: PopopxMeshEvent) async {
        switch event {
        case let .inbound(message):
            guard let frame = message.controlFrame else { return }
            // Control frames ride the encrypted private channel, so the sender's key is known by
            // construction. One that arrives without a key is an unauthenticated frame and is
            // dropped rather than banner-raised.
            guard let peerMeshPublicKeyHex = message.senderMeshPublicKey?.popopxHex,
                  PopopxMeshControlFrame.isMeshPublicKey(peerMeshPublicKeyHex) else {
                PopopxMeshLog.pairing.warning(
                    "⚠️ control frame from \(message.sender.hex, privacy: .public) with no resolved key — dropped"
                )
                return
            }
            switch frame {
            case let .pairingRequest(inviteLink):
                await handlePairingRequest(inviteLink, from: peerMeshPublicKeyHex)
            case let .pairingAck(meshPublicKey):
                await handlePairingAck(meshPublicKey, from: peerMeshPublicKeyHex)
            case .deliveryAck:
                break
            }

        case let .bluetoothState(state):
            if !state.isUsable {
                // Nothing can be answered while the radio is down; requests stay pending so the
                // user can still decide when the link returns.
                PopopxMeshLog.pairing.info("📡 radio unavailable (\(String(describing: state), privacy: .public))")
            }

        case .peerAppeared, .peerDisappeared, .sendFailed:
            break
        }
    }

    private func handlePairingRequest(_ inviteLink: String, from peerMeshPublicKeyHex: String) async {
        guard PopopxOfflineBridge.normalizedInviteLink(inviteLink) != nil else {
            PopopxMeshLog.pairing.warning(
                "⚠️ pairing link from \(peerMeshPublicKeyHex.prefix(8), privacy: .public) failed prefix validation — dropped"
            )
            return
        }
        if case .paired = peers[peerMeshPublicKeyHex]?.state {
            do {
                try await acknowledge(pairingWith: peerMeshPublicKeyHex)
            } catch {
                PopopxMeshLog.pairing.error(
                    "❌ re-ack failed for \(peerMeshPublicKeyHex.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            return
        }
        if recentlyDeclined(peerMeshPublicKeyHex) {
            PopopxMeshLog.pairing.info(
                "⏳ pairing request from \(peerMeshPublicKeyHex.prefix(8), privacy: .public) suppressed by decline cooldown"
            )
            return
        }

        let request = PopopxPairingRequest(peerMeshPublicKeyHex: peerMeshPublicKeyHex, inviteLink: inviteLink)
        pending[peerMeshPublicKeyHex] = request
        peers[peerMeshPublicKeyHex, default: PeerLink(state: .unlinked)].state =
            .requestReceived(inviteLink: inviteLink)

        // Manual mode stops here: the link is never handed to module 2 without the user.
        guard await store.pairingPolicy == .autoSilent else {
            NotificationCenter.default.post(
                name: Self.bannerNotification,
                object: nil,
                userInfo: [
                    "peerMeshPublicKeyHex": peerMeshPublicKeyHex,
                    "receivedAt": request.receivedAt
                ]
            )
            PopopxMeshLog.pairing.notice(
                "🔔 pairing request from \(peerMeshPublicKeyHex.prefix(8), privacy: .public) awaiting user"
            )
            return
        }

        do {
            _ = try await approve(request)
            PopopxMeshLog.pairing.notice(
                "🤝 auto-silent pairing with \(peerMeshPublicKeyHex.prefix(8), privacy: .public)"
            )
        } catch {
            PopopxMeshLog.pairing.error(
                "❌ auto pairing failed for \(peerMeshPublicKeyHex.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func handlePairingAck(_ meshPublicKey: String, from peerMeshPublicKeyHex: String) async {
        let localMeshPublicKeyHex = await outbound.localMeshPublicKeyHex
        guard meshPublicKey == localMeshPublicKeyHex else {
            // An ack naming someone else is either a stale relay or a lie; neither binds us.
            PopopxMeshLog.pairing.warning(
                "⚠️ pairing ack for a different key from \(peerMeshPublicKeyHex.prefix(8), privacy: .public) — ignored"
            )
            return
        }
        markPaired(peerMeshPublicKeyHex)
        PopopxMeshLog.pairing.notice("✅ paired with \(peerMeshPublicKeyHex.prefix(8), privacy: .public)")
    }

    // MARK: - Helpers

    private func acknowledge(pairingWith peerMeshPublicKeyHex: String) async throws(PopopxPairingError) {
        do {
            try await outbound.send(
                control: .pairingAck(meshPublicKey: await outbound.localMeshPublicKeyHex),
                to: peerMeshPublicKeyHex
            )
        } catch {
            throw .sendFailed(error.failure)
        }
        markPaired(peerMeshPublicKeyHex)
    }

    private func recentlyDeclined(_ peerMeshPublicKeyHex: String) -> Bool {
        guard let declinedAt = peers[peerMeshPublicKeyHex]?.declinedAt else { return false }
        return Date.now.timeIntervalSince(declinedAt) < Self.declineCooldown
    }

    private func rejectIfRecentlyDeclined(_ peerMeshPublicKeyHex: String) throws(PopopxPairingError) {
        if recentlyDeclined(peerMeshPublicKeyHex) {
            throw .declinedRecently(peerMeshPublicKeyHex: peerMeshPublicKeyHex)
        }
    }
}
