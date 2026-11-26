//
//  MeshGroupsView.swift
//  PopopxMeshUI
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Cabin's private group surface (module 8). Everything on this screen is Bluetooth-only traffic: a group
//  is a name, a roster and a 32-byte key that live on these phones, and an invite is a blob the
//  creator signs and sends 1:1 over the Noise session pairing already built. There is no server, no
//  relay, no channel id and no passphrase — the creator's signature is what makes a membership real,
//  which is Bitchat's creator-signed model rather than a shared-secret channel.
//
//  Two things are added on top of the Kit: (1) a state object that folds the group event stream into
//  one timeline — our own sealed messages and the neighbours' decrypted ones, by message id, oldest
//  first — and (2) one view that is both the list and the thread. `NavigationView` is off the table
//  and a push would need `NavigationStack`, which is iOS 16; this package's floor is iOS 15 (ruling A),
//  so selecting a group swaps the pane in place instead.
//
//  Style follows the rest of this target: system materials and semantic colours only, the same
//  `PopopxMeshChannelBadge` the merged timeline uses, no raw hex, no `.cornerRadius`. The design
//  tokens in the app's `Shared/Theme/PopopxTheme.swift` are `internal` to that target and therefore
//  unreachable from a package — which is why this screen looks like `MeshPlazaView`.
//

import Combine
import Foundation
import PopopxMeshKit
import SwiftUI

// MARK: - Model

/// The group layer's UI state: what groups this device holds, who is in them, the merged thread, and
/// the three actions a person can take (create, invite, talk).
///
/// It holds the send side as `any PopopxMeshGroupOutbound` for the same reason the plaza holds
/// `any PopopxMeshOutbound`: a test drives it with a fake and never touches a radio.
@MainActor
public final class PopopxMeshGroupsModel: ObservableObject, PopopxMeshSwitchable {
    /// A group message is one flooded packet. The engine's fragmentation still applies, but a thread
    /// that carries a novel is not a thread.
    public static let maxMessageCharacters = 512

    @Published public private(set) var groups: [PopopxMeshGroup] = []
    /// Merged timeline across every group this device can read, oldest first. Filtered per thread by
    /// `messages(in:)`, so one array is enough and a re-flooded message cannot appear twice.
    @Published public private(set) var messages: [PopopxMeshGroupMessage] = []
    /// Peers whose signing key this device has heard — the only peers a roster can name.
    @Published public private(set) var invitablePeers: [String] = []
    @Published public private(set) var radioState: PopopxBluetoothState = .unknown
    /// Our Ed25519 public key hex. Whether a group's creator row carries it is how this screen knows
    /// the roster sheet should offer Invite / Remove at all.
    @Published public private(set) var localSigningPublicKeyHex: String?

    /// The thread the detail pane shows. `nil` is the list pane, not "nothing selected".
    @Published public var selectedGroupID: Data?
    @Published public var groupDraft: String = ""
    @Published public var draft: String = ""

    /// The last refusal, kept as the Kit's error value rather than a string so the copy lives in one
    /// function and a test can assert on the case.
    @Published public private(set) var lastFailure: PopopxMeshGroupError?
    @Published public private(set) var isBusy = false

    private let outbound: any PopopxMeshGroupOutbound
    private let source: PopopxMeshStateSource
    private let hub: PopopxMeshGroupEventHub
    private var groupTask: Task<Void, Never>?
    private var radioTask: Task<Void, Never>?

    public init(
        outbound: any PopopxMeshGroupOutbound = PopopxMeshEngine.shared,
        source: PopopxMeshStateSource = .shared,
        hub: PopopxMeshGroupEventHub = .shared
    ) {
        self.outbound = outbound
        self.source = source
        self.hub = hub
    }

    // MARK: Reads

    public var selectedGroup: PopopxMeshGroup? {
        guard let selectedGroupID else { return nil }
        return groups.first { $0.id == selectedGroupID }
    }

    public func messages(in groupID: Data) -> [PopopxMeshGroupMessage] {
        messages.filter { $0.groupID == groupID }
    }

    /// Whether this device created the group. Answered from the creator's ROSTER ROW rather than from
    /// the mesh key, because a signing key is what the signature was made with: `PopopxGroupStore`
    /// pins both together, and a group whose creator row is not ours can never be re-signed here.
    public func isCreator(_ group: PopopxMeshGroup) -> Bool {
        guard let localSigningPublicKeyHex else { return false }
        return group.creator?.signingPublicKeyHex == localSigningPublicKeyHex
    }

    /// Peers an invite sheet can offer: a signing key we have heard, and no roster row yet.
    public func inviteCandidates(for group: PopopxMeshGroup) -> [String] {
        let taken = Set(group.members.map(\.meshPublicKeyHex))
        return invitablePeers.filter { !taken.contains($0) }
    }

