//
//  PopopxMeshPrivateChatView.swift
//  PopopxMeshUI
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  module 7's private-chat screen — the 1:1 offline conversation with ONE paired mesh neighbour. Phase 2 asks for
//  "add a standalone #mesh local offline plaza and private-chat screen (with local temporary nickname setting)": the plaza is the broadcast half
//  (`MeshPlazaView`), this is the private half, and it is a separate screen rather than a filter on
//  the plaza because the two have different guarantees — a flood is unencrypted, unacknowledged and
//  for whoever is standing nearby, while a private message is Noise_XX keyed, BLE_ACK guarded and
//  addressed to one key.
//
//  Three rules decide the whole file.
//
//  1. It is the OFFLINE surface. One envelope goes to `PopopxMeshOutbound.send(envelope:to:)` and
//     nothing else: no SMP request is built, no `PopopxMessageRouter` is contacted, no connectivity
//     question is asked. Choosing the public network is module 5's job — it owns the 3-second window,
//     the re-route that keeps the `messageId`, and the offline backlog. A screen that reached for SMP
//     underneath the router would be a second sender of the same text, and the peer's deduplicator
//     is the only thing that makes two senders one message.
//  2. Zero-breakage (iron rule 27). Nothing here rewrites `ChatView` or mounts into it: this is its own
//     destination view, reached from `MeshPrivacySettingsView`'s binding list, and it badges rows
//     with the same `PopopxMeshChannelBadge` the merged timeline uses, so a bubble means the same
//     thing on both screens.
//  3. Global circuit-breaker (iron rule 28). `meshIsEnabled` mirrors the fuse's own `@Published` switch, so with the
//     switch off this view is an `EmptyView`, the mirror is never subscribed, the peer table is never
//     read, and `sendDraft()` returns before it asks anyone anything. Off means off, including here.
//
//  The nickname is the plaza's: one local display name in `Documents/popopx_mesh/`, editable on this
//  screen too, because it is the name a peer sees on the other side of a private session as well as
//  on a broadcast. "Temporary" in the only sense the spec means — device-local display state, never bound to
//  a contact, erased with the rest of the sandbox by a panic wipe.
//

import Combine
import Foundation
import PopopxMeshKit
import SwiftUI

// MARK: - Values the screen shows

/// One peer's radio facts, in the shape this screen can draw.
///
/// `PopopxMeshPeer` (module 7's mirror) and `PopopxPeerReachability` (module 4) are the core's own types
/// and neither has a public initialiser, so a host that already holds a node table — and every test
/// of the reachability rule — states the situation through this value instead of through a radio.
public struct PopopxMeshPrivateChatPeer: Hashable, Sendable {
    public let peerIDHex: String
    public let nickname: String?
    /// Hops away as the mesh last measured it: 0 is a link this device holds.
    public let hopCount: Int
    public let lastSeenAt: Date
    /// True when one of our own links carries the peer, false when a neighbour relays for it.
    public let isDirect: Bool

    public init(
        peerIDHex: String,
        nickname: String? = nil,
        hopCount: Int = 0,
        lastSeenAt: Date = .now,
        isDirect: Bool = true
    ) {
        self.peerIDHex = peerIDHex
        self.nickname = nickname
        self.hopCount = hopCount
        self.lastSeenAt = lastSeenAt
        self.isDirect = isDirect
    }

    /// The mirror's peer, named the way this screen names it.
    init(mirrored peer: PopopxMeshPeer) {
        self.peerIDHex = peer.peerID.hex
        self.nickname = peer.nickname
        self.hopCount = peer.hopCount
        self.lastSeenAt = peer.lastSeenAt
        self.isDirect = peer.isDirect
    }
}

/// Why a message this screen authored did not go out. Kept separate from the mesh's own failure
/// value so the two reasons a user has to be told apart — "nobody is paired with you" and "the radio
/// refused it" — cannot be collapsed by a later caller.
public enum PopopxMeshPrivateChatRefusal: Hashable, Sendable {
    /// Unbound stranger: no proof this key belongs to anyone, with the state that said so attached so the
    /// line can distinguish "never paired" from "waiting on their approval". The sentence itself is
    /// Module 5's own (`PopopxMessageRouter.unboundStrangerStatusText`), quoted rather than paraphrased.
    case peerNotPaired(MeshPairingState)
    /// The frame reached the send path and module 2's engine refused it before the radio.
    case transport(PopopxMeshSendFailure)
}

