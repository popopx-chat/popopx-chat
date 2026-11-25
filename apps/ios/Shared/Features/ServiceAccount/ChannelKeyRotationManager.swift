//
//  ChannelKeyRotationManager.swift
//  POPOPX (iOS)
//
//  Module 1: the zero-knowledge channel envelope (`popopx.channel.enc.v1`), the per-epoch keys it is sealed with, and the one
//  place on this device allowed to change them.
//
//  ### The three properties this layer is built to hold
//
//  1. **Key material never leaves this device.** It is written to the Keychain with
//     `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (PopopxEcoKeychain, PopopxEcoModels.swift:858) and never into a file, a
//     default container, or `UserDefaults`. The `#key=…&pub=…` fragment of a public channel URI is stripped before any part of
//     that string is handed onward — `PopopxChannelPublicURI.connectionURI` is the only spelling the connection path may see.
//  2. **A frame cannot claim a channel or an epoch it was not sealed for.** The envelope's `signature` is checked against the
//    channel's Ed25519 identity key *before* decryption is even attempted, and the ChaChaPoly additional-authenticated-data
//    carries `protocol ‖ channelId ‖ epoch ‖ identity key`, so ciphertext copied between channels or between epochs fails the
//    authentication tag rather than decrypting into somebody else's plaintext.
//  3. **Nothing here invents a key.** A member device holds the channel's *public* identity key only; minting an epoch key locally
//     would produce a key the server does not hold, which reads on the wire as "the channel went silent". So the only way a new
//    epoch enters this device is a signed `channel_key_update` frame, and the UI's rotate button sends a *request* through the
//     existing send chain instead of pretending to be the issuer. That is a deliberate narrowing of the brief's
//     "一键触发新密钥轮换", recorded in the acceptance report.
//
//  ### Where this deviates from the brief, and why
//
//  - The brief signs "epoch + nonce + ciphertext 字节拼接". A bare concatenation is ambiguous across epochs: epoch `1` followed by
//    a nonce whose first byte is ASCII `1`… is the same byte string as epoch `11` followed by a shorter nonce. `signingPreimage`
//    therefore prefixes the protocol name and separates the three parts with `|`, and the same rule is applied on both sides of
//    the seam (and pinned by `PopopxEcoChannelKeyTests.testSigningPreimageIsNotAmbiguousAcrossEpochs`).
//  - The brief also mandates the AAD be "channelId + epoch", but its own envelope JSON carries **no channel id at all**. The id
//    comes from the frame around the envelope (`PopopxChannelKeyUpdate.channelId`), and an envelope without an explicit id could
//    only be checked by trying every stored epoch of every channel — sound for one channel, a brute-force oracle for two.
//  - `ChannelAccessToken` does not exist in this checkout; the channel credential is `PopopxChannelSubscriptionTicket`
//    (PopopxBadgeCreditsModels.swift:1265). "同步签发/更新" is implemented as the check that can be done honestly from this side:
//    a rotation that hands over a **new identity key** is refused when this device already paid under a different one
//    (`PopopxCreditsManager.channelIssuerConflict`, PopopxCreditsManager.swift:524). Re-issuing the ticket itself is not done
//    here: `subscribeToChannel` debits compute credits, so a rotation that "re-issued" it would be a second charge.
//

import CryptoKit
import Foundation
import Security

// MARK: - Limits

extension PopopxEcoLimits {
    /// Stored epochs per channel. Thirty covers a daily rotation for a month with room to spare; past that the oldest surviving
    /// epoch is dropped, because "read a message from six months ago" is not a promise this module makes.
    static let maximumStoredEpochs = 30
    /// Envelope ciphertext, in bytes. A channel post is a few kilobytes; one megabyte would be an attachment wearing a card's
    /// clothes, and attachments have their own (encrypted, chunked) path.
    static let maximumCiphertextBytes = 512 * 1_024
    static let maximumPlaintextBytes = 512 * 1_024
    /// The rotation-warning window, in days.
    static let minimumExpiryWarningDays = 1
    static let maximumExpiryWarningDays = 90
    static let defaultExpiryWarningDays = 7
    /// Epoch numbers are ints on the wire; past one million a server has a different problem than this client can help with.
    static let maximumEpoch = 1_000_000
}

// MARK: - Envelope

/// `popopx.channel.enc.v1` — one ChaCha20-Poly1305 box, signed by the channel's Ed25519 identity key.
///
/// Wire form, verbatim from the brief:
/// ```json
/// {"protocol":"popopx.channel.enc.v1","epoch":1,"nonce":"<base64 12B>","ciphertext":"<base64>","signature":"<base64>"}
/// ```
/// `nonce`, `ciphertext` and `signature` are **standard padded base64** (not the base64url of the payload URIs): the brief spells
/// them `<Base64_…>`, and this JSON travels inside a frame where `+` and `/` need no escaping anyway. Lenient decoding of both
/// alphabets is implemented so a peer built to the other reading is still readable — a one-character alphabet disagreement should
/// not look like "the channel is empty".
struct PopopxChannelEnvelope: Codable, Hashable, Sendable {
    static let protocolName = "popopx.channel.enc.v1"
    /// ChaChaPoly's nonce is exactly 12 bytes; the cap is not a limit, it is the definition.
    static let nonceBytes = 12
    /// The Poly1305 tag, appended to the ciphertext on the wire.
    static let tagBytes = 16
    static let signatureBytes = 64
    static let identityKeyBytes = 32
    static let epochKeyBytes = 32

    var epoch: Int
    var nonce: Data
    /// The `SealedBox.combined` form: 16-byte Poly1305 tag followed by the ciphertext.
    var ciphertext: Data
    /// Raw 64-byte Ed25519 signature.
    var signature: Data

    private enum CodingKeys: String, CodingKey {
        case proto = "protocol"
        case epoch
        case nonce
        case ciphertext
        case signature
    }

