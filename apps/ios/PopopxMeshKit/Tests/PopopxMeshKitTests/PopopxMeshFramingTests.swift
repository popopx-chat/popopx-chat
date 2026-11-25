//
//  PopopxMeshFramingTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The fragment layer parses bytes a stranger chose, so the tests are written from the receiving
//  side: what does a hostile header do to our memory, and does an honest round trip survive the
//  wire codec. Byte-level assertions pin the header layout, because changing one of those offsets
//  silently changes which peer can read us.
//

import Foundation
import Testing

import PopopxMeshKit

// MARK: - Fixtures

private let testSender = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
private let testRecipient = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11])
private let testBroadcast = Data(repeating: 0xFF, count: 8)
private let testTimestamp: UInt64 = 1_700_000_000_000
private let testFragmentID = Data([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7])

private func u64(_ data: Data) -> UInt64 {
    data.reduce(into: UInt64(0)) { $0 = ($0 << 8) | UInt64($1) }
}

private func makePacket(
    payload: Data,
    type: PopopxMeshMessageType = .message,
    recipientID: Data? = nil,
    ttl: UInt8 = 7,
    signature: Data? = nil
) -> PopopxMeshPacket {
    PopopxMeshPacket(
        type: type.rawValue,
        ttl: ttl,
        timestamp: testTimestamp,
        senderID: testSender,
        recipientID: recipientID,
        payload: payload,
        signature: signature
    )
}

/// A fragment packet assembled by hand, so a test can describe one that
/// `PopopxMeshFragmenter` would never produce.
private func rawFragment(
    id: Data = testFragmentID,
    index: Int,
    total: Int,
    originalType: UInt8 = PopopxMeshMessageType.message.rawValue,
    data: Data = Data([0x41]),
    senderID: Data = testSender,
    recipientID: Data? = testBroadcast,
    type: UInt8 = PopopxMeshMessageType.fragment.rawValue
) -> PopopxMeshPacket {
    var payload = Data()
    payload.append(id)
    payload.append(UInt8((index >> 8) & 0xFF))
    payload.append(UInt8(index & 0xFF))
    payload.append(UInt8((total >> 8) & 0xFF))
    payload.append(UInt8(total & 0xFF))
    payload.append(originalType)
    payload.append(data)
    return PopopxMeshPacket(
        type: type,
        ttl: 7,
        timestamp: testTimestamp,
        senderID: senderID,
        recipientID: recipientID,
        payload: payload
    )
}

private func key(id: Data = testFragmentID, sender: Data = testSender) -> PopopxMeshFragmentKey {
    PopopxMeshFragmentKey(sender: u64(sender), id: u64(id))
}

private func bytes(_ string: String) -> Data { Data(string.utf8) }

// MARK: - Outbound framing

@Suite("PopopxMeshFragmenter")
struct FragmenterTests {
    @Test("a payload that already fits comes back as one wrapped fragment")
    func wrapsASingleFragment() throws {
        let payload = Data(repeating: 0x5A, count: 100)
        let fragments = try #require(
            PopopxMeshFragmenter.fragment(makePacket(payload: payload), maxPayloadBytes: 469, fragmentID: testFragmentID)
        )

