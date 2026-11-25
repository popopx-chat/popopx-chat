//
//  PopopxMeshTimelineDedupTests.swift
//  PopopxMeshUITests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Ruling 1 in one sentence: after a restore flushes an offline message into the app's own database, the
//  timeline must show ONE bubble. The two copies do not share an identifier — the offline row carries
//  the mesh `messageId` this router minted, the stored row carries the main database's `ChatItem` id —
//  so nothing in either stream can recognize the other. These tests pin the pairing rule and, just as
//  importantly, the case where the pairing is absent: without it the same text really is drawn twice,
//  which is what makes the pair load-bearing rather than the timestamps or the text.
//

import Foundation
import Testing

import PopopxMeshKit
import PopopxMeshUI

private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func meshRow(_ id: String, text: String, at offset: TimeInterval = 0) -> PopopxMeshTimelineMessage {
    .offline(messageID: id, timestamp: base.addingTimeInterval(offset), text: text, hopCount: 0)
}

private func storedRow(_ id: String, text: String, at offset: TimeInterval = 0) -> PopopxMeshTimelineMessage {
    .application(messageID: id, timestamp: base.addingTimeInterval(offset), text: text, direction: .outgoing)
}

// MARK: - Merger

@Suite("PopopxMeshTimelineMerger / dual-id dedup")
struct PopopxMeshTimelineDualIDTests {
    @Test("a flushed mesh row and its stored twin merge into one bubble")
    func pairCollapsesToTheStoredCopy() {
        let result = PopopxMeshTimelineMerger.merge(
            application: [storedRow("100001", text: "after the re-delivery")],
            offline: [meshRow("0e9c1a4f-2b3c-4d5e-8f90-112233445566", text: "after the re-delivery")],
            flushedAppChatItemIDs: ["0e9c1a4f-2b3c-4d5e-8f90-112233445566": 100_001]
        )
        // One row, and it is the app's copy: the overlay must not draw anything for it.
        #expect(result.rows.count == 1)
        #expect(result.offlineOnlyRows.isEmpty)
        #expect(result.rows.first?.presentInApplicationStream == true)
    }

    @Test("the surviving row keeps the stored copy's badge, not the mesh one")
    func storedCopyWinsTheChannel() {
        let meshID = "0e9c1a4f-2b3c-4d5e-8f90-112233445566"
        let result = PopopxMeshTimelineMerger.merge(
            application: [storedRow("100001", text: "the same message")],
            offline: [meshRow(meshID, text: "the same message")],
            flushedAppChatItemIDs: [meshID: 100_001]
        )
        #expect(result.rows.map(\.channel) == [.smpPublicNetwork])
    }

    /// The control. Same timestamps, same text, same ids — only the pairing is gone, and the bubble
    /// count doubles. This is the defect ruling 1 exists to close, so it is asserted, not assumed.
    @Test("without the pairing the same message is drawn twice")
    func missingPairDrawsTwice() {
        let meshID = "0e9c1a4f-2b3c-4d5e-8f90-112233445566"
        let result = PopopxMeshTimelineMerger.merge(
            application: [storedRow("100001", text: "the same message")],
            offline: [meshRow(meshID, text: "the same message")],
            flushedAppChatItemIDs: [:]
        )
        #expect(result.rows.count == 2)
        #expect(result.offlineOnlyRows.count == 1)
    }

    @Test("the pairing is keyed the other way round just as well")
    func reverseKeyingCollapses() {
        // A host that hands its own rows in under the mesh id: the map is walked from the mesh side, so
        // both spellings of the key land in the same bucket.
        let meshID = "66bb99aa-0011-2233-4455-667788990011"
        let result = PopopxMeshTimelineMerger.merge(
            application: [storedRow(meshID, text: "the other way round")],
            offline: [meshRow(meshID, text: "the other way round")],
            flushedAppChatItemIDs: [meshID: 200_002]
        )
        #expect(result.rows.count == 1)
        #expect(result.offlineOnlyRows.isEmpty)
    }

    @Test("a flushed row whose stored twin is off-window stays visible")
    func unpairedMeshRowSurvives() {
        let result = PopopxMeshTimelineMerger.merge(
            application: [],
            offline: [meshRow("aaaaaaaa-1111-2222-3333-444455556666", text: "not stored yet")],
            flushedAppChatItemIDs: ["aaaaaaaa-1111-2222-3333-444455556666": 300_003]
        )
        // Known pair, no stored row in the window: the offline copy is all there is, so it is drawn.
        #expect(result.rows.count == 1)
        #expect(result.offlineOnlyRows.count == 1)
    }