/// What one outgoing row owes the user. Derived, never stored optimistically: the only positive
/// evidence this layer has is a `BLE_ACK` removing an id from the mirror's owed-relay set.
public enum PopopxMeshPrivateChatDelivery: Hashable, Sendable {
    /// The peer's copy. Nothing is owed back for it.
    case received
    /// Handed to the mesh; no acknowledgement recorded for the id yet.
    case handedToMesh
    /// Grey clock — the mesh could not put it on the radio, or still owes a relay for it.
    case awaitingRelay
    /// A `BLE_ACK` for this id arrived: the peer confirmed it.
    case acknowledged
    /// Never left this device, for one of the reasons above.
    case refused(PopopxMeshPrivateChatRefusal)
}

/// One row of the conversation. `id` is the mesh's global `messageId` — the value every dedup, ACK
/// and re-route in the package keys on — so a row here and a row in the merged timeline are the same
/// message rather than two look-alikes.
public struct PopopxMeshPrivateChatMessage: Identifiable, Hashable, Sendable {
    public let id: String
    public let text: String
    public let timestamp: Date
    public let direction: PopopxMeshTimelineDirection
    /// The channel the row is badged with, after the merge's rules — including the grey-clock
    /// override an owed relay applies.
    public let channel: PopopxMeshTimelineChannel
    public let senderNickname: String?
    public let delivery: PopopxMeshPrivateChatDelivery

    public init(
        id: String,
        text: String,
        timestamp: Date,
        direction: PopopxMeshTimelineDirection,
        channel: PopopxMeshTimelineChannel,
        senderNickname: String? = nil,
        delivery: PopopxMeshPrivateChatDelivery
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.direction = direction
        self.channel = channel
        self.senderNickname = senderNickname
        self.delivery = delivery
    }

    public var badge: PopopxMeshBadgeDescriptor { PopopxMeshBadgeDescriptor(channel: channel) }

    /// A row that never left the device has no channel to badge. Drawing the orange ripple for a
    /// message the mesh never accepted would be this screen claiming a delivery it did not get.
    public var showsChannelBadge: Bool {
        if case .refused(.peerNotPaired) = delivery { return false }
        return true
    }

    /// Whether the delivery line is a problem, so the view asks instead of re-deriving the rule.
    public var deliveryIsFailure: Bool {
        if case .refused = delivery { return true }
        return false
    }

    init(row: PopopxMeshTimelineRow, delivery: PopopxMeshPrivateChatDelivery) {
        self.id = row.messageID
        self.text = row.text
        self.timestamp = row.timestamp
        self.direction = row.direction
        self.channel = row.channel
        self.senderNickname = row.senderNickname
        self.delivery = delivery
    }
}

/// Why an empty conversation is empty, decided by the view model so the copy is testable and a
/// future `body` cannot guess.
public enum PopopxMeshPrivateChatEmptyReason: Hashable, Sendable {
    /// Not paired with this key at all: module 5's stranger sentence is the honest answer.
    case notPaired
    /// Our own radio cannot carry anything.
    case radioUnavailable(PopopxBluetoothState)
    /// Paired, and silent for longer than module 4's reachability window — the spec's out-of-range case.
    case peerOutOfRange(hops: Int, lastSeenAt: Date)
    /// Paired and the radio is up, but this device has never heard the node since Bluetooth came up.
    case peerNeverHeard
    /// In range, and simply nothing said yet.
    case nothingSaidYet
}

/// The empty state as two lines of copy.
public struct PopopxMeshPrivateChatEmptyState: Hashable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

// MARK: - View model

/// Everything the private screen knows, and every rule it applies, with no SwiftUI in it.
@MainActor
public final class PopopxMeshPrivateChatModel: ObservableObject {
    /// The same composer bound as the plaza's. Not a protocol limit — the engine fragments what a
    /// link cannot take whole — just one bubble's worth of text on one screen.
    public static let maxDraftCharacters = 512

    /// The conversation, merged, deduplicated by `messageId` and ordered.
    @Published public private(set) var messages: [PopopxMeshPrivateChatMessage] = []

    /// Editable by design: the composer's `TextField` binds here.
    @Published public var draft: String = ""

    /// This device's local mesh name, shared with the plaza's. Editable; `saveNickname()` is what
    /// turns the typed text into persisted, clamped state.
    @Published public var nickname: String

