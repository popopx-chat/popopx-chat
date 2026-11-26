//
//  PopopxOpaqueInviteCodecTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Cross-language conformance for the /i/v1/ invite codec.
//
//  The published vectors are the whole point of this file: they are sealed by the gateway's Python
//  and must come back byte-identical here, because an app link the gateway refuses to open is a
//  broken share path that no CI run in this repository can see. Everything else here is the
//  boundary — what sealing refuses (so nothing leaves this app that the servers reject), what
//  opening forgives (the ruled asymmetry: legacy `smp://` and Mac Node payloads may be read, never
//  minted), and what neither side may do: hand back a payload that authenticates but is not an
//  address.
//

import CryptoKit
import Foundation
import Testing

@testable import PopopxMeshKit

private typealias Codec = PopopxOpaqueInviteCodec
private typealias Failure = PopopxOpaqueInviteError

@Suite("PopopxOpaqueInviteCodec")
struct PopopxOpaqueInviteCodecTests {

    // MARK: Helpers

    /// Every published link this codec must read, including the one it must never mint.
    private var published: [PopopxOpaqueInviteVector] {
        PopopxOpaqueInviteVectors.suite + PopopxOpaqueInviteVectors.studio + [PopopxOpaqueInviteVectors.rejectedSMP]
    }

    /// The subset this codec is allowed to mint.
    private var sealable: [PopopxOpaqueInviteVector] {
        PopopxOpaqueInviteVectors.suite + PopopxOpaqueInviteVectors.studio
    }

    /// Seal an arbitrary payload with the format key, so a test can hand the opener something that
    /// authenticates but must still be refused. `@testable` visibility is the point.
    private func rawEnvelope(payload: String, nonce: Data) -> String {
        let box = try! ChaChaPoly.seal(
            Data(payload.utf8),
            using: Codec.formatKey,
            nonce: try! ChaChaPoly.Nonce(data: nonce),
            authenticating: Codec.aad
        )
        return Codec.base64URL(nonce + box.ciphertext + box.tag)
    }

    /// Flips one bit of the tag rather than one base64 character, for the same reason the gateway's
    /// `_flip_last_sealed_byte` exists: the last digit can carry discarded padding bits, so a
    /// character swap can leave the decoded bytes untouched and make a tamper test vacuous.
    private func flipTagBit(_ code: String) -> String? {
        guard var raw = Codec.base64URLDecode(code), let last = raw.indices.last else { return nil }
        raw[last] ^= 0x01
        return Codec.base64URL(raw)
    }

    // MARK: Derivation

    @Test("The published key derives from the published inputs")
    func formatKeyMatchesTheVectorFiles() {
        let derived = Codec.hkdf(
            ikm: Data(hex: PopopxOpaqueInviteVectors.ikmHex),
            salt: Data(PopopxOpaqueInviteVectors.salt.utf8),
            info: Data(PopopxOpaqueInviteVectors.info.utf8),
            length: 32
        )
        #expect(Data(keyBytes: derived) == Data(hex: PopopxOpaqueInviteVectors.keyHex))
        #expect(Data(keyBytes: Codec.formatKey) == Data(keyBytes: derived))
        #expect(Codec.linkPrefix == PopopxOpaqueInviteVectors.linkPrefix)
        #expect(Codec.linkPrefix.utf8.count == 25)
    }

    @Test("RFC 5869 case 1 survives the port")
    func hkdfStandardVector() {
        let v = PopopxOpaqueInviteVectors.hkdfCase1
        let out = Data(keyBytes: Codec.hkdf(
            ikm: Data(hex: v.ikmHex),
            salt: Data(hex: v.saltHex),
            info: Data(hex: v.infoHex),
            length: v.length
        ))
        #expect(out.count == v.length)
        #expect(out.hexLowered == v.okmHex)
    }

