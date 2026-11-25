//
//  TorManager.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

/// Owns one embedded daemon and publishes the routing decision the host app must apply.
///
/// Deliberately does **not** call into the chat core. The core's network configuration lives in the
/// iOS target's `NetCfg`/`AppGroup.swift` and in `setNetworkConfig` in `POPOPXAPI.swift:923`; a
/// package that imported those would drag UIKit back in, which is the exact coupling this split
/// exists to avoid. The manager therefore publishes a ``TorRoutingPolicy`` and the macOS app is the
/// one place that translates it onto `NetCfg` — see `README.md` for the field-by-field mapping.
@MainActor
public final class TorManager: ObservableObject {
    @Published public private(set) var phase: TorPhase = .stopped
    @Published public private(set) var gate: TrafficGate = .permitted
    @Published public private(set) var policy: TorRoutingPolicy = .disabled
    @Published public private(set) var exitNode: TorExitNode?
    @Published public private(set) var daemonVersion: String?
    @Published public private(set) var strictModeEnabled: Bool

    public struct Configuration: Sendable {
        public let applicationSupportDirectory: URL
        public let locatorOptions: TorBinaryLocator.Options
        /// Circuit loss is retried a bounded number of times before the manager gives up and reports
        /// `.failed`. Unbounded retry is how a privacy tool ends up silently off; a counted retry that
        /// ends in a visible blocked banner is how it ends up honestly off.
        public let recoveryAttempts: Int
        public let isolationMode: Torrc.IsolationMode

        public init(
            applicationSupportDirectory: URL,
            locatorOptions: TorBinaryLocator.Options = .init(),
            recoveryAttempts: Int = 3,
            isolationMode: Torrc.IsolationMode = .destination
        ) {
            self.applicationSupportDirectory = applicationSupportDirectory
            self.locatorOptions = locatorOptions
            self.recoveryAttempts = recoveryAttempts
            self.isolationMode = isolationMode
        }

        public static let runSubdirectory = "Tor"
    }

    private let configuration: Configuration
    private let allocator: LoopbackPortAllocator
    private let lifecycle: TorLifecycle
    private var process: TorProcess?
    private var controller: TorController?
    private var bridges: [BridgeLine] = []
    private var recoveryUsed = 0
    private var ports: Torrc.Ports?

    public init(configuration: Configuration, strictModeEnabled: Bool = true) {
        self.configuration = configuration
        self.strictModeEnabled = strictModeEnabled
        self.allocator = LoopbackPortAllocator()
        self.lifecycle = TorLifecycle()
    }

    /// Installs the shutdown hooks. Separate from `init` so a host that constructs the manager
    /// lazily does not register signal handlers it never intended to own.
    ///
    /// The hooks need no closure from here: ``TorLifecycle/adopt(process:controller:)`` hands the
    /// daemon and its socket to the hooks at connect time, which is the only cleanup that is safe to
    /// run from a signal handler or from the main thread while the app is terminating.
    public func installLifecycleHooks() {
        lifecycle.install()
    }

    // MARK: - Public control

