//
//  PopopxMeshTimelineMergeTests.swift
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Module 7's timeline rules, asserted on the merger rather than on a rendered view: dedup strictly on the
//  globally unique messageId, sort by timestamp, control signalling filtered, and the three badges
//  (blue shield / orange ripple + hop count / grey clock) classified from the channel, not from the text.
//

import Foundation
import Testing
@testable import PopopxMeshUI
import PopopxMeshKit

private func day(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
}

@Suite("PopopxMeshTimelineMerger")
struct PopopxMeshTimelineMergeTests {
    @Test("An id both streams carry appears once, as the app's copy")
    func dedupKeepsApplicationCopy() {
        let shared = PopopxMeshTimelineMessage.application(
            messageID: "same-id",
            timestamp: day(10),
            text: "hello over SMP",
            direction: .outgoing
        )
        let meshCopy = PopopxMeshTimelineMessage.offline(
            messageID: "same-id",
            timestamp: day(11),
            text: "hello over mesh",
            hopCount: 2
        )
        let result = PopopxMeshTimelineMerger.merge(
            application: [shared],
            offline: [meshCopy]
        )
        #expect(result.rows.count == 1)
        let row = try? XCTUnwrapRow(result.rows.first)
        #expect(row?.text == "hello over SMP")
        #expect(row?.channel == .smpPublicNetwork)
        // The flag the overlay needs: this row is already in the chat's own list, so the strip must
        // not draw it a second time.
        #expect(row?.presentInApplicationStream == true)
        #expect(result.offlineOnlyRows.isEmpty)
    }

    @Test("A mesh-only row is drawn by the overlay, in timestamp order")
    func offlineOnlyRowsSortByTimestamp() {
        let older = PopopxMeshTimelineMessage.offline(
            messageID: "b-old", timestamp: day(1), text: "older", hopCount: 0
        )
        let newer = PopopxMeshTimelineMessage.offline(
            messageID: "a-new", timestamp: day(9), text: "newer", hopCount: 3
        )
        let app = PopopxMeshTimelineMessage.application(
            messageID: "c-app", timestamp: day(5), text: "app", direction: .incoming
        )
        let result = PopopxMeshTimelineMerger.merge(application: [app], offline: [newer, older])
        #expect(result.rows.map(\.messageID) == ["b-old", "c-app", "a-new"])
        #expect(result.offlineOnlyRows.map(\.messageID) == ["b-old", "a-new"])
    }

    @Test("The same id flooded by three neighbours is one row")
    func strictIdempotencyOnMessageID() {
        let flooders = ["a", "b", "c"]
        let copies = flooders.enumerated().map { index, letter in
            PopopxMeshTimelineMessage.offline(
                messageID: "flooded",
                timestamp: day(4),
                text: "one flood",
                hopCount: index,
                senderPeerIDHex: PopopxMeshTestKeys.peerIDHex(letter)
            )
        }
        let result = PopopxMeshTimelineMerger.merge(application: [], offline: copies)
        #expect(result.rows.count == 1)
        // The last offline copy wins within the mesh stream, so the hop count is the one the local
        // node heard last, not the smallest.
        #expect(result.rows.first?.hopCount == 2)
    }

    @Test("Control signalling never reaches the timeline")
    func controlFramesAreFiltered() {
        let pairing = PopopxMeshTimelineMessage(
            messageID: "ctl-1",
            timestamp: day(1),
            text: PopopxMeshControlFrame.pairingRequestPrefix + "popopx://invite/x",
            direction: .incoming,
            channel: .offlineMesh(hopCount: 1)
        )
        let ack = PopopxMeshTimelineMessage.offline(
            messageID: "ctl-2",
            timestamp: day(2),
            text: PopopxMeshControlFrame.deliveryAckPrefix + "some-message",
            hopCount: 0
        )
        let flagged = PopopxMeshTimelineMessage.offline(
            messageID: "ctl-3",
            timestamp: day(3),
            text: "looks like prose",
            hopCount: 0,
            isControlSignal: true
        )
        let result = PopopxMeshTimelineMerger.merge(application: [], offline: [pairing, ack, flagged])
        #expect(result.rows.isEmpty)
        // And the classification does not need the flag: the prefixes are the wire protocol's own.
        #expect(PopopxMeshTimelineMerger.isControlText(PopopxMeshControlFrame.pairingAckPrefix + "abc"))
        #expect(!PopopxMeshTimelineMerger.isControlText("hello neighbours"))
    }

