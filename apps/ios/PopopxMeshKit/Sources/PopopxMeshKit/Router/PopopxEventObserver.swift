//
//  PopopxEventObserver.swift
//  PopopxMeshKit  —  module 6
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Automatic session upgrade once online. A read-only bypass mounted on the chat core's *existing* event bus, watching
//  for the two events that say an offline pairing has become a real contact:
//  `contactConnected` (`Shared/Model/AppAPITypes.swift:1240`) and `contactSndReady`
//  (`AppAPITypes.swift:1242`, the first send landing on the server side). When one arrives, the
//  pending connection the offline `/_connect` created (module 2's `tempConnId`, recorded by module 1's
//  `bind`) is upgraded to the contact id the event carries, the router moves everything filed under
//  the temporary id onto the real one, and a `NotificationCenter` posting lets the open chat page
//  swap its status bar without a reload.
//
//  Read-only in the strongest sense this package can manage. The observer never consumes, filters,
//  reorders or cancels the app's stream: it takes *its own* subscription (`sessionEvents()` hands out
//  a fresh one per call), so the app's pump keeps its consumer and the two never share a buffer. It
//  runs the upgrade on its own task, so a slow store cannot hold the producer's thread. It has no
//  way to make an event disappear — every input produces a `PopopxSessionUpgradeResult` that says
//  what was done, including `.ignored` for the hundred event kinds that are none of its business.
//  And it fails quietly: a malformed or ambiguous event is logged and answered, never thrown back
//  into a bus that has no idea this observer exists.
//
//  What it deliberately does not do: no SMP call, no FFI, no second identity store. The one atomic
//  write is `IdentityMappingStore.upgradePendingConnection(tempConnId:toFinalContactId:)`, which is
//  module 1's own transaction — module 6 only decides *when* it runs.
//

import Foundation

// MARK: - The event, as the package can see it

/// The two events module 6 acts on, plus the honest "something else" arm.
///
/// The app's bus carries a few hundred cases (`AppAPIEvent`); the adapter is expected to forward the
/// whole stream rather than pre-filter it, so that what this observer ignores is visible in its own
/// code instead of hidden in somebody else's `switch`.
public enum PopopxChatSessionEventKind: Hashable, Sendable {
    /// `case contactConnected(user:contact:userCustomProfile:)` — the peer's identity was proved and
    /// the contact exists.
    case contactConnected
    /// `case contactSndReady(user:contact:)` — the first message reached the server for that contact.
    case contactSndReady
    /// Any other event. Carries its `name` (the same string `AppAPIEvent.name` produces) so a log line
    /// can say which one it was, and nothing else.
    case other(name: String)

    public var isUpgradeCandidate: Bool {
        switch self {
        case .contactConnected, .contactSndReady: true
        case .other: false
        }
    }

    /// The stable string a UI or a log can switch on, matching the app's own `AppAPIEvent.name`.
    public var rawName: String {
        switch self {
        case .contactConnected: "contactConnected"
        case .contactSndReady: "contactSndReady"
        case let .other(name): name
        }
    }
}

/// One event from the chat core, reduced to the four things an upgrade needs.
///
/// The adapter builds these from `AppAPIEvent`: `contactId` is `Contact.id`
/// (`POPOPXChat/ChatTypes.swift`), `tempConnId` is the `PendingContactConnection.pccConnId`
/// (`ChatTypes.swift:2911`) that module 2's `PopopxOfflineInvite` returned, and
/// `peerMeshPublicKeyHex` is the mesh key the invite was bound to. Either of the two optional fields
/// is enough for the upgrade: `tempConnId` when the app still has the pending connection at hand, the
/// mesh key when only the mesh remembers it. `userRef` is `UserRef`'s display string — quoted back in
/// the notification so a page open on another account can tell it is not for it.
public struct PopopxChatSessionEvent: Hashable, Sendable {
    public let kind: PopopxChatSessionEventKind
    /// The contact the core just created or confirmed. nil for every other event kind.
    public let contactId: Int64?
    public let tempConnId: Int64?
    public let peerMeshPublicKeyHex: String?
    public let userRef: String?
    public let nickname: String?

