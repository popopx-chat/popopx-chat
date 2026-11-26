//
//  PopopxOpaqueInviteCodec.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The public share form of a connection URI: `https://popopx.chat/i/v1/<code>`.
//
//  Byte-compatible with `popopx-service-suite/gateway/app/opaque_invite_codec.py` and
//  `popopx-bot-studio/studio/app/security/opaque_invite_codec.py`; the published vectors in
//  `PopopxOpaqueInviteVectors.swift` are copied verbatim from those two files and the tests assert
//  this codec reproduces every byte of them.
//
//  What v1 is: HKDF-SHA256 over a fixed, published key-derivation input, then ChaCha20-Poly1305
//  with a fresh 12-byte nonce per link and a fixed AAD, encoded as unpadded base64url.
//
//  What v1 is NOT: confidentiality. `ikmHex` is a *format* key — every client must hold it, so it
//  is in the source of an AGPL app by design, and the gateway's own docstring says the envelope
//  "is not confidentiality against someone who reads this file". The property this buys is that the
//  relay host stops appearing in link previews, screenshots, forwards and chat history. Copy and
//  privacy disclosures must describe it that way and never as an encrypted or private link.
//
//  Asymmetry, deliberate (ruled 2026-11-26): sealing is as strict as the two server repositories,
//  so nothing this app produces can be refused by them. Opening is wider, so a link from anywhere
//  in the ecosystem still resolves. Widening the seal side would break that contract in the other
//  direction — `smp://` is a listed *rejected* vector upstream, not an accepted one.
//

import CryptoKit
import Foundation
import Security

// MARK: - Errors

public enum PopopxOpaqueInviteError: Error, Hashable, Sendable {
    /// Nothing to seal. Raised before the scheme check so an empty field cannot be read as
    /// "unsupported scheme" by a caller deciding what to show the user.
    case emptyURI
    /// The URI does not start with one of the three schemes the servers seal.
    case uriSchemeInvalid
    /// A URI that would not survive being pasted: leading/trailing space, or any control
    /// character or whitespace inside. The servers reject these too, and a wrapped tab is still a
    /// tab once unwrapped.
    case uriNotPlain
    /// Plaintext over the seal ceiling. The gateway refuses to *decode* anything past this, so
    /// sealing more would mint a link only this app could open.
    case uriTooLong(bytes: Int, limit: Int)
    /// Not a `…/i/v1/<code>` link at all — including the `https://popopx.chat.<code>` dot form,
    /// which DNS cannot represent (labels cap at 63 bytes) and upstream rejects on purpose.
    case linkPrefixInvalid
    /// The code is empty, or longer than the v1 ceiling.
    case codeLengthInvalid
    /// The code is not unpadded base64url.
    case codeNotBase64URL
    /// The AEAD tag did not verify, or the payload is not UTF-8, or the recovered URI is outside
    /// the allowlist this codec accepts when opening. Deliberately one case for all three: which
    /// one it was is not something a caller can act on, and a QR that fails should say "not a
    /// POPOPX invite" rather than leak how close it got.
    case tampered
    /// The system RNG refused to fill a nonce. Distinct from `tampered` because the caller's answer
    /// is "try again", not "that link is invalid".
    case nonceUnavailable
}

// MARK: - Codec

public enum PopopxOpaqueInviteCodec {
    /// Versioned prefix. Changing it is a new format, not a configuration change: links minted
    /// under the old one stay decodable only if the old derivation inputs also stay.
    public static let linkPrefix = "https://popopx.chat/i/v1/"

    /// The published key-derivation inputs. These are format constants, shared verbatim with the
    /// gateway and Bot Studio codecs; a mismatch here is silent interop failure, not a security
    /// boundary, which is why they are named instead of inlined.
    static let ikmHex = "d1abbcb09b5bf244d9d8b6b1dcc38835b5a419d8a1d62b014c1bb49e765dbdeb"
    static let salt = Data("popopx.chat/invite-link/v1/salt".utf8)
    static let info = Data("popopx.chat/invite-link/v1/key".utf8)
    static let aad = Data("popopx.chat/invite-link/v1/aad".utf8)

    static let nonceBytes = 12
    static let tagBytes = 16
    static let keyBytes = 32

    /// Seal ceiling, equal to the gateway's `MAX_URI_BYTES`.
    public static let maxSealPlaintextBytes = 2048
    /// Open ceiling, equal to Bot Studio's `MAX_ADDRESS_BYTES` and wider on purpose: a link this
    /// app did not mint is still worth resolving if it is otherwise intact.
    public static let maxOpenPlaintextBytes = 4096

    /// Schemes the servers will seal. Kept in this order and this spelling to match `URI_SCHEMES`.
    public static let sealableSchemes = ["popopx:/", "popopx://", "https://"]

