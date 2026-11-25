//
//  IdentityMappingStore.swift
//  PopopxMeshKit  —  module 1
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The bridge between two id spaces that otherwise never meet: a 64-hex Bluetooth mesh public key
//  (which only exists while a radio is in range) and a POPOPX `contactId` / pending-connection id
//  (which lives in the chat database). Keeping the table here means the mesh side never has to
//  open that database, and the app side never has to learn the mesh's key format.
//
//  The table is one JSON payload in the Keychain, written whole in one call. It is deliberately
//  not a file under `Documents/popopx_mesh/`: a plaintext list of which offline neighbour is which
//  of the user's contacts is exactly the kind of record that must not leave the device in a backup.
//

import Foundation

// The contract's `PopopxMeshKeychain` already implements the four methods exactly; it just does not
// claim the protocol, and its file may not be edited, so the conformance is stated here — the only
// place that can know the mapping table is the thing that consumes it.
extension PopopxMeshKeychain: PopopxMeshSecretStoring {}

/// What the app does when an offline peer asks to become a contact. Read by module 3 before it
/// touches the FFI, so the switch has one owner and one persisted value.
public enum MeshPairingPolicy: String, Codable, CaseIterable, Sendable {
    /// The default, and the safe answer for a radio anyone can switch on: an inbound request only
    /// raises the banner, and nothing reaches `/_connect` until the user approves it.
    case manualConfirm
    /// The exchange finishes on its own once the Bluetooth private session exists.
    case autoSilent
}

/// One row: a mesh key, the chat object it currently stands for, and how it got there.
public struct PopopxMeshContactMapping: Codable, Hashable, Sendable {
    /// Canonical lower-case hex, the same 64 characters `SYS_POPOPX_ACK:` carries.
    public let meshPublicKeyHex: String
    /// Nil until the pending connection becomes a real contact.
    public var contactId: Int64?
    /// The `PendingContactConnection.pccConnId` the offline `/_connect` produced; nil after the
    /// upgrade, so a stale id can never resolve to a chat again.
    public var tempConnId: Int64?
    public var createdAt: Date
    public var updatedAt: Date
    public var nickname: String?

    public init(
        meshPublicKeyHex: String,
        contactId: Int64? = nil,
        tempConnId: Int64? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        nickname: String? = nil
    ) {
        self.meshPublicKeyHex = meshPublicKeyHex
        self.contactId = contactId
        self.tempConnId = tempConnId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.nickname = nickname
    }

    /// Bound to a pending connection only — module 6 lists these as "offline pairing, not yet a contact".
    public var isPending: Bool { contactId == nil && tempConnId != nil }
}

/// One case per panic-wipe step, because the caller has to know which step left something behind
/// on a device the user is afraid of losing.
public enum PopopxMeshWipeFailure: Hashable, Sendable {
    case keychain(reason: String)
    case preferences(reason: String)
    case cacheFiles(reason: String)
}

public struct PopopxMeshWipeReport: Hashable, Sendable {
    public let failures: [PopopxMeshWipeFailure]

    public init(failures: [PopopxMeshWipeFailure] = []) {
        self.failures = failures
    }

    public var isClean: Bool { failures.isEmpty }
}

/// Why the stored table could not be used as-is. Surfaced instead of swallowed, so a corrupt
/// payload can be repaired rather than silently replaced by an empty table.
public enum PopopxMappingPayloadIssue: Hashable, Sendable {
    case undecodablePayload(byteCount: Int)
    case keychainReadFailed(reason: String)
}

public enum IdentityMappingError: Error, Hashable, Sendable {
    case meshPublicKeyRejected(characterCount: Int)
    case keychainReadFailed(reason: String)
    case keychainWriteFailed(reason: String)
    /// The write failed *and* the previous payload could not be put back: the table may now be
    /// empty on a device that still shows bindings, which is the one case the user must hear about.
    case keychainRollbackFailed(reason: String)
    case payloadRejected(reason: String)
    /// Refusing to write is not a storage fault: when the old JSON cannot be read, the original payload must stay exactly as it was.
    case writeBlocked(issue: PopopxMappingPayloadIssue)
}