    init(epoch: Int, nonce: Data, ciphertext: Data, signature: Data) {
        self.epoch = epoch
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.signature = signature
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let proto = try container.decode(String.self, forKey: .proto)
        guard proto == Self.protocolName else { throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.proto], debugDescription: "unknown protocol")) }
        epoch = try container.decode(Int.self, forKey: .epoch)
        nonce = try Self.decodeBase64(container.decode(String.self, forKey: .nonce), exactly: Self.nonceBytes)
        ciphertext = try Self.decodeBase64(container.decode(String.self, forKey: .ciphertext), upTo: PopopxEcoLimits.maximumCiphertextBytes)
        signature = try Self.decodeBase64(container.decode(String.self, forKey: .signature), exactly: Self.signatureBytes)
    }

    /// Encoding is the exact mirror of `init(from:)`: the same protocol name, the same standard base64, no extra fields.
    ///
    /// It is written by hand rather than left to the synthesised conformance because the synthesised form would encode `nonce` as
    /// `[UInt8]`, which is a different document from `"<Base64_12字节Nonce>"` and would be read by the server as a corrupt envelope.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.protocolName, forKey: .proto)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(PopopxChannelBase64.encode(nonce), forKey: .nonce)
        try container.encode(PopopxChannelBase64.encode(ciphertext), forKey: .ciphertext)
        try container.encode(PopopxChannelBase64.encode(signature), forKey: .signature)
    }

    /// The AAD: everything the box must be bound to that is *outside* the box.
    ///
    /// The identity key is in here on purpose. Without it, an attacker who holds a stolen epoch key from channel A could seal a
    /// payload that decrypts cleanly under the same-numbered epoch of channel B (identical key numbers are not unlikely once two
    /// channels are generated by the same sloppy RNG); with it, the tag fails.
    func authenticationData(channelId: String, identityKey: Data) -> Data {
        var data = Data(Self.protocolName.utf8)
        data.append(0x7C)
        data.append(Data(channelId.utf8))
        data.append(0x7C)
        data.append(Data(String(epoch).utf8))
        data.append(0x7C)
        data.append(identityKey)
        return data
    }

    /// The signed byte string. See the header: a separator is what makes `epoch ‖ nonce` unambiguous.
    func signingPreimage(channelId: String) -> Data {
        var data = Data(Self.protocolName.utf8)
        data.append(0x7C)
        data.append(Data(channelId.utf8))
        data.append(0x7C)
        data.append(Data(String(epoch).utf8))
        data.append(0x7C)
        data.append(nonce)
        data.append(0x7C)
        data.append(ciphertext)
        return data
    }

    var isSane: Bool {
        (1...PopopxEcoLimits.maximumEpoch).contains(epoch)
            && nonce.count == Self.nonceBytes
            && !ciphertext.isEmpty
            && ciphertext.count <= PopopxEcoLimits.maximumCiphertextBytes
            && signature.count == Self.signatureBytes
    }

    // MARK: Sealing (the issuer side, and the unit tests)

    /// Encrypt and sign. `identityKey` is the **private** Ed25519 key; this call exists so the protocol can be exercised in both
    /// directions by the test target without a server. Nothing on the member's side ever holds a private channel key.
    static func seal(
        plaintext: Data,
        epoch: Int,
        channelId: String,
        epochKey: Data,
        identityPrivateKey: Curve25519.Signing.PrivateKey
    ) -> PopopxChannelEnvelope? {
        guard (1...PopopxEcoLimits.maximumEpoch).contains(epoch),
              epochKey.count == epochKeyBytes,
              plaintext.count <= PopopxEcoLimits.maximumPlaintextBytes
        else { return nil }
        // `ChaChaPoly.Nonce()` is the SDK's own 96-bit CSPRNG draw, so this path has no hand-rolled randomness to get wrong.
        let nonce = ChaChaPoly.Nonce()
        var envelope = PopopxChannelEnvelope(epoch: epoch, nonce: Data(), ciphertext: Data(), signature: Data())
        envelope.nonce = nonce.withUnsafeBytes { Data($0) }
        guard envelope.nonce.count == Self.nonceBytes else { return nil }
        // The AAD is assembled from the envelope's *outside* values only, so the one `authenticationData` implementation feeds both
        // halves of the protocol: `ciphertext` and `signature` play no part in it.
        let identityPublic = identityPrivateKey.publicKey.rawRepresentation
        guard let box = try? ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: epochKey),
            nonce: nonce,
            authenticating: envelope.authenticationData(channelId: channelId, identityKey: identityPublic)
        ) else { return nil }
        // `ciphertext` on the wire is ct ‖ tag, the conventional ChaCha20-Poly1305 spelling: `SealedBox.combined` cannot be used
        // because it also carries the nonce, and this envelope already has a `nonce` field of its own.
        envelope.ciphertext = box.ciphertext + box.tag
        guard let signature = try? identityPrivateKey.signature(for: envelope.signingPreimage(channelId: channelId)) else {
            return nil
        }
        envelope.signature = Data(signature)
        return envelope
    }

    /// Open: verify, then decrypt. Both failure modes collapse into nil at this entry point, because a caller with no channel state
    /// to reason about has only one honest answer. `ChannelKeyRotationManager.apply` uses `verify` + `decrypt` separately, so the key
    /// page can say which of the two refused a frame.
    static func open(
        _ envelope: PopopxChannelEnvelope,
        channelId: String,
        epochKey: Data,
        identityPublicKey: Data
    ) -> Data? {
        guard envelope.verified(channelId: channelId, identityPublicKey: identityPublicKey) else { return nil }
        return envelope.decrypt(channelId: channelId, epochKey: epochKey, identityPublicKey: identityPublicKey)
    }

    /// The Ed25519 check of this envelope's own signature against a channel's identity key.
    /// Malformed key or signature material answers `false`, never a trap.
    func verified(channelId: String, identityPublicKey: Data) -> Bool {
        PopopxChannelCrypto.verify(
            signature: signature,
            preimage: signingPreimage(channelId: channelId),
            publicKey: identityPublicKey
        )
    }

    /// The AEAD opening. The AAD is rebuilt from the caller's channel id rather than trusted from the frame, which is what makes a
    /// box copied between channels or between epochs fail its tag instead of decrypting into somebody else's plaintext.
    ///
    /// `SealedBox(combined:)` is deliberately not used: ChaChaPoly's combined form carries the nonce *inside* it, and this envelope
    /// keeps `nonce` as its own field, so the box is re-assembled from `ciphertext` = ct ‖ tag.
    func decrypt(channelId: String, epochKey: Data, identityPublicKey: Data) -> Data? {
        guard isSane,
              epochKey.count == Self.epochKeyBytes,
              identityPublicKey.count == Self.identityKeyBytes,
              ciphertext.count > Self.tagBytes,
              let sealNonce = try? ChaChaPoly.Nonce(data: nonce),
              let box = try? ChaChaPoly.SealedBox(
                nonce: sealNonce,
                ciphertext: ciphertext.dropLast(Self.tagBytes),
                tag: ciphertext.suffix(Self.tagBytes)
              )
        else { return nil }
        return try? ChaChaPoly.open(
            box,
            using: SymmetricKey(data: epochKey),
            authenticating: authenticationData(channelId: channelId, identityKey: identityPublicKey)
        )
    }

    static func decodeBase64(_ text: String, exactly count: Int) throws -> Data {
        let data = try decodeBase64(text, upTo: count)
        guard data.count == count else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "wrong length"))
        }
        return data
    }

    static func decodeBase64(_ text: String, upTo limit: Int) throws -> Data {
        guard let data = PopopxChannelBase64.decode(text), data.count <= limit else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not base64 or too long"))
        }
        return data
    }
}