    @Test("an unflushed mesh row never collapses with an unrelated stored row")
    func differentPairDoesNotMerge() {
        let result = PopopxMeshTimelineMerger.merge(
            application: [storedRow("100001", text: "alpha")],
            offline: [meshRow("ffffffff-0000-1111-2222-333344445555", text: "beta")],
            flushedAppChatItemIDs: ["cccccccc-0000-1111-2222-333344445555": 100_001]
        )
        #expect(result.rows.count == 2)
    }

    @Test("a pair still owes its grey clock to nobody: relay state is decided by the routing set")
    func awaitingRelayDoesNotResurrectAFlushedRow() {
        let meshID = "0e9c1a4f-2b3c-4d5e-8f90-112233445566"
        let result = PopopxMeshTimelineMerger.merge(
            application: [storedRow("100001", text: "re-delivered")],
            offline: [meshRow(meshID, text: "re-delivered")],
            awaitingRelayMessageIDs: ["100001"],
            flushedAppChatItemIDs: [meshID: 100_001]
        )
        // One row, and the routing layer's verdict wins the badge over both transports.
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.channel == .awaitingRelay)
    }

    @Test("the merger's own default pairing changes nothing for a host that never sets it")
    func injectedDefaultIsInert() {
        let merger = PopopxMeshTimelineMerger()
        let result = merger.merge(
            application: [storedRow("100001", text: "the same message")],
            offline: [meshRow("0e9c1a4f-2b3c-4d5e-8f90-112233445566", text: "the same message")]
        )
        #expect(result.rows.count == 2)
    }

    @Test("a merger built with pairs applies them without a per-call argument")
    func mergerCarriesItsOwnPairs() {
        let meshID = "0e9c1a4f-2b3c-4d5e-8f90-112233445566"
        let merger = PopopxMeshTimelineMerger(flushedAppChatItemIDs: [meshID: 100_001])
        let result = merger.merge(
            application: [storedRow("100001", text: "the same message")],
            offline: [meshRow(meshID, text: "the same message")]
        )
        #expect(result.rows.count == 1)
        #expect(result.offlineOnlyRows.isEmpty)
    }
}

// MARK: - Model plumbing

@MainActor
@Suite("PopopxMeshTimelineModel / dual-id plumbing")
struct PopopxMeshTimelineDualIDModelTests {
    /// `refreshRoutingState()` is the only way the pairs reach the Combine pipeline, so the assertion
    /// here is about the wire, not the rule: a model built on a routing observer that reports a pairing
    /// must merge the two id spaces apart, with no per-call argument.
    @Test("the pairs a routing observer reports reach the merge")
    func refreshRoutesPairsIntoMerge() async {
        let meshID = "0e9c1a4f-2b3c-4d5e-8f90-112233445566"
        let routing = PopopxMeshFakeRouting(flushedAppIDs: [meshID: 100_001])
        let model = PopopxMeshTimelineModel(source: PopopxMeshStateSource(hub: PopopxMeshEventHub()), routing: routing)
        await model.refreshRoutingState()
        model.replaceApplicationStream([
            storedRow("100001", text: "one message, two names"),
            storedRow(meshID, text: "one message, two names"),
        ])
        #expect(model.result.rows.count == 1)
        #expect(model.offlineOnlyRows.isEmpty)
    }

    @Test("a model whose observer reports nothing leaves both id spaces separate")
    func absentPairsKeepBothRows() async {
        let meshID = "0e9c1a4f-2b3c-4d5e-8f90-112233445566"
        let model = PopopxMeshTimelineModel(
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub()),
            routing: PopopxMeshFakeRouting()
        )
        await model.refreshRoutingState()
        model.replaceApplicationStream([
            storedRow("100001", text: "two names"),
            storedRow(meshID, text: "two names"),
        ])
        #expect(model.result.rows.count == 2)
    }
}

// MARK: - One app-stream entry per mounted chat

