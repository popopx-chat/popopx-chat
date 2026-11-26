//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
// POPOPX signed server cluster configuration — payload model, wire frame, trust anchor.
//
// The device can be told which servers to use without the user seeing anything, provided the
// instruction cannot be forged. Everything in this file exists to answer one question — *did POPOPX
// sign exactly these bytes* — and to make that answer decidable from the frame alone.
//
// Three properties are load-bearing and easy to lose later:
//
// 1. **Verify, then inflate. Never the other way round.** The signature covers the compressed token
//    as it was received, so a forged line is rejected before a single byte reaches a decompressor.
//    Anyone who can message the Config Bot, or who is added to the broadcast group, can emit a
//    `SERVER_CFG_V1::` line; inflating first would hand attacker-controlled bytes to zlib to find out
//    whether the line was genuine. The measured case that justifies the order: 200 000 NUL bytes
//    compress to 217, which is 290 transmitted characters — comfortably inside every size limit here —
//    and only the ceiling below stops them becoming 200 KB of live memory.
//
// 2. **Verification runs over received bytes, never over a re-serialization.** The signed body is
//    canonical JSON in *insertion* order, and a newer producer may add fields anywhere in it, so
//    "decode, re-encode, compare" is not a verification method even when the payload is valid. This
//    module therefore contains no encoder at all: the only thing that can produce a frame is
//    `scripts/ios/server-config-mint.swift`, outside every target.
//
// 3. **The suppression criterion must not depend on anything that can fail.** `isControlText` answers
//    for the shape of the line only: an expired frame, a frame signed by nobody, and a frame longer
//    than any honest one are all still hidden. Signature validity is not part of it, because a forged
//    frame that renders as a bubble is the outcome being prevented, not the one being diagnosed. The
//    acceptance test below is deliberately narrower than that shape test, and the two are kept apart
//    on purpose.
//
// The byte-level values in `PopopxServerConfigLimits` are not this module's design choices: each one
// mirrors the signing side, which is the authority. Where a limit exists on both sides and the two
// disagree, honest frames get refused and coverage silently stays at zero, so the numbers below are
// quoted from the generator rather than invented here.

import Compression
import CryptoKit
import Foundation

// MARK: - Limits

/// Size and shape ceilings. Each one is a rejection, not a warning: a frame that violates any of them
/// is deleted without being applied and without telling the user.
enum PopopxServerConfigLimits {
    /// The longest token segment the client accepts, counted in unicode scalars.
    ///
    /// Applied to everything after the 29-character `::popopx_sys::SERVER_CFG_V1::` prefix, which is
    /// the same span the signing side budgets (`MAX_SEGMENT_CHARS`), so a frame that can be signed
    /// honestly can always be offered to this parser. Scalars rather than `String.count`: the
    /// generator's limit is a code-point count, and the two only coincide because the segment
    /// alphabet is ASCII — a line carrying anything else must be refused, not counted differently.
    static let maximumSegmentCharacters = 1_024

    /// `POPOPXCFG1-`, the token tag. Eleven characters, always present, never signed.
    static let tokenPrefix = "POPOPXCFG1-"

    /// base64url of a 64-byte Ed25519 signature, unpadded, is exactly this many characters. Checked
    /// before decoding so that a malformed line cannot reach a decoder at all.
    static let signatureSegmentCharacters = 86

    /// Hard ceiling on inflated output. Beyond this, a signed body is a bomb and is refused whole.
    static let maximumInflatedBytes = 65_536

    /// Roster sizes. Above these the generator refuses to sign, so accepting more would mean accepting
    /// a body no honest tool produced. They have to stay at or above the compiled factory presets
    /// (`src/Popopx/Chat/Operators/Presets.hs`: 8 SMP plus the relay, 3 XFTP, 3 NTF), otherwise a full
    /// roster could never be delivered through this channel - `server-config-mint.swift` mirrors them.
    static let maximumSMPServerEntries = 10
    static let maximumXFTPServerEntries = 4
    static let maximumNotificationServerEntries = 4
    static let maximumRelayEntries = 2
    static let maximumICEEntries = 3

    /// `^[a-z0-9.-]+$` names, at most this long, with at least two labels.
    static let maximumHostCharacters = 253

    /// A server fingerprint is the base64url of 32 bytes: 43 characters. The generator also accepts one
    /// trailing `=` on input and strips it before signing, so a padded spelling is legal to receive and
    /// normalized here the same way.
    static let serverKeyCharacters = 43

    /// Ed25519 keys and signatures.
    static let signingKeyCharacters = 64
    static let signatureByteCount = 64

    /// `k-` plus ten hex characters, derived from the public key rather than carried as an owner name.
    static let keyIdPrefix = "k-"
    static let keyIdHashCharacters = 10
    static let keyIdCharacters = 12

    /// `bh` in the receipt: the first sixteen hex characters of the signed body's SHA-256.
    static let bodyHashCharacters = 16

    /// The signed format version and the compression tag. An unknown value in either is refused without
    /// best-effort parsing, because both describe how the bytes were made rather than what they say.
    static let formatVersion = 1
    static let encodingTag = "z9"

    /// Longest validity a body may claim. The signing side refuses a longer span, and a short window is
    /// also what makes a captured frame useless to whoever captures it later.
    static let maximumValiditySeconds = 30 * 24 * 60 * 60

    /// Counters travel as JSON integers and are bounded at 2^53 so that a value survives a round trip
    /// through any consumer's double, exactly as the generator requires.
    static let maximumCounterValue = 9_007_199_254_740_992

    /// Hosts this device will dial on the operator's instruction.
    ///
    /// Without this list, a leaked signing key would be enough to point the user at a machine the
    /// attacker runs, and every message they then sent would be theirs to read. These suffixes add no
    /// host the installation does not already reach: `.popopx.chat` and `.popopx.im` are the domains the
    /// app declares for universal links (`POPOPX (iOS).entitlements`), and `.popopx.im` is also what the
    /// shipped factory preset dials — `serverDomains = ["popopx.im"]` and the preset SMP rows in
    /// `src/Popopx/Chat/Operators/Presets.hs`, whose fingerprints are byte-for-byte the ones the
    /// operator's roster carries. `.simplex.im` was admitted while this fork's preset still offered the
    /// hosts upstream had used; `allPresetServers` now names popopx.im hosts only, so no server this
    /// installation dials matches that suffix any more, and an admission rule nobody can reach is only
    /// more ground a leaked signing key can claim. `.onion` is admitted by TLD rather than by suffix:
    /// its addresses are content-derived and change whenever a server is rebuilt.
    static let admittedHostnameSuffixes = [".popopx.chat", ".popopx.im"]
    static let onionSuffix = ".onion"

    /// ICE transport schemes, and the two that need credentials to be worth using.
    static let iceSchemes = ["stun", "stuns", "turn", "turns"]
    static let credentialRequiringSchemes = ["turn", "turns"]
    static let iceTransports = ["udp", "tcp"]

