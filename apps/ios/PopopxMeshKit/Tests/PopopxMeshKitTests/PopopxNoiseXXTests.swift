//
//  PopopxNoiseXXTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The handshake, the byte lengths it puts on the wire, and the counters around a finished session.
//  The length and known-answer tests are the reason this file exists: they fail when a padding, a
//  tag or a hashing order drifts, which is the kind of change that leaves both ends of a fresh
//  session working with each other and silently broken against every peer already in the field.
//

import CryptoKit
import Foundation
import Testing

@testable import PopopxMeshKit

// MARK: - Helpers

private func identity(seed: UInt8) throws -> PopopxMeshIdentity {
    try #require(
        PopopxMeshIdentity(privateSeed: Data(repeating: seed, count: 32)),
        "a 32-byte seed must always make an identity"
    )
}

/// Runs one XX handshake with the payloads the mesh would actually send and hands back both sides'
/// results. `complete` is checked as each message lands, not only at the end, so a pattern that
/// finishes early or late is caught here rather than in the transport.
private func fullExchange(
    alice: PopopxMeshIdentity,
    bob: PopopxMeshIdentity,
    initiatorEphemeral: Data? = nil,
    responderEphemeral: Data? = nil,
    payload1: Data = Data(),
    payload2: Data = Data(),
    payload3: Data = Data()
) throws -> (initiator: PopopxNoiseHandshakeResult, responder: PopopxNoiseHandshakeResult) {
    var aliceHandshake = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    var bobHandshake = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)
    aliceHandshake.ephemeralSeedOverride = initiatorEphemeral
    bobHandshake.ephemeralSeedOverride = responderEphemeral

    let message1 = try aliceHandshake.nextMessage(payload: payload1)
    #expect(aliceHandshake.isComplete == false)
    let (read1, after1) = try bobHandshake.consume(message1)
    #expect(read1 == payload1)
    #expect(after1 == false)

    let message2 = try bobHandshake.nextMessage(payload: payload2)
    let (read2, after2) = try aliceHandshake.consume(message2)
    #expect(read2 == payload2)
    #expect(after2 == false)
    // XX ends with a message the initiator speaks, so reading message 2 does not finish it.
    #expect(aliceHandshake.isComplete == false)

    let message3 = try aliceHandshake.nextMessage(payload: payload3)
    let (read3, after3) = try bobHandshake.consume(message3)
    #expect(read3 == payload3)
    #expect(after3 == true)
    #expect(bobHandshake.isComplete)

    return (try aliceHandshake.finalize(), try bobHandshake.finalize())
}

/// The initiator while it waits for message 2, plus that message. Handed back as a pair so a test
/// can damage the message and still give it to an instance that never read the good one.
private func pendingMessage2(
    alice: PopopxMeshIdentity,
    bob: PopopxMeshIdentity,
    payload: Data = Data("hi".utf8)
) throws -> (awaiting: PopopxNoiseXXHandshake, message: Data) {
    var aliceHandshake = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    var bobHandshake = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)
    _ = try bobHandshake.consume(try aliceHandshake.nextMessage(payload: Data()))
    return (aliceHandshake, try bobHandshake.nextMessage(payload: payload))
}

/// The responder while it waits for message 3, plus message 3 itself.
private func pendingMessage3(
    alice: PopopxMeshIdentity,
    bob: PopopxMeshIdentity
) throws -> (awaiting: PopopxNoiseXXHandshake, message: Data) {
    var aliceHandshake = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    var bobHandshake = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)
    _ = try bobHandshake.consume(try aliceHandshake.nextMessage(payload: Data()))
    _ = try aliceHandshake.consume(try bobHandshake.nextMessage(payload: Data()))
    return (bobHandshake, try aliceHandshake.nextMessage(payload: Data()))
}

/// Seals a frame straight with CryptoKit, past the counter `PopopxNoiseCipherState` will produce.
/// Only a test can put such a counter on the wire, because the send side refuses it; the receive
/// side still has to name it, so the bytes are built by hand in the same format.
private func sealedBeyondTheCeiling(key: Data, counter: UInt64) throws -> Data {
    let nonce = PopopxNoiseCipherState.nonceBytes(counter: counter)
    let box = try ChaChaPoly.seal(
        Data(),
        using: SymmetricKey(data: key),
        nonce: ChaChaPoly.Nonce(data: nonce),
        authenticating: Data()
    )
    var frame = nonce
    frame.append(box.ciphertext)
    frame.append(box.tag)
    return frame
}

/// A session pair that has finished handshaking, built the way the transport would build one.
private func sessions(
    _ alice: PopopxMeshIdentity,
    _ bob: PopopxMeshIdentity
) throws -> (alice: PopopxNoiseSession, bob: PopopxNoiseSession) {
    let pair = try fullExchange(alice: alice, bob: bob)
    return (try session(for: pair.initiator), try session(for: pair.responder))
}

private func session(
    for result: PopopxNoiseHandshakeResult
) throws -> PopopxNoiseSession {
    try #require(
        PopopxNoiseSession(
            peerPublicKey: result.peerStaticPublicKey,
            keys: result.transportKeys
        ),
        "the keys and peer key a handshake reports must always build a session"
    )
}