    @Test("An id the router still owes a relay is re-badged to the grey clock")
    func awaitingRelayOverridesChannel() {
        let meshRow = PopopxMeshTimelineMessage.offline(
            messageID: "owed", timestamp: day(1), text: "waiting", hopCount: 2
        )
        let appRow = PopopxMeshTimelineMessage.application(
            messageID: "also-owed", timestamp: day(2), text: "smp too", direction: .outgoing
        )
        let result = PopopxMeshTimelineMerger.merge(
            application: [appRow],
            offline: [meshRow],
            awaitingRelayMessageIDs: ["owed", "also-owed"]
        )
        #expect(result.rows.map(\.channel) == [.awaitingRelay, .awaitingRelay])
        // Sorting puts awaiting relay before a delivered mesh row at the same instant: the honest "not yet
        // there" is the more urgent thing to show.
        let sameInstant = PopopxMeshTimelineMerger.merge(
            application: [],
            offline: [
                PopopxMeshTimelineMessage.offline(
                    messageID: "z-delivered", timestamp: day(7), text: "delivered", hopCount: 1
                ),
                PopopxMeshTimelineMessage.offline(
                    messageID: "a-relay", timestamp: day(7), text: "relay", hopCount: 1
                )
            ],
            awaitingRelayMessageIDs: ["a-relay"]
        )
        #expect(sameInstant.rows.map(\.messageID) == ["a-relay", "z-delivered"])
    }

    @Test("Blue shield is SMP, orange ripple with hops is mesh, grey clock is awaiting relay")
    func badgeClassification() {
        let smp = PopopxMeshBadgeDescriptor(channel: .smpPublicNetwork)
        #expect(smp.tone == .blue)
        #expect(smp.symbolName == "shield.lefthalf.filled")
        #expect(smp.accessory == nil)

        let mesh = PopopxMeshBadgeDescriptor(channel: .offlineMesh(hopCount: 3))
        #expect(mesh.tone == .orange)
        #expect(mesh.symbolName == "antenna.radiowaves.left.and.right")
        #expect(mesh.accessory == "· 3")
        #expect(mesh.accessibilityLabel.contains("3 hops"))

        let direct = PopopxMeshBadgeDescriptor(channel: .offlineMesh(hopCount: 0))
        #expect(direct.accessory == "· 0")
        #expect(direct.accessibilityLabel.contains("direct"))

        let relay = PopopxMeshBadgeDescriptor(channel: .awaitingRelay)
        #expect(relay.tone == .grey)
        #expect(relay.symbolName == "clock")
    }

    @Test("A row's badge comes from its channel, so a mesh row cannot show a shield")
    func rowBadgeFollowsChannel() {
        let row = PopopxMeshTimelineRow(
            messageID: "r",
            timestamp: day(1),
            text: "t",
            direction: .incoming,
            channel: .offlineMesh(hopCount: 1),
            senderNickname: nil,
            presentInApplicationStream: false
        )
        #expect(row.badge.tone == .orange)
        #expect(row.badge.accessory == "· 1")
        #expect(row.hopCount == 1)
    }

    @Test("The merge is deterministic: the same inputs in any arrival order give one output")
    func orderIndependence() {
        let app = (0..<6).map {
            PopopxMeshTimelineMessage.application(
                messageID: "app-\($0)",
                timestamp: day(TimeInterval($0)),
                text: "a\($0)",
                direction: .outgoing
            )
        }
        let offline = (0..<6).map {
            PopopxMeshTimelineMessage.offline(
                messageID: "off-\($0)",
                timestamp: day(TimeInterval($0)),
                text: "o\($0)",
                hopCount: $0 % 3
            )
        }
        let forward = PopopxMeshTimelineMerger.merge(application: app, offline: offline)
        let backward = PopopxMeshTimelineMerger.merge(application: app.reversed(), offline: offline.reversed())
        #expect(forward.rows == backward.rows)
        // Both streams are in `rows` — the merge is not a filter — so the orderable claim is that
        // each stream keeps its own ascending order inside the merged timeline, and that the merged
        // timeline holds every id exactly once. (Asserting `rows == app ids` would contradict the
        // mesh-only rows the overlay draws, which `offlineOnlyRowsSortByTimestamp` pins down.)
        #expect(forward.rows.count == 12)
        #expect(Set(forward.rows.map(\.messageID)) == Set(app.map(\.messageID) + offline.map(\.messageID)))
        #expect(
            forward.rows.filter { $0.channel == .smpPublicNetwork }.map(\.messageID)
                == (0..<6).map { "app-\($0)" }
        )
        #expect(
            forward.rows.filter { $0.hopCount != nil }.map(\.messageID)
                == (0..<6).map { "off-\($0)" }
        )
        // Reversing the arrival order cannot move a row: the tie-break is the id, not the array.
        #expect(
            backward.rows.filter { $0.channel == .smpPublicNetwork }.map(\.messageID)
                == (0..<6).map { "app-\($0)" }
        )
    }

    @Test("The control prefixes are the wire protocol's own, not a copy")
    func prefixesComeFromTheProtocol() {
        #expect(PopopxMeshTimelineMerger.controlPrefixes.contains(PopopxMeshControlFrame.pairingRequestPrefix))
        #expect(PopopxMeshTimelineMerger.controlPrefixes.contains(PopopxMeshControlFrame.pairingAckPrefix))
        #expect(PopopxMeshTimelineMerger.controlPrefixes.contains(PopopxMeshControlFrame.deliveryAckPrefix))
    }
}

