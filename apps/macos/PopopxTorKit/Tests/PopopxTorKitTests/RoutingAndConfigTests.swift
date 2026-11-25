//
//  RoutingAndConfigTests.swift
//  PopopxTorKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Darwin
import Foundation
@testable import PopopxTorKit
import XCTest

final class IPAddressLiteralTests: XCTestCase {
    func testLoopbackLiteralsAreAccepted() {
        XCTAssertEqual(IPAddressLiteral("127.0.0.1"), .v4("127.0.0.1"))
        XCTAssertEqual(IPAddressLiteral("::1"), .v6("::1"))
        XCTAssertEqual(IPAddressLiteral("127.0.0.53"), .v4("127.0.0.53"))
    }

    func testHostnamesAreRejectedIncludingLocalhost() {
        // `APITypes.swift:446-458` in the app target drops a proxy whose host is not a numeric
        // literal, and it drops it in silence: the app then connects directly while the settings
        // screen still shows a proxy.
        XCTAssertNil(IPAddressLiteral("localhost"))
        XCTAssertNil(IPAddressLiteral("proxy.local"))
        XCTAssertNil(IPAddressLiteral("socks.torproject.org"))
        XCTAssertNil(IPAddressLiteral("127.0.0.1.example.com"))
        XCTAssertNil(IPAddressLiteral(""))
    }

    func testOctetsMustBeInRange() {
        XCTAssertNil(IPAddressLiteral("300.1.1.1"))
        XCTAssertNil(IPAddressLiteral("127.0.0"))
    }

    func testLeadingZeroOctetsAreRejected() {
        XCTAssertNil(IPAddressLiteral("01.2.3.4"))
        XCTAssertNil(IPAddressLiteral("127.0.0.01"))
    }

    func testIPv6CompressionAndGroupCountAreEnforced() {
        // The "::" run may sit at either end; anything that is neither eight groups nor compressed is
        // not a literal, and a rejected host here means the proxy silently disappears upstream.
        for host in ["::", "::1", "fe80::", "fe80::1", "2001:db8:0:0:0:0:0:1", "::ffff:127.0.0.1"] {
            XCTAssertNotNil(IPAddressLiteral(host), "\(host) is a valid literal")
        }
        for host in ["1:2:3", "1:2:3:4:5:6:7:8:9", "fe80::1::2", "1::2:", "gggg::1", "127.0.0.1:8080"] {
            XCTAssertNil(IPAddressLiteral(host), "\(host) is not a valid literal")
        }
    }

    func testEncodingBracketsOnlyIPv6() {
        XCTAssertEqual(IPAddressLiteral("127.0.0.1")?.encodedHost, "127.0.0.1")
        // `Transport/Client.hs:256` splits the proxy string on its first colon, so an unbracketed
        // v6 literal would be cut to an empty host.
        XCTAssertEqual(IPAddressLiteral("::1")?.encodedHost, "[::1]")
    }
}

final class RoutingPolicyTests: XCTestCase {
    func testStrictPolicyProhibitsTheDirectFallbackBeforeTheCircuitIsUp() throws {
        for ready in [false, true] {
            let policy = try TorRoutingPolicy.makePolicy(
                socksHost: "127.0.0.1",
                socksPort: 39_123,
                strict: true,
                circuitReady: ready
            )
            XCTAssertEqual(policy.smpProxyFallback, .prohibit, ready ? "after bootstrap" : "during bootstrap")
            XCTAssertEqual(policy.directConnectionsPermitted, false)
            XCTAssertEqual(policy.hostMode, .onionViaSocks)
            // Ruling: onion preference is never forced, because every `.onion` in the shipped relay
            // presets belongs to another operator.
            XCTAssertEqual(policy.requiredHostMode, false)
        }
    }

    func testProxyStringCarriesNoScheme() throws {
        let policy = try TorRoutingPolicy.makePolicy(
            socksHost: "127.0.0.1", socksPort: 39_123, strict: true, circuitReady: true
        )
        XCTAssertEqual(policy.proxyString, "127.0.0.1:39123")
        // The dependency parses this with `StrEncoding`, not as a URL: a scheme prefix would be read
        // as the SOCKS username and the proxy would silently stop being used.
        let proxy = policy.proxyString ?? ""
        for scheme in ["socks5h://", "socks5://", "socks4://", "http://"] {
            XCTAssertFalse(proxy.contains(scheme), "\(scheme) must not appear")
        }
        XCTAssertFalse(proxy.contains("/"))
    }

