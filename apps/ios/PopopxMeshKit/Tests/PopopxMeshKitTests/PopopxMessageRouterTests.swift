//
//  PopopxMessageRouterTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Module 5: the seamless all-direction switch and the SMP re-routing hub. Every case is a routing *rule*, not a timing accident: the
//  3-second and 15-second windows are driven through `PopopxRoutingClock`, the public channel through a
//  fake `PopopxSMPChatCore`, the radio through a fake `PopopxBluetoothJudging`, and connectivity
//  through a fake `PopopxConnectivitySource` — so "no ACK inside smpAckTimeout" is proved in
//  milliseconds and cannot pass by sleeping.
//
//  The assertions that matter most are about the `messageId`: minted once, kept across the parallel
//  re-send, the failure re-route and the restore flush, and identical in both channels — because the
//  peer's single `PopopxMeshDeduplicator` entry is the only thing that makes two copies one message.
//  A router that re-minted on retry would deliver everything twice and look entirely healthy doing it.
//
//  The fakes here are internal rather than private: module 6's tests mount a real router on the same
//  fixtures, and a second copy of six fakes would be two chances for them to disagree.
//

import Foundation
import PopopxMeshKit
import Testing

// MARK: - Fixtures

/// The kit's own lock shape, copied here because `Guard` is internal to the library: `NSLock.lock()`
/// is unavailable from a non-isolated `async` body, so every suspension-free critical section in a
/// test goes through this closure instead.
final class TestMutex: @unchecked Sendable {
    private let lock = NSLock()
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// "Not yet" as a value a test can hold. `wait()` parks until `openNow()`, and `openNow()` is
/// synchronous so a test can put it in `defer` and never leave a continuation parked at the end.
final class Latch: @unchecked Sendable {
    private let monitor = TestMutex()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if monitor.withLock({ isOpen }) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            monitor.withLock {
                if isOpen {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }
    }

    func openNow() {
        let parked: [CheckedContinuation<Void, Never>] = monitor.withLock {
            isOpen = true
            let waiting = waiters
            waiters = []
            return waiting
        }
        for continuation in parked { continuation.resume() }
    }

    var parkedCount: Int {
        monitor.withLock { waiters.count }
    }
}

struct FakeSMPError: Error, CustomStringConvertible {
    let description: String
}

/// The chat core, seen through module 2's widened seam. `hold` keeps the ACK from arriving, which is how
/// "no SMP server ACK inside 3 seconds" is produced without waiting three seconds.
actor FakeSMPCore: PopopxSMPChatCore {
    static let foreignMessageId = "ffffffff-ffff-ffff-ffff-ffffffffffff"

    private var hold: Latch?
    private var refuses = false
    private var wrongIdInAck = false
    private var appChatItemIDs: [String: Int64] = [:]
    private(set) var requests: [PopopxSMPSendRequest] = []
    private(set) var pairingCalls = 0

    func setHold(_ hold: Latch?) { self.hold = hold }
    func setRefuses(_ flag: Bool) { refuses = flag }
    func setWrongIdInAck(_ flag: Bool) { wrongIdInAck = flag }
    /// The row ids the host's database would give these messages — what ruling 1's ack field carries.
    func setAppChatItemIDs(_ ids: [String: Int64]) { appChatItemIDs = ids }

    /// Module 2's two methods are part of the same door; the router must never ring them.
    func createOfflineInvite(incognito: Bool) async throws -> PopopxOfflineInvite {
        pairingCalls += 1
        throw FakeSMPError(description: "the router must not start a pairing")
    }

    func acceptOfflineInvite(_ inviteLink: String, incognito: Bool) async throws -> PopopxOfflineAcceptance {
        pairingCalls += 1
        throw FakeSMPError(description: "the router must not accept a pairing")
    }

    func sendTextOverSMP(_ request: PopopxSMPSendRequest) async throws -> PopopxSMPAck {
        requests.append(request)
        if refuses { throw FakeSMPError(description: "no ack") }
        if let hold { await hold.wait() }
        let messageId = wrongIdInAck ? Self.foreignMessageId : request.messageId
        return PopopxSMPAck(
            messageId: messageId,
            contactId: request.contactId,
            appChatItemId: appChatItemIDs[messageId]
        )
    }

    var sentMessageIds: [String] { requests.map(\.messageId) }
    var contactIds: [Int64] { requests.map(\.contactId) }
}

/// The mesh's send side. Records the envelope id, because "the same id went out on the radio too" is
/// the whole promise.
actor FakeOutbound: PopopxMeshOutbound {
    private var refuses = false
    private(set) var sent: [(id: String, body: String, peer: String)] = []
    private(set) var broadcastTexts: [String] = []

    func setRefuses(_ flag: Bool) { refuses = flag }

    var localMeshPublicKeyHex: String { "6c6f63616c" }

    func send(envelope: PopopxMeshEnvelope, to meshPublicKeyHex: String) async throws(PopopxMeshSendError) {
        if refuses {
            throw PopopxMeshSendError(messageId: envelope.id, failure: .noSessionWithPeer)
        }
        #expect(envelope.kind == .text, "the router sends chat text, never a control frame")
        #expect(!envelope.body.isEmpty, "the text travels inside the envelope")
        sent.append((envelope.id, envelope.body, meshPublicKeyHex))
    }

    func sendBroadcast(text: String) async throws(PopopxMeshSendError) {
        broadcastTexts.append(text)
    }

    var sentMessageIds: [String] { sent.map(\.id) }
}

/// Connectivity as the router sees it: one current value, plus edges a test can push.
actor FakeConnectivity: PopopxConnectivitySource {
    private var path: PopopxNetworkPath?
    private var continuations: [AsyncStream<PopopxNetworkPath>.Continuation] = []
    private(set) var startCalls = 0

    func start() { startCalls += 1 }

    func setConnected(_ connected: Bool, interface: PopopxNetworkInterface = .wifi) {
        let next = PopopxNetworkPath(
            isConnected: connected,
            interface: connected ? interface : .none,
            blockage: connected ? .none : .notAvailable
        )
        path = next
        for continuation in continuations { continuation.yield(next) }
    }

    func currentPath() -> PopopxNetworkPath? { path }

    func pathChanges() -> AsyncStream<PopopxNetworkPath> {
        let (stream, continuation) = AsyncStream<PopopxNetworkPath>.makeStream(bufferingPolicy: .unbounded)
        continuations.append(continuation)
        if let path { continuation.yield(path) }
        return stream
    }

    var subscriptionCount: Int { continuations.count }

    /// Ends every stream, the way `NetworkStateMonitor.stop()` does, so a test can prove the router
    /// notices and can subscribe again.
    func finishAllSubscriptions() {
        for continuation in continuations { continuation.finish() }
        continuations.removeAll()
    }
}

/// Module 4's three questions, answered from a dictionary. `reachabilityAsks` is what proves the router
/// asked with `peerReachabilityTimeout` rather than with some other number.
actor FakeBluetoothJudge: PopopxBluetoothJudging {
    private var radio: PopopxBluetoothState = .poweredOn
    private var reachableKeys: Set<String> = []
    private var handler: (@Sendable (PopopxBluetoothDeliveryFailure) async -> Void)?
    private(set) var reachabilityAsks: [(key: String, timeout: TimeInterval)] = []
    private(set) var installCount = 0

    var radioState: PopopxBluetoothState { radio }

    func setRadio(_ state: PopopxBluetoothState) { radio = state }
    func setReachable(_ keys: Set<String>) { reachableKeys = keys }

    func isPeerReachable(publicKey meshPublicKeyHex: String, timeout: TimeInterval) -> Bool {
        reachabilityAsks.append((meshPublicKeyHex, timeout))
        return reachableKeys.contains(meshPublicKeyHex)
    }

    func setDeliveryFailureHandler(_ handler: (@Sendable (PopopxBluetoothDeliveryFailure) async -> Void)?) {
        self.handler = handler
        if handler != nil { installCount += 1 }
    }

    /// The callback module 4 fires when no `BLE_ACK` arrives inside `bleAckTimeout`.
    func deliverFailure(_ failure: PopopxBluetoothDeliveryFailure) async {
        await handler?(failure)
    }

    var hasHandler: Bool { handler != nil }
    var lastAskedTimeout: TimeInterval? { reachabilityAsks.last?.timeout }
    var askedKeys: [String] { reachabilityAsks.map(\.key) }
}

/// Captures `NotificationCenter` postings without a Combine subscription.
///
/// The `object:` filter is not decoration: several routers exist in this process at once, so a
/// collector that watches the notification name alone can be handed another router's status.
final class NotificationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [[AnyHashable: Any]] = []
    private var token: NSObjectProtocol?

