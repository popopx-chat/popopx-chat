//
//  PopopxMeshGroupTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Module 8's trust boundaries, tested where they are decided: the AEAD (an epoch key that is not the
//  group's opens nothing, and so does a moved epoch or a flipped byte), the creator-signed state (who
//  may change a roster, whether its signature came from the creator the roster pins, and which
//  creator a known group id keeps), the rotation (a removed member stops reading on the very next
//  message), and the flood (a node without the key carries the packet and learns nothing).
//
//  Nothing here touches the real Keychain or the real sandbox: every node gets an in-memory
//  `PopopxMeshSecretStoring`, its own temporary directory and a signing identity the test holds, so a
//  forged state can be signed with a key the test controls. The engine's `receive` is `fileprivate`,
//  so mesh-level frames enter the way CoreBluetooth hands them in — the public
//  `PopopxBLETransportDelegate` callback — and a frame leaves the way it goes out the air, through a
//  transport that only records.
//

import Foundation
import PopopxMeshKit
import Testing

// MARK: - Test doubles

/// In-memory Keychain, one per node: a group's key really is that node's own secret, and a member
/// cannot read another member's store by accident.
private final class FakeSecrets: PopopxMeshSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    private static func key(_ service: String, _ account: String) -> String {
        service + "\u{1}" + account
    }

    func data(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[Self.key(service, account)]
    }

    func set(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[Self.key(service, account)] = data
    }

    func remove(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[Self.key(service, account)] = nil
    }

    func removeAll(service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        for stored in items.keys where stored.hasPrefix(service + "\u{1}") {
            items[stored] = nil
        }
    }
}

/// A radio that records what it was asked to transmit and delivers nothing by itself: the test is the
/// wire, and it decides which node hears which frame.
private final class FakeMeshTransport: PopopxBLETransporting, @unchecked Sendable {
    private let lock = TestMutex()
    private var sentFrames: [Data] = []
    private let linkTable: [PopopxBLELink]

    init() {
        linkTable = [PopopxBLELink(isCentralRole: true, canSend: true, negotiatedMTU: 517)]
    }

    var state: PopopxBluetoothState { get async { .poweredOn } }
    var links: [PopopxBLELink] { get async { linkTable } }
    var linkID: UUID { linkTable[0].linkID }
    /// A link this transport never opened — stands in for "a frame arrived from a neighbour".
    var ingressLinkID: UUID { UUID() }

    var frames: [Data] {
        lock.withLock { sentFrames }
    }

    var packets: [PopopxMeshPacket] { frames.compactMap { PopopxMeshPacket.decode($0) } }

    func packets(of type: PopopxMeshMessageType) -> [PopopxMeshPacket] {
        packets.filter { $0.decodedType == type }
    }

    func setDelegate(_ delegate: (any PopopxBLETransportDelegate)?) async {}
    func start() async {}
    func stop() async {}

    func send(_ data: Data, to linkID: UUID) async -> Bool {
        lock.withLock {
            sentFrames.append(data)
            return true
        }
    }

    func notifySubscribers(_ data: Data) async {
        lock.withLock { sentFrames.append(data) }
    }

    func connect(to linkID: UUID) async {}
    func disconnect(_ linkID: UUID) async {}
}

/// Counts what a group hub published, for the assertions about silence: a keyless relay publishes
/// nothing. `watch` subscribes before returning, so nothing is published into a gap left by the task.
private final class GroupEventLog: @unchecked Sendable {
    private let lock = TestMutex()
    private var events: [PopopxMeshGroupEvent] = []
    private var task: Task<Void, Never>?

