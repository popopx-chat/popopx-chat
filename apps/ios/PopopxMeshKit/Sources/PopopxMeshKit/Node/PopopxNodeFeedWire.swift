//
//  PopopxNodeFeedWire.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Decoder for `popopx.discover.feed.v1` — the signed Discover feed a bound Mac Node delivers as the
//  `feed.json` artifact of one result message.
//
//  Producer side, quoted rather than guessed (`PopopxMacNode` main = e40f5e3):
//   - item fields                     Discover/DiscoverModels.swift:176-186
//   - item signing body (7 keys)      Discover/DiscoverModels.swift:226-236
//   - envelope fields                 Discover/DiscoverModels.swift:247-271
//   - envelope signing body (5 keys)  Discover/DiscoverModels.swift:276-301
//   - structural refusals             Discover/DiscoverModels.swift:313-320
//   - item `sha256` semantics         Discover/DiscoverCenter.swift:287-293
//   - key/signature encoding          Core/MacNodePopopxBridge.swift:556,573-579, Models/MacNodeModels.swift:4044-4057
//
//  The one thing a receiver cannot do is hash the bytes it was sent. The node writes `feed.json` with
//  `NodeJSON.encoder(prettyPrinted: true)` (MacNodeModels.swift:426-437 = `[.prettyPrinted,
//  .sortedKeys]`, which escapes `/`), while both signatures cover a body **rebuilt from the decoded
//  values** with `[.sortedKeys, .withoutEscapingSlashes]`. So this file re-serializes from decoded
//  strings, and the file's own formatting is irrelevant to it.
//
//  The escaping table below was measured against Foundation on this machine (macOS 27 SDK, Swift
//  6.4) rather than read out of a specification, because it is the producer's actual serializer:
//   - `"` → `\"`, `\` → `\\`
//   - 0x08 → `\b`, 0x0C → `\f`, 0x09 → `\t`, 0x0A → `\n`, 0x0D → `\r`
//   - every other scalar below 0x20 → `\u00xx`, hex **lowercase**
//   - 0x2F `/` → raw (that is what `.withoutEscapingSlashes` buys), 0x7F → raw
//   - U+2028, U+2029 → raw, and no Unicode normalization is performed: a decomposed `e` + U+0301
//     stays `65 cc81`
//   - an unpaired surrogate never reaches this file at all. Measured on this machine:
//     `JSONSerialization` refuses to *parse* a `"\ud800"` escape (NSCocoaErrorDomain 3840, "expected
//     low-surrogate code point"), and `String.unicodeScalars` reports an ill-formed UTF-16 surrogate
//     as U+FFFD rather than as the surrogate. So there is nothing here to guard against, and the
//     builders are total — a feed that somehow carried one would fail on its digest, which is the
//     same refusal by a better instrument.
//   - key order: for the fixed protocol key sets, Foundation's `.sortedKeys` order is the order
//     spelled out in `itemKeys`/`envelopeKeys` below; `PopopxNodeFeedWireTests` asserts that
//     equality against `JSONSerialization` itself on every vector, so a toolchain that ever sorted
//     differently fails loudly instead of silently refusing every real feed
//

import CryptoKit
import Foundation

// MARK: - Values

/// One entry of the feed. All nine fields are strings on the wire; the producer's own `Codable`
/// emits exactly these keys, so a missing one is a refusal rather than a default. `Codable` is for
/// `PopopxNodeFeedSnapshot` (this device's own storage) — the wire itself is parsed by hand.
public struct PopopxNodeFeedItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    /// `folder`, `rss`, `json` or `mcp` — carried through unvalidated, it is display data.
    public var source: String
    public var sourceLabel: String
    /// Deliberately allowed to be empty by the producer: a local file path must not travel to the
    /// phone as a tappable target, so nothing here may assume a scheme is present.
    public var link: String
    public var timestamp: String
    /// Lowercase hex of this item's own seven-key canonical body.
    public var sha256: String
    /// Unpadded base64url Ed25519 signature over that same body.
    public var signature: String

    public init(
        id: String, title: String, summary: String, source: String, sourceLabel: String,
        link: String, timestamp: String, sha256: String, signature: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.source = source
        self.sourceLabel = sourceLabel
        self.link = link
        self.timestamp = timestamp
        self.sha256 = sha256
        self.signature = signature
    }
}

