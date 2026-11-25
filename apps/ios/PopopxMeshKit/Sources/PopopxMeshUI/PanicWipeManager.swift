//
//  PanicWipeManager.swift
//  PopopxMeshUI
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Emergency wipe for red lines 27/28: three taps, one confirmation, then everything this feature ever wrote is
//  gone and the process dies so no key can survive in memory.
//
//  The order is the security property, and it is not negotiable:
//
//      1. stopRadio                 — no scan, no advertisement, no in-flight frame
//      2. clearVolatileState        — Noise sessions and the static key leave memory
//      3. eraseKeychainMapping      — the durable identity map and the mesh switches
//      4. overwriteMeshSandbox      — the mesh's own files, overwritten before they are removed
//      5. overwriteApplicationDatabase — ONLY on an explicit non-default opt-in
//      6. terminate                 — the process ends, so nothing re-derives state afterwards
//
//  Step 5 exists as an option and not as a default. The app's real SQLCipher database belongs to the
//  chat, and the red line forbids any part of this feature from touching it unless a caller deliberately
//  asks for it; even then this package cannot know the path, so the host must hand one over. A
//  request for step 5 without a URL is reported as a refusal, never as a success.
//
//  Both the process exit and the filesystem root are injectable for exactly that reason: the tests
//  assert the order without killing the test runner and without writing into a real Documents folder.
//

import Combine
import Foundation
import PopopxMeshKit
import SwiftUI
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Steps

/// One step of the wipe. The declaration order *is* the promised order, so the rank cannot drift.
public enum PopopxPanicWipeStep: String, CaseIterable, Sendable, Comparable {
    case stopRadio
    case clearVolatileState
    case eraseKeychainMapping
    case overwriteMeshSandbox
    case overwriteApplicationDatabase
    case terminate

    /// The position in the promised order, derived from `allCases`.
    public var rank: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }

    public static func < (lhs: PopopxPanicWipeStep, rhs: PopopxPanicWipeStep) -> Bool {
        lhs.rank < rhs.rank
    }

    /// What the user is told is happening, one phrase per step, so the confirm sheet can be built
    /// from the same source as the wipe.
    public var words: String {
        switch self {
        case .stopRadio: return "stop Bluetooth"
        case .clearVolatileState: return "clear session keys"
        case .eraseKeychainMapping: return "erase the identity map"
        case .overwriteMeshSandbox: return "overwrite mesh files"
        case .overwriteApplicationDatabase: return "overwrite the chat database"
        case .terminate: return "close the app"
        }
    }
}

/// Why a step did not finish. Named per step, so a report can say what survived on a device the user
/// is afraid of losing.
public enum PopopxPanicWipeFailure: Hashable, Sendable {
    case radioStep(reason: String)
    case keyStep(reason: String)
    case mappingStep(reason: String)
    case sandboxStep(path: String, reason: String)
    case databaseStep(path: String, reason: String)
    /// Opt-in was requested but no URL was supplied: refusing is the only safe answer, because
    /// guessing at a chat database path from a package risks deleting the wrong file.
    case databaseStepRefused(reason: String)

    /// Which step this failure belongs to — used to keep the journal honest about a step that partly
    /// ran.
    public var step: PopopxPanicWipeStep {
        switch self {
        case .radioStep: return .stopRadio
        case .keyStep: return .clearVolatileState
        case .mappingStep: return .eraseKeychainMapping
        case .sandboxStep: return .overwriteMeshSandbox
        case .databaseStep, .databaseStepRefused: return .overwriteApplicationDatabase
        }
    }
}

/// What one wipe did, in the order it did it.
public struct PopopxPanicWipeJournal: Hashable, Sendable {
    public var steps: [PopopxPanicWipeStep] = []
    public var erasedFiles: [String] = []
    public var failures: [PopopxPanicWipeFailure] = []
    /// Whether the app's own database file was opened for writing. `false` is the red-line-mandated
    /// default, and the tests hold the manager to it.
    public var didTouchApplicationDatabase = false

    public init() {}
}

public struct PopopxPanicWipeReport: Hashable, Sendable {
    /// Every step that ran, in the order it ran. An empty array is a wipe that never started; a
    /// sequence out of order is a bug, not a detail.
    public let steps: [PopopxPanicWipeStep]
    /// Paths whose bytes were overwritten before removal, so the caller can show a count instead of a
    /// promise.
    public let erasedFiles: [String]
    public let failures: [PopopxPanicWipeFailure]
    public let didTouchApplicationDatabase: Bool

