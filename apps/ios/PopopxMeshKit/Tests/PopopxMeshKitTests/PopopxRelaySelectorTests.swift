//
//  PopopxRelaySelectorTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The iOS half of the relay latency contract, mirroring `PopopxRelaySelectorTest.kt` case for case:
//  the two clients may render a badge differently but must not rank differently, and a divergence
//  here would mean a user sees "best" on one device and a different "best" on the other.
//
//  No test in this file opens a socket. The transport is injected, which is what makes the load-bearing
//  assertion possible: with a proxy configured, the number of direct handshakes attempted is zero.
//

import Testing

@testable import PopopxMeshKit

private let epoch: Int64 = 1_000_000_000
private let ttl = PopopxRelaySelector.cacheTtlMs

private func probe(host: String, ms: Int?, at: Int64 = epoch) -> PopopxRelayProbe {
    PopopxRelayProbe(host: host, latencyMs: ms, completedAtMs: at, reason: ms == nil ? PopopxRelaySelector.unreachable : nil)
}

/// Records what the selector asked for, so "no socket" is an assertion instead of a comment. An actor,
/// because the transport runs on several task-group children at once.
private actor ProbeLog {
    private(set) var hosts: [String] = []
    private(set) var port = -1
    private(set) var timeoutMs = -1

    func record(host: String, port: Int, timeoutMs: Int) {
        hosts.append(host)
        self.port = port
        self.timeoutMs = timeoutMs
    }

    var count: Int { hosts.count }
}

// MARK: - Constants

@Test("the probe ceiling, cache window, port and badge thresholds are the ruled values")
func ruledConstants() {
    #expect(PopopxRelaySelector.probeTimeoutMs == 3_000)
    #expect(PopopxRelaySelector.cacheTtlMs == 10 * 60 * 1_000)
    #expect(PopopxRelaySelector.probePort == 443)
    #expect(PopopxRelaySelector.fastBelowMs == 150)
    #expect(PopopxRelaySelector.slowBelowMs == 400)
}

// MARK: - Ranking

@Test("ranking orders measured hosts by latency")
func rankingOrdersByLatency() {
    let probes = [
        "smp3.popopx.im": probe(host: "smp3.popopx.im", ms: 90),
        "smp1.popopx.im": probe(host: "smp1.popopx.im", ms: 240),
        "smp2.popopx.im": probe(host: "smp2.popopx.im", ms: 30),
    ]
    let hosts = ["smp3.popopx.im", "smp1.popopx.im", "smp2.popopx.im"]
    #expect(PopopxRelaySelector.rank(hosts: hosts, probes: probes, nowMs: epoch + 1_000)
        == ["smp2.popopx.im", "smp3.popopx.im", "smp1.popopx.im"])
    #expect(PopopxRelaySelector.preferred(hosts: hosts, probes: probes, nowMs: epoch + 1_000) == "smp2.popopx.im")
}

@Test("unmeasured hosts follow the measured ones and keep their incoming order")
func unmeasuredKeepInputOrder() {
    let probes = ["smp2.popopx.im": probe(host: "smp2.popopx.im", ms: 500)]
    let hosts = ["smp1.popopx.im", "smp2.popopx.im", "smp3.popopx.im", "smp4.popopx.im"]
    // smp2 leads however slowly — it is the only evidence — and the tail stays in the core's shuffled
    // order instead of clustering on the first host.
    #expect(PopopxRelaySelector.rank(hosts: hosts, probes: probes, nowMs: epoch + 1)
        == ["smp2.popopx.im", "smp1.popopx.im", "smp3.popopx.im", "smp4.popopx.im"])
}

@Test("without measurements the ranking is the input order")
func noMeasurementsNoReordering() {
    let hosts = ["smp7.popopx.im", "smp2.popopx.im", "smp9.popopx.im"]
    #expect(PopopxRelaySelector.rank(hosts: hosts, probes: [:], nowMs: epoch) == hosts)
    #expect(PopopxRelaySelector.rank(hosts: hosts, probes: [:], nowMs: epoch, probingAllowed: false) == hosts)
    #expect(PopopxRelaySelector.preferred(hosts: [], probes: [:], nowMs: epoch) == nil)
}

@Test("a timed-out host does not sink the others")
func timeoutDoesNotSinkOthers() {
    let probes = [
        "smp1.popopx.im": probe(host: "smp1.popopx.im", ms: nil),
        "smp2.popopx.im": probe(host: "smp2.popopx.im", ms: 120),
    ]
    let hosts = ["smp1.popopx.im", "smp2.popopx.im", "smp3.popopx.im"]
    #expect(PopopxRelaySelector.rank(hosts: hosts, probes: probes, nowMs: epoch + 1)
        == ["smp2.popopx.im", "smp1.popopx.im", "smp3.popopx.im"])
}

