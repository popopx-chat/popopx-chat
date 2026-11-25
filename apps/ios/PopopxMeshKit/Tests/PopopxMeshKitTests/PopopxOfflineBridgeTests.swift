//
//  PopopxOfflineBridgeTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Module 1 and module 2 together: the mapping table under a fake Keychain (the real one would raise a
//  permission dialog on a CI Mac) and the offline door under a fake chat core. Every assertion that
//  matters is about what is *not* left behind — a half-applied upgrade, a binding with no contact,
//  a link that reached the FFI unvalidated, a wipe that stopped at the first error.
//

import Foundation
import PopopxMeshKit
import Testing

private struct FakeSecretError: Error, CustomStringConvertible {
    let description: String
}

private struct FakeCoreError: Error, CustomStringConvertible {
    let description: String = "chat core refused"
}

/// In-memory stand-in for the Keychain, with the two failure switches the rollback tests need.
private final class FakeSecrets: PopopxMeshSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var setCalls = 0
    private var refusedSetCalls: Set<Int> = []
    private var refusesRemoveAll = false

    private static func key(_ service: String, _ account: String) -> String { service + "\u{1}" + account }

    func data(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[Self.key(service, account)]
    }

    func set(_ data: Data, service: String, account: String) throws {
        lock.lock()
        setCalls += 1
        let call = setCalls
        lock.unlock()
        if refusedSetCalls.contains(call) {
            throw FakeSecretError(description: "keychain set refused")
        }
        lock.lock()
        items[Self.key(service, account)] = data
        lock.unlock()
    }

    func remove(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[Self.key(service, account)] = nil
    }

    func removeAll(service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if refusesRemoveAll {
            throw FakeSecretError(description: "keychain removeAll refused")
        }
        items = items.filter { !$0.key.hasPrefix(service + "\u{1}") }
    }

    // MARK: Test side

    func prime(payload: Data, service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        items[Self.key(service, account)] = payload
    }

    func payload(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[Self.key(service, account)]
    }

    var storedItemCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    func refuseNextSet() {
        lock.lock()
        defer { lock.unlock() }
        refusedSetCalls.insert(setCalls + 1)
    }

    /// Refuses the next `count` set calls — the second one is the rollback that could not land.
    func refuseNextSets(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        for offset in 1...max(1, count) { refusedSetCalls.insert(setCalls + offset) }
    }

    func refuseRemoveAll(_ flag: Bool) {
        lock.lock()
        defer { lock.unlock() }
        refusesRemoveAll = flag
    }
}

private actor FakeOfflineCore: PopopxOfflineChatCore {
    var inviteLinkToReturn = "https://popopx.chat/contact#/?v=2&smp=smp%3A%2F%2FAAAA%40relay.example"
    var nextTempConnId: Int64 = 700
    var acceptanceKind: PopopxOfflineAcceptance.Kind = .confirmation
    var refuses = false
    private(set) var createdIncognito: [Bool] = []
    private(set) var acceptedLinks: [String] = []

    // An actor's stored properties cannot be assigned from outside, so the fixtures set them here.
    func setRefuses(_ flag: Bool) { refuses = flag }
    func setAcceptanceKind(_ kind: PopopxOfflineAcceptance.Kind) { acceptanceKind = kind }

    func createOfflineInvite(incognito: Bool) async throws -> PopopxOfflineInvite {
        createdIncognito.append(incognito)
        if refuses { throw FakeCoreError() }
        let id = nextTempConnId
        nextTempConnId += 1
        return PopopxOfflineInvite(inviteLink: inviteLinkToReturn, tempConnId: id)
    }

    func acceptOfflineInvite(_ inviteLink: String, incognito: Bool) async throws -> PopopxOfflineAcceptance {
        acceptedLinks.append(inviteLink)
        if refuses { throw FakeCoreError() }
        let id = nextTempConnId
        nextTempConnId += 1
        return PopopxOfflineAcceptance(tempConnId: id, kind: acceptanceKind)
    }
}