/// Base64 that accepts both alphabets.
///
/// Why not `Data(base64Encoded:)` alone: that call rejects `-` and `_`, so a peer that spells the envelope with the base64url the
/// rest of this app uses would be silently unreadable. Why not `Data(popopxBase64URL:)` alone: it rejects `+`, `/` and `=`, so the
/// brief's own `<Base64_…>` spelling would be unreadable. Accepting both costs nothing here because these values are never split
/// on a delimiter — they live inside JSON strings, not inside a query.
enum PopopxChannelBase64 {
    static func encode(_ data: Data) -> String { data.base64EncodedString() }

    static func decode(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = Data(base64Encoded: trimmed) { return data }
        return Data(popopxBase64URL: trimmed)
    }
}

// MARK: - Crypto seam

/// The verification primitive, one call away from being replaced.
///
/// Ed25519 is new to this app: the commerce family signs with ECDSA P-256 (`PopopxCommerceSignature`,
/// PopopxBadgeCreditsModels.swift:1449), because that key already exists for the app's own business signing. A channel identity key
/// is a different key with a different holder, so it gets its own algorithm rather than being squeezed into the P-256 key that
/// happens to be on the device.
enum PopopxChannelCrypto {
    /// Verify a raw 64-byte Ed25519 signature over `preimage` with a raw 32-byte public key.
    ///
    /// `false` for any malformed input, including a 33-byte key: the caller has already decided that a bad key means a bad frame,
    /// and an exception would only move that decision somewhere less obvious.
    static func verify(signature: Data, preimage: Data, publicKey: Data) -> Bool {
        guard signature.count == PopopxChannelEnvelope.signatureBytes,
              publicKey.count == PopopxChannelEnvelope.identityKeyBytes,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        else { return false }
        return key.isValidSignature(signature, for: preimage)
    }

    /// Generate an identity key pair — for the tests, and for a future issuer-side build. Nothing in the member app calls it.
    static func makeIdentityKey() -> Curve25519.Signing.PrivateKey { Curve25519.Signing.PrivateKey() }

    /// 32 bytes of epoch key from the system CSPRNG.
    static func makeEpochKey() -> Data { PopopxChannelRandom.bytes(PopopxChannelEnvelope.epochKeyBytes) }
}

/// The one random-byte source of this module.
///
/// `SecRandomCopyBytes` rather than `Int.random`/`UInt64.random`: those are seeded per-process and are not a key-generation
/// primitive, and an epoch key must be unpredictable to somebody who can watch this device. A failure of the system call yields an
/// empty `Data`, which every caller below rejects by length — a short key is never used, and never silently padded.
enum PopopxChannelRandom {
    static func bytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        return status == errSecSuccess ? data : Data()
    }
}

// MARK: - Key update frame

/// The `channel_key_update` frame: a channel id, a revocation flag, and the sealed envelope that carries the new key.
///
/// Wire form:
/// ```json
/// {"t":"ku","update":{"ch":"<channelId>","rp":true,"env":{ …popopx.channel.enc.v1… }}}
/// ```
///
/// ### Why the new key is inside an envelope rather than a field
/// The epoch key is the secret that keeps a channel zero-knowledge *from the relay*. A plaintext `key=` field would be readable by
/// every server that carries the message, which contradicts the one property the brief names as the point of the whole exercise.
/// Sealing it under the epoch key this frame is replacing means only a member that already holds the current key can read the next
/// one — and that is exactly the "forward secrecy across epochs" a rotation is supposed to buy.
struct PopopxChannelKeyUpdate: Codable, Hashable, Sendable {
    var channelId: String
    /// The epoch the envelope is sealed under — the channel's *current* key, not the new one.
    var sealedUnderEpoch: Int
    /// When true, every epoch older than the new one is revoked on this device.
    var revokePrevious: Bool
    var envelope: PopopxChannelEnvelope

