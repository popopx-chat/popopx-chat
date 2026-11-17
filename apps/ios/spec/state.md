# POPOPX Chat iOS -- State Management

**Source:** [`ChatModel.swift`](../Shared/Model/ChatModel.swift#L1-L1522) | [`ChatTypes.swift`](../POPOPXChat/ChatTypes.swift#L1-L6723)

> Technical specification for the app's state architecture: ChatModel, ItemsModel, Chat, ChatInfo, and preference storage.
>
> Related specs: [Architecture](architecture.md) | [API Reference](api.md) | [README](README.md)
> Related product: [Concept Index](../product/concepts.md)

---

## Table of Contents

1. [Overview](#1-overview)
2. [ChatModel -- Primary App State](#2-chatmodel)
3. [ItemsModel -- Per-Chat Message State](#3-itemsmodel)
4. [ChatTagsModel -- Tag Filtering State](#4-chattagsmodel)
5. [ChannelRelaysModel -- Channel Relay State](#5-channelrelaysmodel)
6. [Chat -- Single Conversation State](#6-chat)
7. [ChatInfo -- Conversation Metadata](#7-chatinfo)
8. [State Flow](#8-state-flow)
9. [Preference Storage](#9-preference-storage)

---

## 1. Overview

The app uses SwiftUI's `ObservableObject` pattern for reactive state management. The state hierarchy is:

```
ChatModel (singleton -- global app state)
├── currentUser: User?
├── users: [UserInfo]
├── chats: [Chat]                    (chat list)
├── chatId: String?                  (active chat ID)
├── im: ItemsModel.shared            (primary chat items)
├── secondaryIM: ItemsModel?         (secondary chat items, e.g. support scope)
├── activeCall: Call?
├── callInvitations: [ChatId: RcvCallInvitation]
├── deviceToken / savedToken / tokenStatus
├── notificationMode: NotificationsMode
├── onboardingStage: OnboardingStage?
├── migrationState: MigrationToState?
└── ... (50+ @Published properties)

ItemsModel (singleton + secondary instances -- per-chat message state)
├── reversedChatItems: [ChatItem]    (messages in reverse order)
├── chatState: ActiveChatState       (pagination/split state)
├── isLoading / showLoadingProgress
└── preloadState: PreloadState

Chat (per-conversation -- one per entry in chat list)
├── chatInfo: ChatInfo               (type + metadata)
├── chatItems: [ChatItem]            (preview items)
└── chatStats: ChatStats             (unread counts)

ChatTagsModel (singleton -- filter state)
├── userTags: [ChatTag]
├── activeFilter: ActiveFilter?
├── presetTags: [PresetTag: Int]
└── unreadTags: [Int64: Int]
```

---

## 2. [ChatModel](../Shared/Model/ChatModel.swift#L392-L1403)

**Class**: `final class ChatModel: ObservableObject`
**Singleton**: `ChatModel.shared`
**Source**: [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift#L392)

### Key Published Properties

#### App Lifecycle
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `onboardingStage` | `OnboardingStage?` | Current onboarding step | [L393](../Shared/Model/ChatModel.swift#L393) |
| `chatInitialized` | `Bool` | Whether chat has been initialized | [L402](../Shared/Model/ChatModel.swift#L402) |
| `chatRunning` | `Bool?` | Whether chat engine is running | [L403](../Shared/Model/ChatModel.swift#L403) |
| `chatDbChanged` | `Bool` | Whether DB was changed externally | [L404](../Shared/Model/ChatModel.swift#L404) |
| `chatDbEncrypted` | `Bool?` | Whether DB is encrypted | [L405](../Shared/Model/ChatModel.swift#L405) |
| `chatDbStatus` | `DBMigrationResult?` | DB migration status | [L406](../Shared/Model/ChatModel.swift#L406) |
| `ctrlInitInProgress` | `Bool` | Whether controller is initializing | [L407](../Shared/Model/ChatModel.swift#L407) |
| `migrationState` | `MigrationToState?` | Device migration state | [L457](../Shared/Model/ChatModel.swift#L457) |

#### User State
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `currentUser` | `User?` | Active user profile (triggers theme reapply on change) | [L396](../Shared/Model/ChatModel.swift#L396) |
| `users` | `[UserInfo]` | All user profiles | [L401](../Shared/Model/ChatModel.swift#L401) |
| `v3DBMigration` | `V3DBMigrationState` | Legacy DB migration state | [L395](../Shared/Model/ChatModel.swift#L395) |

#### Chat List
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `chats` | `[Chat]` (private set) | All conversations for current user | [L413](../Shared/Model/ChatModel.swift#L413) |
| `deletedChats` | `Set<String>` | Chat IDs pending deletion animation | [L414](../Shared/Model/ChatModel.swift#L414) |

#### Active Chat
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `chatId` | `String?` | Currently open chat ID | [L416](../Shared/Model/ChatModel.swift#L416) |
| `chatAgentConnId` | `String?` | Agent connection ID for active chat | [L417](../Shared/Model/ChatModel.swift#L417) |
| `chatSubStatus` | `SubscriptionStatus?` | Active chat subscription status | [L418](../Shared/Model/ChatModel.swift#L418) |
| `openAroundItemId` | `ChatItem.ID?` | Item to scroll to when opening | [L419](../Shared/Model/ChatModel.swift#L419) |
| `chatToTop` | `String?` | Chat to scroll to top | [L420](../Shared/Model/ChatModel.swift#L420) |
| `groupMembers` | `[GMember]` | Members of active group | [L422](../Shared/Model/ChatModel.swift#L422) |
| `groupMembersIndexes` | `[Int64: Int]` | Member ID to index mapping | [L423](../Shared/Model/ChatModel.swift#L423) |
| `membersLoaded` | `Bool` | Whether members have been loaded | [L424](../Shared/Model/ChatModel.swift#L424) |
| `secondaryIM` | `ItemsModel?` | Secondary items model (e.g. support chat scope) | [L501](../Shared/Model/ChatModel.swift#L501) |

#### Authentication
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `contentViewAccessAuthenticated` | `Bool` | Whether user has passed authentication | [L410](../Shared/Model/ChatModel.swift#L410) |
| `laRequest` | `LocalAuthRequest?` | Pending authentication request | [L411](../Shared/Model/ChatModel.swift#L411) |

#### Notifications
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `deviceToken` | `DeviceToken?` | Current APNs device token | [L435](../Shared/Model/ChatModel.swift#L435) |
| `savedToken` | `DeviceToken?` | Previously saved token | [L436](../Shared/Model/ChatModel.swift#L436) |
| `tokenRegistered` | `Bool` | Whether token is registered with server | [L437](../Shared/Model/ChatModel.swift#L437) |
| `tokenStatus` | `NtfTknStatus?` | Token registration status | [L439](../Shared/Model/ChatModel.swift#L439) |
| `notificationMode` | `NotificationsMode` | Current notification mode (.off/.periodic/.instant) | [L440](../Shared/Model/ChatModel.swift#L440) |
| `notificationServer` | `String?` | Notification server URL | [L441](../Shared/Model/ChatModel.swift#L441) |
| `notificationPreview` | `NotificationPreviewMode` | What to show in notifications | [L442](../Shared/Model/ChatModel.swift#L442) |
| `notificationResponse` | `UNNotificationResponse?` | Pending notification action | [L408](../Shared/Model/ChatModel.swift#L408) |
| `ntfContactRequest` | `NTFContactRequest?` | Pending contact request from notification | [L444](../Shared/Model/ChatModel.swift#L444) |
| `ntfCallInvitationAction` | `(ChatId, NtfCallAction)?` | Pending call action from notification | [L445](../Shared/Model/ChatModel.swift#L445) |

#### Calls
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `callInvitations` | `[ChatId: RcvCallInvitation]` | Pending incoming call invitations | [L447](../Shared/Model/ChatModel.swift#L447) |
| `activeCall` | `Call?` | Currently active call | [L448](../Shared/Model/ChatModel.swift#L448) |
| `callCommand` | `WebRTCCommandProcessor` | WebRTC command queue | [L449](../Shared/Model/ChatModel.swift#L449) |
| `showCallView` | `Bool` | Whether to show full-screen call UI | [L450](../Shared/Model/ChatModel.swift#L450) |
| `activeCallViewIsCollapsed` | `Bool` | Whether call view is in PiP mode | [L451](../Shared/Model/ChatModel.swift#L451) |

#### Remote Desktop
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `remoteCtrlSession` | `RemoteCtrlSession?` | Active remote desktop session | [L454](../Shared/Model/ChatModel.swift#L454) |

#### Misc
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `userAddress` | `UserContactLink?` | User's POPOPX address | [L431](../Shared/Model/ChatModel.swift#L431) |
| `chatItemTTL` | `ChatItemTTL` | Global message TTL | [L432](../Shared/Model/ChatModel.swift#L432) |
| `appOpenUrl` | `URL?` | URL opened while app active | [L433](../Shared/Model/ChatModel.swift#L433) |
| `appOpenUrlLater` | `URL?` | URL opened while app inactive | [L434](../Shared/Model/ChatModel.swift#L434) |
| `showingInvitation` | `ShowingInvitation?` | Currently displayed invitation | [L456](../Shared/Model/ChatModel.swift#L456) |
| `draft` | `ComposeState?` | Saved compose draft | [L460](../Shared/Model/ChatModel.swift#L460) |
| `draftChatId` | `String?` | Chat ID for saved draft | [L462](../Shared/Model/ChatModel.swift#L462) |
| `networkInfo` | `UserNetworkInfo` | Current network type and status | [L463](../Shared/Model/ChatModel.swift#L463) |
| `conditions` | `ServerOperatorConditions` | Server usage conditions | [L465](../Shared/Model/ChatModel.swift#L465) |
| `stopPreviousRecPlay` | `URL?` | Currently playing audio source | [L459](../Shared/Model/ChatModel.swift#L459) |

### Non-Published Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `messageDelivery` | `[Int64: () -> Void]` | Pending delivery confirmation callbacks | [L467](../Shared/Model/ChatModel.swift#L467) |
| `filesToDelete` | `Set<URL>` | Files queued for deletion | [L469](../Shared/Model/ChatModel.swift#L469) |
| `chatListBanner` | `ChatListBanner?` | The banner kind the chat list showed this app session; `bannerSlotFree(for:)` tells whether a kind may take the slot (see [chat-list.md](client/chat-list.md)) | [L473](../Shared/Model/ChatModel.swift#L473) |
| `im` | `ItemsModel` | Reference to `ItemsModel.shared` | [L498](../Shared/Model/ChatModel.swift#L498) |

### Key Methods

| Method | Description | Line |
|--------|-------------|------|
| `getUser(_ userId:)` | Find user by ID | [L521](../Shared/Model/ChatModel.swift#L521) |
| `updateUser(_ user:)` | Update user in list and current | [L532](../Shared/Model/ChatModel.swift#L532) |
| `removeUser(_ user:)` | Remove user from list | [L542](../Shared/Model/ChatModel.swift#L542) |
| `getChat(_ id:)` | Find chat by ID | [L553](../Shared/Model/ChatModel.swift#L553) |
| `addChat(_ chat:)` | Add chat to list | [L608](../Shared/Model/ChatModel.swift#L608) |
| `updateChatInfo(_ cInfo:)` | Update chat metadata | [L622](../Shared/Model/ChatModel.swift#L622) |
| `replaceChat(_ id:, _ chat:)` | Replace chat in list | [L674](../Shared/Model/ChatModel.swift#L674) |
| `removeChat(_ id:)` | Remove chat from list | [L1325](../Shared/Model/ChatModel.swift#L1325) |
| `popChat(_ id:)` | Move chat to top of list | [L1292](../Shared/Model/ChatModel.swift#L1292) |
| `totalUnreadCountForAllUsers()` | Sum unread across all users | [L1192](../Shared/Model/ChatModel.swift#L1192) |

---

## 3. [ItemsModel](../Shared/Model/ChatModel.swift#L75-L175)

**Class**: `class ItemsModel: ObservableObject`
**Primary singleton**: `ItemsModel.shared`
**Secondary instances**: Created via `ItemsModel.loadSecondaryChat()` for scope-based views (e.g., group member support chat)
**Source**: [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift#L75)

### Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `reversedChatItems` | `[ChatItem]` | Messages in reverse chronological order (newest first) | [L81](../Shared/Model/ChatModel.swift#L81) |
| `itemAdded` | `Bool` | Flag indicating a new item was added | [L84](../Shared/Model/ChatModel.swift#L84) |
| `chatState` | `ActiveChatState` | Pagination splits and loaded ranges | [L88](../Shared/Model/ChatModel.swift#L88) |
| `isLoading` | `Bool` | Whether messages are currently loading | [L92](../Shared/Model/ChatModel.swift#L92) |
| `showLoadingProgress` | `ChatId?` | Chat ID showing loading spinner | [L93](../Shared/Model/ChatModel.swift#L93) |
| `preloadState` | `PreloadState` | State for infinite-scroll preloading | [L78](../Shared/Model/ChatModel.swift#L78) |
| `secondaryIMFilter` | `SecondaryItemsModelFilter?` | Filter for secondary instances | [L77](../Shared/Model/ChatModel.swift#L77) |

### Computed Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `lastItemsLoaded` | `Bool` | Whether the oldest messages have been loaded | [L98](../Shared/Model/ChatModel.swift#L98) |
| `contentTag` | `MsgContentTag?` | Content type filter (if secondary) | [L160](../Shared/Model/ChatModel.swift#L160) |
| `groupScopeInfo` | `GroupChatScopeInfo?` | Group scope filter (if secondary) | [L168](../Shared/Model/ChatModel.swift#L168) |

### Throttling

`ItemsModel` uses a custom publisher throttle (0.2 seconds) to batch rapid updates to `reversedChatItems` and prevent excessive SwiftUI re-renders:

```swift
publisher
    .throttle(for: 0.2, scheduler: DispatchQueue.main, latest: true)
    .sink { self.objectWillChange.send() }
    .store(in: &bag)
```

Direct `@Published` properties (`isLoading`, `showLoadingProgress`) bypass throttling for immediate UI response.

### Key Methods

| Method | Description | Line |
|--------|-------------|------|
| `loadOpenChat(_ chatId:)` | Load chat with 250ms navigation delay | [L118](../Shared/Model/ChatModel.swift#L118) |
| `loadOpenChatNoWait(_ chatId:, _ openAroundItemId:)` | Load chat without delay | [L144](../Shared/Model/ChatModel.swift#L144) |
| `loadSecondaryChat(_ chatId:, chatFilter:)` | Create secondary ItemsModel instance | [L111](../Shared/Model/ChatModel.swift#L111) |

### [SecondaryItemsModelFilter](../Shared/Model/ChatModel.swift#L59-L71)

Used for secondary chat views (e.g., group member support scope, content type filter):

```swift
enum SecondaryItemsModelFilter {
    case groupChatScopeContext(groupScopeInfo: GroupChatScopeInfo)
    case msgContentTagContext(contentTag: MsgContentTag)
}
```

---

## 4. [ChatTagsModel](../Shared/Model/ChatModel.swift#L190-L291)

**Class**: `class ChatTagsModel: ObservableObject`
**Singleton**: `ChatTagsModel.shared`
**Source**: [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift#L190)

### Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `userTags` | `[ChatTag]` | User-defined tags | [L193](../Shared/Model/ChatModel.swift#L193) |
| `activeFilter` | `ActiveFilter?` | Currently active filter tab | [L194](../Shared/Model/ChatModel.swift#L194) |
| `presetTags` | `[PresetTag: Int]` | Preset tag counts (groups, contacts, favorites, etc.) | [L195](../Shared/Model/ChatModel.swift#L195) |
| `unreadTags` | `[Int64: Int]` | Unread count per user tag | [L196](../Shared/Model/ChatModel.swift#L196) |

### [ActiveFilter](../Shared/Views/ChatList/ChatListView.swift#L54)

```swift
enum ActiveFilter {
    case presetTag(PresetTag)   // .favorites, .contacts, .groups, .business, .groupReports
    case userTag(ChatTag)       // User-defined tag
    case unread                 // Unread conversations
}
```

---

## 5. [ChannelRelaysModel](../Shared/Model/ChatModel.swift#L336-L360)

**Class**: `class ChannelRelaysModel: ObservableObject`
**Singleton**: `ChannelRelaysModel.shared`
**Source**: [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift#L336)

Holds runtime relay state for the currently viewed channel. Used by `ChannelRelaysView` to display and manage relays. Reset when the view is dismissed.

### Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `groupId` | `Int64?` | Group ID of the channel whose relays are loaded | [L338](../Shared/Model/ChatModel.swift#L338) |
| `groupRelays` | `[GroupRelay]` | Current relay instances for the channel | [L339](../Shared/Model/ChatModel.swift#L339) |

### Methods

| Method | Description | Line |
|--------|-------------|------|
| `set(groupId:groupRelays:)` | Populate all properties at once | [L341](../Shared/Model/ChatModel.swift#L341) |
| `reset()` | Clear all properties to nil/empty | [L356](../Shared/Model/ChatModel.swift#L356) |

---

## 6. [Chat](../Shared/Model/ChatModel.swift#L1415-L1467)

**Class**: `final class Chat: ObservableObject, Identifiable, ChatLike`
**Source**: [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift#L1415)

Represents a single conversation in the chat list. Each `Chat` is an independent observable object.

### Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `chatInfo` | `ChatInfo` | Conversation type and metadata | [L1416](../Shared/Model/ChatModel.swift#L1416) |
| `chatItems` | `[ChatItem]` | Preview items (typically last message) | [L1417](../Shared/Model/ChatModel.swift#L1417) |
| `chatStats` | `ChatStats` | Unread counts and min unread item ID | [L1418](../Shared/Model/ChatModel.swift#L1418) |
| `created` | `Date` | Creation timestamp | [L1419](../Shared/Model/ChatModel.swift#L1419) |

### [ChatStats](../POPOPXChat/ChatTypes.swift#L2562-L2584)

```swift
struct ChatStats: Decodable, Hashable {
    var unreadCount: Int = 0
    var unreadMentions: Int = 0
    var reportsCount: Int = 0
    var minUnreadItemId: Int64 = 0
    var unreadChat: Bool = false
}
```

### Computed Properties

| Property | Description | Line |
|----------|-------------|------|
| `id` | Chat ID from `chatInfo.id` | [L1450](../Shared/Model/ChatModel.swift#L1450) |
| `viewId` | Unique view identity including creation time | [L1452](../Shared/Model/ChatModel.swift#L1452) |
| `unreadTag` | Whether chat counts as "unread" based on notification settings | [L1442](../Shared/Model/ChatModel.swift#L1442) |
| `supportUnreadCount` | Unread count for group support scope | [L1454](../Shared/Model/ChatModel.swift#L1454) |

---

## 7. [ChatInfo](../POPOPXChat/ChatTypes.swift#L1994-L2537)

**Enum**: `public enum ChatInfo: Identifiable, Decodable, NamedChat, Hashable`
**Source**: [`POPOPXChat/ChatTypes.swift`](../POPOPXChat/ChatTypes.swift#L1374)

Represents the type and metadata of a conversation:

```swift
public enum ChatInfo: Identifiable, Decodable, NamedChat, Hashable {
    case direct(contact: Contact)
    case group(groupInfo: GroupInfo, groupChatScope: GroupChatScopeInfo?)
    case local(noteFolder: NoteFolder)
    case contactRequest(contactRequest: UserContactRequest)
    case contactConnection(contactConnection: PendingContactConnection)
    case invalidJSON(json: Data?)
}
```

### Cases

| Case | Associated Value | Description |
|------|-----------------|-------------|
| `.direct` | `Contact` | One-to-one conversation |
| `.group` | `GroupInfo, GroupChatScopeInfo?` | Group conversation (optional scope for member support threads) |
| `.local` | `NoteFolder` | Local notes (self-chat) |
| `.contactRequest` | `UserContactRequest` | Incoming contact request |
| `.contactConnection` | `PendingContactConnection` | Pending connection |
| `.invalidJSON` | `Data?` | Undecodable chat data |

### Key Computed Properties on ChatInfo

| Property | Type | Description |
|----------|------|-------------|
| `chatType` | `ChatType` | `.direct`, `.group`, `.local`, `.contactRequest`, `.contactConnection` |
| `id` | `ChatId` | Prefixed ID (e.g., `"@1"` for direct, `"#5"` for group) |
| `displayName` | `String` | Contact/group name |
| `image` | `String?` | Profile image (base64) |
| `chatSettings` | `ChatSettings?` | Notification/favorite settings |
| `chatTags` | `[Int64]?` | Assigned tag IDs |

### Relay-Related Data Model (Channels)

A **channel** is a group with `groupInfo.useRelays == true`. These types support the relay/channel infrastructure:

#### New Fields on Existing Types

| Type | Field | Type | Description | Line |
|------|-------|------|-------------|------|
| `User` | `userChatRelay` | `Bool` | Whether user acts as a chat relay | [L30](../POPOPXChat/ChatTypes.swift#L30) |
| `GroupInfo` | `useRelays` | `Bool` | Whether group uses relay infrastructure (channel mode) | [L3041](../POPOPXChat/ChatTypes.swift#L3041) |
| `GroupInfo` | `relayOwnStatus` | `RelayStatus?` | Current user's relay status in this group | [L3041](../POPOPXChat/ChatTypes.swift#L3041) |
| `GroupProfile` | `publicGroup` | `PublicGroupProfile?` | Channel-specific profile data (type, link, ID) | [L3196](../POPOPXChat/ChatTypes.swift#L3196) |

#### New Types

| Type | Kind | Description | Line |
|------|------|-------------|------|
| `RelayStatus` | `enum` | Relay lifecycle: `.rsNew`, `.rsInvited`, `.rsAccepted`, `.rsActive`, `.rsInactive`, `.rsRejected` | [L3396](../POPOPXChat/ChatTypes.swift#L3396) |
| `RelayStatus.text` | `extension` | Localized display text: New/Invited/Accepted/Active/Inactive/Rejected | [L1978](../POPOPXChat/ChatTypes.swift#L1978) |
| `GroupRelay` | `struct` | Relay instance for a group (ID, member ID, relay status). Fetched at runtime via `apiGetGroupRelays` (owner only) | [L3386](../POPOPXChat/ChatTypes.swift#L3386) |
| `UserChatRelay` | `struct` | User's chat relay configuration (ID, SMP address, name, domains, preset/tested/enabled/deleted flags) | [L3339](../POPOPXChat/ChatTypes.swift#L3339) |

#### New Enum Cases

| Enum | Case | Description | Line |
|------|------|-------------|------|
| `GroupMemberRole` | `.relay` | Role for relay members (below `.observer`) | [L3653](../POPOPXChat/ChatTypes.swift#L3653) |
| `CIDirection` | `.channelRcv` | Message direction for channel-received messages (via relay) | [L4417](../POPOPXChat/ChatTypes.swift#L4417) |

---

## 8. State Flow

### App Start
```
SimpleXApp.init()
    → haskell_init()
    → initChatAndMigrate()
        → chat_migrate_init_key() -- creates/opens DB
        → startChat(mainApp: true) -- starts core
        → apiGetChats(userId) -- populates ChatModel.chats
        → UI renders ChatListView
```

### Opening a Chat
```
User taps chat in ChatListView
    → ItemsModel.loadOpenChat(chatId)
        → 250ms delay for navigation animation
        → ChatModel.chatId = chatId
        → loadChat(chatId:, im:)
            → apiGetChat(chatId, pagination: .last(count: 50))
            → ItemsModel.reversedChatItems = [ChatItem]
        → ChatView renders messages
```

### Receiving a Message (Event)
```
Haskell core generates ChatEvent.newChatItems
    → Event loop calls chat_recv_msg_wait
    → Decoded as ChatEvent.newChatItems(user, chatItems)
    → ChatModel updates:
        1. Insert new Chat items into ChatModel.chats (preview)
        2. If chat is open: insert into ItemsModel.reversedChatItems
        3. Update ChatStats (unread counts)
        4. Update ChatTagsModel (tag unread counts)
    → SwiftUI re-renders affected views via @Published observation
```

### Sending a Message
```
User taps send in ComposeView
    → apiSendMessages(type, id, scope, live, ttl, composedMessages)
    → Haskell processes, returns ChatResponse1.newChatItems
    → ChatModel.chats updated with new preview
    → ItemsModel.reversedChatItems gets new item
    → ChatView scrolls to bottom, shows sent message
```

---

## 9. Preference Storage

### UserDefaults (via @AppStorage)

App-level UI settings stored in `UserDefaults.standard`:

| Key Constant | Type | Description |
|--------------|------|-------------|
| `DEFAULT_PERFORM_LA` | `Bool` | Enable local authentication |
| `DEFAULT_PRIVACY_PROTECT_SCREEN` | `Bool` | Hide screen in app switcher |
| `DEFAULT_SHOW_LA_NOTICE` | `Bool` | Show LA setup notice |
| `DEFAULT_NOTIFICATION_ALERT_SHOWN` | `Bool` | Notification permission alert shown |
| `DEFAULT_CALL_KIT_CALLS_IN_RECENTS` | `Bool` | Show CallKit calls in recents |

### GroupDefaults

Settings shared between main app and extensions (NSE, SE) via app group `UserDefaults`:

| Key | Description |
|-----|-------------|
| `appStateGroupDefault` | Current app state (.active/.suspended/.stopped) |
| `dbContainerGroupDefault` | Database container location (.group/.documents) |
| `ntfPreviewModeGroupDefault` | Notification preview mode |
| `storeDBPassphraseGroupDefault` | Whether to store DB passphrase |
| `callKitEnabledGroupDefault` | Whether CallKit is enabled |
| `onboardingStageDefault` | Current onboarding stage |
| `currentThemeDefault` | Current theme name |
| `systemDarkThemeDefault` | Dark mode theme name |
| `themeOverridesDefault` | Custom theme overrides |
| `currentThemeIdsDefault` | Active theme override IDs |

### Keychain (KeyChain wrapper)

Sensitive data stored in iOS Keychain:

| Key | Description |
|-----|-------------|
| `kcDatabasePassword` | SQLite database encryption key |
| `kcAppPassword` | App lock password |
| `kcSelfDestructPassword` | Self-destruct trigger password |

### Haskell DB (via apiSaveSettings / apiGetSettings)

Chat-level preferences stored in the SQLite database (managed by Haskell core):

- Per-contact preferences (timed messages, voice, calls, etc.)
- Per-group preferences
- Per-user notification settings
- Network configuration
- Server lists

---

## Source Files

| File | Path |
|------|------|
| ChatModel, ItemsModel, Chat, ChatTagsModel, ChannelRelaysModel | [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift) |
| ChatInfo, User, Contact, GroupInfo, ChatItem | [`POPOPXChat/ChatTypes.swift`](../POPOPXChat/ChatTypes.swift) |
| ActiveFilter | [`Shared/Views/ChatList/ChatListView.swift`](../Shared/Views/ChatList/ChatListView.swift#L54) |
| Preference defaults | [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift), [`POPOPXChat/FileUtils.swift`](../POPOPXChat/FileUtils.swift) |
