//
//  PopopxNodeFeedWireTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The receiver side of the `popopx.discover.feed.v1` contract, checked against the pinned vectors in
//  `PopopxNodeFeedVectors`. See that file's header for what the vectors can and cannot prove.
//
//  The load-bearing test here is `canonicalBodiesMatchTheMint`: it compares the *bytes* this
//  serializer rebuilds against digests minted from Foundation's own
//  `JSONSerialization(…, [.sortedKeys, .withoutEscapingSlashes])` output. A signature check alone
//  passes for any self-consistent pair of encoder and verifier; this one fails the moment an
//  implementation escapes a `/`, normalizes an accent, or sorts a key differently — which is the exact
//  way a Kotlin receiver drifts, and it is pinned to the same numbers there.
//

import Foundation
import Testing

@testable import PopopxMeshKit

private typealias V = PopopxNodeFeedVectors
private typealias Wire = PopopxNodeFeedWire

private typealias Parsed = Result<PopopxNodeFeed, Wire.Refusal>

private func refusal(_ result: Parsed) -> Wire.Refusal? {
    if case let .failure(reason) = result { return reason }
    return nil
}

private func feedOf(_ result: Parsed) -> PopopxNodeFeed? {
    if case let .success(feed) = result { return feed }
    return nil
}

@Suite("PopopxNodeFeedWire")
struct PopopxNodeFeedWireTests {

    // MARK: Helpers

    /// A vector that must parse; a carrier that stops parsing here makes every later assertion about
    /// signatures meaningless, so it fails the test rather than returning an empty feed.
    private func feed(_ carrier: String) -> PopopxNodeFeed {
        guard let parsed = feedOf(Wire.parse(Data(carrier.utf8))) else {
            Issue.record("vector did not parse: \(String(describing: refusal(Wire.parse(Data(carrier.utf8)))))")
            return PopopxNodeFeed(schema: "", generatedAt: "", nodeId: "", publicKey: "", items: [], signature: "")
        }
        return parsed
    }

    private func outcome(
        _ carrier: String, trusted: String? = V.signingPublicKey, newerThan: Date? = nil
    ) -> Wire.Outcome {
        Wire.verify(data: Data(carrier.utf8), trustedPublicKey: trusted, newerThan: newerThan)
    }

    private func refused(_ carrier: String, _ reason: Wire.Refusal, trusted: String? = V.signingPublicKey) {
        switch outcome(carrier, trusted: trusted) {
        case let .refused(actual): #expect(actual == reason, "expected \(reason), got \(actual)")
        case .accepted: Issue.record("expected .refused(\(reason)), got .accepted")
        }
    }

