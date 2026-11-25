//
//  PopopxMeshStateSource.swift
//  PopopxMeshUI
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The one place the mesh's event stream becomes interface state. Modules 1-4 publish
//  `PopopxMeshEvent`s; every view in this target reads the reduced snapshot below instead of
//  inventing its own listener, so that "how many subscribers does the hub have" stays a number the
//  fuse can reason about (`PopopxMeshKillSwitch.verifiedActivitySnapshot`) and so a view that
//  disappears cannot leave a pump running.
//
//  Deliberately absent: Nostr, relays, geohash, WebSockets. The plaza's neighbourhood is Bluetooth
//  range and nothing else (iron rule 1).
//

import Combine
import Foundation
import PopopxMeshKit

/// What the mesh currently looks like from inside the app. A value, so views diff it and tests can
/// assert on it without a window.
public struct PopopxMeshStreamState: Hashable, Sendable {
    /// The radio, as the last `bluetoothState` event reported it (module 4 keeps its own copy in the
    /// monitor; this is the UI's).
    public let radioState: PopopxBluetoothState

    /// Neighbours the mesh has named, with the hop count each was last heard at.
    public let peers: [PopopxMeshPeer]

    /// Private offline messages, newest copy of each `messageId`, in arrival order.
    public let privateMessages: [PopopxMeshTimelineMessage]

    /// The `#mesh` plaza: unencrypted local broadcasts, in arrival order.
    public let broadcasts: [PopopxMeshTimelineMessage]

    /// ids the mesh could not put on the radio (or the router has not seen an ACK for) — the rows
    /// the timeline marks with the grey clock.
    public let awaitingRelayMessageIDs: Set<String>

    public init(
        radioState: PopopxBluetoothState = .unknown,
        peers: [PopopxMeshPeer] = [],
        privateMessages: [PopopxMeshTimelineMessage] = [],
        broadcasts: [PopopxMeshTimelineMessage] = [],
        awaitingRelayMessageIDs: Set<String> = []
    ) {
        self.radioState = radioState
        self.peers = peers
        self.privateMessages = privateMessages
        self.broadcasts = broadcasts
        self.awaitingRelayMessageIDs = awaitingRelayMessageIDs
    }

    public func peer(withHex hex: String) -> PopopxMeshPeer? {
        peers.first { $0.peerID.hex == hex || $0.meshPublicKey?.popopxHex == hex }
    }

    /// The most recent broadcast, if any: the plaza's "last heard from" line.
    public var latestBroadcastAt: Date? {
        broadcasts.map(\.timestamp).max()
    }
}

/// Routing state the interface would like to know but must not require: module 5 owns it, and module 5
/// is not part of this target. Three members, nothing else, so the app-side router can conform to
/// it in one extension without revealing its internals.
public protocol PopopxMeshRoutingObserving: Sendable {
    /// Whether this device has a public-internet (SMP) route. The banner's "Bluetooth disconnected, public contact not yet exchanged" copy needs this to be
    /// honest about whether re-sending over SMP is even possible.
    func isPublicNetworkAvailable() async -> Bool

    /// Messages the router has queued for a relay and not yet seen an ACK for. The timeline unions
    /// these with what the mesh itself reported as `sendFailed`, so a build with no router wired in
    /// still shows the right grey clocks for the failures the engine does report.
    func pendingRelayMessageIDs() async -> Set<String>

    /// Whether this peer's mesh key is bound to a POPOPX contact — i.e. whether an offline
    /// conversation has a public-network identity behind it at all.
    func isContactBound(forMeshPublicKeyHex meshPublicKeyHex: String) async -> Bool

    /// The mesh `messageId` → main-database row id pairs for the messages that have already been
    /// flushed over SMP. A message has two names — the id this router minted, which only the offline
    /// row carries, and the row id the app's own store gave it, which only the app's list carries — and
    /// without the pair the merged timeline cannot know they are one message.
    func flushedAppChatItemIDs() async -> [String: Int64]
}