    @Test("The hex reader and the RFC 8439 AEAD vector agree with the published bytes")
    func aeadStandardVector() {
        let (keyHex, nonceHex, aadHex, plaintext, ciphertextHex, tagHex) = PopopxOpaqueInviteVectors.chachaCase
        let key = Data(hex: keyHex)
        let nonce = Data(hex: nonceHex)
        #expect(key.count == 32)
        #expect(nonce.count == 12)
        let box = try! ChaChaPoly.seal(
            Data(plaintext.utf8),
            using: SymmetricKey(data: key),
            nonce: try! ChaChaPoly.Nonce(data: nonce),
            authenticating: Data(hex: aadHex)
        )
        #expect(box.ciphertext.hexLowered == ciphertextHex)
        #expect(box.tag.hexLowered == tagHex)
    }

    // MARK: The published vectors, byte for byte

    @Test("Every published vector seals to its published code")
    func publishedVectorsSealExactly() throws {
        for vector in sealable {
            let nonce = Data(hex: vector.nonceHex)
            #expect(nonce.count == Codec.nonceBytes, "vector nonce did not decode as hex")
            let sealed = try #require(Codec.sealedBytes(uri: vector.plaintext, nonce: nonce))
            #expect(Codec.base64URL(sealed) == vector.sealedB64URL)
            #expect(Codec.link(forURI: vector.plaintext, nonce: nonce) == vector.link)
        }
    }

    @Test("Every published link opens back to its published plaintext")
    func publishedLinksOpenExactly() throws {
        #expect(published.count == 6)
        for vector in published {
            #expect(try Codec.uri(fromLink: vector.link) == vector.plaintext)
            #expect(Codec.uriIfOpaqueLink(vector.link) == vector.plaintext)
        }
    }

    @Test("The shape test accepts a minted link and refuses its near misses")
    func shapeCheckIsNotTooKind() throws {
        for vector in sealable {
            #expect(Codec.looksLikeOpaqueLink(vector.link))
        }
        let code = try Codec.substring(ofLink: PopopxOpaqueInviteVectors.suite[0].link)
        #expect(!Codec.looksLikeOpaqueLink(code))
        #expect(!Codec.looksLikeOpaqueLink("https://popopx.chat." + code))
        #expect(!Codec.looksLikeOpaqueLink("https://popopx.chat/i/v2/" + code))
        #expect(!Codec.looksLikeOpaqueLink(Codec.linkPrefix))
    }

    @Test("The code opens under every spelling of the link prefix, and under no other")
    func linkPrefixSpellings() throws {
        // Spelled out here rather than read from `Codec.openLinkPrefixes`: a loop over the production
        // list passes when that list shrinks to one entry, which is the exact regression this test
        // exists to catch.
        let expected = ["https://popopx.chat/i/v1/", "popopx:/i/v1/", "popopx://popopx.chat/i/v1/"]
        #expect(Codec.openLinkPrefixes == expected)
        let vector = try #require(PopopxOpaqueInviteVectors.suite.first)
        let code = try Codec.substring(ofLink: vector.link)
        for prefix in expected {
            let link = prefix + code
            #expect(Codec.looksLikeOpaqueLink(link), "prefix \(prefix) not read")
            #expect(try Codec.uri(fromLink: link) == vector.plaintext)
        }
        // Reading three spellings must not mean writing three: the servers publish one.
        #expect(Codec.openLinkPrefixes.first == Codec.linkPrefix)
        #expect(try #require(Codec.link(forURI: vector.plaintext)).hasPrefix(Codec.linkPrefix))
        // The near misses stay refused, including the app-scheme versions of them.
        #expect(!Codec.looksLikeOpaqueLink("popopx:/i/v2/" + code))
        #expect(!Codec.looksLikeOpaqueLink("popopx://popopx.chat." + code))
        #expect(throws: Failure.linkPrefixInvalid) { try Codec.uri(fromLink: "popopx:/invitation/" + code) }
    }

    // MARK: Sealing side — the strict half

    @Test("An smp:// address is never minted, even though it is still readable")
    func legacySchemeIsNotSealable() {
        let legacy = PopopxOpaqueInviteVectors.rejectedSMP.plaintext
        #expect(Codec.link(forURI: legacy) == nil)
        #expect(throws: Failure.uriSchemeInvalid) { try Codec.sealCode(forURI: legacy) }
    }

