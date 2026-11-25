//
//  PopopxMeshSettingsModelTests.swift
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The three rules of the settings page: the master switch writes the one key the fuse reads, the
//  connection policy picker writes where module 3 reads, and clearing identity bindings goes through
//  the store's own unbind path, then reports what actually disappeared — not what it hoped would.
//

import Foundation
import Testing
@testable import PopopxMeshUI
import PopopxMeshKit

@MainActor
@Suite("PopopxMeshSettingsModel")
struct PopopxMeshSettingsModelTests {
    private struct Harness {
        let model: PopopxMeshSettingsModel
        let store: PopopxMeshFakeBindingStore
        let pairing: PopopxMeshFakePairing
        let fuse: PopopxMeshKillSwitch
        let engine: PopopxMeshFakeComponent
        let interface: PopopxMeshFakeComponent
        let journal: PopopxMeshJournal
        let defaults: UserDefaults
    }

    private func makeHarness(
        label: String,
        mappings: [PopopxMeshContactMapping] = [],
        policy: MeshPairingPolicy = .manualConfirm
    ) throws -> Harness {
        let journal = PopopxMeshJournal()
        let store = PopopxMeshFakeBindingStore(policy: policy, mappings: mappings, journal: journal)
        let pairing = PopopxMeshFakePairing(journal: journal, bindingStore: store)
        let engine = PopopxMeshFakeComponent(name: "engine", journal: journal)
        let interface = PopopxMeshFakeComponent(name: "interface", journal: journal)
        let defaults = try popopxMeshTestDefaults(label)
        let fuse = PopopxMeshKillSwitch(
            engine: engine,
            healthMonitor: PopopxMeshFakeComponent(name: "health", journal: journal),
            pairing: nil,
            interface: interface,
            hub: PopopxMeshEventHub(),
            defaults: defaults,
            nicknameStore: PopopxMeshNicknameStore(directory: FileManager.default.temporaryDirectory)
        )
        let model = PopopxMeshSettingsModel(store: store, pairing: pairing, killSwitch: fuse)
        return Harness(
            model: model, store: store, pairing: pairing, fuse: fuse,
            engine: engine, interface: interface, journal: journal, defaults: defaults
        )
    }

