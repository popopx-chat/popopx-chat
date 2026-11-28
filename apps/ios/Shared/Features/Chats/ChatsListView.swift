//
//  ChatsListView.swift
//  POPOPX (iOS)
//
//  [Phase four - Tab 1 Chats] The new chat list.
//
//  Three-section structure: the top embeds the third phase's `PopopxTelemetryHeader` (identity switch / dual-mode status / "+" menu),
//  the middle is the four capsule filters All - Encrypted online - Cabin offline - Channels, below them the chat list with one card per row.
//
//  Stack ownership (this follows the **landed** `Shared/Navigation/MainTabView.swift`, not the task brief's assumption):
//  MainTabView.swift:14-20 and :76-79 decide explicitly that the Chats tab carries its own NavigationStack and only the other three tabs are wrapped by the shell.
//  The reason is that the only place in this project that turns "open a chat" into "push a page" is the binding of `ChatModel.chatId`
//  (Shared/Model/ChatModel.swift:411) to the stack path (old ChatListView.swift:210-217);
//  and the write entries of `chatId` are `ItemsModel.loadOpenChat` (:113) / `loadOpenChatNoWait` (:139),
//  whose callers include notifications (Shared/Model/NtfManager.swift:81), deep link / connection setup (Shared/Model/POPOPXAPI.swift:1091
//  /:1825/:2182/:2849), opening attachments (ChatModel.swift:1303) and new contacts. Once that binding moves into the shell,
//  opening a chat from a notification fails silently - so this page builds its own stack, and `.searchable`, `navigationDestination` and the overlays belong to it.
//  If MainTabView later starts wrapping the Chats tab in a stack, `NavigationStack(path: chatPath)` in this file has to be deleted along with it.
//
//  The route-badge decision table (Docs/popopx-brand-spec.md §2.2, one badge per row, purple and cyan never mixed on the same row §1.1):
//
//  | Basis of the decision                              | Badge                                            |
//  |--------------------------------------------|--------------------------------------------------|
//  | Cabin-bound + neighbour route present (heard within 15 s) | `meshInk` + `antenna.radiowaves.left.and.right` + `· N` (the number must appear, §1.4 item 3) |
//  | Cabin-bound + no route (radio off / no neighbour / past the window) | `labelSecondary` + `clock` + "Awaiting relay" |
//  | Not Cabin-bound, SMP connection ready (local direct chats and groups/channels) | `brand` + `lock.shield.fill` |
//  | Not Cabin-bound and SMP not ready either (incl. read-only observed groups) | "Not connected" (no icon; `clock` is reserved for "Awaiting relay") |
//  | The binding table has not finished loading          | "Reading" (the channel is never guessed for the user) |
//  | Local notes / contact awaiting acceptance / invalid data | no badge (there is no route to say anything about) |
//
//  The single actor hop: `IdentityMappingStore` is an actor, and awaiting it row by row would turn the list into a serial queue,
//  so `allMappings()` is read exactly once inside `reloadMeshBindings()` and flattened into `[contactId: meshPublicKeyHex]`
//  (when one contact has several bindings the one with the newest `updatedAt` wins); hop counts are looked up synchronously in the observed
//  `PopopxMeshStateSource.state`. Refresh trigger = any of fuse, current identity, or the neighbour set changing.
//
//  The red line kept: never touch project.pbxproj (this file must be dragged into the POPOPX (iOS) target by hand); colors/spacing/font sizes/springs
//  come only from PopopxTheme tokens; the two **views** `ChatListNavLink` / `ChatPreviewView` are not reused (old theme),
//  but opening a chat still uses the real `ChatView` with its original five parameters (Shared/Views/ChatList/ChatListView.swift:641).
//
//  The chat row's leading/trailing swipe shortcuts (real device round 8, added back by task seven): hung on this row's wrapper `PopopxChatRowSwipe`,
//  with the button list ported item by item against upstream `ChatListNavLink.swift` - reusing the view would drag the old card back with it, so what is ported is
//  the list and the API, while the drawing uses the system `.swipeActions` + `Label`.
//

import SwiftUI
import UIKit   // `imageFromBase64` returns a UIImage (ImageUtils.swift:431); same form as PopopxMeView.swift:44
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - Route decision value

/// The current route verdict for one chat row. A value type, with the verdicts concentrated in `ChatsListView.channel(for:)`,
/// so the badge only draws it - rendering and verdict cannot tell different stories.
enum PopopxRowChannel: Hashable {
    /// SMP public-network online (indigo-violet lock).
    case smp
    /// Cabin offline with a live route. `hops` is the hop count the mesh measured last, 0 = this device holds the link.
    case mesh(hops: Int)
    /// Cabin-bound, but no usable route at this moment: sendable as soon as a neighbour appears.
    case awaitingRelay
    /// Not Cabin-bound and SMP not connected either.
    case unreachable
    /// The binding table has not finished loading, so any route verdict is premature.
    case checking
    /// This conversation has no route at all (local notes, data that cannot be read).
    case none

    /// The "Cabin offline" case collects **bound** contacts, whether or not there is a route right now:
    /// the filter answers "does this conversation go over Cabin", only the badge answers "does it get through at this moment".
    var isMeshBound: Bool {
        switch self {
        case .mesh, .awaitingRelay: true
        default: false
        }
    }
}

// MARK: - Filters

/// The four capsules at the top, deliberately without icons: `All` has no matching symbol in the §6 icon vocabulary, and a filter
/// with half a set of icons looks more broken than one with none; route meaning is carried only by the badges.
///
/// **Why "Lists" is not a case of this enum (real device round 10, the ruling of task A)**
///
/// 1. The two axes are semantically orthogonal: this enum answers "which route does this conversation take", while lists answer "which bucket the user put these conversations in".
///    Merging them into one selection state would let "tap Channels" silently clear the list the user is reading - upstream has no such problem, because it has only
///    one axis (`ChatTagsModel.activeFilter`); this fork's four capsules are a second axis added by the redesign.
/// 2. The types do not fit: `ChatTag` is dynamic data with an `Int64` id, while `PopopxChatFilter` is a `Int, CaseIterable`
///    static enum. Forcing it in would mean making `allCases` computed from the model, so a UI enum would depend on runtime data,
///    and the loop behind `counts(of:)` would no longer be exhaustive.
/// 3. Truth should exist only once: the selection already lives in `ChatTagsModel.activeFilter` (@Published),
///    and `clearActiveChatFilterIfNeeded()` (Shared/Model/ChatModel.swift:278) zeroes it automatically when the list
///    gets deleted. Keeping another copy in the page's `@State` would be a second truth - exactly the flaw task B fixes.
///
/// So lists go through the separate menu capsule beside it (`PopopxListOption` + `listsMenu` of `PopopxChatFilterBar`),
/// the same device upstream `TagsView` uses when there are more than three tags, degrading to a `Menu` (`collapsedTagsFilterView`,
/// Shared/Views/ChatList/ChatListView.swift:1154): **the number of lists is unbounded,
/// and one row fits only on the condition that it collapses**.
enum PopopxChatFilter: Int, CaseIterable, Identifiable {
    case all
    case online
    case meshOffline
    case channel

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: Copy.filterAll
        case .online: Copy.filterOnline
        case .meshOffline: Copy.filterMeshOffline
        case .channel: Copy.filterChannel
        }
    }

    /// `isChannel` says whether this conversation is a public channel, which has nothing to do with the route it takes: like a group, a channel has only SMP
    /// as one route (see the `.group` branch in `channel(for:)`), so it cannot be derived from `PopopxRowChannel`.
    func matches(_ channel: PopopxRowChannel, isChannel: Bool) -> Bool {
        switch self {
        case .all: true
        case .online: channel == .smp
        case .meshOffline: channel.isMeshBound
        case .channel: isChannel
        }
    }
}

// MARK: - One case of the "Lists" filter

/// One candidate entry consumed by the "Lists" menu capsule: `All` · `Unread` · one per user-created list.
///
/// Deliberately a **value type**, recomputed by the page every render from `ChatTagsModel.shared.userTags` x the current conversations:
/// the UI keeps no second list, so after a list is created or deleted this capsule cannot stay on the stale data of the moment the sheet popped
/// (task B's requirement 3). `filter` is exactly the value written back to `ChatTagsModel.activeFilter`.
struct PopopxListOption: Identifiable, Equatable {
    /// Selecting it = writing this case into `ChatTagsModel.activeFilter`; `nil` means "no list filter" (All).
    let filter: ActiveFilter?
    /// A user-created list name is data, not copy - it is always drawn through `Text(verbatim:)`.
    let title: String
    let emoji: String?
    /// How many conversations fall in this case, from the same source as the number on the four route capsules (the result of `searchedEntries()`).
    /// `nil` = this case is not in this page's menu (when the old list page leaves the selection on some built-in case); better to report no number.
    let count: Int?

    var id: String { filter?.id ?? "list.all" }

    /// `ActiveFilter` is itself Equatable, so "is this case the current one" compares directly, with no separately stored selection.
    func selected(_ active: ActiveFilter?) -> Bool { filter == active }
}

// MARK: - List item

private struct PopopxChatEntry {
    let chat: Chat
    let channel: PopopxRowChannel
    /// Whether the conversation itself is a channel (`ChatInfo.isChannel` = the group's `useRelays`, POPOPXChat/ChatTypes.swift:2296).
    let isChannel: Bool
}

/// The neighbour set's "identity signature": only peer ids, never `lastSeenAt`/`hopCount` - the latter change on every broadcast,
/// and using one as the `.task(id:)` key would make the binding table reread the Keychain every second.
private struct PopopxMeshBindingKey: Equatable {
    let fuseOn: Bool
    let userId: Int64?
    let peerIDs: [String]
}

// MARK: - Page

/// The key name of the pioneer-trial dialog's "was it asked" flag. Written as a file-level constant instead of an `@AppStorage("...")` literal:
/// UserDefaults keys have to be surveyed by name (the self-destruct and migration sites count them by name), and scattered inside decorators they become unsearchable.
private let popopxTrialWelcomeAskedKey = "popopx.commerce.trialWelcomeAsked"

/// The whole page is `@MainActor`, the same style as `MainTabView.swift:127`, `PopopxMeView.swift:52`,
/// `PopopxProximityAddContactView.swift:39`, so the page's synchronous helpers
/// (route verdict, haptics, writing @State) need no individual annotation and never trip isolation-related warnings.
@MainActor
struct ChatsListView: View {
    @EnvironmentObject private var chatModel: ChatModel

    /// The source of truth for the "Lists" capsule, which **must be attached to the page** rather than only to the chat rows.
    ///
    /// The root cause task B found is right here: before the redesign `ChatTagsModel` was observed only by the chat row wrapper
    /// `PopopxChatRowSwipe` (the same-named `@StateObject` later in this file), while the filter bar is drawn in the page's
    /// `chrome` - the page observed neither, so after a list is created in the row's swipe panel and `userTags` gets written,
    /// `ChatsListView.body` recomputes not even once, and the filter bar necessarily stays on the stale list until you leave and re-enter.
    /// `ChatModel` cannot rescue this either: `updateContact` only changes the `chatInfo` of the `Chat` class
    /// (Shared/Model/ChatModel.swift:617-650), the `@Published var chats` array itself does not move,
    /// so the page's `body` is not invalidated either.
    ///
    /// It uses the `.shared` singleton (the same object as the chat row's), so the two observations cannot tell different stories.
    @StateObject private var chatTagsModel = ChatTagsModel.shared

    /// Both are existing runtime singletons: `isFuseOn` and `stateSource.state` are the badge's real source of truth.
    @ObservedObject private var runtime: PopopxMeshRuntime
    @ObservedObject private var meshState: PopopxMeshStateSource

    @AppStorage(DEFAULT_PRIVACY_SHOW_CHAT_PREVIEWS) private var showChatPreviews = true

