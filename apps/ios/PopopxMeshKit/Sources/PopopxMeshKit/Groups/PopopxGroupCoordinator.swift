//
//  PopopxGroupCoordinator.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The group state machine: everything that decides whether a piece of group traffic is believed.
//  It does no I/O — the engine hands it bytes that already arrived and takes back the bytes to put
//  on the radio — which is what makes the ordered security checks below testable without a radio at
//  all, and why this type can be driven from a unit test on macOS.
//
//  The trust model, in one paragraph: a group exists because the creator signed a roster. An invite
//  therefore has to come from the creator's own authenticated Noise session (`senderIsNotCreator`
//  is checked before anything else), the signature is verified against the creator's key as pinned
//  in that roster's own rows, a group already held keeps its creator, and an epoch never moves
//  backwards. A roster that no longer names us means we were removed, and that branch runs before
//  any write — which is exactly Bitchat's order
//  (`bitchat/ViewModels/ChatGroupCoordinator.swift:542-628`), kept because the order IS the property:
//  run the upsert first and a takeover state has already been persisted before it is noticed.
//

import Foundation

// MARK: - Outcomes

/// One signed state blob addressed to one peer. The addressing is part of the value and not a
/// detail: the blob contains a group key, so which copy goes to whom is a security decision, and a
/// removal genuinely needs two different blobs for two different audiences.
public struct PopopxGroupStateSend: Hashable, Sendable {
    public let recipientMeshPublicKeyHex: String
    public let payload: Data

    public init(recipientMeshPublicKeyHex: String, payload: Data) {
        self.recipientMeshPublicKeyHex = recipientMeshPublicKeyHex
        self.payload = payload
    }
}

/// What the coordinator produced for a roster change: the group it describes and the exact copies
/// to put on the radio. Recipients include every existing member, not just the invitee — the key
/// rotated, so a member that is not told cannot read the next message.
public struct PopopxGroupDistribution: Hashable, Sendable {
    public let group: PopopxMeshGroup
    /// One entry per peer, each with the blob that peer is allowed to hold.
    public let sends: [PopopxGroupStateSend]
    public let recipients: [String]
    /// The added or removed member, for copy ("invited X to Y").
    public let changedMemberMeshPublicKeyHex: String
    public let isInvite: Bool

    public init(
        group: PopopxMeshGroup,
        sends: [PopopxGroupStateSend],
        changedMemberMeshPublicKeyHex: String,
        isInvite: Bool
    ) {
        self.group = group
        self.sends = sends
        self.recipients = sends.map(\.recipientMeshPublicKeyHex)
        self.changedMemberMeshPublicKeyHex = changedMemberMeshPublicKeyHex
        self.isInvite = isInvite
    }
}

/// The result of believing — or refusing — an inbound group state blob.
public enum PopopxGroupApplyOutcome: Hashable, Sendable {
    /// We were not in this group before and are now.
    case joined(PopopxMeshGroup)
    /// We already held it and the roster or epoch moved.
    case updated(PopopxMeshGroup)
    /// The creator's signed roster no longer includes us; the group is gone from this device.
    case removed(groupID: Data, name: String)
    /// Nothing changed. `reason` is the first check that fired, in the order above.
    case refused(PopopxGroupRejection, groupIDHex: String?)
}

// MARK: - Coordinator

