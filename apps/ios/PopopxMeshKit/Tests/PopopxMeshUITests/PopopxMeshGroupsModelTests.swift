//
//  PopopxMeshGroupsModelTests.swift
//  PopopxMeshUITests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  缺陷 1: 「新建群组在列表中显示后立即消失，再次打开闪现后又消失」.
//
//  The cause was not the store. `PopopxGroupStore` writes the roster file and the epoch key and reads
//  them back before it answers, and it still does — one test below checks exactly that. The cause was
//  that the view built a NEW model on every recompute of its parent's body: a fresh object holding
//  `groups = []`, with nothing subscribed and no `.onAppear` to start it, because the view's structural
//  identity had not changed. The fix is that the host owns one model, so what is asserted here is this
//  model's behaviour under the calls that host now makes — plus the control that a model which is NOT
//  started really does show nothing. Without that control, an empty list would pass every test here.
//

import Foundation
import Testing

@testable import PopopxMeshUI
import PopopxMeshKit

@MainActor
@Suite("PopopxMeshGroupsModel / one model, kept across rebuilds")
struct PopopxMeshGroupsModelTests {
    private struct Harness {
        let device: PopopxMeshGroupDevice
        let source: PopopxMeshStateSource
        let meshHub: PopopxMeshEventHub
        let model: PopopxMeshGroupsModel
        let journal: PopopxMeshJournal

        func cleanUp() { device.remove() }
    }

    private func makeHarness(label: String) throws -> Harness {
        let journal = PopopxMeshJournal()
        let device = try PopopxMeshGroupDevice.make(journal: journal, label: label)
        let meshHub = PopopxMeshEventHub()
        let source = PopopxMeshStateSource(hub: meshHub)
        let model = PopopxMeshGroupsModel(
            outbound: device.outbound,
            source: source,
            hub: device.groupHub
        )
        return Harness(device: device, source: source, meshHub: meshHub, model: model, journal: journal)
    }

    /// Brings a mirror up and waits until it is on the group stream AND has completed a read of the
    /// store. Every assertion runs after this, because the defect being pinned is a mirror that was
    /// never started — and because waiting on the read counter instead of on what the read assigns would
    /// let the next call race the reload that is still in flight. `localSigningPublicKeyHex` is the last
    /// thing `reload()` writes, so it is the honest completion signal.
    private func startAndSettle(
        _ model: PopopxMeshGroupsModel,
        hub: PopopxMeshGroupEventHub
    ) async throws {
        model.start()
        try await popopxMeshWaitUntil("the group subscription") { await hub.subscriberCount >= 1 }
        try await popopxMeshWaitUntil("a completed store read") { model.localSigningPublicKeyHex != nil }
    }

    @Test("starting the same model twice leaves one subscription and two reads")
    func startIsIdempotent() async throws {
        let made = try makeHarness(label: "start-twice")
        defer { made.cleanUp() }

        made.model.start()
        made.model.start()
        try await popopxMeshWaitUntil("one group subscription") { await made.device.groupHub.subscriberCount == 1 }
        try await popopxMeshWaitUntil("both reads landed") { await made.device.outbound.recordedReads >= 2 }
        // A rebuild that calls `start()` again is the app's normal path (`.onAppear` on a pane the host
        // re-mounts). It must not fan out into a second subscription, a second pump or a read per pass.
        #expect(await made.device.groupHub.subscriberCount == 1)
        #expect(await made.device.outbound.recordedReads == 2)

        // The control. A model nobody started shows nothing and reads nothing — were it to list a group,
        // every test below would be asserting the harness rather than the module.
        let idle = PopopxMeshGroupsModel(
            outbound: made.device.outbound,
            source: made.source,
            hub: made.device.groupHub
        )
        #expect(idle.groups.isEmpty)
        #expect(idle.selectedGroup == nil)
        #expect(idle.canCreate == false)
        #expect(await made.device.outbound.recordedReads == 2)
    }