    public init(
        kind: PopopxChatSessionEventKind,
        contactId: Int64? = nil,
        tempConnId: Int64? = nil,
        peerMeshPublicKeyHex: String? = nil,
        userRef: String? = nil,
        nickname: String? = nil
    ) {
        self.kind = kind
        self.contactId = contactId
        self.tempConnId = tempConnId
        self.peerMeshPublicKeyHex = peerMeshPublicKeyHex
        self.userRef = userRef
        self.nickname = nickname
    }

    /// An event from the bus that has nothing to do with a pairing upgrade.
    public static func other(_ name: String, userRef: String? = nil) -> PopopxChatSessionEvent {
        PopopxChatSessionEvent(kind: .other(name: name), userRef: userRef)
    }

    /// The mesh key in the store's own canonical spelling, so an adapter that forwards upper-case hex
    /// from a `Data` description still resolves.
    public var canonicalPeerKey: String? {
        peerMeshPublicKeyHex.flatMap { IdentityMappingStore.canonicalMeshPublicKeyHex($0) }
    }
}

/// The bypass seam the app implements — see `PopopxEventObserver`'s header for why it is a subscription
/// and not a callback the observer could swallow.
public protocol PopopxChatEventFeeding: Sendable {
    /// A *fresh* subscription to the chat core's event stream, already mapped into
    /// `PopopxChatSessionEvent`. Called once per `startObserving()`: every consumer of the app's bus
    /// gets its own, so mounting this observer cannot take events away from anybody.
    func sessionEvents() async -> AsyncStream<PopopxChatSessionEvent>
}

/// What one event did. Every arm is a fact about the mesh's own records, never an error thrown at a
/// bus that does not know this observer exists.
public enum PopopxSessionUpgradeResult: Hashable, Sendable {
    /// Atomic upgrade complete: `movedBindings` mesh keys now resolve to the contact, and the router moved
    /// `migration`'s worth of offline records and queued messages onto it. `flushedMessages` is how
    /// many of those the public network took right away — 0 while offline, where they wait in
    /// `unacknowledgedMeshMessages` for the restore edge instead.
    case upgraded(
        tempConnId: Int64,
        contactId: Int64,
        movedBindings: Int,
        migration: PopopxMigrationReport,
        flushedMessages: Int
    )
    /// This contact's bindings were already upgraded — the second of the two events, or a re-delivery.
    /// Idempotent by construction: nothing moved, nothing posted.
    case alreadyUpgraded(contactId: Int64)
    /// A contact the mesh never paired with offline (the ordinary online case), or a pending
    /// connection that is gone. Nothing was ours to upgrade.
    case noPendingConnection(contactId: Int64)
    /// The event named neither a pending connection nor a mesh key, and more than one pairing is
    /// in flight, so guessing would upgrade the wrong peer. Refused on purpose; the app can resolve
    /// it by forwarding `tempConnId`.
    case ambiguous(contactId: Int64, pendingCandidateCount: Int)
    /// Missing or non-positive ids — the upgrade simply cannot be attempted.
    case malformed(kind: PopopxChatSessionEventKind)
    /// Not one of the two events. The bypass looked at it and moved on.
    case ignored(kind: PopopxChatSessionEventKind)

    /// The banner-facing code this result posts in `userInfo`.
    public var statusCode: String {
        switch self {
        case .upgraded: "upgraded"
        case .alreadyUpgraded: "alreadyUpgraded"
        case .noPendingConnection: "noPendingConnection"
        case .ambiguous: "ambiguous"
        case .malformed: "malformed"
        case .ignored: "ignored"
        }
    }

    /// True only when something actually changed, which is the gate on the notification.
    public var didChangeState: Bool {
        if case .upgraded = self { true } else { false }
    }
}

// MARK: - The observer