    func testNonStrictPolicyRelaxesDirectConnectionsOnlyAfterBootstrap() throws {
        let during = try TorRoutingPolicy.makePolicy(
            socksHost: "127.0.0.1", socksPort: 39_123, strict: false, circuitReady: false
        )
        let after = try TorRoutingPolicy.makePolicy(
            socksHost: "127.0.0.1", socksPort: 39_123, strict: false, circuitReady: true
        )
        XCTAssertEqual(during.directConnectionsPermitted, true)
        XCTAssertEqual(after.directConnectionsPermitted, false)
        XCTAssertEqual(after.smpProxyFallback, .allowProtected)
        XCTAssertEqual(after.proxyString, during.proxyString)
    }

    func testAHostnameNeverBecomesANilProxy() {
        // The fail-open this type exists to close: a hostname would be accepted here and dropped by
        // the core, leaving the app with no proxy and no warning.
        XCTAssertThrowsError(try TorRoutingPolicy.makePolicy(
            socksHost: "localhost", socksPort: 39_123, strict: true, circuitReady: true
        )) { error in
            guard let failure = error as? RoutingPolicyError, case .hostIsNotAnIPLiteral(let host) = failure else {
                return XCTFail("expected hostIsNotAnIPLiteral, got \(error)")
            }
            XCTAssertEqual(host, "localhost")
        }
    }

    func testAnUnboundPortIsRejected() {
        XCTAssertThrowsError(try TorRoutingPolicy.makePolicy(
            socksHost: "127.0.0.1", socksPort: 0, strict: true, circuitReady: false
        )) { error in
            XCTAssertTrue(error is RoutingPolicyError)
        }
    }

    func testDisabledAndProhibitedPoliciesAreDistinguishable() {
        XCTAssertNil(TorRoutingPolicy.disabled.proxyString)
        XCTAssertEqual(TorRoutingPolicy.disabled.directConnectionsPermitted, true)
        XCTAssertEqual(TorRoutingPolicy.disabled.smpProxyFallback, .allowProtected)

        XCTAssertNil(TorRoutingPolicy.prohibited.proxyString)
        XCTAssertEqual(TorRoutingPolicy.prohibited.smpProxyFallback, .prohibit)
        XCTAssertEqual(TorRoutingPolicy.prohibited.directConnectionsPermitted, false)
    }

    func testIntentRawValuesMatchTheWireNamesTheCoreEncodes() {
        // Measured against `apps/ios/POPOPXChat/APITypes.swift:321-325` (`HostMode`), `:327-330`
        // (`SocksMode`) and `:352-355` (`SMPProxyFallback`). Renaming a case on either side without
        // the other is a silent configuration loss, so both spellings are pinned here.
        XCTAssertEqual(SmpProxyFallbackIntent.allCases.map(\.rawValue), ["allow", "allowProtected", "prohibit"])
        XCTAssertEqual(HostModeIntent.allCases.map(\.rawValue), ["onionViaSocks", "onion", "public"])
        XCTAssertEqual(SocksModeIntent.allCases.map(\.rawValue), ["always", "onion"])
    }

    func testNoPublishedPolicyLeavesAClearnetRelayUnproxied() throws {
        // `SocksMode.onion` means "proxy only `.onion` destinations", so a relay reached by its public
        // host would connect directly while the UI still reported Tor as on. The package never offers
        // it, which is what makes `directConnectionsPermitted` a claim the core actually honours.
        var policies = [TorRoutingPolicy.disabled, TorRoutingPolicy.prohibited]
        for strict in [false, true] {
            for ready in [false, true] {
                policies.append(try TorRoutingPolicy.makePolicy(
                    socksHost: "127.0.0.1",
                    socksPort: 39_123,
                    strict: strict,
                    circuitReady: ready
                ))
            }
        }
        for policy in policies {
            XCTAssertEqual(policy.socksMode, .always)
        }
    }
}

