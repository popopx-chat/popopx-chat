//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
// POPOPX signed server cluster configuration — persistence.
//
// Two tiers, and the split is not decoration:
//
// **UserDefaults (`groupDefaults`)** holds the small records that decide whether a frame is worth
// acting on at all — the per-key generation floors, the broken-generation list, the receipt dedupe claim, the
// URIs this mechanism introduced. A frame arriving in the receive path needs the floor before the core
// is known to be reachable, and a whole-table read to answer "what generation are we on" would make
// every silent decision depend on the database being open.
//
// **Files under the App Group container** hold the two blobs that are only read when something has gone
// wrong: the pre-apply snapshot that makes rollback possible, and a staged frame that arrived when
// applying was not safe. Both are whole-value replacements, so an atomic write is exactly the right
// primitive, and neither is large enough to care about incremental access.
//
// The state model follows the wire contract rather than the shape a dictionary would suggest. Two
// counters matter and they are not interchangeable: `seq` is the generation, monotonic **per signing
// key** and never derived from a clock, and `exp` is a lifetime. A generated frame is actionable when
// its generation is above this device's floor *for that key* and is not on the broken list. Gaps in
// `seq` are legal — a reserved generation that was never published leaves a hole — so the floor is a
// floor, not a count.
//
// `pol.ms` is the revocation lever and it is the one place a floor moves *down*: the operator signs a
// higher minimum generation to pull a bad one out from under every device, and a device that only ever
// raised its floor could not be told to accept the corrected generation that follows. Everything else
// here moves in the fail-safe direction: the floor is raised at accept time, before applying, so a crash
// between raising it and finishing the apply cannot lead to the same bad configuration being applied
// again when the delivery guarantee re-presents the same message.
//
// The rollback snapshot is written *before* the core table is touched and deleted only once the change
// is verified. If it cannot be written, the caller refuses the update: an applied configuration with no
// way back is the one state this module must never produce.
//
// The persisted key names and the on-disk schema version changed with the contract alignment, and
// nothing is migrated from the previous spelling on purpose. This mechanism has shipped to no device
// yet, so a migration would be code that only ever runs against state produced by a build that refused
// every frame it read.
//
// Nothing here reaches the core. The store answers "what did we already accept"; the API calls live in
// `PopopxServerConfigSignalHandler`.

import Foundation
import os
// `groupDefaults` and `APP_GROUP_NAME` are top-level declarations of `POPOPXChat` (`AppGroup.swift:61`,
// `:72`), not of this target, so the file that reads the shared suite needs the same import every other
// App Group consumer in `Shared/` carries.
import POPOPXChat

// MARK: - Values

/// Where an applied configuration stands. The verdict is what makes a relaunch safe to reason about: a
/// record left `.pending` means the process died, or was backgrounded, inside the probe window.
enum PopopxServerConfigVerdict: String, Codable, Sendable {
    case pending
    case verified
    case rolledBack
}

/// The highest generation this device has acted on for one signing key.
///
/// Keyed by `kid` rather than stored as a single number because a rotation resets the counter: the new
/// key's first generation is `1`, and a device holding a global floor of `7` would refuse every frame
/// the replacement key ever signs. That failure mode is silent — the device simply never updates again —
/// which is the reason it is worth the extra level of structure.
struct PopopxServerConfigFloor: Codable, Equatable, Sendable {
    let kid: String
    var seq: Int
}

/// The state of the server table immediately before an update was applied.
struct PopopxServerConfigSnapshot: Codable, Sendable {
    /// Disk-format version, deliberately separate from the payload's wire version: this is about whether
    /// *this file* can be read, and a schema change here must discard rather than guess.
    static let schemaVersion = 2

    let schemaVersion: Int
    let takenAt: Date
    /// The generation this snapshot exists to return the device to, and the key that signed it.
    let kid: String
    let seq: Int
    /// The rows this mechanism owned at the time, carried alongside the table so a rollback restores
    /// ownership as well as addresses. Without it, a rollback would leave the device believing the rows
    /// it just wrote back were its own to delete on the next update.
    let introducedURIs: [String]
    /// The full table, exactly as `getUserServers()` returned it. Rollback sends these rows back and then
    /// re-reads, which is how the manual save flow learns server ids
    /// (`NetworkAndServers.swift:492-497`); a partial snapshot could not.
    let servers: [UserOperatorServers]