    /// Edit a pinned vector the way an attacker would: decode, change one value, re-encode. The
    /// signatures stay exactly as the node made them.
    private func mutated(_ carrier: String, _ change: (inout [String: Any]) -> Void) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: Data(carrier.utf8)),
              var envelope = object as? [String: Any]
        else {
            Issue.record("vector did not decode")
            return Data()
        }
        change(&envelope)
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    // MARK: Acceptance

    @Test("The honest vectors are accepted under the pinned key")
    func honestVectorsAccept() {
        for (name, carrier) in [("plain", V.plain), ("escaping", V.escaping), ("unicode", V.unicode), ("empty", V.empty)] {
            if case let .refused(reason) = outcome(carrier) {
                Issue.record("\(name) refused: \(reason)")
            }
        }
    }

    @Test("An empty feed is a legitimate feed, not a malformed one")
    func emptyFeedIsValid() {
        #expect(feed(V.empty).items.isEmpty)
        if case .accepted = outcome(V.empty) {} else { Issue.record("the empty feed was refused") }
    }

    @Test("The file's own formatting is irrelevant: escaped slashes decode to the wire values")
    func decodedValuesAreUnescaped() {
        let parsed = feed(V.plain)
        #expect(parsed.items[0].link == "https://popopx.example/blog/1-2-0?x=a/b")
        #expect(parsed.items[1].sourceLabel == "~/Documents")
        #expect(parsed.items[1].link.isEmpty)
        let unicode = feed(V.unicode)
        #expect(unicode.items[0].title.unicodeScalars.contains(where: { $0.value == 0x2028 }))
        #expect(unicode.items[0].title.unicodeScalars.contains(where: { $0.value == 0x7F }))
        #expect(unicode.items[0].title.utf8.contains(0xF0)) // the astral emoji survives as UTF-8
        // Deliberately decomposed at mint time, and it must stay that way: normalizing here would
        // change the bytes under the signature. Compared by scalar, not by `contains` — Foundation's
        // string comparison is canonical-equivalent, so `contains("é")` is true for `e` + U+0301 and
        // would pass a decoder that had silently normalized. That is a measured result, not a theory.
        let summary = unicode.items[0].summary
        let scalars = Array(summary.unicodeScalars).map(\.value)
        #expect(scalars.contains(0x301))
        #expect(!scalars.contains(0xE9))
        #expect(summary.utf8Hex.contains("65cc81"))
        #expect(!summary.utf8Hex.contains("c3a9"))
    }

    // MARK: The byte gate

    @Test("Canonical bodies hash to the digests the mint measured from Foundation's own output")
    func canonicalBodiesMatchTheMint() {
        #expect(Wire.digestHex(Wire.canonicalItemBody(feed(V.plain).items[0])) == V.Digest.plainItemBody)
        #expect(Wire.digestHex(Wire.canonicalEnvelopeBody(feed(V.plain))) == V.Digest.plainEnvelopeBody)
        #expect(Wire.digestHex(Wire.canonicalItemBody(feed(V.escaping).items[0])) == V.Digest.escapingItemBody)
        #expect(Wire.digestHex(Wire.canonicalEnvelopeBody(feed(V.escaping))) == V.Digest.escapingEnvelopeBody)
        #expect(Wire.digestHex(Wire.canonicalItemBody(feed(V.unicode).items[0])) == V.Digest.unicodeItemBody)
        #expect(Wire.digestHex(Wire.canonicalEnvelopeBody(feed(V.unicode))) == V.Digest.unicodeEnvelopeBody)
        #expect(Wire.digestHex(Wire.canonicalEnvelopeBody(feed(V.empty))) == V.Digest.emptyEnvelopeBody)
    }

    @Test("Hashing the bytes that arrived is not the signed body")
    func fileBytesDifferFromSigningBody() {
        // For the two ASCII vectors the carrier is byte-identical to what the node wrote to disk, so
        // this compares the receiver's real input against the real signature body, not a paraphrase.
        #expect(Wire.digestHex(Data(V.plain.utf8)) == V.Digest.plainFileBytes)
        #expect(Wire.digestHex(Data(V.plain.utf8)) != V.Digest.plainEnvelopeBody)
        #expect(Wire.digestHex(Data(V.escaping.utf8)) == V.Digest.escapingFileBytes)
        // The unicode carrier is the one place the pinned text and the disk bytes part company.
        #expect(Wire.digestHex(Data(V.unicode.utf8)) == V.Digest.unicodeCarrierBytes)
        #expect(Wire.digestHex(Data(V.unicode.utf8)) != V.Digest.unicodeFileBytes)
    }

    @Test("Foundation's .sortedKeys order is the order this decoder hardcodes")
    func keyOrderMatchesFoundation() {
        // Reading the order out of JSONSerialization's own output, rather than from a comment saying
        // it was measured, so a toolchain that ever sorts differently fails here instead of refusing
        // every real feed in the field.
        func orderIn(_ text: String, _ keys: [String]) -> [String] {
            func position(_ key: String) -> Int {
                text.range(of: "\"\(key)\"")?.lowerBound.utf16Offset(in: text) ?? .max
            }
            return keys.sorted { position($0) < position($1) }
        }
        let itemSample: [String: Any] = [
            "timestamp": "", "sourceLabel": "", "link": "", "title": "", "summary": "", "id": "",
            "source": "", "signature": "", "sha256": "",
        ]
        let itemText = String(decoding: try! JSONSerialization.data(withJSONObject: itemSample, options: [.sortedKeys]), as: UTF8.self)
        #expect(orderIn(itemText, Wire.itemKeys) == Wire.itemKeys)

        let envelopeSample: [String: Any] = [
            "items": [[String: Any]](), "publicKey": "", "schema": "", "generatedAt": "", "nodeId": "",
            "signature": "",
        ]
        let envelopeText = String(decoding: try! JSONSerialization.data(withJSONObject: envelopeSample, options: [.sortedKeys]), as: UTF8.self)
        #expect(orderIn(envelopeText, Wire.envelopeBodyKeys) == Wire.envelopeBodyKeys)
    }

    @Test("The escaping table reproduces Foundation byte for byte")
    func escapingTable() {
        var item = PopopxNodeFeedItem(
            id: "x", title: "", summary: "", source: "rss", sourceLabel: "L",
            link: "https://a/b", timestamp: V.itemTimestamp, sha256: "", signature: ""
        )
        item.title = "q\"t b\\k s/l"
        item.summary = String(String.UnicodeScalarView(
            [0x08, 0x0C, 0x09, 0x0A, 0x0D, 0x01, 0x1F].compactMap(Unicode.Scalar.init)
        ))
        item.sourceLabel = "del\u{7F} ls\u{2028} ps\u{2029}"
        let body = String(decoding: Wire.canonicalItemBody(item), as: UTF8.self)
        #expect(body.contains(#""title":"q\"t b\\k s/l""#)) // quote and backslash escaped, slash raw
        #expect(body.contains(#""link":"https://a/b""#))
        #expect(body.contains("\\b\\f\\t\\n\\r"))
        #expect(body.contains("\\u0001\\u001f")) // four digits, lowercase hex
        #expect(body.contains("del\u{7F}"))
        #expect(body.contains("ls\u{2028} ps\u{2029}"))
        #expect(!body.contains("\\/"))
        // The seven signing keys, in order — and the two that are *about* the signature are absent,
        // which is what lets a digest be checked before any key is believed.
        #expect(body.hasPrefix(#"{"id":"x","link":"https://a/b","source":"rss","sourceLabel":""#))
        #expect(!body.contains("sha256"))
        #expect(!body.contains("signature"))
        #expect(body.hasSuffix("}"))
    }

    // MARK: Refusals, one per decision

    @Test("An item edited after signing fails on its digest, before any crypto")
    func editedItemFailsItsDigest() { refused(V.digestDrift, .itemDigest) }

    @Test("A recomputed digest cannot rescue an old item signature")
    func staleItemSignature() { refused(V.itemSignature, .itemSignature) }

    @Test("An envelope field changed after signing is caught by the envelope signature only")
    func changedEnvelopeField() { refused(V.envelopeSignature, .envelopeSignature) }

    @Test("Items signed by a second key are refused under the declared key")
    func foreignKeySignedItems() { refused(V.foreignKey, .itemSignature) }

    @Test("Reordering the items breaks only the envelope, which is what the order is for")
    func reorderedItems() {
        let data = mutated(V.plain) { envelope in
            var items = envelope["items"] as! [[String: Any]]
            items.swapAt(0, 1)
            envelope["items"] = items
        }
        switch Wire.verify(data: data, trustedPublicKey: V.signingPublicKey, newerThan: nil) {
        case let .refused(reason): #expect(reason == .envelopeSignature)
        case .accepted: Issue.record("a reordered envelope was accepted")
        }
    }

    @Test("A key that changed after pinning is refused, never re-pinned")
    func rotatedKeyIsVisible() {
        switch outcome(V.plain, trusted: V.otherPublicKey) {
        case let .refused(reason): #expect(reason == .keyMismatch)
        case .accepted: Issue.record("a rotated key was accepted")
        }
        // With nothing pinned yet the same feed is acceptable — pinning is the caller's first run.
        if case .accepted = outcome(V.plain, trusted: nil) {} else { Issue.record("the unpinned first run was refused") }
    }

    @Test("generatedAt must be strictly newer than the snapshot on file")
    func stalenessIsStrict() {
        guard let at = feed(V.plain).generatedAtDate else { Issue.record("generatedAt did not parse"); return }
        refusedStale(at)
    }

    private func refusedStale(_ at: Date) {
        switch outcome(V.plain, newerThan: at) {
        case let .refused(reason): #expect(reason == .stale)
        case .accepted: Issue.record("a snapshot of equal age was accepted")
        }
        switch outcome(V.plain, newerThan: at.addingTimeInterval(60)) {
        case let .refused(reason): #expect(reason == .stale)
        case .accepted: Issue.record("an older snapshot was accepted")
        }
        if case .accepted = outcome(V.plain, newerThan: at.addingTimeInterval(-60)) {}
        else { Issue.record("a newer snapshot was refused") }
    }

    @Test("The structural refusals fire before anything is signed")
    func structuralRefusals() {
        #expect(refusal(Wire.parse(Data(#"{"schema":"popopx.discover.feed.v2"}"#.utf8))) == .schema)
        #expect(refusal(Wire.parse(Data("[]".utf8))) == .malformedJSON)
        #expect(refusal(Wire.parse(Data("not json".utf8))) == .malformedJSON)
        #expect(refusal(Wire.parse(Data("\"a string\"".utf8))) == .malformedJSON)
        #expect(refusal(Wire.parse(Data(repeating: 0x20, count: Int(Wire.maximumFeedBytes) + 1))) == .malformedJSON)
        #expect(refusal(Wire.parse(mutated(V.plain) { $0["publicKey"] = "" })) == .emptyKey)
        // A padded or standard-alphabet key is refused rather than repaired.
        #expect(refusal(Wire.parse(mutated(V.plain) { $0["publicKey"] = "AA==" })) == .emptyKey)
        #expect(refusal(Wire.parse(mutated(V.plain) { $0["publicKey"] = "AA/+AA" })) == .emptyKey)
        #expect(refusal(Wire.parse(mutated(V.plain) { $0["signature"] = "" })) == .emptySig)
        #expect(refusal(Wire.parse(mutated(V.plain) { $0["items"] = ["not an object"] })) == .itemShape)
        // A macro argument cannot carry a multiline closure, so each edit is built first and asserted
        // on its own line.
        let blankId = mutated(V.plain) { envelope in
            var items = envelope["items"] as! [[String: Any]]
            items[0]["id"] = ""
            envelope["items"] = items
        }
        #expect(refusal(Wire.parse(blankId)) == .itemShape)
        let missingTitle = mutated(V.plain) { envelope in
            var items = envelope["items"] as! [[String: Any]]
            items[0].removeValue(forKey: "title")
            envelope["items"] = items
        }
        #expect(refusal(Wire.parse(missingTitle)) == .itemShape)
        let shortDigest = mutated(V.plain) { envelope in
            var items = envelope["items"] as! [[String: Any]]
            items[0]["sha256"] = "too short"
            envelope["items"] = items
        }
        #expect(refusal(Wire.parse(shortDigest)) == .itemShape)
        // A number is not the string the producer writes, and describing it is not this decoder's job.
        let numericTimestamp = mutated(V.plain) { envelope in
            var items = envelope["items"] as! [[String: Any]]
            items[0]["timestamp"] = 1_764_000_000
            envelope["items"] = items
        }
        #expect(refusal(Wire.parse(numericTimestamp)) == .itemShape)
    }

    @Test("The item ceiling is structural: 60 parses, 61 does not, and neither reaches crypto")
    func itemCeiling() {
        func envelope(withCount count: Int) -> Data {
            let item: [String: Any] = [
                "id": "i", "title": "t", "summary": "s", "source": "rss", "sourceLabel": "L", "link": "",
                "timestamp": V.itemTimestamp, "sha256": String(repeating: "0", count: 64), "signature": "AAA",
            ]
            return try! JSONSerialization.data(withJSONObject: [
                "schema": Wire.schemaIdentifier, "generatedAt": V.generatedAt, "nodeId": "node-7f2a",
                "publicKey": V.signingPublicKey, "items": Array(repeating: item, count: count),
                "signature": "AAA",
            ])
        }
        #expect(feedOf(Wire.parse(envelope(withCount: 60)))?.items.count == 60)
        #expect(refusal(Wire.parse(envelope(withCount: 61))) == .itemShape)
    }

    @Test("A lone surrogate in the JSON is refused, not signed over")
    func loneSurrogateIsRefused() {
        if case let .accepted(parsed) = outcome(V.loneSurrogate) {
            Issue.record("a lone-surrogate feed was accepted: \(parsed.items.map(\.title))")
        }
    }

    // MARK: Storing

    @Test("Storing pins the key, refuses a rotated one, and keeps the reason on record")
    func ingestChain() throws {
        let at = try #require(Wire.date(V.generatedAt))
        let pinned = try #require(stored(Wire.ingest(Data(V.plain.utf8), into: nil, now: at)))
        #expect(pinned.publicKey == V.signingPublicKey)
        #expect(pinned.items.count == 2)
        #expect(pinned.generatedAt == V.generatedAt)
        #expect(pinned.keyChangedAtMs == nil)

        // The same envelope twice is not newer, so the snapshot does not move. This is the dedupe:
        // a re-synced chat row must not rewrite the panel or re-run the crypto for show.
        switch Wire.ingest(Data(V.plain.utf8), into: pinned, now: at) {
        case let .refused(reason, state):
            #expect(reason == .stale)
            #expect(state == pinned)
        case .stored: Issue.record("an identical feed replaced the snapshot")
        }

        // A feed under a different key is refused rather than re-pinned, and the refusal carries the
        // reason forward so the panel can say why nothing changed.
        let other = PopopxNodeFeedSnapshot(
            items: [], generatedAt: "2026-11-27T08:00:00Z", nodeId: "node-7f2a", publicKey: V.otherPublicKey
        )
        switch Wire.ingest(Data(V.plain.utf8), into: other, now: at) {
        case let .refused(reason, state):
            #expect(reason == .keyMismatch)
            #expect(state?.keyChangedAtMs == Int64(at.timeIntervalSince1970 * 1_000))
            #expect(state?.publicKey == V.otherPublicKey, "the pinned key was overwritten")
            #expect(state?.items.isEmpty == true, "a refused feed replaced the items")
        case .stored: Issue.record("a rotated key was stored")
        }

        // A tampered feed leaves the stored state byte-for-byte where it was, warning included.
        switch Wire.ingest(Data(V.digestDrift.utf8), into: pinned, now: at) {
        case let .refused(reason, state):
            #expect(reason == .itemDigest)
            #expect(state == pinned)
        case .stored: Issue.record("a tampered feed was stored")
        }

        // And once a key change is on record, a later success does not quietly undo it.
        var warned = other
        warned.publicKey = V.signingPublicKey
        warned.keyChangedAtMs = 1
        let kept = try #require(stored(Wire.ingest(Data(V.plain.utf8), into: warned, now: at)))
        #expect(kept.keyChangedAtMs == 1)
        #expect(kept.items.count == 2)
    }

    private func stored(_ apply: Wire.FeedApply) -> PopopxNodeFeedSnapshot? {
        if case let .stored(snapshot) = apply { return snapshot }
        return nil
    }

    // MARK: Primitives

    @Test("Unpadded base64url only, and exactly 32 bytes")
    func keyDecodingIsStrict() {
        #expect(Wire.keyBytes(V.signingPublicKey)?.count == 32)
        #expect(Wire.keyBytes("") == nil)
        #expect(Wire.keyBytes(String(repeating: "A", count: 43) + "=") == nil)
        #expect(Wire.keyBytes("AA/+AA") == nil)
        #expect(Wire.keyBytes("A") == nil)
        #expect(Wire.keyBytes(String(repeating: "A", count: 42)) == nil) // 31.5 bytes is not a key
    }

    @Test("generatedAt accepts the stamped form and a fractional one")
    func dateParsing() {
        #expect(Wire.date("2026-11-27T09:05:00Z") != nil)
        #expect(Wire.date("2026-11-27T09:05:00.123Z") != nil)
        #expect(Wire.date("2026-11-27 09:05:00") == nil)
        #expect(Wire.date("") == nil)
    }

    @Test("The auto-receive gate says no to everything that is not a bound node's feed")
    func autoReceiveGate() {
        let feed = Wire.artifactFileName
        #expect(Wire.shouldAutoReceive(fileName: feed, byteCount: 4_096, alreadyReceived: false, fromBoundNode: true))
        #expect(Wire.shouldAutoReceive(fileName: feed, byteCount: Wire.maximumFeedBytes, alreadyReceived: false, fromBoundNode: true))
        // The negative half is the point: each of these is a download the app must not start.
        #expect(!Wire.shouldAutoReceive(fileName: feed, byteCount: 1, alreadyReceived: false, fromBoundNode: false))
        #expect(!Wire.shouldAutoReceive(fileName: feed, byteCount: Wire.maximumFeedBytes + 1, alreadyReceived: false, fromBoundNode: true))
        #expect(!Wire.shouldAutoReceive(fileName: feed, byteCount: 0, alreadyReceived: false, fromBoundNode: true))
        #expect(!Wire.shouldAutoReceive(fileName: feed, byteCount: -1, alreadyReceived: false, fromBoundNode: true))
        #expect(!Wire.shouldAutoReceive(fileName: "other.json", byteCount: 1, alreadyReceived: false, fromBoundNode: true))
        #expect(!Wire.shouldAutoReceive(fileName: feed, byteCount: 1, alreadyReceived: true, fromBoundNode: true))
        #expect(!Wire.shouldAutoReceive(fileName: "FEED.JSON", byteCount: 1, alreadyReceived: false, fromBoundNode: true),
                "the basename is compared, not matched case-insensitively — the node writes one spelling")
        // The same file-level test, asked *after* the download, has to reach the same verdict: the
        // mount measures the real bytes before reading them, and it must not invent a second rule.
        #expect(Wire.isArtifact(fileName: feed, byteCount: Wire.maximumFeedBytes))
        #expect(!Wire.isArtifact(fileName: feed, byteCount: Wire.maximumFeedBytes + 1))
        #expect(!Wire.isArtifact(fileName: feed, byteCount: 0))
        #expect(!Wire.isArtifact(fileName: "Feed.json", byteCount: 1))
    }
}

private extension String {
    /// The string's UTF-8 spelled as hex. Used instead of `contains` whenever the question is about
    /// bytes, because Swift's string comparison is canonical-equivalent and would report a
    /// normalized `é` and a decomposed `e` + U+0301 as the same text.
    var utf8Hex: String { Data(utf8).map { String(format: "%02x", $0) }.joined() }
}
