//
//  PopopxRelaySelector.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Latency of the SMP relays the current profile has enabled, measured on the device.
//
//  Byte-for-byte behavioural twin of
//  `apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/network/PopopxRelaySelector.kt`:
//  same constants (3 s probe ceiling, 10-minute cache, port 443, green <150 ms, amber <400 ms), same
//  ranking, same badge states, same proxy gate. A platform may render the badge differently; it may
//  not decide differently.
//
//  The zero-metadata rule (铁律, ruled 2026-11-26): a probe is a TCP connect and a TLS handshake and
//  nothing else. No queue id, no contact address, no device or profile identifier, no application
//  bytes at all — `startHandshake` is the last thing the socket sees before it is closed. A probe
//  that carried session state would be a metadata leak presented as a performance feature.
//
//  The proxy rule: when SMP traffic is routed through the app's SOCKS5/Tor proxy, the proxy is opened
//  inside the pinned popopxmq dependency, so an app-layer socket does not traverse it. A direct probe
//  taken while a proxy is on would therefore reveal the public address the proxy exists to hide.
//  `allowed == false` means the transport is never invoked and every badge becomes `unavailable`
//  (不可测) — never a stale number, which a user would read as a live reading.
//
//  What this does not do: choose the server for a new queue. That happens in the Haskell core
//  (`chooseRandomServers`, over the enabled set), which this layer cannot reach and, by ruling, must
//  not try to. `preferredHost` is offered for callers that have an app-side choice to make; where
//  there is none, the ranking is a label and a toggle, not an override.
//

import Foundation
import Network

// MARK: - Values

/// One probe result. `latencyMs == nil` means "no handshake came back"; `reason` names the class of
/// failure coarsely, because an error string can carry a port or a TLS alert and none of that belongs
/// in a UI label.
public struct PopopxRelayProbe: Equatable, Hashable, Sendable {
    public let host: String
    public let latencyMs: Int?
    public let completedAtMs: Int64
    public let reason: String?

    public init(host: String, latencyMs: Int?, completedAtMs: Int64, reason: String? = nil) {
        self.host = host
        self.latencyMs = latencyMs
        self.completedAtMs = completedAtMs
        self.reason = reason
    }

    public var healthy: Bool { latencyMs != nil }
}

/// The badge a settings row shows. `unavailable` is deliberately distinct from `slow`: the first is
/// "this build is not allowed to look", the second is "it looked and it was bad". Folding them would
/// hide the proxy gate, which is the one fact here a user is entitled to see.
public enum PopopxRelayBadge: String, Hashable, Sendable {
    case unknown
    case fast
    case acceptable
    case slow
    case unreachable
    case unavailable

    /// The English literal this badge is localized under, as a `String` on purpose: `PopopxMeshKit`
    /// has no SwiftUI dependency (the view layer is `PopopxMeshUI`), so the UI wraps this in a
    /// `LocalizedStringKey` at the point of display. A key is a literal here, the same convention as
    /// `PopopxPanicWipeManager.confirmationBoundary` — no pbxproj change needed to add one.
    /// "Acceptable" rather than the shorter "OK": the literal is the lookup key, and `zh` already
    /// resolves "OK" to the alert button (「好的」), which would otherwise render as a latency badge.
    public var labelKey: String {
        switch self {
        case .unknown: return "Not measured"
        case .fast: return "Fast"
        case .acceptable: return "Acceptable"
        case .slow: return "Slow"
        case .unreachable: return "Unreachable"
        case .unavailable: return "Not measurable with a proxy on"
        }
    }
}

/// How one host is reached, as a seam: returning nil means "no handshake inside the timeout". A test
/// substitutes this, so the proxy gate and the ranking are provable without a network — and a probe
/// count is assertable, which is the only way to prove "no direct socket when the proxy is on".
public typealias PopopxRelayHandshake = @Sendable (_ host: String, _ port: Int, _ timeoutMs: Int) async -> Int?

// MARK: - Decisions

public enum PopopxRelaySelector {
    /// A relay that has not answered this quickly is treated as down for selection purposes.
    public static let probeTimeoutMs = 3_000
    /// Re-probe interval: the trade between a useful badge and a background connection pattern that
    /// someone on the network can correlate.
    public static let cacheTtlMs: Int64 = 10 * 60 * 1_000
    /// SMP over TLS. No path and no query — the address stops at the host on purpose.
    public static let probePort = 443
    /// Green / amber ceilings.
    public static let fastBelowMs = 150
    public static let slowBelowMs = 400

    /// Monotonic milliseconds: a wall-clock jump (NTP, travel, a manual change) must not be able to
    /// make a measurement look negative or immortal.
    public static func nowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// Probes still trustworthy at `nowMs`. Absent and expired are the same thing to every caller:
    /// not evidence.
    public static func fresh(
        _ probes: [String: PopopxRelayProbe],
        nowMs: Int64,
        ttlMs: Int64 = PopopxRelaySelector.cacheTtlMs
    ) -> [String: PopopxRelayProbe] {
        probes.filter { $0.value.completedAtMs + ttlMs > nowMs }
    }