    init(kid: String, seq: Int, introducedURIs: [String], servers: [UserOperatorServers], takenAt: Date = Date()) {
        self.schemaVersion = Self.schemaVersion
        self.takenAt = takenAt
        self.kid = kid
        self.seq = seq
        self.introducedURIs = introducedURIs
        self.servers = servers
    }
}

/// Which kind of conversation a frame arrived in.
///
/// Stored rather than inferred at promotion time, because the two conversation kinds number their
/// contacts in different namespaces: a group's `apiId` and a contact's `apiId` overlap as integers, so a
/// receipt routed by the bare number can land in the wrong conversation. It also decides whether a
/// receipt may be sent at all — see `PopopxServerConfigSignalHandler`.
enum PopopxServerConfigSourceChat: String, Codable, Sendable {
    case direct
    case group
}

/// The receipt this device owes an operator, and how to route it.
///
/// No outcome field: the contract's receipt grammar is `::<seq>[::<bh>]`, which can state that a device
/// received a generation and which body it installed, and nothing else. A refusal therefore cannot be
/// reported at all — reporting one as a bare `<seq>` would be counted by the operator's roll-up as an
/// acknowledged device, which is a false coverage claim rather than a partial one. The rule this store
/// implements follows from that: acknowledge what was installed, and what was legitimately stale, and
/// stay silent about everything refused.
///
/// All of it is device-local routing state, never part of a signed payload.
struct PopopxServerConfigPendingAck: Codable, Equatable, Sendable {
    let kid: String
    let seq: Int
    /// Body hash of the configuration that was installed, or nil when the receipt reports a generation
    /// this device did not install.
    let bodyHash: String?
    let chatType: PopopxServerConfigSourceChat
    let chatId: Int64

    /// Identity for dedupe purposes: everything except the hash.
    ///
    /// The operator's own identity for a receipt is generation plus body hash, but *this device's*
    /// question is narrower — "have I answered this delivery?" — and a retry of one delivery can present
    /// the same frame with a hash this device computed differently if the build changed in between. Two
    /// receipts for one generation in one conversation is the outcome being prevented.
    var claimKey: String {
        "\(kid)|\(seq)|\(chatType.rawValue)|\(chatId)"
    }
}

/// A frame that arrived at a moment it could not be applied.
///
/// Stores the received *segment text*, not the decoded payload: a staged frame is still untrusted until
/// it is verified, verification runs over exactly these bytes, and the body is no longer separable from
/// its compressed form once inflated. Re-verifying on promotion also means an expiry that passed while
/// the frame sat there is honoured instead of baked in.
struct PopopxServerConfigStagedFrame: Codable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let receivedAt: Date
    /// The whole line, prefix included, as it arrived.
    let segment: String
    let chatType: PopopxServerConfigSourceChat
    let chatId: Int64

    init(segment: String, chatType: PopopxServerConfigSourceChat, chatId: Int64, receivedAt: Date = Date()) {
        self.schemaVersion = Self.schemaVersion
        self.receivedAt = receivedAt
        self.segment = segment
        self.chatType = chatType
        self.chatId = chatId
    }
}

// MARK: - Store

/// All state for the configuration mechanism. Static, nonisolated, and cheap: the file reads happen on
/// the promotion path, not in a view body, and the defaults reads are single keys.
enum PopopxServerConfigStore {
    static let directoryName = "popopx_server_config"
    static let snapshotFileName = "rollback.json"
    static let stagedFileName = "staged.json"

    /// Flat camelCase, like every other `groupDefaults` key in the app (`GROUP_DEFAULT_*` in
    /// `AppGroup.swift`). Verified against the tree: no existing key in any target begins with
    /// `serverConfig`, so none of these can shadow a preference the settings screens write.
    private static let keyFloors = "serverConfigFloors"
    private static let keyBrokenEntries = "serverConfigBrokenEntries"
    private static let keyAckClaims = "serverConfigAckClaims"
    private static let keyIntroducedURIs = "serverConfigIntroducedURIs"
    private static let keyVerdict = "serverConfigVerdict"
    private static let keyPendingAck = "serverConfigPendingAck"
    /// Suffixed with a profile id, so the census above ("no existing key begins with `serverConfig`")
    /// still holds: the full key is this string, a dot, and a number.
    private static let keyOfficialSubscription = "serverConfigOfficialSubscription"
    /// System config chat IDs per userId: stored as JSON dictionary [userId: [chatId]].
    private static let keySystemConfigChatIds = "serverConfigSystemConfigChatIds"

