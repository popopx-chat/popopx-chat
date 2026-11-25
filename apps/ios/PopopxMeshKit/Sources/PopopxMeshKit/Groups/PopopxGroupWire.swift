//
//  PopopxGroupWire.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Two payloads, both TLV so an old node ignores a field it does not know instead of losing the
//  rest:
//
//  * `PopopxGroupStatePayload` — the creator-signed group state (roster, epoch, key, name) that
//    travels 1:1 inside a Noise frame. Bitchat sends it as NoisePayloadType 0x06/0x07; here it is
//    the body of a `PopopxMeshMessageType.groupState` packet.
//  * `PopopxGroupMessageEnvelope` — the flooded, outer-unsigned group traffic, type 0x41. Only the
//    group id, the epoch and the AEAD nonce are visible to a relay; everything about the message is
//    inside the ciphertext.
//
//  The framing is Bitchat's (`GroupProtocol.swift:82-134`), the field numbers are ours, and every
//  parse is over an unindexed `[UInt8]` copy so a caller's slice indices cannot leak into it — the
//  same discipline `PopopxNoiseXXHandshake.take` follows.
//

import CryptoKit
import Foundation

// MARK: - TLV

/// `type(1) ‖ length(2, big-endian) ‖ value`.
enum PopopxGroupTLV {
    /// Encoding fails instead of truncating: a value that does not fit the 16-bit length field would
    /// otherwise ship as a blob the receiver rejects during parse, with no error on the sender.
    static func put(_ type: UInt8, _ value: Data, into out: inout Data) throws {
        guard value.count <= Int(UInt16.max) else { throw PopopxMeshGroupError.storageFailed("tlv value too long") }
        out.append(type)
        out.append(UInt8((value.count >> 8) & 0xFF))
        out.append(UInt8(value.count & 0xFF))
        out.append(value)
    }

