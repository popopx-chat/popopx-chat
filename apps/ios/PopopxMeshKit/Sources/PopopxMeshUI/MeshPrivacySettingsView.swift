//
//  MeshPrivacySettingsView.swift
//  PopopxMeshUI
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The mesh's own settings page: global kill switch, connection policy (manual confirmation vs automatic silent) and clearing identity bindings. It is
//  a `List` of `settingsRow`-shaped rows with a `Toggle` bound through `@AppStorage`, because that is
//  how `Shared/Views/UserSettings/PrivacySettings.swift` builds every row: a symbol, a control, a
//  footer that explains the consequence. The mesh should read like part of this app.
//
//  Two rules decide the whole file. The switch writes the key the fuse reads
//  (`PopopxMeshKillSwitch.enabledDefaultsKey`, which *is* `IdentityMappingStore.meshEnabledDefaultsKey`)
//  and nothing else, so `@AppStorage` and `PopopxMeshKillSwitch.isEnabled` cannot disagree; and the
//  policy picker writes where module 3 reads (`IdentityMappingStore.pairingPolicy`), before it touches
//  the FFI, so this page can never become a second source of truth.
//

import Combine
import Foundation
import PopopxMeshKit
import SwiftUI

// MARK: - Contracts

/// What this page needs from module 1. `IdentityMappingStore` has all four already with these exact
/// names, so the conformance below only adapts the two computed properties to `async` method calls —
/// no core file is edited, and the page binds to the real store instead of to a copy of its state.
public protocol PopopxMeshBindingObserving: Sendable {
    func pairingPolicy() async -> MeshPairingPolicy

    func setPairingPolicy(_ policy: MeshPairingPolicy) async

    func allMappings() async -> [PopopxMeshContactMapping]

    @discardableResult
    func unbind(meshPublicKeyHex: String) async throws(IdentityMappingError) -> Bool
}

public extension PopopxMeshBindingObserving {
    /// A host that only wants the switch and the picker need not answer the binding questions; the
    /// page then reports "no bindings" rather than pretending to have cleared some.
    func allMappings() async -> [PopopxMeshContactMapping] { [] }

    @discardableResult
    func unbind(meshPublicKeyHex: String) async throws(IdentityMappingError) -> Bool { false }
}

extension IdentityMappingStore: PopopxMeshBindingObserving {
    public func pairingPolicy() async -> MeshPairingPolicy {
        pairingPolicy
    }

    public func setPairingPolicy(_ policy: MeshPairingPolicy) async {
        updatePairingPolicy(policy)
    }
}

/// Module 3's own way of dropping a peer: `forget` clears the manager's in-memory state *and* the
/// durable binding, so a page that unbound the key behind its back would resurrect a peer the user
/// removed. `ManualPairingManager` already has this method, so the conformance below is empty. It is
/// a separate protocol from `PopopxMeshPairingControlling` because the banner must not be able to
/// forget anyone.
public protocol PopopxMeshPairingForgetting: Sendable {
    func forget(_ peerMeshPublicKeyHex: String) async
}

extension ManualPairingManager: PopopxMeshPairingForgetting {}

/// One row of the binding table, as the page shows it.
public struct PopopxMeshBindingSummary: Identifiable, Hashable, Sendable {
    public let meshPublicKeyHex: String
    public let contactId: Int64?
    public let tempConnId: Int64?
    public let nickname: String?
    public let updatedAt: Date

    public var id: String { meshPublicKeyHex }

    /// What the user needs to know at a glance: whether this neighbour is a contact yet, or still a
    /// pending connection module 6 has not upgraded.
    public var status: String {
        if let contactId { return "contact :\(contactId)" }
        if let tempConnId { return "pending :\(tempConnId)" }
        return "unlinked"
    }

    public init(_ mapping: PopopxMeshContactMapping) {
        self.meshPublicKeyHex = mapping.meshPublicKeyHex
        self.contactId = mapping.contactId
        self.tempConnId = mapping.tempConnId
        self.nickname = mapping.nickname
        self.updatedAt = mapping.updatedAt
    }

    public init(
        meshPublicKeyHex: String,
        contactId: Int64? = nil,
        tempConnId: Int64? = nil,
        nickname: String? = nil,
        updatedAt: Date = .now
    ) {
        self.meshPublicKeyHex = meshPublicKeyHex
        self.contactId = contactId
        self.tempConnId = tempConnId
        self.nickname = nickname
        self.updatedAt = updatedAt
    }
}

// MARK: - View model

