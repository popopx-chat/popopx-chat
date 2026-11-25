//
//  PopopxMeshDeduplicator.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Two memories with two jobs. The short one holds packet ids for the seconds a flood is in the
//  air, and is what stops a relay from echoing its own re-transmission back down the mesh. The
//  long one holds message ids for minutes, so a message that arrives twice — over two links, or
//  from the router after the radio already delivered it — is shown to the user once.
//
//  Both are bounded twice over, by age and by count, because each bound fails on its own: a TTL
//  alone lets a peer spray new ids and grow the table without limit, and a count alone lets a
//  peer keep one id alive forever by re-sending it.
//

import Foundation
import os

public struct PopopxMeshDedupStats: Sendable, Equatable {
    /// Ids in the flood window.
    public let recentCount: Int
    /// Ids in the message window.
    public let messageCount: Int
    /// Times a `note` call found the id already there, i.e. how much flooding this node has
    /// suppressed. Counted on `note` only: `contains` is a question, `note` is a decision.
    public let hits: Int

    public init(recentCount: Int, messageCount: Int, hits: Int) {
        self.recentCount = recentCount
        self.messageCount = messageCount
        self.hits = hits
    }
}

/// Every flood decision in the engine goes through here, so both lookups are dictionary hits and
/// eviction is O(1) from the front of an insertion queue: nothing in `note` walks the table.
public actor PopopxMeshDeduplicator {
    /// `PopopxMeshPacket.packetID` is 16 bytes and a mesh message id is capped by
    /// `PopopxMeshControlFrame.maxArgumentLength`. Anything longer is not an id this engine
    /// mints, so it is not worth a dictionary key: we answer "not seen" and stay stateless about
    /// it, which relays one copy instead of letting a stranger size our memory by his own bytes.
    public static let maxKeyBytes = 64

    private let recentWindow: TimeInterval
    private let recentMaxCount: Int
    private let messageWindow: TimeInterval
    private let messageMaxCount: Int

    private var packets = Window()
    private var messages = Window()
    private var hits = 0

    public init(config: PopopxMeshConfig = .default) {
        self.recentWindow = max(0, config.recentPacketWindow)
        self.recentMaxCount = max(1, config.recentPacketMaxCount)
        self.messageWindow = max(0, config.messageDedupMaxAge)
        self.messageMaxCount = max(1, config.messageDedupMaxCount)
    }

    // MARK: Packet level

    /// true the first time an id is seen — the caller may put it on the radio. false means it is a
    /// repeat and the caller must drop it.
    public func note(packetID: Data) -> Bool {
        guard !packetID.isEmpty, packetID.count <= Self.maxKeyBytes else {
            PopopxMeshLog.route.log("mesh dedup: packet id unusable as a key, not remembered")
            return true
        }
        let now = Date()
        packets.removeExpired(before: now.addingTimeInterval(-recentWindow))
        if packets.contains(packetID) {
            hits += 1
            return false
        }
        packets.insert(packetID, at: now)
        while packets.count > recentMaxCount {
            guard packets.removeOldest() else { break }
        }
        return true
    }

    /// Whether we would relay it, without saying that we looked. Also expires the front of the
    /// window, so a caller that only asks still keeps the table honest.
    public func contains(packetID: Data) -> Bool {
        let now = Date()
        packets.removeExpired(before: now.addingTimeInterval(-recentWindow))
        return packets.contains(packetID)
    }

    // MARK: Message level

    /// true when this envelope id has not been delivered yet, i.e. the caller should show or store
    /// it. Keyed by `PopopxMeshEnvelope.id`, which the sender mints and reuses verbatim across
    /// Bluetooth and SMP retries.
    public func noteMessage(id: String) -> Bool {
        let key = Data(id.utf8)
        guard !key.isEmpty, key.count <= PopopxMeshControlFrame.maxArgumentLength else {
            PopopxMeshLog.route.log("mesh dedup: message id unusable as a key, not remembered")
            return true
        }
        let now = Date()
        messages.removeExpired(before: now.addingTimeInterval(-messageWindow))
        if messages.contains(key) {
            hits += 1
            return false
        }
        messages.insert(key, at: now)
        while messages.count > messageMaxCount {
            guard messages.removeOldest() else { break }
        }
        return true
    }

    /// Message ids held, newest first — the order `PopopxGCSFilter.build` needs so that trimming
    /// to a byte budget drops the oldest ids rather than an arbitrary subset.
    public func seenMessageIDs() -> [Data] { messages.idsNewestFirst }

    /// A sketch of what we already have, for a peer that resyncs after being out of range.
    ///
    /// Built on message ids, not packet ids, on purpose: a packet id names one radio frame, so the
    /// 30-second flood window is a different set every second, is capped at 100 entries, and says
    /// nothing to a peer asking about hours of history. The message id is the thing whose
    /// re-delivery a user would notice, and `messageDedupMaxAge`/`MaxCount` is the window that
    /// outlives a resync.
    public func gossipFilter(maxBytes: Int, targetFalsePositiveRate: Double) -> PopopxGCSFilter? {
        PopopxGCSFilter.build(
            ids: seenMessageIDs(),
            maxBytes: maxBytes,
            targetFalsePositiveRate: targetFalsePositiveRate
        )
    }

    // MARK: Housekeeping

    /// Drops what has aged out of both windows. The mutating calls above do the same work for the
    /// front of each queue, so this only has to be called on a timer, and `now` is a parameter so
    /// a test can move the clock instead of waiting for it.
    public func prune(now: Date) {
        packets.removeExpired(before: now.addingTimeInterval(-recentWindow))
        messages.removeExpired(before: now.addingTimeInterval(-messageWindow))
    }

    public var stats: PopopxMeshDedupStats {
        PopopxMeshDedupStats(recentCount: packets.count, messageCount: messages.count, hits: hits)
    }

    // MARK: - Window

    /// Insertion-ordered id set with O(1) access to the oldest entry. Insertion order is also age
    /// order, because a repeat sighting neither moves its key nor refreshes its stamp: replaying a
    /// stale id must not let a peer keep it alive past the window it was supposed to leave.
    private struct Window {
        private var stamps: [Data: Date] = [:]
        private var order: [Data] = []
        private var head = 0

        var count: Int { stamps.count }

        func contains(_ id: Data) -> Bool { stamps[id] != nil }

        /// For an id `contains` has already reported absent; inserting a known id twice would put
        /// two queue entries behind one key and skew the eviction order.
        mutating func insert(_ id: Data, at date: Date) {
            stamps[id] = date
            order.append(id)
            compact()
        }

        mutating func oldest() -> (id: Data, at: Date)? {
            while head < order.count {
                let candidate = order[head]
                if let at = stamps[candidate] { return (candidate, at) }
                head += 1
            }
            return nil
        }

        @discardableResult
        mutating func removeOldest() -> Bool {
            guard let (id, _) = oldest() else { return false }
            stamps.removeValue(forKey: id)
            head += 1
            compact()
            return true
        }

        @discardableResult
        mutating func removeExpired(before cutoff: Date) -> Int {
            var removed = 0
            while let (id, at) = oldest(), at < cutoff {
                stamps.removeValue(forKey: id)
                head += 1
                removed += 1
            }
            if removed > 0 { compact() }
            return removed
        }

        var idsNewestFirst: [Data] { Array(order[head...].reversed()) }

        /// Amortises the queue: the front is dropped in bulk once half of it is dead, so eviction
        /// stays O(1) instead of shifting the whole array per insert.
        private mutating func compact() {
            guard head > 0, head * 2 >= order.count else { return }
            order.removeFirst(head)
            head = 0
        }
    }
}
