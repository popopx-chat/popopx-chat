# POPOPX Chat iOS -- Navigation Architecture

> Technical specification for the navigation stack, deep linking, sheet presentation, and call overlay.
>
> Related specs: [Chat List](chat-list.md) | [Chat View](chat-view.md) | [State Management](../state.md) | [README](../README.md)
> Related product: [Product Overview](../../product/README.md)

**Source:** [`ContentView.swift`](../../Shared/ContentView.swift) | [`NewChatView.swift`](../../Shared/Views/NewChat/NewChatView.swift) | [`SettingsView.swift`](../../Shared/Views/UserSettings/SettingsView.swift) | [`OnboardingView.swift`](../../Shared/Views/Onboarding/OnboardingView.swift) | [`UserProfilesView.swift`](../../Shared/Views/UserSettings/UserProfilesView.swift)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Root View -- ContentView](#2-root-view)
3. [Navigation Stack](#3-navigation-stack)
4. [Sheet Presentation](#4-sheet-presentation)
5. [Deep Linking](#5-deep-linking)
6. [Call Overlay](#6-call-overlay)
7. [Authentication Gate](#7-authentication-gate)
8. [Onboarding Flow](#8-onboarding-flow)

---

## 1. Overview

The app's navigation follows a hierarchical model with a single navigation stack rooted in `ContentView`. Modal sheets and full-screen overlays augment the primary navigation path.

```
SimpleXApp
└── ContentView (root)
    ├── Authentication gate (LocalAuthView / SetAppPasscodeView)
    ├── Onboarding flow (if first launch / migration)
    ├── Main content
    │   └── NavigationStack
    │       ├── ChatListView (root of stack)
    │       │   ├── ChatView (pushed)
    │       │   │   ├── ChatInfoView / GroupChatInfoView (.appSheet, modal)
    │       │   │   └── ChatItemInfoView (.sheet, modal)
    │       │   └── ContactConnectionInfo (.appSheet, modal)
    │       └── Settings views (pushed)
    ├── Sheets (modal)
    │   ├── UserPicker
    │   ├── NewChatView
    │   ├── WhatsNew / Notices
    │   └── Settings sub-views
    └── Overlays (always on top)
        ├── Active call banner (when call active)
        └── ActiveCallView (full-screen call)
```

---

## 2. Root View -- [`ContentView`](../../Shared/ContentView.swift#L26)

**File**: [`Shared/ContentView.swift`](../../Shared/ContentView.swift)

`ContentView` is the root view injected by `SimpleXApp`. It manages:

### [Environment](../../Shared/ContentView.swift#L25-L37)
- `@EnvironmentObject var chatModel: ChatModel`
- `@EnvironmentObject var theme: AppTheme`
- `@Environment(\.scenePhase) var scenePhase`

### [Key State](../../Shared/ContentView.swift#L35-L52)
| Property | Type | Purpose |
|----------|------|---------|
| [`contentAccessAuthenticationExtended`](../../Shared/ContentView.swift#L37) | `Bool` | Passed at init to avoid re-render timing issues |
| [`automaticAuthenticationAttempted`](../../Shared/ContentView.swift#L40) | `Bool` | Whether biometric auth was auto-attempted |
| [`waitingForOrPassedAuth`](../../Shared/ContentView.swift#L53) | `Bool` | Whether auth gate should show |
| [`chatListUserPickerSheet`](../../Shared/ContentView.swift#L54) | `UserPickerSheet?` | Active user picker sheet |

### [View Selection Logic](../../Shared/ContentView.swift#L63-L83)

```swift
// Simplified decision tree in ContentView.body:
if !prefPerformLA || accessAuthenticated {
    contentView()   // Main app content
} else {
    lockButton()    // Authentication required
}
```

The [`contentView()`](../../Shared/ContentView.swift#L174) function further decides:
- If `chatModel.onboardingStage != .onboardingComplete`: show [onboarding](../../Shared/ContentView.swift#L177)
- If `chatModel.migrationState != nil`: show migration UI
- Otherwise: show `ChatListView` in a navigation container

---

## 3. Navigation Stack

### iOS Version Compatibility

**File**: [`Shared/Views/ChatList/ChatListView.swift`](../../Shared/Views/ChatList/ChatListView.swift#L204)

The deployment target is iOS 17.0, so `NavigationStack` is used directly and the former
`NavStackCompat` wrapper (needed while the app still supported iOS 15) was removed. The chat
list root pushes `ChatView` through a `NavigationPath` derived from `chatModel.chatId`:

```swift
// ChatListView: path is [true] while a chat is open, and an empty path clears chatId
NavigationStack(path: Binding(
    get: { chatModel.chatId != nil ? [true] : [] },
    set: { path in if path.isEmpty { chatModel.chatId = nil } }
)) {
    chatListView
        .navigationDestination(for: Bool.self) { _ in chatView() }
}
```

### Primary Navigation Path

```
ChatListView
    │
    ├─[tap chat]─→ ChatView
    │                  │
    │                  ├─[tap info]─→ ChatInfoView (direct)
    │                  │              └─→ VerifyCodeView, etc.
    │                  │
    │                  ├─[tap info]─→ GroupChatInfoView (group)
    │                  │              ├─→ GroupMemberInfoView
    │                  │              ├─→ GroupProfileView
    │                  │              └─→ GroupLinkView
    │                  │
    │                  └─[tap message info]─→ ChatItemInfoView
    │
    ├─[tap connection]─→ ContactConnectionInfo
    │
    └─[settings]─→ SettingsView
                       ├─→ NotificationsView
                       ├─→ NetworkAndServers
                       ├─→ AppearanceSettings
                       ├─→ PrivacySettings
                       ├─→ DatabaseView
                       └─→ UserProfilesView
```

### Servers pages push by value, registered at the stack root

[`SettingsView`](../../Shared/Views/UserSettings/SettingsView.swift#L431) and
[`AddChannelView`](../../Shared/Views/NewChat/AddChannelView.swift#L85) push a
[`ServersDestination`](../../Shared/Views/UserSettings/NetworkAndServers/NetworkAndServers.swift#L217); the relay and
message-server rows on the pages below push `ChatRelaySelection` / `ProtocolServerSelection`. The matching
`navigationDestination(for:)` declarations live on the stacks that host them -
[`UserPickerSheetView`](../../Shared/Views/ChatList/ChatListView.swift#L120) (settings sheet),
[`NewChatSheet`](../../Shared/Views/NewChat/NewChatMenuButton.swift#L106) (new chat sheet) and the Me tab's stack in
[`MainTabView`](../../Shared/Navigation/MainTabView.swift#L159) - and never on the page that
shows the rows: for one value type SwiftUI keeps only the registration nearest the stack root, so a per-page
declaration is inert and the row tap navigates nowhere. Each of those stacks owns the `SaveableSettings` whose
`servers` the destination closures bind ([ChatListView.swift#L83](../../Shared/Views/ChatList/ChatListView.swift#L83),
[NewChatMenuButton.swift#L59](../../Shared/Views/NewChat/NewChatMenuButton.swift#L59)), so the two entry paths edit the
same store.

The POPOPX settings tree ([`PopopxSettingsView`](../../Shared/Features/Settings/PopopxSettingsViews.swift)) keeps that
registration layout but does not use a `NavigationLink(value:)` for its own row. On device the row pushed by value
redrew the settings page and only released the pending value on the next navigation event (back), identically whether
the declarations lived on the settings page or on the stack root - the registration depth is not the variable. The row
is a plain `Button` that appends the value to an explicit `NavigationStack(path:)` owned by the hosting stack
([`PopopxSettingsNavTrack`](../../Shared/Navigation/MainTabView.swift#L107), injected by both live hosts), the same
deterministic mechanism `ChatModel.chatId` uses to open a chat. Pages below it still push by value.

### Navigation Trigger

Chat navigation is triggered by setting `ChatModel.chatId`:

```swift
// In ChatListNavLink:
ItemsModel.shared.loadOpenChat(chatId) {
    // This sets ChatModel.chatId = chatId after a 250ms delay
    // allowing navigation animation to start smoothly
}
```

---

## 4. Sheet Presentation

Sheets are presented modally on top of the navigation stack:

| Sheet | Trigger | Content |
|-------|---------|---------|
| UserPicker | Tap user avatar in nav bar | User list, settings shortcuts |
| [`NewChatView`](../../Shared/Views/NewChat/NewChatView.swift#L79) | Tap FAB / "+" button | Create link, scan QR, paste link, new group |
| WhatsNew | App update detected | Release notes |
| AddGroupView | "New Group" action | Group creation wizard |
| ConnectDesktopView | Settings > Desktop | Remote desktop pairing |
| MigrateFromDevice | Settings > Migration | Device export |
| MigrateToDevice | Onboarding migration | Device import |
| [LocalAuthView](../../Shared/ContentView.swift#L100) | App foreground after background | Biometric/passcode auth |

### Sheet Management

Sheets use SwiftUI `.sheet(item:)` or `.sheet(isPresented:)` modifiers on `ContentView` and `ChatListView`. Some sheets use the centralized [`AppSheetState.shared`](../../Shared/ContentView.swift#L536) observable for coordination:

```swift
class AppSheetState: ObservableObject {
    static let shared = AppSheetState()
    var scenePhaseActive: Bool = false
    // ... sheet state coordination
}
```

---

## 5. Deep Linking

### Notification Deep Link

When the user taps a notification:

1. `NtfManager.processNotificationResponse()` extracts the `chatId` from notification payload
2. If a different user: calls `changeActiveUser(userId:)`
3. Sets `ChatModel.chatId = chatId` to navigate to the conversation
4. If the app was in background: the notification response is stored in `ChatModel.notificationResponse` and processed when the app becomes active

### [URL Deep Link](../../Shared/ContentView.swift#L284)

POPOPX links (`popopx:/chat#...`) are handled via [`connectViaUrl()`](../../Shared/ContentView.swift#L465):

```swift
.onOpenURL { url in
    if AppChatState.shared.value == .active {
        chatModel.appOpenUrl = url      // Process immediately
    } else {
        chatModel.appOpenUrlLater = url // Process when active
    }
}
```

URL processing routes to the appropriate connection flow (join group, add contact, etc.) via [`planAndConnect()`](../../Shared/Views/NewChat/NewChatView.swift#L1320).

App links use the app's own scheme, `popopxchat:`, for everything that is not a connection link; the inherited `simplexchat:` is registered beside it and still recognised, so a link issued before the move opens. `connectViaUrl_()` branches on that scheme before the path switch, so an app link never reaches `planAndConnect()`, and `openAppLink()` dispatches on its path. A badge link (`popopxchat:/badge/code/<code>`) goes to `openBadgeLink()` in [`BadgesRedeemCodeView.swift`](../../Shared/Views/Badges/BadgesRedeemCodeView.swift), which presents `BadgesRedeemLinkView` as an app sheet. The sheet names the active profile and asks before redeeming, since any web page can send the link and a profile holds one badge at a time. On *Add badge* it redeems the code into that profile and then shows `BadgesView`; *Cancel* sends nothing. If that profile already shows a badge (read from `BadgeModel` when the sheet renders), which core would refuse, the sheet does not offer to add it: it says nothing was added, says where a code for another badge is (on the page it was bought on, under *Show code*), and offers *View your badge*; it cannot tell a repeated link for the badge it shows from another badge's code, so it asserts neither. While the code is being redeemed, *Dismiss* or a swipe closes the sheet without cancelling anything; if the redemption then succeeds with the sheet closed or covered, an alert says the badge was added and names the profile, unless the profile is hidden and no longer active, when nothing is shown (`showBadgeAddedAlert()`, which the store lane shares). While the sheet shows a redemption in flight (`isBadgeLinkIssuing()`), `connectViaUrl_()` ignores a further app link; otherwise it dismisses the sheets as for any link, which replaces an earlier badge link sheet. Any other path is a link type from a later version, and gets an alert asking to check for app updates. An app link can carry a secret, so `onOpenURL` logs it as "app link" rather than the URL.

### Call Deep Link

Call invitations from notifications:
1. `NtfManager` detects `ntfActionAcceptCall` action
2. Sets `ChatModel.ntfCallInvitationAction = (chatId, .accept)`
3. `ContentView` picks up the pending action and initiates the call

---

## 6. Call Overlay

The call UI overlays the entire app when a call is active:

### [Call Banner](../../Shared/ContentView.swift#L208)

When `ChatModel.activeCall != nil` and call is in connecting/active state:
- A banner appears at the top of ContentView (height: [`callTopPadding = 40`](../../Shared/ContentView.swift#L59))
- Shows contact name, call duration, tap to return to full-screen call
- Main content is padded down to accommodate the banner

### [Full-Screen Call View](../../Shared/ContentView.swift#L190)

When `ChatModel.showCallView == true`:
- `ActiveCallView` covers the entire screen as a ZStack overlay
- Contains local/remote video, controls (mute, camera, speaker, end)
- PiP mode: `ChatModel.activeCallViewIsCollapsed` collapses to mini view
- Call view is always rendered on top of navigation and sheets

```swift
// In ContentView.allViews():
ZStack {
    contentView()
        .padding(.top, showCallArea ? callTopPadding : 0)

    if showCallArea, let call = chatModel.activeCall {
        VStack {
            activeCallInteractiveArea(call)
            Spacer()
        }
    }

    if chatModel.showCallView, let call = chatModel.activeCall {
        callView(call)  // Full screen overlay
    }
}
```

---

## 7. Authentication Gate

### [Local Authentication](../../Shared/ContentView.swift#L375)

When [`DEFAULT_PERFORM_LA`](../../Shared/ContentView.swift#L44) is enabled:

1. App enters background: `chatModel.contentViewAccessAuthenticated = false`
2. App returns to foreground: `ContentView` shows [`lockButton()`](../../Shared/ContentView.swift#L243) instead of content
3. User taps lock button: [`LocalAuthView`](../../Shared/ContentView.swift#L100) presented
4. On successful auth: `chatModel.contentViewAccessAuthenticated = true`, content revealed

### Authentication Methods
- Face ID / Touch ID (via `LocalAuthentication` framework)
- Custom numeric passcode
- Custom alphanumeric passcode

### [Extended Authentication](../../Shared/ContentView.swift#L367)
- After successful auth, a grace period prevents re-auth for brief background/foreground cycles ([`unlockedRecently()`](../../Shared/ContentView.swift#L367))
- [`contentAccessAuthenticationExtended`](../../Shared/ContentView.swift#L37) is computed at `ContentView.init` to avoid render-time race conditions
- The `enteredBackgroundAuthenticated` timestamp tracks when the app was last authenticated in background

---

## 8. [Onboarding Flow](../../Shared/Views/Onboarding/OnboardingView.swift#L13)

First-launch experience controlled by [`ChatModel.onboardingStage`](../../Shared/Model/ChatModel.swift#L388):

```swift
enum OnboardingStage: String, Identifiable {
    case step1_POPOPXInfo              // Welcome screen
    case step2_CreateProfile           // Create the first anonymous identity
    case step3_CreatePOPOPXAddress     // deprecated
    case step3_ChooseServerOperators   // Routing: push mode + offline mesh + relay operators
    case step4_SetNotificationsMode    // deprecated
    case step4_NetworkCommitments      // Commitments, launch protection, privacy policy / terms
    case onboardingComplete            // Normal operation
}
```

Each stage is a dedicated view presented in place of `ChatListView` within [`ContentView`](../../Shared/ContentView.swift#L26).

The four live screens are pushed one after another (`POPOPXInfo` → `CreateFirstProfile` → `YourNetworkView` → `OnboardingConditionsView`), each rendering the shared `PopopxOnboardingHeader` progress pill; the header and the offline `PopopxLegalDocumentSheet` reader live in [`OnboardingView.swift`](../../Shared/Views/Onboarding/OnboardingView.swift) alongside the stage enum. Accepting on the last screen records the conditions with `acceptConditions`/`setServerOperators`, idempotently issues the pioneer trial badge, then swaps the stage inside `dismissAllSheets(animated: false)` + a deferred `DispatchQueue.main.async`, which is what keeps the deep nav stack from being torn down inside its own event handler.

Migration state (`ChatModel.migrationState != nil`) takes precedence over onboarding.

---

## 9. Channel Creation Flow (`AddChannelView`)

**Source:** [`Shared/Views/NewChat/AddChannelView.swift`](../../Shared/Views/NewChat/AddChannelView.swift)

### Entry Point

The live entry is the "Messages" tab "+" menu: [`PopopxPlusMenu`](../../Shared/Navigation/PopopxTelemetryHeader.swift)
calls `onCreateChannel`, which sets `showsCreateChannel` in
[`ChatsListView`](../../Shared/Features/Chats/ChatsListView.swift#L281) and pushes `AddChannelView` through
`navigationDestination(isPresented:)`. The same sentence still exists in the legacy
[`NewChatMenuButton`](../../Shared/Views/NewChat/NewChatMenuButton.swift#L179), but its two hosts are not mounted by
the current shell: `ChatListView` (which shows that menu when `chatModel.chatRunning` is
`true` [`#L386`](../../Shared/Views/ChatList/ChatListView.swift#L386)) has no call site outside its own previews, and
`ChatHelp` is only pushed by `SettingsView` [`#L456`](../../Shared/Views/UserSettings/SettingsView.swift#L456), which
likewise has no call site.

The "Contacts" tab has the read side: the pinned
[`Subscribed channels` row](../../Shared/Features/Contacts/PopopxContactsView.swift#L304) pushes
`PopopxChannelsPage`, whose top-right entry pushes `NewChatView(selection: .connect, showQRCodeScanner: true)`
(the existing scan/paste page) for joining a channel by link or QR code.

### Three-Step Wizard

| Step | Function | Description |
|------|----------|-------------|
| 1. Profile | `profileStepView()` | Channel name input (`channelNameTextField()`), profile image picker. "Configure relays" link to `NetworkAndServers`. Validates via `canCreateProfile()` (non-empty + valid display name) and `checkHasRelays()`. |
| 2. Progress | `progressStepView(_:)` | Relay connection progress with `RelayProgressIndicator` (circular active/total or spinner). Expandable relay list with `relayStatusIndicator(_:)` (green/red/orange dots). Cancel via `cancelChannelCreation(_:)` which calls `apiDeleteChat`. |
| 3. Link | `linkStepView(_:)` | Wraps `GroupLinkView(isChannel: true)` for channel link sharing. |

### Key Functions

| Function | Scope | Description |
|----------|-------|-------------|
| `createChannel()` | private | Calls `apiNewPublicGroup(incognito:relayIds:groupProfile:)`, sets `ChannelRelaysModel` |
| `getEnabledRelays()` | private | Filters enabled/non-deleted relays, selects random 3 |
| `checkHasRelays()` | private | Validates at least one relay exists |
| `relayDisplayName(_:)` | module | name > domain > link host > fallback |
| `relayStatusIndicator(_:)` | module | Green/red/orange dot + status text |
| `RelayProgressIndicator` | module | Circular progress (active/total) or spinner |

## 10. Relay URL Interception

**Source:** [`Shared/ContentView.swift`](../../Shared/ContentView.swift#L472)

In `connectViaUrl_()`, relay address links (URL path `/r`) are intercepted before processing:

```swift
if path == "/r" {
    showAlert(NSLocalizedString("Relay address", ...),
              message: NSLocalizedString("This is a chat relay address, it cannot be used to connect.", ...))
    return
}
```

Similarly, in `planAndConnect()` (`NewChatView.swift`), `.popopxLink(_, .relay, _, _)` patterns trigger the same alert and block connection.

## 11. Channel-Specific NewChatView Behavior

**Source:** [`Shared/Views/NewChat/NewChatView.swift`](../../Shared/Views/NewChat/NewChatView.swift)

### Prepared Group Alert (`showPrepareGroupAlert`)

When `groupShortLinkInfo?.direct == false` (channel relay link), the prepare alert uses:
- Channel icon: `antenna.radiowaves.left.and.right.circle.fill`
- Title: "Open channel"
- Error: "Error opening channel"
- `apiPrepareGroup` call passes `directLink: false`
- Stores `groupShortLinkInfo.groupRelays` in `ChatModel.shared.channelRelayHostnames`

### Own Link Confirmation (`showOwnGroupLinkConfirmConnectSheet`)

For channels: shows "This is your link for channel" with only "Open channel" + "Cancel" buttons. No incognito or profile selection options.

### Known Group Alert (`showOpenKnownGroupAlert`)

For channels (`groupInfo.useRelays`): the title is "Open channel"; for groups, "Open group"; business chats keep "Open chat" / "Open new chat". Unless the chat is merely prepared (`nextConnectPrepared`) or a business chat, the alert shows an information line with the user's membership role (`memberRoleInformation`) in the secondary color: subscriber/contributor for channels, observer/member for groups, moderator/admin/owner for both.

---

## Source Files

| File | Path |
|------|------|
| Root view | [`Shared/ContentView.swift`](../../Shared/ContentView.swift) |
| App entry point | `Shared/POPOPXApp.swift` |
| Chat list (nav root) | [`Shared/Views/ChatList/ChatListView.swift`](../../Shared/Views/ChatList/ChatListView.swift#L204) |
| Nav link wrapper | `Shared/Views/ChatList/ChatListNavLink.swift` |
| User picker | `Shared/Views/ChatList/UserPicker.swift` |
| New chat view | [`Shared/Views/NewChat/NewChatView.swift`](../../Shared/Views/NewChat/NewChatView.swift) |
| Channel creation | [`Shared/Views/NewChat/AddChannelView.swift`](../../Shared/Views/NewChat/AddChannelView.swift) |
| New chat menu | [`Shared/Views/NewChat/NewChatMenuButton.swift`](../../Shared/Views/NewChat/NewChatMenuButton.swift) |
| Settings view | [`Shared/Views/UserSettings/SettingsView.swift`](../../Shared/Views/UserSettings/SettingsView.swift) |
| User profiles | [`Shared/Views/UserSettings/UserProfilesView.swift`](../../Shared/Views/UserSettings/UserProfilesView.swift) |
| Onboarding view | [`Shared/Views/Onboarding/OnboardingView.swift`](../../Shared/Views/Onboarding/OnboardingView.swift) |
| Active call view | `Shared/Views/Call/ActiveCallView.swift` |
| Local auth view | `Shared/Views/LocalAuth/LocalAuthView.swift` |
| Notification manager | `Shared/Model/NtfManager.swift` |