    private enum CodingKeys: String, CodingKey {
        case channelId = "ch"
        case sealedUnderEpoch = "se"
        case revokePrevious = "rp"
        case envelope = "env"
    }

    init(channelId: String, sealedUnderEpoch: Int, revokePrevious: Bool, envelope: PopopxChannelEnvelope) {
        self.channelId = channelId
        self.sealedUnderEpoch = sealedUnderEpoch
        self.revokePrevious = revokePrevious
        self.envelope = envelope
    }

    var isSane: Bool {
        !channelId.isEmpty
            && channelId.count <= PopopxEcoLimits.maximumPayloadCharacters
            && (1...PopopxEcoLimits.maximumEpoch).contains(sealedUnderEpoch)
            && envelope.isSane
            // The two epoch numbers must be able to mean something different, or the frame is asking to decrypt itself with the
            // key it is replacing. A server that omits `se` is not supported: the field is what makes replay detection possible.
            && envelope.epoch != sealedUnderEpoch
    }
}

/// The plaintext of a rotation envelope.
///
/// Deliberately *not* the frame itself: this is what sits inside the box, and it is the only place the new key appears.
struct PopopxChannelEpochSecret: Codable, Hashable, Sendable {
    var epoch: Int
    /// base64url, 32 bytes. The payload URIs' alphabet is used here because this JSON is opaque on the wire and never parsed by
    /// anything but this file, so the stricter decoding rule (no unknown characters, PopopxSecurePayload.swift:415) is free.
    var keyBase64URL: String
    /// Optional identity-key handover. Present only when the channel is rotating who it is, which is the one case that has to be
    /// checked against the credential this device paid for — see the header.
    var publicKeyBase64URL: String?
    /// Expiry of this epoch, in milliseconds. Absent means "no expiry is promised", which the schedule renders as 无.
    var expiresAtMs: Int64?

    var isSane: Bool {
        (1...PopopxEcoLimits.maximumEpoch).contains(epoch)
            && (Data(popopxBase64URL: keyBase64URL)?.count == PopopxChannelEnvelope.epochKeyBytes)
            && (publicKeyBase64URL == nil
                || Data(popopxBase64URL: publicKeyBase64URL!)?.count == PopopxChannelEnvelope.identityKeyBytes)
            && (expiresAtMs == nil || expiresAtMs! > 0)
    }
}

// MARK: - Stored state

/// One stored epoch of one channel.
struct PopopxChannelEpoch: Codable, Hashable, Identifiable, Sendable {
    var epoch: Int
    var keyBase64URL: String
    var createdAtMs: Int64
    var expiresAtMs: Int64?
    var revoked: Bool

    var id: Int { epoch }

    var keyData: Data? { Data(popopxBase64URL: keyBase64URL) }

    /// Whether this key may be used to open a frame right now.
    var isUsable: Bool {
        !revoked && (expiresAtMs == nil || expiresAtMs! > Int64(Date.now.timeIntervalSince1970 * 1_000))
    }
}

/// Everything this device knows about one channel.
struct PopopxChannelKeyState: Codable, Hashable, Identifiable, Sendable {
    var channelId: String
    /// The Ed25519 trust root, base64url. Written from the public URI's `pub` and replaced only by a signed handover.
    var identityKeyBase64URL: String
    /// The epoch frames are sealed under — what `open` needs as the symmetric key.
    var epochs: [PopopxChannelEpoch]
    /// The epoch a member should try first, kept explicit rather than "highest number wins": a revoked newest epoch must still be
    /// skipped without re-deriving the answer from the array every time.
    var currentEpoch: Int
    var addedAtMs: Int64
    /// Where the URI said the relay is. Display and connection only; it is never part of a key or a signature.
    var relay: String?
    /// The service account that last sent a key frame for this channel, as a local contact id.
    ///
    /// Recorded because a rotation request has to be *addressed to somebody*: the client cannot mint an epoch key, so the only honest
    /// "rotate" action is to ask the account that issued the previous one. It is a local row number, not an identity, which is why the
    /// request path treats it as "the conversation to send into" and never as a credential, and why a channel imported from a URI
    /// alone has `nil` here until an update frame actually lands.
    var issuerContactId: Int64? = nil

    var id: String { channelId }

    var identityKeyData: Data? { Data(popopxBase64URL: identityKeyBase64URL) }

    var currentKey: PopopxChannelEpoch? {
        epochs.first { $0.epoch == currentEpoch && $0.isUsable }
    }

    /// Newest usable epoch, which is what "the key a new frame should seal under" means on the issuer side.
    var newestUsableKey: PopopxChannelEpoch? {
        epochs.filter(\.isUsable).max(by: { $0.epoch < $1.epoch })
    }
}

// MARK: - Result

/// Why a rotation did or did not land. The reasons are separate values rather than one "failed" because the UI must be able to say
/// which of them the user can act on: `unknownChannel` has a fix (open the channel link), `signatureInvalid` is an attack or a bug.
enum PopopxKeyRotationResult: Hashable, Sendable {
    case installed(epoch: Int, revoked: [Int])
    /// A frame for an epoch this device already holds — a re-send, not a rotation.
    case alreadyCurrent(epoch: Int)
    case rejected(PopopxKeyRejection)
}

enum PopopxKeyRejection: String, Hashable, Sendable {
    /// No identity key for that channel on this device, so nothing to verify against and nothing to decrypt with.
    case unknownChannel
    case signatureInvalid
    case decryptFailed
    /// `sealedUnderEpoch` does not match any usable key here.
    case unknownSealedEpoch
    /// The new epoch is not newer than what is stored, so accepting it would be a replay.
    case epochNotNewer
    /// The envelope decrypted into bytes that are not a well-formed epoch secret.
    case malformedPayload
    /// A handover to a different identity key while this device holds a paid credential pinned to another one.
    case issuerConflict
    /// The frame or the plaintext broke a limit.
    case outOfRange
}

