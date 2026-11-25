//
//  NetworkStateMonitor.swift
//  PopopxMeshKit  —  Module 5
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The public-internet half of seamless switching in every direction: what `NWPathMonitor` says about the device, turned into
//  one Sendable value that `PopopxMessageRouter` reads before it chooses a channel and streams to
//  whenever the choice changes. Nothing here decides where a message goes — module 5's router does —
//  and nothing here reaches the network: this is a listener on the operating system's own path
//  state, which is the only public-network fact this package is allowed to know without going
//  through module 2's seam.
//
//  Two rules shape the file. The value is a *snapshot plus a stream*, because the router needs an
//  answer now (`currentPath()`) and also needs to react when the answer changes
//  (`pathChanges()`), and a single `NWPathMonitor` can serve both. And every timer the monitor
//  schedules is cancelled and nilled in `stop()`, because a global fuse that leaves a watchdog
//  armed would keep waking a mesh the user just switched off.
//

import Foundation
import Network

// MARK: - Time

/// The two places module 5 waits — the SMP ACK window in the router and the first-report watchdog
/// here — read time through this one value, so a test can substitute a scaled clock and prove a
/// 3-second rule in 3 milliseconds instead of sleeping.
///
/// `delay` must return when the interval is over *or* when the calling task is cancelled; a
/// cancelled wait must not be reported as "the time passed".
public struct PopopxRoutingClock: Sendable {
    public let date: @Sendable () -> Date
    public let delay: @Sendable (TimeInterval) async -> Void

    public init(date: @escaping @Sendable () -> Date, delay: @escaping @Sendable (TimeInterval) async -> Void) {
        self.date = date
        self.delay = delay
    }

    /// Real time: the only clock the app should ever hand to a production instance.
    public static let wall = PopopxRoutingClock(
        date: { Date.now },
        delay: { interval in
            guard interval > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    )
}

// MARK: - The value

/// Which radio carried the report. `NWInterface.InterfaceType` is an enum from a
/// library-evolution-enabled framework, so the mapping switches exhaustively and falls through a
/// default instead of naming cases a future SDK adds.
public enum PopopxNetworkInterface: String, Hashable, Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case other
    case none

    public init(_ type: NWInterface.InterfaceType) {
        switch type {
        case .wifi: self = .wifi
        case .cellular: self = .cellular
        case .wiredEthernet: self = .wiredEthernet
        case .loopback: self = .loopback
        default: self = .other
        }
    }
}

/// Why a path is not usable, as `NWPath.unsatisfiedReason` spells it. The banner can say "Cellular permission
/// denied" instead of the useless "No network" when the system, not the radio, is the one refusing.
public enum PopopxPathBlockage: String, Hashable, Sendable {
    case none
    case notAvailable
    case cellularDenied
    case wifiDenied
    case localNetworkDenied
    case vpnInactive

    init(_ reason: NWPath.UnsatisfiedReason?) {
        switch reason {
        case nil: self = .none
        case .cellularDenied: self = .cellularDenied
        case .wifiDenied: self = .wifiDenied
        case .localNetworkDenied: self = .localNetworkDenied
        case .vpnInactive: self = .vpnInactive
        default: self = .notAvailable
        }
    }

    /// The reason a dead path has, in the user's language, or nil when the path is fine. Kept here
    /// rather than in a view so the router's banner and any later copy agree on the wording.
    public var displayText: String? {
        switch self {
        case .none: nil
        case .notAvailable: NSLocalizedString("No network connection", comment: "")
        case .cellularDenied: NSLocalizedString("Cellular data access has been denied", comment: "")
        case .wifiDenied: NSLocalizedString("Wi-Fi access has been denied", comment: "")
        case .localNetworkDenied: NSLocalizedString("Local network access has been denied", comment: "")
        case .vpnInactive: NSLocalizedString("The encrypted tunnel is not ready", comment: "")
        }
    }
}

