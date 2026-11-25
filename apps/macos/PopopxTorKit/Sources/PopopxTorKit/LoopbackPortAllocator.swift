//
//  LoopbackPortAllocator.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Darwin
import Foundation

/// Reserves pairs of high loopback ports for the embedded `tor` daemon's `SocksPort` and
/// `ControlPort`.
///
/// The reservation is real, not a scan: the allocator binds and listens on the port, then closes it
/// only once `tor` has been handed the number. A pure "is anything connected here" probe would
/// report a free port that another process could steal in the gap between the probe and `tor`
/// binding it, which is exactly the race that makes a "detected free port" unreliable as a security
/// boundary.
public struct LoopbackPortAllocator: Sendable {
    public enum AllocationError: Error, Equatable, CustomStringConvertible {
        case socketUnavailable(Int32)
        case bindUnavailable(Int32)
        case listenUnavailable(Int32)
        case exhausted(attempts: Int)

        public var description: String {
            switch self {
            case let .socketUnavailable(errno): return "socket() failed with errno \(errno)"
            case let .bindUnavailable(errno): return "bind() failed with errno \(errno)"
            case let .listenUnavailable(errno): return "listen() failed with errno \(errno)"
            case let .exhausted(attempts): return "no free loopback port after \(attempts) attempts"
            }
        }
    }

    /// Tor's own defaults, so that a developer who already runs a Tor browser or a brew service gets
    /// pushed off both of them rather than colliding.
    static let reservedPorts: Set<UInt16> = [9050, 9051, 9150, 9151]

    public let lowerBound: UInt16
    public let upperBound: UInt16
    private let attempts: Int

    public init(lowerBound: UInt16 = 49_152, upperBound: UInt16 = 65_534, attempts: Int = 64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.attempts = attempts
    }

    /// Binds two distinct ports on `127.0.0.1`.
    ///
    /// The two are allocated in one call because handing `tor` a `SocksPort` and a `ControlPort`
    /// that are individually free but collide with each other is a configuration error we can rule
    /// out here for the price of a set.
    public func allocate() throws -> (socks: ReservedPort, control: ReservedPort) {
        let socks = try reserve(excluding: [])
        let control = try reserve(excluding: [socks.port])
        return (socks, control)
    }

    func reserve(excluding excluded: Set<UInt16>) throws -> ReservedPort {
        for _ in 0..<attempts {
            let candidate = UInt16.random(in: lowerBound...upperBound)
            guard !excluded.contains(candidate), !Self.reservedPorts.contains(candidate) else { continue }
            // `port` 0 would let the kernel choose, but then the chosen number is not one we
            // filtered; binding the candidate keeps the exclusion list meaningful.
            if let descriptor = bindLoopback(candidate) {
                return ReservedPort(descriptor: descriptor, port: candidate)
            }
        }
        throw AllocationError.exhausted(attempts: attempts)
    }

    /// Returns a listening descriptor, or `nil` when the candidate port is busy.
    private func bindLoopback(_ port: UInt16) -> Int32? {
        // SOCK_STREAM on AF_INET is the same family and type `tor` will use, so a bind that succeeds
        // here is a bind that will succeed for the child.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        // 127.0.0.1 explicitly. `INADDR_ANY` would answer on every interface, which would expose the
        // SOCKS port to the LAN and defeat the whole point of an embedded, loopback-only proxy.
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = port.bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound < 0 {
            close(fd)
            return nil
        }
        if listen(fd, 1) < 0 {
            close(fd)
            return nil
        }
        return fd
    }
}

/// A loopback port this process is holding open. Holding it is the guarantee; releasing it is the
/// handoff to the `tor` child.
public final class ReservedPort: @unchecked Sendable {
    /// Module-visible rather than `fileprivate` so a test can read `getsockname` off the held socket
    /// and prove the reservation really is a loopback listener rather than one on every interface.
    let descriptor: Int32
    public let port: UInt16
    private var held = true
    private let gate = NSLock()

    init(descriptor: Int32, port: UInt16) {
        self.descriptor = descriptor
        self.port = port
    }

    /// Closes the listening socket, making the port available to the `tor` child process.
    public func release() {
        gate.lock()
        defer { gate.unlock() }
        guard held else { return }
        held = false
        close(descriptor)
    }

    deinit {
        release()
    }
}