    /// How many floor records, broken entries and receipts are kept. Bounded because each is a JSON
    /// blob in `UserDefaults` that a device could otherwise accumulate forever; the newest entries are
    /// the ones that matter, since an old generation is below its floor by the time any list is anywhere
    /// near this length. Sixteen is four times the number of keys a rotation can plausibly involve.
    private static let maximumTrackedRecords = 16

    // MARK: Floors

    /// Every recorded floor, oldest first.
    static var floors: [PopopxServerConfigFloor] {
        get { decoded([PopopxServerConfigFloor].self, forKey: keyFloors) ?? [] }
        set { persist(newValue, forKey: keyFloors) }
    }

    /// The generation this device last acted on for one key, or zero when it has never seen that key.
    ///
    /// Zero rather than nil: "nothing from this key yet" and "the floor is zero" are the same instruction
    /// to the caller, and an optional here would only move the `??` to every call site.
    static func floor(for kid: String) -> Int {
        floors.first(where: { $0.kid == kid })?.seq ?? 0
    }

    /// Whether a generation is worth acting on: strictly above that key's floor, and not known to fail.
    static func isAcceptable(kid: String, seq: Int) -> Bool {
        guard seq > floor(for: kid) else { return false }
        return !isBroken(kid: kid, seq: seq)
    }

    /// Records an acceptance and the URIs it introduced, and opens a probe window (`pending`).
    static func markAccepted(kid: String, seq: Int, introducedURIs: [String]) {
        var records = floors
        if let index = records.firstIndex(where: { $0.kid == kid }) {
            records[index].seq = max(records[index].seq, seq)
        } else {
            records.append(PopopxServerConfigFloor(kid: kid, seq: seq))
        }
        if records.count > maximumTrackedRecords {
            records = Array(records.suffix(maximumTrackedRecords))
        }
        persist(records, forKey: keyFloors)
        groupDefaults.set(introducedURIs, forKey: keyIntroducedURIs)
        groupDefaults.set(PopopxServerConfigVerdict.pending.rawValue, forKey: keyVerdict)
    }

    /// Closes the probe window successfully.
    static func markVerified() {
        groupDefaults.set(PopopxServerConfigVerdict.verified.rawValue, forKey: keyVerdict)
    }

    /// Records a rollback: the generation is burned and the floor stays raised (the device did see that
    /// generation). Ownership of the server rows is *not* touched here — the caller restores it from the
    /// snapshot, which is the only record of what the device owned beforehand.
    static func markRolledBack(kid: String, seq: Int) {
        var broken = brokenEntries
        broken.append(brokenEntry(kid: kid, seq: seq))
        if broken.count > maximumTrackedRecords {
            broken = Array(broken.suffix(maximumTrackedRecords))
        }
        persist(broken, forKey: keyBrokenEntries)
        groupDefaults.set(PopopxServerConfigVerdict.rolledBack.rawValue, forKey: keyVerdict)
    }

    static var verdict: PopopxServerConfigVerdict? {
        guard let raw = groupDefaults.string(forKey: keyVerdict) else { return nil }
        return PopopxServerConfigVerdict(rawValue: raw)
    }

    // MARK: Revocation