    public init(journal: PopopxPanicWipeJournal) {
        self.steps = journal.steps
        self.erasedFiles = journal.erasedFiles
        self.failures = journal.failures
        self.didTouchApplicationDatabase = journal.didTouchApplicationDatabase
    }

    public init(
        steps: [PopopxPanicWipeStep],
        erasedFiles: [String],
        failures: [PopopxPanicWipeFailure],
        didTouchApplicationDatabase: Bool
    ) {
        self.steps = steps
        self.erasedFiles = erasedFiles
        self.failures = failures
        self.didTouchApplicationDatabase = didTouchApplicationDatabase
    }

    public var isClean: Bool { failures.isEmpty }

    /// True when the steps ran in the promised order.
    public var isInOrder: Bool {
        zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// A one-line summary for a log or a footer: what is left on the device.
    public var summary: String {
        if failures.isEmpty {
            return "wiped \(steps.count) step(s), \(erasedFiles.count) file(s) overwritten"
        }
        return "wiped \(steps.count) step(s), \(failures.count) failure(s)"
    }
}

/// Observer for the wipe's progress. Non-isolated and `Sendable` on purpose: the recorder is the
/// thing a test asserts on, so it has to be readable from outside the main actor — including from a
/// `deinit` — without an isolation hop.
///
/// One asymmetry, and it is the honest one: every step is told to have started, and every step except
/// `.terminate` is also told to have finished. A wipe that really did terminate cannot report that the
/// terminate step *completed*, because nothing runs after `exit(0)`; `start:terminate` is the last
/// entry a recorder ever sees for a full wipe, which is exactly what makes "the exit is the last step,
/// and nothing follows it" assertable.
public protocol PopopxPanicWipeRecording: Sendable {
    func panicWipeDidStart(step: PopopxPanicWipeStep)

    func panicWipeDidFinish(step: PopopxPanicWipeStep, erasedFileCount: Int)

    func panicWipeDidFail(_ failure: PopopxPanicWipeFailure, at step: PopopxPanicWipeStep)
}

public extension PopopxPanicWipeRecording {
    /// A recorder that only cares about failures should not have to write two empty methods.
    func panicWipeDidStart(step: PopopxPanicWipeStep) {}

    func panicWipeDidFinish(step: PopopxPanicWipeStep, erasedFileCount: Int) {}
}

/// The default recorder: nobody is watching.
public struct PopopxPanicWipeSilentRecorder: PopopxPanicWipeRecording {
    public init() {}

    public func panicWipeDidStart(step: PopopxPanicWipeStep) {}

    public func panicWipeDidFinish(step: PopopxPanicWipeStep, erasedFileCount: Int) {}

    public func panicWipeDidFail(_ failure: PopopxPanicWipeFailure, at step: PopopxPanicWipeStep) {}
}

// // MARK: - Contracts with module 1 and module 2

/// How the panic route destroys the mesh's own key material. `PopopxMeshEngine.destroyIdentity()`
/// already regenerates the static key, drops every peer table and removes the Keychain item, and
/// `destroyGroupState()` takes module 8's half with it — every group key, the roster file and the
/// Ed25519 signing key — the conformance below is the whole binding, and no core file is edited.
public protocol PopopxMeshKeyBurning: Sendable {
    func burnMeshKeys() async
}

extension PopopxMeshEngine: PopopxMeshKeyBurning {
    public func burnMeshKeys() async {
        destroyIdentity()
        await destroyGroupState()
    }
}

/// How the panic route clears the durable identity map, the mesh switches in `UserDefaults` and the
/// plain cache files. `IdentityMappingStore.emergencyWipeAllMappings()` already does all three and
/// reports every failure it hit.
public protocol PopopxMeshMappingErasing: Sendable {
    func eraseAllMeshMappings() async -> PopopxMeshWipeReport
}

extension IdentityMappingStore: PopopxMeshMappingErasing {
    public func eraseAllMeshMappings() async -> PopopxMeshWipeReport {
        emergencyWipeAllMappings()
    }
}

// MARK: - Overwrite-then-delete

/// Deletes a file by overwriting its bytes first, then removing it.
///
/// Two passes — zeros, then a random pattern — because a single zero pass is the kind of "secure
/// delete" a reviewer should question: APFS is copy-on-write, so overwriting in place may allocate
/// new blocks and leave the old ones for the disk's own garbage collection. What this does guarantee
/// is that the file the app can still reach holds no readable mesh payload, and that a companion
/// `-wal`/`-journal` cannot keep committed rows alive after the main file is gone. Full-disk
/// encryption remains the real defence, and saying so here is more useful than pretending otherwise.
public struct PopopxMeshSecureDeleter: @unchecked Sendable {
    /// The largest buffer written at a time: 64 KiB is enough to cover a pass without holding a copy
    /// of a large database in memory.
    public static let patternByteCount = 64 * 1024