    public func start() async {
        guard process == nil else { return }
        // A bridge whose transport is a separate binary cannot be used by the embedded daemon, and
        // launching it anyway would leave the UI describing a bootstrap that never completes. Checked
        // here as well as in `apply(bridges:)` because the set survives in the app's own storage.
        if let unusable = unusableBridges {
            fail(Self.bridgeError(unusable))
            return
        }
        phase = .launching
        publishGate()
        let located = TorBinaryLocator.locate(options: configuration.locatorOptions)
        let binary: URL
        switch located {
        case let .success(found):
            binary = found.url
        case let .failure(error):
            fail(error)
            return
        }
        let reserved: (socks: ReservedPort, control: ReservedPort)
        do {
            reserved = try allocator.allocate()
        } catch {
            fail(error)
            return
        }
        let runDirectory = configuration.applicationSupportDirectory
            .appendingPathComponent(Configuration.runSubdirectory, isDirectory: true)
        let ports = Torrc.Ports(socks: reserved.socks.port, control: reserved.control.port)
        let torrc = Torrc(
            ports: ports,
            dataDirectory: runDirectory,
            isolationMode: configuration.isolationMode,
            bridges: bridges
        )
        do {
            try torrc.write()
        } catch {
            fail(error)
            return
        }
        self.ports = ports
        // The ports must be released before the child binds them, and only after the `torrc` naming
        // them has been written: releasing earlier reopens the steal window the allocator exists to
        // close.
        reserved.socks.release()
        reserved.control.release()

        let launched = TorProcess(binary: binary, torrc: torrc.torrcURL) { [weak self] status, output in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // An expected stop already moved the phase; overwriting it with `.failed` would show
                // an error banner for a shutdown the user asked for.
                if self.process?.terminationRequested == false, status != 0 {
                    self.fail(TorError.daemonExitedUnexpectedly(status: status, output: output))
                }
            }
        }
        process = launched
        do {
            try launched.launch()
        } catch {
            process = nil
            fail(error)
            return
        }
        await connect(to: ports)
    }

    public func stop() async {
        controller?.shutdown()
        controller = nil
        let current = process
        process = nil
        ports = nil
        current?.terminate()
        exitNode = nil
        phase = .stopped
        publishGate()
    }

    /// Switching the guard on takes effect immediately; switching it off never reopens a circuit the
    /// daemon cannot prove it has.
    public func setStrictMode(_ enabled: Bool) {
        strictModeEnabled = enabled
        publishGate()
    }

    public func rebuildCircuit() async {
        guard let controller else { return }
        do {
            try await controller.signalNewCircuit()
            exitNode = nil
        } catch {
            fail(error)
        }
    }

    /// Bridge changes restart the daemon.
    ///
    /// `SETCONF UseBridges=1` can flip the flag, but a pluggable transport that was not exec'd at
    /// startup cannot be introduced by a config message, and half-applying the change would leave the
    /// UI describing bridges that the running daemon is not using.
    public func apply(bridges: [BridgeLine]) async {
        let rejected = bridges.filter { !$0.isValid }
        guard rejected.isEmpty else {
            fail(TorError.protocolFraming("\(rejected.count) bridge line(s) were rejected"))
            return
        }
        // Refused before the daemon is torn down: a bridge set this build cannot use must not cost
        // the user the connection they already have.
        let unusable = bridges.requiringClientPlugin
        guard unusable.isEmpty else {
            fail(Self.bridgeError(unusable))
            return
        }
        self.bridges = bridges
        await stop()
        await start()
    }

    public var configuredBridges: [BridgeLine] { bridges }

    private var unusableBridges: [BridgeLine]? {
        let unusable = bridges.requiringClientPlugin
        return unusable.isEmpty ? nil : unusable
    }

    private static func bridgeError(_ bridges: [BridgeLine]) -> TorError {
        .clientTransportPluginMissing(transports: Array(Set(bridges.map(\.transport.rawValue))).sorted())
    }

    // MARK: - Wiring

    private func connect(to ports: Torrc.Ports) async {
        // The daemon has to bind its control port before anything can be asked of it, and the only
        // honest way to know is to keep trying to connect until it answers or the process dies.
        let deadline = Date().addingTimeInterval(30)
        var transport: LoopbackControlTransport?
        while Date() < deadline {
            if let candidate = try? LoopbackControlTransport(host: ports.address, port: ports.control, timeout: 2) {
                transport = candidate
                break
            }
            if process?.isRunning == false {
                fail(TorError.daemonExitedUnexpectedly(
                    status: -1,
                    output: process?.outputTail ?? "the daemon exited before its control port answered"
                ))
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let connected = transport else {
            fail(TorError.timeout("the control port on \(ports.address):\(ports.control)"))
            return
        }
        let made = TorController(
            transport: connected,
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in self?.handle(event) }
            },
            onError: { [weak self] error in
                Task { @MainActor [weak self] in self?.handleLoss(reason: String(describing: error)) }
            }
        )
        controller = made
        made.startReading()
        if let process {
            lifecycle.adopt(process: process, controller: made)
        }
        do {
            let info = try await made.protocolInfo()
            daemonVersion = info.version
            // Bound before switching: on an `Optional<Method>` subject, `case .none` is read as
            // `Optional.none` and would silently catch "no method at all" as Tor's `METHODS=NONE`.
            guard let method = info.preferredMethod() else {
                throw TorError.protocolFraming("PROTOCOLINFO offered no method this package can complete")
            }
            switch method {
            case .cookie:
                try await made.authenticate(.cookie(file: info.cookieFile ?? defaultCookieURL(ports: ports)))
            case .safeCookie:
                throw TorError.protocolFraming(
                    "the daemon offers only SAFECOOKIE, whose handshake this package does not "
                        + "implement; enable CookieAuthentication in the generated torrc"
                )
            case .hashedPassword:
                throw TorError.protocolFraming(
                    "the daemon offers only HASHEDPASSWORD, and no control password is written "
                        + "into the generated torrc; a password would have to be stored somewhere "
                        + "to be presented"
                )
            case .none:
                // `METHODS=NONE`: the daemon accepts unauthenticated loopback controllers, so there is
                // no credential to present. Connecting is still safe because
                // `LoopbackControlTransport` refuses any host that is not a loopback literal.
                break
            }
            try await made.subscribe(to: TorController.requiredEvents)
            if let progress = try await made.bootstrapPhase() {
                apply(progress: progress)
            }
        } catch {
            fail(error)
        }
    }

    private func defaultCookieURL(ports: Torrc.Ports) -> URL {
        configuration.applicationSupportDirectory
            .appendingPathComponent(Configuration.runSubdirectory, isDirectory: true)
            .appendingPathComponent("control_auth_cookie")
    }

    private func handle(_ event: TorController.Event) {
        switch event.name {
        case "BOOTSTRAP":
            if let progress = BootstrapProgress.parse(event.payload.joined(separator: " ")) {
                apply(progress: progress)
            }
        case "CIRC":
            handleCircuitLine(event.payload.joined(separator: " "))
        default:
            break
        }
    }

    private func handleCircuitLine(_ text: String) {
        let fields = text.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3 else { return }
        let state = String(fields[2])
        switch state {
        case "BUILT":
            if case .circuitLost = phase {
                phase = .ready
                recoveryUsed = 0
                publishGate()
            }
        case "CLOSED", "FAILED":
            guard case .ready = phase else { return }
            // A single circuit closing is not an outage — Tor opens and closes general circuits in
            // normal operation — so this is treated as "confirm the exit" rather than "cut the
            // network". The gate only closes when the confirmation itself fails.
            Task { [weak self] in await self?.verifyAfterCircuitLoss() }
        default:
            break
        }
    }

    private func verifyAfterCircuitLoss() async {
        guard let controller else { return }
        do {
            exitNode = try await controller.exitNode()
        } catch {
            handleLoss(reason: String(describing: error))
        }
    }

    private func handleLoss(reason: String) {
        controller = nil
        exitNode = nil
        guard recoveryUsed < configuration.recoveryAttempts else {
            fail(TorError.controlPortUnreachable(reason))
            return
        }
        recoveryUsed += 1
        phase = .circuitLost
        publishGate()
    }

    private func apply(progress: BootstrapProgress) {
        let previous = phase
        phase = previous.byApplying(progress: progress)
        if phase == .ready, previous != .ready {
            recoveryUsed = 0
            Task { [weak self] in
                self?.exitNode = try? await self?.controller?.exitNode() ?? nil
            }
        }
        publishGate()
    }

    private func fail(_ error: Error) {
        phase = .failed(reason: String(describing: error))
        exitNode = nil
        publishGate()
    }

    /// Recomputes the gate and the policy from the same facts, so the banner the user reads and the
    /// configuration the app pushes cannot disagree.
    private func publishGate() {
        policy = resolvedPolicy()
        gate = TrafficGate.evaluate(phase: phase, strict: strictModeEnabled)
    }

    private func resolvedPolicy() -> TorRoutingPolicy {
        guard strictModeEnabled || phase != .stopped else {
            return .disabled
        }
        guard let ports else {
            // No ports means no proxy to hand the core. With the guard on that is a hard stop:
            // publishing `.disabled` here would reopen direct connections.
            return strictModeEnabled ? .prohibited : .disabled
        }
        do {
            return try TorRoutingPolicy.makePolicy(
                socksHost: ports.address,
                socksPort: ports.socks,
                strict: strictModeEnabled,
                circuitReady: phase == .ready
            )
        } catch {
            // The host is the literal this package bound, so reaching here means the allocator and
            // the policy disagree about what counts as numeric. That is a failure of the guard
            // itself, and it is shown as one rather than written off as Tor being off.
            phase = .failed(reason: String(describing: error))
            return strictModeEnabled ? .prohibited : .disabled
        }
    }

    deinit {
        // `@MainActor` makes `controller` inaccessible here, and a `deinit` is the last chance to not
        // leave a daemon behind, so the kill goes through the process object directly.
        let captured = process
        Task.detached(priority: .userInitiated) {
            _ = captured?.terminate(graceInterval: 1.0)
        }
    }
}