    /// Applies the operator's revocation lever: `pol.ms` declares a minimum live generation, so every
    /// generation of *this key* below it is voided by raising the recorded floor to `ms - 1`.
    ///
    /// One direction only, and it is the whole point of the lever. Pulling a recorded floor down to
    /// `ms - 1` is what let a still-unexpired generation the device had already acted on be re-installed by
    /// replaying it, and the shipped cluster signs `min_seq: 1`, which made that comparison the only one that
    /// ever ran. The corrected roster a withdrawal is followed by always carries a higher generation, so a
    /// floor that only ever rises loses nothing the operator needs — and it is the only reading under which
    /// "the floor never decreases" is a fact rather than a promise.
    ///
    /// Scoped to the key that verified: a ratchet published for one rotation must not void another key's
    /// history, and after a rotation the old key's floor is the only thing standing between a device and the
    /// generations that were taken out of service.
    ///
    /// Returns whether anything moved, which is what makes the call worth logging: a device that is already
    /// above the declared baseline changes nothing, and the difference matters when reading a log after an
    /// incident.
    @discardableResult
    static func revoke(kid: String, below minSeq: Int) -> Bool {
        guard minSeq >= 1 else { return false }
        let target = minSeq - 1
        var records = floors
        guard let index = records.firstIndex(where: { $0.kid == kid }) else {
            // Nothing recorded for this key: a baseline of zero needs no record, and `ms` of one revokes
            // nothing at all.
            guard target > 0 else { return false }
            records.append(PopopxServerConfigFloor(kid: kid, seq: target))
            persist(records, forKey: keyFloors)
            return true
        }
        guard records[index].seq < target else { return false }
        records[index].seq = target
        persist(records, forKey: keyFloors)
        return true
    }

    // MARK: Broken generations

    /// Generations that were applied and then rolled back, as `kid|seq` strings. Never retried, so a frame
    /// that reliably breaks connectivity cannot be re-live by the delivery guarantee re-sending it.
    static var brokenEntries: [String] {
        decoded([String].self, forKey: keyBrokenEntries) ?? []
    }

    static func isBroken(kid: String, seq: Int) -> Bool {
        brokenEntries.contains(brokenEntry(kid: kid, seq: seq))
    }

    private static func brokenEntry(kid: String, seq: Int) -> String {
        "\(kid)|\(seq)"
    }

    // MARK: Ownership

    /// The SMP server URIs this mechanism added, and therefore the only rows it may remove.
    ///
    /// Ownership is tracked by URI, never by `preset`: `preset` is the core's own notion and is true for
    /// the shipped default servers, so claiming by it would let a signed frame delete rows the
    /// installation itself put there, let alone rows the user added.
    static var introducedURIs: [String] {
        groupDefaults.array(forKey: keyIntroducedURIs) as? [String] ?? []
    }

    static func setIntroducedURIs(_ uris: [String]) {
        groupDefaults.set(uris, forKey: keyIntroducedURIs)
    }

    // MARK: Official subscription

    /// Whether the two official conversations were joined for one profile.
    ///
    /// Keyed by profile, unlike every other key in this file: the floors, the receipts and the ownership
    /// list describe what this *device* already did to its server table, which is one table shared by all
    /// profiles, whereas a subscription is a chat, and a chat belongs to one profile. A second profile
    /// created on the same device has no conversations of its own yet, so a device-wide flag would leave
    /// it permanently unsubscribed.
    ///
    /// `false` is the unset state, which is also the state a profile reaches when the user has left both
    /// conversations: nothing here re-reads the chat list to put them back.
    static func officialSubscriptionSeeded(userId: Int64) -> Bool {
        groupDefaults.bool(forKey: "\(keyOfficialSubscription).\(userId)")
    }

    static func markOfficialSubscriptionSeeded(userId: Int64) {
        groupDefaults.set(true, forKey: "\(keyOfficialSubscription).\(userId)")
    }

    // MARK: System config chat IDs

    /// Returns all system config chat IDs for a given userId.
    static func systemConfigChatIds(for userId: Int64) -> Set<Int64> {
        guard let data = groupDefaults.data(forKey: keySystemConfigChatIds),
              let dict = try? JSONDecoder().decode([String: [Int64]].self, from: data),
              let ids = dict[String(userId)] else {
            return []
        }
        return Set(ids)
    }

    /// Adds a system config chat ID for a given userId.
    static func addSystemConfigChatId(_ chatId: Int64, for userId: Int64) {
        var dict: [String: [Int64]] = [:]
        if let data = groupDefaults.data(forKey: keySystemConfigChatIds),
           let existing = try? JSONDecoder().decode([String: [Int64]].self, from: data) {
            dict = existing
        }
        var ids = dict[String(userId)] ?? []
        guard !ids.contains(chatId) else { return }
        ids.append(chatId)
        dict[String(userId)] = ids
        if let encoded = try? JSONEncoder().encode(dict) {
            groupDefaults.set(encoded, forKey: keySystemConfigChatIds)
        }
    }