@Test("the freshness window is exclusive at the boundary")
func freshnessIsExclusive() {
    let probes = ["smp1.popopx.im": probe(host: "smp1.popopx.im", ms: 40)]
    #expect(PopopxRelaySelector.fresh(probes, nowMs: epoch + ttl - 1).count == 1)
    #expect(PopopxRelaySelector.fresh(probes, nowMs: epoch + ttl).isEmpty, "exactly ttl old is stale")
    #expect(PopopxRelaySelector.fresh(probes, nowMs: epoch + ttl + 1).isEmpty)
    let hosts = ["smp1.popopx.im", "smp2.popopx.im"]
    #expect(PopopxRelaySelector.rank(hosts: hosts, probes: probes, nowMs: epoch + ttl + 1) == hosts)
    #expect(PopopxRelaySelector.badge(host: "smp1.popopx.im", probes: probes, nowMs: epoch + ttl + 1) == .unknown)
}

// MARK: - Badges

@Test("badge thresholds")
func badgeThresholds() {
    func badge(_ ms: Int) -> PopopxRelayBadge {
        PopopxRelaySelector.badge(host: "smp1.popopx.im", probes: ["smp1.popopx.im": probe(host: "smp1.popopx.im", ms: ms)], nowMs: epoch + 1)
    }
    #expect(badge(0) == .fast)
    #expect(badge(149) == .fast)
    #expect(badge(150) == .acceptable)
    #expect(badge(399) == .acceptable)
    #expect(badge(400) == .slow)
    #expect(badge(2_999) == .slow)
}

@Test("unreachable, fast and unknown are three different answers")
func badgeKinds() {
    let probes = [
        "smp1.popopx.im": probe(host: "smp1.popopx.im", ms: nil),
        "smp2.popopx.im": probe(host: "smp2.popopx.im", ms: 60),
    ]
    #expect(PopopxRelaySelector.badge(host: "smp1.popopx.im", probes: probes, nowMs: epoch + 1) == .unreachable)
    #expect(PopopxRelaySelector.badge(host: "smp2.popopx.im", probes: probes, nowMs: epoch + 1) == .fast)
    #expect(PopopxRelaySelector.badge(host: "smp3.popopx.im", probes: probes, nowMs: epoch + 1) == .unknown)
}

@Test("a proxy turns every badge into 不可测, even beside a fresh reading")
func proxyHidesEveryBadge() {
    let probes = [
        "smp1.popopx.im": probe(host: "smp1.popopx.im", ms: 20),
        "smp2.popopx.im": probe(host: "smp2.popopx.im", ms: nil),
    ]
    for host in ["smp1.popopx.im", "smp2.popopx.im", "smp3.popopx.im"] {
        #expect(
            PopopxRelaySelector.badge(host: host, probes: probes, nowMs: epoch + 1, probingAllowed: false) == .unavailable,
            "\(host) must not show a number while a proxy is on"
        )
    }
}

// MARK: - The probe seam

@Test("with a proxy active not one direct handshake is attempted")
func proxyBlocksEveryProbe() async {
    let hosts = ["smp1.popopx.im", "smp2.popopx.im"]
    let latencies = ["smp1.popopx.im": 40, "smp2.popopx.im": 80]
    let log = ProbeLog()

    let transport: PopopxRelayHandshake = { host, port, timeoutMs in
        await log.record(host: host, port: port, timeoutMs: timeoutMs)
        return latencies[host]
    }

    let refused = await PopopxRelaySelector.probe(hosts: hosts, allowed: false, transport: transport)
    #expect(await log.count == 0, "a direct probe while a proxy is on leaks the public address")
    #expect(refused.isEmpty)

    // Control: the same call with the gate open really does fan out, so the zero above is the gate and
    // not a transport that was never wired up.
    let round = await PopopxRelaySelector.probe(hosts: hosts, allowed: true, transport: transport)
    #expect(await log.count == 2)
    #expect(round.count == 2)
    #expect(await log.port == 443)
    #expect(await log.timeoutMs == 3_000)
    #expect(round["smp1.popopx.im"]?.latencyMs == 40)
    #expect(round["smp1.popopx.im"]?.healthy == true)
}

@Test("an empty host set probes nothing even when allowed")
func emptyHostSet() async {
    let log = ProbeLog()
    let transport: PopopxRelayHandshake = { host, port, timeoutMs in
        await log.record(host: host, port: port, timeoutMs: timeoutMs)
        return 10
    }
    let round = await PopopxRelaySelector.probe(hosts: [], allowed: true, transport: transport)
    #expect(round.isEmpty)
    #expect(await log.count == 0)
}

