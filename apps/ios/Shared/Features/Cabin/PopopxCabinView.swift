//
//  PopopxCabinView.swift
//  POPOPX (iOS)
//
//  Phase 4 Tab 3 "Cabin" — this tab now has two screens, both inside this file, and both only about what is within physical range: the broadcast stream,
//  nearby nodes, the master switch; no public internet, no relay, no SMP.
//  - `PopopxMeshPlazaRootView` = the root of this tab, and in practice that is the package's `PopopxMeshUI/MeshPlazaView.swift`
//    full screen (from this round it is no longer "a page you reach by tapping the top-left corner"). The package copy stays untouched; three mount points repo-wide:
//    the root of this tab, this page's `.plaza` route, and `PopopxAddFriendView.swift:121` (the
//    `SettingsView.swift:396` sentence is a comment, and its own mount was removed long ago in 71001954f).
//  - `PopopxCabinView` = the full-height drawer summoned by the capsule in the **middle** of the root's top bar; the app-side rewrite of the local Bluetooth state.
//    Nothing is missing from the screen inside the drawer: master switch, radio, the three channel rows, nearby nodes, private chat and pairing. (The settings-centre screen, from round 10
//    onwards, is placed directly by the top-right capsule of the root screen, and the duplicate entry in the drawer's top bar was deleted outright — see decision 2 below.)
//
//  Device round 8 · task 1 (the root screen's top bar in three segments + full-screen immersion): `.topBarLeading` = the back key to the "Chat" tab
//  (the four capsules at the bottom of this tab gave way to it, it is the only exit, and the action writes the selected tab of `MainTabView`
//  through the `tabSelection` binding passed in by the host); `.principal` = the teal capsule of the old Cabin panel that used to stand in the top-left corner (the nearby-node radar and the offline group chats are both
//  inside it); `.topBarTrailing` = the offline mesh settings centre, position unchanged, round 10 shortened the label to "Settings" (the width accounting is in
//  the paragraph above `meshDiscoveryEntry`). The drawer and every page it pushes, their top bars,
//  are all left alone. The 49pt give-way of the bottom bar is declared by the root screen's own content with `.toolbar(.hidden, for: .tabBar)`, see
//  the two reasons given in that section of `PopopxMeshPlazaRootView.body`.
//
//  Three data sources, all real objects from the package; this file writes no second transport path:
//  1. `PopopxMeshStateSource.shared.state` —— `radioState / peers / broadcasts / latestBroadcastAt`。
//     `@ObservedObject` reads this mirror directly; nothing is `await`ed inside body.
//  2. `BluetoothHealthMonitor` (actor) — `allNodes()` is the only source of the node table and the hop-count badges, and the online judgement uses
//     `PopopxPeerReachability.isReachable(now:radioOn:timeout:)`, whose window cites module 4's own constant
//     `PopopxMeshConfig.default.peerReachabilityTimeout` (15 seconds; the `defaultReachabilityTimeout` at `BluetoothHealthMonitor.swift:66`
//     is just its alias). Actor readings are taken only in `.task` polling and after actions.
//  3. `ManualPairingManager` + `IdentityMappingStore` (two actors) — `allStates()` /
//     `pendingRequests()` / `initiatePairing(with:incognito:)` give the pairing facts, and `allMappings()` gives the "already bound" fact.
//
//  The send path is copied verbatim from `MeshPlazaView`: broadcast = `PopopxMeshOutbound.sendBroadcast(text:)` on
//  `PopopxMeshRuntime.shared.engineBackend` (`Shared/Model/POPOPXAPI.swift:3748`), which is to say the very same backend
//  that `PopopxAddFriendView.swift:121-125` passes in when mounting the plaza; the truncation/limit/local-echo/dedup
//  rules are copied from `PopopxMeshPlazaModel.broadcastDraft()` (`MeshPlazaView.swift:171-189`),
//  `rebuildPosts(from:)` (`:216-235`) and `deduped(_:)` (`:258-268`). The nickname write entry =
//  `PopopxMeshKillSwitch.setNickname(_:)` (inside the package `saveNickname()` ultimately does nothing but this).
//  "Tap to start Bluetooth private chat directly" = `initiatePairing(with:incognito:)` sending one offline connection invitation (the only action that can make a
//  Noise private-chat session exist), then pushing the package's private-chat screen `PopopxMeshPrivateChatView` with all four dependencies explicitly given
//  as real objects — its default parameters are the `PopopxMeshEngine.shared` / `.shared` singletons, which would let a page with the master switch off casually build up the engine
//  and the radio (the comment after `POPOPXAPI.swift:3557` is saying exactly this), so not one default value is used.
//
//  Channel naming (ruling; inside the package it is English `#mesh`, and `#mesh` appears 0 times in repo-wide `Shared/`):
//  - the public broadcast channel = `Copy.hallRow`; from round 10 the source text is `#Cabin Hall` (brand words follow the same English convention; the zh translation still is
//    the Chinese form of "#Cabin Hall"). Keeping the `#`: it is the visual mark of "a channel", not the word `#mesh`;
//    this channel is unencrypted flooding, only within Bluetooth range, it does not pass through a server, and it is not echoed back to the sender.
//  - the local encrypted channel (`Copy.encryptedChannelsRow`) = the set of Noise_XX 1:1 sessions this device has already established with a single Bluetooth neighbour (criterion = a mapping row in module 1,
//    or module 3 reporting `.paired`). It travels over the mesh rather than SMP, so the whole row is teal only and no indigo-violet appears (§1.1).
//
//  Colour discipline: teal appears only on rows that state mesh facts; the switch fill of `PopopxToggleRow` is hard-coded in the atomic library as
//  `PopopxPalette.brand` (`PopopxControls.swift:400`), so the master-switch row carries no teal badge — purple and teal coexisting
//  inside the same control is a §1.1 violation. Teal badges always carry the hop-count number (§1.4 rule 3). The 120% signature detail of this page is
//  the nearby-node radar; under Reduce Motion it degrades to a static ring plus a numeric hop count, and not one looping animation starts (§5).
//
//  Top bar and settings centre (the offline-mesh entries consolidated, seven decisions):
//  1. This top-left capsule has two destinations, chosen by how it is mounted (`leadingBarEntry`): standing alone as a page it is still "Discover" =
//     `path.append(.plaza)`, entering the package's own `MeshPlazaView`, written verbatim like the mount in `PopopxAddFriendView.swift:118-128`
//     and sharing one title Key (what device round 5 demanded was precisely "two entries opening exactly the same functional page");
//     as the drawer above the "Cabin" root it becomes dismiss-the-drawer instead — the root screen already treats the plaza as its home page, and the drawer must not offer another
//     loop back to the screen that summoned it. This capsule used to (before round 5) enter this page's own "Discover" screen
//     (`PopopxCabinNearbyCard` + `groupsCard`, two cards), and neither card lost an entry: the radar is in the hall's top-right
//     "discovery mode" (the switch state of `discoveryEntry`, reading the same `nodes`), and this device's offline groups plus the create entry are in the content area's
//     "offline group chat" row (`path.append(.groups)` → `MeshGroupsView`). The hall itself belongs to the content area's
//     `channelsCard` first row, and neither of these two capsules displaces the other; the `.plaza` route and its registration stay as they were.
//  2. "Offline mesh settings" = `PopopxCabinMeshSettingsSheet`, with three cards in order: master switch and pairing policy, node identity and
//     real runtime state, offline data and clearing. These four things used to be scattered across the offline-mesh group on the "Me" page and the Cabin card on the "All settings" page,
//     and when they were removed they were carried over item by item with full equivalence: `requestFuse(_:)` / `setPairingPolicy(_:)` / `verifiedActivitySnapshot()` /
//     `emergencyWipeAllMappings()`; not one binding changed its source, and no second state store was added;
//     from device round 10 this sheet is presented directly by **the root screen** in its own `.sheet`, and the reader of the nine numeric cells moved over with it
//     (`PopopxMeshPlazaRootView.refreshMeshSettingsFacts(waitingForSettle:)`, running only during the stretch the sheet is open)
//     : there is still only one presenter and one reader, it is simply no longer the drawer. The duplicate entry in the drawer screen's top bar, together with its set of
//     `showsMeshSettings` / identity / verification readings, was deleted outright, and both sides of the node table share the single fold implementation `PopopxCabinNodeFold`.
//  3. The settings centre's view is kept cohesive at the end of this file: zero new files, zero `project.pbxproj` changes (iron rule: do not script the project file);
//  4. The stack is held by this page itself: `NavigationStack(path: $path)` lives here, and `MainTabView` holds only the bare root
//     (from this round `PopopxMeshPlazaRootView()`, which presses this entire page into the drawer and still wraps no stack around the outside).
//     If `path` is not the copy bound to the stack, the four `path.append` calls never push anything at all; see the paragraph above `PopopxCabinRoute`;
//     this rule moves into the drawer together with this round: the page inside the drawer keeps holding its own stack, and the root stack never touches it.
//  5. The first round's claim of "100% carried over" did not hold under a device re-check; four things leaked outside this sheet, and this round adds them back item by item: the entry to the pairing-records page
//     (together with the state word at the end of its row that rewrites itself with the fuse), the dynamic subtitle under the master switch, the second verification with the settle window after flipping the switch,
//     and the current value of the pairing policy plus its own explanation. Adding them back still writes through `PopopxMeshRuntime` into the few unique objects in the package.
//  6. The entry to the pairing-records page lives in this sheet, so it pushes the root screen's own stack: the row first dismisses this sheet and then `append`s.
//     That page inside the package carries no stack of its own (it is one whole `List`), and its switch is `@AppStorage(PopopxMeshKillSwitch.enabledDefaultsKey)`
//     — the same key as the runtime mirror, so both places flip the same switch and there is no second toggle.
//  7. The only new row added to the sheet is the radio-and-permissions diagnostic: the reading recognises only `BluetoothHealthMonitor`'s `currentRadioState`,
//     the same reading as the top-bar capsule (`PopopxTelemetryHeader.swift:177`), and the state wording reuses
//     `PopopxDualStatusCapsule.words(for:)` (`PopopxTelemetryHeader.swift:391`); not one third way of saying anything is invented.
//     Only when the state lands on `unauthorized`/`poweredOff` does this row offer the "open system settings" tap: while the switch is healthy, tapping it
//     only jumps to a page that has nothing to change.
//
//  Localisation: every source sentence on this screen is an English original used as its own Key; the convention with the 16 translation catalogues is in the `Copy` section below
//  (device round 10 turned that whole batch of Phase 4 hard-written Chinese into Keys, so the screen no longer shows a single Chinese character). Chinese inside comments is another round's business.
//  Brand words follow the same convention: the Key source text writes Cabin in English, and the Chinese tab name no longer appears in any source sentence (`Copy.tabTitle`,
//  `Copy.hallRow` and `cabinPanelEntryHint`, those three renamed in this round; the old Keys' translations have to follow).
//  The bottom-bar cell is a different matter: it lives in `MainTabView.swift:245`, it was not touched this round, and it is not this file's business.
//

import Foundation
import SwiftUI
import PopopxMeshKit
import PopopxMeshUI

// MARK: - Push routes

/// The stack is held by this page itself: `path` must be the very copy **bound to the stack** — the same copy when this page is mounted as a drawer.
/// Before 2026-11-20 it sat on `@State` while `MainTabView` wrapped a bare stack around it, so those `path.append` calls
/// never pushed anything (the binding did not exist); moving the stack in here connected it, and Phase 4's "the message tab owns its stack" is the same pattern.
private enum PopopxCabinRoute: Hashable {
    /// "#Cabin Hall": the full broadcast stream + broadcast input + this device's temporary nickname. The entry is the first row of the content area's `channelsCard`.
    case hall
    /// The package's own "Cabin nearby plaza" (`PopopxMeshUI/MeshPlazaView`), and "Add friend → enter Cabin discovery,
    /// nearby groups/channels (BLE Mesh)" push the same view and the same title entry. From this round the root of this tab is directly
    /// that screen, so only the standalone-page variant's top-left corner still pushes in here; the registration stays as before (see decision 1 above).
    case plaza
    /// The local encrypted channel: the list of 1:1 encrypted sessions this device has already established with Bluetooth neighbours.
    case encryptedChannels
    /// Local encrypted group chat (the package's `MeshGroupsView`): the group name + member list + the 32-byte group key live only on these phones,
    /// membership is established by the creator's signature, with no server, no relay, and no passphrase.
    case groups
    /// Private chat with a specific mesh public key (the package's `PopopxMeshPrivateChatView`).
    case privateChat(peerMeshPublicKeyHex: String)
}

// MARK: - Label

/// How a public key is read: the same rule as the package's banner/private-chat page; past 16 characters take the first 16 plus an ellipsis
/// （`PopopxMeshBannerModel.shorten`，`ManualPairingBannerView.swift:358`；`PopopxMeshPrivateChatModel
/// (`.peerLabel` only forwards to it). Both hosts inside the package are `@MainActor` classes, and a non-isolated value type cannot call them synchronously,
/// so the same rule is replicated here verbatim, guaranteeing repo-wide that one public key has exactly one spelling.
private enum PopopxCabinLabel {
    static func abbreviate(_ hex: String) -> String {
        hex.count > 16 ? "\(hex.prefix(16))…" : hex
    }
}

// MARK: - The fixed values of the top bar's rendering

/// The two constants shared by the four top-bar capsules. Written in a value type instead of scattered across four view snippets: inside one bar the tinted background must be the same
/// opacity, and four capsules each writing their own number would be four different "faint teals".
private enum PopopxCabinBar {
    /// The fainter teal background: `mesh` extracted at 12% laid over the navigation bar background, and the `meshInk` text it carries still passes AA
    /// (repo-wide the existing pattern for this level of tint is `tint.opacity(0.10…0.12)`, the same level as the badge capsule and the card reading).
    static let softTintOpacity: Double = 0.12
}

// MARK: - Node snapshot

/// All the facts about one nearby node on this page: module 4's reachability + the mirror's nickname/RSSI + module 1's binding + module 3's pairing.
/// A value type, computed once by `refresh()`; the row view only reads it and no longer touches actors.
private struct PopopxCabinNode: Identifiable, Hashable {
    /// The three tiers of the binding fact, straight from the fields of `PopopxMeshContactMapping`.
    enum Binding: Hashable {
        /// `contactId != nil`: behind this mesh public key there is a real POPOPX contact.
        case contact
        /// `contactId == nil` and `isPending`: the offline connection invitation has been sent, and it is not a contact yet.
        case pending
        /// The mapping table has no row for this one.
        case none
    }

    let peerIDHex: String
    /// The 64-bit hexadecimal public key parsed from an announce or a handshake; when nil this node still cannot be addressed and only its flooding can be heard.
    let meshPublicKeyHex: String?
    let nickname: String?
    let hopCount: Int
    let lastSeenAt: Date
    let rssi: Int8?
    let isDirect: Bool
    let isReachable: Bool
    let binding: Binding
    let pairingState: MeshPairingState

    var id: String { peerIDHex }

    /// How the name is taken, matching the package's private-chat page: announce nickname → public-key abbreviation → the 8-byte line id prefix.
    /// The order lives in `PopopxCabinAuthor.label`, because the plaza's rows need the same spelling from
    /// different fields and two spellings of one peer is how two screens start disagreeing about who is who.
    var label: String {
        PopopxCabinAuthor.label(nickname: nickname, meshPublicKeyHex: meshPublicKeyHex, peerIDHex: peerIDHex)
    }

    /// Whether a private chat can be opened: without a public key no session can be assembled, and `SYS_POPOPX_*` frames would have nowhere to go.
    var canOpenChat: Bool { meshPublicKeyHex != nil }
    var isBound: Bool { binding == .contact }
    var isPaired: Bool {
        if case .paired = pairingState { return true }
        return false
    }
    /// The criterion for the "local encrypted channel" = the criterion under which the package's private-chat page allows sending a message, verbatim the same source: module 3 reports `.paired`
    /// or module 1 has this row (`peerIsPaired` at `PopopxMeshPrivateChatView.swift:314-317`).
    var hasEncryptedChannel: Bool { isBound || binding == .pending || isPaired }
}

// MARK: - The node table's single fold implementation

/// Module 4's table + the mirror's peers table + module 1's bindings + module 3's pairings, folded into one screen of values computed in one pass.
///
/// Extracted only for one discipline: **repo-wide there is one and only one fold implementation**. The drawer screen (`PopopxCabinView.refresh()`) and the root screen's
/// settings centre (`PopopxMeshPlazaRootView.refreshMeshSettingsFacts(waitingForSettle:)`, device round 10 moved the table
/// there) both read this very same `load()`, and nobody is allowed to assemble another copy — two tables whose numbers disagree is the most expensive kind of error on this page.
/// Called only in `.task` / `onChange` / after an action; never ask an actor inside `body`.
@MainActor
private enum PopopxCabinNodeFold {
    struct Reading {
        let radio: PopopxBluetoothState
        /// The master-switch state at the moment of folding. The caller has to decide, in that same instant, whether to clear its own table cell,
        /// and must not go back and ask `isFuseOn` after the await — if the switch flipped in between, the table and the criterion would be talking about two different moments.
        let fuseOn: Bool
        let nodes: [PopopxCabinNode]
        let requests: [PopopxPairingRequest]
    }