/// `contactId <-> meshPublicKey` is one-to-many: the same person can be reachable over Bluetooth
/// on two phones, and both keys must resolve to the one contact the user sees.
public actor IdentityMappingStore {
    public static let keychainService = "chat.popopx.mesh.identity-map"
    /// One account holds the whole table: a per-binding account would need N Keychain round trips
    /// per message and could half-commit a wipe.
    public static let keychainAccount = "identity-map.v1"
    public static let pairingPolicyDefaultsKey = "chat.popopx.mesh.pairingPolicy"
    public static let meshEnabledDefaultsKey = "chat.popopx.mesh.enabled"

    /// A nickname is stored here, not displayed by this layer, so it is clamped rather than
    /// validated: a peer-controlled string must not be able to grow the one Keychain item freely.
    public static let maxNicknameCharacters = 120

    public static let shared = IdentityMappingStore()

    private let defaults: UserDefaults
    private let secrets: any PopopxMeshSecretStoring

    private var mappings: [String: PopopxMeshContactMapping] = [:]
    private var contactIndex: [Int64: Set<String>] = [:]
    private var pendingIndex: [Int64: Set<String>] = [:]
    private var loaded = false
    private var payloadIssue: PopopxMappingPayloadIssue?
    private var preservedPayload: Data?

    public init(defaults: UserDefaults = .standard, secrets: any PopopxMeshSecretStoring = PopopxMeshKeychain.shared) {
        self.defaults = defaults
        self.secrets = secrets
    }

    // MARK: - Switches

    /// Written through to `UserDefaults` immediately: a fuse that only took effect at the next
    /// launch would be worthless in panic mode.
    public var pairingPolicy: MeshPairingPolicy {
        get {
            MeshPairingPolicy(rawValue: defaults.string(forKey: Self.pairingPolicyDefaultsKey) ?? "") ?? .manualConfirm
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.pairingPolicyDefaultsKey)
            PopopxMeshLog.store.info("⚙️ pairing policy = \(newValue.rawValue, privacy: .public)")
        }
    }

    /// Global fuse, off by default: with this false the upper layers never start a radio at all,
    /// so the mesh cannot become reachable on a device whose owner has not said yes.
    public var meshEnabled: Bool {
        get { defaults.bool(forKey: Self.meshEnabledDefaultsKey) }
        set {
            defaults.set(newValue, forKey: Self.meshEnabledDefaultsKey)
            PopopxMeshLog.store.info("⚙️ mesh enabled = \(newValue, privacy: .public)")
        }
    }

    /// Assigning an actor's property from outside is not allowed and the switches are read by other
    /// actors, so the settings screen and module 3 go through these; they are the setters, callable.
    public func updatePairingPolicy(_ policy: MeshPairingPolicy) {
        pairingPolicy = policy
    }

    public func updateMeshEnabled(_ enabled: Bool) {
        meshEnabled = enabled
    }

    // MARK: - Reads

    /// A mesh key has one useful spelling, so the upper case a peer may send is folded instead of
    /// becoming a second row for the same person.
    public static func canonicalMeshPublicKeyHex(_ candidate: some StringProtocol) -> String? {
        guard PopopxMeshControlFrame.isMeshPublicKey(candidate) else { return nil }
        return candidate.lowercased()
    }

    public func contactId(forMeshPublicKeyHex candidate: String) -> Int64? {
        loadIfNeeded()
        guard let hex = Self.canonicalMeshPublicKeyHex(candidate) else { return nil }
        return mappings[hex]?.contactId
    }

    public func meshPublicKeyHexes(forContactId contactId: Int64) -> [String] {
        loadIfNeeded()
        return (contactIndex[contactId] ?? []).sorted()
    }

    public func mapping(forMeshPublicKeyHex candidate: String) -> PopopxMeshContactMapping? {
        loadIfNeeded()
        guard let hex = Self.canonicalMeshPublicKeyHex(candidate) else { return nil }
        return mappings[hex]
    }

    /// The pending half of the table: what module 6 shows until `contactConnected` arrives.
    public func pendingMappings(forTempConnId tempConnId: Int64) -> [PopopxMeshContactMapping] {
        loadIfNeeded()
        return (pendingIndex[tempConnId] ?? [])
            .sorted()
            .compactMap { mappings[$0] }
    }

    public func allMappings() -> [PopopxMeshContactMapping] {
        loadIfNeeded()
        return mappings.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.meshPublicKeyHex < $1.meshPublicKeyHex
        }
    }

    /// The payload this store could not decode, kept verbatim so a later release can repair it
    /// instead of losing the bindings. Non-nil implies writes are blocked.
    public var preservedPayloadBytes: Data? {
        loadIfNeeded()
        return preservedPayload
    }

    public var storedPayloadIssue: PopopxMappingPayloadIssue? {
        loadIfNeeded()
        return payloadIssue
    }

    // MARK: - Writes

    /// Records an offline pairing right after `/_connect` produced the pending connection.
    @discardableResult
    public func bind(tempConnId: Int64, meshPublicKeyHex candidate: String, nickname: String?)
        throws(IdentityMappingError) -> PopopxMeshContactMapping
    {
        loadIfNeeded()
        guard let hex = Self.canonicalMeshPublicKeyHex(candidate) else {
            PopopxMeshLog.store.error(
                "🚫 bind refused: malformed mesh key (\(candidate.count, privacy: .public) characters)"
            )
            throw .meshPublicKeyRejected(characterCount: candidate.count)
        }
        let previous = mappings[hex]
        let mapping = PopopxMeshContactMapping(
            meshPublicKeyHex: hex,
            contactId: previous?.contactId,
            tempConnId: tempConnId,
            createdAt: previous?.createdAt ?? .now,
            updatedAt: .now,
            nickname: Self.clamped(nickname) ?? previous?.nickname
        )
        var next = mappings
        next[hex] = mapping
        try writeThrough(next)
        PopopxMeshLog.store.notice(
            "🔗 bound \(hex.prefix(8), privacy: .public) to pending connection :\(tempConnId, privacy: .public)"
        )
        return mapping
    }

    /// module 6 calls this when `contactConnected` (`Shared/Model/AppAPITypes.swift:1240`,
    /// `Contact.contactId`) names the pending connection: the row survives, the temporary id does not.
    /// - Returns: how many mesh keys moved onto the contact — more than one when the peer has
    ///  several radios.
    @discardableResult
    public func upgradePendingConnection(tempConnId: Int64, toFinalContactId contactId: Int64)
        throws(IdentityMappingError) -> Int
    {
        loadIfNeeded()
        let hexes = (pendingIndex[tempConnId] ?? []).sorted()
        guard !hexes.isEmpty else { return 0 }
        var next = mappings
        for hex in hexes {
            guard let current = next[hex] else { continue }
            next[hex] = PopopxMeshContactMapping(
                meshPublicKeyHex: hex,
                contactId: contactId,
                tempConnId: nil,
                createdAt: current.createdAt,
                updatedAt: .now,
                nickname: current.nickname
            )
        }
        try writeThrough(next)
        PopopxMeshLog.store.notice(
            "⬆️ upgraded \(hexes.count, privacy: .public) binding(s) from pending :\(tempConnId, privacy: .public) to @\(contactId, privacy: .public)"
        )
        return hexes.count
    }

    @discardableResult
    public func unbind(meshPublicKeyHex candidate: String) throws(IdentityMappingError) -> Bool {
        loadIfNeeded()
        guard let hex = Self.canonicalMeshPublicKeyHex(candidate), mappings[hex] != nil else { return false }
        var next = mappings
        next[hex] = nil
        try writeThrough(next)
        PopopxMeshLog.store.notice("✂️ unbound \(hex.prefix(8), privacy: .public)")
        return true
    }

    /// A deleted contact takes every one of that peer's radios with it.
    @discardableResult
    public func unbindAll(forContactId contactId: Int64) throws(IdentityMappingError) -> Int {
        loadIfNeeded()
        let hexes = contactIndex[contactId] ?? []
        guard !hexes.isEmpty else { return 0 }
        var next = mappings
        for hex in hexes { next[hex] = nil }
        try writeThrough(next)
        PopopxMeshLog.store.notice("✂️ unbound \(hexes.count, privacy: .public) mesh key(s) of @\(contactId, privacy: .public)")
        return hexes.count
    }

    /// Panic mode: everything this package remembered, gone, in one call that never stops early.
    ///
    /// Every step runs even after a failure and its error is collected, because a wipe that
    /// reported success after doing half the job would be worse than one that admitted the rest —
    /// the caller acts on `isClean`. The in-memory table goes first so no reader can take a binding
    /// out of this process while the Keychain and disk copies are still being removed.
    public func emergencyWipeAllMappings() -> PopopxMeshWipeReport {
        var failures: [PopopxMeshWipeFailure] = []

        apply([:])
        preservedPayload = nil
        payloadIssue = nil
        loaded = true

        do {
            try secrets.removeAll(service: Self.keychainService)
        } catch {
            failures.append(.keychain(reason: Self.describe(error)))
        }

        defaults.removeObject(forKey: Self.pairingPolicyDefaultsKey)
        defaults.removeObject(forKey: Self.meshEnabledDefaultsKey)
        if defaults.object(forKey: Self.pairingPolicyDefaultsKey) != nil
            || defaults.object(forKey: Self.meshEnabledDefaultsKey) != nil
        {
            failures.append(.preferences(reason: "mesh switches survived removeObject"))
        }

        do {
            try Self.removeMeshCacheFiles()
        } catch {
            failures.append(.cacheFiles(reason: Self.describe(error)))
        }

        PopopxMeshLog.store.error("🧨 identity map wiped — \(failures.count, privacy: .public) step(s) failed")
        return PopopxMeshWipeReport(failures: failures)
    }

    // MARK: - Storage

    /// Rebuilding both reverse indexes from the one dictionary, instead of patching them per
    /// operation, is what makes "delete one side and the other follows" true by construction
    /// rather than by discipline.
    private func apply(_ next: [String: PopopxMeshContactMapping]) {
        mappings = next
        var contacts: [Int64: Set<String>] = [:]
        var pending: [Int64: Set<String>] = [:]
        for (hex, mapping) in next {
            if let contactId = mapping.contactId {
                contacts[contactId, default: []].insert(hex)
            } else if let tempConnId = mapping.tempConnId {
                pending[tempConnId, default: []].insert(hex)
            }
        }
        contactIndex = contacts
        pendingIndex = pending
    }

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let mappings: [PopopxMeshContactMapping]
    }

    /// Backup before write: the payload currently in the Keychain is read first and put back if
    /// the new one is refused, so a failed upgrade leaves the table exactly as it was. The table
    /// is only swapped in memory once the Keychain has accepted it — the two copies cannot drift.
    private func writeThrough(_ next: [String: PopopxMeshContactMapping]) throws(IdentityMappingError) {
        if let issue = payloadIssue {
            PopopxMeshLog.store.error(
                "🚫 write refused, stored payload preserved: \(String(describing: issue), privacy: .public)"
            )
            throw .writeBlocked(issue: issue)
        }
        let sorted = next.values.sorted { $0.meshPublicKeyHex < $1.meshPublicKeyHex }
        let payload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            payload = try encoder.encode(Snapshot(schemaVersion: 1, mappings: sorted))
        } catch {
            throw .payloadRejected(reason: Self.describe(error))
        }

        let backup: Data?
        do {
            backup = try secrets.data(service: Self.keychainService, account: Self.keychainAccount)
        } catch {
            throw .keychainReadFailed(reason: Self.describe(error))
        }

        do {
            try secrets.set(payload, service: Self.keychainService, account: Self.keychainAccount)
        } catch {
            do {
                if let backup {
                    try secrets.set(backup, service: Self.keychainService, account: Self.keychainAccount)
                } else {
                    try secrets.remove(service: Self.keychainService, account: Self.keychainAccount)
                }
            } catch {
                throw .keychainRollbackFailed(reason: Self.describe(error))
            }
            throw .keychainWriteFailed(reason: Self.describe(error))
        }
        apply(next)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let payload: Data?
        do {
            payload = try secrets.data(service: Self.keychainService, account: Self.keychainAccount)
        } catch {
            payloadIssue = .keychainReadFailed(reason: Self.describe(error))
            PopopxMeshLog.store.error("❌ identity map unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        guard let payload else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: payload)
            apply(Dictionary(uniqueKeysWithValues: snapshot.mappings.map { ($0.meshPublicKeyHex, $0) }))
            PopopxMeshLog.store.info("📖 identity map loaded — \(snapshot.mappings.count, privacy: .public) binding(s)")
        } catch {
            preservedPayload = payload
            payloadIssue = .undecodablePayload(byteCount: payload.count)
            PopopxMeshLog.store.error(
                "⚠️ identity payload of \(payload.count, privacy: .public) bytes did not decode — kept verbatim, writes blocked until repaired"
            )
        }
    }

    private static func clamped(_ nickname: String?) -> String? {
        guard let nickname else { return nil }
        return String(nickname.prefix(maxNicknameCharacters))
    }

    /// A missing mesh directory is the clean case — nothing was ever cached. Each file is removed
    /// on its own so one stuck entry cannot leave the rest of the cache behind in a panic wipe.
    private static func removeMeshCacheFiles() throws {
        let directory = PopopxMeshPaths.meshDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var stuck: [String] = []
        for child in children {
            do {
                try FileManager.default.removeItem(at: child)
            } catch {
                stuck.append(child.lastPathComponent)
            }
        }
        guard stuck.isEmpty else {
            throw PopopxMeshStorageError.writeFailed(
                path: directory.path,
                underlying: "retained \(stuck.count) file(s)"
            )
        }
    }

    private static func describe(_ error: Error) -> String {
        String(describing: error)
    }
}
