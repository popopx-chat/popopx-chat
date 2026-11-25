//
//  TorExitNode.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// The exit relay a general-purpose circuit is currently using.
///
/// Surfacing this is a privacy control, not a statistic: a user who has opted into Tor is entitled to
/// see *which* relay their traffic leaves from, and "Connected" without an address is a claim the
/// UI has no business making.
public struct TorExitNode: Sendable, Equatable {
    /// The relay fingerprint, 40 hex characters, no padding.
    public let fingerprint: String
    /// The nickname from the network status, when the descriptor was available locally.
    public let nickname: String?
    /// `true` when the chain has no exit hop — the circuit terminates at the relay itself, which is
    /// what a `.onion` destination produces. Reported rather than hidden, because "no exit" and "exit
    /// unknown" mean different things to a user checking whether they are anonymous.
    public let terminatesInsideNetwork: Bool

    /// Parses one `GETINFO circuit-status` answer.
    ///
    /// Line shape, from `GETINFO circreport-format`:
    ///
    ///     id purpose state path time_created reason
    ///     5 GENERAL BUILT 3:$fp1~n1,7:$fp2~n2,9:$fp3~n3 2026-11-23T09:00:00
    ///
    /// Only a `BUILT` `GENERAL` circuit qualifies. `EXTENDED` means the chain is half-built, which is
    /// exactly when showing an exit would be a lie about where traffic is going.
    public static func parse(circuitStatus text: String) -> TorExitNode? {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, fields[1] == "GENERAL", fields[2] == "BUILT" else { continue }
            let hops = fields[3].split(separator: ",")
            guard let last = hops.last else { continue }
            guard let identity = last.split(separator: ":").dropFirst().first else { continue }
            let pieces = identity.split(separator: "~")
            guard let head = pieces.first else { continue }
            // Tor writes each hop as `$FINGERPRINT~Nickname`; the sigil is notation, not part of the
            // digest, and leaving it in fails the hex check and reports every exit as unknown.
            let fingerprint = head.hasPrefix("$") ? head.dropFirst() : head
            guard isFingerprint(String(fingerprint)) else { continue }
            return TorExitNode(
                fingerprint: String(fingerprint).uppercased(),
                nickname: pieces.count > 1 ? String(pieces[1]) : nil,
                // Tor appends `,$hash` for the *rendezvous* hop, and marks the exit with `$digest`.
                // A single-hop chain reaching an onion service has no exit at all.
                terminatesInsideNetwork: hops.count < 3
            )
        }
        return nil
    }

    private static func isFingerprint(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy(\.isHexDigit)
    }

    /// A displayable form that never invents a nickname.
    public var display: String {
        if let nickname, !nickname.isEmpty { return "\(nickname) (\(fingerprint.prefix(8)))" }
        if terminatesInsideNetwork { return "hidden service circuit (\(fingerprint.prefix(8)))" }
        return fingerprint
    }
}