    /// The radio tier is read first and returned as soon as it is read: the settings centre's diagnostic cell has to state the current reading even while the master switch is closed, and must not be blocked by the
    /// empty table below. This hop only asks the actor for the value it already remembers; it does not wake Bluetooth up on anyone's behalf.
    /// The origin of `isUsable` is `BluetoothHealthMonitor.swift:207`, so one read serves two purposes,
    /// and the diagnostic row and the node rows necessarily speak about Bluetooth at the same moment.
    static func load() async -> Reading {
        let runtime = PopopxMeshRuntime.shared
        let radio = await runtime.healthMonitor.currentRadioState
        let fuseOn = runtime.isFuseOn
        guard fuseOn else {
            // The master switch is closed: no scanning, no broadcasting, no relaying, so these two cells can only be empty. Keeping the stale table would mean "looks like it is still alive".
            return Reading(radio: radio, fuseOn: false, nodes: [], requests: [])
        }
        let radioOn = radio.isUsable
        let observed = await runtime.healthMonitor.allNodes()
        let states = await runtime.pairing.allStates()
        let requests = await runtime.pairing.pendingRequests()
        let mappings = await runtime.mappingStore.allMappings()

        var pairingByHex: [String: MeshPairingState] = [:]
        pairingByHex.reserveCapacity(states.count)
        for entry in states { pairingByHex[entry.peerMeshPublicKeyHex] = entry.state }

        var bindingByHex: [String: PopopxCabinNode.Binding] = [:]
        bindingByHex.reserveCapacity(mappings.count)
        for row in mappings {
            if row.contactId != nil {
                bindingByHex[row.meshPublicKeyHex] = .contact
            } else if row.isPending {
                bindingByHex[row.meshPublicKeyHex] = .pending
            } else {
                bindingByHex[row.meshPublicKeyHex] = PopopxCabinNode.Binding.none
            }
        }

        // The mirror's peers table provides nickname and RSSI keyed by the 8-byte line id; module 4's table is the judge of hop count and being online.
        let mirrorPeers = PopopxMeshStateSource.shared.state.peers
        var peerByID: [String: PopopxMeshPeer] = [:]
        for peer in mirrorPeers { peerByID[peer.peerID.hex] = peer }

        let window = PopopxMeshConfig.default.peerReachabilityTimeout
        var built: [PopopxCabinNode] = []
        built.reserveCapacity(observed.count)
        for entry in observed {
            let peer = peerByID[entry.peerIDHex]
            let hex = entry.meshPublicKeyHex ?? peer?.meshPublicKey?.popopxHex
            built.append(
                PopopxCabinNode(
                    peerIDHex: entry.peerIDHex,
                    meshPublicKeyHex: hex,
                    nickname: peer?.nickname,
                    hopCount: entry.hopCount,
                    lastSeenAt: entry.lastSeenAt,
                    rssi: peer?.rssi,
                    isDirect: entry.isDirect,
                    isReachable: entry.isReachable(now: .now, radioOn: radioOn, timeout: window),
                    binding: hex.flatMap { bindingByHex[$0] } ?? PopopxCabinNode.Binding.none,
                    pairingState: hex.flatMap { pairingByHex[$0] } ?? .unlinked
                )
            )
        }
        // Neighbours that module 4 never recorded must still appear: the mirror's `peers` table is the truth of the connection layer. The online judgement uses exactly the same formula as the package's private-chat page's
        // `peerIsInRange` (`PopopxMeshPrivateChatView.swift:320-324`) — the radio usable,
        // and the silence not exceeding the same window; the hop count and silence duration are stated from the mirror's own readings (hopCount = 0 when this device holds the link).
        var listed: Set<String> = Set(observed.map(\.peerIDHex))
        for peer in mirrorPeers where !listed.contains(peer.peerID.hex) {
            listed.insert(peer.peerID.hex)
            let hex = peer.meshPublicKey?.popopxHex
            built.append(
                PopopxCabinNode(
                    peerIDHex: peer.peerID.hex,
                    meshPublicKeyHex: hex,
                    nickname: peer.nickname,
                    hopCount: peer.hopCount,
                    lastSeenAt: peer.lastSeenAt,
                    rssi: peer.rssi,
                    isDirect: peer.isDirect,
                    isReachable: radioOn && Date.now.timeIntervalSince(peer.lastSeenAt) <= window,
                    binding: hex.flatMap { bindingByHex[$0] } ?? PopopxCabinNode.Binding.none,
                    pairingState: hex.flatMap { pairingByHex[$0] } ?? .unlinked
                )
            )
        }
        return Reading(radio: radio, fuseOn: true, nodes: sortedForDisplay(built), requests: requests)
    }

    /// Ones that are online first, then ones with few hops, and finally by the time they were heard. The stale rows in `allNodes()` from before `sweep()` clears them do not
    /// disappear, so every row still has to pass `isReachable`, which says so plainly as "out of range" instead of pretending it is gone.
    private static func sortedForDisplay(_ nodes: [PopopxCabinNode]) -> [PopopxCabinNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isReachable != rhs.isReachable { return lhs.isReachable }
            if lhs.hopCount != rhs.hopCount { return lhs.hopCount < rhs.hopCount }
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.peerIDHex < rhs.peerIDHex
        }
    }
}

// MARK: - One speaker, two offline paths

/// What tapping a speaker's name does, written once.
///
/// Two screens offer it: the drawer's hall (`PopopxCabinHallView.authorControl`) and the package's plaza,
/// which cannot navigate the app's stack and so takes the actions from its host. This file's own comment
/// above `sendFriendRequest(to:)` states the rule that makes the extraction necessary: module 3's
/// `initiatePairing(with:incognito:)` is the only thing in the repo that can make an offline friendship
/// exist, and a second copy of everything wrapped around it — the fuse refusal, the missing-key refusal,
/// the receipts — is how two screens end up saying two different things about one peer. The host supplies
/// its stack, its toast and its spinner; nothing outside this enum decides anything.
@MainActor
enum PopopxCabinAuthor {
    /// Everything a host contributes besides the peer it was tapped on.
    struct Host {
        let runtime: PopopxMeshRuntime
        let toast: PopopxToastModel
        /// Push the package's private-chat page for a key this enum has just accepted. It has to be the
        /// host's own `path`: a `navigationDestination` registered on a stack this view does not hold
        /// pushes nothing, which is exactly the bug 2026-11-20's note at the top of this file records.
        let pushChat: (String) -> Void
        /// Re-read whatever the host derived from the pairing state, after the action lands. The drawer
        /// folds its node table here; a screen with no table of its own says so and passes nothing to do.
        let refresh: () async -> Void
        /// The host's "this row is working" marker, set once the guards have passed and cleared when the
        /// action returns. The drawer closes over the row id it was tapped from; the plaza renders no
        /// spinner on an author name, so it passes a pair that does nothing.
        let beginOpening: () -> Void
        let endOpening: () -> Void
    }

    /// One action in flight for the whole device, keyed by the public key it was asked for. Carried over
    /// from the drawer, which guarded on `openingNodeID == nil` before either body could run:
    /// `initiatePairing` refuses a peer it has already *paired* with, but not a second call for a peer
    /// still waiting for its first receipt, so a double tap floods twice and writes the binding twice.
    private static var openingHex: String?

    /// The drawer's node rows and the plaza's rows spell one peer the same way, because both call this:
    /// announced nickname → the public key abbreviated by the package's own rule → the 8-byte wire id's
    /// prefix. `nonisolated` so `PopopxCabinNode.label` can forward here without a hop.
    nonisolated static func label(nickname: String?, meshPublicKeyHex: String?, peerIDHex: String) -> String {
        if let nickname {
            let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        if let meshPublicKeyHex { return PopopxCabinLabel.abbreviate(meshPublicKeyHex) }
        return String(peerIDHex.prefix(8))
    }

    /// The full meaning of "tap to start Bluetooth private chat directly": first send one offline
    /// connection invitation through module 3 (the only action that can make a Noise private session
    /// exist), then push the package's private-chat page onto the stack. Every failure is spoken out in a
    /// plain sentence; only the two cases "this public key still cannot be parsed" and "the invitation
    /// link itself is not valid" do not enter the private-chat page — that page would hold nothing
    /// besides the failure notice.
    static func openChat(hex: String?, label: String, host: Host) async {
        guard let key = await accepted(hex: hex, label: label, host: host) else { return }
        defer { finish(host: host) }

        // Asked live rather than from a folded row: the plaza has no fold of its own, and a peer paired
        // since the last reading still must not be sent a second invitation.
        let pairingState = await host.runtime.pairing.state(for: key)
        if case .paired = pairingState {
            // Module 3 has already proven the pairing: do not resend an invitation (`initiatePairing`
            // throws `.alreadyPaired` for an already-paired peer), go straight into the session.
            host.pushChat(key)
            return
        }

        var refusedWithoutSession = false
        do {
            _ = try await host.runtime.pairing.initiatePairing(with: key, incognito: false)
            PopopxHaptics.notice(.success)
            host.toast.show(Copy.pairingSentToast(label), kind: .mesh)
        } catch let pairingError {
            PopopxHaptics.notice(.error)
            host.toast.show(Copy.pairingWords(for: pairingError, label: label), kind: .danger)
            switch pairingError {
            case .peerKeyRejected, .inviteLinkRejected:
                refusedWithoutSession = true
            case .alreadyPaired, .declinedRecently, .requestUnknown, .requestSuperseded,
                 .sendFailed, .offlineBridge, .mappingStoreFailed:
                // The session is still worth opening: the private-chat page re-reads the binding and the
                // pairing evidence itself, and spells out one by one why nothing can be sent.
                break
            }
        }
        await host.refresh()
        guard !refusedWithoutSession else { return }
        host.pushChat(key)
    }

    /// The second exit when a speaker's name is tapped: send only one offline connection invitation,
    /// without pushing the private-chat page onto the stack.
    static func sendFriendRequest(hex: String?, label: String, host: Host) async {
        guard let key = await accepted(hex: hex, label: label, host: host) else { return }
        defer { finish(host: host) }
        do {
            _ = try await host.runtime.pairing.initiatePairing(with: key, incognito: false)
            PopopxHaptics.notice(.success)
            host.toast.show(Copy.pairingSentToast(label), kind: .mesh)
        } catch let pairingError {
            PopopxHaptics.notice(.error)
            host.toast.show(Copy.pairingWords(for: pairingError, label: label), kind: .danger)
        }
        await host.refresh()
    }

    /// The plaza's author menu, using this file's existing three entries for its copy: the two titles and
    /// the reason both are greyed. No new sentence, so the two screens cannot drift apart.
    static func plazaActions(host: Host) -> [PopopxMeshPlazaAuthorAction] {
        [
            PopopxMeshPlazaAuthorAction(
                title: Copy.authorChat,
                isAvailable: { $0.meshPublicKeyHex != nil },
                unavailableReason: Copy.authorNoKey
            ) { post in
                Task { await openChat(hex: post.meshPublicKeyHex, label: plazaLabel(post), host: host) }
            },
            PopopxMeshPlazaAuthorAction(
                title: Copy.authorPair,
                isAvailable: { $0.meshPublicKeyHex != nil },
                unavailableReason: Copy.authorNoKey
            ) { post in
                Task { await sendFriendRequest(hex: post.meshPublicKeyHex, label: plazaLabel(post), host: host) }
            },
        ]
    }

    /// The package's one and only 1:1 offline private-chat surface, mounted from a runtime. Every host
    /// that pushes it goes through here, because three entry points written out three times are three
    /// chances to disagree about one page. All four dependencies are the runtime's real objects and not
    /// one default value: the defaults are `PopopxMeshEngine.shared` / `PopopxMeshKillSwitch.shared`,
    /// which would build the engine and the radio out on a machine whose master switch is closed (the red
    /// line in this file's header).
    @MainActor @ViewBuilder static func privateChatView(
        peerMeshPublicKeyHex: String,
        runtime: PopopxMeshRuntime
    ) -> some View {
        PopopxMeshPrivateChatView(
            peerMeshPublicKeyHex: peerMeshPublicKeyHex,
            outbound: runtime.engineBackend,
            source: runtime.stateSource,
            store: runtime.mappingStore,
            killSwitch: runtime.killSwitch
        )
        .navigationTitle(Copy.privateChatTitle)
    }

    /// A plaza row's name in this app's words, from the fields the row actually carries, through the one
    /// spelling above.
    private static func plazaLabel(_ post: PopopxMeshPlazaPost) -> String {
        guard case let .neighbour(nickname, peerIDHex) = post.author else { return post.displayName }
        return label(nickname: nickname, meshPublicKeyHex: post.meshPublicKeyHex, peerIDHex: peerIDHex)
    }

    /// The two refusals every author action shares, in the order the drawer has stated them since it was
    /// written: the fuse first (nothing goes out at all), then the key (this peer cannot be addressed).
    /// Returns the key to work with, or nil when the action was refused and the reason already spoken.
    private static func accepted(hex: String?, label: String, host: Host) async -> String? {
        guard host.runtime.isFuseOn else {
            PopopxHaptics.notice(.warning)
            host.toast.show(Copy.fuseOffToast, kind: .danger)
            return nil
        }
        guard let hex else {
            PopopxHaptics.notice(.warning)
            host.toast.show(Copy.noKeyToast(label), kind: .danger)
            return nil
        }
        guard openingHex == nil else { return nil }
        openingHex = hex
        host.beginOpening()
        return hex
    }

    private static func finish(host: Host) {
        openingHex = nil
        host.endOpening()
    }
}

/// The three hops on the root stack: the top-left "Groups" capsule → nearby Bluetooth Mesh groups; the
/// "pairing records" row in the settings centre → the package's pairing-records and offline-binding page;
/// and a tap on a plaza speaker's name → the package's 1:1 private chat for that peer's public key.
///
/// Deliberately does not reuse `PopopxCabinRoute`: the page inside the drawer must keep holding its own `path` (see criterion 4 of the view below —
/// the private-chat hop pushes a page after the offline connection invitation has been sent, the action is async, and only a path bound to its own stack can still push after that).
/// The root stack registers only these cells it actually goes to, and does not drag in the semantics of the drawer's five cases.
private enum PopopxMeshPlazaRoute: Hashable {
    case nearbyGroups
    case privacyRecords
    case privateChat(peerMeshPublicKeyHex: String)
}

// MARK: - Tab 3 root (full-screen plaza + the old panel inside a full-height drawer)

/// The landing page of Phase 4 Tab 3 "Cabin": you arrive straight into the package's full-screen `MeshPlazaView`, the old Cabin panel collapses into the
/// full-height drawer summoned by the middle capsule, and the offline mesh settings centre is placed directly by the top-right capsule **on this screen** (from device round 10
/// it no longer opens the drawer first and then the sheet), while the top-left is the back key to "Chat".
/// The type is written in this file rather than in a new one (iron rule: do not script `project.pbxproj`) — as with `PopopxCabinMeshSettingsSheet`
/// the same approach.
///
/// Four mounting criteria:
/// 1. The plaza gets two new parameters in its "home page" tier: `hidesTabBar: false` states that this screen's role is a home page and not a pushed page
///    (so leaving it does not `stop()`), and `keepsRunningWhenHidden: true` makes tab switching stop clearing the broadcast history —
///    `PopopxMeshPlazaModel.stop()` clears `posts` (package's `MeshPlazaView.swift:162-166`),
///    so what this device shouted out is not retracted just because someone tapped "Chat". ⚠️ From this round **the bottom four capsules still give way**, but not because these two parameters
///    requested it: hiding the bottom bar is declared by this view separately, on the root stack's screen content, with `.toolbar(.hidden, for: .tabBar)`
///    (see that section in `body`), and the package's `hidesTabBar` handles only the one question "is this screen a pushed page".
/// 2. The model is the runtime's one plaza mirror, passed through `MeshPlazaView(model:)`: that convenience
///    init would, on every body recompute, new a `PopopxMeshPlazaModel`, and `@ObservedObject` follows by
///    switching to the new one — the home page's body
///    recomputes more often than a pushed page does (opening the drawer once is twice), and swapping the model means the timeline becomes empty and nobody ever `start()`s it again.
///    `@StateObject` alone fixed only **this** screen: the two pushed plazas (`PopopxCabinRoute.plaza` and
///    `PopopxAddFriendRoute.meshPlaza`) kept building their own inside a `navigationDestination` builder and
///    had the same empty-square failure. One instance on `PopopxMeshRuntime` is what makes all three hold,
///    and it is on the fuse with them. The three dependencies are still given verbatim as
///    `PopopxMeshRuntime`'s real objects, and not one default value is used anywhere — the default value is
///    `PopopxMeshEngine.shared`, which would build out the engine and the radio even while the master switch is closed (the red line in the file header).
/// 3. No title is set: this bar's four slots are already standing full (two in the top-left + the teal capsule in the middle + one on the right), and on 393pt (iPhone 15
///    Pro) stacking a centred title on top of that is where truncation begins — the middle slot is this round's title position, occupied by the old Cabin panel's capsule.
///    The width accounting is written entry by entry above `meshDiscoveryEntry` (all four counted). This screen's name is stated by the bottom bar's "Cabin" and the list section header
///    `#mesh`; `Copy.plazaTitle` continues to be used at the `.plaza` site, so the two can never be two different screens.
/// 4. The page inside the drawer holds its own `NavigationStack(path:)` (decision 4 in the file header), so the whole block sits outside the root stack: mounted as a page of the root stack
///    it would either show two navigation bars, or make that file's four `path.append` calls all miss — the private-chat hop pushes a page after the offline
///    connection invitation is sent, the action is async, and only a `path` bound to its own stack can still push after that.
@MainActor
struct PopopxMeshPlazaRootView: View {
    @ObservedObject private var meshRuntime: PopopxMeshRuntime

    /// The binding of `MainTabView`'s selected tab, given by the host at the mount point (that tab in `MainTabView.swift`).
    /// After the top bar went full-screen immersive there is no cross-cutting navigation beneath this tab at all, and the only exit is the top-left back key — what it has to write
    /// is exactly this copy. Going through `@Binding` instead of inventing a new `@Observable` routing object injected into the environment: `MainTabView`'s
    /// `selection` already is that single source of truth (decision 3's `onChange(of: chatModel.chatId)` writes it too),
    /// and wrapping another layer would create a second holder; while a required init parameter ⇒ a host that forgets to mount it fails to compile outright, which is easier to find than "tapping does nothing"
    /// (the same reasoning as `PopopxSettingsNavTrack` deliberately having no default value).
    @Binding private var tabSelection: PopopxTab

    /// The old Cabin panel's full-height drawer (default detent = full screen, covering the bottom four capsules).
    @State private var showsCabinPanel = false
    /// The "Cabin offline mesh settings centre": the top-right capsule places this sheet directly on this screen, with the drawer no longer in between.
    @State private var showsMeshSettings = false
    // The nine numeric cells in the sheet. When the presenter moved to this screen, the reader moved to this screen with it — the duplicate entry in the drawer's top bar and its set of
    // readings were deleted together, and repo-wide there is still only one fold implementation: the node table goes through `PopopxCabinNodeFold` (the drawer screen reads the same
    // implementation), while the three identity cells and the verification are asked only during the stretch the sheet is open. Outside this view there is no second reader.
    @State private var meshSettingsNodes: [PopopxCabinNode] = []
    @State private var verifiedSnapshot: PopopxMeshActivitySnapshot?
    @State private var localKeyHex = ""
    @State private var bindingCount = 0
    @State private var queuedCount = 0
    /// The radio tier reported by module 4 itself; nil = this run has not read any value yet (we do not guess an "unknown" on its behalf to display).
    @State private var monitorRadioState: PopopxBluetoothState?
    /// The receipt of the wipe action (cleaned / a few items still not cleared) is spoken by this screen's toast, the same control as the drawer screen's.
    @State private var meshSettingsToast = PopopxToastModel()

    /// The cadence while the sheet is open. The tier uses the same 2 seconds as the drawer screen: module 4's silence window is 15 seconds, and once every 2 seconds is enough for
    /// readings like "last heard" not to lie, without turning the three actors' hops into dozens per second.
    private static let meshSettingsRefreshInterval: Duration = .seconds(2)

    /// The path of the page inside the drawer itself — the root stack does not borrow it; the reason is in the paragraph above `PopopxMeshPlazaRoute`.
    @State private var rootPath: [PopopxMeshPlazaRoute] = []

    @MainActor init(tabSelection: Binding<PopopxTab>) {
        _tabSelection = tabSelection
        _meshRuntime = ObservedObject(wrappedValue: PopopxMeshRuntime.shared)
    }

    /// This screen's half of the author menu. It owns the toast (the same model `.popopxToast` is
    /// attached to below) and the root stack's `path`, and has nothing to refresh: the plaza re-reads the
    /// mirror by itself, and the settings centre re-reads for as long as that sheet is on screen — an
    /// action taken from the plaza therefore cannot leave a stale reading anywhere on this tab.
    @MainActor private var authorHost: PopopxCabinAuthor.Host {
        PopopxCabinAuthor.Host(
            runtime: meshRuntime,
            toast: meshSettingsToast,
            pushChat: { rootPath.append(.privateChat(peerMeshPublicKeyHex: $0)) },
            refresh: {},
            beginOpening: {},
            endOpening: {}
        )
    }

