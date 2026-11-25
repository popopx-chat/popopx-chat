//
//  PopopxMeshGroupModel.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The value types of a private group: an id that travels in the clear so a node without the key
//  can still dedup and flood it, a roster the creator signs, and an epoch that orders every roster
//  change. Modelled on Bitchat's `BitchatGroup` (bitchat/Services/Groups/GroupProtocol.swift:31),
//  with its 64-hex `fingerprint` replaced by POPOPX's mesh public key hex — the same string the
//  pairing frames and the identity mapping table already use, so a roster row names a peer the way
//  the rest of this package names peers and nothing else.
//
//  The symmetric key is deliberately absent from this type: it belongs in the Keychain and a group
//  that gets written to disk must never carry it. See `PopopxGroupStore`.
//

import Foundation

// MARK: - Member

/// One roster entry, as the creator pinned it at invite time.
public struct PopopxMeshGroupMember: Codable, Hashable, Sendable {
    /// Nicknames are carried in the signed roster blob, so they are bounded in bytes, not characters.
    public static let maxNicknameBytes = 64

    /// Our/their X25519 mesh public key, 64 lowercase hex characters — the value a Noise handshake
    /// proved, and the only peer name this package trusts.
    public let meshPublicKeyHex: String
    /// The member's Ed25519 signing public key, 32 bytes. Learned from that peer's announce; it is
    /// what makes a group message's authorship provable rather than merely decryptable.
    public let signingPublicKey: Data
    /// The name shown for this member, fixed at invite time. A later rename does not move the
    /// signature, so an old roster row keeps the name the creator signed.
    public var nickname: String

    public init?(meshPublicKeyHex: String, signingPublicKey: Data, nickname: String) {
        guard meshPublicKeyHex.count == PopopxMeshIdentity.keyByteCount * 2,
              meshPublicKeyHex.allSatisfy(\.isHexDigit),
              Data(popopxHex: meshPublicKeyHex) != nil,
              signingPublicKey.count == PopopxGroupSigningIdentity.keyByteCount else { return nil }
        self.meshPublicKeyHex = meshPublicKeyHex.lowercased()
        self.signingPublicKey = signingPublicKey
        self.nickname = PopopxMeshGroupMember.clampedNickname(nickname)
    }

    public var meshPublicKey: Data? { Data(popopxHex: meshPublicKeyHex) }

    public var peerID: PopopxMeshPeerID? {
        meshPublicKey.map(PopopxMeshPeerID.init(publicKey:))
    }

    public var signingPublicKeyHex: String { signingPublicKey.popopxHex }

    static func clampedNickname(_ nickname: String) -> String {
        var candidate = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dropped by whole Characters, so the UTF-8 prefix written into the signed roster can never
        // split a scalar and make the entire roster undecodable for everyone else.
        while Data(candidate.utf8).count > Self.maxNicknameBytes {
            candidate.removeLast()
        }
        return candidate
    }
}

// MARK: - Group

/// Creator-signed group state minus the key. Metadata only; everything a member needs to seal or
/// open traffic lives in `PopopxGroupStore` (key) and here (roster, epoch).
public struct PopopxMeshGroup: Codable, Hashable, Sendable {
    /// Roster size is a wire constraint first (a count byte) and a UX constraint second.
    public static let maxMembers = 16
    public static let idByteCount = 16
    public static let keyByteCount = PopopxGroupSigningIdentity.keyByteCount
    /// Bitchat's `maxGroupNameLength`; the group name is a label, never a routing input.
    public static let maxNameCharacters = 40

    /// 16 random bytes, in the clear on every flooded packet so a keyless relay can dedup and
    /// flood it without being able to read it.
    public let id: Data
    public var name: String
    /// Bumped on every key rotation; a message is bound to the epoch it was sealed under, both in
    /// the AEAD's associated data and in the bytes the sender signs.
    public var epoch: UInt32
    public var members: [PopopxMeshGroupMember]
    /// The only identity allowed to sign group state for this group.
    public let creatorMeshPublicKeyHex: String

    public init?(
        id: Data,
        name: String,
        epoch: UInt32,
        members: [PopopxMeshGroupMember],
        creatorMeshPublicKeyHex: String
    ) {
        guard id.count == Self.idByteCount else { return nil }
        guard creatorMeshPublicKeyHex.count == PopopxMeshIdentity.keyByteCount * 2,
              Data(popopxHex: creatorMeshPublicKeyHex) != nil else { return nil }
        self.id = id
        self.name = PopopxMeshGroup.clampedName(name)
        self.epoch = epoch
        self.members = members
        self.creatorMeshPublicKeyHex = creatorMeshPublicKeyHex.lowercased()
    }