    @State private var telemetry: PopopxTelemetryModel
    @State private var toast = PopopxToastModel()
    @State private var filter: PopopxChatFilter = .all
    @State private var searchText = ""
    /// 2026-11-20 real device round 2's ruling on the magnifier + collapsible search row: collapsed by default, it occupies a row only once opened.
    /// When collapsing, `searchText` is cleared, to avoid an invisible condition that keeps filtering the list.
    @State private var showsSearchRow = false
    /// The identity switcher only **writes** this value; the actual switch is done by `switchIdentity` below (the top bar deliberately does not switch itself).
    @State private var currentUserId: Int64?
    @State private var showsAddFriend = false
    @State private var showsCreateGroup = false
    @State private var showsCreateChannel = false
    @State private var showsScan = false
    @State private var showsMyAddressQR = false
    /// The "Configure relays" row in the create-channel page pushes `NetworkAndServers` by value (`AddChannelView.swift:85`),
    /// the same policy as the Me tab's stack (`MainTabView.swift:121`): whoever hosts the stack holds the `SaveableSettings`.
    @StateObject private var serversSettings = SaveableSettings()
    /// The notice dialog for the 3-day pioneer trial badge: asked once only, and closing it stops the interruption.
    /// This flag only means "was it asked"; "has this device claimed it" lives in the Keychain's `trialGuard`
    /// (which is what `PopopxBadgeManager.canClaimPioneerTrial` reads), so clearing this flag cannot grant anyone an extra claim.
    @AppStorage(popopxTrialWelcomeAskedKey) private var trialWelcomeAsked = false
    /// Carrier state for the badge's three exits (trial note / detail / paywall); this page only raises `.trial` itself,
    /// while the other two are switched by the exits inside the dialog (`PopopxBadgeSheetHost`).
    @State private var badgeSheet: PopopxBadgeSheet?
    /// The identity id being switched: `changeActiveUserAsync_` reloads the conversations, so re-entering only muddles the state.
    @State private var switchingUserId: Int64?
    /// contactId -> meshPublicKeyHex, the whole table read in a single actor hop.
    @State private var meshBindings: [Int64: String] = [:]
    @State private var meshBindingsLoaded = false
    /// The badge's "freshness" uses this render-time instant rather than `Date.now`: only a state change redraws the view,
    /// so a 5-second poll lets neighbours silent past the window fade to "Awaiting relay" on their own.
    @State private var clock = Date.now

    // `fileprivate` rather than `private`: besides this page's verdict, `maxMeshHops` is also referenced by
    // `PopopxChatFilterBar` and `PopopxChatsEmptyState` in the same file, and Swift's `private` covers only
    // the inside of one type (including its same-file extensions); a cross-type reference directly hits "inaccessible due to 'private'".
    /// The hop cap references module 5's constant directly (`PopopxMeshConfig.fragmentRelayTtlCap`); 7 is not restated here.
    fileprivate static let maxMeshHops = Int(PopopxMeshConfig.default.fragmentRelayTtlCap)
    /// 15 seconds: the same window module 4 uses to judge "Bluetooth unreachable", read from configuration.
    private static let reachabilityTimeout = PopopxMeshConfig.default.peerReachabilityTimeout
    private static let meshPollSeconds: Double = 5

    @MainActor init() {
        let runtime = PopopxMeshRuntime.shared
        _runtime = ObservedObject(wrappedValue: runtime)
        _meshState = ObservedObject(wrappedValue: runtime.stateSource)
        _currentUserId = State(initialValue: ChatModel.shared.currentUser?.userId)
        // Use `.shared` rather than a new instance: the top bar renders here, while "nearby is running" is written in by the face-to-face page (the begin/finish of PopopxProximityAddContactView).
        _telemetry = State(initialValue: .shared)
    }

    var body: some View {
        NavigationStack(path: chatPath) {
            chatList
        }
        .background(PopopxPalette.base)
    }

    /// `ChatModel.chatId` (Shared/Model/ChatModel.swift:411) -> the stack path. Shape and semantics copied from the old
    /// ChatListView.swift:210-217: a non-empty field pushes one page, going back writes nil back. Path elements use `Bool`
    /// (the same type as the old code): this page only needs the "is some chat open" signal, and which exact one is always read from `chatId`
    /// at that moment, so there are never two truths.
    private var chatPath: Binding<[Bool]> {
        Binding(
            get: { chatModel.chatId != nil ? [true] : [] },
            set: { path in if path.isEmpty { chatModel.chatId = nil } }
        )
    }

