//
//  PopopxGCSFilter.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  A Golomb-coded set: the packed, one-way membership list Bitchat's sync protocol uses to
//  ask "which of these do you already have?" without either side sending its list in the clear.
//  It is a set difference sketch, not a Bloom filter — GCS is what the deployed peers speak, and
//  it costs about log2(1/fpr) bits per element where a Bloom filter needs 1.44 times that.
//
//  Encoding, byte for byte:
//    serialized = version(1) ++ p(1) ++ M(4, big endian) ++ Golomb-Rice bitstream
//    bitstream  = for each element, in ascending mapped order, the delta from the previous one
//                 (>= 1) written as q = (delta-1) >> p ones then a zero, followed by the p-bit
//                 remainder. MSB first inside each byte.
//
//  Mapping an id: h64 = first 8 bytes of SHA256(id), big endian, cut to 63 bits, taken mod M,
//  with 0 remapped to 1 so every delta is positive. Determinism is the contract — two peers must
//  land an id on the same bucket or the sketch answers a different question than it was asked.
//

import CryptoKit
import Foundation

public struct PopopxGCSFilter: Sendable {
    // MARK: Limits

    /// The only serialization this version reads.
    public static let version: UInt8 = 1
    /// `version ++ p ++ M`.
    static let headerBytes = 6
    /// p is the remainder width in bits, so fpr ~= 1/2^p. Above 32 the remainder is wider than any
    /// filter that could plausibly fit a packet and the shifts below start losing bits.
    public static let maxP = 32
    /// Ceiling on the bitstream, in both directions: `build` never offers more, and `init?(data:)`
    /// refuses more rather than decoding a peer's request for our memory.
    public static let maxEncodedBytes = 4096
    /// Ceiling on elements, so a bitstream crafted to keep yielding small deltas cannot make us
    /// append forever.
    public static let maxElements = 10_000
    /// Longer than this and it is not an id this engine minted; hashing it would just be work.
    public static let maxIDBytes = 128

    // MARK: State

    /// Golomb-Rice remainder width.
    public let p: Int
    /// Hash-space size: every id maps into 1..<M.
    public let m: UInt32
    /// The Golomb-Rice bitstream, without our header.
    let bitstream: Data
    /// Decoded, ascending, unique. Cached because `contains` runs per inbound id per peer.
    private let values: [UInt64]
    /// How many leading entries of `build`'s `ids` the filter actually encodes. Trimming to fit
    /// the byte budget only ever drops from the tail, so a caller that passes ids newest-first
    /// can treat this as an exact cursor.
    public let includedCount: Int

    public var elementCount: Int { values.count }

    private init(p: Int, m: UInt32, bitstream: Data, values: [UInt64], includedCount: Int) {
        self.p = p
        self.m = m
        self.bitstream = bitstream
        self.values = values
        self.includedCount = includedCount
    }

    // MARK: Decoding a peer's filter

    /// nil for anything this builder would not have produced: too short, too long, a version, a
    /// `p` or an `M` out of range, or a bitstream that decodes to more elements than exist. Never
    /// a crash — every byte below is chosen by the peer.
    public init?(data: Data) {
        guard data.count >= Self.headerBytes, data.count <= Self.maxEncodedBytes + Self.headerBytes else {
            return nil
        }
        let base = data.startIndex
        guard data[base] == Self.version else { return nil }
        let p = Int(data[base + 1])
        guard p >= 1, p <= Self.maxP else { return nil }
        var m: UInt32 = 0
        for offset in 0..<4 { m = (m << 8) | UInt32(data[base + 2 + offset]) }
        let bitstream = data.subdata(in: (base + Self.headerBytes)..<data.endIndex)
        // M == 1 is how an empty set is written and M == 0 is not a modulus at all; bits behind
        // either would be a set that cannot exist.
        guard m == 1 ? bitstream.isEmpty : m > 1 else { return nil }
        guard let values = Self.decode(p: p, m: m, bitstream: bitstream) else { return nil }
        self.init(p: p, m: m, bitstream: bitstream, values: values, includedCount: values.count)
    }

    // MARK: Building

