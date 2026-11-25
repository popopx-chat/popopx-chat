//
//  LifecycleTests.swift
//  PopopxTorKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
@testable import PopopxTorKit
import XCTest

/// No `tor` binary is needed for any test in this file: the transport is scripted and the child
/// process is a shell script that speaks the same three things a daemon does — stdout, an exit
/// status, and a SIGTERM.
final class ControlTransportTests: XCTestCase {
    func testLoopbackDetectionIgnoresEveryOtherSpelling() throws {
        // `XCTUnwrap` rather than `!`: a literal the parser cannot read is a test failure, and a crash
        // here would take the whole suite down with it.
        for host in ["127.0.0.1", "127.42.1.7", "::1"] {
            XCTAssertTrue(LoopbackControlTransport.isLoopback(try XCTUnwrap(IPAddressLiteral(host))), host)
        }
        for host in ["10.0.0.1", "0.0.0.0", "fe80::1"] {
            XCTAssertFalse(LoopbackControlTransport.isLoopback(try XCTUnwrap(IPAddressLiteral(host))), host)
        }
    }

    func testTheGuardRunsBeforeTheConnection() {
        // Refusing to even attempt a non-loopback control port is the point; the message is what
        // distinguishes the guard from an ordinary connection failure.
        for host in ["10.0.0.1", "localhost", "0.0.0.0", "192.168.1.1"] {
            XCTAssertThrowsError(try LoopbackControlTransport(host: host, port: 9051, timeout: 1)) { error in
                guard let failure = error as? TorError, case .controlPortUnreachable(let detail) = failure else {
                    return XCTFail("expected controlPortUnreachable, got \(error)")
                }
                XCTAssertTrue(
                    detail.contains("not a loopback literal"),
                    "\(host) must be refused by the guard, not by the kernel: \(detail)"
                )
            }
        }
    }

    func testALoopbackLiteralReachesTheKernel() throws {
        // The other half of the guard: a real loopback address must not be refused for being an
        // address literal. The port is one this allocator just released, so nothing is listening and
        // the failure has to come from `connect()`.
        let reserved = try LoopbackPortAllocator().reserve(excluding: [])
        let port = reserved.port
        reserved.release()
        XCTAssertThrowsError(try LoopbackControlTransport(host: "127.0.0.1", port: port, timeout: 1)) { error in
            guard let failure = error as? TorError, case .controlPortUnreachable(let detail) = failure else {
                return XCTFail("expected controlPortUnreachable, got \(error)")
            }
            XCTAssertFalse(detail.contains("not a loopback literal"), detail)
            XCTAssertTrue(detail.contains("connect()"), detail)
        }
    }
}

final class TorControllerTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testProtocolInfoIsWrittenAndParsed() async throws {
        let script = [data("250-AUTH METHODS=COOKIE COOKIEFILE=\"/tmp/tor/control_auth_cookie\"\r\n250-INFO Version=0.4.8.12\r\n250 OK\r\n")]
        let transport = ScriptedTransport(replies: script)
        let controller = TorController(transport: transport)
        controller.startReading()
        defer { controller.shutdown() }

