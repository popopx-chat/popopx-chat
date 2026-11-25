//
//  PopopxMeshPrivateChatTests.swift
//  PopopxMeshUITests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Module 7's private chat screen, measured the way the plaza and the settings page are measured: through the view
//  model, with the core replaced by the doubles in `PopopxMeshUITestSupport.swift`.
//
//  What the suite insists on:
//
//  - One row per global `messageId`, in one order, for the ONE peer this screen is about. Traffic from
//    a neighbour this conversation is not with must not appear, even while the mirror is holding it.
//  - The badge is the merged timeline's badge, and a message this screen refused carries no channel
//    badge at all — nothing that never reached a radio may be drawn as though it had.
//  - A send to a peer nobody is paired with is refused out loud. Refused means a row on screen plus a
//    reason; silently dropped is a bug, and so is handing the frame to the mesh first and explaining
//    afterwards.
//  - the global fuse off (iron rule 28) leaves nothing: no rows, no subscription, no mirror pump, no call that
//    could reach Bluetooth, and no eaten draft.
//
//  Peer messages and node facts are pushed in through `replaceIncomingMessages` / `replacePeer`
//  rather than through the event hub, because `PopopxMeshInbound` and `PopopxMeshPeer` have no
//  initialiser outside the core. Those two entry points exist for hosts for exactly that reason.
//

import Foundation
import Testing
@testable import PopopxMeshUI
import PopopxMeshKit

@MainActor
@Suite("PopopxMeshPrivateChatModel")
struct PopopxMeshPrivateChatModelTests {
    private struct Harness {
        let model: PopopxMeshPrivateChatModel
        let source: PopopxMeshStateSource
        let outbound: PopopxMeshFakeOutbound
        let pairing: PopopxMeshFakePairing
        let store: PopopxMeshFakeBindingStore
        let fuse: PopopxMeshKillSwitch
        let journal: PopopxMeshJournal
        let directory: PopopxMeshTestDirectory
    }

    /// The peer this screen is about, deliberately different from the local key so "whose message is
    /// this" cannot pass by accident.
    private let peer = PopopxMeshTestKeys.peerB

    /// - Parameters:
    ///   - pairingStates: module 3's live answer. Empty is the unbound-stranger case.
    ///   - mappings: module 1's durable answer. A mapping with no paired state is the case where the
    ///     settings page listed a peer the pairing manager has since forgotten.
    ///   - fuseOn: the master switch, driven through the real fuse object rather than a flag of my own.
    private func makeHarness(
        label: String,
        pairingStates: [String: MeshPairingState] = [PopopxMeshTestKeys.peerB: .paired],
        mappings: [PopopxMeshContactMapping] = [PopopxMeshTestKeys.mapping(for: PopopxMeshTestKeys.peerB)],
        fuseOn: Bool = true,
        rejection: PopopxMeshSendFailure? = nil
    ) async throws -> Harness {
        let directory = try PopopxMeshTestDirectory(label: label)
        let journal = PopopxMeshJournal()
        let store = PopopxMeshFakeBindingStore(mappings: mappings, journal: journal)
        let pairing = PopopxMeshFakePairing(journal: journal, states: pairingStates, bindingStore: store)
        let outbound = PopopxMeshFakeOutbound(journal: journal, rejection: rejection)
        let source = PopopxMeshStateSource(hub: PopopxMeshEventHub())
        let defaults = try popopxMeshTestDefaults(label)
        let fuse = PopopxMeshKillSwitch(
            engine: PopopxMeshFakeComponent(name: "engine", journal: journal),
            healthMonitor: PopopxMeshFakeComponent(name: "health", journal: journal),
            pairing: nil,
            interface: PopopxMeshFakeComponent(name: "interface", journal: journal),
            hub: PopopxMeshEventHub(),
            defaults: defaults,
            nicknameStore: PopopxMeshNicknameStore(directory: FileManager.default.temporaryDirectory)
        )
        let model = PopopxMeshPrivateChatModel(
            peerMeshPublicKeyHex: peer,
            outbound: outbound,
            source: source,
            nicknameStore: PopopxMeshNicknameStore(directory: directory.url),
            pairing: pairing,
            bindings: store,
            killSwitch: fuse
        )
        // Registered, so the fuse owns this screen's life the way it owns the mirror's: a test that
        // turns the switch off is testing the tear-down, not a call the test made itself.
        await fuse.register(
            PopopxMeshSwitchedComponent(name: "private chat", role: .interface, component: model)
        )
        if fuseOn {
            await fuse.setEnabled(true)
        }
        return Harness(
            model: model, source: source, outbound: outbound, pairing: pairing, store: store,
            fuse: fuse, journal: journal, directory: directory
        )
    }