    @Test("a created group is still listed after the reload that follows it")
    func createdGroupSurvivesItsOwnReload() async throws {
        let made = try makeHarness(label: "create-survives")
        defer { made.cleanUp() }
        try await startAndSettle(made.model, hub: made.device.groupHub)

        made.model.groupDraft = "Cabin crew"
        await made.model.createGroup()

        let groupID = try #require(made.model.selectedGroupID, "creating a group selects it")
        #expect(made.model.groups.contains { $0.id == groupID })
        #expect(made.model.groups.count == 1)
        #expect(made.model.selectedGroup?.name == "Cabin crew")
        #expect(made.model.lastFailure == nil)
        // The list row is the store's answer, not the create call's return value: this is the line that
        // failed once a rebuild swapped in an unstarted model.
        #expect(made.model.isCreator(made.model.groups[0]))

        // And it is on disk, at the epoch it was created with, key included.
        let stored = try #require(await made.device.store.group(withID: groupID))
        #expect(stored.epoch == 1)
        #expect(stored.members.count == 1)
        #expect(await made.device.store.key(forGroupID: groupID)?.count == PopopxMeshGroup.keyByteCount)
    }

    @Test("a re-read keeps the open thread and only closes a group that really left")
    func reloadKeepsTheSelectionOfAGroupThatStillExists() async throws {
        let made = try makeHarness(label: "reload-keeps-selection")
        defer { made.cleanUp() }
        try await startAndSettle(made.model, hub: made.device.groupHub)

        made.model.groupDraft = "Still here"
        await made.model.createGroup()
        let groupID = try #require(made.model.selectedGroupID)

        await made.model.reload()
        #expect(made.model.selectedGroupID == groupID)
        #expect(made.model.selectedGroup?.name == "Still here")

        // The store is the only thing that may close the thread. Clearing the selection on every read is
        // what made 「新建群后无法发送消息」 unfixable from the list pane, because `sendDraft()` needs it.
        await made.device.store.removeGroup(withID: groupID)
        await made.model.reload()
        #expect(made.model.selectedGroupID == nil)
        #expect(made.model.selectedGroup == nil)
    }

    @Test("hiding the pane keeps the list and clears only the thread")
    func stopKeepsTheGroupsAndClearsTheMessages() async throws {
        let made = try makeHarness(label: "stop-keeps-list")
        defer { made.cleanUp() }
        try await startAndSettle(made.model, hub: made.device.groupHub)

        made.model.groupDraft = "Leave and return"
        await made.model.createGroup()
        let groupID = try #require(made.model.selectedGroupID)
        made.model.draft = "before the pane went away"
        await made.model.sendDraft()
        try await popopxMeshWaitUntil("the bubble") { made.model.messages(in: groupID).count == 1 }

        // `stop()` is what `.onDisappear` used to call, and what the fuse calls on the way off. Dropping
        // the list there would be the flash-away bug under a different name.
        made.model.stop()
        #expect(made.model.groups.contains { $0.id == groupID })
        #expect(made.model.messages.isEmpty)

        made.model.start()
        try await popopxMeshWaitUntil("the list after returning") { made.model.groups.count == 1 }
        #expect(made.model.selectedGroupID == groupID)
    }

    @Test("the fuse turning back on re-reads a group left on disk")
    func fuseRestartReReadsTheStore() async throws {
        let made = try makeHarness(label: "fuse-restart")
        defer { made.cleanUp() }
        let defaults = try popopxMeshTestDefaults("fuse-restart")
        let fuse = PopopxMeshKillSwitch(
            engine: PopopxMeshFakeComponent(name: "engine", journal: made.journal),
            healthMonitor: PopopxMeshFakeComponent(name: "health", journal: made.journal),
            pairing: nil,
            interface: PopopxMeshFakeComponent(name: "interface", journal: made.journal),
            hub: made.meshHub,
            defaults: defaults,
            nicknameStore: PopopxMeshNicknameStore(directory: FileManager.default.temporaryDirectory)
        )

        // Registered while the switch is off, which is what `bootstrap()` does: registering must not
        // start anything, and a mirror mounted before the group existed must not claim to hold it.
        await fuse.register(
            PopopxMeshSwitchedComponent(name: "meshGroups", role: .interface, component: made.model)
        )
        #expect(made.model.groups.isEmpty)

        let group = try await made.device.coordinator.createGroup(named: "Last session")
        #expect(made.model.groups.isEmpty, "a mirror the fuse never started reads nothing")

        await fuse.setEnabled(true)
        try await popopxMeshWaitUntil("the reload after the switch") {
            made.model.groups.contains { $0.id == group.id }
        }
        #expect(made.model.groups.first { $0.id == group.id }?.name == "Last session")
        // The pane was never reopened, so this read can only have come from the fuse transition.
        #expect(fuse.isActiveSnapshot.runningInterfaceWork.contains("meshGroups"))

        await fuse.setEnabled(false)
        #expect(made.model.messages.isEmpty)
        // Off is off for the thread. The roster is not this mirror's to forget, and the store still
        // answers for it, so the next transition on finds it again.
        #expect(made.model.groups.contains { $0.id == group.id })
        #expect(await made.device.store.group(withID: group.id) != nil)
    }