    /// Removes all system config chat IDs for a given userId (e.g., on profile deletion).
    static func clearSystemConfigChatIds(for userId: Int64) {
        guard let data = groupDefaults.data(forKey: keySystemConfigChatIds),
              var dict = try? JSONDecoder().decode([String: [Int64]].self, from: data) else {
            return
        }
        dict.removeValue(forKey: String(userId))
        if let encoded = try? JSONEncoder().encode(dict) {
            groupDefaults.set(encoded, forKey: keySystemConfigChatIds)
        }
    }

    // MARK: Receipt dedupe

    /// Claims the right to send one receipt, returning false when it is already claimed.
    ///
    /// Called *before* the message goes out, so a retry of the same delivery cannot produce two receipts:
    /// the SMP delivery guarantee will happily re-present a frame whose row deletion raced a relaunch, and
    /// an operator counting roll-out progress by receipts needs one per device per generation.
    static func claimAck(for ack: PopopxServerConfigPendingAck) -> Bool {
        var claims = ackClaims
        guard !claims.contains(where: { $0.claimKey == ack.claimKey }) else { return false }
        claims.append(ack)
        if claims.count > maximumTrackedRecords {
            claims = Array(claims.suffix(maximumTrackedRecords))
        }
        persist(claims, forKey: keyAckClaims)
        return true
    }

    /// Releases a claim so a failed send can be retried.
    static func releaseAckClaim(for ack: PopopxServerConfigPendingAck) {
        let claims = ackClaims.filter { $0.claimKey != ack.claimKey }
        persist(claims, forKey: keyAckClaims)
    }

    private static var ackClaims: [PopopxServerConfigPendingAck] {
        decoded([PopopxServerConfigPendingAck].self, forKey: keyAckClaims) ?? []
    }

    /// The receipt that is owed but not yet sent.
    ///
    /// Durable rather than in-memory on purpose: a receipt is only worth sending once the probe window has
    /// a verdict, and the window is exactly the thing a backgrounded or killed process interrupts. Without
    /// this slot the operator would lose the receipt for the one outcome they most want to know about — the
    /// update that had to be rolled back.
    static var pendingAck: PopopxServerConfigPendingAck? {
        get { decoded(PopopxServerConfigPendingAck.self, forKey: keyPendingAck) }
        set { persistIfPresent(newValue, forKey: keyPendingAck) }
    }

    // MARK: Files

