//
//  PopopxMeshFragments.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  A frame too large for one MTU goes on the radio as a run of `.fragment` packets and is put
//  back together on the far side. The 13-byte header and the receiver's ceilings are Bitchat's,
//  kept both for interoperation and because an inbound fragment is unauthenticated bytes from a
//  stranger: every count it declares is a request, never a fact, and the buffer below is exactly
//  what a stranger is allowed to grow.
//

import CryptoKit
import Foundation
import os

// MARK: - Reassembly key

/// Which stream a fragment belongs to: the sender's 8-byte wire id and the 8-byte id it stamped
/// on the stream. The sender half keeps two peers that happen to pick the same random id from
/// overwriting each other's reassembly.
public struct PopopxMeshFragmentKey: Hashable, Sendable {
    public let sender: UInt64
    public let id: UInt64

    public init(sender: UInt64, id: UInt64) {
        self.sender = sender
        self.id = id
    }

    /// The `id` half as 8 big-endian bytes, which is the order the wire writes a stream id in.
    public var idBytes: Data {
        var value = id.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

// MARK: - Header

/// One parsed fragment header. Parsing is where every number a peer gets to choose is checked,
/// so nothing downstream has to remember which fields are hostile.
public struct PopopxMeshFragmentHeader: Sendable {
    /// `fragmentID(8) ++ UInt16BE index ++ UInt16BE total ++ originalType(1)`.
    public static let byteCount = 13
    public static let idByteCount = 8
    /// Bitchat's ceiling on a declared fragment count. A stream longer than this is a lie about
    /// a size we would never send, and answering it is how a receiver's memory dies.
    public static let maxTotal = 10_000

    public let key: PopopxMeshFragmentKey
    public let index: Int
    public let total: Int
    /// The `type` byte of the packet being reassembled, so the caller can dispatch the finished
    /// payload without a second frame.
    public let originalType: UInt8
    public let data: Data
    public let isBroadcast: Bool

    /// nil for anything that is not a well-formed fragment: a payload shorter than the header, a
    /// sender field too short to key on, a `total` of zero or beyond `maxTotal`, an `index` the
    /// declared `total` cannot hold.
    public init?(packet: PopopxMeshPacket) {
        let payload = packet.payload
        guard payload.count >= Self.byteCount else { return nil }
        // The key reads the sender field as exactly 8 bytes. A shorter one would still shift out
        // a plausible-looking number, and a wrong key merges two strangers' streams.
        guard packet.senderID.count == PopopxMeshPeerID.byteCount else { return nil }

        let base = payload.startIndex
        let rawIndex = (UInt16(payload[base + 8]) << 8) | UInt16(payload[base + 9])
        let rawTotal = (UInt16(payload[base + 10]) << 8) | UInt16(payload[base + 11])
        guard rawTotal > 0, Int(rawTotal) <= Self.maxTotal, rawIndex < rawTotal else { return nil }

        self.key = PopopxMeshFragmentKey(
            sender: Self.u64(packet.senderID),
            id: Self.u64(payload.subdata(in: base..<(base + Self.idByteCount)))
        )
        self.index = Int(rawIndex)
        self.total = Int(rawTotal)
        self.originalType = payload[base + 12]
        self.data = payload.subdata(in: (base + Self.byteCount)..<payload.endIndex)
        self.isBroadcast = packet.isBroadcast
    }

    private static func u64(_ bytes: Data) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

// MARK: - Fragmenting

public enum PopopxMeshFragmenter {
    public static let fragmentIDByteCount = PopopxMeshFragmentHeader.idByteCount

    /// A stream id nobody else can predict, because it is half of the key an inbound fragment is
    /// filed under: a peer that could guess another peer's ids could pre-seed reassembly slots and
    /// race its own streams against them, so this comes from CryptoKit's RNG rather than a seedable
    /// source.
    public static func randomFragmentID() -> Data {
        Data(SymmetricKey(size: SymmetricKeySize(bitCount: 64)).withUnsafeBytes { Array($0) })
    }

    /// Splits `packet.payload` into runs of at most `maxPayloadBytes - 13` bytes and wraps each
    /// one as a `.fragment` packet, keeping the original `senderID`, `recipientID`, `timestamp`,
    /// `ttl`, `signature` and version so a receiver still ties the run to the same sender and a
    /// relay still dedups it the same way.
    ///
    /// A payload that already fits comes back as a one-element array holding a *wrapped* fragment
    /// rather than the packet itself: one shape on the wire means one path through an inbound
    /// parser, and a sender that had to branch on "did it fit" would branch wrongly under pressure.
    ///
    /// nil when no valid split exists — a budget that cannot hold the header plus one byte, an
    /// empty payload, a wrong-width id, a packet that is already a fragment, or more fragments
    /// than any receiver in the mesh is allowed to accept.
    public static func fragment(
        _ packet: PopopxMeshPacket,
        maxPayloadBytes: Int,
        fragmentID: Data = PopopxMeshFragmenter.randomFragmentID()
    ) -> [PopopxMeshPacket]? {
        guard fragmentID.count == fragmentIDByteCount else { return nil }
        guard packet.type != PopopxMeshMessageType.fragment.rawValue else { return nil }
        guard maxPayloadBytes > PopopxMeshFragmentHeader.byteCount else { return nil }
        let chunkSize = maxPayloadBytes - PopopxMeshFragmentHeader.byteCount
        guard !packet.payload.isEmpty else { return nil }

        let count = (packet.payload.count + chunkSize - 1) / chunkSize
        guard count <= PopopxMeshFragmentHeader.maxTotal else { return nil }

        let base = packet.payload.startIndex
        var fragments: [PopopxMeshPacket] = []
        fragments.reserveCapacity(count)
        var offset = 0
        for index in 0..<count {
            let end = min(offset + chunkSize, packet.payload.count)
            let chunk = packet.payload.subdata(in: (base + offset)..<(base + end))
            fragments.append(
                makeFragment(
                    of: packet,
                    fragmentID: fragmentID,
                    index: index,
                    total: count,
                    chunk: chunk
                )
            )
            offset = end
        }
        return fragments
    }

    private static func makeFragment(
        of packet: PopopxMeshPacket,
        fragmentID: Data,
        index: Int,
        total: Int,
        chunk: Data
    ) -> PopopxMeshPacket {
        var payload = Data(capacity: PopopxMeshFragmentHeader.byteCount + chunk.count)
        payload.append(fragmentID)
        payload.append(contentsOf: bigEndian(UInt16(index)))
        payload.append(contentsOf: bigEndian(UInt16(total)))
        payload.append(packet.type)
        payload.append(chunk)

        return PopopxMeshPacket(
            type: PopopxMeshMessageType.fragment.rawValue,
            ttl: packet.ttl,
            timestamp: packet.timestamp,
            senderID: packet.senderID,
            recipientID: packet.recipientID,
            payload: payload,
            signature: packet.signature,
            version: packet.version
        )
    }

    private static func bigEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
}

// MARK: - Outcomes

public enum PopopxMeshFragmentRejection: Hashable, Sendable {
    /// The header does not parse, or two fragments under one key disagree about the stream.
    case malformedHeader
    /// `maxInFlight` streams are already open and none of them has aged out yet.
    case tooManyInFlight
    /// Accepting this fragment would take the reassembly past `maxReassembledBytes`.
    case oversized(projectedBytes: Int, limit: Int)
    /// The stream this fragment belongs to is older than `lifetime` and was dropped instead of
    /// resumed; a later fragment under the same key starts a clean one.
    case expired
}

public enum PopopxMeshAssemblerOutcome: Sendable, Equatable {
    /// Held; the stream is still missing fragments. Also the answer for a repeat of an index
    /// we already hold, which is counted once.
    case stored(key: PopopxMeshFragmentKey)
    /// Every index of the stream is in. The buffer is gone from the table.
    case complete(key: PopopxMeshFragmentKey, originalType: UInt8, data: Data)
    case rejected(reason: PopopxMeshFragmentRejection)
}

// MARK: - Assembling

/// Files inbound fragments under their key until the stream is whole, then hands back the
/// original payload. Everything it owns is bounded by three numbers fixed at init and by nothing
/// a peer declares.
public actor PopopxMeshFragmentAssembler {
    private struct Assembly {
        let total: Int
        let originalType: UInt8
        let startedAt: Date
        var heldBytes: Int
        var chunks: [Int: Data]
    }

    private var assemblies: [PopopxMeshFragmentKey: Assembly] = [:]

    /// The three ceilings are fixed at init and read-only afterwards, so a caller that merely
    /// wants to know them — the engine sizing an outbound frame, a health page reporting the
    /// limit — does not have to hop onto the actor.
    nonisolated public let lifetime: TimeInterval
    nonisolated public let maxInFlight: Int
    /// Ceiling on one reassembled payload, not on the table: `maxInFlight` already bounds the
    /// total. Sized for a mesh frame, since nothing legitimate arrives as fragments otherwise.
    nonisolated public let maxReassembledBytes: Int

    public init(
        lifetime: TimeInterval = PopopxMeshConfig.default.fragmentLifetime,
        maxInFlight: Int = PopopxMeshConfig.default.maxInFlightAssemblies,
        maxReassembledBytes: Int = 2048
    ) {
        self.lifetime = lifetime
        self.maxInFlight = max(1, maxInFlight)
        self.maxReassembledBytes = max(1, maxReassembledBytes)
    }

    /// For a caller that already carries a config, so the fragment numbers cannot drift apart from
    /// the rest of the mesh's. `maxReassembledBytes` is not in the config yet: the engine's frame
    /// ceiling is its own decision until the contract grows a field for it.
    public init(config: PopopxMeshConfig, maxReassembledBytes: Int = 2048) {
        self.init(
            lifetime: config.fragmentLifetime,
            maxInFlight: config.maxInFlightAssemblies,
            maxReassembledBytes: maxReassembledBytes
        )
    }

    public var inFlightCount: Int { assemblies.count }

    /// nil when `packet` is not a fragment at all: that is the caller's type dispatch, not a
    /// stream we should be counting, logging or holding a slot for.
    ///
    /// `now` is injectable so the expiry path is testable without sleeping; production callers
    /// leave it alone.
    public func append(_ packet: PopopxMeshPacket, now: Date = Date()) -> PopopxMeshAssemblerOutcome? {
        guard packet.type == PopopxMeshMessageType.fragment.rawValue else { return nil }
        guard let header = PopopxMeshFragmentHeader(packet: packet) else {
            PopopxMeshLog.route.log("mesh fragment dropped: header does not parse")
            return .rejected(reason: .malformedHeader)
        }

        // One lookup for the whole function: the two checks below either return or leave the
        // stream as it was, so what we read here is still what is held further down.
        let held = assemblies[header.key]
        if let started = held {
            if now.timeIntervalSince(started.startedAt) > lifetime {
                // Drop rather than resume. Past the lifetime we can no longer tell this fragment
                // from a new stream that reused the id, and resuming on a stranger's say-so is
                // how a peer pins a buffer forever by dripping one fragment per window.
                assemblies.removeValue(forKey: header.key)
                PopopxMeshLog.route.log("mesh fragment dropped: stream expired")
                return .rejected(reason: .expired)
            }
            if started.total != header.total || started.originalType != header.originalType {
                // Two fragments under one key describe different streams. Nothing identifies the
                // honest one, so the whole stream goes; a real sender re-floods inside a round trip.
                assemblies.removeValue(forKey: header.key)
                PopopxMeshLog.route.log("mesh fragment dropped: stream contradicts itself")
                return .rejected(reason: .malformedHeader)
            }
        }

        // The projection is what we would hold afterwards, from bytes actually received. A
        // declared `total` never enters it: pre-allocating on a peer's number is the bug this
        // whole type exists to avoid.
        let heldBytes = held?.heldBytes ?? 0
        let replacedBytes = held?.chunks[header.index]?.count ?? 0
        let projectedBytes = heldBytes - replacedBytes + header.data.count
        guard projectedBytes <= maxReassembledBytes else {
            assemblies.removeValue(forKey: header.key)
            PopopxMeshLog.route.log(
                "mesh fragment dropped: oversized \(projectedBytes, privacy: .public) of \(self.maxReassembledBytes, privacy: .public) bytes"
            )
            return .rejected(reason: .oversized(projectedBytes: projectedBytes, limit: maxReassembledBytes))
        }

        var assembly: Assembly
        if let existing = held {
            assembly = existing
        } else {
            // Refuse instead of evicting the oldest: forcing a slot fails two assemblies where
            // dropping this one fails one, and the peer spraying fragments is the one choosing
            // which half-finished stream of ours dies.
            guard assemblies.count < maxInFlight else {
                PopopxMeshLog.route.log("mesh fragment dropped: at max in flight")
                return .rejected(reason: .tooManyInFlight)
            }
            assembly = Assembly(
                total: header.total,
                originalType: header.originalType,
                startedAt: now,
                heldBytes: 0,
                chunks: [:]
            )
        }

        // A re-delivered index replaces what it held instead of adding to it: fragments bypass
        // packet dedup upstream and a sync can re-serve an index we already have, so a duplicate
        // near the ceiling must not tip a valid stream over it.
        if let previous = assembly.chunks.updateValue(header.data, forKey: header.index) {
            assembly.heldBytes += header.data.count - previous.count
        } else {
            assembly.heldBytes += header.data.count
        }

        guard assembly.chunks.count == header.total else {
            assemblies[header.key] = assembly
            return .stored(key: header.key)
        }

        var reassembled = Data(capacity: assembly.heldBytes)
        for index in 0..<header.total {
            if let chunk = assembly.chunks[index] { reassembled.append(chunk) }
        }
        assemblies.removeValue(forKey: header.key)
        return .complete(key: header.key, originalType: header.originalType, data: reassembled)
    }

    /// Drops every stream older than `lifetime`. Returns how many went.
    @discardableResult
    public func prune(now: Date) -> Int {
        let expired = assemblies
            .filter { now.timeIntervalSince($0.value.startedAt) > lifetime }
            .map(\.key)
        for key in expired { assemblies.removeValue(forKey: key) }
        return expired.count
    }
}
