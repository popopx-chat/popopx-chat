//
//  PopopxGroupStore.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Where a group lives: the roster, name and epoch as JSON in the mesh's own sandbox directory, the
//  symmetric key in the Keychain, never together. Bitchat splits it the same way
//  (`bitchat/Services/Groups/GroupStore.swift:56-230`), and for the same reason: the metadata is
//  boring to an attacker, the key is the whole group, and only one of the two stores is
//  `ThisDeviceOnly` and wiped by module 7's fuse.
//
//  Two rules this type owns and enforces on every path, including the load from disk:
//  * a group whose key is missing is not a group. `load()` drops it rather than keeping a shell the
//    user can open and fail to write into;
//  * a known groupID keeps the creator it was created with. `upsert` refuses a state that would
//    hand our group id to a different creator, however well its own signature checks out.
//

import Foundation
import Security

public actor PopopxGroupStore {
    public static let metadataFileName = "groups.json"
    public static let metadataDirectoryName = "groups"
    /// Keychain account prefix, mirroring Bitchat's `groupKey-\(groupID.hex)`.
    public static let keyAccountPrefix = "groupKey-"

    private let secrets: any PopopxMeshSecretStoring
    private let fileURL: URL
    private var groups: [PopopxMeshGroup] = []
    private var didLoad = false

    /// `directory` defaults to the mesh sandbox (`Documents/popopx_mesh/groups/`), which is iron rule 5's
    /// rule for offline state and is what module 7's panic wipe already clears. A test injects a
    /// temporary directory and never touches the real one.
    public init(
        secrets: any PopopxMeshSecretStoring = PopopxMeshKeychain.shared,
        directory: URL? = nil
    ) {
        self.secrets = secrets
        let base = directory ?? PopopxMeshPaths.meshDirectory()
        self.fileURL = base
            .appendingPathComponent(Self.metadataDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.metadataFileName)
    }

    public var metadataURL: URL { fileURL }

    // MARK: - Reads

    /// All groups this device holds a usable key for, in the order they were created.
    public func allGroups() -> [PopopxMeshGroup] {
        usableGroups()
    }

    public func group(withID id: Data) -> PopopxMeshGroup? {
        usableGroups().first { $0.id == id }
    }

    /// The current-epoch key, from the Keychain. nil means the group's metadata outlived its key —
    /// an unreachable-on-purpose state that callers must surface rather than paper over.
    public func key(forGroupID id: Data) -> Data? {
        guard let data = try? secrets.data(
            service: PopopxGroupSigningIdentity.keychainService,
            account: Self.keyAccount(for: id)
        ) else { return nil }
        guard data.count == PopopxMeshGroup.keyByteCount else {
            PopopxMeshLog.store.error(
                "🚫 group key for \(id.popopxHex.prefix(16), privacy: .public) is \(data.count) bytes, 32 required"
            )
            return nil
        }
        return data
    }

    /// The directory as it stands on disk, ignoring any half-written entry whose key is gone. The
    /// caller's view of "which groups am I in" has to be the same view the sealing path uses.
    private func usableGroups() -> [PopopxMeshGroup] {
        ensureLoaded()
        return groups.filter { key(forGroupID: $0.id) != nil }
    }

    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        load()
    }

    /// Drops groups whose key is missing, whose roster is over the cap, or whose creator is not in
    /// that roster, and keeps one entry per group id. Loading bypasses `upsert`, so `upsert`'s
    /// invariants are re-checked here rather than trusted.
    private func load() {
        // Absent file, unreadable file and a file this build cannot parse all mean the same thing
        // to the caller: no groups. `PopopxMeshFileStore.read` throws for the first one, so the
        // error is logged rather than turned into a silent "0 groups" on a corrupted file.
        guard let stored = try? PopopxMeshFileStore.read([PopopxMeshGroup].self, from: fileURL) else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                PopopxMeshLog.store.error("🚫 group metadata unreadable at \(self.fileURL.path, privacy: .public)")
            }
            return
        }
        var seen: Set<Data> = []
        groups = stored.filter { group in
            group.isWellFormed && seen.insert(group.id).inserted && key(forGroupID: group.id) != nil
        }
    }

    // MARK: - Mutations

    /// A new group at epoch 1 with the creator as sole member. The id and the key both come from
    /// `SecRandomCopyBytes`, and a failure to mint either is returned as an error rather than
    /// falling back to a shorter or predictable value.
    @discardableResult
    public func createGroup(
        named rawName: String,
        creator: PopopxMeshGroupMember
    ) throws(PopopxMeshGroupError) -> (group: PopopxMeshGroup, key: Data) {
        let name = PopopxMeshGroup.clampedName(rawName)
        guard !name.isEmpty else { throw PopopxMeshGroupError.nameEmpty }
        guard let id = Self.randomBytes(PopopxMeshGroup.idByteCount),
              let key = Self.randomBytes(PopopxMeshGroup.keyByteCount) else {
            throw PopopxMeshGroupError.storageFailed("random bytes refused by the system")
        }
        guard let group = PopopxMeshGroup(
            id: id,
            name: name,
            epoch: 1,
            members: [creator],
            creatorMeshPublicKeyHex: creator.meshPublicKeyHex
        ) else { throw PopopxMeshGroupError.storageFailed("new group not well formed") }
        try upsert(group, key: key)
        return (group, key)
    }

    /// Inserts or replaces a group and its current key. Rejects an over-cap or empty roster, a
    /// roster without its creator, a bad key length, and any change to the creator of a group
    /// already held.
    public func upsert(
        _ group: PopopxMeshGroup,
        key: Data
    ) throws(PopopxMeshGroupError) {
        guard key.count == PopopxMeshGroup.keyByteCount else {
            throw PopopxMeshGroupError.storageFailed("group key is \(key.count) bytes, 32 required")
        }
        guard group.isWellFormed else {
            throw PopopxMeshGroupError.storageFailed("group rejected: roster or creator malformed")
        }
        ensureLoaded()
        if let existing = groups.first(where: { $0.id == group.id }),
           !existing.hasSameCreator(as: group) {
            PopopxMeshLog.store.error(
                "🚫 refusing group state claiming creator \(group.creatorMeshPublicKeyHex.prefix(8), privacy: .public) for a group created by \(existing.creatorMeshPublicKeyHex.prefix(8), privacy: .public)"
            )
            throw PopopxMeshGroupError.rejected(.creatorPinning)
        }
        do {
            try secrets.set(
                key,
                service: PopopxGroupSigningIdentity.keychainService,
                account: Self.keyAccount(for: group.id)
            )
        } catch {
            throw PopopxMeshGroupError.storageFailed("group key not persisted: \(error)")
        }
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        try persist()
    }

    /// Creator-side roster change without touching the key or the epoch. Not the invite path:
    /// Bitchat rotates on every roster change so the receiver gets a strict ordering, and so we do
    /// too (`PopopxGroupCoordinator.invite`).
    @discardableResult
    public func updateRoster(
        groupID: Data,
        members: [PopopxMeshGroupMember]
    ) throws(PopopxMeshGroupError) -> PopopxMeshGroup {
        ensureLoaded()
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
            throw PopopxMeshGroupError.groupNotFound(groupIDHex: groupID.popopxHex)
        }
        guard key(forGroupID: groupID) != nil else {
            throw PopopxMeshGroupError.keyMissing(groupIDHex: groupID.popopxHex)
        }
        var updated = groups[index]
        updated.members = members
        guard updated.isWellFormed else {
            throw PopopxMeshGroupError.storageFailed("roster rejected: over cap, empty, or creator absent")
        }
        guard groups[index].hasSameCreator(as: updated) else {
            throw PopopxMeshGroupError.rejected(.creatorPinning)
        }
        groups[index] = updated
        try persist()
        return updated
    }

    /// New random key, epoch + 1, new roster. Every roster change — an invite as much as a removal —
    /// goes through here, so a removed member's key stops decrypting future traffic by itself.
    @discardableResult
    public func rotateKey(
        groupID: Data,
        members: [PopopxMeshGroupMember]
    ) throws(PopopxMeshGroupError) -> (group: PopopxMeshGroup, key: Data) {
        ensureLoaded()
        guard let existing = groups.first(where: { $0.id == groupID }) else {
            throw PopopxMeshGroupError.groupNotFound(groupIDHex: groupID.popopxHex)
        }
        guard let newKey = Self.randomBytes(PopopxMeshGroup.keyByteCount) else {
            throw PopopxMeshGroupError.storageFailed("random bytes refused by the system")
        }
        var rotated = existing
        // Saturating rather than wrapping: a group that reached the top of the counter cannot be
        // advanced, and a wrapped epoch would silently re-open every old message to the AAD check.
        guard rotated.epoch < UInt32.max else {
            throw PopopxMeshGroupError.storageFailed("epoch exhausted")
        }
        rotated.epoch = existing.epoch + 1
        rotated.members = members
        try upsert(rotated, key: newKey)
        return (rotated, newKey)
    }

    public func removeGroup(withID id: Data) {
        ensureLoaded()
        groups.removeAll { $0.id == id }
        try? secrets.remove(
            service: PopopxGroupSigningIdentity.keychainService,
            account: Self.keyAccount(for: id)
        )
        try? persist()
    }

    /// Module 7's panic wipe calls this alongside `removeAll(service:)`: the metadata file goes too, so
    /// a restored backup cannot resurrect a group whose key no longer exists.
    public func wipe() {
        ensureLoaded()
        for group in groups {
            try? secrets.remove(
                service: PopopxGroupSigningIdentity.keychainService,
                account: Self.keyAccount(for: group.id)
            )
        }
        groups.removeAll()
        try? PopopxMeshFileStore.remove(fileURL)
    }

    // MARK: - Internals

    private func persist() throws(PopopxMeshGroupError) {
        do {
            if groups.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try PopopxMeshFileStore.remove(fileURL)
                }
                return
            }
            try PopopxMeshFileStore.write(groups, to: fileURL)
        } catch {
            throw PopopxMeshGroupError.storageFailed("group metadata not persisted: \(error)")
        }
    }

    private static func keyAccount(for id: Data) -> String {
        Self.keyAccountPrefix + id.popopxHex
    }

    /// `SecRandomCopyBytes`, not `UInt8.random`: the system generator is the one with a seeded state,
    /// and a group id or key made from `random(in:)` is a claim about the Swift PRNG we cannot make.
    private static func randomBytes(_ count: Int) -> Data? {
        guard count > 0 else { return nil }
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            PopopxMeshLog.store.error("🚫 SecRandomCopyBytes failed with OSStatus \(status)")
            return nil
        }
        return bytes
    }
}