    /// The group container, without the force-unwrap `getGroupContainerDirectory` uses
    /// (`FileUtils.swift:64-66`). Both targets declare the group, so nil is not an expected value, but a
    /// nil container must degrade to "this update cannot be rolled back, so it is not applied" rather than
    /// to a crash inside a message handler. `PopopxDecoyProfileGenerator.swift:367-371` makes the same
    /// argument about the same helper.
    static var directoryURL: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_NAME) else { return nil }
        return container.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileURL(_ name: String) -> URL? {
        directoryURL?.appendingPathComponent(name)
    }

    /// Whole-file atomic write with complete file protection, using the same mechanism the decoy store
    /// uses for the same reason (`PopopxDecoyProfileGenerator.swift:417-421`).
    ///
    /// Protected because the rollback snapshot is the user's complete server table — which servers they
    /// use, and since a cluster is reached through several names, how many of them. That is connection
    /// metadata the user never chose to have sitting in an unencrypted copy of the app's container.
    private static func write<T: Encodable>(_ value: T, to name: String) -> Bool {
        guard let url = fileURL(name), let directory = directoryURL else { return false }
        guard let data = encode(value) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try applyCompleteProtection(at: directory)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try applyCompleteProtection(at: url)
            return true
        } catch {
            // The stage only: a path would put the group container name in a log line for no benefit.
            PopopxServerConfigLog.log.error("server config: persisted state could not be written")
            return false
        }
    }

    /// `versionOf` is passed in rather than reached through a protocol so that both record types keep
    /// their own `schemaVersion` without either being made visible to a file-private protocol.
    private static func read<T: Decodable>(
        _ type: T.Type,
        from name: String,
        expectedSchemaVersion: Int,
        versionOf: (T) -> Int
    ) -> T? {
        guard let url = fileURL(name) else { return nil }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            PopopxServerConfigLog.log.error("server config: persisted state unreadable")
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let value = try? decoder.decode(type, from: data) else {
            // Corrupt or written by a different schema: treated as absent, which is the same answer as
            // "nothing staged", and never as "apply whatever the last bytes were".
            PopopxServerConfigLog.log.error("server config: persisted state not decodable")
            remove(name)
            return nil
        }
        guard versionOf(value) == expectedSchemaVersion else {
            remove(name)
            return nil
        }
        return value
    }

    private static func remove(_ name: String) {
        guard let url = fileURL(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func applyCompleteProtection(at url: URL) throws {
        try FileManager.default.setAttributes(
            [FileAttributeKey.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    // MARK: Rollback slot

    /// Writes the pre-apply snapshot. False means the caller must not apply.
    ///
    /// Overwriting an existing snapshot is refused unless the previous update was verified: a snapshot
    /// taken *before* an unverified update is the last known good table, and replacing it mid-window would
    /// leave the device holding the bad configuration as its own fallback.
    static func writeRollback(_ snapshot: PopopxServerConfigSnapshot) -> Bool {
        if verdict == .pending, existingRollbackSequence() != nil { return false }
        return write(snapshot, to: snapshotFileName)
    }

    static func readRollback() -> PopopxServerConfigSnapshot? {
        read(PopopxServerConfigSnapshot.self,
             from: snapshotFileName,
             expectedSchemaVersion: PopopxServerConfigSnapshot.schemaVersion,
             versionOf: \.schemaVersion)
    }

    static func clearRollback() {
        remove(snapshotFileName)
    }

    /// The generation the held snapshot belongs to, without handing the caller the whole table.
    static func existingRollbackSequence() -> Int? {
        readRollback()?.seq
    }

    // MARK: Staging

    static func stage(_ frame: PopopxServerConfigStagedFrame) -> Bool {
        write(frame, to: stagedFileName)
    }

    /// Consumes a staged frame: read and delete in one call, so a promotion that crashes halfway cannot
    /// re-promote the same frame forever. Re-verification on the promotion path is what keeps this safe —
    /// the deleted bytes are the bytes that get checked again.
    static func takeStaged() -> PopopxServerConfigStagedFrame? {
        guard let frame = read(PopopxServerConfigStagedFrame.self,
                               from: stagedFileName,
                               expectedSchemaVersion: PopopxServerConfigStagedFrame.schemaVersion,
                               versionOf: \.schemaVersion) else { return nil }
        remove(stagedFileName)
        return frame
    }

    static func clearStaged() {
        remove(stagedFileName)
    }

    /// Whether anything is waiting for a promotion.
    static var hasStagedFrame: Bool {
        guard let url = fileURL(stagedFileName) else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    // MARK: Codable helpers

    /// One encoder for every persisted value, configured here so that a date never has to be spelled
    /// differently in two places. `UserDefaults` cannot hold a `Date` inside a nested struct, which is why
    /// the records go in as JSON data rather than as property-list values.
    private static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(value)
    }

    private static func persist<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = encode(value) else {
            PopopxServerConfigLog.log.error("server config: state not encodable")
            return
        }
        groupDefaults.set(data, forKey: key)
    }

    private static func persistIfPresent<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value else {
            groupDefaults.removeObject(forKey: key)
            return
        }
        persist(value, forKey: key)
    }

    private static func decoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = groupDefaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let value = try? decoder.decode(type, from: data) else {
            // A record this build cannot read is treated as absent, never as satisfied: an empty floor
            // list re-admits generations the device did apply, which is the recoverable direction because
            // applying a generation twice is a no-op — the merge is by URI and an owned URI that is
            // already present is left alone. An empty *broken* list re-admits a generation that broke
            // connectivity, which the probe window catches and rolls back again. Both end in a working
            // device; neither ends in a silent corruption of the table.
            PopopxServerConfigLog.log.error("server config: state not decodable")
            groupDefaults.removeObject(forKey: key)
            return nil
        }
        return value
    }
}

/// One logger for the module, on the subsystem and category style the other silent features already use
/// (`PopopxSilentSignalingRouter.swift:148`). State changes must leave a trace for development, and
/// nothing that a user can see.
enum PopopxServerConfigLog {
    static let log = Logger(subsystem: "com.popopxchat.popopx", category: "server-config")
}
