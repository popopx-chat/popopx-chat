//
//  PopopxMeshPendingForwardQueue.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  A message this device wanted to flood while no link was writable. It is not a retry queue — module 4
//  owns acknowledgements and the router owns what happens after one times out — and it is not
//  store-and-forward for other people's traffic, which the mesh relays immediately or drops. It holds
//  this device's own user-visible sends until the first link that can carry one opens, and it is empty
//  the moment the engine stops, because "with the fuse off no mesh state is left in memory" is the
//  rule `stop()` already states for sessions, peers and the deduplicator.
//

import Foundation

/// One send waiting for a link, with everything `deliver` needed to put it back on the radio.
///
/// It carries the whole packet rather than the frames cut for the link that was missing: the link that
/// opens later may negotiate a different MTU, and a frame cut for one peer is not a frame another can
/// take.
public struct PopopxMeshPendingForward: Equatable, Sendable {
    public let packet: PopopxMeshPacket
    /// The id the UI knows this send by, so a flush can be traced to the row it belonged to.
    public let messageID: String
    /// The peer the send was addressed to, when it was addressed at all. A flood names nobody, and a
    /// group message is a flood: this is nil for both, and the flush looks the peer up again rather
    /// than trusting an address that may have aged.
    public let peerMeshPublicKeyHex: String?

    public init(packet: PopopxMeshPacket, messageID: String, peerMeshPublicKeyHex: String? = nil) {
        self.packet = packet
        self.messageID = messageID
        self.peerMeshPublicKeyHex = peerMeshPublicKeyHex
    }
}

/// A bounded FIFO of sends the radio could not take.
///
/// The cap and the drop-oldest policy are `PopopxMessageRouter.maxUnacknowledgedMessages`'s, for the
/// reason the router states there: a queue that cannot be capped is a memory leak with a nicer name,
/// and the entries a long wait cannot reach are the ones the user has already scrolled past.
public struct PopopxMeshPendingForwardQueue: Equatable, Sendable {
    public static let defaultCapacity = 256

    public let capacity: Int
    private var entries: [PopopxMeshPendingForward] = []

    public init(capacity: Int = PopopxMeshPendingForwardQueue.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Adds a send, once. Re-offering an id that is already held is a no-op and answers false, because
    /// the same text reaching a neighbour twice is the defect this queue exists to avoid, not a
    /// feature of a flush that ran while another was pending.
    @discardableResult
    public mutating func enqueue(_ entry: PopopxMeshPendingForward) -> Bool {
        if contains(messageID: entry.messageID) { return false }
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return true
    }

    public func contains(messageID: String) -> Bool {
        entries.contains { $0.messageID == messageID }
    }

    /// Takes the whole queue out at once, oldest first, so a flush that finds no writable link again
    /// re-enqueues into an empty structure rather than racing the entries it is still iterating.
    public mutating func drain() -> [PopopxMeshPendingForward] {
        let pending = entries
        entries = []
        return pending
    }

    public mutating func removeAll() {
        entries = []
    }
}
