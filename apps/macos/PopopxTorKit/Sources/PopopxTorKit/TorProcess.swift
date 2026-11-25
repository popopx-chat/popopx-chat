//
//  TorProcess.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The `tor` child process.
///
/// The daemon is started with `-f` pointing at a generated file rather than with its configuration on
/// the command line. Two reasons, both practical: a `ControlPort` written into the argument vector is
/// visible to every `ps` on the machine, and Tor's own precedence rules make command-line `--Key
/// Value` overrides silently win over a `torrc` the user may have edited — leaving us reporting a
/// configuration that is not the one running.
public final class TorProcess: @unchecked Sendable {
    public enum LaunchError: Error, Equatable, CustomStringConvertible {
        case alreadyRunning
        case notRunning
        case executableNotPermitted(String)

        public var description: String {
            switch self {
            case .alreadyRunning: return "a tor process is already running under this manager"
            case .notRunning: return "no tor process is running"
            case let .executableNotPermitted(detail): return "the tor helper could not be started: \(detail)"
            }
        }
    }

    private let task = Process()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let binary: URL
    private let torrc: URL
    private let gate = NSLock()
    private var running = false
    /// The last lines the daemon wrote, kept so a startup failure can be reported with the daemon's
    /// own words. `SafeLogging 1` is set in the generated config precisely because this buffer ends
    /// up in crash logs and in whatever the host app chooses to show.
    private var tail: [String] = []
    private let tailLimit = 40
    private let onExit: @Sendable (Int32, String) -> Void

    public var processIdentifier: Int32 { task.processIdentifier }
    public var isRunning: Bool {
        gate.lock(); defer { gate.unlock() }; return running
    }

    /// - Parameter onExit: called with the termination status and the captured output tail. Fires on
    ///   an arbitrary queue, and fires for an expected `terminate()` too — the caller decides which
    ///   is which by asking `terminationRequested`, because a manager that assumes "exited == crashed"
    ///   will show an error banner on every clean shutdown.
    public init(
        binary: URL,
        torrc: URL,
        onExit: @escaping @Sendable (Int32, String) -> Void
    ) {
        self.binary = binary
        self.torrc = torrc
        self.onExit = onExit
    }

    private(set) public var terminationRequested = false

    public func launch(extraArguments: [String] = []) throws {
        gate.lock()
        if running { gate.unlock(); throw LaunchError.alreadyRunning }
        running = true
        terminationRequested = false
        gate.unlock()

        task.executableURL = binary
        task.arguments = ["-f", torrc.path] + extraArguments
        // A minimal environment. Inheriting the app's would hand the daemon the app's `TMPDIR`,
        // proxy variables (`all_proxy` in particular, which would send the daemon's own directory
        // fetches out through the very proxy we are trying to make the only path) and any
        // `Tor2web`-style overrides left by a shell profile.
        task.environment = [
            "HOME": torrc.deletingLastPathComponent().path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        task.standardOutput = standardOutput
        task.standardError = standardError
        task.terminationHandler = { [weak self] process in
            guard let self else { return }
            let output = self.drain()
            self.gate.lock()
            self.running = false
            self.gate.unlock()
            self.onExit(process.terminationStatus, output)
        }
        do {
            try task.run()
        } catch {
            gate.lock()
            running = false
            gate.unlock()
            throw LaunchError.executableNotPermitted(String(describing: error))
        }
        startCollecting()
    }

    /// Asks the daemon to leave, waits, then hard-kills.
    ///
    /// The grace period exists because Tor flushes its cached consensus on `SIGTERM`, and killing it
    /// mid-write leaves a state file the next launch has to discard — which costs a full directory
    /// download the next time the user turns Tor on.
    @discardableResult
    public func terminate(graceInterval: TimeInterval = 4.0) -> Bool {
        gate.lock()
        guard running else { gate.unlock(); return true }
        terminationRequested = true
        let identifier = task.processIdentifier
        gate.unlock()
        kill(identifier, SIGTERM)
        let deadline = Date().addingTimeInterval(graceInterval)
        while task.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if task.isRunning {
            kill(identifier, SIGKILL)
            return false
        }
        return true
    }

    private func startCollecting() {
        // One readability handler per pipe, re-armed by `readDataToEndOfFile` semantics on the
        // background queue. Without this a daemon that writes more than the 64 KB pipe buffer
        // blocks in `write()` and the circuit never completes — the classic silent hang of a
        // subprocess whose output nobody drains.
        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.record(String(data: handle.availableData, encoding: .utf8) ?? "")
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.record(String(data: handle.availableData, encoding: .utf8) ?? "")
        }
    }

