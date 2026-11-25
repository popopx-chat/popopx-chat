//
//  PopopxBLELinkTableTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  CoreBluetooth itself is exercised on a device, not here — but every decision the transport makes
//  before it touches the radio lives in the link table, so that is what these pin: the order frames
//  leave in, when a link is allowed to have anything at all, how many neighbours we may dial, and
//  whether a closed link really kept nothing.
//

import Foundation
import Testing

@testable import PopopxMeshKit

struct PopopxBLELinkTableTests {
    private let central = UUID()
    private let listener = UUID()

    private func makeTable(
        maxQueuedFrames: Int = 64,
        maxCentralLinks: Int = 6,
        maxMTU: Int = 512
    ) -> PopopxBLELinkTable {
        PopopxBLELinkTable(
            maxQueuedFrames: maxQueuedFrames,
            maxCentralLinks: maxCentralLinks,
            maxMTU: maxMTU
        )
    }

    private func frame(_ marker: UInt8, bytes: Int = 4) -> Data {
        Data([marker] + Array(repeating: UInt8(0), count: max(0, bytes - 1)))
    }

    /// A link whose gate is open, which is the state a frame has to reach before the radio takes it.
    private func writableLink(_ table: PopopxBLELinkTable, _ linkID: UUID, isCentralRole: Bool = true) {
        _ = table.open(linkID: linkID, isCentralRole: isCentralRole)
        _ = table.setCanSend(true, for: linkID)
    }

    // MARK: - MTU and frame size

    @Test func aFreshLinkCarriesTheATTDefaultOfTwentyThree() {
        let table = makeTable()
        _ = table.open(linkID: central, isCentralRole: true)
        let link = table.link(for: central)
        #expect(link?.negotiatedMTU == PopopxBLELinkTable.defaultATTMTU)
        #expect(link?.negotiatedMTU == 23)
        #expect(link?.usablePayloadBytes == 20)
        #expect(link?.canSend == false)
        #expect(link?.rssi == nil)
    }

    @Test func usablePayloadTracksTheNegotiatedMTU() {
        let table = makeTable()
        _ = table.open(linkID: central, isCentralRole: true)
        _ = table.recordMTU(512, for: central)
        #expect(table.link(for: central)?.usablePayloadBytes == 509)
        _ = table.recordMTU(185, for: central)
        #expect(table.link(for: central)?.usablePayloadBytes == 182)
        _ = table.recordMTU(23, for: central)
        #expect(table.link(for: central)?.usablePayloadBytes == 20)
    }

    @Test func anAbsurdMTUIsClampedIntoTheRangeWeCanHonour() {
        let table = makeTable(maxMTU: 512)
        _ = table.open(linkID: central, isCentralRole: true)
        _ = table.recordMTU(9_000, for: central)
        #expect(table.link(for: central)?.negotiatedMTU == 512)
        _ = table.recordMTU(4, for: central)
        #expect(table.link(for: central)?.negotiatedMTU == 23)
    }

    @Test func theWriteBudgetAppleReportsGainsTheATTHeaderBack() {
        let table = makeTable()
        _ = table.open(linkID: central, isCentralRole: true)
        // `maximumWriteValueLength(for:)` answers 20 on a link that settled at the ATT minimum.
        #expect(table.recordWriteBudget(usableBytes: 20, for: central) == 23)
        #expect(table.recordWriteBudget(usableBytes: 509, for: central) == 512)
        #expect(table.link(for: central)?.usablePayloadBytes == 509)
        // A zero budget means the radio told us nothing, not that the link shrank to nothing.
        #expect(table.recordWriteBudget(usableBytes: 0, for: central) == nil)
        #expect(table.link(for: central)?.negotiatedMTU == 512)
        #expect(table.recordWriteBudget(usableBytes: 100, for: UUID()) == nil)
    }

    @Test func anOversizedFrameIsRefusedWholeRatherThanCutDown() {
        let table = makeTable()
        writableLink(table, central)
        #expect(table.link(for: central)?.usablePayloadBytes == 20)
        let oversized = frame(0xA5, bytes: 21)
        let decision = table.requestSend(oversized, to: central)
        #expect(decision == .rejected(.frameTooLarge(bytes: 21, usable: 20)))
        #expect(table.queueDepth == 0)
        #expect(table.framesInFlight == 0)
        // The same bytes fit once the link's MTU does, which is the only way a peer that negotiated
        // 512 ever gets a 300-byte fragment.
        _ = table.recordMTU(512, for: central)
        #expect(table.requestSend(oversized, to: central) == .transmit(oversized))
    }

