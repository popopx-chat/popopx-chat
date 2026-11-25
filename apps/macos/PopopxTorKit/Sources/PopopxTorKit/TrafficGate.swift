//
//  TrafficGate.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// A parsed `status/bootstrap-phase` answer or `BOOTSTRAP` event.
public struct BootstrapProgress: Sendable, Equatable {
    public let percent: Int
    /// e.g. `status/client/conn`.
    public let tag: String?
    /// The human-readable part Tor puts after the percentage.
    public let summary: String?
    /// The record's log level when it is not the ordinary `NOTICE` — i.e. when Tor reported a
    /// problem that did not stop bootstrap.
    public let warning: String?

    public var isComplete: Bool { percent >= 100 }

    /// Extracts the phase from either spelling the daemon uses:
    ///
    /// - `NOTICE BOOTSTRAP PROGRESS=45 TAG=loading_descriptors SUMMARY="Loading relay descriptors"`
    /// - `650 BOOTSTRAP 45 loading_descriptors`
    ///
    /// The first is `GETINFO status/bootstrap-phase`, the second is the `BOOTSTRAP` event. They
    /// differ in where the number sits and in whether a summary exists at all, so neither field is
    /// assumed to be present in both.
    public static func parse(_ text: String) -> BootstrapProgress? {
        let normalized = text.replacingOccurrences(of: "\r", with: "")
        if let percent = value(forKey: "PROGRESS", in: normalized).flatMap(Int.init(_:)) {
            let summary = quotedValue(forKey: "SUMMARY", in: normalized)
            let level = normalized.split(separator: " ").first.map(String.init(_:))
            return BootstrapProgress(
                percent: percent,
                tag: value(forKey: "TAG", in: normalized),
                summary: summary,
                warning: level == "WARN" ? level : nil
            )
        }
        let pieces = normalized.split(separator: " ").map(String.init(_:))
        guard let mark = pieces.firstIndex(of: "BOOTSTRAP"), mark + 1 < pieces.count,
              let percent = Int(pieces[mark + 1]) else { return nil }
        return BootstrapProgress(
            percent: percent,
            tag: mark + 2 < pieces.count ? pieces[mark + 2] : nil,
            summary: nil,
            warning: nil
        )
    }

    private static func value(forKey key: String, in text: String) -> String? {
        let prefix = key + "="
        for piece in text.split(separator: " ") {
            guard piece.hasPrefix(prefix) else { continue }
            let raw = piece.dropFirst(prefix.count)
            return raw.isEmpty ? nil : String(raw)
        }
        return nil
    }

    /// `SUMMARY` is the one quoted field in the bootstrap record, and its value contains spaces, so
    /// the space-separated scan above cannot read it.
    private static func quotedValue(forKey key: String, in text: String) -> String? {
        guard let range = text.range(of: key + "=\"") else { return nil }
        let tail = text[range.upperBound...]
        guard let closing = tail.firstIndex(of: "\"") else { return nil }
        let raw = tail[..<closing]
        return raw.isEmpty ? nil : String(raw)
    }
}

/// Where the daemon is, as the UI and the policy builder see it.
public enum TorPhase: Sendable, Equatable {
    case stopped
    /// The child has been launched and the control port has not answered yet.
    case launching
    /// Control port answered; `percent` is Tor's own figure, not an extrapolation.
    case bootstrapping(Int)
    /// `BOOTSTRAP 100%` seen.
    case ready
    /// Was ready, the circuit went away.
    case circuitLost
    case failed(reason: String)
}

/// Whether the app may carry traffic right now.
///
/// Named for the decision rather than for a switch position on purpose: "kill switch off" reads as
/// disabled in both directions, and getting that backwards in a privacy control is the worst
/// possible mistake.
public enum TrafficGate: Sendable, Equatable {
    case permitted
    case blocked(reason: BlockingReason)

    public enum BlockingReason: Sendable, Equatable {
        case daemonStopped
        case launching
        case bootstrapping(percent: Int)
        case circuitLost
        case failed(reason: String)
    }

    public var isBlocked: Bool {
        switch self {
        case .permitted: return false
        case .blocked: return true
        }
    }

    /// The single decision point, and it is total: every phase maps to exactly one outcome, so a
    /// new phase cannot be added without the compiler forcing a choice here.
    ///
    /// When the guard is on, only `.ready` permits traffic. That includes the window where Tor is
    /// listening on the SOCKS port but has not built a circuit: connections are refused rather than
    /// queued, which is the intended behaviour and the reason `smpProxyFallback` stays at `prohibit`
    /// during bootstrap rather than relaxing.
    public static func evaluate(phase: TorPhase, strict: Bool) -> TrafficGate {
        switch phase {
        case .ready:
            return .permitted
        case let .bootstrapping(percent):
            return strict ? .blocked(reason: .bootstrapping(percent: percent)) : .permitted
        case .launching:
            return strict ? .blocked(reason: .launching) : .permitted
        case .stopped:
            return strict ? .blocked(reason: .daemonStopped) : .permitted
        case .circuitLost:
            return strict ? .blocked(reason: .circuitLost) : .permitted
        case let .failed(reason):
            return strict ? .blocked(reason: .failed(reason: reason)) : .permitted
        }
    }
}

public extension TorPhase {
    /// Folds one control-port message into the phase.
    ///
    /// A `BOOTSTRAP` event with a lower percentage than we have already seen is ignored rather than
    /// replayed: Tor emits `650 BOOTSTRAP 0%` again after `SIGNAL NEWNYM` in some versions, and
    /// letting that drag a `ready` daemon back to `bootstrapping` would flap the banner and — with
    /// the guard on — cut a working connection for no reason.
    func byApplying(progress: BootstrapProgress) -> TorPhase {
        switch self {
        case .ready where !progress.isComplete:
            // Bootstrap is already done. A lower percentage now is Tor re-announcing after
            // `SIGNAL NEWNYM`, not a regression: circuit loss has its own signal (`CIRC`), and
            // letting this reopen the kill switch would cut a daemon that is still carrying traffic.
            return self
        case let .bootstrapping(seen) where progress.percent <= seen:
            return self
        default:
            return progress.isComplete ? .ready : .bootstrapping(progress.percent)
        }
    }
}