    /// `@unchecked Sendable`, justified: `FileManager`'s own documentation states its methods are
    /// safe to call from multiple threads, and the only mutable state an instance can hold is a
    /// delegate — which this type never sets, and which no caller can reach through a `let`. The
    /// stored value is therefore immutable and the shared singleton it usually holds is stateless.
    public let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// SQLCipher's companions. A `-wal` file holds pages that are not in the main file yet, so
    /// erasing only the main file would leave readable chat rows behind; same for `-journal`.
    public static func companionURLs(of url: URL) -> [URL] {
        ["-wal", "-shm", "-journal"].map { suffix in
            URL(fileURLWithPath: url.path + suffix)
        }
    }

    public func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    /// The bytes a pass writes: `count` zeroes, or a random pattern when `randomised`.
    static func passBuffer(byteCount: Int, randomised: Bool) -> Data {
        guard byteCount > 0 else { return Data() }
        var buffer = Data(count: byteCount)
        if randomised {
            for index in buffer.indices {
                buffer[index] = UInt8.random(in: 0...255)
            }
        }
        return buffer
    }

    /// Overwrite the file and its companions, then remove them. Throws the underlying IO failure so
    /// the caller can name the path that survived.
    @discardableResult
    public func erase(fileAt url: URL) throws -> Bool {
        guard fileExists(at: url) else { return false }
        let targets = ([url] + Self.companionURLs(of: url)).filter { fileExists(at: $0) }
        for target in targets {
            let length = byteLength(of: target)
            if length > 0 {
                try overwrite(url: target, byteCount: length)
            }
            do {
                try fileManager.removeItem(at: target)
            } catch {
                throw PopopxMeshStorageError.writeFailed(
                    path: target.path,
                    underlying: "removeItem after overwrite failed: \(error.localizedDescription)"
                )
            }
        }
        return true
    }

    /// Every regular file under `directory`, deepest first, then the (now empty) directory itself.
    /// Returns the paths whose bytes were overwritten, so the report can count them.
    @discardableResult
    public func erase(directoryAt url: URL) throws -> [String] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let walker = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            throw PopopxMeshStorageError.directoryUnusable(path: url.path, underlying: "cannot enumerate")
        }
        var found: [URL] = []
        for case let item as URL in walker {
            found.append(item)
        }
        var erased: [String] = []
        // Deepest first: a file inside a subdirectory must be gone before its parent is removed.
        for item in found.reversed() where !item.path.hasSuffix("-wal") && !item.path.hasSuffix("-shm") && !item.path.hasSuffix("-journal") {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fileManager.removeItem(at: item)
            } else if try erase(fileAt: item) {
                erased.append(item.path)
            }
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw PopopxMeshStorageError.directoryUnusable(
                path: url.path,
                underlying: "directory survived removal: \(error.localizedDescription)"
            )
        }
        return erased
    }

    private func byteLength(of url: URL) -> Int {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return max(0, Int(size?.int64Value ?? 0))
    }

    /// The two passes, written through one handle so nothing renames the file out from under them.
    private func overwrite(url: URL, byteCount: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for randomised in [false, true] {
            let buffer = Self.passBuffer(
                byteCount: min(byteCount, Self.patternByteCount),
                randomised: randomised
            )
            try? handle.seek(toOffset: 0)
            var written = 0
            while written < byteCount {
                let chunk = min(buffer.count, byteCount - written)
                if chunk <= 0 { break }
                handle.write(buffer.prefix(chunk))
                written += chunk
            }
            try? handle.synchronize()
        }
    }
}

