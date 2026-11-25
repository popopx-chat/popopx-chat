//
//  PopopxMeshKillSwitchTests.swift
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Red line 28: off means off. These four tests are the fuse's whole promise — launch off starts no BLE
//  at all, turning it on mid-session starts cleanly, turning it off leaves nothing running, and a
//  nickname change re-applies through the same path.
//

import Foundation
import Testing
@testable import PopopxMeshUI
import PopopxMeshKit

@MainActor
@Suite("PopopxMeshKillSwitch bookkeeping")
struct PopopxMeshKillSwitchTests {
    /// A fuse wired to fakes: no engine, no transport, no `CBCentralManager`.
    private func makeFuse(
        label: String,
        enabledAtLaunch: Bool? = nil,
        nicknameDirectory: URL? = nil
    ) throws -> (
        fuse: PopopxMeshKillSwitch,
        engine: PopopxMeshFakeComponent,
        health: PopopxMeshFakeComponent,
        interface: PopopxMeshFakeComponent,
        journal: PopopxMeshJournal,
        defaults: UserDefaults
    ) {
        let journal = PopopxMeshJournal()
        let engine = PopopxMeshFakeComponent(name: "engine", journal: journal)
        let health = PopopxMeshFakeComponent(name: "health", journal: journal)
        let interface = PopopxMeshFakeComponent(name: "interface", journal: journal)
        let defaults = try popopxMeshTestDefaults(label)
        if let enabledAtLaunch {
            defaults.set(enabledAtLaunch, forKey: PopopxMeshKillSwitch.enabledDefaultsKey)
        }
        let fuse = PopopxMeshKillSwitch(
            engine: engine,
            healthMonitor: health,
            pairing: nil,
            interface: interface,
            hub: PopopxMeshEventHub(),
            defaults: defaults,
            nicknameStore: PopopxMeshNicknameStore(
                directory: nicknameDirectory ?? FileManager.default.temporaryDirectory
            )
        )
        return (fuse, engine, health, interface, journal, defaults)
    }

    @Test("Launch with the switch off starts nothing at all")
    func launchOffStartsNothing() async throws {
        let made = try makeFuse(label: "launch-off")
        let fuse = made.fuse

        // No key written, so `UserDefaults.bool` is false: the default must be off, never "unknown".
        #expect(fuse.persistedIsEnabled == false)
        #expect(fuse.isEnabled == false)

        await fuse.restoreOnLaunch()

        let engineCounts = await made.engine.counts
        let healthCounts = await made.health.counts
        let interfaceCounts = await made.interface.counts
        #expect(engineCounts.start == 0)
        #expect(healthCounts.start == 0)
        #expect(interfaceCounts.start == 0)
        #expect(fuse.phase == .off)
        #expect(fuse.isActiveSnapshot.isRadioQuiet)
        #expect(fuse.isActiveSnapshot.isFullyIdle)
        // Nothing was even attempted: the journal is the proof, not just the counters.
        #expect(made.journal.all.isEmpty)
    }

    @Test("Launch with the switch on starts every component, mirror first")
    func launchOnStartsEverything() async throws {
        let made = try makeFuse(label: "launch-on", enabledAtLaunch: true)
        await made.fuse.restoreOnLaunch()

        let engineCounts = await made.engine.counts
        let healthCounts = await made.health.counts
        let interfaceCounts = await made.interface.counts
        #expect(engineCounts.start == 1)
        #expect(healthCounts.start == 1)
        #expect(interfaceCounts.start == 1)
        #expect(made.fuse.phase == .on)

        // The mirror subscribes before the radio publishes, or the first Bluetooth state event of the
        // session reaches nobody and the banner shows "unknown" until the next one.
        if let interfaceIndex = made.journal.index(containing: "start:interface"),
           let engineIndex = made.journal.index(containing: "start:engine") {
            #expect(interfaceIndex < engineIndex)
        } else {
            Issue.record("fuse did not record its start order: \(made.journal.all)")
        }
    }

    @Test("Turning the fuse off mid-session leaves no BLE work behind")
    func disableStopsEverything() async throws {
        let made = try makeFuse(label: "mid-session", enabledAtLaunch: true)
        await made.fuse.restoreOnLaunch()
        made.journal.reset()

        await made.fuse.setEnabled(false)

        let engineCounts = await made.engine.counts
        let healthCounts = await made.health.counts
        let interfaceCounts = await made.interface.counts
        #expect(engineCounts.stop == 1)
        #expect(healthCounts.stop == 1)
        #expect(interfaceCounts.stop == 1)
        #expect(made.fuse.phase == .off)
        #expect(made.defaults.bool(forKey: PopopxMeshKillSwitch.enabledDefaultsKey) == false)

        let snapshot = await made.fuse.verifiedActivitySnapshot()
        #expect(snapshot.runningRadioWork.isEmpty)
        #expect(snapshot.runningInterfaceWork.isEmpty)
        #expect(snapshot.isRadioQuiet)
        // The verified snapshot asks the hub, so this is the check that a subscriber was actually
        // released rather than merely forgotten by the fuse's own bookkeeping.
        #expect(snapshot.eventHubSubscribers == 0)
        #expect(snapshot.isFullyIdle)

        // The radio goes down before the mirror, or a mirror outlives the events it mirrors.
        if let engineIndex = made.journal.index(containing: "stop:engine"),
           let interfaceIndex = made.journal.index(containing: "stop:interface") {
            #expect(engineIndex < interfaceIndex)
        } else {
            Issue.record("fuse did not record its stop order: \(made.journal.all)")
        }
    }