    var body: some View {
        NavigationStack(path: $rootPath) {
            MeshPlazaView(
                model: meshRuntime.plazaModel,
                hidesTabBar: false,
                keepsRunningWhenHidden: true,
                authorActions: PopopxCabinAuthor.plazaActions(host: authorHost)
            )
            // The bottom matches the other two mount sites with the same sentence (`PopopxCabinView`'s `.plaza`, `PopopxAddFriendView.swift:127`):
            // the plaza carries no background of its own, so the host gives the grouped background once, and only then are the three screens the same piece of cloth.
            .modifier(ThemedBackground(grouped: true))
            // This round (device round 8): this tab is full-screen immersive — the bottom four capsules give way on the root screen, and the 49pt is returned to the content.
            // It is attached to the root stack's screen content rather than to `MainTabView`'s `TabView`, for two reasons:
            // ① the depth matches the device-verified site at `ChatsListView.swift:405` (same tab, same stack, same content layer)
            //    — the bottom bar's visibility is read by `TabView` from the preference bubbled up by the content subtree of **the tab it selects**, and writing it
            //    at `TabView`'s own layer is outside that read, i.e. a bet on an unverified behaviour;
            // ② declared at the content layer, "this screen is visible" is its validity window: when switching to another tab this screen stops being visible, the preference
            //    withdraws itself automatically, and the other three tabs' bar is not dragged away by this tab. Attaching it to `TabView` would mean computing a value from `selection`,
            //    which would then press down on the four per-page `.hidden` declarations at `ChatsListView.swift:268/275/285/405`.
            // `hidesTabBar: false` stays untouched: those two parameters speak about this screen's **role** in the package (home page ≠ a pushed
            // page, tab switching must not clear the broadcast stream), not about a bottom-bar switch; the bottom-bar cell is now asked to give way by the host itself. The two do not conflict
            // — the package's `meshHallTabBarHidden(_:)`, in its `false` branch, deliberately declares nothing and does not write
            // `.toolbar(.visible, for: .tabBar)` (`MeshPlazaView.swift:519-534`), precisely so as not to override
            // this sentence of the host's. The visibility overload itself exists from iOS 16 onwards and the app's floor is 17.0, so no gate is needed.
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                // Three segments: left = Discover (nearby offline groups) + back to "Chat", middle = the old Cabin panel (the nearby-node radar and the offline
                // group chats are both on that screen), right = the offline mesh settings centre. Toolbar items still belong only to the content layer that declares them, and the drawer
                // and every page it pushes have their own bars. The four capsules' width accounting is written entry by entry in the paragraph above `meshDiscoveryEntry`.
                ToolbarItem(placement: .topBarLeading) { meshDiscoveryEntry }
                ToolbarItem(placement: .topBarLeading) { backToChatsEntry }
                ToolbarItem(placement: .principal) { cabinPanelEntry }
                ToolbarItem(placement: .topBarTrailing) { meshSettingsEntry }
            }
            .navigationDestination(for: PopopxMeshPlazaRoute.self) { route in
                switch route {
                case .nearbyGroups:
                    // Verbatim identical to the drawer's `.groups` site (the registration of `PopopxCabinRoute.groups` in this file):
                    // the same `MeshGroupsView`, the same single model, the same title Key. Two entries cannot produce
                    // two different screens. The model comes from the runtime rather than being built here because this
                    // closure is a `navigationDestination` builder — building a model in it makes the parent's body recompute
                    // throw away the list and the subscription every couple of seconds.
                    MeshGroupsView(model: meshRuntime.groupsModel, keepsRunningWhenHidden: true)
                    .navigationTitle(Copy.groupsRow)

                case .privacyRecords:
                    // The destination of the settings centre's "pairing records" row: the package's one and only pairing-records and offline-binding page. All three objects
                    // come from the runtime, exactly the same set the drawer screen used to hand it; it carries no stack of its own, so it is wrapped
                    // at the root-stack level (`MeshPrivacySettingsView` is one whole `List`, with no `NavigationStack` of its own).
                    MeshPrivacySettingsView(
                        store: meshRuntime.mappingStore,
                        pairing: meshRuntime.pairing,
                        killSwitch: meshRuntime.killSwitch
                    )
                    .navigationTitle(Copy.privacyRecordsRow)
                    .modifier(ThemedBackground(grouped: true))

                case let .privateChat(peerMeshPublicKeyHex):
                    // Where a plaza author action lands. The same mount helper the drawer's own
                    // `.privateChat` uses, so the page pushed from the home tab and the page pushed from
                    // the drawer cannot be two different screens.
                    PopopxCabinAuthor.privateChatView(
                        peerMeshPublicKeyHex: peerMeshPublicKeyHex,
                        runtime: meshRuntime
                    )
                }
            }
            .popopxToast(meshSettingsToast)
            .sheet(isPresented: $showsCabinPanel) {
                PopopxCabinView(hostedAsCabinPanel: true)
                    .presentationDragIndicator(.visible)
            }
        }
        // The settings centre is mounted on this outer stack, and the drawer's sheet belongs to a separate content layer: each sheet presents its own,
        // so the limitation where only the first of two sheets presented in one transaction lands is never hit here.
        .sheet(isPresented: $showsMeshSettings) {
            PopopxCabinMeshSettingsSheet(
                fuseOn: meshRuntime.isFuseOn,
                pairingPolicy: meshRuntime.pairingPolicy,
                snapshot: verifiedSnapshot,
                radioState: monitorRadioState,
                nodes: meshSettingsNodes,
                localKeyHex: localKeyHex,
                bindingCount: bindingCount,
                queuedCount: queuedCount,
                onToggleFuse: { meshRuntime.requestFuse($0) },
                onSelectPolicy: { meshRuntime.setPairingPolicy($0) },
                onVerify: { await refreshMeshSettingsVerification(waitingForSettle: false) },
                onWipe: { await clearOfflineIdentity() },
                onOpenPrivacyRecords: {
                    // Dismiss the sheet first and then push: this row's destination is a page on the stack, not a second modal layer.
                    showsMeshSettings = false
                    rootPath.append(.privacyRecords)
                },
                onClose: { showsMeshSettings = false }
            )
        }
        // The nine-cell cadence runs only while the sheet is open: this tab lives long-term on `TabView`, and an unbounded poll would ask
        // the three actors once every 2 seconds. The single time the sheet comes up, verification is asked with a settle window (a snapshot taken during `starting`/`stopping`
        // speaks about "the previous moment"), and after that each tick asks only the present.
        .task(id: showsMeshSettings) {
            guard showsMeshSettings else { return }
            await refreshMeshSettingsFacts(waitingForSettle: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.meshSettingsRefreshInterval)
                if Task.isCancelled { break }
                await refreshMeshSettingsFacts(waitingForSettle: false)
            }
        }
        // Flipping the switch while the sheet is open: during those few hundred milliseconds the runtime state that is read most wants to tell the truth, so ask again with a settle window.
        .onChange(of: meshRuntime.isFuseOn) { _, _ in
            guard showsMeshSettings else { return }
            Task { @MainActor in await refreshMeshSettingsFacts(waitingForSettle: true) }
        }
    }

    // MARK: Facts for the settings centre

    /// The single fold for the nine numeric cells in the sheet: the node table (the three cells within range / via relay / farthest hops read it), the three identity cells, the real runtime state.
    /// Called only on the tick while the sheet is open and after flipping the switch or a wipe; `body` never asks an actor, not even once.
    @MainActor private func refreshMeshSettingsFacts(waitingForSettle: Bool) async {
        let reading = await PopopxCabinNodeFold.load()
        meshSettingsNodes = reading.nodes
        monitorRadioState = reading.radio
        await refreshMeshSettingsIdentityFacts()
        await refreshMeshSettingsVerification(waitingForSettle: waitingForSettle)
    }

    /// The settings centre's three identity fact cells: mapping-table row count, offline queue length, this device's mesh static public key. Three actor hops.
    @MainActor private func refreshMeshSettingsIdentityFacts() async {
        bindingCount = await meshRuntime.mappingStore.allMappings().count
        queuedCount = await meshRuntime.router.pendingMessageCount
        // When the engine never started this cell is an empty string (`PopopxMeshEngineBackend` does not build an engine for anyone), and an empty string is not
        // "the public key is gone" — it only means "this machine has not answered yet". So it is rewritten only when something real is read, and a wipe does not touch it either:
        // a wipe deletes module 1's mapping table and the cache files, while this device's own static key sits in another Keychain service
        // (`PopopxMeshEngine.swift:123-142`); deleting that would instead make the other side unable to recognise this machine next time.
        let hex = await meshRuntime.engineBackend.localMeshPublicKeyHex
        if !hex.isEmpty { localKeyHex = hex }
    }

    /// Verify the real runtime state once. With `waitingForSettle` the transitional state is given a waiting window of at most 5 × 250 ms.
    @MainActor private func refreshMeshSettingsVerification(waitingForSettle: Bool) async {
        var snapshot = await meshRuntime.killSwitch.verifiedActivitySnapshot()
        if waitingForSettle {
            for _ in 0..<5 where snapshot.phase == .starting || snapshot.phase == .stopping {
                try? await Task.sleep(for: .milliseconds(250))
                snapshot = await meshRuntime.killSwitch.verifiedActivitySnapshot()
            }
        }
        verifiedSnapshot = snapshot
    }

    /// Clear the offline identity bindings and this device's mesh cache. The one and only call is module 1's `emergencyWipeAllMappings()`:
    /// it clears the Keychain bindings row by row, deletes two switch preferences, and `removeMeshCacheFiles()` deletes every file in
    /// `Documents/popopx_mesh/` — the unacknowledged queue (`unacknowledged_mesh.json`),
    /// the outbox and this device's nickname are all in there. The package has no public API for "clearing only the queue", so this cell speaks about deleting the whole lot,
    /// and does not pretend that half of it can be deleted; if `failures` in the report is non-empty the count is reported as it is, never dressed up as "cleared clean".
    @MainActor private func clearOfflineIdentity() async {
        // The order follows the package's `MeshPrivacySettingsView.swift:214-217`: pull the switch first, then delete. The other way round lets the components still running
        // write the queue they hold back to disk, and then the "already cleared" cell would be a lie.
        if meshRuntime.isFuseOn { await meshRuntime.setFuse(false) }
        let report = await meshRuntime.mappingStore.emergencyWipeAllMappings()
        await refreshMeshSettingsFacts(waitingForSettle: true)
        if report.isClean {
            PopopxHaptics.notice(.success)
            meshSettingsToast.show(Copy.wipeCleanToast, kind: .mesh)
        } else {
            PopopxHaptics.notice(.error)
            meshSettingsToast.show(Copy.wipeFailedToast(report.failures.count), kind: .danger)
        }
    }

    // MARK: The three top-bar entries

    /// Top-left: back to the "Chat" tab. After this tab went full-screen immersive there is no cross-cutting navigation at the bottom of the screen, so this capsule is the only exit,
    /// and therefore it must always be present and be recognisable at a glance. Its drawing is the same tier as the drawer's dismiss key (`cabinPanelCloseEntry`): neutral background,
    /// icon only with no text — this bar's width accounting for the four capsules is written entry by entry above `meshDiscoveryEntry`, and the back key taking
    /// only 35pt comes from exactly that; giving it one more word would be a fourth truncation point. `chevron.left` is the system's direction word for "back",
    /// and VoiceOver reads the `.accessibilityLabel` sentence rather than the icon.
    private var backToChatsEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            tabSelection = .chats
        } label: {
            Image(systemName: "chevron.left")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.meshInk)
                .accessibilityHidden(true)
                .padding(.horizontal, PopopxMetrics.spaceS)
                .frame(minHeight: PopopxMetrics.minHitTarget)
                .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Text(Copy.backToMessages))
        .accessibilityIdentifier("popopx.cabin.backToChats")
    }

    /// The first capsule in the top-left: nearby Bluetooth Mesh groups.
    ///
    /// "Add friend → more ways → enter Cabin discovery, nearby groups/channels (BLE Mesh)" pushes the package's `MeshPlazaView`
    /// (`PopopxAddFriendView.swift:118-128`), and the root of this tab already is that screen (criterion 3), so pushing it once more from the root
    /// means pushing this very screen onto itself. So this capsule picks up the other half that entry lacks — groups: the same package
    /// `MeshGroupsView`, the same `Copy.groupsRow` title, the same three real dependencies as the row inside the drawer.
    ///
    /// Drawing: the same skeleton as this bar's other two capsules (`PopopxMetrics.radiusControl` background, `PopopxPressButtonStyle`,
    /// `contentShape`, `lineLimit(1)` + `minimumScaleFactor` + `PopopxMetrics.minHitTarget`), with the background swapped to
    /// the fainter teal `mesh.opacity(0.12)` + `meshInk` text (§"mesh must not carry text naked on its own": `mesh` on a white card
    /// is only 2.98:1, `meshInk` is 6.03:1). Deliberately not the middle capsule's solid teal — two identical teal capsules in one bar
    /// cannot be told apart at a glance as to which is the panel and which is the groups; the faint background drops it to the "secondary entry" tier, and the icon stays `person.3.fill`,
    /// the same mark and the same destination as the drawer content area's "offline group chat" row.
    ///
    /// This bar's width accounting (iPhone 15 Pro 393pt, default font size; the English word widths are typographic bounds measured string by string with CoreText on SF 15pt (= `PopopxType.meta`
    /// = `.subheadline`), the same font face on macOS/iOS, rounded; icons are estimated at
    /// `.caption` 12pt + `imageScale(.medium)`, with the tier between 11–20pt. The English tier = the worst of the four capsules).
    /// Available width = 393 − the navigation bar's left/right margins 16×2 = **361pt**, minus the ≈8pt gap between the two capsules of the same group
    /// ⇒ the ceiling for all four combined **≈353pt**:
    /// · this capsule: padding 8×2 = 16 + icon ≈ 20 + gap 4 + "Groups" 49.9 = **≈ 90pt**
    ///   (the zh tier of this Key already has a value in the catalogue: "Groups" 14.9 → ≈ 55pt);
    /// · `backToChatsEntry`: padding 12×2 = 24 + `chevron.left` ≈ 11 = **≈ 35pt**;
    /// · `cabinPanelEntry` (`.principal`): padding 8×2 = 16 + icon ≈ 13 + gap 4 + "Cabin" 39.5 = **≈ 73pt**
    ///   (the zh tier "Cabin" 29.8 → ≈ 63pt);
    /// · `meshSettingsEntry`: padding 12×2 = 24 + icon ≈ 15 + gap 4 + dot 8 + gap 4 + "Settings" 56.6
    ///   = **≈ 112pt** (the zh tier of this Key already has a value in the catalogue: "Settings" 29.8 → ≈ 85pt);
    /// · total 90 + 35 + 73 + 112 = **310pt**, plus that 8pt gap in the same group = **318 ≤ 361 ⇒ 43pt of slack (12%)**,
    ///   and that slack is what is left for Dynamic Type and the longest translations: one font size larger (about +20%) and the whole bar reaches 372pt,
    ///   crossing the line, so every one of the four capsules carries `lineLimit(1)` + `minimumScaleFactor(0.85)` — shrink the text first, then give way.
    /// The right-hand capsule was shortened this round from the offline mesh settings label (with "Offline mesh settings" measured at 145.8pt, that capsule alone would need 201pt) to
    /// "Settings": the whole bar was already eating 389pt, and without that change this top-left capsule's icon + word had nowhere to be placed.
    /// Not one word of the full statement is lost — a short word on the screen, and VoiceOver reads the complete
    /// "Offline mesh settings" sentence from `.accessibilityLabel`, while the sheet header `PopopxSheetContainer` still states the full sentence.
    /// `.fixedSize()` makes this capsule hold its intrinsic width when squeezed and lets `minimumScaleFactor` shrink the text first,
    /// and only when it cannot shrink further do the left and right give way; the destination has its own `.accessibilityHint`.
    private var meshDiscoveryEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            rootPath.append(.nearbyGroups)
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "person.3.fill")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                Text(Copy.groupsPill)
                    .font(PopopxType.meta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(PopopxPalette.meshInk)
            .padding(.horizontal, PopopxMetrics.spaceXS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(
                PopopxPalette.mesh.opacity(PopopxCabinBar.softTintOpacity),
                in: .rect(cornerRadius: PopopxMetrics.radiusControl)
            )
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
            .fixedSize()
        }
        .buttonStyle(PopopxPressButtonStyle())
        // What VoiceOver reads is the destination (`Copy.groupsRow` = the title of the screen being pushed itself), not the one short word on screen:
        // the capsule has only "Groups" left, so putting the full statement in the label keeps Apple's rule "the label must begin with the visible text" true as well.
        .accessibilityLabel(Text(Copy.groupsRow))
        .accessibilityHint(Text(Copy.meshGroupsHint))
        .accessibilityIdentifier("popopx.cabin.discovery")
    }

    /// Middle (`.principal`): the old Cabin panel — the nearby-node radar and the offline group chats are both on that screen. It used to stand in the top-left corner,
    /// and device round 8 gave the top-left to the back key and moved it to the middle, changing neither the teal nor the icon (the same entry changing place, not identity).
    /// This slot is this bar's "title position": the width accounting for all four capsules is written entry by entry above `meshDiscoveryEntry`, and this one takes 73pt.
    /// `.fixedSize()` makes it **shrink itself** rather than get snapped when squeezed: it holds its intrinsic width, and
    /// `minimumScaleFactor(0.85)` covers another layer (at large font sizes shrink the text first, and only then give way left and right).
    /// The full statement lives in `.accessibilityHint`, so VoiceOver does not have to squeeze it into this one word.
    private var cabinPanelEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            showsCabinPanel = true
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "square.grid.2x2")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                Text(Copy.tabTitle)
                    .font(PopopxType.meta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(PopopxPalette.onMesh)
            .padding(.horizontal, PopopxMetrics.spaceXS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
            .fixedSize()
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(Copy.cabinPanelEntryHint))
        .accessibilityIdentifier("popopx.cabin.panel")
    }

    /// Top-right: the offline mesh settings centre — this screen places `PopopxCabinMeshSettingsSheet` directly, without going through the drawer.
    /// That dot is runtime state, not decoration: while the fuse is closed it switches to the neutral colour, saying the same thing as the first card in the sheet.
    /// On screen there is only the one word "Settings" (width accounting above `meshDiscoveryEntry`); the full statement is in
    /// `.accessibilityLabel`, so VoiceOver and the sheet header both read the complete sentence.
    private var meshSettingsEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            showsMeshSettings = true
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "slider.horizontal.3")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.meshInk)
                    .accessibilityHidden(true)
                Circle()
                    .fill(meshRuntime.isFuseOn ? PopopxPalette.mesh : PopopxPalette.labelHint)
                    .frame(width: PopopxMetrics.spaceXS, height: PopopxMetrics.spaceXS)
                    .accessibilityHidden(true)
                Text(Copy.meshSettingsPill)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
            .fixedSize()
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Text(Copy.meshSettingsEntry))
        .accessibilityValue(Text(verbatim: meshRuntime.isFuseOn ? Copy.meshRowOn : Copy.meshRowFusedOff))
        .accessibilityIdentifier("popopx.cabin.root.meshSettings")
    }
}