    @Test("a group made before relaunch comes back from disk and can still be sent to")
    func relaunchReadsTheSameGroup() async throws {
        let made = try makeHarness(label: "relaunch")
        defer { made.cleanUp() }
        try await startAndSettle(made.model, hub: made.device.groupHub)

        made.model.groupDraft = "Across the restart"
        await made.model.createGroup()
        let groupID = try #require(made.model.selectedGroupID)

        // Same directory, same Keychain, new stack: the process the user gets after a kill.
        let reopened = made.device.relaunched(journal: made.journal)
        let model = PopopxMeshGroupsModel(
            outbound: reopened.outbound,
            source: PopopxMeshStateSource(hub: made.meshHub),
            hub: reopened.groupHub
        )
        try await startAndSettle(model, hub: reopened.groupHub)

        #expect(model.groups.map(\.id).contains(groupID))
        #expect(model.groups.first { $0.id == groupID }?.name == "Across the restart")
        // The signing identity came back from the same Keychain, so the roster still names this device.
        let creatorSigningHex = await made.device.coordinator.localSigningPublicKeyHex
        #expect(model.localSigningPublicKeyHex == creatorSigningHex)
        model.selectedGroupID = groupID
        model.draft = "still speaking"
        await model.sendDraft()
        try await popopxMeshWaitUntil("the send landed") { await reopened.outbound.recordedSends.count == 1 }
        #expect(await reopened.outbound.recordedSends == ["still speaking"])
        #expect(model.messages(in: groupID).first { $0.text == "still speaking" } != nil)
    }

    @Test("the radio reaching the mirror is what unlocks the send button")
    func radioStateSeededFromTheCurrentSnapshot() async throws {
        let made = try makeHarness(label: "radio-seed")
        defer { made.cleanUp() }
        try await startAndSettle(made.model, hub: made.device.groupHub)

        made.model.groupDraft = "Nearby"
        await made.model.createGroup()
        let groupID = try #require(made.model.selectedGroupID)
        made.model.draft = "can I send yet"
        // The radio has never reported, so the button is grey and says why. This is the state the defect
        // report read as 「离线」: a mirror that missed the engine's one publish stayed `.unknown`.
        #expect(made.model.radioState == .unknown)
        #expect(made.model.canSend == false)

        // The pump has to be on the hub before the event is published, or this test would be measuring
        // the wait rather than the pipeline.
        try await popopxMeshWaitUntil("the state pump on the hub") { await made.meshHub.subscriberCount >= 1 }
        await made.meshHub.publish(.bluetoothState(.poweredOn))
        try await popopxMeshWaitUntil("the radio state to reach the mirror") {
            made.model.radioState == .poweredOn
        }
        #expect(made.model.canSend)

        // A mirror that mounts AFTER that publish must still learn the radio's state, because the state
        // source hands a new consumer its current value before any new event.
        let late = PopopxMeshGroupsModel(
            outbound: made.device.outbound,
            source: made.source,
            hub: made.device.groupHub
        )
        late.start()
        try await popopxMeshWaitUntil("the late mirror to see the radio") { late.radioState == .poweredOn }
        #expect(late.radioState.isUsable)
        #expect(late.groups.contains { $0.id == groupID })
    }

    @Test("a refusal is reported instead of silently doing nothing")
    func refusalIsSurfacedRatherThanSwallowed() async throws {
        let made = try makeHarness(label: "refusal")
        defer { made.cleanUp() }
        try await startAndSettle(made.model, hub: made.device.groupHub)

        made.model.groupDraft = "Refused"
        await made.model.createGroup()
        let groupID = try #require(made.model.selectedGroupID)
        let failure = PopopxMeshGroupError.keyMissing(groupIDHex: groupID.popopxHex)
        await made.device.outbound.setRefusal(failure)

        made.model.draft = "into a group with no key"
        await made.model.sendDraft()
        #expect(made.model.lastFailure == failure)
        // The draft is cleared before the Kit is called, and this pins that rather than wish it away:
        // the engine seals the bubble BEFORE it floods, so a `.deliveryFailed` refusal already left a row
        // in the thread. Restoring the text unconditionally would type the same message twice.
        #expect(made.model.draft.isEmpty)
        #expect(await made.device.outbound.recordedSends.isEmpty)
        #expect(PopopxMeshGroupsModel.words(for: failure).isEmpty == false)
    }
}