/// The signed envelope. `publicKey` is self-declared; whether it may be believed is the caller's
/// problem (`DiscoverSubscriptionManager` pins it on first full verification), never this decoder's.
public struct PopopxNodeFeed: Equatable, Sendable {
    public var schema: String
    public var generatedAt: String
    public var nodeId: String
    public var publicKey: String
    public var items: [PopopxNodeFeedItem]
    public var signature: String

    public init(
        schema: String, generatedAt: String, nodeId: String, publicKey: String,
        items: [PopopxNodeFeedItem], signature: String
    ) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.nodeId = nodeId
        self.publicKey = publicKey
        self.items = items
        self.signature = signature
    }

    /// The producer stamps this with `PrivacyStamp.iso` = `ISO8601DateFormatter`
    /// `[.withInternetDateTime]` in UTC (PrivacyBridges/PrivacyProposalLedger.swift:13-18).
    public var generatedAtDate: Date? { PopopxNodeFeedWire.date(generatedAt) }
}

/// What a receiver keeps between launches: the items it verified, the instant the node generated
/// them, the node's own id, and **the key they were verified under** — which is what makes the next
/// envelope's key a question with an answer.
///
/// `Codable` here is for this device's own storage only. Nothing may decode an incoming envelope with
/// it: the wire format is parsed by `PopopxNodeFeedWire.parse`, and the fields that decide acceptance
/// (`signature`, and each item's `sha256`) are deliberately absent, so a snapshot cannot be mistaken
/// for something a peer sent.
public struct PopopxNodeFeedSnapshot: Codable, Equatable, Sendable {
    public var items: [PopopxNodeFeedItem]
    public var generatedAt: String
    public var nodeId: String
    public var publicKey: String
    /// Milliseconds since 1970 of the last envelope whose key was **not** the pinned one. Set and
    /// persisted because the refusal repeats on every later feed: without it, a rotated node key would
    /// leave the panel showing stale content and no reason, forever.
    public var keyChangedAtMs: Int64?

    public init(
        items: [PopopxNodeFeedItem], generatedAt: String, nodeId: String, publicKey: String,
        keyChangedAtMs: Int64? = nil
    ) {
        self.items = items
        self.generatedAt = generatedAt
        self.nodeId = nodeId
        self.publicKey = publicKey
        self.keyChangedAtMs = keyChangedAtMs
    }

    public init(feed: PopopxNodeFeed) {
        self.init(
            items: feed.items, generatedAt: feed.generatedAt, nodeId: feed.nodeId,
            publicKey: feed.publicKey
        )
    }

    public var generatedAtDate: Date? { PopopxNodeFeedWire.date(generatedAt) }
}

// MARK: - Decoder

public enum PopopxNodeFeedWire {
    public static let schemaIdentifier = "popopx.discover.feed.v1"

    /// `DiscoverConfig.maximumItems` on the node (DiscoverModels.swift:98): more than this is not a
    /// feed the producer can make, so it is refused instead of silently truncated.
    public static let maximumItems = 60

    /// The same ceiling the mount applies before it asks XFTP for the bytes, and again before it reads
    /// them — kept here so the two ends of one decision cannot drift apart.
    public static let maximumFeedBytes: Int64 = 262_144

    /// `AppPaths.discoverFeedFile` on the node (`MacNodeModels.swift:3174`), and the basename the
    /// bridge puts in the file item (`MacNodePopopxBridge.swift:2504`).
    public static let artifactFileName = "feed.json"