    func watch(_ hub: PopopxMeshGroupEventHub) async {
        let stream = await hub.subscribe()
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.lock.withLock { self.events.append(event) }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func count(_ matches: (PopopxMeshGroupEvent) -> Bool) -> Int {
        lock.withLock { events.filter(matches).count }
    }

    var messageCount: Int {
        count { event in
            if case .message = event { return true }
            return false
        }
    }

    var refusalCount: Int {
        count { event in
            if case .stateRefused = event { return true }
            return false
        }
    }
}

// MARK: - Harness

private func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("popopx-group-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls until the condition holds or the deadline passes. Every mesh assertion here is about bytes
/// that left one actor and reached another through a `Task`; a fixed sleep would be either flaky or
/// slow, and the deadline is deliberately generous.
private func until(timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// One device's whole group stack: its own mesh identity, its own signing key (held by the test so a
/// forged state can be signed with it), its own store and its own hub.
private struct GroupNode {
    let coordinator: PopopxGroupCoordinator
    let store: PopopxGroupStore
    let hub: PopopxMeshGroupEventHub
    let secrets: FakeSecrets
    let directory: URL
    let meshHex: String
    let signing: PopopxGroupSigningIdentity

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeGroupNode(nickname: String) async throws -> GroupNode {
    let secrets = FakeSecrets()
    let directory = try temporaryDirectory()
    let identity = PopopxMeshIdentity.generate()
    let signing = PopopxGroupSigningIdentity.loadOrMake(secrets: secrets)
    let store = PopopxGroupStore(secrets: secrets, directory: directory)
    let hub = PopopxMeshGroupEventHub()
    let coordinator = PopopxGroupCoordinator(
        meshPublicKeyHex: identity.meshPublicKeyHex,
        secrets: secrets,
        store: store,
        hub: hub,
        signingIdentity: signing
    )
    await coordinator.setLocalNickname(nickname)
    let meshHex = await coordinator.localMeshPublicKeyHexValue
    return GroupNode(
        coordinator: coordinator,
        store: store,
        hub: hub,
        secrets: secrets,
        directory: directory,
        meshHex: meshHex,
        signing: signing
    )
}

/// What one invite produced: the outcome for the peer, the blob the peer was sent, and the whole
/// distribution so a test can see who else was addressed.
private struct InviteResult {
    let outcome: PopopxGroupApplyOutcome
    let blob: Data
    let distribution: PopopxGroupDistribution
}

/// The creator learns the peer's signing key the way the engine learns it — from the announce — then
/// invites it, and the invite is applied by the peer as though it had arrived over the Noise session
/// that authenticated the creator.
private func invite(
    _ peer: GroupNode,
    into group: PopopxMeshGroup,
    by creator: GroupNode,
    nickname: String = "Peer"
) async throws -> InviteResult {
    await creator.coordinator.recordPeer(
        meshPublicKeyHex: peer.meshHex,
        signingPublicKeyHex: peer.signing.publicKeyHex,
        nickname: nickname
    )
    let distribution = try await creator.coordinator.invite(
        peerMeshPublicKeyHex: peer.meshHex,
        toGroupID: group.id
    )
    let blob = try #require(distribution.sends.first {
        $0.recipientMeshPublicKeyHex == peer.meshHex
    }?.payload)
    let outcome = await peer.coordinator.applyState(blob, fromMeshPublicKeyHex: creator.meshHex)
    return InviteResult(outcome: outcome, blob: blob, distribution: distribution)
}

/// Signs a state for `group` with the given key and signer, and encodes it — the test's stand-in for
/// "a creator put this on the radio", valid or forged as the case requires.
private func signedState(
    group: PopopxMeshGroup,
    key: Data,
    signer: PopopxGroupSigningIdentity
) throws -> Data {
    let payload = try #require(
        PopopxGroupStatePayload.makeSigned(group: group, key: key, sign: { signer.sign($0) })
    )
    return try #require(payload.encoded())
}

private func joinedGroup(_ outcome: PopopxGroupApplyOutcome) throws -> PopopxMeshGroup {
    switch outcome {
    case let .joined(group), let .updated(group): group
    case let .removed(_, name): throw HarnessFailure("expected a membership, got a removal of \(name)")
    case let .refused(reason, id): throw HarnessFailure("refused \(reason.rawValue) for \(id ?? "nil")")
    }
}

/// The harness's own failure, so a wrong outcome says what happened instead of trapping.
private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

// MARK: - Seal and open

@Test("a sealed group message opens for the member the creator invited")
func sealOpenRoundTrip() async throws {
    let creator = try await makeGroupNode(nickname: "Creator")
    let member = try await makeGroupNode(nickname: "Member")
    defer { creator.cleanUp(); member.cleanUp() }

    let group = try await creator.coordinator.createGroup(named: "Cabin")
    #expect(group.epoch == 1)
    #expect(group.members.count == 1)
    #expect(await creator.store.group(withID: group.id)?.name == "Cabin")

    let result = try await invite(member, into: group, by: creator, nickname: "Member")
    let joined = try joinedGroup(result.outcome)
    // A key rotation on every roster change: the invite itself is already epoch 2.
    #expect(joined.epoch == 2)
    #expect(joined.members.count == 2)
    #expect(await member.store.key(forGroupID: group.id) != nil)
    let memberKey = await member.store.key(forGroupID: group.id)
    let creatorKey = await creator.store.key(forGroupID: group.id)
    #expect(memberKey == creatorKey)

    let (payload, localCopy) = try await creator.coordinator.sealMessage("row 7 seat 3", toGroupID: group.id)
    #expect(localCopy.isLocal)
    #expect(localCopy.text == "row 7 seat 3")
    #expect(localCopy.hopCount == 0)

    let opened = try #require(await member.coordinator.receiveMessage(payload, hopCount: 2))
    #expect(opened.text == "row 7 seat 3")
    #expect(opened.groupID == group.id)
    #expect(opened.id == localCopy.id)
    // The sender is named by the roster row the signature matched, and the hop count is this node's
    // own view of the flood, not the sender's claim.
    #expect(opened.senderMeshPublicKeyHex == creator.meshHex)
    #expect(opened.hopCount == 2)
    #expect(!opened.isLocal)
    #expect(opened.senderNickname == "Creator")
}

@Test("a wrong key, a moved epoch, another group and a flipped byte all open nothing")
func wrongKeyAndTamperedFramesAreRefused() async throws {
    let creator = try await makeGroupNode(nickname: "Creator")
    defer { creator.cleanUp() }
    let group = try await creator.coordinator.createGroup(named: "Keys")
    let key = try #require(await creator.store.key(forGroupID: group.id))
    let (payload, _) = try await creator.coordinator.sealMessage("weather", toGroupID: group.id)
    let envelope = try #require(PopopxGroupMessageEnvelope.decoded(payload))
    // Sanity: the real key does open it, so every refusal below is about the field that changed.
    #expect(try PopopxGroupCrypto.openMessage(envelope, key: key).text == "weather")

    var wrongKey = key
    wrongKey[0] ^= 0x01
    #expect(throws: PopopxGroupCryptoError.self) {
        _ = try PopopxGroupCrypto.openMessage(envelope, key: wrongKey)
    }
    #expect(throws: PopopxGroupCryptoError.self) {
        _ = try PopopxGroupCrypto.openMessage(envelope, key: Data(count: 16))
    }

    // The epoch is in the associated data, so a valid packet replayed under another epoch dies before
    // the key is consulted — and a key rotated by the next invite cannot read what it was rotated out
    // of, even with the ciphertext in hand.
    let movedEpoch = try #require(
        PopopxGroupMessageEnvelope(
            groupID: envelope.groupID, epoch: envelope.epoch &+ 1,
            nonce: envelope.nonce, ciphertext: envelope.ciphertext
        )
    )
    #expect(throws: PopopxGroupCryptoError.self) {
        _ = try PopopxGroupCrypto.openMessage(movedEpoch, key: key)
    }

    var otherGroup = envelope.groupID
    otherGroup[15] ^= 0xFF
    let movedGroup = try #require(
        PopopxGroupMessageEnvelope(
            groupID: otherGroup, epoch: envelope.epoch,
            nonce: envelope.nonce, ciphertext: envelope.ciphertext
        )
    )
    #expect(throws: PopopxGroupCryptoError.self) {
        _ = try PopopxGroupCrypto.openMessage(movedGroup, key: key)
    }

    var tampered = envelope.ciphertext
    tampered[tampered.count - 5] ^= 0x80
    let flipped = try #require(
        PopopxGroupMessageEnvelope(
            groupID: envelope.groupID, epoch: envelope.epoch,
            nonce: envelope.nonce, ciphertext: tampered
        )
    )
    #expect(throws: PopopxGroupCryptoError.self) {
        _ = try PopopxGroupCrypto.openMessage(flipped, key: key)
    }
}