    /// The badge for one host. `probingAllowed` is the proxy gate; it wins over any stored reading.
    public static func badge(
        host: String,
        probes: [String: PopopxRelayProbe],
        nowMs: Int64,
        probingAllowed: Bool = true,
        ttlMs: Int64 = PopopxRelaySelector.cacheTtlMs
    ) -> PopopxRelayBadge {
        guard probingAllowed else { return .unavailable }
        guard let probe = fresh(probes, nowMs: nowMs, ttlMs: ttlMs)[host] else { return .unknown }
        guard let latency = probe.latencyMs else { return .unreachable }
        if latency < fastBelowMs { return .fast }
        if latency < slowBelowMs { return .acceptable }
        return .slow
    }

    /// Enabled hosts, best first. Only fresh, healthy measurements are promoted, in ascending latency
    /// order; everything else keeps the order it arrived in and follows the measured set. That matters:
    /// the incoming order is the core's shuffled enabled list, so an unmeasured tail stays randomised
    /// instead of piling onto the first host and turning a latency feature into a load imbalance.
    public static func rank(
        hosts: [String],
        probes: [String: PopopxRelayProbe],
        nowMs: Int64,
        probingAllowed: Bool = true,
        ttlMs: Int64 = PopopxRelaySelector.cacheTtlMs
    ) -> [String] {
        guard probingAllowed else { return hosts }
        let usable = fresh(probes, nowMs: nowMs, ttlMs: ttlMs)
        let measured = hosts.filter { usable[$0]?.healthy == true }
        let rest = hosts.filter { usable[$0]?.healthy != true }
        return measured.sorted { (usable[$0]!.latencyMs ?? 0) < (usable[$1]!.latencyMs ?? 0) } + rest
    }

    /// The head of `rank`, or nil when there is nothing to prefer. Callers read nil as "keep doing what
    /// you were already doing".
    public static func preferred(
        hosts: [String],
        probes: [String: PopopxRelayProbe],
        nowMs: Int64,
        probingAllowed: Bool = true
    ) -> String? {
        rank(hosts: hosts, probes: probes, nowMs: nowMs, probingAllowed: probingAllowed).first
    }

    /// Merge a round into a cache. An empty round means the round was refused (proxy on, or nothing to
    /// probe), which is not evidence that anything got worse, so the previous readings survive; hosts
    /// that left the enabled set are dropped either way.
    public static func merged(
        previous: [String: PopopxRelayProbe],
        round: [String: PopopxRelayProbe],
        hosts: [String]
    ) -> [String: PopopxRelayProbe] {
        let kept = Set(hosts)
        if round.isEmpty { return previous.filter { kept.contains($0.key) } }
        return previous.filter { !kept.contains($0.key) }.merging(round) { _, new in new }
    }

    // MARK: Probing

    /// Probe every host concurrently. `allowed` is checked here rather than at each call site: this is
    /// the only function that touches a socket, so a caller that forgets the flag still cannot leak.
    public static func probe(
        hosts: [String],
        allowed: Bool,
        transport: PopopxRelayHandshake? = nil,
        timeoutMs: Int = PopopxRelaySelector.probeTimeoutMs,
        port: Int = PopopxRelaySelector.probePort
    ) async -> [String: PopopxRelayProbe] {
        guard allowed, !hosts.isEmpty else { return [:] }
        let handshake = transport ?? directTransport
        return await withTaskGroup(of: PopopxRelayProbe.self) { group in
            for host in hosts {
                group.addTask {
                    let latency = await handshake(host, port, timeoutMs)
                    return PopopxRelayProbe(
                        host: host,
                        latencyMs: latency,
                        completedAtMs: PopopxRelaySelector.nowMs(),
                        reason: latency == nil ? PopopxRelaySelector.unreachable : nil
                    )
                }
            }
            var results: [String: PopopxRelayProbe] = [:]
            for await sample in group { results[sample.host] = sample }
            return results
        }
    }

    public static let unreachable = "unreachable"

    /// The production transport: connect, handshake, close. Kept as a value so a caller can pass a
    /// proxy-aware implementation later without any decision logic changing.
    public static let directTransport: PopopxRelayHandshake = { host, port, timeoutMs in
        await PopopxTLSSession().time(host: host, port: port, timeoutMs: timeoutMs)
    }
}

// MARK: - The socket