/// Reads and writes the three settings. Everything with a rule in it lives here, so the rules are
/// testable without a window.
@MainActor
public final class PopopxMeshSettingsModel: ObservableObject {
    @Published public private(set) var bindings: [PopopxMeshBindingSummary] = []

    @Published public private(set) var isClearing = false

    /// What the last clear-identity-bindings left behind, so the page can name the number that survived instead
    /// of claiming a clean sweep it did not get. nil until a clear has run.
    @Published public private(set) var bindingsLeftAfterClear: Int?

    /// The policy as the store has it. Published because the picker needs a value to bind to; it is
    /// only ever changed by writing it through the store first.
    @Published public var pairingPolicy: MeshPairingPolicy

    /// The fuse's own report, re-read on every refresh: this page is where a user comes to check
    /// that switching the mesh off really did stop the Bluetooth work.
    @Published public private(set) var activity: PopopxMeshActivitySnapshot

    private let store: any PopopxMeshBindingObserving
    private let pairing: (any PopopxMeshPairingForgetting)?
    private let killSwitch: PopopxMeshKillSwitch?

    /// - Parameters:
    ///   - pairing: when the host built a module 3 manager, clearing goes through its `forget`, which also
    ///     drops the manager's own peer state. Without it the page still clears the mapping, because
    ///     that is the half that survives a restart.
    ///   - killSwitch: the fuse the master switch writes through. nil is only useful in tests that never
    ///     touch the switch.
    public init(
        store: any PopopxMeshBindingObserving,
        pairing: (any PopopxMeshPairingForgetting)? = nil,
        killSwitch: PopopxMeshKillSwitch? = nil
    ) {
        self.store = store
        self.pairing = pairing
        self.killSwitch = killSwitch
        self.pairingPolicy = .manualConfirm
        self.activity = PopopxMeshActivitySnapshot(
            phase: .off,
            persistedSwitch: false,
            runningRadioWork: [],
            runningInterfaceWork: []
        )
    }

    /// The switch as the fuse holds it. The view binds `@AppStorage` to the same key and pushes
    /// changes through `setFuseEnabled`, so there is one persisted value and one in-memory one.
    public var fuseEnabled: Bool {
        killSwitch?.isEnabled ?? persistedFuseEnabled
    }

    /// Same key, read straight from disk — the value a model without a fuse can still answer.
    public var persistedFuseEnabled: Bool {
        killSwitch?.persistedIsEnabled
            ?? UserDefaults.standard.bool(forKey: PopopxMeshKillSwitch.enabledDefaultsKey)
    }

    /// Pulls what the store owns. Called on appear and after every write, so the page cannot drift.
    public func refresh() async {
        pairingPolicy = await store.pairingPolicy()
        bindings = await store.allMappings().map(PopopxMeshBindingSummary.init)
        if let killSwitch {
            activity = await killSwitch.verifiedActivitySnapshot()
        } else {
            activity = PopopxMeshActivitySnapshot(
                phase: persistedFuseEnabled ? .on : .off,
                persistedSwitch: persistedFuseEnabled,
                runningRadioWork: [],
                runningInterfaceWork: []
            )
        }
    }

    /// Writes the policy where module 3 reads it. This is the only path that changes automatic silent.
    public func updatePairingPolicy(_ policy: MeshPairingPolicy) async {
        await store.setPairingPolicy(policy)
        pairingPolicy = policy
        PopopxMeshLog.pairing.info("⚙️ mesh settings: policy = \(policy.rawValue, privacy: .public)")
        await refresh()
    }

    /// Global kill switch, through the fuse — the only component allowed to start or stop a radio.
    public func setFuseEnabled(_ enabled: Bool) async {
        await killSwitch?.setEnabled(enabled)
        await refresh()
    }