/// Seals `plaintext` at `counter` with a given key, so a test can put an arbitrary counter on the
/// wire instead of sending two thousand real messages to reach one.
private func frame(
    from keys: PopopxNoiseTransportKeys,
    plaintext: Data,
    counter: UInt64
) throws -> Data {
    try PopopxNoiseCipherState(key: keys.sendKey).encrypt(plaintext, nonce: counter).frame
}

// MARK: - Handshake

@Test("XX handshake authenticates both static keys and crosses the transport keys")
func handshakeEstablishesSession() throws {
    let alice = try identity(seed: 0x11)
    let bob = try identity(seed: 0x22)
    let pair = try fullExchange(alice: alice, bob: bob)

    #expect(pair.initiator.peerStaticPublicKey == bob.publicKey)
    #expect(pair.responder.peerStaticPublicKey == alice.publicKey)
    #expect(pair.initiator.peerStaticPublicKey.count == 32)

    // The handshake hash is what both sides can quote to each other as a short authentication
    // string, so the two copies have to be byte-identical.
    #expect(pair.initiator.handshakeHash == pair.responder.handshakeHash)
    #expect(pair.initiator.handshakeHash.count == 32)
    #expect(pair.initiator.handshakeHash != Data(repeating: 0, count: 32))

    // Split order: k1 encrypts initiator -> responder, k2 the other way round.
    #expect(pair.initiator.transportKeys.sendKey == pair.responder.transportKeys.receiveKey)
    #expect(pair.initiator.transportKeys.receiveKey == pair.responder.transportKeys.sendKey)
    #expect(pair.initiator.transportKeys.sendKey != pair.initiator.transportKeys.receiveKey)
    #expect(pair.initiator != pair.responder)
}

@Test("Two different peers finish with different keys and different hashes")
func handshakeDistinguishesPeers() throws {
    let alice = try identity(seed: 0x23)
    let first = try fullExchange(alice: alice, bob: try identity(seed: 0x24))
    let second = try fullExchange(alice: alice, bob: try identity(seed: 0x25))

    #expect(first.initiator.handshakeHash != second.initiator.handshakeHash)
    #expect(first.initiator.transportKeys.sendKey != second.initiator.transportKeys.sendKey)
    #expect(first.initiator.peerStaticPublicKey != second.initiator.peerStaticPublicKey)
}

@Test("Handshake payloads travel with their message and come back out of it")
func handshakePayloadsRoundTrip() throws {
    let note = Data("pair me please".utf8)
    let pair = try fullExchange(
        alice: try identity(seed: 0x26),
        bob: try identity(seed: 0x27),
        payload1: note,
        payload2: Data([0x00]),
        payload3: note
    )
    // A finished pair still talks, so the payloads did not desynchronise the symmetric state.
    var (alice, bob) = try (session(for: pair.initiator), session(for: pair.responder))
    #expect(try bob.decrypt(try alice.encrypt(note)) == note)
    #expect(try alice.decrypt(try bob.encrypt(note)) == note)
}

// MARK: - Transport

@Test("Transport messages from one side open on the other, in both directions")
func transportRoundTrip() throws {
    var (sender, receiver) = try sessions(try identity(seed: 0x31), try identity(seed: 0x32))

    for size in [0, 1, 2, 255, 469, 512, 1024] {
        let plaintext = Data((0..<size).map { UInt8($0 % 251) })
        let wire = try sender.encrypt(plaintext)
        #expect(wire.count == plaintext.count + PopopxNoiseCipherState.frameOverhead)
        #expect(try receiver.decrypt(wire) == plaintext)

        let reply = try receiver.encrypt(plaintext)
        #expect(try sender.decrypt(reply) == plaintext)
    }
    #expect(sender.messagesSent == 7)
    #expect(receiver.messagesSent == 7)
    // Both sides read seven frames, so each expects the peer's next one at counter 7.
    #expect(sender.peerCounter == 7)
    #expect(receiver.peerCounter == 7)
}

@Test("A ciphertext frame is never the plaintext it carries")
func transportHidesPlaintext() throws {
    var (sender, receiver) = try sessions(try identity(seed: 0x41), try identity(seed: 0x42))
    let plaintext = Data("popopx mesh hello".utf8)
    let wire = try sender.encrypt(plaintext)

    #expect(wire.firstRange(of: plaintext) == nil)
    #expect(wire.count == plaintext.count + 28)
    #expect(try receiver.decrypt(wire) == plaintext)
}

@Test("An empty payload still travels as a real frame")
func emptyPayloadTravels() throws {
    var (sender, receiver) = try sessions(try identity(seed: 0x43), try identity(seed: 0x44))
    let wire = try sender.encrypt(Data())

    #expect(wire.count == 28)
    #expect(try receiver.decrypt(wire) == Data())
}

@Test("The frame overhead agrees with the config the fragmenter sizes against")
func frameOverheadMatchesConfig() {
    #expect(PopopxMeshConfig.default.noiseTransportOverhead == PopopxNoiseCipherState.frameOverhead)
    #expect(PopopxNoiseCipherState.frameOverhead == 28)
    #expect(PopopxNoiseCipherState.nonceByteCount == 12)
    #expect(PopopxNoiseCipherState.tagByteCount == 16)
}

// MARK: - On-wire lengths