    @Test("The page reads the policy and the bindings from the store, not from a copy")
    func refreshReadsThrough() async throws {
        let made = try makeHarness(
            label: "settings-refresh",
            mappings: [
                PopopxMeshTestKeys.mapping(for: PopopxMeshTestKeys.peerA, contactId: 7),
                PopopxMeshTestKeys.mapping(for: PopopxMeshTestKeys.peerB, contactId: nil)
            ],
            policy: .autoSilent
        )
        await made.model.refresh()

        #expect(made.model.pairingPolicy == .autoSilent)
        #expect(made.model.bindings.count == 2)
        #expect(made.model.bindings.first(where: { $0.meshPublicKeyHex == PopopxMeshTestKeys.peerA })?.status
            == "contact :7")
        // A binding that only has a pending connection is module 6's "not yet a contact" row.
        #expect(made.model.bindings.first(where: { $0.meshPublicKeyHex == PopopxMeshTestKeys.peerB })?.status
            == "pending :11")
    }

    @Test("The picker writes through the store before it changes what the page shows")
    func policyWriteThrough() async throws {
        let made = try makeHarness(label: "settings-policy")
        await made.model.refresh()
        #expect(made.model.pairingPolicy == .manualConfirm)

        await made.model.updatePairingPolicy(.autoSilent)
        let writes = await made.store.recordedPolicyWrites()
        #expect(writes == [.autoSilent])
        #expect(made.model.pairingPolicy == .autoSilent)
        #expect(made.defaults.string(forKey: IdentityMappingStore.pairingPolicyDefaultsKey) == nil)
        // The fake stands in for the store, so the persisted key is the fake's business; what the page
        // promises is that it never writes a second key of its own.
        #expect(made.journal.all.contains("policy:autoSilent"))
    }

    @Test("The master switch goes through the fuse, and the fuse is the only thing that starts a radio")
    func fuseWriteThrough() async throws {
        let made = try makeHarness(label: "settings-fuse")
        await made.model.refresh()

        await made.model.setFuseEnabled(true)
        #expect(made.fuse.isEnabled)
        #expect(made.defaults.bool(forKey: PopopxMeshKillSwitch.enabledDefaultsKey))
        let engineCounts = await made.engine.counts
        #expect(engineCounts.start == 1)

        await made.model.setFuseEnabled(false)
        #expect(made.fuse.phase == .off)
        let snapshot = made.fuse.isActiveSnapshot
        #expect(snapshot.isFullyIdle)
    }

    @Test("The activity the page reports is the activity the fuse has")
    func activityIsReported() async throws {
        let made = try makeHarness(label: "settings-activity")
        await made.model.refresh()
        #expect(made.model.activity.phase == .off)
        #expect(made.model.activity.isFullyIdle)
        #expect(MeshPrivacySettingsView.words(for: made.model.activity) == "off, Bluetooth idle")

        await made.model.setFuseEnabled(true)
        await made.model.refresh()
        #expect(made.model.activity.phase == .on)
        #expect(made.model.activity.runningRadioWork.contains("engine"))
        // The footer has to distinguish "on" from "still winding down", or the settings screen gets
        // blamed for a scan it already stopped.
        #expect(MeshPrivacySettingsView.words(for: made.model.activity).contains("on"))
    }

    @Test("Clearing identity bindings forgets every peer and reports how many actually went")
    func clearAllBindings() async throws {
        let made = try makeHarness(
            label: "settings-clear",
            mappings: [
                PopopxMeshTestKeys.mapping(for: PopopxMeshTestKeys.peerA),
                PopopxMeshTestKeys.mapping(for: PopopxMeshTestKeys.peerB),
                PopopxMeshTestKeys.mapping(for: PopopxMeshTestKeys.peerC)
            ]
        )
        await made.model.refresh()
        #expect(made.model.bindings.count == 3)

        let removed = await made.model.clearAllBindings()
        #expect(removed == 3)
        #expect(made.model.bindings.isEmpty)
        #expect(made.model.bindingsLeftAfterClear == 0)

        let forgotten = await made.pairing.answered
        #expect(Set(forgotten.forgotten) == Set([
            PopopxMeshTestKeys.peerA, PopopxMeshTestKeys.peerB, PopopxMeshTestKeys.peerC
        ]))
        // Clearing takes the fuse down first: unbinding a live peer would leave the engine re-pairing it
        // on the next announce, which reads as the button not working.
        #expect(made.fuse.isEnabled == false)
    }

    @Test("A binding the store refuses to remove is counted as left behind")
    func clearCountsWhatSurvived() async throws {
        let journal = PopopxMeshJournal()
        // No pairing manager, so the store's own `unbind` is the path; a store that keeps one row back
        // must show up in the report rather than be wishfully counted.
        let store = PopopxMeshStubbornStore(journal: journal)
        let model = PopopxMeshSettingsModel(store: store)
        await model.refresh()
        #expect(model.bindings.count == 2)

        let removed = await model.clearAllBindings()
        #expect(removed == 1)
        #expect(model.bindingsLeftAfterClear == 1)
        #expect(model.bindings.count == 1)
    }

    @Test("Forgetting one neighbour leaves the others alone")
    func forgetOneBinding() async throws {
        let made = try makeHarness(
            label: "settings-forget-one",
            mappings: [
                PopopxMeshTestKeys.mapping(for: PopopxMeshTestKeys.peerA),
                PopopxMeshTestKeys.mapping(for: PopopxMeshTestKeys.peerB)
            ]
        )
        await made.model.refresh()

        let gone = await made.model.forgetBinding(PopopxMeshTestKeys.peerA)
        #expect(gone)
        #expect(made.model.bindings.map(\.meshPublicKeyHex) == [PopopxMeshTestKeys.peerB])
        let forgotten = await made.pairing.answered
        #expect(forgotten.forgotten == [PopopxMeshTestKeys.peerA])
    }

    @Test("The policy list is the store's enum, so no third option can appear")
    func offeredPoliciesAreTheWholeEnum() {
        #expect(Set(MeshPrivacySettingsView.policies.map(\.rawValue)) == Set(MeshPairingPolicy.allCases.map(\.rawValue)))
        #expect(MeshPrivacySettingsView.words(for: .manualConfirm) == "Manual confirmation")
        #expect(MeshPrivacySettingsView.words(for: .autoSilent) == "Silent pairing")
    }

    @Test("A model without a fuse still answers the switch, from the same key")
    func fuselessModelReadsTheKey() async throws {
        let journal = PopopxMeshJournal()
        let store = PopopxMeshFakeBindingStore(policy: .manualConfirm, journal: journal)
        let model = PopopxMeshSettingsModel(store: store)
        // Nothing to turn on, and the page must not pretend otherwise.
        await model.setFuseEnabled(true)
        #expect(model.fuseEnabled == false)
        await model.refresh()
        #expect(model.activity.isFullyIdle)
    }
}

/// A store that removes exactly one row and keeps the rest, so "how many went" is measured rather than
/// echoed back from the call's own return value.
actor PopopxMeshStubbornStore: PopopxMeshBindingObserving {
    private var mappings: [PopopxMeshContactMapping]
    private let journal: PopopxMeshJournal
    private var removedOnce = false

    init(journal: PopopxMeshJournal) {
        self.journal = journal
        self.mappings = [
            PopopxMeshTestKeys.mapping(for: PopopxMeshTestKeys.peerA),
            PopopxMeshTestKeys.mapping(for: PopopxMeshTestKeys.peerB)
        ]
    }

    func pairingPolicy() async -> MeshPairingPolicy {
        .manualConfirm
    }

    func setPairingPolicy(_ policy: MeshPairingPolicy) async {
        journal.record("policy:\(policy.rawValue)")
    }

    func allMappings() async -> [PopopxMeshContactMapping] {
        mappings
    }

    @discardableResult
    func unbind(meshPublicKeyHex: String) async throws(IdentityMappingError) -> Bool {
        guard !removedOnce else { return false }
        removedOnce = true
        mappings.removeAll { $0.meshPublicKeyHex == meshPublicKeyHex }
        return true
    }
}
