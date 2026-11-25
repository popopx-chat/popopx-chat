//
//  ProfileStorageManager.swift
//  POPOPX (iOS)
//
//  [Encrypted personal profile - module one, part two] where the originals sit in the sandbox, and the "after the recipient first opened it" clock.
//
//  All three files - builder, sender, reader - touch the disk only through this one actor: local drafts go through `loadEditable` /
//  `saveEditable`, media goes through `importImage` / `importVideo` / `loadMedia` / `removeMedia`,
//  and timing goes through `readState` / `markFirstOpened` / `forgetRead`. No second path means no second set of semantics.
//
//  ### Hard boundaries
//  1. Touches only `Application Support/PersonalProfile/`. The app's existing `getDocumentsDirectory()` /
//     `getAppFilesDirectory()` (`FileUtils.swift:59`, `:253`) are the territory of the upstream app's attachment history,
//     the two histories do not know each other and neither may write into the other's. The app target has no ready-made Application Support
//     helper, so this derives it itself from `FileManager.default.urls(for:.applicationSupportDirectory,...)`,
//     and creates the intermediate directories itself.
//  2. Every file written to disk is written with `[.atomic, .completeFileProtection]`, and the directory itself gets another pass of
//     `FileAttributeKey.protectionKey = .complete` (the precedent for that form is `PopopxMeshStorage.swift:112`).
//     This file is the first place in the app target that uses `FileProtectionType`, so both the "newly written" and the "already existing file"
//     have to be handled: the write option only applies to the inode created in that one call, and media brought in by `moveItem` and directories
//     created by `createDirectory` each carry their own default attributes.
//  3. On the recipient side `profileId` / `mediaId` are **strings supplied by the peer** (JSON fields inside `data=`).
//     They enter paths, and `removeMedia` therefore uses them to delete files, so they must pass a character whitelist before entering a path --
//     otherwise a single `../../` hands the delete rights out of this sandbox directory.
//  4. Timing uses the wall clock (`Date().timeIntervalSince1970`), not a monotonic clock. The top-secret path has the window lifecycle of
//     `PopopxSecureWindowManager` to rely on, whereas this clock has to cross launches, sessions and repeated openings, so only a wall clock works. A wall clock can be wound back by the owner,
//     so if `now` precedes `firstOpenedAt` by more than the tolerance it is judged `.clockRewound` and treated as already destroyed.
//     This file claims no resistance to clock tampering, only that tampering gets detected.
//  5. Timing records are keyed by `(chatId, itemId)`, not by `profileId`: the same card sent once more is a completely fresh
//     read, and a card that has already burned cannot come back to life because the peer resent it. `forgetRead` deletes the whole record and the destruction path must call it,
//     otherwise a burned row grows a fresh countdown again because its record is still there.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import AVFoundation
import Foundation
import UIKit

// MARK: - Read state

/// The read identity of one profile card on **one particular message**.
///
/// The key carries chatId/itemId rather than profileId; see rule 5 in the file header: a resent business card must start its clock over.
struct PopopxProfileReadKey: Hashable, Sendable, Codable {
    var chatId: Int64
    var itemId: Int64
}

/// The four phases of the read clock. `firstOpenedAt` is returned in every branch except `unread`, so the UI can
/// compute its own progress bar without asking the storage layer a second time.
enum PopopxProfileReadState: Hashable, Sendable {
    /// Never opened (the timing of an `ephemeral` card has not started at this point).
    case unread
    /// Opened, still inside the time limit.
    case counting(firstOpenedAt: TimeInterval, remainingSeconds: Int)
    /// Opened and the time limit has run out: the content must be treated as destroyed.
    case expired(firstOpenedAt: TimeInterval)
    /// The clock was wound back (or the device time moved a lot by a timezone/time-sync change): the content is likewise treated as destroyed, better to let it stay unread.
    case clockRewound(firstOpenedAt: TimeInterval)
}

/// The local read result of one media block. Three cases rather than `URL?`: the card must distinguish "never received" from "received but unreadable",
/// the first is a link problem (a resend can be offered), the second is a local file problem (only "corrupted" can be shown).
enum PopopxProfileMediaLoad: Hashable, Sendable {
    case loaded(URL)
    case missing(mediaId: String)
    case unreadable(mediaId: String, reason: String)
}