    /// Trim + length cap, nothing else: a group name is chosen by the creator and is not validated
    /// for content, so an empty name is refused rather than replaced with a guess.
    public static func clampedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(Self.maxNameCharacters))
    }

    public static func isValidName(_ raw: String) -> Bool {
        !Self.clampedName(raw).isEmpty
    }

    /// The id this group's traffic is keyed under: first 8 bytes of SHA256(groupID), the same
    /// derivation Bitchat uses for a group's virtual peer id. Not a routable peer — a table key.
    public var peerID: PopopxMeshPeerID { PopopxMeshPeerID(publicKey: id) }

    public var idHex: String { id.popopxHex }

    public var creator: PopopxMeshGroupMember? {
        members.first { $0.meshPublicKeyHex == creatorMeshPublicKeyHex }
    }

    public func isMember(_ meshPublicKeyHex: String) -> Bool {
        members.contains { $0.meshPublicKeyHex == meshPublicKeyHex.lowercased() }
    }

    public func member(withSigningKey signingKey: Data) -> PopopxMeshGroupMember? {
        members.first { $0.signingPublicKey == signingKey }
    }

    public func member(withMeshPublicKeyHex meshPublicKeyHex: String) -> PopopxMeshGroupMember? {
        members.first { $0.meshPublicKeyHex == meshPublicKeyHex.lowercased() }
    }

    /// Whether both name the same creator — fingerprint AND signing key. A group keeps the creator
    /// it was created with: state for a known groupID naming anyone else is a takeover attempt,
    /// however validly it is self-signed.
    public func hasSameCreator(as other: PopopxMeshGroup) -> Bool {
        guard let mine = creator, let theirs = other.creator else { return false }
        return mine.meshPublicKeyHex == theirs.meshPublicKeyHex
            && mine.signingPublicKey == theirs.signingPublicKey
    }

    /// The invariants every stored group satisfies: a well-sized id, a non-empty roster within the
    /// cap, a unique member per peer, and that member's creator in it.
    public var isWellFormed: Bool {
        id.count == Self.idByteCount
            && !members.isEmpty
            && members.count <= Self.maxMembers
            && creator != nil
            && Set(members.map(\.meshPublicKeyHex)).count == members.count
    }
}

// MARK: - Errors

/// Why a group operation did not happen. Named per case because each one has different copy and a
/// different retry: only `.peerNotResolved` and `.delivery` are waiting for the radio.
public enum PopopxMeshGroupError: Error, Hashable, Sendable {
    /// The creator's own signing key is not on this device — it is generated at startup, so this
    /// means the Keychain refused it, which is a real state, not an impossibility.
    case signingIdentityUnavailable
    case nameEmpty
    case notCreator(meshPublicKeyHex: String)
    case groupNotFound(groupIDHex: String)
    /// The key for a group we hold the metadata of is gone from the Keychain. The group is unusable
    /// and says so rather than silently sealing under a fresh key.
    case keyMissing(groupIDHex: String)
    case memberCapReached(limit: Int)
    case alreadyMember(meshPublicKeyHex: String)
    /// The peer named is not in the roster, so there is nothing to remove.
    case memberNotFound(meshPublicKeyHex: String)
    /// The peer named is the creator. Its row is what every member's `applyState` pins the group to,
    /// so a roster without it is a state nobody can believe — the creator leaves by deleting the
    /// group, which is a different operation.
    case cannotRemoveCreator(meshPublicKeyHex: String)
    /// This device is not in the group's roster, so it can neither read it nor write into it.
    case notMember(groupIDHex: String)
    /// We have never heard this peer's announce, so we do not know its signing key and cannot pin
    /// it into a roster we are about to sign. Retrying after the peer announces again is the fix.
    case peerNotResolved(meshPublicKeyHex: String)
    /// The peer's hex is not a mesh public key at all.
    case peerPublicKeyInvalid(meshPublicKeyHex: String)
    /// A roster change that would leave the group with no members.
    case rosterWouldBeEmpty
    /// The local store refused a write (directory or Keychain).
    case storageFailed(String)
    /// State was produced and stored locally but could not be handed to the radio for these peers.
    /// The roster has already advanced: this is reported, not undone.
    case deliveryFailed(peerMeshPublicKeyHexes: [String], failure: PopopxMeshSendFailure)
    /// Inbound state was refused. `PopopxGroupRejection` says which check.
    case rejected(PopopxGroupRejection)
}

/// Which of the ordered inbound checks refused a group state blob. Ordered because the first check
/// that fails is the one worth logging; see `PopopxGroupCoordinator.applyState`.
public enum PopopxGroupRejection: String, Hashable, Sendable {
    case malformed
    case senderIsNotCreator
    case badCreatorSignature
    case creatorPinning
    case epochRegression
    /// Validly signed, but the roster names nobody on this device and we did not hold the group.
    case notInRoster
}

/// A decrypted group message, as it reached one member.
public struct PopopxMeshGroupMessage: Hashable, Sendable {
    public let id: String
    public let groupID: Data
    /// The roster entry the sender's signature matched — i.e. the creator's word on who this is,
    /// not the packet header's.
    public let senderMeshPublicKeyHex: String
    public let senderNickname: String
    public let text: String
    /// From the signed inner bytes: a relay cannot move a message around in time.
    public let sentAt: Date
    /// Hops the flood had taken when this device heard it; 0 for our own echo.
    public let hopCount: Int
    /// True for the copy this device produced itself, so a timeline can show one bubble per message.
    public let isLocal: Bool

    public init(
        id: String,
        groupID: Data,
        senderMeshPublicKeyHex: String,
        senderNickname: String,
        text: String,
        sentAt: Date,
        hopCount: Int,
        isLocal: Bool
    ) {
        self.id = id
        self.groupID = groupID
        self.senderMeshPublicKeyHex = senderMeshPublicKeyHex
        self.senderNickname = senderNickname
        self.text = text
        self.sentAt = sentAt
        self.hopCount = hopCount
        self.isLocal = isLocal
    }

    public var groupIDHex: String { groupID.popopxHex }
}