// MARK: - Tab page

@MainActor
struct PopopxCabinView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// The fuse truth and the four actor handles all live on the runtime; `PopopxMeshStateSource` is the mirror singleton in the package.
    @ObservedObject private var meshRuntime: PopopxMeshRuntime
    @ObservedObject private var meshState: PopopxMeshStateSource

    @State private var toast = PopopxToastModel()
    @State private var path: [PopopxCabinRoute] = []
    @State private var nodes: [PopopxCabinNode] = []
    @State private var pendingRequests: [PopopxPairingRequest] = []
    /// Broadcasts sent by this device: the mesh does not echo flooding back to the sender, so this copy has to be kept by ourselves (the same inside the package).
    @State private var localBroadcasts: [PopopxMeshPlazaPost] = []
    @State private var nicknameText = ""
    @State private var showsPairingRequests = false
    /// The `peerIDHex` of the machine whose private chat is being opened: only that row shows progress, the whole page is not greyed out.
    @State private var openingNodeID: String?

    /// The offline groups this device has joined, from one local read of `PopopxGroupStore`. The group table on the top-bar "Discover" page and
    /// the numeric cell of the "offline group chat" row both read this copy; when the master switch is closed the engine never existed, so this is an empty table.
    @State private var groups: [PopopxMeshGroup] = []

    /// The polling cadence: module 4's silence window is 15 seconds, and once every 2 seconds is enough for readings like "last heard" not to lie,
    /// while not turning the three actors' hops into dozens per second.
    private static let refreshInterval: Duration = .seconds(2)

    /// How it is mounted: `true` = as the full-height drawer above the "Cabin" root. The top-left capsule then switches from "enter the plaza" to "dismiss the drawer"
    /// (`leadingBarEntry`), with every other row intact. `false` = standing alone as a page, i.e. the preview and the tier used before this round.
    private let hostedAsCabinPanel: Bool

    @MainActor init(hostedAsCabinPanel: Bool = false) {
        _meshRuntime = ObservedObject(wrappedValue: PopopxMeshRuntime.shared)
        _meshState = ObservedObject(wrappedValue: PopopxMeshStateSource.shared)
        self.hostedAsCabinPanel = hostedAsCabinPanel
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    header
                    statusCard
                    channelsCard
                    nearbyCard
                }
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.top, PopopxMetrics.spaceS)
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PopopxPalette.base)
            .navigationTitle(Copy.tabTitle)
            .toolbar {
                // Top-left = the plaza / dismiss the drawer, chosen by how it is mounted, and this bar has only that one capsule. The offline mesh settings centre is not
                // in this bar — it is placed directly by the root screen's top-right capsule (device round 10), and putting another capsule here would be two entries for the same
                // sheet. Toolbar items belong only to the content layer that declares them, so pushing the hall or the private-chat page hands the bar over to that page's own.
                ToolbarItem(placement: .topBarLeading) { leadingBarEntry }
            }
            .navigationDestination(for: PopopxCabinRoute.self) { route in
                switch route {
                case .hall:
                    PopopxCabinHallView(
                        fuseOn: meshRuntime.isFuseOn,
                        radioState: radioState,
                        nickname: $nicknameText,
                        posts: mergedBroadcastPosts,
                        nodes: nodes,
                        openingNodeID: openingNodeID,
                        directPeerCount: directPeerCount,
                        onBroadcast: { text in await sendBroadcast(text) },
                        onSaveNickname: { await saveNickname() },
                        onTurnOnFuse: {
                            await meshRuntime.setFuse(true)
                            await refresh()
                        },
                        onOpenChat: { node in await openBluetoothChat(with: node) },
                        onSendFriendRequest: { node in await sendFriendRequest(to: node) },
                        onRescan: { await refresh() }
                    )
                    .navigationTitle(Copy.hallRow)

                case .plaza:
                    // The top-left destination when the page stands alone (the drawer tier no longer gives it a loop back; see `leadingBarEntry`),
                    // kept because `PopopxCabinRoute.plaza` and this registration are one unit. This whole block is verbatim identical to
                    // `PopopxAddFriendView.swift:118-128`: the same `MeshPlazaView`, the same single plaza
                    // model taken from the runtime (never built here — see criterion 2 above `PopopxMeshPlazaRootView`), the same author menu, the same title Key,
                    // the same `ThemedBackground(grouped: true)`. `hidesTabBar` keeps its default because this screen **is** a pushed page; `keepsRunningWhenHidden: true`
                    // is not a per-screen choice any more, since the model is shared with the home tab and leaving this page must not
                    // empty the timeline that tab is showing. The two entries therefore cannot produce two different screens
                    // — that is exactly what device round 5 demanded.
                    MeshPlazaView(
                        model: meshRuntime.plazaModel,
                        keepsRunningWhenHidden: true,
                        authorActions: PopopxCabinAuthor.plazaActions(host: authorHost())
                    )
                    .navigationTitle(Copy.plazaTitle)
                    .modifier(ThemedBackground(grouped: true))

                case .encryptedChannels:
                    PopopxCabinChannelsView(
                        fuseOn: meshRuntime.isFuseOn,
                        nodes: nodes,
                        openingNodeID: openingNodeID,
                        pendingCount: pendingRequests.count,
                        onOpenChat: { node in await openBluetoothChat(with: node) },
                        onShowPending: { showsPairingRequests = true }
                    )
                    .navigationTitle(Copy.encryptedChannelsRow)

                case .groups:
                    // The package's one and only offline group-chat surface (groups with a creator signature + group messages),
                    // on the runtime's single model: the underlying dependencies are the real objects (`engineBackend`,
                    // `stateSource`), never the defaults — `PopopxMeshEngine.shared` would be built out even while the master
                    // switch is closed, and the red line does not allow it. `engineBackend` answers "no signing identity" when
                    // the engine never started, and then this page only shows an empty list without conjuring a group into existence.
                    MeshGroupsView(model: meshRuntime.groupsModel, keepsRunningWhenHidden: true)
                    .navigationTitle(Copy.groupsRow)

                case let .privateChat(peerMeshPublicKeyHex):
                    // The package's one and only 1:1 offline private-chat surface, through the one mount
                    // helper (its comment states why no dependency may take its default value). Same page
                    // the plaza's author action lands on from the home tab.
                    PopopxCabinAuthor.privateChatView(
                        peerMeshPublicKeyHex: peerMeshPublicKeyHex,
                        runtime: meshRuntime
                    )
                }
            }
            .sheet(isPresented: $showsPairingRequests) {
                PopopxCabinPairingRequestsSheet(
                    requests: pendingRequests,
                    nodes: nodes,
                    onApprove: { request in await approve(request) },
                    onDecline: { request in await decline(request) }
                )
            }
            .popopxToast(toast)
            .task {
                // Subscribe to the mirror only while the master switch is open: `PopopxMeshStateSource` is a component of the kill switch and is started and stopped by it;
                // this page calling `start()` in the closed state would leave a state of "the switch is closed but somebody is subscribing".
                if meshRuntime.isFuseOn { meshState.start() }
                nicknameText = currentNickname()
                await refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.refreshInterval)
                    if Task.isCancelled { break }
                    await refresh()
                }
            }
            // Recompute the moment the master switch flips: OFF has to clear the node table (module 4's table keeps stale data even after stop, and continuing to show it is a lie),
            // and ON has to subscribe and read once immediately, without waiting for the next 2 seconds.
            .onChange(of: meshRuntime.isFuseOn) { _, isOn in
                nicknameText = currentNickname()
                Task { @MainActor in
                    if isOn { meshState.start() }
                    await refresh()
                }
            }
            // Right after the radio flips the mirror holds only broadcasts, and reachability is not computed yet; add one actor read.
            .onChange(of: meshState.state.radioState) { _, _ in
                Task { @MainActor in await refresh() }
            }
        }
    }

    // MARK: The top-bar entry capsule

    /// This top-left capsule is chosen by how it is mounted, with position and size in the same tier and only the destination and colour changing: a drawer must not offer a loop back to
    /// "the screen that summoned it" (that screen is this tab's root), so the drawer tier switches it to dismiss.
    @ViewBuilder private var leadingBarEntry: some View {
        if hostedAsCabinPanel {
            cabinPanelCloseEntry
        } else {
            nearbyDiscoveryEntry
        }
    }

    /// The drawer's dismiss key. Neutral background: it is a navigation action, not a mesh fact, and teal is reserved for the content area's mesh-fact
    /// tier (§1.1). The drawer also has `.presentationDragIndicator(.visible)` and the swipe-down gesture as two escape routes.
    private var cabinPanelCloseEntry: some View {
        Button {
            PopopxHaptics.selection()
            dismiss()
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "xmark")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.meshInk)
                    .accessibilityHidden(true)
                Text(Copy.close)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityIdentifier("popopx.cabin.panelClose")
    }

    /// The top-left "Discover" when the page stands alone: the package's own Cabin nearby plaza, and "Add friend → enter Cabin discovery, nearby groups/channels"
    /// The same screen. Before device round 3 this capsule read "nearby Cabin plaza" and tapping it entered the hall; after the hall moved into a content-area row,
    /// this capsule was changed to open the plaza page instead. Round 5 removed this page's own "Discover" screen (the node radar + this device's groups, two cards): those two cards
    /// still exist everywhere they were — the radar is in the hall's top-right "discovery mode", the groups are in the content area's "offline group chat" row,
    /// and the plaza page itself has both the broadcast stream and the nearby nodes, so two entries should not give two destinations.
    /// From this round the root of this tab is directly that screen, so this capsule only appears when the page stands alone (the default mounting).
    private var nearbyDiscoveryEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            path.append(.plaza)
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "radar")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                Text(Copy.discoveryEntry)
                    .font(PopopxType.meta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(PopopxPalette.onMesh)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(Copy.plazaEntryHint))
        .accessibilityIdentifier("popopx.cabin.discovery")
    }

    // MARK: Derived facts (pure computation, does not touch actors)

    /// The hop ceiling: cites the `PopopxMeshConfig` constant instead of hard-coding 7 (§1.1 records exactly this origin).
    private var relayHopCap: Int { Int(PopopxMeshConfig.default.fragmentRelayTtlCap) }
    /// The TTL ceiling the broadcast actually uses, again a constant.
    private var broadcastTTL: Int { Int(PopopxMeshConfig.default.ttlDefault) }
    /// The silence window for the online judgement, module 4's same constant.
    private var reachabilityWindow: TimeInterval { PopopxMeshConfig.default.peerReachabilityTimeout }

    private var radioState: PopopxBluetoothState { meshState.state.radioState }
    private var radioUsable: Bool { meshState.state.radioState.isUsable }
    private var directPeerCount: Int { meshState.state.peers.filter(\.isDirect).count }

    /// The hall's one screen of stream: broadcasts received by the mesh + the echo of what this device sent, strictly deduplicated by the global `messageId`, oldest first.
    /// The field mapping is copied verbatim from `PopopxMeshPlazaModel.rebuildPosts(from:)`, and the dedup rule from `deduped(_:)`.
    private var mergedBroadcastPosts: [PopopxMeshPlazaPost] {
        var incoming: [PopopxMeshPlazaPost] = []
        incoming.reserveCapacity(meshState.state.broadcasts.count + localBroadcasts.count)
        for message in meshState.state.broadcasts where !message.isControlSignal {
            incoming.append(
                PopopxMeshPlazaPost(
                    id: message.messageID,
                    text: message.text,
                    timestamp: message.timestamp,
                    author: .neighbour(
                        nickname: message.senderNickname,
                        peerIDHex: message.senderPeerIDHex ?? message.messageID
                    ),
                    hopCount: message.channel.hopCount ?? 0
                )
            )
        }
        incoming.append(contentsOf: localBroadcasts)

        var seen: Set<String> = []
        var kept: [PopopxMeshPlazaPost] = []
        for post in incoming where seen.insert(post.id).inserted {
            kept.append(post)
        }
        return kept.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }

    // MARK: Top

    private var header: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(Copy.pageTitle)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.label)
            Text(Copy.pageExplainer(relayHopCap, broadcastTTL))
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The master switch + the radio + the time of the last broadcast heard within this device's range. All three rows are facts, with no decoration.
    private var statusCard: some View {
        PopopxSectionCard(
            Copy.statusTitle,
            footnote: meshRuntime.isFuseOn
                ? Copy.statusFootnote(Int(reachabilityWindow))
                : Copy.fuseOffFootnote
        ) {
            // No teal badge on this row: the switch fill of `PopopxToggleRow` is the brand (purple) hard-coded in the atomic library,
            // and purple and teal coexisting inside one control is a §1.1 violation. The mesh teal semantics speak in the two rows below and on the radar.
            PopopxToggleRow(
                Copy.fuseRowTitle,
                note: meshRuntime.isFuseOn ? Copy.fuseOnNote : Copy.fuseOffNote,
                isOn: fuseBinding
            )
            rowSeparator
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxIconBadgeView(
                    systemName: radioUsable ? "antenna.radiowaves.left.and.right" : "wifi.slash",
                    tint: radioUsable ? .mesh : .neutral
                )
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.radioWords(radioState))
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                    Text(radioFootnote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .padding(.vertical, PopopxMetrics.spaceXS)
            .popopxAnimation(PopopxSpring.fluid, value: radioState, reduceMotion: reduceMotion)
        }
    }

    private var radioFootnote: String {
        guard meshRuntime.isFuseOn else { return Copy.fuseOffRadioNote }
        guard let latest = meshState.state.latestBroadcastAt else { return Copy.noBroadcastYet }
        return Copy.lastBroadcastWords(PopopxCabinClock.since(latest))
    }

    /// The fuse has only one landing point: `killSwitch.setEnabled(_:)` (the `setFuse` at POPOPXAPI.swift:3883 is its only production caller).
    /// A Binding's setter cannot await, so the switch always goes through the synchronous `requestFuse(_:)` (:3771, which in turn starts a `setFuse`);
    /// while this page's two "turn on the master switch" buttons (:181, :417) are already inside an async context, so they `await setFuse(true)` directly and then refresh.
    /// Neither path writes `UserDefaults` from this page, otherwise we would get "the switch is closed but Bluetooth is still running", or the reverse.
    private var fuseBinding: Binding<Bool> {
        Binding(
            get: { meshRuntime.isFuseOn },
            set: { meshRuntime.requestFuse($0) }
        )
    }

    // MARK: The two channel entries

    private var channelsCard: some View {
        PopopxSectionCard(Copy.channelsTitle, footnote: Copy.channelsFootnote) {
            PopopxPickerRow(
                Copy.hallRow,
                value: hallRowValue,
                systemImage: "bubble.left.and.bubble.right.fill",
                tint: .mesh
            ) {
                path.append(.hall)
            }
            rowSeparator
            PopopxPickerRow(
                Copy.encryptedChannelsRow,
                value: Copy.encryptedChannelsValue(channelNodes.count),
                systemImage: "lock.circle.fill",
                tint: .mesh
            ) {
                path.append(.encryptedChannels)
            }
            rowSeparator
            // The offline group chat's numbers come only from one local read of `PopopxGroupStore`; when the master switch is closed the engine never existed, and that cell
            // states the existing "master switch closed" wording, without inventing a third way of saying it.
            PopopxPickerRow(
                Copy.groupsRow,
                value: meshRuntime.isFuseOn ? Copy.groupsValue(groups.count) : Copy.fuseOffValue,
                systemImage: "person.3.fill",
                tint: .mesh
            ) {
                path.append(.groups)
            }
        }
    }

    private var hallRowValue: String {
        guard meshRuntime.isFuseOn else { return Copy.fuseOffValue }
        let posts = mergedBroadcastPosts.count
        return posts == 0 ? Copy.hallEmpty : Copy.hallCount(posts)
    }

    private var channelNodes: [PopopxCabinNode] { nodes.filter(\.hasEncryptedChannel) }
    private var strangerNodes: [PopopxCabinNode] { nodes.filter { !$0.hasEncryptedChannel } }

    // MARK: Nearby nodes (this page's only 120% detail)

    /// This screen is handed over wholesale to `PopopxCabinNearbyCard`: what the hall's "discovery mode" mounts is the very same view with the very same `nodes`,
    /// and leaving a second implementation here would amount to allowing two places to say different things.
    private var nearbyCard: some View {
        PopopxCabinNearbyCard(
            nodes: nodes,
            fuseOn: meshRuntime.isFuseOn,
            radioState: radioState,
            directPeerCount: directPeerCount,
            openingNodeID: openingNodeID,
            onOpenChat: { node in await self.openBluetoothChat(with: node) },
            onRescan: { await refresh() },
            onTurnOnFuse: {
                await meshRuntime.setFuse(true)
                await refresh()
            }
        )
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }

    // MARK: - actor readings

    /// Fold the readings this screen needs into one screen of values. Called only in `.task` / `onChange` / after an action, never inside body.
    /// The node table and the pairing-request cells go through `PopopxCabinNodeFold` — the root screen's settings centre reads the very same fold,
    /// and repo-wide there is only this one (that screen asks for a few extra numbers besides `groups`, all on its own side).
    @MainActor private func refresh() async {
        let reading = await PopopxCabinNodeFold.load()
        nodes = reading.nodes
        pendingRequests = reading.requests
        // Master switch closed: no scanning, no broadcasting, no relaying, so this page must not keep any stale table that "looks like it is still alive" —
        // `load()` already answers with empty tables and empty requests in that case, and here we only fill in the one groups cell it does not handle.
        guard reading.fuseOn else {
            groups = []
            return
        }
        // The group count comes from one local read of `PopopxGroupStore` and does not touch the radio; when the engine never started the backend answers with an empty table directly,
        // so the 0 read in this cell is the same statement as "this phone has no groups yet".
        groups = await meshRuntime.engineBackend.meshGroups()
    }

    // MARK: - Actions

    /// Where a node row's or a hall bubble's tap lands. The deciding itself lives in `PopopxCabinAuthor`,
    /// written once for this drawer and for the plaza's injected menu; what stays here is only what belongs
    /// to this screen — the row that shows progress, and the stack this page pushes onto.
    @MainActor private func openBluetoothChat(with node: PopopxCabinNode) async {
        await PopopxCabinAuthor.openChat(hex: node.meshPublicKeyHex, label: node.label, host: authorHost(row: node.id))
    }

    /// The second exit of the same tap: send one offline connection invitation without pushing the
    /// private-chat page. Same core, same receipts, so the two cannot say two different things about
    /// one peer.
    @MainActor private func sendFriendRequest(to node: PopopxCabinNode) async {
        await PopopxCabinAuthor.sendFriendRequest(hex: node.meshPublicKeyHex, label: node.label, host: authorHost(row: node.id))
    }

    /// This screen's half of the author host. `row` is the node table id the tap came from, which is what
    /// the row's own progress marker is keyed by; a plaza row has no node-table identity to light, so those
    /// mounts pass nil and only the shared in-flight guard applies.
    @MainActor private func authorHost(row: String? = nil) -> PopopxCabinAuthor.Host {
        PopopxCabinAuthor.Host(
            runtime: meshRuntime,
            toast: toast,
            pushChat: { path.append(.privateChat(peerMeshPublicKeyHex: $0)) },
            refresh: { await self.refresh() },
            beginOpening: { openingNodeID = row },
            endOpening: { openingNodeID = nil }
        )
    }

    /// The hall's send. The semantics are copied verbatim from `PopopxMeshPlazaModel.broadcastDraft()`: truncate to the limit first,
    /// then, regardless of success or failure, this device keeps one row (flooding is not echoed back to the sender), while failure hands only one sentence back to the hall to display.
    @MainActor private func sendBroadcast(_ raw: String) async -> PopopxMeshSendFailure? {
        let text = String(raw.prefix(PopopxMeshPlazaModel.maxDraftCharacters))
        var failure: PopopxMeshSendFailure?
        do {
            try await meshRuntime.engineBackend.sendBroadcast(text: text)
        } catch let sendError {
            PopopxMeshLog.route.warning(
                "📡 Cabin hall broadcast rejected: \(String(describing: sendError.failure), privacy: .public)"
            )
            failure = sendError.failure
        }
        appendLocalBroadcast(text)
        return failure
    }

    private func appendLocalBroadcast(_ text: String) {
        guard !text.isEmpty else { return }
        var posts = localBroadcasts
        posts.append(
            PopopxMeshPlazaPost(
                id: "local:\(UUID().uuidString.lowercased())",
                text: text,
                timestamp: .now,
                author: .local,
                hopCount: 0
            )
        )
        // The limit is the same constant as the package's state mirror, and whatever exceeds it is dropped from the head.
        if posts.count > PopopxMeshStateSource.defaultCapacity {
            posts.removeFirst(posts.count - PopopxMeshStateSource.defaultCapacity)
        }
        localBroadcasts = posts
    }

    private func currentNickname() -> String {
        meshRuntime.killSwitch.nickname
            ?? PopopxMeshNicknameStore().read()
            ?? ""
    }

    /// The nickname's only write entry = the fuse switch itself (it clamps, writes the sandbox file, publishes `nickname`, and while open restarts this device's mesh along the way).
    @MainActor private func saveNickname() async {
        await meshRuntime.killSwitch.setNickname(nicknameText)
        nicknameText = currentNickname()
        PopopxHaptics.notice(.success)
        toast.show(Copy.nicknameSavedToast, kind: .mesh)
    }

    @MainActor private func approve(_ request: PopopxPairingRequest) async {
        let label = PopopxCabinLabel.abbreviate(request.peerMeshPublicKeyHex)
        do {
            _ = try await meshRuntime.pairing.approve(request, incognito: false)
            PopopxHaptics.notice(.success)
            toast.show(Copy.approveToast, kind: .mesh)
        } catch let pairingError {
            PopopxHaptics.notice(.error)
            toast.show(Copy.pairingWords(for: pairingError, label: label), kind: .danger)
        }
        await refresh()
    }

    @MainActor private func decline(_ request: PopopxPairingRequest) async {
        // `decline` does not throw: it only drops the request and records a 60-second cooldown (`ManualPairingManager.swift:232-238`).
        await meshRuntime.pairing.decline(request)
        PopopxHaptics.impact(.light)
        toast.show(Copy.declineToast, kind: .mesh)
        await refresh()
    }
}

