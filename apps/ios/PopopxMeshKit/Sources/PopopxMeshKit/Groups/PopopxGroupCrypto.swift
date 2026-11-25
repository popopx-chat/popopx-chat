//
//  PopopxGroupCrypto.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Seal and open one group message. The construction is Bitchat's
//  (`bitchat/Services/Groups/GroupProtocol.swift:460-570`) with POPOPX's domain strings:
//
//  inner TLV = messageID ‖ sender's Ed25519 public key ‖ nickname ‖ timestamp ‖ content ‖
//              Ed25519 signature over (domain ‖ groupID ‖ epoch ‖ messageID ‖ timestamp ‖ content)
//  wire      = ChaChaPoly(inner, key: group key, nonce: random 12B,
//                          aad: groupID ‖ epoch big-endian) ‖ tag, in a TLV with the cleartext
//                          groupID, epoch and nonce.
//
//  Two properties come out of that shape and neither is decoration:
//  * the AAD binds ciphertext to one group at one epoch, so a relay cannot move a packet to another
//    group or an earlier epoch, and a member cannot re-seal another member's opened bytes under a
//    later key — the signature would no longer verify at that epoch;
//  * the signature is over the content and the sender's key, so possession of the group key is not
//    authorship. Which member a signing key belongs to is the roster's question, answered by
//    `PopopxGroupCoordinator.receiveMessage`, not here.
//

import CryptoKit
import Foundation

public enum PopopxGroupCryptoError: Error, Hashable, Sendable {
    case signingFailed
    case sealFailed
    case decryptionFailed
    case badSenderSignature
    case malformedPayload
}

/// What a group message carried, once opened and signature-checked.
public struct PopopxGroupMessagePlaintext: Equatable, Sendable {
    public let id: String
    /// The signer's own key, read out of the signed bytes: proving authorship, not membership.
    public let senderSigningPublicKey: Data
    /// Free text the sender chose for display; the roster's name wins where they disagree.
    public let senderNickname: String
    public let sentAt: Date
    public let text: String
}

public enum PopopxGroupCrypto {
    public static let messageSigningDomain = Data("popopx-group-msg-v1".utf8)

    private enum InnerField: UInt8 {
        case messageID = 0x01
        case senderSigningKey = 0x02
        case nickname = 0x03
        case timestamp = 0x04
        case content = 0x05
        case signature = 0x06
    }

    /// The bytes the sender signs. The group id and epoch are in here as well as in the AAD: the
    /// AAD stops a packet being moved, this stops the *content* being moved — a signature over the
    /// same text at another epoch or in another group does not verify.
    public static func messageSigningContent(
        groupID: Data,
        epoch: UInt32,
        messageID: String,
        timestampMs: UInt64,
        content: String
    ) -> Data {
        var data = messageSigningDomain
        data.append(groupID)
        data.append(PopopxGroupTLV.epochData(epoch))
        data.append(Data(messageID.utf8))
        data.append(PopopxGroupTLV.timestampData(timestampMs))
        data.append(Data(content.utf8))
        return data
    }

    /// Seals one message and returns the bytes for a `PopopxMeshMessageType.groupMessage` payload,
    /// ready to flood. `sign` is handed the signing content and returns nil when the local signing
    /// key is gone — an unsigned message is refused, never sent.
    public static func sealMessage(
        content: String,
        messageID: String,
        senderNickname: String,
        senderSigningPublicKey: Data,
        timestampMs: UInt64,
        groupID: Data,
        epoch: UInt32,
        key: Data,
        sign: (Data) -> Data?
    ) throws -> Data {
        guard groupID.count == PopopxMeshGroup.idByteCount,
              key.count == PopopxMeshGroup.keyByteCount,
              senderSigningPublicKey.count == PopopxGroupSigningIdentity.keyByteCount,
              !messageID.isEmpty else { throw PopopxGroupCryptoError.malformedPayload }

        let signingContent = messageSigningContent(
            groupID: groupID,
            epoch: epoch,
            messageID: messageID,
            timestampMs: timestampMs,
            content: content
        )
        guard let signature = sign(signingContent),
              signature.count == PopopxGroupSigningIdentity.signatureByteCount else {
            throw PopopxGroupCryptoError.signingFailed
        }

        var inner = Data()
        do {
            try PopopxGroupTLV.put(InnerField.messageID.rawValue, Data(messageID.utf8), into: &inner)
            try PopopxGroupTLV.put(InnerField.senderSigningKey.rawValue, senderSigningPublicKey, into: &inner)
            try PopopxGroupTLV.put(InnerField.nickname.rawValue, Data(senderNickname.utf8), into: &inner)
            try PopopxGroupTLV.put(InnerField.timestamp.rawValue, PopopxGroupTLV.timestampData(timestampMs), into: &inner)
            try PopopxGroupTLV.put(InnerField.content.rawValue, Data(content.utf8), into: &inner)
            try PopopxGroupTLV.put(InnerField.signature.rawValue, signature, into: &inner)
        } catch {
            throw PopopxGroupCryptoError.malformedPayload
        }

        var aad = groupID
        aad.append(PopopxGroupTLV.epochData(epoch))
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.seal(inner, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw PopopxGroupCryptoError.sealFailed
        }
        var ciphertext = sealed.ciphertext
        ciphertext.append(sealed.tag)
        guard let envelope = PopopxGroupMessageEnvelope(
            groupID: groupID,
            epoch: epoch,
            nonce: Data(sealed.nonce),
            ciphertext: ciphertext
        ) else { throw PopopxGroupCryptoError.sealFailed }
        guard let payload = envelope.encoded() else { throw PopopxGroupCryptoError.sealFailed }
        return payload
    }

