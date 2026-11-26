//
//  PopopxMessageRouter.swift
//  PopopxMeshKit  —  module 5
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Seamless all-direction switching and SMP re-routing hub. One entry point for "send this text to this peer" that always picks
//  the channel that can carry it right now, and one exit for the two ways a channel can disappoint:
//  the public network does not answer inside `PopopxMeshConfig.smpAckTimeout` (3 s), or Bluetooth
//  reports `onBluetoothDeliveryFailed` after `bleAckTimeout` (5 s) without a BLE_ACK.
//
//  Scenario A (online → offline / weak-network downgrade): SMP is the default while `NetworkStateMonitor` says the path is
//  up. When the window runs out and the peer is reachable on the mesh, the same message goes out on
//  the mesh too — concurrently, never instead, because cancelling a live SMP send to go look at a
//  radio would lose a message that was already leaving the device.
//
//  Scenario B (Bluetooth → SMP): the same rules read the other way. Pre-send prediction skips Bluetooth when the peer left
//  range (`peerReachabilityTimeout`, 15 s) or the radio is off while this device is online and bound;
//  In-flight re-routing turns a delivery failure into an SMP re-send that keeps the original `messageId`;
//  and the pure-offline fallback parks what neither channel could take in `unacknowledgedMeshMessages` until
//  `flushPendingMessagesOnNetworkRestore()` runs on the restore edge.
//
//  Two invariants. `messageId` is minted once and never replaced — it is the only thing that makes a
//  parallel re-send and a re-route safe to look at twice, and the peer's single
//  `PopopxMeshDeduplicator` entry is what collapses both copies into one message. And nothing here
//  reaches the network on its own: the public channel goes through module 2's seam
//  (`PopopxSMPChatCore` refines `PopopxOfflineChatCore`), so the app target keeps the FFI and this
//  package keeps the rules.
//

import Foundation

// MARK: - The public door

/// One text message handed to the POPOPX SMP server. `messageId` is the global id the router minted
/// (or kept from the Bluetooth attempt that failed): the adapter must carry it verbatim into the
/// message it sends, so the peer sees one id across both channels.
public struct PopopxSMPSendRequest: Hashable, Sendable {
    public let messageId: String
    public let contactId: Int64
    public let text: String
    public let sentAt: Date

    public init(messageId: String, contactId: Int64, text: String, sentAt: Date = .now) {
        self.messageId = messageId
        self.contactId = contactId
        self.text = text
        self.sentAt = sentAt
    }
}

/// The SMP server took the message. Returning it is the only positive answer the router accepts: the
/// 3-second rule is a rule about *this*, not about the FFI call coming back.
public struct PopopxSMPAck: Hashable, Sendable {
    public let messageId: String
    public let contactId: Int64
    public let acknowledgedAt: Date
    /// The row the host's own chat database now holds for this message, if the host can name it.
    ///
    /// One offline message and the SMP copy that replaced it are the same text under two unrelated
    /// ids: the mesh `messageId` this router minted, and the main database's `ChatItem` id. Without
    /// the second one the merged timeline cannot tell that the row it is about to add is already
    /// drawn, and the user sees the bubble twice after a restore. A host that leaves it nil gets the
    /// old behaviour, which is correct for a message the app never stored.
    public let appChatItemId: Int64?

    public init(
        messageId: String,
        contactId: Int64,
        acknowledgedAt: Date = .now,
        appChatItemId: Int64? = nil
    ) {
        self.messageId = messageId
        self.contactId = contactId
        self.acknowledgedAt = acknowledgedAt
        self.appChatItemId = appChatItemId
    }
}

/// What module 5 needs on top of module 2's seam, so the router's public channel is the *same* door the
/// offline pairing already uses rather than a second one the host has to wire twice.
///
/// The app's adapter implements this with the send path that already exists —
/// `apiSendMessages(type:id:scope:sendAsGroup:live:ttl:sign:composedMessages:)`
/// (`Shared/Model/POPOPXAPI.swift:577`) over `sendPOPOPXCmd` (`POPOPXChat/API.swift:121`) — and must not
/// block on anything the mesh owns: throwing is reported as "no ACK", which is what routes the
/// message elsewhere.
public protocol PopopxSMPChatCore: PopopxOfflineChatCore {
    /// Waits until the SMP server has taken the message. Throwing means no ACK, and the router then
    /// falls back to the mesh or to `unacknowledgedMeshMessages`; it never retries on its own, because
    /// the chat core owns SMP's own retry queue.
    func sendTextOverSMP(_ request: PopopxSMPSendRequest) async throws -> PopopxSMPAck
}

// MARK: - Addresses

/// Who a message is for, in whichever id space the caller holds. The three spellings are the three
/// moments of a pairing: a mesh key alone (a neighbour no card was exchanged with), a temporary
/// `connId` (an offline `/_connect` that is not a contact yet), and a real `contactId` (the SMP
/// address). Module 6 turns the second into the third.
public enum PopopxRouteTarget: Hashable, Sendable, Codable {
    case contactId(Int64)
    case tempConnId(Int64)
    case meshPublicKeyHex(String)

    /// The SMP address, when there is one. Only a real contact can be reached over the public network
    /// — a pending connection has no server-side queue to write to yet.
    public var contactId: Int64? {
        if case let .contactId(id) = self { id } else { nil }
    }

    public var tempConnId: Int64? {
        if case let .tempConnId(id) = self { id } else { nil }
    }

    public var meshPublicKeyHex: String? {
        if case let .meshPublicKeyHex(hex) = self { hex } else { nil }
    }
}

/// A message the caller asked the router to deliver.
public struct PopopxOutboundMessage: Hashable, Sendable {
    public let messageId: String
    public let target: PopopxRouteTarget
    public let text: String
    public let sentAt: Date

    public init(messageId: String, target: PopopxRouteTarget, text: String, sentAt: Date = .now) {
        self.messageId = messageId
        self.target = target
        self.text = text
        self.sentAt = sentAt
    }

    /// The id every channel and every retry of this message keeps, spelled the way
    /// `PopopxMeshEngine` spells a control frame's id: a lower-case UUID string.
    public static func newMessageId() -> String {
        UUID().uuidString.lowercased()
    }
}

/// Why a message is sitting in `unacknowledgedMeshMessages`.
public enum PopopxQueueReason: String, Codable, Hashable, Sendable {
    /// Pure-offline fallback: no path, and nothing on the radio to take it either.
    case noNetwork
    /// The bound peer has not been heard of inside `peerReachabilityTimeout`, or our radio is off.
    case peerUnreachable
    /// SMP was chosen, no ACK came, and there was no mesh to add the copy to.
    case smpUnacknowledged
    /// The mesh refused the frame before it reached the radio.
    case meshRefused
    /// Still addressed to a temporary `connId`; flushable once module 6 upgrades that connection.
    case awaitingContactUpgrade
}

/// One entry of `unacknowledgedMeshMessages`. `messageId` is kept so a flush re-sends the very same
/// message rather than a new one: the peer's dedup is the only thing standing between a restore and a
/// duplicated conversation.
public struct PopopxPendingMeshMessage: Codable, Hashable, Sendable, Identifiable {
    public let messageId: String
    public let target: PopopxRouteTarget
    public let text: String
    public let peerMeshPublicKeyHex: String?
    public let queuedAt: Date
    public let reason: PopopxQueueReason

    public var id: String { messageId }

    public init(
        messageId: String,
        target: PopopxRouteTarget,
        text: String,
        peerMeshPublicKeyHex: String?,
        queuedAt: Date = .now,
        reason: PopopxQueueReason
    ) {
        self.messageId = messageId
        self.target = target
        self.text = text
        self.peerMeshPublicKeyHex = peerMeshPublicKeyHex
        self.queuedAt = queuedAt
        self.reason = reason
    }

    /// The same entry under a new address or reason — the id, the text and `queuedAt` never move.
    func relocated(to target: PopopxRouteTarget, reason: PopopxQueueReason? = nil) -> PopopxPendingMeshMessage {
        PopopxPendingMeshMessage(
            messageId: messageId,
            target: target,
            text: text,
            peerMeshPublicKeyHex: peerMeshPublicKeyHex,
            queuedAt: queuedAt,
            reason: reason ?? self.reason
        )
    }
}