    /// A coturn REST credential is HMAC-SHA1, so exactly 20 raw bytes under standard base64.
    static let restCredentialBytes = 20
}

// MARK: - Rejections

/// Why a frame was refused. Logged, never shown: an unverifiable configuration is not news to the
/// user, and naming the cause on screen would tell an attacker which check caught them.
enum PopopxServerConfigRejection: String, Error, Sendable {
    case framePrefixMissing = "line does not start with the configuration prefix"
    case segmentTooLong = "segment exceeds the client cap"
    case tokenMalformed = "token is not POPOPXCFG1-<base64url>.<base64url>"
    case signatureSegmentMalformed = "signature segment is not 86 base64url characters"
    case signatureMalformed = "signature segment does not decode"
    case signatureWrongLength = "signature is not 64 bytes"
    case signatureNotVerifying = "signature did not verify"
    case deflateHeaderInvalid = "not a zlib stream"
    case deflateFailed = "deflate stream invalid"
    case deflateTruncated = "deflate stream ended early"
    case deflateTrailingBytes = "bytes remain after the deflate stream"
    case deflateOverCap = "inflated body exceeds the memory ceiling"
    case checksumMismatch = "adler-32 trailer does not match the inflated body"
    case bodyNotJSON = "inflated body is not JSON"
    case bodyNotObject = "body is not an object"
    case formatVersionUnsupported = "unsupported payload format version"
    case encodingUnknown = "unknown payload encoding"
    case keyIdMalformed = "key id is not k- plus ten hex characters"
    case keyIdMismatch = "key id does not match the verifying key"
    case sequenceMissing = "seq missing or out of range"
    case issuedAtMissing = "iat missing or out of range"
    case expiryMissing = "exp missing or out of range"
    case expiryNotAfterIssue = "exp is not after iat"
    case validitySpanTooLong = "validity span exceeds the ceiling"
    case expired = "expiry at or before now"
    case smpRosterInvalid = "smp roster is not a valid array"
    case smpRosterTooLarge = "smp roster exceeds its ceiling"
    case xftpRosterInvalid = "xftp roster is not a valid array"
    case xftpRosterTooLarge = "xftp roster exceeds its ceiling"
    case ntfRosterInvalid = "ntf roster is not a valid array"
    case ntfRosterTooLarge = "ntf roster exceeds its ceiling"
    case relayRosterInvalid = "relay roster is not a valid array"
    case relayRosterTooLarge = "relay roster exceeds its ceiling"
    case iceRosterInvalid = "ice roster is not a valid array"
    case iceRosterTooLarge = "ice roster exceeds its ceiling"
    case entryShapeInvalid = "server entry is not an array of two or three strings"
    case entryKeyInvalid = "server fingerprint is not 43 base64url characters"
    case entryHostInvalid = "host is not a plain lowercase name"
    case entryHostUnadmitted = "host is outside the admitted domains"
    case entryOnionInvalid = "onion alternate is not a v3 address"
    case relayEntryShapeInvalid = "relay entry is not an array of two strings"
    case relayKeyInvalid = "relay key is not 43 base64url characters"
    case iceEntryShapeInvalid = "ice entry is not an object"
    case iceSchemeUnknown = "ice scheme is not stun, stuns, turn or turns"
    case icePortInvalid = "ice port missing or out of range"
    case iceTransportUnknown = "ice transport is not udp or tcp"
    case iceCredentialsMissing = "turn entry carries no REST credentials"
    case iceCredentialsNotAllowed = "stun entry carries credentials"
    case iceUsernameMalformed = "ice username is not the REST expiry:id form"
    case iceCredentialMalformed = "ice credential is not base64 of 20 bytes"
    case iceExpiryInvalid = "ice expiry is not a positive integer within the counter ceiling"
    case policyMissing = "policy block is not an object"
    case policyAckInvalid = "policy ack is neither a boolean nor on/off"
    case policyMinSeqInvalid = "policy min_seq is not a positive integer"
    case policyInstallWindowInvalid = "policy install window is not a positive integer"
    case policyRolloutInvalid = "policy rollout is outside one to one hundred"
    case policyTtlInvalid = "policy ttl is not a positive integer"
}

// MARK: - Payload

/// One SMP, XFTP or notification server: a fingerprint, a public name, and optionally the v3 onion
/// address for the same machine.
///
/// The wire form is positional — `[key, host]` or `[key, host, onion]` — chosen by the generator to
/// keep the signed body inside its budget. Note the order: a relay entry is `[host, key]`, the other
/// way round, so the two must not share a parser.
struct PopopxServerEntry: Equatable, Sendable {
    /// Unpadded base64url of the 32-byte server key, as the transport trusts it.
    let key: String
    /// Public hostname, already grammar-checked and admitted.
    let host: String
    /// v3 onion address, without port.
    let onion: String?

    /// Hosts to try for this one server, in the order the core should walk them.
    var hostnames: [String] {
        onion.map { [host, $0] } ?? [host]
    }
}

/// A chat relay. The address is assembled by the client as `https://{host}/r#{key}`; the frame carries
/// the parts, never the URL.
struct PopopxRelayEntry: Equatable, Sendable {
    let host: String
    let key: String
}

/// A structured ICE server.
///
/// Deliberately not a URL, and the client must not make one out of a single string: a coturn REST
/// username contains `:` and its credential is base64 with `+/=`, so an inline `turn:user:cred@host`
/// form mis-parses in the existing URL-userinfo path — and a call path that fails to parse its ICE
/// list falls back to a hardcoded server, which is failing *open* on a paid-for credential.
struct PopopxIceEntry: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int
    let transport: String?
    let username: String?
    let credential: String?
    let expiresAt: Int?
}

/// The policy block. `ack` is the only field this device acts on directly; the rest are kept so the
/// log can say which generation and rollout a frame belonged to.
struct PopopxServerConfigPolicy: Equatable, Sendable {
    /// Whether the operator wants a receipt. Absent false is the normal case.
    let ack: Bool
    /// Generations below this are void. The revocation lever: the operator signs a higher `minSeq` to
    /// pull a bad generation out from under devices.
    let minSeq: Int
    /// How long a still-valid generation may sit waiting before it must not be installed. Only the
    /// staged path can exceed it; a frame applied immediately is inside it by construction.
    let installWindowSeconds: Int
    /// Percentage of devices the operator is targeting. The generator decides who is contacted, so
    /// this is recorded and not enforced here — a client that skipped 95% of honest frames would
    /// break the rollout rather than protect it.
    let rolloutPercent: Int
    /// Delivery lifetime the operator promised itself, in seconds.
    let ttlSeconds: Int
}