@Test("a member cannot change a roster, and holding the key is not authorship")
func keyPossessionIsNotAuthorship() async throws {
    let creator = try await makeGroupNode(nickname: "Creator")
    let member = try await makeGroupNode(nickname: "Member")
    defer { creator.cleanUp(); member.cleanUp() }

    let group = try await creator.coordinator.createGroup(named: "Authorship")
    _ = try await invite(member, into: group, by: creator, nickname: "Member")
    // The member holds the group key, which is enough to seal a readable message…
    let (payload, _) = try await member.coordinator.sealMessage("from the member", toGroupID: group.id)
    #expect(await creator.coordinator.receiveMessage(payload, hopCount: 0)?.text == "from the member")
    // …and not enough to change the roster.
    await #expect(throws: PopopxMeshGroupError.notCreator(meshPublicKeyHex: creator.meshHex)) {
        _ = try await member.coordinator.invite(
            peerMeshPublicKeyHex: creator.meshHex,
            toGroupID: group.id
        )
    }
    await #expect(throws: PopopxMeshGroupError.notCreator(meshPublicKeyHex: creator.meshHex)) {
        _ = try await member.coordinator.removeMember(creator.meshHex, fromGroupID: group.id)
    }

    // A state the member signs itself: internally well-formed, and signed by a key the roster does not
    // name as the creator.
    let current = try #require(await member.store.group(withID: group.id))
    let key = try #require(await member.store.key(forGroupID: group.id))
    let forged = try signedState(group: current, key: key, signer: member.signing)
    let decoded = try #require(PopopxGroupStatePayload.decoded(forged))
    #expect(decoded.verifyCreatorSignature() == false)
    // Sent by a peer claiming to be the creator, the signature check is what stops it — the sender
    // check alone would not, because the state really does name the creator.
    let outcome = await creator.coordinator.applyState(forged, fromMeshPublicKeyHex: creator.meshHex)
    guard case let .refused(reason, refusedID) = outcome else {
        Issue.record("a member-signed state should be refused, got \(outcome)")
        return
    }
    #expect(reason == .badCreatorSignature)
    #expect(refusedID == group.idHex)
    #expect(await creator.coordinator.members(of: group.id).count == 2)
}