    @ViewBuilder private var chatList: some View {
        let entries = searchedEntries()
        // Two independent axes, each filtering once: the route (four capsules, the page's own `@State`) and the list
        // (`ChatTagsModel.activeFilter`, one truth for the whole app). Both defaults mean "no filtering",
        // so the screen settled in rounds 8 and 9 has not moved by an inch.
        let listFilter = chatTagsModel.activeFilter
        let rows = entries.filter {
            filter.matches($0.channel, isChannel: $0.isChannel) && matchesList($0, listFilter)
        }
        List {
            if let notice = serviceNotice {
                Text(notice)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PopopxMetrics.spaceS)
                    .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
                    .listRowInsets(EdgeInsets(
                        top: PopopxMetrics.space2XS,
                        leading: PopopxMetrics.gutter,
                        bottom: PopopxMetrics.space2XS,
                        trailing: PopopxMetrics.gutter
                    ))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("popopx.chats.serviceNotice")
            }
            if rows.isEmpty {
                emptyState(
                    searching: !searchText.trimmed.isEmpty,
                    hasAnyChat: !chatModel.chats.isEmpty,
                    // Computed only when the empty state is really drawn: it answers "does the list itself have anything in it".
                    listScoped: listFilter == nil
                        ? nil
                        : entries.filter { matchesList($0, listFilter) }.count
                )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(rows, id: \.chat.viewId) { entry in
                    row(entry)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, PopopxMetrics.minHitTarget)
        .scrollContentBackground(.hidden)
        .background(PopopxPalette.base)
        // The large "Chats" title is withdrawn together with the `.searchable` drawer (real device round 2, item 1):
        // the system title bar is hidden entirely, the first row is taken over by the unified top bar in `chrome`, and search is folded into a collapsible row.
        // The hiding applies only to this page of the stack - `PopopxChatRoomDestination` declares the title bar visible itself,
        // so the back button and in-page navigation are unaffected.
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { chrome }
        // Opening a chat: the destination type and the old five parameters are copied without a single change (see `PopopxChatRoomDestination`).
        .navigationDestination(for: Bool.self) { _ in chatRoom() }
        // The two items in the "+" menu go to two real pages that already exist in the app.
        // `ThemedBackground` is the old theme's API: what gets pushed is an old page, and letting it lay its own theme underneath keeps it from blurring into one mass,
        // so the mounting copies Shared/Views/NewChat/NewChatMenuButton.swift:89 and :93.
        .navigationDestination(isPresented: $showsCreateGroup) {
            PopopxCreateGroupView()
                .navigationTitle(Copy.createGroupTitle)
                .modifier(ThemedBackground(grouped: true))
                // The new-chat dialog also collapses the bottom bar (real device round 2 item 2, same policy as `chatRoom()`).
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showsScan) {
            NewChatView(selection: .connect, showQRCodeScanner: true)
                .navigationTitle(Copy.scanTitle)
                .modifier(ThemedBackground(grouped: true))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .tabBar)
        }
        // Create channel: the same `AddChannelView` (the one in the old "New chat" menu, :97-101), with the mounting copied from
        // the `showsCreateGroup` site above - the same push, the same `ThemedBackground`, the same collapsed bottom bar.
        // Its internal "Configure relays" row is pushed by `ServersDestination` value (AddChannelView.swift:85),
        // so these three registrations must hang at the stack root (same policy as MainTabView.swift:159-167: for one type only the registration nearest the root is kept).
        .navigationDestination(isPresented: $showsCreateChannel) {
            AddChannelView()
                .navigationTitle(Copy.createChannelTitle)
                .modifier(ThemedBackground(grouped: true))
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(for: ServersDestination.self) { destination in
            serversDestination(destination, ss: serversSettings, servers: $serversSettings.servers)
        }
        .navigationDestination(for: ProtocolServerSelection.self) { selection in
            protocolServerDestination(selection, servers: $serversSettings.servers)
        }
        .navigationDestination(for: ChatRelaySelection.self) { selection in
            chatRelayDestination(selection, servers: $serversSettings.servers)
        }
        .sheet(isPresented: $showsAddFriend) {
            PopopxAddFriendView()
        }
        .sheet(isPresented: $showsMyAddressQR) {
            PopopxMyAddressQRSheet()
        }
        // The pioneer trial badge notice dialog. Hung on this page rather than on the `POPOPXApp` layer: the chat stack already exists here,
        // so the sheet has something to attach to; `PopopxTrialWelcomeModal` carries its own "claim" button and its failure reasons,
        // so this layer only decides "should we ask this time" and does not claim on its behalf.
        // The three badge panels share one carrier: tapping "view badge detail" inside the dialog has to switch to the detail page,
        // and swapping `item` is enough - no second sheet needs to be attached at this layer.
        // The top bar's badge does not attach its own sheet either; it uses the same one handed down through `$badgeSheet` (`PopopxTelemetryHeader.badgeSheet`):
        // what the second investigation of "tapping 'view badge detail' does nothing" in real device round 9 turned up was exactly two sheets, this one plus the top bar's, attached on one chain.
        .popopxBadgeSheets($badgeSheet)
        .popopxToast(toast)
        .task { await startTelemetry() }
        .task { presentTrialWelcomeIfNeeded() }
        .task(id: meshBindingKey) { await reloadMeshBindings() }
        .task(id: runtime.isFuseOn) { await pollMeshFreshness() }
        .onChange(of: currentUserId) { _, userId in
            Task { @MainActor in await switchIdentity(to: userId) }
        }
        .onChange(of: chatModel.currentUser?.userId) { _, userId in
            currentUserId = userId
        }
    }

    // MARK: Top bar + filters

    @ViewBuilder private var chrome: some View {
        let entries = searchedEntries()
        let active = chatTagsModel.activeFilter
        // The two axes are each other's denominator for those numbers: with one list selected, the four route capsules report "how many in this list
        // go over SMP / over Cabin / are channels"; with Cabin offline selected, the "Lists" capsule reports "how many conversations each list has
        // in this case". No cell reports a number that is not visible on the screen (the rule set in real device round 2).
        // The two names each say "which numbers this set feeds", not "which axis filtered it", otherwise the reading comes out exactly reversed.
        let entriesForChannelCounts = active == nil ? entries : entries.filter { matchesList($0, active) }
        let entriesForListCounts = filter == .all ? entries : entries.filter { filter.matches($0.channel, isChannel: $0.isChannel) }
        VStack(spacing: 0) {
            PopopxTelemetryHeader(
                currentUserId: $currentUserId,
                identities: switchableIdentities,
                telemetry: telemetry,
                badgeSheet: $badgeSheet,
                onAddFriend: { showsAddFriend = true },
                onStartGroupChat: { showsCreateGroup = true },
                onCreateChannel: { showsCreateChannel = true },
                onScan: { showsScan = true },
                onMyQR: { showsMyAddressQR = true }
            )
            if showsSearchRow {
                PopopxChatSearchRow(text: $searchText, onClose: closeSearchRow)
                    .transition(.opacity)
            } else {
                PopopxChatFilterBar(
                    selection: $filter,
                    counts: counts(of: entriesForChannelCounts),
                    lists: listOptions(of: entriesForListCounts),
                    listSelection: active,
                    onSelectList: { selectList($0) },
                    onSearch: { popopxToggleSearch(open: true) }
                )
            }
            Rectangle()
                .fill(PopopxPalette.separator)
                .frame(height: PopopxMetrics.divider)
        }
        .background(PopopxMaterial.bar)
    }

    /// Expand/collapse the search row. The animation uses the brand spring, and Reduce Motion is managed centrally on the `popopxAnimation` side.
    private func popopxToggleSearch(open: Bool) {
        withAnimation(PopopxSpring.snappy) { showsSearchRow = open }
        PopopxHaptics.selection()
    }

    /// Collapsing must clear the condition: keep the keyword and what the user sees is a list that lost a few rows for no apparent reason.
    private func closeSearchRow() {
        searchText = ""
        popopxToggleSearch(open: false)
    }

    // MARK: Row

    /// One row = `PopopxChatRowSwipe` (the card itself + the leading/trailing swipe shortcuts) + this row's inline geometry.
    ///
    /// The three statements on row padding, divider and row background stay where they are: the swipe buttons hang on the **row content**, so what changes is the content and not the row's geometry,
    /// `PopopxMetrics.gutter` remains the only gutter source, and for why the gesture sinks into the wrapper instead of being attached in place on
    /// the `Button`, see the type comment of `PopopxChatRowSwipe`.
    @ViewBuilder private func row(_ entry: PopopxChatEntry) -> some View {
        PopopxChatRowSwipe(
            chat: entry.chat,
            channel: entry.channel,
            showsPreview: showChatPreviews
        )
        .listRowInsets(EdgeInsets(
            top: PopopxMetrics.space2XS,
            leading: PopopxMetrics.gutter,
            bottom: PopopxMetrics.space2XS,
            trailing: PopopxMetrics.gutter
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Destination: the id is read fresh from `chatId`, and `PopopxChatRoomDestination` then fetches the conversation by id.
    /// The page brought up by the stack path. Both branches have to carry the attachment, so they are wrapped in a `Group`:
    /// the "conversation is gone" screen is equally a page inside the chat stack, and the bottom bar must collapse there when it should.
    @ViewBuilder private func chatRoom() -> some View {
        Group {
            if let chatId = chatModel.chatId {
                PopopxChatRoomDestination(chatId: chatId)
            } else {
                Text(Copy.chatGone)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PopopxPalette.base)
            }
        }
        // Real device round 2 item 2: entering a chat collapses the bottom four tabs. This statement hangs on "the page being pushed in",
        // not on the list, so on return the system takes it back by scope - the list page's bottom bar keeps its four tabs as before.
        // Opening a chat from the address book or from Cabin also comes through here: both only write `ChatModel.chatId`,
        // after which `MainTabView.swift:186` switches the tab to "Chats" and this page's stack presents it, the only chat exit in the whole app.
        .toolbar(.hidden, for: .tabBar)
        // The top bar row is hidden entirely on the list page (the `chatList` above), so the chat must declare it visible itself,
        // otherwise the back button and ChatView's title bar disappear together.
        .toolbar(.visible, for: .navigationBar)
    }

    // MARK: Data

    /// The same exclusion rule as the old list (Shared/Views/ChatList/ChatListView.swift:665).
    private func searchedEntries() -> [PopopxChatEntry] {
        let query = searchText.trimmed.localizedLowercase
        // System config chats for the current user, to be hidden from UI — matched by kind and id.
        let systemConfigRefs = chatModel.systemConfigChatRefs()
        var entries: [PopopxChatEntry] = []
        entries.reserveCapacity(chatModel.chats.count)
        for chat in chatModel.chats {
            let info = chat.chatInfo
            guard !info.chatDeleted, !info.contactCard else { continue }
            // Hide system config chats from the list.
            if let ref = PopopxSystemChatRef(chatType: info.chatType, apiId: info.apiId),
               systemConfigRefs.contains(ref) { continue }
            if !query.isEmpty, !info.chatViewName.localizedLowercase.contains(query) { continue }
            entries.append(PopopxChatEntry(
                chat: chat,
                channel: channel(for: chat),
                isChannel: info.isChannel
            ))
        }
        return entries
    }

    private func counts(of entries: [PopopxChatEntry]) -> [PopopxChatFilter: Int] {
        var counts: [PopopxChatFilter: Int] = [:]
        for option in PopopxChatFilter.allCases {
            counts[option] = entries.filter { option.matches($0.channel, isChannel: $0.isChannel) }.count
        }
        return counts
    }

    // MARK: The list axis

    /// All the data of the "Lists" menu capsule in the filter bar: `All` · `Unread` · then one entry per user list.
    ///
    /// Recomputed every render from `chatTagsModel.userTags`, with **no copy stored in `@State`** -
    /// creating a list in a chat row's swipe panel goes through exactly `tm.userTags = userTags`
    /// (`createChatTag` in Shared/Views/ChatList/TagListView.swift),
    /// so as long as this reads that @Published, the new list appears on the filter bar in the same render (task B item 3).
    ///
    /// The numbers are computed here too rather than read from the model's two count tables: `ChatTagsModel.unreadTags` records
    /// "how many **unread** items each list has" (`updateChatTagRead` / `decTagsReadCount`,
    /// Shared/Model/ChatModel.swift:252-270, for the ● dot on upstream's tag rows), and `presetTags` only covers
    /// the built-in cases of `PresetTag` (:193-210) - the model simply has no table of "how many conversations a user list contains",
    /// while what this capsule wants is precisely the member count, which can only be counted out of each conversation's own `chatInfo.chatTags`.
    private func listOptions(of entries: [PopopxChatEntry]) -> [PopopxListOption] {
        var options: [PopopxListOption] = [
            PopopxListOption(filter: nil, title: Copy.filterAll, emoji: nil, count: entries.count),
            PopopxListOption(
                filter: .unread, title: Copy.listsUnread, emoji: nil,
                count: entries.filter { $0.chat.unreadTag }.count
            ),
        ]
        options.reserveCapacity(options.count + chatTagsModel.userTags.count)
        for tag in chatTagsModel.userTags {
            options.append(PopopxListOption(
                filter: .userTag(tag),
                title: tag.chatTagText,
                emoji: tag.chatTagEmoji,
                count: entries.filter { $0.chat.chatInfo.chatTags?.contains(tag.chatTagId) == true }.count
            ))
        }
        return options
    }

    /// The list axis's decision matches, item by item, the `filtered(_:)` inside the old list's `filteredChats()`
    /// (Shared/Views/ChatList/ChatListView.swift:686-692):
    /// two screens selecting the same case must filter out the same conversations, so they cannot tell different stories.
    private func matchesList(_ entry: PopopxChatEntry, _ active: ActiveFilter?) -> Bool {
        switch active {
        case .none: true
        case .some(.unread): entry.chat.unreadTag
        case let .some(.userTag(tag)): entry.chat.chatInfo.chatTags?.contains(tag.chatTagId) == true
        case let .some(.presetTag(tag)): presetTagMatchesChat(tag, entry.chat.chatInfo, entry.chat.chatStats)
        }
    }

    /// Selecting a case = writing `ChatTagsModel.activeFilter` (the app's single list-selection state).
    /// Deliberately different from the old screen's `setActiveFilter` (:1207): that one has toggle semantics, "tap the same capsule again to cancel",
    /// while here the tap lands on a row of a menu, tapping it again still wants that row, and cancelling belongs to the "All" row.
    private func selectList(_ active: ActiveFilter?) {
        // Compare first, then haptic: tapping the same row twice changes nothing, so that tap deserves no feedback (same policy as
        // `guard !selected else { return }` in `capsule(_:)`, which sits before the haptic).
        guard active != chatTagsModel.activeFilter else { return }
        PopopxHaptics.selection()
        chatTagsModel.activeFilter = active
    }

    /// The route decision. The order is the priority: fuse -> binding table -> binding -> radio -> neighbour route -> freshness.
    private func channel(for chat: Chat) -> PopopxRowChannel {
        // The SMP side's criterion is `chatInfo.sndReady` (POPOPXChat/ChatTypes.swift:2156): its meaning is exactly
        // "can this conversation go over SMP right now", and contactRequest / contactConnection are naturally false,
        // Saved Notes are naturally true, so there is no need to restate the per-case decision in this file.
        let smpReady = chat.chatInfo.sndReady
        switch chat.chatInfo {
        case let .direct(contact):
            return directChannel(contactId: contact.contactId, smpReady: smpReady)
        case .group:
            // Groups and channels have only the SMP public network path: Cabin offline does not relay group broadcasts, so they get no cyan.
            return smpReady ? .smp : .unreachable
        case .local, .contactRequest, .contactConnection, .invalidJSON:
            // Saved Notes go through no channel at all; a contact not established yet has no channel it can promise either.
            return .none
        }
    }

    private func directChannel(contactId: Int64, smpReady: Bool) -> PopopxRowChannel {
        // The fuse is off: not one key in the binding table counts, and the only real channel right now is SMP.
        guard runtime.isFuseOn else { return smpReady ? .smp : .unreachable }
        guard meshBindingsLoaded else { return .checking }
        guard let hex = meshBindings[contactId] else { return smpReady ? .smp : .unreachable }
        guard meshState.state.radioState.isUsable else { return .awaitingRelay }
        guard let peer = meshState.state.peer(withHex: hex) else { return .awaitingRelay }
        // Hops past the TTL ceiling, or silence past module 4's reachability window, is no longer a hops badge that can promise delivery.
        guard peer.hopCount >= 0, peer.hopCount <= Self.maxMeshHops else { return .awaitingRelay }
        guard clock.timeIntervalSince(peer.lastSeenAt) <= Self.reachabilityTimeout else { return .awaitingRelay }
        return .mesh(hops: peer.hopCount)
    }

    private func reloadMeshBindings() async {
        guard runtime.isFuseOn else {
            meshBindings = [:]
            meshBindingsLoaded = true
            return
        }
        let mappings = await runtime.mappingStore.allMappings()
        var newestUpdate: [Int64: Date] = [:]
        var bindings: [Int64: String] = [:]
        for mapping in mappings {
            // Only accept bindings that already point at a real contact: a row still waiting for the pairing result has `contactId` nil
            // (that is how `isPending` is defined, IdentityMappingStore.swift:65), so it has no chat to match.
            guard let contactId = mapping.contactId else { continue }
            // When one contact has several bindings only the newest one counts (`allMappings()` is already sorted by createdAt,
            // but the same contact can be rebound more than once, so here the newest is taken again by updatedAt).
            if let seen = newestUpdate[contactId], seen >= mapping.updatedAt { continue }
            newestUpdate[contactId] = mapping.updatedAt
            bindings[contactId] = mapping.meshPublicKeyHex
        }
        // The fuse can be pulled while the table is being read: that round's conclusion must not be written back to the UI.
        guard runtime.isFuseOn else {
            meshBindings = [:]
            meshBindingsLoaded = true
            return
        }
        meshBindings = bindings
        meshBindingsLoaded = true
    }

    private func pollMeshFreshness() async {
        guard runtime.isFuseOn else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.meshPollSeconds))
            guard !Task.isCancelled else { break }
            clock = Date.now
        }
    }

    private func startTelemetry() async {
        await telemetry.start()
    }

    /// The one first-launch notice about the trial badge: ask only when both conditions hold, and once asked, persist it in that UserDefaults slot.
    ///
    /// `canClaimPioneerTrial` reads 'no badge record + no trialGuard in Keychain',
    /// and that record is already fetched synchronously in `PopopxBadgeManager`'s `init()` (PopopxBadgeManager.swift:65-71),
    /// so there is no need to wait for `start()` here: `start()` installs the StoreKit delivery and the heartbeat, which have nothing to do with this decision.
    /// Those who already claimed it, those already downgraded at expiry, and those already asked all return straight from here: no sheet, no disk read, nothing sent.
    private func presentTrialWelcomeIfNeeded() {
        guard !trialWelcomeAsked else { return }
        guard PopopxBadgeManager.shared.canClaimPioneerTrial else { return }
        trialWelcomeAsked = true
        badgeSheet = .trial
    }