// MARK: - Three-tap arming

/// The gesture that asks. Deliberately its own type: "three taps inside one second, and nothing
/// else" is a rule, and a rule written inside a view modifier is a rule nobody can test.
@MainActor
public final class PopopxPanicWipeArming: ObservableObject {
    /// Taps separated by more than this are unrelated taps. A user who taps the screen three times
    /// while scrolling must not be one tap away from a wipe.
    public static let tapWindow: TimeInterval = 1.0

    /// Exactly three. A fourth tap is a mis-click on a screen that has not reacted yet, so it resets
    /// the sequence instead of firing the confirmation a second time.
    public static let requiredTaps = 3

    /// How long the confirmation stays answerable. Past that the user has stopped looking at the
    /// phone, and an alert that wipes when finally tapped is not a confirmation.
    public static let confirmLifetime: TimeInterval = 15

    @Published public private(set) var tapCount = 0

    /// Set when the third tap lands; the view binds its alert to this.
    @Published public private(set) var isAwaitingConfirmation = false

    private var firstTapAt: Date?
    private var confirmationRequestedAt: Date?

    public init() {}

    /// One tap. Returns true only when the sequence reached exactly three inside the window.
    @discardableResult
    public func tap(now: Date = .now) -> Bool {
        // Tapping while the sheet is up is the "never mind" gesture: the sequence is abandoned, and
        // the sheet itself is the only thing that can start a wipe.
        if isAwaitingConfirmation {
            reset()
            return false
        }
        if let first = firstTapAt, now.timeIntervalSince(first) > Self.tapWindow {
            tapCount = 0
            firstTapAt = nil
        }
        if firstTapAt == nil {
            firstTapAt = now
        }
        tapCount += 1
        guard tapCount >= Self.requiredTaps else { return false }
        let armed = tapCount == Self.requiredTaps
        reset()
        guard armed else { return false }
        isAwaitingConfirmation = true
        confirmationRequestedAt = now
        return true
    }

    /// The user answered, either way, so nothing may stay armed.
    public func resolveConfirmation() {
        reset()
    }

    /// Consent has a shelf life: an alert nobody answered within `confirmLifetime` no longer means
    /// "yes" when it is finally tapped.
    public func confirmationIsStillValid(now: Date = .now) -> Bool {
        guard isAwaitingConfirmation, let requested = confirmationRequestedAt else { return false }
        if now.timeIntervalSince(requested) > Self.confirmLifetime {
            reset()
            return false
        }
        return true
    }

    public func reset() {
        tapCount = 0
        firstTapAt = nil
        confirmationRequestedAt = nil
        isAwaitingConfirmation = false
    }
}

// MARK: - Manager

/// The panic wipe, as an object the settings page and the hidden trigger both talk to.
@MainActor
public final class PopopxPanicWipeManager: ObservableObject {
    /// The real exit. Nothing in a test may reach this, which is why it is a stored closure and not a
    /// call.
    public static let processExit: @Sendable (Int32) -> Void = { status in
        exit(status)
    }

    /// A promise, in code: no interface in this package can ever ask for step 5. The only way the
    /// app's SQLCipher file is opened for overwriting is a host that calls
    /// `execute(includeApplicationDatabase:)` with `true` itself, knowing the path.
    public static let interfaceOptInToDatabaseErase = false

    @Published public private(set) var lastReport: PopopxPanicWipeReport?

    @Published public private(set) var isWiping = false

    public let arming: PopopxPanicWipeArming

    private let radio: [any PopopxMeshSwitchable]
    private let keys: any PopopxMeshKeyBurning
    private let mapping: any PopopxMeshMappingErasing
    private let inMemoryMirrors: [any PopopxMeshSwitchable]
    private let deleter: PopopxMeshSecureDeleter
    private let meshDirectory: URL
    private let applicationDatabaseURL: URL?
    private let termination: (@Sendable (Int32) -> Void)?
    private let recorder: any PopopxPanicWipeRecording