/// The signed configuration, version 1.
///
/// The field names follow the wire, which is short for budget reasons, not for style: the whole body
/// has to fit inside `maximumSegmentCharacters` next to its signature. Unknown top-level fields are
/// ignored rather than refused, because a newer generator appends them and refusing one would turn a
/// forward-compatible addition into an outage.
struct PopopxServerClusterPayloadV1: Equatable, Sendable {
    /// Generation number, monotonic per signing key, never derived from a clock. Gaps are legal: a
    /// reserved generation that was never signed leaves one.
    let seq: Int
    /// Issued-at and expiry, epoch seconds. A body is refused at or after `expiresAt`.
    let issuedAt: Int
    let expiresAt: Int
    /// Which key signed this, checked against the key that verified the signature.
    let keyId: String
    let smpServers: [PopopxServerEntry]
    let xftpServers: [PopopxServerEntry]
    let notificationServers: [PopopxServerEntry]
    let relays: [PopopxRelayEntry]
    let iceServers: [PopopxIceEntry]
    let policy: PopopxServerConfigPolicy
}

// MARK: - Hostnames

/// The two hostname rules a cluster has to satisfy: it must be a plain name rather than something
/// carrying URI syntax, and it must be a host this organization operates.
enum PopopxServerConfigHost {
    /// The generator's `^[a-z0-9.-]+$`: lowercase letters, digits, dots and hyphens only. Anything else
    /// — a scheme, a port, userinfo, an underscore, an uppercase letter, non-ASCII — is refused, so a
    /// host field can never smuggle a second server, a transport or a credential into the URI that is
    /// eventually assembled from it.
    static let hostnameAllowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// Fingerprint and relay key alphabet: base64url without padding.
    static let base64URLKeyCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// v3 onion addresses: 56 base32 characters and the TLD.
    static let onionCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz234567")

    static func isAdmitted(_ host: String) -> Bool {
        if host.hasSuffix(PopopxServerConfigLimits.onionSuffix),
           host.count > PopopxServerConfigLimits.onionSuffix.count {
            return true
        }
        return PopopxServerConfigLimits.admittedHostnameSuffixes.contains { host.hasSuffix($0) }
    }

    /// The shape rules alone, without the domain rule.
    static func grammarRejection(for host: String) -> PopopxServerConfigRejection? {
        guard !host.isEmpty,
              host.unicodeScalars.count <= PopopxServerConfigLimits.maximumHostCharacters,
              host.unicodeScalars.allSatisfy({ hostnameAllowedCharacters.contains($0) })
        else { return .entryHostInvalid }
        // Two labels, no empty label, no leading or trailing separator: the same shape rules the
        // generator applies before it will sign the name.
        if host.hasPrefix(".") || host.hasSuffix(".") || host.hasPrefix("-") || host.hasSuffix("-") {
            return .entryHostInvalid
        }
        let labels = host.components(separatedBy: ".")
        guard labels.count >= 2, !labels.contains(where: { $0.isEmpty }) else { return .entryHostInvalid }
        return nil
    }

    /// The reason this host is unusable, or nil when every rule holds.
    static func rejection(for host: String) -> PopopxServerConfigRejection? {
        if let grammarRejection = grammarRejection(for: host) { return grammarRejection }
        guard isAdmitted(host) else { return .entryHostUnadmitted }
        return nil
    }

    /// Validates one `[key, host, onion?]` triple. Padding on a fingerprint is normalized away, because
    /// the generator strips it before signing and a device that kept it would dial a different string
    /// from the one that was authorized.
    static func entry(_ values: [String]) -> Result<PopopxServerEntry, PopopxServerConfigRejection> {
        guard values.count == 2 || values.count == 3 else { return .failure(.entryShapeInvalid) }
        guard let key = fingerprint(values[0]) else { return .failure(.entryKeyInvalid) }
        if let hostRejection = rejection(for: values[1]) { return .failure(hostRejection) }
        if values.count == 3, !isOnion(values[2]) { return .failure(.entryOnionInvalid) }
        return .success(PopopxServerEntry(
            key: key,
            host: values[1],
            onion: values.count == 3 ? values[2] : nil
        ))
    }

    /// A relay key, which unlike a server fingerprint is never carried padded: the generator's grammar
    /// for it is exactly 43 characters, so a padded spelling here is a hand-edited roster.
    static func relayKey(_ text: String) -> String? {
        guard text.count == PopopxServerConfigLimits.serverKeyCharacters else { return nil }
        return fingerprint(text)
    }

    static func fingerprint(_ text: String) -> String? {
        let unpadded = text.hasSuffix("=") ? String(text.dropLast()) : text
        guard unpadded.unicodeScalars.count == PopopxServerConfigLimits.serverKeyCharacters,
              unpadded.unicodeScalars.allSatisfy({ base64URLKeyCharacters.contains($0) })
        else { return nil }
        return unpadded
    }

    static func isOnion(_ host: String) -> Bool {
        guard host.hasSuffix(PopopxServerConfigLimits.onionSuffix) else { return false }
        let name = String(host.dropLast(PopopxServerConfigLimits.onionSuffix.count))
        guard name.count == 56, name.unicodeScalars.allSatisfy({ onionCharacters.contains($0) }) else { return false }
        return true
    }
}

// MARK: - Trust anchor

/// The keys this device believes.
///
/// A list rather than a single key because a rotation has to be shipped *before* the key it retires is
/// decommissioned: the frame that moves to a new key has to be accepted by a build that still trusts the
/// old one, and the only way to do that without a second release is to carry both and select by `kid`.
/// Today the list holds exactly one entry, so a frame signed by any other key is refused.
enum PopopxServerConfigTrust {
    /// Production signing key, lowercase hex of the 32-byte public half. Its private half is held
    /// outside this repository and outside this build, which is the whole point of pinning a key rather
    /// than deriving it from the payload — the three other signature checks in this app take their key
    /// from the data they are checking (`PopopxGroupWire.verifyCreatorSignature`,
    /// `DiscoverCatalogModels.verifySignature`, `PopopxChannelCrypto.verify`) and none of them can tell
    /// a forged record from a genuine one.
    ///
    /// The matching key id, derived rather than declared, is `k-ad1dc5463a`. To rotate: append the new
    /// public key here, ship, re-sign with the new key, then remove the old entry in a later release.
    static let signingPublicKeyHexes = [
        "d3941ecfa89f4e6d916cebc103a79fe3b6dd37ca8bbbc2087f70d7dece5aab6e"
    ]

    /// The signature domain. A signature is made over this byte string followed by the token, so a
    /// signature for another payload kind in this product cannot be replayed as a server
    /// configuration even if it were otherwise well-formed.
    static let signatureDomain = Data("popopx|popx_srv_cfg_v1|".utf8)

    /// Parsed once per process: a malformed constant should surface as "nothing verifies" rather than as
    /// a crash inside a message handler.
    static let signingPublicKeys: [Curve25519.Signing.PublicKey] = signingPublicKeyHexes.compactMap { hex in
        guard let keyData = decodeKeyHex(hex),
              keyData.count == PopopxServerConfigLimits.signingKeyCharacters / 2 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    }