    func observe(_ name: Notification.Name, object: Any? = nil) {
        lock.lock()
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { note in
            self.lock.lock()
            self.payloads.append(note.userInfo ?? [:])
            self.lock.unlock()
        }
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return payloads.count
    }

    func payload(_ index: Int) -> [AnyHashable: Any] {
        lock.lock()
        defer { lock.unlock() }
        return index < payloads.count ? payloads[index] : [:]
    }

    func stop() {
        lock.lock()
        let token = self.token
        self.token = nil
        lock.unlock()
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// Collects an `AsyncStream` from a task, the way a status-bar view would.
final class StatusCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [PopopxRoutingStatus] = []

    var all: [PopopxRoutingStatus] {
        lock.lock()
        defer { lock.unlock() }
        return statuses
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return statuses.count
    }

    func append(_ status: PopopxRoutingStatus) {
        lock.lock()
        statuses.append(status)
        lock.unlock()
    }
}

/// One test's own Keychain stand-in and `UserDefaults` suite, so no case reads another's table. The
/// real Keychain would raise a permission dialog on a CI Mac.
final class MeshTestSecrets: PopopxMeshSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    private static func keyed(_ service: String, _ account: String) -> String { service + "\u{1}" + account }

    func data(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[Self.keyed(service, account)]
    }

    func set(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[Self.keyed(service, account)] = data
    }

    func remove(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[Self.keyed(service, account)] = nil
    }

    func removeAll(service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items = items.filter { !$0.key.hasPrefix(service + "\u{1}") }
    }
}

struct MeshTestSandbox {
    let suiteName: String
    let secrets = MeshTestSecrets()

    init(label: String = "router") throws {
        suiteName = "chat.popopx.mesh.\(label).tests.\(UUID().uuidString)"
        guard UserDefaults(suiteName: suiteName) != nil else {
            throw FakeSMPError(description: "UserDefaults suite unavailable")
        }
    }

    func makeStore() throws -> IdentityMappingStore {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FakeSMPError(description: "UserDefaults suite unavailable")
        }
        return IdentityMappingStore(defaults: defaults, secrets: secrets)
    }

    func reset() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}

/// 64 lower-case hex characters, distinguishable per fixture.
func meshTestHex(_ marker: String) -> String {
    let letters = CharacterSet(charactersIn: "0123456789abcdef")
    let cleaned = String(marker.unicodeScalars.filter { letters.contains($0) })
    return String((cleaned + String(repeating: "0", count: 64)).prefix(64))
}

/// Everything a test needs to poke at after `send` returns.
struct RouterParts {
    let core: FakeSMPCore
    let outbound: FakeOutbound
    let network: FakeConnectivity
    let judge: FakeBluetoothJudge
    let deduplicator: PopopxMeshDeduplicator
    /// Non-nil when the ACK is held: open it in `defer`, or a parked `sendTextOverSMP` outlives the test.
    let ackHold: Latch?
    /// Non-nil when the clock's delay is parked: same reason.
    let clockGate: Latch?

    func openLatches() {
        ackHold?.openNow()
        clockGate?.openNow()
    }
}

/// Builds one router over one store.
///
/// `heldACK` with an instant deadline is the "no ACK inside 3 s" world: the window runs out while the
/// server has not answered. `ackInTime` with a parked deadline is the healthy world: the ACK is the
/// only possible answer. Anything else would be a race, and a routing rule proved by a race is not
/// proved.
func makeRouterParts(
    store: IdentityMappingStore,
    online: Bool = true,
    radio: PopopxBluetoothState = .poweredOn,
    reachable: Set<String> = [],
    heldACK: Bool = false,
    ackInTime: Bool = false,
    smpRefuses: Bool = false,
    wrongIdInAck: Bool = false,
    meshRefuses: Bool = false,
    config: PopopxMeshConfig = .default,
    deduplicator: PopopxMeshDeduplicator? = nil,
    queueURL: URL? = nil,
    recordsURL: URL? = nil
) async -> (PopopxMessageRouter, RouterParts) {
    let core = FakeSMPCore()
    let outbound = FakeOutbound()
    let network = FakeConnectivity()
    let judge = FakeBluetoothJudge()
    let ackHold = heldACK ? Latch() : nil
    let clockGate = ackInTime ? Latch() : nil
    let dedup = deduplicator ?? PopopxMeshDeduplicator()

    await core.setHold(ackHold)
    await core.setRefuses(smpRefuses)
    await core.setWrongIdInAck(wrongIdInAck)
    await outbound.setRefuses(meshRefuses)
    await judge.setRadio(radio)
    await judge.setReachable(reachable)
    await network.setConnected(online)

    let clock = PopopxRoutingClock(
        date: { Date.now },
        delay: { _ in
            // Parked forever when the test wants the ACK to be the only answer; a real 0 otherwise,
            // which `PopopxRoutingClock.wall` treats as "the window already ran out".
            if let gate = clockGate { await gate.wait() }
        }
    )
    let router = PopopxMessageRouter(
        core: core,
        outbound: outbound,
        network: network,
        health: judge,
        store: store,
        deduplicator: dedup,
        config: config,
        clock: clock,
        queueURL: queueURL,
        recordsURL: recordsURL
    )
    let parts = RouterParts(
        core: core,
        outbound: outbound,
        network: network,
        judge: judge,
        deduplicator: dedup,
        ackHold: ackHold,
        clockGate: clockGate
    )
    return (router, parts)
}

