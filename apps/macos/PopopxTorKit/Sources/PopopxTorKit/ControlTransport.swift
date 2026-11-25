//
//  ControlTransport.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Darwin
import Foundation

/// A bidirectional byte pipe to the control port.
///
/// Behind a protocol so the controller, the parser and the whole authentication path are testable
/// without a Tor on the machine — which matters because CI has none, and a test that cannot run is
/// an absent guard rather than a passing one.
public protocol ControlTransport: AnyObject {
    func write(_ data: Data) throws
    /// Blocks until at least one byte arrives, the peer closes, or the deadline passes.
    func read(maximumBytes: Int) throws -> Data
    func close()
}

/// Loopback TCP client for the control port.
///
/// A plain blocking POSIX socket rather than `Network.framework`: the read loop here is a single
/// thread with a shutdown path, and `NWConnection`'s callback queue model would add a hop and a
/// class of reordering questions in exchange for nothing this client needs.
public final class LoopbackControlTransport: ControlTransport, @unchecked Sendable {
    private var descriptor: Int32 = -1
    private let gate = NSLock()

    /// Wraps an already-connected descriptor.
    ///
    /// Read timeouts come from `SO_RCVTIMEO` on the socket itself, so there is no deadline to carry
    /// here; an absolute `Date` would only invite the mistake of comparing it against a relative one.
    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Connects to `host:port`, refusing any host that is not a loopback literal.
    ///
    /// The refusal is not paranoia about configuration drift: the control port can rewrite the
    /// daemon's own exit configuration, so a socket that reaches a control port across a network
    /// boundary is a traffic-redirection primitive handed to whatever is on that boundary.
    public convenience init(host: String, port: UInt16, timeout: TimeInterval = 5) throws {
        guard let address = IPAddressLiteral(host), Self.isLoopback(address) else {
            throw TorError.controlPortUnreachable(
                "\(host) is not a loopback literal; the control port is only ever contacted on 127.0.0.1"
            )
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TorError.controlPortUnreachable("socket() errno \(errno)") }
        var storage = sockaddr_in()
        storage.sin_family = sa_family_t(AF_INET)
        storage.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        storage.sin_port = port.bigEndian
        let connected: Int32 = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected < 0 {
            let code = errno
            Darwin.close(fd)
            throw TorError.controlPortUnreachable("connect() errno \(code)")
        }
        // SO_RCVTIMEO keeps a wedged daemon from blocking the caller forever; a read that times out
        // surfaces as `.timeout` rather than as a hung thread behind a spinner.
        var receipt = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receipt, socklen_t(MemoryLayout<timeval>.size))
        var sendTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        self.init(descriptor: fd)
    }

    public func write(_ data: Data) throws {
        gate.lock()
        defer { gate.unlock() }
        guard descriptor >= 0 else { throw TorError.controlPortUnreachable("socket closed") }
        try data.withUnsafeBytes { raw in
            var sent = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < data.count {
                let wrote = Darwin.send(descriptor, base + sent, data.count - sent, 0)
                if wrote <= 0 {
                    if errno == EINTR { continue }
                    throw TorError.controlPortUnreachable("send() errno \(errno)")
                }
                sent += wrote
            }
        }
    }

    public func read(maximumBytes: Int) throws -> Data {
        gate.lock()
        let current = descriptor
        gate.unlock()
        guard current >= 0 else { return Data() }
        var payload = [UInt8](repeating: 0, count: maximumBytes)
        let got = recv(current, &payload, maximumBytes, 0)
        if got == 0 {
            // Clean peer shutdown. The event loop treats this as "the daemon is gone" and the gate
            // closes; it is never mapped onto a retry-with-backoff path, because a control port that
            // hangs up is a different failure from one that is slow.
            return Data()
        }
        if got < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                throw TorError.timeout("control port reply")
            }
            if errno == EINTR { return Data() }
            throw TorError.controlPortUnreachable("recv() errno \(errno)")
        }
        return Data(payload[0..<got])
    }

    public func close() {
        gate.lock()
        defer { gate.unlock() }
        guard descriptor >= 0 else { return }
        // SHUT_RDWR first: a reader parked in `recv` only returns promptly on a shutdown, and
        // without it `close()` on another thread leaves that reader holding the old descriptor
        // number, which a later unrelated socket could be assigned.
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
    }

    static func isLoopback(_ address: IPAddressLiteral) -> Bool {
        switch address {
        case let .v4(text): return text.hasPrefix("127.")
        case let .v6(text): return text.lowercased() == "::1"
        }
    }
}

/// In-memory transport for tests and for driving the controller from a recorded session.
///
/// Each reply is released only after a command has been written, which is the causality the real
/// socket has: without it a test's reader thread drains the whole script before the first waiter is
/// registered, and the replies are dropped as unsolicited.
public final class ScriptedTransport: ControlTransport, @unchecked Sendable {
    private var replies: [Data]
    private var index = 0
    private let commandWritten = DispatchSemaphore(value: 0)
    public private(set) var written = Data()
    public private(set) var closed = false

    public init(replies: [Data]) {
        self.replies = replies
    }

    public func write(_ data: Data) throws {
        written.append(data)
        commandWritten.signal()
    }

    public func read(maximumBytes: Int) throws -> Data {
        guard index < replies.count else { return Data() }
        commandWritten.wait()
        defer { index += 1 }
        return replies[index]
    }

    public func close() {
        closed = true
    }
}