    /// Verifies and reports *which* key accepted, because the key id inside the payload has to be
    /// checked against that key rather than against any key in the list.
    ///
    /// Fail-closed at every step: an empty list verifies nothing, which is the correct reading of a
    /// build whose anchor constant was removed or corrupted.
    static func verify(signature: Data, message: Data) -> Int? {
        guard signature.count == PopopxServerConfigLimits.signatureByteCount else { return nil }
        for (index, key) in signingPublicKeys.enumerated() where key.isValidSignature(signature, for: message) {
            return index
        }
        return nil
    }

    /// `k-` plus the first ten hex characters of SHA-256 over the raw public key — the generator's
    /// derivation (`key_id_from_public`), restated here because a `kid` that is merely well-formed
    /// proves nothing about who signed the body.
    static func keyId(forPublicKeyHex hex: String) -> String? {
        guard let raw = decodeKeyHex(hex), raw.count == PopopxServerConfigLimits.signingKeyCharacters / 2 else { return nil }
        return keyId(for: raw)
    }

    static func keyId(for publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        return PopopxServerConfigLimits.keyIdPrefix + String(digest.prefix(PopopxServerConfigLimits.keyIdHashCharacters))
    }

    /// Strict hex: even length, hex digits only.
    static func decodeKeyHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0, hex.count <= 256 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

// MARK: - Wire frame

/// One decoded frame, before any decision about it.
struct PopopxServerConfigFrame: Sendable {
    let payload: PopopxServerClusterPayloadV1
    /// The body exactly as it was inflated from the signed bytes. The receipt hashes *this*, so an ACK
    /// proves which configuration the device installed rather than merely that it acknowledged
    /// something.
    let body: Data
    /// First sixteen hex characters of the body's SHA-256.
    let bodyHash: String
    /// Index into `PopopxServerConfigTrust.signingPublicKeyHexes` of the key that verified.
    let trustedKeyIndex: Int
}

/// Codec for the configuration frame.
///
/// This module owns its own grammar instead of registering a case in `PopopxCommerceSignalKind`, for
/// one structural reason: that codec refuses any payload longer than 1 024 characters, and a refusal
/// there means the line stops being signalling to `PopopxSysMarker.isSignalText` — an over-long frame
/// would then render as a bubble, in the list preview, and in a banner. `PopopxEcoMarker` and
/// `PopopxEcoUplink` are already admitted as second and third grammars for the same reason, and the
/// criterion below is added to `isSignalText` so that all render-suppression sites inherit it.
enum PopopxServerConfigWire {
    static let marker = "::popopx_sys::"
    static let configKind = "SERVER_CFG_V1"
    static let ackKind = "SERVER_CFG_ACK"
    static let configPrefix = "\(marker)\(configKind)::"
    static let ackPrefix = "\(marker)\(ackKind)::"

    /// The suppression criterion. Shape only, on purpose: prefix, one of the two kind names, `::`, then
    /// a single run with no whitespace in it. Nothing is decoded, no key is consulted and no length is
    /// rejected — an attacker who cannot forge a frame can still try to make one visible, and this
    /// function is what stops them.
    ///
    /// An empty payload is the shape as well. Nothing honest produces it — a frame with no signed
    /// payload cannot be accepted, so there is nothing to gain by sending one — and requiring one would
    /// mean "a line that starts with our grammar is never a message" held for every such line except
    /// exactly one, which is the line an attacker would pick.
    ///
    /// Trimming is part of *this* test only. The acceptance path below refuses a line with anything in
    /// front of the prefix, so a leading space can produce a hidden nothing rather than an update.
    static func isControlText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: Substring
        if trimmed.hasPrefix(configPrefix) {
            body = trimmed.dropFirst(configPrefix.count)
        } else if trimmed.hasPrefix(ackPrefix) {
            body = trimmed.dropFirst(ackPrefix.count)
        } else {
            return false
        }
        return body.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// Decode, verify and validate one frame, in that order and no other.
    ///
    /// The steps mirror the signing side's own `decode` so that a frame accepted here is a frame the
    /// generator would accept, and one refused here is refused there too. Divergence in either
    /// direction is invisible in production: the device just never updates, and nothing is reported.
    static func decodeConfigFrame(_ text: String, now: Int) -> Result<PopopxServerConfigFrame, PopopxServerConfigRejection> {
        guard text.hasPrefix(configPrefix) else { return .failure(.framePrefixMissing) }
        let segment = String(text.dropFirst(configPrefix.count))
        guard segment.unicodeScalars.count <= PopopxServerConfigLimits.maximumSegmentCharacters else {
            return .failure(.segmentTooLong)
        }
        guard let (compressed, signatureText) = tokenParts(segment) else { return .failure(.tokenMalformed) }

        // Length before decoding: a short or long segment is a structural rejection, and the order is
        // what keeps a malformed line away from every decoder downstream.
        guard signatureText.unicodeScalars.count == PopopxServerConfigLimits.signatureSegmentCharacters else {
            return .failure(.signatureSegmentMalformed)
        }
        guard let signature = Data(popopxBase64URL: signatureText) else { return .failure(.signatureMalformed) }
        guard signature.count == PopopxServerConfigLimits.signatureByteCount else { return .failure(.signatureWrongLength) }

        guard let keyIndex = PopopxServerConfigTrust.verify(
            signature: signature,
            message: PopopxServerConfigTrust.signatureDomain + Data(compressed.utf8)
        ) else {
            return .failure(.signatureNotVerifying)
        }
        // Nothing above this line has touched a decompressor. Everything below it operates on bytes that
        // the pinned key authorized.
        guard let compressedBytes = Data(popopxBase64URL: compressed) else { return .failure(.tokenMalformed) }
        let body: Data
        switch PopopxServerConfigInflator.inflate(compressedBytes) {
        case let .success(inflated):
            body = inflated
        case let .failure(reason):
            return .failure(reason)
        }
        return PopopxServerConfigBodyParser.parse(body: body, now: now, keyIndex: keyIndex)
    }

    /// `POPOPXCFG1-<base64url>.<base64url>`, anchored and with exactly one dot.
    ///
    /// A dot is outside the base64url alphabet, so splitting on it cannot be confused by escaping, and
    /// neither half can absorb the other. The character test also excludes `=`, which means a padded
    /// token is refused here rather than being quietly tolerated by a decoder that accepts padding.
    private static func tokenParts(_ segment: String) -> (compressed: String, signature: String)? {
        guard segment.hasPrefix(PopopxServerConfigLimits.tokenPrefix) else { return nil }
        let token = segment.dropFirst(PopopxServerConfigLimits.tokenPrefix.count)
        let parts = token.components(separatedBy: ".")
        guard parts.count == 2 else { return nil }
        let alphabet = PopopxServerConfigHost.base64URLKeyCharacters
        for part in parts {
            guard !part.isEmpty, part.unicodeScalars.allSatisfy({ alphabet.contains($0) }) else { return nil }
        }
        return (parts[0], parts[1])
    }