    /// The top bar only writes the selected userId back; switching (the api layer reloading chats, rebuilding the whole chat view tree) belongs here -
    /// `Shared/Navigation/PopopxTelemetryHeader.swift:187-188` is written to exactly this division of labour.
    private func switchIdentity(to userId: Int64?) async {
        guard let userId, userId != chatModel.currentUser?.userId, switchingUserId == nil else { return }
        switchingUserId = userId
        defer { switchingUserId = nil }
        do {
            try await changeActiveUserAsync_(userId, viewPwd: nil)
            let name = chatModel.users.first { $0.user.userId == userId }?.user.displayName ?? Copy.unnamedIdentity
            PopopxHaptics.notice(.success)
            toast.show(Copy.identitySwitched(name), kind: .encrypted)
        } catch {
            // On failure the switcher must be set back to the real identity, otherwise the top bar keeps showing a choice that never took effect.
            currentUserId = chatModel.currentUser?.userId
            logger.error("popopx chats: switching identity \(userId) failed: \(responseError(error))")
            PopopxHaptics.notice(.error)
            toast.show(Copy.identitySwitchFailed, kind: .danger)
        }
    }

    /// Switchable identities: the same rule as UserPicker.swift:33-35 (likewise `PopopxMeView.swift:541-545`) -
    /// locked identities (`user.hidden`, i.e. having a `viewPwdHash`) do not enter the switcher, because what is passed here is `viewPwd: nil`,
    /// and switching to a locked identity with nil can only fail; locked identities belong to identity management on the Me page.
    /// but the current identity must be in the table, otherwise the top bar shows its own name as 'Not selected'. Order follows UserPicker
    /// (`activeOrder` reversed), so the two lists never say different things.
    private var switchableIdentities: [User] {
        let current = chatModel.currentUser?.userId
        return chatModel.users
            .filter { !$0.user.hidden || $0.user.userId == current }
            .sorted { $0.user.activeOrder > $1.user.activeOrder }
            .map(\.user)
    }

    private var meshBindingKey: PopopxMeshBindingKey {
        PopopxMeshBindingKey(
            fuseOn: runtime.isFuseOn,
            userId: chatModel.currentUser?.userId,
            peerIDs: meshState.state.peers.map { $0.peerID.hex }.sorted()
        )
    }

    private var serviceNotice: String? {
        switch chatModel.chatRunning {
        case .some(true): nil
        case .some(false): Copy.serviceDisconnected
        case .none: Copy.serviceStarting
        }
    }

    // MARK: Empty state

    private func emptyState(searching: Bool, hasAnyChat: Bool, listScoped: Int?) -> some View {
        PopopxChatsEmptyState(
            searching: searching,
            query: searchText.trimmed,
            hasAnyChat: hasAnyChat,
            filter: filter,
            listScoped: listScoped,
            fuseOn: runtime.isFuseOn,
            radioUsable: meshState.state.radioState.isUsable,
            bindingsLoaded: meshBindingsLoaded
        )
    }
}

// MARK: - Capsule filter

@MainActor private struct PopopxChatFilterBar: View {
    @Binding var selection: PopopxChatFilter
    let counts: [PopopxChatFilter: Int]
    /// The setting of the 'List' menu capsule (`All` . `Unread` . each user list), recomputed by the page every frame.
    let lists: [PopopxListOption]
    /// The currently selected setting (`ChatTagsModel.activeFilter`). The selection is not stored here - storing it would make a second source of truth.
    let listSelection: ActiveFilter?
    let onSelectList: (ActiveFilter?) -> Void
    /// The search entry pinned at the end of the row, not drawn when nil. Deliberately kept out of the horizontal scroll area: it sits at the far right of the whole row,
    /// so it is reachable whatever filter capsule is scrolled to (device round 2 ruled: magnifier + collapsible search row).
    var onSearch: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The trailing edge's dissolve width: wide enough to read as a dissolve rather than a hard clip,
    /// narrow enough not to dim a whole capsule.
    private static let trailingFadeWidth = PopopxMetrics.spaceM

    var body: some View {
        // Horizontal scroll rather than wrapping: at accessibility font size the filter capsules do not fit on one row, and truncation is worse than scrolling.
        // The four capsules' occupancy budget on iPhone 15 Pro (393pt) at Large font size (inner padding 12×2=24, Chinese glyphs counted as 1em≈17pt,
        // digits metricSmall≈7pt, capsule spacing spaceXS=8): All 69, Online encrypted 103, Cabin offline 103, Channels 69
        // → content 344 + spacing 24 = 368, plus the 16 gutter inside the scroll area and 8 at the tail = 392; the magnifier capsule is pinned
        // outside the scroll area (44 + tail 12 = 56), so the whole row needs 448 - 393 cannot hold it, the shortfall is 55pt, and the fourth capsule only shows fully after a sideways swipe.
        // With three capsules the same budget is 371, leaving 22pt. Conclusion: no wrapping, no second row, rely on the existing horizontal scroll,
        // and the fourth capsule deliberately takes the shortest correct wording ('Channels', two Chinese glyphs, the same width as 'All').
        // The 'List' capsule added back in round 10 sits at the **very end** of the scroll area, and that is not arbitrary: with the scroll area at position 0 the four capsules
        // land pixel-for-pixel where the round 9 device screenshots show them (the 55pt-shortfall budget can only grow longer, it never moves position),
        // and this capsule is the fifth one that only appears thanks to the swipe that already existed then. Its own name is clamped by characters
        // (`clampedName`), so however long the list name is, it cannot push this row onto two lines.
        // The magnifier at the row end is pinned outside the scroll area: HStack lays out the fixed-width end first and ScrollView takes what is left,
        // so wrapping the search entry outside this layer cannot mis-measure the row's settings (the top-bar cluster was tripped by
        // `.fixedSize()` outside `ViewThatFits`, the same lesson).
        // Device round 2 item 2: a capsule sliced at the scroll area's edge read as truncation, not as "swipe for more" — so the
        // scroll area dissolves its first and last `trailingFadeWidth` points into the bar. The dissolve is unconditional: the
        // frame-based "is anything still beyond the edge" probe this replaced never delivered on the iOS 26 runtime (the
        // preference stayed at zero across a scroll), and a fade that only sometimes appears is worse than one that is always
        // there. The mask is attached to the ScrollView's own frame, never to the row, which is what keeps the pinned magnifier
        // at full contrast — nothing is drawn over it.
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PopopxMetrics.spaceXS) {
                    ForEach(PopopxChatFilter.allCases) { option in
                        capsule(option)
                    }
                    listsMenu()
                }
                .padding(.leading, PopopxMetrics.gutter)
                .padding(.trailing, onSearch == nil ? PopopxMetrics.gutter : PopopxMetrics.spaceXS)
                .padding(.vertical, PopopxMetrics.space2XS)
            }
            .mask {
                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    let fade = min(0.4, Self.trailingFadeWidth / width)
                    // Symmetric dissolve on both physical edges: a capsule sliced at whichever edge
                    // overflows reads as truncation, not as "swipe for more", and the two-edge form is
                    // mirror-invariant — RTL gets the same dissolve without any direction branch.
                    // The mask lives on the ScrollView's own frame, so the pinned magnifier outside
                    // the scroll area is never dimmed.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: fade),
                            .init(color: .black, location: 1 - fade),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: UnitPoint(x: 0, y: 0.5),
                        endPoint: UnitPoint(x: 1, y: 0.5)
                    )
                }
            }
            if let onSearch {
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(PopopxType.secondary)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(PopopxPressButtonStyle(feedback: nil))
                .accessibilityLabel(Copy.searchOpen)
                .accessibilityIdentifier("popopx.chats.searchToggle")
                .padding(.trailing, PopopxMetrics.gutter - PopopxMetrics.space2XS)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.filterGroupLabel)
    }

    private func capsule(_ option: PopopxChatFilter) -> some View {
        let count = counts[option] ?? 0
        let selected = option == selection
        return Button {
            guard !selected else { return }
            PopopxHaptics.selection()
            selection = option
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Text(verbatim: option.title)
                    .font(PopopxType.emphasis)
                Text(verbatim: "\(count)")
                    .font(PopopxType.metricSmall)
                    .opacity(selected ? 1 : 0.7)
            }
            .foregroundStyle(selected ? PopopxPalette.onBrand : PopopxPalette.labelSecondary)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(selected ? PopopxPalette.brand : PopopxPalette.card, in: .capsule)
            .overlay {
                if !selected {
                    Capsule().strokeBorder(PopopxPalette.labelHint, lineWidth: PopopxMetrics.divider)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .popopxAnimation(PopopxSpring.snappy, value: selected, reduceMotion: reduceMotion)
        .accessibilityLabel(option.title)
        .accessibilityValue(Copy.filterValue(count, hopCap: ChatsListView.maxMeshHops, isMesh: option == .meshOffline))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: The 'List' capsule

    /// The current setting; **nil when there is no list filter**, even though the 'All' row is also in `lists`.
    /// 'All' does not deserve a highlight because the first channel capsule to its left is also called 'All' - two capsules lit as 'All' at once
    /// would only make people think they filtered the same thing twice.
    private var activeListOption: PopopxListOption? {
        guard let listSelection else { return nil }
        return lists.first { $0.selected(listSelection) }
            ?? PopopxListOption(filter: listSelection, title: Copy.listsChip, emoji: nil, count: nil)
    }

    private var hasUserLists: Bool {
        lists.contains {
            switch $0.filter {
            case .some(.userTag): true
            default: false
            }
        }
    }

    /// The list name is clamped to 12 characters. Why by characters rather than by width: adding `.frame(maxWidth:)` to this capsule
    /// would stretch even the narrower ones to full (`Text` is a flexible view inside an HStack and eats whatever width it gets),
    /// so that capsule would end up a step wider than its neighbours and the even equal-width rhythm settled in round 9 would fall apart.
    /// The full name is readable in one piece in every row of the menu below; the capsule only says which entry it currently rests on.
    private func clampedName(_ name: String) -> String {
        name.count > 12 ? String(name.prefix(12)) + "…" : name
    }

    /// The 'List' capsule: folded into a menu instead of laying out a fifth, sixth and onward capsules. Two reasons:
    /// there is no upper bound on how many lists a user can create, while this row is only 393pt (the width budget above already owes 55pt);
    /// upstream does exactly the same thing once there are more than three tags (`collapsedTagsFilterView`,
    /// Shared/Views/ChatList/ChatListView.swift:1154）。
    ///
    /// Its rendering (inner padding / capsule fill / stroke / `brand` on selection / `minHitTarget`) and `capsule(_:)`
    /// use the same set of tokens and the same modifier order, so it reads as family rather than as another control pasted alongside.
    private func listsMenu() -> some View {
        let active = activeListOption
        return Menu {
            ForEach(lists) { option in
                listItem(option)
            }
            if !hasUserLists {
                // Not a single list exists yet: the menu tells the truth and says where to create one, instead of offering a baffling blank setting.
                Button {} label: {
                    Text(Copy.listsEmptyHint)
                }
                .disabled(true)
            }
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: active == nil ? "line.3.horizontal.decrease.circle" : "tag.fill")
                    .font(PopopxType.metricSmall)
                Text(verbatim: clampedName(active?.title ?? Copy.listsChip))
                    .font(PopopxType.emphasis)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let count = active?.count {
                    Text(verbatim: "\(count)")
                        .font(PopopxType.metricSmall)
                }
            }
            .foregroundStyle(active == nil ? PopopxPalette.labelSecondary : PopopxPalette.onBrand)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(active == nil ? PopopxPalette.card : PopopxPalette.brand, in: .capsule)
            .overlay {
                if active == nil {
                    Capsule().strokeBorder(PopopxPalette.labelHint, lineWidth: PopopxMetrics.divider)
                }
            }
            .contentShape(.capsule)
        }
        .menuIndicator(.hidden)
        .popopxAnimation(PopopxSpring.snappy, value: active?.id ?? "none", reduceMotion: reduceMotion)
        .accessibilityLabel(Copy.listsGroupLabel)
        // Report the member count when there is a setting to report, report nothing when none is selected: with no setting selected this capsule's number has no credible referent
        // (it is neither the rows on screen nor the number of lists), so it is better not reported at all.
        .accessibilityValue(Text(verbatim: active?.count.map { "\($0)" } ?? ""))
        .accessibilityAddTraits(active == nil ? [] : .isSelected)
        .accessibilityIdentifier("popopx.chats.listsFilter")
    }

    /// A row in the menu: the selected row swaps its icon for `checkmark`, an unselected list shows its own emoji,
    /// and the two built-in settings show one generic tag symbol. Upstream's collapsed menu does not mark the selection (it expresses it
    /// through the font weight of the outer row); this capsule is collapsed and its weight is not visible, so the selection has to land in the menu rows - that choice is
    /// this fork's own, not a copy. The trailing `· N` reuses this file's hops middle dot (`hopsSuffix`),
    /// and the number itself needs no translation.
    private func listItem(_ option: PopopxListOption) -> some View {
        let selected = option.selected(listSelection)
        return Button {
            onSelectList(option.filter)
        } label: {
            Label {
                Text(verbatim: option.count.map { "\(option.title) · \($0)" } ?? option.title)
            } icon: {
                if selected {
                    Image(systemName: "checkmark")
                } else if let emoji = option.emoji {
                    Text(verbatim: emoji)
                } else {
                    Image(systemName: "tag")
                }
            }
        }
    }
}

