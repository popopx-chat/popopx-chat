//
//  TorControlPanel.swift
//  PopopxTorUI
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import PopopxTorKit
import SwiftUI

/// The control surface: the guard switch, the circuit, the daemon's own progress, and the bridges.
///
/// Every number shown here is one the daemon reported. Nothing is extrapolated, nothing is
/// remembered from a previous session, and the two places where this build genuinely cannot protect
/// the user are stated as text rather than left to a release note.
public struct TorControlPanel: View {
    @ObservedObject private var manager: TorManager
    @State private var bridgeDraft = ""
    @State private var bridgeRejected = false

    public init(manager: TorManager) {
        self.manager = manager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let percent = manager.phase.bootstrapPercent {
                ProgressView(value: Double(percent), total: 100)
                    .progressViewStyle(.linear)
            }
            if case let .blocked(reason) = manager.gate {
                TorBlockingBanner(reason: reason, strict: manager.strictModeEnabled)
            }
            strictSection
            circuitSection
            bridgesSection
            boundarySection
            actionButton
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(manager.phase.title)
                .font(.headline)
            if let version = manager.daemonVersion {
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var strictSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(localized("Strict Tor mode"), isOn: Binding(
                get: { manager.strictModeEnabled },
                set: { manager.setStrictMode($0) }
            ))
            Text(localized("Until Tor reports a completed circuit, no connection is allowed to leave this machine unproxied."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var circuitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(localized("Exit relay"))
                    .font(.callout)
                Spacer()
                if let exit = manager.exitNode {
                    Text(exit.display)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text(localized("Not known yet"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await manager.rebuildCircuit() }
            } label: {
                Label(localized("Build a new circuit"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(manager.exitNode == nil && manager.phase != .ready)
            .help(localized("Asks Tor for fresh guard, middle and exit hops. Tor picks the relay; a new circuit is not a guarantee of a new exit."))
        }
    }

    private var bridgesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("Bridges"))
                .font(.callout.weight(.semibold))
            if manager.configuredBridges.isEmpty {
                Text(localized("None. A direct connection to the Tor network is attempted."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.configuredBridges.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        Text(manager.configuredBridges[index].address)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Button {
                            removeBridge(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help(localized("Remove this bridge"))
                    }
                }
            }
            HStack(spacing: 6) {
                TextField(localized("obfs4 198.51.100.7:9001 …"), text: Binding(
                    get: { bridgeDraft },
                    // The rejection notice is about the text that was submitted, so new keystrokes
                    // retire it. A binding setter does this without `onChange`, whose one-parameter
                    // form is deprecated on the SDK this package builds against.
                    set: {
                        bridgeDraft = $0
                        bridgeRejected = false
                    }
                ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Button(localized("Add")) {
                    addBridge()
                }
                .disabled(bridgeDraft.trimmed.isEmpty)
            }
            if bridgeRejected {
                Text(localized("That line was not accepted: it must start with a transport name, and an obfs4 line needs its fingerprint and cert."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(localized("A bridge needs its transport plugin (obfs4proxy, snowflake-proxy) installed with the daemon; this build embeds only tor, so a bridge line is refused and the existing connection is left running."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var boundarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized("What this does not cover"))
                .font(.callout.weight(.semibold))
            Text(localized("Voice and video calls use WebRTC, including its STUN and TURN signalling, and are not routed through the Tor proxy."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(localized("Onion addresses are used only when a contact or relay supplies one. This build does not bias connections toward any preferred .onion directory."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.10)))
    }

    private var actionButton: some View {
        Button {
            Task {
                if manager.phase == .stopped {
                    await manager.start()
                } else {
                    await manager.stop()
                }
            }
        } label: {
            Text(manager.phase == .stopped ? localized("Start Tor") : localized("Stop Tor"))
                .frame(maxWidth: .infinity)
        }
    }

    private func addBridge() {
        guard let line = BridgeLine(bridgeDraft) else {
            bridgeRejected = true
            return
        }
        bridgeRejected = false
        bridgeDraft = ""
        var next = manager.configuredBridges
        next.append(line)
        Task { await manager.apply(bridges: next) }
    }

    private func removeBridge(at index: Int) {
        var next = manager.configuredBridges
        guard next.indices.contains(index) else { return }
        next.remove(at: index)
        Task { await manager.apply(bridges: next) }
    }
}

fileprivate extension String {
    /// Trimming is done here rather than at the call sites so the Add button and the parser agree on
    /// what an empty line is.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