/// The reasons this layer (import, compression, transcoding) is allowed to state out loud. Keeping it apart from `PopopxProfileError` is deliberate: that one is
/// a payload/protocol layer failure, changing it means changing the protocol; this one is a failure in the local processing steps. Mixing the two enums
/// would let local errors pollute the protocol-level cases.
enum PopopxProfileMediaError: Error, Hashable, Sendable {
    /// The bytes handed in are not a decodable image at all.
    case undecodableImage
    /// Still above `ProfileStorageManager.maximumImageBytes` after compressing down to the smallest setting.
    case oversizedImage(bytes: Int)
    /// The file handed in is not a decodable video at all (or its duration cannot be read).
    case undecodableVideo
    /// The transcode did not finish, or the device cannot provide this export preset.
    case exportFailed(reason: String)
    /// Still above `ProfileStorageManager.maximumVideoBytes` after the 30 second truncation.
    case oversizedVideo(bytes: Int)
    /// Illegal identifier: `profileId` does not pass the character whitelist checked before entering a path.
    case rejectedIdentifier

    /// One line of Chinese text for the user.
    var reasonText: String {
        switch self {
        case .undecodableImage:
            return NSLocalizedString("This image cannot be read; try another one.", comment: "")
        case let .oversizedImage(bytes):
            return String(format: NSLocalizedString("Compressed to its smallest setting this image is still %1$lld KB, over the %2$lld MB limit for a single image.", comment: ""), bytes / 1_024, ProfileStorageManager.maximumImageBytes / 1_024 / 1_024)
        case .undecodableVideo:
            return NSLocalizedString("This video cannot be read; try another one.", comment: "")
        case let .exportFailed(reason):
            return String(format: NSLocalizedString("Video transcoding did not finish (%@)", comment: ""), reason)
        case let .oversizedVideo(bytes):
            return String(format: NSLocalizedString("Trimmed to %1$lld seconds, this video is still %2$lld KB, over the %3$lld MB limit.", comment: ""), ProfileStorageManager.maximumVideoSeconds, bytes / 1_024, ProfileStorageManager.maximumVideoBytes / 1_024 / 1_024)
        case .rejectedIdentifier:
            return NSLocalizedString("The profile identifier is not valid; the write was refused.", comment: "")
        }
    }
}

// MARK: - Storage

