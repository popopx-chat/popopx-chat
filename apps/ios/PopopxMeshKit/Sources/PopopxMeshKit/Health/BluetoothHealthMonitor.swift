//
//  BluetoothHealthMonitor.swift
//  PopopxMeshKit  —  module 4
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Watches the radio and every Bluetooth node's freshness, and guards the delivery of each
//  outbound Bluetooth private message with a BLE_ACK timeout. It never decides where a message
//  goes: it reports, and module 5 (PopopxMessageRouter) reroutes.
//

import Foundation

/// What a delivery failure looks like to the router. `peerMeshPublicKeyHex` is nil when the peer
/// was only ever seen by its 8-byte wire id — a relay can drop a flood before the sender's key is
/// known to us, and the router still has to be told which message stalled.
public struct PopopxBluetoothDeliveryFailure: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// No `BLE_ACK:<messageId>` inside `PopopxMeshConfig.bleAckTimeout`.
        case ackTimeout
        /// The link carrying the message closed, or the mesh could not put it on the radio.
        case linkLost
        /// Our own radio went off or lost authorization with the message still outstanding.
        case radioUnavailable(PopopxBluetoothState)
    }

    public let messageId: String
    public let peerMeshPublicKeyHex: String?
    public let peerIDHex: String
    public let reason: Reason
    public let failedAt: Date

    public init(
        messageId: String,
        peerMeshPublicKeyHex: String?,
        peerIDHex: String,
        reason: PopopxBluetoothDeliveryFailure.Reason,
        failedAt: Date = .now
    ) {
        self.messageId = messageId
        self.peerMeshPublicKeyHex = peerMeshPublicKeyHex
        self.peerIDHex = peerIDHex
        self.reason = reason
        self.failedAt = failedAt
    }
}

/// One node's freshness as the monitor last saw it.
public struct PopopxPeerReachability: Hashable, Sendable {
    public let peerIDHex: String
    public let meshPublicKeyHex: String?
    public let lastSeenAt: Date
    public let hopCount: Int
    public let isDirect: Bool

    public func isReachable(now: Date, radioOn: Bool, timeout: TimeInterval) -> Bool {
        radioOn && now.timeIntervalSince(lastSeenAt) <= timeout
    }
}