    public var canCreate: Bool {
        !groupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canSend: Bool {
        selectedGroupID != nil
            && radioState.isUsable
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Life cycle

    /// Mirrors the group event stream and the radio state. Idempotent. A group that never arrives is
    /// an empty list, not a stuck spinner: nothing here waits on the network.
    public func start() {
        source.start()
        let hub = self.hub
        if groupTask == nil {
            groupTask = Task { @MainActor [weak self] in
                // `subscribe` is an actor hop, so the stream is obtained inside the task rather than
                // making `start()` async for the sake of one line.
                let stream = await hub.subscribe()
                for await event in stream {
                    if Task.isCancelled { break }
                    self?.apply(event: event)
                }
            }
        }
        if radioTask == nil {
            let stateStream = source.observeState()
            radioTask = Task { @MainActor [weak self] in
                for await state in stateStream {
                    if Task.isCancelled { break }
                    self?.radioState = state.radioState
                }
            }
        }
        Task { await self.reload() }
    }

    public func stop() {
        groupTask?.cancel()
        groupTask = nil
        radioTask?.cancel()
        radioTask = nil
        messages = []
    }

    // MARK: Fuse component

    /// The fuse starts and stops this mirror like any other interface component.
    ///
    /// This is what makes 「蓝牙开关重连后群组列表仍在」 true rather than lucky: a model that mounted while
    /// the switch was off read an empty store, and nothing re-reads that store until the switch moves —
    /// the group events belong to the engine, which was not running. Turning on reloads instead of only
    /// subscribing, so a group created in an earlier session comes back without the pane being reopened.
    public func meshSwitchDidTurnOn(nickname: String?) async {
        start()
        await reload()
    }

    public func meshSwitchDidTurnOff() async {
        stop()
    }

    /// Pulls the current truth from the Kit. Called on appear and after every mutation, because a
    /// roster the creator signed is only visible once it has been through the store.
    public func reload() async {
        groups = await outbound.meshGroups()
        invitablePeers = await outbound.invitableMeshPeers()
        localSigningPublicKeyHex = await outbound.localSigningPublicKeyHex
        if let selectedGroupID, !groups.contains(where: { $0.id == selectedGroupID }) {
            self.selectedGroupID = nil
        }
    }

    // MARK: Actions

    public func createGroup() async {
        let name = PopopxMeshGroup.clampedName(groupDraft)
        guard !name.isEmpty else { return }
        groupDraft = ""
        if let group = await perform({ try await self.outbound.createGroup(named: name) }) {
            selectedGroupID = group.id
        }
        await reload()
    }

    public func open(_ groupID: Data) {
        selectedGroupID = groupID
    }

    public func closeDetail() {
        selectedGroupID = nil
    }

    public func invite(_ peerMeshPublicKeyHex: String) async {
        guard let groupID = selectedGroupID else { return }
        await perform {
            _ = try await self.outbound.invite(peerMeshPublicKeyHex: peerMeshPublicKeyHex, toGroupID: groupID)
        }
        await reload()
    }

    public func remove(_ peerMeshPublicKeyHex: String) async {
        guard let groupID = selectedGroupID else { return }
        await perform {
            _ = try await self.outbound.removeMeshGroupMember(peerMeshPublicKeyHex, fromGroupID: groupID)
        }
        await reload()
    }

    /// Seals and floods one message. A refusal from the radio does not remove the bubble: the text is
    /// in the thread because it was sealed into it, and neighbours may still hear a later re-flood.
    public func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let groupID = selectedGroupID else { return }
        let trimmed = String(text.prefix(Self.maxMessageCharacters))
        draft = ""
        await perform { try await self.outbound.sendGroupMessage(trimmed, toGroupID: groupID) }
    }

    /// One funnel for every Kit call. The closure is `throws` rather than `throws(PopopxMeshGroupError)`
    /// because typed throws do not survive an `any` existential: the protocol declares the concrete
    /// error for every requirement, and the erased call site only knows `any Error`. The second catch
    /// therefore reports a foreign error as a failure instead of pretending it did not happen.
    private func perform<T>(_ action: () async throws -> T) async -> T? {
        isBusy = true
        defer { isBusy = false }
        do {
            let value = try await action()
            lastFailure = nil
            return value
        } catch let failure as PopopxMeshGroupError {
            lastFailure = failure
            PopopxMeshLog.route.warning(
                "👥 group action refused: \(String(describing: failure), privacy: .public)"
            )
            return nil
        } catch {
            lastFailure = .storageFailed("unexpected error: \(String(describing: error))")
            PopopxMeshLog.route.error(
                "❌ group action threw outside the group error set: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    // MARK: Reduction

    private func apply(event: PopopxMeshGroupEvent) {
        switch event {
        case let .changed(group):
            if let index = groups.firstIndex(where: { $0.id == group.id }) {
                groups[index] = group
            } else {
                groups.append(group)
            }
        case let .removed(groupID, _):
            groups.removeAll { $0.id == groupID }
            messages.removeAll { $0.groupID == groupID }
            if selectedGroupID == groupID { selectedGroupID = nil }
        case let .message(message):
            // Our own seal publishes once and a re-flood is refused by the Kit's deduplicator, so
            // this only guards a host that restarts the pump mid-flight.
            guard !messages.contains(where: { $0.id == message.id }) else { return }
            messages.append(message)
            if messages.count > PopopxMeshStateSource.defaultCapacity {
                messages.removeFirst(messages.count - PopopxMeshStateSource.defaultCapacity)
            }
            messages.sort {
                if $0.sentAt != $1.sentAt { return $0.sentAt < $1.sentAt }
                return $0.id < $1.id
            }
        case let .stateRefused(groupIDHex, reason):
            // A refused state is a roster this device may not believe. Worth one line on screen: the
            // alternative is an invite that appears to have done nothing.
            PopopxMeshLog.route.warning(
                "🚫 group state refused (\(reason.rawValue, privacy: .public)) for \(groupIDHex ?? "?", privacy: .public)"
            )
            lastFailure = .rejected(reason)
        }
    }

    /// Module 8's refusals, one line of copy each. `.peerNotResolved` is the one a host really hits —
    /// a peer whose signing key has never been announced cannot be pinned into a roster — so it says
    /// what to do about it rather than only what failed.
    /// The group layer's refusals go through the app's own table: `NSLocalizedString` resolves against
    /// the main bundle, which is where the 16 `*.lproj/Localizable.strings` catalogues live, so this
    /// screen says the same sentence as the Cabin host rather than keeping a second copy here.
    private static func key(_ value: String) -> String { NSLocalizedString(value, comment: "POPOPX offline groups") }
    private static func fmt(_ value: String, _ argument: CVarArg) -> String { String(format: key(value), argument) }
    private static func fmt(_ value: String, _ first: CVarArg, _ second: CVarArg) -> String {
        String(format: key(value), first, second)
    }

    public static func words(for failure: PopopxMeshGroupError) -> String {
        switch failure {
        case .signingIdentityUnavailable: key("No signing key on this device")
        case .nameEmpty: key("Give the group a name")
        case .notCreator: key("Only the creator can change this roster")
        case .groupNotFound: key("This group is no longer on this device")
        case .keyMissing: key("The group key is gone from the Keychain")
        case let .memberCapReached(limit): fmt("A group holds %lld members", limit)
        case .alreadyMember: key("Already in this group")
        case .memberNotFound: key("Not in this group")
        case .cannotRemoveCreator: key("The creator cannot be removed — only a peer")
        case .peerNotResolved: key("That peer has not announced a signing key yet — meet it over Bluetooth first")
        case .peerPublicKeyInvalid: key("That is not a peer key")
        case .rosterWouldBeEmpty: key("Someone has to be left in the group")
        case .notMember: key("You are not in this group")
        case let .storageFailed(reason): fmt("Could not store the group: %@", reason)
        case let .deliveryFailed(peers, sendFailure):
            fmt("Not sent — %@ (%lld peer(s))", MeshPlazaView.words(for: sendFailure), peers.count)
        case let .rejected(reason): fmt("Group state refused: %@", reason.rawValue)
        }
    }
}

// MARK: - View

/// The group list and the group thread, in one pane-switching view.
@MainActor
public struct MeshGroupsView: View {
    @ObservedObject private var model: PopopxMeshGroupsModel
    /// Whether leaving this pane takes the mirror down. The Cabin's home page passes `true`, matching
    /// the plaza: the fuse owns this model's life, not the pane.
    private let keepsRunningWhenHidden: Bool

    /// The host holds the model, and holds exactly one of it.
    ///
    /// The initialiser that took `outbound`/`source`/`hub` and built the model here is gone on purpose:
    /// a view made inside a `navigationDestination` builder is rebuilt on every parent recompute, and a
    /// rebuilt model comes back with `groups = []` and `radioState = .unknown` that nothing ever
    /// `start()`s, because `.onAppear` does not re-fire for a view whose structural identity did not
    /// change. A host that has not decided where its one model lives now fails to compile.
    public init(model: PopopxMeshGroupsModel, keepsRunningWhenHidden: Bool = false) {
        self.model = model
        self.keepsRunningWhenHidden = keepsRunningWhenHidden
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let group = model.selectedGroup {
                detail(group)
            } else {
                list
            }
        }
        .onAppear { model.start() }
        .onDisappear { if !keepsRunningWhenHidden { model.stop() } }
    }

    // MARK: List pane

    private var list: some View {
        List {
            Section {
                if model.groups.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No groups on this device yet.")
                        Text("A group exists only on the phones in it. Creating one puts nothing on any network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(model.groups, id: \.idHex) { group in
                        Button {
                            model.open(group.id)
                        } label: {
                            row(group)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Groups")
                    Spacer()
                    Text("\(model.groups.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 8) {
                    TextField("New group name", text: $model.groupDraft)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            Task { await model.createGroup() }
                        }
                    Button {
                        Task { await model.createGroup() }
                    } label: {
                        if model.isBusy {
                            ProgressView()
                        } else {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                    .disabled(!model.canCreate)
                    .accessibilityLabel(Text("Create group"))
                }
            } footer: {
                Text(
                    "Up to \(PopopxMeshGroup.maxMembers) members, and the name is not secret — the messages are."
                )
                .font(.caption2)
            }
        }
    }

    private func row(_ group: PopopxMeshGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.body.weight(.semibold))
                    if model.isCreator(group) {
                        Text("You created this")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(group.members.count) member(s) · epoch \(group.epoch)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PopopxMeshChannelBadge(channel: .offlineMesh(hopCount: 0))
        }
        .padding(.vertical, 2)
    }

    // MARK: Detail pane

    private func detail(_ group: PopopxMeshGroup) -> some View {
        VStack(spacing: 0) {
            header(group)
            Divider()
            timeline(group)
            Divider()
            if model.isCreator(group) {
                roster(group)
                Divider()
            }
            composer
            failureLine
        }
    }

    private func header(_ group: PopopxMeshGroup) -> some View {
        HStack(spacing: 8) {
            Button {
                model.closeDetail()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Back to groups"))

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.headline)
                Text(
                    model.radioState.isUsable
                        ? "\(group.members.count) member(s) · epoch \(group.epoch)"
                        : PopopxMeshBannerModel.radioTitle(model.radioState)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func timeline(_ group: PopopxMeshGroup) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.messages(in: group.id), id: \.id) { message in
                    bubble(message)
                }
                if model.messages(in: group.id).isEmpty {
                    Text("Nothing said in this group yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func bubble(_ message: PopopxMeshGroupMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if message.isLocal { Spacer(minLength: 24) }
            VStack(alignment: message.isLocal ? .trailing : .leading, spacing: 3) {
                Text(message.senderNickname.isEmpty ? "Peer" : message.senderNickname)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.isLocal {
                    PopopxMeshChannelBadge(channel: .offlineMesh(hopCount: message.hopCount))
                }
            }
            if !message.isLocal { Spacer(minLength: 24) }
            Text(MeshPlazaView.clock(message.sentAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(message.isLocal ? Color.secondary.opacity(0.12) : Color.clear)
    }

    /// Only a creator can change a roster, so the sheet is not rendered for anyone else — the Kit
    /// throws `.notCreator` and this screen has no reason to offer a button that will fail.
    private func roster(_ group: PopopxMeshGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Members")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                inviteMenu(group)
            }
            ForEach(group.members, id: \.meshPublicKeyHex) { member in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.nickname.isEmpty ? String(member.meshPublicKeyHex.prefix(8)) : member.nickname)
                        Text(String(member.meshPublicKeyHex.prefix(8)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if member.meshPublicKeyHex != group.creatorMeshPublicKeyHex {
                        Button {
                            Task { await model.remove(member.meshPublicKeyHex) }
                        } label: {
                            Image(systemName: "person.crop.circle.badge.xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove member"))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func inviteMenu(_ group: PopopxMeshGroup) -> some View {
        Menu {
            let candidates = model.inviteCandidates(for: group)
            if candidates.isEmpty {
                Text("No peer to invite")
            } else {
                ForEach(candidates, id: \.self) { peer in
                    Button(peer.prefix(12)) {
                        Task { await model.invite(peer) }
                    }
                }
            }
        } label: {
            Image(systemName: "person.badge.plus")
        }
        .disabled(group.members.count >= PopopxMeshGroup.maxMembers || model.inviteCandidates(for: group).isEmpty)
        .accessibilityLabel(Text("Invite a nearby peer"))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message the group", text: $model.draft)
                .disabled(!model.radioState.isUsable)
                .onSubmit {
                    Task { await model.sendDraft() }
                }
            Button {
                Task { await model.sendDraft() }
            } label: {
                if model.isBusy {
                    ProgressView()
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .disabled(!model.canSend)
            .accessibilityLabel(Text("Send to group"))
        }
        .padding(12)
    }

    @ViewBuilder private var failureLine: some View {
        if let failure = model.lastFailure {
            Text(PopopxMeshGroupsModel.words(for: failure))
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
    }
}