    @Test("Sealing refuses the inputs the gateway refuses")
    func sealGuards() {
        #expect(throws: Failure.emptyURI) { try Codec.sealCode(forURI: "") }
        #expect(throws: Failure.uriSchemeInvalid) { try Codec.sealCode(forURI: "popopx.chat/i/v1/x") }
        #expect(throws: Failure.uriSchemeInvalid) { try Codec.sealCode(forURI: "javascript:alert(1)") }
        #expect(throws: Failure.uriSchemeInvalid) { try Codec.sealCode(forURI: "SMP://smp1.popopx.im/a") }
        #expect(throws: Failure.uriNotPlain) { try Codec.sealCode(forURI: " https://popopx.chat/i/v1/x") }
        #expect(throws: Failure.uriNotPlain) { try Codec.sealCode(forURI: "https://popopx.chat/i/v1/x ") }
        #expect(throws: Failure.uriNotPlain) { try Codec.sealCode(forURI: "https://popopx.chat/a\tb") }
        #expect(throws: Failure.uriNotPlain) { try Codec.sealCode(forURI: "https://popopx.chat/a\nb") }
        #expect(throws: Failure.codeLengthInvalid) { try Codec.sealCode(forURI: "https://x.test/a", nonce: Data(count: 11)) }
    }