// MARK: - Who may sign a roster

@Test("state from anyone but the creator is refused, and a known group keeps its creator")
func nonCreatorAndTakeoverStatesAreRefused() async throws {
    let creator = try await makeGroupNode(nickname: "Creator")
    let member = try await makeGroupNode(nickname: "Member")
    let stranger = try await makeGroupNode(nickname: "Stranger")
    defer { creator.cleanUp(); member.cleanUp(); stranger.cleanUp() }

    let group = try await creator.coordinator.createGroup(named: "Cabin")
    let result = try await invite(member, into: group, by: creator, nickname: "Member")
    let current = try joinedGroup(result.outcome)
    let _ = try #require(await creator.store.key(forGroupID: group.id))

    // The same valid state, but the caller says a different peer sent it. In the engine that claim
    // comes out of the Noise handshake, which is why it is the check that runs first.
    let wrongSender = await member.coordinator.applyState(result.blob, fromMeshPublicKeyHex: stranger.meshHex)
    guard case let .refused(reason, refusedID) = wrongSender else {
        Issue.record("a non-creator sender should be refused, got \(wrongSender)")
        return
    }
    #expect(reason == .senderIsNotCreator)
    #expect(refusedID == group.idHex)

    // A takeover: a state that names a new creator and signs its own roster, for the same group id.
    // It is internally valid — the signature checks out against the row it carries — which is exactly
    // why the group's pinned creator has to be the one that decides.
    let usurperRow = try #require(
        PopopxMeshGroupMember(
            meshPublicKeyHex: stranger.meshHex,
            signingPublicKey: stranger.signing.publicKey,
            nickname: "Usurper"
        )
    )
    let takeoverGroup = try #require(
        PopopxMeshGroup(
            id: group.id,
            name: current.name,
            epoch: current.epoch &+ 1,
            members: [usurperRow],
            creatorMeshPublicKeyHex: stranger.meshHex
        )
    )
    let takeover = try signedState(
        group: takeoverGroup,
        key: Data(repeating: 0x07, count: PopopxMeshGroup.keyByteCount),
        signer: stranger.signing
    )
    let decodedTakeover = try #require(PopopxGroupStatePayload.decoded(takeover))
    // Valid on its own terms, which is the point: only pinning catches it.
    #expect(decodedTakeover.verifyCreatorSignature())
    let pinned = await member.coordinator.applyState(takeover, fromMeshPublicKeyHex: stranger.meshHex)
    guard case let .refused(takeoverReason, _) = pinned else {
        Issue.record("a creator takeover should be refused, got \(pinned)")
        return
    }
    #expect(takeoverReason == .creatorPinning)
    // The member's copy is untouched, and it still reads what the real creator seals next.
    #expect(await member.store.group(withID: group.id)?.creatorMeshPublicKeyHex == creator.meshHex)
    let (payload, _) = try await creator.coordinator.sealMessage("still ours", toGroupID: group.id)
    #expect(await member.coordinator.receiveMessage(payload, hopCount: 0)?.text == "still ours")
}

