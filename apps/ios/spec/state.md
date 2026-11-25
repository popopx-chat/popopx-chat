# POPOPX Chat iOS -- State Management

**Source:** [`ChatModel.swift`](../Shared/Model/ChatModel.swift#L1-L1517) | [`ChatTypes.swift`](../POPOPXChat/ChatTypes.swift#L1-L6723)

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

## 2. [ChatModel](../Shared/Model/ChatModel.swift#L387-L1398)

**Class**: `final class ChatModel: ObservableObject`
**Singleton**: `ChatModel.shared`
**Source**: [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift#L387)

### Key Published Properties

#### App Lifecycle
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `onboardingStage` | `OnboardingStage?` | Current onboarding step | [L388](../Shared/Model/ChatModel.swift#L388) |
| `chatInitialized` | `Bool` | Whether chat has been initialized | [L397](../Shared/Model/ChatModel.swift#L397) |
| `chatRunning` | `Bool?` | Whether chat engine is running | [L398](../Shared/Model/ChatModel.swift#L398) |
| `chatDbChanged` | `Bool` | Whether DB was changed externally | [L399](../Shared/Model/ChatModel.swift#L399) |
| `chatDbEncrypted` | `Bool?` | Whether DB is encrypted | [L400](../Shared/Model/ChatModel.swift#L400) |
| `chatDbStatus` | `DBMigrationResult?` | DB migration status | [L401](../Shared/Model/ChatModel.swift#L401) |
| `ctrlInitInProgress` | `Bool` | Whether controller is initializing | [L402](../Shared/Model/ChatModel.swift#L402) |
| `migrationState` | `MigrationToState?` | Device migration state | [L452](../Shared/Model/ChatModel.swift#L452) |

#### User State
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `currentUser` | `User?` | Active user profile (triggers theme reapply on change) | [L391](../Shared/Model/ChatModel.swift#L391) |
| `users` | `[UserInfo]` | All user profiles | [L396](../Shared/Model/ChatModel.swift#L396) |
| `v3DBMigration` | `V3DBMigrationState` | Legacy DB migration state | [L390](../Shared/Model/ChatModel.swift#L390) |

#### Chat List
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `chats` | `[Chat]` (private set) | All conversations for current user | [L408](../Shared/Model/ChatModel.swift#L408) |
| `deletedChats` | `Set<String>` | Chat IDs pending deletion animation | [L409](../Shared/Model/ChatModel.swift#L409) |

#### Active Chat
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `chatId` | `String?` | Currently open chat ID | [L411](../Shared/Model/ChatModel.swift#L411) |
| `chatAgentConnId` | `String?` | Agent connection ID for active chat | [L412](../Shared/Model/ChatModel.swift#L412) |
| `chatSubStatus` | `SubscriptionStatus?` | Active chat subscription status | [L413](../Shared/Model/ChatModel.swift#L413) |
| `openAroundItemId` | `ChatItem.ID?` | Item to scroll to when opening | [L414](../Shared/Model/ChatModel.swift#L414) |
| `chatToTop` | `String?` | Chat to scroll to top | [L415](../Shared/Model/ChatModel.swift#L415) |
| `groupMembers` | `[GMember]` | Members of active group | [L417](../Shared/Model/ChatModel.swift#L417) |
| `groupMembersIndexes` | `[Int64: Int]` | Member ID to index mapping | [L418](../Shared/Model/ChatModel.swift#L418) |
| `membersLoaded` | `Bool` | Whether members have been loaded | [L419](../Shared/Model/ChatModel.swift#L419) |
| `secondaryIM` | `ItemsModel?` | Secondary items model (e.g. support chat scope) | [L496](../Shared/Model/ChatModel.swift#L496) |

#### Authentication
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `contentViewAccessAuthenticated` | `Bool` | Whether user has passed authentication | [L405](../Shared/Model/ChatModel.swift#L405) |
| `laRequest` | `LocalAuthRequest?` | Pending authentication request | [L406](../Shared/Model/ChatModel.swift#L406) |

#### Notifications
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `deviceToken` | `DeviceToken?` | Current APNs device token | [L430](../Shared/Model/ChatModel.swift#L430) |
| `savedToken` | `DeviceToken?` | Previously saved token | [L431](../Shared/Model/ChatModel.swift#L431) |
| `tokenRegistered` | `Bool` | Whether token is registered with server | [L432](../Shared/Model/ChatModel.swift#L432) |
| `tokenStatus` | `NtfTknStatus?` | Token registration status | [L434](../Shared/Model/ChatModel.swift#L434) |
| `notificationMode` | `NotificationsMode` | Current notification mode (.off/.periodic/.instant) | [L435](../Shared/Model/ChatModel.swift#L435) |
| `notificationServer` | `String?` | Notification server URL | [L436](../Shared/Model/ChatModel.swift#L436) |
| `notificationPreview` | `NotificationPreviewMode` | What to show in notifications | [L437](../Shared/Model/ChatModel.swift#L437) |
| `notificationResponse` | `UNNotificationResponse?` | Pending notification action | [L403](../Shared/Model/ChatModel.swift#L403) |
| `ntfContactRequest` | `NTFContactRequest?` | Pending contact request from notification | [L439](../Shared/Model/ChatModel.swift#L439) |
| `ntfCallInvitationAction` | `(ChatId, NtfCallAction)?` | Pending call action from notification | [L440](../Shared/Model/ChatModel.swift#L440) |

#### Calls
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `callInvitations` | `[ChatId: RcvCallInvitation]` | Pending incoming call invitations | [L442](../Shared/Model/ChatModel.swift#L442) |
| `activeCall` | `Call?` | Currently active call | [L443](../Shared/Model/ChatModel.swift#L443) |
| `callCommand` | `WebRTCCommandProcessor` | WebRTC command queue | [L444](../Shared/Model/ChatModel.swift#L444) |
| `showCallView` | `Bool` | Whether to show full-screen call UI | [L445](../Shared/Model/ChatModel.swift#L445) |
| `activeCallViewIsCollapsed` | `Bool` | Whether call view is in PiP mode | [L446](../Shared/Model/ChatModel.swift#L446) |

#### Remote Desktop
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `remoteCtrlSession` | `RemoteCtrlSession?` | Active remote desktop session | [L449](../Shared/Model/ChatModel.swift#L449) |

#### Misc
| Property | Type | Description | Line |
|----------|------|-------------|------|
| `userAddress` | `UserContactLink?` | User's POPOPX address | [L426](../Shared/Model/ChatModel.swift#L426) |
| `chatItemTTL` | `ChatItemTTL` | Global message TTL | [L427](../Shared/Model/ChatModel.swift#L427) |
| `appOpenUrl` | `URL?` | URL opened while app active | [L428](../Shared/Model/ChatModel.swift#L428) |
| `appOpenUrlLater` | `URL?` | URL opened while app inactive | [L429](../Shared/Model/ChatModel.swift#L429) |
| `showingInvitation` | `ShowingInvitation?` | Currently displayed invitation | [L451](../Shared/Model/ChatModel.swift#L451) |
| `draft` | `ComposeState?` | Saved compose draft | [L455](../Shared/Model/ChatModel.swift#L455) |
| `draftChatId` | `String?` | Chat ID for saved draft | [L457](../Shared/Model/ChatModel.swift#L457) |
| `networkInfo` | `UserNetworkInfo` | Current network type and status | [L458](../Shared/Model/ChatModel.swift#L458) |
| `conditions` | `ServerOperatorConditions` | Server usage conditions | [L460](../Shared/Model/ChatModel.swift#L460) |
| `stopPreviousRecPlay` | `URL?` | Currently playing audio source | [L454](../Shared/Model/ChatModel.swift#L454) |

### Non-Published Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `messageDelivery` | `[Int64: () -> Void]` | Pending delivery confirmation callbacks | [L462](../Shared/Model/ChatModel.swift#L462) |
| `filesToDelete` | `Set<URL>` | Files queued for deletion | [L464](../Shared/Model/ChatModel.swift#L464) |
| `chatListBanner` | `ChatListBanner?` | The banner kind the chat list showed this app session; `bannerSlotFree(for:)` tells whether a kind may take the slot (see [chat-list.md](client/chat-list.md)) | [L468](../Shared/Model/ChatModel.swift#L468) |
| `im` | `ItemsModel` | Reference to `ItemsModel.shared` | [L493](../Shared/Model/ChatModel.swift#L493) |

### Key Methods

| Method | Description | Line |
|--------|-------------|------|
| `getUser(_ userId:)` | Find user by ID | [L516](../Shared/Model/ChatModel.swift#L516) |
| `updateUser(_ user:)` | Update user in list and current | [L527](../Shared/Model/ChatModel.swift#L527) |
| `removeUser(_ user:)` | Remove user from list | [L537](../Shared/Model/ChatModel.swift#L537) |
| `getChat(_ id:)` | Find chat by ID | [L548](../Shared/Model/ChatModel.swift#L548) |
| `addChat(_ chat:)` | Add chat to list | [L603](../Shared/Model/ChatModel.swift#L603) |
| `updateChatInfo(_ cInfo:)` | Update chat metadata | [L617](../Shared/Model/ChatModel.swift#L617) |
| `replaceChat(_ id:, _ chat:)` | Replace chat in list | [L669](../Shared/Model/ChatModel.swift#L669) |
| `removeChat(_ id:)` | Remove chat from list | [L1320](../Shared/Model/ChatModel.swift#L1320) |
| `popChat(_ id:)` | Move chat to top of list | [L1287](../Shared/Model/ChatModel.swift#L1287) |
| `totalUnreadCountForAllUsers()` | Sum unread across all users | [L1187](../Shared/Model/ChatModel.swift#L1187) |

---

## 3. [ItemsModel](../Shared/Model/ChatModel.swift#L70-L170)

**Class**: `class ItemsModel: ObservableObject`
**Primary singleton**: `ItemsModel.shared`
**Secondary instances**: Created via `ItemsModel.loadSecondaryChat()` for scope-based views (e.g., group member support chat)
**Source**: [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift#L70)

### Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `reversedChatItems` | `[ChatItem]` | Messages in reverse chronological order (newest first) | [L76](../Shared/Model/ChatModel.swift#L76) |
| `itemAdded` | `Bool` | Flag indicating a new item was added | [L79](../Shared/Model/ChatModel.swift#L79) |
| `chatState` | `ActiveChatState` | Pagination splits and loaded ranges | [L83](../Shared/Model/ChatModel.swift#L83) |
| `isLoading` | `Bool` | Whether messages are currently loading | [L87](../Shared/Model/ChatModel.swift#L87) |
| `showLoadingProgress` | `ChatId?` | Chat ID showing loading spinner | [L88](../Shared/Model/ChatModel.swift#L88) |
| `preloadState` | `PreloadState` | State for infinite-scroll preloading | [L73](../Shared/Model/ChatModel.swift#L73) |
| `secondaryIMFilter` | `SecondaryItemsModelFilter?` | Filter for secondary instances | [L72](../Shared/Model/ChatModel.swift#L72) |

### Computed Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `lastItemsLoaded` | `Bool` | Whether the oldest messages have been loaded | [L93](../Shared/Model/ChatModel.swift#L93) |
| `contentTag` | `MsgContentTag?` | Content type filter (if secondary) | [L155](../Shared/Model/ChatModel.swift#L155) |
| `groupScopeInfo` | `GroupChatScopeInfo?` | Group scope filter (if secondary) | [L163](../Shared/Model/ChatModel.swift#L163) |

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
| `loadOpenChat(_ chatId:)` | Load chat with 250ms navigation delay | [L113](../Shared/Model/ChatModel.swift#L113) |
| `loadOpenChatNoWait(_ chatId:, _ openAroundItemId:)` | Load chat without delay | [L139](../Shared/Model/ChatModel.swift#L139) |
| `loadSecondaryChat(_ chatId:, chatFilter:)` | Create secondary ItemsModel instance | [L106](../Shared/Model/ChatModel.swift#L106) |

### [SecondaryItemsModelFilter](../Shared/Model/ChatModel.swift#L54-L66)

Used for secondary chat views (e.g., group member support scope, content type filter):

```swift
enum SecondaryItemsModelFilter {
    case groupChatScopeContext(groupScopeInfo: GroupChatScopeInfo)
    case msgContentTagContext(contentTag: MsgContentTag)
}
```

---

## 4. [ChatTagsModel](../Shared/Model/ChatModel.swift#L185-L286)

**Class**: `class ChatTagsModel: ObservableObject`
**Singleton**: `ChatTagsModel.shared`
**Source**: [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift#L185)

### Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `userTags` | `[ChatTag]` | User-defined tags | [L188](../Shared/Model/ChatModel.swift#L188) |
| `activeFilter` | `ActiveFilter?` | Currently active filter tab | [L189](../Shared/Model/ChatModel.swift#L189) |
| `presetTags` | `[PresetTag: Int]` | Preset tag counts (groups, contacts, favorites, etc.) | [L190](../Shared/Model/ChatModel.swift#L190) |
| `unreadTags` | `[Int64: Int]` | Unread count per user tag | [L191](../Shared/Model/ChatModel.swift#L191) |

### [ActiveFilter](../Shared/Views/ChatList/ChatListView.swift#L54)

```swift
enum ActiveFilter {
    case presetTag(PresetTag)   // .favorites, .contacts, .groups, .business, .groupReports
    case userTag(ChatTag)       // User-defined tag
    case unread                 // Unread conversations
}
```

---

## 5. [ChannelRelaysModel](../Shared/Model/ChatModel.swift#L331-L355)

**Class**: `class ChannelRelaysModel: ObservableObject`
**Singleton**: `ChannelRelaysModel.shared`
**Source**: [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift#L331)

Holds runtime relay state for the currently viewed channel. Used by `ChannelRelaysView` to display and manage relays. Reset when the view is dismissed.

### Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `groupId` | `Int64?` | Group ID of the channel whose relays are loaded | [L333](../Shared/Model/ChatModel.swift#L333) |
| `groupRelays` | `[GroupRelay]` | Current relay instances for the channel | [L334](../Shared/Model/ChatModel.swift#L334) |

### Methods

| Method | Description | Line |
|--------|-------------|------|
| `set(groupId:groupRelays:)` | Populate all properties at once | [L336](../Shared/Model/ChatModel.swift#L336) |
| `reset()` | Clear all properties to nil/empty | [L351](../Shared/Model/ChatModel.swift#L351) |

---

## 6. [Chat](../Shared/Model/ChatModel.swift#L1410-L1462)

**Class**: `final class Chat: ObservableObject, Identifiable, ChatLike`
**Source**: [`Shared/Model/ChatModel.swift`](../Shared/Model/ChatModel.swift#L1410)

Represents a single conversation in the chat list. Each `Chat` is an independent observable object.

### Properties

| Property | Type | Description | Line |
|----------|------|-------------|------|
| `chatInfo` | `ChatInfo` | Conversation type and metadata | [L1411](../Shared/Model/ChatModel.swift#L1411) |
| `chatItems` | `[ChatItem]` | Preview items (typically last message) | [L1412](../Shared/Model/ChatModel.swift#L1412) |
| `chatStats` | `ChatStats` | Unread counts and min unread item ID | [L1413](../Shared/Model/ChatModel.swift#L1413) |
| `created` | `Date` | Creation timestamp | [L1414](../Shared/Model/ChatModel.swift#L1414) |

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
| `id` | Chat ID from `chatInfo.id` | [L1445](../Shared/Model/ChatModel.swift#L1445) |
| `viewId` | Unique view identity including creation time | [L1447](../Shared/Model/ChatModel.swift#L1447) |
| `unreadTag` | Whether chat counts as "unread" based on notification settings | [L1437](../Shared/Model/ChatModel.swift#L1437) |
| `supportUnreadCount` | Unread count for group support scope | [L1449](../Shared/Model/ChatModel.swift#L1449) |

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