        let info = try await controller.protocolInfo()
        XCTAssertEqual(info.methods, [.cookie])
        XCTAssertEqual(info.version, "0.4.8.12")
        XCTAssertEqual(info.cookieFile?.path, "/tmp/tor/control_auth_cookie")
        XCTAssertTrue(String(decoding: transport.written, as: UTF8.self).hasPrefix("PROTOCOLINFO 1\r\n"))
    }

    func testBootstrapPhaseReadsThePercentageTheDaemonReported() async throws {
        let script = [data("250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY=\"Done\"\r\n250 OK\r\n")]
        let controller = TorController(transport: ScriptedTransport(replies: script))
        controller.startReading()
        defer { controller.shutdown() }
        let progress = try await controller.bootstrapPhase()
        XCTAssertEqual(progress?.percent, 100)
        XCTAssertEqual(progress?.summary, "Done")
    }

    func testExitNodeComesFromTheCircuitTable() async throws {
        let exit = "9C3D" + String(repeating: "0", count: 36)
        let script = [data("250+circuit-status=\r\n250-1 GENERAL BUILT 3:$7A1F\(String(repeating: "0", count: 36))~guard,5:$8B2E\(String(repeating: "0", count: 36))~mid,9:$\(exit)~exitname\r\n250 OK\r\n")]
        let controller = TorController(transport: ScriptedTransport(replies: script))
        controller.startReading()
        defer { controller.shutdown() }
        let node = try await controller.exitNode()
        XCTAssertEqual(node?.fingerprint, exit)
        XCTAssertEqual(node?.nickname, "exitname")
    }

    func testARejectedAuthenticationIsNotSilentlyPositive() async throws {
        let controller = TorController(transport: ScriptedTransport(replies: [data("551 Authorization required\r\n")]))
        controller.startReading()
        defer { controller.shutdown() }
        do {
            try await controller.authenticate(.password("anything"))
            XCTFail("an error reply must not authenticate")
        } catch let error as TorError {
            XCTAssertEqual(error, .authenticationRejected)
        }
    }

    func testAReplyForOneCommandIsNeverGivenToAnother() async throws {
        // Replies are matched in write order because the daemon answers serially. The second chunk
        // also carries an unsolicited event ahead of its reply, which is the case that loses a reply
        // to the event loop when every caller reads the socket itself.
        let collector = EventCollector()
        let script = [
            data("250 OK\r\n"),
            data("650 BW 1024 2048\r\n250-version=0.4.8.12\r\n250 OK\r\n")
        ]
        let controller = TorController(transport: ScriptedTransport(replies: script), onEvent: { event in
            collector.append(event.name)
        })
        controller.startReading()
        defer { controller.shutdown() }

        try await controller.signalNewCircuit()
        let values = try await controller.getInfo(["version"])
        XCTAssertEqual(values["version"], "0.4.8.12")
        XCTAssertEqual(collector.names, ["BW"])
    }

    func testSendingAfterShutdownFailsInsteadOfWaitingForever() async {
        let controller = TorController(transport: ScriptedTransport(replies: []))
        controller.shutdown()
        do {
            _ = try await controller.send("GETINFO version\r\n")
            XCTFail("a shut-down controller must refuse the command")
        } catch let error as TorError {
            guard case .controlPortUnreachable = error else {
                return XCTFail("expected controlPortUnreachable, got \(error)")
            }
        } catch {
            XCTFail("expected TorError, got \(error)")
        }
    }

    func testEventNamesComeFromTheClosingLineOrTheOpeningKeyword() {
        XCTAssertEqual(
            TorController.event(from: ControlMessage(code: 650, message: "BOOTSTRAP 45 loading_descriptors", lines: [], data: [])).name,
            "BOOTSTRAP"
        )
        XCTAssertEqual(
            TorController.event(from: ControlMessage(code: 650, message: "CIRC 5 BUILT $7A1F~a", lines: [], data: [])).name,
            "CIRC"
        )
        XCTAssertEqual(
            TorController.event(from: ControlMessage(code: 650, message: "OK", lines: ["status/client/orconn=1"], data: ["r Outer"])).name,
            "status/client/orconn"
        )
    }

    func testRequiredEventsCoverProgressAndCircuitLoss() {
        XCTAssertEqual(TorController.requiredEvents, ["BOOTSTRAP", "CIRC", "BW"])
    }
}

/// A lock-protected collector, because the controller delivers events on its own reader thread.
private final class EventCollector: @unchecked Sendable {
    private let gate = NSLock()
    private var storage: [String] = []

    func append(_ name: String) {
        gate.lock()
        storage.append(name)
        gate.unlock()
    }

    var names: [String] {
        gate.lock(); defer { gate.unlock() }
        return storage
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let gate = NSLock()
    private var storage: Value?

    func set(_ value: Value) {
        gate.lock()
        storage = value
        gate.unlock()
    }

    var value: Value? {
        gate.lock(); defer { gate.unlock() }
        return storage
    }
}

private struct ExitOutcome {
    let status: Int32
    let output: String
    let requested: Bool
}

/// The exit handler needs the process it belongs to, and a `let` cannot be captured inside its own
/// initial value, so the handler looks the process up through this.
private final class ProcessHolder: @unchecked Sendable {
    private let gate = NSLock()
    private var stored: TorProcess?

    func set(_ process: TorProcess) {
        gate.lock()
        stored = process
        gate.unlock()
    }