    /// The receipt this device sends: `::popopx_sys::SERVER_CFG_ACK::<seq>[::<bh>]`.
    ///
    /// Plain digits rather than a token, because the receipt carries no instruction — only a fact about
    /// this device — and the receiver already knows who sent it because it arrived on the connection the
    /// frame came from. `bodyHash` is what turns "I acknowledge" into "I installed *this* configuration";
    /// it is omitted only when the device is reporting a generation it did not install.
    static func ackFrame(seq: Int, bodyHash: String?) -> String? {
        guard seq >= 1, seq <= PopopxServerConfigLimits.maximumCounterValue else { return nil }
        guard let bodyHash else { return "\(ackPrefix)\(seq)" }
        guard bodyHash.count == PopopxServerConfigLimits.bodyHashCharacters,
              bodyHash.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
        else { return nil }
        return "\(ackPrefix)\(seq)::\(bodyHash)"
    }

    /// The first sixteen hex characters of SHA-256 over the signed body, lowercase: the same recipe the
    /// generator uses, over the same bytes.
    static func bodyHash(of body: Data) -> String {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return String(digest.prefix(PopopxServerConfigLimits.bodyHashCharacters))
    }
}

// MARK: - Inflate

/// zlib decompression under a hard output ceiling.
///
/// `Compression` is Apple's own framework, but its `COMPRESSION_ZLIB` is the RFC 1951 *payload* in both
/// directions, not the RFC 1950 stream the generator writes (`wbits=15`: a two-byte header and an
/// Adler-32 trailer around the deflate bytes). Measured against the system SDK: fed a whole `0x78 0xDA`
/// stream it answers `END` with a wrong byte count rather than an error, so the framing is done here —
/// header validated and skipped, trailer located and verified — and the decoder is handed only deflate.
///
/// The checksum is not decoration. Measured against the generator's own streams: a flipped byte inside a
/// payload is refused two ways depending on where it lands - three positions tried, two never reached the
/// end of the stream and were reported as truncated, one inflated to full length and differed only in its
/// Adler-32 - so both tests are needed, and neither may return bytes. Skipping the trailer comparison would
/// leave the second of those to be caught by nothing but the signature, and a corrupted roster that
/// inflates to a plausible-looking one is precisely what the checksum exists to make impossible.
///
/// The streaming API is used rather than `compression_decode_buffer` because the contract refuses three
/// distinct cases — output over the ceiling, a stream that ends early, and a second stream glued onto the
/// end — and only the streaming form reports how much output it produced and whether it ran out of room,
/// which is the only way to tell "over the ceiling" from "truncated" instead of guessing from a failure.
///
/// Measured on this SDK, a stream with a second deflate stream appended answers `END` with `src_size` of
/// zero: the decoder stops at the end of the first stream and does not say so. `deflateTrailingBytes` is
/// therefore the second line of defence, and the trailer check the one that actually fires — the four bytes
/// taken as the checksum belong to whatever was appended, so they cannot match. That is not a hole: the
/// signature covers the whole compressed segment including the appended bytes, so the only way to reach a
/// device with trailing garbage is for the operator to have signed it, and the inflated body is unchanged.
///
/// Every non-success path is a refusal, and no path returns partial output: whatever the caller receives
/// is what the signed bytes decompressed to, whole.
enum PopopxServerConfigInflator {
    static func inflate(_ source: Data) -> Result<Data, PopopxServerConfigRejection> {
        // Two header bytes plus a four-byte trailer, and nothing in between, is the smallest real stream.
        guard source.count >= 6, hasZlibHeader(source) else { return .failure(.deflateHeaderInvalid) }
        // One byte above the ceiling, so "exactly at the limit" succeeds and "over it" is detected as a
        // full buffer rather than as a guess.
        let capacity = PopopxServerConfigLimits.maximumInflatedBytes + 1
        var destination = [UInt8](repeating: 0, count: capacity)
        let trailer = Array(source.suffix(4))

        return source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                guard let sourceStart = sourceBytes.bindMemory(to: UInt8.self).baseAddress,
                      let destinationStart = destinationBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return .failure(.deflateFailed)
                }
                var stream = compression_stream(
                    dst_ptr: destinationStart,
                    dst_size: 0,
                    src_ptr: sourceStart,
                    src_size: 0,
                    state: nil
                )
                guard compression_stream_init(
                    &stream,
                    COMPRESSION_STREAM_DECODE,
                    COMPRESSION_ZLIB
                ) == COMPRESSION_STATUS_OK else {
                    return .failure(.deflateFailed)
                }
                defer { compression_stream_destroy(&stream) }
                // The buffers are attached after `compression_stream_init`, not in the struct's
                // initialiser: that call zeroes every field except `state` (compression.h:384), so a
                // stream built with them arrives at the first process call with no input and no output
                // room, and reports an error having read nothing.
                stream.dst_ptr = destinationStart
                stream.dst_size = capacity
                stream.src_ptr = sourceStart + 2
                stream.src_size = sourceBytes.count - 6

                // FINALIZE is set on every call, as the system header advises: without it a truncated
                // stream is reported as success having produced nothing, and there would be nothing below
                // to refuse. The status names are compared rather than matched because they are imported C
                // enumerations, and there is deliberately no case for "output buffer full" — that condition
                // is read from `dst_size`, which is the only place the ceiling is enforced.
                let finalize = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                // Input fully consumed without the stream finishing is a refusal, but one call is allowed
                // to report that state while buffered output is still being flushed.
                var stalled = false
                while true {
                    let status = compression_stream_process(&stream, finalize)
                    let produced = capacity - stream.dst_size
                    if status == COMPRESSION_STATUS_END {
                        guard produced <= PopopxServerConfigLimits.maximumInflatedBytes else {
                            return .failure(.deflateOverCap)
                        }
                        // Nothing may follow the deflate stream inside the payload: the generator refuses to
                        // sign a frame with `unused_data`, and this device refuses to read one.
                        if stream.src_size != 0 { return .failure(.deflateTrailingBytes) }
                        guard adler32(destinationStart, produced)
                                == trailerValue(trailer) else { return .failure(.checksumMismatch) }
                        return .success(Data(bytes: destinationStart, count: produced))
                    }
                    guard status == COMPRESSION_STATUS_OK else {
                        // A corrupt stream and one that stops mid-block both surface here: the decoder
                        // reports an unfinished deflate block as an error once its input is exhausted, so
                        // which of the two names is logged is a diagnostic rather than a decision. What
                        // matters is that neither path can return bytes.
                        return .failure(stream.src_size == 0 ? .deflateTruncated : .deflateFailed)
                    }
                    if stream.dst_size == 0 { return .failure(.deflateOverCap) }
                    guard stream.src_size != 0 else {
                        if stalled { return .failure(.deflateTruncated) }
                        stalled = true
                        continue
                    }
                }
            }
        }
    }

    /// RFC 1950's two-byte header check: compression method 8, window within 32 KiB, the header checksum
    /// divisible by 31, and no preset dictionary. Cheap, and it turns "is this zlib at all" into a decision
    /// this module makes itself instead of one inherited from whatever the system decoder reports.
    ///
    /// The *specific* header a level-9 stream produces (`0x78 0xDA`) is deliberately not required: the
    /// generator emits it, but FLEVEL is informational, and demanding one byte string would refuse a
    /// valid frame built by any other zlib. FDICT is required to be clear because a preset-dictionary
    /// stream carries four more header bytes, and the generator never uses one.
    private static func hasZlibHeader(_ data: Data) -> Bool {
        let header = [UInt8](data.prefix(2))
        guard header.count == 2 else { return false }
        guard header[0] & 0x0F == 8 else { return false }
        guard (header[0] >> 4) < 8 else { return false }
        guard header[1] & 0x20 == 0 else { return false }
        return (UInt16(header[0]) << 8 | UInt16(header[1])) % 31 == 0
    }

    /// The trailer as RFC 1950 stores it: big-endian.
    private static func trailerValue(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// RFC 1950's checksum over the inflated bytes. Computed here rather than trusted from the decoder:
    /// `COMPRESSION_ZLIB` is handed the deflate payload only, so the trailer goes unexamined unless this
    /// module examines it — and a byte flipped inside a valid-looking stream inflates to the right length
    /// and differs nowhere else.
    private static func adler32(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        for index in 0..<count {
            low = (low + UInt32(bytes[index])) % 65521
            high = (high + low) % 65521
        }
        return (high << 16) | low
    }
}