    @Test("The seal ceiling is the gateway's, and it is inclusive")
    func sealCeiling() {
        let head = "https://popopx.chat/"
        let atLimit = head + String(repeating: "a", count: Codec.maxSealPlaintextBytes - head.utf8.count)
        #expect(Array(atLimit.utf8).count == Codec.maxSealPlaintextBytes)
        #expect(Codec.link(forURI: atLimit) != nil)
        #expect(throws: Failure.uriTooLong(bytes: Codec.maxSealPlaintextBytes + 1, limit: Codec.maxSealPlaintextBytes)) {
            try Codec.sealCode(forURI: atLimit + "a")
        }
    }

    @Test("Two shares of one address are two different links")
    func freshNoncesAreNotReused() throws {
        let uri = PopopxOpaqueInviteVectors.suite[0].plaintext
        let a = try #require(Codec.link(forURI: uri))
        let b = try #require(Codec.link(forURI: uri))
        #expect(a != b)
        #expect(try Codec.uri(fromLink: a) == uri)
        #expect(try Codec.uri(fromLink: b) == uri)
    }

    // MARK: Opening side — the tolerant half, and its floor

    @Test("A legacy address and a Mac Node payload open; an address does not")
    func tolerantOpening() throws {
        let zeroNonce = Data(count: Codec.nonceBytes)

        let legacy = PopopxOpaqueInviteVectors.rejectedSMP.plaintext
        let legacyLink = Codec.linkPrefix + rawEnvelope(payload: legacy, nonce: zeroNonce)
        #expect(try Codec.uri(fromLink: legacyLink) == legacy)

        let pairing = "PPXNODE1-" + String(repeating: "Q", count: 96) + "." + String(repeating: "R", count: 48)
        let nodeLink = Codec.linkPrefix + rawEnvelope(payload: pairing, nonce: zeroNonce)
        #expect(try Codec.uri(fromLink: nodeLink) == pairing)
        #expect(!Codec.sealableSchemes.contains(where: { pairing.hasPrefix($0) }))

        // Opening is wider than connecting: the connect path uses this to refuse a pairing offer
        // without pretending it is a damaged invite.
        #expect(Codec.isConnectableOpened(legacy))
        #expect(!Codec.isConnectableOpened(pairing))
        #expect(Codec.isConnectableOpened("popopx:/invitation#?key=AAAA"))
        #expect(Codec.isConnectableOpened("https://popopx.chat/invitation#?key=AAAA"))
        #expect(!Codec.isConnectableOpened(""))

        // A payload that authenticates but is not an address is still refused: the tag alone is not
        // the trust boundary.
        for trap in ["javascript:alert(1)", "data:text/html,<script>", "<img src=x onerror=1>", " https://popopx.chat/a"] {
            let bait = Codec.linkPrefix + rawEnvelope(payload: trap, nonce: zeroNonce)
            #expect(throws: Failure.tampered) { try Codec.uri(fromLink: bait) }
        }
        #expect(throws: Failure.codeLengthInvalid) {
            try Codec.uri(fromLink: Codec.linkPrefix + rawEnvelope(payload: "", nonce: zeroNonce))
        }
    }

    @Test("A damaged envelope never yields an address")
    func tamperRejection() throws {
        let vector = try #require(published.first)
        #expect(try Codec.uri(fromLink: vector.link) == vector.plaintext)

        let flipped = try #require(flipTagBit(vector.sealedB64URL))
        #expect(flipped != vector.sealedB64URL)
        #expect(throws: Failure.tampered) { try Codec.uri(fromLink: Codec.linkPrefix + flipped) }

        #expect(throws: Failure.tampered) { try Codec.uri(fromLink: vector.link + "A") }
        #expect(throws: Failure.codeLengthInvalid) { try Codec.uri(fromLink: String(vector.link.dropLast(90))) }
        #expect(throws: Failure.codeLengthInvalid) { try Codec.uri(fromLink: Codec.linkPrefix) }
        #expect(throws: Failure.codeNotBase64URL) { try Codec.uri(fromLink: Codec.linkPrefix + "****") }
        #expect(throws: Failure.codeNotBase64URL) { try Codec.uri(fromLink: Codec.linkPrefix + "ab=c") }
        #expect(throws: Failure.codeNotBase64URL) {
            try Codec.uri(fromLink: Codec.linkPrefix + vector.sealedB64URL.replacingOccurrences(of: "-", with: "+"))
        }
        #expect(throws: Failure.linkPrefixInvalid) { try Codec.uri(fromLink: "https://popopx.chat." + vector.sealedB64URL) }
        #expect(throws: Failure.linkPrefixInvalid) { try Codec.uri(fromLink: "https://example.test/i/v1/" + vector.sealedB64URL) }
    }

    @Test("The open ceiling is Bot Studio's, and wider than the seal ceiling by ruling")
    func openCeiling() throws {
        #expect(Codec.maxOpenPlaintextBytes > Codec.maxSealPlaintextBytes)
        let zeroNonce = Data(count: Codec.nonceBytes)
        let head = "https://popopx.chat/"

        let wide = head + String(repeating: "a", count: Codec.maxOpenPlaintextBytes - head.utf8.count)
        #expect(Codec.link(forURI: wide) == nil)
        #expect(try Codec.uri(fromLink: Codec.linkPrefix + rawEnvelope(payload: wide, nonce: zeroNonce)) == wide)

        let beyond = head + String(repeating: "a", count: Codec.maxOpenPlaintextBytes + 1 - head.utf8.count)
        #expect(throws: Failure.codeLengthInvalid) {
            try Codec.uri(fromLink: Codec.linkPrefix + rawEnvelope(payload: beyond, nonce: zeroNonce))
        }
    }

    // MARK: Primitives

    @Test("The strict base64url reader accepts only the wire alphabet")
    func base64URLAlphabet() {
        #expect(Codec.base64URLDecode("AA") == Data([0x00]))
        #expect(Codec.base64URLDecode("AAA") == Data([0x00, 0x00]))
        #expect(Codec.base64URLDecode("A-_8") != nil)
        #expect(Codec.base64URLDecode("AAAAA") == nil)
        #expect(Codec.base64URLDecode("") == nil)
        #expect(Codec.base64URLDecode("A") == nil)
        #expect(Codec.base64URLDecode("AA==") == nil)
        #expect(Codec.base64URLDecode("AA/+") == nil)
        #expect(Codec.base64URLDecode("AAé") == nil)
    }

    @Test("A malformed hex literal reads empty instead of half a key")
    func hexReaderRejectsSilently() {
        #expect(Data(hex: PopopxOpaqueInviteVectors.ikmHex).count == 32)
        #expect(Data(hex: "").isEmpty)
        #expect(Data(hex: "abc").isEmpty)
        #expect(Data(hex: "zz").isEmpty)
        #expect(Data(hex: "d1 abb").isEmpty)
    }
}

private extension Data {
    init(keyBytes key: SymmetricKey) {
        self = key.withUnsafeBytes { Data($0) }
    }

    var hexLowered: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