    // MARK: - Queueing

    @Test func framesLeaveInTheOrderTheyArrived() {
        let table = makeTable()
        _ = table.open(linkID: central, isCentralRole: true)
        let frames = (0..<4).map { frame(UInt8($0)) }
        for one in frames {
            #expect(table.requestSend(one, to: central) == .queued)
        }
        #expect(table.queueDepth(linkID: central) == 4)
        // Nothing may leave while the gate is shut, however long the queue is.
        #expect(table.nextPendingFrame(linkID: central) == nil)
        _ = table.setCanSend(true, for: central)
        let drained = (0..<4).map { _ in table.nextPendingFrame(linkID: central) }
        #expect(drained == frames.map(Optional.some))
        #expect(table.nextPendingFrame(linkID: central) == nil)
        #expect(table.queueDepth == 0)
    }

    @Test func aFrameIsOnlyReleasedToTheRadioWhenTheLinkCanTakeIt() {
        let table = makeTable()
        writableLink(table, central)
        let first = frame(0x01)
        let second = frame(0x02)
        // Empty queue and an open gate: straight through, counted as in flight.
        #expect(table.requestSend(first, to: central) == .transmit(first))
        #expect(table.framesInFlight == 1)
        // The gate shuts: from here the table owns the bytes.
        _ = table.setCanSend(false, for: central)
        #expect(table.requestSend(second, to: central) == .queued)
        #expect(table.nextPendingFrame(linkID: central) == nil)
        // Opening it again hands out the frame that arrived first, not the newest one.
        #expect(table.setCanSend(true, for: central)?.canSend == true)
        #expect(table.framesInFlight == 0)
        #expect(table.nextPendingFrame(linkID: central) == second)
        #expect(table.framesInFlight == 1)
    }

    @Test func aFullQueueRefusesTheFrameThatDoesNotFit() {
        let table = makeTable(maxQueuedFrames: 2)
        _ = table.open(linkID: central, isCentralRole: true)
        #expect(table.requestSend(frame(0x0A), to: central) == .queued)
        #expect(table.requestSend(frame(0x0B), to: central) == .queued)
        #expect(table.requestSend(frame(0x0C), to: central) == .rejected(.writeQueueFull(linkID: central)))
        #expect(table.queueDepth(linkID: central) == 2)
        // Draining one opens exactly one slot again — the cap is a bound, not a latch.
        _ = table.setCanSend(true, for: central)
        #expect(table.nextPendingFrame(linkID: central) != nil)
        #expect(table.requestSend(frame(0x0C), to: central) == .queued)
        #expect(table.queueDepth(linkID: central) == 2)
    }

    @Test func aFrameTheRadioRefusedGoesBackToTheFrontOfItsQueue() {
        let table = makeTable()
        writableLink(table, central)
        let first = frame(0x01)
        let second = frame(0x02)
        #expect(table.requestSend(first, to: central) == .transmit(first))
        // The write buffer filled up: from here on the table owns the bytes again.
        _ = table.setCanSend(false, for: central)
        #expect(table.requestSend(second, to: central) == .queued)
        #expect(table.framesInFlight(linkID: central) == 1)
        // CoreBluetooth said no to `first`; it must overtake nothing.
        #expect(table.returnFrame(first, to: central))
        #expect(table.framesInFlight == 0)
        _ = table.setCanSend(true, for: central)
        #expect(table.nextPendingFrame(linkID: central) == first)
        #expect(table.nextPendingFrame(linkID: central) == second)
    }

    @Test func abandoningAFrameSettlesTheCountWithoutQueueingIt() {
        let table = makeTable()
        writableLink(table, central)
        _ = table.requestSend(frame(0x01), to: central)
        #expect(table.framesInFlight(linkID: central) == 1)
        table.abandonFrame(linkID: central)
        #expect(table.framesInFlight == 0)
        #expect(table.queueDepth == 0)
        // An unknown link has nothing to abandon, and must not invent one.
        table.abandonFrame(linkID: UUID())
        #expect(table.returnFrame(frame(0x01), to: UUID()) == false)
    }