/// Local storage and read clock for profiles. An `actor` rather than a `@MainActor class`: media import is encoding work
/// on the order of minutes (it runs on background threads), while the read clock is asked by the bubble once a second; both must live in the same serial domain but neither should
/// occupy the main thread.
actor ProfileStorageManager {
    static let shared = ProfileStorageManager()

    // MARK: Budgets

    /// Byte ceiling for one compressed image (2 MiB). Library originals are routinely above 8 MB, and a card pushes several within one session.
    static let maximumImageBytes = 2 * 1024 * 1024
    /// Byte ceiling for one exported video (15 MiB). Mesh carries plain text only, so this ceiling constrains the XFTP hop.
    static let maximumVideoBytes = 15 * 1024 * 1024
    /// Video duration ceiling (seconds). Truncate rather than reject: of a user's 3 minute video, the card can use only the first few seconds.
    static let maximumVideoSeconds = 30

    /// The two tables of image compression: the outer loop steps down the longest edge, the inner loop steps down the quality.
    ///
    /// Shrink pixels first and lower quality second, rather than driving `jpegData(compressionQuality:)` all the way down to 0.05: quality-first would
    /// first turn the image into a block of mosaic and then complain about the size, while pixel-first keeps a legible image that is only a little smaller.
    private static let imagePixelLadder: [Int] = [2_560, 1_920, 1_440, 1_080, 800, 600]
    private static let imageQualities: [CGFloat] = [0.85, 0.7, 0.55, 0.4]

    /// Tolerance for wall-clock rewind. 2 seconds covers the fine adjustments of automatic time sync but not an operation like "set the time back ten minutes"
    /// that is meant to make the countdown long again -- that must land on `.clockRewound`.
    private static let clockRewindTolerance: TimeInterval = 2

    /// Upper bound on the allowed character count for an identifier that enters a path (a UUID is 36, with double headroom left for other implementations).
    private static let maximumIdentifierCharacters = 64

    // MARK: Paths

    /// `Application Support/PersonalProfile/`. The app target has no ready-made Application Support helper,
    /// so it is derived here; if it cannot be obtained we fall back to `temporaryDirectory` -- better not to land in the permanent area than to `!` a URL that may be
    /// nil (the form at `FileUtils.swift:59` crashes outright when an external volume is not mounted, and this file does not repeat that mistake).
    static var rootDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (support ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static let directoryName = "PersonalProfile"
    private static let editableName = "manifest.json"
    private static let readStateName = "read-state.json"
    private static let mediaDirectoryName = "media"

    /// Peer identifiers that fail the character whitelist all land in this directory name: that directory is always empty, so the read result is
    /// `.missing` and zero files get deleted. Neither is an out-of-bounds path allowed through, nor is another throwing branch opened for it.
    private static let rejectedIdentifierPlaceholder = "invalid"

    private static var editableURL: URL { rootDirectory.appendingPathComponent(editableName) }
    private static var readStateURL: URL { rootDirectory.appendingPathComponent(readStateName) }

    private static func mediaDirectory(profileId: String) -> URL {
        rootDirectory
            .appendingPathComponent(mediaDirectoryName, isDirectory: true)
            .appendingPathComponent(safeComponent(profileId, fallback: rejectedIdentifierPlaceholder), isDirectory: true)
    }

    private static func fileExtension(for kind: PopopxProfileMedia.Kind) -> String {
        switch kind {
        case .image: return "jpg"
        case .video: return "mp4"
        }
    }

    /// One component inside a path. Only `[A-Za-z0-9-_]` is allowed: `.` is not in it, so `..`, `.` and any dotted
    /// variant are replaced wholesale by the fallback, and `/` can hardly get in at all.
    private static func safeComponent(_ raw: String, fallback: String) -> String {
        guard !raw.isEmpty, raw.count <= maximumIdentifierCharacters else { return fallback }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return fallback }
        return raw
    }

    /// Whether a value can be used as a path component as-is. Only what passes here may be written into the sandbox; the reading side needs no such gate,
    /// because `safeComponent` has already replaced out-of-bounds values with a directory name that is necessarily empty.
    private static func isSafeIdentifier(_ raw: String) -> Bool {
        !raw.isEmpty && safeComponent(raw, fallback: rejectedIdentifierPlaceholder) == raw
    }

    // MARK: On-disk attributes

    /// Creates the directory and gives it `.complete` protection. When it already exists `createDirectory(withIntermediateDirectories:true)`
    /// is idempotent, and so are the attributes, so it can be called blindly before every write.
    private static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        applyProtection(at: url)
    }

    /// Atomic write plus `.complete` protection. The `.completeFileProtection` of `Data.write` only guarantees that the inode **created this one time**
    /// carries protection; it cannot cover the case of a file that existed long before with other attributes (`.atomic` swaps in a new inode, but directory attributes
    /// and the media moved in by `moveItem` still need patching), so the attributes are set explicitly once more after the write.
    private static func write(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        applyProtection(at: url)
    }

    /// Applies the attribute afterwards. Failure is only logged, never thrown: on a volume without data protection (simulator, external volume) this call is doomed to fail,
    /// and "refuse to save the profile because protection cannot be set" would make the whole feature look broken on a development machine. On a real device this one always succeeds,
    /// and the failed attempt leaves a trace in the log.
    private static func applyProtection(at url: URL) {
        do {
            try FileManager.default.setAttributes(
                [FileAttributeKey.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        } catch {
            logger.error("POPOPX profile: could not set complete file protection for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func discard(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("POPOPX profile: the temporary file was not deleted \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Local draft

    /// Reads the local editable draft. Returning nil covers two situations: nothing has been stored yet, or the file cannot be read (unrecognised version, broken JSON,
    /// over budget). **Neither case deletes the file**: an undecodable draft is forensic evidence, and silently wiping the user's text and images would be a second incident.
    func loadEditable() -> PopopxProfileManifest? {
        let url = Self.editableURL
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("POPOPX profile: the draft could not be read (\(error.localizedDescription, privacy: .public))")
            return nil
        }
        guard let manifest = PopopxProfileManifest.decoded(json: data) else {
            logger.error("POPOPX profile: the draft content is not valid; the original file is kept and not overwritten")
            return nil
        }
        return manifest
    }

    /// Stores the local draft.
    ///
    /// What gets written is **the copy that was passed in**, not the `normalized()` one: `deliveryMode` is a decision made at send time
    /// rather than a property of the content, and normalization would drop every media block because of `.meshTextOnly` -- saving once would delete the images the user made,
    /// which is unacceptable. Validation goes through this same gate as `PopopxProfilePayload.make`: a draft must be **sendable**,
    /// and failing at save time is far cheaper than failing when send is tapped.
    func saveEditable(_ manifest: PopopxProfileManifest) throws {
        _ = try PopopxProfilePayload.make(manifest)
        let data = try manifest.encodedJSON()
        try Self.write(data, to: Self.editableURL)
    }

    // MARK: Media

    /// Image: decode -> compress inside 2 MiB following the two pixel/quality tables -> write to disk.
    ///
    /// Always JPEG (not following the "store PNG when there is alpha" decision at `ImageUtils.swift:97`): a card wants a predictable
    /// size, and PNG simply does not compress library photos. **Re-encoding drops all EXIF/GPS along the way** -- this is not
    /// a side effect but the goal: letting an original with capture coordinates into the profile would hang the user's location on their own business card.
    func importImage(_ data: Data, profileId: String) throws -> PopopxProfileMedia {
        guard Self.isSafeIdentifier(profileId) else { throw PopopxProfileMediaError.rejectedIdentifier }
        guard let image = UIImage(data: data) else { throw PopopxProfileMediaError.undecodableImage }
        let jpeg = try Self.compress(image: image)
        let media = PopopxProfileMedia(
            mediaId: UUID().uuidString.lowercased(),
            kind: .image,
            bytes: jpeg.count,
            durationSeconds: nil,
            caption: nil
        )
        try Self.write(jpeg, to: mediaURL(media, profileId: profileId))
        return media
    }

    /// The compression loop that puts pixels first and quality second. It only rejects when every rung has been run through and the size is still over (see the `imagePixelLadder` block).
    private static func compress(image: UIImage) throws -> Data {
        var current = image
        var lastBytes = 0
        for side in imagePixelLadder {
            current = current.popopxProfileScaled(maximumPixelSide: side)
            for quality in imageQualities {
                guard let encoded = current.jpegData(compressionQuality: quality) else {
                    throw PopopxProfileMediaError.undecodableImage
                }
                lastBytes = encoded.count
                if encoded.count <= maximumImageBytes { return encoded }
            }
        }
        throw PopopxProfileMediaError.oversizedImage(bytes: lastBytes)
    }

    /// Video: truncate to 30 seconds -> transcode -> keep only if inside the 15 MiB budget.
    ///
    /// The transcode reuses the choice the app already makes (the `AVAssetExportSession` at `ImageUtils.swift:350`-`:363` +
    /// `AVAssetExportPreset640x480`): that preset outputs H.264 and is the only export path in the whole app verified on a real device,
    /// so swapping in a new encoding configuration would open a second path inside this feature that nobody has validated.
    /// The `metadataItemFilter = .forSharing()` follows it as well: the author, the device model and the recording location are all in that
    /// metadata, and a profile video should not carry them out of the door.
    func importVideo(from url: URL, profileId: String) async throws -> PopopxProfileMedia {
        guard Self.isSafeIdentifier(profileId) else { throw PopopxProfileMediaError.rejectedIdentifier }
        let directory = Self.mediaDirectory(profileId: profileId)
        try Self.ensureDirectory(directory)
        let mediaId = UUID().uuidString.lowercased()
        let output = directory.appendingPathComponent("\(mediaId).\(Self.fileExtension(for: .video))")
        // The exporter requires that the output file does not exist, and the file it writes itself does not carry the protection attributes we want,
        // so it is first exported to a temporary name in the same directory, protection is applied, then it is renamed to the real name (renaming on the same volume is atomic).
        let temporary = directory.appendingPathComponent("\(mediaId).exporting.mp4")
        var committed = false
        defer { if !committed { Self.discard(temporary) } }

        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw PopopxProfileMediaError.undecodableVideo
        }
        guard duration.seconds.isFinite, duration.seconds > 0 else {
            throw PopopxProfileMediaError.undecodableVideo
        }
        let seconds = min(duration.seconds, Double(Self.maximumVideoSeconds))
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset640x480) else {
            throw PopopxProfileMediaError.exportFailed(reason: NSLocalizedString("This device does not support the 640×480 export preset", comment: ""))
        }
        session.outputURL = temporary
        session.outputFileType = .mp4
        session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        await session.export()
        guard session.status == .completed else {
            throw PopopxProfileMediaError.exportFailed(reason: session.error?.localizedDescription ?? NSLocalizedString("The export did not reach a completed state", comment: ""))
        }
        let exported = (try? FileManager.default.attributesOfItem(atPath: temporary.path)) ?? [:]
        guard let bytes = (exported[.size] as? NSNumber)?.int64Value, bytes > 0 else {
            throw PopopxProfileMediaError.exportFailed(reason: NSLocalizedString("The export produced no result", comment: ""))
        }
        guard bytes <= Int64(Self.maximumVideoBytes) else {
            throw PopopxProfileMediaError.oversizedVideo(bytes: Int(bytes))
        }
        if FileManager.default.fileExists(atPath: output.path) {
            // mediaId is a freshly generated UUID, so it cannot collide; if it does, local state is broken, and letting the new file overwrite the old one is more useful than
            // throwing an error the user cannot read.
            Self.discard(output)
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            throw PopopxProfileMediaError.exportFailed(reason: error.localizedDescription)
        }
        Self.applyProtection(at: output)
        committed = true
        return PopopxProfileMedia(
            mediaId: mediaId,
            kind: .video,
            bytes: Int(bytes),
            durationSeconds: Int(seconds.rounded()),
            caption: nil
        )
    }

    /// The local path of a given media block. The extension is decided by `kind` and never comes from that JSON off the wire, so the path suffix
    /// is also out of reach of uncontrolled input on this side.
    func mediaURL(_ media: PopopxProfileMedia, profileId: String) -> URL {
        Self.mediaDirectory(profileId: profileId)
            .appendingPathComponent("\(Self.safeComponent(media.mediaId, fallback: Self.rejectedIdentifierPlaceholder)).\(Self.fileExtension(for: media.kind))")
    }

    /// Only checks "is it there, can it be read, is it empty" without reading bytes into memory: a 15 MiB video is loaded
    /// on demand by the UI side, and reading the whole block here on its behalf would only spend all the memory while proving nothing extra.
    func loadMedia(_ media: PopopxProfileMedia, profileId: String) -> PopopxProfileMediaLoad {
        let url = mediaURL(media, profileId: profileId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing(mediaId: media.mediaId)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .unreadable(mediaId: media.mediaId, reason: NSLocalizedString("The file is not readable", comment: ""))
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attributes else {
            return .unreadable(mediaId: media.mediaId, reason: NSLocalizedString("The file attributes could not be read", comment: ""))
        }
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return .unreadable(mediaId: media.mediaId, reason: NSLocalizedString("The file size could not be read", comment: ""))
        }
        guard size > 0 else {
            return .unreadable(mediaId: media.mediaId, reason: NSLocalizedString("The file content is empty", comment: ""))
        }
        return .loaded(url)
    }

    /// Deletes by id. The signature has only the id and no `kind`, so both the real name and that `.exporting.mp4` temporary name must be hit:
    /// match on the `id.` prefix instead of assembling one specific extension.
    func removeMedia(profileId: String, ids: [String]) {
        let directory = Self.mediaDirectory(profileId: profileId)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let wanted = Set(ids.map { Self.safeComponent($0, fallback: Self.rejectedIdentifierPlaceholder) + "." })
        for entry in entries where wanted.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
            Self.discard(entry)
        }
    }

    /// Burns all originals of a whole profile (view-once time up, or panic cleanup). The directory is removed with them,
    /// so that no empty directory is left for the callers of `removeAllMedia` to mistake for something still being there.
    func removeAllMedia(profileId: String) {
        let directory = Self.mediaDirectory(profileId: profileId)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        Self.discard(directory)
    }

    // MARK: Read clock

    /// The current read state of one card.
    ///
    /// The first time a key is asked about, the `ttlSeconds` given in that call are **bound to the record**: the
    /// signature of `markFirstOpened` has no duration parameter at all, so it can only take the value from that binding. The side effect pointing in this direction is deliberate --
    /// the bubble calls this function on every redraw, so before the card is really opened the binding is certainly already written.
    func readState(_ key: PopopxProfileReadKey, ttlSeconds: Int, now: Date) -> PopopxProfileReadState {
        let stored = stateTable()[Self.stateKey(key)] ?? Record(ttlSeconds: nil, firstOpenedAt: nil)
        guard let openedAt = stored.firstOpenedAt else {
            if stored.ttlSeconds != ttlSeconds {
                setRecord(Record(ttlSeconds: ttlSeconds, firstOpenedAt: nil), for: key)
            }
            return .unread
        }
        return Self.deriveState(firstOpenedAt: openedAt, ttlSeconds: ttlSeconds, now: now)
    }

    /// Records the moment of the "first open". Repeated calls are idempotent: a card that has already been recorded **keeps its original start time**,
    /// so quitting and re-entering, or backgrounding and coming back, cannot mint a fresh time limit -- which is exactly the thing "start the clock on open" is meant to prevent.
    func markFirstOpened(_ key: PopopxProfileReadKey) -> PopopxProfileReadState {
        let now = Date()
        let stored = stateTable()[Self.stateKey(key)] ?? Record(ttlSeconds: nil, firstOpenedAt: nil)
        let openedAt = stored.firstOpenedAt ?? now.timeIntervalSince1970
        setRecord(Record(ttlSeconds: stored.ttlSeconds, firstOpenedAt: openedAt), for: key)
        return Self.deriveState(firstOpenedAt: openedAt, ttlSeconds: stored.ttlSeconds, now: now)
    }

    /// Erases the read record of a card. The destruction path must call it: while the record stays, the card grows a countdown again on the next render.
    func forgetRead(_ key: PopopxProfileReadKey) {
        guard stateTable()[Self.stateKey(key)] != nil else { return }
        setRecord(nil, for: key)
    }

    // MARK: Persisting the read state

    private struct Record: Codable, Hashable {
        var ttlSeconds: Int?
        var firstOpenedAt: TimeInterval?
    }

    /// An in-memory table, pulled from disk the first time it is used. Writing out happens after every change, so the cache here and the file stay aligned on the success path;
    /// for the exception see `stateFileIsUnreadable`.
    private var records: [String: Record]?

    /// There is a **present but undecodable** state file on disk. Such a file is the only wreckage of this clock: the session keeps timing from memory as usual,
    /// but no longer writes to that path, so as not to turn the scene of "which cards the user has already burned" into a blob of brand-new data.
    private var stateFileIsUnreadable = false

    private static func stateKey(_ key: PopopxProfileReadKey) -> String {
        "\(key.chatId):\(key.itemId)"
    }

    private func stateTable() -> [String: Record] {
        if let records { return records }
        var loaded: [String: Record] = [:]
        let url = Self.readStateURL
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
                loaded = decoded
            } else {
                // The file is there but the whole thing fails to decode: the synthesised Codable dictionary is all-or-nothing, half a record cannot be rescued.
                stateFileIsUnreadable = true
                logger.error("POPOPX profile: the reading-state file cannot be decoded; this session starts from an empty table and will not overwrite that file")
            }
        }
        records = loaded
        return loaded
    }

    /// Mutates the table and writes it out. None of this layer's three timing interfaces throws (`readState` is asked by the bubble once a second, `markFirstOpened`
    /// sits right under the user's finger), so a failed write can only be logged.
    ///
    /// This weakness must be written out: after a failed write the session still follows memory and everything looks normal, but **after a restart the timing falls back to
    /// `unread`**, and the recipient gets to read it once more. This is the inherent cost of a wall clock plus file storage; there is no false claim of
    /// the monotonic guarantees of the top-secret link.
    private func setRecord(_ record: Record?, for key: PopopxProfileReadKey) {
        var table = stateTable()
        let id = Self.stateKey(key)
        if let record {
            table[id] = record
        } else {
            table.removeValue(forKey: id)
        }
        records = table
        guard !stateFileIsUnreadable else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try Self.write(try encoder.encode(table), to: Self.readStateURL)
        } catch {
            logger.error("POPOPX profile: writing the reading state failed (\(error.localizedDescription, privacy: .public)); after a restart the timers may fall back to unread")
        }
    }

    /// Computes the current phase from the start moment.
    ///
    /// This clock only means something for `ephemeral`: a permanent business card must not go through it (`PopopxProfilePayload.isEphemeral`
    /// is the only gate), because any cell here answering "the time limit is reached" makes the action on the UI side delete the content.
    ///
    /// Passing nil for `ttlSeconds` is reachable on only one path: `markFirstOpened` called cold (never following
    /// the order "first `readState` to bind the duration, then open"). That case gives 0 seconds remaining rather than guessing a longer time limit --
    /// for the privacy semantics shorter is preferred over longer, and the next `readState` carrying the real duration immediately computes the correct remaining seconds back.
    private static func deriveState(firstOpenedAt: TimeInterval, ttlSeconds: Int?, now: Date) -> PopopxProfileReadState {
        // The record itself may hold values left over from a broken file (0, negative, NaN). In that case there is no "how much is left" to speak of,
        // so it is handled as already at the limit instead of letting a brand-new full time limit through.
        guard firstOpenedAt.isFinite, firstOpenedAt > 0 else { return .expired(firstOpenedAt: 0) }
        let elapsed = now.timeIntervalSince1970 - firstOpenedAt
        guard elapsed.isFinite else { return .expired(firstOpenedAt: firstOpenedAt) }
        if elapsed < -clockRewindTolerance {
            return .clockRewound(firstOpenedAt: firstOpenedAt)
        }
        guard let ttl = ttlSeconds else {
            return .counting(firstOpenedAt: firstOpenedAt, remainingSeconds: 0)
        }
        let passed = max(0, elapsed)
        // Judge it dead by value range first and only then convert to `Int`: a start earlier than 1970 would make `Int(passed)` trap outright,
        // and "expired long ago" is the correct answer to that range problem anyway.
        guard passed < Double(ttl + 1) else { return .expired(firstOpenedAt: firstOpenedAt) }
        // Round up: rounding down equals giving away up to 1 free second on every second boundary, rounding up declares death early.
        let remaining = ttl - Int(passed.rounded(.up))
        guard remaining > 0 else { return .expired(firstOpenedAt: firstOpenedAt) }
        return .counting(firstOpenedAt: firstOpenedAt, remainingSeconds: remaining)
    }
}

// MARK: - Image scaling

extension UIImage {
    /// Scale proportionally until the longest edge is no more than `side` pixels; if it is already small enough return it as-is (no redraw that produces nothing).
    fileprivate func popopxProfileScaled(maximumPixelSide side: Int) -> UIImage {
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        guard pixels.width > 1, pixels.height > 1, side > 0 else { return self }
        let longest = max(pixels.width, pixels.height)
        guard longest > Double(side) else { return self }
        let factor = Double(side) / longest
        let target = CGSize(
            width: max(1, floor(pixels.width * factor)),
            height: max(1, floor(pixels.height * factor))
        )
        let format = UIGraphicsImageRendererFormat.default()
        // `scale = 1`: the target size here is already the pixel size, so let the renderer not multiply by the screen scale again -- that would amount to scaling for nothing.
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            self.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