    /// - Parameters:
    ///   - radio: whatever holds a Bluetooth manager open — the fuse's components (engine, health
    ///     monitor, pairing manager) all conform to `PopopxMeshSwitchable` already, and they are
    ///     stopped in the order given.
    ///   - inMemoryMirrors: the UI-side state sources whose published content *is* mesh traffic. They
    ///     are cleared with the keys, not with the radio, because a banner that still shows a peer
    ///     after a wipe is a leak the user can see.
    ///   - meshDirectory: module 1's sandbox, `Documents/popopx_mesh/`. Injectable so tests write to a
    ///     temporary directory instead of a real container.
    ///   - applicationDatabaseURL: the app's SQLCipher file, if the host is willing to let it be
    ///     erased at all. Held here rather than passed per call, so "the caller knew the path" is a
    ///     property of how the manager was built, not of a flag flipped late.
    ///   - termination: `Self.processExit` in the app; `nil` (or a recorder) in tests, where killing
    ///     the process would kill the runner.
    public init(
        radio: [any PopopxMeshSwitchable] = [PopopxMeshEngine.shared, BluetoothHealthMonitor.shared],
        keys: any PopopxMeshKeyBurning = PopopxMeshEngine.shared,
        mapping: any PopopxMeshMappingErasing = IdentityMappingStore.shared,
        inMemoryMirrors: [any PopopxMeshSwitchable] = [PopopxMeshStateSource.shared],
        deleter: PopopxMeshSecureDeleter = PopopxMeshSecureDeleter(),
        meshDirectory: URL = PopopxMeshPaths.meshDirectory(),
        applicationDatabaseURL: URL? = nil,
        termination: (@Sendable (Int32) -> Void)? = PopopxPanicWipeManager.processExit,
        recorder: any PopopxPanicWipeRecording = PopopxPanicWipeSilentRecorder(),
        arming: PopopxPanicWipeArming = PopopxPanicWipeArming()
    ) {
        self.radio = radio
        self.keys = keys
        self.mapping = mapping
        self.inMemoryMirrors = inMemoryMirrors
        self.deleter = deleter
        self.meshDirectory = meshDirectory
        self.applicationDatabaseURL = applicationDatabaseURL
        self.termination = termination
        self.recorder = recorder
        self.arming = arming
    }

    // MARK: The gesture

    /// Forwards a tap to the arming state machine, so a view has one object to talk to.
    @discardableResult
    public func tap(at now: Date = .now) -> Bool {
        arming.tap(now: now)
    }

    public var isAwaitingConfirmation: Bool {
        arming.isAwaitingConfirmation
    }

    public func cancelConfirmation() {
        arming.resolveConfirmation()
    }

    // MARK: The wipe

    /// Runs the wipe.
    ///
    /// `includeApplicationDatabase` is the non-default opt-in the ruling requires: false (the default,
    /// and the only value reachable from the UI) means the app's own database file is never opened,
    /// written or removed — not even to read its size. Every step runs even after a failure, because a
    /// wipe that stopped halfway would report success for the part it did.
    ///
    /// The report is built AFTER step 6 has been asked for. `terminate` is one of the promised steps
    /// (iron rule: stop Bluetooth → clear memory → wipe Keychain → overwrite sandbox → exit), so a report that left it out would
    /// describe a wipe that never ended — and a host that supplied no termination has to be told, in
    /// that same report, that its keys are still resident in a live process.
    @discardableResult
    public func execute(includeApplicationDatabase: Bool = false) async -> PopopxPanicWipeReport {
        isWiping = true
        var journal = PopopxPanicWipeJournal()

        await stopRadio(into: &journal)
        await clearVolatileState(into: &journal)
        await eraseMapping(into: &journal)
        await eraseMeshSandbox(into: &journal)
        if includeApplicationDatabase {
            await eraseApplicationDatabase(into: &journal)
        }

        // What the wipe did is logged BEFORE the exit is asked for, not after: an `os_log` line
        // written once `exit(0)` has been called has nothing guaranteeing it survives, and a panic
        // wipe is exactly the event someone reads the log for afterwards.
        PopopxMeshLog.store.error(
            "🧨 panic wipe: \(journal.steps.count, privacy: .public) step(s) before the exit, \(journal.erasedFiles.count, privacy: .public) file(s) overwritten, \(journal.failures.count, privacy: .public) failure(s), chat database touched=\(journal.didTouchApplicationDatabase, privacy: .public)"
        )

        await terminateProcess(into: &journal)

        let report = PopopxPanicWipeReport(journal: journal)
        lastReport = report
        isWiping = false
        if !report.isClean {
            // With the real `processExit` nothing after step 6 runs, so this line can only be reached
            // by a host that injected its own termination — and the case worth naming there is exactly
            // the one the report already carries: a step failed, and the process is still alive.
            PopopxMeshLog.store.error(
                "🧨 panic wipe report (process still running): \(report.summary, privacy: .public)"
            )
        }
        return report
    }