// MARK: - Collapsible search row

/// The row the top bar round 2 ruled for: it appears only once the magnifier is tapped, and binds the same `searchText`,
/// so the filtering logic (`searchedEntries()`) was not changed by a single line - it only moved from the `.searchable` drawer into the page's own row.
/// The text field carries no decoration beyond the rounded card: 44pt hit target, `gutter` aligned with the list content, collapse condition on the right.
@MainActor private struct PopopxChatSearchRow: View {
    @Binding var text: String
    let onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "magnifyingglass")
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
            TextField(Copy.searchPrompt, text: $text)
                .font(PopopxType.body)
                .textFieldStyle(.plain)
                .foregroundStyle(PopopxPalette.label)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .accessibilityLabel(Copy.searchPrompt)
                .accessibilityIdentifier("popopx.chats.searchField")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(PopopxType.secondary)
                        .foregroundStyle(PopopxPalette.labelHint)
                        .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.searchClear)
            }
            Button(action: onClose) {
                Text(Copy.searchClose)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.brand)
                    .frame(minHeight: PopopxMetrics.minHitTarget)
                    .padding(.horizontal, PopopxMetrics.space2XS)
                    .contentShape(.rect)
            }
            .buttonStyle(PopopxPressButtonStyle(feedback: nil))
            .accessibilityIdentifier("popopx.chats.searchClose")
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .frame(minHeight: PopopxMetrics.minHitTarget)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.vertical, PopopxMetrics.space2XS)
        // Expanding focuses it: that step turns 'open search' and 'start typing' into one operation, and the keyboard is handed back when it collapses.
        .onAppear { focused = true }
        .onDisappear { focused = false }
    }
}

// MARK: - Chat row

@MainActor private struct PopopxChatRow: View {
    @ObservedObject var chat: Chat
    let channel: PopopxRowChannel
    let showsPreview: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The avatar side is `space2XL` (48pt): the badge sits in the right column, the row height is decided by content, and the 44pt hit area is guaranteed by the outer `minHeight`.
    private var avatarSide: CGFloat { PopopxMetrics.space2XL }

    /// At accessibility font size the preview yields the second row - if one row only ever shows one row, large-font users see nothing but truncation.
    private var previewLineLimit: Int { dynamicTypeSize.isAccessibilitySize ? 2 : 1 }

    var body: some View {
        HStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
            avatar
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                    Text(verbatim: chat.chatInfo.chatViewName)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: PopopxMetrics.space2XS)
                    PopopxUnreadMark(chat: chat)
                }
                Text(verbatim: preview)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .lineLimit(previewLineLimit)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: PopopxMetrics.space2XS) {
                timestamp
                PopopxChannelBadge(channel: channel)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay {
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        }
        .popopxCardElevation(colorScheme: colorScheme)
        .contentShape(Rectangle())
        // Acceptance anchor: the row's AX shape changes with screen width and modal layers (measured on a cold start at 375pt: the list draws two rows, the row title is left as staticText,
        // and the only 'button' carrying the group name is the navigation title at 220x32), so the test case needs a handle that changes with neither language nor shape.
        .accessibilityIdentifier("popopx.row")
    }

    private var avatar: some View {
        Group {
            if let image = imageFromBase64(chat.chatInfo.image) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    PopopxPalette.separator
                    Text(verbatim: monogram)
                        .font(PopopxType.secondary)
                        .foregroundStyle(PopopxPalette.label)
                }
            }
        }
        .frame(width: avatarSide, height: avatarSide)
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous))
        .accessibilityHidden(true)
    }

    private var timestamp: Text {
        formatTimestampText(chat.chatItems.last?.meta.itemTs ?? chat.chatInfo.chatTs)
            // The timestamp uses `metric`: PopopxTheme.swift:203-204 states plainly that 'hops, latency and timestamps use monospaced digits',
            // so the list refreshing every minute does not jitter left and right.
            .font(PopopxType.metric)
            .foregroundStyle(PopopxPalette.labelSecondary)
    }

    private var monogram: String {
        let name = chat.chatInfo.chatViewName.trimmed
        guard let first = name.first else { return Copy.monogramFallback }
        return String(first).uppercased()
    }

    private var preview: String {
        guard showsPreview else { return Copy.previewHidden }
        guard let item = chat.chatItems.last else {
            return chat.chatInfo.chatType == .local ? Copy.noNotesYet : Copy.noMessagesYet
        }
        if item.isDeletedContent { return Copy.deletedContent }
        let text = item.text.trimmed
        return text.isEmpty ? Copy.noTextContent : text
    }
}

// MARK: - Chat row swipe actions

/// Device round 8, task seven: put the left/right swipe actions that the last round's redesign dropped back **on**.
///
/// Its feature surface was ported item by item against `Shared/Views/ChatList/ChatListNavLink.swift`, it is not a new design:
/// which buttons each `chatType` has, in what order, which existing API a tap takes, whether a confirmation is needed, all match upstream.
///
/// Why this wrapper layer exists instead of attaching `.swipeActions` in place inside `ChatsListView.row(_:)`:
/// a few of the swipe buttons need presentation state **one per row** - `deleteContactDialog` requires
/// the three callback channels `SomeAlert` / `SomeActionSheet` / `SomeSheet` (Shared/Views/Chat/ChatInfoView.swift:1139),
/// the 'List' button has to open `TagSheetRoot` on this row's sheet, and contactConnection's 'Name' works the same way.
/// Attaching them to the page would make the whole list share one slot of state, and two rows' different confirmation sheets would knock each other out; upstream likewise keeps the state
/// on the row content itself (`ChatListNavLink`'s `@State alert/actionSheet/sheet`), and this is the same shape.
///
/// The row content is still a `Button`, not swapped for a `NavigationLink`: `Tests iOS/Tests_iOS.swift:428-454` hits this row through
/// the inline `staticTexts` and the `popopx.row` anchor on `PopopxChatRow`, and changing the control would change this row's AX shape;
/// besides, opening a chat has only the `ChatModel.chatId` route (see 'who owns the stack' at the head of the file), so switching to value navigation would cut off opening from a notification.
///
/// `allowsFullSwipe: false`: in this fork delete/clear always go through a confirmation (upstream uses no `role:` either, see
/// `ChatListNavLink.swift:385-401`); a full swipe would only drop the outermost button, which is meaningless for something that still needs confirming,
/// and it would also fight the card's rounded corners. This is the single gesture restriction relative to upstream (`allowsFullSwipe: true`).
@MainActor private struct PopopxChatRowSwipe: View {
    @EnvironmentObject private var chatModel: ChatModel
    @ObservedObject var chat: Chat
    let channel: PopopxRowChannel
    let showsPreview: Bool

    /// The 'List' button's host page reads it; the injection matches the old list's same place (ChatListView.swift:185).
    @StateObject private var chatTagsModel = ChatTagsModel.shared

    /// Three callback channels + one sheet slot, all belonging to this row alone.
    /// `alert` / `actionSheet` / `sheet` are the three callback channels `deleteContactDialog` requires
    /// (Shared/Views/Chat/ChatInfoView.swift:1139); the 'More' action sheet and the second-level confirmation share the same pair of channels.
    /// `sheet` carries both `DeleteActiveContactDialog` and the 'List' `TagSheetRoot` - the two are already
    /// mutually exclusive (only one can be up on the same row at the same moment), and merging them into one `.sheet` avoids stacking two presentation layers on the same view.
    @State private var alert: SomeAlert?
    @State private var actionSheet: SomeActionSheet?
    @State private var sheet: SomeSheet<AnyView>?
    @State private var showContactConnectionInfo = false

    /// The five swipe-button tints all come from semantic tokens `PopopxPalette` already has (the theme file is a red line, no new colours).
    /// Upstream's `.orange` / `.yellow` / `.mint` have no matching token in this fork, so they map to the nearest by meaning:
    /// `primary`→`brand`, `green`→`success`, `red`→`danger`, `orange` (clear, irreversible but deletes no entity)→`dangerInk`,
    /// and no tint plus `yellow`/`mint`/`indigo` (secondary or neutral)→`neutral`.
    private static let connect = PopopxPalette.brand
    private static let favorite = PopopxPalette.success
    private static let destructive = PopopxPalette.danger
    private static let irreversible = PopopxPalette.dangerInk
    private static let neutral = PopopxPalette.labelSecondary

    var body: some View {
        Group {
            switch chat.chatInfo {
            case let .direct(contact):
                directRow(contact)
            case let .group(groupInfo, _):
                groupRow(groupInfo)
            case .local:
                noteFolderRow()
            case let .contactRequest(cReq):
                contactRequestRow(cReq)
            case let .contactConnection(cConn):
                contactConnectionRow(cConn)
            case .invalidJSON:
                // Data that cannot be interpreted: upstream gives this row no swipe buttons either, only opening the raw JSON
                // (ChatListNavLink.swift:641-651), and this is the same shape - never hand out a button nobody knows what it does.
                rowCard
            }
        }
        .alert(item: $alert) { $0.alert }
        // The contact deletion's two-level confirmation and the 'More' action sheet are both ActionSheets - that is the interface shape
        // `deleteContactDialog` requires, and this fork's same chain attaches it that way too (PopopxChatInfoView.swift:175).
        .actionSheet(item: $actionSheet) { $0.actionSheet }
        // One `.sheet` carries both `DeleteActiveContactDialog` (the second-level delete confirmation) and the 'List'
        // `TagSheetRoot`: these two panels are mutually exclusive anyway, so stacking a second `.sheet` would only add a presentation layer.
        .sheet(item: $sheet) { someSheet in
            someSheet.content
                .presentationDetents([.fraction(someSheet.fraction)])
        }
    }

    // MARK: Card and opening