// MARK: - Manager

/// The owner of the channel key store.
///
/// `@MainActor` because every caller is a view or an inbound message handler, and because the Keychain calls here are microseconds
/// of work against a store that this app already touches from the main actor in the commerce module. Keeping the actor hops out of
/// this type is also what lets a card button read the current epoch synchronously, in the same render pass it paints the label.
@MainActor
@Observable
final class ChannelKeyRotationManager {
    static let shared = ChannelKeyRotationManager()

    /// The channels this device holds keys for, ordered by the moment they were added so the list does not reshuffle under a tap.
    private(set) var channels: [PopopxChannelKeyState] = []

    /// How long before an epoch expires the key page starts saying so. Persisted, because it is a user preference, not a constant.
    private(set) var expiryWarningDays: Int = PopopxEcoLimits.defaultExpiryWarningDays {
        didSet {
            guard expiryWarningDays != oldValue else { return }
            let clamped = min(max(expiryWarningDays, PopopxEcoLimits.minimumExpiryWarningDays), PopopxEcoLimits.maximumExpiryWarningDays)
            if clamped != expiryWarningDays {
                // A `didSet` that corrects itself re-enters `didSet`; the clamp guard above is what stops that from looping, and the
                // value is written once to storage either way.
                expiryWarningDays = clamped
                return
            }
            defaults.set(clamped, forKey: PopopxEcoKeys.expiryWarningDays)
        }
    }

    private let defaults: UserDefaults
    private let verifier: (Data, Data, Data) -> Bool
    private var loaded = false

    /// `verifier` is a parameter rather than a call to `PopopxChannelCrypto.verify` inside the body so that a test can prove the
    /// manager *rejects* a bad signature without a test-only keypair and without a mutable global.
    init(defaults: UserDefaults = .standard, verifier: @escaping (Data, Data, Data) -> Bool = PopopxChannelCrypto.verify) {
        self.defaults = defaults
        self.verifier = verifier
    }

    // MARK: Loading

