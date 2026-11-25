//
//  PopopxMeshIdentity.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation

/// The X25519 key pair a node announces itself with. `privateSeed` is the raw 32-byte scalar,
/// kept as Data rather than a CryptoKit key so the struct stays Sendable and can cross actor
/// and Task boundaries without a second copy of the key material.
public struct PopopxMeshIdentity: Sendable {
    public static let keyByteCount = 32

    public let privateSeed: Data
    public let publicKey: Data

    public init?(privateSeed: Data) {
        guard privateSeed.count == Self.keyByteCount else { return nil }
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateSeed) else {
            return nil
        }
        self.privateSeed = privateSeed
        self.publicKey = key.publicKey.rawRepresentation
    }

    public init?(privateSeed: Data, publicKey: Data) {
        guard privateSeed.count == Self.keyByteCount, publicKey.count == Self.keyByteCount else {
            return nil
        }
        self.privateSeed = privateSeed
        self.publicKey = publicKey
    }

    public init(keyAgreementKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateSeed = keyAgreementKey.rawRepresentation
        self.publicKey = keyAgreementKey.publicKey.rawRepresentation
    }

    public static func generate() -> PopopxMeshIdentity {
        Self(keyAgreementKey: Curve25519.KeyAgreement.PrivateKey())
    }

    /// A hex mesh public key as it appears in `SYS_POPOPX_ACK:` and in the mapping table.
    public var meshPublicKeyHex: String {
        publicKey.map { String(format: "%02x", $0) }.joined()
    }

    /// The short on-wire id: first 8 bytes of SHA256(pubkey).
    public var peerID: PopopxMeshPeerID {
        PopopxMeshPeerID(publicKey: publicKey)
    }

    public func keyAgreementPrivateKey() -> Curve25519.KeyAgreement.PrivateKey? {
        try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateSeed)
    }

    public func keyAgreementPublicKey() -> Curve25519.KeyAgreement.PublicKey? {
        try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
    }
}

public extension Data {
    init?(popopxHex string: some StringProtocol) {
        let chars = Array(string)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            // Exactly two characters per byte. `chars[index...index + 1]` is a CLOSED range and reads
            // three, so a window like "1b2" asks for 0x1B2, which does not fit in UInt8: the decoder
            // returned nil for essentially every real 64-character key, and the seven call sites in
            // `PopopxMeshEngine` (peer lookup, send, restore, sender resolution) each failed silently.
            let window = chars[index..<index + 2]
            guard let byte = UInt8(String(window), radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index += 2
        }
        self = Data(bytes)
    }

    var popopxHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