        #expect(fragments.count == 1)
        let fragment = try #require(fragments.first)
        #expect(fragment.type == PopopxMeshMessageType.fragment.rawValue)
        #expect(Array(fragment.payload.prefix(13)) == [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0, 0, 0, 1, 0x02])
        #expect(Array(fragment.payload.dropFirst(13)) == Array(payload))
    }

    @Test("the header is fragmentID(8) ++ index BE(2) ++ total BE(2) ++ originalType(1)")
    func writesTheHeaderByteForByte() throws {
        let payload = Data((0..<230).map { UInt8($0 % 251) })
        // Budget of 63 bytes means 50 bytes of payload per fragment: 5 fragments, the last 30.
        let fragments = try #require(
            PopopxMeshFragmenter.fragment(makePacket(payload: payload), maxPayloadBytes: 63, fragmentID: testFragmentID)
        )
        #expect(fragments.count == 5)

        let first = Array(fragments[0].payload.prefix(13))
        #expect(first == [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0x00, 0x00, 0x00, 0x05, 0x02])
        #expect(Array(fragments[0].payload.dropFirst(13)) == Array(payload.prefix(50)))

        // Index 255 would be the byte where a little-endian writer goes wrong.
        let last = Array(fragments[4].payload.prefix(13))
        #expect(last == [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0x00, 0x04, 0x00, 0x05, 0x02])
        #expect(Array(fragments[4].payload.dropFirst(13)) == Array(payload.suffix(30)))

        #expect(fragments.allSatisfy { $0.payload.count <= 63 })
        #expect(fragments.reduce(0) { $0 + $1.payload.count - 13 } == payload.count)
    }

    @Test("index and total are big-endian past 255")
    func writesWideCounters() throws {
        let payload = Data(repeating: 0x07, count: 60_000)
        // Budget 269 means 256 bytes of payload per fragment, so 235 of them: 235 and 200 both
        // need a second byte, which a one-byte counter or a little-endian writer would get wrong.
        let fragments = try #require(
            PopopxMeshFragmenter.fragment(makePacket(payload: payload), maxPayloadBytes: 269, fragmentID: testFragmentID)
        )
        #expect(fragments.count == 235)
        let counters = Array(fragments[200].payload.subdata(in: 8..<12))
        #expect(counters == [0x00, 0xC8, 0x00, 0xEB])
        let lastChunkBytes = 60_000 - 234 * 256
        #expect(fragments.last?.payload.count == 13 + lastChunkBytes)
    }

    @Test("sender, recipient, timestamp, ttl and signature are carried through untouched")
    func copiesTheEnvelopeFields() throws {
        let signature = Data(repeating: 0x33, count: PopopxMeshPacket.signatureSize)
        let original = makePacket(
            payload: Data(repeating: 0x01, count: 500),
            recipientID: testRecipient,
            ttl: 4,
            signature: signature
        )
        let fragments = try #require(PopopxMeshFragmenter.fragment(original, maxPayloadBytes: 113, fragmentID: testFragmentID))
        #expect(fragments.count == 5)
        for fragment in fragments {
            #expect(fragment.senderID == testSender)
            #expect(fragment.recipientID == testRecipient)
            #expect(fragment.timestamp == testTimestamp)
            #expect(fragment.ttl == 4)
            #expect(fragment.signature == signature)
            #expect(fragment.version == original.version)
            #expect(!fragment.isBroadcast)
        }
    }

    @Test("an impossible split is refused instead of half-done", arguments: [
        ImpossibleCase.zeroBudget, .emptyPayload, .shortID, .alreadyAFragment, .tooManyFragments
    ])
    func refusesImpossibleSplits(_ testCase: ImpossibleCase) {
        let result: [PopopxMeshPacket]?
        switch testCase {
        case .zeroBudget:
            result = PopopxMeshFragmenter.fragment(makePacket(payload: bytes("hi")), maxPayloadBytes: 12, fragmentID: testFragmentID)
        case .emptyPayload:
            result = PopopxMeshFragmenter.fragment(makePacket(payload: Data()), maxPayloadBytes: 469, fragmentID: testFragmentID)
        case .shortID:
            result = PopopxMeshFragmenter.fragment(makePacket(payload: bytes("hi")), maxPayloadBytes: 469, fragmentID: Data(count: 7))
        case .alreadyAFragment:
            result = PopopxMeshFragmenter.fragment(
                rawFragment(index: 0, total: 2, data: bytes("chunk")),
                maxPayloadBytes: 4_096,
                fragmentID: testFragmentID
            )
        case .tooManyFragments:
            result = PopopxMeshFragmenter.fragment(
                makePacket(payload: Data(repeating: 0x02, count: 10_001)),
                maxPayloadBytes: 14,
                fragmentID: testFragmentID
            )
        }
        #expect(result == nil)
    }

    enum ImpossibleCase { case zeroBudget, emptyPayload, shortID, alreadyAFragment, tooManyFragments }
}

// MARK: - Inbound header

@Suite("PopopxMeshFragmentHeader")
struct FragmentHeaderTests {
    @Test("parses a well-formed header and the broadcast flag both ways")
    func parses() throws {
        let broadcast = try #require(PopopxMeshFragmentHeader(packet: rawFragment(index: 1, total: 5, data: bytes("abc"))))
        #expect(broadcast.key == key())
        #expect(broadcast.index == 1)
        #expect(broadcast.total == 5)
        #expect(broadcast.originalType == PopopxMeshMessageType.message.rawValue)
        #expect(broadcast.data == bytes("abc"))
        #expect(broadcast.isBroadcast)

        let directed = try #require(PopopxMeshFragmentHeader(packet: rawFragment(index: 0, total: 1, recipientID: testRecipient)))
        #expect(!directed.isBroadcast)
    }

    @Test("a 13-byte payload is a header with nothing behind it, which is legal")
    func emptyChunk() throws {
        let header = try #require(PopopxMeshFragmentHeader(packet: rawFragment(index: 0, total: 1, data: Data())))
        #expect(header.data.isEmpty)
    }

    @Test("every count a peer chooses is checked against the bytes and against the ceiling", arguments: [
        Hostile.shortPayload, .zeroTotal, .overMaxTotal, .indexEqualsTotal, .indexPastTotal, .shortSenderID, .oversizedSenderID
    ])
    func rejectsHostileHeaders(_ testCase: Hostile) {
        let packet: PopopxMeshPacket
        switch testCase {
        case .shortPayload:
            packet = PopopxMeshPacket(
                type: PopopxMeshMessageType.fragment.rawValue,
                ttl: 7,
                timestamp: testTimestamp,
                senderID: testSender,
                recipientID: testBroadcast,
                payload: Data(count: 12)
            )
        case .zeroTotal:
            packet = rawFragment(index: 0, total: 0)
        case .overMaxTotal:
            packet = rawFragment(index: 0, total: 10_001)
        case .indexEqualsTotal:
            packet = rawFragment(index: 4, total: 4)
        case .indexPastTotal:
            packet = rawFragment(index: 9, total: 4)
        case .shortSenderID:
            packet = rawFragment(index: 0, total: 2, senderID: Data(count: 7))
        case .oversizedSenderID:
            packet = rawFragment(index: 0, total: 2, senderID: Data(count: 9))
        }
        #expect(PopopxMeshFragmentHeader(packet: packet) == nil)
    }