    @Test func sendingToAnUnknownLinkIsReportedAsSuch() {
        let table = makeTable()
        #expect(table.requestSend(frame(0x01), to: central) == .rejected(.linkNotFound(central)))
        #expect(table.nextPendingFrame(linkID: central) == nil)
        #expect(table.setCanSend(true, for: central) == nil)
        #expect(table.recordMTU(200, for: central) == nil)
        #expect(table.queueDepth(linkID: central) == 0)
    }

    // MARK: - Gates, handshakes, admission

    @Test func onlyTheFlipIntoWritableIsWorthAnnouncing() {
        let table = makeTable()
        _ = table.open(linkID: central, isCentralRole: true)
        #expect(table.setCanSend(false, for: central) == nil)
        #expect(table.setCanSend(true, for: central)?.canSend == true)
        #expect(table.setCanSend(true, for: central) == nil)
        #expect(table.setCanSend(false, for: central)?.canSend == false)
        #expect(table.setCanSend(false, for: central) == nil)
    }

    @Test func aHandshakeStaysPendingUntilTheLinkIsUsable() {
        let table = makeTable()
        _ = table.open(linkID: central, isCentralRole: true)
        #expect(table.pendingHandshakeCount == 0)
        table.markHandshakePending(for: central)
        #expect(table.pendingHandshakeIDs == [central])
        #expect(table.pendingHandshakeCount == 1)
        _ = table.completeHandshake(for: central)
        #expect(table.pendingHandshakeCount == 0)
        // Closing a link that was still handshaking says so, which is how the transport knows a
        // continuation on it has to be answered.
        table.markHandshakePending(for: central)
        #expect(table.close(linkID: central)?.handshakeWasPending == true)
    }

    @Test func theCentralBudgetCountsTheLinksWeDialedAndIgnoresTheOnesDialedIntoUs() {
        let table = makeTable(maxCentralLinks: 2)
        #expect(table.admitsCentralLink())
        _ = table.open(linkID: UUID(), isCentralRole: true)
        _ = table.open(linkID: listener, isCentralRole: false)
        #expect(table.centralLinkCount == 1)
        #expect(table.admitsCentralLink())
        _ = table.open(linkID: central, isCentralRole: true)
        #expect(table.centralLinkCount == 2)
        #expect(!table.admitsCentralLink())
        // Saturated outgoing budget, but a neighbour may still connect to us.
        #expect(table.linkCount == 3)
        _ = table.open(linkID: UUID(), isCentralRole: false)
        #expect(table.linkCount == 4)
        #expect(!table.admitsCentralLink())
    }

    @Test func rssiIsRecordedAgainstTheLinkThatReportedIt() {
        let table = makeTable()
        _ = table.open(linkID: central, isCentralRole: true)
        #expect(table.link(for: central)?.rssi == nil)
        table.record(rssi: -72, for: central)
        #expect(table.link(for: central)?.rssi == -72)
        table.record(rssi: -40, for: central)
        #expect(table.link(for: central)?.rssi == -40)
        table.record(rssi: -1, for: UUID())
    }

    // MARK: - Closing

    @Test func closingALinkHandsBackTheFramesItNeverReleased() {
        let table = makeTable()
        writableLink(table, central)
        _ = table.requestSend(frame(0x01), to: central)
        _ = table.setCanSend(false, for: central)
        _ = table.requestSend(frame(0x02), to: central)
        _ = table.requestSend(frame(0x03), to: central)
        #expect(table.framesInFlight(linkID: central) == 1)
        #expect(table.queueDepth(linkID: central) == 2)

        guard let outcome = table.close(linkID: central) else {
            Issue.record("the link was not there to close")
            return
        }
        #expect(outcome.droppedInFlightFrameCount == 1)
        #expect(outcome.droppedQueuedFrames.count == 2)
        #expect(outcome.droppedQueuedFrames == [frame(0x02), frame(0x03)])
        #expect(outcome.link.linkID == central)
        // Nothing survives the link that held it — the leak this whole type exists to prevent.
        #expect(table.framesInFlight == 0)
        #expect(table.queueDepth == 0)
        #expect(table.pendingHandshakeCount == 0)
        #expect(table.link(for: central) == nil)
        #expect(table.close(linkID: central) == nil)
    }

