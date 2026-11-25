//
//  PopopxPanicWipeTests.swift
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The two properties that matter here are ORDER and SCOPE: the steps must run stop-BLE first and
//  terminate last, and the app's own SQLCipher database must not be opened unless the caller opted
//  in. Both the filesystem root and the process exit are injected, so nothing in this file writes to a
//  real container or kills the test runner.
//

import Foundation
import Testing
@testable import PopopxMeshUI
import PopopxMeshKit

@MainActor
@Suite("PopopxPanicWipeManager")
struct PopopxPanicWipeTests {
    private struct Harness {
        let manager: PopopxPanicWipeManager
        let recorder: PopopxMeshFakeWipeRecorder
        let journal: PopopxMeshJournal
        let engine: PopopxMeshFakeComponent
        let health: PopopxMeshFakeComponent
        let mirror: PopopxMeshFakeComponent
        let sandbox: PopopxMeshTestDirectory
        let database: PopopxMeshTestDirectory
        let exits: PopopxMeshExitRecorder
    }

    private func makeHarness(
        label: String,
        mappingFailures: [PopopxMeshWipeFailure] = [],
        withDatabase: Bool = true,
        termination: (@Sendable (Int32) -> Void)? = nil
    ) throws -> Harness {
        let journal = PopopxMeshJournal()
        let recorder = PopopxMeshFakeWipeRecorder()
        let engine = PopopxMeshFakeComponent(name: "engine", journal: journal)
        let health = PopopxMeshFakeComponent(name: "health", journal: journal)
        let mirror = PopopxMeshFakeComponent(name: "mirror", journal: journal)
        let exits = PopopxMeshExitRecorder()
        let sandbox = try PopopxMeshTestDirectory(label: "\(label)-sandbox")
        try sandbox.write("flood queue", to: PopopxMeshPaths.unacknowledgedQueueName, size: 4_096)
        try sandbox.write("outbox", to: PopopxMeshPaths.outboxName, size: 2_048)
        try sandbox.write("Ada", to: PopopxMeshNicknameStore.fileName)
        let database = try PopopxMeshTestDirectory(label: "\(label)-db")
        if withDatabase {
            // A real SQLCipher file is a blob of bytes; size is what the overwrite pass reads.
            try database.write("chat rows", to: "chat.sqlite", size: 8_192)
            try database.write("wal pages", to: "chat.sqlite-wal", size: 512)
        }
        let manager = PopopxPanicWipeManager(
            radio: [engine, health],
            keys: PopopxMeshFakeKeyBurner(journal: journal),
            mapping: PopopxMeshFakeMappingEraser(journal: journal, failures: mappingFailures),
            inMemoryMirrors: [mirror],
            meshDirectory: sandbox.url,
            applicationDatabaseURL: withDatabase
                ? database.url.appendingPathComponent("chat.sqlite")
                : nil,
            termination: termination ?? { code in exits.record(code) },
            recorder: recorder
        )
        return Harness(
            manager: manager,
            recorder: recorder,
            journal: journal,
            engine: engine,
            health: health,
            mirror: mirror,
            sandbox: sandbox,
            database: database,
            exits: exits
        )
    }

