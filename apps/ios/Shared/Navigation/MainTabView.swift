//
//  MainTabView.swift
//  POPOPX (iOS)
//
//  Phase four: the classic four-tab bottom navigation: Chats / Contacts / Cabin / Me.
//
//  This project previously had no bottom navigation TabView: in `Shared`, `TabView(selection:)` appeared in only 3 places, all of them paged content carousels
//  (WhatsNewView.swift:819, ChatItemInfoView.swift:94, OnboardingCards.swift:146), and the main interface was
//  `ContentView` laying `ChatListView` out directly. This file replaces the root content with a four-tab shell; all four pages are newly built in this phase,
//  and the old `Shared/Views/ChatList/ChatListView.swift` is kept as is and no longer mounted at the root.
//
//  Three structural decisions:
//
//  1. **The Chats tab carries its own NavigationStack; the other three tabs are wrapped by this file.**
//     The field that opens a conversation is `ChatModel.chatId` (ChatModel.swift:411), and the unified entry point that writes it is
//     `ItemsModel.loadOpenChat(_:)` (ChatModel.swift:113, write point :120) and `loadOpenChatNoWait` (:139/:148),
//     with callers including notifications (NtfManager.swift:81), deep link / connection setup (POPOPXAPI.swift:1091, :1825, :2182, :2849),
//     opening attachments (ChatModel.swift:1303) and creating a new contact (CIMemberCreatedContactView.swift:29).
//     And the only place in the whole project that turns that field into pushing one page is the old ChatListView's stack-path binding
//     (ChatListView.swift:210-217). That binding must stay inside the Chats page, or the four-tab shell would cut off opening a conversation from a notification.
//     Of the other three tabs: Contacts and Me carry only inline Sheets and are wrapped uniformly by the shell's NavigationStack (:134, :152); Cabin
//     has held its own `NavigationStack(path:)` since 2026-11-20, and from this round the root of that tab is `PopopxMeshPlazaRootView`
//     (with its own root stack, landing on the full-screen plaza inside the package, `PopopxCabinView.swift:218`), and the old panel became its full-height drawer,
//     so the shell here still hosts only the bare page (:148): the `path` that async push binds to belongs to the page inside the drawer itself.
//     The `navigationDestination` registrations for the three server sub-pages of Me / All settings are also mounted at this tab's stack root (:159-165):
//     a value-based link only recognises the stack that carries it, and the settings page is pushed from this page through a destination closure, so a closure-pushed page writing its own registration
//     does not take effect by a single line, which is the root cause of Relay servers merely redrawing All settings when tapped.
//
//  2. **Unread counts use existing interfaces only.** The Chats tab's badge goes through
//     `ChatModel.totalUnreadCountForAllUsers()` (ChatModel.swift:1187, including aggregation across anonymous identities),
//     and this file computes no second unread definition; the pending-confirmation counts of Cabin/pairing are presented on their own pages and not repeated on the tab label.
//
//  3. **Opening a conversation from another tab must first switch the tab to Chats.** The stack that presents the conversation lives inside the Chats page (decision 1), so after other pages
//     call `ItemsModel.shared.loadOpenChat(_:)`, this file uses `onChange(of: chatModel.chatId)`
//     to switch the selected tab over; without that line, a conversation row on the Contacts page does nothing at all while the Chats tab has never been visited.
//
//  Colours, font sizes and corner radii all come from `Shared/Theme/PopopxTheme.swift` (PopopxPalette / PopopxMetrics / PopopxType /
//  PopopxMaterial), and this file contains no bare colour value or bare font size. The tab syntax deliberately uses `TabView(selection:) + .tabItem`
//  (not deprecated, available on iOS 17) and not the `Tab {}` builder that only exists on iOS 18: the minimum version the main project resolves to was measured as
//  `IPHONEOS_DEPLOYMENT_TARGET = 17.0` (the pbxproj writes `$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)`, and
//  `xcodebuild -showBuildSettings` resolves it under SDK iphonesimulator27.2 to 17.0); meanwhile
//  `PopopxMeshKit/Package.swift:9` is still the `.iOS(.v15)` kept by ruling A, which is the package-side floor and does not reach here.
//  Conversely, `tabBarMinimizeBehavior` measured as **iOS 26.0+** (the gate log's own words:
//  "'tabBarMinimizeBehavior' is only available in iOS 26.0 or newer"), so it must be gated on a 17.0 target,
//  see `popopxTabBarKept()` at the end of the file: that is a branch that really exists, not dead code.
//
//  ⚠️ Another measured correction: `ENABLE_PREVIEWS = NO` does not exempt the body of `#Preview` from type checking, and the first error of the Phase 4 gate
//  came from the preview on the Cabin page. The `#Preview` in this file is compiled the same way, so changing it is the same as changing code.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The iron rule forbids scripts from modifying project.pbxproj.
//