// MARK: - The nearby-nodes screen (radar + per-device rows)

/// The whole "nearby active devices at 1–N hops" screen: the radar, the overflow note, the one real enable button when the master switch is closed, and the per-device rows.
///
/// It was extracted into one view instead of being written twice at two sites, for the sake of the hall's "discovery mode" — what it mounts is this very screen, and the node table is still
/// only the one folded by the host (`PopopxCabinNode`); the hall does not build a second list. The hop ceiling, TTL, silence window and dense-network
/// thresholds are these four `PopopxMeshConfig` constants, so the view cites them itself rather than taking numbers from callers (passing them would amount to allowing two places to pass them wrong).
@MainActor
private struct PopopxCabinNearbyCard: View {
    let nodes: [PopopxCabinNode]
    let fuseOn: Bool
    /// The radio tier is given by the host (the mirror's copy) and the singleton is not asked a second time here: if two places ask, there will be two moments when they say different things.
    let radioState: PopopxBluetoothState
    /// The direct-neighbour count is taken from the mirror's `peers` table (the truth of the connection layer), not from the node rows folded out of this table, so only the host can supply it.
    let directPeerCount: Int
    let openingNodeID: String?
    let onOpenChat: (PopopxCabinNode) async -> Void
    let onRescan: () async -> Void
    let onTurnOnFuse: () async -> Void

    /// The radar draws at most this many points on one screen; the extras are still listed in full in the rows below, not one of them hidden.
    static let markerLimit = 12

    private var radioUsable: Bool { radioState.isUsable }
    private var hopCap: Int { Int(PopopxMeshConfig.default.fragmentRelayTtlCap) }
    private var broadcastTTL: Int { Int(PopopxMeshConfig.default.ttlDefault) }
    private var denseHopCap: Int { Int(PopopxMeshConfig.default.denseBroadcastTtlCap) }
    private var highDegreeThreshold: Int { PopopxMeshConfig.default.highDegreeThreshold }
    private var reachabilityWindow: TimeInterval { PopopxMeshConfig.default.peerReachabilityTimeout }

    var body: some View {
        PopopxSectionCard(Copy.nearbyTitle(hopCap), footnote: footnote) {
            PopopxCabinRadar(
                nodes: nodes,
                hopCap: hopCap,
                markerLimit: Self.markerLimit,
                scanning: fuseOn && radioUsable
            )
            .padding(.bottom, nodes.count > Self.markerLimit ? PopopxMetrics.spaceXS : PopopxMetrics.spaceM)
            if nodes.count > Self.markerLimit {
                Text(Copy.radarOverflow(nodes.count, Self.markerLimit))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, PopopxMetrics.spaceXS)
            }

            if !fuseOn {
                // When the master switch is closed it says honestly that nothing is scanning: this screen is then left with one real, working enable button.
                PopopxButton(Copy.fuseTurnOn, systemImage: "antenna.radiowaves.left.and.right") {
                    await onTurnOnFuse()
                }
            } else if nodes.isEmpty {
                emptyBlock
            } else {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    PopopxCabinNodeRow(
                        node: node,
                        busy: openingNodeID == node.id,
                        open: { await onOpenChat(node) }
                    )
                    if index < nodes.count - 1 { rowSeparator }
                }
            }
        }
    }

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            Text(radioUsable ? Copy.nearbyEmptyScanning : Copy.radioWords(radioState))
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PopopxButton(Copy.rescan, systemImage: "arrow.clockwise", role: .secondary, fullWidth: false) {
                PopopxHaptics.impact(.light)
                await onRescan()
            }
        }
    }

    private var footnote: String {
        guard fuseOn else { return Copy.fuseOffFootnote }
        if directPeerCount > highDegreeThreshold {
            return Copy.denseNetworkNote(highDegreeThreshold, denseHopCap)
        }
        return Copy.nearbyFootnote(
            Int(reachabilityWindow),
            Int(PopopxMeshReachEstimate.metresPerHop),
            broadcastTTL,
            PopopxCabinClock.metres(PopopxMeshReachEstimate.metres(hops: broadcastTTL))
        )
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - The radar (this page's signature detail)

/// The concentric radar of nearby nodes. The static part is "rings + numeric hop counts", and the moving ring is only one teal pulse travelling from inside outwards.
/// Under Reduce Motion only the static rings and numbers are drawn, and not one looping animation starts (§5's explicit requirement for radar/pulse-type animations).
@MainActor
private struct PopopxCabinRadar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let nodes: [PopopxCabinNode]
    let hopCap: Int
    let markerLimit: Int
    let scanning: Bool

    @State private var pulseOutward = false

    /// The size is expressed only through tokens: one side = 48 × 3.
    private static let side: CGFloat = PopopxMetrics.space2XL * 3
    private static let dotSide: CGFloat = PopopxMetrics.spaceM + PopopxMetrics.space2XS

    var body: some View {
        ZStack {
            rings
            if scanning && !reduceMotion {
                pulse
            }
            markers
            core
        }
        .frame(width: Self.side, height: Self.side)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.radarLabel(onlineCount, nodes.count))
        .popopxAnimation(PopopxSpring.fluid, value: nodes.count, reduceMotion: reduceMotion)
        .onAppear { startPulse() }
        .onChange(of: scanning) { _, isScanning in
            if isScanning {
                startPulse()
            } else {
                pulseOutward = false
            }
        }
    }

    private var onlineCount: Int { nodes.filter(\.isReachable).count }
    private var shownNodes: [PopopxCabinNode] { Array(nodes.prefix(markerLimit)) }

    /// Three concentric rings: the line width uses §4's `stroke` (1.5pt), the further out the more solid, and the outermost ring is the hop-ceiling ring.
    private var rings: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .strokeBorder(
                        PopopxPalette.mesh.opacity(0.16 + Double(index) * 0.10),
                        lineWidth: PopopxMetrics.stroke
                    )
                    .padding(Self.side * (0.055 + 0.135 * CGFloat(2 - index)))
            }
        }
    }

    private var pulse: some View {
        Circle()
            .strokeBorder(PopopxPalette.mesh, lineWidth: PopopxMetrics.stroke)
            .scaleEffect(pulseOutward ? 1 : 0.18)
            .opacity(pulseOutward ? 0.06 : 0.6)
    }

    /// The point position is decided by only two real numbers: radius = hops / ceiling, angle = the index spread evenly. There is no fake data at all.
    private var markers: some View {
        ZStack {
            ForEach(Array(shownNodes.enumerated()), id: \.element.id) { index, node in
                marker(node: node, index: index)
            }
        }
    }

    /// Position is decided by only two real numbers: radius = hops / ceiling (the 0-hop device lands on the innermost ring), angle = the index spread evenly around the circle.
    /// Trigonometry is computed on `Double` throughout and then explicitly converted back to `CGFloat`: no implicit conversion is relied upon.
    private func marker(node: PopopxCabinNode, index: Int) -> some View {
        let hops = Double(min(max(node.hopCount, 0), max(hopCap, 1)))
        let radius = Double(Self.side / 2) * (0.18 + 0.74 * (hops / Double(max(hopCap, 1))))
        let degrees = Double(index) / Double(max(shownNodes.count, 1)) * 360 - 90
        let radians = degrees * .pi / 180
        return PopopxCabinHopDot(hops: node.hopCount, online: node.isReachable)
            .offset(
                x: CGFloat(radius * cos(radians)),
                y: CGFloat(radius * sin(radians))
            )
    }

    /// The centre is this device: the teal `meshInk` outline carries the semantics (this device is itself in the mesh), not SMP's purple.
    private var core: some View {
        ZStack {
            Circle()
                .fill(PopopxPalette.meshInk.opacity(0.16))
                .frame(
                    width: Self.dotSide + PopopxMetrics.spaceXS,
                    height: Self.dotSide + PopopxMetrics.spaceXS
                )
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.meshInk)
        }
    }

    private func startPulse() {
        guard scanning, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
            pulseOutward = true
        }
    }
}

/// Teal node dots always print the hop-count number (§1.4 rule 3): a dot that drops offline degrades to a grey ring, and the number is still there.
@MainActor
private struct PopopxCabinHopDot: View {
    let hops: Int
    let online: Bool

    var body: some View {
        Text("\(hops)")
            .font(PopopxType.metricSmall)
            .foregroundStyle(online ? PopopxPalette.onMesh : PopopxPalette.labelSecondary)
            .frame(width: PopopxMetrics.spaceM + PopopxMetrics.space2XS,
                   height: PopopxMetrics.spaceM + PopopxMetrics.space2XS)
            .background(online ? PopopxPalette.mesh : Color.clear, in: Circle())
            .overlay(
                Circle().strokeBorder(
                    online ? Color.clear : PopopxPalette.labelHint,
                    lineWidth: PopopxMetrics.stroke
                )
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Badges and node rows

/// The hop-count badge: solid `mesh` + `onMesh` digits, and it always carries the two words "N hops" (§2.2).
@MainActor
private struct PopopxCabinHopBadge: View {
    let hops: Int

    var body: some View {
        Text(Copy.hopsWords(hops))
            .font(PopopxType.metricSmall)
            .foregroundStyle(PopopxPalette.onMesh)
            .padding(.horizontal, PopopxMetrics.space2XS)
            .padding(.vertical, PopopxMetrics.space2XS / 2)
            .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            .accessibilityHidden(true)
    }
}

/// The relationship badge: it states only binding/pairing facts, always in neutral colours, and does not compete with the teal hop-count semantics for colour.
@MainActor
private struct PopopxCabinStateBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PopopxType.microTag)
            .foregroundStyle(PopopxPalette.labelSecondary)
            .padding(.horizontal, PopopxMetrics.space2XS)
            .padding(.vertical, PopopxMetrics.space2XS / 2)
            .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
    }
}

@MainActor
private struct PopopxCabinNodeRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: PopopxCabinNode
    let busy: Bool
    let open: () async -> Void

    var body: some View {
        Button(action: { Task { await open() } }) {
            HStack(spacing: PopopxMetrics.spaceS) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            node.isReachable ? PopopxPalette.mesh : PopopxPalette.labelHint,
                            lineWidth: PopopxMetrics.stroke
                        )
                        .frame(width: PopopxMetrics.spaceM, height: PopopxMetrics.spaceM)
                    if node.isReachable {
                        Circle()
                            .fill(PopopxPalette.mesh)
                            .frame(
                                width: PopopxMetrics.space2XS,
                                height: PopopxMetrics.space2XS
                            )
                    }
                }
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(node.label)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(1)
                    Text(detail)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                VStack(alignment: .trailing, spacing: PopopxMetrics.space2XS) {
                    PopopxCabinHopBadge(hops: node.hopCount)
                    if let relationshipWords {
                        PopopxCabinStateBadge(text: relationshipWords)
                    }
                }
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PopopxPalette.meshInk)
                } else {
                    Image(systemName: "chevron.right")
                        .font(PopopxType.microTag)
                        .imageScale(.medium)
                        .foregroundStyle(PopopxPalette.labelHint)
                }
            }
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(busy)
        .opacity(node.canOpenChat ? 1 : 0.72)
        .popopxAnimation(PopopxSpring.fluid, value: node.isReachable, reduceMotion: reduceMotion)
        .accessibilityLabel(Copy.rowLabel(node.label, detail, relationshipWords))
    }

    /// Every number in a row comes from module 4 or from the mirror: direct/relay, silence duration, RSSI, and unkind statements like "out of range".
    private var detail: String {
        var parts: [String] = [
            node.isDirect ? Copy.directLink : Copy.relayLink,
            Copy.lastSeenWords(node.lastSeenAt)
        ]
        if let rssi = node.rssi { parts.append(Copy.rssiWords(Int(rssi))) }
        if !node.isReachable { parts.append(Copy.outOfRangeMark) }
        if !node.canOpenChat { parts.append(Copy.noKeyMark) }
        return parts.joined(separator: " · ")
    }

    private var relationshipWords: String? {
        switch node.binding {
        case .contact: return Copy.boundBadge
        case .pending: return Copy.pendingBadge
        case .none:
            switch node.pairingState {
            case .unlinked: return nil
            case .requestSent, .requestReceived, .paired: return Copy.pairingStateWords(node.pairingState)
            }
        }
    }
}

// MARK: - #Cabin Hall

/// The whole "#Cabin Hall" screen: the complete broadcast stream + broadcast input + this device's temporary nickname. When the master switch is closed this screen is read-only,
/// and it offers one real enable button, without drawing any input field that looks as if it could send.
///
/// Two things live in this one page, and neither one builds a second copy of the data:
/// - the top-right "discovery mode" toggles the main page's `PopopxCabinNearbyCard` screen (the same view, the same `nodes`);
/// - the speaker name on a bubble is a `Menu`, whose two actions land on the existing `openBluetoothChat(with:)` and
///   `sendFriendRequest(to:)`, and the public-key conversion is recognised only in the node table's one copy (see `node(for:)`).
@MainActor
private struct PopopxCabinHallView: View {
    let fuseOn: Bool
    /// The whole tier is passed in rather than a `Bool`: the composer only asks "can I send", while the discovery-mode screen also has to be able to say "why it cannot".
    let radioState: PopopxBluetoothState
    @Binding var nickname: String
    let posts: [PopopxMeshPlazaPost]
    let nodes: [PopopxCabinNode]
    let openingNodeID: String?
    let directPeerCount: Int
    let onBroadcast: (String) async -> PopopxMeshSendFailure?
    let onSaveNickname: () async -> Void
    let onTurnOnFuse: () async -> Void
    let onOpenChat: (PopopxCabinNode) async -> Void
    let onSendFriendRequest: (PopopxCabinNode) async -> Void
    let onRescan: () async -> Void

    @State private var draft = ""
    /// The in-flight marker: during `send()` the draft stays in the box (a failure does not swallow the text), so the button has to close its own gate,
    /// and must not rely on `trimmedDraft` turning false — the latter drops the click one frame before the await.
    @State private var sending = false
    @State private var failureNote: String?
    /// Discovery mode defaults to collapsed: the hall is the place to talk, looking around is a separate matter, but one tap in the top-right brings it up.
    @State private var showsDiscovery = false

    private var radioUsable: Bool { radioState.isUsable }