    /// Read the store. Idempotent, and called from the views' `task` rather than from `init`: a Keychain read at process start
    /// would run before the app knows whether it is in a locked state, and `…WhenUnlocked…` items are then simply absent, which is
    /// indistinguishable from "the user has no channels".
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        expiryWarningDays = defaults.integer(forKey: PopopxEcoKeys.expiryWarningDays)
        if expiryWarningDays < PopopxEcoLimits.minimumExpiryWarningDays {
            // `integer(forKey:)` on an unset key is 0, which is below the floor and not a user choice.
            expiryWarningDays = PopopxEcoLimits.defaultExpiryWarningDays
        }
        let stored = PopopxEcoCodec.decode([PopopxChannelKeyState].self, from: defaults.data(forKey: PopopxEcoKeys.channelIndex)) ?? []
        channels = stored.compactMap { state in
            guard !state.channelId.isEmpty,
                  state.identityKeyData != nil,
                  state.epochs.count <= PopopxEcoLimits.maximumStoredEpochs,
                  state.epochs.allSatisfy({ $0.epoch >= 1 && $0.epoch <= PopopxEcoLimits.maximumEpoch })
            else { return nil }
            // The epoch *keys* live in the Keychain; the index carries only their metadata, so a row whose secret is gone is a row
            // that cannot decrypt anything and must not be offered as "active".
            var state = state
            // Read into locals first: `state.epochs = state.epochs.compactMap { … state.channelId … }` would be an overlapping
            // access of one struct through the exclusivity rule, and the closure's capture of `state` is the part that trips it.
            let channelId = state.channelId
            let storedEpochs = state.epochs
            state.epochs = storedEpochs.compactMap { epoch in
                guard let key = PopopxEcoKeychain.read(PopopxEcoKeychain.epochAccount(channelId: channelId, epoch: epoch.epoch)),
                      key.count == PopopxChannelEnvelope.epochKeyBytes
                else { return nil }
                var epoch = epoch
                epoch.keyBase64URL = key.popopxBase64URL
                return epoch
            }
            guard !state.epochs.isEmpty else { return nil }
            if state.epochs.first(where: { $0.epoch == state.currentEpoch }) == nil {
                state.currentEpoch = state.epochs.map(\.epoch).max() ?? state.currentEpoch
            }
            return state
        }
    }

    // MARK: Import

    /// Store the key material of a public channel URI. Returns false when the URI is unreadable or the write failed.
    ///
    /// Re-importing the same channel id with the **same** key is a no-op that still returns true (a link tapped twice is not an
    /// error); with a *different* identity key it is refused unless this device holds no paid credential for that channel —
    /// otherwise a second channel owner could take over a subscription paid to the first.
    @discardableResult
    func importPublicURI(_ text: String) -> Bool {
        loadIfNeeded()
        guard let uri = PopopxChannelPublicURI.parse(text),
              let key = Data(popopxBase64URL: uri.masterKeyBase64URL),
              let pub = Data(popopxBase64URL: uri.issuerPublicKeyBase64URL)
        else { return false }

        if let existing = channel(uri.channelId) {
            guard existing.identityKeyBase64URL == uri.issuerPublicKeyBase64URL else {
                return PopopxCreditsManager.shared.channelIssuerConflict(
                    channelId: uri.channelId,
                    issuerPublicKeyBase64URL: uri.issuerPublicKeyBase64URL
                ) == false && PopopxCreditsManager.shared.ticket(forChannelId: uri.channelId) == nil
            }
            return true
        }

        guard PopopxEcoKeychain.write(key, account: PopopxEcoKeychain.epochAccount(channelId: uri.channelId, epoch: 1)),
              PopopxEcoKeychain.write(pub, account: PopopxEcoKeychain.channelAccount(uri.channelId)),
              PopopxEcoKeychain.write(Data("\(1)".utf8), account: PopopxEcoKeychain.currentEpochAccount(channelId: uri.channelId))
        else { return false }

        let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
        let state = PopopxChannelKeyState(
            channelId: uri.channelId,
            identityKeyBase64URL: uri.issuerPublicKeyBase64URL,
            epochs: [PopopxChannelEpoch(epoch: 1, keyBase64URL: uri.masterKeyBase64URL, createdAtMs: nowMs, expiresAtMs: nil, revoked: false)],
            currentEpoch: 1,
            addedAtMs: nowMs,
            relay: uri.relay
        )
        channels.append(state)
        save()
        return true
    }

    // MARK: Rotation

    /// Apply a `channel_key_update` frame.
    ///
    /// The order is the security order and it is not negotiable: find the channel, verify the signature against the stored identity
    /// key, *then* decrypt, *then* check the plaintext's epoch is newer. Verifying first is what stops an attacker who cannot break
    /// ChaCha-Poly1305 from learning anything by probing (a decrypt-then-verify order turns the decryption into an oracle), and the
    /// "newer" test last is what turns a recorded, re-sent frame into a no-op rather than a rollback.
    /// - Parameter issuerContactId: the conversation this frame arrived in, passed through from `PopopxEcoStore.apply` so a later
    ///   rotation request has something to be addressed to. `nil` (a frame with no known conversation, or a test) leaves whatever was
    ///   recorded before it alone rather than clearing it.
    func apply(_ update: PopopxChannelKeyUpdate, issuerContactId: Int64? = nil) -> PopopxKeyRotationResult {
        loadIfNeeded()
        guard update.isSane else { return .rejected(.outOfRange) }
        guard let state = channel(update.channelId), let identityKey = state.identityKeyData else {
            return .rejected(.unknownChannel)
        }
        guard verifier(update.envelope.signature, update.envelope.signingPreimage(channelId: update.channelId), identityKey) else {
            return .rejected(.signatureInvalid)
        }
        guard let sealed = state.epochs.first(where: { $0.epoch == update.sealedUnderEpoch }),
              sealed.isUsable,
              let sealedKey = sealed.keyData,
              sealedKey.count == PopopxChannelEnvelope.epochKeyBytes
        else { return .rejected(.unknownSealedEpoch) }
        guard let plaintext = update.envelope.decrypt(
            channelId: update.channelId,
            epochKey: sealedKey,
            identityPublicKey: identityKey
        ) else { return .rejected(.decryptFailed) }
        guard let secret = PopopxEcoCodec.decode(PopopxChannelEpochSecret.self, from: plaintext), secret.isSane else {
            return .rejected(.malformedPayload)
        }
        guard secret.epoch > state.currentEpoch, secret.epoch > sealed.epoch else {
            if secret.epoch == state.currentEpoch {
                // A re-send still tells this device who the issuer is, which is the one fact worth keeping from it.
                if let issuerContactId, let index = channels.firstIndex(where: { $0.channelId == state.channelId }),
                   channels[index].issuerContactId != issuerContactId {
                    channels[index].issuerContactId = issuerContactId
                    save()
                }
                return .alreadyCurrent(epoch: secret.epoch)
            }
            return .rejected(.epochNotNewer)
        }
        guard secret.epoch <= PopopxEcoLimits.maximumEpoch else { return .rejected(.outOfRange) }

        // Identity-key handover: the envelope is signed by the *old* key, which is a legitimate handover, but this device may have
        // paid a credential pinned to that old key. Refusing the handover keeps the paid credential meaningful.
        if let newPub = secret.publicKeyBase64URL, newPub != state.identityKeyBase64URL {
            if PopopxCreditsManager.shared.channelIssuerConflict(channelId: state.channelId, issuerPublicKeyBase64URL: newPub) {
                return .rejected(.issuerConflict)
            }
        }

        guard let newKey = Data(popopxBase64URL: secret.keyBase64URL) else { return .rejected(.malformedPayload) }
        var revoked: [Int] = []
        var next = state
        if update.revokePrevious {
            for index in next.epochs.indices where next.epochs[index].epoch != secret.epoch && !next.epochs[index].revoked {
                next.epochs[index].revoked = true
                revoked.append(next.epochs[index].epoch)
            }
        }
        next.epochs.removeAll { $0.epoch == secret.epoch }
        next.epochs.append(
            PopopxChannelEpoch(
                epoch: secret.epoch,
                keyBase64URL: secret.keyBase64URL,
                createdAtMs: Int64(Date.now.timeIntervalSince1970 * 1_000),
                expiresAtMs: secret.expiresAtMs,
                revoked: false
            )
        )
        next.currentEpoch = secret.epoch
        next.issuerContactId = issuerContactId ?? state.issuerContactId
        if let newPub = secret.publicKeyBase64URL { next.identityKeyBase64URL = newPub }
        // Bounded history, oldest surviving entry dropped first: `maximumStoredEpochs` is a cap on the *stored* set, and a revoked
        // epoch is the least useful one to keep.
        if next.epochs.count > PopopxEcoLimits.maximumStoredEpochs {
            next.epochs.sort { $0.epoch < $1.epoch }
            next.epochs.removeFirst(next.epochs.count - PopopxEcoLimits.maximumStoredEpochs)
        }

        guard PopopxEcoKeychain.write(newKey, account: PopopxEcoKeychain.epochAccount(channelId: next.channelId, epoch: secret.epoch)),
              PopopxEcoKeychain.write(Data("\(secret.epoch)".utf8), account: PopopxEcoKeychain.currentEpochAccount(channelId: next.channelId))
        else { return .rejected(.decryptFailed) }
        if let newPub = secret.publicKeyBase64URL, let pub = Data(popopxBase64URL: newPub) {
            PopopxEcoKeychain.write(pub, account: PopopxEcoKeychain.channelAccount(next.channelId))
        }
        for epoch in revoked {
            PopopxEcoKeychain.remove(PopopxEcoKeychain.epochAccount(channelId: next.channelId, epoch: epoch))
        }

        if let index = channels.firstIndex(where: { $0.channelId == next.channelId }) {
            channels[index] = next
        } else {
            channels.append(next)
        }
        save()
        return .installed(epoch: secret.epoch, revoked: revoked)
    }

    /// Seal a rotation frame — the issuer side of the protocol.
    ///
    /// Exposed for the tests and for a future build that hosts a channel; a member device has no identity private key, so nothing in
    /// the app path can reach it. Keeping it here rather than in a test file means the encoding rule exists once and is exercised by
    /// `apply`, which is the only proof that the two halves really agree.
    static func makeUpdate(
        channelId: String,
        identityPrivateKey: Curve25519.Signing.PrivateKey,
        currentEpoch: Int,
        currentKey: Data,
        newEpoch: Int,
        newKey: Data,
        newIdentityPublicKey: Data? = nil,
        expiresAtMs: Int64? = nil,
        revokePrevious: Bool = false
    ) -> PopopxChannelKeyUpdate? {
        guard newKey.count == PopopxChannelEnvelope.epochKeyBytes,
              let plaintext = PopopxEcoCodec.encode(
                PopopxChannelEpochSecret(
                    epoch: newEpoch,
                    keyBase64URL: newKey.popopxBase64URL,
                    publicKeyBase64URL: newIdentityPublicKey?.popopxBase64URL,
                    expiresAtMs: expiresAtMs
                )
              ),
              let envelope = PopopxChannelEnvelope.seal(
                plaintext: plaintext,
                epoch: newEpoch,
                channelId: channelId,
                epochKey: currentKey,
                identityPrivateKey: identityPrivateKey
              )
        else { return nil }
        return PopopxChannelKeyUpdate(
            channelId: channelId,
            sealedUnderEpoch: currentEpoch,
            revokePrevious: revokePrevious,
            envelope: envelope
        )
    }

    // MARK: Revocation

    /// Revoke one epoch by hand (the key page's per-row action).
    ///
    /// The newest usable epoch is protected: revoking it would leave the channel with no key at all, and the honest result of that is
    /// a permanently unreadable channel rather than a useful "revoked" state. A user who really wants that effect has the delete
    /// action on the whole channel.
    @discardableResult
    func revoke(channelId: String, epoch: Int) -> Bool {
        loadIfNeeded()
        guard let index = channels.firstIndex(where: { $0.channelId == channelId }),
              let epochIndex = channels[index].epochs.firstIndex(where: { $0.epoch == epoch }),
              channels[index].currentEpoch != epoch,
              !channels[index].epochs[epochIndex].revoked
        else { return false }
        channels[index].epochs[epochIndex].revoked = true
        PopopxEcoKeychain.remove(PopopxEcoKeychain.epochAccount(channelId: channelId, epoch: epoch))
        save()
        return true
    }

    /// Forget a channel entirely: its identity key, every epoch key, and the index row. Used by the key page and by the same
    /// "clear my data" path that wipes the commerce keychain.
    func removeChannel(_ channelId: String) {
        loadIfNeeded()
        guard let index = channels.firstIndex(where: { $0.channelId == channelId }) else { return }
        for epoch in channels[index].epochs {
            PopopxEcoKeychain.remove(PopopxEcoKeychain.epochAccount(channelId: channelId, epoch: epoch.epoch))
        }
        PopopxEcoKeychain.remove(PopopxEcoKeychain.channelAccount(channelId))
        PopopxEcoKeychain.remove(PopopxEcoKeychain.currentEpochAccount(channelId: channelId))
        channels.remove(at: index)
        save()
    }

    // MARK: Reading

    func channel(_ channelId: String) -> PopopxChannelKeyState? {
        loadIfNeeded()
        return channels.first { $0.channelId == channelId }
    }

    func state(for uriText: String) -> PopopxChannelKeyState? {
        guard let uri = PopopxChannelPublicURI.parse(uriText) else { return nil }
        return channel(uri.channelId)
    }

    /// The current epoch key, or nil when the channel is unknown or its key has expired/been revoked.
    func currentKey(channelId: String) -> Data? {
        channel(channelId)?.currentKey?.keyData
    }

    /// Open an envelope that arrived on its own (a channel post, once the relay path exists). Same order as `apply`, and the same
    /// single assembly point: only `PopopxChannelEnvelope.decrypt` builds a `SealedBox`, so the two halves of the protocol cannot
    /// spell the ct ‖ tag split differently.
    func open(_ envelope: PopopxChannelEnvelope, channelId: String) -> Data? {
        guard let state = channel(channelId), let identityKey = state.identityKeyData, envelope.isSane,
              verifier(envelope.signature, envelope.signingPreimage(channelId: channelId), identityKey),
              let epoch = state.epochs.first(where: { $0.epoch == envelope.epoch }), epoch.isUsable,
              let key = epoch.keyData
        else { return nil }
        return envelope.decrypt(channelId: channelId, epochKey: key, identityPublicKey: identityKey)
    }

    // MARK: Schedule

    /// How close this channel is to needing a new key.
    ///
    /// Two answers are possible and they are not the same statement: "the server pushes a new epoch in N days" is something this
    /// device cannot know, so the schedule reports the *local* consequence of the expiry the server actually signed into
    /// `PopopxChannelEpochSecret.expiresAtMs`. A channel that never signs an expiry is `unbounded`, and the key page says so rather
    /// than inventing a countdown.
    func schedule(for channelId: String, now: Date = .now) -> PopopxKeyRotationSchedule {
        guard let state = channel(channelId), let epoch = state.currentKey ?? state.epochs.first(where: { $0.epoch == state.currentEpoch }) else {
            return .noChannel
        }
        guard !epoch.revoked else { return .revoked(epoch: epoch.epoch) }
        guard let expiresAtMs = epoch.expiresAtMs else { return .unbounded(epoch: epoch.epoch) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        guard expiresAtMs > nowMs else { return .expired(epoch: epoch.epoch, atMs: expiresAtMs) }
        let daysLeft = Int((expiresAtMs - nowMs) / (24 * 60 * 60 * 1_000))
        return daysLeft < expiryWarningDays
            ? .expiringSoon(epoch: epoch.epoch, expiresAtMs: expiresAtMs, daysLeft: daysLeft)
            : .active(epoch: epoch.epoch, expiresAtMs: expiresAtMs, daysLeft: daysLeft)
    }

    func setExpiryWarningDays(_ days: Int) {
        expiryWarningDays = days
    }

    // MARK: Persistence

    private func save() {
        // The index holds metadata only. `keyBase64URL` is blanked before the write so a copy of the app's plist (an iCloud backup
        // of the container, a forensic image) carries channel *names* and epoch *numbers*, never the keys — which is the entire point
        // of the Keychain half of this store.
        var redacted = channels
        for index in redacted.indices {
            for epochIndex in redacted[index].epochs.indices {
                redacted[index].epochs[epochIndex].keyBase64URL = ""
            }
        }
        guard let data = PopopxEcoCodec.encode(redacted) else { return }
        defaults.set(data, forKey: PopopxEcoKeys.channelIndex)
    }
}