@Test("Handshake messages have the byte lengths the XX pattern promises")
func handshakeWireLengths() throws {
    let alice = try identity(seed: 0x51)
    let bob = try identity(seed: 0x52)
    var initiator = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    var responder = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)
    let empty = Data()

    // -> e: the ephemeral public key and nothing else.
    let message1 = try initiator.nextMessage(payload: empty)
    #expect(message1.count == 32)
    _ = try responder.consume(message1)

    // <- e, ee, s, es: 32 + (32 + 16) + (0 + 16).
    let message2 = try responder.nextMessage(payload: empty)
    #expect(message2.count == 96)
    _ = try initiator.consume(message2)

    // -> s, se: (32 + 16) + (0 + 16).
    let message3 = try initiator.nextMessage(payload: empty)
    #expect(message3.count == 64)
    _ = try responder.consume(message3)

    // A payload rides on the end of the message it belongs to, and only message 1's is unkeyed.
    var anotherInitiator = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    let sized = Data(repeating: 0x7F, count: 5)
    let sizedMessage1 = try anotherInitiator.nextMessage(payload: sized)
    #expect(sizedMessage1.count == 32 + 5)

    var freshInitiator = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    let plainMessage1 = try freshInitiator.nextMessage(payload: Data())
    var anotherResponder = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)
    _ = try anotherResponder.consume(plainMessage1)
    #expect(try anotherResponder.nextMessage(payload: sized).count == 32 + 48 + 5 + 16)
}

@Test("Message 1 carries its payload in the clear, as a pattern with no key yet requires")
func messageOnePayloadIsReadableOnTheWire() throws {
    let alice = try identity(seed: 0x61)
    var initiator = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    let payload = Data("unauthenticated".utf8)
    let message1 = try initiator.nextMessage(payload: payload)

    #expect(message1.count == 32 + payload.count)
    #expect(message1.suffix(payload.count) == payload)

    // Message 2 is keyed: the same payload cannot be recognised on the wire.
    let (_, message2) = try pendingMessage2(alice: alice, bob: try identity(seed: 0x62), payload: payload)
    #expect(message2.count == 32 + 48 + payload.count + 16)
    #expect(message2.suffix(payload.count) != payload)
}

// MARK: - Known answers

/// Locked values for the seeds and pinned ephemerals below, in hex. They were produced by a second,
/// independent implementation of the same primitives (Node's built-in OpenSSL: `x25519`,
/// `hkdfSync('sha256')`, `chacha20-poly1305`) run over the same transcripts, and each one was then
/// confirmed from this package before it was written down. Nothing here is a placeholder.
///
/// To re-derive them, add this inside `knownAnswerHandshake` for one run and paste the output:
///
///     print("KAT handshakeHash", pair.initiator.handshakeHash.popopxHex)
///     print("KAT frameAtOne", try frame(from: pair.initiator.transportKeys, plaintext: Data("popopx".utf8), counter: 1).popopxHex)
///
/// Removing the lines afterwards is part of the recipe: a test that prints its own expectations can
/// never fail, so the values are literals and the prints are not.
private enum KAT {
    static let handshakeHash = "82e4a694c0a0d6e4d725585f3b0c453dbd6c5ad7e513ecd87bcb701153fc5df4"
    static let initiatorSeesPeer = "db48257e1237976a74ad8cfedca00213408fe89ac6251f1b930245f242b5c31a"
    static let responderSeesPeer = "c306fb0ef2bf8b7f93bad98155fa37daec74db0c4cbeda6c6f1dba9d36558252"
    static let initiatorSendKey = "91ddefe4726ad560e54ba668b987bd4d92f78656ed3cf0a26ea0305932786072"
    static let initiatorReceiveKey = "7b1a45176f9b047629b63392b5703d3b851d9021c278bfc08a97433caa35d36f"
    static let frameAtZero = "0000000000000000000000000756db07a66a1de005667df0a9741f8fe05663bc1621"
    /// Counter 0 is the one counter whose two encodings are the same bytes, so on its own it proves
    /// nothing about byte order. These three do: a big-endian counter fails them.
    static let frameAtOne = "000000000100000000000000e8b801edf02437c2cc727743ca14a7fa96ef24e990ac"
    static let frameAtFive = "0000000005000000000000008902ed5eb5c58d8514a1381138980c5d1d9d503fa4cb"
    static let frameAtSeven = "000000000700000000000000f02fbfe05abc3c614617d78d793ff1dbfbc15894f0f2"
}

@Test("A pinned handshake reproduces one hash, one key pair and one frame")
func knownAnswerHandshake() throws {
    let alice = try identity(seed: 0xA1)
    let bob = try identity(seed: 0xB2)
    let pair = try fullExchange(
        alice: alice,
        bob: bob,
        initiatorEphemeral: Data(repeating: 0x01, count: 32),
        responderEphemeral: Data(repeating: 0x02, count: 32)
    )

    // Both ends first: if either side drifted during the three messages these fail, and only then
    // do the literals below say which of the two readings of the spec the field expects.
    #expect(pair.initiator.handshakeHash == pair.responder.handshakeHash)
    #expect(alice.publicKey.popopxHex == KAT.responderSeesPeer)
    #expect(bob.publicKey.popopxHex == KAT.initiatorSeesPeer)
    #expect(pair.initiator.handshakeHash.popopxHex == KAT.handshakeHash)
    #expect(pair.initiator.peerStaticPublicKey.popopxHex == KAT.initiatorSeesPeer)
    #expect(pair.responder.peerStaticPublicKey.popopxHex == KAT.responderSeesPeer)
    #expect(pair.initiator.transportKeys.sendKey.popopxHex == KAT.initiatorSendKey)
    #expect(pair.initiator.transportKeys.receiveKey.popopxHex == KAT.initiatorReceiveKey)

    let wire = try frame(from: pair.initiator.transportKeys, plaintext: Data("popopx".utf8), counter: 0)
    #expect(wire.count == 34)
    #expect(wire.popopxHex == KAT.frameAtZero)
    // Same key, same counter, same bytes: sealing at a fixed nonce must not drift between calls.
    #expect(try frame(from: pair.initiator.transportKeys, plaintext: Data("popopx".utf8), counter: 0) == wire)

    var receiver = try session(for: pair.responder)
    #expect(try receiver.decrypt(wire) == Data("popopx".utf8))

}