// MARK: - The model

@MainActor
@Suite("PopopxMeshTimelineModel")
struct PopopxMeshTimelineModelTests {
    @Test("Feeding the two streams publishes merged rows without a view")
    func pipelinePublishes() async throws {
        let model = PopopxMeshTimelineModel(
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub()),
            routing: PopopxMeshNoRoutingObserver()
        )
        model.replaceApplicationStream([
            PopopxMeshTimelineMessage.application(
                messageID: "app-1", timestamp: day(2), text: "app", direction: .outgoing
            )
        ])
        #expect(model.result.rows.count == 1)
        // The overlay only ever draws what the app's list does not contain, so the red line
        // "zero-breakage UI mounting" ("do not rewrite ChatView") cannot turn into "draw the same bubble twice".
        #expect(model.offlineOnlyRows.isEmpty)

        model.setAwaitingRelayMessageIDs(["app-1"])
        #expect(model.result.rows.first?.channel == .awaitingRelay)
        #expect(model.offlineOnlyRows.isEmpty)
    }

    @Test("Plain tuples map onto the application stream")
    func tupleFeeder() {
        let model = PopopxMeshTimelineModel(
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub())
        )
        model.replaceApplicationStream(with: [
            (messageID: "one", timestamp: day(1), text: "first"),
            (messageID: "two", timestamp: day(2), text: "second")
        ])
        #expect(model.result.rows.map(\.text) == ["first", "second"])
        #expect(model.result.rows.allSatisfy { $0.channel == .smpPublicNetwork })
    }

    @Test("The router's owed ids are unioned with the mirror's")
    func relayIdsUnion() async throws {
        let routing = PopopxMeshFakeRouting(relayIDs: ["from-router"])
        let source = PopopxMeshStateSource(hub: PopopxMeshEventHub())
        let model = PopopxMeshTimelineModel(source: source, routing: routing)
        await model.refreshRoutingState()
        #expect(model.result.rows.isEmpty)

        // The mirror reports a send that never left the device; that id becomes awaiting relay.
        source.ingest(.sendFailed(messageId: "from-mesh", peer: nil, reason: .noLinkToPeer))
        await model.refreshRoutingState()
        model.replaceApplicationStream([
            PopopxMeshTimelineMessage.application(
                messageID: "from-router", timestamp: day(1), text: " owed by router", direction: .outgoing
            ),
            PopopxMeshTimelineMessage.application(
                messageID: "from-mesh", timestamp: day(2), text: "owed by mesh", direction: .outgoing
            )
        ])
        #expect(model.result.rows.map(\.channel) == [.awaitingRelay, .awaitingRelay])
    }

    @Test("Starting and stopping the mirror leaves no consumer behind")
    func consumersAreReleased() async throws {
        let source = PopopxMeshStateSource(hub: PopopxMeshEventHub())
        let model = PopopxMeshTimelineModel(source: source)
        #expect(source.consumerCount == 0)
        model.start()
        try await popopxMeshWaitUntil("a consumer to appear") { source.consumerCount > 0 }
        model.stop()
        try await popopxMeshWaitUntil("the consumer to be released") { source.consumerCount == 0 }
        // The mirror outlives the timeline on purpose (the banner and the plaza read the same source);
        // it is the fuse that takes it down, and that is the path asserted here.
        await source.meshSwitchDidTurnOff()
        #expect(source.isPumping == false)
        #expect(source.state == PopopxMeshStreamState())
    }
}

/// `XCTAssert` is not available here, so a small local unwrap keeps the dedup test readable.
private func XCTUnwrapRow(_ row: PopopxMeshTimelineRow?) throws -> PopopxMeshTimelineRow {
    try #require(row)
}