// MARK: - Schedule

/// The rotation state of one channel as the key page presents it.
enum PopopxKeyRotationSchedule: Hashable, Sendable {
    case noChannel
    case active(epoch: Int, expiresAtMs: Int64, daysLeft: Int)
    case expiringSoon(epoch: Int, expiresAtMs: Int64, daysLeft: Int)
    case expired(epoch: Int, atMs: Int64)
    case revoked(epoch: Int)
    /// The channel's current key carries no signed expiry.
    case unbounded(epoch: Int)

    /// Whether a rotation is worth asking for.
    var needsRotation: Bool {
        switch self {
        case .expiringSoon, .expired, .revoked: true
        default: false
        }
    }

    var epoch: Int? {
        switch self {
        case .noChannel: nil
        case .active(let epoch, _, _), .expiringSoon(let epoch, _, _), .expired(let epoch, _), .revoked(let epoch), .unbounded(let epoch): epoch
        }
    }
}

// MARK: - Rotation request

/// What asking the service account for the next epoch produced.
///
/// Four verdicts rather than a boolean because three of them mean different sentences to the user: `queued` says "sent, not delivered
/// yet" over a Bluetooth link, `noIssuer` says "this channel was opened from a URI and no account has ever sent a key to it", which is
/// the one case where no button on this page can help.
enum PopopxChannelRotationRequestOutcome: Hashable, Sendable {
    /// The request left this device. The new epoch arrives as a signed `channel_key_update` frame, never as a reply to this call.
    case requested
    /// Mesh-only hold: the request is in module 5's queue and will be retried.
    case queued
    /// Nothing to ask: no service account is recorded for this channel.
    case noIssuer
    case sendFailed
}