    var terminationRequested: Bool {
        gate.lock(); defer { gate.unlock() }
        return stored?.terminationRequested ?? false
    }
}

final class TorProcessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("popopx-torprocess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    /// A stand-in daemon: it writes what it was told to, stays alive until signalled, or exits with
    /// the given status. `TorProcess` always passes `-f <torrc>`, which the script ignores.
    private func stubDaemon(body: String) throws -> URL {
        let url = directory.appendingPathComponent("stub-tor")
        try ("""
        #!/bin/sh
        \(body)
        """).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func stateFile() throws -> URL {
        let url = directory.appendingPathComponent("torrc")
        try "SocksPort 127.0.0.1:39123\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    func testAChildIsLaunchedHeldAndStoppedOnRequest() throws {
        let binary = try stubDaemon(body: "echo ready\nsleep 30\n")
        let exitStatus = Locked<Int32>()
        let process = TorProcess(binary: binary, torrc: try stateFile()) { status, _ in
            exitStatus.set(status)
        }
        try process.launch()
        XCTAssertTrue(process.isRunning)
        XCTAssertNotEqual(process.processIdentifier, 0)
        XCTAssertTrue(
            waitFor { process.outputTail.contains("ready") },
            "stdout must be drained while the child runs, or a chatty daemon blocks in write()"
        )

        XCTAssertThrowsError(try process.launch()) { error in
            guard let failure = error as? TorProcess.LaunchError, case .alreadyRunning = failure else {
                return XCTFail("expected alreadyRunning, got \(error)")
            }
        }

        XCTAssertTrue(process.terminate(graceInterval: 4), "the child should leave on SIGTERM")
        XCTAssertTrue(waitFor { !process.isRunning })
        XCTAssertTrue(process.terminationRequested)
        XCTAssertTrue(waitFor { exitStatus.value != nil }, "the exit handler runs for an expected stop too")
    }

    func testAnUnexpectedExitCarriesTheDaemonsOwnWords() throws {
        let text = "SocksPort is already in use"
        let binary = try stubDaemon(body: "echo '\(text)'\nsleep 0.5\nexit 3\n")
        let completion = expectation(description: "the stub daemon exits")
        let outcome = Locked<ExitOutcome>()
        let holder = ProcessHolder()
        let process = TorProcess(binary: binary, torrc: try stateFile()) { status, output in
            outcome.set(ExitOutcome(status: status, output: output, requested: holder.terminationRequested))
            completion.fulfill()
        }
        holder.set(process)
        try process.launch()
        wait(for: [completion], timeout: 15)

        guard let recorded = outcome.value else { return XCTFail("no exit was recorded") }
        XCTAssertEqual(recorded.status, 3)
        XCTAssertTrue(recorded.output.contains(text), "startup failures must be reported with the daemon's text")
        XCTAssertFalse(recorded.requested, "an exit we did not ask for is not a stop")
    }

    func testAMissingBinaryThrowsRatherThanExitingLater() throws {
        let process = TorProcess(
            binary: URL(fileURLWithPath: "/nonexistent/popopx-tor"),
            torrc: try stateFile(),
            onExit: { _, _ in XCTFail("a process that never started cannot exit") }
        )
        XCTAssertThrowsError(try process.launch()) { error in
            guard let failure = error as? TorProcess.LaunchError, case .executableNotPermitted = failure else {
                return XCTFail("expected executableNotPermitted, got \(error)")
            }
        }
        XCTAssertFalse(process.isRunning)
    }

    func testTerminatingSomethingAlreadyGoneIsNotAFailure() throws {
        let binary = try stubDaemon(body: "sleep 30\n")
        let process = TorProcess(binary: binary, torrc: try stateFile()) { _, _ in }
        try process.launch()
        XCTAssertTrue(process.terminate(graceInterval: 4))
        XCTAssertTrue(process.terminate(graceInterval: 4), "a second stop must be idempotent for the lifecycle hooks")
        XCTAssertFalse(process.isRunning)
    }

    func testTheChildDoesNotInheritTheAppEnvironment() throws {
        // `all_proxy` in the app's environment would send the daemon's own directory fetches out
        // through the proxy it is being asked to provide, so the environment is rebuilt from two keys.
        let binary = try stubDaemon(body: "echo \"HOME=$HOME all_proxy=${all_proxy:-absent} PATH=$PATH\"\nsleep 30\n")
        let process = TorProcess(binary: binary, torrc: try stateFile()) { _, _ in }
        try process.launch()
        defer { process.terminate(graceInterval: 2) }
        XCTAssertTrue(waitFor { process.outputTail.contains("all_proxy=absent") }, process.outputTail)
        XCTAssertTrue(process.outputTail.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), process.outputTail)
        XCTAssertTrue(process.outputTail.contains("HOME=\(try stateFile().deletingLastPathComponent().path)"), process.outputTail)
    }
}