    private var trimmedDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // The container structure is isomorphic to the real chat page: inside the `VStack(spacing: 0)` of `ChatView.swift:205` the message list is
        // the only flexible member and the input bar is the last one (the same file, `:237` mounts `ComposeView`, and `ComposeView.swift:595`
        // places `popopxComposerBar(...)` at the end of its own `VStack`). When the keyboard rises, SwiftUI pulls the safe area
        // upwards, the list shrinks by itself, and the input bar stays flush against the keyboard's top edge — the main chat page has fitted like that for years.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    if showsDiscovery {
                        PopopxCabinNearbyCard(
                            nodes: nodes,
                            fuseOn: fuseOn,
                            radioState: radioState,
                            directPeerCount: directPeerCount,
                            openingNodeID: openingNodeID,
                            onOpenChat: { node in await onOpenChat(node) },
                            onRescan: { await onRescan() },
                            onTurnOnFuse: { await onTurnOnFuse() }
                        )
                    }

                    PopopxSectionCard(Copy.hallChannel(posts.count), footnote: Copy.hallFootnote) {
                        feed
                    }

                    if fuseOn {
                        nicknameCard
                    } else {
                        PopopxSectionCard(Copy.fuseOffHeadline, footnote: Copy.fuseOffFootnote) {
                            PopopxButton(Copy.fuseTurnOn, systemImage: "antenna.radiowaves.left.and.right") {
                                await onTurnOnFuse()
                            }
                        }
                    }
                }
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.top, PopopxMetrics.spaceS)
                // The root cause in device round 6: the previous version attached the dismiss layer to `.background`, and that layer is only as large as the content `VStack`.
                // The blank lower half of the screen belongs to the `ScrollView` itself (`UIScrollView` hit-tests the whole viewport and
                // eats the tap), so the background layer cannot reach it; the padding inside a card is likewise eaten by `PopopxSectionCard`'s own rounded background.
                // So "tap the blank area" tapped nothing — it was not that the gesture was not installed, but that that region never belonged to this layer.
                // Now the content layer itself is stretched to fill the viewport (top-aligned, so with short content the blank below lands on this layer) and only then does `contentShape`
                // have something to hit; the dismiss action stays on this layer.
                // `.onTapGesture` rather than `.simultaneousGesture`: descendant controls hit first, so the nickname `Menu`
                // (`authorControl`) and the buttons inside cards behave as always, and there is no "opening the menu also dismissed the keyboard";
                // simultaneousGesture would trigger on exactly that nickname capsule, which is precisely the conflict to avoid.
                // Dismissing goes through `hideKeyboard()`: `PopopxTextArea`'s `@FocusState` is private to the control
                // (`Shared/Components/PopopxControls.swift:260`, `:272`, a red-line file we do not touch), so the host cannot get
                // that binding and can only go through the standard responder chain, the same call as the main chat page's `ChatView.swift:1099`.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { hideKeyboard() }
            }
            // Device round 9: the input bar changed from "the last member of the VStack" to sitting inside the safe area below the list. The previous version relied on SwiftUI
            // pushing the whole stack up when the keyboard rose — the hall is pushed from inside the drawer, and the drawer is itself mounted on a sheet layer (see
            // the `PopopxCabinMeshSettingsSheet` chain), and the fitting rules on the sheet side differ from those of the root stack, so in practice
            // "Broadcast" was left half covered by the keyboard. `.safeAreaInset` makes the input bar occupy the bottom safe-area region, and when the keyboard raises that region
            // it rises with it, the list shrinks by itself, and it is no longer coupled to "translate the whole stack".
            // `if fuseOn` stays inside the inset: when the fuse is broken this cell is empty, the inset takes no space, and the list still reaches the edge as usual.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if fuseOn {
                    VStack(spacing: 0) {
                        Divider()
                        composer
                    }
                }
            }
        }
        // Dragging the list dismisses the keyboard. The position follows the real chat page: attached to the whole content block rather than to some `ScrollView`
        // (`ChatView.swift:159`, which uses `.immediately` there; here `.interactively` is used as this round required,
        // so the keyboard follows the finger and only decides on release whether to dismiss or stay, the same tier as `PopopxCabinView`'s main page :388).
        // Tapping the blank area to dismiss sits alongside it: `hideKeyboard()` goes through UIKit's resignFirstResponder broadcast, holding no
        // and contending for no SwiftUI focus binding, so that upstream warning about "freezing when used together with `.focused`" does not apply here —
        // this page never had a second `.focused` from beginning to end.
        .scrollDismissesKeyboard(.interactively)
        // Entering the hall means this is the place to talk: the bottom four Tab capsules must give way entirely, and leaving this page back to the Cabin main page brings them back automatically.
        // The convention is the same as the site where the message page pushes `ChatView` (`ChatsListView.swift:405`) — it is declared on the layer
        // that got pushed, not declared on the list page; the main page does not attach it, so the main page's four capsules have always been fine.
        // From this round the hall is only pushed from inside the drawer, and the drawer already covers the whole bottom bar, so this sentence lands on nothing in that stack:
        // inert rather than harmful (the same judgement as the package's `meshHallTabBarHidden(_:)`), and it stays because this rule
        // only holds when declared "on the layer that got pushed"; removing it would amount to letting the next person who mounts the hall into the root stack miss it.
        // After device round 8 this sentence lands on even less: the root screen itself gives the bottom bar away, and the stack inside the drawer has above it
        // a region that never had a bottom bar in the first place.
        .toolbar(.hidden, for: .tabBar)
        .background(PopopxPalette.base)
        .toolbar {
            // Toolbar items follow "the content layer that declares them", so the main page's two entries do not follow into this layer, and this capsule does not
            // stay behind on the main page either — the same rule as the comment above `PopopxCabinView.meshSettingsEntry`.
            ToolbarItem(placement: .topBarTrailing) { discoveryEntry }
        }
    }

    /// The discovery-mode switch. The whole chip is the state itself: filled teal when on (a mesh fact), and only the outlined background colour when collapsed.
    private var discoveryEntry: some View {
        Button {
            PopopxHaptics.selection()
            showsDiscovery.toggle()
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "radar")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                Text(Copy.discoveryMode)
                    .font(PopopxType.meta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(showsDiscovery ? PopopxPalette.onMesh : PopopxPalette.meshInk)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(
                showsDiscovery ? PopopxPalette.mesh : PopopxPalette.card,
                in: .rect(cornerRadius: PopopxMetrics.radiusControl)
            )
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityValue(Text(verbatim: showsDiscovery ? Copy.switchOn : Copy.switchOff))
        .accessibilityHint(Text(verbatim: Copy.discoveryHint))
        .accessibilityIdentifier("popopx.cabin.hall.discovery")
    }

    @ViewBuilder private var feed: some View {
        if posts.isEmpty {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Text(Copy.hallEmptyHeadline)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Text(Copy.hallEmptyDetail)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PopopxMetrics.spaceXS)
        } else {
            let shown = Array(posts.suffix(60))
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, post in
                bubble(post)
                if index < shown.count - 1 { rowSeparator }
            }
        }
    }

    private func bubble(_ post: PopopxMeshPlazaPost) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                HStack(spacing: PopopxMetrics.space2XS) {
                    authorControl(post)
                    // Broadcasts sent by this device have no hop count to speak of; every received one must carry how many hops it travelled.
                    if case .neighbour = post.author {
                        PopopxCabinHopBadge(hops: post.hopCount)
                    }
                }
                Text(post.text)
                    .font(PopopxType.body)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                    // The whole bubble is still read in one pass — but the merge no longer hangs on the outermost layer: as soon as the outer layer `combine`s,
                    // the speaker button inside it is swallowed by the screen reader, and that name capsule is left with nothing but the word "button".
                    .accessibilityLabel(Copy.bubbleLabel(authorWords(post), post.text, post.hopCount))
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            Text(PopopxCabinClock.clock(post.timestamp))
                .font(PopopxType.metricSmall)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
        .padding(.vertical, PopopxMetrics.space2XS)
    }

    /// The speaker's name = the one entry point of this broadcast. There is nothing to attach on this device's own row, so only the neighbour's row is a control.
    /// Using `Menu` rather than a direct action: one and the same person has two paths (enter a private chat / send just one add-friend request), and you only know which one you want after tapping.
    /// When the public key cannot be parsed both actions are always `disabled` and the reason is written out, instead of pushing an empty page onto the stack.
    @ViewBuilder private func authorControl(_ post: PopopxMeshPlazaPost) -> some View {
        let name = authorWords(post)
        if case .neighbour = post.author {
            let node = node(for: post)
            Menu {
                if let node, node.canOpenChat {
                    Button(Copy.authorChat, systemImage: "lock.circle.fill") {
                        Task { await onOpenChat(node) }
                    }
                    Button(Copy.authorPair, systemImage: "person.badge.plus") {
                        Task { await onSendFriendRequest(node) }
                    }
                } else {
                    Text(Copy.authorNoKey)
                    Button(Copy.authorChat, systemImage: "lock.circle.fill") {}
                        .disabled(true)
                    Button(Copy.authorPair, systemImage: "person.badge.plus") {}
                        .disabled(true)
                }
            } label: {
                Text(name)
                    .font(PopopxType.meta)
                    .foregroundStyle(node?.canOpenChat == true ? PopopxPalette.meshInk : PopopxPalette.labelSecondary)
                    .frame(minHeight: PopopxMetrics.minHitTarget)
                    .contentShape(.rect(cornerRadius: PopopxMetrics.radiusChip))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityHint(Text(verbatim: Copy.authorMenuHint))
        } else {
            Text(name)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.label)
        }
    }

    /// A broadcast's author carries only the 8-byte line id, while both the private-chat and the pairing paths need the mesh public key. The conversion is recognised only in the node table's copy: it is
    /// the `PopopxCabinNode.meshPublicKeyHex` folded out of module 4's `allNodes()` and the mirror's `peers` table, the same source as the radar and
    /// the node rows. The package's `meshPublicKeyHex(forPeerIDHex:)` (`PopopxMeshEngine.swift:325`) lives
    /// on the actor `PopopxMeshEngine`, while the app side may only let `PopopxMeshEngineBackend` make that singleton exist
    /// (`POPOPXAPI.swift:3587`) — asking it once from this page would mean building an engine for machines whose master switch is closed.
    private func node(for post: PopopxMeshPlazaPost) -> PopopxCabinNode? {
        guard case let .neighbour(_, peerIDHex) = post.author else { return nil }
        return nodes.first { $0.peerIDHex == peerIDHex }
    }

    /// The package's `PopopxMeshPlazaPost.Author.displayName` is the English "You"; this page states its own Chinese wording separately.
    private func authorWords(_ post: PopopxMeshPlazaPost) -> String {
        switch post.author {
        case .local:
            return Copy.localAuthor
        case let .neighbour(nickname, peerIDHex):
            if let nickname {
                let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return clean }
            }
            return PopopxCabinLabel.abbreviate(peerIDHex)
        }
    }

    /// The broadcast input bar: the isomorphic twin of the real chat page's bottom bar (see the `VStack(spacing: 0)` comment inside `body`).
    /// One row = the input box + the "Broadcast" button, with no title and no footnote: the previous round's whole `PopopxSectionCard` had four layers — title,
    /// footnote, character count and the button row — and the moment the keyboard rose it pushed the bottom-most button row behind the keyboard, while what `ChatView.swift:237`
    /// mounts as `ComposeView`/`PopopxInputBar.swift:632-642` has always been only one horizontal row flush against the keyboard's top edge.
    /// Only the two rows that "must be said on the spot" are kept: the radio being unavailable, and the last send failing.
    private var composer: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            if !radioUsable {
                Text(Copy.composerRadioOff)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failureNote {
                Text(failureNote)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else if draft.count > PopopxMeshPlazaModel.maxDraftCharacters {
                // The character count appears only when out of bounds: keeping a count row permanently in the bottom bar spreads the burden of "an editor" onto every shout;
                // being over the limit is itself the thing that needs saying in advance (`send()` also refuses, but that hop you only learn after pressing the button).
                Text(Copy.draftCount(draft.count, PopopxMeshPlazaModel.maxDraftCharacters))
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.dangerInk)
            }
            HStack(alignment: .bottom, spacing: PopopxMetrics.spaceXS) {
                PopopxTextArea(Copy.composerField, prompt: Copy.composerPrompt, text: $draft)
                PopopxButton(Copy.broadcastSend, systemImage: "paperplane.fill", fullWidth: false) {
                    await send()
                }
                .disabled(!trimmedDraft || sending)
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.vertical, PopopxMetrics.spaceS)
        .background(PopopxPalette.base)
    }

    private var nicknameCard: some View {
        PopopxSectionCard(
            Copy.nicknameTitle,
            footnote: Copy.nicknameFootnote(
                PopopxMeshNicknameStore.defaultNickname,
                PopopxMeshNicknameStore.maxCharacters
            )
        ) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                PopopxTextField(
                    Copy.nicknameField,
                    prompt: Copy.nicknamePrompt,
                    text: $nickname,
                    systemImage: "person.text.rectangle"
                )
                PopopxButton(Copy.nicknameSave, role: .secondary, fullWidth: false) {
                    await onSaveNickname()
                }
            }
        }
    }

    /// Send: broadcast first, and clear the draft **only after success**; on failure the text just typed stays in the box, so changing one character is enough to resend.
    /// Reversing the order steps on two landmines at once: clearing before the await ⇒ `trimmedDraft` turns false in the same frame, and during the in-flight window the
    /// taps are swallowed by `.disabled` (not even a haptic); and the failure path would destroy the user's words while the neighbours'
    /// local broadcast bubbles are already stuck on screen (`appendLocalBroadcast`), leaving a message on the screen that nobody ever received.
    /// `sending` is necessary: the draft is now retained in flight, so `trimmedDraft` no longer closes the gate for us.
    @MainActor private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        let failure = await onBroadcast(text)
        if let failure {
            failureNote = Copy.broadcastWords(for: failure)
            PopopxHaptics.notice(.error)
        } else {
            draft = ""
            failureNote = nil
            PopopxHaptics.notice(.success)
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - Local encrypted channels

/// The 1:1 encrypted sessions this device has already established with Bluetooth neighbours. Unbound neighbours get a separate section, spelling out what tapping one will do.
@MainActor
private struct PopopxCabinChannelsView: View {
    let fuseOn: Bool
    let nodes: [PopopxCabinNode]
    let openingNodeID: String?
    let pendingCount: Int
    let onOpenChat: (PopopxCabinNode) async -> Void
    let onShowPending: () -> Void

    private var channels: [PopopxCabinNode] { nodes.filter(\.hasEncryptedChannel) }
    private var strangers: [PopopxCabinNode] { nodes.filter { !$0.hasEncryptedChannel } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                PopopxSectionCard(Copy.channelListTitle(channels.count), footnote: Copy.channelFootnote(fuseOn)) {
                    if channels.isEmpty {
                        Text(Copy.channelEmpty(fuseOn))
                            .font(PopopxType.meta)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, PopopxMetrics.spaceXS)
                    } else {
                        rows(channels)
                    }
                }

                if fuseOn, !strangers.isEmpty {
                    PopopxSectionCard(Copy.strangerTitle(strangers.count), footnote: Copy.strangerFootnote) {
                        rows(strangers)
                    }
                }

                PopopxSectionCard(Copy.pendingTitle, footnote: Copy.pendingFootnote) {
                    PopopxPickerRow(
                        Copy.pendingRow,
                        value: Copy.pendingValue(pendingCount),
                        systemImage: "envelope.badge.fill",
                        tint: .mesh,
                        action: onShowPending
                    )
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
    }

    private func rows(_ list: [PopopxCabinNode]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, node in
            PopopxCabinNodeRow(node: node, busy: openingNodeID == node.id) {
                await onOpenChat(node)
            }
            if index < list.count - 1 { rowSeparator }
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}


// MARK: - Connections awaiting a decision

/// Received connection requests: accept and decline both land straight on module 3's real methods, sharing the same state as the package's top banner,
/// so the decisions made in the two places are visible to each other.
@MainActor
private struct PopopxCabinPairingRequestsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let requests: [PopopxPairingRequest]
    let nodes: [PopopxCabinNode]
    let onApprove: (PopopxPairingRequest) async -> Void
    let onDecline: (PopopxPairingRequest) async -> Void

    var body: some View {
        PopopxSheetContainer(Copy.pendingSheetTitle, subtitle: Copy.pendingSheetSubtitle) {
            if requests.isEmpty {
                Text(Copy.pendingSheetEmpty)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(requests) { request in
                    PopopxSectionCard(
                        label(request),
                        footnote: Copy.pendingSince(PopopxCabinClock.since(request.receivedAt))
                    ) {
                        Text(Copy.pendingInviteHint)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: PopopxMetrics.spaceS) {
                            PopopxButton(Copy.approve, systemImage: "checkmark.seal.fill") {
                                await onApprove(request)
                            }
                            PopopxButton(Copy.decline, systemImage: "xmark.circle.fill", role: .secondary, fullWidth: false) {
                                await onDecline(request)
                            }
                        }
                        .padding(.top, PopopxMetrics.spaceS)
                    }
                }
            }
        } footer: {
            PopopxButton(Copy.close, role: .secondary) { dismiss() }
                .padding(PopopxMetrics.spaceM)
        }
        .presentationDragIndicator(.visible)
    }

    private func label(_ request: PopopxPairingRequest) -> String {
        if let node = nodes.first(where: { $0.meshPublicKeyHex == request.peerMeshPublicKeyHex }) {
            return node.label
        }
        return PopopxCabinLabel.abbreviate(request.peerMeshPublicKeyHex)
    }
}

// MARK: - Cabin offline mesh settings centre