final class TrafficGateTests: XCTestCase {
    func testStrictModeBlocksEverythingExceptACompletedCircuit() {
        for phase in [TorPhase.stopped, .launching, .bootstrapping(0), .bootstrapping(99), .circuitLost, .failed(reason: "x")] {
            XCTAssertEqual(TrafficGate.evaluate(phase: phase, strict: true).isBlocked, true, "\(phase)")
        }
        XCTAssertEqual(TrafficGate.evaluate(phase: .ready, strict: true), .permitted)
    }

    func testNonStrictModeNeverBlocks() {
        let phases = [TorPhase.stopped, .launching, .bootstrapping(45), .circuitLost, .failed(reason: "x"), .ready]
        for phase in phases {
            XCTAssertEqual(TrafficGate.evaluate(phase: phase, strict: false), .permitted, "\(phase)")
        }
    }

    func testBlockedReasonCarriesThePhaseThatCausedIt() {
        XCTAssertEqual(
            TrafficGate.evaluate(phase: .bootstrapping(62), strict: true),
            .blocked(reason: .bootstrapping(percent: 62))
        )
        XCTAssertEqual(
            TrafficGate.evaluate(phase: .circuitLost, strict: true),
            .blocked(reason: .circuitLost)
        )
        XCTAssertEqual(
            TrafficGate.evaluate(phase: .stopped, strict: true),
            .blocked(reason: .daemonStopped)
        )
    }

    func testProgressOnlyMovesForward() {
        XCTAssertEqual(TorPhase.bootstrapping(40).byApplying(progress: progress(30)), .bootstrapping(40))
        XCTAssertEqual(TorPhase.bootstrapping(40).byApplying(progress: progress(70)), .bootstrapping(70))
        XCTAssertEqual(TorPhase.bootstrapping(40).byApplying(progress: progress(100)), .ready)
        XCTAssertEqual(TorPhase.stopped.byApplying(progress: progress(10)), .bootstrapping(10))
    }

    func testANewnymReannouncementDoesNotReopenTheSwitchOnAReadyDaemon() {
        // Tor re-emits `PROGRESS=0` after `SIGNAL NEWNYM` in some versions. Circuit loss has its own
        // `CIRC` event; a progress message must not be able to cut a working connection.
        for percent in [0, 55] {
            XCTAssertEqual(TorPhase.ready.byApplying(progress: progress(percent)), .ready)
        }
        XCTAssertEqual(TorPhase.ready.byApplying(progress: progress(100)), .ready)
    }

    private func progress(_ percent: Int) -> BootstrapProgress {
        BootstrapProgress(percent: percent, tag: nil, summary: nil, warning: nil)
    }
}

final class TorrcTests: XCTestCase {
    private let ports = Torrc.Ports(socks: 39_123, control: 39_124)

    private func torrc(
        isolation: Torrc.IsolationMode = .destination,
        bridges: [BridgeLine] = []
    ) -> Torrc {
        Torrc(
            ports: ports,
            dataDirectory: URL(fileURLWithPath: "/tmp/popopx-torkit-test"),
            isolationMode: isolation,
            owningProcessIdentifier: 4242,
            bridges: bridges
        )
    }

    private func socksLines(_ config: Torrc) -> [Substring] {
        config.contents().split(separator: "\n").filter { $0.hasPrefix("SocksPort ") }
    }

    func testExactlyOneSocksListenerIsEmitted() {
        // Each `SocksPort` line is another listener, so a second line asks the daemon to bind the
        // port we just reserved again and it exits at startup.
        XCTAssertEqual(socksLines(torrc()).count, 1)
        XCTAssertEqual(socksLines(torrc(isolation: .username)).count, 1)
    }

    func testLoopbackIsSpelledOnBothListeners() {
        let text = torrc().contents()
        XCTAssertTrue(text.contains("SocksPort 127.0.0.1:39123 IsolateDestAddr IsolateDestPort"))
        XCTAssertTrue(text.contains("ControlPort 127.0.0.1:39124"))
        XCTAssertFalse(text.contains("ControlPort 0."))
        XCTAssertFalse(text.contains("ControlPort 9051"))
    }

    func testNoPlaintextSecretIsEverWritten() {
        let text = torrc().contents()
        for forbidden in ["HashedControlPassword", "ControlPortPassword", "Socks5PasswordAuthAccept", "AUTHENTICATE"] {
            XCTAssertFalse(text.contains(forbidden), "\(forbidden) must not appear in the generated config")
        }
        XCTAssertTrue(text.contains("CookieAuthentication 1"))
        XCTAssertTrue(text.contains("CookieAuthFileGroupReadable 0"))
    }