public actor PopopxEventObserver {
    // No `shared`, like module 3/5: this type needs a router, and a router needs the app's chat core.
    // Phase 2 constructs one observer, mounts it on the event pump and on the UI, and stops it with
    // the global fuse.

    /// Posted after a real upgrade so the open chat page can swap its status bar without a reload —
    /// the prompt's "let the current chat page smoothly upgrade its status bar". `userInfo` carries `statusCode`, `contactId`,
    /// `tempConnId`, `movedBindings`, `movedQueuedMessages`, `movedOfflineRecords`,
    /// `flushedMessages`, `meshPublicKeyHexes` and `statusText` (the banner copy the router now
    /// believes, which is the field a status-bar view can show as-is). Nothing is posted for an event
    /// that changed no state: a page would otherwise animate on every `contactSndReady`.
    public static let upgradeNotification = Notification.Name("chat.popopx.mesh.sessionUpgraded")

    public static let statusCodeKey = "statusCode"
    public static let contactIdKey = "contactId"
    public static let tempConnIdKey = "tempConnId"
    public static let movedBindingsKey = "movedBindings"
    public static let movedQueuedMessagesKey = "movedQueuedMessages"
    public static let movedOfflineRecordsKey = "movedOfflineRecords"
    public static let flushedMessagesKey = "flushedMessages"
    public static let meshPublicKeyHexesKey = "meshPublicKeyHexes"
    public static let userRefKey = "userRef"
    public static let statusTextKey = "statusText"

    private enum TempResolution: Hashable {
        case resolved(Int64)
        case none
        case ambiguous(Int)
    }

    private let feed: any PopopxChatEventFeeding
    private let store: IdentityMappingStore
    private let router: PopopxMessageRouter

    private var observationTask: Task<Void, Never>?
    private var handled: [PopopxChatSessionEvent: PopopxSessionUpgradeResult] = [:]

    /// The number of events whose result the observer can still quote, bounded so a long-lived bypass
    /// on a busy bus cannot grow a cache of every event it ever saw.
    public static let maxRememberedEvents = 512

    public init(
        feed: any PopopxChatEventFeeding,
        store: IdentityMappingStore = .shared,
        router: PopopxMessageRouter
    ) {
        self.feed = feed
        self.store = store
        self.router = router
    }

    // MARK: - Lifecycle

    /// Takes its own subscription and starts reading. Idempotent, like the rest of the package's
    /// lifecycle: the global fuse may be toggled repeatedly.
    public func startObserving() async {
        guard observationTask == nil else { return }
        let stream = await feed.sessionEvents()
        observationTask = Task { [weak self] in
            // Sequential on purpose: `contactConnected` and `contactSndReady` for the same peer must
            // be decided in the order the core sent them, or the second would look like a fresh
            // upgrade. The producer is never blocked by this loop — the stream is the buffer between
            // the app's pump and this bypass.
            for await event in stream {
                if Task.isCancelled { break }
                await self?.observe(event)
            }
            if !Task.isCancelled { await self?.clearObservationHandle() }
        }
        PopopxMeshLog.offline.info("▶️ event observer mounted (read-only bypass)")
    }

    /// Ends the bypass. The app's own consumers are untouched: this only cancels the task holding our
    /// subscription, and the feed's `onTermination` removes the subscription from the bus.
    public func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        handled.removeAll()
        PopopxMeshLog.offline.info("⏹ event observer unmounted")
    }

    public var isObserving: Bool { observationTask != nil }

    private func clearObservationHandle() {
        observationTask = nil
    }

    // MARK: - The one entry point

    /// The upgrade decision for one event.
    ///
    /// Awaited by `startObserving()`'s loop; a host that pushes events from its own pump should
    /// `Task { await observer.observe(event) }` rather than insert this into the delivery path — it
    /// writes to two actors and never throws, so there is nothing for the caller to handle, and
    /// awaiting it would make the app's event dispatch wait on the mesh.
    @discardableResult
    public func observe(_ event: PopopxChatSessionEvent) async -> PopopxSessionUpgradeResult {
        let result = await decide(event)
        // Remembered for the UI's "why did this banner change" question, and so a re-delivered event
        // can be answered with the same verdict it got the first time.
        remember(event, result: result)
        return result
    }

    public func result(for event: PopopxChatSessionEvent) -> PopopxSessionUpgradeResult? {
        handled[event]
    }

    public var handledEventCount: Int { handled.count }

    private func decide(_ event: PopopxChatSessionEvent) async -> PopopxSessionUpgradeResult {
        guard event.kind.isUpgradeCandidate else {
            // Read-only bypass: everything that is not one of the two events is looked at and passed over.
            return .ignored(kind: event.kind)
        }
        guard let contactId = event.contactId, contactId > 0 else {
            PopopxMeshLog.offline.warning(
                "🚫 \(event.kind.rawName, privacy: .public) carried no usable contact id"
            )
            return .malformed(kind: event.kind)
        }
        // Already upgraded: the second event for the same peer, or the same event delivered twice by a
        // reconnecting bus. Answered before the resolution below, because after an upgrade there is no
        // pending connection left to resolve and `.noPendingConnection` would be the wrong story.
        if await store.meshPublicKeyHexes(forContactId: contactId).isEmpty == false {
            PopopxMeshLog.offline.info(
                "⏭ \(event.kind.rawName, privacy: .public) for @\(contactId, privacy: .public) — bindings already upgraded"
            )
            return .alreadyUpgraded(contactId: contactId)
        }
        switch await resolveTempConnId(for: event, contactId: contactId) {
        case .none:
            // An ordinary online contact. The mesh never spoke to this peer over Bluetooth, so there
            // is nothing here to upgrade and nothing to say about it.
            return .noPendingConnection(contactId: contactId)
        case let .ambiguous(count):
            PopopxMeshLog.offline.warning(
                "🤔 \(event.kind.rawName, privacy: .public) for @\(contactId, privacy: .public) names no pending connection and \(count, privacy: .public) are in flight — refusing to guess"
            )
            return .ambiguous(contactId: contactId, pendingCandidateCount: count)
        case let .resolved(tempConnId):
            return await upgrade(tempConnId: tempConnId, contactId: contactId, event: event)
        }
    }

    /// Which temporary connection this event is about.
    ///
    /// The app's `contactConnected` carries a `Contact`, not the `PendingContactConnection` that
    /// produced it, so the mesh's own records are the only bridge — and in the SMP id space the two
    /// ids can even be the same number. Both are supported, in this order: the id the adapter has,
    /// then the pending row named by the peer's mesh key, then the single pending row when exactly one
    /// exists. Anything looser is a guess about somebody else's pairing, and a wrong upgrade is worse
    /// than no upgrade.
    private func resolveTempConnId(for event: PopopxChatSessionEvent, contactId: Int64) async -> TempResolution {
        if let tempConnId = event.tempConnId, tempConnId > 0 {
            return .resolved(tempConnId)
        }
        if let peerKey = event.canonicalPeerKey,
           let row = await store.mapping(forMeshPublicKeyHex: peerKey), row.isPending,
           let tempConnId = row.tempConnId {
            return .resolved(tempConnId)
        }
        let pending = await store.allMappings().filter(\.isPending)
        if pending.isEmpty { return .none }
        if pending.count == 1, let tempConnId = pending.first?.tempConnId {
            PopopxMeshLog.offline.info(
                "🧭 \(event.kind.rawName, privacy: .public) resolved by the sole pending connection :\(tempConnId, privacy: .public)"
            )
            return .resolved(tempConnId)
        }
        // More than one in flight and the event named neither of them.
        _ = contactId
        return .ambiguous(pending.count)
    }

    /// Call `IdentityMappingStore` to complete the atomic upgrade, then notify `PopopxMessageRouter` to migrate. The store write
    /// happens first and alone: if it moves nothing, the router is not asked to move anything either,
    /// so a failed or redundant upgrade cannot re-file queue entries under a contact that never was
    /// ours.
    private func upgrade(
        tempConnId: Int64,
        contactId: Int64,
        event: PopopxChatSessionEvent
    ) async -> PopopxSessionUpgradeResult {
        let movedBindings: Int
        do {
            movedBindings = try await store.upgradePendingConnection(
                tempConnId: tempConnId,
                toFinalContactId: contactId
            )
        } catch {
            // IdentityMappingError is a storage refusal, not a chat failure: the pending connection
            // stays as it is and the next `contactSndReady` tries again. The app's bus never learns
            // any of this happened.
            PopopxMeshLog.store.error(
                "❌ upgrade :\(tempConnId, privacy: .public) → @\(contactId, privacy: .public) refused: \(String(describing: error), privacy: .public)"
            )
            return .noPendingConnection(contactId: contactId)
        }
        guard movedBindings > 0 else {
            return .noPendingConnection(contactId: contactId)
        }
        // Module 6 → module 5: the ids themselves never change, only the address they are filed under.
        let migration = await router.migrateQueuedMessages(
            fromTempConnId: tempConnId,
            toContactId: contactId
        )
        // A message queued *because the contact did not exist yet* has no reason to wait for a network
        // edge that may never come — an upgrade is proof the public path is already working. The flush
        // answers 0 when there is no path, so offline peers keep their backlog for
        // `flushPendingMessagesOnNetworkRestore()`.
        let flushed = migration.isEmpty ? 0 : await router.flushPendingMessagesOnNetworkRestore()
        // The unbound-stranger hint just stopped being true for this peer.
        await router.refreshStatus(afterUpgradeContact: contactId)
        let meshPublicKeyHexes = await store.meshPublicKeyHexes(forContactId: contactId)
        await postUpgradeNotification(
            contactId: contactId,
            tempConnId: tempConnId,
            movedBindings: movedBindings,
            migration: migration,
            flushed: flushed,
            meshPublicKeyHexes: meshPublicKeyHexes,
            userRef: event.userRef
        )
        PopopxMeshLog.offline.notice(
            "⬆️ :\(tempConnId, privacy: .public) → @\(contactId, privacy: .public): \(movedBindings, privacy: .public) binding(s), queued=\(migration.movedQueuedMessages, privacy: .public) records=\(migration.movedOfflineRecords, privacy: .public) flushed=\(flushed, privacy: .public)"
        )
        return .upgraded(
            tempConnId: tempConnId,
            contactId: contactId,
            movedBindings: movedBindings,
            migration: migration,
            flushedMessages: flushed
        )
    }

    private func postUpgradeNotification(
        contactId: Int64,
        tempConnId: Int64,
        movedBindings: Int,
        migration: PopopxMigrationReport,
        flushed: Int,
        meshPublicKeyHexes: [String],
        userRef: String?
    ) async {
        // Only the status read hops actors; the posting itself stays on this task, because a banner
        // that arrives a runloop late is a banner that arrives after the user already sent something.
        let status = await router.currentStatus()
        var userInfo: [String: Any] = [
            Self.statusCodeKey: "upgraded",
            Self.contactIdKey: contactId,
            Self.tempConnIdKey: tempConnId,
            Self.movedBindingsKey: movedBindings,
            Self.movedQueuedMessagesKey: migration.movedQueuedMessages,
            Self.movedOfflineRecordsKey: migration.movedOfflineRecords,
            Self.flushedMessagesKey: flushed,
            Self.meshPublicKeyHexesKey: meshPublicKeyHexes,
        ]
        if let userRef { userInfo[Self.userRefKey] = userRef }
        if let displayText = status.displayText { userInfo[Self.statusTextKey] = displayText }
        NotificationCenter.default.post(
            name: Self.upgradeNotification,
            object: nil,
            userInfo: userInfo
        )
    }

    private func remember(_ event: PopopxChatSessionEvent, result: PopopxSessionUpgradeResult) {
        handled[event] = result
        guard handled.count > Self.maxRememberedEvents else { return }
        let drop = handled.count - Self.maxRememberedEvents
        // No timestamps on an event this package does not own, so the dictionary's own order is as
        // good a replacement policy as any and the cache cannot grow with the bus. The event being
        // remembered is skipped: a cap that evicted the answer it is caching would be absurd.
        for key in Array(handled.keys).filter({ $0 != event }).prefix(drop) {
            handled[key] = nil
        }
    }
}