/// One test's own defaults suite plus its own fake Keychain, so no case reads another's switches.
private struct MeshSandbox {
    let suiteName: String
    let secrets: FakeSecrets

    init() throws {
        suiteName = "chat.popopx.mesh.tests.\(UUID().uuidString)"
        guard UserDefaults(suiteName: suiteName) != nil else {
            throw FakeSecretError(description: "UserDefaults suite unavailable")
        }
        secrets = FakeSecrets()
    }

    /// Each store gets its own `UserDefaults` for the same suite: `UserDefaults` is not `Sendable`,
    /// so one instance cannot be handed to two actors, and the suite — not the instance — is what
    /// the persistence round trip proves.
    func makeStore() throws -> IdentityMappingStore {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FakeSecretError(description: "UserDefaults suite unavailable")
        }
        return IdentityMappingStore(defaults: defaults, secrets: secrets)
    }

    func reset() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}

/// 64 lower-case hex characters, distinguishable per fixture.
private func meshHex(_ marker: String) -> String {
    let letters = CharacterSet(charactersIn: "0123456789abcdef")
    let cleaned = String(marker.unicodeScalars.filter { letters.contains($0) })
    return String((cleaned + String(repeating: "0", count: 64)).prefix(64))
}

private func makeMeshCacheFiles(in documents: URL) throws -> URL {
    let directory = documents.appendingPathComponent(PopopxMeshPaths.directoryName, isDirectory: true)
    let nested = directory.appendingPathComponent("relay", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(#"{"queue":[]}"#.utf8).write(to: directory.appendingPathComponent(PopopxMeshPaths.unacknowledgedQueueName))
    try Data("outbox".utf8).write(to: directory.appendingPathComponent(PopopxMeshPaths.outboxName))
    try Data("nested".utf8).write(to: nested.appendingPathComponent("inner.json"))
    return directory
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@Suite(.serialized)
struct PopopxOfflineBridgeTests {
    // MARK: - Module 1: switches

    @Test("pairing policy and mesh fuse persist for the next instance")
    func switchesRoundTrip() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let first = try sandbox.makeStore()
        #expect(await first.pairingPolicy == .manualConfirm)
        #expect(await first.meshEnabled == false)

        await first.updatePairingPolicy(.autoSilent)
        await first.updateMeshEnabled(true)

        let second = try sandbox.makeStore()
        #expect(await second.pairingPolicy == .autoSilent)
        #expect(await second.meshEnabled == true)

        await second.updateMeshEnabled(false)
        #expect(try await sandbox.makeStore().meshEnabled == false)
    }

    // MARK: - Module 1: bind, look up, upgrade

    @Test("bind then look up both directions, then upgrade the pending row")
    func bindLookUpAndUpgrade() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshHex("aa11")
        let tempConnId: Int64 = 501

        let bound = try await store.bind(tempConnId: tempConnId, meshPublicKeyHex: hex.uppercased(), nickname: "Ada")
        #expect(bound.meshPublicKeyHex == hex, "upper case folds to the one canonical spelling")
        #expect(bound.isPending)
        #expect(await store.contactId(forMeshPublicKeyHex: hex) == nil)
        #expect(await store.pendingMappings(forTempConnId: tempConnId).count == 1)

        let upgraded = try await store.upgradePendingConnection(tempConnId: tempConnId, toFinalContactId: 900)
        #expect(upgraded == 1)
        #expect(await store.contactId(forMeshPublicKeyHex: hex) == 900)
        #expect(await store.meshPublicKeyHexes(forContactId: 900) == [hex])
        #expect(await store.pendingMappings(forTempConnId: tempConnId).isEmpty)

        let mapping = try #require(await store.mapping(forMeshPublicKeyHex: hex))
        #expect(mapping.tempConnId == nil)
        #expect(mapping.contactId == 900)
        #expect(mapping.nickname == "Ada")
        #expect(!mapping.isPending)

        // Read the same table through a fresh instance: the upgrade is on disk, not just in memory.
        #expect(try await sandbox.makeStore().contactId(forMeshPublicKeyHex: hex) == 900)
        // A second upgrade of the dead temp id is a no-op, not a rebind.
        #expect(try await store.upgradePendingConnection(tempConnId: tempConnId, toFinalContactId: 901) == 0)
        #expect(await store.contactId(forMeshPublicKeyHex: hex) == 900)
    }

    @Test("bind refuses a malformed mesh key instead of storing it")
    func bindRefusesMalformedKey() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()

        let tooShort = "zz" + String(repeating: "0", count: 62)
        await #expect(throws: IdentityMappingError.meshPublicKeyRejected(characterCount: tooShort.count)) {
            _ = try await store.bind(tempConnId: 1, meshPublicKeyHex: tooShort, nickname: nil)
        }
        await #expect(throws: IdentityMappingError.meshPublicKeyRejected(characterCount: 3)) {
            _ = try await store.bind(tempConnId: 1, meshPublicKeyHex: "abc", nickname: nil)
        }
        #expect(await store.allMappings().isEmpty)
        #expect(sandbox.secrets.storedItemCount == 0)
    }

    // MARK: - Module 1: atomic upgrade

    @Test("a refused Keychain write rolls the payload back and leaves the row pending")
    func upgradeRollsBackOnRefusedWrite() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let hex = meshHex("bb22")
        _ = try await store.bind(tempConnId: 600, meshPublicKeyHex: hex, nickname: nil)
        let before = try #require(sandbox.secrets.payload(
            service: IdentityMappingStore.keychainService,
            account: IdentityMappingStore.keychainAccount
        ))

        sandbox.secrets.refuseNextSet()
        await #expect(throws: IdentityMappingError.keychainWriteFailed(reason: "keychain set refused")) {
            _ = try await store.upgradePendingConnection(tempConnId: 600, toFinalContactId: 700)
        }

        #expect(sandbox.secrets.payload(
            service: IdentityMappingStore.keychainService,
            account: IdentityMappingStore.keychainAccount
        ) == before, "the table is byte-for-byte what it was before the failed upgrade")
        let mapping = try #require(await store.mapping(forMeshPublicKeyHex: hex))
        #expect(mapping.contactId == nil)
        #expect(mapping.tempConnId == 600)
        #expect(await store.pendingMappings(forTempConnId: 600).count == 1)

        // The retry that cannot even restore the backup is the one failure the user must hear about.
        sandbox.secrets.refuseNextSets(2)
        await #expect(throws: IdentityMappingError.keychainRollbackFailed(reason: "keychain set refused")) {
            _ = try await store.upgradePendingConnection(tempConnId: 600, toFinalContactId: 700)
        }
    }

    // MARK: - Module 1: one-to-many consistency

    @Test("one contact with two radios: deleting either side updates both indexes")
    func oneToManyDeleteConsistency() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let store = try sandbox.makeStore()
        let first = meshHex("cc33")
        let second = meshHex("dd44")

        _ = try await store.bind(tempConnId: 801, meshPublicKeyHex: first, nickname: nil)
        _ = try await store.bind(tempConnId: 802, meshPublicKeyHex: second, nickname: nil)
        #expect(try await store.upgradePendingConnection(tempConnId: 801, toFinalContactId: 42) == 1)
        #expect(try await store.upgradePendingConnection(tempConnId: 802, toFinalContactId: 42) == 1)
        #expect(await store.meshPublicKeyHexes(forContactId: 42) == [first, second].sorted())

        #expect(try await store.unbind(meshPublicKeyHex: first) == true)
        #expect(await store.meshPublicKeyHexes(forContactId: 42) == [second])
        #expect(await store.contactId(forMeshPublicKeyHex: first) == nil)

        // Deleting the contact takes the last radio with it, and no pending row survives.
        #expect(try await store.unbindAll(forContactId: 42) == 1)
        #expect(await store.allMappings().isEmpty)
        #expect(await store.meshPublicKeyHexes(forContactId: 42).isEmpty)
        #expect(await store.pendingMappings(forTempConnId: 802).isEmpty)
        #expect(try await sandbox.makeStore().allMappings().isEmpty, "the deletion reached the Keychain")
        #expect(try await store.unbind(meshPublicKeyHex: first) == false)
    }

    // MARK: - Module 1: panic wipe

    @Test("panic wipe clears memory, Keychain, switches and cache files")
    func emergencyWipeClearsEverything() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let documents = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let meshDirectory = try makeMeshCacheFiles(in: documents)
        PopopxMeshPaths.setDocumentsDirectory(documents)

        let store = try sandbox.makeStore()
        _ = try await store.bind(tempConnId: 900, meshPublicKeyHex: meshHex("ee55"), nickname: nil)
        await store.updatePairingPolicy(.autoSilent)
        await store.updateMeshEnabled(true)

        let report = await store.emergencyWipeAllMappings()
        #expect(report.isClean)
        #expect(sandbox.secrets.storedItemCount == 0)
        #expect(await store.allMappings().isEmpty)
        #expect(!exists(meshDirectory.appendingPathComponent(PopopxMeshPaths.unacknowledgedQueueName)))
        #expect(!exists(meshDirectory.appendingPathComponent(PopopxMeshPaths.outboxName)))
        #expect(!exists(meshDirectory.appendingPathComponent("relay")), "a subdirectory is cache too")

        let next = try sandbox.makeStore()
        #expect(await next.pairingPolicy == .manualConfirm)
        #expect(await next.meshEnabled == false)
        #expect(await next.allMappings().isEmpty)
        try FileManager.default.removeItem(at: documents)
    }

    @Test("panic wipe keeps going when its first step fails")
    func emergencyWipeContinuesAfterFailure() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let documents = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let meshDirectory = try makeMeshCacheFiles(in: documents)
        PopopxMeshPaths.setDocumentsDirectory(documents)
        sandbox.secrets.refuseRemoveAll(true)

        let store = try sandbox.makeStore()
        _ = try await store.bind(tempConnId: 901, meshPublicKeyHex: meshHex("ff66"), nickname: nil)
        await store.updatePairingPolicy(.autoSilent)
        await store.updateMeshEnabled(true)

        let report = await store.emergencyWipeAllMappings()
        #expect(report.failures == [.keychain(reason: "keychain removeAll refused")])
        #expect(!report.isClean, "a half wipe never claims success")
        // The steps after the failure still ran.
        #expect(!exists(meshDirectory.appendingPathComponent(PopopxMeshPaths.unacknowledgedQueueName)))
        let next = try sandbox.makeStore()
        #expect(await next.pairingPolicy == .manualConfirm)
        #expect(await next.meshEnabled == false)
        try FileManager.default.removeItem(at: documents)
    }

    // MARK: - Module 1: migration safety

    @Test("an undecodable payload is preserved, blocks writes, and is still wipeable")
    func undecodablePayloadIsPreserved() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let garbage = Data("not json at all".utf8)
        sandbox.secrets.prime(
            payload: garbage,
            service: IdentityMappingStore.keychainService,
            account: IdentityMappingStore.keychainAccount
        )
        let store = try sandbox.makeStore()

        #expect(await store.allMappings().isEmpty)
        #expect(await store.storedPayloadIssue == .undecodablePayload(byteCount: garbage.count))
        #expect(await store.preservedPayloadBytes == garbage)

        await #expect(throws: IdentityMappingError.writeBlocked(issue: .undecodablePayload(byteCount: garbage.count))) {
            _ = try await store.bind(tempConnId: 10, meshPublicKeyHex: meshHex("ab12"), nickname: nil)
        }
        #expect(sandbox.secrets.payload(
            service: IdentityMappingStore.keychainService,
            account: IdentityMappingStore.keychainAccount
        ) == garbage, "a table this store cannot read is never overwritten")

        // Panic mode outranks the write block.
        #expect(await store.emergencyWipeAllMappings().isClean)
        #expect(sandbox.secrets.storedItemCount == 0)
    }

    // MARK: - Module 2: prefix gate

    @Test("normalizedInviteLink accepts and canonicalises our own links", arguments: [
        ("popopx:/contact#/?v=2&smp=smp%3A%2F%2FAA%40relay.example", "popopx:/contact#/?v=2&smp=smp%3A%2F%2FAA%40relay.example"),
        ("popopx://contact#/?v=2&smp=smp%3A%2F%2FAA", "popopx:/contact#/?v=2&smp=smp%3A%2F%2FAA"),
        ("https://popopx.chat/contact#/?v=2&smp=smp%3A%2F%2FAA", "popopx:/contact#/?v=2&smp=smp%3A%2F%2FAA"),
        ("popopx:/contact", "popopx:/contact")
    ])
    func acceptedLinks(_ raw: String, _ canonical: String) {
        #expect(PopopxOfflineBridge.normalizedInviteLink(raw) == canonical)
    }

    @Test("normalizedInviteLink rejects everything else", arguments: [
        "simplex:/contact#/?v=2",
        "nostr:npub1l2vyh47mk2p0qlku7llfldmlxcg7srh0qzc9b",
        "http://popopx.chat/contact#/?v=2",
        "https://evil.example/contact#/?v=2",
        "https://popopx.chat.evil.example/contact",
        "https://popopx.chat",
        "popopx:/",
        "popopx://",
        "",
        "popopx:/contact#/?v=2\nhttps://popopx.chat/x",
        "popopx:/contact#/?v=2 smp=smp%3A%2F%2FAA",
        "popopx:/contact#\";rm -rf",
        "popopx:/contäct",
        String(repeating: "a", count: 3_000)
    ])
    func rejectedLinks(_ raw: String) {
        #expect(PopopxOfflineBridge.normalizedInviteLink(raw) == nil)
    }

    // MARK: - Module 2: outbound

    @Test("generating an invite binds the temp connection id to the peer key")
    func generateInviteBindsMapping() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let core = FakeOfflineCore()
        let bridge = PopopxOfflineBridge(core: core, store: try sandbox.makeStore())
        let hex = meshHex("12ab")

        let invite = try await bridge.generateOfflineInviteLink(meshPublicKeyHex: hex, incognito: true)
        #expect(invite.inviteLink == "popopx:/contact#/?v=2&smp=smp%3A%2F%2FAAAA%40relay.example")
        #expect(await core.createdIncognito == [true])

        // A second store over the same fake Keychain: the binding survived the instance that made it.
        let reloaded = try sandbox.makeStore()
        let mapping = try #require(await reloaded.mapping(forMeshPublicKeyHex: hex))
        #expect(mapping.tempConnId == invite.tempConnId)
        #expect(mapping.contactId == nil)
        #expect(mapping.isPending)
    }

    @Test("a malformed mesh key is refused before the chat core is touched")
    func generateRefusesBadKeyBeforeFFI() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let core = FakeOfflineCore()
        let bridge = PopopxOfflineBridge(core: core, store: try sandbox.makeStore())

        let malformed = "nostr:npub1"
        await #expect(throws: PopopxOfflineBridgeError.meshPublicKeyRejected(characterCount: malformed.count)) {
            _ = try await bridge.generateOfflineInviteLink(meshPublicKeyHex: malformed)
        }
        #expect(await core.createdIncognito.isEmpty)
        #expect(try await sandbox.makeStore().allMappings().isEmpty)
    }

    @Test("a core failure is reported without a binding and without the link")
    func generateCoreFailureLeavesNothingBound() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let core = FakeOfflineCore()
        await core.setRefuses(true)
        let bridge = PopopxOfflineBridge(core: core, store: try sandbox.makeStore())

        await #expect(throws: PopopxOfflineBridgeError.coreFailed(reason: "chat core refused")) {
            _ = try await bridge.generateOfflineInviteLink(meshPublicKeyHex: meshHex("34cd"))
        }
        #expect(try await sandbox.makeStore().allMappings().isEmpty)
    }

    @Test("an invite the store cannot bind reports its orphaned temp id for cleanup")
    func generateReportsUnboundInvite() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let garbage = Data("{".utf8)
        sandbox.secrets.prime(
            payload: garbage,
            service: IdentityMappingStore.keychainService,
            account: IdentityMappingStore.keychainAccount
        )
        let core = FakeOfflineCore()
        let store = try sandbox.makeStore()
        let bridge = PopopxOfflineBridge(core: core, store: store)

        var refusal: PopopxOfflineBridgeError?
        do {
            _ = try await bridge.generateOfflineInviteLink(meshPublicKeyHex: meshHex("56ef"))
            Issue.record("the bridge claimed an invite it could not bind")
        } catch {
            refusal = error
        }
        guard case let .inviteUnbound(tempConnId, reason)? = refusal else {
            Issue.record("expected inviteUnbound, got \(String(describing: refusal))")
            return
        }
        #expect(tempConnId == 700, "the pending connection the caller must delete")
        #expect(!reason.contains("popopx:/"))
        #expect(await store.allMappings().isEmpty)
        #expect(await core.createdIncognito.count == 1)
    }

    // MARK: - Module 2: inbound

    @Test("accepting a link normalises it for the core and binds the peer key")
    func acceptLinkNormalisesAndBinds() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let core = FakeOfflineCore()
        await core.setAcceptanceKind(.invitation)
        let store = try sandbox.makeStore()
        let bridge = PopopxOfflineBridge(core: core, store: store)
        let hex = meshHex("78aa")

        let acceptance = try await bridge.acceptOfflineInviteLink(
            "https://popopx.chat/contact#/?v=2&smp=smp%3A%2F%2FBB",
            meshPublicKeyHex: hex,
            incognito: true
        )
        #expect(acceptance.kind == .invitation)
        #expect(await core.acceptedLinks == ["popopx:/contact#/?v=2&smp=smp%3A%2F%2FBB"])

        let mapping = try #require(await store.mapping(forMeshPublicKeyHex: hex))
        #expect(mapping.tempConnId == acceptance.tempConnId)
        #expect(mapping.isPending)
    }

    @Test("accepting without a mesh key still returns the acceptance, unbound")
    func acceptWithoutMeshKeyStaysUnbound() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let core = FakeOfflineCore()
        let store = try sandbox.makeStore()
        let bridge = PopopxOfflineBridge(core: core, store: store)

        let acceptance = try await bridge.acceptOfflineInviteLink("popopx:/contact#/?v=2")
        #expect(acceptance.kind == .confirmation)
        #expect(await store.allMappings().isEmpty)
    }

    @Test("a rejected link never reaches the chat core")
    func rejectedLinkStopsBeforeFFI() async throws {
        let sandbox = try MeshSandbox()
        defer { sandbox.reset() }
        let core = FakeOfflineCore()
        let store = try sandbox.makeStore()
        let bridge = PopopxOfflineBridge(core: core, store: store)
        let hostile = "simplex:/contact#/?v=2"
        let hex = meshHex("98bb")

        await #expect(throws: PopopxOfflineBridgeError.inviteLinkRejected(characterCount: hostile.count)) {
            _ = try await bridge.acceptOfflineInviteLink(hostile, meshPublicKeyHex: hex)
        }
        let injected = "popopx:/a\nb"
        await #expect(throws: PopopxOfflineBridgeError.inviteLinkRejected(characterCount: injected.count)) {
            _ = try await bridge.acceptOfflineInviteLink(injected, meshPublicKeyHex: hex)
        }
        #expect(await core.acceptedLinks.isEmpty)
        #expect(await store.allMappings().isEmpty)
    }
}