// MARK: - Body

/// Turns verified bytes into a payload, or into the reason it cannot be one.
///
/// Structural validation only: expiry against the clock is here because it is a property of the body and
/// the instant, but the anti-downgrade floor is deliberately not, because that is device state and this
/// file must stay decidable from the frame alone.
///
/// Each stage returns its own precise reason, and `parse` propagates the first one rather than collapsing
/// every failure into "the roster was invalid". A refused frame produces nothing the user can see, so the
/// log line is the entire diagnostic surface: one string for forty distinct defects would make an
/// operator's roster typo indistinguishable from a schema change this build predates.
enum PopopxServerConfigBodyParser {
    static func parse(
        body: Data,
        now: Int,
        keyIndex: Int
    ) -> Result<PopopxServerConfigFrame, PopopxServerConfigRejection> {
        let object: [String: Any]
        switch PopopxServerConfigField.object(body) {
        case let .success(dictionary): object = dictionary
        case let .failure(reason): return .failure(reason)
        }

        let keyId: String
        switch identity(object, keyIndex: keyIndex) {
        case let .success(claimed): keyId = claimed
        case let .failure(reason): return .failure(reason)
        }

        let timing: (seq: Int, issuedAt: Int, expiresAt: Int)
        switch clock(object, now: now) {
        case let .success(counters): timing = counters
        case let .failure(reason): return .failure(reason)
        }

        let smp: [PopopxServerEntry]
        switch serverRoster(object["smp"], ceiling: PopopxServerConfigLimits.maximumSMPServerEntries,
                            invalid: .smpRosterInvalid, tooLarge: .smpRosterTooLarge) {
        case let .success(entries): smp = entries
        case let .failure(reason): return .failure(reason)
        }
        // A cluster with no SMP servers is not a cluster: it would mean "remove every server this device
        // dials", which the generator refuses to sign and which would leave the installation unable to
        // reach anybody.
        guard !smp.isEmpty else { return .failure(.smpRosterInvalid) }

        let xftp: [PopopxServerEntry]
        switch serverRoster(object["xftp"], ceiling: PopopxServerConfigLimits.maximumXFTPServerEntries,
                            invalid: .xftpRosterInvalid, tooLarge: .xftpRosterTooLarge) {
        case let .success(entries): xftp = entries
        case let .failure(reason): return .failure(reason)
        }

        let ntf: [PopopxServerEntry]
        switch serverRoster(object["ntf"], ceiling: PopopxServerConfigLimits.maximumNotificationServerEntries,
                            invalid: .ntfRosterInvalid, tooLarge: .ntfRosterTooLarge) {
        case let .success(entries): ntf = entries
        case let .failure(reason): return .failure(reason)
        }

        let relays: [PopopxRelayEntry]
        switch relayRoster(object["relay"]) {
        case let .success(entries): relays = entries
        case let .failure(reason): return .failure(reason)
        }

        let ice: [PopopxIceEntry]
        switch iceRoster(object["ice"]) {
        case let .success(entries): ice = entries
        case let .failure(reason): return .failure(reason)
        }

        let policy: PopopxServerConfigPolicy
        switch policyBlock(object) {
        case let .success(block): policy = block
        case let .failure(reason): return .failure(reason)
        }

        let payload = PopopxServerClusterPayloadV1(
            seq: timing.seq,
            issuedAt: timing.issuedAt,
            expiresAt: timing.expiresAt,
            keyId: keyId,
            smpServers: smp,
            xftpServers: xftp,
            notificationServers: ntf,
            relays: relays,
            iceServers: ice,
            policy: policy
        )
        return .success(PopopxServerConfigFrame(
            payload: payload,
            body: body,
            bodyHash: PopopxServerConfigWire.bodyHash(of: body),
            trustedKeyIndex: keyIndex
        ))
    }

    /// Which key the payload claims, and whether that is the key that actually verified.
    ///
    /// The comparison is against the key the signature check named, not against any key in the trust
    /// list: with two entries present for a rotation, a body carrying the retired id but verified by the
    /// new key is exactly the mismatch this catches.
    private static func identity(
        _ object: [String: Any],
        keyIndex: Int
    ) -> Result<String, PopopxServerConfigRejection> {
        guard let version = PopopxServerConfigField.integer(object["v"]),
              version == PopopxServerConfigLimits.formatVersion else {
            return .failure(.formatVersionUnsupported)
        }
        guard let encoding = PopopxServerConfigField.text(object["enc"]),
              encoding == PopopxServerConfigLimits.encodingTag else {
            return .failure(.encodingUnknown)
        }
        guard let keyId = PopopxServerConfigField.text(object["kid"]), isKeyId(keyId) else {
            return .failure(.keyIdMalformed)
        }
        guard keyIndex >= 0, keyIndex < PopopxServerConfigTrust.signingPublicKeyHexes.count,
              PopopxServerConfigTrust.keyId(
                  forPublicKeyHex: PopopxServerConfigTrust.signingPublicKeyHexes[keyIndex]
              ) == keyId
        else {
            return .failure(.keyIdMismatch)
        }
        return .success(keyId)
    }