    /// nil on malformed framing — a truncated value or a header the buffer cannot cover.
    static func parse(_ data: Data) -> [(type: UInt8, value: Data)]? {
        let bytes = [UInt8](data)
        var fields: [(UInt8, Data)] = []
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 3 else { return nil }
            let type = bytes[offset]
            let length = (Int(bytes[offset + 1]) << 8) | Int(bytes[offset + 2])
            let valueStart = offset + 3
            guard bytes.count - valueStart >= length else { return nil }
            fields.append((type, Data(bytes[valueStart..<(valueStart + length)])))
            offset = valueStart + length
        }
        return fields
    }

    static func epochData(_ epoch: UInt32) -> Data {
        var bigEndian = epoch.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func epoch(from data: Data) -> UInt32? {
        guard data.count == 4 else { return nil }
        return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func timestampData(_ timestampMs: UInt64) -> Data {
        var bigEndian = timestampMs.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func timestamp(from data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

// MARK: - Roster wire form

/// Deterministic roster blob: a count byte, then per member the raw 32-byte mesh public key, the
/// raw 32-byte signing key, and a length-prefixed UTF-8 nickname. The creator signature covers the
/// SHA-256 of these exact bytes, so the encoding must not reorder or respace anything.
enum PopopxGroupRosterCoding {
    private static let keyLength = PopopxMeshIdentity.keyByteCount
    private static let signingKeyLength = PopopxGroupSigningIdentity.keyByteCount

    static func encode(_ members: [PopopxMeshGroupMember]) -> Data? {
        guard !members.isEmpty, members.count <= PopopxMeshGroup.maxMembers else { return nil }
        var out = Data([UInt8(members.count)])
        for member in members {
            guard let meshKey = member.meshPublicKey, meshKey.count == keyLength,
                  member.signingPublicKey.count == signingKeyLength else { return nil }
            let nickname = Data(PopopxMeshGroupMember.clampedNickname(member.nickname).utf8)
            guard nickname.count <= UInt8.max else { return nil }
            out.append(meshKey)
            out.append(member.signingPublicKey)
            out.append(UInt8(nickname.count))
            out.append(nickname)
        }
        return out
    }

    static func decode(_ data: Data) -> [PopopxMeshGroupMember]? {
        let bytes = [UInt8](data)
        guard let count = bytes.first, count > 0, Int(count) <= PopopxMeshGroup.maxMembers else { return nil }
        var members: [PopopxMeshGroupMember] = []
        members.reserveCapacity(Int(count))
        var offset = 1
        for _ in 0..<Int(count) {
            let fixed = keyLength + signingKeyLength + 1
            guard bytes.count - offset >= fixed else { return nil }
            let meshKey = Data(bytes[offset..<(offset + keyLength)])
            let signingKey = Data(bytes[(offset + keyLength)..<(offset + keyLength + signingKeyLength)])
            let nicknameLength = Int(bytes[offset + keyLength + signingKeyLength])
            let nicknameStart = offset + fixed
            guard bytes.count - nicknameStart >= nicknameLength else { return nil }
            let nicknameEnd = nicknameStart + nicknameLength
            guard let nickname = String(bytes: bytes[nicknameStart..<nicknameEnd], encoding: .utf8),
                  let member = PopopxMeshGroupMember(
                    meshPublicKeyHex: meshKey.popopxHex,
                    signingPublicKey: signingKey,
                    nickname: nickname
                  ) else { return nil }
            members.append(member)
            offset = nicknameEnd
        }
        guard offset == bytes.count else { return nil }
        // Two rows for one peer would make "who is the creator" and "who is removed" ambiguous.
        guard Set(members.map(\.meshPublicKeyHex)).count == members.count else { return nil }
        return members
    }
}

// MARK: - Group state payload

/// The creator-signed state an invite and a key update are made of. Both self-describe their own
/// creator, so for a group already held the stored creator has to match as well — see
/// `PopopxGroupCoordinator.applyState`, which runs those checks in Bitchat's order.
public struct PopopxGroupStatePayload: Equatable, Sendable {
    public let id: Data
    public let name: String
    /// The ChaCha20-Poly1305 group key for `epoch`. This is why the payload never travels in the
    /// clear: it is inside a Noise frame, authenticated by the handshake, to one peer.
    public let key: Data
    public let epoch: UInt32
    public let members: [PopopxMeshGroupMember]
    public let creatorMeshPublicKeyHex: String
    /// Ed25519, by the creator, over `signingContent`.
    public let signature: Data

    private enum FieldType: UInt8 {
        case groupID = 0x01
        case name = 0x02
        case key = 0x03
        case epoch = 0x04
        case roster = 0x05
        case creatorKey = 0x06
        case signature = 0x07
    }

    /// Domain separation: a signature over group state can never be replayed as a signature over a
    /// group message, or as one from another build of this protocol.
    public static let signingDomain = Data("popopx-group-v1".utf8)

    /// The bytes the creator signs. Key, roster and name go in by hash so the signed content stays
    /// fixed-size; covering the name stops a store-and-forward relay that cached a signed state from
    /// swapping the display name while keeping the signature valid.
    public static func signingContent(
        groupID: Data,
        epoch: UInt32,
        key: Data,
        rosterBlob: Data,
        name: String
    ) -> Data {
        var content = signingDomain
        content.append(groupID)
        content.append(PopopxGroupTLV.epochData(epoch))
        content.append(Data(SHA256.hash(data: key)))
        content.append(Data(SHA256.hash(data: rosterBlob)))
        content.append(Data(SHA256.hash(data: Data(name.utf8))))
        return content
    }

    /// nil when the roster cannot be encoded (over cap, malformed member) or signing fails — an
    /// unsigned state is never sent, so a caller cannot mistake a stub for an invite.
    public static func makeSigned(
        group: PopopxMeshGroup,
        key: Data,
        sign: (Data) -> Data?
    ) -> PopopxGroupStatePayload? {
        guard key.count == PopopxMeshGroup.keyByteCount,
              let rosterBlob = PopopxGroupRosterCoding.encode(group.members) else { return nil }
        let content = signingContent(
            groupID: group.id,
            epoch: group.epoch,
            key: key,
            rosterBlob: rosterBlob,
            name: group.name
        )
        guard let signature = sign(content),
              signature.count == PopopxGroupSigningIdentity.signatureByteCount else { return nil }
        return PopopxGroupStatePayload(
            id: group.id,
            name: group.name,
            key: key,
            epoch: group.epoch,
            members: group.members,
            creatorMeshPublicKeyHex: group.creatorMeshPublicKeyHex,
            signature: signature
        )
    }

    public func encoded() -> Data? {
        guard let rosterBlob = PopopxGroupRosterCoding.encode(members),
              let creatorKey = Data(popopxHex: creatorMeshPublicKeyHex),
              creatorKey.count == PopopxMeshIdentity.keyByteCount,
              id.count == PopopxMeshGroup.idByteCount,
              key.count == PopopxMeshGroup.keyByteCount,
              signature.count == PopopxGroupSigningIdentity.signatureByteCount else { return nil }
        var out = Data()
        do {
            try PopopxGroupTLV.put(FieldType.groupID.rawValue, id, into: &out)
            try PopopxGroupTLV.put(FieldType.name.rawValue, Data(name.utf8), into: &out)
            try PopopxGroupTLV.put(FieldType.key.rawValue, key, into: &out)
            try PopopxGroupTLV.put(FieldType.epoch.rawValue, PopopxGroupTLV.epochData(epoch), into: &out)
            try PopopxGroupTLV.put(FieldType.roster.rawValue, rosterBlob, into: &out)
            try PopopxGroupTLV.put(FieldType.creatorKey.rawValue, creatorKey, into: &out)
            try PopopxGroupTLV.put(FieldType.signature.rawValue, signature, into: &out)
        } catch {
            return nil
        }
        return out
    }

    public static func decoded(_ data: Data) -> PopopxGroupStatePayload? {
        guard let fields = PopopxGroupTLV.parse(data) else { return nil }
        var groupID: Data?
        var name: String?
        var key: Data?
        var epoch: UInt32?
        var members: [PopopxMeshGroupMember]?
        var creatorHex: String?
        var signature: Data?

        for (type, value) in fields {
            switch FieldType(rawValue: type) {
            case .groupID where value.count == PopopxMeshGroup.idByteCount:
                groupID = value
            case .name:
                name = String(data: value, encoding: .utf8)
            case .key where value.count == PopopxMeshGroup.keyByteCount:
                key = value
            case .epoch:
                epoch = PopopxGroupTLV.epoch(from: value)
            case .roster:
                members = PopopxGroupRosterCoding.decode(value)
            case .creatorKey where value.count == PopopxMeshIdentity.keyByteCount:
                creatorHex = value.popopxHex
            case .signature where value.count == PopopxGroupSigningIdentity.signatureByteCount:
                signature = value
            default:
                break // forward compatible: an unknown TLV, or a known one with the wrong length, is skipped
            }
        }

        guard let groupID, let name, let key, let epoch, let members, let creatorHex, let signature else {
            return nil
        }
        // The creator has to be a row in the roster it signs itself into, otherwise there is no
        // pinned key to verify the signature against.
        let creatorHexLower = creatorHex.lowercased()
        guard members.contains(where: { $0.meshPublicKeyHex == creatorHexLower }) else { return nil }
        return PopopxGroupStatePayload(
            id: groupID,
            name: name,
            key: key,
            epoch: epoch,
            members: members,
            creatorMeshPublicKeyHex: creatorHexLower,
            signature: signature
        )
    }

    /// Verifies the creator signature against the creator's signing key as pinned in this state's
    /// own roster, and requires the creator to be in that roster. Self-referential by design: the
    /// sender binding (that the authenticated Noise peer IS this creator) is the caller's check.
    public func verifyCreatorSignature() -> Bool {
        guard members.count <= PopopxMeshGroup.maxMembers,
              let creator = members.first(where: { $0.meshPublicKeyHex == creatorMeshPublicKeyHex }),
              let rosterBlob = PopopxGroupRosterCoding.encode(members) else { return false }
        let content = PopopxGroupStatePayload.signingContent(
            groupID: id,
            epoch: epoch,
            key: key,
            rosterBlob: rosterBlob,
            name: name
        )
        return PopopxGroupSigningIdentity.verify(signature, for: content, publicKey: creator.signingPublicKey)
    }

    public var asGroup: PopopxMeshGroup? {
        PopopxMeshGroup(
            id: id,
            name: name,
            epoch: epoch,
            members: members,
            creatorMeshPublicKeyHex: creatorMeshPublicKeyHex
        )
    }
}

// MARK: - Group message envelope

/// The cleartext framing of a flooded group message. Only what a relay needs to do its job — the
/// group id for the table lookup, the epoch for the key, the nonce to open it — is visible.
public struct PopopxGroupMessageEnvelope: Equatable, Sendable {
    public let groupID: Data
    public let epoch: UInt32
    /// 12 bytes, chosen by the AEAD; the same nonce never repeats under one key because a fresh
    /// random nonce is drawn per seal.
    public let nonce: Data
    /// ciphertext ‖ 16-byte tag.
    public let ciphertext: Data

    private enum FieldType: UInt8 {
        case groupID = 0x01
        case epoch = 0x02
        case nonce = 0x03
        case ciphertext = 0x04
    }

    public init?(groupID: Data, epoch: UInt32, nonce: Data, ciphertext: Data) {
        guard groupID.count == PopopxMeshGroup.idByteCount,
              nonce.count == PopopxNoiseCipherState.nonceByteCount,
              ciphertext.count > PopopxNoiseCipherState.tagByteCount else { return nil }
        self.groupID = groupID
        self.epoch = epoch
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    public func encoded() -> Data? {
        var out = Data()
        do {
            try PopopxGroupTLV.put(FieldType.groupID.rawValue, groupID, into: &out)
            try PopopxGroupTLV.put(FieldType.epoch.rawValue, PopopxGroupTLV.epochData(epoch), into: &out)
            try PopopxGroupTLV.put(FieldType.nonce.rawValue, nonce, into: &out)
            try PopopxGroupTLV.put(FieldType.ciphertext.rawValue, ciphertext, into: &out)
        } catch {
            return nil
        }
        return out
    }

    public static func decoded(_ data: Data) -> PopopxGroupMessageEnvelope? {
        guard let fields = PopopxGroupTLV.parse(data) else { return nil }
        var groupID: Data?
        var epoch: UInt32?
        var nonce: Data?
        var ciphertext: Data?
        for (type, value) in fields {
            switch FieldType(rawValue: type) {
            case .groupID where value.count == PopopxMeshGroup.idByteCount:
                groupID = value
            case .epoch:
                epoch = PopopxGroupTLV.epoch(from: value)
            case .nonce where value.count == PopopxNoiseCipherState.nonceByteCount:
                nonce = value
            case .ciphertext where value.count > PopopxNoiseCipherState.tagByteCount:
                ciphertext = value
            default:
                break
            }
        }
        guard let groupID, let epoch, let nonce, let ciphertext else { return nil }
        return PopopxGroupMessageEnvelope(groupID: groupID, epoch: epoch, nonce: nonce, ciphertext: ciphertext)
    }
}