/// The pre-send prediction's answer, kept in the decision so the UI can say *why* a channel was not used and a test
/// can assert the prediction instead of a timing accident.
public enum PopopxBluetoothPrediction: Hashable, Sendable {
    case reachable(peerMeshPublicKeyHex: String)
    /// The peer was bound and heard of, but has been silent longer than the reachability window.
    case peerOutOfRange(peerMeshPublicKeyHex: String)
    /// Our own radio is off, resetting or unauthorized.
    case radioUnavailable(PopopxBluetoothState)
    /// Nothing bound on the mesh side at all — a stranger, or a card that was never exchanged.
    case notBound

    /// The peer the prediction is about, whichever arm answered it.
    public var peerKey: String? {
        switch self {
        case let .reachable(hex), let .peerOutOfRange(hex): hex
        case .radioUnavailable, .notBound: nil
        }
    }
}

/// What the router actually did with one message.
public enum PopopxRouteOutcome: Hashable, Sendable {
    /// Scenario A, the normal case: the SMP server took the message inside the window.
    case smpAcknowledged(contactId: Int64)
    /// Scenario A rule 1's tail: no SMP ACK inside `smpAckTimeout` and the peer is reachable, so the same
    /// `messageId` went out on the mesh as well, concurrently.
    case smpUnacknowledgedMeshParallel(contactId: Int64, peerMeshPublicKeyHex: String)
    /// No SMP ACK and no second channel to add. The attempt stays in flight; its later failure queues
    /// the message.
    case smpUnacknowledgedNoMesh(contactId: Int64)
    /// Bluetooth carried it, because there is no path (offline downgrade) or because pre-send prediction chose it.
    case meshSent(peerMeshPublicKeyHex: String)
    /// Pure-offline fallback: the message is in `unacknowledgedMeshMessages`.
    case queuedOffline(PopopxQueueReason)
    /// Unbound stranger: no SMP address exists and nothing on the radio can take it, so nothing was sent.
    case refusedUnboundStranger(peerMeshPublicKeyHex: String?)
    /// This `messageId` is already being routed, or was already re-routed. The second request was
    /// ignored on purpose — that is what makes a retry idempotent.
    case duplicate(messageId: String)
    /// A failure callback named a message this router has no record of, so there is no text to
    /// re-send. Happens after a relaunch, whose in-flight attempts are gone.
    case nothingToReroute(messageId: String)
}

/// The whole answer for one send, including the prediction that shaped it.
public struct PopopxRoutedMessage: Hashable, Sendable {
    public let messageId: String
    public let target: PopopxRouteTarget
    public let outcome: PopopxRouteOutcome
    public let bluetooth: PopopxBluetoothPrediction?

    public init(
        messageId: String,
        target: PopopxRouteTarget,
        outcome: PopopxRouteOutcome,
        bluetooth: PopopxBluetoothPrediction? = nil
    ) {
        self.messageId = messageId
        self.target = target
        self.outcome = outcome
        self.bluetooth = bluetooth
    }
}

/// What one chat page's status bar should say right now. `unboundStranger` is the prompt's
/// Unbound-stranger notice and carries its wording verbatim in `displayText`.
public enum PopopxRoutingStatus: Hashable, Sendable {
    /// Public network is up; SMP is the default channel.
    case smpOnline
    /// Offline, Bluetooth up: the message goes over Mesh.
    case meshOnly(peerMeshPublicKeyHex: String?)
    /// Public network marginal (no ACK in 3 s), Mesh is re-sending concurrently.
    case dualChannel(peerMeshPublicKeyHex: String)
    /// Neither path works; the backlog message count.
    case queued(messageCount: Int)
    /// "Bluetooth has disconnected; no public card exchanged yet (move closer again to continue sending)"
    case unboundStranger
    /// `NWPathMonitor` has not reported yet — deliberately not guessed as "online".
    case pathUnknown

    /// A stable code for a view that switches instead of reading text, so a copy edit cannot break a
    /// binding.
    public var statusCode: String {
        switch self {
        case .smpOnline: "smpOnline"
        case .meshOnly: "meshOnly"
        case .dualChannel: "dualChannel"
        case .queued: "queued"
        case .unboundStranger: "unboundStranger"
        case .pathUnknown: "pathUnknown"
        }
    }

    /// nil for the statuses that need no banner, so an overlay can bind to this directly.
    public var displayText: String? {
        switch self {
        case .smpOnline:
            nil
        case .meshOnly:
            NSLocalizedString("The public network is unavailable — messages go over Bluetooth mesh", comment: "")
        case let .dualChannel(peer):
            String(format: NSLocalizedString("The public network is slow — also sending over Bluetooth mesh (%@)", comment: ""), String(peer.prefix(8)))
        case let .queued(count):
            String(format: NSLocalizedString("Neither Bluetooth nor the public network is available — %lld messages waiting to send", comment: ""), count)
        case .unboundStranger:
            PopopxMessageRouter.unboundStrangerStatusText
        case .pathUnknown:
            NSLocalizedString("Checking the public network status", comment: "")
        }
    }
}

/// How many things moved when module 6 upgraded a temporary connection.
public struct PopopxMigrationReport: Hashable, Sendable {
    public let movedQueuedMessages: Int
    public let movedOfflineRecords: Int

    public init(movedQueuedMessages: Int = 0, movedOfflineRecords: Int = 0) {
        self.movedQueuedMessages = movedQueuedMessages
        self.movedOfflineRecords = movedOfflineRecords
    }

    public var isEmpty: Bool { movedQueuedMessages == 0 && movedOfflineRecords == 0 }
}

/// One offline Bluetooth message the mesh delivered for a recipient that was still a pending
/// connection. `PopopxEventObserver` moves these to the real `contactId` when the upgrade lands.
///
/// The `messageId` here is an address, not a memory: the only thing that decides whether an id has
/// been seen before is `PopopxMeshDeduplicator`, which this router asks through `shouldDeliver`.
public struct PopopxMeshOfflineRecord: Codable, Hashable, Sendable, Identifiable {
    public let messageId: String
    public let target: PopopxRouteTarget
    public let peerMeshPublicKeyHex: String?
    public let text: String
    public let receivedAt: Date

    public var id: String { messageId }

    public init(
        messageId: String,
        target: PopopxRouteTarget,
        peerMeshPublicKeyHex: String?,
        text: String,
        receivedAt: Date = .now
    ) {
        self.messageId = messageId
        self.target = target
        self.peerMeshPublicKeyHex = peerMeshPublicKeyHex
        self.text = text
        self.receivedAt = receivedAt
    }

    func relocated(to target: PopopxRouteTarget) -> PopopxMeshOfflineRecord {
        PopopxMeshOfflineRecord(
            messageId: messageId,
            target: target,
            peerMeshPublicKeyHex: peerMeshPublicKeyHex,
            text: text,
            receivedAt: receivedAt
        )
    }
}

// MARK: - The Bluetooth seam this router reads

/// What module 5 needs from module 4: the pre-send prediction question, the radio state it is answered against, and the
/// failure sink in-flight re-routing installs itself into.
///
/// `BluetoothHealthMonitor` is the only production answer — see `PopopxBluetoothHealthJudge` — and the
/// protocol exists because the monitor's own state is written by CoreBluetooth callbacks and mesh
/// events that a unit test cannot raise. The router's routing rules are the thing under test here, so
/// the radio facts come in through a seam a fixture can hold, exactly like
/// `PopopxPathProviding` does for connectivity.
public protocol PopopxBluetoothJudging: Sendable {
    /// Our own radio, as module 4 sees it. `isUsable` false is the prompt's "Bluetooth off" case.
    var radioState: PopopxBluetoothState { get async }

    /// Whether the peer is still in Bluetooth range: heard from within `timeout`, which the router always takes from
    /// `PopopxMeshConfig.peerReachabilityTimeout` (15 s).
    func isPeerReachable(publicKey meshPublicKeyHex: String, timeout: TimeInterval) async -> Bool

    /// Installs the re-routing sink, or retracts it. `nil` must mean "no callback", the same contract
    /// module 4 documents.
    func setDeliveryFailureHandler(
        _ handler: (@Sendable (PopopxBluetoothDeliveryFailure) async -> Void)?
    ) async
}

