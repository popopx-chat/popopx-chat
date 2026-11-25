//
//  PopopxBLELinkTable.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Why the link bookkeeping lives in its own type instead of inside the transport: every decision a
//  Bluetooth link has to make — may I take a frame now, how large may it be, does another frame
//  already own this link's queue, may we dial one more neighbour — is arithmetic, not CoreBluetooth.
//  Kept here it is testable on a machine with no radio, which is where those mistakes are cheapest
//  to find, and the transport stays a thin adapter that only translates decisions into ATT calls.
//
//  Isolation: `entries` is read and written inside `gate` and nowhere else. `gate` is a serial queue
//  this type owns, and every method below is a single `gate.sync` leaf that never calls another
//  public method from inside its own critical section, so the queue cannot deadlock against itself.
//  That is the whole reason the class can be `@unchecked Sendable`: the transport mutates links from
//  its CoreBluetooth queue while unit tests hammer the same links from arbitrary `Task` threads, and
//  both are serialized by `gate` rather than by an agreement nobody checked.
//

import Foundation

/// Per-link send bookkeeping for the Bluetooth transport. Internal on purpose: the engine talks to
/// a transport, never to its tables.
final class PopopxBLELinkTable: @unchecked Sendable {
    /// What a close took with it. The transport reads this to fail the frames that never made it and
    /// to resume the continuations that were waiting on the link; the counts are what the tests pin.
    /// Queued frames come back by value — the radio never had them, so dropping them here would lose
    /// bytes nobody upstream knows about. In-flight ones are already CoreBluetooth's problem, so only
    /// how many there were is worth reporting.
    struct CloseOutcome: Hashable, Sendable {
        let link: PopopxBLELink
        let droppedQueuedFrames: [Data]
        let droppedInFlightFrameCount: Int
        let handshakeWasPending: Bool
    }

    /// The answer to "may I put this frame on this link right now".
    enum SendDecision: Hashable, Sendable {
        /// Hand these bytes to CoreBluetooth immediately. Counted as in flight from this moment.
        case transmit(Data)
        /// The link took ownership of the frame and will hand it back through `nextPendingFrame`.
        case queued
        /// The frame is still the caller's problem; the payload carries why.
        case rejected(PopopxBLETransportError)
    }

    private struct Entry {
        var link: PopopxBLELink
        var queued: [Data] = []
        var framesInFlight = 0
        var handshakePending = false
        let openedAt: Date
    }

    /// Frames a single link may hold while the radio is not ready. Bounded because an unbounded
    /// queue in front of a dead neighbour is a memory leak with extra steps; the caller learns the
    /// frame was refused and can re-flood or drop it.
    let maxQueuedFrames: Int
    /// How many links we dialed (central role) may exist at once. Our own peripheral-role links — the
    /// ones neighbours dial into us — are not counted: iOS caps those for us and the budget is there
    /// to stop this device from exhausting the shared radio with too many outgoing connections.
    let maxCentralLinks: Int
    /// Ceiling for a reported MTU. `bleMaxMTU`; a peer that claims more than this is not our problem.
    let maxMTU: Int

    /// The ATT MTU iOS hands a link that never negotiated one, and the floor for anything we store.
    static let defaultATTMTU = 23

    private let gate = DispatchQueue(label: "chat.popopx.mesh.ble.links", qos: .userInitiated)
    private var entries: [UUID: Entry] = [:]

    init(maxQueuedFrames: Int = 64, maxCentralLinks: Int = 6, maxMTU: Int = 512) {
        self.maxQueuedFrames = max(1, maxQueuedFrames)
        self.maxCentralLinks = max(1, maxCentralLinks)
        self.maxMTU = max(Self.defaultATTMTU, maxMTU)
    }

    // MARK: - Link lifecycle

    /// Registers a link and returns it, so the caller can announce it. Re-opening a known `linkID`
    /// replaces the entry and drops its queued frames: `linkID` is the peer's address, so the same
    /// id means a re-discovered bearer, and replaying bytes captured against the old one into a new
    /// session would corrupt the engine's frame reassembly rather than recover anything.
    func open(
        linkID: UUID,
        isCentralRole: Bool,
        canSend: Bool = false,
        rssi: Int8? = nil
    ) -> PopopxBLELink {
        gate.sync {
            let link = PopopxBLELink(
                linkID: linkID,
                isCentralRole: isCentralRole,
                canSend: canSend,
                negotiatedMTU: Self.defaultATTMTU,
                rssi: rssi
            )
            entries[linkID] = Entry(link: link, openedAt: Date())
            return link
        }
    }

