//
//  Torrc.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Everything written to disk for one daemon run, and the arguments that point `tor` at it.
///
/// The file is written `0600` inside a `0700` directory because it names the control port and the
/// bridge lines, and a bridge line is capability-adjacent material: a reader who knows which
/// bridges a user configured learns which networks they can reach.
public struct Torrc: Sendable, Equatable {
    public struct Ports: Sendable, Equatable {
        public let socks: UInt16
        public let control: UInt16
        /// The loopback address both ports are bound to. Numeric, never `localhost`: see
        /// ``IPAddressLiteral`` for the fail-open that a hostname causes.
        public let address: String

        public init(socks: UInt16, control: UInt16, address: String = "127.0.0.1") {
            self.socks = socks
            self.control = control
            self.address = address
        }

        public var socksProxyValue: String {
            guard let literal = IPAddressLiteral(address) else { return "" }
            return "\(literal.encodedHost):\(socks)"
        }
    }

    /// How much isolation the daemon should provide between the app's connections.
    public enum IsolationMode: String, Sendable, CaseIterable {
        /// One circuit per destination address and port. Deterministic, needs nothing from the
        /// client, and is the shipped default.
        case destination
        /// Additionally ask Tor to authenticate the SOCKS username the client sends.
        ///
        /// **Unverified against a pinned Tor build — do not ship this without running the check in
        /// `README.md`.** The chat core's default `SocksIsolateByAuth`
        /// (`popopxmq/src/Popopx/Messaging/Client.hs:461-476`) sends
        /// `base64(sha256(userId <> session material))` as the username and an **empty password**,
        /// while Tor's `Socks5PasswordAuth` requires each accepted username to be listed in
        /// `Socks5PasswordAuthAccept`. Those two do not obviously agree. Enabling password auth
        /// without confirming the agreement is the failure mode where every connection is refused,
        /// which the kill switch would then correctly report as a blocked network — a true alarm
        /// about a self-inflicted wound.
        case username
    }

    public let ports: Ports
    public let dataDirectory: URL
    public let isolationMode: IsolationMode
    public let owningProcessIdentifier: Int32
    public let bridges: [BridgeLine]

    public init(
        ports: Ports,
        dataDirectory: URL,
        isolationMode: IsolationMode = .destination,
        owningProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        bridges: [BridgeLine] = []
    ) {
        self.ports = ports
        self.dataDirectory = dataDirectory
        self.isolationMode = isolationMode
        self.owningProcessIdentifier = owningProcessIdentifier
        self.bridges = bridges
    }

    public var controlCookieURL: URL { dataDirectory.appendingPathComponent("control_auth_cookie") }
    public var torrcURL: URL { dataDirectory.appendingPathComponent("torrc") }

    /// The configuration text.
    ///
    /// `__OwningControllerProcess` is not decoration: it is the only lifecycle guarantee that
    /// survives the app being `kill -9`ed or crashing. A SIGTERM handler can be missed by a crash
    /// that takes the process down with its child still running, and an orphaned Tor holding a
    /// private data directory is exactly the kind of leftover that makes the next launch fail for a
    /// reason the user cannot see. Tor watches the owning PID and exits itself.
    public func lines() -> [String] {
        var out: [String] = [
            "DataDirectory \(dataDirectory.path)",
            "CacheDirectory \(dataDirectory.path)",
            // Both ports on loopback only. There is no supported way to ask Tor for a
            // loopback-only ControlPort that also opens it elsewhere, so the address is repeated on
            // each line rather than trusted to a default.
            socksListenerLine,
            "ControlPort \(ports.address):\(ports.control)",
            // Cookie rather than password authentication by default: the secret is written by Tor
            // itself into a 0600 file we never generate, never copy, and never place in an argument
            // vector where `ps` and the process audit log can read it.
            "CookieAuthentication 1",
            "CookieAuthFile \(controlCookieURL.path)",
            "CookieAuthFileGroupReadable 0",
            "__OwningControllerProcess \(owningProcessIdentifier)",
            "AvoidDiskWrites 1",
            "HardwareAccel 1",
            // Circuits and addresses would otherwise be echoed into the log we capture from stdout.
            "SafeLogging 1",
            "Log notice stdout"
        ]
        switch isolationMode {
        case .destination:
            break
        case .username:
            out.append("Socks5PasswordAuth 1")
        }
        if bridges.isEmpty == false {
            out.append("UseBridges 1")
            for bridge in bridges where bridge.isValid {
                out.append("Bridge \(bridge.line)")
            }
        }
        return out
    }

    /// Exactly one `SocksPort` line, with the isolation options on it.
    ///
    /// Tor reads each `SocksPort` as another listener rather than another option on the same one, so
    /// emitting a plain line and an isolated line asks it to bind the port we just reserved twice,
    /// and the daemon exits at startup over what is really a formatting choice.
    private var socksListenerLine: String {
        let base = "SocksPort \(ports.address):\(ports.socks)"
        switch isolationMode {
        case .destination, .username:
            return base + " IsolateDestAddr IsolateDestPort"
        }
    }

    public func contents() -> String {
        lines().joined(separator: "\n") + "\n"
    }

    /// Writes the directory and the file, tightening permissions before any secret-bearing content
    /// lands.
    public func write(overwriting: Bool = true) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if manager.fileExists(atPath: torrcURL.path), !overwriting {
            throw TorError.configurationExists(torrcURL)
        }
        try contents().write(to: torrcURL, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: torrcURL.path)
    }

    /// Removes the run directory. Called on graceful shutdown; a crash leaves it and the next
    /// launch reuses it, which is why the directory lives under Application Support rather than in
    /// a temporary one the OS might reclaim mid-run.
    public func eraseRunState() throws {
        try FileManager.default.removeItem(at: dataDirectory)
    }
}

public enum TorError: Error, Equatable, CustomStringConvertible {
    case configurationExists(URL)
    case binaryNotFound(candidates: [String])
    case daemonExitedUnexpectedly(status: Int32, output: String)
    case controlPortUnreachable(String)
    case authenticationRejected
    case protocolFraming(String)
    case timeout(String)
    case clientTransportPluginMissing(transports: [String])

    public var description: String {
        switch self {
        case let .configurationExists(url): return "a torrc already exists at \(url.path)"
        case let .binaryNotFound(candidates): return "no tor binary found; looked in \(candidates)"
        case let .daemonExitedUnexpectedly(status, output):
            return "tor exited with status \(status): \(output)"
        case let .controlPortUnreachable(detail): return "could not reach the control port: \(detail)"
        case .authenticationRejected: return "the control port rejected our authentication"
        case let .protocolFraming(detail): return "unexpected control-port framing: \(detail)"
        case let .timeout(what): return "timed out waiting for \(what)"
        case let .clientTransportPluginMissing(transports):
            return "the bridges named \(transports.joined(separator: ", ")) need a client transport "
                + "plugin binary that this build does not include, so the daemon could never "
                + "finish bootstrapping; remove them to connect without bridges"
        }
    }
}