    /// Are these the bytes the node publishes? The exact basename and a size the producer can actually
    /// make — nothing else.
    ///
    /// Split out because the question is asked twice with different surroundings: once before the
    /// download, where the sender's identity still has to be established, and once after it, where a
    /// file that is already on disk is re-measured before anything reads it into memory. Transport
    /// (`FileProtocol`) and sender identity are the caller's half: this layer has no chat model.
    public static func isArtifact(fileName: String, byteCount: Int64) -> Bool {
        fileName == artifactFileName && byteCount > 0 && byteCount <= maximumFeedBytes
    }

    /// The narrow predicate the app mount asks before it downloads a node artifact. It lives here,
    /// beside the byte ceiling it applies, so that "would this have been received at all" is a
    /// question a test can ask instead of one a reviewer has to read an app file to answer.
    ///
    /// `fromBoundNode` is the whole security story: an unbound sender with a perfectly signed feed is
    /// still not a node this phone agreed to listen to. A zero or oversized length is refused too — an
    /// empty file can never be an envelope, and the ceiling is the only thing standing between a
    /// stranger's disk quota and this process's memory.
    public static func shouldAutoReceive(
        fileName: String, byteCount: Int64, alreadyReceived: Bool, fromBoundNode: Bool
    ) -> Bool {
        fromBoundNode && !alreadyReceived && isArtifact(fileName: fileName, byteCount: byteCount)
    }

    /// Every reason this layer can refuse. Kept as a value, not a log line: the caller decides
    /// whether a refusal is silent (an unbound sender, a bad signature) or visible (a key that
    /// changed after pinning), and a count in a console log is not a UI.
    public enum Refusal: String, Equatable, Error, Sendable {
        /// Not a JSON object, or a field that is not the string/array type the producer always writes.
        case malformedJSON
        /// `schema` absent or not `popopx.discover.feed.v1`.
        case schema
        /// `publicKey` absent, empty, not unpadded base64url, or not 32 bytes — `structuralRefusal`
        /// calls the empty case `signature`, but the two are different decisions for the caller.
        case emptyKey
        /// `signature` absent or empty.
        case emptySig
        /// An item is not an object, misses a field, has an empty `id`/`signature`, a `sha256` that
        /// is not 64 characters, or there are more items than the node is allowed to emit.
        case itemShape
        /// `sha256Hex(canonical item body)` is not the digest on the item.
        case itemDigest
        /// An item signature does not verify under the envelope key.
        case itemSignature
        /// The envelope signature does not verify under the envelope key.
        case envelopeSignature
        /// The envelope key differs from the pinned one. Refusing is the whole point: switching
        /// quietly would turn a possible key rotation into a silent accept.
        case keyMismatch
        /// `generatedAt` unreadable, or not strictly newer than the snapshot on file.
        case stale
    }

    public enum Outcome: Equatable, Sendable {
        case accepted(PopopxNodeFeed)
        case refused(Refusal)
    }

    // MARK: Canonical bodies

    /// Item keys, in the order Foundation's `.sortedKeys` emits them. The producer's dictionary
    /// (DiscoverModels.swift:229-236) fixes the set; the order was measured, not assumed.
    static let itemKeys: [String] = [
        "id", "link", "sha256", "signature", "source", "sourceLabel", "summary", "timestamp", "title"
    ]

    /// The seven keys of the item signing body — `sha256` and `signature` are excluded, which is why
    /// the digest of an item can be checked before its signature is believed.
    static let itemBodyKeys = ["id", "link", "source", "sourceLabel", "summary", "timestamp", "title"]

    /// Envelope keys, same measurement. `items` is an array and keeps its wire order.
    static let envelopeBodyKeys = ["generatedAt", "items", "nodeId", "publicKey", "schema"]

    /// The bytes the item's `sha256` and signature are made of.
    public static func canonicalItemBody(_ item: PopopxNodeFeedItem) -> Data {
        var out = Data()
        out.append(ascii("{"))
        for (index, key) in itemBodyKeys.enumerated() {
            if index > 0 { out.append(ascii(",")) }
            out.append(jsonLiteral(key))
            out.append(ascii(":"))
            appendJSONString(item[field: key], to: &out)
        }
        out.append(ascii("}"))
        return out
    }