    private static func isKeyId(_ text: String) -> Bool {
        guard text.hasPrefix(PopopxServerConfigLimits.keyIdPrefix) else { return false }
        let hash = text.dropFirst(PopopxServerConfigLimits.keyIdPrefix.count)
        guard hash.unicodeScalars.count == PopopxServerConfigLimits.keyIdHashCharacters else { return false }
        return hash.unicodeScalars.allSatisfy { PopopxServerConfigField.hexCharacters.contains($0) }
    }

    /// The three counters, their ordering, and the two windows they have to fit inside.
    ///
    /// `exp <= now` counts as expired rather than expiring exactly at the boundary, matching the
    /// generator: a frame is dead the second it says it is.
    private static func clock(
        _ object: [String: Any],
        now: Int
    ) -> Result<(seq: Int, issuedAt: Int, expiresAt: Int), PopopxServerConfigRejection> {
        guard let seq = PopopxServerConfigField.counter(object["seq"]) else { return .failure(.sequenceMissing) }
        guard let issuedAt = PopopxServerConfigField.counter(object["iat"]) else { return .failure(.issuedAtMissing) }
        guard let expiresAt = PopopxServerConfigField.counter(object["exp"]) else { return .failure(.expiryMissing) }
        guard expiresAt > issuedAt else { return .failure(.expiryNotAfterIssue) }
        guard expiresAt - issuedAt <= PopopxServerConfigLimits.maximumValiditySeconds else {
            return .failure(.validitySpanTooLong)
        }
        guard expiresAt > now else { return .failure(.expired) }
        return .success((seq, issuedAt, expiresAt))
    }

    /// One `[key, host, onion?]` roster. The three server rosters share this grammar and differ only in
    /// field name and ceiling; the ceilings stay separate because the generator signs them separately.
    private static func serverRoster(
        _ value: Any?,
        ceiling: Int,
        invalid: PopopxServerConfigRejection,
        tooLarge: PopopxServerConfigRejection
    ) -> Result<[PopopxServerEntry], PopopxServerConfigRejection> {
        switch PopopxServerConfigField.rows(value, ceiling: ceiling, invalid: invalid, tooLarge: tooLarge) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(rows):
            var entries: [PopopxServerEntry] = []
            for row in rows {
                // A wrong-typed field inside an otherwise legal row is the entry's own shape error, which is
                // what the generator reports (`_host` handed a non-string, models.py:168), not a roster
                // error: the list is fine and one value in it is not, and a roster-level reason points an
                // operator at the wrong line.
                guard let values = PopopxServerConfigField.strings(row) else { return .failure(.entryShapeInvalid) }
                switch PopopxServerConfigHost.entry(values) {
                case let .success(entry): entries.append(entry)
                case let .failure(reason): return .failure(reason)
                }
            }
            return .success(entries)
        }
    }

    private static func relayRoster(
        _ value: Any?
    ) -> Result<[PopopxRelayEntry], PopopxServerConfigRejection> {
        switch PopopxServerConfigField.rows(value, ceiling: PopopxServerConfigLimits.maximumRelayEntries,
                                            invalid: .relayRosterInvalid, tooLarge: .relayRosterTooLarge) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(rows):
            var entries: [PopopxRelayEntry] = []
            for row in rows {
                // `[host, key]` — the reverse of a server entry. Same shapes, opposite order, which is
                // why this is spelled out instead of sharing `PopopxServerConfigHost.entry`.
                guard let values = PopopxServerConfigField.strings(row), values.count == 2 else {
                    return .failure(.relayEntryShapeInvalid)
                }
                if let hostRejection = PopopxServerConfigHost.rejection(for: values[0]) { return .failure(hostRejection) }
                guard PopopxServerConfigHost.relayKey(values[1]) != nil else { return .failure(.relayKeyInvalid) }
                entries.append(PopopxRelayEntry(host: values[0], key: values[1]))
            }
            return .success(entries)
        }
    }

    private static func iceRoster(
        _ value: Any?
    ) -> Result<[PopopxIceEntry], PopopxServerConfigRejection> {
        switch PopopxServerConfigField.rows(value, ceiling: PopopxServerConfigLimits.maximumICEEntries,
                                            invalid: .iceRosterInvalid, tooLarge: .iceRosterTooLarge) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(rows):
            var entries: [PopopxIceEntry] = []
            for row in rows {
                switch iceEntry(row) {
                case let .success(entry): entries.append(entry)
                case let .failure(reason): return .failure(reason)
                }
            }
            return .success(entries)
        }
    }

    private static func iceEntry(
        _ value: Any?
    ) -> Result<PopopxIceEntry, PopopxServerConfigRejection> {
        guard let object = value as? [String: Any] else { return .failure(.iceEntryShapeInvalid) }
        guard let scheme = PopopxServerConfigField.text(object["t"]),
              PopopxServerConfigLimits.iceSchemes.contains(scheme) else { return .failure(.iceSchemeUnknown) }
        guard let host = PopopxServerConfigField.text(object["h"]) else { return .failure(.iceEntryShapeInvalid) }
        // Shape only, deliberately: the generator applies no domain rule to `ice` (`models.py:266-365`), and the
        // cluster it ships publishes `turn.example.net` (`cluster.json:59`). Requiring a branded suffix here
        // would refuse every real frame over a host this build never dials, and the SMP roster that does route
        // messages would be dropped with it. The admission rule stays on the rosters that become URIs, and
        // belongs at the call path whenever this list starts being consumed.
        if let hostRejection = PopopxServerConfigHost.grammarRejection(for: host) { return .failure(hostRejection) }
        // Port is mandatory rather than defaulted. A turn entry whose port was guessed is precisely the
        // shape that lets a call path give up and fall back to the hardcoded upstream relay.
        guard let port = PopopxServerConfigField.integer(object["p"]), port >= 1, port <= 65535 else {
            return .failure(.icePortInvalid)
        }
        let transport = PopopxServerConfigField.text(object["tr"])
        if let transport, !transport.isEmpty, !PopopxServerConfigLimits.iceTransports.contains(transport) {
            return .failure(.iceTransportUnknown)
        }

        let username = PopopxServerConfigField.text(object["u"]) ?? ""
        let credential = PopopxServerConfigField.text(object["c"]) ?? ""
        // `x` is read for every scheme, because the generator validates it for every scheme
        // (`IceEntry._build`, models.py:355): an expiry is a claim about a clock, not a property of TURN
        // credentials. Left inside the credential branch, `{"t":"stun","x":0}` parsed as "expires at zero",
        // which downstream reads as either "already expired" or "never expires" depending on the reader.
        var expiry: Int?
        if object["x"] != nil {
            guard let parsed = PopopxServerConfigField.integer(object["x"]), parsed >= 1,
                  parsed <= PopopxServerConfigLimits.maximumCounterValue else {
                return .failure(.iceExpiryInvalid)
            }
            expiry = parsed
        }
        if PopopxServerConfigLimits.credentialRequiringSchemes.contains(scheme) {
            guard !username.isEmpty, !credential.isEmpty else { return .failure(.iceCredentialsMissing) }
            guard isRESTUsername(username) else { return .failure(.iceUsernameMalformed) }
            guard isRESTCredential(credential) else { return .failure(.iceCredentialMalformed) }
        } else {
            // A stun entry has nowhere to use a credential, so one on a stun entry means the generator and
            // this reader disagree about what `t` means. Refuse rather than pick a side.
            guard username.isEmpty, credential.isEmpty else { return .failure(.iceCredentialsNotAllowed) }
        }
        return .success(PopopxIceEntry(
            scheme: scheme,
            host: host,
            port: port,
            transport: (transport?.isEmpty ?? true) ? nil : transport,
            username: username.isEmpty ? nil : username,
            credential: credential.isEmpty ? nil : credential,
            expiresAt: expiry
        ))
    }

    /// `^<1..12 digits>:<[A-Za-z0-9_-]{1,64}>$` — coturn's REST username, expiry first, then the id the
    /// server was configured to recognize.
    private static func isRESTUsername(_ text: String) -> Bool {
        let parts = text.components(separatedBy: ":")
        guard parts.count == 2 else { return false }
        guard parts[0].unicodeScalars.count >= 1, parts[0].unicodeScalars.count <= 12,
              parts[0].unicodeScalars.allSatisfy({ PopopxServerConfigField.digitCharacters.contains($0) }) else { return false }
        guard parts[1].unicodeScalars.count >= 1, parts[1].unicodeScalars.count <= 64 else { return false }
        return parts[1].unicodeScalars.allSatisfy { PopopxServerConfigHost.base64URLKeyCharacters.contains($0) }
    }

    /// Standard base64 of exactly 20 raw bytes, which is HMAC-SHA1's output and what coturn recomputes.
    /// Padding is required here, unlike everywhere else in this format: this value is base64 as coturn
    /// spells it, not as this wire carries it, and the generator validates it the same strict way.
    private static func isRESTCredential(_ text: String) -> Bool {
        guard let raw = Data(base64Encoded: text, options: []) else { return false }
        return raw.count == PopopxServerConfigLimits.restCredentialBytes
    }

    private static func policyBlock(
        _ object: [String: Any]
    ) -> Result<PopopxServerConfigPolicy, PopopxServerConfigRejection> {
        guard let block = object["pol"] as? [String: Any] else { return .failure(.policyMissing) }
        guard let ack = PopopxServerConfigField.flag(block["ack"]) else { return .failure(.policyAckInvalid) }
        guard let minSeq = PopopxServerConfigField.counter(block["ms"]) else { return .failure(.policyMinSeqInvalid) }
        // `install_window` is the long spelling the generator also accepts on input, so refusing it here
        // would reject a frame the reference implementation decodes.
        guard let installWindow = PopopxServerConfigField.counter(block["iw"] ?? block["install_window"]) else {
            return .failure(.policyInstallWindowInvalid)
        }
        guard let rollout = PopopxServerConfigField.counter(block["ro"]), rollout <= 100 else {
            return .failure(.policyRolloutInvalid)
        }
        guard let ttl = PopopxServerConfigField.counter(block["ttl"]) else { return .failure(.policyTtlInvalid) }
        // Only `ro` gets a client-side bound, because only `ro` is checked by the generator while
        // *decoding*; the install window and the ttl ranges are enforced at signing time, and a device
        // that enforced them too could refuse a frame that was legal when it was made.
        return .success(PopopxServerConfigPolicy(
            ack: ack,
            minSeq: minSeq,
            installWindowSeconds: installWindow,
            rolloutPercent: rollout,
            ttlSeconds: ttl
        ))
    }
}

