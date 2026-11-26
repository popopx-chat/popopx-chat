//
//  PopopxMeshUITestSupport.swift
//  PopopxMeshUITests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Shared doubles. Nothing here opens a radio: every fake stands in for a core actor, and the
//  module's own models take their dependencies by initialiser precisely so a test can be run without
//  touching `PopopxMeshEngine.shared` (whose `init` builds a `CBCentralManager` — a test that used the
//  singleton would be a test that needs Bluetooth).
//

import Foundation
import Testing
@testable import PopopxMeshUI
import PopopxMeshKit

// MARK: - Scratch space

/// A throwaway directory, removed when the test is done. Every filesystem assertion in this suite
/// happens inside one of these, never in a real `Documents/`.
struct PopopxMeshTestDirectory {
    let url: URL

    init(label: String) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("popopx-mesh-ui-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base
    }

    func write(_ text: String, to name: String, size: Int? = nil) throws {
        let payload: Data
        if let size {
            payload = Data((0..<size).map { _ in UInt8(ascii: "A") })
        } else {
            payload = Data(text.utf8)
        }
        try payload.write(to: url.appendingPathComponent(name))
    }

    func contents(of name: String) -> Data? {
        try? Data(contentsOf: url.appendingPathComponent(name))
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// `UserDefaults` for one test. A suite name unique to the run keeps the fuse's persisted key from
/// leaking between tests, or into `.standard`.
func popopxMeshTestDefaults(_ label: String) throws -> UserDefaults {
    let name = "PopopxMeshUITests.\(label).\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        throw PopopxMeshStorageError.writeFailed(path: name, underlying: "no suite")
    }
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - Journal

/// Order, not just outcome, is what most of these tests assert, so every fake writes into one shared
/// journal.
///
/// `@unchecked Sendable`, justified: the only stored state is the array below, and every read and
/// write of it happens between `lock()` and `unlock()`. It is a class rather than an actor because
/// `PopopxPanicWipeRecording`'s methods are synchronous and non-isolated (the module's rule is that a
/// wipe must never await on the thing reporting it), and because tests read the journal from
/// non-isolated places, including assertions made after the subject is gone.
final class PopopxMeshJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// The index of the first entry carrying `marker`, or nil. Ordering assertions read as
    /// "index of X is below index of Y", which is the property actually being tested.
    func index(containing marker: String) -> Int? {
        all.firstIndex(where: { $0.contains(marker) })
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

// MARK: - Fuse doubles

/// Stands in for the engine, the health monitor, the pairing manager and the interface mirror.
actor PopopxMeshFakeComponent: PopopxMeshSwitchable {
    let name: String
    private let journal: PopopxMeshJournal
    private var startCount = 0
    private var stopCount = 0
    private var lastNickname: String?

    init(name: String, journal: PopopxMeshJournal) {
        self.name = name
        self.journal = journal
    }

    func meshSwitchDidTurnOn(nickname: String?) async {
        startCount += 1
        lastNickname = nickname
        journal.record("start:\(name)")
    }

    func meshSwitchDidTurnOff() async {
        stopCount += 1
        journal.record("stop:\(name)")
    }

    var counts: (start: Int, stop: Int) { (startCount, stopCount) }

    var nickname: String? { lastNickname }
}

// MARK: - Panic wipe doubles

/// Records the wipe's steps, and the order the components went down in.
final class PopopxMeshFakeWipeRecorder: PopopxPanicWipeRecording, @unchecked Sendable {
    /// Same lock justification as `PopopxMeshJournal`: the protocol this satisfies is non-isolated and
    /// synchronous by design, so the state has to be guarded rather than actor-isolated.
    private let lock = NSLock()
    private var events: [String] = []

    func panicWipeDidStart(step: PopopxPanicWipeStep) {
        append("start:\(step.rawValue)")
    }

    func panicWipeDidFinish(step: PopopxPanicWipeStep, erasedFileCount: Int) {
        append("finish:\(step.rawValue):\(erasedFileCount)")
    }

    func panicWipeDidFail(_ failure: PopopxPanicWipeFailure, at step: PopopxPanicWipeStep) {
        append("fail:\(step.rawValue)")
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private func append(_ entry: String) {
        lock.lock()
        events.append(entry)
        lock.unlock()
    }
}

actor PopopxMeshFakeKeyBurner: PopopxMeshKeyBurning {
    private let journal: PopopxMeshJournal

    init(journal: PopopxMeshJournal) {
        self.journal = journal
    }

    func burnMeshKeys() async {
        journal.record("burn-keys")
    }
}

actor PopopxMeshFakeMappingEraser: PopopxMeshMappingErasing {
    private let journal: PopopxMeshJournal
    private let failures: [PopopxMeshWipeFailure]
    private(set) var callCount = 0

    init(journal: PopopxMeshJournal, failures: [PopopxMeshWipeFailure] = []) {
        self.journal = journal
        self.failures = failures
    }

    func eraseAllMeshMappings() async -> PopopxMeshWipeReport {
        callCount += 1
        journal.record("erase-mappings")
        return PopopxMeshWipeReport(failures: failures)
    }
}

// MARK: - Settings / banner doubles

actor PopopxMeshFakeBindingStore: PopopxMeshBindingObserving {
    private var policy: MeshPairingPolicy
    private var mappings: [PopopxMeshContactMapping]
    let journal: PopopxMeshJournal
    private(set) var policyWrites: [MeshPairingPolicy] = []
    private(set) var unbindRequests: [String] = []

    init(
        policy: MeshPairingPolicy = .manualConfirm,
        mappings: [PopopxMeshContactMapping] = [],
        journal: PopopxMeshJournal
    ) {
        self.policy = policy
        self.mappings = mappings
        self.journal = journal
    }

    func pairingPolicy() async -> MeshPairingPolicy {
        policy
    }

    func setPairingPolicy(_ policy: MeshPairingPolicy) async {
        // The fake stores what it is told, or a test that writes a policy and reads it back would be
        // asserting the fake instead of the module.
        self.policy = policy
        policyWrites.append(policy)
        journal.record("policy:\(policy.rawValue)")
    }

    func allMappings() async -> [PopopxMeshContactMapping] {
        mappings
    }

    @discardableResult
    func unbind(meshPublicKeyHex: String) async throws(IdentityMappingError) -> Bool {
        unbindRequests.append(meshPublicKeyHex)
        journal.record("unbind:\(meshPublicKeyHex.prefix(6))")
        mappings.removeAll { $0.meshPublicKeyHex == meshPublicKeyHex }
        return true
    }

    /// Lets a test see what the policy write actually did, without reading the module's own copy.
    func recordedPolicyWrites() -> [MeshPairingPolicy] {
        policyWrites
    }
}

actor PopopxMeshFakePairing: PopopxMeshPairingControlling, PopopxMeshPairingForgetting {
    private let journal: PopopxMeshJournal
    private var requests: [PopopxPairingRequest]
    private var states: [String: MeshPairingState]
    /// The real manager's `forget` unbinds the mapping as its last step, so the double does too —
    /// otherwise a settings test that went through `forget` would read an unchanged store and assert
    /// the fake's memory instead of the module's measurement.
    private let bindingStore: PopopxMeshFakeBindingStore?
    private(set) var declines: [String] = []
    private(set) var approvals: [String] = []
    private(set) var forgotten: [String] = []

    init(
        journal: PopopxMeshJournal,
        requests: [PopopxPairingRequest] = [],
        states: [String: MeshPairingState] = [:],
        bindingStore: PopopxMeshFakeBindingStore? = nil
    ) {
        self.journal = journal
        self.requests = requests
        self.states = states
        self.bindingStore = bindingStore
    }

    func pendingRequests() async -> [PopopxPairingRequest] {
        requests
    }

    func state(for peerMeshPublicKeyHex: String) async -> MeshPairingState {
        states[peerMeshPublicKeyHex] ?? .unlinked
    }

    @discardableResult
    func approve(_ request: PopopxPairingRequest) async throws(PopopxPairingError) -> PopopxOfflineAcceptance {
        approvals.append(request.peerMeshPublicKeyHex)
        journal.record("approve:\(request.peerMeshPublicKeyHex.prefix(6))")
        requests.removeAll { $0.id == request.id }
        states[request.peerMeshPublicKeyHex] = .paired
        return PopopxOfflineAcceptance(tempConnId: 42, kind: .confirmation)
    }

    func decline(_ request: PopopxPairingRequest) async {
        declines.append(request.peerMeshPublicKeyHex)
        journal.record("decline:\(request.peerMeshPublicKeyHex.prefix(6))")
        requests.removeAll { $0.id == request.id }
        states[request.peerMeshPublicKeyHex] = .unlinked
    }

    func forget(_ peerMeshPublicKeyHex: String) async {
        forgotten.append(peerMeshPublicKeyHex)
        journal.record("forget:\(peerMeshPublicKeyHex.prefix(6))")
        states[peerMeshPublicKeyHex] = .unlinked
        _ = try? await bindingStore?.unbind(meshPublicKeyHex: peerMeshPublicKeyHex)
    }

    var answered: (approved: [String], declined: [String], forgotten: [String]) {
        (approvals, declines, forgotten)
    }
}

/// A router that reports whatever a test needs reported.
actor PopopxMeshFakeRouting: PopopxMeshRoutingObserving {
    private let available: Bool
    private let relayIDs: Set<String>
    private let bound: Set<String>
    private let flushedAppIDs: [String: Int64]

    init(
        available: Bool = false,
        relayIDs: Set<String> = [],
        bound: Set<String> = [],
        flushedAppIDs: [String: Int64] = [:]
    ) {
        self.available = available
        self.relayIDs = relayIDs
        self.bound = bound
        self.flushedAppIDs = flushedAppIDs
    }

    func isPublicNetworkAvailable() async -> Bool {
        available
    }

    func pendingRelayMessageIDs() async -> Set<String> {
        relayIDs
    }

    func flushedAppChatItemIDs() async -> [String: Int64] {
        flushedAppIDs
    }

    func isContactBound(forMeshPublicKeyHex meshPublicKeyHex: String) async -> Bool {
        bound.contains(meshPublicKeyHex)
    }
}

/// The outbound contract, so the plaza can be tested without an engine.
actor PopopxMeshFakeOutbound: PopopxMeshOutbound {
    private let journal: PopopxMeshJournal
    private let rejection: PopopxMeshSendFailure?
    private(set) var broadcasts: [String] = []

    init(journal: PopopxMeshJournal, rejection: PopopxMeshSendFailure? = nil) {
        self.journal = journal
        self.rejection = rejection
    }

    var localMeshPublicKeyHex: String {
        get async { String(repeating: "a", count: 64) }
    }

    func send(envelope: PopopxMeshEnvelope, to meshPublicKeyHex: String) async throws(PopopxMeshSendError) {
        journal.record("send:\(envelope.id.prefix(6))")
        if let rejection {
            throw PopopxMeshSendError(messageId: envelope.id, failure: rejection)
        }
    }

    func sendBroadcast(text: String) async throws(PopopxMeshSendError) {
        broadcasts.append(text)
        journal.record("broadcast:\(text)")
        if let rejection {
            throw PopopxMeshSendError(messageId: "broadcast", failure: rejection)
        }
    }

    var sentBroadcasts: [String] { broadcasts }
}

// MARK: - Group doubles

/// In-memory Keychain, one per test device: a group's epoch key and its signing identity live here, so
/// no UI test reads or writes the device's real items.
///
/// Shared `service\0account` namespace, exactly as `PopopxMeshKeychain` keys its items, because a fake
/// that flattened the two into one dictionary would let a group key answer a signing-identity read.
final class PopopxMeshFakeSecrets: PopopxMeshSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    private static func entry(_ service: String, _ account: String) -> String {
        service + "\u{1}" + account
    }

    func data(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[Self.entry(service, account)]
    }

    func set(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[Self.entry(service, account)] = data
    }

    func remove(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[Self.entry(service, account)] = nil
    }

    func removeAll(service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        for stored in items.keys where stored.hasPrefix(service + "\u{1}") {
            items[stored] = nil
        }
    }

    func heldCount(service: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return items.keys.filter { $0.hasPrefix(service + "\u{1}") }.count
    }
}

/// The group send side as the interface sees it: the real coordinator and the real store over a
/// temporary directory and a test Keychain, and no radio.
///
/// Not a stub list on purpose. 缺陷 1's standard is that a created group SURVIVES, and that is only a
/// claim about persistence if the layer under the model really persists — a fake that returned an array
/// it was handed would let the test assert the fake. `groupReads` counts the reads instead of hiding
/// them, which is how a test tells 「读一次并留住」 apart from 「每次 body 重算都重读」.
actor PopopxMeshFakeGroupOutbound: PopopxMeshGroupOutbound {
    private let coordinator: PopopxGroupCoordinator
    private let journal: PopopxMeshJournal
    private(set) var groupReads = 0
    private(set) var sentTexts: [String] = []
    /// Set to make the Kit refuse, so a failure copy can be reached without a radio.
    private(set) var refusal: PopopxMeshGroupError?

    init(coordinator: PopopxGroupCoordinator, journal: PopopxMeshJournal) {
        self.coordinator = coordinator
        self.journal = journal
    }

    var localSigningPublicKeyHex: String? {
        get async { await coordinator.localSigningPublicKeyHex }
    }

    func meshGroups() async -> [PopopxMeshGroup] {
        groupReads += 1
        journal.record("read-groups")
        return await coordinator.groups()
    }

    func meshGroupMembers(of groupID: Data) async -> [PopopxMeshGroupMember] {
        await coordinator.members(of: groupID)
    }

    func createGroup(named name: String) async throws(PopopxMeshGroupError) -> PopopxMeshGroup {
        if let refusal { throw refusal }
        return try await coordinator.createGroup(named: name)
    }

    func invite(
        peerMeshPublicKeyHex: String,
        toGroupID groupID: Data
    ) async throws(PopopxMeshGroupError) -> PopopxGroupDistribution {
        if let refusal { throw refusal }
        return try await coordinator.invite(peerMeshPublicKeyHex: peerMeshPublicKeyHex, toGroupID: groupID)
    }

    func removeMeshGroupMember(
        _ peerMeshPublicKeyHex: String,
        fromGroupID groupID: Data
    ) async throws(PopopxMeshGroupError) -> PopopxGroupDistribution {
        if let refusal { throw refusal }
        return try await coordinator.removeMember(peerMeshPublicKeyHex, fromGroupID: groupID)
    }

    func sendGroupMessage(_ text: String, toGroupID groupID: Data) async throws(PopopxMeshGroupError) {
        if let refusal { throw refusal }
        // The coordinator publishes the local copy on the device's own group hub, so the model sees the
        // bubble the same way it sees a neighbour's: through the stream, not through a return value.
        _ = try await coordinator.sealMessage(text, toGroupID: groupID)
        sentTexts.append(text)
    }

    func invitableMeshPeers() async -> [String] {
        await coordinator.invitablePeers()
    }

    /// Arms a refusal, so the model's failure copy can be reached without a radio or a broken Keychain.
    func setRefusal(_ failure: PopopxMeshGroupError?) {
        refusal = failure
    }

    var recordedReads: Int { groupReads }
    var recordedSends: [String] { sentTexts }
}

/// One test device's group stack, built the way the app builds its own — engine backend, state source
/// and hub replaced by the test's copies, the store and coordinator left real.
struct PopopxMeshGroupDevice {
    let secrets: PopopxMeshFakeSecrets
    let directory: PopopxMeshTestDirectory
    let groupHub: PopopxMeshGroupEventHub
    let store: PopopxGroupStore
    let coordinator: PopopxGroupCoordinator
    let outbound: PopopxMeshFakeGroupOutbound
    let meshPublicKeyHex: String

    private init(
        secrets: PopopxMeshFakeSecrets,
        directory: PopopxMeshTestDirectory,
        groupHub: PopopxMeshGroupEventHub,
        store: PopopxGroupStore,
        coordinator: PopopxGroupCoordinator,
        outbound: PopopxMeshFakeGroupOutbound,
        meshPublicKeyHex: String
    ) {
        self.secrets = secrets
        self.directory = directory
        self.groupHub = groupHub
        self.store = store
        self.coordinator = coordinator
        self.outbound = outbound
        self.meshPublicKeyHex = meshPublicKeyHex
    }

    /// A device that has never run: its own temporary directory, its own Keychain, its own hub.
    static func make(journal: PopopxMeshJournal, label: String = "device") throws -> PopopxMeshGroupDevice {
        let secrets = PopopxMeshFakeSecrets()
        let directory = try PopopxMeshTestDirectory(label: label)
        return Self.build(
            journal: journal,
            secrets: secrets,
            directory: directory,
            groupHub: PopopxMeshGroupEventHub(),
            meshPublicKeyHex: PopopxMeshIdentity.generate().meshPublicKeyHex
        )
    }

    /// The same directory and the same Keychain behind a new stack: what the app holds when it is
    /// relaunched, because a fresh `PopopxGroupStore` has loaded nothing until it is read.
    func relaunched(journal: PopopxMeshJournal) -> PopopxMeshGroupDevice {
        Self.build(
            journal: journal,
            secrets: secrets,
            directory: directory,
            groupHub: groupHub,
            meshPublicKeyHex: meshPublicKeyHex
        )
    }

    private static func build(
        journal: PopopxMeshJournal,
        secrets: PopopxMeshFakeSecrets,
        directory: PopopxMeshTestDirectory,
        groupHub: PopopxMeshGroupEventHub,
        meshPublicKeyHex: String
    ) -> PopopxMeshGroupDevice {
        let store = PopopxGroupStore(secrets: secrets, directory: directory.url)
        let coordinator = PopopxGroupCoordinator(
            meshPublicKeyHex: meshPublicKeyHex,
            secrets: secrets,
            store: store,
            hub: groupHub
        )
        return PopopxMeshGroupDevice(
            secrets: secrets,
            directory: directory,
            groupHub: groupHub,
            store: store,
            coordinator: coordinator,
            outbound: PopopxMeshFakeGroupOutbound(coordinator: coordinator, journal: journal),
            meshPublicKeyHex: meshPublicKeyHex
        )
    }

    func remove() {
        directory.remove()
    }
}

// MARK: - Waiting

/// Waits for a condition the module drives asynchronously (a pump task, a Combine assignment).
/// Bounded, so a broken pipeline fails the test instead of hanging it.
///
/// `@MainActor` on purpose: the banner/settings models under test are main-actor types, and a
/// nonisolated helper would turn every `condition` closure into a value sent across isolation
/// domains — Swift 6 rejects reading e.g. `model.radioState` from inside one.
@MainActor
func popopxMeshWaitUntil(
    _ description: String,
    ticks: Int = 200,
    condition: () async -> Bool
) async throws {
    for _ in 0..<ticks {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("timed out waiting for \(description)")
}

// MARK: - Fixtures

enum PopopxMeshTestKeys {
    /// 64 hex characters, the shape `PopopxMeshControlFrame.isMeshPublicKey` insists on.
    static func hex(_ letter: String, count: Int = 64) -> String {
        precondition(letter.count == 1, "a key is one repeated hex digit")
        return String(repeating: letter, count: count)
    }

    /// The 8-byte wire id, as the mesh spells it.
    static func peerIDHex(_ letter: String) -> String {
        hex(letter, count: 16)
    }

    static let peerA = hex("a")
    static let peerB = hex("b")
    static let peerC = hex("c")

    static func request(for peer: String, link: String = "popopx://invite/test") -> PopopxPairingRequest {
        PopopxPairingRequest(peerMeshPublicKeyHex: peer, inviteLink: link, receivedAt: .now)
    }

    static func mapping(for peer: String, contactId: Int64? = 7, nickname: String? = nil) -> PopopxMeshContactMapping {
        PopopxMeshContactMapping(
            meshPublicKeyHex: peer,
            contactId: contactId,
            tempConnId: contactId == nil ? 11 : nil,
            nickname: nickname
        )
    }
}
