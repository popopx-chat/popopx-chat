//
//  IPAddressLiteral.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Host validation for the proxy value handed to the chat core.
///
/// The iOS side already refuses anything that is not an IP literal — `NetworkProxy.valid` in
/// `apps/ios/POPOPXChat/APITypes.swift:457` tests the host against `NWEndpoint.Host` and accepts
/// only `.ipv4` and `.ipv6`. The failure is silent: an invalid proxy is dropped by `toProxyString()`
/// returning nil, the setting is saved to the app group anyway, and the app then connects directly.
/// For a Tor feature that is a fail-open, so the same rule is enforced here before a value is ever
/// offered to the caller, and with a reason attached instead of a nil.
public enum IPAddressLiteral: Sendable, Equatable {
    case v4(String)
    case v6(String)

    /// Parses a numeric IPv4 or IPv6 literal. Hostnames — including `localhost` — are rejected.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.contains(":") {
            guard Self.isValidIPv6(trimmed) else { return nil }
            self = .v6(trimmed)
        } else {
            guard Self.isValidIPv4(trimmed) else { return nil }
            self = .v4(trimmed)
        }
    }

    /// The literal as it must appear in a proxy string: bracketed for v6, bare for v4.
    ///
    /// `Transport/Client.hs:256` in the dependency parses the host out of the proxy string with an
    /// `AT.char ':'` split, so an unbracketed v6 literal would be cut at its first colon.
    public var encodedHost: String {
        switch self {
        case let .v4(address): return address
        case let .v6(address): return "[\(address)]"
        }
    }

    private static func isValidIPv4(_ text: String) -> Bool {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { piece in
            guard (1...3).contains(piece.count), piece.allSatisfy(\.isNumber) else { return false }
            // "01" parses as 1 but is not what the operator meant, and the dependency's parser would
            // accept it; rejecting keeps the stored string and the bound socket describing one host.
            if piece.count > 1, piece.first == "0" { return false }
            guard let value = UInt8(piece) else { return false }
            return value <= 255
        }
    }

    private static func isValidIPv6(_ text: String) -> Bool {
        var value = text
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        guard value.contains(":") else { return false }
        // At most one "::" run, and it may sit at either end ("::1" and "fe80::" are both real).
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        var groups: [Substring] = []
        for half in halves {
            // An empty half is the compression itself; an empty piece at the *edge* of a non-empty
            // half is a stray colon ("1::2:" splits into ["1", "2:"]… and then into a trailing "").
            if half.isEmpty { continue }
            let pieces = half.split(separator: ":", omittingEmptySubsequences: false)
            guard let first = pieces.first, !first.isEmpty, let last = pieces.last, !last.isEmpty else {
                return false
            }
            groups.append(contentsOf: pieces)
        }
        var count = 0
        for (index, group) in groups.enumerated() {
            // A trailing embedded IPv4 ( ::ffff:127.0.0.1 ) is a valid v6 spelling, occupies two
            // 16-bit groups, and would fail the hex check below.
            if index == groups.count - 1, group.contains(".") {
                guard isValidIPv4(String(group)) else { return false }
                count += 2
                continue
            }
            guard group.count <= 4, group.allSatisfy({ $0.isHexDigit }) else { return false }
            count += 1
        }
        // Without "::" the address must be written in full; with it, the run has to stand for at
        // least one group, so the spelled-out part may not already fill eight.
        return halves.count == 2 ? count <= 7 : count == 8
    }
}