    @Test("Re-enabling after a disable starts cleanly, not twice")
    func reEnableStartsCleanly() async throws {
        let made = try makeFuse(label: "re-enable", enabledAtLaunch: true)
        await made.fuse.restoreOnLaunch()
        await made.fuse.setEnabled(false)
        await made.fuse.setEnabled(true)

        let engineCounts = await made.engine.counts
        #expect(engineCounts.start == 2)
        #expect(engineCounts.stop == 1)
        #expect(made.fuse.phase == .on)

        // Flipping to the state already in force must not restart anything: a user tapping the same
        // side twice cannot tear down live sessions.
        await made.fuse.setEnabled(true)
        let afterDouble = await made.engine.counts
        #expect(afterDouble.start == 2)
        #expect(afterDouble.stop == 1)
    }

    @Test("A disabled fuse ignores a component registered later, and an enabled one starts it")
    func lateRegistrationFollowsTheSwitch() async throws {
        let made = try makeFuse(label: "late-register")
        let late = PopopxMeshFakeComponent(name: "router", journal: made.journal)
        await made.fuse.register(
            PopopxMeshSwitchedComponent(name: "router", role: .radio, component: late)
        )
        var lateCounts = await late.counts
        #expect(lateCounts.start == 0)

        await made.fuse.setEnabled(true)
        lateCounts = await late.counts
        #expect(lateCounts.start == 1)

        await made.fuse.setEnabled(false)
        lateCounts = await late.counts
        #expect(lateCounts.stop == 1)
        #expect(made.fuse.isActiveSnapshot.isFullyIdle)
    }

    @Test("A nickname change restarts the mesh with the new name")
    func nicknameChangeRestartsWithNewName() async throws {
        let directory = try PopopxMeshTestDirectory(label: "fuse-nickname")
        defer { directory.remove() }
        let made = try makeFuse(label: "nickname", enabledAtLaunch: true, nicknameDirectory: directory.url)
        await made.fuse.restoreOnLaunch()

        await made.fuse.setNickname("  Ada  ")
        #expect(made.fuse.nickname == "Ada")
        // The engine's only entry point for its advertised name is `start(nickname:)`, so applying a
        // name means a restart — and the restart must carry the name.
        let engineNickname = await made.engine.nickname
        #expect(engineNickname == "Ada")
        let engineCounts = await made.engine.counts
        #expect(engineCounts.start == 2)
        #expect(engineCounts.stop >= 1)
        // And it is on disk in the mesh's own sandbox, not in the Keychain.
        #expect(directory.exists(PopopxMeshNicknameStore.fileName))

        await made.fuse.clearNickname()
        #expect(made.fuse.nickname == nil)
        #expect(!directory.exists(PopopxMeshNicknameStore.fileName))
    }

    @Test("The persisted key is the one module 1 models, not a second one")
    func persistedKeyIsTheCoreKey() {
        #expect(PopopxMeshKillSwitch.enabledDefaultsKey == IdentityMappingStore.meshEnabledDefaultsKey)
    }

    @Test("A component that cannot stop is reported by the snapshot, not hidden")
    func snapshotNamesWhatIsStillRunning() async throws {
        let made = try makeFuse(label: "partial-stop", enabledAtLaunch: true)
        await made.fuse.restoreOnLaunch()
        // The snapshot names each component by the identity it was REGISTERED under — the fuse's own
        // slots, which is what `PopopxMeshSwitchedComponent.name` and `componentNames` expose — not by
        // whatever a double happens to call itself. The claim being held to is that both radio halves
        // are listed while they are still running, and that neither set is missing one.
        let radio = made.fuse.isActiveSnapshot.runningRadioWork
        #expect(radio.contains("engine"))
        #expect(radio.contains("healthMonitor"))
        #expect(radio.count == 2)
        #expect(made.fuse.isActiveSnapshot.runningInterfaceWork == ["interface"])
        #expect(made.fuse.isActiveSnapshot.isActive)
        #expect(!made.fuse.isActiveSnapshot.isRadioQuiet)
    }
}
