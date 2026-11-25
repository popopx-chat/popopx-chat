//
//  BridgeLine.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// One `Bridge …` line from `torrc`.
///
/// Validation is deliberately strict and rejects rather than trims, because a malformed bridge line
/// makes Tor exit at startup with a parse error on stderr, and a UI that had shown "3 bridges
/// configured" while the daemon never started is worse than a field that refuses the keystroke.
public struct BridgeLine: Sendable, Equatable {
    public enum Transport: String, Sendable, CaseIterable {
        case obfs4
        case snowflake
        case meek
        case ctubid
        case fte
        case scramble_suite = "scramlesuite"

        /// Transports whose lines carry a fingerprint and certificate arguments after the address.
        var expectsArguments: Bool {
            switch self {
            case .obfs4, .fte, .scramble_suite: return true
            case .snowflake, .meek, .ctubid: return false
            }
        }

        /// Whether the client side of the transport lives in a separate executable.
        ///
        /// All six spellings this parser accepts are pluggable transports: `tor` reaches them only
        /// through a `ClientTransportPlugin <transport> exec <path>` line naming a proxy binary of
        /// its own. A `Bridge` line without that plugin does not quietly degrade — the daemon cannot
        /// bootstrap at all — so ``TorManager`` refuses it and says why rather than showing a progress
        /// figure that never moves.
        var requiresClientPlugin: Bool { true }
    }

    /// The whole line exactly as it appeared, which is what `torrc` needs.
    public let line: String
    public let transport: Transport
    public let address: String
    public let fingerprint: String?
    public let arguments: [String: String]

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // A bridge line from a bridge authority always names its transport first. A bare
        // `host:port`, which is what an `obfs4://` URL decodes to, does not, and no `Bridge` line
        // can be built from it — so only the first spelling parses.
        guard let head = parts.first, let transport = Transport(rawValue: head) else { return nil }
        var fingerprint: String?
        var arguments: [String: String] = [:]
        var address = ""
        if transport.expectsArguments {
            guard parts.count >= 3 else { return nil }
            address = parts[1]
            fingerprint = parts[2]
            for pair in parts.dropFirst(3) {
                guard let equals = pair.firstIndex(of: "=") else { return nil }
                let key = String(pair[..<equals])
                let value = String(pair[pair.index(after: equals)...])
                guard !key.isEmpty, !value.isEmpty else { return nil }
                arguments[key] = value
            }
            guard !address.isEmpty, Self.isBase16(fingerprint ?? ""), !arguments.isEmpty else { return nil }
        } else {
            guard parts.count >= 2 else { return nil }
            address = parts[1]
        }
        guard address.contains(":") || address.contains(".") else { return nil }
        self.line = trimmed
        self.transport = transport
        self.address = address
        self.fingerprint = fingerprint
        self.arguments = arguments
    }

    /// `obfs4` needs `cert=`; a line without it is a copy from somewhere other than a bridge
    /// authority and will not connect.
    public var isValid: Bool {
        guard !line.isEmpty, !address.isEmpty else { return false }
        switch transport {
        case .obfs4: return arguments["cert"] != nil && fingerprint != nil
        default: return true
        }
    }

    private static func isBase16(_ text: String?) -> Bool {
        guard let text, text.count == 40 else { return false }
        return text.allSatisfy(\.isHexDigit)
    }
}

extension Array where Element == BridgeLine {
    /// The valid lines this build cannot use, because their transport is a separate binary.
    var requiringClientPlugin: [BridgeLine] {
        filter { $0.isValid && $0.transport.requiresClientPlugin }
    }
}