@Test("a stale roster cannot move an epoch backwards, and an equal one still applies")
func epochRegressionIsRefused() async throws {
    let creator = try await makeGroupNode(nickname: "Creator")
    let member = try await makeGroupNode(nickname: "Member")
    let latecomer = try await makeGroupNode(nickname: "Late")
    defer { creator.cleanUp(); member.cleanUp(); latecomer.cleanUp() }

    let group = try await creator.coordinator.createGroup(named: "Cabin")
    let first = try await invite(member, into: group, by: creator, nickname: "Member")
    let second = try await invite(latecomer, into: group, by: creator, nickname: "Late")
    // The member is not the invitee, so it gets the same roster as its own state send: an invite
    // re-states the whole roster to everyone in it. Delivering that is what puts the member on epoch 3
    // — without it there is nothing for a replay to regress.
    let forMember = try #require(second.distribution.sends.first {
        $0.recipientMeshPublicKeyHex == member.meshHex
    }?.payload)
    let caughtUp = await member.coordinator.applyState(forMember, fromMeshPublicKeyHex: creator.meshHex)
    guard case .updated = caughtUp else {
        Issue.record("the member should take the roster the second invite produced, got \(caughtUp)")
        return
    }
    let held = try #require(await member.store.group(withID: group.id))
    #expect(held.epoch == 3)
    #expect(held.members.count == 3)

    // Re-delivering the state this node already holds (a session retry, a duplicated frame) is not an
    // epoch regression: monotonic, not strictly greater, or a retry would refuse its own roster.
    let reapplied = await member.coordinator.applyState(
        forMember,
        fromMeshPublicKeyHex: creator.meshHex
    )
    guard case let .updated(sameEpoch) = reapplied else {
        Issue.record("the current state should apply again, got \(reapplied)")
        return
    }
    #expect(sameEpoch.epoch == 3)

    // The state from epoch 2, delivered now: refused, and the epoch on disk does not move.
    let stale = await member.coordinator.applyState(first.blob, fromMeshPublicKeyHex: creator.meshHex)
    guard case let .refused(reason, refusedID) = stale else {
        Issue.record("a stale epoch should be refused, got \(stale)")
        return
    }
    #expect(reason == .epochRegression)
    #expect(refusedID == group.idHex)
    #expect(await member.store.group(withID: group.id)?.epoch == 3)
    #expect(await member.store.group(withID: group.id)?.members.count == 3)

    // A stale REMOVAL must not undo a later re-invite either: the refusal is the same check, and the
    // member keeps speaking.
    let (payload, _) = try await creator.coordinator.sealMessage("after the replay", toGroupID: group.id)
    #expect(await member.coordinator.receiveMessage(payload, hopCount: 1)?.text == "after the replay")
}

@Test("a state nobody here is named in is not kept")
func stateThatDoesNotNameUsIsRefused() async throws {
    let creator = try await makeGroupNode(nickname: "Creator")
    let outsider = try await makeGroupNode(nickname: "Outsider")
    defer { creator.cleanUp(); outsider.cleanUp() }

    let group = try await creator.coordinator.createGroup(named: "Inner")
    let key = try #require(await creator.store.key(forGroupID: group.id))
    let blob = try signedState(group: group, key: key, signer: creator.signing)
    let outcome = await outsider.coordinator.applyState(blob, fromMeshPublicKeyHex: creator.meshHex)
    guard case let .refused(reason, id) = outcome else {
        Issue.record("expected a refusal, got \(outcome)")
        return
    }
    #expect(reason == .notInRoster)
    #expect(id == group.idHex)
    #expect(await outsider.store.allGroups().isEmpty)
    // Refusing to store it is not refusing to carry it: this node is the relay in the next test.
    let log = GroupEventLog()
    await log.watch(outsider.hub)
    defer { log.stop() }
    let (payload, _) = try await creator.coordinator.sealMessage("relayed", toGroupID: group.id)
    #expect(await outsider.coordinator.receiveMessage(payload, hopCount: 4) == nil)
    #expect(log.messageCount == 0)
}

// MARK: - Roster changes