    /// Encodes `ids` as small as `maxBytes` and no smaller. Returns nil when `maxBytes` cannot
    /// even hold the header.
    ///
    /// Both inputs are treated as unbounded: `ids` is cut to `maxElements` from the front (so a
    /// caller passing newest-first keeps the ones it cares about) and ids longer than `maxIDBytes`
    /// are skipped, so neither a huge list nor a huge element turns into a huge hash loop.
    /// Elements that do not fit the byte budget are trimmed from the tail, a tenth at a time,
    /// until the encoding stops overflowing it.
    public static func build(
        ids: [Data],
        maxBytes: Int,
        targetFalsePositiveRate: Double
    ) -> PopopxGCSFilter? {
        guard maxBytes >= headerBytes else { return nil }
        let budget = min(maxBytes - headerBytes, maxEncodedBytes)
        let p = deriveP(targetFalsePositiveRate: targetFalsePositiveRate)

        let candidates = ids.prefix(maxElements).filter { !$0.isEmpty && $0.count <= maxIDBytes }
        let estimated = estimateMaxElements(sizeBytes: budget, p: p)
        let initialCount = min(candidates.count, estimated)
        guard initialCount > 0 else { return empty(p: p) }

        // M is pinned to the first candidate count and stays put while the tail is trimmed, so a
        // trimmed filter still means the same thing per element as an untrimmed one.
        let range = hashRange(count: initialCount, p: p)
        let modulo = UInt64(range)

        func encodeFirst(_ count: Int) -> (values: [UInt64], encoded: Data) {
            let mapped = normalize(
                candidates.prefix(count).map { mapHash(h64($0), modulo: modulo) }.sorted(),
                modulo: modulo
            )
            return (mapped, mapped.isEmpty ? Data() : encode(values: mapped, p: p))
        }

        var count = initialCount
        var attempt = encodeFirst(count)
        while attempt.encoded.count > budget, count > 1 {
            count = max(1, count * 9 / 10)
            attempt = encodeFirst(count)
        }
        // One element that still does not fit is not a filter, it is a caller who set maxBytes
        // below what their own `p` costs. Say so by returning the empty set rather than a lie.
        guard attempt.encoded.count <= budget else { return empty(p: p) }

        return Self(
            p: p,
            m: range,
            bitstream: attempt.encoded,
            values: attempt.values,
            includedCount: count
        )
    }

    /// The set with nothing in it: everything answers "no", which makes a peer send it again.
    private static func empty(p: Int) -> PopopxGCSFilter {
        Self(p: p, m: 1, bitstream: Data(), values: [], includedCount: 0)
    }

    // MARK: Queries

    /// true when the id may be in the set. False is exact: a set element is never answered "no".
    public func contains(_ id: Data) -> Bool {
        guard m > 1, !values.isEmpty else { return false }
        return Self.contains(values: values, candidate: bucket(for: id))
    }

    /// The bucket `id` occupies in 1..<M. Public because a peer comparing two filters must map ids
    /// the same way both sides did, and because it is the one function here worth pinning in a test.
    public func bucket(for id: Data) -> UInt64 {
        guard m > 1 else { return 0 }
        return Self.mapHash(Self.h64(id), modulo: UInt64(m))
    }

    /// Header plus bitstream: what goes on the wire, and what `init?(data:)` takes back.
    public var serialized: Data {
        var out = Data(capacity: Self.headerBytes + bitstream.count)
        out.append(Self.version)
        out.append(UInt8(clamping: p))
        out.append(UInt8((m >> 24) & 0xFF))
        out.append(UInt8((m >> 16) & 0xFF))
        out.append(UInt8((m >> 8) & 0xFF))
        out.append(UInt8(m & 0xFF))
        out.append(bitstream)
        return out
    }

    // MARK: Parameters

    /// fpr ~= 1/2^p, so p = ceil(log2(1/fpr)). Clamped at both ends: below 0.25 buys nothing an
    /// honest caller wants, and asking for better than 1e-6 costs a tenth of a bit per element and
    /// cannot be met by a set this small anyway. A request of 0 therefore means "as precise as this
    /// format goes", which is what a caller who writes 0 means.
    public static func deriveP(targetFalsePositiveRate: Double) -> Int {
        // NaN or infinity is not a rate at all: take the coarsest one a filter can be built at
        // rather than pretending to buy precision the bitstream cannot hold.
        guard targetFalsePositiveRate.isFinite else { return 2 }
        let rate = min(0.25, max(0.000_001, targetFalsePositiveRate))
        return min(maxP, max(1, Int(ceil(log2(1.0 / rate)))))
    }

    /// A Golomb-Rice element costs about p + 2 bits: p for the remainder, and a unary quotient
    /// averaging one or two bits at the densities this filter is built at.
    static func estimateMaxElements(sizeBytes: Int, p: Int) -> Int {
        let bits = max(8, sizeBytes * 8)
        let per = max(3, p + 2)
        return max(1, bits / per)
    }

    /// M = n * 2^p, saturating at UInt32. The classic Golomb-Coded-Set modulus: it puts about one
    /// collision per 2^p elements, which is where the ~1/2^p false-positive rate comes from.
    private static func hashRange(count: Int, p: Int) -> UInt32 {
        guard count > 0 else { return 1 }
        if p >= 64 { return UInt32.max }
        let (product, overflow) = UInt64(count).multipliedReportingOverflow(by: UInt64(1) << UInt64(p))
        if overflow { return UInt32.max }
        if product == 0 { return 1 }
        return product > UInt64(UInt32.max) ? UInt32.max : UInt32(product)
    }

    // MARK: Hashing

    /// First 8 bytes of SHA256, big endian, top bit cleared so every subsequent shift and
    /// addition stays inside 63 bits and cannot wrap into a negative-looking value.
    private static func h64(_ id: Data) -> UInt64 {
        let digest = Data(SHA256.hash(data: id))
        var value: UInt64 = 0
        for byte in digest.prefix(8) { value = (value << 8) | UInt64(byte) }
        return value & 0x7FFF_FFFF_FFFF_FFFF
    }