@Test("a host that never answers is recorded, not silently dropped")
func failureIsStillAnAnswer() async {
    let latencies = ["smp1.popopx.im": 50, "smp2.popopx.im": nil]
    let transport: PopopxRelayHandshake = { host, _, _ in latencies[host] ?? nil }
    let round = await PopopxRelaySelector.probe(hosts: ["smp1.popopx.im", "smp2.popopx.im"], allowed: true, transport: transport)
    #expect(round.count == 2, "a failure is still an answer about that host")
    let failed = round["smp2.popopx.im"]
    #expect(failed?.latencyMs == nil)
    #expect(failed?.reason == PopopxRelaySelector.unreachable)
    #expect(failed?.healthy == false)
}

// MARK: - Cache merging

@Test("a refused round keeps the old readings, a deleted host still leaves")
func refusedRoundKeepsReadings() {
    let previous = [
        "smp1.popopx.im": probe(host: "smp1.popopx.im", ms: 30),
        "smp2.popopx.im": probe(host: "smp2.popopx.im", ms: 60),
    ]
    let merged = PopopxRelaySelector.merged(previous: previous, round: [:], hosts: ["smp1.popopx.im"])
    #expect(Array(merged.keys) == ["smp1.popopx.im"])
    #expect(merged["smp1.popopx.im"]?.latencyMs == 30)
    // A refused round is not evidence that a relay got worse, so the reading survives; it is the badge
    // — not the cache — that the proxy gate hides.
    #expect(PopopxRelaySelector.badge(host: "smp1.popopx.im", probes: merged, nowMs: epoch + 1, probingAllowed: false) == .unavailable)
}

@Test("a real round replaces the hosts it covered and leaves the others alone")
func realRoundReplacesOwnHosts() {
    let previous = [
        "smp1.popopx.im": probe(host: "smp1.popopx.im", ms: 30),
        "smp2.popopx.im": probe(host: "smp2.popopx.im", ms: 60),
    ]
    // This round covered smp1 only (the other group's servers, or xftp, are a different host set).
    let round = ["smp1.popopx.im": probe(host: "smp1.popopx.im", ms: nil, at: epoch + 5_000)]
    let merged = PopopxRelaySelector.merged(previous: previous, round: round, hosts: ["smp1.popopx.im"])
    #expect(merged.count == 2)
    #expect(merged["smp1.popopx.im"]?.latencyMs == nil)
    #expect(merged["smp2.popopx.im"]?.latencyMs == 60, "hosts outside this round keep their reading")
    #expect(PopopxRelaySelector.badge(host: "smp1.popopx.im", probes: merged, nowMs: epoch + 5_001) == .unreachable)
    #expect(PopopxRelaySelector.badge(host: "smp2.popopx.im", probes: merged, nowMs: epoch + 5_001) == .fast)
}

// MARK: - The store

@Test("the store runs one round at a time and honours the freshness window")
func storeSingleFlight() async {
    let store = PopopxRelayLatency()
    let hosts = ["smp1.popopx.im", "smp2.popopx.im"]
    let latencies = ["smp1.popopx.im": 210, "smp2.popopx.im": 35]
    let log = ProbeLog()
    let transport: PopopxRelayHandshake = { host, port, timeoutMs in
        await log.record(host: host, port: port, timeoutMs: timeoutMs)
        return latencies[host]
    }

    // Refused: nothing probed, nothing cached, badge says 不可测.
    _ = await store.refresh(hosts: hosts, probingAllowed: false, transport: transport)
    #expect(await log.count == 0)
    #expect(await store.badge(host: "smp1.popopx.im", probingAllowed: false) == .unavailable)

    // Allowed: one round, ranked by latency.
    _ = await store.refresh(hosts: hosts, probingAllowed: true, transport: transport)
    #expect(await log.count == 2)
    #expect(await store.ranked(hosts, probingAllowed: true) == ["smp2.popopx.im", "smp1.popopx.im"])
    #expect(await store.badge(host: "smp2.popopx.im", probingAllowed: true) == .fast)
    #expect(await store.badge(host: "smp1.popopx.im", probingAllowed: true) == .acceptable)
    // The ranking falls back to the incoming order the moment probing is refused again.
    #expect(await store.ranked(hosts, probingAllowed: false) == hosts)

    // A second refresh inside the window does not re-probe.
    _ = await store.refresh(hosts: hosts, probingAllowed: true, transport: transport)
    #expect(await log.count == 2)

    // 立即重新测速 does.
    _ = await store.refresh(hosts: hosts, probingAllowed: true, force: true, transport: transport)
    #expect(await log.count == 4)

    await store.invalidate()
    #expect(await store.probes().isEmpty)
}