    func close(linkID: UUID) -> CloseOutcome? {
        gate.sync { outcome(for: entries.removeValue(forKey: linkID)) }
    }

    /// Drops every link and returns what each one was holding, oldest first. `stop()` and a radio
    /// power-off run through this so nothing survives the radio that created it.
    @discardableResult
    func closeAll() -> [CloseOutcome] {
        gate.sync {
            let ordered = entries.sorted { $0.value.openedAt < $1.value.openedAt }
            entries.removeAll(keepingCapacity: false)
            return ordered.compactMap { outcome(for: $0.value) }
        }
    }

    /// Leaf: reads a removed entry and must be called from inside one `gate.sync`.
    private func outcome(for entry: Entry?) -> CloseOutcome? {
        guard let entry else { return nil }
        return CloseOutcome(
            link: entry.link,
            droppedQueuedFrames: entry.queued,
            droppedInFlightFrameCount: entry.framesInFlight,
            handshakeWasPending: entry.handshakePending
        )
    }

    func link(for linkID: UUID) -> PopopxBLELink? {
        gate.sync { entries[linkID]?.link }
    }

    var links: [PopopxBLELink] {
        gate.sync { entries.values.sorted { $0.openedAt < $1.openedAt }.map(\.link) }
    }

    var linkIDs: [UUID] {
        gate.sync { Array(entries.keys) }
    }

    var isEmpty: Bool {
        gate.sync { entries.isEmpty }
    }

    var linkCount: Int {
        gate.sync { entries.count }
    }

    // MARK: - Central admission

    var centralLinkCount: Int {
        gate.sync { entries.values.filter { $0.link.isCentralRole }.count }
    }

    /// Whether dialing one more neighbour is within `bleMaxCentralLinks`. Checked before `connect`,
    /// not after, so an over-budget discovery event never costs a link teardown.
    func admitsCentralLink() -> Bool {
        gate.sync { entries.values.filter { $0.link.isCentralRole }.count < maxCentralLinks }
    }

    // MARK: - Facts the radio reports

    /// Sets writability. Returns the link only when it flipped closed → open, which is the single
    /// moment worth telling the engine about; a repeat `true` is background noise on a busy link.
    /// Flipping to writable also clears the link's in-flight count, because the callback that makes
    /// a link writable again (`peripheralIsReadyToSendWriteWithoutResponse`, or a subscriber coming
    /// back) is CoreBluetooth's notice that the buffer those frames sat in has drained.
    func setCanSend(_ canSend: Bool, for linkID: UUID) -> PopopxBLELink? {
        gate.sync {
            guard var entry = entries[linkID], entry.link.canSend != canSend else { return nil }
            entry.link.canSend = canSend
            if canSend { entry.framesInFlight = 0 }
            entries[linkID] = entry
            return entry.link
        }
    }

    func record(rssi: Int8, for linkID: UUID) {
        gate.sync {
            guard var entry = entries[linkID] else { return }
            entry.link.rssi = rssi
            entries[linkID] = entry
        }
    }

    /// Stores a negotiated ATT MTU, clamped into `defaultATTMTU...maxMTU`, and returns the resulting
    /// link. Only the ceiling depends on this table; the floor is the ATT spec's minimum.
    @discardableResult
    func recordMTU(_ mtu: Int, for linkID: UUID) -> PopopxBLELink? {
        gate.sync { applyMTU(mtu, to: linkID) }
    }

    /// The CB-facing form: Apple reports what a link fits as a byte budget
    /// (`maximumWriteValueLength(for:)`, `CBCentral.maximumUpdateValueLength`), which is the MTU with
    /// the 3-byte ATT header taken out. Returns the stored MTU, or nil for an unknown link.
    @discardableResult
    func recordWriteBudget(usableBytes: Int, for linkID: UUID) -> Int? {
        guard usableBytes > 0 else { return nil }
        return gate.sync { applyMTU(usableBytes + 3, to: linkID)?.negotiatedMTU }
    }

    /// Leaf: touches `entries` directly, so it is called only from inside one `gate.sync` and never
    /// through another public method.
    private func applyMTU(_ mtu: Int, to linkID: UUID) -> PopopxBLELink? {
        guard var entry = entries[linkID] else { return nil }
        entry.link.negotiatedMTU = min(max(mtu, Self.defaultATTMTU), maxMTU)
        entries[linkID] = entry
        return entry.link
    }

    // MARK: - Handshakes

    /// Marks a link as still waiting for its ATT setup to finish. The transport mirrors its pending
    /// continuations here so "a close left a waiter parked forever" is a countable fact, not a hunch.
    func markHandshakePending(for linkID: UUID) {
        gate.sync {
            guard var entry = entries[linkID] else { return }
            entry.handshakePending = true
            entries[linkID] = entry
        }
    }