/// Why the feed is keyed at all: this app pushes one chat view on top of another without the first one
/// disappearing, and every `ChatView` mounts the same `PopopxMeshRuntime.shared.timelineModel`. If the
/// feed were a single array, whichever view wrote last would decide what *every* chat deduplicates
/// against — the flushed message of the chat that did not write last is a bubble plus a strip row
/// again. These tests are about ownership, not about the pairing rule.
@MainActor
@Suite("PopopxMeshTimelineModel / app stream ownership")
struct PopopxMeshTimelineChatScopedStreamTests {
    /// A model whose routing observer reports the given mesh-id → row-id pairs.
    private func makeModel(
        flushedAppIDs: [String: Int64] = [:]
    ) -> PopopxMeshTimelineModel {
        PopopxMeshTimelineModel(
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub()),
            routing: PopopxMeshFakeRouting(flushedAppIDs: flushedAppIDs)
        )
    }

    @Test("both mounted chats contribute their rows to one timeline")
    func mountedChatsUnion() {
        let model = PopopxMeshTimelineModel(
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub())
        )
        model.replaceApplicationStream([storedRow("a-1", text: "alpha")], forChatID: "chat-a")
        model.replaceApplicationStream([storedRow("b-1", text: "beta")], forChatID: "chat-b")
        // A replacement-style feed would show only beta.
        #expect(model.result.rows.map(\.messageID) == ["a-1", "b-1"])
    }

    @Test("leaving a chat takes back only that chat's rows")
    func removalIsScopedToItsEntry() {
        let model = PopopxMeshTimelineModel(
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub())
        )
        model.replaceApplicationStream([storedRow("a-1", text: "alpha")], forChatID: "chat-a")
        model.replaceApplicationStream([storedRow("b-1", text: "beta")], forChatID: "chat-b")
        model.removeApplicationStream(forChatID: "chat-b")
        #expect(model.result.rows.map(\.messageID) == ["a-1"])
        // And removing an entry that never fed — the `onDisappear` of a view whose task never ran —
        // must not empty the timeline.
        model.removeApplicationStream(forChatID: "chat-b")
        #expect(model.result.rows.map(\.messageID) == ["a-1"])
    }

    @Test("a chat that re-feeds replaces its own rows and leaves the others alone")
    func refeedReplacesOnlyItsEntry() {
        let model = PopopxMeshTimelineModel(
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub())
        )
        model.replaceApplicationStream([storedRow("a-1", text: "alpha old"), storedRow("a-2", text: "alpha new")], forChatID: "chat-a")
        model.replaceApplicationStream([storedRow("b-1", text: "beta")], forChatID: "chat-b")
        model.replaceApplicationStream([storedRow("a-2", text: "alpha new")], forChatID: "chat-a")
        #expect(model.result.rows.map(\.messageID) == ["a-2", "b-1"])
    }

    @Test("the pairing collapses a message whose two halves came from two different chats")
    func pairCollapsesAcrossEntries() async {
        let meshID = "0e9c1a4f-2b3c-4d5e-8f90-112233445566"
        let model = makeModel(flushedAppIDs: [meshID: 100_001])
        await model.refreshRoutingState()
        model.replaceApplicationStream([storedRow(meshID, text: "after the re-delivery")], forChatID: "chat-a")
        model.replaceApplicationStream([storedRow("100001", text: "after the re-delivery")], forChatID: "chat-b")
        #expect(model.result.rows.count == 1)
        #expect(model.result.rows.first?.messageID == "100001")
        // Control: the union alone would not have done this — the same two entries with no pairing are
        // two rows, so it is the pair that collapses them, wherever each half came from.
        let unpaired = makeModel()
        await unpaired.refreshRoutingState()
        unpaired.replaceApplicationStream([storedRow(meshID, text: "after the re-delivery")], forChatID: "chat-a")
        unpaired.replaceApplicationStream([storedRow("100001", text: "after the re-delivery")], forChatID: "chat-b")
        #expect(unpaired.result.rows.count == 2)
    }

    @Test("the fuse taking the timeline down clears every chat's entry")
    func stopClearsAllEntries() {
        let model = PopopxMeshTimelineModel(
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub())
        )
        model.replaceApplicationStream([storedRow("a-1", text: "alpha")], forChatID: "chat-a")
        model.replaceApplicationStream([storedRow("b-1", text: "beta")], forChatID: "chat-b")
        model.stop()
        #expect(model.result.rows.isEmpty)
        // A stale entry would reappear on the next feed from any chat, which is what this pins down.
        model.replaceApplicationStream([storedRow("c-1", text: "gamma")], forChatID: "chat-c")
        #expect(model.result.rows.map(\.messageID) == ["c-1"])
    }

    @Test("a host that names no chat still has one stream, not none")
    func unscopedFeedIsStillOneStream() {
        let model = PopopxMeshTimelineModel(
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub())
        )
        model.replaceApplicationStream([storedRow("x-1", text: "unclaimed")])
        #expect(model.result.rows.map(\.messageID) == ["x-1"])
        model.replaceApplicationStream([storedRow("x-2", text: "unclaimed")])
        // The unscoped host replaces its own entry rather than adding a second one.
        #expect(model.result.rows.map(\.messageID) == ["x-2"])
    }
}