    /// The card body itself and its tap behaviour were not changed by one line: still `PopopxChatRow`, still `PopopxPressButtonStyle`,
    /// still 'tapping a row does only the one thing the existing convention says' - `ItemsModel.loadOpenChat` reads the messages first and 250ms later writes
    /// `ChatModel.chatId` (ChatModel.swift:113-139), and the stack-path binding immediately turns it into a page;
    /// that is the same route opening from a notification takes, and this file keeps no second copy of the 'which chat is open' state.
    private var rowCard: some View {
        Button {
            open()
        } label: {
            PopopxChatRow(chat: chat, channel: channel, showsPreview: showsPreview)
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .disabled(!openable)
        .opacity(openable ? 1 : 0.5)
    }

    /// Whether a chat can be opened copies the criterion from the old list's same place (Shared/Views/ChatList/ChatListView.swift:568),
    /// moved out of `ChatsListView` as it stands, with not one condition changed.
    private var openable: Bool {
        chatModel.chatRunning == true && !chatModel.deletedChats.contains(chat.chatInfo.id)
    }

    private func open() {
        guard openable else { return }
        PopopxHaptics.impact(.light)
        ItemsModel.shared.loadOpenChat(chat.chatInfo.id)
    }

    // MARK: Attachment table by chatType

    /// One-to-one chat.
    ///
    /// The contact-card row needs no special case: `searchedEntries()` already takes it out together with `chatDeleted`
    /// (this file :413, that one `!info.chatDeleted, !info.contactCard`), and upstream
    /// `ChatListNavLink.swift:98-120` has no counterpart here.
    ///
    /// When an incoming request waits for confirmation the three left-side buttons are withdrawn as a group (upstream `:128`'s `.if(!contact.nextAcceptContactRequest)`):
    /// a contact not accepted yet has nothing to say about 'read / pin / mute'.
    @ViewBuilder private func directRow(_ contact: Contact) -> some View {
        rowCard
            .if(!contact.nextAcceptContactRequest) { v in
                v.swipeActions(edge: .leading, allowsFullSwipe: false) {
                    markReadButton()
                    toggleFavoriteButton()
                    toggleNtfsButton()
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if contact.nextAcceptContactRequest {
                    if let contactRequestId = contact.contactRequestId {
                        acceptContactRequestButton(contactRequestId, incognito: false)
                        if !chatModel.addressShortLinkDataSet {
                            acceptContactRequestButton(contactRequestId, incognito: true)
                        }
                        rejectContactRequestButton(contactRequestId)
                    } else if let groupDirectInv = contact.groupDirectInv, !groupDirectInv.memberRemoved {
                        // A direct invitation handed over by a group member: accept/reject goes through the `acceptMemberContactRequest` pair,
                        // which is not the same API as the contact-request pair (the same branch at ComposeView.swift:584-587).
                        acceptMemberContactRequestButton(contact)
                        rejectMemberContactRequestButton(contact)
                    } else {
                        deleteContactButton(contact)
                    }
                } else {
                    tagChatButton()
                    if !chat.chatItems.isEmpty {
                        clearChatButton()
                    }
                    deleteContactButton(contact)
                }
            }
    }

    /// Groups and channels: each of the three `memberStatus` settings attaches its own, the same branch as upstream's `groupNavLink`.
    @ViewBuilder private func groupRow(_ groupInfo: GroupInfo) -> some View {
        switch groupInfo.membership.memberStatus {
        case .memInvited:
            rowCard
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    joinGroupButton(groupInfo)
                    if groupInfo.canDelete {
                        deleteGroupChatButton(groupInfo)
                    }
                }
        case .memAccepted:
            rowCard
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    tagChatButton()
                    if groupInfo.membership.memberCurrentOrPending && !(groupInfo.useRelays && groupInfo.isOwner) {
                        leaveGroupChatButton(groupInfo)
                    }
                    if groupInfo.canDelete {
                        deleteGroupChatButton(groupInfo)
                    }
                }
        default:
            rowCard
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    markReadButton()
                    toggleFavoriteButton()
                    toggleNtfsButton()
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    groupTrailingButtons(groupInfo)
                }
        }
    }

    /// The right-side button table for a joined group. The counting logic copies upstream `ChatListNavLink.swift:268-298` sentence by sentence:
    /// past 3 buttons iOS can only draw 3 (Apple FB25316763), and the extras are collected into the 'More' action sheet.
    @ViewBuilder private func groupTrailingButtons(_ groupInfo: GroupInfo) -> some View {
        tagChatButton()
        let showReportsButton = chat.chatStats.reportsCount > 0 && groupInfo.membership.memberRole >= .moderator
        let showClearButton = !chat.chatItems.isEmpty
        let showDeleteGroup = groupInfo.canDelete
        let showLeaveGroup = groupInfo.membership.memberCurrentOrPending && !(groupInfo.useRelays && groupInfo.isOwner)
        let totalNumberOfButtons = 1 + (showReportsButton ? 1 : 0) + (showClearButton ? 1 : 0)
            + (showDeleteGroup ? 1 : 0) + (showLeaveGroup ? 1 : 0)

        if showClearButton && totalNumberOfButtons <= 3 {
            clearChatButton()
        }
        if showReportsButton && totalNumberOfButtons <= 3 {
            archiveAllReportsButton()
        }
        if showLeaveGroup {
            leaveGroupChatButton(groupInfo)
        }
        if showDeleteGroup && totalNumberOfButtons <= 3 {
            deleteGroupChatButton(groupInfo)
        } else if totalNumberOfButtons > 3 {
            if showDeleteGroup && !groupInfo.membership.memberActive {
                // No longer in the group: the delete button is given directly, not tucked into 'More' to wait for a second tap.
                deleteGroupChatButton(groupInfo)
                moreOptionsButton(false, groupInfo)
            } else {
                moreOptionsButton(true, groupInfo)
            }
        }
    }

    /// Private note feed: the left side has only 'Read/Unread', the right side only 'Clear' - upstream's same two places
    /// (`ChatListNavLink.swift:311-318`). Pin/mute means nothing for a feed only you read, and with no channel there is no
    /// revocable incoming request either, so these two groups of buttons are fewer - nothing was left unattached.
    private func noteFolderRow() -> some View {
        rowCard
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                markReadButton()
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !chat.chatItems.isEmpty {
                    clearNoteFolderButton()
                }
            }
    }

    /// Someone not accepted yet: only accept / accept incognito / reject. No left side - a chat not yet established has no read state and no mute.
    private func contactRequestRow(_ cReq: UserContactRequest) -> some View {
        rowCard.swipeActions(edge: .trailing, allowsFullSwipe: false) {
            acceptContactRequestButton(cReq.apiId, incognito: false)
            if !chatModel.addressShortLinkDataSet {
                acceptContactRequestButton(cReq.apiId, incognito: true)
            }
            rejectContactRequestButton(cReq.apiId)
        }
    }

    /// Connecting: delete this connection, plus open its details (upstream's `showContactConnectionInfo` 'Name' button).
    /// The sheet hangs on this branch rather than on `body`: only this kind of chat needs it, at the same position as upstream `:543`.
    private func contactConnectionRow(_ cConn: PendingContactConnection) -> some View {
        rowCard
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteContactConnectionButton(cConn)
                contactConnectionNameButton()
            }
            .appSheet(isPresented: $showContactConnectionInfo) {
                if case let .contactConnection(contactConnection) = chat.chatInfo {
                    ContactConnectionInfo(contactConnection: contactConnection)
                        .modifier(ThemedBackground(grouped: true))
                }
            }
    }

    // MARK: Read / pin / mute

    /// Read / unread. The decision uses the same criterion as `PopopxUnreadMark` (`chatStats.unreadCount` / `unreadChat`),
    /// so when the badge is lit as unread this button must read 'Read', and otherwise it must read 'Unread' - the two places cannot disagree.
    @ViewBuilder private func markReadButton() -> some View {
        if chat.chatStats.unreadCount > 0 || chat.chatStats.unreadChat {
            Button {
                PopopxHaptics.selection()
                Task { await markChatRead(ItemsModel.shared, chat) }
            } label: {
                Label(Copy.swipeRead, systemImage: "checkmark")
            }
            .tint(Self.connect)
        } else {
            Button {
                PopopxHaptics.selection()
                Task { await markChatUnread(chat) }
            } label: {
                Label(Copy.swipeUnread, systemImage: "circlebadge.fill")
            }
            .tint(Self.connect)
        }
    }

    /// Pinning == `favorite` (`apiSetChatSettings`, ChatView.swift:3465). This fork's protocol has no
    /// 'hide' setting, so there are only the on and off buttons, and no third state is invented.
    @ViewBuilder private func toggleFavoriteButton() -> some View {
        if chat.chatInfo.chatSettings?.favorite == true {
            Button {
                PopopxHaptics.selection()
                toggleChatFavorite(chat, favorite: false)
            } label: {
                Label(Copy.swipeUnfavorite, systemImage: "star.slash.fill")
            }
            .tint(Self.favorite)
        } else {
            Button {
                PopopxHaptics.selection()
                toggleChatFavorite(chat, favorite: true)
            } label: {
                Label(Copy.swipeFavorite, systemImage: "star.fill")
            }
            .tint(Self.favorite)
        }
    }

    /// Mute. Neither the setting nor the wording is rewritten here: `chatInfo.nextNtfMode` gives the next one (all→mentions/none,
    /// mentions→none, none→all), and `MsgFilter.text(mentions:)` gives the three wordings 'Mute / Mute all / Unmute'
    /// while `iconFilled` gives the icon; when there is no next setting (configuration that cannot be read) this button does not appear, same as upstream.
    @ViewBuilder private func toggleNtfsButton() -> some View {
        if let nextMode = chat.chatInfo.nextNtfMode {
            Button {
                PopopxHaptics.selection()
                toggleNotifications(chat, enableNtfs: nextMode)
            } label: {
                Label(nextMode.text(mentions: chat.chatInfo.hasMentions), systemImage: nextMode.iconFilled)
            }
            .tint(Self.neutral)
        }
    }

    // MARK: List / clear / delete

    /// 'List': which tag this chat is filed under, still using the app's own `TagSheetRoot` (it holds both the tag editor and the lists).
    private func tagChatButton() -> some View {
        Button {
            PopopxHaptics.selection()
            setTagChatSheet()
        } label: {
            Label(Copy.swipeList, systemImage: "tag.fill")
        }
        .tint(Self.neutral)
    }

    /// The fractional height copies the upstream algorithm (`ChatListNavLink.swift:412-427`): 4 rows of slack + 44pt per tag, capped at 0.62.
    /// Screen height is read from the host window rather than `UIScreen.main` (deprecated as of iOS 16); if it cannot be had, fall back to the 0.62 cap itself.
    private func setTagChatSheet() {
        let reservedSpace: Double = 4 * 44
        let tagsSpace = Double(max(chatTagsModel.userTags.count, 3)) * 44
        let maxHeight: Double = 0.62
        let screenHeight = Double(SceneDelegate.windowStatic?.bounds.height ?? 0)
        let fraction = screenHeight > 0 ? min((reservedSpace + tagsSpace) / screenHeight, maxHeight) : maxHeight
        sheet = SomeSheet(
            content: {
                AnyView(
                    TagSheetRoot(chat: chat, editorAsRoot: chatTagsModel.userTags.isEmpty)
                        .environmentObject(chatTagsModel)
                )
            },
            id: "popopx.chatRow.listsSheet",
            fraction: fraction
        )
    }

    private func clearChatButton() -> some View {
        Button {
            PopopxHaptics.selection()
            AlertManager.shared.showAlert(clearChatAlert())
        } label: {
            Label(Copy.swipeClear, systemImage: "gobackward")
        }
        .tint(Self.irreversible)
    }

    private func clearNoteFolderButton() -> some View {
        Button {
            PopopxHaptics.selection()
            AlertManager.shared.showAlert(clearNoteFolderAlert())
        } label: {
            Label(Copy.swipeClear, systemImage: "gobackward")
        }
        .tint(Self.irreversible)
    }

    /// Delete contact: two-level confirmation, the second level being the 'keep the chats / delete the contact + notify them / do not notify' screen.
    /// This chain requires three callback channels, so the three states below must stay on this row.
    private func deleteContactButton(_ contact: Contact) -> some View {
        Button {
            PopopxHaptics.selection()
            deleteContactDialog(
                chat,
                contact,
                dismissToChatList: false,
                showAlert: { alert = $0 },
                showActionSheet: { actionSheet = $0 },
                showSheetContent: { sheet = $0 }
            )
        } label: {
            Label(Copy.swipeDelete, systemImage: "trash.fill")
        }
        .tint(Self.destructive)
    }

    private func deleteGroupChatButton(_ groupInfo: GroupInfo) -> some View {
        Button {
            PopopxHaptics.selection()
            AlertManager.shared.showAlert(deleteGroupAlert(groupInfo))
        } label: {
            Label(Copy.swipeDelete, systemImage: "trash.fill")
        }
        .tint(Self.destructive)
    }

    private func leaveGroupChatButton(_ groupInfo: GroupInfo) -> some View {
        Button {
            PopopxHaptics.selection()
            AlertManager.shared.showAlert(leaveGroupAlert(groupInfo))
        } label: {
            Label(Copy.swipeLeave, systemImage: "rectangle.portrait.and.arrow.right.fill")
        }
        .tint(Self.neutral)
    }

    /// 'Join': the group and channel at the invited setting. The one that joins incognito swaps to the mask icon, on upstream's same criterion.
    private func joinGroupButton(_ groupInfo: GroupInfo) -> some View {
        Button {
            PopopxHaptics.selection()
            joinGroup(groupInfo.groupId) {}
        } label: {
            Label(
                Copy.swipeJoin,
                systemImage: chat.chatInfo.incognito ? "theatermasks" : "ipad.and.arrow.forward"
            )
        }
        .tint(Self.connect)
    }

    private func archiveAllReportsButton() -> some View {
        Button {
            PopopxHaptics.selection()
            AlertManager.shared.showAlert(archiveAllReportsAlert())
        } label: {
            Label(Copy.swipeArchiveReports, systemImage: "archivebox")
        }
        .tint(Self.neutral)
    }

    /// 'More': collected into the action sheet past 3 buttons. Its content matches upstream's `moreOptionsButton` (:429-460) sentence by sentence.
    private func moreOptionsButton(_ canShowGroupDelete: Bool, _ groupInfo: GroupInfo) -> some View {
        Button {
            PopopxHaptics.selection()
            var buttons: [ActionSheet.Button] = [
                .default(Text(Copy.swipeClear)) {
                    AlertManager.shared.showAlert(clearChatAlert())
                }
            ]
            if chat.chatStats.reportsCount > 0
                && groupInfo.membership.memberRole >= .moderator && groupInfo.ready {
                buttons.append(.default(Text(Copy.swipeArchiveReports)) {
                    AlertManager.shared.showAlert(archiveAllReportsAlert())
                })
            }
            if canShowGroupDelete, groupInfo.canDelete {
                buttons.append(.destructive(Text(Copy.swipeDelete)) {
                    AlertManager.shared.showAlert(deleteGroupAlert(groupInfo))
                })
            }
            buttons.append(.cancel())
            actionSheet = SomeActionSheet(
                actionSheet: ActionSheet(
                    title: Text(canShowGroupDelete ? Copy.swipeMoreDeleteTitle : Copy.swipeMoreTitle),
                    buttons: buttons
                ),
                id: "popopx.chatRow.moreOptions"
            )
        } label: {
            Label(Copy.swipeMore, systemImage: "ellipsis")
        }
        .tint(Self.neutral)
    }

    // MARK: Incoming requests and connection setup

    private func acceptContactRequestButton(_ contactRequestId: Int64, incognito: Bool) -> some View {
        Button {
            PopopxHaptics.selection()
            Task { await acceptContactRequest(incognito: incognito, contactRequestId: contactRequestId) }
        } label: {
            Label(
                incognito ? Copy.swipeAcceptIncognito : Copy.swipeAccept,
                systemImage: incognito ? "theatermasks.fill" : "checkmark"
            )
        }
        .tint(Self.connect)
    }

    private func rejectContactRequestButton(_ contactRequestId: Int64) -> some View {
        Button {
            PopopxHaptics.selection()
            AlertManager.shared.showAlert(rejectContactRequestAlert(contactRequestId))
        } label: {
            Label(Copy.swipeReject, systemImage: "multiply")
        }
        .tint(Self.destructive)
    }

    private func acceptMemberContactRequestButton(_ contact: Contact) -> some View {
        Button {
            PopopxHaptics.selection()
            acceptMemberContactRequest(contact)
        } label: {
            Label(Copy.swipeAccept, systemImage: "checkmark")
        }
        .tint(Self.connect)
    }

    private func rejectMemberContactRequestButton(_ contact: Contact) -> some View {
        Button {
            PopopxHaptics.selection()
            showRejectMemberContactRequestAlert(contact)
        } label: {
            Label(Copy.swipeReject, systemImage: "multiply")
        }
        .tint(Self.destructive)
    }

    private func deleteContactConnectionButton(_ contactConnection: PendingContactConnection) -> some View {
        Button {
            PopopxHaptics.selection()
            AlertManager.shared.showAlert(deleteContactConnectionAlert(contactConnection))
        } label: {
            Label(Copy.swipeDelete, systemImage: "trash.fill")
        }
        .tint(Self.destructive)
    }

    private func contactConnectionNameButton() -> some View {
        Button {
            PopopxHaptics.selection()
            showContactConnectionInfo = true
        } label: {
            Label(Copy.swipeName, systemImage: "pencil")
        }
        .tint(Self.connect)
    }

    // MARK: Confirmation dialogs

    // The English source sentences of the five confirmation dialogs are copied word for word from upstream `ChatListNavLink.swift:560-632`: these Keys are in the 16 language catalogs
    // with translations already, and writing them again would only add a set of keys nobody translated, making the same thing speak two ways in two screens.

    private func clearChatAlert() -> Alert {
        Alert(
            title: Text("Clear conversation?"),
            message: Text(chat.chatInfo.displayName + "\n\n")
                + Text("All messages will be deleted - this cannot be undone! The messages will be deleted ONLY for you."),
            primaryButton: .destructive(Text(Copy.swipeClear)) {
                Task { await clearChat(chat) }
            },
            secondaryButton: .cancel()
        )
    }

    private func clearNoteFolderAlert() -> Alert {
        Alert(
            title: Text("Clear private notes?"),
            message: Text("All messages will be deleted - this cannot be undone!"),
            primaryButton: .destructive(Text(Copy.swipeClear)) {
                Task { await clearChat(chat) }
            },
            secondaryButton: .cancel()
        )
    }

    private func deleteGroupAlert(_ groupInfo: GroupInfo) -> Alert {
        let label: LocalizedStringKey = groupInfo.useRelays ? "Delete channel?" : groupInfo.businessChat == nil ? "Delete group?" : "Delete chat?"
        return Alert(
            title: Text(label),
            message: Text(chat.chatInfo.displayName + "\n\n") + deleteGroupAlertMessage(groupInfo),
            primaryButton: .destructive(Text(Copy.swipeDelete)) {
                Task { await deleteChat(chat) }
            },
            secondaryButton: .cancel()
        )
    }

    private func leaveGroupAlert(_ groupInfo: GroupInfo) -> Alert {
        let titleLabel: LocalizedStringKey = groupInfo.useRelays ? "Leave channel?" : groupInfo.businessChat == nil ? "Leave group?" : "Leave chat?"
        let messageLabel: LocalizedStringKey = (
            groupInfo.useRelays
            ? "You will stop receiving messages from this channel. Chat history will be preserved."
            : groupInfo.businessChat == nil
            ? "You will stop receiving messages from this group. Chat history will be preserved."
            : "You will stop receiving messages from this chat. Chat history will be preserved."
        )
        return Alert(
            title: Text(titleLabel),
            message: Text(chat.chatInfo.displayName + "\n\n") + Text(messageLabel),
            primaryButton: .destructive(Text(Copy.swipeLeave)) {
                Task { await leaveGroup(groupInfo.groupId) }
            },
            secondaryButton: .cancel()
        )
    }

    private func archiveAllReportsAlert() -> Alert {
        Alert(
            title: Text("Archive all reports?"),
            message: Text("All reports will be archived for you."),
            primaryButton: .destructive(Text("Archive")) {
                Task { await archiveAllReportsForMe() }
            },
            secondaryButton: .cancel()
        )
    }

    private func archiveAllReportsForMe() async {
        do {
            if case let .groupChatItemsDeleted(user, groupInfo, chatItemIDs, _, member) = try await apiArchiveReceivedReports(groupId: chat.chatInfo.apiId) {
                await groupChatItemsDeleted(user, groupInfo, chatItemIDs, member)
            }
        } catch {
            logger.error("archiveAllReportsForMe error: \(responseError(error))")
        }
    }
}