@Test("The frame prefix carries the counter little-endian, as Noise specifies")
func framePrefixIsLittleEndian() throws {
    let alice = try identity(seed: 0xA1)
    let bob = try identity(seed: 0xB2)
    let pair = try fullExchange(
        alice: alice,
        bob: bob,
        initiatorEphemeral: Data(repeating: 0x01, count: 32),
        responderEphemeral: Data(repeating: 0x02, count: 32)
    )
    let keys = pair.initiator.transportKeys
    let plaintext = Data("popopx".utf8)

    for (counter, expected) in [(1, KAT.frameAtOne), (5, KAT.frameAtFive), (7, KAT.frameAtSeven)] {
        let wire = try frame(from: keys, plaintext: plaintext, counter: UInt64(counter))
        #expect(wire.popopxHex == expected, "counter \(counter) sealed to a frame nobody else produces")
        // The prefix is readable before any decryption, which is what lets a relay hop run the
        // replay check on a frame it cannot open.
        #expect(PopopxNoiseCipherState.counter(nonceBytes: wire.prefix(12)) == UInt64(counter))
    }
}

// MARK: - Tampering

@Test("Flipping any single byte of a frame stops it opening")
func tamperedFrameIsRejected() throws {
    var (sender, receiver) = try sessions(try identity(seed: 0x71), try identity(seed: 0x72))
    let plaintext = Data("mesh payload".utf8)
    let wire = try sender.encrypt(plaintext)

    for index in wire.indices {
        var tampered = wire
        tampered[index] ^= 0x01
        // Flipping the counter moves the frame to a nonce nobody sent, so the reason varies (an
        // unseen counter fails the tag, a stale one never reaches the AEAD); refusing it does not.
        #expect(throws: (any Error).self) {
            _ = try receiver.decrypt(tampered)
        }
    }
    // Inside the authenticated part the counter still reads 0, so there it is always the tag.
    for index in 12..<wire.count {
        var tampered = wire
        tampered[index] ^= 0x01
        #expect(throws: PopopxNoiseError.decryptionFailed) {
            _ = try receiver.decrypt(tampered)
        }
    }
    // None of those attempts moved either counter, so the honest frame still opens.
    #expect(sender.messagesSent == 1)
    #expect(receiver.peerCounter == nil)
    #expect(try receiver.decrypt(wire) == plaintext)
}

@Test("A frame from another session does not open")
func wrongKeyIsRejected() throws {
    var (sender, _) = try sessions(try identity(seed: 0x81), try identity(seed: 0x82))
    var (_, otherReceiver) = try sessions(try identity(seed: 0x83), try identity(seed: 0x84))
    let wire = try sender.encrypt(Data("not for you".utf8))

    #expect(throws: PopopxNoiseError.decryptionFailed) {
        _ = try otherReceiver.decrypt(wire)
    }
}

@Test("A frame shorter than its own framing is refused before any crypto runs")
func shortFrameIsRefused() throws {
    var (sender, receiver) = try sessions(try identity(seed: 0x91), try identity(seed: 0x92))
    let wire = try sender.encrypt(Data("hello".utf8))

    for length in [0, 11, 12, 27] {
        #expect(throws: PopopxNoiseError.messageTooShort(bytes: length, required: 28)) {
            _ = try receiver.decrypt(wire.prefix(length))
        }
    }
}

@Test("A nonce prefix without its zero padding is refused")
func malformedNoncePrefixIsRefused() throws {
    var (_, receiver) = try sessions(try identity(seed: 0x93), try identity(seed: 0x94))
    let junk = Data([0x00, 0x01, 0x00, 0x00]) + Data(repeating: 0x07, count: 8) + Data(repeating: 0x5A, count: 20)

    #expect(throws: PopopxNoiseError.decryptionFailed) {
        _ = try receiver.decrypt(junk)
    }
}

// MARK: - Replays and ordering

@Test("The same frame read twice is a replay")
func replayIsRejected() throws {
    var (sender, receiver) = try sessions(try identity(seed: 0xA1), try identity(seed: 0xB1))

    let first = try sender.encrypt(Data("one".utf8))
    let second = try sender.encrypt(Data("two".utf8))
    #expect(try receiver.decrypt(first) == Data("one".utf8))
    #expect(throws: PopopxNoiseError.replayed(counter: 0)) {
        _ = try receiver.decrypt(first)
    }
    // A rejected replay must not have eaten the next counter.
    #expect(try receiver.decrypt(second) == Data("two".utf8))
    #expect(receiver.peerCounter == 2)
}