/// The "Me" page's offline-mesh group and the "All settings" page's Cabin card are moved in here wholesale, and not one landing point changed its source:
/// master switch = `PopopxMeshRuntime.requestFuse(_:)`, pairing policy = `MeshPairingPolicy`'s two cases written through
/// `setPairingPolicy(_:)` into `IdentityMappingStore`, runtime state = `PopopxMeshKillSwitch.verifiedActivitySnapshot()`,
/// clearing = `IdentityMappingStore.emergencyWipeAllMappings()`, the pairing-records page = the package's `MeshPrivacySettingsView`
/// and its three runtime objects. This view only reads the facts the host has folded and only calls back; it never touches an actor itself — that way, while this card is open,
/// the page's 2-second cadence remains the only source of readings.
@MainActor
private struct PopopxCabinMeshSettingsSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let fuseOn: Bool
    let pairingPolicy: MeshPairingPolicy
    let snapshot: PopopxMeshActivitySnapshot?
    /// The radio tier reported by module 4 itself, read once every 2 seconds by the host; nil = this run has not read one yet (we do not guess a tier on its behalf).
    let radioState: PopopxBluetoothState?
    let nodes: [PopopxCabinNode]
    let localKeyHex: String
    let bindingCount: Int
    let queuedCount: Int
    let onToggleFuse: (Bool) -> Void
    let onSelectPolicy: (MeshPairingPolicy) -> Void
    let onVerify: () async -> Void
    let onWipe: () async -> Void
    let onOpenPrivacyRecords: () -> Void
    let onClose: () -> Void

    @State private var confirmsWipe = false

    var body: some View {
        PopopxSheetContainer(Copy.meshSettingsEntry, subtitle: Copy.sheetSubtitle) {
            switchCard
            identityCard
            dangerCard
        } footer: {
            PopopxButton(Copy.close, role: .secondary) { onClose() }
                .padding(PopopxMetrics.spaceM)
        }
        .presentationDragIndicator(.visible)
        .confirmationDialog(Copy.wipeQuestion, isPresented: $confirmsWipe, titleVisibility: .visible) {
            Button(Copy.wipeAction, role: .destructive) {
                confirmsWipe = false
                Task { @MainActor in await onWipe() }
            }
            Button(Copy.cancel, role: .cancel) { confirmsWipe = false }
        } message: {
            Text(Copy.wipeDetail)
        }
    }

    // MARK: Card 1 · master switch and pairing policy

    private var switchCard: some View {
        PopopxSectionCard(Copy.cardSwitch, footnote: Copy.meshFootnote) {
            // This row likewise gets no teal badge: the switch fill of `PopopxToggleRow` is the brand purple hard-coded in the atomic library,
            // and purple plus teal inside the same control is a §1.1 violation (the same reason as that row of this page's status card).
            // The subtitle rewrites itself with the fuse, and that is the wording the Cabin card on the "All settings" page originally had: while the switch is closed, saying "scanning, broadcasting and
            // relaying are all running" would be lying. No sentence needs to be said statically twice — the static one is already in this card's footnote.
            PopopxToggleRow(
                Copy.fuseRow,
                note: fuseOn ? Copy.fuseRowNoteOn : Copy.fuseRowNoteOff,
                isOn: Binding(get: { fuseOn }, set: { onToggleFuse($0) })
            )
            // The switch's receipt belongs to the caller: the atomic library's `Toggle` carries no haptics, and flipping a switch is an action that must have feel.
            .onChange(of: fuseOn) { _, _ in PopopxHaptics.selection() }
            rowSeparator
            // This row already carried the "which tier is current" value cell in the settings tree, and when it was consolidated in the first round it was inlined into a radio group,
            // so that value cell and its own explanation sentence both dropped out. The radio group stays inlined (this layer is already a sheet, so do not open another layer),
            // and the value plus the explanation are added back here.
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
                Text(Copy.pairingPolicy)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Text(policyTitle(pairingPolicy))
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .lineLimit(1)
            }
            Text(Copy.pairingSheetSubtitle)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, PopopxMetrics.space2XS)
            // Enumerate only the two cases `MeshPairingPolicy` actually has (IdentityMappingStore.swift:27-33);
            // an inlined radio group rather than opening another sheet: this layer already is a sheet.
            ForEach(Array(MeshPairingPolicy.allCases.enumerated()), id: \.element) { _, policy in
                PopopxRadioRow(
                    policyTitle(policy),
                    note: policyNote(policy),
                    selected: pairingPolicy == policy
                ) {
                    PopopxHaptics.selection()
                    onSelectPolicy(policy)
                }
            }
            rowSeparator
            // The entry to the pairing-records page — the one row the first round missed outright. The state word at the end of the row is that cell it already had back then,
            // and both entries reuse the same Keys already published on the "Me" page, so this row needs no newly written sentence.
            PopopxPickerRow(
                Copy.privacyRecordsRow,
                value: fuseOn ? Copy.meshRowOn : Copy.meshRowFusedOff,
                systemImage: "lock.shield.fill",
                tint: .mesh,
                action: onOpenPrivacyRecords
            )
        }
        // This flip of the switch rewrites three pieces of text and the row-end labels inside this card; under Reduce Motion they land directly with no transition.
        // This is the binding the "All settings" card originally had, and the first migration left it outside the door.
        .popopxAnimation(PopopxSpring.fluid, value: fuseOn, reduceMotion: reduceMotion)
    }

    // MARK: Card 2 · node identity and real runtime state

    private var identityCard: some View {
        PopopxSectionCard(Copy.cardIdentity, footnote: Copy.keyFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(Copy.localKeyRow)
                    .font(PopopxType.body)
                    .foregroundStyle(PopopxPalette.label)
                // The whole 64-bit hexadecimal string is written out as it is and stays selectable: a fingerprint has to be portable to another channel for comparison,
                // and an abbreviated string cannot be compared against anything. An empty string means "this machine has never run Cabin", not "the key is lost".
                Text(localKeyHex.isEmpty ? Copy.localKeyAbsent : localKeyHex)
                    .font(PopopxType.metric)
                    .foregroundStyle(localKeyHex.isEmpty ? PopopxPalette.labelHint : PopopxPalette.labelSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PopopxMetrics.space2XS)
            .accessibilityElement(children: .combine)
            rowSeparator
            // The five rows of numbers are one and the same ledger, so no separator lines are drawn inside the row; lines are drawn only between the hexadecimal string above and the verification block below.
            VStack(spacing: PopopxMetrics.space2XS) {
                factRow(Copy.bindingRow, "\(bindingCount)")
                factRow(Copy.queueRow, "\(queuedCount)")
                factRow(Copy.inReachRow, "\(onlineCount) / \(nodes.count)")
                factRow(Copy.relayRow, "\(relayedCount)")
                factRow(Copy.farthestRow, "\(farthestHop) / \(relayHopCap)")
            }
            .padding(.vertical, PopopxMetrics.space2XS)
            rowSeparator
            radioDiagnosisRow
            rowSeparator
            verificationBlock
        }
    }

    // MARK: Radio and permissions diagnostic (the only row added this round)

    /// This row is a button only when the tier lands on `unauthorized`/`poweredOff`: in those two cases the system settings really do have one item to change.
    /// Giving it a tappable entry while the tier is healthy would only send people to a settings page with nothing to move, so that cell
    /// honestly stays "not tappable". The reading has a single source — module 4's own `currentRadioState`,
    /// the same reading as the top-bar capsule (`PopopxTelemetryHeader.swift:177`), and the tier wording reuses
    /// `PopopxDualStatusCapsule.words(for:)`（`PopopxTelemetryHeader.swift:391`）。
    @ViewBuilder private var radioDiagnosisRow: some View {
        let state = radioState
        let needsSettings = state == .unauthorized || state == .poweredOff
        HStack(spacing: PopopxMetrics.spaceS) {
            PopopxIconBadgeView(
                systemName: needsSettings ? "wifi.slash" : "antenna.radiowaves.left.and.right",
                tint: needsSettings ? .neutral : .mesh
            )
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(Copy.radioDiagnosisRow)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Text(radioDiagnosisNote(state))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PopopxMetrics.spaceXS)
            if needsSettings {
                Button {
                    PopopxHaptics.impact(.light)
                    UIApplication.shared.open(appSettingsURL)
                } label: {
                    Text(Copy.radioOpenSettings)
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.meshInk)
                        .padding(.horizontal, PopopxMetrics.spaceS)
                        .frame(minHeight: PopopxMetrics.minHitTarget)
                        .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                        .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
                }
                .buttonStyle(PopopxPressButtonStyle())
                .accessibilityIdentifier("popopx.cabin.mesh.openSettings")
            } else {
                // The non-tappable cell only speaks and does not pose as a control: one tier and no chevron. The tick is given only to the tier that "really is healthy" —
                // drawing a tick for `unknown` would be saying "not read yet" as "read, and it is fine".
                VStack(alignment: .trailing, spacing: PopopxMetrics.space2XS) {
                    Text(verbatim: radioDiagnosisWords(state))
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .lineLimit(1)
                    if state == .poweredOn {
                        Image(systemName: "checkmark.circle.fill")
                            .font(PopopxType.microTag)
                            .imageScale(.medium)
                            .foregroundStyle(PopopxPalette.meshInk)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: PopopxMetrics.minHitTarget)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PopopxMetrics.space2XS)
        .popopxAnimation(PopopxSpring.fluid, value: state, reduceMotion: reduceMotion)
    }

    /// The two words naming the tier cite the top-bar capsule's word table directly; a third way of saying anything is not invented here.
    private func radioDiagnosisWords(_ state: PopopxBluetoothState?) -> String {
        guard let state else { return Copy.radioUnknown }
        return PopopxDualStatusCapsule.words(for: state)
    }

    /// Three honest sentences: healthy, needing a change in the system settings, and "this run has not read any value yet". That last tier must exist,
    /// because while the master switch is closed module 4 receives no radio events at all and that cell can only stay on the value it last read — saying "unknown"
    /// is more honest than inventing a "Bluetooth is off" for it.
    private func radioDiagnosisNote(_ state: PopopxBluetoothState?) -> String {
        switch state {
        case nil: return Copy.radioDiagnosisPending
        case .unauthorized: return Copy.radioDiagnosisUnauthorized
        case .poweredOff: return Copy.radioDiagnosisPoweredOff
        case .poweredOn: return Copy.radioDiagnosisHealthy
        case .unknown, .resetting, .unsupported: return Copy.radioDiagnosisQuiet
        }
    }

    /// Within range / via relay / farthest hops: all computed on the spot from the `PopopxCabinNode` the page has already folded, without asking any actor again.
    /// The criterion is exactly the same one used by this page's radar and node rows (`isReachable` is module 4's `PopopxPeerReachability` conclusion).
    private var onlineCount: Int { nodes.filter(\.isReachable).count }
    private var relayedCount: Int { nodes.filter { $0.isReachable && !$0.isDirect }.count }
    private var farthestHop: Int { nodes.filter(\.isReachable).map(\.hopCount).max() ?? 0 }
    /// The hop ceiling cites the configuration constant instead of hard-coding 7 (the same origin as this page's `relayHopCap`).
    private var relayHopCap: Int { Int(PopopxMeshConfig.default.fragmentRelayTtlCap) }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            Text(title)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.label)
            Spacer(minLength: PopopxMetrics.spaceXS)
            Text(value)
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
    }

    /// The fuse switch only expresses "intent". This block writes the runtime state: phase, the number of Bluetooth/interface components actually running, the number of event subscriptions,
    /// all from `PopopxMeshKillSwitch.verifiedActivitySnapshot()` (the one authoritative answer in the package).
    /// Taken over verbatim from the block that used to sit on the "Me" page; neither the source of facts nor the wording changed.
    private var verificationBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "waveform.path")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.meshInk)
                    .accessibilityHidden(true)
                Text(Copy.verifyHeadline)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                PopopxButton(Copy.verifyAgain, systemImage: "arrow.clockwise", role: .ghost, fullWidth: false) {
                    await onVerify()
                }
            }
            Text(verifiedSentence)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PopopxMetrics.space2XS)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Copy.verifyHeadline))
    }

    /// The relation between what the switch says and Bluetooth's real state is spelled out entirely here: better to write "still running" than to dress it up.
    private var verifiedSentence: String {
        guard let snapshot else { return Copy.verifyPending }
        var text: String
        switch snapshot.phase {
        case .off: text = Copy.phaseOff
        case .starting: text = Copy.phaseStarting
        case .on: text = Copy.phaseOn
        case .stopping: text = Copy.phaseStopping
        }
        if snapshot.isActive {
            text += String(
                format: Copy.busySuffixFormat,
                snapshot.runningRadioWork.count,
                snapshot.runningInterfaceWork.count
            )
        } else {
            text += Copy.quietSuffix
        }
        if let subscribers = snapshot.eventHubSubscribers {
            text += String(format: Copy.subscribersSuffixFormat, subscribers)
        }
        // The on-disk switch saying "on" while the phase is not on (or the reverse) is a start/stop that did not complete, and it may also be a crash in the middle.
        if snapshot.persistedSwitch != (snapshot.phase == .on) {
            text += Copy.mismatchSuffix
        }
        return text
    }

    // MARK: Card 3 · offline data and clearing

    private var dangerCard: some View {
        PopopxSectionCard(Copy.cardDanger, footnote: Copy.wipeDetail) {
            // The button does one thing only: raise the second confirmation. The deletion is executed by the host afterwards, and the result is spoken by the host's toast.
            // Nothing like "cleared" is written here, and nothing is said when the user cancels; that green receipt from `PopopxButton` is given by the atomic library as
            // "this async action finished" (a red-line file, unchangeable), and it is covered by the confirmation dialog raised in the same frame.
            PopopxButton(Copy.wipeAction, systemImage: "trash", role: .destructive) {
                confirmsWipe = true
            }
        }
    }

    // MARK: Policy copy

    private func policyTitle(_ policy: MeshPairingPolicy) -> String {
        switch policy {
        case .manualConfirm: return Copy.policyManual
        case .autoSilent: return Copy.policyAuto
        }
    }

    private func policyNote(_ policy: MeshPairingPolicy) -> String {
        switch policy {
        case .manualConfirm: return Copy.policyManualNote
        case .autoSilent: return Copy.policyAutoNote
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - Time

/// Time has only two forms: the `HH:mm` on a bubble (the template matches the package's plaza) and the relative time in explanatory rows.
private enum PopopxCabinClock {
    /// A formatter is built fresh each time: `DateFormatter` is not `Sendable`, and the package's `MeshPlazaView.clock(_:)`
    /// (`MeshPlazaView.swift:451-456`) is written the same way, and this page does not turn it into a static stored property.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }

    private static func dated(_ date: Date) -> String {
        let formatter = DateFormatter()
        // The template is always written as a locale-neutral Unicode pattern (`MMM d HH:mm`), and for the Chinese tier
        // `setLocalizedDateFormatFromTemplate` arranges the order itself. What used to be written here directly was
        // a `"M<month>d<day> HH:mm"` pattern: to ICU those month and day characters are literals, so the English tier emitted them as Chinese as well.
        formatter.setLocalizedDateFormatFromTemplate("MMM d HH:mm")
        return formatter.string(from: date)
    }

    static func since(_ date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return Copy.justNow
        case ..<60: return Copy.secondsAgo(seconds)
        case ..<3_600: return Copy.minutesAgo(seconds / 60)
        case ..<86_400: return Copy.hoursAgo(seconds / 3_600)
        default: return dated(date)
        }
    }

    /// Say the metres once: above a kilometre the unit switches, using the same boundary as the package's `PopopxMeshReachEstimate.radius`.
    static func metres(_ value: Int) -> String {
        value >= 1_000 ? Copy.kilometresWords(Double(value) / 1_000) : Copy.metresWords(value)
    }
}

// MARK: - Icon badge

/// `PopopxIconBadge` is a `private` type at `PopopxControls.swift:315` and cannot be reached outside that file;
/// The same set of tokens is replicated here verbatim (32pt square / `radiusChip` / `microTag` + `imageScale(.medium)` / `.ink`),
/// and no third way of drawing it is established.
@MainActor
private struct PopopxIconBadgeView: View {
    let systemName: String
    let tint: PopopxIconTint

    var body: some View {
        Image(systemName: systemName)
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(tint.ink)
            .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
            .background(tint.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            .accessibilityHidden(true)
    }
}

// MARK: - Copy

/// Every user-visible sentence on this page appears exactly once, here; the source text is an English original and the original is the Key (the convention is in the `key(_:)`
/// section below). Every failure path has an honest sentence, exhausting all cases of the three enums.
///
/// Sentences carrying numbers always go through `String(format:)`. Where the parameter order and the sentence order differ (`pageExplainer`, `radarLabel`
/// and a few other places) the placeholders are written positionally as `%1$lld` / `%2$lld`, so a translation that moves a number elsewhere changes only the index, never the count;
/// where the orders agree, plain `%lld` / `%@` is written, under the same convention as `PopopxTelemetryHeader.swift:625`.
private enum Copy {
    static let tabTitle = key("Cabin")
    static let pageTitle = key("Cabin · Local Bluetooth")

    static func pageExplainer(_ hopCap: Int, _ ttl: Int) -> String {
        String(format: key("Everything on this page is inside this device's Bluetooth reach: broadcasts spread unencrypted through the Cabin hall, while private chat runs over the encrypted Noise link with a neighbour. A broadcast travels at most %2$lld hops, relaying caps at %1$lld hops, and none of it crosses the public internet."), hopCap, ttl)
    }

    static let statusTitle = key("Master switch and radio")
    static let fuseRowTitle = key("Cabin offline mesh")
    static let fuseOnNote = key("When it is open this device scans, advertises itself and relays for other devices")
    static let fuseOffNote = key("When it is closed there is no scanning, no advertising and no relaying, and every number below is empty")
    static let fuseOffFootnote = key("The master switch is closed: this device has not sent a single byte over Bluetooth.")
    static let fuseOffRadioNote = key("While the master switch is closed the radio is never started, so this row has no reading.")
    static let fuseOffValue = key("Master switch closed")
    static let fuseTurnOn = key("Turn on Cabin")
    static let noBroadcastYet = key("No broadcast has been heard within this device's reach yet.")
    static func lastBroadcastWords(_ words: String) -> String { String(format: key("Last broadcast heard: %@"), words) }
    static func statusFootnote(_ window: Int) -> String {
        String(format: key("Online means this device heard from that device within the last %lld seconds. The master switch row only names where its truth comes from; this page keeps no state of its own."), window)
    }

    static let channelsTitle = key("Channels")
    static let channelsFootnote = key("The hall is an unencrypted flood; a local encrypted channel is the Noise link between this device and one neighbour. Neither of them goes through a server.")
    static let hallRow = key("#Cabin Hall")
    static let hallEmpty = key("No broadcasts yet")
    static func hallCount(_ posts: Int) -> String { String(format: key("%lld broadcasts"), posts) }
    static let encryptedChannelsRow = key("Local encrypted channels")
    static func encryptedChannelsValue(_ count: Int) -> String { String(format: key("%lld established"), count) }

    static func nearbyTitle(_ hopCap: Int) -> String { String(format: key("Active devices within 1–%lld hops"), hopCap) }
    static func nearbyFootnote(_ window: Int, _ metresPerHop: Int, _ ttl: Int, _ radius: String) -> String {
        String(format: key("Hops = the limit set when the frame was sent minus the value left when it was received; %1$lld seconds of silence counts as offline. One ring assumes about %2$lld metres per hop, so %3$lld hops reach roughly %4$@."), window, metresPerHop, ttl, radius)
    }
    static func denseNetworkNote(_ threshold: Int, _ cap: Int) -> String {
        String(format: key("More than %1$lld direct neighbours: the broadcast hop cap tightens itself to %2$lld hops, and the covered area shrinks with it."), threshold, cap)
    }
    static let nearbyEmptyScanning = key("There is nothing to hear inside this reach right now. Walk closer to a device that has Cabin switched on, then scan again.")
    static let rescan = key("Scan again")
    static func radarLabel(_ online: Int, _ total: Int) -> String {
        String(format: key("Radar: %2$lld devices known, %1$lld of them online. The number inside each dot is that device's hop count."), online, total)
    }

    static let directLink = key("Direct")
    static let relayLink = key("Relayed")
    static func lastSeenWords(_ date: Date) -> String { String(format: key("Last heard %@"), PopopxCabinClock.since(date)) }
    static func rssiWords(_ value: Int) -> String { "\(value) dBm" }
    /// The four tiers of relative time. `PopopxCabinClock.since(_:)` is their only caller: that is a pure static utility which cannot reach
    /// `Text` and can only take an already-translated string, so the sentences are written here and it picks the tier.
    static let justNow = key("just now")
    static func secondsAgo(_ seconds: Int) -> String { String(format: key("%lld seconds ago"), seconds) }
    static func minutesAgo(_ minutes: Int) -> String { String(format: key("%lld minutes ago"), minutes) }
    static func hoursAgo(_ hours: Int) -> String { String(format: key("%lld hours ago"), hours) }
    /// The two distance tiers: the boundary is the same one as the package's `PopopxMeshReachEstimate.radius` (above a kilometre the unit switches).
    static func metresWords(_ value: Int) -> String { String(format: key("%lld metres"), value) }
    static func kilometresWords(_ value: Double) -> String { String(format: key("%.1f kilometres"), value) }
    static let outOfRangeMark = key("Out of reach")
    static let noKeyMark = key("Key not resolved")
    static let boundBadge = key("Bound")
    static let pendingBadge = key("Pending")

    static let privateChatTitle = key("Bluetooth private chat")

    // The hall screen
    static func hallChannel(_ posts: Int) -> String { String(format: key("#Cabin Hall · %lld posts"), posts) }
    static let hallFootnote = key("The flood is not encrypted and not acknowledged, and it never leaves Bluetooth reach; the same text relayed by several devices is still shown once.")
    static let hallEmptyHeadline = key("Nobody has spoken inside this reach yet.")
    static let hallEmptyDetail = key("Anything sent here floods only to devices on the same mesh. It does not go through a server and it never stays on the public internet.")
    static let localAuthor = key("This device")
    static let composerField = key("Broadcast text")
    static let composerPrompt = key("Say something; it goes only to devices inside Bluetooth reach")
    static let broadcastSend = key("Broadcast")
    /// The bottom bar keeps only this one short hint: the previous version's title and footnote (`shout to everyone in this room` / `whatever passes N characters is truncated…`)
    /// were withdrawn together with the whole card, and the fact "flooding is not acknowledged" has been in `hallFootnote` on the screen above all along.
    static let composerRadioOff = key("The radio is not usable right now")
    static func draftCount(_ current: Int, _ limit: Int) -> String { "\(current) / \(limit)" }
    static let fuseOffHeadline = key("The master switch is closed, so the hall is read-only")

    static let nicknameTitle = key("This device's temporary nickname")
    static let nicknameField = key("Nickname")
    static let nicknamePrompt = key("The name shown on this device's broadcast bubbles")
    static let nicknameSave = key("Save")
    static func nicknameFootnote(_ fallback: String, _ limit: Int) -> String {
        String(format: key("It lives in the mesh sandbox folder and it is not a key; leave it empty to fall back to %@, and keep it under %lld characters. Changing it restarts the mesh on this device."), fallback, limit)
    }
    /// The badge always carries the number (§1.4 rule 3); 0 hops means this device holds the link, so "direct" is written out too.
    static func hopsWords(_ hops: Int) -> String { hops == 0 ? key("0 hops · direct") : String(format: key("%lld hops"), hops) }
    static func radarOverflow(_ total: Int, _ drawn: Int) -> String {
        String(format: key("The radar draws only %2$lld dots on this screen; the %1$lld rows below still list every one of them."), total, drawn)
    }
    static func bubbleLabel(_ author: String, _ text: String, _ hops: Int) -> String {
        String(format: key("%1$@, received on hop %2$lld: %3$@"), author, hops, text)
    }

    // The speaker menu on a hall bubble. Keyed since device round 2 on 2026-11-20: these four are actions added in this round, and red line four requires
    // new copy to land in every language, so they no longer take the file header's exemption "the remaining literals on this page are Phase 4 Chinese written directly".
    static let authorChat = key("Initiate an offline Bluetooth chat")
    static let authorPair = key("Send a face-to-face or offline friend request")
    /// The tier that carries only the line id with the public key not yet parsed: both actions are disabled, and this sentence is the reason.
    static let authorNoKey = key("This device has not resolved this peer's mesh key yet; both actions need it first")
    static let authorMenuHint = key("Open this person's offline actions")

    // The local encrypted channel
    static func channelListTitle(_ count: Int) -> String { String(format: key("Private chats established · %lld"), count) }
    static func channelFootnote(_ fuseOn: Bool) -> String {
        fuseOn
            ? key("One channel = this device has a row for it in the binding table, or the pairing state reports paired. Tap a row to go straight into the Bluetooth private chat.")
            : key("While the master switch is closed the binding table is not read and no channel is listed.")
    }
    /// The `1–7` in the original text was a second copy of the number transcribed from `nearbyTitle(hopCap)`: change the hop ceiling and it starts lying,
    /// and this screen cannot reach hopCap. Name the identifier, do not copy the number.
    static func channelEmpty(_ fuseOn: Bool) -> String {
        fuseOn
            ? key("This device has no encrypted channel with any Bluetooth neighbour yet. Tap a device in the nearby list and it sends an offline pairing invitation first.")
            : key("The master switch is closed, so this page has no session that could be opened.")
    }
    static func strangerTitle(_ count: Int) -> String { String(format: key("Unbound neighbours · %lld"), count) }
    static let strangerFootnote = key("These devices were only heard inside reach and there is no contact behind them yet; tapping a row first sends an offline pairing invitation, then opens the private chat page.")
    static let pendingTitle = key("Pairing invitations waiting for your decision")
    static let pendingRow = key("Pairing requests received")
    static func pendingValue(_ count: Int) -> String { count == 0 ? key("None") : String(format: key("%lld waiting"), count) }
    static let pendingFootnote = key("This reads the same pairing state as the banner at the top of the page, so the two places see each other's decision.")
    /// The same Key as `pendingRow` (the two places were the identical sentence in the original text), not a second entry.
    static let pendingSheetTitle = key("Pairing requests received")
    static let pendingSheetSubtitle = key("Accepting is what binds this mesh key as an offline contact; declining keeps this device quiet about the peer for 60 seconds.")
    static let pendingSheetEmpty = key("Nothing is waiting for your decision right now.")
    static let pendingInviteHint = key("Accept takes the invitation link and binds the peer's mesh key; decline only drops the request and deletes no existing contact.")
    static func pendingSince(_ words: String) -> String { String(format: key("Received %@"), words) }
    static let approve = key("Accept")
    static let decline = key("Decline")
    static let close = key("Close")
    static let approveToast = key("Pairing accepted; the peer is now an offline contact")
    static let declineToast = key("This pairing request was declined")

    // Action receipts
    static func pairingSentToast(_ label: String) -> String { String(format: key("Offline pairing invitation sent to %@"), label) }
    static func noKeyToast(_ label: String) -> String { String(format: key("%@ has no resolved mesh key yet, so this device cannot start a private chat with it"), label) }
    static let fuseOffToast = key("The Cabin master switch is closed, so nothing goes out over Bluetooth")
    static let nicknameSavedToast = key("The nickname was written into this device's mesh sandbox")

    /// The VoiceOver line concatenates three existing statements, and the concatenation itself is a sentence too: the separator is left to the translations, and a full-width comma is not hard-written.
    static func rowLabel(_ name: String, _ detail: String, _ relationship: String?) -> String {
        if let relationship { return String(format: key("%1$@, %2$@, %3$@"), name, detail, relationship) }
        return String(format: key("%1$@, %2$@"), name, detail)
    }

    /// The six radio states, exhausting `PopopxBluetoothState`.
    static func radioWords(_ state: PopopxBluetoothState) -> String {
        switch state {
        case .unknown: return key("Bluetooth status unknown")
        case .resetting: return key("Bluetooth is resetting")
        case .unsupported: return key("This device has no usable Bluetooth mesh")
        case .unauthorized: return key("Bluetooth permission is not granted")
        case .poweredOff: return key("Bluetooth is switched off")
        case .poweredOn: return key("Bluetooth is on and listening inside reach")
        }
    }

    /// The four pairing states, exhausting `MeshPairingState`.
    static func pairingStateWords(_ state: MeshPairingState) -> String {
        switch state {
        case .unlinked: return key("Not paired")
        case .requestSent: return key("Invitation sent, waiting for the peer to accept")
        case .requestReceived: return key("The peer is asking to pair")
        case .paired: return key("Paired")
        }
    }

    /// The six flooding failure states, exhausting `PopopxMeshSendFailure` (the package's `MeshPlazaView.words(for:)` is internal,
    /// and this place cannot reach it, but it still states the same batch of facts).
    static func broadcastWords(for failure: PopopxMeshSendFailure) -> String {
        switch failure {
        case .noLinkToPeer: return key("No link to use: no device inside reach picked this broadcast up")
        case .linkDropped: return key("The link dropped: the content never made it onto Bluetooth")
        case .ttlExhausted: return key("Hops exhausted: this broadcast spent its whole hop limit before any device picked it up")
        case let .oversized(payloadBytes, limitBytes):
            return String(format: key("Over the single-frame limit (%1$lld > %2$lld bytes), so this content was not sent in fragments."), payloadBytes, limitBytes)
        case .noSessionWithPeer: return key("There is no encrypted session with this device yet, so the private message cannot go out")
        case let .radioUnavailable(state): return String(format: key("The radio is not usable: %@"), radioWords(state))
        }
    }

    /// All nine connection states are given an exit, exhausting `PopopxPairingError`. `requestUnknown` / `requestSuperseded` are thrown only by
    /// `approve` (`ManualPairingManager.swift:192-218`), and the invitation-sending path only ever meets the first seven.
    static func pairingWords(for error: PopopxPairingError, label: String) -> String {
        switch error {
        case .peerKeyRejected:
            return key("This mesh key is not valid; this device will not send anything to it")
        case .alreadyPaired:
            return String(format: key("%@ is already a bound contact, so just open the private chat"), label)
        case .declinedRecently:
            return String(format: key("A pairing invitation to %@ was declined just now, and the 60 second cooldown blocks another one"), label)
        case .requestUnknown:
            return key("This request is no longer on the waiting list")
        case .requestSuperseded:
            return key("The peer replaced this invitation with a new link, so the old one is not bound")
        case .inviteLinkRejected:
            return key("The invitation link does not match this device's offline gate format, and it was dropped")
        case let .sendFailed(failure):
            return String(format: key("The invitation was created but never made it onto Bluetooth: %@"), broadcastWords(for: failure))
        case let .offlineBridge(reason):
            return String(format: key("This device could not create the offline invitation: %@"), reason)
        case let .mappingStoreFailed(reason):
            return String(format: key("Writing the binding table failed: %@. The session exists, but this device cannot yet tell whose it is"), reason)
        }
    }

    // MARK: Top-bar entries and the offline mesh settings centre
    //
    // The section above was still hard-written Chinese literals before this round (the Phase 4 way of writing), and now the whole section is turned into Keys: this screen's
    // source text and Key are the same sentence, and no Chinese character remains on the screen (the conventions are the two in the file header). From here on it is the entries added
    // in earlier rounds plus the settings centre, whose writing was already Keys. `en.lproj` is not written by convention (a missing entry falls back to the Key itself, which is English).
    // The rows migrated wholesale from the "Me" page deliberately reuse the same Keys the "Me" page published long ago: one Key whose wording is decided by the translation already in
    // the catalogue means the two places always say the same sentence, and that is the only way this migration can guarantee "the row removed and the row left behind state the same thing".
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX cabin offline mesh settings")
    }

    /// The top-left capsule of the top bar. Since device round 3 on 2026-11-20 it is no longer the hall; since round 5 it enters the package's plaza page.
    /// The old hint sentence (`Lists the devices within Bluetooth reach…`, which described that screen's two cards) has 0 Swift references,
    /// and was deleted from the 16 catalogues in this round; the three discovery-page entries (create-group entry, member count, group footnote) were deleted in the same batch.
    static let discoveryEntry = key("Discover")
    static let plazaEntryHint = key("Opens the nearby square: the broadcast stream and the nodes within Bluetooth reach")
    /// The top-left capsule on the "Cabin" root screen: only two characters on its face (the panel's name is this tab's name, reusing `Copy.tabTitle`
    /// instead of inventing a third way of saying it), and this sentence spells out what it actually opens. The drawer's dismiss key likewise uses only the existing "Close".
    /// Brand words write Cabin in English per the existing convention: from round 10 the Chinese tab name no longer appears in the source text of any Key — with Chinese inside a Key,
    /// the `en` tier reads characters that were never translated, and nobody in the 16 catalogues can write a translation against a Key that mixes two languages.
    /// The bottom-bar cell (`MainTabView.swift:245`, untouched this round and not this file's business) is a different matter.
    static let cabinPanelEntryHint = key("Opens the Cabin panel: the master switch, the channels and the nearby nodes")
    /// The VoiceOver wording of the top-left back key (the screen shows only an icon, taking up not one character of width). After this tab went full-screen immersive
    /// it is this tab's only exit, so this sentence states the destination rather than the direction of the action.
    static let backToMessages = key("Back to messages")
    /// The same Key as `PopopxAddFriendView.swift:718`: the titles of the two entries are therefore necessarily the same sentence.
    static let plazaTitle = key("Nearby mesh plaza")
    static let meshSettingsEntry = key("Offline mesh settings")
    /// The short words on the faces of the two top-bar capsules. Both are **existing Keys** (`Groups` and `Settings` already have
    /// translations in the 16 catalogues, with the same convention as that "Settings" in `PopopxMeView.swift`), so this round adds no new entry: the capsule fits only one word,
    /// and the full statement is in VoiceOver — the left one reads `.accessibilityLabel(meshGroupsHint)` and the right one reads
    /// `.accessibilityLabel(meshSettingsEntry)`, while the settings-centre header is still the full sentence. The width accounting is in
    /// the paragraph above `meshDiscoveryEntry`.
    static let groupsPill = key("Groups")
    static let meshSettingsPill = key("Settings")
    static let meshRowOn = key("Fuse is open")
    static let meshRowFusedOff = key("Closed by the fuse")
    /// The top-right capsule of the hall. What it switches is the screen the main page already has, not a second list, so the wording says only that layer.
    static let discoveryMode = key("Discovery mode")
    static let discoveryHint = key("Shows or hides the nearby radar and its node list above the hall")
    static let groupsRow = key("Offline groups")
    /// The accessibility hint of the top-left "Discover" capsule: make clear that what this opens is nearby Bluetooth Mesh groups, not public-internet channels.
    static let meshGroupsHint = key("Discover nearby groups and channels over the Bluetooth mesh")
    static func groupsValue(_ groups: Int) -> String { String(format: key("%lld groups"), groups) }
    /// Reusing existing entries: both Keys already have translations in the 16 catalogues (the "Me" page's row of switches uses precisely them).
    static let switchOn = key("Turned on")
    static let switchOff = key("Turned off")
    static let sheetSubtitle = key("The switch, the pairing policy, this device's mesh identity and the data it keeps, in one place.")
    /// Reusing an existing entry: this Key already has a translation in all 16 catalogues (the same convention as `PopopxMeView.swift`'s `"Settings"`).
    static let cancel = NSLocalizedString("Cancel", comment: "Cabin: cancelling the offline mesh wipe")

    static let cardSwitch = key("Mesh switch and pairing")
    static let meshFootnote = key("Closing the master switch stops Bluetooth scanning, advertising and relaying all at once; the other rows on this page stay readable but start no Bluetooth object.")
    static let fuseRow = key("Offline mesh master switch")
    /// The subtitle of the master-switch row rewrites itself with the fuse. The static sentence "closing it is the fuse" is stated by this card's footnote above, so the two halves do not repeat into the same cell.
    static let fuseRowNoteOn = key("Running: Bluetooth scanning, advertising and relaying are all live on this device.")
    static let fuseRowNoteOff = key("Closed by the fuse: every mesh component stopped together and Bluetooth is scanning nothing.")
    static let pairingPolicy = key("Nearby pairing policy")
    /// The explanation of the pairing policy: the subtitle of the policy sheet on the original "Me" page and the "All settings" page, the same Key, the same translated sentence.
    static let pairingSheetSubtitle = key("Decides whether a nearby device's Bluetooth pairing needs your confirmation.")
    static let privacyRecordsRow = key("Offline mesh privacy and pairings")
    static let policyManual = key("Ask me before pairing")
    static let policyManualNote = key("A nearby pairing request shows a confirmation; nothing connects until you tap it.")
    static let policyAuto = key("Pair silently")
    static let policyAutoNote = key("Pairing completes on its own once the private Bluetooth session is up, without asking.")

    // Radio and permissions diagnostic (the only row added this round: the reading has one source, and the tier wording reuses the top-bar capsule's word table)
    static let radioDiagnosisRow = key("Bluetooth permission and radio")
    static let radioOpenSettings = key("Open Settings")
    static let radioUnknown = key("Not read yet")
    static let radioDiagnosisHealthy = key("The radio is on and this app is allowed to use Bluetooth, so there is nothing to change in the Settings app.")
    static let radioDiagnosisUnauthorized = key("This app is not allowed to use Bluetooth. Allow it in the Settings app, then open the master switch again.")
    static let radioDiagnosisPoweredOff = key("Bluetooth is switched off on this device. Turn it on, then open the master switch again.")
    static let radioDiagnosisQuiet = key("The mesh's own Bluetooth monitor has not reported a usable radio yet. With the master switch closed no Bluetooth object is created at all, so this row can only repeat the last reading it was given.")
    static let radioDiagnosisPending = key("This device has not asked the Bluetooth monitor for a reading yet in this run. Turn the master switch on once and this row reports the real state.")

    static let cardIdentity = key("Node identity and actual state")
    static let localKeyRow = key("This device's mesh key")
    static let localKeyAbsent = key("Not created on this device yet")
    static let bindingRow = key("Bound offline contacts")
    static let queueRow = key("Messages queued for a link")
    static let inReachRow = key("In reach now")
    static let relayRow = key("Reached through a relay")
    static let farthestRow = key("Farthest hop in use")
    static let keyFootnote = key("The fingerprint is this device's Noise static public key: 64 hex characters held in the keychain from the first time mesh ran on this device, unchanged by restarts. It is not your POPOPX address.")
    static let verifyHeadline = key("Actual Bluetooth state")
    static let verifyAgain = key("Verify actual state")
    static let verifyPending = key("Not verified yet in this run. Tap Verify to read the real state.")
    static let phaseOff = key("Stopped")
    static let phaseStarting = key("Starting")
    static let phaseOn = key("Running")
    static let phaseStopping = key("Stopping")
    static let quietSuffix = key(", with no component running")
    static let busySuffixFormat = NSLocalizedString(", still running %1$d Bluetooth component(s) and %2$d interface component(s)", comment: "Cabin: verified activity counts")
    static let subscribersSuffixFormat = NSLocalizedString(", %d event subscriptions", comment: "Cabin: verified event hub subscribers")
    static let mismatchSuffix = key("; the switch and the running state do not agree yet")

    static let cardDanger = key("Offline data and clearing")
    static let wipeAction = key("Clear offline bindings and cache")
    static let wipeQuestion = key("Clear offline bindings and cache on this device?")
    static let wipeDetail = key("Removes this device's offline contact bindings, both mesh switches and every file in the mesh cache folder, including the queue waiting for a link and the local nickname. This device's own mesh key stays, so neighbours already paired with it still recognise it.")
    static let wipeCleanToast = key("Offline bindings and mesh cache cleared")
    static func wipeFailedToast(_ count: Int) -> String {
        String(format: NSLocalizedString("%d items could not be cleared", comment: "Cabin: mesh wipe report failures"), count)
    }
}

// MARK: - Previews

#if DEBUG
// The mesh types (`PopopxMeshPeer`, `PopopxPeerReachability`) have no public init, so fake data cannot be produced;
// every preview below mounts the real singletons, and `bootstrap()` is the very path `Shared/POPOPXApp.swift` takes at launch.
struct PopopxCabinView_Previews: PreviewProvider {
    static var previews: some View {
        // The stack is held by this page itself (decision 4 in the file header), and wrapping another layer here would be a second stack, onto which `path.append` would push.
        PopopxCabinView()
            .task { await PopopxMeshRuntime.shared.bootstrap() }
    }
}

// The Reduce Motion preview was deleted: `EnvironmentValues.accessibilityReduceMotion` is read-only in this SDK
// (SwiftUICore.swiftinterface:23758 `public var … : Bool { get }`), and `.environment(\.…)` wants a
// WritableKeyPath, so it cannot be written, and there is no supported substitute. This page's three radar/badge animations all read the same environment value
// (:127, :690, :856); to verify the static radar, turn the system switch on: Settings → Accessibility → Motion → Reduce Motion.

struct PopopxCabinHallView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxCabinHallView(
                fuseOn: true,
                radioState: .poweredOn,
                nickname: .constant(PopopxMeshNicknameStore().read() ?? ""),
                posts: [],
                nodes: [],
                openingNodeID: nil,
                directPeerCount: 0,
                onBroadcast: { _ in nil },
                onSaveNickname: {},
                onTurnOnFuse: {},
                onOpenChat: { _ in },
                onSendFriendRequest: { _ in },
                onRescan: {}
            )
            .navigationTitle(Copy.hallRow)
        }
        .task { await PopopxMeshRuntime.shared.bootstrap() }
    }
}

struct PopopxCabinChannelsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxCabinChannelsView(
                fuseOn: PopopxMeshRuntime.shared.isFuseOn,
                nodes: [],
                openingNodeID: nil,
                pendingCount: 0,
                onOpenChat: { _ in },
                onShowPending: {}
            )
            .navigationTitle(Copy.encryptedChannelsRow)
        }
        .task { await PopopxMeshRuntime.shared.bootstrap() }
    }
}
#endif