    enum Hostile { case shortPayload, zeroTotal, overMaxTotal, indexEqualsTotal, indexPastTotal, shortSenderID, oversizedSenderID }

    @Test("the accepted ceiling is exactly maxTotal")
    func acceptsMaxTotal() throws {
        #expect(PopopxMeshFragmentHeader.maxTotal == 10_000)
        let header = try #require(PopopxMeshFragmentHeader(packet: rawFragment(index: 9_999, total: 10_000)))
        #expect(header.total == 10_000)
    }
}

// MARK: - Reassembly

@Suite("PopopxMeshFragmentAssembler")
struct FragmentAssemblerTests {
    @Test("one fragment completes immediately and frees its slot")
    func singleFragment() async throws {
        let assembler = PopopxMeshFragmentAssembler()
        let payload = bytes("the whole message fits")
        let fragments = try #require(
            PopopxMeshFragmenter.fragment(makePacket(payload: payload), maxPayloadBytes: 469, fragmentID: testFragmentID)
        )

        #expect(await assembler.append(fragments[0]) == .complete(key: key(), originalType: 0x02, data: payload))
        #expect(await assembler.inFlightCount == 0)
    }

    @Test("fragments complete in any order, and a repeat of an index counts once")
    func outOfOrderAndDuplicates() async throws {
        let assembler = PopopxMeshFragmentAssembler()
        let first = bytes("aaaa")
        let second = bytes("bbbbbb")
        let third = bytes("cc")

        #expect(await assembler.append(rawFragment(index: 2, total: 3, data: third)) == .stored(key: key()))
        #expect(await assembler.inFlightCount == 1)
        #expect(await assembler.append(rawFragment(index: 2, total: 3, data: third)) == .stored(key: key()))
        #expect(await assembler.append(rawFragment(index: 0, total: 3, data: first)) == .stored(key: key()))
        #expect(
            await assembler.append(rawFragment(index: 1, total: 3, data: second))
                == .complete(key: key(), originalType: 0x02, data: first + second + third)
        )
        #expect(await assembler.inFlightCount == 0)
    }

    @Test("a re-served index with different bytes replaces it rather than doubling the stream")
    func reservedIndexReplaces() async throws {
        let assembler = PopopxMeshFragmentAssembler()
        #expect(await assembler.append(rawFragment(index: 0, total: 2, data: bytes("xx"))) == .stored(key: key()))
        #expect(await assembler.append(rawFragment(index: 0, total: 2, data: bytes("yyyy"))) == .stored(key: key()))
        #expect(
            await assembler.append(rawFragment(index: 1, total: 2, data: bytes("z")))
                == .complete(key: key(), originalType: 0x02, data: bytes("yyyyz"))
        )
    }

    @Test("a stream with a hole never completes and keeps exactly one slot")
    func missingFragmentNeverCompletes() async throws {
        let assembler = PopopxMeshFragmentAssembler()
        #expect(await assembler.append(rawFragment(index: 0, total: 3)) == .stored(key: key()))
        #expect(await assembler.append(rawFragment(index: 2, total: 3)) == .stored(key: key()))
        #expect(await assembler.inFlightCount == 1)
    }

    @Test("a non-fragment packet is not this type's business")
    func ignoresOtherTypes() async throws {
        let assembler = PopopxMeshFragmentAssembler()
        #expect(await assembler.append(makePacket(payload: bytes("plain"))) == nil)
        #expect(await assembler.inFlightCount == 0)
    }

    @Test("a fragment whose header does not parse is rejected, not stored")
    func malformedHeader() async throws {
        let assembler = PopopxMeshFragmentAssembler()
        let broken = PopopxMeshPacket(
            type: PopopxMeshMessageType.fragment.rawValue,
            ttl: 7,
            timestamp: testTimestamp,
            senderID: testSender,
            recipientID: testBroadcast,
            payload: Data(count: 12)
        )
        #expect(await assembler.append(broken) == .rejected(reason: .malformedHeader))
        #expect(await assembler.inFlightCount == 0)
    }

    @Test("two fragments that disagree about total drop the stream instead of picking a winner")
    func contradictoryTotalDropsStream() async throws {
        let assembler = PopopxMeshFragmentAssembler()
        #expect(await assembler.append(rawFragment(index: 0, total: 2)) == .stored(key: key()))
        #expect(
            await assembler.append(rawFragment(index: 1, total: 10_000))
                == .rejected(reason: .malformedHeader)
        )
        #expect(await assembler.inFlightCount == 0)
        // The key is free again, so an honest re-flood of the same id can start over.
        #expect(await assembler.append(rawFragment(index: 0, total: 2)) == .stored(key: key()))
    }

    @Test("a contradictory originalType drops the stream too")
    func contradictoryTypeDropsStream() async throws {
        let assembler = PopopxMeshFragmentAssembler()
        #expect(await assembler.append(rawFragment(index: 0, total: 2, originalType: 0x02)) == .stored(key: key()))
        #expect(await assembler.append(rawFragment(index: 1, total: 2, originalType: 0x11)) == .rejected(reason: .malformedHeader))
        #expect(await assembler.inFlightCount == 0)
    }

    @Test("a huge declared total costs nothing until the bytes actually arrive")
    func declaresBigButHoldsSmall() async throws {
        let assembler = PopopxMeshFragmentAssembler(lifetime: 30, maxInFlight: 4, maxReassembledBytes: 256)
        for index in 0..<3 {
            #expect(await assembler.append(rawFragment(index: index, total: 10_000, data: bytes("ab"))) == .stored(key: key()))
        }
        // Proof there is no 10_000-slot buffer: three 2-byte chunks are all we hold, and the
        // stream is nowhere near complete.
        #expect(await assembler.inFlightCount == 1)
    }

    @Test("an oversized fragment kills the assembly it was aimed at, not the table")
    func oversizedAttack() async throws {
        let assembler = PopopxMeshFragmentAssembler(lifetime: 30, maxInFlight: 4, maxReassembledBytes: 256)
        #expect(await assembler.append(rawFragment(index: 0, total: 2, data: Data(repeating: 0x01, count: 100))) == .stored(key: key()))
        #expect(
            await assembler.append(rawFragment(index: 1, total: 2, data: Data(repeating: 0x02, count: 4_000)))
                == .rejected(reason: .oversized(projectedBytes: 4_100, limit: 256))
        )
        #expect(await assembler.inFlightCount == 0)

        // A different key is untouched by the attack, and still reassembles.
        let other = Data([0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7])
        #expect(await assembler.append(rawFragment(id: other, index: 0, total: 1, data: bytes("ok")))
            == .complete(key: key(id: other), originalType: 0x02, data: bytes("ok")))
    }

    @Test("a stream declaring total 10000 and carrying a giant chunk cannot grow the buffer")
    func giantDeclarationWithGiantChunk() async throws {
        let assembler = PopopxMeshFragmentAssembler(lifetime: 30, maxInFlight: 4, maxReassembledBytes: 256)
        let id = Data([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8])
        // Two honest-looking pieces first: the declaration costs nothing on its own.
        #expect(await assembler.append(rawFragment(id: id, index: 0, total: 10_000, data: Data(repeating: 0x01, count: 100)))
            == .stored(key: key(id: id)))
        #expect(await assembler.inFlightCount == 1)
        // Then the same key demands 4 KiB at once. The projection is built from bytes that
        // actually arrived, so the 10000 never enters it and the limit holds.
        #expect(
            await assembler.append(rawFragment(id: id, index: 1, total: 10_000, data: Data(repeating: 0x02, count: 4_000)))
                == .rejected(reason: .oversized(projectedBytes: 4_100, limit: 256))
        )
        #expect(await assembler.inFlightCount == 0)
    }

    @Test("a re-delivered index near the ceiling does not tip a valid stream over it")
    func duplicateDoesNotTipTheCeiling() async throws {
        let assembler = PopopxMeshFragmentAssembler(lifetime: 30, maxInFlight: 2, maxReassembledBytes: 10)
        let chunk = Data(repeating: 0x03, count: 6)
        #expect(await assembler.append(rawFragment(index: 0, total: 2, data: chunk)) == .stored(key: key()))
        #expect(await assembler.append(rawFragment(index: 0, total: 2, data: chunk)) == .stored(key: key()))
        #expect(
            await assembler.append(rawFragment(index: 1, total: 2, data: Data(repeating: 0x04, count: 4)))
                == .complete(key: key(), originalType: 0x02, data: chunk + Data(repeating: 0x04, count: 4))
        )
    }

    @Test("the in-flight cap is refused, not worked around by evicting a live stream")
    func maxInFlight() async throws {
        let assembler = PopopxMeshFragmentAssembler(lifetime: 30, maxInFlight: 2, maxReassembledBytes: 2_048)
        let idA = Data([0x01, 0, 0, 0, 0, 0, 0, 0])
        let idB = Data([0x02, 0, 0, 0, 0, 0, 0, 0])
        let idC = Data([0x03, 0, 0, 0, 0, 0, 0, 0])

        #expect(await assembler.append(rawFragment(id: idA, index: 0, total: 4)) == .stored(key: key(id: idA)))
        #expect(await assembler.append(rawFragment(id: idB, index: 0, total: 4)) == .stored(key: key(id: idB)))
        #expect(await assembler.append(rawFragment(id: idC, index: 0, total: 4)) == .rejected(reason: .tooManyInFlight))
        #expect(await assembler.inFlightCount == 2)

        // An open stream still makes progress while the table is full.
        #expect(await assembler.append(rawFragment(id: idA, index: 1, total: 4)) == .stored(key: key(id: idA)))
    }

    @Test("an aged-out stream is dropped instead of resumed, and the slot is reused")
    func expiry() async throws {
        let assembler = PopopxMeshFragmentAssembler(lifetime: 10, maxInFlight: 4, maxReassembledBytes: 2_048)
        let start = Date()
        #expect(await assembler.append(rawFragment(index: 0, total: 3), now: start) == .stored(key: key()))
        #expect(await assembler.append(rawFragment(index: 1, total: 3), now: start.addingTimeInterval(11)) == .rejected(reason: .expired))
        #expect(await assembler.inFlightCount == 0)
        // Late arrivals after the drop cannot resurrect the old bytes.
        #expect(await assembler.append(rawFragment(index: 2, total: 3), now: start.addingTimeInterval(12)) == .stored(key: key()))
    }

    @Test("prune drops aged streams and reports how many")
    func prune() async throws {
        let assembler = PopopxMeshFragmentAssembler(lifetime: 30, maxInFlight: 8, maxReassembledBytes: 2_048)
        let start = Date()
        for index in 0..<3 {
            let id = Data([UInt8(0xC0 + index), 0, 0, 0, 0, 0, 0, 0])
            #expect(await assembler.append(rawFragment(id: id, index: 0, total: 9), now: start) == .stored(key: key(id: id)))
        }
        #expect(await assembler.inFlightCount == 3)
        #expect(await assembler.prune(now: start.addingTimeInterval(29)) == 0)
        #expect(await assembler.prune(now: start.addingTimeInterval(31)) == 3)
        #expect(await assembler.inFlightCount == 0)
        #expect(await assembler.prune(now: start.addingTimeInterval(60)) == 0)
    }

    @Test("the defaults come from PopopxMeshConfig")
    func defaultsFromConfig() async throws {
        let assembler = PopopxMeshFragmentAssembler()
        #expect(assembler.lifetime == PopopxMeshConfig.default.fragmentLifetime)
        #expect(assembler.maxInFlight == PopopxMeshConfig.default.maxInFlightAssemblies)
        #expect(assembler.maxReassembledBytes == 2_048)
    }

    @Test("a caller holding its own config gets that config's numbers")
    func configInit() async throws {
        var config = PopopxMeshConfig()
        config.fragmentLifetime = 5
        config.maxInFlightAssemblies = 2
        let assembler = PopopxMeshFragmentAssembler(config: config)
        #expect(assembler.lifetime == 5)
        #expect(assembler.maxInFlight == 2)

        let start = Date()
        #expect(await assembler.append(rawFragment(index: 0, total: 4), now: start) == .stored(key: key()))
        #expect(await assembler.append(rawFragment(index: 0, total: 4), now: start.addingTimeInterval(6)) == .rejected(reason: .expired))
    }

    @Test("a ceiling of zero is not a legal configuration")
    func clampsDegenerateLimits() async throws {
        let assembler = PopopxMeshFragmentAssembler(lifetime: 30, maxInFlight: 0, maxReassembledBytes: 0)
        #expect(assembler.maxInFlight == 1)
        #expect(assembler.maxReassembledBytes == 1)
        // Still able to take one one-byte fragment, which is all a limit of 1 means.
        #expect(await assembler.append(rawFragment(index: 0, total: 2, data: Data([0x01]))) == .stored(key: key()))
        #expect(await assembler.append(rawFragment(index: 1, total: 2, data: Data([0x01, 0x02])))
            == .rejected(reason: .oversized(projectedBytes: 3, limit: 1)))
    }

    @Test("reassembles after the real wire codec, padding included")
    func survivesTheWireCodec() async throws {
        let payload = Data((0..<1_000).map { UInt8($0 % 253) })
        let fragments = try #require(
            PopopxMeshFragmenter.fragment(
                makePacket(payload: payload),
                maxPayloadBytes: PopopxMeshConfig.default.fragmentSize,
                fragmentID: testFragmentID
            )
        )
        #expect(fragments.count == 3)

        let assembler = PopopxMeshFragmentAssembler()
        var outcome: PopopxMeshAssemblerOutcome?
        for fragment in fragments.shuffled() {
            let wire = try #require(fragment.encoded(padded: true))
            let decoded = try #require(PopopxMeshPacket.decode(wire))
            outcome = await assembler.append(decoded)
        }
        #expect(outcome == .complete(key: key(), originalType: 0x02, data: payload))
    }
}