    /// The one line the confirm sheet shows. Built here rather than in the view, so what a user
    /// consents to is testable text.
    public func confirmationMessage(includeApplicationDatabase: Bool = false) -> String {
        var phrases = [
            PopopxPanicWipeStep.stopRadio.words,
            PopopxPanicWipeStep.clearVolatileState.words,
            PopopxPanicWipeStep.eraseKeychainMapping.words,
            PopopxPanicWipeStep.overwriteMeshSandbox.words
        ]
        if includeApplicationDatabase {
            phrases.append(PopopxPanicWipeStep.overwriteApplicationDatabase.words)
        }
        phrases.append(PopopxPanicWipeStep.terminate.words)
        return "This will " + phrases.joined(separator: ", ") + ". It cannot be undone."
    }

    // MARK: Steps

    private func stopRadio(into journal: inout PopopxPanicWipeJournal) async {
        begin(.stopRadio, into: &journal)
        // The radio first, in the order the host declared: a scan still winding down while the keys
        // are being burned can still receive a frame that re-creates a session.
        for component in radio {
            await component.meshSwitchDidTurnOff()
        }
        finish(.stopRadio, into: &journal)
    }

    private func clearVolatileState(into journal: inout PopopxPanicWipeJournal) async {
        begin(.clearVolatileState, into: &journal)
        await keys.burnMeshKeys()
        for mirror in inMemoryMirrors {
            await mirror.meshSwitchDidTurnOff()
        }
        finish(.clearVolatileState, into: &journal)
    }

    private func eraseMapping(into journal: inout PopopxPanicWipeJournal) async {
        begin(.eraseKeychainMapping, into: &journal)
        let report = await mapping.eraseAllMeshMappings()
        for failure in report.failures {
            record(.mappingStep(reason: String(describing: failure)), at: .eraseKeychainMapping, into: &journal)
        }
        finish(.eraseKeychainMapping, into: &journal)
    }

    private func eraseMeshSandbox(into journal: inout PopopxPanicWipeJournal) async {
        begin(.overwriteMeshSandbox, into: &journal)
        do {
            let erased = try deleter.erase(directoryAt: meshDirectory)
            journal.erasedFiles.append(contentsOf: erased)
            finish(.overwriteMeshSandbox, erasedFileCount: erased.count, into: &journal)
        } catch {
            record(.sandboxStep(path: meshDirectory.path, reason: String(describing: error)), at: .overwriteMeshSandbox, into: &journal)
            finish(.overwriteMeshSandbox, into: &journal)
        }
    }

    /// Step 5, and the only step that can ever touch the chat. Reachable from `execute` only through
    /// the explicit opt-in flag; no view in this package passes one.
    private func eraseApplicationDatabase(into journal: inout PopopxPanicWipeJournal) async {
        begin(.overwriteApplicationDatabase, into: &journal)
        guard let url = applicationDatabaseURL else {
            record(.databaseStepRefused(
                reason: "the host asked for the chat database to be erased but gave no path; refusing rather than guessing"
            ), at: .overwriteApplicationDatabase, into: &journal)
            finish(.overwriteApplicationDatabase, into: &journal)
            return
        }
        journal.didTouchApplicationDatabase = true
        do {
            if try deleter.erase(fileAt: url) {
                journal.erasedFiles.append(url.path)
                finish(.overwriteApplicationDatabase, erasedFileCount: 1, into: &journal)
            } else {
                finish(.overwriteApplicationDatabase, into: &journal)
            }
        } catch {
            record(.databaseStep(path: url.path, reason: String(describing: error)), at: .overwriteApplicationDatabase, into: &journal)
            finish(.overwriteApplicationDatabase, into: &journal)
        }
    }