@Test("a removed member stops reading on the very next message")
func rosterRemovalTakesEffect() async throws {
    let creator = try await makeGroupNode(nickname: "Creator")
    let staying = try await makeGroupNode(nickname: "Staying")
    let leaving = try await makeGroupNode(nickname: "Leaving")
    defer { creator.cleanUp(); staying.cleanUp(); leaving.cleanUp() }

    let group = try await creator.coordinator.createGroup(named: "Crew")
    _ = try await invite(staying, into: group, by: creator, nickname: "Staying")
    _ = try await invite(leaving, into: group, by: creator, nickname: "Leaving")
    let beforeRemoval = try #require(await creator.store.group(withID: group.id))
    #expect(beforeRemoval.members.count == 3)

    let distribution = try await creator.coordinator.removeMember(
        leaving.meshHex,
        fromGroupID: group.id
    )
    #expect(!distribution.isInvite)
    #expect(distribution.changedMemberMeshPublicKeyHex == leaving.meshHex)
    // No self-send to the creator: `rotateKey` already wrote this state into its own store, so the
    // sends are the one member who stays plus the notice to the one who does not.
    #expect(distribution.sends.count == 2)
    let notice = try #require(distribution.sends.first { $0.recipientMeshPublicKeyHex == leaving.meshHex })
    let realState = try #require(distribution.sends.first { $0.recipientMeshPublicKeyHex == staying.meshHex })
    // Different bytes: the notice cannot carry the key it is rotating the reader out of.
    #expect(notice.payload != realState.payload)

    let stayedOutcome = await staying.coordinator.applyState(
        realState.payload,
        fromMeshPublicKeyHex: creator.meshHex
    )
    guard case let .updated(group) = stayedOutcome else {
        Issue.record("the staying member should update, got \(stayedOutcome)")
        return
    }
    let updated = group
    #expect(updated.epoch == beforeRemoval.epoch &+ 1)
    #expect(updated.members.count == 2)
    #expect(updated.member(withMeshPublicKeyHex: leaving.meshHex) == nil)

    let removedOutcome = await leaving.coordinator.applyState(
        notice.payload,
        fromMeshPublicKeyHex: creator.meshHex
    )
    guard case let .removed(groupID, name) = removedOutcome else {
        Issue.record("the removee should be removed, got \(removedOutcome)")
        return
    }
    #expect(groupID == group.id)
    #expect(name == "Crew")
    // The group and its key are gone from the removee's device — the throwaway key was never stored,
    // because a roster that does not name us is a deletion, not an update.
    #expect(await leaving.store.group(withID: group.id) == nil)
    #expect(await leaving.store.key(forGroupID: group.id) == nil)

    let (payload, _) = try await creator.coordinator.sealMessage("after you left", toGroupID: group.id)
    #expect(await leaving.coordinator.receiveMessage(payload, hopCount: 0) == nil)
    #expect(await staying.coordinator.receiveMessage(payload, hopCount: 1)?.text == "after you left")
    // The removee holds no group to seal into, so a stale copy is not a speaking licence either.
    await #expect(throws: PopopxMeshGroupError.groupNotFound(groupIDHex: group.idHex)) {
        _ = try await leaving.coordinator.sealMessage("let me back in", toGroupID: group.id)
    }
    // The creator is the trust root, so it leaves by the group going away, not by being removed.
    await #expect(throws: PopopxMeshGroupError.cannotRemoveCreator(meshPublicKeyHex: creator.meshHex)) {
        _ = try await creator.coordinator.removeMember(creator.meshHex, fromGroupID: group.id)
    }
    // And the old epoch's traffic is still readable by nobody who was rotated out: what matters is
    // that the NEW message is unreadable to the removee, which the line above proved.
}

@Test("the same message flooded four times is delivered once")
func reFloodedMessageIsDeduped() async throws {
    let creator = try await makeGroupNode(nickname: "Creator")
    let member = try await makeGroupNode(nickname: "Member")
    defer { creator.cleanUp(); member.cleanUp() }

    let log = GroupEventLog()
    await log.watch(member.hub)
    defer { log.stop() }

    let group = try await creator.coordinator.createGroup(named: "Flood")
    _ = try await invite(member, into: group, by: creator, nickname: "Member")
    let (payload, sealed) = try await creator.coordinator.sealMessage("once", toGroupID: group.id)
    #expect(sealed.senderNickname == "Creator")

    #expect(await member.coordinator.receiveMessage(payload, hopCount: 0) != nil)
    // More copies, on other paths and at other hop counts: the message id is the identity, not the
    // link the frame arrived on, and the flood window has not expired.
    #expect(await member.coordinator.receiveMessage(payload, hopCount: 1) == nil)
    #expect(await member.coordinator.receiveMessage(payload, hopCount: 5) == nil)
    let last = await until { log.messageCount == 1 }
    #expect(last)
    #expect(log.messageCount == 1)

    // A different message under the same key is not a duplicate.
    let (otherPayload, _) = try await creator.coordinator.sealMessage("twice", toGroupID: group.id)
    #expect(await member.coordinator.receiveMessage(otherPayload, hopCount: 0)?.text == "twice")
    let secondDelivery = await until { log.messageCount == 2 }
    #expect(secondDelivery)
    #expect(log.messageCount == 2)
}