    private static func mapHash(_ hash: UInt64, modulo: UInt64) -> UInt64 {
        guard modulo > 1 else { return 0 }
        let value = hash % modulo
        return value == 0 ? 1 : value
    }

    /// Keeps the sequence strictly increasing, which is what lets the deltas stay positive: equal
    /// buckets are the same element, and a bucket at M is one past the end of the space.
    private static func normalize(_ values: [UInt64], modulo: UInt64) -> [UInt64] {
        guard modulo > 1, !values.isEmpty else { return [] }
        var out: [UInt64] = []
        out.reserveCapacity(values.count)
        var last: UInt64 = 0
        for value in values {
            let capped = min(value, modulo - 1)
            if capped > last {
                out.append(capped)
                last = capped
            }
        }
        return out
    }

    // MARK: Bitstream

    private static func encode(values: [UInt64], p: Int) -> Data {
        var writer = BitWriter()
        var previous: UInt64 = 0
        let mask: UInt64 = (1 << UInt64(p)) - 1
        for value in values {
            let delta = value &- previous
            previous = value
            let quotient = (delta &- 1) >> UInt64(p)
            let remainder = (delta &- 1) & mask
            writer.writeOnes(count: Int(quotient))
            writer.writeBit(0)
            writer.writeBits(value: remainder, count: p)
        }
        return writer.toData()
    }

    /// nil when the stream decodes to more elements than `maxElements`: a crafted sequence of
    /// small deltas is a request for memory, not a set.
    private static func decode(p: Int, m: UInt32, bitstream: Data) -> [UInt64]? {
        guard m > 1 else { return [] }
        var reader = BitReader(bitstream)
        var values: [UInt64] = []
        var accumulator: UInt64 = 0
        while true {
            guard let quotient = reader.readUnary() else { break }
            guard let remainder = reader.readBits(count: p) else { break }
            accumulator = accumulator &+ (UInt64(quotient) << UInt64(p)) + UInt64(remainder) + 1
            if accumulator >= UInt64(m) { break }
            values.append(accumulator)
            if values.count > maxElements { return nil }
        }
        return values
    }

    private static func contains(values: [UInt64], candidate: UInt64) -> Bool {
        var low = 0
        var high = values.count - 1
        while low <= high {
            let middle = (low + high) >> 1
            let value = values[middle]
            if value == candidate { return true }
            if value < candidate { low = middle + 1 } else { high = middle - 1 }
        }
        return false
    }

    /// MSB-first, as the format is specified. Slice-free byte array, so no index-space surprises
    /// between a Data we built and a Data a peer sent us.
    private struct BitWriter {
        private var bytes: [UInt8] = []
        private var current: UInt8 = 0
        private var filled = 0

        mutating func writeBit(_ bit: Int) {
            current = (current << 1) | UInt8(bit & 1)
            filled += 1
            if filled == 8 {
                bytes.append(current)
                current = 0
                filled = 0
            }
        }

        mutating func writeOnes(count: Int) {
            for _ in 0..<max(0, count) { writeBit(1) }
        }

        mutating func writeBits(value: UInt64, count: Int) {
            guard count > 0 else { return }
            for shift in stride(from: count - 1, through: 0, by: -1) {
                writeBit(Int((value >> UInt64(shift)) & 1))
            }
        }

        func toData() -> Data {
            var bytes = self.bytes
            if filled > 0 { bytes.append(current << UInt8(8 - filled)) }
            return Data(bytes)
        }
    }

    private struct BitReader {
        private let bytes: [UInt8]
        private var index = 0
        private var current: UInt8 = 0
        private var left = 0

        init(_ data: Data) {
            self.bytes = [UInt8](data)
            if !bytes.isEmpty {
                current = bytes[0]
                left = 8
            }
        }

        mutating func readBit() -> Int? {
            guard index < bytes.count else { return nil }
            let bit = Int((current >> 7) & 1)
            current = current << 1
            left -= 1
            if left == 0 {
                index += 1
                if index < bytes.count {
                    current = bytes[index]
                    left = 8
                }
            }
            return bit
        }

        /// Unary quotient: the number of ones before the terminating zero, or nil at end of stream.
        mutating func readUnary() -> Int? {
            var count = 0
            while true {
                guard let bit = readBit() else { return nil }
                if bit == 1 { count += 1 } else { return count }
            }
        }

        mutating func readBits(count: Int) -> UInt64? {
            var value: UInt64 = 0
            for _ in 0..<count {
                guard let bit = readBit() else { return nil }
                value = (value << 1) | UInt64(bit)
            }
            return value
        }
    }
}

// MARK: - Equatable

/// Two filters are the same when they say the same thing on the wire. `values` is derived from
/// these three, so comparing it too would only make equality O(n) — and a peer's truncated stream
/// that happens to decode to the same set is not the same message we would have sent.
extension PopopxGCSFilter: Equatable {
    public static func == (lhs: PopopxGCSFilter, rhs: PopopxGCSFilter) -> Bool {
        lhs.p == rhs.p && lhs.m == rhs.m && lhs.bitstream == rhs.bitstream
    }
}