    /// Mirrored from the fuse, so flipping the master switch off collapses this screen without waiting for a
    /// packet that may never come.
    @Published public private(set) var meshIsEnabled: Bool

    @Published public private(set) var radioState: PopopxBluetoothState = .unknown

    /// The peer's radio facts, as the mirror last reported them or as a host pushed them in.
    @Published public private(set) var peer: PopopxMeshPrivateChatPeer?

    /// Module 3's live state for this key, as of the last `refresh()` or `sendDraft()`.
    @Published public private(set) var pairingState: MeshPairingState = .unlinked

    /// Module 1's row for this key, if this device has one.
    @Published public private(set) var binding: PopopxMeshBindingSummary?

    /// The last reason a send did not go out, so the composer can say it in one line.
    @Published public private(set) var lastRefusal: PopopxMeshPrivateChatRefusal?

    @Published public private(set) var isSending = false

    private let peerMeshPublicKeyHex: String
    private let outbound: any PopopxMeshOutbound
    private let source: PopopxMeshStateSource
    private let nicknameStore: PopopxMeshNicknameStore
    private let nicknameApplier: (any PopopxMeshNicknameApplying)?
    /// Module 3's seam for the live answer to "is this peer paired". module 3 has no singleton — it needs
    /// the app's chat core — so a host that has a manager hands one over, and a host that has none is
    /// judged on module 1's durable row instead.
    private let pairing: (any PopopxMeshPairingControlling)?
    private let bindings: (any PopopxMeshBindingObserving)?
    private let killSwitch: PopopxMeshKillSwitch?
    /// 15 seconds, the same window module 4 measures "Bluetooth unreachable" against, read from the config rather than
    /// retyped here.
    private let reachabilityTimeout: TimeInterval
    private var ownRecords: [PopopxMeshTimelineMessage] = []
    private var pushedIncoming: [PopopxMeshTimelineMessage] = []
    private var mirroredIncoming: [PopopxMeshTimelineMessage] = []
    /// The ids this screen authored that it handed to the mesh.
    private var handedOffIDs: Set<String> = []
    private var acknowledgedIDs: Set<String> = []
    private var refusalsByID: [String: PopopxMeshPrivateChatRefusal] = [:]
    private var mirroredRelayIDs: Set<String> = []
    private var pumpTask: Task<Void, Never>?

    /// - Parameters:
    ///   - peerMeshPublicKeyHex: the ONE peer this screen talks to, in the 64-hex spelling
    ///     `SYS_POPOPX_ACK:` carries. Spelled differently it is canonicalised rather than refused, so
    ///     a host that read a key out of a frame in upper case still lands on one conversation.
    ///   - pairing: module 3's seam, the live proof.
    ///   - bindings: module 1's seam, the durable proof. With neither seam there is no proof of a peer
    ///     and every send is refused — which is the unbound-stranger rule, not a limitation.
    ///   - killSwitch: the fuse. `nil` falls back to the persisted key, exactly as
    ///     `PopopxMeshSettingsModel` does, so there is still one value and one owner of it.
    public init(
        peerMeshPublicKeyHex: String,
        outbound: any PopopxMeshOutbound,
        source: PopopxMeshStateSource = .shared,
        nicknameStore: PopopxMeshNicknameStore = PopopxMeshNicknameStore(),
        nicknameApplier: (any PopopxMeshNicknameApplying)? = nil,
        pairing: (any PopopxMeshPairingControlling)? = nil,
        bindings: (any PopopxMeshBindingObserving)? = nil,
        killSwitch: PopopxMeshKillSwitch? = nil,
        config: PopopxMeshConfig = .default
    ) {
        let canonical = IdentityMappingStore.canonicalMeshPublicKeyHex(peerMeshPublicKeyHex)
        self.peerMeshPublicKeyHex = canonical ?? peerMeshPublicKeyHex.lowercased()
        self.outbound = outbound
        self.source = source
        self.nicknameStore = nicknameStore
        self.nicknameApplier = nicknameApplier
        self.pairing = pairing
        self.bindings = bindings
        self.killSwitch = killSwitch
        self.reachabilityTimeout = config.peerReachabilityTimeout
        self.nickname = nicknameStore.read() ?? PopopxMeshNicknameStore.defaultNickname
        self.meshIsEnabled = killSwitch?.isEnabled
            ?? UserDefaults.standard.bool(forKey: PopopxMeshKillSwitch.enabledDefaultsKey)
        // With a fuse present its own `@Published` is the only writer of `meshIsEnabled`, so
        // `assign(to:)` rather than a `sink`: no closure has to claim a hop onto the main actor, and
        // the operator manages the subscription itself — the same data flow `PopopxMeshTimelineModel`
        // uses for its merged rows.
        if let killSwitch {
            killSwitch.$isEnabled.assign(to: &$meshIsEnabled)
        }
    }