// MARK: - Golomb-coded set

@Suite("PopopxGCSFilter")
struct GCSFilterTests {
    @Test("build, serialize, decode and query a set")
    func roundTrip() throws {
        let ids = (0..<20).map { bytes("gcs-in-\($0)") }
        let filter = try #require(PopopxGCSFilter.build(ids: ids, maxBytes: 512, targetFalsePositiveRate: 0.01))
        #expect(filter.includedCount == 20)
        #expect(filter.serialized.count <= 512)

        let decoded = try #require(PopopxGCSFilter(data: filter.serialized))
        #expect(decoded == filter)
        #expect(decoded.p == filter.p)
        #expect(decoded.m == filter.m)
        for id in ids { #expect(decoded.contains(id)) }
        #expect(!decoded.contains(bytes("gcs-absent")))
    }

    @Test("an empty set serializes to a header and answers no to everything")
    func emptySet() throws {
        let filter = try #require(PopopxGCSFilter.build(ids: [], maxBytes: 512, targetFalsePositiveRate: 0.01))
        #expect(filter.elementCount == 0)
        #expect(filter.includedCount == 0)
        #expect(filter.serialized.count == 6)
        #expect(!filter.contains(bytes("anything")))

        let decoded = try #require(PopopxGCSFilter(data: filter.serialized))
        #expect(decoded == filter)
        #expect(!decoded.contains(bytes("anything")))
    }

    @Test("a budget below the header is not a filter")
    func refusesTinyBudget() {
        #expect(PopopxGCSFilter.build(ids: [bytes("a")], maxBytes: 5, targetFalsePositiveRate: 0.01) == nil)
    }

    @Test("garbage from a peer decodes to nothing, never to a crash", arguments: Garbage.all)
    func rejectsGarbage(_ garbage: Garbage) {
        let data: Data
        switch garbage {
        case .empty: data = Data()
        case .shortHeader: data = Data([1, 7, 0, 0])
        case .wrongVersion:
            data = Data([0x02, 7, 0, 0, 0x03, 0x20])
        case .pIsZero:
            data = Data([0x01, 0, 0, 0, 0x03, 0x20])
        case .pTooWide:
            data = Data([0x01, 33, 0, 0, 0x03, 0x20])
        case .emptyModulusWithBits:
            data = Data([0x01, 7, 0, 0, 0, 1, 0xFF])
        case .zeroModulus:
            data = Data([0x01, 7, 0, 0, 0, 0])
        case .oversized:
            data = Data([0x01, 7, 0, 0, 0x03, 0x20]) + Data(repeating: 0xFF, count: PopopxGCSFilter.maxEncodedBytes + 1)
        }
        #expect(PopopxGCSFilter(data: data) == nil)
    }

    enum Garbage: CaseIterable {
        case empty, shortHeader, wrongVersion, pIsZero, pTooWide, emptyModulusWithBits, zeroModulus, oversized
        static var all: [Garbage] { allCases }
    }

    @Test("a truncated bitstream decodes to a subset rather than to garbage")
    func survivesTruncation() throws {
        let ids = (0..<200).map { bytes("gcs-trunc-\($0)") }
        let filter = try #require(PopopxGCSFilter.build(ids: ids, maxBytes: 2_048, targetFalsePositiveRate: 0.01))
        let truncated = Data(filter.serialized.dropLast(4))
        if let partial = PopopxGCSFilter(data: truncated) {
            #expect(partial.elementCount <= filter.elementCount)
        }
    }

    @Test("the mapping is deterministic and inside 1..<M")
    func deterministicMapping() throws {
        let ids = (0..<50).map { bytes("gcs-det-\($0)") }
        let first = try #require(PopopxGCSFilter.build(ids: ids, maxBytes: 1_024, targetFalsePositiveRate: 0.02))
        let second = try #require(PopopxGCSFilter.build(ids: ids, maxBytes: 1_024, targetFalsePositiveRate: 0.02))
        #expect(first.serialized == second.serialized)
        for id in ids {
            let bucket = first.bucket(for: id)
            #expect(bucket >= 1)
            #expect(bucket < UInt64(first.m))
            #expect(bucket == second.bucket(for: id))
        }
    }

    @Test("p is derived as ceil(log2(1/fpr)) and clamped to the buildable range")
    func derivesP() throws {
        #expect(PopopxGCSFilter.deriveP(targetFalsePositiveRate: 0.25) == 2)
        #expect(PopopxGCSFilter.deriveP(targetFalsePositiveRate: 0.01) == 7)
        #expect(PopopxGCSFilter.deriveP(targetFalsePositiveRate: 0.001) == 10)
        // Clamped at both ends: a rate of 0 means "as precise as the format goes", and a rate we
        // cannot even name falls back to the coarsest one rather than to a bogus width.
        #expect(PopopxGCSFilter.deriveP(targetFalsePositiveRate: 0.9) == 2)
        #expect(PopopxGCSFilter.deriveP(targetFalsePositiveRate: 0) == 20)
        #expect(PopopxGCSFilter.deriveP(targetFalsePositiveRate: -1) == 20)
        #expect(PopopxGCSFilter.deriveP(targetFalsePositiveRate: .nan) == 2)
        #expect(PopopxGCSFilter.deriveP(targetFalsePositiveRate: .infinity) == 2)
        let filter = try #require(PopopxGCSFilter.build(ids: [bytes("x")], maxBytes: 128, targetFalsePositiveRate: 1e-12))
        #expect(filter.p == 20)
    }

    @Test("1000 ids against 10000 unseen ones measure the false-positive rate we asked for")
    func measuredFalsePositiveRate() throws {
        let built = (0..<1_000).map { bytes("gcs-measured-in-\($0)") }
        let filter = try #require(PopopxGCSFilter.build(ids: built, maxBytes: 4_096, targetFalsePositiveRate: 0.01))
        // fpr ~= 1/2^p, and M ~= n * 2^p.
        #expect(filter.p == 7)
        #expect(filter.m == 128_000)
        #expect(filter.elementCount > 900)
        #expect(filter.serialized.count <= 4_096)

        // No false negatives, ever: a set element must answer yes.
        for id in built { #expect(filter.contains(id)) }
        let decoded = try #require(PopopxGCSFilter(data: filter.serialized))
        for id in built { #expect(decoded.contains(id)) }

        let probes = (0..<10_000).map { bytes("gcs-measured-out-\($0)") }
        #expect(probes.count == 10_000)
        let falsePositives = probes.reduce(0) { $0 + (decoded.contains($1) ? 1 : 0) }
        // Expected around 78 at 1/128. The floor catches a `contains` that answers yes to
        // everything, the ceiling a filter that is quietly four times sloppier than asked.
        #expect(falsePositives > 0)
        #expect(falsePositives < 400)
    }

    @Test("hostile build inputs are cut before they cost anything")
    func capsHostileInputs() throws {
        let many = (0..<30_000).map { bytes("gcs-many-\($0)") }
        let filter = try #require(PopopxGCSFilter.build(ids: many, maxBytes: 1_000_000, targetFalsePositiveRate: 0.01))
        // maxBytes is clamped to the engine's own ceiling, not to the caller's number.
        #expect(filter.serialized.count <= PopopxGCSFilter.maxEncodedBytes + 6)
        #expect(filter.includedCount <= PopopxGCSFilter.maxElements)
        #expect(filter.elementCount <= PopopxGCSFilter.maxElements)

        // Elements that are not ids — empty or absurdly long — are skipped rather than hashed.
        let junk = try #require(PopopxGCSFilter.build(
            ids: [Data(), Data(repeating: 0x09, count: PopopxGCSFilter.maxIDBytes + 1)],
            maxBytes: 512,
            targetFalsePositiveRate: 0.01
        ))
        #expect(junk.elementCount == 0)
        #expect(junk.includedCount == 0)
        #expect(!junk.contains(Data()))
    }
}

// MARK: - Deduplication

@Suite("PopopxMeshDeduplicator")
struct DeduplicatorTests {
    @Test("the first copy of a packet is relayed, every copy after it is not")
    func notesOnce() async throws {
        let dedup = PopopxMeshDeduplicator()
        let id = Data(repeating: 0x4F, count: 16)

        #expect(await dedup.contains(packetID: id) == false)
        #expect(await dedup.note(packetID: id) == true)
        #expect(await dedup.contains(packetID: id) == true)
        #expect(await dedup.note(packetID: id) == false)
        #expect(await dedup.stats == PopopxMeshDedupStats(recentCount: 1, messageCount: 0, hits: 1))
    }