public extension PopopxMeshRoutingObserving {
    /// The answer a host that has not wired module 5 gets: no pairs, which is the behaviour before the
    /// dual-id mapping — a flushed message is drawn once by the app and once by the mesh strip.
    func flushedAppChatItemIDs() async -> [String: Int64] { [:] }
}

/// The default when the host has not wired module 5 in yet: offline only, which is exactly what a
/// build with no router must claim.
public struct PopopxMeshNoRoutingObserver: PopopxMeshRoutingObserving {
    public init() {}

    public func isPublicNetworkAvailable() async -> Bool { false }

    public func pendingRelayMessageIDs() async -> Set<String> { [] }

    public func isContactBound(forMeshPublicKeyHex meshPublicKeyHex: String) async -> Bool { false }
}

/// The continuation registry of `PopopxMeshStateSource`, kept in its own class for one reason:
/// `AsyncStream.Continuation.onTermination` wants a `@Sendable` closure, and a `@MainActor` class
/// cannot be captured from one. The mailbox can, and its lock is what makes that safe — every
/// mutation of `consumers` happens under it, so `@unchecked Sendable` here is a checked claim.
final class PopopxMeshStateMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var consumers: [UUID: AsyncStream<PopopxMeshStreamState>.Continuation] = [:]

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return consumers.count
    }

    func insert(
        _ continuation: AsyncStream<PopopxMeshStreamState>.Continuation,
        id: UUID
    ) {
        lock.lock()
        defer { lock.unlock() }
        consumers[id] = continuation
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        consumers[id] = nil
    }

    func yield(_ state: PopopxMeshStreamState) {
        lock.lock()
        let targets = Array(consumers.values)
        lock.unlock()
        for continuation in targets { continuation.yield(state) }
    }

    func finishAll() -> Int {
        lock.lock()
        let targets = Array(consumers.values)
        consumers.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
        return targets.count
    }
}

/// Subscribes to the hub once, reduces every event into `PopopxMeshStreamState`, and hands that
/// state to as many views as need it. Also a fuse component: while it is up it holds exactly one hub
/// subscription, which is the thing `verifiedActivitySnapshot` counts.
@MainActor
public final class PopopxMeshStateSource: ObservableObject, PopopxMeshSwitchable {
    /// The single mirror the views mount against. Views take it as a parameter, so a host that
    /// builds its own hub for tests simply builds its own source.
    public static let shared = PopopxMeshStateSource()

    /// Messages kept per stream. A flood carries each text once per neighbour that hears it; the
    /// window only has to cover what a screen can scroll, and the engine keeps the mesh's own
    /// dedup memory, so this is interface retention, not correctness.
    public static let defaultCapacity = 256

    @Published public private(set) var state = PopopxMeshStreamState()

    private let hub: PopopxMeshEventHub
    private let capacity: Int
    private let mailbox = PopopxMeshStateMailbox()
    private var pumpTask: Task<Void, Never>?

    public init(hub: PopopxMeshEventHub = .shared, capacity: Int = PopopxMeshStateSource.defaultCapacity) {
        self.hub = hub
        self.capacity = max(16, capacity)
    }

    /// How many views are reading this mirror. A non-zero count with the fuse off would be a leaked
    /// subscription, which is exactly what the checklist looks for.
    public var consumerCount: Int { mailbox.count }

    public var isPumping: Bool { pumpTask != nil }

    // MARK: - Fuse component

    public func meshSwitchDidTurnOn(nickname: String?) async {
        start()
    }

    public func meshSwitchDidTurnOff() async {
        stop()
    }

    // MARK: - Lifecycle

    /// Idempotent, so several views may call it and the fuse may call it again after a restart.
    public func start() {
        guard pumpTask == nil else { return }
        let hub = self.hub
        pumpTask = Task { @MainActor [weak self] in
            let stream = await hub.subscribe()
            for await event in stream {
                if Task.isCancelled { break }
                self?.ingest(event)
            }
        }
    }