    private func record(_ text: String) {
        guard !text.isEmpty else { return }
        gate.lock()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            tail.append(String(line))
        }
        if tail.count > tailLimit { tail.removeFirst(tail.count - tailLimit) }
        gate.unlock()
    }

    private func drain() -> String {
        for handle in [standardOutput.fileHandleForReading, standardError.fileHandleForReading] {
            handle.readabilityHandler = nil
            try? handle.close()
        }
        gate.lock()
        let snapshot = tail.joined(separator: "\n")
        gate.unlock()
        return snapshot
    }

    public var outputTail: String {
        gate.lock(); defer { gate.unlock() }
        return tail.joined(separator: "\n")
    }
}

/// Installs the shutdown hooks that keep an orphaned daemon from outliving the app.
///
/// Three paths are covered and the third is the one that matters. A user quitting the app hits
/// `willTerminate`; a `kill` or a `sudo`-style stop hits the signal sources; a crash or an ODB kill
/// hits **none of the in-process handlers**, which is why `Torrc` also writes
/// `__OwningControllerProcess` and lets Tor watch our PID from the outside. A lifecycle manager that
/// relies only on signal handlers is a lifecycle manager that leaks a process exactly when the app
/// fails.
public final class TorLifecycle: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(label: "com.popopxchat.popopx.tor.lifecycle")
    private let gate = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var token: NSObjectProtocol?
    private var child: TorProcess?
    private var control: TorController?

    public init() {}

    /// The handler is supplied at install time rather than at initialisation because it needs the
    /// manager, and the manager cannot hand out `self` before its own `init` has finished.
    public func install(onTerminate: @escaping @Sendable () -> Void = {}) {
        gate.lock()
        let alreadyInstalled = handler != nil || token != nil
        handler = onTerminate
        gate.unlock()
        guard !alreadyInstalled else { return }
        installSignalSources()
        #if canImport(AppKit)
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fire()
        }
        #endif
    }

    /// Attaches the daemon and its control socket so termination can tear them down.
    ///
    /// The kill path does not go through `TorManager` on purpose: the manager is `@MainActor`, a
    /// signal source fires on an arbitrary thread, and `willTerminate` is already on the main thread
    /// — where an actor hop would queue behind the very termination this exists to complete.
    public func adopt(process: TorProcess, controller: TorController) {
        gate.lock()
        child = process
        control = controller
        gate.unlock()
    }

    public func remove() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        gate.lock()
        handler = nil
        gate.unlock()
    }

    deinit {
        remove()
    }

    private func fire() {
        gate.lock()
        let pending = handler
        let outgoing = child
        let socket = control
        child = nil
        control = nil
        gate.unlock()
        // The socket first: `TorController.shutdown()` resumes every parked waiter with an error, so
        // an `await` that is still open cannot outlive the process it was talking to.
        socket?.shutdown()
        _ = outgoing?.terminate(graceInterval: 2.0)
        pending?()
    }

    private func installSignalSources() {
        // `signal(..., SIG_IGN)` first: a disposition of `SIG_DFL` would tear the process down before
        // the dispatch source ever fires.
        for identifier in [SIGTERM, SIGINT, SIGHUP] {
            signal(identifier, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: identifier, queue: queue)
            source.setEventHandler { [weak self] in
                self?.fire()
                // Restoring the default disposition and re-raising keeps the exit status and the
                // crash-report behaviour the OS would have shown, instead of the app returning 0 as
                // though it had finished its work.
                signal(identifier, SIG_DFL)
                raise(identifier)
            }
            source.resume()
            sources.append(source)
        }
    }
}