    /// Clear identity bindings. Every row goes down the same path the user would use in the chat: the manager's
    /// `forget` when there is a manager (it unbinds too), otherwise the store's `unbind`. Deliberately
    /// *not* `emergencyWipeAllMappings()` — that is the panic route, and it also takes the fuse and
    /// the offline cache with it, which this page has no business deciding.
    ///
    /// The fuse is switched off first: unbinding while the mesh is live would end a session
    /// mid-conversation and the engine would simply re-pair the peer on the next announce.
    ///
    /// The count returned is measured from the store's own before/after state, not from what the
    /// calls claimed, so a refusal cannot be reported as a removal.
    @discardableResult
    public func clearAllBindings() async -> Int {
        let before = Set(bindings.map(\.meshPublicKeyHex))
        isClearing = true
        await killSwitch?.setEnabled(false)
        for meshPublicKeyHex in before.sorted() {
            if let pairing {
                await pairing.forget(meshPublicKeyHex)
            } else {
                do {
                    _ = try await store.unbind(meshPublicKeyHex: meshPublicKeyHex)
                } catch {
                    PopopxMeshLog.store.error(
                        "❌ unbind refused for \(meshPublicKeyHex.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
        isClearing = false
        await refresh()
        let after = Set(bindings.map(\.meshPublicKeyHex))
        let removed = before.subtracting(after).count
        bindingsLeftAfterClear = after.count
        PopopxMeshLog.pairing.notice(
            "🧹 settings: cleared \(removed, privacy: .public) binding(s), \(after.count, privacy: .public) left"
        )
        return removed
    }

    /// One row's Forget, for a user who wants to drop a single neighbour. Same path, same measurement.
    @discardableResult
    public func forgetBinding(_ meshPublicKeyHex: String) async -> Bool {
        let wasListed = bindings.contains(where: { $0.meshPublicKeyHex == meshPublicKeyHex })
        await killSwitch?.setEnabled(false)
        if let pairing {
            await pairing.forget(meshPublicKeyHex)
        } else {
            do {
                _ = try await store.unbind(meshPublicKeyHex: meshPublicKeyHex)
            } catch {
                PopopxMeshLog.store.error(
                    "❌ unbind refused: \(String(describing: error), privacy: .public)"
                )
            }
        }
        await refresh()
        let stillListed = bindings.contains(where: { $0.meshPublicKeyHex == meshPublicKeyHex })
        return wasListed && !stillListed
    }
}

// MARK: - View

@MainActor
public struct MeshPrivacySettingsView: View {
    /// The fuse's key, spelled once: `chat.popopx.mesh.enabled`. Off by default, which is what
    /// `UserDefaults.bool` on an absent key already answers.
    @AppStorage(PopopxMeshKillSwitch.enabledDefaultsKey) private var fuseEnabled = false

    @ObservedObject private var model: PopopxMeshSettingsModel

    public init(model: PopopxMeshSettingsModel) {
        self.model = model
    }

    /// The one-line mount for the app's settings stack: the real store, the real fuse, and — when the
    /// host has a module 3 manager — its forget path.
    public init(
        store: IdentityMappingStore = .shared,
        pairing: (any PopopxMeshPairingForgetting)? = nil,
        killSwitch: PopopxMeshKillSwitch = .shared
    ) {
        self.init(
            model: PopopxMeshSettingsModel(
                store: store,
                pairing: pairing,
                killSwitch: killSwitch
            )
        )
    }

    public var body: some View {
        List {
            Section {
                settingsRow("antenna.radiowaves.left.and.right") {
                    Toggle(
                        "Enable offline Bluetooth mesh network",
                        isOn: fuseBinding
                    )
                }
            } header: {
                Text("Offline mesh")
            } footer: {
                Text(
                    "Off stops Bluetooth completely: no scanning, no advertising, no timers. Nothing mesh-related starts at launch while this is off, and the app behaves like the stock build."
                )
                + Text("\nCurrently: ")
                + Text(verbatim: MeshPrivacySettingsView.words(for: model.activity))
            }

            Section {
                settingsRow("person.badge.plus") {
                    Picker(
                        "Pairing",
                        selection: Binding(
                            get: { model.pairingPolicy },
                            set: { policy in
                                Task { await model.updatePairingPolicy(policy) }
                            }
                        )
                    ) {
                        ForEach(MeshPrivacySettingsView.policies, id: \.self) { policy in
                            Text(MeshPrivacySettingsView.words(for: policy)).tag(policy)
                        }
                    }
                }
            } header: {
                Text("Handshake")
            } footer: {
                Text(
                    "Manual confirmation shows a banner and sends nothing until you approve it. Silent pairing finishes the Bluetooth handshake on its own."
                )
            }

            Section {
                if model.bindings.isEmpty {
                    Text("No identity bindings on this device.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.bindings) { binding in
                        bindingRow(binding)
                        privateChatRow(binding)
                    }
                    settingsRow("trash") {
                        Button {
                            Task { await model.clearAllBindings() }
                        } label: {
                            if model.isClearing {
                                ProgressView()
                            } else {
                                Text("Clear identity bindings")
                            }
                        }
                        .tint(.red)
                        .disabled(model.isClearing)
                    }
                }
            } header: {
                Text("Mesh identity map")
            } footer: {
                bindingFooter
            }
        }
        .navigationTitle("Offline Mesh")
        .task { await model.refresh() }
    }

    /// The master switch, as a binding that writes the key and then tells the fuse.
    ///
    /// A `set` side effect rather than `.onChange`: `onChange(of:perform:)` is deprecated at this
    /// package's macOS 14 floor (and the two-parameter form needs iOS 17), and a Toggle's action is
    /// already exactly one write — observing it afterwards would be a second path to the same value.
    /// `@AppStorage` still owns persistence, so the key is on disk before the fuse is asked to start
    /// anything, which is the ordering a crash between the two steps needs.
    private var fuseBinding: Binding<Bool> {
        Binding(
            get: { fuseEnabled },
            set: { newValue in
                fuseEnabled = newValue
                Task { await model.setFuseEnabled(newValue) }
            }
        )
    }

    private func bindingRow(_ binding: PopopxMeshBindingSummary) -> some View {
        settingsRow("link") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: binding.nickname ?? String(binding.meshPublicKeyHex.prefix(16)))
                    Text(verbatim: binding.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Forget") {
                    Task { await model.forgetBinding(binding.meshPublicKeyHex) }
                }
                .font(.caption)
            }
        }
    }

    /// Module 7's private-chat view, one entry per bound peer: the binding is the only proof this device has that
    /// a mesh key belongs to someone, so the row that lists it is the row that opens its
    /// conversation. `NavigationLink(destination:label:)` rather than the closure form because that
    /// form is iOS 16 and this package still builds for iOS 15.
    ///
    /// The entry exists only while the master switch is on. The private view's one-line mount hands the engine
    /// singleton to its model, and a settings page that built one while the switch was off would be
    /// creating a Bluetooth central from the very screen that just promised not to (red line 28): off is
    /// not a greyed-out door, it is no door.
    @ViewBuilder private func privateChatRow(_ binding: PopopxMeshBindingSummary) -> some View {
        if fuseEnabled {
            settingsRow("message") {
                NavigationLink(
                    destination: PopopxMeshPrivateChatView(
                        peerMeshPublicKeyHex: binding.meshPublicKeyHex
                    )
                ) {
                    HStack {
                        Text("Offline private chat")
                        Spacer()
                        Text(verbatim: PopopxMeshPrivateChatModel.peerLabel(binding.meshPublicKeyHex))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var bindingFooter: some View {
        if let left = model.bindingsLeftAfterClear, left > 0 {
            Text(verbatim: "\(left) binding(s) could not be removed. Turn Bluetooth off and try again.")
                .foregroundStyle(.orange)
        } else {
            Text(
                "A binding maps a Bluetooth key to a POPOPX contact. It lives in the Keychain and is never backed up. Clearing bindings does not delete any contact and does not touch your chat history."
            )
        }
    }

    /// Manual confirmation vs automatic silent, in the store's own enum, so this page cannot offer a policy that does
    /// not exist.
    static let policies: [MeshPairingPolicy] = [.manualConfirm, .autoSilent]

    static func words(for policy: MeshPairingPolicy) -> String {
        switch policy {
        case .manualConfirm: return "Manual confirmation"
        case .autoSilent: return "Silent pairing"
        }
    }

    /// The fuse's phase in the user's terms. A page that only says "off" while a scan is still
    /// winding down is the settings screen that gets blamed for a battery drain.
    static func words(for snapshot: PopopxMeshActivitySnapshot) -> String {
        if snapshot.isFullyIdle { return "off, Bluetooth idle" }
        switch snapshot.phase {
        case .off: return "off, \(snapshot.runningRadioWork.count) Bluetooth task(s) finishing"
        case .starting: return "starting"
        case .on: return "on, \(snapshot.runningRadioWork.count) Bluetooth task(s) running"
        case .stopping: return "stopping"
        }
    }
}

/// The same row shape `Shared/Views/UserSettings/SettingsView.swift` uses: an SF Symbol behind the
/// control, so a mesh row and a privacy row look alike. Named the same on purpose — the app's copy is
/// fileprivate to its target, and a package cannot reach it.
@MainActor
private func settingsRow<Content: View>(
    _ symbol: String,
    @ViewBuilder content: () -> Content
) -> some View {
    ZStack(alignment: .leading) {
        Image(systemName: symbol)
            .frame(maxWidth: 24, maxHeight: 24, alignment: .center)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.secondary)
        content()
            .padding(.leading, 36)
    }
}