// MARK: - Channel badges

@MainActor private struct PopopxChannelBadge: View {
    let channel: PopopxRowChannel

    var body: some View {
        switch channel {
        case .smp:
            label(symbol: Copy.smpSymbol, text: nil, tint: PopopxPalette.brand, spoken: Copy.channelSmp)
        case let .mesh(hops):
            // §1.4 item 3: a hops badge always carries the number; the colour is decoration only.
            label(
                symbol: Copy.meshSymbol,
                text: Copy.hopsSuffix(hops),
                tint: PopopxPalette.meshInk,
                spoken: Copy.channelMesh(hops)
            )
        case .awaitingRelay:
            label(symbol: Copy.relaySymbol, text: Copy.awaitingRelay, tint: PopopxPalette.labelSecondary, spoken: Copy.awaitingRelay)
        case .unreachable:
            label(symbol: nil, text: Copy.unreachable, tint: PopopxPalette.labelSecondary, spoken: Copy.unreachable)
        case .checking:
            label(symbol: nil, text: Copy.checking, tint: PopopxPalette.labelSecondary, spoken: Copy.checking)
        case .none:
            EmptyView()
        }
    }

    /// A row element with a single badge: the icon is decoration, and the meaning is always spelled out by `accessibilityLabel`.
    @ViewBuilder private func label(symbol: String?, text: String?, tint: Color, spoken: String) -> some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            if let symbol {
                // §6: badge symbols are no lighter than medium weight; the same writing as PopopxControls.swift:320-322.
                Image(systemName: symbol)
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            if let text {
                // Digits use `metric` (monospaced), the Chinese caption uses `microTag`.
                Text(verbatim: text)
                    .font(text.contains(where: \.isNumber) ? PopopxType.metric : PopopxType.microTag)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

// MARK: - Unread mark

@MainActor private struct PopopxUnreadMark: View {
    @ObservedObject var chat: Chat

    /// Unread does not use `brand`: cyan and violet must not share a row (§1.1), and the channel badge is this row's colour bearer.
    /// The inverted `label` fill + `card` ink is far above 4.5:1 in both modes and carries no channel semantics at all.
    private var fill: Color { PopopxPalette.label }
    private var ink: Color { PopopxPalette.card }

    var body: some View {
        let count = chat.chatStats.unreadCount
        let unread = count > 0 || chat.chatStats.unreadChat
        if unread {
            if count > 0 {
                Text(verbatim: count > 99 ? "99+" : "\(count)")
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(ink)
                    .padding(.horizontal, PopopxMetrics.space2XS)
                    .frame(minWidth: PopopxMetrics.spaceL, minHeight: PopopxMetrics.spaceS)
                    .background(fill, in: .capsule)
                    .accessibilityLabel(Copy.unreadCount(count))
            } else {
                Circle()
                    .fill(fill)
                    .frame(width: PopopxMetrics.spaceXS, height: PopopxMetrics.spaceXS)
                    .accessibilityLabel(Copy.unreadDot)
            }
        }
    }
}

// MARK: - Empty state

@MainActor private struct PopopxChatsEmptyState: View {
    let searching: Bool
    let query: String
    let hasAnyChat: Bool
    let filter: PopopxChatFilter
    /// With the list axis filtering: 'how many chats this setting has to begin with' (before the channel axis is applied); nil when it is not.
    /// The empty state must make clear 'why it is empty', and 'this list is empty to begin with' versus 'this setting has no Cabin chats'
    /// are two different statements - only with this number can they be told apart, and only then is a stocked list not described as an empty one.
    let listScoped: Int?
    let fuseOn: Bool
    let radioUsable: Bool
    let bindingsLoaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            Text(title)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
            Text(detail)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PopopxMetrics.spaceM)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay {
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.vertical, PopopxMetrics.spaceS)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if searching { return Copy.emptySearchTitle }
        if !hasAnyChat { return Copy.emptyNoneTitle }
        return Copy.emptyFilteredTitle
    }

    /// The empty state must say clearly 'why it is empty': the four settings have different explanations, and none of them gets a 'coming soon'.
    private var detail: String {
        if searching { return Copy.emptySearchDetail(query) }
        if !hasAnyChat { return Copy.emptyNoneDetail }
        // Answer the list axis first: when this setting has no chats to begin with, no channel filter can produce a result, and
        // at that point talking about 'ready SMP connections all carry an indigo-violet lock badge' sends people the wrong way.
        if let listScoped, listScoped == 0 { return Copy.emptyListDetail }
        switch filter {
        case .all:
            return Copy.emptyAllDetail
        case .online:
            return Copy.emptyOnlineDetail
        case .meshOffline:
            if !fuseOn { return Copy.emptyMeshFuseOffDetail }
            if !bindingsLoaded { return Copy.emptyMeshLoadingDetail }
            if !radioUsable { return Copy.emptyMeshRadioOffDetail }
            return Copy.emptyMeshDetail(ChatsListView.maxMeshHops)
        case .channel:
            return Copy.emptyChannelDetail
        }
    }
}

// MARK: - Chat room destination page

/// The real destination page: `ChatView` and its five inputs copy `Shared/Views/ChatList/ChatListView.swift:641` verbatim.
/// Fetched by id at the moment of use, so it tells the truth when a chat is deleted before opening instead of giving an empty shell of a chat room.
@MainActor private struct PopopxChatRoomDestination: View {
    @EnvironmentObject private var chatModel: ChatModel
    let chatId: ChatId