    /// The id the mesh puts in front of a key, by the screen's own derivation rule. Pinned against a
    /// known answer in `keyDerivationMatchesTheMeshsOwn` below; the core's `Data(popopxHex:)` cannot be
    /// used here because it does not decode a 64-character key at all.
    private func wireID(of keyHex: String) throws -> String {
        try #require(PopopxMeshPrivateChatModel.wireIDHex(ofMeshPublicKeyHex: keyHex))
    }

    private func incoming(
        id: String,
        at seconds: Int,
        text: String,
        hops: Int = 1,
        from keyHex: String
    ) throws -> PopopxMeshTimelineMessage {
        .offline(
            messageID: id,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seconds)),
            text: text,
            hopCount: hops,
            direction: .incoming,
            senderNickname: "Ada",
            senderPeerIDHex: try wireID(of: keyHex)
        )
    }

    private func sentJournalEntries(_ journal: PopopxMeshJournal) -> [String] {
        journal.all.filter { $0.hasPrefix("send:") }
    }

    private func offlineRow(
        id: String,
        direction: PopopxMeshTimelineDirection,
        hops: Int = 0,
        owedByTheMesh: Set<String> = []
    ) -> PopopxMeshTimelineRow {
        PopopxMeshTimelineMerger.merge(
            application: [],
            offline: [
                .offline(
                    messageID: id,
                    timestamp: Date(timeIntervalSince1970: 100),
                    text: "text",
                    hopCount: hops,
                    direction: direction
                ),
            ],
            awaitingRelayMessageIDs: owedByTheMesh
        ).rows[0]
    }

    // MARK: - Derivation

    @Test("The key to wire-id rule is the mesh's own, and it decodes a real key")
    func keyDerivationMatchesTheMeshsOwn() throws {
        let key = PopopxMeshTestKeys.peerB
        let bytes = try #require(PopopxMeshPrivateChatModel.meshPublicKeyBytes(ofMeshPublicKeyHex: key))
        #expect(bytes.count == PopopxMeshIdentity.keyByteCount)
        // The encoding direction of the core's hex helper works, so it can check the decoding one.
        #expect(bytes.popopxHex == key)

        // Known answer: SHA256 of 32 0xbb bytes, first 8 of it. Independent of any code under test.
        #expect(PopopxMeshPrivateChatModel.wireIDHex(ofMeshPublicKeyHex: key) == "4ca14526b2751b64")
        #expect(PopopxMeshPrivateChatModel.wireIDHex(ofMeshPublicKeyHex: PopopxMeshTestKeys.peerA) == "e0e77a507412b120")
        #expect(PopopxMeshPrivateChatModel.wireIDHex(ofMeshPublicKeyHex: PopopxMeshTestKeys.peerC) == "c2f480d4dda9f452")

        // The core's own derivation, from bytes this screen decoded: the two must not be different rules.
        #expect(PopopxMeshPrivateChatModel.wireIDHex(ofMeshPublicKeyHex: key)
            == PopopxMeshPeerID(publicKey: bytes).hex)

        // A key that is not a key is nothing to route to.
        #expect(PopopxMeshPrivateChatModel.wireIDHex(ofMeshPublicKeyHex: "ff") == nil)
        #expect(PopopxMeshPrivateChatModel.wireIDHex(ofMeshPublicKeyHex: String(repeating: "z", count: 64)) == nil)
        #expect(PopopxMeshPrivateChatModel.wireIDHex(ofMeshPublicKeyHex: "") == nil)
    }

    // MARK: - Ordering and deduplication

    @Test("Both sides of one conversation share a list, ordered by when they happened")
    func rowsAreOrdered() async throws {
        let made = try await makeHarness(label: "chat-order")
        let model = made.model
        defer { made.directory.remove() }
        model.start()
        defer { model.stop() }

        model.replaceIncomingMessages([
            try incoming(id: "m3", at: 300, text: "third", from: peer),
            try incoming(id: "m1", at: 100, text: "first", from: peer),
            // A neighbour this conversation is not with: the mirror may hold it, this screen may not.
            try incoming(id: "m9", at: 200, text: "not for you", from: PopopxMeshTestKeys.peerC),
        ])
        #expect(model.messages.map(\.text) == ["first", "third"])

        model.draft = "mine"
        await model.sendDraft()
        // The reply is stamped now and the fixtures are 1970: ascending time is the rule, not arrival.
        #expect(model.messages.map(\.text) == ["first", "third", "mine"])
        #expect(model.messages.map(\.direction) == [.incoming, .incoming, .outgoing])
    }

    @Test("One messageId is one row, however many times the peer's copy arrives")
    func rowsAreDedupedById() async throws {
        let made = try await makeHarness(label: "chat-dedup")
        let model = made.model
        defer { made.directory.remove() }
        model.start()
        defer { model.stop() }

        model.replaceIncomingMessages([
            try incoming(id: "same", at: 100, text: "flooded once", from: peer),
            try incoming(id: "same", at: 100, text: "flooded again", from: peer),
            try incoming(id: "same", at: 100, text: "the newest copy", from: peer),
        ])

        #expect(model.messages.count == 1)
        #expect(model.messages.map(\.id) == ["same"])
        // The merge's rule: the last copy of an id wins, so a re-flood cannot rewrite history backwards.
        #expect(model.messages.first?.text == "the newest copy")
    }

    @Test("A sender this screen cannot name is not a message in this conversation")
    func unknownSenderIsNotShown() async throws {
        let made = try await makeHarness(label: "chat-sender")
        let model = made.model
        defer { made.directory.remove() }
        model.start()
        defer { model.stop() }

        let noSenderID = PopopxMeshTimelineMessage.offline(
            messageID: "anonymous",
            timestamp: Date(timeIntervalSince1970: 100),
            text: "no sender at all",
            hopCount: 0
        )
        model.replaceIncomingMessages([
            noSenderID,
            try incoming(id: "theirs", at: 110, text: "for someone else", from: PopopxMeshTestKeys.peerC),
            try incoming(id: "ours", at: 120, text: "for us", from: peer),
        ])

        #expect(model.messages.map(\.id) == ["ours"])
        // A host that mounted this screen by key never has to look up a node table to know whose
        // conversation it is looking at.
        #expect(model.peerMeshPublicKey == peer)
    }

    @Test("A control signal is never drawn as a message")
    func controlSignalsAreDropped() async throws {
        let made = try await makeHarness(label: "chat-control")
        let model = made.model
        defer { made.directory.remove() }
        model.start()
        defer { model.stop() }

        let sender = try wireID(of: peer)
        model.replaceIncomingMessages([
            PopopxMeshTimelineMessage.offline(
                messageID: "sys-req",
                timestamp: Date(timeIntervalSince1970: 100),
                text: "SYS_POPOPX_REQ:popopx:/contact#abc",
                hopCount: 1,
                senderPeerIDHex: sender
            ),
            PopopxMeshTimelineMessage.offline(
                messageID: "sys-ack",
                timestamp: Date(timeIntervalSince1970: 110),
                text: "BLE_ACK:say-1",
                hopCount: 0,
                senderPeerIDHex: sender
            ),
            PopopxMeshTimelineMessage.offline(
                messageID: "say-1",
                timestamp: Date(timeIntervalSince1970: 120),
                text: "the actual sentence",
                hopCount: 1,
                senderPeerIDHex: sender
            ),
        ])
        #expect(model.messages.map(\.id) == ["say-1"])
    }

    // MARK: - Badges

    @Test("A relayed message carries the orange ripple with its hop count")
    func relayedBadge() async throws {
        let made = try await makeHarness(label: "chat-badge-relay")
        let model = made.model
        defer { made.directory.remove() }
        model.start()
        defer { model.stop() }

        model.replaceIncomingMessages([
            try incoming(id: "h2", at: 100, text: "two hops away", hops: 2, from: peer),
        ])
        let row = try #require(model.messages.first)
        #expect(row.channel == .offlineMesh(hopCount: 2))
        #expect(row.badge.symbolName == "antenna.radiowaves.left.and.right")
        #expect(row.badge.tone == .orange)
        #expect(row.badge.accessory == "· 2")
        #expect(row.badge.accessibilityLabel == "Offline mesh, 2 hops")
        #expect(row.showsChannelBadge)
    }

    @Test("An id the mesh still owes a relay for is re-badged to the grey clock")
    func awaitingRelayBadge() async throws {
        let made = try await makeHarness(label: "chat-badge-owed")
        let model = made.model
        defer { made.directory.remove() }
        model.start()
        defer { model.stop() }

        model.draft = "will not fit the radio"
        await model.sendDraft()
        let messageId = try #require(model.messages.first?.id)
        #expect(model.messages.first?.delivery == .handedToMesh)

        // Module 2's own report that the frame never left the device is the routing layer's verdict, and
        // it outranks whatever the transport said when the frame was handed over.
        made.source.ingest(.sendFailed(messageId: messageId, peer: nil, reason: .noLinkToPeer))
        try await popopxMeshWaitUntil("the owed relay to reach the row") {
            model.messages.first?.channel == .awaitingRelay
        }
        let row = try #require(model.messages.first)
        #expect(row.badge.symbolName == "clock")
        #expect(row.badge.tone == .grey)
        #expect(row.badge.accessory == nil)
        #expect(row.delivery == .awaitingRelay)
        #expect(row.showsChannelBadge, "this one really did go to the mesh")
    }

    @Test("A message refused before the mesh gets no channel badge at all")
    func refusedRowClaimsNoChannel() async throws {
        let made = try await makeHarness(label: "chat-badge-refused", pairingStates: [:], mappings: [])
        let model = made.model
        defer { made.directory.remove() }
        model.start()
        defer { model.stop() }

        model.draft = "stranger"
        await model.sendDraft()
        let row = try #require(model.messages.first)
        #expect(row.delivery == .refused(.peerNotPaired(.unlinked)))
        #expect(row.showsChannelBadge == false)
        #expect(row.badge.symbolName == "antenna.radiowaves.left.and.right")
        // The unbound stranger in the sender's own words, not a paraphrase of them.
        #expect(PopopxMeshPrivateChatModel.words(for: row.delivery)
            .contains(PopopxMessageRouter.unboundStrangerStatusText))
    }

    // MARK: - Delivery

    @Test("The delivery line is decided by the evidence, not by hope")
    func deliveryRuleIsPure() throws {
        let handed = offlineRow(id: "m1", direction: .outgoing)
        let theirs = offlineRow(id: "m2", direction: .incoming, hops: 3)
        let owed = offlineRow(id: "m3", direction: .outgoing, owedByTheMesh: ["m3"])
        let acked = offlineRow(id: "m4", direction: .outgoing)

        // Handed over with no acknowledgement recorded is all this layer actually knows.
        #expect(
            PopopxMeshPrivateChatModel.delivery(for: handed, refusals: [:], acknowledgedIDs: [])
                == .handedToMesh
        )
        // Nothing is owed back for the peer's own copy.
        #expect(
            PopopxMeshPrivateChatModel.delivery(for: theirs, refusals: [:], acknowledgedIDs: [])
                == .received
        )
        // The grey clock outranks an ack: an id the routing layer still owes is not delivered.
        #expect(
            PopopxMeshPrivateChatModel.delivery(for: owed, refusals: [:], acknowledgedIDs: ["m3"])
                == .awaitingRelay
        )
        // A BLE_ACK that cleared this id is the only thing allowed to say delivered.
        #expect(
            PopopxMeshPrivateChatModel.delivery(for: acked, refusals: [:], acknowledgedIDs: ["m4"])
                == .acknowledged
        )
        // A refusal outranks all of it.
        let refusal = PopopxMeshPrivateChatRefusal.transport(.ttlExhausted)
        #expect(
            PopopxMeshPrivateChatModel.delivery(for: acked, refusals: ["m4": refusal], acknowledgedIDs: ["m4"])
                == .refused(refusal)
        )
    }

    @Test("A send the mesh refused keeps the text and names the failure")
    func transportRefusalKeepsText() async throws {
        let made = try await makeHarness(
            label: "chat-transport-refusal",
            rejection: .ttlExhausted
        )
        let model = made.model
        defer { made.directory.remove() }
        model.start()
        defer { model.stop() }

        model.draft = "  echo  "
        await model.sendDraft()
        let row = try #require(model.messages.first)
        #expect(row.text == "echo")
        #expect(row.delivery == .refused(.transport(.ttlExhausted)))
        #expect(model.lastRefusal == .transport(.ttlExhausted))
        // The frame was offered to module 2, so the refusal is the mesh's answer, not this screen's.
        #expect(sentJournalEntries(made.journal).count == 1)
        #expect(model.draft.isEmpty)
    }

    // MARK: - The unbound-stranger gate

    @Test("A peer nobody is paired with is refused, and the text is not dropped")
    func unpairedPeerIsRefused() async throws {
        let made = try await makeHarness(label: "chat-unpaired", pairingStates: [:], mappings: [])
        let model = made.model
        defer { made.directory.remove() }
        model.start()
        defer { model.stop() }

        model.draft = "are you there"
        await model.sendDraft()

        // Refused out loud: a row that says so, and nothing given to the mesh.
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.text == "are you there")
        #expect(model.peerIsPaired == false)
        #expect(sentJournalEntries(made.journal).isEmpty)
        #expect(model.emptyReason == nil, "there is something to show, so it is not an empty state")

        // Pairing is what changed, not the screen's mood: approve the request and the same composer
        // hands the next draft to the mesh.
        try await made.pairing.approve(PopopxMeshTestKeys.request(for: peer))
        model.draft = "now then"
        await model.sendDraft()

        #expect(model.peerIsPaired)
        #expect(sentJournalEntries(made.journal).count == 1)
        #expect(model.messages.count == 2)
        #expect(model.messages.last?.delivery == .handedToMesh)
        #expect(model.lastRefusal == nil)
    }

    @Test("A durable binding is a proof even when module 3 has forgotten the peer")
    func bindingAloneIsEnough() async throws {
        let made = try await makeHarness(label: "chat-binding-only", pairingStates: [:])
        let model = made.model
        defer { made.directory.remove() }
        await model.refresh()
        model.draft = "one message"
        await model.sendDraft()

        #expect(model.binding?.meshPublicKeyHex == peer)
        #expect(model.pairingState == .unlinked)
        #expect(sentJournalEntries(made.journal).count == 1)
        #expect(model.messages.first?.delivery == .handedToMesh)
    }

    @Test("Without either proof nothing reaches the mesh, however many attempts")
    func noProofNeverSends() async throws {
        let made = try await makeHarness(label: "chat-no-proof", pairingStates: [:], mappings: [])
        let model = made.model
        defer { made.directory.remove() }

        for text in ["a", "b", "c"] {
            model.draft = text
            await model.sendDraft()
        }
        #expect(sentJournalEntries(made.journal).isEmpty)
        #expect(Set(model.messages.map(\.text)) == ["a", "b", "c"])
        #expect(model.messages.count == 3)
        #expect(
            model.messages.allSatisfy { $0.delivery == .refused(.peerNotPaired(.unlinked)) }
        )
    }

    // MARK: - Empty states

    @Test("Paired and out of range is said as paired and out of range")
    func outOfRangeEmptyState() async throws {
        let made = try await makeHarness(label: "chat-out-of-range")
        let model = made.model
        defer { made.directory.remove() }
        model.start()
        defer { model.stop() }
        made.source.ingest(.bluetoothState(.poweredOn))
        try await popopxMeshWaitUntil("the radio to reach the screen") { model.radioState == .poweredOn }

        let silence = Date.now.addingTimeInterval(-120)
        model.replacePeer(PopopxMeshPrivateChatPeer(
            peerIDHex: try wireID(of: peer),
            nickname: "Ada",
            hopCount: 2,
            lastSeenAt: silence,
            isDirect: false
        ))

        #expect(model.peerIsInRange == false)
        #expect(model.emptyReason == .peerOutOfRange(hops: 2, lastSeenAt: silence))
        let state = try #require(model.emptyState)
        #expect(state.title == "Not in Bluetooth range")
        #expect(state.detail.contains("Ada"))
        #expect(state.detail.contains("2 hops · ≈60 m"))
        // The two promises an offline screen is allowed to make, and the two it is not: no queue of
        // its own, and no fallback to the public network.
        #expect(state.detail.contains("nothing is queued"))
        #expect(state.detail.contains("public network"))

        // Heard from again, inside module 4's window, and the same screen has nothing to apologise for.
        model.replacePeer(PopopxMeshPrivateChatPeer(
            peerIDHex: try wireID(of: peer),
            nickname: "Ada",
            hopCount: 2,
            lastSeenAt: .now
        ))
        #expect(model.peerIsInRange)
        #expect(model.emptyReason == .nothingSaidYet)
        #expect(model.emptyState?.title == "Nothing said yet")
    }

    @Test("Each kind of silence gets its own sentence")
    func everyEmptyReasonIsNamed() async throws {
        // Not paired: module 5's stranger sentence, quoted rather than paraphrased.
        let stranger = try await makeHarness(label: "chat-empty-stranger", pairingStates: [:], mappings: [])
        defer { stranger.directory.remove() }
        #expect(stranger.model.emptyReason == .notPaired)
        #expect(stranger.model.emptyState?.detail == PopopxMessageRouter.unboundStrangerStatusText)

        // Radio down, peer known and bound.
        let cold = try await makeHarness(label: "chat-empty-radio")
        defer { cold.directory.remove() }
        cold.model.start()
        defer { cold.model.stop() }
        cold.source.ingest(.bluetoothState(.poweredOff))
        try await popopxMeshWaitUntil("the radio to fall") { cold.model.radioState == .poweredOff }
        #expect(cold.model.emptyReason == .radioUnavailable(.poweredOff))
        #expect(cold.model.emptyState?.detail.contains("leaves the device") == true)

        // Radio up and never heard from since Bluetooth came up: no hops, no distance, no invented
        // radius, because there is no measurement to report.
        let quiet = try await makeHarness(label: "chat-empty-never")
        defer { quiet.directory.remove() }
        quiet.model.start()
        defer { quiet.model.stop() }
        quiet.source.ingest(.bluetoothState(.poweredOn))
        try await popopxMeshWaitUntil("the radio to come up") { quiet.model.radioState == .poweredOn }
        #expect(quiet.model.emptyReason == .peerNeverHeard)
        #expect(quiet.model.peerReachDescription == nil)
    }

    // MARK: - The local temporary nickname

    @Test("The nickname saves, clamps, and comes back from the mesh sandbox")
    func nicknameRoundTrip() async throws {
        let made = try await makeHarness(label: "chat-nickname")
        let model = made.model
        defer { made.directory.remove() }

        #expect(model.nickname == PopopxMeshNicknameStore.defaultNickname)
        model.nickname = "   Ada   "
        await model.saveNickname()
        #expect(model.nickname == "Ada")
        #expect(made.directory.exists(PopopxMeshNicknameStore.fileName))
        #expect(PopopxMeshNicknameStore(directory: made.directory.url).read() == "Ada")

        model.nickname = String(repeating: "n", count: 200)
        await model.saveNickname()
        let longest = String(repeating: "n", count: PopopxMeshNicknameStore.maxCharacters)
        #expect(model.nickname == longest)

        model.nickname = "not saved"
        model.reloadNickname()
        #expect(model.nickname == longest)
    }

    @Test("The private screen and the plaza edit one local name, not two")
    func nicknameIsTheSameFileThePlazaUses() async throws {
        let made = try await makeHarness(label: "chat-nickname-shared")
        let model = made.model
        defer { made.directory.remove() }

        model.nickname = "Mesh Ada"
        await model.saveNickname()

        let plaza = PopopxMeshPlazaModel(
            outbound: made.outbound,
            source: made.source,
            nicknameStore: PopopxMeshNicknameStore(directory: made.directory.url)
        )
        // One file, one value: the name a peer sees on a broadcast is the name this screen set.
        #expect(plaza.nickname == "Mesh Ada")
        #expect(PopopxMeshNicknameStore.fileName == "plaza_nickname.json")

        plaza.nickname = "Changed there"
        await plaza.saveNickname()
        model.reloadNickname()
        #expect(model.nickname == "Changed there")
    }

    // MARK: - The global fuse

    @Test("With the fuse off the screen holds no state and asks nothing of the mesh")
    func fuseOffLeavesNothing() async throws {
        let made = try await makeHarness(label: "chat-fuse-off", fuseOn: false)
        let model = made.model
        defer { made.directory.remove() }

        model.start()
        #expect(model.meshIsEnabled == false)
        // The mirror is not even subscribed: no pump, no consumer, no event stream to leak.
        #expect(made.source.isPumping == false)
        #expect(made.source.consumerCount == 0)

        model.replaceIncomingMessages([try incoming(id: "m1", at: 100, text: "ignored", from: peer)])
        model.replacePeer(PopopxMeshPrivateChatPeer(peerIDHex: try wireID(of: peer), hopCount: 1))
        model.draft = "hello?"
        await model.sendDraft()
        await model.saveNickname()
        await model.refresh()

        #expect(model.messages.isEmpty)
        #expect(model.peer == nil)
        #expect(model.emptyReason == nil)
        #expect(model.canSend == false)
        #expect(model.draft == "hello?")
        #expect(model.pairingState == .unlinked)
        #expect(model.binding == nil)
        #expect(sentJournalEntries(made.journal).isEmpty)
        #expect(made.journal.all.filter { $0.hasPrefix("send:") || $0.hasPrefix("broadcast:") }.isEmpty)
        // The sandbox file is the mesh's to erase, and an off fuse never writes it.
        #expect(!made.directory.exists(PopopxMeshNicknameStore.fileName))

        // The same screen with the switch on: it is the fuse that opened it, not the test.
        await made.fuse.setEnabled(true)
        try await popopxMeshWaitUntil("the fuse to reach the screen") { model.meshIsEnabled }
        model.start()
        #expect(made.source.consumerCount > 0)
        #expect(made.source.isPumping)
        #expect(model.canSend)

        model.draft = "now"
        await model.sendDraft()
        #expect(sentJournalEntries(made.journal).count == 1)
        #expect(model.messages.count == 1)

        // And the same screen with it off again: the conversation is gone, not greyed out.
        await made.fuse.setEnabled(false)
        try await popopxMeshWaitUntil("the tear-down") { !model.meshIsEnabled }
        #expect(model.messages.isEmpty)
        try await popopxMeshWaitUntil("the subscription to go") { made.source.consumerCount == 0 }
    }

    @Test("A blank draft is not a message and a long one is capped")
    func composerBounds() async throws {
        let made = try await makeHarness(label: "chat-composer")
        let model = made.model
        defer { made.directory.remove() }

        model.draft = "   \n  "
        #expect(model.canSend == false)
        await model.sendDraft()
        #expect(model.messages.isEmpty)
        #expect(sentJournalEntries(made.journal).isEmpty)

        model.draft = String(
            repeating: "x",
            count: PopopxMeshPrivateChatModel.maxDraftCharacters + 100
        )
        #expect(model.canSend)
        await model.sendDraft()
        #expect(model.messages.first?.text.count == PopopxMeshPrivateChatModel.maxDraftCharacters)
    }

    // MARK: - Naming

    @Test("A peer is named by what it announced, then the contact table, then its key")
    func peerNamePrecedence() async throws {
        let named = PopopxMeshTestKeys.mapping(for: peer, nickname: "Booked as Bea")
        let made = try await makeHarness(label: "chat-naming", mappings: [named])
        let model = made.model
        defer { made.directory.remove() }

        await model.refresh()
        #expect(model.peerDisplayName == "Booked as Bea")

        model.replacePeer(PopopxMeshPrivateChatPeer(
            peerIDHex: try wireID(of: peer),
            nickname: "Announced as Ada",
            hopCount: 0
        ))
        #expect(model.peerDisplayName == "Announced as Ada")

        let anonymous = try await makeHarness(
            label: "chat-naming-anonymous",
            mappings: [PopopxMeshTestKeys.mapping(for: peer, nickname: "   ")]
        )
        defer { anonymous.directory.remove() }
        await anonymous.model.refresh()
        #expect(anonymous.model.peerDisplayName == PopopxMeshPrivateChatModel.peerLabel(peer))
        #expect(anonymous.model.peerDisplayName.hasSuffix("…"))
    }

    @Test("The reach line says hops, distance, who is carrying it and when")
    func reachLine() async throws {
        let made = try await makeHarness(label: "chat-reach")
        let model = made.model
        defer { made.directory.remove() }

        model.replacePeer(PopopxMeshPrivateChatPeer(
            peerIDHex: try wireID(of: peer),
            nickname: "Ada",
            hopCount: 3,
            lastSeenAt: Date.now.addingTimeInterval(-45),
            isDirect: false
        ))
        #expect(model.peerReachDescription == "3 hops · ≈90 m · relayed · seen 45 s ago")

        model.replacePeer(PopopxMeshPrivateChatPeer(
            peerIDHex: try wireID(of: peer),
            hopCount: 0
        ))
        #expect(model.peerReachDescription == "0 hops · ≈0 m · direct link · seen just now")
    }
}