/// One reading of the public path. Deliberately a value type: it crosses the `NWPathMonitor`
/// queue, the monitor actor and the router actor, and `NWPath` itself is only `Sendable` from
/// iOS 17 while this package still deploys to iOS 15.
public struct PopopxNetworkPath: Hashable, Sendable {
    /// `NWPath.status == .satisfied`. False also covers `.requiresConnection`: a path that needs a
    /// login portal cannot carry an SMP request, which is exactly the weak-network case the router treats as
    /// offline.
    public let isConnected: Bool
    public let interface: PopopxNetworkInterface
    /// `NWPath.isExpensive` — cellular or a personal hotspot.
    public let isExpensive: Bool
    /// `NWPath.isConstrained` — low-data mode.
    public let isConstrained: Bool
    public let blockage: PopopxPathBlockage
    public let reportedAt: Date

    public init(
        isConnected: Bool,
        interface: PopopxNetworkInterface,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        blockage: PopopxPathBlockage = .none,
        reportedAt: Date = .now
    ) {
        self.isConnected = isConnected
        self.interface = interface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.blockage = blockage
        self.reportedAt = reportedAt
    }

    /// One reading with nothing behind it: used when the watchdog found the system silent.
    public static let unknown = PopopxNetworkPath(
        isConnected: false,
        interface: .none,
        blockage: .notAvailable,
        reportedAt: .distantPast
    )

    init(_ path: NWPath, reportedAt: Date) {
        let satisfied = path.status == .satisfied
        var chosen: PopopxNetworkInterface = .none
        if satisfied {
            // Preference order, not first-match: a phone on Wi-Fi with LTE up must be reported as
            // Wi-Fi, because that is the interface the mesh's "weak network" copy would blame.
            for type: NWInterface.InterfaceType in [.wifi, .cellular, .wiredEthernet, .loopback, .other]
            where path.usesInterfaceType(type) {
                chosen = PopopxNetworkInterface(type)
                break
            }
        }
        self.init(
            isConnected: satisfied,
            interface: chosen,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            blockage: PopopxPathBlockage(satisfied ? nil : path.unsatisfiedReason),
            reportedAt: reportedAt
        )
    }

    /// What a banner says about this reading. The mesh copy belongs to the router's status; this is
    /// only the connectivity fact, kept short so no UI layer has to reconstruct it.
    public var displayText: String {
        if isConnected {
            switch interface {
            case .cellular: return NSLocalizedString("Internet available (cellular)", comment: "")
            case .wifi: return NSLocalizedString("Internet available (Wi-Fi)", comment: "")
            case .wiredEthernet: return NSLocalizedString("Internet available (wired network)", comment: "")
            case .loopback: return NSLocalizedString("Internet available (loopback)", comment: "")
            case .other: return NSLocalizedString("Internet available", comment: "")
            case .none: return NSLocalizedString("Internet available (interface unknown)", comment: "")
            }
        }
        if let blockage = blockage.displayText { return blockage }
        return NSLocalizedString("Internet unavailable", comment: "")
    }
}

// MARK: - The seam the monitor reads

/// What `NetworkStateMonitor` needs from the system, so the monitor's own start/stop bookkeeping is
/// testable without a live `NWPathMonitor`, and so a second consumer (a watch extension, a test)
/// can feed the same machine.
public protocol PopopxPathProviding: Sendable {
    /// Delivers the current path, then every change, on whatever thread the source chooses. The
    /// handler is called off-isolation on purpose: the monitor hops back before touching state.
    func startReporting(_ handler: @escaping @Sendable (PopopxNetworkPath) -> Void) async

    /// Stops for good: a `NWPathMonitor` cannot be restarted after `cancel()`, so a source that
    /// wants to be startable again must build a new one.
    func stopReporting() async
}