/// Binds a mesh key to a pending connection and then upgrades it, which is the only way module 1's table
/// can hold "this contactId is also this radio".
func bindAsContact(
    _ store: IdentityMappingStore,
    hex: String,
    tempConnId: Int64,
    contactId: Int64
) async throws {
    _ = try await store.bind(tempConnId: tempConnId, meshPublicKeyHex: hex, nickname: nil)
    let moved = try await store.upgradePendingConnection(tempConnId: tempConnId, toFinalContactId: contactId)
    #expect(moved == 1)
}

/// Module 4's failure value: no BLE_ACK inside `bleAckTimeout`.
func meshFailure(messageId: String, peerHex: String? = nil) -> PopopxBluetoothDeliveryFailure {
    PopopxBluetoothDeliveryFailure(
        messageId: messageId,
        peerMeshPublicKeyHex: peerHex,
        peerIDHex: "aabbccddeeff0011",
        reason: .ackTimeout
    )
}

/// Lets an asynchronous edge (a restore subscription, a status stream) settle without a fixed sleep
/// long enough to hide a real bug.
func settled(_ check: () async -> Bool) async throws {
    for _ in 0..<100 {
        if await check() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

// MARK: - Tests

@Suite(.serialized)
struct PopopxMessageRouterTests {
    // MARK: Scenario A: online → offline / weak-network downgrade

    @Test("Scenario A: online and bound goes over SMP and never touches the radio")
    func onlineBoundUsesSMP() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa01")
        try await bindAsContact(store, hex: hex, tempConnId: 501, contactId: 77)
        let (router, parts) = await makeRouterParts(store: store, online: true, reachable: [hex], ackInTime: true)
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-online", target: .contactId(77), text: "hi")
        )
        #expect(routed.outcome == .smpAcknowledged(contactId: 77))
        #expect(routed.bluetooth == .reachable(peerMeshPublicKeyHex: hex))
        #expect(await parts.core.requests.count == 1)
        #expect(await parts.core.requests.first?.text == "hi")
        #expect(await parts.core.requests.first?.messageId == "id-online")
        #expect(await parts.core.requests.first?.contactId == 77)
        #expect(await parts.outbound.sent.isEmpty, "a healthy public path must not light the radio")
        #expect(await parts.core.pairingCalls == 0, "the router must not start a pairing")
        #expect(await router.pendingMessageCount == 0)
        #expect(await router.currentStatus() == .smpOnline)
    }

    @Test("Scenario A: offline and the peer is on the radio falls back to the mesh")
    func offlineFallsBackToMesh() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa02")
        try await bindAsContact(store, hex: hex, tempConnId: 502, contactId: 78)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [hex])
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-mesh", target: .contactId(78), text: "moved closer")
        )
        #expect(routed.outcome == .meshSent(peerMeshPublicKeyHex: hex))
        #expect(await parts.outbound.sentMessageIds == ["id-mesh"])
        #expect(await parts.core.requests.isEmpty, "no path, so no SMP request at all")
        #expect(await router.currentStatus() == .meshOnly(peerMeshPublicKeyHex: hex))
    }

    @Test("Scenario A rule 1: no SMP ACK in 3s and a reachable peer puts the same id on the mesh too")
    func slowSMPAddsParallelMesh() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa03")
        try await bindAsContact(store, hex: hex, tempConnId: 503, contactId: 79)
        let (router, parts) = await makeRouterParts(store: store, online: true, reachable: [hex], heldACK: true)
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-parallel", target: .contactId(79), text: "weak network")
        )
        #expect(
            routed.outcome == .smpUnacknowledgedMeshParallel(contactId: 79, peerMeshPublicKeyHex: hex),
            "the window measures an ACK, so the SMP send must still be in flight underneath it"
        )
        #expect(await parts.core.sentMessageIds == ["id-parallel"])
        #expect(await parts.outbound.sentMessageIds == ["id-parallel"], "the mesh copy keeps the id")
        #expect(await parts.outbound.sent.first?.peer == hex)
        #expect(await router.currentStatus() == .dualChannel(peerMeshPublicKeyHex: hex))
        #expect(await router.pendingMessageCount == 0, "a parallel send is not a failure")
    }

    @Test("Scenario A: a slow SMP with no mesh to add is reported, not swallowed")
    func slowSMPWithoutMeshStaysUnacknowledged() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa04")
        try await bindAsContact(store, hex: hex, tempConnId: 504, contactId: 80)
        // Reachable set empty: the peer left range, so there is no second channel to add.
        let (router, parts) = await makeRouterParts(store: store, online: true, heldACK: true)
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-slow", target: .contactId(80), text: "public network only")
        )
        #expect(routed.outcome == .smpUnacknowledgedNoMesh(contactId: 80))
        #expect(routed.bluetooth == .peerOutOfRange(peerMeshPublicKeyHex: hex))
        #expect(await parts.outbound.sent.isEmpty)
    }

    @Test("Scenario A: an ACK naming a different id is not an ACK")
    func ackWithForeignIdIsNoAck() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("aa05")
        try await bindAsContact(store, hex: hex, tempConnId: 505, contactId: 81)
        let (router, parts) = await makeRouterParts(
            store: store,
            online: true,
            reachable: [hex],
            heldACK: true,
            wrongIdInAck: true
        )
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-wrong", target: .contactId(81), text: "the wrong id")
        )
        #expect(routed.outcome == .smpUnacknowledgedMeshParallel(contactId: 81, peerMeshPublicKeyHex: hex))
        // The late ACK names somebody else's message: it cannot deliver ours, and must not queue it.
        #expect(await router.unacknowledgedMeshMessages.isEmpty)
        #expect(await parts.core.sentMessageIds == ["id-wrong"])
    }

    // MARK: Scenario B pre-send prediction

    @Test("Pre-send prediction: a peer silent past peerReachabilityTimeout skips Bluetooth")
    func preJudgeSkipsOutOfRangePeer() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("bb01")
        try await bindAsContact(store, hex: hex, tempConnId: 601, contactId: 88)
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-silent", target: .contactId(88), text: "out of range")
        )
        #expect(routed.outcome == .smpAcknowledged(contactId: 88))
        #expect(routed.bluetooth == .peerOutOfRange(peerMeshPublicKeyHex: hex))
        #expect(await parts.outbound.sent.isEmpty, "a peer silent for 15 seconds cannot occupy the send window")
        #expect(await parts.judge.lastAskedTimeout == PopopxMeshConfig.default.peerReachabilityTimeout)
        #expect(await parts.judge.askedKeys == [hex])
    }

    @Test("Pre-send prediction: our own radio off skips Bluetooth")
    func preJudgeSkipsWhenRadioIsOff() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("bb02")
        try await bindAsContact(store, hex: hex, tempConnId: 602, contactId: 89)
        let (router, parts) = await makeRouterParts(
            store: store,
            online: true,
            radio: .poweredOff,
            reachable: [hex],
            ackInTime: true
        )
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-off", target: .contactId(89), text: "Bluetooth is off")
        )
        #expect(routed.outcome == .smpAcknowledged(contactId: 89))
        #expect(routed.bluetooth == .radioUnavailable(.poweredOff))
        #expect(await parts.judge.askedKeys.isEmpty, "a dead radio must not even be asked")
        #expect(await parts.outbound.sent.isEmpty)
    }

    @Test("Pre-send prediction: an unknown mesh key is not bound, so there is no radio to predict about")
    func preJudgeHasNothingToPredictForAStranger() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-unknown", target: .meshPublicKeyHex(meshTestHex("bb03")), text: "stranger")
        )
        #expect(routed.bluetooth == .notBound)
        #expect(await parts.judge.askedKeys.isEmpty)
        #expect(routed.outcome == .refusedUnboundStranger(peerMeshPublicKeyHex: nil))
    }

    // MARK: Scenario B in flight: onBluetoothDeliveryFailed

    @Test("In-flight timeout re-routing: a delivery failure re-sends over SMP with the original messageId")
    func deliveryFailureReroutesKeepingID() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("cc01")
        try await bindAsContact(store, hex: hex, tempConnId: 701, contactId: 99)
        // Offline at send time, so the mesh is the first channel; the failure arrives afterwards.
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [hex], ackInTime: true)
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-ble", target: .contactId(99), text: "Bluetooth first")
        )
        #expect(routed.outcome == .meshSent(peerMeshPublicKeyHex: hex))
        #expect(await parts.core.requests.isEmpty)

        // The path comes back, then BLE_ACK times out at 5 s.
        await parts.network.setConnected(true)
        let outcome = await router.onBluetoothDeliveryFailed(messageId: "id-ble", peerMeshKey: hex)
        #expect(outcome == .smpAcknowledged(contactId: 99))
        let requests = await parts.core.requests
        #expect(requests.map(\.messageId) == ["id-ble"], "re-routing must keep the original messageId")
        #expect(requests.map(\.text) == ["Bluetooth first"])
        #expect(requests.map(\.contactId) == [99])
        #expect(await parts.outbound.sentMessageIds == ["id-ble"], "one Bluetooth copy, one public-network copy, the same id")
        #expect(await router.pendingMessageCount == 0)
    }

    @Test("In-flight re-routing is idempotent: the second failure of one id does not re-send")
    func secondFailureOfSameIDIsDuplicate() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("cc02")
        try await bindAsContact(store, hex: hex, tempConnId: 702, contactId: 100)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [hex], heldACK: true)
        defer { parts.openLatches() }

        _ = await router.send(
            PopopxOutboundMessage(messageId: "id-twice", target: .contactId(100), text: "relay repeated flood")
        )
        await parts.network.setConnected(true)
        let first = await router.onBluetoothDeliveryFailed(messageId: "id-twice", peerMeshKey: hex)
        #expect(first == .smpUnacknowledgedNoMesh(contactId: 100))
        let second = await router.onBluetoothDeliveryFailed(messageId: "id-twice", peerMeshKey: hex)
        #expect(second == .duplicate(messageId: "id-twice"))
        #expect(await parts.core.sentMessageIds == ["id-twice"], "one id may be re-delivered over the public network only once")
    }

    @Test("In flight: a failure for an id this router never journaled re-sends nothing")
    func failureForUnknownIDDoesNothing() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let (router, parts) = await makeRouterParts(store: store, online: true)
        defer { parts.openLatches() }

        let outcome = await router.onBluetoothDeliveryFailed(messageId: "id-ghost", peerMeshKey: meshTestHex("cc03"))
        #expect(outcome == .nothingToReroute(messageId: "id-ghost"))
        #expect(await parts.core.requests.isEmpty)
        #expect(await parts.outbound.sent.isEmpty)
        #expect(await router.pendingMessageCount == 0, "there is no text to queue either")
    }

    @Test("In flight: a failure while offline parks the message in unacknowledgedMeshMessages")
    func failureWhileOfflineQueues() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("cc04")
        try await bindAsContact(store, hex: hex, tempConnId: 704, contactId: 101)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [hex])
        defer { parts.openLatches() }

        _ = await router.send(PopopxOutboundMessage(messageId: "id-park", target: .contactId(101), text: "offline"))
        let outcome = await router.onBluetoothDeliveryFailed(messageId: "id-park", peerMeshKey: hex)
        #expect(outcome == .queuedOffline(.peerUnreachable))
        let queue = await router.unacknowledgedMeshMessages
        #expect(queue.count == 1)
        let parked = try #require(queue["id-park"])
        #expect(parked.messageId == "id-park", "the queue entry is addressed by the same id")
        #expect(parked.text == "offline")
        #expect(parked.peerMeshPublicKeyHex == hex)
        #expect(parked.reason == .peerUnreachable)
        #expect(await parts.core.requests.isEmpty)
    }

    @Test("Module 4 linkage: start() installs the sink once, and one callback re-sends once")
    func failureHandlerInstalledThroughModuleFour() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("cc05")
        try await bindAsContact(store, hex: hex, tempConnId: 705, contactId: 102)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [hex], ackInTime: true)
        defer { parts.openLatches() }

        await router.start()
        #expect(await parts.judge.hasHandler)
        // Repeated starts — the global fuse gets toggled — must not leave two sinks or two re-sends.
        await router.start()
        await router.start()

        _ = await router.send(PopopxOutboundMessage(messageId: "id-sink", target: .contactId(102), text: "linkage"))
        await parts.network.setConnected(true)
        await parts.judge.deliverFailure(meshFailure(messageId: "id-sink", peerHex: hex))
        #expect(await parts.core.sentMessageIds == ["id-sink"], "the sink reached the router at all")
        #expect(await parts.core.requests.count == 1, "one callback, one re-send, however many installs")
        await router.stop()
        #expect(await parts.judge.hasHandler == false, "stop() retracts the sink")
    }

    @Test("Module 4 linkage: a failure that names no mesh key still re-sends to the bound contact")
    func failureWithoutPeerKeyStillResolvesContact() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("cc06")
        try await bindAsContact(store, hex: hex, tempConnId: 706, contactId: 103)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [hex], ackInTime: true)
        defer { parts.openLatches() }

        _ = await router.send(
            PopopxOutboundMessage(messageId: "id-nokey", target: .contactId(103), text: "the relay only knows the wire id")
        )
        await parts.network.setConnected(true)
        // A relay can drop a flood before the sender's key is known, and module 4 still reports it.
        let outcome = await router.onBluetoothDeliveryFailed(messageId: "id-nokey", peerMeshKey: nil)
        #expect(outcome == .smpAcknowledged(contactId: 103))
        #expect(await parts.core.sentMessageIds == ["id-nokey"], "the id is kept even without the peer key")
    }

    // MARK: The pure-offline fallback and the network-restore flush

    @Test("Pure-offline fallback: neither channel can take it, so it waits in unacknowledgedMeshMessages")
    func offlineAndUnreachableQueues() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("dd01")
        try await bindAsContact(store, hex: hex, tempConnId: 801, contactId: 110)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [])
        defer { parts.openLatches() }
        #expect(await router.currentStatus() == .pathUnknown, "no send has happened yet, so nothing is claimed")

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-queue", target: .contactId(110), text: "neither path works")
        )
        #expect(routed.outcome == .queuedOffline(.peerUnreachable))
        #expect(await router.pendingMessageCount == 1)
        #expect(await router.currentStatus() == .queued(messageCount: 1))
        #expect(await parts.core.requests.isEmpty)

        // The same id again must not grow a second entry: that is the retry-safety half of the rule.
        let again = await router.send(
            PopopxOutboundMessage(messageId: "id-queue", target: .contactId(110), text: "neither path works")
        )
        #expect(again.outcome == .duplicate(messageId: "id-queue"))
        #expect(await router.pendingMessageCount == 1)
    }

    @Test("Pure-offline fallback: the mesh refusing the frame queues under meshRefused")
    func meshRefusalQueues() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("dd02")
        try await bindAsContact(store, hex: hex, tempConnId: 802, contactId: 111)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [hex], meshRefuses: true)
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-refused", target: .contactId(111), text: "the frame was refused")
        )
        #expect(routed.outcome == .queuedOffline(.meshRefused))
        #expect(await router.pendingMessageCount == 1)
        #expect(await parts.outbound.sent.isEmpty, "refused means the frame never reached the radio")
    }

    @Test("flushPendingMessagesOnNetworkRestore re-sends the backlog in order, keeping every id")
    func flushReplaysBacklogInOrder() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("dd03")
        try await bindAsContact(store, hex: hex, tempConnId: 803, contactId: 112)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [], ackInTime: true)
        defer { parts.openLatches() }

        _ = await router.send(PopopxOutboundMessage(messageId: "aaa-1", target: .contactId(112), text: "the first message"))
        _ = await router.send(PopopxOutboundMessage(messageId: "aaa-2", target: .contactId(112), text: "the second message"))
        _ = await router.send(PopopxOutboundMessage(messageId: "aaa-3", target: .contactId(112), text: "the third message"))
        #expect(await router.pendingMessageCount == 3)

        await parts.network.setConnected(true)
        #expect(await router.flushPendingMessagesOnNetworkRestore() == 3)
        #expect(await router.pendingMessageCount == 0)
        #expect(await parts.core.sentMessageIds == ["aaa-1", "aaa-2", "aaa-3"], "the flush order = the input order")
        #expect(await parts.core.contactIds == [112, 112, 112])
        #expect(await router.currentStatus() == .smpOnline)
    }

    @Test("flush is a no-op while offline and leaves the queue untouched")
    func flushRefusesWhileOffline() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("dd04")
        try await bindAsContact(store, hex: hex, tempConnId: 804, contactId: 113)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [])
        defer { parts.openLatches() }

        _ = await router.send(PopopxOutboundMessage(messageId: "id-stay", target: .contactId(113), text: "wait here"))
        #expect(await router.flushPendingMessagesOnNetworkRestore() == 0)
        #expect(await router.pendingMessageCount == 1)
        #expect(await parts.core.requests.isEmpty, "a flush must not invent a public request")
        // Asking twice while offline changes nothing either.
        #expect(await router.flushPendingMessagesOnNetworkRestore() == 0)
        #expect(await router.pendingMessageCount == 1)
    }

    @Test("flush keeps a message addressed to an unupgraded connId queued, not lost")
    func flushKeepsPendingConnectionEntries() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("dd05")
        _ = try await store.bind(tempConnId: 805, meshPublicKeyHex: hex, nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [])
        defer { parts.openLatches() }

        // Offline and the peer is out of range, with no contact behind it: queued, not refused — the
        // mesh key exists, so a flush could one day carry it.
        let queued = await router.send(
            PopopxOutboundMessage(messageId: "id-pending", target: .tempConnId(805), text: "not a contact yet")
        )
        // The blocker at send time is the radio, not the missing contact: `.awaitingContactUpgrade` is
        // reserved for a peer with no binding at all, and this one has a mesh key. The label only
        // changes below, once the network is back and the absent contact is the only thing left.
        #expect(queued.outcome == .queuedOffline(.peerUnreachable))

        await parts.network.setConnected(true)
        // Online, but a pending connection has no SMP queue to write to: it stays, with its id.
        #expect(await router.flushPendingMessagesOnNetworkRestore() == 0)
        let entry = try #require(await router.unacknowledgedMeshMessages["id-pending"])
        #expect(entry.reason == .awaitingContactUpgrade)
        #expect(entry.target == .tempConnId(805))
        #expect(entry.text == "not a contact yet")
        #expect(await parts.core.requests.isEmpty)
    }

    @Test("Network-restore flush: start()'s own subscription flushes on the restore edge, unasked")
    func restoreEdgeFlushesAutomatically() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("dd06")
        try await bindAsContact(store, hex: hex, tempConnId: 806, contactId: 114)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [], ackInTime: true)
        defer { parts.openLatches() }
        await router.start()
        defer { await router.stop() }

        _ = await router.send(PopopxOutboundMessage(messageId: "id-edge", target: .contactId(114), text: "the network is back"))
        #expect(await router.pendingMessageCount == 1)

        await parts.network.setConnected(true)
        try await settled { await router.pendingMessageCount == 0 }
        #expect(await parts.core.sentMessageIds == ["id-edge"], "NWPathMonitor's restore edge flushes on its own")
    }

    @Test("a failing flush puts the message back with its original queuedAt and text")
    func failedFlushRequeuesWithoutLosingAnything() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("dd07")
        try await bindAsContact(store, hex: hex, tempConnId: 807, contactId: 115)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [])
        defer { parts.openLatches() }

        _ = await router.send(PopopxOutboundMessage(messageId: "id-back", target: .contactId(115), text: "try again"))
        let before = try #require(await router.unacknowledgedMeshMessages["id-back"])

        // Now online, but the chat core throws: the entry must come back exactly as it was.
        await parts.network.setConnected(true)
        await parts.core.setRefuses(true)
        #expect(await router.flushPendingMessagesOnNetworkRestore() == 0)
        let after = try #require(await router.unacknowledgedMeshMessages["id-back"])
        #expect(after.messageId == before.messageId)
        #expect(after.text == before.text)
        #expect(after.queuedAt == before.queuedAt, "a failed restore must not restart the clock")
        #expect(after.reason == .smpUnacknowledged)
        #expect(await parts.core.sentMessageIds == ["id-back"])
    }

    @Test("the offline queue survives a relaunch through its own file")
    func queuePersistsAcrossRouters() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("dd08")
        try await bindAsContact(store, hex: hex, tempConnId: 808, contactId: 116)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("popopx-router-\(UUID().uuidString)", isDirectory: true)
        let queueURL = directory.appendingPathComponent(PopopxMeshPaths.unacknowledgedQueueName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let (first, firstParts) = await makeRouterParts(store: store, online: false, reachable: [], queueURL: queueURL)
        _ = await first.send(PopopxOutboundMessage(messageId: "id-disk", target: .contactId(116), text: "written to disk"))
        #expect(FileManager.default.fileExists(atPath: queueURL.path))
        firstParts.openLatches()

        // A brand-new router, nothing in memory, reads back what the last run left.
        let (second, secondParts) = await makeRouterParts(
            store: store,
            online: true,
            ackInTime: true,
            queueURL: queueURL
        )
        defer { secondParts.openLatches() }
        await second.start()
        #expect(await second.pendingMessageCount == 1)
        #expect(await second.flushPendingMessagesOnNetworkRestore() == 1)
        #expect(await secondParts.core.sentMessageIds == ["id-disk"])
        #expect(await second.unacknowledgedMeshMessages.isEmpty)
        await second.stop()
    }

    // MARK: - Ruling 1: one message, two ids

    /// What the merged timeline can only learn from here: a flushed message also has a row id in the
    /// host's own database. Losing that pair is what makes the same text show twice after a restore.
    @Test("a flush whose ack names the stored row records the pairing")
    func flushRecordsAppChatItemID() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("df01")
        try await bindAsContact(store, hex: hex, tempConnId: 880, contactId: 180)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [], ackInTime: true)
        defer { parts.openLatches() }
        await parts.core.setAppChatItemIDs(["id-pair": 90_001])

        _ = await router.send(PopopxOutboundMessage(messageId: "id-pair", target: .contactId(180), text: "re-delivered"))
        #expect(await router.pendingMessageCount == 1)
        await parts.network.setConnected(true)
        // `ackInTime` parks the router's SMP deadline so the fake's ACK is the only answer, which is
        // how the other flush-count tests here (`flushReplaysBacklogInOrder`, the written-to-disk one) stay
        // deterministic. On the default 0-delay clock the deadline passes first: the flush reports 0 and
        // re-queues, the late ACK then delivers the message and records the pair, and the assertion
        // below measures the scheduler instead of the rule. That is what the two failures of this test
        // in a full-suite run were; the product behaviour was right both times.
        #expect(await router.flushPendingMessagesOnNetworkRestore() == 1)
        #expect(await parts.core.sentMessageIds == ["id-pair"], "a re-delivery may be handed over only once")
        #expect(await router.recordedFlushedAppChatItemIDs() == ["id-pair": 90_001])
    }

    @Test("an ack for someone else's id names no row")
    func foreignAckRecordsNoPairing() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("df02")
        try await bindAsContact(store, hex: hex, tempConnId: 881, contactId: 181)
        let (router, parts) = await makeRouterParts(store: store, online: true, reachable: [], wrongIdInAck: true)
        defer { parts.openLatches() }
        // The row id is filed under the id the fake will actually answer with, so the only thing that
        // can keep it out of the pairing is the router refusing an ack that named a different message.
        await parts.core.setAppChatItemIDs([FakeSMPCore.foreignMessageId: 90_002])

        _ = await router.send(PopopxOutboundMessage(messageId: "id-foreign", target: .contactId(181), text: "the wrong name"))
        #expect(await router.recordedFlushedAppChatItemIDs().isEmpty)
    }

    @Test("the pairing outlives the queue it came from")
    func pairingSurvivesRelaunchWithEmptyQueue() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("df03")
        try await bindAsContact(store, hex: hex, tempConnId: 882, contactId: 182)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("popopx-pairs-\(UUID().uuidString)", isDirectory: true)
        let queueURL = directory.appendingPathComponent(PopopxMeshPaths.unacknowledgedQueueName)
        defer { try? FileManager.default.removeItem(at: directory) }

        // `ackInTime` for the same reason as `flushRecordsAppChatItemID`: the flush's reported count is
        // only deterministic when the ACK, not the parked deadline, is the answer.
        let (first, firstParts) = await makeRouterParts(
            store: store,
            online: false,
            reachable: [],
            ackInTime: true,
            queueURL: queueURL
        )
        defer { firstParts.openLatches() }
        await firstParts.core.setAppChatItemIDs(["id-keep": 90_003])
        _ = await first.send(PopopxOutboundMessage(messageId: "id-keep", target: .contactId(182), text: "disk pair"))
        await firstParts.network.setConnected(true)
        #expect(await first.flushPendingMessagesOnNetworkRestore() == 1)
        #expect(await first.pendingMessageCount == 0)

        // A second router, empty backlog: the file it reads holds no messages, only the pairing. The
        // queue and its pairs are read by `start()`, so a router that never started knows nothing.
        let (second, secondParts) = await makeRouterParts(store: store, online: true, reachable: [], queueURL: queueURL)
        defer { secondParts.openLatches() }
        await second.start()
        defer { await second.stop() }
        #expect(await second.pendingMessageCount == 0)
        #expect(await second.recordedFlushedAppChatItemIDs() == ["id-keep": 90_003])
    }

    @Test("the pairing list is capped and drops the oldest flush")
    func pairingListIsCappedOldestFirst() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("df04")
        try await bindAsContact(store, hex: hex, tempConnId: 883, contactId: 183)
        let cap = PopopxMessageRouter.maxTrackedFlushedAppItems
        let (router, parts) = await makeRouterParts(store: store, online: true, reachable: [], ackInTime: true)
        defer { parts.openLatches() }
        await parts.core.setAppChatItemIDs(
            Dictionary(uniqueKeysWithValues: (0...cap).map { ("cap-\($0)", Int64(1_000 + $0)) })
        )

        for index in 0...cap {
            _ = await router.send(PopopxOutboundMessage(messageId: "cap-\(index)", target: .contactId(183), text: "message \(index)"))
        }
        try await settled { await router.recordedFlushedAppChatItemIDs().count == cap }
        let kept = await router.recordedFlushedAppChatItemIDs()
        #expect(kept["cap-0"] == nil, "the oldest flush is the one dropped")
        #expect(kept["cap-\(cap)"] == Int64(1_000 + cap), "the newest is kept")
        #expect(kept.count == cap)
    }

    @Test("the queue is capped, and the entries a restore cannot reach are the oldest")
    func queueIsCapped() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("dd09")
        try await bindAsContact(store, hex: hex, tempConnId: 809, contactId: 117)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [])
        defer { parts.openLatches() }

        let overflow = PopopxMessageRouter.maxUnacknowledgedMessages + 8
        for index in 0..<overflow {
            _ = await router.send(
                PopopxOutboundMessage(messageId: String(format: "q-%04d", index), target: .contactId(117), text: "backlog")
            )
        }
        #expect(await router.pendingMessageCount == PopopxMessageRouter.maxUnacknowledgedMessages)
        let pending = await router.pendingMessages()
        #expect(pending.first?.messageId == "q-0008", "the 8 oldest were dropped")
        #expect(pending.last?.messageId == String(format: "q-%04d", overflow - 1))
    }

    // MARK: The unbound-stranger prompt

    @Test("Unbound stranger: no card and no radio yields the prompt's sentence, and nothing was sent")
    func unboundStrangerRefusesWithItsSentence() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let stranger = meshTestHex("ee01")
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [])
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-stranger", target: .meshPublicKeyHex(stranger), text: "who are you?")
        )
        #expect(routed.outcome == .refusedUnboundStranger(peerMeshPublicKeyHex: nil))
        #expect(routed.bluetooth == .notBound)
        #expect(await parts.core.requests.isEmpty)
        #expect(await parts.outbound.sent.isEmpty)
        #expect(await router.pendingMessageCount == 0, "a stranger's message cannot be promised a flush")
        #expect(await router.trackedAttemptCount == 0, "a refusal is not an attempt in flight")

        let status = await router.currentStatus()
        #expect(status == .unboundStranger)
        #expect(
            status.displayText == PopopxMessageRouter.unboundStrangerStatusText,
            "the banner copy is the prompt's sentence, verbatim"
        )
        #expect(status.displayText == PopopxMessageRouter.unboundStrangerStatusText)
        #expect(await router.unboundStrangerStatus() == PopopxMessageRouter.unboundStrangerStatusText)
    }

    @Test("the stranger banner lifts when module 6 says the card arrived")
    func strangerBannerLiftsAfterUpgrade() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let stranger = meshTestHex("ee06")
        let (router, parts) = await makeRouterParts(store: store, online: true, ackInTime: true)
        defer { parts.openLatches() }

        _ = await router.send(
            PopopxOutboundMessage(messageId: "id-stranger-off", target: .meshPublicKeyHex(stranger), text: "who are you?")
        )
        #expect(await router.currentStatus() == .unboundStranger)

        await router.refreshStatus(afterUpgradeContact: 199)
        #expect(await router.currentStatus() == .smpOnline)
        #expect(await router.unboundStrangerStatus() == nil)
    }

    @Test("the status surface replays its first value, then every change, and posts notifications")
    func statusStreamAndNotification() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("ee02")
        try await bindAsContact(store, hex: hex, tempConnId: 901, contactId: 120)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [])
        defer { parts.openLatches() }

        let collector = NotificationCollector()
        collector.observe(PopopxMessageRouter.statusNotification, object: router)
        defer { collector.stop() }

        let seen = StatusCollector()
        let stream = await router.statusChanges()
        let reader = Task {
            for await status in stream {
                seen.append(status)
                if seen.count >= 3 { break }
            }
        }
        try await settled { seen.count >= 1 }
        #expect(seen.all.first == .pathUnknown, "the current value comes before anything has been sent")

        _ = await router.send(PopopxOutboundMessage(messageId: "id-status", target: .contactId(120), text: "backlog"))
        try await settled { seen.count >= 2 }
        #expect(seen.all.contains(.queued(messageCount: 1)))

        _ = await router.send(PopopxOutboundMessage(messageId: "id-status-2", target: .contactId(120), text: "more backlog"))
        try await settled { collector.count >= 2 }
        let firstPayload = collector.payload(0)
        #expect(firstPayload[PopopxMessageRouter.statusCodeKey] as? String == "queued")
        #expect(
            firstPayload[PopopxMessageRouter.statusTextKey] as? String == PopopxRoutingStatus.queued(messageCount: 1).displayText
        )
        reader.cancel()
        await router.stop()
        // `stop()` finishes every stream: a leaked `for await` cannot outlive the router.
        try await settled { await router.statusSubscriptionCount == 0 }
    }

    @Test("a healthy SMP send publishes no banner text at all")
    func onlineStatusHasNoBanner() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("ee03")
        try await bindAsContact(store, hex: hex, tempConnId: 902, contactId: 121)
        let (router, parts) = await makeRouterParts(store: store, online: true, reachable: [hex], ackInTime: true)
        defer { parts.openLatches() }

        _ = await router.send(PopopxOutboundMessage(messageId: "id-quiet", target: .contactId(121), text: "all clear"))
        let status = await router.currentStatus()
        #expect(status == .smpOnline)
        #expect(status.displayText == nil)
        #expect(await router.unboundStrangerStatus() == nil)
    }

    // MARK: Idempotent dedup on the globally unique messageId

    @Test("shouldDeliver answers once per id, from the one deduplicator the system has")
    func shouldDeliverIsIdempotent() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let dedup = PopopxMeshDeduplicator()
        let (first, firstParts) = await makeRouterParts(store: store, deduplicator: dedup)
        let (second, secondParts) = await makeRouterParts(store: store, deduplicator: dedup)
        defer { firstParts.openLatches(); secondParts.openLatches() }

        #expect(await first.shouldDeliver(messageId: "shared-id"))
        #expect(await first.shouldDeliver(messageId: "shared-id") == false)
        // A different router, the same answer: the memory belongs to the deduplicator, not to a router.
        #expect(await second.shouldDeliver(messageId: "shared-id") == false)
        #expect(await second.shouldDeliver(messageId: "brand-new"))
        #expect(await dedup.noteMessage(id: "shared-id") == false)
    }

    @Test("recordIncoming stores an offline message once per id, however it arrived")
    func recordIncomingDeduplicatesByID() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let (router, parts) = await makeRouterParts(store: store, online: true)
        defer { parts.openLatches() }

        let record = PopopxMeshOfflineRecord(
            messageId: "in-1",
            target: .tempConnId(903),
            peerMeshPublicKeyHex: meshTestHex("ee04"),
            text: "received while offline"
        )
        #expect(await router.recordIncoming(record))
        #expect(await router.recordIncoming(record) == false, "the same message must not be stored twice")
        let records = await router.offlineRecords(for: .tempConnId(903))
        #expect(records.count == 1)
        #expect(records.first?.text == "received while offline")
        #expect(records.first?.receivedAt == record.receivedAt)
    }

    @Test("an SMP copy and a mesh copy carry one id, so the peer sees one message")
    func oneIdAcrossChannels() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("ee05")
        try await bindAsContact(store, hex: hex, tempConnId: 904, contactId: 122)
        let dedup = PopopxMeshDeduplicator()
        let (router, parts) = await makeRouterParts(
            store: store,
            online: true,
            reachable: [hex],
            heldACK: true,
            deduplicator: dedup
        )
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-both", target: .contactId(122), text: "concurrent send")
        )
        #expect(routed.outcome == .smpUnacknowledgedMeshParallel(contactId: 122, peerMeshPublicKeyHex: hex))
        let meshIDs = await parts.outbound.sentMessageIds
        let smpIDs = await parts.core.sentMessageIds
        #expect(meshIDs == smpIDs, "both channels must use exactly the same ids")
        // The peer's side of the promise: whichever copy lands first is shown, the other is dropped.
        #expect(await dedup.noteMessage(id: "id-both"))
        #expect(await dedup.noteMessage(id: "id-both") == false)
    }

    @Test("the envelope handed to the mesh quotes the router's id, not a freshly minted one")
    func envelopeIDIsTheRoutersID() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("ee07")
        try await bindAsContact(store, hex: hex, tempConnId: 908, contactId: 123)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [hex])
        defer { parts.openLatches() }

        let routed = await router.send(
            PopopxOutboundMessage(messageId: "id-envelope", target: .contactId(123), text: "envelope")
        )
        #expect(routed.outcome == .meshSent(peerMeshPublicKeyHex: hex))
        let sent = await parts.outbound.sent
        #expect(sent.count == 1)
        #expect(sent.first?.id == "id-envelope")
        #expect(sent.first?.body == "envelope")
    }

    // MARK: Module 6's migration entry point

    @Test("migrateQueuedMessages re-files the backlog and the records, and only the address moves")
    func migrationMovesQueueAndRecords() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("ff01")
        _ = try await store.bind(tempConnId: 905, meshPublicKeyHex: hex, nickname: nil)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [])
        defer { parts.openLatches() }

        _ = await router.send(PopopxOutboundMessage(messageId: "mig-1", target: .tempConnId(905), text: "queued"))
        _ = await router.send(PopopxOutboundMessage(messageId: "mig-2", target: .tempConnId(905), text: "queued as well"))
        _ = await router.recordIncoming(
            PopopxMeshOfflineRecord(
                messageId: "in-mig",
                target: .tempConnId(905),
                peerMeshPublicKeyHex: hex,
                text: "from the peer"
            )
        )

        let report = await router.migrateQueuedMessages(fromTempConnId: 905, toContactId: 200)
        #expect(report.movedQueuedMessages == 2)
        #expect(report.movedOfflineRecords == 1)
        let pending = await router.pendingMessages()
        #expect(pending.map(\.messageId) == ["mig-1", "mig-2"], "the ids do not move, only the address")
        #expect(pending.allSatisfy { $0.target == .contactId(200) })
        #expect(pending.allSatisfy { $0.reason == .noNetwork })
        #expect(await router.offlineRecords(for: .contactId(200)).count == 1)
        #expect(await router.offlineRecords(for: .tempConnId(905)).isEmpty)
        // Nothing left under the temp id, so a second migration is a no-op.
        #expect(await router.migrateQueuedMessages(fromTempConnId: 905, toContactId: 200).isEmpty)
    }

    // MARK: Lifecycle

    @Test("start() observes the path; stop() leaves no timer, no subscription and no hung send")
    func lifecycleRetractsEverything() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("ff02")
        try await bindAsContact(store, hex: hex, tempConnId: 906, contactId: 130)
        let (router, parts) = await makeRouterParts(store: store, online: true, reachable: [hex], ackInTime: true)
        defer { parts.openLatches() }

        await router.start()
        #expect(await router.isObservingNetwork)
        #expect(await parts.network.startCalls >= 1, "the router boots its own connectivity source")
        #expect(await parts.network.subscriptionCount == 1)

        let inflight = Task { await router.sendText("still sending", toContactId: 130) }
        try await settled { await router.outstandingTimerCount == 1 }
        await router.stop()
        #expect(await router.outstandingTimerCount == 0, "no timer may be woken once the fuse is off")
        #expect(await router.isObservingNetwork == false)
        // `send` was parked in the ACK window; stop() must resume it rather than orphan it.
        let routed = await inflight.value
        #expect(routed.messageId.count == 36)

        // An id-less second stop is harmless.
        await router.stop()
    }

    @Test("stop() on a router that was never started is harmless and idempotent")
    func stopWithoutStartIsSafe() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let (router, parts) = await makeRouterParts(store: store, online: true)
        defer { parts.openLatches() }

        await router.stop()
        await router.stop()
        #expect(await router.isObservingNetwork == false)
        #expect(await router.outstandingTimerCount == 0)
        #expect(await parts.judge.hasHandler == false)
        #expect(await router.pendingMessageCount == 0)
    }

    @Test("a router whose stream ended re-subscribes on the next start instead of holding a dead handle")
    func restartAfterStreamFinished() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let (router, parts) = await makeRouterParts(store: store, online: false)
        defer { parts.openLatches() }

        await router.start()
        #expect(await router.isObservingNetwork)
        // The global fuse stopped the monitor, which finished every stream it had handed out.
        await parts.network.finishAllSubscriptions()
        try await settled { await router.isObservingNetwork == false }

        await router.start()
        #expect(await router.isObservingNetwork)
        #expect(await parts.network.subscriptionCount == 1, "the stale stream was replaced, not stacked")
        await router.stop()
    }

    @Test("sendText mints one lower-case UUID id and uses it everywhere")
    func sendTextMintsOneID() async throws {
        let sandbox = try MeshTestSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshTestHex("ff03")
        try await bindAsContact(store, hex: hex, tempConnId: 907, contactId: 140)
        let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [hex])
        defer { parts.openLatches() }

        let routed = await router.sendText("the convenience method", toContactId: 140)
        #expect(routed.target == .contactId(140))
        #expect(routed.outcome == .meshSent(peerMeshPublicKeyHex: hex))
        let minted = routed.messageId
        #expect(minted.count == 36, "a lower-case UUID, the spelling the engine uses")
        #expect(minted == minted.lowercased())
        #expect(await parts.outbound.sentMessageIds == [minted])
        // And it is a per-call mint, not a per-router one.
        #expect(PopopxOutboundMessage.newMessageId() != PopopxOutboundMessage.newMessageId())
    }
}