@Test("a member's own echo of its message is not a second bubble")
func selfEchoIsDropped() async throws {
    let creator = try await makeGroupNode(nickname: "Creator")
    let member = try await makeGroupNode(nickname: "Member")
    defer { creator.cleanUp(); member.cleanUp() }

    let group = try await creator.coordinator.createGroup(named: "Echo")
    _ = try await invite(member, into: group, by: creator, nickname: "Member")
    let (payload, local) = try await member.coordinator.sealMessage("mine", toGroupID: group.id)
    // The sender publishes its own copy once; a neighbour re-flooding the same bytes back must not
    // produce a second one.
    #expect(await member.coordinator.receiveMessage(payload, hopCount: 1) == nil)
    // The creator, a different node, reads it.
    #expect(await creator.coordinator.receiveMessage(payload, hopCount: 3)?.id == local.id)
}

// MARK: - Mesh level

@Test("a node without the group key relays the flood and reads nothing")
func keylessNodeRelaysTheFlood() async throws {
    let speakerDirectory = try temporaryDirectory()
    let relayDirectory = try temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: speakerDirectory)
        try? FileManager.default.removeItem(at: relayDirectory)
    }
    var config = PopopxMeshConfig()
    config.relayMinDelay = 0
    config.relayMaxDelay = 0.001

    let speakerTransport = FakeMeshTransport()
    let relayTransport = FakeMeshTransport()
    let relayHub = PopopxMeshGroupEventHub()
    let speaker = PopopxMeshEngine(
        config: config,
        transport: speakerTransport,
        hub: PopopxMeshEventHub(),
        secrets: FakeSecrets(),
        groupStore: PopopxGroupStore(secrets: FakeSecrets(), directory: speakerDirectory)
    )
    // A second node with its own identity, its own empty group store and its own hub: it is the relay.
    let relay = PopopxMeshEngine(
        config: config,
        transport: relayTransport,
        hub: PopopxMeshEventHub(),
        secrets: FakeSecrets(),
        groupStore: PopopxGroupStore(secrets: FakeSecrets(), directory: relayDirectory),
        groupHub: relayHub
    )
    let log = GroupEventLog()
    await log.watch(relayHub)
    defer { log.stop() }

    await speaker.start(nickname: "Speaker")
    await relay.start(nickname: "Relay")

    let group = try await speaker.createGroup(named: "Relay test")
    try await speaker.sendGroupMessage("carry me", toGroupID: group.id)

    let flooded = await until { !speakerTransport.packets(of: .groupMessage).isEmpty }
    #expect(flooded)
    let original = try #require(speakerTransport.packets(of: .groupMessage).first)
    let frame = try #require(speakerTransport.frames.first {
        PopopxMeshPacket.decode($0)?.decodedType == .groupMessage
    })
    // A broadcast at the config's TTL, with the 16-byte group id in the clear so a relay can dedup it
    // without being able to read it.
    #expect(original.isBroadcast)
    #expect(original.ttl == config.ttlDefault)
    #expect(original.payload.contains(Data([0x01, 0x00, 0x10])))
    // The speaker's own hub got exactly one — its local copy — and nothing came back.
    #expect(log.messageCount == 0)

    // The neighbour hears the frame on a link it did not open, as CoreBluetooth delivers it.
    relay.bleTransport(relayTransport, didReceive: frame, from: relayTransport.ingressLinkID)
    let forwarded = await until { !relayTransport.packets(of: .groupMessage).isEmpty }
    #expect(forwarded)
    let relayed = try #require(relayTransport.packets(of: .groupMessage).first)
    // TTL down by one and the payload byte-identical: a relay that rewrote the ciphertext would break
    // every member downstream.
    #expect(relayed.ttl == config.ttlDefault - 1)
    #expect(relayed.payload == original.payload)
    #expect(relayed.senderID == original.senderID)
    #expect(relayed.packetID == original.packetID)
    // Nothing was published anywhere on this node, because nothing was readable.
    #expect(log.messageCount == 0)
    #expect(await relay.meshGroups().isEmpty)

    // The same packet again from a second neighbour: dropped as a duplicate, never re-flooded.
    let relaysBefore = relayTransport.packets(of: .groupMessage).count
    relay.bleTransport(relayTransport, didReceive: frame, from: relayTransport.ingressLinkID)
    let doubled = await until(timeout: 1) {
        relayTransport.packets(of: .groupMessage).count > relaysBefore
    }
    #expect(!doubled)
    #expect(relayTransport.packets(of: .groupMessage).count == relaysBefore)

    await relay.stop()
    await speaker.stop()
}

