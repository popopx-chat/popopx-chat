//
//  TorStatusCapsule.swift
//  PopopxTorUI
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import PopopxTorKit
import SwiftUI

/// The one-line state of the embedded daemon, for a window's top bar or the settings header.
///
/// Two facts are shown and nothing else: whether the daemon finished bootstrap, and whether traffic
/// is currently permitted. The percentage is Tor's own figure from `status/bootstrap-phase`, so a
/// stalled daemon reads as stalled instead of as a bar that is quietly animating toward a promise
/// nobody measured.
public struct TorStatusCapsule: View {
    @ObservedObject private var manager: TorManager
    @State private var panelPresented = false

    public init(manager: TorManager) {
        self.manager = manager
    }

    public var body: some View {
        Button {
            panelPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: manager.phase.symbolName)
                    .foregroundStyle(manager.phase.tint)
                Text(manager.phase.title)
                    .font(.callout)
                    .lineLimit(1)
                if let percent = manager.phase.bootstrapPercent, percent < 100 {
                    Text("\(percent)%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(manager.gate.isBlocked ? Color.red.opacity(0.12) : Color.gray.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help(manager.gate.helpText)
        .popover(isPresented: $panelPresented, arrowEdge: .bottom) {
            TorControlPanel(manager: manager)
        }
    }
}

/// The kill-switch banner.
///
/// Deliberately a separate view rather than a `Text` the panel composes inline: the same wording has
/// to appear on the window chrome and in settings, and a banner that differs between the two places
/// is a banner the user learns to ignore.
struct TorBlockingBanner: View {
    let reason: TrafficGate.BlockingReason
    let strict: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(strict ? localized("Tor connections blocked") : localized("Tor is not connected"))
                    .font(.callout.weight(.semibold))
                Text(reason.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.10)))
    }
}

extension TorPhase {
    var title: String {
        switch self {
        case .stopped: return localized("Tor off")
        case .launching: return localized("Starting Tor")
        case .bootstrapping: return localized("Connecting to Tor")
        case .ready: return localized("Tor connected")
        case .circuitLost: return localized("Tor circuit lost")
        case .failed: return localized("Tor failed")
        }
    }

    var symbolName: String {
        switch self {
        case .stopped: return "circle"
        case .launching, .bootstrapping: return "circle.dashed"
        case .ready: return "checkmark.circle.fill"
        case .circuitLost: return "exclamationmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .circuitLost, .failed: return .red
        case .stopped: return .gray
        case .launching, .bootstrapping: return .orange
        }
    }

    var bootstrapPercent: Int? {
        if case let .bootstrapping(percent) = self { return percent }
        return nil
    }
}

extension TrafficGate {
    var helpText: String {
        switch self {
        case .permitted: return localized("Traffic is permitted")
        case let .blocked(reason): return reason.detail
        }
    }
}

extension TrafficGate.BlockingReason {
    var detail: String {
        switch self {
        case .daemonStopped:
            return localized("The Tor daemon is not running, and direct connections are blocked by Strict Tor mode.")
        case .launching:
            return localized("Waiting for the Tor control port to answer. Direct connections are blocked.")
        case let .bootstrapping(percent):
            return String(
                format: localized("Tor has reached %d%% of bootstrap. Direct connections are blocked until it completes."),
                percent
            )
        case .circuitLost:
            return localized("The Tor circuit went away. Direct connections are blocked until a new one is built.")
        case let .failed(reason):
            return String(format: localized("Tor failed: %@. Direct connections are blocked."), reason)
        }
    }
}

/// English literals are the keys, matching the rest of the app's localisation.
///
/// Resolved against the host bundle, not `Bundle.module`: this package ships no catalogs, and the
/// 18 `.lproj` directories live with the application target that links it.
@inline(__always)
func localized(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}