    @discardableResult
    func completeHandshake(for linkID: UUID) -> PopopxBLELink? {
        gate.sync {
            guard var entry = entries[linkID], entry.handshakePending else { return entries[linkID]?.link }
            entry.handshakePending = false
            entries[linkID] = entry
            return entry.link
        }
    }

    var pendingHandshakeCount: Int {
        gate.sync { entries.values.filter(\.handshakePending).count }
    }

    var pendingHandshakeIDs: [UUID] {
        gate.sync { entries.values.filter(\.handshakePending).map { $0.link.linkID } }
    }

    // MARK: - Queues

    /// The one way a frame enters a link. Size is checked against the link's own negotiated MTU
    /// rather than truncated: splitting an oversized message into ATT-sized pieces is the engine's
    /// job (it knows about fragment lifetimes and relay TTLs), and a transport that quietly cut a
    /// frame in half would hand the peer a corrupt packet instead of a usable error.
    func requestSend(_ frame: Data, to linkID: UUID) -> SendDecision {
        gate.sync {
            guard var entry = entries[linkID] else { return .rejected(.linkNotFound(linkID)) }
            guard frame.count <= entry.link.usablePayloadBytes else {
                return .rejected(.frameTooLarge(bytes: frame.count, usable: entry.link.usablePayloadBytes))
            }
            // A frame that arrives behind others already waiting takes its place at the end of the
            // queue even when the gate is open, or FIFO would be a suggestion.
            guard entry.link.canSend, entry.queued.isEmpty else {
                return append(frame, to: &entry, linkID: linkID)
            }
            entry.framesInFlight += 1
            entries[linkID] = entry
            return .transmit(frame)
        }
    }

    /// Leaf: called only from inside one `gate.sync`, on an entry that came out of `entries`.
    private func append(_ frame: Data, to entry: inout Entry, linkID: UUID) -> SendDecision {
        guard entry.queued.count < maxQueuedFrames else { return .rejected(.writeQueueFull(linkID: linkID)) }
        entry.queued.append(frame)
        entries[linkID] = entry
        return .queued
    }

    /// The next frame this link may send, in the order it arrived, or nil while the link is not
    /// writable. Callers loop on it; the loop ends by itself when the queue empties or the radio
    /// closes the gate.
    func nextPendingFrame(linkID: UUID) -> Data? {
        gate.sync {
            guard var entry = entries[linkID], entry.link.canSend, !entry.queued.isEmpty else { return nil }
            let frame = entry.queued.removeFirst()
            entry.framesInFlight += 1
            entries[linkID] = entry
            return frame
        }
    }

    /// Puts a frame CoreBluetooth refused back at the head, so a refused write keeps its place in the
    /// queue instead of overtaking what was already waiting. False means the room it had is gone.
    @discardableResult
    func returnFrame(_ frame: Data, to linkID: UUID) -> Bool {
        gate.sync {
            guard var entry = entries[linkID] else { return false }
            guard entry.queued.count < maxQueuedFrames else { return false }
            entry.queued.insert(frame, at: 0)
            entry.framesInFlight = max(0, entry.framesInFlight - 1)
            entries[linkID] = entry
            return true
        }
    }

    /// Takes a released frame out of the count without queueing it again, for the paths where the
    /// caller has already reported the frame as failed. Without it a link that could not be written to
    /// would carry an in-flight frame that nothing can ever settle.
    func abandonFrame(linkID: UUID) {
        gate.sync {
            guard var entry = entries[linkID] else { return }
            entry.framesInFlight = max(0, entry.framesInFlight - 1)
            entries[linkID] = entry
        }
    }

    // MARK: - Read-only totals

    func queueDepth(linkID: UUID) -> Int {
        gate.sync { entries[linkID]?.queued.count ?? 0 }
    }

    /// Frames waiting for a writable link, across every link.
    var queueDepth: Int {
        gate.sync { entries.reduce(0) { $0 + $1.value.queued.count } }
    }

    /// Frames this table has handed to CoreBluetooth that the radio has not reported as flushed.
    /// It moves when a frame leaves a queue and back to zero when the link's `canSend` flips true
    /// again or the link closes, which is what makes "no frame survived its link" a checkable claim.
    var framesInFlight: Int {
        gate.sync { entries.reduce(0) { $0 + $1.value.framesInFlight } }
    }

    func framesInFlight(linkID: UUID) -> Int {
        gate.sync { entries[linkID]?.framesInFlight ?? 0 }
    }
}