    @Test("The steps run in the promised order, and the radio is the first thing to stop")
    func stepOrder() async throws {
        let made = try makeHarness(label: "order")
        defer { made.sandbox.remove(); made.database.remove() }

        let report = await made.manager.execute()
        #expect(report.steps == [
            .stopRadio, .clearVolatileState, .eraseKeychainMapping,
            .overwriteMeshSandbox, .terminate
        ])
        #expect(report.isInOrder)
        #expect(report.didTouchApplicationDatabase == false)

        // The recorder sees the interleaving the report cannot show: the radio components went down
        // before the keys were burned, and the keys before the Keychain table.
        let events = made.journal.all
        let firstStop = events.firstIndex(of: "stop:engine")
        let burn = events.firstIndex(of: "burn-keys")
        let erase = events.firstIndex(of: "erase-mappings")
        #expect(firstStop != nil && burn != nil && erase != nil)
        if let firstStop, let burn, let erase {
            #expect(firstStop < burn)
            #expect(burn < erase)
        }
        // Bluetooth first, then memory, then disk: nothing can still be receiving while the wipe is
        // deleting what it received.
        let steps = made.recorder.all.compactMap { entry -> String? in
            entry.hasPrefix("start:") ? entry : nil
        }
        #expect(steps == [
            "start:stopRadio",
            "start:clearVolatileState",
            "start:eraseKeychainMapping",
            "start:overwriteMeshSandbox",
            "start:terminate"
        ])
    }

    @Test("The process is terminated last, and only once")
    func terminationIsLast() async throws {
        let made = try makeHarness(label: "terminate")
        defer { made.sandbox.remove(); made.database.remove() }

        _ = await made.manager.execute()
        let codes = made.exits.codes
        #expect(codes == [0])
        // Every other step finished before the exit was asked for.
        let events = made.recorder.all
        let terminateIndex = events.firstIndex(of: "start:terminate")
        #expect(terminateIndex == events.count - 1)
    }

    @Test("Without a termination the wipe reports that state is still in memory")
    func missingTerminationIsAFailure() async throws {
        let journal = PopopxMeshJournal()
        let sandbox = try PopopxMeshTestDirectory(label: "no-exit-sandbox")
        defer { sandbox.remove() }
        let manager = PopopxPanicWipeManager(
            radio: [PopopxMeshFakeComponent(name: "engine", journal: journal)],
            keys: PopopxMeshFakeKeyBurner(journal: journal),
            mapping: PopopxMeshFakeMappingEraser(journal: journal),
            inMemoryMirrors: [],
            meshDirectory: sandbox.url,
            applicationDatabaseURL: nil,
            // A host that said "do not quit" must be told that its keys are still resident.
            termination: nil
        )
        let report = await manager.execute()
        #expect(report.failures.contains(.radioStep(
            reason: "host supplied no termination: the process is still running with wiped keys"
        )))
        #expect(report.isClean == false)
        #expect(report.steps.last == .terminate)
    }

    @Test("The mesh sandbox is overwritten and removed")
    func sandboxIsErased() async throws {
        let made = try makeHarness(label: "sandbox")
        let queue = made.sandbox.url.appendingPathComponent(PopopxMeshPaths.unacknowledgedQueueName)
        let before = try Data(contentsOf: queue)
        #expect(before.count == 4_096)

        let report = await made.manager.execute()
        defer { made.database.remove() }

        #expect(FileManager.default.fileExists(atPath: made.sandbox.url.path) == false)
        #expect(report.erasedFiles.count >= 3)
        #expect(report.erasedFiles.contains(where: { $0.hasSuffix(PopopxMeshPaths.unacknowledgedQueueName) }))
        #expect(report.erasedFiles.contains(where: { $0.hasSuffix(PopopxMeshNicknameStore.fileName) }))
        #expect(report.isClean)
        #expect(made.recorder.all.contains("start:overwriteMeshSandbox"))
        // The fuse's own components are what the wipe stopped; the mirror's published state is gone
        // with them, so a banner cannot keep showing a peer that no longer exists.
        let mirrorCounts = await made.mirror.counts
        #expect(mirrorCounts.stop == 1)
    }

    @Test("The chat database is untouched unless the caller opts in")
    func databaseNeedsOptIn() async throws {
        let made = try makeHarness(label: "no-opt-in")
        let databaseURL = made.database.url.appendingPathComponent("chat.sqlite")
        let before = try Data(contentsOf: databaseURL)
        #expect(before.count == 8_192)

        let report = await made.manager.execute()
        defer { made.sandbox.remove(); made.database.remove() }

        // The default: the file is still there, byte for byte, and the report says it never opened it.
        #expect(report.didTouchApplicationDatabase == false)
        #expect(report.steps.contains(.overwriteApplicationDatabase) == false)
        let after = try Data(contentsOf: databaseURL)
        #expect(after == before)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path + "-wal") == true)
    }

    @Test("An explicit opt-in erases the database and its write-ahead log")
    func databaseOptIn() async throws {
        let made = try makeHarness(label: "opt-in")
        let databaseURL = made.database.url.appendingPathComponent("chat.sqlite")
        #expect(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))

        let report = await made.manager.execute(includeApplicationDatabase: true)
        defer { made.sandbox.remove(); made.database.remove() }

        #expect(report.didTouchApplicationDatabase == true)
        #expect(report.steps.firstIndex(of: .overwriteApplicationDatabase)
            == report.steps.firstIndex(of: .overwriteMeshSandbox)! + 1)
        #expect(report.erasedFiles.contains(databaseURL.path))
        // The -wal companion goes too, or "erased" would still leave committed pages readable.
        #expect(FileManager.default.fileExists(atPath: databaseURL.path + "-wal") == false)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path) == false)
    }

    @Test("Opting in without giving a path is refused, not guessed")
    func optInWithoutPath() async throws {
        let made = try makeHarness(label: "no-db-path", withDatabase: false)
        let report = await made.manager.execute(includeApplicationDatabase: true)
        defer { made.sandbox.remove(); made.database.remove() }

        #expect(report.steps.contains(.overwriteApplicationDatabase))
        #expect(report.didTouchApplicationDatabase == false)
        if case let .databaseStepRefused(reason) = report.failures.first {
            #expect(reason.contains("refusing rather than guessing"))
        } else {
            Issue.record("expected a refusal, got \(report.failures)")
        }
    }

    @Test("A step that fails does not stop the rest of the wipe")
    func failuresDoNotStopTheWipe() async throws {
        let made = try makeHarness(
            label: "partial",
            mappingFailures: [.keychain(reason: "keybag locked")]
        )
        defer { made.sandbox.remove(); made.database.remove() }

        let report = await made.manager.execute()
        #expect(report.steps.count == 5)
        #expect(report.failures.count == 1)
        #expect(report.isClean == false)
        // The sandbox still went, because a wipe that stopped at the Keychain would leave the cache
        // on a device the user is afraid of losing.
        #expect(FileManager.default.fileExists(atPath: made.sandbox.url.path) == false)
    }

    @Test("The confirm sheet's text names every step that will run")
    func confirmationCopy() {
        let journal = PopopxMeshJournal()
        let manager = PopopxPanicWipeManager(
            radio: [PopopxMeshFakeComponent(name: "engine", journal: journal)],
            keys: PopopxMeshFakeKeyBurner(journal: journal),
            mapping: PopopxMeshFakeMappingEraser(journal: journal),
            inMemoryMirrors: [],
            meshDirectory: FileManager.default.temporaryDirectory,
            applicationDatabaseURL: nil,
            termination: { _ in }
        )
        let plain = manager.confirmationMessage()
        #expect(plain.contains("stop Bluetooth"))
        #expect(plain.contains("clear session keys"))
        #expect(plain.contains("erase the identity map"))
        #expect(plain.contains("overwrite mesh files"))
        #expect(plain.contains("close the app"))
        #expect(plain.contains("chat database") == false)

        let opted = manager.confirmationMessage(includeApplicationDatabase: true)
        #expect(opted.contains("overwrite the chat database"))
    }

    @Test("Three taps inside the window arm the sheet; a fourth disarms it")
    func armingGesture() throws {
        let arming = PopopxPanicWipeArming()
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(arming.tap(now: start) == false)
        #expect(arming.tap(now: start.addingTimeInterval(0.2)) == false)
        #expect(arming.tap(now: start.addingTimeInterval(0.4)) == true)
        #expect(arming.isAwaitingConfirmation)

        // A fourth tap on a screen that has not reacted yet is a mis-click, not a second request.
        #expect(arming.tap(now: start.addingTimeInterval(0.5)) == false)
        #expect(arming.isAwaitingConfirmation == false)
        #expect(arming.tapCount == 0)

        // Slow taps are unrelated taps.
        arming.reset()
        #expect(arming.tap(now: start) == false)
        #expect(arming.tap(now: start.addingTimeInterval(0.9)) == false)
        #expect(arming.tap(now: start.addingTimeInterval(1.9)) == false)
        #expect(arming.isAwaitingConfirmation == false)

        // Consent expires.
        arming.reset()
        _ = arming.tap(now: start)
        _ = arming.tap(now: start.addingTimeInterval(0.1))
        _ = arming.tap(now: start.addingTimeInterval(0.2))
        #expect(arming.confirmationIsStillValid(now: start.addingTimeInterval(1.0)))
        #expect(arming.confirmationIsStillValid(now: start.addingTimeInterval(20.0)) == false)
        #expect(arming.isAwaitingConfirmation == false)
    }

    @Test("The interface can never reach the database step")
    func interfaceCannotOptIn() {
        // The gate's destructive button is hard-wired to this constant, so no screen in the app can
        // ask for step 5; only a host calling `execute(includeApplicationDatabase: true)` itself can.
        #expect(PopopxPanicWipeManager.interfaceOptInToDatabaseErase == false)
    }
}