import SwiftUI
import POPOPXChat

// MARK: - Tabs

/// The four tabs. The `Hashable` enum values serve directly as the `TabView` selection, avoiding a bare Int ordering.
enum PopopxTab: String, Hashable, CaseIterable {
    case chats
    case contacts
    case cabin
    case me

    var title: String {
        switch self {
        case .chats: return PopopxMainTabCopy.chats
        case .contacts: return PopopxMainTabCopy.contacts
        case .cabin: return PopopxMainTabCopy.cabin
        case .me: return PopopxMainTabCopy.me
        }
    }

    /// Icons carry recognition only, not colour: the selected colour is given uniformly by `tint` (§1.1, colours express channel semantics only).
    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .contacts: return "person.2"
        case .cabin: return "antenna.radiowaves.left.and.right"
        case .me: return "person.crop.circle"
        }
    }
}

// MARK: - The path of the All settings stack

/// The holder of the path of the stack that carries All settings. The two hosts each new up their own and never share: `MainTabView`'s Me tab
/// and `UserPickerSheetView` (Add friend / switch identity / settings). `PopopxSettingsView` reads it through
/// `@Environment(PopopxSettingsNavTrack.self)`, **deliberately with no default value**: a host that misses the injection crashes during development,
/// which is easier to find than a dead row that does nothing when tapped.
///
/// The type is written in this file rather than a new one: the iron rule forbids scripts from editing `project.pbxproj`, so new types are always folded into an already compiled file.
///
/// Reason for existing, from the 2026-11-20 on-device walkthrough, round 2: **the registration position is not the lever**.
/// Tapping Me / All settings / Relay and servers only redrew the current page and pushed only when Back was pressed, and both spellings failed:
/// first the registration was written in All settings itself (before `8dea049d3`), then it was moved up to the stack root (`8dea049d3`). The symptoms were word for word the same,
/// while ProtocolServersView.swift:295-298 states that for one type only the registration nearest the stack root is kept, so the second placement is the correct one.
/// What was broken was not resolution but the **activation** of the `NavigationLink(value:)` hop: it binds writing a value into the stack's path and finding the registration by value
/// into the same tap, so once the tap is swallowed by a row rebuild the value stays behind in an uncommitted transaction and only comes out on the next navigation event (Back).
/// The fix replaces that hop with the same deterministic push used by the track verified on a real device in the Chats tab: the stack root holds an explicit path
/// (`NavigationStack(path:)`), the row body is an ordinary `Button`, and a tap performs a single state assignment, the same mechanism by which
/// `ChatsListView.swift:209-212` opens a conversation from `chatModel.chatId`.
/// The four hops further down (yourServers / serverOperator / protocol servers / chat relay) are still value-based links, resolved by the three registrations at the stack root,
/// since they sit in the same stack as `NetworkAndServers` and are the only value-based stretch of this track.
@MainActor
@Observable
final class PopopxSettingsNavTrack {
    var path = NavigationPath()
}

// MARK: - Four-tab shell

