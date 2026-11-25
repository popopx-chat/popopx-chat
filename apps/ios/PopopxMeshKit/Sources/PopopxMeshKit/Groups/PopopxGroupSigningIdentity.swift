//
//  PopopxGroupSigningIdentity.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The Ed25519 half of a node's identity. `PopopxMeshIdentity` is X25519 only — it is a key
//  agreement key, and CryptoKit (like libsodium, like Noise) does not let one Curve25519 scalar be
//  used for signing as well. Group traffic therefore needs a second long-term key, which is what
//  Bitchat also does: its roster rows carry a 32-byte signing key next to the Noise fingerprint
//  (bitchat/Services/Groups/GroupProtocol.swift:20-27).
//
//  Deliberately NOT in the packet header and NOT a new field in the wire format: it rides the
//  announce payload, which is a JSON dictionary of strings that every decoder here already reads
//  key-by-key and ignores unknown keys in
//  (`PopopxMeshEngine.consumeAnnounce`), and it rides the signed roster and the signed inner bytes
//  of every group message. An existing peer therefore keeps parsing our announce exactly as before.
//

import CryptoKit
import Foundation

public struct PopopxGroupSigningIdentity: Sendable {
    public static let keyByteCount = 32
    public static let signatureByteCount = 64

    /// The mesh's group secrets live under one service, so module 7's panic wipe takes the signing
    /// key and every group key in one `removeAll(service:)`.
    public static let keychainService = "chat.popopx.mesh.groups"
    public static let keychainAccount = "group-signing-key"

    public let privateSeed: Data
    public let publicKey: Data

    public init?(privateSeed: Data) {
        guard privateSeed.count == Self.keyByteCount else { return nil }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateSeed) else {
            return nil
        }
        self.privateSeed = privateSeed
        self.publicKey = key.publicKey.rawRepresentation
    }

    public init(key: Curve25519.Signing.PrivateKey) {
        self.privateSeed = key.rawRepresentation
        self.publicKey = key.publicKey.rawRepresentation
    }

    public static func generate() -> PopopxGroupSigningIdentity {
        Self(key: Curve25519.Signing.PrivateKey())
    }

    /// 64 lowercase hex, the shape `SYS_POPOPX_ACK:` already uses for a key and the shape the
    /// announce payload's dictionary values are.
    public var publicKeyHex: String { publicKey.popopxHex }

    public func sign(_ data: Data) -> Data? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateSeed) else {
            PopopxMeshLog.store.error("❌ group signing key cannot be re-read from its own seed")
            return nil
        }
        return try? key.signature(for: data)
    }

    /// A public key we did not make, from the wire. Length and parse are checked; a key that fails
    /// either is simply not a signer.
    public static func verify(
        _ signature: Data,
        for data: Data,
        publicKey: Data
    ) -> Bool {
        guard signature.count == Self.signatureByteCount,
              publicKey.count == Self.keyByteCount,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// Same cold-start invariant `PopopxMeshEngine.loadOrMakeIdentity` enforces for the X25519 key:
    /// a node that loses its signing key at relaunch silently invalidates every roster row that
    /// pinned it, so a `SecItemAdd` that accepted the bytes is not believed until they come back.
    public static func loadOrMake(secrets: any PopopxMeshSecretStoring) -> PopopxGroupSigningIdentity {
        if let stored = try? secrets.data(service: Self.keychainService, account: Self.keychainAccount),
           let restored = PopopxGroupSigningIdentity(privateSeed: stored) {
            return restored
        }
        let fresh = Self.generate()
        do {
            try secrets.set(
                fresh.privateSeed,
                service: Self.keychainService,
                account: Self.keychainAccount
            )
        } catch {
            PopopxMeshLog.store.error(
                "❌ group signing key not persisted: \(String(describing: error), privacy: .public)"
            )
        }
        return fresh
    }
}