    /// Schemes accepted *when opening*, plus the Mac Node pairing prefix. `smp://` is a legacy raw
    /// address this app may be handed but never mints; `PPXNODE1-…` is an Ed25519-signed pairing
    /// offer, whose own verification lives in `PopopxNodePairing` — this codec only unwraps it, it
    /// does not vouch for it.
    ///
    /// Public because the connect path needs the same list to decide whether an opened payload is a
    /// connection address at all: a pairing offer unwrapped into `planAndConnect` would be reported
    /// to the user as a damaged invite. Deriving it here keeps that check from re-typing the schemes.
    public static let openableSchemes = sealableSchemes + ["smp://"]
    static let openablePrefixes = ["PPXNODE1-"]

    /// Whether an opened payload is a connection address rather than some other wrapped byte string.
    public static func isConnectableOpened(_ text: String) -> Bool {
        openableSchemes.contains(where: { text.hasPrefix($0) })
    }

    /// Derived once: the HKDF is 4 HMAC-SHA256 calls, and doing it per link would put it on the
    /// share-sheet path.
    static let formatKey: SymmetricKey = hkdf(
        ikm: Data(hex: ikmHex),
        salt: salt,
        info: info,
        length: keyBytes
    )

    // MARK: Sealing

    /// The public form of a connection URI, or nil when the URI is not sealable.
    ///
    /// Returns nil instead of throwing so a caller can fall back to the raw link without a
    /// do/catch on the UI path; `sealCode` carries the reason when one is needed.
    public static func link(forURI uri: String, nonce: Data? = nil) -> String? {
        guard let code = try? sealCode(forURI: uri, nonce: nonce) else { return nil }
        return linkPrefix + code
    }

    /// `link(forURI:)` with the reason exposed.
    /// - Throws: `PopopxOpaqueInviteError` for an input the servers would also refuse.
    public static func sealCode(forURI uri: String, nonce: Data? = nil) throws -> String {
        let text = try validatedSealableURI(uri)
        let nonceData: Data
        if let nonce {
            guard nonce.count == nonceBytes else { throw PopopxOpaqueInviteError.codeLengthInvalid }
            nonceData = nonce
        } else {
            // A fresh nonce per link is what stops two shares of the same contact address being
            // comparable, so a failed CSPRNG must not silently fall back to a fixed one.
            guard let generated = randomNonce() else { throw PopopxOpaqueInviteError.nonceUnavailable }
            nonceData = generated
        }
        let box = try ChaChaPoly.seal(
            Data(text.utf8),
            using: formatKey,
            nonce: ChaChaPoly.Nonce(data: nonceData),
            authenticating: aad
        )
        return base64URL(nonceData + box.ciphertext + box.tag)
    }

    /// The bare code, with a caller-supplied nonce. Exposed for the vector tests, which must pin
    /// the nonce to reproduce published bytes.
    public static func sealedBytes(uri: String, nonce: Data) -> Data? {
        guard let text = try? validatedSealableURI(uri), nonce.count == nonceBytes else { return nil }
        let box = try? ChaChaPoly.seal(
            Data(text.utf8),
            using: formatKey,
            nonce: ChaChaPoly.Nonce(data: nonce),
            authenticating: aad
        )
        guard let box else { return nil }
        return nonce + box.ciphertext + box.tag
    }

    // MARK: Opening

    /// Recovers the connection URI an opaque link carries.
    /// - Throws: `PopopxOpaqueInviteError.tampered` for anything that does not authenticate.
    public static func uri(fromLink link: String) throws -> String {
        try openCode(substring(ofLink: link))
    }

    /// `uri(fromLink:)` as an optional, for paste and QR paths where "not an invite" is the normal
    /// answer.
    public static func uriIfOpaqueLink(_ value: String) -> String? {
        try? uri(fromLink: value)
    }

    /// Shape test only: it does not prove the envelope authenticates. Used to decide whether to try
    /// the codec at all before falling back to the plain-link path.
    public static func looksLikeOpaqueLink(_ value: String) -> Bool {
        guard let prefix = openLinkPrefix(in: value) else { return false }
        let code = String(value.dropFirst(prefix.count))
        return !code.isEmpty && code.count <= maxOpenTokenChars && base64URLDecode(code) != nil
    }

    // MARK: Steps, split out so a test can tell prefix from envelope from payload

    /// The prefixes this codec will read. Only the first is ever minted: `popopxChatLink` defines
    /// `popopx:/…` and `https://popopx.chat/…` as two spellings of one address, and an invitation
    /// carried between clients arrives rewritten either way. Reading only the minted form would make
    /// the same link work when pasted and fail when tapped.
    static let openLinkPrefixes = [linkPrefix, "popopx:/i/v1/", "popopx://popopx.chat/i/v1/"]

    static func openLinkPrefix(in link: String) -> String? {
        openLinkPrefixes.first { link.hasPrefix($0) }
    }

    static func substring(ofLink link: String) throws -> String {
        guard let prefix = openLinkPrefix(in: link) else { throw PopopxOpaqueInviteError.linkPrefixInvalid }
        let code = String(link.dropFirst(prefix.count))
        guard !code.isEmpty, code.count <= maxOpenTokenChars else {
            throw PopopxOpaqueInviteError.codeLengthInvalid
        }
        return code
    }