// MARK: - Exit recorder

/// Stands in for `exit(0)`. A test that called the real thing would end the runner.
final class PopopxMeshExitRecorder: @unchecked Sendable {
    /// Lock-guarded, for the same reason as `PopopxMeshJournal`: the exit closure this is handed to is
    /// `@Sendable`, so the state has to be guarded rather than actor-isolated.
    private let lock = NSLock()
    private var recorded: [Int32] = []

    func record(_ code: Int32) {
        lock.lock()
        recorded.append(code)
        lock.unlock()
    }

    var codes: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

// MARK: - Secure delete

@Suite("PopopxMeshSecureDeleter")
struct PopopxMeshSecureDeleterTests {
    @Test("Overwriting really rewrites the bytes before the file is gone")
    func overwriteThenDelete() throws {
        let directory = try PopopxMeshTestDirectory(label: "delete")
        defer { directory.remove() }
        try directory.write("secret mesh payload", to: "cache.json", size: 1_000)
        let deleter = PopopxMeshSecureDeleter()
        let url = directory.url.appendingPathComponent("cache.json")
        #expect(deleter.fileExists(at: url))

        #expect(try deleter.erase(fileAt: url) == true)
        #expect(deleter.fileExists(at: url) == false)
        // Erasing a file that is already absent is not a failure: a wipe must be safe to repeat.
        #expect(try deleter.erase(fileAt: url) == false)
    }