@Test("Counters that arrive out of order still open, once each")
func outOfOrderCountersOpen() throws {
    let pair = try fullExchange(
        alice: try identity(seed: 0xC1),
        bob: try identity(seed: 0xC2)
    )
    var receiver = try session(for: pair.responder)

    // Flooding gives one peer's packets a head start and a late finish; the window has to take the
    // whole shuffled run and then refuse any of it a second time.
    let order: [UInt64] = [0, 5, 3, 4, 1, 2, 6]
    for counter in order {
        let plaintext = Data([UInt8(64 + counter)])
        let wire = try frame(
            from: pair.initiator.transportKeys,
            plaintext: plaintext,
            counter: counter
        )
        #expect(try receiver.decrypt(wire) == plaintext)
    }
    #expect(receiver.peerCounter == 7)

    for counter in order {
        let wire = try frame(
            from: pair.initiator.transportKeys,
            plaintext: Data([UInt8(64 + counter)]),
            counter: counter
        )
        #expect(throws: PopopxNoiseError.replayed(counter: counter)) {
            _ = try receiver.decrypt(wire)
        }
    }
    // A newer counter is still welcome after all that shuffling.
    let next = try frame(from: pair.initiator.transportKeys, plaintext: Data([0x7F]), counter: 7)
    #expect(try receiver.decrypt(next) == Data([0x7F]))
}

@Test("A counter the window no longer remembers is refused with the start it fell behind")
func counterOutsideWindowIsRefused() throws {
    let pair = try fullExchange(
        alice: try identity(seed: 0xD1),
        bob: try identity(seed: 0xD2)
    )
    var receiver = try session(for: pair.responder)
    let keys = pair.initiator.transportKeys

    #expect(try receiver.decrypt(try frame(from: keys, plaintext: Data([0xFF]), counter: 2_000)) == Data([0xFF]))

    // 1023 counters behind the highest is the oldest thing still remembered; 1024 behind is not.
    let oldestKept: UInt64 = 2_000 - 1_023
    #expect(try receiver.decrypt(try frame(from: keys, plaintext: Data([0x01]), counter: oldestKept)) == Data([0x01]))

    #expect(throws: PopopxNoiseError.counterOutsideWindow(counter: 976, windowStart: 977)) {
        _ = try receiver.decrypt(try frame(from: keys, plaintext: Data([0x02]), counter: 976))
    }
    #expect(throws: PopopxNoiseError.counterOutsideWindow(counter: 0, windowStart: 977)) {
        _ = try receiver.decrypt(try frame(from: keys, plaintext: Data([0x03]), counter: 0))
    }
    #expect(receiver.peerCounter == 2_001)
}

@Test("A forged frame cannot retire a counter the real peer still needs")
func failedDecryptionLeavesTheWindowUntouched() throws {
    let pair = try fullExchange(
        alice: try identity(seed: 0xE1),
        bob: try identity(seed: 0xE2)
    )
    var receiver = try session(for: pair.responder)

    // Garbage at a counter the real peer is about to use: the open fails, so nothing is marked and
    // the honest frame at the same counter still gets through.
    let junk = PopopxNoiseCipherState.nonceBytes(counter: 7) + Data(repeating: 0x5A, count: 32)
    #expect(throws: PopopxNoiseError.decryptionFailed) {
        _ = try receiver.decrypt(junk)
    }
    #expect(receiver.peerCounter == nil)

    let real = try frame(from: pair.initiator.transportKeys, plaintext: Data("seven".utf8), counter: 7)
    #expect(try receiver.decrypt(real) == Data("seven".utf8))
    #expect(receiver.peerCounter == 8)
}

@Test("A narrow window forgets exactly where it says it does")
func customWindowSizeBoundary() throws {
    let pair = try fullExchange(
        alice: try identity(seed: 0xF8),
        bob: try identity(seed: 0x09)
    )
    var receiver = try #require(
        PopopxNoiseSession(
            peerPublicKey: pair.responder.peerStaticPublicKey,
            keys: pair.responder.transportKeys,
            replayWindow: 8
        ),
        "a window of 8 counters is inside the accepted range, so the session must build"
    )
    let keys = pair.initiator.transportKeys

    #expect(try receiver.decrypt(try frame(from: keys, plaintext: Data([0x01]), counter: 100)) == Data([0x01]))
    // Offsets 1 through 7 behind the highest are remembered.
    for counter in [99, 98, 97, 96, 95, 94, 93] {
        let plaintext = Data([UInt8(counter)])
        #expect(try receiver.decrypt(
            try frame(from: keys, plaintext: plaintext, counter: UInt64(counter))
        ) == plaintext)
    }
    #expect(throws: PopopxNoiseError.replayed(counter: 95)) {
        _ = try receiver.decrypt(try frame(from: keys, plaintext: Data([95]), counter: 95))
    }
    // Eight counters behind 100 is outside a window that is eight wide.
    #expect(throws: PopopxNoiseError.counterOutsideWindow(counter: 92, windowStart: 93)) {
        _ = try receiver.decrypt(try frame(from: keys, plaintext: Data([92]), counter: 92))
    }
}

// MARK: - Counter ceilings