@Test("an invite for a peer we have never heard is refused before anything is put on the radio")
func inviteWithoutASigningKeyFailsRatherThanFloods() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = PopopxMeshConfig()
    config.relayMinDelay = 0
    config.relayMaxDelay = 0.001

    let transport = FakeMeshTransport()
    let engine = PopopxMeshEngine(
        config: config,
        transport: transport,
        hub: PopopxMeshEventHub(),
        secrets: FakeSecrets(),
        groupStore: PopopxGroupStore(secrets: FakeSecrets(), directory: directory)
    )
    await engine.start(nickname: "Creator")

    let group = try await engine.createGroup(named: "Quiet")
    let stranger = PopopxMeshIdentity.generate().meshPublicKeyHex
    // The roster row needs the peer's Ed25519 key, which only its announce can give us. Refusing here
    // is the honest answer; flooding a key we do not have would be the lie.
    await #expect(throws: PopopxMeshGroupError.peerNotResolved(meshPublicKeyHex: stranger)) {
        _ = try await engine.invite(peerMeshPublicKeyHex: stranger, toGroupID: group.id)
    }
    await #expect(throws: PopopxMeshGroupError.peerPublicKeyInvalid(meshPublicKeyHex: "zz")) {
        _ = try await engine.invite(peerMeshPublicKeyHex: "zz", toGroupID: group.id)
    }
    // Nothing group-shaped left the device: no state blob, and no flood of a message into a group of
    // one that no one else could read anyway.
    #expect(transport.packets(of: .groupState).isEmpty)
    #expect(await engine.invitableMeshPeers().isEmpty)
    #expect(await engine.meshGroups().count == 1)
    #expect(await engine.meshGroupMembers(of: group.id).count == 1)

    await engine.stop()
}

@Test("a group's key and metadata leave the device on panic wipe, and a new signing key takes over")
func destroyGroupStateBurnsEverything() async throws {
    let node = try await makeGroupNode(nickname: "Burn")
    let other = try await makeGroupNode(nickname: "Other")
    defer { node.cleanUp(); other.cleanUp() }

    let group = try await node.coordinator.createGroup(named: "Secret crew")
    _ = try await invite(other, into: group, by: node, nickname: "Other")
    let key = try #require(await node.store.key(forGroupID: group.id))
    let signingAccountHeld = try node.secrets.data(
        service: PopopxGroupSigningIdentity.keychainService,
        account: PopopxGroupSigningIdentity.keychainAccount
    )
    #expect(signingAccountHeld != nil)
    // The roster file exists while a group does — a wipe that only cleared memory would survive it.
    let metadataPath = await node.store.metadataURL.path
    #expect(FileManager.default.fileExists(atPath: metadataPath))

    let oldSigningHex = node.signing.publicKeyHex
    await node.coordinator.destroyAll()

    #expect(await node.store.allGroups().isEmpty)
    #expect(await node.store.key(forGroupID: group.id) == nil)
    #expect(try node.secrets.data(
        service: PopopxGroupSigningIdentity.keychainService,
        account: PopopxGroupSigningIdentity.keychainAccount
    ) != nil, "a fresh signing key was minted and persisted")
    // The key the burned group used is gone from the store's own service.
    let sentinelKey = try? node.secrets.data(
        service: PopopxGroupSigningIdentity.keychainService,
        account: "wrong-account-sentinel"
    )
    #expect(sentinelKey == nil)
    #expect(key.count == PopopxMeshGroup.keyByteCount)
    #expect(!FileManager.default.fileExists(atPath: metadataPath))
    let newHex = await node.coordinator.localSigningPublicKeyHex ?? ""
    #expect(!newHex.isEmpty)
    #expect(newHex != oldSigningHex)
    // Group creation works again in the same session, rather than throwing until relaunch.
    let rebuilt = try await node.coordinator.createGroup(named: "After the burn")
    #expect(rebuilt.members.first?.signingPublicKeyHex == newHex)
    // The peer that held the burned group cannot read anything sealed after the wipe.
    let (payload, _) = try await node.coordinator.sealMessage("new voice", toGroupID: rebuilt.id)
    #expect(await other.coordinator.receiveMessage(payload, hopCount: 0) == nil)
    // And the old group is simply not there to seal into.
    await #expect(throws: PopopxMeshGroupError.groupNotFound(groupIDHex: group.idHex)) {
        _ = try await node.coordinator.sealMessage("ghost", toGroupID: group.id)
    }
}