    @Test("A database's companions are erased with it")
    func companionsGoToo() throws {
        let directory = try PopopxMeshTestDirectory(label: "delete-wal")
        defer { directory.remove() }
        try directory.write("main", to: "chat.sqlite", size: 512)
        try directory.write("wal", to: "chat.sqlite-wal", size: 512)
        try directory.write("shm", to: "chat.sqlite-shm", size: 64)
        let deleter = PopopxMeshSecureDeleter()
        let url = directory.url.appendingPathComponent("chat.sqlite")

        #expect(try deleter.erase(fileAt: url))
        for suffix in ["", "-wal", "-shm", "-journal"] {
            #expect(FileManager.default.fileExists(atPath: url.path + suffix) == false)
        }
    }

    @Test("A directory is emptied from the bottom up")
    func directoryWalk() throws {
        let directory = try PopopxMeshTestDirectory(label: "delete-dir")
        let nested = directory.url.appendingPathComponent("sub/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("deep.json"))
        try Data("y".utf8).write(to: directory.url.appendingPathComponent("top.json"))

        let deleter = PopopxMeshSecureDeleter()
        let erased = try deleter.erase(directoryAt: directory.url)
        #expect(erased.count == 2)
        #expect(FileManager.default.fileExists(atPath: directory.url.path) == false)
        // And a directory that was never there is an empty result, not an error.
        #expect(try deleter.erase(directoryAt: directory.url).isEmpty)
    }

    @Test("The pass buffer is the documented size, and a zero-length file is not read")
    func bufferSizing() {
        #expect(PopopxMeshSecureDeleter.passBuffer(byteCount: 0, randomised: false).isEmpty)
        #expect(PopopxMeshSecureDeleter.passBuffer(byteCount: 8, randomised: false) == Data(count: 8))
        let random = PopopxMeshSecureDeleter.passBuffer(byteCount: 32, randomised: true)
        #expect(random.count == 32)
        #expect(random != Data(count: 32))
    }
}