// MARK: - Fields

/// Reads from a `JSONSerialization` object without the casts and the number-kind guessing recurring at
/// every call site.
///
/// The boolean test is the reason this is its own type rather than a handful of inline casts:
/// `JSONSerialization` bridges JSON `true` to an `NSNumber`, and an `NSNumber` answers to `as? Int`, so an
/// unchecked read would accept `{"seq":true}` as generation one. `CFBooleanGetTypeID` is the only thing
/// that separates the two, and it is an identity comparison rather than a value comparison.
enum PopopxServerConfigField {
    static let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
    static let digitCharacters = CharacterSet(charactersIn: "0123456789")

    /// An absent roster is an empty one, which is how the generator writes a field it has nothing for.
    /// Anything else — a string where an array belongs, a list over its ceiling — keeps its own reason,
    /// because those are two different bugs on two different sides of the wire.
    static func rows(
        _ value: Any?,
        ceiling: Int,
        invalid: PopopxServerConfigRejection,
        tooLarge: PopopxServerConfigRejection
    ) -> Result<[Any], PopopxServerConfigRejection> {
        if value == nil { return .success([]) }
        guard let rows = value as? [Any] else { return .failure(invalid) }
        guard rows.count <= ceiling else { return .failure(tooLarge) }
        return .success(rows)
    }

    static func object(_ body: Data) -> Result<[String: Any], PopopxServerConfigRejection> {
        guard let value = try? JSONSerialization.jsonObject(with: body) else { return .failure(.bodyNotJSON) }
        guard let dictionary = value as? [String: Any] else { return .failure(.bodyNotObject) }
        return .success(dictionary)
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        // "q" is the encoding JSONSerialization gives an integral literal; anything written with a fraction
        // or an exponent arrives as "d". The generator accepts only the first — `isinstance` in
        // `_positive_int` is false for a float — so 1e3 is a different type of claim, not 1000 spelled
        // another way. Comparing the ceiling against `int64Value` rather than `doubleValue` is the other
        // half of the same rule: 9 007 199 254 740 993 and 9 007 199 254 740 992 are the same double, so a
        // double comparison lets a sequence number past the counter ceiling through, and the device then
        // installs a generation the signing service would have refused to mint.
        guard String(cString: number.objCType) == "q" else { return nil }
        let exact = number.int64Value
        guard exact >= 0, exact <= Int64(PopopxServerConfigLimits.maximumCounterValue) else { return nil }
        return Int(exact)
    }

    /// A counter field: a JSON integer, at least one, bounded so it survives a round trip through any
    /// consumer's double exactly as the generator requires.
    static func counter(_ value: Any?) -> Int? {
        guard let number = integer(value), number >= 1 else { return nil }
        return number
    }

    static func text(_ value: Any?) -> String? {
        value as? String
    }

    static func strings(_ value: Any?) -> [String]? {
        guard let rows = value as? [Any] else { return nil }
        return rows.allSatisfy { $0 is String } ? rows as? [String] : nil
    }

    /// `ack` travels as the string `"on"`/`"off"` — the operator's config format spells policy flags that
    /// way — while the generator's own wire parser also accepts a JSON boolean. Both are read; anything
    /// else, including `1`, is refused, because a truthy number is a different agreement about what the
    /// field means rather than another spelling of the same one.
    static func flag(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        if let text = value as? String {
            if text == "on" { return true }
            if text == "off" { return false }
        }
        return nil
    }
}
