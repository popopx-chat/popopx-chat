//
//  PopopxEventObserverTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Module 6: the automatic session upgrade once online. The bypass is mounted on a fake of the app's event bus and a real module 5
//  router over a real module 1 store, so what these cases prove is the three things that actually matter
//  about a read-only observer: it upgrades the right pending connection and only that one, it moves
//  what the router had filed under the temporary id, and it changes nothing about the events the
//  app's own consumer is still receiving.
//
//  The idempotence cases are the ones a careless implementation loses: `contactConnected` and
//  `contactSndReady` both name the same peer, so a second upgrade would run over a row that is
//  already a contact, and a second notification would make a chat page animate twice for one pairing.
//

import Foundation
import PopopxMeshKit
import Testing

/// The app's event bus, as module 6 sees it: every consumer gets its own stream, and pushing an event
/// reaches all of them. That is the property the read-only claim rests on.
actor FakeChatFeed: PopopxChatEventFeeding {
    private var continuations: [AsyncStream<PopopxChatSessionEvent>.Continuation] = []
    private(set) var subscriptionCount = 0

    func sessionEvents() -> AsyncStream<PopopxChatSessionEvent> {
        let (stream, continuation) = AsyncStream<PopopxChatSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        continuations.append(continuation)
        subscriptionCount += 1
        return stream
    }

    func push(_ event: PopopxChatSessionEvent) {
        for continuation in continuations { continuation.yield(event) }
    }

    func finishAll() {
        for continuation in continuations { continuation.finish() }
        continuations.removeAll()
    }
}

@Suite(.serialized)
struct PopopxEventObserverTests {
    // MARK: - The upgrade itself