    /// The bytes the envelope signature is made of: the five keys, with every item present as its
    /// **full nine-key object**, in array order.
    public static func canonicalEnvelopeBody(_ feed: PopopxNodeFeed) -> Data {
        var out = Data()
        out.append(ascii("{"))
        for (index, key) in envelopeBodyKeys.enumerated() {
            if index > 0 { out.append(ascii(",")) }
            out.append(jsonLiteral(key))
            out.append(ascii(":"))
            switch key {
            case "items":
                out.append(ascii("["))
                for (itemIndex, item) in feed.items.enumerated() {
                    if itemIndex > 0 { out.append(ascii(",")) }
                    appendJSONObject(item, to: &out)
                }
                out.append(ascii("]"))
            default:
                appendJSONString(feed[field: key], to: &out)
            }
        }
        out.append(ascii("}"))
        return out
    }

    /// The nine-key form of one item, as it appears **inside** the envelope body.
    private static func appendJSONObject(_ item: PopopxNodeFeedItem, to out: inout Data) {
        out.append(ascii("{"))
        for (index, key) in itemKeys.enumerated() {
            if index > 0 { out.append(ascii(",")) }
            out.append(jsonLiteral(key))
            out.append(ascii(":"))
            appendJSONString(item[field: key], to: &out)
        }
        out.append(ascii("}"))
    }

    // MARK: Escaping

    private static func ascii(_ character: UInt8) -> Data { Data([character]) }
    private static func ascii(_ text: String) -> Data { Data(text.utf8) }

    /// Protocol key names are ASCII, so they need no escaping; spelling that out keeps a future key
    /// with a quote in it from being silently written raw.
    private static func jsonLiteral(_ key: String) -> Data {
        var out = Data([0x22])
        appendEscaped(key, to: &out)
        out.append(0x22)
        return out
    }

    private static func appendJSONString(_ text: String, to out: inout Data) {
        out.append(0x22)
        for scalar in text.unicodeScalars { appendEscaped(String(scalar), to: &out) }
        out.append(0x22)
    }