    @Test func closeAllEmptiesEveryQueueAtOnce() {
        let table = makeTable(maxQueuedFrames: 8, maxCentralLinks: 8)
        let ids = (0..<4).map { _ in UUID() }
        for (offset, id) in ids.enumerated() {
            _ = table.open(linkID: id, isCentralRole: offset % 2 == 0)
            table.markHandshakePending(for: id)
            _ = table.requestSend(frame(UInt8(offset)), to: id)
        }
        #expect(table.queueDepth == 4)
        let outcomes = table.closeAll()
        #expect(outcomes.count == 4)
        #expect(Set(outcomes.map(\.link.linkID)) == Set(ids))
        #expect(outcomes.reduce(0) { $0 + $1.droppedQueuedFrames.count } == 4)
        #expect(outcomes.filter(\.handshakeWasPending).count == 4)
        #expect(table.isEmpty)
        #expect(table.linkIDs.isEmpty)
        #expect(table.queueDepth == 0)
        #expect(table.framesInFlight == 0)
        #expect(table.pendingHandshakeCount == 0)
        #expect(table.admitsCentralLink())
    }

    @Test func reopeningALinkDoesNotInheritTheOldQueue() {
        let table = makeTable()
        writableLink(table, central)
        _ = table.requestSend(frame(0x01), to: central)
        _ = table.setCanSend(false, for: central)
        _ = table.requestSend(frame(0x02), to: central)
        #expect(table.queueDepth(linkID: central) == 1)
        #expect(table.framesInFlight == 1)
        _ = table.open(linkID: central, isCentralRole: true)
        #expect(table.queueDepth == 0)
        #expect(table.framesInFlight == 0)
        #expect(table.pendingHandshakeCount == 0)
        #expect(table.link(for: central)?.canSend == false)
    }

    // MARK: - Concurrent bookkeeping

    /// The table is shared between the transport's CoreBluetooth queue and everything else, so the
    /// same calls are run at each other from many `Task`s and the totals have to still add up.
    @Test func concurrentEnqueuesNeitherCrashNorLoseCount() async {
        let linkCount = 4
        let perTask = 60
        let taskCount = 24
        let table = makeTable(maxQueuedFrames: 512, maxCentralLinks: linkCount)
        let ids = (0..<linkCount).map { _ in UUID() }
        for id in ids { _ = table.open(linkID: id, isCentralRole: true) }

        await withTaskGroup(of: Int.self) { group in
            for step in 0..<taskCount {
                group.addTask {
                    var accepted = 0
                    for index in 0..<perTask {
                        switch table.requestSend(self.frame(UInt8(step % 7)), to: ids[index % ids.count]) {
                        case .rejected(.writeQueueFull): break
                        case .rejected: Issue.record("unexpected rejection \(ids[index % ids.count])")
                        case .queued, .transmit: accepted += 1
                        }
                        // Interleave the readers with the writers: a snapshot taken mid-storm must
                        // still be a coherent number, not a torn read of the map.
                        if index % 11 == 0 { _ = table.queueDepth + table.framesInFlight }
                        if index % 17 == 0 { _ = table.links.count }
                    }
                    return accepted
                }
            }
            var total = 0
            for await accepted in group { total += accepted }
            #expect(total == taskCount * perTask)
            // Everything the table accepted is either still queued or in the radio's hands, and the
            // two together are exactly what was handed in.
            #expect(table.queueDepth + table.framesInFlight == total)
            #expect(table.queueDepth <= linkCount * 512)
        }

        for id in ids { _ = table.close(linkID: id) }
        #expect(table.queueDepth == 0)
        #expect(table.framesInFlight == 0)
    }

    @Test func concurrentDrainAndEnqueueConserveTheFrames() async {
        let table = makeTable(maxQueuedFrames: 128)
        let linkID = UUID()
        writableLink(table, linkID)
        let rounds = 40

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<rounds { _ = table.requestSend(self.frame(0x01), to: linkID) }
            }
            group.addTask {
                for _ in 0..<rounds {
                    _ = table.nextPendingFrame(linkID: linkID)
                    table.abandonFrame(linkID: linkID)
                }
            }
            group.addTask {
                for _ in 0..<rounds {
                    _ = table.setCanSend(false, for: linkID)
                    _ = table.setCanSend(true, for: linkID)
                }
            }
        }
        // Frames drained are frames gone; whatever is left is queued plus what the radio holds.
        let attempts = rounds
        let accounted = table.queueDepth + table.framesInFlight
        #expect(accounted <= attempts)
        #expect(table.linkCount == 1)
        _ = table.close(linkID: linkID)
        #expect(table.queueDepth == 0)
        #expect(table.framesInFlight == 0)
    }
}