/// The real `NWPathMonitor`, wrapped rather than used directly.
///
/// The wrapper owns the queue and the monitor's lifetime, keeps the raw monitor behind a lock (the
/// class is only `Sendable` from iOS 17, so it must not be the thing that crosses an isolation
/// boundary), and converts every `NWPath` into a `Sendable` `PopopxNetworkPath` at the door so no
/// system object ever leaves this file.
public final class PopopxNWPathSource: PopopxPathProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var monitor: NWPathMonitor?

    public init(queueLabel: String = "chat.popopx.mesh.path-monitor") {
        queue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    /// The protocol's requirements are `async` so an actor can implement them; the work itself is
    /// one synchronous, lock-held section, which `NSLock` may only be used from outside an
    /// asynchronous context, so it lives in these two helpers.
    public func startReporting(_ handler: @escaping @Sendable (PopopxNetworkPath) -> Void) async {
        start(handler)
    }

    public func stopReporting() async {
        stop()
    }

    private func start(_ handler: @escaping @Sendable (PopopxNetworkPath) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            handler(PopopxNetworkPath(path, reportedAt: .now))
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    private func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let monitor else { return }
        self.monitor = nil
        // The handler goes before `cancel()` so no in-flight update on the queue can reach a
        // consumer that already stopped.
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}

/// What module 5 needs from a connectivity source, and the only way anything in this package learns
/// whether the public network is up. `NetworkStateMonitor` is the production implementation; a test
/// substitutes its own so a network restore can be produced without a radio.
public protocol PopopxConnectivitySource: Sendable {
    /// Puts the source to work. `NetworkStateMonitor` needs it because a `NWPathMonitor` reports
    /// nothing until started; a fake that is fed by hand can leave it out — the extension's no-op is
    /// there so the router can ask anybody, and asking is what makes `PopopxMessageRouter.start()`
    /// self-sufficient instead of depending on the host having remembered to boot the monitor.
    func start() async

    /// The last reported path, nil when nothing has been reported yet — see
    /// `NetworkStateMonitor.currentPath()` for why that is a tri-state.
    func currentPath() async -> PopopxNetworkPath?

    /// Every report from now on, with the current value replayed first. Each call is a separate
    /// subscription, and a consumer that stops iterating is removed by the source.
    func pathChanges() async -> AsyncStream<PopopxNetworkPath>
}

extension PopopxConnectivitySource {
    public func start() async {}
}

// MARK: - The monitor

/// Live public-network state, as a current value and as a stream of changes.
///
/// `PopopxMessageRouter` subscribes to `pathChanges()`; the UI reads `currentPath()` or subscribes
/// too. Every subscription gets the current value replayed first, so a consumer that starts after
/// boot is never blind, and every subscription is finished on `stop()` so a leaked `for await`
/// loop cannot keep the actor alive.
public actor NetworkStateMonitor: PopopxConnectivitySource {
    /// The process-wide connectivity fact. One `NWPathMonitor` per process is what Apple expects,
    /// and the router and the banner must not disagree about the answer.
    public static let shared = NetworkStateMonitor()

    /// How long to wait for the system's first report before assuming the monitor is stuck.
    /// `NWPathMonitor` documents that it delivers the current path as soon as it starts, so a
    /// silence this long is a cold start gone wrong, not a slow network.
    public static let defaultFirstReportTimeout: TimeInterval = 2

    /// The watchdog fires once: a second silent monitor is a device problem the router's own
    /// "path unknown" answer already covers, and restarting forever would be worse than giving up.
    public static let maxFirstReportRestarts = 1

    private let source: any PopopxPathProviding
    private let clock: PopopxRoutingClock
    private let firstReportTimeout: TimeInterval

    private var latest: PopopxNetworkPath?
    private var subscriptions: [UUID: AsyncStream<PopopxNetworkPath>.Continuation] = [:]
    private var firstReportTask: Task<Void, Never>?
    private var restarts = 0
    private var reported = false
    private var started = false

    public init(
        source: any PopopxPathProviding = PopopxNWPathSource(),
        clock: PopopxRoutingClock = .wall,
        firstReportTimeout: TimeInterval = NetworkStateMonitor.defaultFirstReportTimeout
    ) {
        self.source = source
        self.clock = clock
        self.firstReportTimeout = firstReportTimeout
    }

    // MARK: Lifecycle

    /// Idempotent, like module 4's monitor: the global switch may be toggled repeatedly.
    public func start() async {
        guard !started else { return }
        started = true
        reported = false
        await installSource()
        PopopxMeshLog.route.info("▶️ network monitor started")
    }

    /// Cancels the watchdog, finishes every stream and releases the system monitor. After this
    /// returns, `retainsScheduledWork` is false — the rule the module is written against, since a
    /// fuse that left a timer armed would keep waking a mesh the user switched off.
    public func stop() async {
        guard started else { return }
        started = false
        cancelWatchdog()
        let live = subscriptions.values
        for continuation in live { continuation.finish() }
        subscriptions.removeAll()
        await source.stopReporting()
        PopopxMeshLog.route.info("⏹ network monitor stopped")
    }

    public func startIfNeeded() async {
        guard !started else { return }
        await start()
    }

    public var isStarted: Bool { started }

    /// True while any timer or stream this monitor owns is still alive. Measured by the tests that
    /// assert `stop()` really retracts the monitor.
    public var retainsScheduledWork: Bool {
        firstReportTask != nil || !subscriptions.isEmpty
    }

    // MARK: PopopxConnectivitySource

    /// nil until the first report. The router reads that as "we do not know yet", which is the only
    /// honest answer before the system has spoken and the reason it is a tri-state rather than a
    /// `Bool` defaulting to connected.
    public func currentPath() -> PopopxNetworkPath? {
        latest
    }

    /// A fresh stream of every report from now on, starting with the current value when there is
    /// one. `.unbounded` on purpose: a conflated stream could drop the connected reading that the
    /// router's flush-on-restore edge depends on.
    public func pathChanges() -> AsyncStream<PopopxNetworkPath> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PopopxNetworkPath>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        subscriptions[id] = continuation
        if let latest {
            continuation.yield(latest)
        }
        return stream
    }

    /// The one-shot answer for callers that only want to know right now, e.g. the router when it is
    /// asked whether a message may go out over SMP.
    public func isConnectedNow() -> Bool {
        latest?.isConnected ?? false
    }

    public var unsubscribeCount: Int { subscriptions.count }

    // MARK: - Reporting

    private func installSource() async {
        await source.startReporting { [weak self] path in
            Task { await self?.ingest(path) }
        }
        guard firstReportTimeout > 0, firstReportTask == nil else { return }
        let delay = clock.delay
        let timeout = firstReportTimeout
        firstReportTask = Task { [weak self] in
            await delay(timeout)
            guard let self else { return }
            await self.firstReportMissed()
        }
    }

    /// Every system report lands here: the snapshot, the stream, and the watchdog's dismissal.
    private func ingest(_ path: PopopxNetworkPath) {
        guard started else { return }
        reported = true
        cancelWatchdog()
        latest = path
        for continuation in subscriptions.values {
            continuation.yield(path)
        }
        PopopxMeshLog.route.info(
            "🌐 path — connected=\(path.isConnected, privacy: .public) interface=\(path.interface.rawValue, privacy: .public) expensive=\(path.isExpensive, privacy: .public)"
        )
    }

    private func firstReportMissed() async {
        firstReportTask = nil
        guard started, !reported else { return }
        guard restarts < Self.maxFirstReportRestarts else {
            PopopxMeshLog.route.warning(
                "⚠️ no path report after \(self.restarts, privacy: .public) restart(s) — connectivity stays unknown, the router will not assume SMP"
            )
            return
        }
        restarts += 1
        PopopxMeshLog.route.warning(
            "🌫 no path report in \(self.firstReportTimeout, privacy: .public)s — restarting the path source"
        )
        await source.stopReporting()
        await installSource()
    }

    private func cancelWatchdog() {
        firstReportTask?.cancel()
        firstReportTask = nil
    }

    private func unsubscribe(_ id: UUID) {
        subscriptions[id] = nil
    }
}