@Test("A key stops sealing at its ceiling instead of rekeying on its own")
func cipherRefusesAtTheCeiling() throws {
    let cipher = try PopopxNoiseCipherState(key: Data(repeating: 0x0B, count: 32))
    let limit = PopopxNoiseCipherState.messageLimit
    #expect(limit == (1 << 32) - 1)

    #expect(throws: PopopxNoiseError.localNonceExhausted) {
        _ = try cipher.encrypt(Data("no".utf8), nonce: limit)
    }
    // One below the ceiling is still a legal message.
    let last = try cipher.encrypt(Data("yes".utf8), nonce: limit - 1)
    #expect(try cipher.decrypt(last.frame, nonce: limit - 1) == Data("yes".utf8))
    #expect(throws: PopopxNoiseError.peerNonceExhausted) {
        _ = try cipher.decrypt(last.frame, nonce: limit)
    }
    // The tag is the frame's own tail, so a caller can dedupe on it without re-hashing the frame.
    let sealed = try cipher.encrypt(Data("yes".utf8), nonce: 0)
    #expect(sealed.frame.suffix(16) == sealed.tag)
}

@Test("A session reports a peer that ran past the ceiling")
func sessionRefusesExhaustedPeerCounter() throws {
    var (sender, receiver) = try sessions(try identity(seed: 0xF1), try identity(seed: 0xF2))
    let wire = try sender.encrypt(Data("first".utf8))
    #expect(wire.count == 33)
    #expect(sender.messagesSent == 1)
    #expect(try receiver.decrypt(wire) == Data("first".utf8))

    let stranger = try #require(PopopxNoiseTransportKeys(
        sendKey: Data(repeating: 0x0C, count: 32),
        receiveKey: Data(repeating: 0x0D, count: 32)
    ))
    let past = try sealedBeyondTheCeiling(key: stranger.sendKey, counter: PopopxNoiseCipherState.messageLimit)
    // The ceiling is checked before the key, so a peer that overran its counter is named as the
    // problem even when the frame was sealed with somebody else's key.
    #expect(throws: PopopxNoiseError.peerNonceExhausted) {
        _ = try receiver.decrypt(past)
    }
}

@Test("A symmetric key of the wrong length is refused")
func cipherKeyLength() throws {
    #expect(throws: PopopxNoiseError.keyLengthInvalid(bytes: 31)) {
        _ = try PopopxNoiseCipherState(key: Data(repeating: 0x01, count: 31))
    }
    #expect(PopopxNoiseTransportKeys(
        sendKey: Data(repeating: 1, count: 31), receiveKey: Data(repeating: 2, count: 32)
    ) == nil)
    #expect(PopopxNoiseTransportKeys(
        sendKey: Data(repeating: 1, count: 32), receiveKey: Data(repeating: 2, count: 33)
    ) == nil)
    #expect(PopopxNoiseTransportKeys(
        sendKey: Data(repeating: 1, count: 32), receiveKey: Data(repeating: 2, count: 32)
    ) != nil)
}

// MARK: - Handshake ordering and damaged input

@Test("Speaking or listening out of turn is refused")
func outOfOrderHandshakeThrows() throws {
    let alice = try identity(seed: 0x1A)
    let bob = try identity(seed: 0x2B)
    var initiator = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    var responder = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)

    let message1 = try initiator.nextMessage(payload: Data())
    // Message 2 belongs to the responder, so the initiator may neither write nor read it.
    #expect(throws: PopopxNoiseError.handshakeOutOfOrder(role: .responder)) {
        _ = try initiator.nextMessage(payload: Data())
    }
    // Reading message 2 is the initiator's job, so a made-up one is an AEAD failure, not a turn
    // violation: the turn check only ever stops a role from doing the other role's message.
    #expect(throws: PopopxNoiseError.decryptionFailed) {
        _ = try initiator.consume(Data(repeating: 0x30, count: 96))
    }
    // A peer cannot be told its own message 1 back.
    var freshInitiator = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    #expect(throws: PopopxNoiseError.handshakeOutOfOrder(role: .initiator)) {
        _ = try freshInitiator.consume(message1)
    }
    // And a responder that never read message 1 may not speak message 2.
    #expect(throws: PopopxNoiseError.handshakeOutOfOrder(role: .initiator)) {
        _ = try responder.nextMessage(payload: Data())
    }
    // Transport keys cannot be taken from a half handshake.
    #expect(throws: PopopxNoiseError.handshakeNotComplete) {
        _ = try responder.finalize()
    }
}

@Test("A finished handshake refuses more messages and re-finalizes to the same result")
func completedHandshakeIsSpent() throws {
    let alice = try identity(seed: 0x3C)
    let bob = try identity(seed: 0x4D)
    var initiator = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    var responder = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)

    let message1 = try initiator.nextMessage(payload: Data())
    _ = try responder.consume(message1)
    let message2 = try responder.nextMessage(payload: Data())
    _ = try initiator.consume(message2)
    let message3 = try initiator.nextMessage(payload: Data())
    _ = try responder.consume(message3)

    let result = try initiator.finalize()
    #expect(result.peerStaticPublicKey == bob.publicKey)
    #expect(try initiator.finalize() == result)
    let mirrored = try responder.finalize()
    #expect(mirrored.handshakeHash == result.handshakeHash)
    #expect(mirrored.peerStaticPublicKey == alice.publicKey)
    #expect(mirrored.transportKeys.sendKey == result.transportKeys.receiveKey)
    #expect(throws: PopopxNoiseError.handshakeOutOfOrder(role: .initiator)) {
        _ = try initiator.nextMessage(payload: Data())
    }
    #expect(throws: PopopxNoiseError.handshakeOutOfOrder(role: .responder)) {
        _ = try responder.consume(message1)
    }
    #expect(throws: PopopxNoiseError.handshakeOutOfOrder(role: .initiator)) {
        _ = try initiator.consume(message3)
    }
}