    @Test("different packets are different keys")
    func distinctIDs() async throws {
        let dedup = PopopxMeshDeduplicator()
        #expect(await dedup.note(packetID: Data(repeating: 0x01, count: 16)) == true)
        #expect(await dedup.note(packetID: Data(repeating: 0x02, count: 16)) == true)
        #expect(await dedup.stats.recentCount == 2)
        #expect(await dedup.stats.hits == 0)
    }

    @Test("message ids and packet ids live in separate memories")
    func separateStores() async throws {
        let dedup = PopopxMeshDeduplicator()
        let shared = bytes("same-bytes")

        #expect(await dedup.noteMessage(id: "same-bytes") == true)
        #expect(await dedup.noteMessage(id: "same-bytes") == false)
        #expect(await dedup.note(packetID: shared) == true)
        #expect(await dedup.note(packetID: shared) == false)
        #expect(await dedup.stats == PopopxMeshDedupStats(recentCount: 1, messageCount: 1, hits: 2))
        #expect(await dedup.seenMessageIDs() == [shared])
    }

    @Test("seenMessageIDs is newest first, which is what the GCS trim needs")
    func messageOrder() async throws {
        let dedup = PopopxMeshDeduplicator()
        for id in ["m1", "m2", "m3"] { #expect(await dedup.noteMessage(id: id) == true) }
        #expect(await dedup.seenMessageIDs() == [bytes("m3"), bytes("m2"), bytes("m1")])
    }

    @Test("each window ages out on its own clock")
    func prunesByAge() async throws {
        var config = PopopxMeshConfig()
        config.recentPacketWindow = 1
        config.messageDedupMaxAge = 600
        let dedup = PopopxMeshDeduplicator(config: config)

        #expect(await dedup.note(packetID: Data(repeating: 0x0A, count: 16)) == true)
        #expect(await dedup.noteMessage(id: "old-message") == true)
        let after = Date()

        await dedup.prune(now: after.addingTimeInterval(2))
        #expect(await dedup.stats.recentCount == 0)
        #expect(await dedup.stats.messageCount == 1)
        #expect(await dedup.contains(packetID: Data(repeating: 0x0A, count: 16)) == false)
        // Relaying it again is allowed once the flood window closed.
        #expect(await dedup.note(packetID: Data(repeating: 0x0A, count: 16)) == true)

        await dedup.prune(now: after.addingTimeInterval(601))
        #expect(await dedup.stats.messageCount == 0)
        #expect(await dedup.stats.recentCount == 0)
        #expect(await dedup.seenMessageIDs().isEmpty)
    }

    @Test("a full window evicts the oldest entries, age notwithstanding")
    func evictsByCount() async throws {
        var config = PopopxMeshConfig()
        config.recentPacketWindow = 3_600
        config.recentPacketMaxCount = 4
        config.messageDedupMaxAge = 3_600
        config.messageDedupMaxCount = 3
        let dedup = PopopxMeshDeduplicator(config: config)

        for index in 0..<6 {
            #expect(await dedup.note(packetID: Data("p\(index)".utf8)) == true)
        }
        let stats = await dedup.stats
        #expect(stats.recentCount == 4)
        #expect(await dedup.contains(packetID: bytes("p0")) == false)
        #expect(await dedup.contains(packetID: bytes("p1")) == false)
        #expect(await dedup.contains(packetID: bytes("p2")) == true)
        #expect(await dedup.contains(packetID: bytes("p5")) == true)

        for index in 0..<5 {
            #expect(await dedup.noteMessage(id: "m\(index)") == true)
        }
        #expect(await dedup.stats.messageCount == 3)
        #expect(await dedup.seenMessageIDs() == [bytes("m4"), bytes("m3"), bytes("m2")])
        // The evicted message ids are forgotten, so they would be delivered a second time; that
        // is the trade the count ceiling makes against memory, and it is why it is 1000 by default.
        #expect(await dedup.noteMessage(id: "m0") == true)
    }

    @Test("a repeat of an evicted id is a fresh decision, not a hit")
    func evictedThenReplayed() async throws {
        var config = PopopxMeshConfig()
        config.recentPacketMaxCount = 1
        let dedup = PopopxMeshDeduplicator(config: config)
        #expect(await dedup.note(packetID: bytes("first")) == true)
        #expect(await dedup.note(packetID: bytes("second")) == true)
        #expect(await dedup.note(packetID: bytes("first")) == true)
        #expect(await dedup.stats.hits == 0)
        #expect(await dedup.stats.recentCount == 1)
    }

    @Test("an id too long to be ours is forwarded rather than remembered")
    func refusesOversizedKeys() async throws {
        let dedup = PopopxMeshDeduplicator()
        let huge = Data(repeating: 0x01, count: PopopxMeshDeduplicator.maxKeyBytes + 1)
        #expect(await dedup.note(packetID: huge) == true)
        #expect(await dedup.note(packetID: huge) == true)
        #expect(await dedup.note(packetID: Data()) == true)
        #expect(await dedup.noteMessage(id: String(repeating: "x", count: 512)) == true)
        #expect(await dedup.noteMessage(id: "") == true)
        let stats = await dedup.stats
        #expect(stats.recentCount == 0)
        #expect(stats.messageCount == 0)
    }

    @Test("the gossip sketch covers the message ids we hold")
    func gossipFilter() async throws {
        let dedup = PopopxMeshDeduplicator()
        #expect(await dedup.gossipFilter(maxBytes: 256, targetFalsePositiveRate: 0.01)?.elementCount == 0)

        for index in 0..<40 { #expect(await dedup.noteMessage(id: "msg-\(index)") == true) }
        let filter = try #require(await dedup.gossipFilter(maxBytes: 256, targetFalsePositiveRate: 0.01))
        #expect(filter.serialized.count <= 256)
        for index in 0..<40 { #expect(filter.contains(bytes("msg-\(index)"))) }

        // A peer that decodes the sketch maps its own ids onto the same buckets.
        let decoded = try #require(PopopxGCSFilter(data: filter.serialized))
        for index in 0..<40 { #expect(decoded.contains(bytes("msg-\(index)"))) }
        let strangers = (100..<200).map { bytes("msg-\($0)") }
        #expect(strangers.filter { decoded.contains($0) }.count < 10)
    }

    @Test("the default config bounds match PopopxMeshConfig")
    func defaultBounds() async throws {
        let dedup = PopopxMeshDeduplicator()
        let config = PopopxMeshConfig.default
        #expect(config.recentPacketWindow == 30)
        #expect(config.recentPacketMaxCount == 100)
        #expect(config.messageDedupMaxAge == 300)
        #expect(config.messageDedupMaxCount == 1_000)

        for index in 0..<250 {
            #expect(await dedup.note(packetID: Data("dflt-\(index)".utf8)) == true)
            #expect(await dedup.noteMessage(id: "dflt-\(index)") == true)
        }
        let stats = await dedup.stats
        #expect(stats.recentCount == config.recentPacketMaxCount)
        #expect(stats.messageCount == 250)
    }
}