@MainActor
struct MainTabView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @State private var selection: PopopxTab = .chats

    /// The in-memory copy of the servers for the Me / All settings / Relay and servers track, on the same definition as ChatListView.swift:83:
    /// whoever carries the stack holds the `SaveableSettings`, and the `serversDestination` closure binds to this very copy.
    /// The page itself asks whether to save when going back (NetworkAndServers.swift:149); this file does not handle saving.
    @StateObject private var meshServers = SaveableSettings()

    /// The path of the Me tab's stack: it carries the only value-based stretch (the three server pages), see `PopopxSettingsNavTrack`.
    @State private var meTrack = PopopxSettingsNavTrack()

    var body: some View {
        TabView(selection: $selection) {
            // Chats: brings its own NavigationStack (see decision 1 in the file header).
            ChatsListView()
                .tabItem { tabLabel(.chats) }
                .tag(PopopxTab.chats)
                .badge(unreadCount)

            NavigationStack {
                PopopxContactsView()
            }
            .tabItem { tabLabel(.contacts) }
            .tag(PopopxTab.contacts)

            // The Cabin tab lands directly on the full-screen plaza inside the package from this round on: the root is `PopopxMeshPlazaRootView`
            // (`PopopxCabinView.swift`), which brings its own root stack, so the shell still hosts only the bare page here. The old Cabin panel
            // (`PopopxCabinView`) is no longer the root of this tab; it is now the full-height drawer summoned by the capsule in the middle of the root top bar,
            // and the page inside the drawer keeps holding its own `NavigationStack(path:)` for unchanged reasons, it merely moved into the drawer:
            // its private chat pushes one more page after sending an offline connection invitation, the action is async, and only the
            // `path` bound to its own stack can keep pushing after that (the `NavigationStack(path: $path)` line at `PopopxCabinView.swift:507`);
            // Mounting it as a page of the root stack would give either two navigation bars or all four `path.append` calls landing nowhere, so the whole block is pressed in from outside
            // rather than pushed into it.
            // Real device round 8, task one: this tab is full-screen immersive (the four bottom-bar items step aside on the root screen, declared by the tab itself),
            // so the only cross-cutting navigation left in this tab is the Back button in the top-left corner of the top bar, and what it writes is the very `selection` below.
            // A binding is passed here rather than a newly minted routing object: `selection` is already the single source of truth for the selected tab (decision 3 and
            // the `onChange(of: chatModel.chatId)` below both write it), and wrapping one more layer in `@Observable` would create
            // a second holder; and an init missing one parameter fails to compile, which is easier to find than a button that does nothing (same reasoning as `PopopxSettingsNavTrack`
            // deliberately having no default value). The bottom bar's hidden declaration lives in the content of its own tab, not on the `TabView`, because
            // hanging it on the `TabView` would have to derive a value from `selection`, and that one statement would override `ChatsListView.swift:268/275/285/405`,
            // the per-page `.hidden` declarations named there (across the previous seven on-device walkthrough rounds, only those four placements, mounted this way, were signed off).
            PopopxMeshPlazaRootView(tabSelection: $selection)
                .tabItem { tabLabel(.cabin) }
                .tag(PopopxTab.cabin)

            NavigationStack(path: $meTrack.path) {
                PopopxMeView()
                    // The registrations for the three server pages are at the stack root (same definition as NetworkAndServers.swift:214-216
                    // and ProtocolServersView.swift:295-298: for one type only the registration nearest the stack root is kept),
                    // and they share those three types and those three functions with the old track at ChatListView.swift:120-128.
                    // The All settings / Relay and servers hop is no longer a value-based link but
                    // `Button { meTrack.path.append(.networkAndServers) }`; see `PopopxSettingsNavTrack`.
                    .navigationDestination(for: ServersDestination.self) { destination in
                        serversDestination(destination, ss: meshServers, servers: $meshServers.servers)
                    }
                    .navigationDestination(for: ProtocolServerSelection.self) { selection in
                        protocolServerDestination(selection, servers: $meshServers.servers)
                    }
                    .navigationDestination(for: ChatRelaySelection.self) { selection in
                        chatRelayDestination(selection, servers: $meshServers.servers)
                    }
            }
            .environment(meTrack)
            .tabItem { tabLabel(.me) }
            .tag(PopopxTab.me)
        }
        .tint(PopopxPalette.brand)
        .background(PopopxPalette.base)
        .toolbarBackground(PopopxMaterial.bar, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .popopxTabBarKept()
        .onChange(of: selection) { _, _ in
            PopopxHaptics.selection()
        }
        // Decision 3: whichever tab opens a conversation, it must land in the Chats tab to be presented.
        // The conversation page is driven by `ChatModel.chatId`, and the stack that turns it into a pushed page lives inside the Chats page (file-header decision 1);
        // the Contacts page calls `ItemsModel.shared.loadOpenChat(_:)` under the same convention
        // (PopopxContactsView.swift:243, :1067 -> ChatModel.swift:113 writes it at :120),
        // and if the Chats tab has never been visited that stack does not exist yet, so this onChange is the only place that catches it.
        .onChange(of: chatModel.chatId) { _, chatId in
            if chatId != nil { selection = .chats }
        }
    }

    /// Unread count: recomputed on every change to `ChatModel.chats` (ChatModel.swift:408). The definition reuses the existing function
    /// `totalUnreadCountForAllUsers()` (ChatModel.swift:1187, see spec/state.md#totalUnreadCountForAllUsers):
    /// it takes the matching count from each conversation's `enableNtfs` (all / mentions only), then adds up `users[].unreadCount` for the identities that are not the current one.
    /// This file computes no second unread definition.
    private var unreadCount: Int { chatModel.totalUnreadCountForAllUsers() }

    private func tabLabel(_ tab: PopopxTab) -> some View {
        Label(tab.title, systemImage: tab.symbol)
    }
}

// MARK: - Bottom bar behaviour

private extension View {
    /// From iOS 26 the bottom bar collapses automatically while scrolling; the four-tab classic navigation needs it to keep standing.
    /// On 17 to 25 this API does not exist, and those versions had no collapsing behaviour anyway, so it returns unchanged.
    @ViewBuilder
    func popopxTabBarKept() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.never)
        } else {
            self
        }
    }
}

// MARK: - Wording

enum PopopxMainTabCopy {
    static let chats = NSLocalizedString("Messages", comment: "")
    static let contacts = NSLocalizedString("Contacts", comment: "")
    static let cabin = NSLocalizedString("Cabin", comment: "")
    static let me = NSLocalizedString("Me", comment: "")
}

// MARK: - Previews

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
            .environmentObject(ChatModel.shared)
            .environmentObject(AppTheme.shared)
    }
}