@Test("Truncated handshake messages report the length they needed")
func truncatedHandshakeMessagesThrow() throws {
    let alice = try identity(seed: 0x5E)
    let bob = try identity(seed: 0x6F)
    var initiator = PopopxNoiseXXHandshake(role: .initiator, localIdentity: alice)
    let message1 = try initiator.nextMessage(payload: Data())

    #expect(throws: PopopxNoiseError.messageTooShort(bytes: 31, required: 32)) {
        var reader = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)
        _ = try reader.consume(message1.prefix(31))
    }
    #expect(throws: PopopxNoiseError.messageTooShort(bytes: 0, required: 32)) {
        var reader = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)
        _ = try reader.consume(Data())
    }

    // Message 2 wants 80 bytes before its payload: 32 for e and 48 for the wrapped static key.
    let (awaiting, message2) = try pendingMessage2(alice: alice, bob: bob)
    #expect(message2.count == 98)
    for (length, required) in [(0, 32), (31, 32), (32, 80), (60, 80), (79, 80)] {
        var reader = awaiting
        #expect(throws: PopopxNoiseError.messageTooShort(bytes: length, required: required)) {
            _ = try reader.consume(message2.prefix(length))
        }
    }

    // Message 3 is a 48-byte wrapped key and then at least a 16-byte payload tag.
    let (awaitingResponder, message3) = try pendingMessage3(alice: alice, bob: bob)
    #expect(message3.count == 64)
    for (length, required) in [(0, 48), (40, 48), (47, 48)] {
        var reader = awaitingResponder
        #expect(throws: PopopxNoiseError.messageTooShort(bytes: length, required: required)) {
            _ = try reader.consume(message3.prefix(length))
        }
    }
    var keyOnly = awaitingResponder
    #expect(throws: PopopxNoiseError.messageTooShort(bytes: 0, required: 16)) {
        _ = try keyOnly.consume(message3.prefix(48))
    }
}

@Test("Foreign bytes at any handshake step come back as an error, not a crash")
func unrelatedDataIsRejectedNotCrashed() throws {
    let alice = try identity(seed: 0x70)
    let bob = try identity(seed: 0x81)

    // Message 1 has no key and no tag, so anything at least a key long is *accepted*: that is the
    // XX pattern's trade-off and the reason the transport must not trust a peer before message 3.
    for size in [32, 48, 96, 512] {
        let junk = Data((0..<size).map { UInt8($0 % 251) })
        var responder = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)
        let (payload, complete) = try responder.consume(junk)
        #expect(complete == false)
        #expect(payload == junk.suffix(size - 32))
    }
    for size in [1, 16, 31] {
        var responder = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)
        #expect(throws: PopopxNoiseError.messageTooShort(bytes: size, required: 32)) {
            _ = try responder.consume(Data(repeating: 0x5A, count: size))
        }
    }

    // Messages 2 and 3 are keyed, so foreign bytes can only fail a tag or the key behind it.
    for size in [1, 16, 96, 512, 4_096] {
        let junk = Data((0..<size).map { UInt8(($0 &+ 7) % 251) })
        let (awaitingInitiator, _) = try pendingMessage2(alice: alice, bob: bob)
        var initiatorReading = awaitingInitiator
        #expect(throws: (any Error).self) {
            _ = try initiatorReading.consume(junk)
        }

        let (awaitingResponder, _) = try pendingMessage3(alice: alice, bob: bob)
        var responderReading = awaitingResponder
        #expect(throws: (any Error).self) {
            _ = try responderReading.consume(junk)
        }
    }
}

@Test("A bit flipped inside a wrapped key is an authentication failure")
func tamperedHandshakeFieldThrows() throws {
    let alice = try identity(seed: 0x92)
    let bob = try identity(seed: 0xA3)

    // The static key sits at bytes 32..<80 of message 2 and 0..<48 of message 3. A flipped byte
    // there fails the tag over the key, and a peer that cannot show its key is not a session.
    for index in [0, 32, 40, 63, 79, 80, 95] {
        let (awaiting, message2) = try pendingMessage2(
            alice: alice,
            bob: bob,
            payload: Data("hi".utf8)
        )
        #expect(message2.count == 98)
        var tampered = message2
        tampered[index] ^= 0x80
        var initiator = awaiting
        #expect(throws: PopopxNoiseError.decryptionFailed) {
            _ = try initiator.consume(tampered)
        }
    }

    for index in [0, 16, 47] {
        let (awaiting, message3) = try pendingMessage3(alice: alice, bob: bob)
        var tampered = message3
        tampered[index] ^= 0x80
        var responder = awaiting
        #expect(throws: PopopxNoiseError.decryptionFailed) {
            _ = try responder.consume(tampered)
        }
    }
}