    /// Stops the pump and closes every consumer's stream: a view that comes back later calls
    /// `observeState()` again and gets a fresh one.
    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        _ = mailbox.finishAll()
        state = PopopxMeshStreamState()
    }

    /// The reduced state, as a stream the interface can iterate. The first value is always the
    /// current state, so a view that mounts late does not render an empty screen while it waits.
    public func observeState() -> AsyncStream<PopopxMeshStreamState> {
        let id = UUID()
        let initial = state
        let (stream, continuation) = AsyncStream<PopopxMeshStreamState>.makeStream()
        let mailbox = self.mailbox
        continuation.onTermination = { _ in
            mailbox.remove(id)
        }
        mailbox.insert(continuation, id: id)
        continuation.yield(initial)
        return stream
    }

    // MARK: - Reduction

    /// One event in, one state out. Public because it is the whole behaviour of this type and the
    /// tests drive it directly, without a radio and without a hub.
    public func ingest(_ event: PopopxMeshEvent) {
        switch event {
        case let .bluetoothState(radio):
            publish(radioState: radio)

        case let .peerAppeared(peer):
            var peers = state.peers
            if let index = peers.firstIndex(where: { $0.peerID == peer.peerID }) {
                peers[index] = peer
            } else {
                peers.append(peer)
            }
            peers.sort { $0.peerID.hex < $1.peerID.hex }
            publish(peers: peers)

        case let .peerDisappeared(peerID):
            publish(peers: state.peers.filter { $0.peerID != peerID })

        case let .inbound(inbound):
            var relayIDs = state.awaitingRelayMessageIDs
            if let frame = inbound.controlFrame, case let .deliveryAck(acknowledged) = frame {
                relayIDs.remove(acknowledged)
            }
            let message = PopopxMeshTimelineMessage(
                offline: inbound,
                senderNickname: nickname(of: inbound)
            )
            if inbound.isBroadcast {
                publish(
                    broadcasts: Self.append(message, to: state.broadcasts, capacity: capacity),
                    relayIDs: relayIDs
                )
            } else {
                publish(
                    privateMessages: Self.append(message, to: state.privateMessages, capacity: capacity),
                    relayIDs: relayIDs
                )
            }

        case let .sendFailed(messageId, _, _):
            var relayIDs = state.awaitingRelayMessageIDs
            relayIDs.insert(messageId)
            publish(relayIDs: relayIDs)
        }
    }

    /// The name the sender announced, looked up by public key first and by the 8-byte wire id
    /// second: a flood relayed before the handshake resolves the key still has an id in the table.
    private func nickname(of inbound: PopopxMeshInbound) -> String? {
        if let hex = inbound.senderMeshPublicKey?.popopxHex, let peer = state.peer(withHex: hex) {
            return peer.nickname
        }
        return state.peers.first { $0.peerID == inbound.sender }?.nickname
    }

    /// The one writer of `state`: each branch rebuilds it, so a view cannot observe a snapshot that
    /// was half updated between two events.
    private func publish(
        radioState: PopopxBluetoothState? = nil,
        peers: [PopopxMeshPeer]? = nil,
        privateMessages: [PopopxMeshTimelineMessage]? = nil,
        broadcasts: [PopopxMeshTimelineMessage]? = nil,
        relayIDs: Set<String>? = nil
    ) {
        state = PopopxMeshStreamState(
            radioState: radioState ?? state.radioState,
            peers: peers ?? state.peers,
            privateMessages: privateMessages ?? state.privateMessages,
            broadcasts: broadcasts ?? state.broadcasts,
            awaitingRelayMessageIDs: relayIDs ?? state.awaitingRelayMessageIDs
        )
        mailbox.yield(state)
    }

    /// Newest copy of a repeated id wins, in place; the oldest entries fall off the front. Keeping
    /// the position of a repeated id means a re-flooded message cannot jump a queue the user is
    /// reading.
    static func append(
        _ message: PopopxMeshTimelineMessage,
        to messages: [PopopxMeshTimelineMessage],
        capacity: Int
    ) -> [PopopxMeshTimelineMessage] {
        var next = messages
        if let index = next.firstIndex(where: { $0.messageID == message.messageID }) {
            next[index] = message
            return next
        }
        next.append(message)
        if next.count > capacity { next.removeFirst(next.count - capacity) }
        return next
    }
}