    /// Opens one flooded payload with the epoch key. Throws for a wrong key, a moved epoch or group,
    /// a tampered byte and a signature that does not match the bytes it claims to sign; membership
    /// of the signer is the caller's check.
    public static func openMessage(
        _ envelope: PopopxGroupMessageEnvelope,
        key: Data
    ) throws -> PopopxGroupMessagePlaintext {
        guard key.count == PopopxMeshGroup.keyByteCount else {
            throw PopopxGroupCryptoError.decryptionFailed
        }
        var aad = envelope.groupID
        aad.append(PopopxGroupTLV.epochData(envelope.epoch))
        let inner: Data
        do {
            let nonce = try ChaChaPoly.Nonce(data: envelope.nonce)
            let body = envelope.ciphertext.dropLast(PopopxNoiseCipherState.tagByteCount)
            let tag = envelope.ciphertext.suffix(PopopxNoiseCipherState.tagByteCount)
            inner = try ChaChaPoly.open(
                ChaChaPoly.SealedBox(nonce: nonce, ciphertext: body, tag: tag),
                using: SymmetricKey(data: key),
                authenticating: aad
            )
        } catch {
            throw PopopxGroupCryptoError.decryptionFailed
        }

        guard let fields = PopopxGroupTLV.parse(inner) else { throw PopopxGroupCryptoError.malformedPayload }
        var messageID: String?
        var signingKey: Data?
        var nickname: String?
        var timestampMs: UInt64?
        var content: String?
        var signature: Data?
        for (type, value) in fields {
            switch InnerField(rawValue: type) {
            case .messageID:
                messageID = String(data: value, encoding: .utf8)
            case .senderSigningKey where value.count == PopopxGroupSigningIdentity.keyByteCount:
                signingKey = value
            case .nickname:
                nickname = String(data: value, encoding: .utf8)
            case .timestamp:
                timestampMs = PopopxGroupTLV.timestamp(from: value)
            case .content:
                content = String(data: value, encoding: .utf8)
            case .signature where value.count == PopopxGroupSigningIdentity.signatureByteCount:
                signature = value
            default:
                break
            }
        }
        guard let messageID, !messageID.isEmpty, let signingKey, let nickname,
              let timestampMs, let content, let signature else {
            throw PopopxGroupCryptoError.malformedPayload
        }

        let signingContent = messageSigningContent(
            groupID: envelope.groupID,
            epoch: envelope.epoch,
            messageID: messageID,
            timestampMs: timestampMs,
            content: content
        )
        guard PopopxGroupSigningIdentity.verify(signature, for: signingContent, publicKey: signingKey) else {
            throw PopopxGroupCryptoError.badSenderSignature
        }
        // A sender's clock is attacker-chosen and the message is displayed by our own calendar; the
        // timestamp is trusted only up to now, so a future-dated message cannot pin itself to the
        // bottom of a timeline.
        let sentAt = min(
            Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000),
            Date.now
        )
        return PopopxGroupMessagePlaintext(
            id: messageID,
            senderSigningPublicKey: signingKey,
            senderNickname: nickname,
            sentAt: sentAt,
            text: content
        )
    }

    /// A fresh message id, in the shape every other mesh id in this package uses.
    public static func makeMessageID() -> String {
        UUID().uuidString.lowercased()
    }
}