/// The one action the *member* side of this protocol can honestly offer.
///
/// A client holds no channel identity private key and this build has no issuer, so `ChannelKeyRotationManager` cannot seal a new epoch
/// by itself; the brief's "一键触发新密钥轮换" is implemented as a `::CB::rotate:<channelId>` request to the account that issued the
/// previous key, which is the only party that can produce one. The frame that comes back is verified exactly like every other key
/// frame — the request grants nothing, it only asks.
@MainActor
enum PopopxChannelRotationRequest {
    static func request(channelId: String) async -> PopopxChannelRotationRequestOutcome {
        guard let state = ChannelKeyRotationManager.shared.channel(channelId),
              let issuerContactId = state.issuerContactId
        else { return .noIssuer }
        switch await PopopxEcoRouter.shared.sendCallback(payload: "rotate:\(channelId)", toContactId: issuerContactId) {
        case .sent: return .requested
        case .queuedOffline: return .queued
        case .failed: return .sendFailed
        }
    }
}

// MARK: - Storage keys

/// The `UserDefaults` keys of this module, named in one place: the self-destruct and migration sites count them by name, and a
/// scattered literal becomes unsearchable (the same rule `ChatsListView.swift:172` records for the rest of the app).
enum PopopxEcoKeys {
    static let channelIndex = "popopx.eco.channels"
    static let expiryWarningDays = "popopx.eco.key.expiryWarningDays"
    static let menus = "popopx.eco.menus"
    static let menuRevisions = "popopx.eco.menu.revisions"
    static let cards = "popopx.eco.cards"
    static let pendingIntents = "popopx.eco.pendingIntents"

    static let allUserDefaultsKeys = [channelIndex, expiryWarningDays, menus, menuRevisions, cards, pendingIntents]

    /// Every eco item in the Keychain of one contact and one channel set. The anti-theft wipe cannot enumerate accounts, so the
    /// caller hands over the ids it knows about; `removeAllKnown` is what the settings page's "clear my data" action calls.
    static func wipe(contactIds: [Int64], channelIds: [String]) {
        for contactId in contactIds { PopopxEcoKeychain.remove(PopopxEcoKeychain.sessionAccount(contactId: contactId)) }
        for channelId in channelIds {
            PopopxEcoKeychain.remove(PopopxEcoKeychain.channelAccount(channelId))
            PopopxEcoKeychain.remove(PopopxEcoKeychain.currentEpochAccount(channelId: channelId))
            for epoch in 1...PopopxEcoLimits.maximumStoredEpochs {
                PopopxEcoKeychain.remove(PopopxEcoKeychain.epochAccount(channelId: channelId, epoch: epoch))
            }
        }
        for key in allUserDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