    @Test("contactConnected upgrades the pending connection module 2 created")
    func contactConnectedUpgradesBinding() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa11")
        _ = try await store.bind(tempConnId: 400, meshPublicKeyHex: hex, nickname: "Ada")
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        let result = await observer.observe(
            PopopxChatSessionEvent(kind: .contactConnected, contactId: 900, tempConnId: 400, peerMeshPublicKeyHex: hex)
        )
        #expect(result == .upgraded(
            tempConnId: 400,
            contactId: 900,
            movedBindings: 1,
            migration: PopopxMigrationReport(),
            flushedMessages: 0
        ))
        // Module 1's row: the mesh key now resolves to a contact, and the temporary id is gone.
        let row = try #require(await store.mapping(forMeshPublicKeyHex: hex))
        #expect(row.contactId == 900)
        #expect(row.tempConnId == nil)
        #expect(row.isPending == false)
        #expect(await store.contactId(forMeshPublicKeyHex: hex) == 900)
        #expect(await store.pendingMappings(forTempConnId: 400).isEmpty)
        // The nickname survived the upgrade: the row moved, the peer did not become somebody else.
        #expect(row.nickname == "Ada")
    }

    @Test("the upgrade migrates the queue filed under the temporary connId")
    func upgradeMigratesQueuedMessages() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa12")
        _ = try await store.bind(tempConnId: 401, meshPublicKeyHex: hex, nickname: nil)
        // Offline, so the two messages the user typed during the pairing land in the queue.
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [], ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        _ = await router.send(PopopxOutboundMessage(messageId: "wait-1", target: .tempConnId(401), text: "the first message"))
        _ = await router.send(PopopxOutboundMessage(messageId: "wait-2", target: .tempConnId(401), text: "the second message"))
        #expect(await router.pendingMessageCount == 2)

        await parts.network.setConnected(true)
        let result = await observer.observe(
            PopopxChatSessionEvent(kind: .contactConnected, contactId: 901, tempConnId: 401, peerMeshPublicKeyHex: hex)
        )
        guard case let .upgraded(_, _, movedBindings, migration, flushed) = result else {
            Issue.record("expected an upgrade, got \(String(reflecting: result))")
            return
        }
        #expect(movedBindings == 1)
        #expect(migration.movedQueuedMessages == 2)
        #expect(migration.movedOfflineRecords == 0)
        // The contact exists now, and the path is up, so the backlog goes out on the spot.
        #expect(flushed == 2)
        #expect(await router.pendingMessageCount == 0)
        #expect(await parts.core.sentMessageIds == ["wait-1", "wait-2"], "migration must not change the ids")
        #expect(await parts.core.contactIds == [901, 901])
    }

    @Test("an offline upgrade migrates the backlog without inventing a public send")
    func upgradeWhileOfflineKeepsBacklogQueued() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa13")
        _ = try await store.bind(tempConnId: 402, meshPublicKeyHex: hex, nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [])
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        _ = await router.send(PopopxOutboundMessage(messageId: "off-1", target: .tempConnId(402), text: "offline backlog"))
        let result = await observer.observe(
            PopopxChatSessionEvent(kind: .contactConnected, contactId: 902, tempConnId: 402, peerMeshPublicKeyHex: hex)
        )
        guard case let .upgraded(_, _, _, migration, flushed) = result else {
            Issue.record("expected an upgrade, got \(String(reflecting: result))")
            return
        }
        #expect(migration.movedQueuedMessages == 1)
        #expect(flushed == 0, "an upgrade with no network must not pretend it sent anything")
        #expect(await parts.core.requests.isEmpty)
        let entry = try #require(await router.unacknowledgedMeshMessages["off-1"])
        #expect(entry.target == .contactId(902))
        #expect(entry.reason == .noNetwork)
        #expect(entry.messageId == "off-1")
    }

    @Test("the upgrade moves the offline records too, so the page shows them on the right contact")
    func upgradeMigratesOfflineRecords() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa14")
        _ = try await store.bind(tempConnId: 403, meshPublicKeyHex: hex, nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        #expect(await router.recordIncoming(
            PopopxMeshOfflineRecord(messageId: "rec-1", target: .tempConnId(403), peerMeshPublicKeyHex: hex, text: "offline peer note")
        ))
        let result = await observer.observe(
            PopopxChatSessionEvent(kind: .contactConnected, contactId: 903, tempConnId: 403, peerMeshPublicKeyHex: hex)
        )
        guard case let .upgraded(_, _, _, migration, _) = result else {
            Issue.record("expected an upgrade, got \(String(reflecting: result))")
            return
        }
        #expect(migration.movedOfflineRecords == 1)
        #expect(await router.offlineRecords(for: .contactId(903)).count == 1)
        #expect(await router.offlineRecords(for: .tempConnId(403)).isEmpty)
        #expect(await router.offlineRecords(for: .contactId(903)).first?.messageId == "rec-1")
    }

    // MARK: - The read-only bypass

    @Test("the bypass takes its own subscription and leaves the app's consumer untouched")
    func observerDoesNotStealEvents() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let feed = FakeChatFeed()
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: feed, store: store, router: router)

        // The app's own pump, mounted first — the observer must not displace it.
        let appStream = await feed.sessionEvents()
        let appSide = EventCollector()
        let pump = Task {
            for await event in appStream { appSide.append(event) }
        }
        await observer.startObserving()
        #expect(await observer.isObserving)
        #expect(await feed.subscriptionCount == 2, "one per consumer, not one shared and fought over")

        let noise = PopopxChatSessionEvent.other("contactUpdated")
        await feed.push(noise)
        await feed.push(
            PopopxChatSessionEvent(kind: .contactSndReady, contactId: 910, tempConnId: 410, peerMeshPublicKeyHex: nil)
        )
        try await settled { appSide.count >= 2 }
        #expect(appSide.all.count == 2, "every event still reached the app's consumer")
        #expect(appSide.all.first == noise, "in order, unfiltered, unchanged")
        // The observer saw the same two, and answered the one that is none of its business.
        try await settled { await observer.handledEventCount >= 2 }
        #expect(await observer.result(for: noise) == .ignored(kind: .other(name: "contactUpdated")))

        await observer.stopObserving()
        #expect(await observer.isObserving == false)
        await feed.push(PopopxChatSessionEvent.other("profileReceived"))
        try await settled { appSide.count >= 3 }
        #expect(appSide.count == 3, "unmounting the bypass cannot mute the bus either")
        pump.cancel()
    }

    @Test("startObserving reads the bus and stopObserving ends its own stream")
    func observingTheBusEndToEnd() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa15")
        _ = try await store.bind(tempConnId: 404, meshPublicKeyHex: hex, nickname: nil)
        let feed = FakeChatFeed()
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: feed, store: store, router: router)
        await observer.startObserving()

        let event = PopopxChatSessionEvent(
            kind: .contactConnected,
            contactId: 904,
            tempConnId: 404,
            peerMeshPublicKeyHex: hex,
            userRef: "@home"
        )
        await feed.push(event)
        try await settled { await store.contactId(forMeshPublicKeyHex: hex) == 904 }
        #expect(await observer.result(for: event)?.statusCode == "upgraded")

        // A finished bus means a finished loop, and the handle must not be kept as a dead one.
        await feed.finishAll()
        try await settled { await observer.isObserving == false }
    }

    @Test("a non-upgrade event is looked at and passed over, with nothing written anywhere")
    func unrelatedEventChangesNothing() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa16")
        _ = try await store.bind(tempConnId: 405, meshPublicKeyHex: hex, nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let collector = NotificationCollector()
        collector.observe(PopopxEventObserver.upgradeNotification)
        defer { collector.stop() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        let result = await observer.observe(PopopxChatSessionEvent.other("rcvdMsg"))
        #expect(result == .ignored(kind: .other(name: "rcvdMsg")))
        #expect(result.didChangeState == false)
        #expect(collector.count == 0)
        let row = try #require(await store.mapping(forMeshPublicKeyHex: hex))
        #expect(row.isPending, "an unrelated event must not quietly upgrade a pairing")
        #expect(await router.pendingMessageCount == 0)
    }

    // MARK: - Idempotence

    @Test("contactSndReady after contactConnected is answered, not re-run")
    func secondEventIsAlreadyUpgraded() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa17")
        _ = try await store.bind(tempConnId: 406, meshPublicKeyHex: hex, nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let collector = NotificationCollector()
        collector.observe(PopopxEventObserver.upgradeNotification)
        defer { collector.stop() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        let connected = PopopxChatSessionEvent(kind: .contactConnected, contactId: 906, tempConnId: 406, peerMeshPublicKeyHex: hex)
        #expect(await observer.observe(connected).statusCode == "upgraded")
        let sndReady = PopopxChatSessionEvent(kind: .contactSndReady, contactId: 906, tempConnId: 406, peerMeshPublicKeyHex: hex)
        #expect(await observer.observe(sndReady) == .alreadyUpgraded(contactId: 906))
        #expect(collector.count == 1, "one upgrade, one status bar notification")
        // A re-delivery of the very same event is answered with the same verdict, not a new upgrade.
        #expect(await observer.observe(connected) == .alreadyUpgraded(contactId: 906))
        #expect(collector.count == 1)
        #expect(await store.meshPublicKeyHexes(forContactId: 906) == [hex], "still exactly one binding")
    }

    @Test("an event with no usable contact id is malformed and changes nothing")
    func malformedEventIsRefused() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        _ = try await store.bind(tempConnId: 407, meshPublicKeyHex: meshTestHex("aa18"), nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        #expect(
            await observer.observe(PopopxChatSessionEvent(kind: .contactConnected))
                == .malformed(kind: .contactConnected)
        )
        #expect(
            await observer.observe(PopopxChatSessionEvent(kind: .contactSndReady, contactId: 0, tempConnId: 407))
                == .malformed(kind: .contactSndReady)
        )
        let rows = await store.allMappings()
        #expect(rows.count == 1)
        #expect(rows.first?.isPending == true, "a malformed event must not consume the pending pairing")
    }

    // MARK: - Extracting connId and the real contactId

    @Test("the mesh key alone resolves the pending connection when the bus names no connId")
    func resolvesByMeshKey() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa19")
        _ = try await store.bind(tempConnId: 408, meshPublicKeyHex: hex, nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        let result = await observer.observe(
            PopopxChatSessionEvent(kind: .contactConnected, contactId: 908, peerMeshPublicKeyHex: hex.uppercased())
        )
        #expect(result.statusCode == "upgraded")
        #expect(await store.contactId(forMeshPublicKeyHex: hex) == 908)
    }

    @Test("a single pending connection is matched when the event names neither id")
    func resolvesBySolePendingConnection() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa20")
        _ = try await store.bind(tempConnId: 409, meshPublicKeyHex: hex, nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        let result = await observer.observe(PopopxChatSessionEvent(kind: .contactConnected, contactId: 909))
        #expect(result.statusCode == "upgraded")
        #expect(await store.meshPublicKeyHexes(forContactId: 909) == [hex])
    }

    @Test("two pending connections and no hint is refused, not guessed")
    func ambiguousPendingConnectionsAreRefused() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let first = meshTestHex("aa21")
        let second = meshTestHex("aa22")
        _ = try await store.bind(tempConnId: 410, meshPublicKeyHex: first, nickname: nil)
        _ = try await store.bind(tempConnId: 411, meshPublicKeyHex: second, nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let collector = NotificationCollector()
        collector.observe(PopopxEventObserver.upgradeNotification)
        defer { collector.stop() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        let result = await observer.observe(PopopxChatSessionEvent(kind: .contactConnected, contactId: 911))
        #expect(result == .ambiguous(contactId: 911, pendingCandidateCount: 2))
        #expect(result.didChangeState == false)
        #expect(collector.count == 0)
        // Both pairings are still pending: guessing would have filed one peer under another's id.
        let pendings = await store.allMappings().filter(\.isPending)
        #expect(pendings.count == 2)
        #expect(await store.meshPublicKeyHexes(forContactId: 911).isEmpty)
    }

    @Test("an ordinary online contact with no mesh pairing is left alone")
    func noPendingConnectionIsNotAnError() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let collector = NotificationCollector()
        collector.observe(PopopxEventObserver.upgradeNotification)
        defer { collector.stop() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        let result = await observer.observe(
            PopopxChatSessionEvent(kind: .contactConnected, contactId: 912, tempConnId: nil)
        )
        #expect(result == .noPendingConnection(contactId: 912))
        #expect(collector.count == 0)
        #expect(await store.allMappings().isEmpty)
    }

    // MARK: - The status bar notification

    @Test("the upgrade notification carries the numbers a chat page needs, and the router's banner")
    func upgradeNotificationPayload() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa23")
        _ = try await store.bind(tempConnId: 412, meshPublicKeyHex: hex, nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [])
        defer { parts.openLatches() }
        let collector = NotificationCollector()
        collector.observe(PopopxEventObserver.upgradeNotification)
        defer { collector.stop() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        _ = await router.send(PopopxOutboundMessage(messageId: "n-1", target: .tempConnId(412), text: "one message"))
        #expect(await router.currentStatus() == .queued(messageCount: 1))

        _ = await observer.observe(
            PopopxChatSessionEvent(
                kind: .contactConnected,
                contactId: 913,
                tempConnId: 412,
                peerMeshPublicKeyHex: hex,
                userRef: "@phone"
            )
        )
        #expect(collector.count == 1)
        let payload = collector.payload(0)
        #expect(payload[PopopxEventObserver.statusCodeKey] as? String == "upgraded")
        #expect(payload[PopopxEventObserver.contactIdKey] as? Int64 == 913)
        #expect(payload[PopopxEventObserver.tempConnIdKey] as? Int64 == 412)
        #expect(payload[PopopxEventObserver.movedBindingsKey] as? Int == 1)
        #expect(payload[PopopxEventObserver.movedQueuedMessagesKey] as? Int == 1)
        #expect(payload[PopopxEventObserver.movedOfflineRecordsKey] as? Int == 0)
        #expect(payload[PopopxEventObserver.flushedMessagesKey] as? Int == 0)
        #expect(payload[PopopxEventObserver.meshPublicKeyHexesKey] as? [String] == [hex])
        #expect(payload[PopopxEventObserver.userRefKey] as? String == "@phone")
        // Offline AND nobody in range, so the router's banner is the queued one — the same status the
        // test asserted two lines above, quoted as the page would show it.
        #expect(payload[PopopxEventObserver.statusTextKey] as? String == PopopxRoutingStatus.queued(messageCount: 1).displayText)
    }

    @Test("the stranger banner lifts once the card has arrived")
    func upgradeLiftsTheStrangerBanner() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let stranger = meshTestHex("aa24")
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        _ = await router.send(
            PopopxOutboundMessage(messageId: "s-1", target: .meshPublicKeyHex(stranger), text: "stranger")
        )
        #expect(await router.unboundStrangerStatus() == PopopxMessageRouter.unboundStrangerStatusText)

        _ = try await store.bind(tempConnId: 413, meshPublicKeyHex: stranger, nickname: nil)
        _ = await observer.observe(
            PopopxChatSessionEvent(kind: .contactConnected, contactId: 914, tempConnId: 413, peerMeshPublicKeyHex: stranger)
        )
        #expect(await router.currentStatus() == .smpOnline)
        #expect(await router.unboundStrangerStatus() == nil)
    }

    @Test("the result cache is bounded, so a long-lived bypass cannot grow with the bus")
    func resultCacheIsBounded() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        let last = PopopxChatSessionEvent.other("last-one-here")
        for index in 0..<(PopopxEventObserver.maxRememberedEvents + 40) {
            await observer.observe(.other("event-\(index)"))
        }
        await observer.observe(last)
        #expect(await observer.handledEventCount <= PopopxEventObserver.maxRememberedEvents)
        #expect(await observer.result(for: last) == .ignored(kind: .other(name: "last-one-here")))
    }

    @Test("the two events the observer acts on are named exactly as the app's bus names them")
    func eventNamesMatchTheAppsBus() async throws {
        let sandbox = try MeshTestSandbox(label: "observer")
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }
        let observer = PopopxEventObserver(feed: FakeChatFeed(), store: store, router: router)

        // `AppAPIEvent.name` (Shared/Model/AppAPITypes.swift:1325) spells these exactly this way.
        #expect(PopopxChatSessionEventKind.contactConnected.rawName == "contactConnected")
        #expect(PopopxChatSessionEventKind.contactSndReady.rawName == "contactSndReady")
        #expect(PopopxChatSessionEventKind.contactConnected.isUpgradeCandidate)
        #expect(PopopxChatSessionEventKind.contactSndReady.isUpgradeCandidate)
        #expect(PopopxChatSessionEventKind.other(name: "contactDeleted").isUpgradeCandidate == false)
        #expect(PopopxChatSessionEvent.other("contactDeleted").canonicalPeerKey == nil)
        #expect(await observer.observe(PopopxChatSessionEvent.other("contactDeleted"))
            == .ignored(kind: .other(name: "contactDeleted")))
    }
}

/// Collects the events the app's own consumer receives, so "read-only" is a measured claim.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PopopxChatSessionEvent] = []

    var all: [PopopxChatSessionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func append(_ event: PopopxChatSessionEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