public actor BluetoothHealthMonitor {
    public static let shared = BluetoothHealthMonitor()

    /// A node silent for this long is unreachable; `isPeerReachable`'s parameter defaults to it.
    public static let defaultReachabilityTimeout = PopopxMeshConfig.default.peerReachabilityTimeout

    private struct Outstanding {
        let peerIDHex: String
        let peerMeshPublicKeyHex: String?
        let armedAt: Date
        let timeoutTask: Task<Void, Never>
    }

    private let config: PopopxMeshConfig
    private let hub: PopopxMeshEventHub

    private var radioState: PopopxBluetoothState = .unknown
    private var nodes: [String: PopopxPeerReachability] = [:]
    /// The mesh binds links to 8-byte wire ids; handlers and the mapping store speak in public
    /// keys, so both spellings of a node are kept side by side.
    private var peerIDHexByMeshKey: [String: String] = [:]

    private var outstanding: [String: Outstanding] = [:]
    private var failureHandler: (@Sendable (PopopxBluetoothDeliveryFailure) async -> Void)?
    private var observationTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    public init(
        config: PopopxMeshConfig = .default,
        hub: PopopxMeshEventHub = .shared
    ) {
        self.config = config
        self.hub = hub
    }

    // MARK: - Lifecycle

    /// Subscribes to the mesh event stream and starts the sweep that expires stale nodes.
    /// Idempotent: the global switch can call start/stop repeatedly.
    public func start() async {
        guard observationTask == nil else { return }
        let stream = await hub.subscribe()
        observationTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                await self?.handle(event)
            }
        }
        let interval = config.maintenanceInterval
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.sweep()
            }
        }
        PopopxMeshLog.health.info("▶️ health monitor started")
    }

    /// Stops observing and fails everything still outstanding: an armed timer must not fire into a
    /// stopped monitor, and silence after stop() is not proof of delivery.
    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        let stalled = outstanding.keys
        for messageId in stalled {
            fail(messageId: messageId, reason: .radioUnavailable(radioState))
        }
        outstanding.removeAll()
        PopopxMeshLog.health.info("⏹ health monitor stopped, outstanding=\(stalled.count, privacy: .public)")
    }

    public func setDeliveryFailureHandler(
        _ handler: (@Sendable (PopopxBluetoothDeliveryFailure) async -> Void)?
    ) {
        failureHandler = handler
    }

    // MARK: - Outbound guard

    /// Arms the BLE_ACK deadline for one outbound Bluetooth private message. The router calls this
    /// for every message it puts on the radio, and again if it re-sends the same `messageId`.
    public func recordOutbound(messageId: String, peerMeshPublicKeyHex: String? = nil, peerIDHex: String) {
        guard outstanding[messageId] == nil else { return }
        let timeout = config.bleAckTimeout
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self else { return }
            await self.expired(messageId: messageId)
        }
        outstanding[messageId] = Outstanding(
            peerIDHex: peerIDHex,
            peerMeshPublicKeyHex: peerMeshPublicKeyHex,
            armedAt: .now,
            timeoutTask: task
        )
        PopopxMeshLog.health.debug(
            "⏱ armed BLE_ACK id=\(messageId.prefix(8), privacy: .public) timeout=\(timeout, privacy: .public)"
        )
    }

    /// A `BLE_ACK:<messageId>` arrived. Cancels the guard; an unknown id means the peer acked
    /// something we already gave up on, which is not an error.
    public func confirmDelivery(messageId: String) {
        guard let entry = outstanding.removeValue(forKey: messageId) else { return }
        entry.timeoutTask.cancel()
        touch(
            peerIDHex: entry.peerIDHex,
            meshPublicKeyHex: entry.peerMeshPublicKeyHex,
            hopCount: nodes[entry.peerIDHex]?.hopCount ?? 0,
            isDirect: nodes[entry.peerIDHex]?.isDirect ?? false
        )
        PopopxMeshLog.health.debug(
            "✅ BLE_ACK id=\(messageId.prefix(8), privacy: .public) after=\(Date.now.timeIntervalSince(entry.armedAt), privacy: .public)s"
        )
    }

    public var outstandingMessageCount: Int { outstanding.count }

    // MARK: - Reachability

    /// True when the peer was heard from (directly or relayed) within `timeout` and our own radio
    /// is up. This is the advance prediction the router asks before choosing Bluetooth over SMP.
    public func isPeerReachable(
        publicKey meshPublicKeyHex: String,
        timeout: TimeInterval = BluetoothHealthMonitor.defaultReachabilityTimeout
    ) -> Bool {
        guard radioState.isUsable else { return false }
        guard let peerIDHex = peerIDHexByMeshKey[meshPublicKeyHex],
              let node = nodes[peerIDHex] else { return false }
        return node.isReachable(now: .now, radioOn: radioState.isUsable, timeout: timeout)
    }

    /// The same question for a peer known only by its 8-byte wire id.
    public func isPeerIDReachable(
        _ peerIDHex: String,
        timeout: TimeInterval = BluetoothHealthMonitor.defaultReachabilityTimeout
    ) -> Bool {
        guard radioState.isUsable, let node = nodes[peerIDHex] else { return false }
        return node.isReachable(now: .now, radioOn: radioState.isUsable, timeout: timeout)
    }

    public var isRadioUsable: Bool { radioState.isUsable }

    public var currentRadioState: PopopxBluetoothState { radioState }

    public func reachability(ofMeshPublicKeyHex meshPublicKeyHex: String) -> PopopxPeerReachability? {
        if let peerIDHex = peerIDHexByMeshKey[meshPublicKeyHex] { return nodes[peerIDHex] }
        return nil
    }

    public func allNodes() -> [PopopxPeerReachability] {
        nodes.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    /// Drops nodes nobody has mentioned in four timeout windows, so a device that left the mesh
    /// for good cannot hold a link binding forever.
    public func sweep(now: Date = .now) {
        let expiry = config.peerReachabilityTimeout * 4
        for (peerIDHex, node) in nodes where now.timeIntervalSince(node.lastSeenAt) > expiry {
            nodes[peerIDHex] = nil
            if let meshKey = node.meshPublicKeyHex { peerIDHexByMeshKey[meshKey] = nil }
            PopopxMeshLog.health.debug("🧹 node expired peer=\(peerIDHex, privacy: .public)")
        }
    }

    // MARK: - Event handling

    private func handle(_ event: PopopxMeshEvent) {
        switch event {
        case let .bluetoothState(state):
            let changed = state != radioState
            radioState = state
            if changed {
                PopopxMeshLog.health.notice(
                    "🔄 radio state — now=\(String(describing: state), privacy: .public)"
                )
            }
            if !state.isUsable {
                let stalled = outstanding.keys
                for messageId in stalled {
                    fail(messageId: messageId, reason: .radioUnavailable(state))
                }
            }

        case let .peerAppeared(peer):
            let meshKey = peer.meshPublicKey?.popopxHex
            if let meshKey { peerIDHexByMeshKey[meshKey] = peer.peerID.hex }
            touch(
                peerIDHex: peer.peerID.hex,
                meshPublicKeyHex: meshKey,
                hopCount: peer.hopCount,
                isDirect: peer.isDirect
            )

        case let .peerDisappeared(peerID):
            // A direct neighbour vanishing does not make it unreachable while a relay still
            // answers for it, so lastSeen is kept and only the "direct" claim is dropped.
            if let node = nodes[peerID.hex] {
                nodes[peerID.hex] = PopopxPeerReachability(
                    peerIDHex: node.peerIDHex,
                    meshPublicKeyHex: node.meshPublicKeyHex,
                    lastSeenAt: node.lastSeenAt,
                    hopCount: node.hopCount + 1,
                    isDirect: false
                )
            }
            let stalled = stalledMessageIds(forPeerIDHex: peerID.hex)
            for messageId in stalled {
                fail(messageId: messageId, reason: .linkLost)
            }

        case let .inbound(message):
            if case let .control(.deliveryAck(acknowledgedId)) = message.body {
                confirmDelivery(messageId: acknowledgedId)
            }
            // Any packet naming a sender is evidence it is alive: a relayed fragment counts, which
            // is why the brief's rule is "no heartbeat OR relay packet" rather than link-local only.
            touch(
                peerIDHex: message.sender.hex,
                meshPublicKeyHex: message.senderMeshPublicKey?.popopxHex,
                hopCount: message.hopCount,
                isDirect: message.hopCount == 0
            )
            if let meshKey = message.senderMeshPublicKey?.popopxHex {
                peerIDHexByMeshKey[meshKey] = message.sender.hex
            }

        case let .sendFailed(messageId, peer, reason):
            guard outstanding[messageId] != nil else { return }
            let mapped: PopopxBluetoothDeliveryFailure.Reason
            switch reason {
            case let .radioUnavailable(state):
                mapped = .radioUnavailable(state)
            default:
                mapped = .linkLost
            }
            if let peer {
                // The mesh never left the device, so no ACK will come; report it the same way an
                // ACK timeout would be reported so the router has one code path.
                fail(messageId: messageId, reason: mapped)
                PopopxMeshLog.health.warning(
                    "⚠️ mesh refused send id=\(messageId.prefix(8), privacy: .public) peer=\(peer.hex, privacy: .public) reason=\(String(describing: reason), privacy: .public)"
                )
            } else {
                fail(messageId: messageId, reason: mapped)
                PopopxMeshLog.health.warning(
                    "⚠️ mesh refused broadcast id=\(messageId.prefix(8), privacy: .public) reason=\(String(describing: reason), privacy: .public)"
                )
            }
        }
    }

    private func touch(peerIDHex: String, meshPublicKeyHex: String?, hopCount: Int, isDirect: Bool) {
        let existing = nodes[peerIDHex]
        nodes[peerIDHex] = PopopxPeerReachability(
            peerIDHex: peerIDHex,
            meshPublicKeyHex: meshPublicKeyHex ?? existing?.meshPublicKeyHex,
            lastSeenAt: .now,
            hopCount: hopCount,
            isDirect: isDirect
        )
    }

    private func stalledMessageIds(forPeerIDHex peerIDHex: String) -> [String] {
        outstanding.compactMap { messageId, entry in
            entry.peerIDHex == peerIDHex ? messageId : nil
        }
    }

    private func expired(messageId: String) {
        guard outstanding.removeValue(forKey: messageId) != nil else { return }
        fail(messageId: messageId, reason: .ackTimeout)
    }

    /// Fires the handler off-actor: the router does I/O (SMP re-send), and a slow handler must not
    /// stall the monitor while other ACKs are arriving.
    private func fail(messageId: String, reason: PopopxBluetoothDeliveryFailure.Reason) {
        guard let entry = outstanding.removeValue(forKey: messageId) else { return }
        entry.timeoutTask.cancel()
        let resolvedMeshKey = entry.peerMeshPublicKeyHex ?? nodes[entry.peerIDHex]?.meshPublicKeyHex
        let failure = PopopxBluetoothDeliveryFailure(
            messageId: messageId,
            peerMeshPublicKeyHex: resolvedMeshKey,
            peerIDHex: entry.peerIDHex,
            reason: reason
        )
        PopopxMeshLog.health.warning(
            "❌ bluetooth delivery failed id=\(messageId.prefix(8), privacy: .public) reason=\(String(describing: reason), privacy: .public)"
        )
        guard let failureHandler else { return }
        Task { await failureHandler(failure) }
    }
}