    @State private var scrollToItemId: ChatItem.ID?

    var body: some View {
        if let chat = chatModel.getChat(chatId) {
            let im = ItemsModel.shared
            ChatView(
                chat: chat,
                im: im,
                mergedItems: BoxedValue(MergedItems.create(im, [])),
                floatingButtonModel: FloatingButtonModel(im: im),
                scrollToItemId: $scrollToItemId
            )
        } else {
            Text(Copy.chatGone)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PopopxPalette.base)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Copy

/// All user-visible Chinese is declared once here (§2.5 item 3: the atomic control library ships no copy, the page supplies its own).
private enum Copy {
    /// The top-bar row's copy lives in `PopopxTelemetryCopy`; only the filter bar and this page's own short sentences remain here.
    /// The source is the English sentence itself and that English sentence is the Key (`en.lproj` writes none by convention); the 16 translation catalogs each write their own wording.
    static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX chat list")
    }

    static let searchPrompt = key("Search conversations")
    static let searchOpen = key("Search")
    static let searchClear = key("Clear the search text")
    static let searchClose = key("Close search")
    static let filterGroupLabel = key("Chat channel filter")
    static let filterAll = key("All")
    static let filterOnline = key("Online encrypted")
    static let filterMeshOffline = key("Cabin offline")
    /// The fourth capsule reuses an existing entry: `"Channels"` is already in the 7 catalogs that have translations (de/es/fr/hu/it/ru/zh-Hans,
    /// in zh-Hans it is 'Channels', :1324), and the remaining catalogs fall back to the source sentence itself (English) just like en.
    /// Besides, it is the shortest correct wording among this round's four capsules (two Chinese glyphs, as wide as 'All' - see the filter bar's width budget).
    static let filterChannel = key("Channels")

    // The 'List' capsule (device round 10, task A, added back). Only two of the four sentences are new Keys, and the other two
    // deliberately reuse source sentences already translated in the catalogs: `"Unread"` is the very word this page's swipe button uses
    // (`swipeUnread`), and `Copy.filterAll` is the same wording as the first capsule on the left - saying one meaning two ways in two places
    // costs far more than saving one Key.
    /// This capsule's name when there is no list filter. Once a list is chosen the capsule shows the list's own name (that is user data,
    /// rendered with `Text(verbatim:)` and kept out of the copy table).
    static let listsChip = key("Lists")
    /// The readable name of the whole control (the sentence VoiceOver speaks when it lands on it).
    static let listsGroupLabel = key("Chat lists")
    static let listsUnread = key("Unread")
    /// The honest line in the menu when not a single list exists yet: it says there is none and also where to create one.
    static let listsEmptyHint = key("No lists yet. Choose List from a chat's swipe actions to create one.")
    /// The empty-state sentence 'this setting is empty to begin with' (kept separate from the four channel settings' own explanations).
    static let emptyListDetail = key("This list has no chats yet.")

    /// Same destination as the top-right button under 'Contacts → My encrypted groups', so the two share one Key:
    /// the two titles cannot each say their own sentence (`PopopxContactsView`'s `createGroupEntry`).
    static let createGroupTitle = key("Create an encrypted group")
    /// The title of the create-channel page. `AddChannelView`'s own row button and the old menu's title both use this sentence
    /// (`Shared/Views/NewChat/NewChatMenuButton.swift:99`), so no new sentence is coined.
    static let createChannelTitle = key("Create public channel")
    static let scanTitle = key("Scan QR code")

    // Badges: the three symbols fixed by the icon vocabulary (§6); only one appears per row.
    static let smpSymbol = "lock.shield.fill"
    static let meshSymbol = "antenna.radiowaves.left.and.right"
    static let relaySymbol = "clock"

    static let channelSmp = key("Online encryption · SMP")
    static let awaitingRelay = key("Awaiting relay")
    static let unreachable = key("Unreachable")
    static let checking = key("Loading…")

    static func hopsSuffix(_ hops: Int) -> String { "· \(hops)" }
    static func channelMesh(_ hops: Int) -> String {
        hops == 0 ? key("Cabin offline, direct (0 hops)") : String(format: key("Cabin offline, %lld hops"), hops)
    }
    static func filterValue(_ count: Int, hopCap: Int, isMesh: Bool) -> String {
        isMesh
            ? String(format: key("%1$lld bound chats, relay limit %2$lld hops"), count, hopCap)
            : String(format: key("%lld chats"), count)
    }

    static func unreadCount(_ count: Int) -> String { String(format: key("%lld unread"), count) }
    static let unreadDot = key("Has unread messages")

    static let previewHidden = key("Message previews are off")
    static let noMessagesYet = key("No messages yet")
    static let noNotesYet = key("No notes yet")
    static let deletedContent = key("This message was deleted")
    static let noTextContent = key("(No text content)")
    static let monogramFallback = "？"

    static let emptySearchTitle = key("No matching chats")
    static let emptyNoneTitle = key("No chats yet")
    static let emptyFilteredTitle = key("No chats in this filter yet")

    static func emptySearchDetail(_ query: String) -> String { String(format: key("No chat is named %@. Try another word, or switch back to All."), query) }
    static let emptyNoneDetail = key("Tap the plus button at the top right to add a friend, start a group, or scan a QR code; your first chat appears here.")
    static let emptyAllDetail = key("All your chats are being recycled. Refresh in a moment.")
    static let emptyOnlineDetail = key("Ready SMP connections carry the indigo lock badge; connections that are not up appear only under All.")
    static let emptyMeshFuseOffDetail = key("Cabin offline mesh is switched off. Turn on the master switch at the top, and contacts bound to a Bluetooth identity come back to this filter.")
    static let emptyMeshLoadingDetail = key("Reading the Cabin identity bindings saved on this device.")
    static let emptyMeshRadioOffDetail = key("Bluetooth is unavailable right now, so bound contacts wait as awaiting relay; hop counts appear once the radio is back.")
    static func emptyMeshDetail(_ hopCap: Int) -> String { String(format: key("No contacts are bound to a Cabin Bluetooth identity yet. After a face-to-face add or a QR scan, offline chats of up to %lld hops appear here."), hopCap) }
    static let emptyChannelDetail = key("No channels yet. Create a public channel with the plus button above, or join one from a link or a QR code.")

    static let serviceStarting = key("The encrypted service is starting; chats open in a moment.")
    static let serviceDisconnected = key("The encrypted service has stopped. Start it in Settings → Chat data, or restart the app; chats cannot be opened until it runs.")
    static let chatGone = key("This chat has been deleted, or it has not finished loading.")

    // Swipe actions. All seventeen of these Keys follow upstream `ChatListNavLink.swift`'s English source sentences:
    // they are already in the 16 language catalogs (in zh-Hans respectively: Read / Unread / Favorite / Unfav. / Clear /
    // Delete / Join / Leave / Accept / Accept incognito chat / Reject / List / More / Archive report / Name /
    // Clear group? / Clear or delete group?'), and this page starts no second set of wordings.
    // The mute button is not here: its three wordings (Mute / Mute all / Unmute) are given by `MsgFilter.text(mentions:)` itself;
    // writing them again would only leave the chat info page and the list each saying their own.
    // ⚠️ Known defect, not fixed in this round: the zh translations of the two Keys `"Favorite"` / `"Unfav."` came in with upstream as
    // 'most liked' / 'unmost liked', while what this button does is **pin the chat**, so it should read 'pin' / 'unpin'.
    // Swapping in a new Key would only be worse (a key without a translation shows the bare English source in the Chinese UI), so what must change
    // is the value of those two catalog rows, not the key name here - and `.lproj/Localizable.strings` is a red line this round.
    static let swipeRead = key("Read")
    static let swipeUnread = key("Unread")
    static let swipeFavorite = key("Favorite")
    static let swipeUnfavorite = key("Unfav.")
    static let swipeClear = key("Clear")
    static let swipeDelete = key("Delete")
    static let swipeJoin = key("Join")
    static let swipeLeave = key("Leave")
    static let swipeAccept = key("Accept")
    static let swipeAcceptIncognito = key("Accept incognito")
    static let swipeReject = key("Reject")
    static let swipeList = key("List")
    static let swipeMore = key("More")
    static let swipeArchiveReports = key("Archive reports")
    static let swipeName = key("Name")
    static let swipeMoreTitle = key("Clear group?")
    static let swipeMoreDeleteTitle = key("Clear or delete group?")

    static let unnamedIdentity = key("Unnamed identity")
    static func identitySwitched(_ name: String) -> String { String(format: key("Switched to identity %@"), name) }
    static let identitySwitchFailed = key("Switching identity failed. Try again.")
}

// MARK: - Previews

#if DEBUG
// The stack is built by this page itself (see 'who owns the stack' at the head of the file), so the preview no longer wraps a NavigationStack.
struct ChatsListView_Previews: PreviewProvider {
    static var previews: some View {
        ChatsListView()
            .environmentObject(ChatModel.shared)
            .environmentObject(AppTheme.shared)
    }
}

struct ChatsListViewDark_Previews: PreviewProvider {
    static var previews: some View {
        ChatsListView()
            .environmentObject(ChatModel.shared)
            .environmentObject(AppTheme.shared)
            .preferredColorScheme(.dark)
    }
}
#endif