/// The production judge: module 4's `BluetoothHealthMonitor`, reached through the three calls that
/// already exist on it. Nothing here adds behaviour to the monitor — the module stays the only owner
/// of radio state, node sightings and the 5-second BLE_ACK guard.
public struct PopopxBluetoothHealthJudge: PopopxBluetoothJudging {
    private let monitor: BluetoothHealthMonitor

    public init(monitor: BluetoothHealthMonitor = .shared) {
        self.monitor = monitor
    }

    public var radioState: PopopxBluetoothState {
        get async { await monitor.currentRadioState }
    }

    public func isPeerReachable(publicKey meshPublicKeyHex: String, timeout: TimeInterval) async -> Bool {
        // The monitor's own answer, synchronously inside its actor; `peerReachabilityTimeout` is the
        // default it uses for the same question, so the two cannot drift apart.
        await monitor.isPeerReachable(publicKey: meshPublicKeyHex, timeout: timeout)
    }

    public func setDeliveryFailureHandler(
        _ handler: (@Sendable (PopopxBluetoothDeliveryFailure) async -> Void)?
    ) async {
        await monitor.setDeliveryFailureHandler(handler)
    }
}

// MARK: - The router

public actor PopopxMessageRouter {
    // No `shared`, like module 3: this type needs the app's chat core, which only the host target can
    // supply. The host builds one router, hands it to the send path and to module 6, and starts it with
    // the global fuse.

    /// Unbound-stranger notice, exactly as module 5 writes it. Reachable from `PopopxRoutingStatus
    /// .unboundStranger.displayText`, from the status stream and from the notification's `userInfo`,
    /// so no chat page has to rebuild the sentence.
    public static let unboundStrangerStatusText = NSLocalizedString("Bluetooth is down and no POPOPX public-network card has been exchanged yet — move closer to continue sending.", comment: "")

    /// Posted whenever the routing status changes — including the card-upgraded notification module 6
    /// forwards. `userInfo` carries `statusCode`, and `statusText` only when there is something to
    /// show. No app-side `Notification.Name` carried this meaning before, so this package declares it.
    public static let statusNotification = Notification.Name("chat.popopx.mesh.routingStatus")

    public static let statusTextKey = "statusText"
    public static let statusCodeKey = "statusCode"

    /// The queue is a fuse box, not a mailbox: a device that never gets a network again must not grow
    /// an unbounded plaintext list of everything the user tried to send.
    public static let maxUnacknowledgedMessages = 256

    /// Live routing attempts, kept for the same bound. An attempt is dropped as soon as a channel is
    /// proven, so the cap only bites on a device that keeps failing.
    public static let maxTrackedAttempts = 512

    /// Offline messages remembered per recipient, for the module 6 migration. The "already delivered"
    /// question is answered by the deduplicator, not by this list.
    public static let maxOfflineRecords = 512

    /// Flushed mesh-id → `ChatItem` id pairs kept, oldest dropped first. It has to outlive the queue,
    /// because the pair is what tells the timeline that the offline row and the stored row are one
    /// message — but it may not grow with the whole chat history. Past this many, the oldest flushes
    /// forget their pairing, and an offline row that far back can be drawn next to its stored twin
    /// instead of being replaced by it.
    public static let maxTrackedFlushedAppItems = 1_024

    /// Everything the router knows about one peer's two identities: the SMP address if there is one,
    /// and the mesh key(s) that could carry the message instead.
    private struct Binding {
        let target: PopopxRouteTarget
        let contactId: Int64?
        let meshPublicKeyHexes: [String]

        func withContactId(_ contactId: Int64?) -> Binding {
            Binding(target: target, contactId: contactId, meshPublicKeyHexes: meshPublicKeyHexes)
        }
    }

    /// One message this router is still doing something about. Not a dedup ledger: it holds the text
    /// and which channels already took this id, so a retry can be refused and a re-send can be proven
    /// to have happened once.
    private struct Attempt {
        let messageId: String
        var target: PopopxRouteTarget
        let text: String
        let startedAt: Date
        var contactId: Int64?
        var peerMeshPublicKeyHex: String?
        var sentOverMesh = false
        var reroutedOverSMP = false
        var queued = false
        /// Mesh attempts already spent waiting on a `BLE_ACK` that never came. Private to this router
        /// and never persisted: a retry is a radio decision, and a queue file that survived a
        /// relaunch holding a retry count would promise a re-send nobody armed a deadline for.
        var bleRetries = 0
    }

    /// One flush that landed in the host's own database: the id this router minted, and the row id the
    /// host stored under.
    struct FlushedAppItem: Codable, Hashable {
        var messageId: String
        var appChatItemId: Int64
    }

    private struct StoredQueue: Codable {
        var schemaVersion: Int
        var messages: [PopopxPendingMeshMessage]
        /// Optional so a queue file written before the pairing existed still decodes: an absent key is
        /// "no pairs known", not a corrupt file.
        var flushedAppItems: [FlushedAppItem]?
    }

    private struct StoredRecords: Codable {
        var schemaVersion: Int
        var records: [PopopxMeshOfflineRecord]
    }

    private let core: any PopopxSMPChatCore
    private let outbound: any PopopxMeshOutbound
    private let network: any PopopxConnectivitySource
    private let health: any PopopxBluetoothJudging
    private let store: IdentityMappingStore
    private let deduplicator: PopopxMeshDeduplicator
    private let config: PopopxMeshConfig
    private let clock: PopopxRoutingClock

    /// nil keeps the queue in memory only. The host passes `PopopxMeshPaths.unacknowledgedQueueURL()`
    /// so an offline backlog survives a relaunch in `Documents/popopx_mesh/` — never in the chat
    /// database, per the brief's rule 5.
    private let queueURL: URL?
    private let recordsURL: URL?

    /// Pure-offline fallback queue, the prompt's `unacknowledgedMeshMessages`: what neither channel could take.
    public internal(set) var unacknowledgedMeshMessages: [String: PopopxPendingMeshMessage] = [:]

    private var attempts: [String: Attempt] = [:]
    private var deadlineTasks: [String: Task<Void, Never>] = [:]
    private var offlineRecords: [String: [PopopxMeshOfflineRecord]] = [:]
    private var smpWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var settledAcks: [String: Bool] = [:]
    private var lastStatusPath: PopopxNetworkPath?
    private var status: PopopxRoutingStatus = .pathUnknown
    private var statusSubscriptions: [UUID: AsyncStream<PopopxRoutingStatus>.Continuation] = [:]
    private var observationTask: Task<Void, Never>?
    private var inFlightFlush: Task<Int, Never>?

    /// Ruling 1: the mesh `messageId` → main-database `ChatItem` id pairs, for the messages this router
    /// flushed over SMP. The merged timeline needs them because the two ids name one message, and the
    /// offline row is the only copy that carries the mesh id.
    private var appChatItemIDs: [String: Int64] = [:]

    /// The same pairs oldest first, and the reason the cap can mean "drop the oldest": a dictionary's
    /// iteration order is not its insertion order, so `appChatItemIDs` alone cannot say which pairing
    /// is stale.
    private var flushedAppItems: [FlushedAppItem] = []

    public init(
        core: any PopopxSMPChatCore,
        outbound: any PopopxMeshOutbound = PopopxMeshEngine.shared,
        network: any PopopxConnectivitySource = NetworkStateMonitor.shared,
        health: any PopopxBluetoothJudging = PopopxBluetoothHealthJudge(),
        store: IdentityMappingStore = .shared,
        deduplicator: PopopxMeshDeduplicator = PopopxMeshDeduplicator(),
        config: PopopxMeshConfig = .default,
        clock: PopopxRoutingClock = .wall,
        queueURL: URL? = nil,
        recordsURL: URL? = nil
    ) {
        self.core = core
        self.outbound = outbound
        self.network = network
        self.health = health
        self.store = store
        self.deduplicator = deduplicator
        self.config = config
        self.clock = clock
        self.queueURL = queueURL
        self.recordsURL = recordsURL
    }

    // MARK: - Lifecycle

    /// Subscribes to connectivity (starting the shared `NetworkStateMonitor` if nothing else has),
    /// installs itself as module 4's delivery-failure sink, and takes back whatever the last run left on
    /// disk. Idempotent.
    public func start() async {
        loadQueueFromDisk()
        loadRecordsFromDisk()
        await installBluetoothFailureHandler()
        await network.start()
        guard observationTask == nil else { return }
        let stream = await network.pathChanges()
        observationTask = Task { [weak self] in
            for await path in stream {
                if Task.isCancelled { break }
                await self?.networkChanged(path)
            }
            // The stream ended by itself — `NetworkStateMonitor.stop()` finished it when the global
            // fuse went off. Forget the handle so a later `start()` can subscribe again; a cancelled
            // task must not clear the handle of a newer subscription.
            if !Task.isCancelled { await self?.clearObservationHandle() }
        }
        PopopxMeshLog.route.info(
            "▶️ router up, queued=\(self.unacknowledgedMeshMessages.count, privacy: .public)"
        )
    }

    /// Stops the pipeline and retracts every timer this router owns. It deliberately does **not**
    /// cancel SMP sends already handed to the chat core: killing a user's in-flight public send would
    /// break the zero-breakage red line, and the message is already on its way.
    public func stop() async {
        observationTask?.cancel()
        observationTask = nil
        lastStatusPath = nil
        cancelAllDeadlines()
        drainSMPWaiters()
        let live = statusSubscriptions.values
        for continuation in live { continuation.finish() }
        statusSubscriptions.removeAll()
        await health.setDeliveryFailureHandler(nil)
        PopopxMeshLog.route.info(
            "⏹ router down, queued=\(self.unacknowledgedMeshMessages.count, privacy: .public)"
        )
    }

    /// True while any connectivity subscription is live — the fuse's measurement.
    public var isObservingNetwork: Bool { observationTask != nil }

    /// How many ACK deadlines are still armed. Must be 0 after `stop()`: a router the app has torn
    /// down may not keep waking a timer, and a timer that keeps the router alive keeps the whole
    /// mesh graph alive with it.
    public var outstandingTimerCount: Int { deadlineTasks.count }

    /// How many status streams are live. Must be 0 after `stop()`: a banner view that went away
    /// cannot be the reason a router is still retained.
    public var statusSubscriptionCount: Int { statusSubscriptions.count }

    /// How many messages have a live routing attempt, i.e. what a duplicate id is measured against.
    public var trackedAttemptCount: Int { attempts.count }

    // MARK: - The one entry point

    /// Scenario A and scenario B in the order the prompt writes them: online means SMP; no SMP ACK in time
    /// means Bluetooth in parallel; Bluetooth being the only way means the mesh; neither means the
    /// queue — unless there is no public card behind the peer at all, which is the stranger refusal.
    @discardableResult
    public func send(_ message: PopopxOutboundMessage) async -> PopopxRoutedMessage {
        // Reserved before the first suspension, so a second call with the same id — the peer's retry,
        // or our own re-route racing it — cannot put one message on two more channels.
        guard attempts[message.messageId] == nil else {
            return PopopxRoutedMessage(
                messageId: message.messageId,
                target: message.target,
                outcome: .duplicate(messageId: message.messageId)
            )
        }
        let now = clock.date()
        trimAttemptsIfNeeded(now: now)
        attempts[message.messageId] = Attempt(
            messageId: message.messageId,
            target: message.target,
            text: message.text,
            startedAt: now,
            contactId: message.target.contactId
        )

        let binding = await resolveBinding(for: message.target)
        let prediction = await predictBluetooth(for: binding)

        if await isConnected(), let contactId = binding.contactId {
            // Scenario A rule 1: when online, default to POPOPX SMP.
            return await routeOverSMP(
                messageId: message.messageId,
                contactId: contactId,
                text: message.text,
                binding: binding,
                prediction: prediction,
                // Only after 3 s without an ACK is a concurrent Bluetooth re-send allowed.
                allowParallelMesh: true
            )
        }
        // Offline, or no SMP address to write to: the mesh is the only candidate (offline downgrade).
        if case let .reachable(peerMeshPublicKeyHex) = prediction,
           let outcome = await sendOverMesh(
                messageId: message.messageId,
                text: message.text,
                peerMeshPublicKeyHex: peerMeshPublicKeyHex
           ) {
            publishStatus(for: outcome)
            return PopopxRoutedMessage(
                messageId: message.messageId,
                target: message.target,
                outcome: outcome,
                bluetooth: prediction
            )
        }
        return await parkOrRefuse(messageId: message.messageId, binding: binding, prediction: prediction)
    }

    /// Convenience for the app's own send sites, which hold a `contactId` and no id at all.
    @discardableResult
    public func sendText(_ text: String, toContactId contactId: Int64) async -> PopopxRoutedMessage {
        await send(
            PopopxOutboundMessage(
                messageId: PopopxOutboundMessage.newMessageId(),
                target: .contactId(contactId),
                text: text
            )
        )
    }

    // MARK: - Scenario B in-flight: the delivery-failure callback

    /// Module 4's `onBluetoothDeliveryFailed(messageId:peerMeshKey:)`.
    ///
    /// The network is checked the moment this is called: online and bound means the very same
    /// `messageId` goes out over SMP — it is never replaced, because a new id would show the message
    /// twice. Offline means `unacknowledgedMeshMessages`. An id this router never journaled means
    /// nothing to re-send.
    @discardableResult
    public func onBluetoothDeliveryFailed(messageId: String, peerMeshKey: String?) async -> PopopxRouteOutcome {
        guard var attempt = attempts[messageId] else {
            PopopxMeshLog.route.warning(
                "🤷 delivery failure for an id this router never journaled=\(messageId.prefix(8), privacy: .public)"
            )
            return .nothingToReroute(messageId: messageId)
        }
        guard !attempt.reroutedOverSMP else {
            // The second failure of the same id, from a relay that re-flooded the frame: the SMP copy
            // is already on its way.
            PopopxMeshLog.route.info(
                "⏭ second failure for id=\(messageId.prefix(8), privacy: .public) — SMP re-send already issued"
            )
            return .duplicate(messageId: messageId)
        }
        if attempt.peerMeshPublicKeyHex == nil { attempt.peerMeshPublicKeyHex = peerMeshKey }
        attempts[messageId] = attempt

        // Module 4's deadline says the peer did not answer. It does not say the frame was never
        // sent, and it cannot: handing a frame to CoreBluetooth is not delivering it. So before this
        // id is handed to SMP — which needs a network, a bound contact, and a second copy of a
        // message the mesh may still be carrying — the same envelope goes back on the radio, up to
        // `meshDeliveryRetries` times. The id is never replaced, for the reason the SMP path below
        // already gives: a new id would show the message twice.
        //
        // Two conditions make a retry worth starting. Our own radio has to be up: module 4 reports
        // `.radioUnavailable` when it is not, and a retry into a dead radio spends budget and cannot
        // land. And the peer has to still be on the mesh list, because the commonest reason a frame
        // never gets an ACK is a link that was still negotiating when it was attempted — which is a
        // link that exists a few seconds later, provided the neighbour is still being heard of.
        if attempt.bleRetries < config.meshDeliveryRetries,
           let peerKey = attempt.peerMeshPublicKeyHex,
           await health.radioState.isUsable,
           await health.isPeerReachable(publicKey: peerKey, timeout: config.peerReachabilityTimeout) {
            attempt.bleRetries += 1
            attempts[messageId] = attempt
            if let outcome = await sendOverMesh(
                messageId: messageId,
                text: attempt.text,
                peerMeshPublicKeyHex: peerKey
            ) {
                let spent = attempt.bleRetries
                let ceiling = config.meshDeliveryRetries
                PopopxMeshLog.route.notice(
                    "🔁 mesh retry \(spent, privacy: .public)/\(ceiling, privacy: .public) id=\(messageId.prefix(8), privacy: .public)"
                )
                publishStatus(for: outcome)
                return outcome
            }
            // The radio refused the frame outright rather than losing it: no ACK deadline was armed,
            // so waiting another five seconds for one would be waiting for nothing. Fall through with
            // the attempt spent.
        }

        let binding = await resolveBinding(for: attempt.target)
        var contactId = binding.contactId
        if contactId == nil, let peerMeshPublicKeyHex = peerMeshKey {
            // The failure callback only knows the mesh key; module 1 turns it into the SMP address.
            contactId = await store.contactId(forMeshPublicKeyHex: peerMeshPublicKeyHex)
        }
        let online = await isConnected()

        guard online else {
            // Bluetooth unreachable and this device offline too → pending-send queue, with the id kept.
            let parked = await parkOrRefuse(
                messageId: messageId,
                binding: binding.withContactId(contactId),
                prediction: .radioUnavailable(await health.radioState)
            )
            return parked.outcome
        }
        guard let resolvedContactId = contactId else {
            // Unbound stranger: online, but no public card to re-send behind.
            let refused: PopopxRouteOutcome = .refusedUnboundStranger(peerMeshPublicKeyHex: attempt.peerMeshPublicKeyHex)
            publishStatus(for: refused)
            return refused
        }
        attempt.reroutedOverSMP = true
        attempts[messageId] = attempt
        unacknowledgedMeshMessages[messageId] = nil
        PopopxMeshLog.route.notice(
            "🔁 re-routing id=\(messageId.prefix(8), privacy: .public) over SMP, id kept"
        )
        return await routeOverSMP(
            messageId: messageId,
            contactId: resolvedContactId,
            text: attempt.text,
            binding: binding.withContactId(resolvedContactId),
            prediction: .notBound,
            // This *is* the re-send: there is no second channel to add underneath it.
            allowParallelMesh: false
        ).outcome
    }

    /// The same callback in the value module 4 actually produces.
    @discardableResult
    public func onBluetoothDeliveryFailed(_ failure: PopopxBluetoothDeliveryFailure) async -> PopopxRouteOutcome {
        await onBluetoothDeliveryFailed(messageId: failure.messageId, peerMeshKey: failure.peerMeshPublicKeyHex)
    }

    /// Installs the router as module 4's failure sink. `start()` does it; a host that would rather wire
    /// the two by hand can call this instead.
    public func installBluetoothFailureHandler() async {
        await health.setDeliveryFailureHandler { [weak self] failure in
            guard let self else { return }
            _ = await self.onBluetoothDeliveryFailed(failure)
        }
    }

    // MARK: - Scenario B pure-offline fallback / network-restore flush

    /// Every queued message goes out over SMP with the id it was queued under.
    ///
    /// `start()`'s own connectivity subscription calls this on the restore edge, and the host may pull
    /// it after the user turns the mesh back on. A message still addressed to a temporary `connId`
    /// stays queued — it has no SMP address until module 6 upgrades that connection — and a message whose
    /// send failed again goes back with its original `queuedAt`, so the order the user typed in is the
    /// order a restore replays.
    ///
    /// Returns how many messages the public network actually took.
    @discardableResult
    public func flushPendingMessagesOnNetworkRestore() async -> Int {
        if let inFlight = inFlightFlush {
            // `start()`'s restore-edge subscription gets here first on a real device, so this call
            // usually arrives while a flush is running. Joining that run is the only honest answer:
            // returning 0 claimed nothing was flushed while the queue was being handed to SMP, and a
            // caller that believed it could start a second copy of the same send.
            return await inFlight.value
        }
        let flush = Task { await self.flushBacklog() }
        inFlightFlush = flush
        let flushed = await flush.value
        inFlightFlush = nil
        return flushed
    }

    private func flushBacklog() async -> Int {
        let backlog = pendingMessages()
        guard !backlog.isEmpty else { return 0 }
        guard await isConnected() else {
            PopopxMeshLog.route.info("🌫 flush asked while offline — queue left as is")
            return 0
        }
        PopopxMeshLog.route.notice(
            "🌐 network restored — flushing \(backlog.count, privacy: .public) queued message(s) over SMP"
        )
        var flushed = 0
        for pending in backlog {
            let binding = await resolveBinding(for: pending.target)
            guard let contactId = binding.contactId else {
                requeue(pending, reason: .awaitingContactUpgrade)
                continue
            }
            // A restore must not stack a second copy of a message that is already in flight. An
            // attempt marked `queued` is not in flight: it is the record of the attempt that put the
            // message in the queue, and it is this loop's own job to replace it.
            if attempts[pending.messageId]?.queued == false {
                requeue(pending)
                continue
            }
            attempts[pending.messageId] = Attempt(
                messageId: pending.messageId,
                target: pending.target,
                text: pending.text,
                startedAt: clock.date(),
                contactId: contactId,
                peerMeshPublicKeyHex: pending.peerMeshPublicKeyHex
            )
            let routed = await routeOverSMP(
                messageId: pending.messageId,
                contactId: contactId,
                text: pending.text,
                binding: binding,
                prediction: .notBound,
                allowParallelMesh: false
            )
            if case .smpAcknowledged = routed.outcome {
                flushed += 1
                // The queue entry outlives the send on purpose. `pendingMessageCount == 0` is the
                // signal a caller waits for, and it has to mean "every queued message reached SMP" —
                // clearing it before the hand-off let a drain look like a success two milliseconds
                // early.
                unacknowledgedMeshMessages[pending.messageId] = nil
                PopopxMeshLog.route.notice(
                    "📤 flushed id=\(pending.messageId.prefix(8), privacy: .public) over SMP"
                )
            } else {
                requeue(pending, reason: .smpUnacknowledged)
            }
        }
        publishStatus(flushed > 0 ? .smpOnline : .queued(messageCount: unacknowledgedMeshMessages.count))
        persistQueue()
        return flushed
    }

    public var pendingMessageCount: Int { unacknowledgedMeshMessages.count }

    /// The backlog in the order a restore will replay it.
    public func pendingMessages() -> [PopopxPendingMeshMessage] {
        unacknowledgedMeshMessages.values.sorted {
            if $0.queuedAt != $1.queuedAt { return $0.queuedAt < $1.queuedAt }
            return $0.messageId < $1.messageId
        }
    }

    /// Every flush this router can still name: the mesh id it minted and the row id the host stored it
    /// under. Module 7's merged timeline is the only reader, and it uses the pair to replace an offline
    /// row with the stored copy instead of drawing both.
    ///
    /// Named `recorded…`, not the name `PopopxMeshRoutingObserving` gives its requirement: a host that
    /// implements that requirement by forwarding here would otherwise write `flushedAppChatItemIDs()`,
    /// which resolves to the async requirement it is inside — recursion, not this dictionary. The
    /// distinct name is what makes the witness an unambiguous call.
    public func recordedFlushedAppChatItemIDs() -> [String: Int64] { appChatItemIDs }

    /// The same pairs in the order they were flushed, oldest first.
    public func flushedAppItemHistory() -> [(messageId: String, appChatItemId: Int64)] {
        flushedAppItems.map { (messageId: $0.messageId, appChatItemId: $0.appChatItemId) }
    }

    private func recordFlushedAppItem(messageId: String, appChatItemId: Int64) {
        if appChatItemIDs[messageId] != nil {
            // The same flush named twice (a late ACK after a deadline): the newest row id wins and the
            // position in the oldest-first list does not move.
            appChatItemIDs[messageId] = appChatItemId
            return
        }
        appChatItemIDs[messageId] = appChatItemId
        flushedAppItems.append(FlushedAppItem(messageId: messageId, appChatItemId: appChatItemId))
        while flushedAppItems.count > Self.maxTrackedFlushedAppItems, let oldest = flushedAppItems.first {
            flushedAppItems.removeFirst()
            appChatItemIDs[oldest.messageId] = nil
        }
    }

    // MARK: - Status surface for the UI layer

    public func currentStatus() -> PopopxRoutingStatus { status }

    /// The banner's feed: the current status replayed first, then every change. Nothing in this stream
    /// is a message — it is the one sentence a chat page's status bar shows.
    public func statusChanges() -> AsyncStream<PopopxRoutingStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PopopxRoutingStatus>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribeStatus(id) }
        }
        statusSubscriptions[id] = continuation
        continuation.yield(status)
        return stream
    }

    /// The unbound-stranger sentence on its own, so a caller that only needs to know whether to show it does
    /// not have to switch over the status.
    public func unboundStrangerStatus() async -> String? {
        status == .unboundStranger ? Self.unboundStrangerStatusText : nil
    }

    /// Module 6 calls this after a pairing upgrade. A banner that only ever changes on a send decision
    /// would go on promising "no public card exchanged yet" after the card arrived, which is the one moment the
    /// user most needs the status bar to be right. Only the stranger banner is rewritten: anything
    /// else on screen came from a real attempt and stays until the next one.
    public func refreshStatus(afterUpgradeContact contactId: Int64) async {
        guard status == .unboundStranger else { return }
        if await isConnected() {
            // Online and now bound: SMP is the default channel again, for this peer and for anybody
            // else whose banner was showing the same sentence.
            PopopxMeshLog.route.notice(
                "🃏 @\(contactId, privacy: .public) upgraded — stranger banner lifted, SMP is the default channel again"
            )
            publishStatus(.smpOnline)
            return
        }
        // Still offline: the card exists now, so the honest next sentence is the mesh one — but only
        // when the radio can actually carry it; with neither channel up the stranger banner is still
        // the closest thing to the truth and rewriting it would be a lie of a different shape.
        if await health.radioState.isUsable {
            publishStatus(.meshOnly(peerMeshPublicKeyHex: nil))
        }
    }

    // MARK: - global-unique messageId idempotent dedup

    /// The one message-id memory in the system, asked instead of duplicated: `true` means "show or
    /// store this id", `false` means another channel already delivered it. This router keeps no second
    /// ledger — `PopopxMeshDeduplicator` is the thing that decides, keyed by the id the sender minted
    /// and reuses verbatim across Bluetooth and SMP.
    public func shouldDeliver(messageId: String) async -> Bool {
        await deduplicator.noteMessage(id: messageId)
    }

    /// Records an offline Bluetooth message for its recipient, answering `false` — and storing nothing —
    /// when the same id already arrived over another channel.
    @discardableResult
    public func recordIncoming(_ record: PopopxMeshOfflineRecord) async -> Bool {
        guard await shouldDeliver(messageId: record.messageId) else {
            PopopxMeshLog.route.debug(
                "🔁 id=\(record.messageId.prefix(8), privacy: .public) already delivered over another channel — not recorded twice"
            )
            return false
        }
        offlineRecords[record.messageId, default: []].append(record)
        trimOfflineRecordsIfNeeded()
        persistRecords()
        return true
    }

    public func offlineRecords(for target: PopopxRouteTarget) -> [PopopxMeshOfflineRecord] {
        offlineRecords.values.flatMap { $0 }
            .filter { $0.target == target }
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    // MARK: - module 6's migration

    /// Moves everything hung on a temporary `connId` — the offline records, the
    /// `unacknowledgedMeshMessages` queue and any live attempt — onto the real `contactId`, so a
    /// message the user typed while the pairing was pending goes out over SMP the moment the contact
    /// exists.
    ///
    /// Only the address they are filed under moves; the ids never do.
    @discardableResult
    public func migrateQueuedMessages(fromTempConnId tempConnId: Int64, toContactId contactId: Int64)
        -> PopopxMigrationReport
    {
        let source: PopopxRouteTarget = .tempConnId(tempConnId)
        let destination: PopopxRouteTarget = .contactId(contactId)
        var movedQueue = 0
        var movedRecords = 0

        for (messageId, pending) in unacknowledgedMeshMessages where pending.target == source {
            unacknowledgedMeshMessages[messageId] = pending.relocated(to: destination, reason: .noNetwork)
            movedQueue += 1
        }
        for messageId in attempts.keys where attempts[messageId]?.target == source {
            attempts[messageId]?.target = destination
            attempts[messageId]?.contactId = contactId
        }
        let snapshot = offlineRecords
        for (key, list) in snapshot {
            guard list.contains(where: { $0.target == source }) else { continue }
            movedRecords += list.filter { $0.target == source }.count
            offlineRecords[key] = list.map { $0.target == source ? $0.relocated(to: destination) : $0 }
        }
        if movedQueue > 0 { persistQueue() }
        if movedRecords > 0 { persistRecords() }
        if movedQueue > 0 || movedRecords > 0 {
            PopopxMeshLog.route.notice(
                "🧳 migrated queued=\(movedQueue, privacy: .public) records=\(movedRecords, privacy: .public) from pending :\(tempConnId, privacy: .public) to @\(contactId, privacy: .public)"
            )
        }
        return PopopxMigrationReport(movedQueuedMessages: movedQueue, movedOfflineRecords: movedRecords)
    }

    // MARK: - Channel choice

    /// Both identities of one peer, from module 1's store, whichever way the caller addressed it.
    private func resolveBinding(for target: PopopxRouteTarget) async -> Binding {
        switch target {
        case let .contactId(contactId):
            return Binding(
                target: target,
                contactId: contactId,
                meshPublicKeyHexes: await store.meshPublicKeyHexes(forContactId: contactId)
            )
        case let .tempConnId(tempConnId):
            let rows = await store.pendingMappings(forTempConnId: tempConnId)
            return Binding(
                target: target,
                contactId: rows.first(where: { $0.contactId != nil })?.contactId,
                meshPublicKeyHexes: rows.map(\.meshPublicKeyHex)
            )
        case let .meshPublicKeyHex(hex):
            let mapping = await store.mapping(forMeshPublicKeyHex: hex)
            return Binding(
                target: target,
                contactId: mapping?.contactId,
                meshPublicKeyHexes: mapping == nil ? [] : [hex]
            )
        }
    }

    /// Pre-send prediction: could Bluetooth carry anything right now? The two refusals the prompt names are the
    /// peer's silence (`peerReachabilityTimeout`, 15 s — the window module 4 measures against) and our
    /// own radio being down. `PopopxOfflineBridge`'s second rule is the same one, stated from the
    /// pairing side.
    private func predictBluetooth(for binding: Binding) async -> PopopxBluetoothPrediction {
        guard let candidate = binding.meshPublicKeyHexes.first else { return .notBound }
        let radio = await health.radioState
        guard radio.isUsable else { return .radioUnavailable(radio) }
        for meshPublicKeyHex in binding.meshPublicKeyHexes
        where await health.isPeerReachable(publicKey: meshPublicKeyHex, timeout: config.peerReachabilityTimeout) {
            return .reachable(peerMeshPublicKeyHex: meshPublicKeyHex)
        }
        return .peerOutOfRange(peerMeshPublicKeyHex: candidate)
    }

    private func isConnected() async -> Bool {
        (await network.currentPath())?.isConnected ?? false
    }

    /// The edges of the path, not its level: only a change says anything the status bar has not been
    /// told already.
    private func networkChanged(_ path: PopopxNetworkPath) async {
        let wasConnected = lastStatusPath?.isConnected
        lastStatusPath = path
        if path.isConnected {
            // Once NWPathMonitor detects the network is back, immediately call flushPendingMessagesOnNetworkRestore().
            guard wasConnected != true else { return }
            if unacknowledgedMeshMessages.isEmpty {
                publishStatus(.smpOnline)
            } else {
                _ = await flushPendingMessagesOnNetworkRestore()
            }
            return
        }
        guard wasConnected == true else { return }
        // Offline: say what carries the next message instead of leaving the old "online" banner up.
        let radioUsable = await health.radioState.isUsable
        publishStatus(
            radioUsable
                ? .meshOnly(peerMeshPublicKeyHex: nil)
                : .queued(messageCount: unacknowledgedMeshMessages.count)
        )
    }

    private func clearObservationHandle() {
        observationTask = nil
    }

    /// Scenario A's first choice, shared by `send`, the failure re-route and the restore flush.
    private func routeOverSMP(
        messageId: String,
        contactId: Int64,
        text: String,
        binding: Binding,
        prediction: PopopxBluetoothPrediction,
        allowParallelMesh: Bool
    ) async -> PopopxRoutedMessage {
        let target = binding.target
        startSMPSend(messageId: messageId, contactId: contactId, text: text)
        let acked = await awaitSMPAcknowledgement(messageId: messageId, timeout: config.smpAckTimeout)
        if acked {
            let outcome = PopopxRouteOutcome.smpAcknowledged(contactId: contactId)
            publishStatus(for: outcome)
            return PopopxRoutedMessage(
                messageId: messageId, target: target, outcome: outcome, bluetooth: prediction
            )
        }
        // No SMP server ACK within 3 s. The send is still live — the window measures a *reply*, not a
        // request — so the mesh copy goes out alongside it rather than replacing it.
        if allowParallelMesh, case let .reachable(peerMeshPublicKeyHex) = prediction,
           await sendOverMesh(
                messageId: messageId,
                text: text,
                peerMeshPublicKeyHex: peerMeshPublicKeyHex
           ) != nil {
            let outcome = PopopxRouteOutcome.smpUnacknowledgedMeshParallel(
                contactId: contactId,
                peerMeshPublicKeyHex: peerMeshPublicKeyHex
            )
            publishStatus(for: outcome)
            return PopopxRoutedMessage(
                messageId: messageId, target: target, outcome: outcome, bluetooth: prediction
            )
        }
        let outcome = PopopxRouteOutcome.smpUnacknowledgedNoMesh(contactId: contactId)
        publishStatus(for: outcome)
        return PopopxRoutedMessage(
            messageId: messageId, target: target, outcome: outcome, bluetooth: prediction
        )
    }

    /// Hands one envelope to the mesh, keeping the id. `PopopxMeshEngine` arms module 4's 5-second
    /// BLE_ACK guard for us, so a *successful* return here is only "the frame went out": the failure
    /// callback is what says whether it landed. A throw means it never reached the radio, so no
    /// callback is coming and this router must park the message itself.
    private func sendOverMesh(
        messageId: String,
        text: String,
        peerMeshPublicKeyHex: String
    ) async -> PopopxRouteOutcome? {
        do {
            try await outbound.send(envelope: .text(id: messageId, body: text), to: peerMeshPublicKeyHex)
        } catch {
            PopopxMeshLog.route.warning(
                "📡 mesh refused id=\(messageId.prefix(8), privacy: .public): \(error.failureReason, privacy: .public)"
            )
            return nil
        }
        attempts[messageId]?.sentOverMesh = true
        attempts[messageId]?.peerMeshPublicKeyHex = peerMeshPublicKeyHex
        unacknowledgedMeshMessages[messageId] = nil
        persistQueue()
        PopopxMeshLog.route.notice(
            "📶 sent id=\(messageId.prefix(8), privacy: .public) over mesh to \(peerMeshPublicKeyHex.prefix(8), privacy: .public), BLE_ACK guard armed"
        )
        return .meshSent(peerMeshPublicKeyHex: peerMeshPublicKeyHex)
    }

    /// Pure-offline fallback, or the unbound-stranger refusal when there is no public card behind the peer at all.
    private func parkOrRefuse(
        messageId: String,
        binding: Binding,
        prediction: PopopxBluetoothPrediction
    ) async -> PopopxRoutedMessage {
        let text = attempts[messageId]?.text ?? ""
        let peerKey = attempts[messageId]?.peerMeshPublicKeyHex ?? prediction.peerKey
        // Nothing exchanged with the public network and nothing on the radio either: a queue entry
        // would be a promise no flush could keep, so the user is told instead.
        if binding.contactId == nil, binding.meshPublicKeyHexes.isEmpty {
            let outcome = PopopxRouteOutcome.refusedUnboundStranger(peerMeshPublicKeyHex: peerKey)
            cancelDeadline(messageId)
            attempts[messageId] = nil
            publishStatus(for: outcome)
            return PopopxRoutedMessage(
                messageId: messageId, target: binding.target, outcome: outcome, bluetooth: prediction
            )
        }
        let reason: PopopxQueueReason
        switch prediction {
        case .radioUnavailable, .peerOutOfRange: reason = .peerUnreachable
        case .notBound: reason = binding.contactId == nil ? .awaitingContactUpgrade : .noNetwork
        case .reachable: reason = .meshRefused
        }
        enqueue(
            PopopxPendingMeshMessage(
                messageId: messageId,
                target: binding.target,
                text: text,
                peerMeshPublicKeyHex: peerKey,
                queuedAt: attempts[messageId]?.startedAt ?? clock.date(),
                reason: reason
            )
        )
        attempts[messageId]?.queued = true
        let outcome = PopopxRouteOutcome.queuedOffline(reason)
        publishStatus(for: outcome)
        return PopopxRoutedMessage(
            messageId: messageId, target: binding.target, outcome: outcome, bluetooth: prediction
        )
    }

    // MARK: - SMP send and the 3-second ACK window

    private func startSMPSend(messageId: String, contactId: Int64, text: String) {
        // Not awaited from here on: the window measures the ACK, and abandoning the request to go look
        // at the radio would lose a message that was already leaving the device.
        let core = self.core
        Task { [weak self] in
            let acked: Bool
            let appChatItemId: Int64?
            do {
                let ack = try await core.sendTextOverSMP(
                    PopopxSMPSendRequest(messageId: messageId, contactId: contactId, text: text)
                )
                // An ACK for a different id is not an ACK for this one: the adapter is promised to
                // carry the id verbatim, and a channel that loses it cannot be trusted to deliver.
                acked = ack.messageId == messageId
                // A row id from a send this router does not believe in is not recorded: the pairing
                // would then hide an offline row whose message never reached the server.
                appChatItemId = acked ? ack.appChatItemId : nil
                if !acked {
                    PopopxMeshLog.route.error(
                        "🚫 SMP ack named id=\(ack.messageId.prefix(8), privacy: .public) for id=\(messageId.prefix(8), privacy: .public)"
                    )
                }
            } catch {
                PopopxMeshLog.route.error(
                    "❌ SMP send failed id=\(messageId.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)"
                )
                acked = false
                appChatItemId = nil
            }
            guard !Task.isCancelled else { return }
            await self?.recordSMPResult(
                messageId: messageId,
                contactId: contactId,
                acked: acked,
                appChatItemId: appChatItemId
            )
        }
    }

    /// Waits for the server ACK for at most `timeout`. Running out resumes the waiter with `false` and
    /// cancels only the deadline — the send keeps running, and whatever it decides later is handled by
    /// `recordSMPResult`, which is why the first answer wins.
    private func awaitSMPAcknowledgement(messageId: String, timeout: TimeInterval) async -> Bool {
        if let settled = settledAcks.removeValue(forKey: messageId) {
            cancelDeadline(messageId)
            return settled
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            smpWaiters[messageId, default: []].append(continuation)
            armDeadline(messageId, timeout: timeout)
        }
    }

    private func armDeadline(_ messageId: String, timeout: TimeInterval) {
        cancelDeadline(messageId)
        let delay = clock.delay
        deadlineTasks[messageId] = Task { [weak self] in
            await delay(timeout)
            guard !Task.isCancelled else { return }
            await self?.smpDeadlinePassed(messageId)
        }
    }

    private func smpDeadlinePassed(_ messageId: String) {
        deadlineTasks[messageId] = nil
        guard smpWaiters[messageId] != nil else {
            // Nobody is waiting any more: the send may still land, and `recordSMPResult` will take it.
            return
        }
        settleSMPWaiters(messageId, acked: false)
    }

    /// The real ACK or failure, whenever it arrives. First answer wins, which is what makes a deadline
    /// and a late ACK racing each other harmless.
    private func recordSMPResult(
        messageId: String,
        contactId: Int64,
        acked: Bool,
        appChatItemId: Int64? = nil
    ) async {
        cancelDeadline(messageId)
        if smpWaiters[messageId] != nil {
            settleSMPWaiters(messageId, acked: acked)
        } else {
            settledAcks[messageId] = acked
        }
        guard acked else {
            // The public network refused it after all. The mesh takes the message if it can and the
            // queue if it cannot — but a copy already on the radio is not a copy to re-send.
            guard let attempt = attempts[messageId], !attempt.sentOverMesh, !attempt.queued else { return }
            let binding = await resolveBinding(for: attempt.target)
            let prediction = await predictBluetooth(for: binding)
            if case let .reachable(peerMeshPublicKeyHex) = prediction,
               await sendOverMesh(
                    messageId: messageId,
                    text: attempt.text,
                    peerMeshPublicKeyHex: peerMeshPublicKeyHex
               ) != nil {
                attempts[messageId]?.sentOverMesh = true
                return
            }
            _ = await parkOrRefuse(messageId: messageId, binding: binding, prediction: prediction)
            return
        }
        attempts[messageId] = nil
        unacknowledgedMeshMessages[messageId] = nil
        settledAcks[messageId] = nil
        if let appChatItemId {
            recordFlushedAppItem(messageId: messageId, appChatItemId: appChatItemId)
        }
        persistQueue()
        PopopxMeshLog.route.notice(
            "✅ SMP ACK id=\(messageId.prefix(8), privacy: .public) from @\(contactId, privacy: .public), stored row \(appChatItemId.map(String.init(describing:)) ?? "unknown", privacy: .public)"
        )
    }

    private func settleSMPWaiters(_ messageId: String, acked: Bool) {
        guard let waiters = smpWaiters.removeValue(forKey: messageId) else { return }
        for waiter in waiters { waiter.resume(returning: acked) }
    }

    private func cancelDeadline(_ messageId: String) {
        deadlineTasks[messageId]?.cancel()
        deadlineTasks[messageId] = nil
    }

    private func cancelAllDeadlines() {
        for task in deadlineTasks.values { task.cancel() }
        deadlineTasks.removeAll()
    }

    /// Resumes anyone still waiting so no `send` is left suspended after the router stops. No
    /// continuation is ever dropped: a lost resume is a hung send, not a cancelled one.
    private func drainSMPWaiters() {
        for messageId in smpWaiters.keys { settleSMPWaiters(messageId, acked: false) }
        settledAcks.removeAll()
    }

    // MARK: - Queue and record storage

    private func enqueue(_ message: PopopxPendingMeshMessage) {
        unacknowledgedMeshMessages[message.messageId] = message
        trimQueueIfNeeded()
        persistQueue()
    }

    /// Puts a message back as it was, so a failed restore costs the user nothing but time.
    private func requeue(_ message: PopopxPendingMeshMessage, reason: PopopxQueueReason? = nil) {
        unacknowledgedMeshMessages[message.messageId] = message.relocated(to: message.target, reason: reason)
        attempts[message.messageId]?.queued = true
        cancelDeadline(message.messageId)
        persistQueue()
    }

    private func trimQueueIfNeeded() {
        guard unacknowledgedMeshMessages.count > Self.maxUnacknowledgedMessages else { return }
        let drop = unacknowledgedMeshMessages.count - Self.maxUnacknowledgedMessages
        for message in pendingMessages().prefix(drop) {
            unacknowledgedMeshMessages[message.messageId] = nil
            PopopxMeshLog.route.warning(
                "🧹 queue capped at \(PopopxMessageRouter.maxUnacknowledgedMessages, privacy: .public) — dropped oldest id=\(message.messageId.prefix(8), privacy: .public)"
            )
        }
    }

    private func trimAttemptsIfNeeded(now: Date) {
        guard attempts.count >= Self.maxTrackedAttempts else { return }
        let oldest = attempts.values
            .filter { $0.sentOverMesh || $0.queued }
            .sorted { $0.startedAt < $1.startedAt }
            .prefix(attempts.count - Self.maxTrackedAttempts + 1)
        for attempt in oldest {
            cancelDeadline(attempt.messageId)
            attempts[attempt.messageId] = nil
        }
    }

    private func trimOfflineRecordsIfNeeded() {
        let total = offlineRecords.values.reduce(0) { $0 + $1.count }
        guard total > Self.maxOfflineRecords else { return }
        let keep = offlineRecords.values.flatMap { $0 }
            .sorted { $0.receivedAt < $1.receivedAt }
            .suffix(Self.maxOfflineRecords)
        var rebuilt: [String: [PopopxMeshOfflineRecord]] = [:]
        for record in keep { rebuilt[record.messageId, default: []].append(record) }
        offlineRecords = rebuilt
    }

    private func persistQueue() {
        guard let queueURL else { return }
        do {
            try PopopxMeshFileStore.write(
                StoredQueue(
                    schemaVersion: 1,
                    messages: pendingMessages(),
                    flushedAppItems: flushedAppItems
                ),
                to: queueURL
            )
        } catch {
            PopopxMeshLog.store.error(
                "❌ offline queue not written: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func loadQueueFromDisk() {
        guard let queueURL, unacknowledgedMeshMessages.isEmpty else { return }
        guard let snapshot = try? PopopxMeshFileStore.read(StoredQueue.self, from: queueURL) else { return }
        for message in snapshot.messages where unacknowledgedMeshMessages[message.messageId] == nil {
            unacknowledgedMeshMessages[message.messageId] = message
        }
        // Read before the `messages.isEmpty` gate below: the pairs outlive the queue on purpose, so a
        // file whose backlog is empty is exactly the normal case after a successful flush.
        for item in snapshot.flushedAppItems ?? [] {
            recordFlushedAppItem(messageId: item.messageId, appChatItemId: item.appChatItemId)
        }
        guard !snapshot.messages.isEmpty else { return }
        PopopxMeshLog.store.info(
            "📖 offline queue restored — \(snapshot.messages.count, privacy: .public) message(s)"
        )
    }

    private func persistRecords() {
        guard let recordsURL else { return }
        do {
            try PopopxMeshFileStore.write(
                StoredRecords(
                    schemaVersion: 1,
                    records: offlineRecords.values.flatMap { $0 }.sorted { $0.receivedAt < $1.receivedAt }
                ),
                to: recordsURL
            )
        } catch {
            PopopxMeshLog.store.error(
                "❌ offline records not written: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func loadRecordsFromDisk() {
        guard let recordsURL, offlineRecords.isEmpty else { return }
        guard let snapshot = try? PopopxMeshFileStore.read(StoredRecords.self, from: recordsURL) else { return }
        for record in snapshot.records {
            var list = offlineRecords[record.messageId, default: []]
            guard !list.contains(where: { $0.target == record.target }) else { continue }
            list.append(record)
            offlineRecords[record.messageId] = list
        }
    }

    // MARK: - Status

    /// The status a decision implies. `.nothingToReroute` deliberately says nothing: an id from another
    /// run is not evidence about the network.
    private func publishStatus(for outcome: PopopxRouteOutcome) {
        switch outcome {
        case .smpAcknowledged, .smpUnacknowledgedNoMesh:
            publishStatus(.smpOnline)
        case let .smpUnacknowledgedMeshParallel(_, peerMeshPublicKeyHex):
            publishStatus(.dualChannel(peerMeshPublicKeyHex: peerMeshPublicKeyHex))
        case let .meshSent(peerMeshPublicKeyHex):
            publishStatus(.meshOnly(peerMeshPublicKeyHex: peerMeshPublicKeyHex))
        case .queuedOffline:
            publishStatus(.queued(messageCount: unacknowledgedMeshMessages.count))
        case .refusedUnboundStranger:
            publishStatus(.unboundStranger)
        case .duplicate:
            break
        case .nothingToReroute:
            break
        }
    }

    private func publishStatus(_ next: PopopxRoutingStatus) {
        guard next != status else { return }
        status = next
        for continuation in statusSubscriptions.values {
            continuation.yield(next)
        }
        var userInfo: [String: Any] = [Self.statusCodeKey: next.statusCode]
        if let displayText = next.displayText {
            userInfo[Self.statusTextKey] = displayText
        }
        // `object: self` so an observer can bind to one router. A host that observes with
        // `object: nil` sees every post, exactly as before; inside the test suite, where several
        // routers run concurrently in one process, that distinction is what makes an assertion about
        // "the first status" mean the first status *this* router sent.
        NotificationCenter.default.post(name: Self.statusNotification, object: self, userInfo: userInfo)
        if let displayText = next.displayText {
            PopopxMeshLog.route.notice(
                "🪧 status \(next.statusCode, privacy: .public): \(displayText, privacy: .public)"
            )
        }
    }

    private func unsubscribeStatus(_ id: UUID) {
        statusSubscriptions[id] = nil
    }
}

// MARK: - Reading a mesh refusal

extension PopopxMeshSendError {
    /// The refusal in the router's own words, because a queue entry that says nothing about why it is
    /// sitting there is indistinguishable from a bug.
    var failureReason: String {
        "failure=\(failure) message=\(messageId.prefix(8))"
    }
}