    /// The key this screen sends to, canonicalised. Public because the settings page's row and any
    /// later deep link have to name the same conversation.
    public var peerMeshPublicKey: String { peerMeshPublicKeyHex }

    // MARK: - Reading the screen

    /// The peer's name, by the evidence this device has: what it announced, else what the user's own
    /// contact table calls the key, else the wire id it is known by.
    public var peerDisplayName: String {
        if let announced = trimmed(peer?.nickname) { return announced }
        if let stored = trimmed(binding?.nickname) { return stored }
        return PopopxMeshPrivateChatModel.peerLabel(peerMeshPublicKeyHex)
    }

    /// Whether this key may be handed a message at all: module 3's live `paired`, or a durable module 1
    /// row — which is what the settings page listed to open this screen in the first place.
    public var peerIsPaired: Bool {
        if case .paired = pairingState { return true }
        return binding != nil
    }

    /// Our radio up, the node known, and heard from inside module 4's window — the same three facts
    /// module 5 asks as an up-front prediction, stated here only to describe what is on this screen.
    public var peerIsInRange: Bool {
        guard radioState.isUsable, let peer else { return false }
        return Date.now.timeIntervalSince(peer.lastSeenAt) <= reachabilityTimeout
    }

    /// The composer's gate. Deliberately not gated on the radio or on pairing: whether a send can
    /// leave is a question the mesh answers at the moment it is asked, and a greyed-out field would
    /// hide the one refusal the user needs to read.
    public var canSend: Bool {
        meshIsEnabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How far away the peer is, in the units the plaza already uses, plus when it was last heard.
    public var peerReachDescription: String? {
        guard let peer else { return nil }
        var line = PopopxMeshReachEstimate.description(hops: peer.hopCount)
        line += peer.isDirect ? " · direct link" : " · relayed"
        line += " · seen \(Self.words(since: peer.lastSeenAt))"
        return line
    }

    /// The pairing state in one line, so the header can say what module 3 thinks of this key.
    public var pairingStateDescription: String { Self.words(for: pairingState) }

    public var emptyReason: PopopxMeshPrivateChatEmptyReason? {
        guard meshIsEnabled, messages.isEmpty else { return nil }
        guard peerIsPaired else { return .notPaired }
        guard radioState.isUsable else { return .radioUnavailable(radioState) }
        guard let peer else { return .peerNeverHeard }
        return peerIsInRange
            ? .nothingSaidYet
            : .peerOutOfRange(hops: peer.hopCount, lastSeenAt: peer.lastSeenAt)
    }

    /// nil whenever there is something to show: an empty state drawn next to a real conversation is
    /// the bug this guard exists to prevent.
    public var emptyState: PopopxMeshPrivateChatEmptyState? {
        guard let reason = emptyReason else { return nil }
        return Self.copy(for: reason, peerName: peerDisplayName)
    }

    // MARK: - Lifecycle

    /// Mirrors the mesh for this peer. Idempotent, and a no-op while the fuse is off, so mounting
    /// this screen with the switch off subscribes to nothing and reads nothing.
    public func start() {
        guard meshIsEnabled, pumpTask == nil else { return }
        source.start()
        let stream = source.observeState()
        pumpTask = Task { @MainActor [weak self] in
            for await state in stream {
                if Task.isCancelled { break }
                self?.apply(state: state)
            }
        }
        Task { [weak self] in
            await self?.refresh()
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        // A stream that ended because this screen went away is not evidence about the mesh; the next
        // `apply` starts from the mirror's own current state instead of from a stale comparison.
        mirroredRelayIDs = []
        mirroredIncoming = []
        messages = []
    }

    /// Re-reads the two proofs a send is gated on, plus the mirror's current snapshot.
    public func refresh() async {
        guard meshIsEnabled else { return }
        await refreshPairingEvidence()
        apply(state: source.state)
    }

    /// The composer's send. Three gates, then one envelope — and either way the text stays on screen.
    /// This screen has no queue of its own, because module 5 owns the backlog, so losing what the user
    /// typed is the one thing a refusal must never do.
    public func sendDraft() async {
        guard meshIsEnabled else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let trimmed = String(text.prefix(Self.maxDraftCharacters))
        draft = ""

        await refreshPairingEvidence()
        let messageId = PopopxOutboundMessage.newMessageId()
        guard peerIsPaired else {
            // Refused here, on this screen, before the mesh is asked — nothing reached a radio, so
            // nothing may be badged as though it had.
            let refusal = PopopxMeshPrivateChatRefusal.peerNotPaired(pairingState)
            refusalsByID[messageId] = refusal
            lastRefusal = refusal
            recordOwn(text: trimmed, messageId: messageId)
            rebuild()
            PopopxMeshLog.route.warning(
                "🚫 private chat refused, not paired with \(PopopxMeshPrivateChatModel.peerLabel(self.peerMeshPublicKeyHex), privacy: .public)"
            )
            return
        }

        lastRefusal = nil
        isSending = true
        defer { isSending = false }
        do {
            try await outbound.send(
                envelope: .text(id: messageId, body: trimmed),
                to: peerMeshPublicKeyHex
            )
            handedOffIDs.insert(messageId)
        } catch {
            refusalsByID[messageId] = .transport(error.failure)
            lastRefusal = .transport(error.failure)
            PopopxMeshLog.route.warning(
                "📡 private chat send refused: \(String(describing: error.failure), privacy: .public)"
            )
        }
        recordOwn(text: trimmed, messageId: messageId)
        rebuild()
    }

    /// Saves the local name to the mesh sandbox and re-applies it, so a peer sees it too. The name is
    /// the value the plaza edits as well — one local display name for this device's offline surfaces.
    public func saveNickname() async {
        guard meshIsEnabled else { return }
        let clamped = PopopxMeshNicknameStore.clamped(nickname)
            ?? PopopxMeshNicknameStore.defaultNickname
        nickname = clamped
        try? nicknameStore.write(clamped)
        await nicknameApplier?.applyNickname(clamped)
    }

    /// Drops an unsaved edit by reading the sandbox back — the round trip a test asserts, and the
    /// Revert button's whole job.
    public func reloadNickname() {
        nickname = nicknameStore.read() ?? PopopxMeshNicknameStore.defaultNickname
    }

    /// Feed this screen the peer's messages from outside the mirror — a host that already holds module 5's
    /// offline records for this key pushes them here. The merge collapses them with what the mirror
    /// reports on the global `messageId`, so a host-fed copy and a mesh-fed copy become one row.
    public func replaceIncomingMessages(_ messages: [PopopxMeshTimelineMessage]) {
        guard meshIsEnabled else { return }
        pushedIncoming = messages.filter { isFromPeer($0) }
        rebuild()
    }

    /// Feed this screen the node table it is describing, for a host that reads module 4 rather than the
    /// mirror. The mirror wins whenever it holds the peer, so this cannot become a second source.
    public func replacePeer(_ peer: PopopxMeshPrivateChatPeer?) {
        guard meshIsEnabled else { return }
        self.peer = peer
        rebuild()
    }

    // MARK: - Reduction

    private func apply(state: PopopxMeshStreamState) {
        guard pumpTask != nil else { return }
        noteAcknowledgements(in: state.awaitingRelayMessageIDs)
        mirroredRelayIDs = state.awaitingRelayMessageIDs
        radioState = state.radioState
        mirroredIncoming = state.privateMessages.filter { isFromPeer($0) }
        if let mirrored = state.peer(withHex: peerMeshPublicKeyHex) {
            peer = PopopxMeshPrivateChatPeer(mirrored: mirrored)
        }
        rebuild()
    }

    /// The only thing that removes an id from the mirror's owed-relay set is a `BLE_ACK:` naming it
    /// (`PopopxMeshStateSource.ingest`), so an id this screen handed over that has left the set was
    /// acknowledged. Anything else stays "no BLE_ACK recorded", which is the honest label rather than
    /// a "delivered" one: module 4's ack guard runs inside the core and never reaches module 7's state, so
    /// a send the mesh accepted without complaint has no evidence this layer is allowed to read as
    /// delivered. Saying "on the mesh — no BLE_ACK recorded yet" for it is the ceiling of what an
    /// offline screen can promise, and promising more would be the bug.
    private func noteAcknowledgements(in next: Set<String>) {
        let gone = mirroredRelayIDs.subtracting(next)
        guard !gone.isEmpty else { return }
        for messageId in gone where handedOffIDs.contains(messageId) {
            acknowledgedIDs.insert(messageId)
        }
    }

    private func recordOwn(text: String, messageId: String) {
        let record = PopopxMeshTimelineMessage.offline(
            messageID: messageId,
            timestamp: .now,
            text: text,
            hopCount: 0,
            direction: .outgoing,
            senderNickname: nickname
        )
        ownRecords.append(record)
        if ownRecords.count > PopopxMeshStateSource.defaultCapacity {
            ownRecords.removeFirst(ownRecords.count - PopopxMeshStateSource.defaultCapacity)
        }
    }

    /// The merge, the badge and the delivery line all come from here, so ordering and dedup stay
    /// Module 7's existing rules rather than a second copy of them. Also the fuse's second gate: off,
    /// this screen holds no conversation.
    private func rebuild() {
        guard meshIsEnabled else {
            if !messages.isEmpty { messages = [] }
            return
        }
        let scoped = ownRecords + mirroredIncoming + pushedIncoming
        let merged = PopopxMeshTimelineMerger.merge(
            application: [],
            offline: scoped,
            awaitingRelayMessageIDs: mirroredRelayIDs
        )
        messages = merged.rows.map { row in
            PopopxMeshPrivateChatMessage(row: row, delivery: delivery(for: row))
        }
    }

    private func delivery(for row: PopopxMeshTimelineRow) -> PopopxMeshPrivateChatDelivery {
        Self.delivery(for: row, refusals: refusalsByID, acknowledgedIDs: acknowledgedIDs)
    }

    /// The delivery line as a pure function of the facts this screen collected. Pure so the rule that
    /// promotes a row to `delivered` can be checked at all: the only event that clears an owed relay is
    /// an inbound `BLE_ACK`, and `PopopxMeshInbound`'s initialiser is the core's, so no test of this
    /// target can put one on the mirror.
    static func delivery(
        for row: PopopxMeshTimelineRow,
        refusals: [String: PopopxMeshPrivateChatRefusal],
        acknowledgedIDs: Set<String>
    ) -> PopopxMeshPrivateChatDelivery {
        if let refusal = refusals[row.messageID] { return .refused(refusal) }
        guard row.direction == .outgoing else { return .received }
        if row.channel == .awaitingRelay { return .awaitingRelay }
        return acknowledgedIDs.contains(row.messageID) ? .acknowledged : .handedToMesh
    }

    /// Whichever spelling of this peer's wire id this device holds: the mirror's, a host's, or the
    /// deterministic one — `PopopxMeshPeerID` is the first 8 bytes of SHA256(pubkey), so a key alone
    /// answers it and a conversation needs no node table to know whose messages to show.
    private func isFromPeer(_ message: PopopxMeshTimelineMessage) -> Bool {
        guard let sender = message.senderPeerIDHex else { return false }
        return wireIDCandidates.contains(sender)
    }

    private var wireIDCandidates: Set<String> {
        var candidates: Set<String> = []
        if let peer { candidates.insert(peer.peerIDHex) }
        if let mirrored = source.state.peer(withHex: peerMeshPublicKeyHex) {
            candidates.insert(mirrored.peerID.hex)
        }
        if let derived = Self.wireIDHex(ofMeshPublicKeyHex: peerMeshPublicKeyHex) {
            candidates.insert(derived)
        }
        return candidates
    }

    /// Both proofs, re-read together. Cheap enough to run before every send, which is the only moment
    /// a stale answer could change what leaves the device.
    private func refreshPairingEvidence() async {
        if let pairing {
            pairingState = await pairing.state(for: peerMeshPublicKeyHex)
        }
        if let bindings {
            let rows = await bindings.allMappings()
            binding = rows.first { $0.meshPublicKeyHex == peerMeshPublicKeyHex }
                .map { PopopxMeshBindingSummary($0) }
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    // MARK: - Copy

    /// A 64-character key is not a title. The same abbreviation module 3's logs and the pairing banner
    /// use, so a peer is spelled alike wherever it appears.
    public static func peerLabel(_ meshPublicKeyHex: String) -> String {
        PopopxMeshBannerModel.shorten(meshPublicKeyHex)
    }

    // MARK: - Derivation

    /// The peer's 8-byte wire id, derived from the key this screen was handed — the id module 2 puts in
    /// front of every frame, and the only thing an inbound record carries to say who sent it.
    public static func wireIDHex(ofMeshPublicKeyHex hex: String) -> String? {
        guard let bytes = meshPublicKeyBytes(ofMeshPublicKeyHex: hex) else { return nil }
        return PopopxMeshPeerID(publicKey: bytes).hex
    }

    /// 64 hex digits to 32 bytes, or nil. A short or unhexic key is nothing to route to, and nothing
    /// downstream is allowed to guess at what one meant.
    ///
    /// The shape check is this function's contribution; the decoding is the core's, so the two directions
    /// of one key cannot disagree. `Data(popopxHex:)` accepts any even-length string it can parse, and a
    /// mesh key is exactly 64 digits, so `"0000"` must not reach `PopopxMeshPeerID` as if it were one.
    static func meshPublicKeyBytes(ofMeshPublicKeyHex hex: String) -> Data? {
        guard PopopxMeshControlFrame.isMeshPublicKey(hex) else { return nil }
        return Data(popopxHex: hex)
    }

    static func words(for state: MeshPairingState) -> String {
        switch state {
        case .unlinked: return "not paired with this device"
        case .requestSent: return "pairing asked — waiting for them to accept"
        case .requestReceived: return "they asked to pair — nothing sent yet"
        case .paired: return "paired over Bluetooth"
        }
    }

    static func words(for delivery: PopopxMeshPrivateChatDelivery) -> String {
        switch delivery {
        case .received: return ""
        case .handedToMesh: return "on the mesh — no BLE_ACK recorded yet"
        case .awaitingRelay: return "waiting for a relay"
        case .acknowledged: return "delivered"
        case let .refused(refusal): return words(for: refusal)
        }
    }

    static func words(for refusal: PopopxMeshPrivateChatRefusal) -> String {
        switch refusal {
        case let .peerNotPaired(state):
            return "\(PopopxMessageRouter.unboundStrangerStatusText) (pairing: \(words(for: state)))"
        case let .transport(failure):
            return MeshPlazaView.words(for: failure)
        }
    }

    /// "seen 40 s ago", at the granularity a conversation header has.
    static func words(since date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds) s ago"
        case ..<3_600: return "\(seconds / 60) min ago"
        default: return "\(seconds / 3_600) h ago"
        }
    }

    static func copy(
        for reason: PopopxMeshPrivateChatEmptyReason,
        peerName: String
    ) -> PopopxMeshPrivateChatEmptyState {
        switch reason {
        case .notPaired:
            return PopopxMeshPrivateChatEmptyState(
                title: "No conversation yet",
                detail: PopopxMessageRouter.unboundStrangerStatusText
            )
        case let .radioUnavailable(state):
            return PopopxMeshPrivateChatEmptyState(
                title: PopopxMeshBannerModel.radioTitle(state),
                detail: "Offline mesh is paused until Bluetooth is available. Nothing typed here leaves the device."
            )
        case let .peerOutOfRange(hops, lastSeenAt):
            return PopopxMeshPrivateChatEmptyState(
                title: "Not in Bluetooth range",
                detail: peerName
                    + " was \(PopopxMeshReachEstimate.description(hops: hops)) away when it was last seen "
                    + "\(words(since: lastSeenAt)). This screen stays offline: nothing is queued here, and "
                    + "nothing is sent over the public network from here."
            )
        case .peerNeverHeard:
            return PopopxMeshPrivateChatEmptyState(
                title: "Paired, but not heard from yet",
                detail: "This device is bound to \(peerName) and has received no packet from it since Bluetooth came up. Move closer to start the conversation."
            )
        case .nothingSaidYet:
            return PopopxMeshPrivateChatEmptyState(
                title: "Nothing said yet",
                detail: "In range over Bluetooth. What is typed here is encrypted to this peer's key and flooded only inside the mesh."
            )
        }
    }
}

/// The screen is a fuse component too: a host that registers it gets an immediate tear-down when
/// The master switch goes off, rather than a pump that only notices on the next packet.
extension PopopxMeshPrivateChatModel: PopopxMeshSwitchable {
    public func meshSwitchDidTurnOn(nickname: String?) async {
        // The name is read from the sandbox rather than taken from the fuse's copy, so this screen has
        // one writer of it: `PopopxMeshNicknameStore`, which is also the one a panic wipe erases.
        start()
        await refresh()
    }

    public func meshSwitchDidTurnOff() async {
        stop()
        lastRefusal = nil
    }
}

// MARK: - View

/// Standalone offline private-chat screen — one paired neighbour, one conversation, Bluetooth only.
@MainActor
public struct PopopxMeshPrivateChatView: View {
    @ObservedObject private var model: PopopxMeshPrivateChatModel

    public init(model: PopopxMeshPrivateChatModel) {
        self.model = model
    }

    /// The one-line mount for the settings page's row: the real engine as the send path, the real
    /// mirror, the real store as the durable pairing proof, and the real fuse. module 3 has no
    /// singleton, so a host that has a pairing manager hands its model one directly.
    public init(
        peerMeshPublicKeyHex: String,
        outbound: any PopopxMeshOutbound = PopopxMeshEngine.shared,
        source: PopopxMeshStateSource = .shared,
        store: IdentityMappingStore = .shared,
        killSwitch: PopopxMeshKillSwitch = .shared
    ) {
        self.init(
            model: PopopxMeshPrivateChatModel(
                peerMeshPublicKeyHex: peerMeshPublicKeyHex,
                outbound: outbound,
                source: source,
                bindings: store,
                killSwitch: killSwitch
            )
        )
    }

    public var body: some View {
        // Red line 28, stated once: with the switch off there is nothing to show, not a greyed-out version
        // of it. `onAppear` sits in the other branch, so an off fuse also never starts a pump, never
        // subscribes to the mirror and never reads the node table.
        if model.meshIsEnabled {
            conversation
        } else {
            EmptyView()
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            header
            Divider()
            timeline
            Divider()
            composer
        }
        .navigationTitle(model.peerDisplayName)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: model.peerIsInRange
                        ? "antenna.radiowaves.left.and.right"
                        : "wifi.slash")
                    .foregroundStyle(model.peerIsInRange ? .orange : .gray)
                Text(verbatim: model.pairingStateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let reach = model.peerReachDescription {
                    Text(verbatim: reach)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if !model.radioState.isUsable {
                Text(verbatim: PopopxMeshBannerModel.radioTitle(model.radioState))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var timeline: some View {
        List {
            Section {
                if let empty = model.emptyState {
                    emptyState(empty)
                } else {
                    ForEach(model.messages) { message in
                        bubble(message)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Offline private chat")
                    Spacer()
                    Text(verbatim: "\(model.messages.count) message(s)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func emptyState(_ state: PopopxMeshPrivateChatEmptyState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(state.title))
            Text(verbatim: state.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func bubble(_ message: PopopxMeshPrivateChatMessage) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(
                alignment: message.direction == .outgoing ? .trailing : .leading,
                spacing: 3
            ) {
                Text(verbatim: message.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if message.showsChannelBadge {
                        PopopxMeshChannelBadge(channel: message.channel)
                    }
                    if message.direction == .incoming, let nickname = message.senderNickname,
                       !nickname.isEmpty {
                        Text(verbatim: nickname)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: PopopxMeshPrivateChatModel.words(for: message.delivery))
                        .font(.caption2)
                        .foregroundStyle(message.deliveryIsFailure ? .orange : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.direction == .outgoing ? .trailing : .leading)
            Spacer(minLength: 8)
            Text(verbatim: MeshPlazaView.clock(message.timestamp))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.text.rectangle")
                    .foregroundStyle(.secondary)
                TextField("Local nickname", text: $model.nickname)
                    .textFieldStyle(.plain)
                Button("Save") {
                    Task { await model.saveNickname() }
                }
                Button("Revert") {
                    model.reloadNickname()
                }
                .foregroundStyle(.secondary)
            }
            if let refusal = model.lastRefusal {
                Text(verbatim: PopopxMeshPrivateChatModel.words(for: refusal))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField("Message over Bluetooth only", text: $model.draft)
                Button {
                    Task { await model.sendDraft() }
                } label: {
                    if model.isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(!model.canSend)
                .accessibilityLabel(Text("Send over the offline mesh"))
            }
        }
        .padding(12)
    }
}