/// One TLS handshake, timed.
///
/// A class with a lock, not a bare `NWConnection` in an async closure: at this package's deployment
/// floor the system type is not `Sendable` (the same reason `PopopxNWPathSource` wraps rather than
/// passes through), so the connection never leaves this object, and the continuation is resumed
/// exactly once by whoever takes the slot first — the state handler, the timer, or a cancellation.
private final class PopopxTLSSession: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Int?, Never>?
    private var timer: Task<Void, Never>?
    private var started: Int64 = 0
    private let queue = DispatchQueue(label: "chat.popopx.mesh.relay-probe", qos: .utility)

    /// Elapsed milliseconds until the TLS handshake completed, or nil for timeout / failure / refusal.
    func time(host: String, port: Int, timeoutMs: Int) async -> Int? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                begin(host: host, port: port, timeoutMs: timeoutMs, continuation: continuation)
            }
        } onCancel: {
            finish(nil)
        }
    }

    private func begin(host: String, port: Int, timeoutMs: Int, continuation: CheckedContinuation<Int?, Never>) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            continuation.resume(returning: nil)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters.tls)
        lock.lock()
        guard self.continuation == nil else {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        // Captured by the handler instead of stored, so the callback reads the value this socket was
        // opened with rather than racing whoever next takes the object.
        let started = PopopxRelaySelector.nowMs()
        // `.tls` with no ALPN and no peer certificate pinning: the client-hello carries the server
        // name and nothing else, which is the whole of the probe's on-wire footprint.
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.finish(Int(PopopxRelaySelector.nowMs() - started))
            case .failed, .cancelled:
                self.finish(nil)
            case .waiting:
                // Not an answer: `.waiting` also covers "the radio is still coming up", which is the
                // case the 3 s ceiling exists for. `NWError` carries no separable code at this SDK, so
                // guessing which waiting is fatal would be a guess about a system enum, not a fact.
                break
            default:
                // `.setup` and anything a future SDK adds: neither is an answer, and the timer is what
                // ends the wait for them. `NetworkStateMonitor` writes the same way for the same reason.
                break
            }
        }
        self.connection = connection
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
            if !Task.isCancelled { self?.finish(nil) }
        }
        self.timer = timer
        lock.unlock()

        connection.start(queue: queue)
    }

    /// Takes the continuation slot; whoever gets it first is the answer, and the socket is shut down
    /// after the slot is empty so a late callback cannot resume twice.
    private func finish(_ value: Int?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()

        timer?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        continuation?.resume(returning: value)
    }
}

// MARK: - The store the settings screen reads

/// Cached probe round, owned by one actor so two screens asking at the same time cannot start two
/// rounds against the same hosts (the concurrency hole the earlier relay-latency audit found).
public actor PopopxRelayLatency {
    public static let shared = PopopxRelayLatency()

    /// The last round, keyed by host. Public through `probes()` only, so no caller mutates a reading.
    private var cached: [String: PopopxRelayProbe] = [:]
    private var inFlight: Task<[String: PopopxRelayProbe], Never>?

    public init() {}

    public func probes() -> [String: PopopxRelayProbe] { cached }

    /// The ranked view of `hosts`, using whatever is cached. Refused (proxy on) means the input order
    /// comes back, which is the core's own randomisation.
    public func ranked(_ hosts: [String], probingAllowed: Bool) -> [String] {
        PopopxRelaySelector.rank(hosts: hosts, probes: cached, nowMs: PopopxRelaySelector.nowMs(), probingAllowed: probingAllowed)
    }

    public func badge(host: String, probingAllowed: Bool) -> PopopxRelayBadge {
        PopopxRelaySelector.badge(host: host, probes: cached, nowMs: PopopxRelaySelector.nowMs(), probingAllowed: probingAllowed)
    }

    /// Refresh, unless the cache is still fresh and `force` is false. `force` is the 「立即重新测速」
    /// button. A concurrent call joins the round already running instead of starting another.
    public func refresh(
        hosts: [String],
        probingAllowed: Bool,
        force: Bool = false,
        transport: PopopxRelayHandshake? = nil
    ) async -> [String: PopopxRelayProbe] {
        guard probingAllowed else {
            // Ruled: no direct probe behind a proxy. The readings stay cached for the badge logic to
            // hide, and the caller's UI shows 不可测.
            return cached
        }
        let now = PopopxRelaySelector.nowMs()
        if !force, hosts.allSatisfy({ cached[$0].map { $0.completedAtMs + PopopxRelaySelector.cacheTtlMs > now } ?? false }) {
            return cached
        }
        if let inFlight { return await inFlight.value }
        let task = Task {
            await PopopxRelaySelector.probe(hosts: hosts, allowed: true, transport: transport)
        }
        inFlight = task
        let round = await task.value
        inFlight = nil
        cached = PopopxRelaySelector.merged(previous: cached, round: round, hosts: hosts)
        return cached
    }

    /// Forget everything, so a profile switch or a proxy toggle cannot leave a reading attached to a
    /// host that is no longer in the enabled set.
    public func invalidate() {
        cached = [:]
        inFlight?.cancel()
        inFlight = nil
    }
}