@Test("Only the XX handshake this build spells out is accepted")
func protocolNameIsChecked() throws {
    let alice = try identity(seed: 0xB4)
    for name in [
        "Noise_XX_25519_ChaChaPoly_AESGCM_SHA256",
        "Noise_IK_25519_ChaChaPoly_SHA256",
        "Noise_XX",
        "",
    ] {
        #expect(throws: PopopxNoiseError.protocolNameMismatch) {
            _ = try PopopxNoiseXXHandshake(
                role: .initiator,
                localIdentity: alice,
                protocolName: name,
                ephemeralSeed: nil
            )
        }
    }
    let accepted = try PopopxNoiseXXHandshake(
        role: .initiator,
        localIdentity: alice,
        protocolName: PopopxNoiseXXHandshake.protocolName
    )
    #expect(!accepted.isComplete)
    // 32 bytes exactly, which is what makes the spec's zero-padded initial h the name itself.
    #expect(PopopxNoiseXXHandshake.protocolName.utf8.count == 32)
}

@Test("An ephemeral seed that cannot become a key is reported, not forced")
func unusableLocalKeyThrows() throws {
    let alice = try identity(seed: 0xC5)
    for badSeed in [Data(), Data(repeating: 0x01, count: 31), Data(repeating: 0x01, count: 33)] {
        var handshake = try PopopxNoiseXXHandshake(
            role: .initiator,
            localIdentity: alice,
            protocolName: PopopxNoiseXXHandshake.protocolName,
            ephemeralSeed: badSeed
        )
        #expect(throws: PopopxNoiseError.localKeyUnusable) {
            _ = try handshake.nextMessage(payload: Data())
        }
    }
}

@Test("A peer key that says nothing about who holds it is refused")
func unusablePeerKeyThrows() throws {
    let bob = try identity(seed: 0xC7)
    var responder = PopopxNoiseXXHandshake(role: .responder, localIdentity: bob)
    // The all-zero encoding is the identity element: a DH against it is a constant, not a secret.
    #expect(throws: PopopxNoiseError.peerKeyUnusable) {
        _ = try responder.consume(Data(repeating: 0, count: 32))
    }
}

// MARK: - Session construction

@Test("A session keeps the peer key and the hex the pairing frames use")
func sessionKeepsPeerIdentity() throws {
    let alice = try identity(seed: 0xD6)
    let bob = try identity(seed: 0xE7)
    let (aliceSession, bobSession) = try sessions(alice, bob)

    #expect(aliceSession.peerPublicKey == bob.publicKey)
    #expect(aliceSession.peerMeshPublicKeyHex == bob.meshPublicKeyHex)
    #expect(bobSession.peerMeshPublicKeyHex == alice.meshPublicKeyHex)
    #expect(aliceSession.peerMeshPublicKeyHex.count == 64)
    #expect(PopopxMeshControlFrame.isMeshPublicKey(aliceSession.peerMeshPublicKeyHex))
    // The pairing ACK the transport answers with is built from exactly this string.
    let ack = PopopxMeshControlFrame.pairingAck(meshPublicKey: aliceSession.peerMeshPublicKeyHex)
    #expect(PopopxMeshControlFrame(ack.text) == ack)
    #expect(PopopxMeshPeerID(publicKey: aliceSession.peerPublicKey).bytes.count == 8)
}

@Test("A session refuses key material and windows it cannot size")
func sessionConstructionIsChecked() throws {
    let keys = try #require(PopopxNoiseTransportKeys(
        sendKey: Data(repeating: 0x01, count: 32),
        receiveKey: Data(repeating: 0x02, count: 32)
    ))
    let peer = Data(repeating: 0x03, count: 32)

    #expect(PopopxNoiseSession(peerPublicKey: Data(repeating: 0x03, count: 31), keys: keys) == nil)
    #expect(PopopxNoiseSession(peerPublicKey: Data(), keys: keys) == nil)
    #expect(PopopxNoiseSession(peerPublicKey: peer, keys: keys, replayWindow: 0) == nil)
    #expect(PopopxNoiseSession(peerPublicKey: peer, keys: keys, replayWindow: -1) == nil)
    #expect(PopopxNoiseSession(peerPublicKey: peer, keys: keys, replayWindow: PopopxNoiseSession.maxReplayWindow + 1) == nil)
    #expect(PopopxNoiseSession(peerPublicKey: peer, keys: keys, replayWindow: 8) != nil)
    #expect(PopopxNoiseSession(peerPublicKey: peer, keys: keys) != nil)
    #expect(PopopxNoiseSession.defaultReplayWindow == 1_024)
}

@Test("Counters belong to a copy, so a leaked duplicate is caught as a replay")
func sessionCountersArePerCopy() throws {
    let pair = try sessions(try identity(seed: 0xD7), try identity(seed: 0xD8))
    var sender = pair.alice
    var receiver = pair.bob

    let shared = try sender.encrypt(Data("shared".utf8))
    var twin = sender
    // The same key and the same nonce give byte-identical output, so a copy that falls behind is
    // stopped by the peer's window, not by anything inside this struct.
    let fromSender = try sender.encrypt(Data("next".utf8))
    let fromTwin = try twin.encrypt(Data("next".utf8))
    #expect(fromSender == fromTwin)

    #expect(try receiver.decrypt(shared) == Data("shared".utf8))
    #expect(try receiver.decrypt(fromSender) == Data("next".utf8))
    #expect(throws: PopopxNoiseError.replayed(counter: 1)) {
        _ = try receiver.decrypt(fromTwin)
    }
}