public actor PopopxGroupCoordinator {
    /// A nickname for the local node to sign into messages with. Display only, and it is the
    /// sender's claim: the roster's name for a member wins when both exist.
    public static let defaultNickname = "POPOPX"

    private let localMeshPublicKeyHex: String
    private let secrets: any PopopxMeshSecretStoring
    private var signingIdentity: PopopxGroupSigningIdentity?
    private let store: PopopxGroupStore
    private let hub: PopopxMeshGroupEventHub
    private let messageDedup: PopopxMeshDeduplicator

    /// Peers whose Ed25519 key we have heard, from their announce. A roster row cannot be written
    /// without one, so this table is also the list of peers that can be invited at all.
    private var signingKeysByMeshHex: [String: Data] = [:]
    private var nicknamesByMeshHex: [String: String] = [:]
    private var localNickname: String

    public init(
        meshPublicKeyHex: String,
        secrets: any PopopxMeshSecretStoring = PopopxMeshKeychain.shared,
        store: PopopxGroupStore? = nil,
        hub: PopopxMeshGroupEventHub = .shared,
        signingIdentity: PopopxGroupSigningIdentity? = nil
    ) {
        self.localMeshPublicKeyHex = meshPublicKeyHex.lowercased()
        self.secrets = secrets
        self.signingIdentity = signingIdentity
            ?? PopopxGroupSigningIdentity.loadOrMake(secrets: secrets)
        self.store = store ?? PopopxGroupStore(secrets: secrets)
        self.hub = hub
        self.messageDedup = PopopxMeshDeduplicator()
        self.localNickname = Self.defaultNickname
    }

    // MARK: Identity and peer directory

    public var localMeshPublicKeyHexValue: String { localMeshPublicKeyHex }

    public var localSigningPublicKeyHex: String? { signingIdentity?.publicKeyHex }

    /// The name the engine advertises and signs into group messages.
    public func setLocalNickname(_ nickname: String) {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        localNickname = trimmed.isEmpty ? Self.defaultNickname : PopopxMeshGroupMember.clampedNickname(trimmed)
    }

    /// Learned from a neighbour's announce. Unsigned like the announce itself, which is why it is
    /// only ever an input to a roster the CREATOR signs and later verifies.
    public func recordPeer(
        meshPublicKeyHex: String,
        signingPublicKeyHex: String,
        nickname: String?
    ) {
        let hex = meshPublicKeyHex.lowercased()
        guard hex.count == PopopxMeshIdentity.keyByteCount * 2,
              signingPublicKeyHex.count == PopopxGroupSigningIdentity.keyByteCount * 2,
              let signingKey = Data(popopxHex: signingPublicKeyHex),
              signingKey.count == PopopxGroupSigningIdentity.keyByteCount else { return }
        signingKeysByMeshHex[hex] = signingKey
        if let nickname, !nickname.isEmpty { nicknamesByMeshHex[hex] = nickname }
    }

    /// Roster rows we have accepted are the strongest source of a member's signing key: they are
    /// creator-signed. Kept in the same table so a peer that never announced is still invitable by
    /// the creator after being invited by hand.
    private func recordRoster(_ members: [PopopxMeshGroupMember]) {
        for member in members {
            signingKeysByMeshHex[member.meshPublicKeyHex] = member.signingPublicKey
            if !member.nickname.isEmpty { nicknamesByMeshHex[member.meshPublicKeyHex] = member.nickname }
        }
    }

    // MARK: - Reads

    public func groups() async -> [PopopxMeshGroup] {
        await store.allGroups()
    }

    public func group(id: Data) async throws(PopopxMeshGroupError) -> PopopxMeshGroup {
        guard let group = await store.group(withID: id) else {
            throw PopopxMeshGroupError.groupNotFound(groupIDHex: id.popopxHex)
        }
        return group
    }

    public func members(of id: Data) async -> [PopopxMeshGroupMember] {
        (await store.group(withID: id))?.members ?? []
    }

    /// Whether this device created the group — the only identity allowed to change its roster.
    public func isCreator(of id: Data) async -> Bool {
        await store.group(withID: id)?.creatorMeshPublicKeyHex == localMeshPublicKeyHex
    }

    /// Peers this device could currently put into a roster, i.e. whose signing key it has heard.
    /// The cache also holds this device's own row, once a roster named it, and a creator is not a
    /// peer it can invite.
    public func invitablePeers() -> [String] {
        signingKeysByMeshHex.keys
            .filter { $0.lowercased() != localMeshPublicKeyHex }
            .sorted()
    }

    // MARK: - Creator-side mutations

    /// Creates a group at epoch 1 with the creator as sole member. No radio traffic: the group
    /// exists the moment the id and key are generated and the key is in the Keychain.
    public func createGroup(named rawName: String) async throws(PopopxMeshGroupError) -> PopopxMeshGroup {
        guard let identity = signingIdentity else { throw PopopxMeshGroupError.signingIdentityUnavailable }
        let name = PopopxMeshGroup.clampedName(rawName)
        guard !name.isEmpty else { throw PopopxMeshGroupError.nameEmpty }
        guard let creator = PopopxMeshGroupMember(
            meshPublicKeyHex: localMeshPublicKeyHex,
            signingPublicKey: identity.publicKey,
            nickname: localNickname
        ) else { throw PopopxMeshGroupError.storageFailed("local member not constructible") }
        recordRoster([creator])
        let (group, _) = try await store.createGroup(named: name, creator: creator)
        await hub.publish(.changed(group))
        return group
    }

    /// Builds the state an invite carries: the roster grows by one, the key rotates, the epoch moves
    /// up, and the creator signs the result. The blob contains the new key, so it goes to exactly
    /// the people named in it — 1:1 over each member's Noise session, never flooded.
    public func invite(
        peerMeshPublicKeyHex rawPeer: String,
        toGroupID id: Data
    ) async throws(PopopxMeshGroupError) -> PopopxGroupDistribution {
        let peer = rawPeer.lowercased()
        guard PopopxMeshControlFrame.isMeshPublicKey(peer), peer.count == PopopxMeshIdentity.keyByteCount * 2,
              Data(popopxHex: peer) != nil else {
            throw PopopxMeshGroupError.peerPublicKeyInvalid(meshPublicKeyHex: rawPeer)
        }
        guard let group = await store.group(withID: id) else {
            throw PopopxMeshGroupError.groupNotFound(groupIDHex: id.popopxHex)
        }
        guard group.creatorMeshPublicKeyHex == localMeshPublicKeyHex else {
            throw PopopxMeshGroupError.notCreator(meshPublicKeyHex: group.creatorMeshPublicKeyHex)
        }
        guard group.members.count < PopopxMeshGroup.maxMembers else {
            throw PopopxMeshGroupError.memberCapReached(limit: PopopxMeshGroup.maxMembers)
        }
        guard group.member(withMeshPublicKeyHex: peer) == nil else {
            throw PopopxMeshGroupError.alreadyMember(meshPublicKeyHex: peer)
        }
        guard let signingKey = signingKeysByMeshHex[peer] else {
            throw PopopxMeshGroupError.peerNotResolved(meshPublicKeyHex: peer)
        }
        guard let member = PopopxMeshGroupMember(
            meshPublicKeyHex: peer,
            signingPublicKey: signingKey,
            nickname: nicknamesByMeshHex[peer] ?? String(peer.prefix(8))
        ) else { throw PopopxMeshGroupError.peerNotResolved(meshPublicKeyHex: peer) }

        // A key rotation on every roster change, not just on removals: two invites that arrive out of
        // order can then no longer share an epoch and last-write-wins a just-added member back out.
        return try await distribute(
            groupID: id,
            members: group.members + [member],
            changedMember: peer,
            isInvite: true
        )
    }

    /// Creator-side removal: the key rotates so the removed member's copy stops decrypting future
    /// traffic, and the new state goes to everyone who remains — the removed peer included, because
    /// that is the notice (Bitchat sends it too, with a throwaway key, so the removee cannot read
    /// anything sealed afterwards; here the state names no key the removee can use because their
    /// own roster row is gone, which is the same outcome arrived at differently).
    public func removeMember(
        _ peerMeshPublicKeyHex: String,
        fromGroupID id: Data
    ) async throws(PopopxMeshGroupError) -> PopopxGroupDistribution {
        let peer = peerMeshPublicKeyHex.lowercased()
        guard let group = await store.group(withID: id) else {
            throw PopopxMeshGroupError.groupNotFound(groupIDHex: id.popopxHex)
        }
        guard group.creatorMeshPublicKeyHex == localMeshPublicKeyHex else {
            throw PopopxMeshGroupError.notCreator(meshPublicKeyHex: group.creatorMeshPublicKeyHex)
        }
        guard group.member(withMeshPublicKeyHex: peer) != nil else {
            throw PopopxMeshGroupError.memberNotFound(meshPublicKeyHex: peer)
        }
        // The creator is the group's trust root: a roster without it is a state no member can
        // believe (`applyState` pins the creator), so removing it is not a roster change but a
        // different operation — delete the group, which module 8 does not offer yet.
        guard peer != group.creatorMeshPublicKeyHex else {
            throw PopopxMeshGroupError.cannotRemoveCreator(meshPublicKeyHex: peer)
        }
        let remaining = group.members.filter { $0.meshPublicKeyHex != peer }
        guard !remaining.isEmpty else { throw PopopxMeshGroupError.rosterWouldBeEmpty }
        return try await distribute(
            groupID: id,
            members: remaining,
            changedMember: peer,
            isInvite: false
        )
    }

    private func distribute(
        groupID id: Data,
        members: [PopopxMeshGroupMember],
        changedMember: String,
        isInvite: Bool
    ) async throws(PopopxMeshGroupError) -> PopopxGroupDistribution {
        guard let identity = signingIdentity else { throw PopopxMeshGroupError.signingIdentityUnavailable }
        let (rotated, key) = try await store.rotateKey(groupID: id, members: members)

        let sharedPayload = try signedBlob(group: rotated, key: key, signing: identity)
        // Our own row gets no send: `rotateKey` already wrote this state into our store, and the
        // engine has no Noise session with itself — a self-addressed blob would be reported as a
        // delivery failure for a message that never needed sending.
        var sends: [PopopxGroupStateSend] = rotated.members
            .filter { $0.meshPublicKeyHex != localMeshPublicKeyHex }
            .map { member in
                PopopxGroupStateSend(
                    recipientMeshPublicKeyHex: member.meshPublicKeyHex,
                    // The new member's copy and every existing member's copy are the same bytes: all
                    // of them are entitled to the current key.
                    payload: sharedPayload
                )
            }
        if !isInvite, changedMember != localMeshPublicKeyHex {
            // The removee gets the roster that says it is out, but not the key that proves it: an
            // honest state signed with a throwaway key. Handing it the real one would mean a removed
            // member keeps reading traffic it was rotated out of — the whole point of rotating.
            let throwaway = Data(count: PopopxMeshGroup.keyByteCount)
            let notice = try signedBlob(group: rotated, key: throwaway, signing: identity)
            sends.append(PopopxGroupStateSend(recipientMeshPublicKeyHex: changedMember, payload: notice))
        }
        await hub.publish(.changed(rotated))
        return PopopxGroupDistribution(
            group: rotated,
            sends: sends,
            changedMemberMeshPublicKeyHex: changedMember,
            isInvite: isInvite
        )
    }

    private func signedBlob(
        group: PopopxMeshGroup,
        key: Data,
        signing identity: PopopxGroupSigningIdentity
    ) throws(PopopxMeshGroupError) -> Data {
        guard let payload = PopopxGroupStatePayload.makeSigned(group: group, key: key, sign: { identity.sign($0) }),
              let blob = payload.encoded() else {
            throw PopopxMeshGroupError.storageFailed("group state could not be signed and encoded")
        }
        return blob
    }

    // MARK: - Inbound state

    /// Believes, or refuses, a creator-signed state blob. `senderMeshPublicKeyHex` must be the peer
    /// the Noise session authenticated, not the packet header's claim — the caller is the engine,
    /// which is the only thing here that knows which.
    public func applyState(
        _ blob: Data,
        fromMeshPublicKeyHex senderMeshPublicKeyHex: String
    ) async -> PopopxGroupApplyOutcome {
        guard let state = PopopxGroupStatePayload.decoded(blob) else {
            PopopxMeshLog.route.debug("🚫 malformed group state payload")
            await hub.publish(.stateRefused(groupIDHex: nil, reason: .malformed))
            return .refused(.malformed, groupIDHex: nil)
        }
        let sender = senderMeshPublicKeyHex.lowercased()
        // The session already authenticated the sender; require that it IS the creator this state
        // names, so a member cannot re-invite or rotate on the creator's behalf.
        guard sender == state.creatorMeshPublicKeyHex else {
            PopopxMeshLog.route.warning(
                "🚫 group state from non-creator \(sender.prefix(8), privacy: .public) refused"
            )
            await hub.publish(.stateRefused(groupIDHex: state.id.popopxHex, reason: .senderIsNotCreator))
            return .refused(.senderIsNotCreator, groupIDHex: state.id.popopxHex)
        }
        // Verified against the creator's key as pinned in this state's own roster.
        guard state.verifyCreatorSignature() else {
            PopopxMeshLog.route.warning("🚫 group state with an invalid creator signature refused")
            await hub.publish(.stateRefused(groupIDHex: state.id.popopxHex, reason: .badCreatorSignature))
            return .refused(.badCreatorSignature, groupIDHex: state.id.popopxHex)
        }
        guard let incoming = state.asGroup else {
            await hub.publish(.stateRefused(groupIDHex: state.id.popopxHex, reason: .malformed))
            return .refused(.malformed, groupIDHex: state.id.popopxHex)
        }

        let existing = await store.group(withID: state.id)
        if let existing {
            // The checks above only prove the sender is the creator the state *claims* — anyone can
            // name themselves and self-sign — so a group we already hold keeps its own creator.
            guard existing.hasSameCreator(as: incoming) else {
                PopopxMeshLog.route.warning(
                    "🚫 group state claiming a different creator for \(state.id.popopxHex.prefix(16), privacy: .public) refused"
                )
                await hub.publish(.stateRefused(groupIDHex: state.id.popopxHex, reason: .creatorPinning))
                return .refused(.creatorPinning, groupIDHex: state.id.popopxHex)
            }
            // Never regress: state arrives over live sessions, so an older epoch is a stale or
            // misbehaving creator device. That includes a stale removal, which must not undo a later
            // re-invite.
            guard state.epoch >= existing.epoch else {
                PopopxMeshLog.route.warning(
                    "🚫 stale group state (epoch \(state.epoch) < \(existing.epoch)) refused"
                )
                await hub.publish(.stateRefused(groupIDHex: state.id.popopxHex, reason: .epochRegression))
                return .refused(.epochRegression, groupIDHex: state.id.popopxHex)
            }
        }

        // Both existing-group checks ran above, so a removal below cannot be reached by a state that
        // failed either.
        guard state.members.contains(where: { $0.meshPublicKeyHex == localMeshPublicKeyHex }) else {
            if let existing {
                await store.removeGroup(withID: existing.id)
                await hub.publish(.removed(groupID: existing.id, name: existing.name))
                PopopxMeshLog.route.notice(
                    "✂️ removed from group \(existing.name, privacy: .public) by the creator's roster"
                )
                return .removed(groupID: existing.id, name: existing.name)
            }
            // A state we are not named in and do not hold is not ours to keep.
            return .refused(.notInRoster, groupIDHex: state.id.popopxHex)
        }

        let isNewMembership = existing == nil
        do {
            try await store.upsert(incoming, key: state.key)
        } catch {
            PopopxMeshLog.store.error("🚫 group state could not be stored: \(String(describing: error), privacy: .public)")
            return .refused(.malformed, groupIDHex: state.id.popopxHex)
        }
        recordRoster(incoming.members)
        await hub.publish(.changed(incoming))
        if isNewMembership {
            PopopxMeshLog.route.notice("👥 joined group \(incoming.name, privacy: .public) at epoch \(incoming.epoch)")
        } else {
            PopopxMeshLog.route.notice("👥 group \(incoming.name, privacy: .public) moved to epoch \(incoming.epoch)")
        }
        return isNewMembership ? .joined(incoming) : .updated(incoming)
    }

    // MARK: - Messages

    /// Seals one message for a group and returns both the bytes to flood and the local copy for the
    /// timeline. The epoch the message is sealed under is the one in the AAD and the signed bytes, so
    /// a member removed by the next rotation cannot read it even if it kept the old ciphertext.
    public func sealMessage(
        _ text: String,
        toGroupID id: Data
    ) async throws(PopopxMeshGroupError) -> (payload: Data, message: PopopxMeshGroupMessage) {
        guard let identity = signingIdentity else { throw PopopxMeshGroupError.signingIdentityUnavailable }
        guard let group = await store.group(withID: id) else {
            throw PopopxMeshGroupError.groupNotFound(groupIDHex: id.popopxHex)
        }
        guard group.isMember(localMeshPublicKeyHex) else {
            throw PopopxMeshGroupError.notMember(groupIDHex: id.popopxHex)
        }
        guard let key = await store.key(forGroupID: id) else {
            throw PopopxMeshGroupError.keyMissing(groupIDHex: id.popopxHex)
        }
        let messageID = PopopxGroupCrypto.makeMessageID()
        let timestampMs = PopopxMeshPacket.nowMillis
        // The coordinator's own failure set is what a caller sees; a seal failure is one reason
        // string, because the crypto error's own wording belongs in the log, not in the API.
        let payload: Data
        do {
            payload = try PopopxGroupCrypto.sealMessage(
                content: text,
                messageID: messageID,
                senderNickname: localNickname,
                senderSigningPublicKey: identity.publicKey,
                timestampMs: timestampMs,
                groupID: id,
                epoch: group.epoch,
                key: key,
                sign: { identity.sign($0) }
            )
        } catch {
            // `sealMessage` throws the untyped error set CryptoKit can raise, so this is the one
            // place that turns "the AEAD or the signature refused" into a group failure.
            throw PopopxMeshGroupError.storageFailed("seal failed: \(String(describing: error))")
        }
        let message = PopopxMeshGroupMessage(
            id: messageID,
            groupID: id,
            senderMeshPublicKeyHex: localMeshPublicKeyHex,
            senderNickname: localNickname,
            text: text,
            sentAt: .now,
            hopCount: 0,
            isLocal: true
        )
        // Remembered here so our own echo, relayed back by a neighbour, is a duplicate rather than a
        // second bubble.
        _ = await messageDedup.noteMessage(id: messageID)
        await hub.publish(.message(message))
        return (payload, message)
    }

    /// Opens a flooded payload. nil is the normal answer for a node that is not in the group: it
    /// relays what it cannot read, and the reason is logged, not surfaced.
    public func receiveMessage(
        _ payload: Data,
        hopCount: Int
    ) async -> PopopxMeshGroupMessage? {
        guard let envelope = PopopxGroupMessageEnvelope.decoded(payload) else {
            PopopxMeshLog.route.debug("🚫 group message payload not TLV-framed, dropped")
            return nil
        }
        guard let group = await store.group(withID: envelope.groupID) else {
            // Not our group: we are the relay. This is the common case on a mesh, so it is a debug
            // line at most and never a user-visible failure.
            return nil
        }
        guard envelope.epoch == group.epoch else {
            PopopxMeshLog.route.debug(
                "🚫 group message at epoch \(envelope.epoch) vs held \(group.epoch) dropped"
            )
            return nil
        }
        guard let key = await store.key(forGroupID: envelope.groupID) else {
            PopopxMeshLog.store.error(
                "🚫 group message for \(group.name, privacy: .public) unreadable: key missing"
            )
            return nil
        }
        let plaintext: PopopxGroupMessagePlaintext
        do {
            plaintext = try PopopxGroupCrypto.openMessage(envelope, key: key)
        } catch {
            PopopxMeshLog.route.debug(
                "🚫 group message could not be opened: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
        // Key possession is not authorship: the signer has to be a row the creator signed.
        guard let member = group.member(withSigningKey: plaintext.senderSigningPublicKey) else {
            PopopxMeshLog.route.warning("🚫 group message from a non-roster signer dropped")
            return nil
        }
        guard member.meshPublicKeyHex != localMeshPublicKeyHex else { return nil }
        guard await messageDedup.noteMessage(id: plaintext.id) else {
            PopopxMeshLog.route.debug("🚫 duplicate group message \(plaintext.id.prefix(8), privacy: .public) dropped")
            return nil
        }
        let name = member.nickname.isEmpty ? plaintext.senderNickname : member.nickname
        let message = PopopxMeshGroupMessage(
            id: plaintext.id,
            groupID: envelope.groupID,
            senderMeshPublicKeyHex: member.meshPublicKeyHex,
            senderNickname: name,
            text: plaintext.text,
            sentAt: plaintext.sentAt,
            hopCount: hopCount,
            isLocal: false
        )
        await hub.publish(.message(message))
        return message
    }

    // MARK: - Housekeeping

    /// Panic wipe (module 7) without the identity change: metadata and keys go, the signing key stays
    /// because a node that keeps talking on the mesh must keep the roster rows that pinned it.
    public func wipe() async {
        await store.wipe()
    }

    /// Panic wipe (module 7), group half. `PopopxMeshEngine.destroyIdentity()` cannot fold this in: it
    /// is synchronous and app-facing, and this is an actor hop plus a file removal.
    ///
    /// Order matters. The signing key is the last thing to leave, and only after every group is
    /// gone — a roster row that pinned the old key can never be satisfied by this device again once
    /// the mesh identity is burned too, so burning it here is the honest move rather than keeping a
    /// key that can only produce states every peer will refuse. `loadOrMake` then mints and
    /// PERSISTS a fresh one, so group creation works again in the same session instead of throwing
    /// `signingIdentityUnavailable` until relaunch.
    public func destroyAll() async {
        let groups = await store.allGroups()
        do {
            try secrets.removeAll(service: PopopxGroupSigningIdentity.keychainService)
        } catch {
            PopopxMeshLog.store.error(
                "❌ group secrets not removed: \(String(describing: error), privacy: .public)"
            )
        }
        signingKeysByMeshHex = [:]
        nicknamesByMeshHex = [:]
        signingIdentity = nil
        await store.wipe()
        signingIdentity = PopopxGroupSigningIdentity.loadOrMake(secrets: secrets)
        for group in groups {
            await hub.publish(.removed(groupID: group.id, name: group.name))
        }
    }
}