    /// Last, and unconditional: a process that keeps running after the keys were burned can rebuild
    /// state from whatever a failed step left behind.
    ///
    /// There is deliberately no `finish` for this step. `exit(0)` does not return, so reporting that
    /// the terminate step *completed* would tell a recorder something the process cannot do; the start
    /// entry is the last thing a real wipe ever writes, and a test can assert exactly that. A host that
    /// declined to supply a termination gets the opposite treatment: the step is named in the journal
    /// and the fact that the process is still alive with burned keys is recorded as a failure, because
    /// "no failures" must never be readable as "the keys are gone".
    private func terminateProcess(into journal: inout PopopxPanicWipeJournal) async {
        begin(.terminate, into: &journal)
        if let termination {
            termination(0)
        } else {
            record(.radioStep(reason: "host supplied no termination: the process is still running with wiped keys"), at: .terminate, into: &journal)
        }
    }

    // MARK: Journal plumbing

    private func begin(_ step: PopopxPanicWipeStep, into journal: inout PopopxPanicWipeJournal) {
        journal.steps.append(step)
        recorder.panicWipeDidStart(step: step)
    }

    private func finish(
        _ step: PopopxPanicWipeStep,
        erasedFileCount: Int = 0,
        into journal: inout PopopxPanicWipeJournal
    ) {
        recorder.panicWipeDidFinish(step: step, erasedFileCount: erasedFileCount)
    }

    private func record(
        _ failure: PopopxPanicWipeFailure,
        at step: PopopxPanicWipeStep,
        into journal: inout PopopxPanicWipeJournal
    ) {
        journal.failures.append(failure)
        recorder.panicWipeDidFail(failure, at: step)
    }
}

// MARK: - Trigger

/// The hidden three-tap target, and the confirmation it raises.
///
/// It is a sibling overlay, never a rewrite: `content` is passed through untouched, so mounting the
/// panic route on the chat view costs that view nothing (red line "zero-disruption UI mounting", POPOPX_MESH_PROMPT.md 1.5). The hit target is a 44 pt square in
/// a corner, deliberately not the whole screen — an overlay that swallowed taps over a chat list would
/// be a bug the user feels before the wipe ever happens.
@MainActor
public struct PopopxPanicWipeGate<Content: View>: View {
    @ObservedObject private var manager: PopopxPanicWipeManager
    private let content: Content

    public init(_ manager: PopopxPanicWipeManager, @ViewBuilder content: () -> Content) {
        self.manager = manager
        self.content = content()
    }

    public var body: some View {
        content
            .overlay(alignment: .bottomTrailing) {
                trigger
            }
            .alert(
                "Erase offline mesh data?",
                isPresented: confirmationBinding,
                presenting: manager
            ) { watched in
                Button("Cancel", role: .cancel) {
                    watched.cancelConfirmation()
                }
                Button("Erase now", role: .destructive) {
                    guard watched.arming.confirmationIsStillValid() else {
                        watched.cancelConfirmation()
                        return
                    }
                    Task {
                        await watched.execute(
                            includeApplicationDatabase: PopopxPanicWipeManager.interfaceOptInToDatabaseErase
                        )
                    }
                }
            } message: { watched in
                Text(verbatim: watched.confirmationMessage())
            }
    }

    /// Invisible, and therefore also accessibility-labelled: a hidden control a user cannot see
    /// should still not be a control a screen reader cannot announce.
    private var trigger: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            // Single taps, counted by `PopopxPanicWipeArming` rather than by SwiftUI's recognizer:
            // the rule is three taps inside one second, and only a state machine that sees the
            // timestamps can tell three quick taps from a scroll's worth of unrelated ones.
            .onTapGesture(count: 1) {
                _ = manager.tap()
            }
            .accessibilityLabel(Text("Panic wipe trigger"))
            .accessibilityHint(Text("Tap three times quickly to erase all offline mesh data"))
            .padding([.trailing, .bottom], 8)
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { manager.isAwaitingConfirmation },
            set: { showing in
                if !showing {
                    manager.cancelConfirmation()
                }
            }
        )
    }
}

public extension View {
    /// The one-line mount: `ChatView().popopxPanicWipeTrigger(manager)`. The wrapped view is not
    /// modified in any way — the trigger is an overlay sibling.
    func popopxPanicWipeTrigger(_ manager: PopopxPanicWipeManager) -> some View {
        PopopxPanicWipeGate(manager) { self }
    }
}