    func testOwningProcessAndSafeLoggingAreSet() {
        let text = torrc().contents()
        XCTAssertTrue(text.contains("__OwningControllerProcess 4242"))
        XCTAssertTrue(text.contains("SafeLogging 1"))
        XCTAssertTrue(text.contains("Log notice stdout"))
    }

    func testUsernameIsolationTurnsOnSOCKS5AuthWithoutNamingAUser() {
        let text = torrc(isolation: .username).contents()
        XCTAssertTrue(text.contains("Socks5PasswordAuth 1"))
    }

    func testBridgesAreOnlyEmittedWhenValid() {
        let valid = BridgeLine("obfs4 5.6.7.9:9001 6991B3A5E9A4003B9D4C000000000000000000AB cert=Y3R58B22 iat-mode=0")
        let invalid = BridgeLine("obfs4 5.6.7.9:9001 6991B3A5E9A4003B9D4C000000000000000000AB iat-mode=0")
        let text = torrc(bridges: [valid!, invalid!]).contents()
        XCTAssertTrue(text.contains("UseBridges 1"))
        XCTAssertEqual(text.split(separator: "\n").filter { $0.hasPrefix("Bridge ") }.count, 1)
    }

    func testNoBridgesMeansNoUseBridges() {
        XCTAssertFalse(torrc().contents().contains("UseBridges"))
    }

    func testWrittenFilesArePrivateToTheUser() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("popopx-torkit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = Torrc(ports: ports, dataDirectory: directory, owningProcessIdentifier: 1)
        try config.write()

        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.int16Value, 0o700)
        let fileMode = try FileManager.default.attributesOfItem(atPath: config.torrcURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.int16Value, 0o600)
    }

    func testRefusingToOverwriteIsAnErrorRatherThanASilentKeep() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("popopx-torkit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = Torrc(ports: ports, dataDirectory: directory, owningProcessIdentifier: 1)
        try config.write()
        XCTAssertThrowsError(try config.write(overwriting: false)) { error in
            guard let failure = error as? TorError, case .configurationExists(let url) = failure else {
                return XCTFail("expected configurationExists, got \(error)")
            }
            XCTAssertEqual(url, config.torrcURL)
        }
    }
}

final class LoopbackPortAllocatorTests: XCTestCase {
    func testTwoDistinctPortsAreReservedOnLoopbackAndHeldOpen() throws {
        let ports = try LoopbackPortAllocator().allocate()
        defer { ports.socks.release(); ports.control.release() }
        XCTAssertNotEqual(ports.socks.port, ports.control.port)
        for reserved in [ports.socks, ports.control] {
            XCTAssertFalse(
                LoopbackPortAllocator.reservedPorts.contains(reserved.port),
                "port \(reserved.port) is Tor's own default and must be avoided"
            )
            XCTAssertTrue((49_152...65_534).contains(reserved.port))
            XCTAssertEqual(Self.listenerAddress(reserved.descriptor), "127.0.0.1")
            // Held, not merely probed: a second bind of the same port must fail while we own it.
            XCTAssertFalse(Self.canBind(reserved.port))
        }
    }

    func testReleasedPortsBecomeBindablesAgain() throws {
        let reserved = try LoopbackPortAllocator().reserve(excluding: [])
        XCTAssertFalse(Self.canBind(reserved.port))
        reserved.release()
        XCTAssertTrue(Self.canBind(reserved.port))
    }

    func testExcludedPortsAreNeverReturned() throws {
        let blocked: Set<UInt16> = Set(49_152...49_161)
        let allocator = LoopbackPortAllocator(lowerBound: 49_152, upperBound: 49_162, attempts: 200)
        let reserved = try allocator.reserve(excluding: blocked)
        defer { reserved.release() }
        XCTAssertEqual(reserved.port, 49_162)
    }

    /// Binds and listens from the test process, then closes. Returns whether the port was free.
    private static func canBind(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = port.bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    private static func listenerAddress(_ descriptor: Int32) -> String {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { return "" }
        return inet_ntoa(address.sin_addr).map { String(cString: $0) } ?? ""
    }
}