    private static func appendEscaped(_ text: String, to out: inout Data) {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, 0x62])
            case 0x0C: out.append(contentsOf: [0x5C, 0x66])
            case 0x09: out.append(contentsOf: [0x5C, 0x74])
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])
            case let code where code < 0x20:
                out.append(contentsOf: Array("\\u00\(hexDigit(code >> 4))\(hexDigit(code & 0x0F))".utf8))
            default:
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
    }

    private static func hexDigit(_ nibble: UInt32) -> Character {
        nibble < 10 ? Character(UnicodeScalar(UInt8(0x30 + UInt8(nibble))))
            : Character(UnicodeScalar(UInt8(0x61 + UInt8(nibble - 10))))
    }

    // MARK: Parsing

    /// JSONSerialization hands back `NSString`, `NSNumber` and `NSNull`, and the producer always
    /// writes strings, so a number is a refusal rather than something to describe.
    static func string(_ value: Any?) -> String? { value as? String }

    /// Decodes and structurally checks the envelope. It does not look at a key it was not given, so
    /// it is safe to call on any bytes; everything cryptographic is in `verify`.
    public static func parse(_ data: Data) -> Result<PopopxNodeFeed, Refusal> {
        guard data.count <= maximumFeedBytes else { return .failure(.malformedJSON) }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let envelope = object as? [String: Any]
        else { return .failure(.malformedJSON) }

        guard let schema = string(envelope["schema"]), schema == schemaIdentifier else {
            return .failure(.schema)
        }
        guard let generatedAt = string(envelope["generatedAt"]), let nodeId = string(envelope["nodeId"]),
              let publicKey = string(envelope["publicKey"])
        else { return .failure(.malformedJSON) }
        guard !publicKey.isEmpty, PopopxNodeFeedWire.keyBytes(publicKey) != nil else {
            return .failure(.emptyKey)
        }
        guard let signature = string(envelope["signature"]), !signature.isEmpty else {
            return .failure(.emptySig)
        }
        guard let rawItems = envelope["items"] as? [Any], rawItems.count <= maximumItems else {
            return .failure(.itemShape)
        }
        var items: [PopopxNodeFeedItem] = []
        items.reserveCapacity(rawItems.count)
        for rawItem in rawItems {
            guard let dictionary = rawItem as? [String: Any],
                  let id = string(dictionary["id"]), let title = string(dictionary["title"]),
                  let summary = string(dictionary["summary"]), let source = string(dictionary["source"]),
                  let sourceLabel = string(dictionary["sourceLabel"]), let link = string(dictionary["link"]),
                  let timestamp = string(dictionary["timestamp"]), let sha256 = string(dictionary["sha256"]),
                  let itemSignature = string(dictionary["signature"])
            else { return .failure(.itemShape) }
            // `structuralRefusal` on the node: an empty id or signature, or a digest that is not 64
            // characters, condemns the whole envelope rather than that one item.
            guard !id.isEmpty, !itemSignature.isEmpty, sha256.count == 64 else {
                return .failure(.itemShape)
            }
            items.append(
                PopopxNodeFeedItem(
                    id: id, title: title, summary: summary, source: source, sourceLabel: sourceLabel,
                    link: link, timestamp: timestamp, sha256: sha256, signature: itemSignature
                )
            )
        }
        return .success(
            PopopxNodeFeed(
                schema: schema, generatedAt: generatedAt, nodeId: nodeId, publicKey: publicKey,
                items: items, signature: signature
            )
        )
    }

    // MARK: Verification

    /// The whole acceptance chain, in the order that costs least first. `trustedPublicKey` is the
    /// pinned key, nil when nothing is pinned yet.
    public static func verify(
        _ feed: PopopxNodeFeed, trustedPublicKey: String?, newerThan: Date?
    ) -> Outcome {
        guard trustedPublicKey == nil || trustedPublicKey == feed.publicKey else {
            return .refused(.keyMismatch)
        }
        guard let key = PopopxNodeFeedWire.keyBytes(feed.publicKey) else { return .refused(.emptyKey) }
        for item in feed.items {
            let body = PopopxNodeFeedWire.canonicalItemBody(item)
            guard digestHex(body) == item.sha256.lowercased() else { return .refused(.itemDigest) }
            guard verifySignature(item.signature, body: body, key: key) else {
                return .refused(.itemSignature)
            }
        }
        let envelopeBody = PopopxNodeFeedWire.canonicalEnvelopeBody(feed)
        guard verifySignature(feed.signature, body: envelopeBody, key: key) else {
            return .refused(.envelopeSignature)
        }
        guard let generatedAt = feed.generatedAtDate else { return .refused(.stale) }
        if let newerThan, generatedAt <= newerThan { return .refused(.stale) }
        return .accepted(feed)
    }

    public static func verify(
        data: Data, trustedPublicKey: String?, newerThan: Date?
    ) -> Outcome {
        switch parse(data) {
        case let .failure(refusal): return .refused(refusal)
        case let .success(feed): return verify(feed, trustedPublicKey: trustedPublicKey, newerThan: newerThan)
        }
    }

    // MARK: Folding a feed into stored state

    /// What storing one envelope decided. `state` is the snapshot to persist: on a refusal it is the
    /// previous one, with `keyChangedAtMs` stamped if the refusal was a key change, so the caller has
    /// one thing to write instead of having to remember which refusals are worth remembering.
    public enum FeedApply: Equatable, Sendable {
        case stored(PopopxNodeFeedSnapshot)
        case refused(Refusal, state: PopopxNodeFeedSnapshot?)
    }

    /// The store-side half of the chain: pin on first success (TOFU), refuse a rotated key, refuse a
    /// feed that is not strictly newer. Kept here rather than in the app because all four of those
    /// decisions are testable against the pinned vectors, and a `@MainActor` class in the app target is
    /// not — the app would otherwise be the only place they could disagree with the node.
    public static func ingest(
        _ data: Data, into current: PopopxNodeFeedSnapshot?, now: Date = Date()
    ) -> FeedApply {
        switch verify(data: data, trustedPublicKey: current?.publicKey, newerThan: current?.generatedAtDate) {
        case let .accepted(feed):
            var snapshot = PopopxNodeFeedSnapshot(feed: feed)
            // A warning that is already on record survives a later success. Clearing it here would let
            // whoever changed the key once also erase the evidence by sending a second, correct feed.
            snapshot.keyChangedAtMs = current?.keyChangedAtMs
            return .stored(snapshot)
        case let .refused(reason):
            guard reason == .keyMismatch, var state = current, state.keyChangedAtMs == nil else {
                return .refused(reason, state: current)
            }
            state.keyChangedAtMs = Int64(now.timeIntervalSince1970 * 1_000)
            return .refused(reason, state: state)
        }
    }

    // MARK: Primitives

    /// Unpadded base64url of the raw 32-byte Ed25519 key, the form `publicKeyBase64URL` writes
    /// (MacNodePopopxBridge.swift:556). A padded or standard-alphabet key is refused, not repaired:
    /// two decodings of one string is how two implementations disagree about a key.
    public static func keyBytes(_ text: String) -> Data? {
        guard isUnpaddedBase64URL(text), let raw = Data(base64URL: text), raw.count == 32 else { return nil }
        return raw
    }

    static func verifySignature(_ signature: String, body: Data, key: Data) -> Bool {
        guard isUnpaddedBase64URL(signature), let raw = Data(base64URL: signature),
              let publickey = try? Curve25519.Signing.PublicKey(rawRepresentation: key)
        else { return false }
        return publickey.isValidSignature(raw, for: body)
    }

    static func digestHex(_ body: Data) -> String {
        Data(SHA256.hash(data: body)).map { String(format: "%02x", $0) }.joined()
    }

    static func date(_ text: String) -> Date? {
        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
        if let date = withoutFraction.date(from: text) { return date }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text)
    }

    /// The character class the node's own `base64URL` output can contain, spelled out because
    /// `Data(base64Encoded:)` is lenient about `+/` and padding and that leniency is not the wire.
    private static func isUnpaddedBase64URL(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let alphabet = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard text.unicodeScalars.allSatisfy({ alphabet.contains($0) }) else { return false }
        return text.count % 4 != 1
    }
}

// MARK: - Field lookup
//
// The body builders address fields by the wire key name, so the key sets above are the single place
// a name is written; a key missing here returns "" rather than crashing, and `itemKeys` and the
// producer's own `Codable` are asserted to agree by `PopopxNodeFeedWireTests`.

private extension PopopxNodeFeedItem {
    subscript(field key: String) -> String {
        switch key {
        case "id": return id
        case "title": return title
        case "summary": return summary
        case "source": return source
        case "sourceLabel": return sourceLabel
        case "link": return link
        case "timestamp": return timestamp
        case "sha256": return sha256
        case "signature": return signature
        default: return ""
        }
    }
}

private extension PopopxNodeFeed {
    subscript(field key: String) -> String {
        switch key {
        case "schema": return schema
        case "generatedAt": return generatedAt
        case "nodeId": return nodeId
        case "publicKey": return publicKey
        case "signature": return signature
        default: return ""
        }
    }
}

// MARK: - Base64url

extension Data {
    /// Unpadded base64url, byte-compatible with `TextKit.base64URL` on the node
    /// (MacNodeModels.swift:4044-4049).
    init?(base64URL text: String) {
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: []) else { return nil }
        self = data
    }

    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