    /// The widest token a plaintext at the open ceiling can encode to.
    static let maxOpenTokenChars = ((nonceBytes + maxOpenPlaintextBytes + tagBytes + 2) / 3) * 4

    static func openCode(_ code: String) throws -> String {
        guard let raw = base64URLDecode(code) else { throw PopopxOpaqueInviteError.codeNotBase64URL }
        guard raw.count >= nonceBytes + tagBytes + 1, raw.count <= nonceBytes + maxOpenPlaintextBytes + tagBytes else {
            throw PopopxOpaqueInviteError.codeLengthInvalid
        }
        guard let box = try? ChaChaPoly.SealedBox(combined: raw),
              let opened = try? ChaChaPoly.open(box, using: formatKey, authenticating: aad)
        else { throw PopopxOpaqueInviteError.tampered }
        guard let text = String(data: opened, encoding: .utf8), opensAcceptable(text) else {
            throw PopopxOpaqueInviteError.tampered
        }
        return text
    }

    /// What this codec will hand back after a successful open. Wider than the seal side by ruling,
    /// narrower than "any string": an unauthenticated byte sequence that happens to decode as UTF-8
    /// cannot reach here (the tag already failed), and a wrapper that would return
    /// `javascript:alert(1)` under a trusted domain is a phishing primitive.
    static func opensAcceptable(_ text: String) -> Bool {
        if text.isEmpty || text != text.trimmingCharacters(in: .whitespacesAndNewlines) { return false }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return false
        }
        if openablePrefixes.contains(where: { text.hasPrefix($0) }) { return true }
        return openableSchemes.contains(where: { text.hasPrefix($0) })
    }

    static func validatedSealableURI(_ uri: String) throws -> String {
        guard !uri.isEmpty else { throw PopopxOpaqueInviteError.emptyURI }
        guard uri == uri.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw PopopxOpaqueInviteError.uriNotPlain
        }
        guard sealableSchemes.contains(where: { uri.hasPrefix($0) }) else {
            throw PopopxOpaqueInviteError.uriSchemeInvalid
        }
        let bytes = Array(uri.utf8).count
        guard bytes <= maxSealPlaintextBytes else {
            throw PopopxOpaqueInviteError.uriTooLong(bytes: bytes, limit: maxSealPlaintextBytes)
        }
        guard !uri.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw PopopxOpaqueInviteError.uriNotPlain
        }
        return uri
    }

    // MARK: Primitives

    /// RFC 5869 HKDF-SHA256 through CryptoKit, the same call
    /// `official_tools/swift_opaque_invite_oracle.swift` makes. `deriveKey(ikm:extractWith:…)` is the
    /// newer overload and needs a higher deployment floor than this package carries; without a PSK the
    /// two are the same function.
    static func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: length
        )
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `SecRandomCopyBytes`, not `Data.random`: same rule `PopopxGroupStore` states for group keys —
    /// the system generator is the one with a seeded state, and a link nonce made from `random(in:)`
    /// is a claim about the Swift PRNG this codec cannot make.
    private static func randomNonce() -> Data? {
        var bytes = Data(count: nonceBytes)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, nonceBytes, base)
        }
        guard status == errSecSuccess else {
            PopopxMeshLog.store.error("🚫 SecRandomCopyBytes failed with OSStatus \(status)")
            return nil
        }
        return bytes
    }

    /// Unpadded base64url, and nothing else: `+/` and a stray `=` are rejected rather than
    /// tolerated, because a code that decodes two ways is a code two implementations can disagree
    /// about. The character class is ASCII-only and spelled out — `isLetter` would also accept
    /// `é`, and `Data(base64Encoded:)`'s own leniency is not the contract.
    static func base64URLDecode(_ text: String) -> Data? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ codeRegex.contains($0) }) else { return nil }
        guard text.count % 4 != 1 else { return nil }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: padded, options: [])
    }

    /// `_CODE_RE` in both server codecs.
    private static let codeRegex = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
}

extension Data {
    /// Used for the published derivation inputs and the vectors' nonces, both of which are hex in
    /// the upstream files. An odd or non-hex string yields empty, which every caller then rejects
    /// on length.
    init(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var nibble: UInt8?
        var malformed = false
        for character in hex.unicodeScalars {
            guard let value = Self.hexDigit(character) else {
                malformed = true
                break
            }
            if let high = nibble {
                bytes.append(high << 4 | value)
                nibble = nil
            } else {
                nibble = value
            }
        }
        // An odd length or a non-hex character reads as no bytes at all rather than a partial key:
        // a silent truncation here would produce a key that opens nothing and names nothing.
        self = (malformed || nibble != nil) ? Data() : Data(bytes)
    }

    private static func hexDigit(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: UInt8(scalar.value - 0x30)
        case 0x41...0x46: UInt8(scalar.value - 0x41 + 10)
        case 0x61...0x66: UInt8(scalar.value - 0x61 + 10)
        default: nil
        }
    }
}
