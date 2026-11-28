//
//  PopopxContactsView.swift
//  POPOPX (iOS)
//
//  [Phase 4] Tab 2 "Contacts": four permanent (pinned) feature cards at the top — new encrypted connection / my encrypted groups /
//  channels I follow / grouped by anonymous identity — below them a modern contacts list with `.searchable`, a right-hand A–Z index and 8pt rounded avatars.
//
//  Data sources (this project has neither `ChatModel.contacts` nor `ChatModel.invitations`, everything is derived from the chat list):
//  · Contacts = the `.direct` chats in `ChatModel.chats` (Shared/Model/ChatModel.swift:408) that are
//    `contact.active`, and the exclusion rules are copied verbatim from ChatListView.swift:665's
//    `!chat.chatInfo.chatDeleted && !chat.chatInfo.contactCard`；
//  · Groups = `.group` with `businessChat == nil && !isChannel` (copying the .groups definition from ChatListView.swift:1248);
//  · Channels = `.group` with `ChatInfo.isChannel` (= `groupInfo?.useRelays == true`, POPOPXChat/ChatTypes.swift:2296)
//    and `membership.memberCurrent`: the groups definition excludes channels by construction, so channels need their own page,
//    and the test is written in `isPopopxChannel(_:)` in one place only (the pinned row's number and the rows inside the page share it).
//  · Encrypted connection requests = `chatType == .contactRequest` (ChatListView.swift:679), answering goes through
//    `acceptContactRequest` / `rejectContactRequest`（Shared/Model/POPOPXAPI.swift:1551 / :1574）；
//  · Cabin pairings awaiting confirmation = `PopopxMeshRuntime.shared.bannerModel.requests` (in PopopxMeshUI
//    `PopopxMeshBannerModel` reads the true value from `ManualPairingManager.pendingRequests()` every 2 seconds).
//
//  How the two badges are counted (they never cross definitions, and never appear in the same coloured row at the same time):
//  · Indigo solid badge = the number of unanswered online encrypted connection requests (`contactRequestChats.count`). It is "unread", not
//    a message count: the page behind this card is exactly those requests, so once they are answered the badge goes to zero and there is no second count. §1.4 item 4 forbids green
//    from carrying permanent state, so `brand` is used.
//  · Teal outlined badge = `bannerModel.requests.count`, and it only takes part in the calculation when `PopopxMeshRuntime.isFuseOn` is true
//    — with the fuse off, `bannerModel.stop()` clears only the banner and not the queue mirror, so what you read would be stale numbers from the last launch.
//    The two numbers each speak of one channel, so per the last sentence of §1.1 ("when two kinds of channel must be shown at once, use two separate badges") they are split into two badges,
//    and the teal one always carries a number per §2.2 (`mesh` solid on a white card is only 2.98, not enough to carry information on its own, hence the outline uses `meshInk`).
//    There is one refresh path only: in `.task`, when the fuse is on, `await bannerModel.refresh()` reads the true value at once, and from then on it is driven by
//    that model's own 2-second polling (`@Published requests` → `@ObservedObject` → this view recomputes),
//    so this file starts no timer of its own and never calls `start()`/`stop()` (those two methods are `PopopxMeshKillSwitch`'s).
//
//  Index degradation note (Chinese display names are the norm in this project, so no fake "Latin letters only" index is done here):
//  A–Z takes the uppercase of the name's first Latin letter, while Chinese is first turned into pinyin by Foundation's `StringTransform.toLatin`,
//  then `stripDiacritics` removes the tone marks, so "Zhang San" lands on Z and "Ai Ming" on A — this is the system's own transcription,
//  not a built-in pinyin table. Characters the transcription cannot get (digits, punctuation, emoji, Arabic/Thai and other non-transliterating scripts) all fall into
//  the section explicitly marked "#", and are never dropped; when the transcription returns nil, the original first character is used for one more check.
//
//  Accessibility: rows and cards are real controls, all ≥ `PopopxMetrics.minHitTarget` (44pt); the right-hand A–Z index is the system Contacts'
//  equally dense shortcut strip (27 44pt segments do not fit on one screen), so it is `accessibilityHidden` itself, and the same capability is provided by the navigation bar's
//  "jump by letter" menu as standard 44pt menu items; the two badges each carry their own Chinese `accessibilityLabel`.
//  Reduce Motion goes through `PopopxMotion`: with it on, the springs for scroll-strip jumps and group changes become instantaneous value changes.
//
//  Red lines observed: project.pbxproj is not touched (this file is dragged into the target by hand); colour/spacing/font size/material/spring come only from
//  PopopxTheme's tokens; controls reuse Shared/Components' atomic library first, and tokens are assembled on the spot only when the atomic library's shapes are not enough
//  (which is why the `PopopxFunctionRowLabel` below is not a `PopopxPickerRow`: the stack path is held by phase 4's
//  MainTabView, so the card must be a `NavigationLink(value:)`, while `PopopxPickerRow` only accepts an action closure);
//  UI Chinese appears only once, in the `Copy` at the end of the file; no TODO, no fake data.
//
//  ⚠️ One integration point handed to MainTabView: the conversation page is driven by `ChatModel.chatId` (the old ChatListView.swift:210-217
//  mapped it with `NavigationStack(path:)`); this file follows the existing convention and calls `ItemsModel.shared.loadOpenChat(_:)`
//  to open a chat; the four-tab shell's `selection` is a private @State, so the Contacts tab cannot take the user over to the "Messages" tab.
//  MainTabView needs to add `.onChange(of: chatModel.chatId) { _, id in if id != nil { selection = .chats } }`
//  (or expose selection as a Binding), otherwise opening a chat from Contacts only appears after switching to the Messages tab.
//

import Foundation
import SwiftUI
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// // MARK: - A–Z bucketing

/// Name → index key. The one and only "pinyin/first letter" test, shared by the list grouping and the right-hand index strip, so the two cannot say different things.
private enum PopopxContactIndex {
    /// The landing point for names that cannot be transliterated to Latin; the UI uses this character directly as the section title.
    static let other = "#"

    static func key(forName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return other }
        // When the transcription fails (returns nil) it falls back to the original string, guaranteeing that "cannot decide" only ever lands in # and never drops a contact.
        let transliterated = trimmed
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? trimmed
        let source = transliterated.isEmpty ? trimmed : transliterated
        // Only the first character is looked at: digits/punctuation/emoji/non-transliterating scripts all go into the "#" section, never wrongly admitted by "skip a few characters until you find a letter".
        guard let first = source.first else { return other }
        let upper = String(first).uppercased()
        guard upper.count == 1, let scalar = upper.unicodeScalars.first,
              scalar.value >= 65, scalar.value <= 90 else { return other }
        return upper
    }
}

// // MARK: - Routing and grouping state

private enum PopopxContactsRoute: Hashable {
    case newConnections
    case groups
    case channels
    case serviceAccounts
    /// "Join channel": lands on the existing scan/paste-link page (the same page is already mounted in the + at the top right of the "Messages" tab,
    /// `ChatsListView.swift:270-275`). A channel link still goes through the app's existing `planAndConnect` →
    /// `apiConnectPlan` → `.groupLink` real path (`NewChatView.swift:1320`, `:1522`).
    case joinChannel
}

/// The actual definition of "group by anonymous identity": whether the chat itself is an anonymous connection (`ChatInfo.incognito`) or a direct connection on the main identity.
/// This is the only "identity ↔ contact" data that really exists in this project: `ChatData` has no userId field
/// (POPOPXChat/ChatTypes.swift:2539), so contacts across identities can only be presented through the unread counts under `chatModel.users`.
private enum PopopxIdentityGrouping: Int, Hashable, CaseIterable {
    case all
    case main
    case anonymous

    var label: String {
        switch self {
        case .all: return Copy.groupingAll
        case .main: return Copy.groupingMain
        case .anonymous: return Copy.groupingAnonymous
        }
    }
}

// MARK: - Tab 2

@MainActor
struct PopopxContactsView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The fuse's true value lives in the runtime (Shared/Model/POPOPXAPI.swift:3640), the pairing queue in bannerModel.
    /// Both are process-level singletons, and as in Phase 3 they are put into `@ObservedObject` inside `@MainActor init()`.
    @ObservedObject private var meshRuntime: PopopxMeshRuntime
    @ObservedObject private var meshBanner: PopopxMeshBannerModel

    @State private var toast = PopopxToastModel()
    @State private var searchText = ""
    @State private var showsIdentitySheet = false
    @State private var grouping: PopopxIdentityGrouping = .all

    @MainActor init() {
        _meshRuntime = ObservedObject(wrappedValue: PopopxMeshRuntime.shared)
        _meshBanner = ObservedObject(wrappedValue: PopopxMeshRuntime.shared.bannerModel)
    }

    var body: some View {
        // `ScrollViewReader` wraps the outermost layer: the dense index strip on the right and the navigation bar's "jump by letter" menu share the same reader object
        // and the same set of keys, so the two entry points cannot behave differently when jumping.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        listBody
                    } header: {
                        pinnedFunctions
                    }
                }
            }
            .background(PopopxPalette.base)
            .overlay(alignment: .trailing) {
                if !searching && sections.count > 1 {
                    PopopxAlphabetIndex(keys: sections.map(\.key)) { key in
                        scroll(to: key, in: proxy)
                    }
                    .padding(.trailing, PopopxMetrics.space2XS)
                }
            }
            .navigationTitle(Copy.pageTitle)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: Copy.searchPrompt)
            .toolbar {
                // The accessibility equivalent of the dense index strip (each segment ~16pt; 27 segments do not fit the 44pt requirement):
                // the same set of keys, and the system menu brings its own 44pt hit area.
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(sections.map(\.key), id: \.self) { key in
                            Button(Copy.indexJumpLabel(key)) { scroll(to: key, in: proxy) }
                        }
                    } label: {
                        Label(Copy.indexMenuLabel, systemImage: "list.number")
                    }
                }
            }
            .navigationDestination(for: PopopxContactsRoute.self) { route in
                switch route {
                case .newConnections:
                    PopopxNewConnectionsPage()
                case .groups:
                    PopopxGroupsPage()
                case .channels:
                    PopopxChannelsPage()
                case .serviceAccounts:
                    PopopxServiceAccountsPage()
                case .joinChannel:
                    // The same page and the same mounting style as the "scan" item in the Messages tab's + menu (`ChatsListView.swift:270-275`),
                    // differing only in the title: this one is here to "join a channel with a link or a QR code", and the title must make both things clear.
                    NewChatView(selection: .connect, showQRCodeScanner: true)
                        .navigationTitle(Copy.joinChannelPageTitle)
                        .modifier(ThemedBackground(grouped: true))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(isPresented: $showsIdentitySheet) {
                PopopxIdentitySheet(
                    grouping: grouping,
                    contacts: contactChats,
                    onGrouping: { choice in
                        grouping = choice
                        showsIdentitySheet = false
                    }
                )
                .environmentObject(chatModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .task { await refreshMeshPending() }
        }
        .popopxToast(toast)
    }

    @ViewBuilder private var listBody: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
            if chatModel.chatRunning != true {
                PopopxNotice(text: Copy.engineNotReadyNote, systemImage: "lock.shield")
            }

            if searching && sections.isEmpty {
                PopopxEmptyState(
                    systemImage: "magnifyingglass",
                    title: Copy.noMatchTitle,
                    note: Copy.noMatchNote
                )
                .padding(.top, PopopxMetrics.spaceL)
            } else if !searching && visibleChats.isEmpty {
                PopopxEmptyState(
                    systemImage: "person.2",
                    title: Copy.emptyTitle,
                    note: Copy.emptyNote
                )
                .padding(.top, PopopxMetrics.spaceL)
            } else {
                ForEach(sections, id: \.key) { section in
                    PopopxSectionCard(section.key) {
                        ForEach(section.chats) { chat in
                            PopopxContactRow(
                                chat: chat,
                                showAnonymousTag: grouping == .all,
                                avatarSize: avatarSize
                            ) {
                                // The same move as the old Contacts (Shared/Views/Contacts/ContactListNavLink.swift:56):
                                // dismiss the full-screen sheet first, then hand the chat to be opened to the existing tab-switch entry.
                                dismissAllSheets(animated: true) {
                                    ItemsModel.shared.loadOpenChat(chat.id)
                                }
                            }
                            if chat.id != section.chats.last?.id {
                                PopopxRowSeparator(inset: avatarSize + PopopxMetrics.spaceS)
                            }
                        }
                    }
                    .id(section.key)
                }
            }
        }
        .padding(.top, PopopxMetrics.spaceS)
        .padding(.bottom, PopopxMetrics.space2XL)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The four pinned feature cards + the current grouping state. It stays permanently as the pinned section header while the list scrolls beneath it.
    private var pinnedFunctions: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            PopopxSectionCard {
                // Card 1: new encrypted connection. Two separate badges = two channels (last sentence of §1.1, §2.2).
                NavigationLink(value: PopopxContactsRoute.newConnections) {
                    PopopxFunctionRowLabel(
                        title: Copy.newConnectionsTitle,
                        note: requestNote,
                        systemImage: "person.badge.plus"
                    ) {
                        if contactRequestCount > 0 {
                            PopopxOnlineCountBadge(count: contactRequestCount)
                        }
                        if meshPendingCount > 0 {
                            PopopxMeshCountBadge(count: meshPendingCount)
                        }
                    }
                }
                .buttonStyle(PopopxPressButtonStyle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Copy.newConnectionsTitle)
                .accessibilityValue(accessibilityBadges)

                PopopxRowSeparator(inset: 0)

                // Card 2: my encrypted groups.
                NavigationLink(value: PopopxContactsRoute.groups) {
                    PopopxFunctionRowLabel(
                        title: Copy.groupsTitle,
                        note: groupNote,
                        systemImage: "person.3.fill"
                    ) {
                        EmptyView()
                    }
                }
                .buttonStyle(PopopxPressButtonStyle())
                .accessibilityElement(children: .combine)

                PopopxRowSeparator(inset: 0)

                // Card 3: channels I follow. In this project a channel is simply "a public group forwarded through relays"
                // （`ChatInfo.isChannel` = `groupInfo?.useRelays == true`，POPOPXChat/ChatTypes.swift:2296），
                // and the definition of `contactChats` above excludes it from the contacts and groups pages, so it needs its own row.
                NavigationLink(value: PopopxContactsRoute.channels) {
                    PopopxFunctionRowLabel(
                        title: Copy.channelsTitle,
                        note: channelNote,
                        systemImage: "antenna.radiowaves.left.and.right"
                    ) {
                        EmptyView()
                    }
                }
                .buttonStyle(PopopxPressButtonStyle())
                .accessibilityElement(children: .combine)

                PopopxRowSeparator(inset: 0)

                // Card 3.5: service accounts I follow. Separated from ordinary contacts so the address book stays clean.
                NavigationLink(value: PopopxContactsRoute.serviceAccounts) {
                    PopopxFunctionRowLabel(
                        title: Copy.serviceAccountsTitle,
                        note: serviceAccountNote,
                        systemImage: "briefcase.fill"
                    ) {
                        if serviceAccountCount > 0 {
                            PopopxOnlineCountBadge(count: serviceAccountCount)
                        }
                    }
                }
                .buttonStyle(PopopxPressButtonStyle())
                .accessibilityElement(children: .combine)

                PopopxRowSeparator(inset: 0)

                // Card 4: group by anonymous identity — a sheet, so an atomic control that takes an action closure can be used.
                PopopxPickerRow(
                    Copy.identitiesTitle,
                    value: identityValue,
                    systemImage: "person.crop.circle.badge.questionmark",
                    tint: .brand
                ) {
                    PopopxHaptics.impact(.light)
                    showsIdentitySheet = true
                }
            }

            if grouping != .all {
                PopopxNotice(text: Copy.groupingActiveNote(grouping.label), systemImage: "line.3.crossed.swirl.circle") {
                    Button(Copy.groupingClear) {
                        PopopxHaptics.selection()
                        grouping = .all
                    }
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.brand)
                    .frame(minHeight: PopopxMetrics.minHitTarget)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(.top, PopopxMetrics.spaceS)
        .padding(.bottom, PopopxMetrics.spaceXS)
        .background(PopopxPalette.base)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PopopxPalette.separator)
                .frame(height: PopopxMetrics.divider)
        }
    }

    // // MARK: Counts and filtering

    private var searching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

    /// Encrypted connection requests: `.contactRequest` chats. The exclusion rules come from the same source as the main list, so deleted/card chats cannot mix into the badge.
    private var contactRequestChats: [Chat] {
        chatModel.chats.filter { chat in
            !chat.chatInfo.chatDeleted
                && !chat.chatInfo.contactCard
                && chat.chatInfo.chatType == .contactRequest
        }
    }

    private var contactRequestCount: Int { contactRequestChats.count }

    /// Cabin pairings awaiting confirmation. With the fuse off it always counts 0: see "How the two badges are counted" in the file header.
    private var meshPendingCount: Int { meshRuntime.isFuseOn ? meshBanner.requests.count : 0 }

    /// The unified definition of contacts + encrypted groups (the main list of Contacts).
    /// Service accounts are excluded: they live in their own page (`PopopxServiceAccountsPage`).
    private var contactChats: [Chat] {
        // System config chats for the current user, to be hidden from UI — matched by kind and id.
        let systemConfigRefs = chatModel.systemConfigChatRefs()
        return chatModel.chats.filter { chat in
            guard !chat.chatInfo.chatDeleted, !chat.chatInfo.contactCard else { return false }
            // Hide system config chats from the contacts list.
            if let ref = PopopxSystemChatRef(chatType: chat.chatInfo.chatType, apiId: chat.chatInfo.apiId),
               systemConfigRefs.contains(ref) { return false }
            switch chat.chatInfo {
            case let .direct(contact):
                // Exclude service accounts from the ordinary contacts list
                guard !PopopxEcoSessionStore.hasSession(for: contact.contactId) else { return false }
                return contact.active && !contact.isContactCard
            case let .group(groupInfo, _):
                return groupInfo.businessChat == nil && !groupInfo.isChannel
            default:
                return false
            }
        }
    }

    private var groupChats: [Chat] {
        contactChats.filter { $0.chatInfo.chatType == .group }
    }

    /// Channels: the test shares the one `isPopopxChannel` with the channel page below, so the two places cannot say different things.
    private var channelChats: [Chat] {
        // System config chats for the current user, to be hidden from UI — matched by kind and id.
        let systemConfigRefs = chatModel.systemConfigChatRefs()
        return chatModel.chats.filter { chat in
            if let ref = PopopxSystemChatRef(chatType: chat.chatInfo.chatType, apiId: chat.chatInfo.apiId),
               systemConfigRefs.contains(ref) { return false }
            return isPopopxChannel(chat)
        }
    }

    /// Service accounts: direct contacts that completed the eco session handshake.
    private var serviceAccountChats: [Chat] {
        // System config chats for the current user, to be hidden from UI — matched by kind and id.
        let systemConfigRefs = chatModel.systemConfigChatRefs()
        return chatModel.chats.filter { chat in
            guard !chat.chatInfo.chatDeleted, !chat.chatInfo.contactCard else { return false }
            // Hide system config chats from the service accounts list.
            if let ref = PopopxSystemChatRef(chatType: chat.chatInfo.chatType, apiId: chat.chatInfo.apiId),
               systemConfigRefs.contains(ref) { return false }
            guard case let .direct(contact) = chat.chatInfo else { return false }
            return contact.active && !contact.isContactCard && PopopxEcoSessionStore.hasSession(for: contact.contactId)
        }
    }

    private var serviceAccountCount: Int {
        serviceAccountChats.count
    }

    private var visibleChats: [Chat] {
        contactChats.filter { chat in
            matchesGrouping(chat) && matchesSearch(chat)
        }
    }

    private func matchesGrouping(_ chat: Chat) -> Bool {
        switch grouping {
        case .all: return true
        case .main: return !chat.chatInfo.incognito
        case .anonymous: return chat.chatInfo.incognito
        }
    }

    /// The search-match definition copies ChatListView.swift:667-676 verbatim: view name / nickname / full name, case-insensitive.
    private func matchesSearch(_ chat: Chat) -> Bool {
        guard searching else { return true }
        let s = normalizedSearch
        return chat.chatInfo.chatViewName.localizedLowercase.contains(s)
            || chat.chatInfo.displayName.localizedLowercase.contains(s)
            || chat.chatInfo.fullName.localizedLowercase.contains(s)
    }

    private var sections: [PopopxContactSection] {
        var buckets: [String: [Chat]] = [:]
        for chat in visibleChats {
            buckets[PopopxContactIndex.key(forName: chat.chatInfo.chatViewName), default: []].append(chat)
        }
        return buckets.keys
            .sorted { lhs, rhs in
                if lhs == PopopxContactIndex.other { return false }
                if rhs == PopopxContactIndex.other { return true }
                return lhs < rhs
            }
            .map { key in
                var chats = buckets[key] ?? []
                chats.sort { lhs, rhs in
                    lhs.chatInfo.chatViewName.localizedStandardCompare(rhs.chatInfo.chatViewName) == .orderedAscending
                }
                return PopopxContactSection(key: key, chats: chats)
            }
    }

    // // MARK: Readings used by the copy

    private var requestNote: String {
        contactRequestCount == 0
            ? Copy.newConnectionsNoteEmpty
            : Copy.newConnectionsNote(contactRequestCount)
    }

    private var groupNote: String {
        groupChats.isEmpty ? Copy.groupsNoteEmpty : Copy.groupsNote(groupChats.count)
    }

    private var channelNote: String {
        channelChats.isEmpty ? Copy.channelsNoteEmpty : Copy.channelsNote(channelChats.count)
    }

    private var serviceAccountNote: String {
        serviceAccountChats.isEmpty ? Copy.serviceAccountsNoteEmpty : Copy.serviceAccountsNote(serviceAccountCount)
    }

    private var identityValue: String {
        Copy.identitiesValue(visibleIdentities.count)
    }

    /// A hidden identity needs the viewing passphrase to switch (`User.hidden` = `viewPwdHash != nil`), and this page does not collect a passphrase,
    /// so following `UserPicker`'s existing practice they are excluded from the list and the reason is written into the sheet.
    private var visibleIdentities: [UserInfo] {
        chatModel.users.filter { !$0.user.hidden }
    }

    private var accessibilityBadges: String {
        var parts: [String] = []
        if contactRequestCount > 0 { parts.append(Copy.badgeOnlineA11y(contactRequestCount)) }
        if meshPendingCount > 0 { parts.append(Copy.badgeMeshA11y(meshPendingCount)) }
        return parts.joined(separator: Copy.badgeSeparator)
    }

    /// The avatar grows with Dynamic Type while `radiusAvatar` stays 8pt (the corner radius explicitly named by this spec).
    private var avatarSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? PopopxMetrics.space2XL
            : PopopxMetrics.minHitTarget
    }

    // // MARK: Behaviour

    private func scroll(to key: String, in proxy: ScrollViewProxy) {
        PopopxHaptics.selection()
        PopopxMotion.withAnimation(PopopxSpring.fluid, reduceMotion: reduceMotion) {
            proxy.scrollTo(key, anchor: .top)
        }
    }

    /// Reads the true value once only; later updates are `PopopxMeshBannerModel`'s own 2-second polling's responsibility (see the file header).
    @MainActor private func refreshMeshPending() async {
        guard meshRuntime.isFuseOn else { return }
        await meshBanner.refresh()
    }
}

private struct PopopxContactSection {
    let key: String
    let chats: [Chat]
}

// // MARK: - A row of the pinned feature cards

/// The same dimensions as `PopopxPickerRow` (32pt square icon badge + title + trailing + `chevron.right`),
/// but the trailing side is replaced by the caller's badge, and the whole row is a `NavigationLink`'s label.
private struct PopopxFunctionRowLabel<Accessory: View>: View {
    let title: String
    let note: String
    let systemImage: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: systemImage)
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxIconTint.brand.ink)
                .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                .background(PopopxIconTint.brand.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: PopopxMetrics.spaceXS)

            accessory()
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .frame(minHeight: PopopxMetrics.minHitTarget)
        .contentShape(Rectangle())
    }
}

private struct PopopxRowSeparator: View {
    let inset: CGFloat

    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.leading, inset)
    }
}

// // MARK: - The two channel badges

/// Online encryption (SMP): `brand` solid + `onBrand`, always with a number.
private struct PopopxOnlineCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: "lock.shield.fill")
            unreadCountText(count)
        }
        .font(PopopxType.metricSmall)
        .foregroundStyle(PopopxPalette.onBrand)
        .padding(.horizontal, PopopxMetrics.spaceXS)
        .frame(minHeight: PopopxMetrics.spaceXL)
        .background(PopopxPalette.brand, in: .capsule)
        .accessibilityLabel(Copy.badgeOnlineA11y(count))
    }
}

/// Offline Cabin: `card` background + `meshInk` outline and text (§1.4 item 3: teal solid is under 3.0, so colour must not carry information on its own).
private struct PopopxMeshCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: "antenna.radiowaves.left.and.right")
            Text("· \(count)")
        }
        .font(PopopxType.metricSmall)
        .foregroundStyle(PopopxPalette.meshInk)
        .padding(.horizontal, PopopxMetrics.spaceXS)
        .frame(minHeight: PopopxMetrics.spaceXL)
        .background(PopopxPalette.card, in: .capsule)
        .overlay(RoundedRectangle(cornerRadius: PopopxMetrics.radiusChip, style: .continuous)
            .strokeBorder(PopopxPalette.meshInk, lineWidth: PopopxMetrics.hairline))
        .accessibilityLabel(Copy.badgeMeshA11y(count))
    }
}

// // MARK: - Contact row

private struct PopopxContactRow: View {
    let chat: Chat
    let showAnonymousTag: Bool
    let avatarSize: CGFloat
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxAvatar(chat: chat, size: avatarSize)

                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(chat.chatInfo.chatViewName)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let note = secondaryText {
                        Text(note)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // An anonymous connection is the fact of "which identity this relationship hangs on", marked in a neutral colour,
                    // so it does not compete for colour with brand (unread) or mesh (the teal-exclusive channel).
                    if showAnonymousTag && chat.chatInfo.incognito {
                        Label(Copy.anonymousTag, systemImage: "eye.slash")
                            .font(PopopxType.microTag)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                    }
                }

                Spacer(minLength: PopopxMetrics.spaceXS)

                unreadBadge
            }
            .padding(.vertical, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityElement(children: .combine)
    }

    private var secondaryText: String? {
        let info = chat.chatInfo
        if case let .group(groupInfo, _) = info {
            return Copy.memberCount(groupInfo.groupSummary.currentMembers)
        }
        if let descr = info.shortDescr, !descr.isEmpty { return descr }
        if let descr = info.profileDescription, !descr.isEmpty { return descr }
        return nil
    }

    /// The unread definition reuses `ChatStats` directly (an existing field) and the display text reuses `unreadCountText` (ChatPreviewView.swift:554),
    /// and the colour is `brand` per §1.4 item 4, never green.
    @ViewBuilder private var unreadBadge: some View {
        let stats = chat.chatStats
        if stats.unreadCount > 0 || stats.unreadChat {
            unreadCountText(stats.unreadCount > 0 ? stats.unreadCount : 1)
                .font(PopopxType.metricSmall)
                .foregroundStyle(PopopxPalette.onBrand)
                .padding(.horizontal, PopopxMetrics.spaceXS)
                .frame(minWidth: PopopxMetrics.spaceXL, minHeight: PopopxMetrics.spaceXL)
                .background(PopopxPalette.brand, in: .capsule)
                .accessibilityLabel(Copy.unreadA11y(max(stats.unreadCount, 1)))
        }
    }
}

/// An 8pt rounded avatar. In this project avatars are base64 strings rather than files, so only the existing `ProfileImage` can be used;
/// internally it crops by the user's own `DEFAULT_PROFILE_IMAGE_CORNER_RADIUS` preference, and this layer wraps another `radiusAvatar`
/// square container on top: when the preference is rounder the container does nothing (a round image has no corner left to clip), when it is squarer everything is pulled back to 8pt.
/// The repository has no "identity → colour" helper (colorForProfile/identityColor/profileColor all return 0 hits),
/// and §1.1 says colour carries channel semantics only, so "one colour per person" is deliberately not done here and placeholder icons are always `brand` (the online SMP list).
private struct PopopxAvatar: View {
    let chat: Chat
    let size: CGFloat
    var tint: Color = PopopxPalette.brand
    /// Which symbol to use when there is no custom avatar. The default `nil` = the original as-is person symbol; the channel page passes `chatIconName`
    /// (a public channel gets the antenna, `POPOPXChat/ChatTypes.swift:3091`), so what the avatar slot says is the chat's own type.
    var icon: String? = nil

    var body: some View {
        ProfileImage(imageStr: chat.chatInfo.image,
                     icon: Image(systemName: icon ?? "person.crop.circle.fill"),
                     size: size,
                     color: tint)
            .frame(width: size, height: size)
            .background(PopopxPalette.cardHigh, in: .rect(cornerRadius: PopopxMetrics.radiusAvatar))
            .clipShape(.rect(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous)
                    .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            )
            .accessibilityHidden(true)
    }
}

// // MARK: - Right-hand A–Z index

private struct PopopxAlphabetIndex: View {
    let keys: [String]
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: PopopxMetrics.space2XS) {
            ForEach(keys, id: \.self) { key in
                Button {
                    select(key)
                } label: {
                    Text(verbatim: key)
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .frame(
                            width: PopopxMetrics.spaceL,
                            height: PopopxMetrics.spaceS + PopopxMetrics.space2XS
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .background(PopopxMaterial.chip, in: .capsule)
        // The dense shortcut strip does not meet 44pt, so it is hidden from assistive technology and the same capability is carried by the navigation bar's "jump by letter" menu.
        .accessibilityHidden(true)
    }
}

// // MARK: - Notice bar / empty state

private struct PopopxNotice<Trailing: View>: View {
    let text: String
    let systemImage: String
    @ViewBuilder let trailing: () -> Trailing

    init(text: String, systemImage: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.text = text
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: systemImage)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopopxMetrics.spaceXS)
            trailing()
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .frame(minHeight: PopopxMetrics.minHitTarget)
    }
}

private struct PopopxEmptyState: View {
    let systemImage: String
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: systemImage)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.labelHint)
                .accessibilityHidden(true)
            Text(title)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
            Text(note)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PopopxMetrics.spaceL)
        .accessibilityElement(children: .combine)
    }
}

// // MARK: - The new encrypted connection page

private struct PopopxNewConnectionsPage: View {
    @EnvironmentObject private var chatModel: ChatModel

    @ObservedObject private var meshRuntime: PopopxMeshRuntime
    @ObservedObject private var meshBanner: PopopxMeshBannerModel

    @State private var toast = PopopxToastModel()

    @MainActor init() {
        _meshRuntime = ObservedObject(wrappedValue: PopopxMeshRuntime.shared)
        _meshBanner = ObservedObject(wrappedValue: PopopxMeshRuntime.shared.bannerModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                PopopxSectionCard(Copy.onlineSectionTitle, footnote: Copy.onlineSectionFootnote) {
                    if requests.isEmpty {
                        PopopxEmptyRow(title: Copy.onlineEmptyTitle, note: Copy.onlineEmptyNote)
                    } else {
                        ForEach(requests) { chat in
                            PopopxContactRequestRow(chat: chat, toast: toast)
                            if chat.id != requests.last?.id {
                                PopopxRowSeparator(inset: 0)
                            }
                        }
                    }
                }

                PopopxSectionCard(Copy.meshSectionTitle, footnote: meshFootnote) {
                    if !meshRuntime.isFuseOn {
                        PopopxEmptyRow(title: Copy.meshFuseOffTitle, note: Copy.meshFuseOffNote)
                    } else if meshBanner.requests.isEmpty {
                        PopopxEmptyRow(title: Copy.meshEmptyTitle, note: Copy.meshEmptyNote)
                    } else {
                        ForEach(meshBanner.requests) { request in
                            PopopxMeshPairingRow(request: request, toast: toast)
                            if request.id != meshBanner.requests.last?.id {
                                PopopxRowSeparator(inset: 0)
                            }
                        }
                    }
                }

                PopopxSectionCard(Copy.pendingSectionTitle, footnote: Copy.pendingSectionFootnote) {
                    if pendingConnections.isEmpty {
                        PopopxEmptyRow(title: Copy.pendingEmptyTitle, note: Copy.pendingEmptyNote)
                    } else {
                        ForEach(pendingConnections) { chat in
                            HStack(spacing: PopopxMetrics.spaceS) {
                                PopopxAvatar(chat: chat, size: PopopxMetrics.minHitTarget, tint: PopopxPalette.labelSecondary)
                                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                                    Text(chat.chatInfo.localAlias.isEmpty
                                         ? Copy.pendingUnnamedConnection
                                         : chat.chatInfo.localAlias)
                                        .font(PopopxType.sectionHeader)
                                        .foregroundStyle(PopopxPalette.label)
                                    Text(Copy.pendingConnectionNote)
                                        .font(PopopxType.caption)
                                        .foregroundStyle(PopopxPalette.labelSecondary)
                                }
                                Spacer(minLength: PopopxMetrics.spaceXS)
                            }
                            .padding(.vertical, PopopxMetrics.spaceS)
                            .frame(minHeight: PopopxMetrics.minHitTarget)
                            .accessibilityElement(children: .combine)
                            if chat.id != pendingConnections.last?.id {
                                PopopxRowSeparator(inset: 0)
                            }
                        }
                    }
                }
            }
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.newConnectionsTitle)
        .task { await refresh() }
        .popopxToast(toast)
    }

    private var requests: [Chat] {
        chatModel.chats.filter { chat in
            !chat.chatInfo.chatDeleted
                && !chat.chatInfo.contactCard
                && chat.chatInfo.chatType == .contactRequest
        }
    }

    /// Connections being established. Their names come from the core (`PendingContactConnection.displayName` is a localised English
    /// phrase), this page does not translate them, so they are presented only with a state this device can state, and are not tappable (the chat does not exist yet).
    private var pendingConnections: [Chat] {
        chatModel.chats.filter { $0.chatInfo.chatType == .contactConnection }
    }

    private var meshFootnote: String {
        guard meshRuntime.isFuseOn else { return Copy.meshFootnoteOff }
        return meshRuntime.pairingPolicy == .autoSilent
            ? Copy.meshFootnoteAuto
            : Copy.meshFootnoteManual
    }

    @MainActor private func refresh() async {
        guard meshRuntime.isFuseOn else { return }
        await meshBanner.refresh()
    }
}

private struct PopopxEmptyRow: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(title)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
            Text(note)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PopopxMetrics.spaceXS)
        .accessibilityElement(children: .combine)
    }
}

/// One online encrypted connection request: all three actions go through existing APIs, and the button shape uses the atomic library's adaptive grid.
private struct PopopxContactRequestRow: View {
    @EnvironmentObject private var chatModel: ChatModel

    let chat: Chat
    let toast: PopopxToastModel

    @State private var inProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxAvatar(chat: chat, size: PopopxMetrics.minHitTarget)
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(chat.chatInfo.chatViewName)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: PopopxMetrics.space2XL + PopopxMetrics.spaceL), spacing: PopopxMetrics.spaceXS)],
                spacing: PopopxMetrics.spaceXS
            ) {
                PopopxButton(Copy.accept, systemImage: "checkmark", role: .primary, fullWidth: true, isLoading: inProgress) {
                    await decide(incognito: false)
                }
                PopopxButton(Copy.acceptIncognito, systemImage: "eye.slash", role: .secondary, fullWidth: true, isLoading: inProgress) {
                    await decide(incognito: true)
                }
                PopopxButton(Copy.reject, systemImage: "xmark", role: .destructive, fullWidth: true, isLoading: inProgress) {
                    await reject()
                }
            }
        }
        .padding(.vertical, PopopxMetrics.spaceS)
        .disabled(chatModel.chatRunning != true || inProgress)
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        let info = chat.chatInfo
        if let descr = info.shortDescr, !descr.isEmpty { return descr }
        return Copy.requestNote
    }

    /// `acceptContactRequest` brings its own `inProgress` binding (POPOPXAPI.swift:1551), and on success
    /// `ChatModel` turns this request into a contact chat, so the row disappears along with the list.
    @MainActor private func decide(incognito: Bool) async {
        guard chatModel.chatRunning == true else {
            toast.show(Copy.engineNotReadyToast, kind: .danger)
            return
        }
        await acceptContactRequest(
            incognito: incognito,
            contactRequestId: chat.chatInfo.apiId,
            inProgress: $inProgress
        )
        toast.show(incognito ? Copy.acceptedIncognitoToast : Copy.acceptedToast, kind: .encrypted)
    }

    @MainActor private func reject() async {
        guard chatModel.chatRunning == true else {
            toast.show(Copy.engineNotReadyToast, kind: .danger)
            return
        }
        inProgress = true
        await rejectContactRequest(chat.chatInfo.apiId, dismissToChatList: false)
        inProgress = false
        toast.show(Copy.rejectedToast, kind: .success)
    }
}

/// One Cabin pairing awaiting confirmation. Every colour here is from the teal family and `brand` never appears — one row speaks of one channel only.
private struct PopopxMeshPairingRow: View {
    let request: PopopxPairingRequest
    let toast: PopopxToastModel

    @State private var inProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            HStack(spacing: PopopxMetrics.spaceS) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    // `mesh` solid can only be paired with `onMesh` (on the bright teal ground neither white nor dark teal text reads out, see PopopxTheme.swift:83).
                    .foregroundStyle(PopopxPalette.onMesh)
                    .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                    .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.meshPeerTitle(shortKey))
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                        .textSelection(.enabled)
                    HStack(spacing: PopopxMetrics.space2XS) {
                        Image(systemName: "clock")
                        Text(request.receivedAt, style: .relative)
                    }
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Copy.meshReceivedA11y)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: PopopxMetrics.space2XL + PopopxMetrics.spaceL), spacing: PopopxMetrics.spaceXS)],
                spacing: PopopxMetrics.spaceXS
            ) {
                PopopxButton(Copy.meshApprove, systemImage: "checkmark", role: .primary, fullWidth: true, isLoading: inProgress) {
                    await approve()
                }
                PopopxButton(Copy.meshDecline, systemImage: "xmark", role: .secondary, fullWidth: true, isLoading: inProgress) {
                    await decline()
                }
            }
        }
        .padding(.vertical, PopopxMetrics.spaceS)
        .disabled(inProgress)
    }

    private var shortKey: String {
        String(request.peerMeshPublicKeyHex.prefix(8))
    }

    @MainActor private func approve() async {
        inProgress = true
        defer { inProgress = false }
        do {
            // Module 3 throws with a typed error (`throws(PopopxPairingError)`); a failure is never left silent.
            _ = try await PopopxMeshRuntime.shared.pairing.approve(request)
            toast.show(Copy.meshApprovedToast, kind: .mesh)
        } catch {
            PopopxHaptics.notice(.error)
            toast.show(Copy.meshApproveFailedToast, kind: .danger)
        }
        await PopopxMeshRuntime.shared.bannerModel.refresh()
    }

    @MainActor private func decline() async {
        inProgress = true
        defer { inProgress = false }
        await PopopxMeshRuntime.shared.pairing.decline(request)
        toast.show(Copy.meshDeclinedToast, kind: .mesh)
        await PopopxMeshRuntime.shared.bannerModel.refresh()
    }
}

// // MARK: - My encrypted groups page

private struct PopopxGroupsPage: View {
    @EnvironmentObject private var chatModel: ChatModel

    /// Where the top-right "create encrypted group" goes: the same page and the same destination as the one in the Messages tab's top-right corner
    /// (`ChatsListView`'s `showsCreateGroup`), and the mounting style copies `NewChatMenuButton.swift:89-93` verbatim.
    @State private var showsCreateGroup = false

    private struct Row {
        let chat: Chat
        let isOwner: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                if groups.isEmpty {
                    PopopxSectionCard {
                        PopopxEmptyRow(title: Copy.groupsEmptyTitle, note: Copy.groupsEmptyNote)
                    }
                } else {
                    PopopxSectionCard(Copy.groupsOwnedTitle, footnote: Copy.groupsSectionFootnote) {
                        rowsCard(owned)
                    }
                    PopopxSectionCard(Copy.groupsJoinedTitle, footnote: Copy.groupsSectionFootnote) {
                        rowsCard(joined)
                    }
                }
            }
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.groupsTitle)
        // Real-device feedback: this page only had "existing groups", with not one entry to create a group, so you had to go back up a level and look in the Messages tab's +.
        // The empty-state row originally said exactly that (`groupsEmptyNote`), so this button brings that path right in front of the user,
        // and the empty-state copy was changed along with it into wording that no longer points elsewhere.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    PopopxHaptics.impact(.light)
                    showsCreateGroup = true
                } label: {
                    Label(Copy.createGroupEntry, systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("popopx.contacts.createGroup")
            }
        }
        .navigationDestination(isPresented: $showsCreateGroup) {
            PopopxCreateGroupView()
                .navigationTitle(Copy.createGroupEntry)
                .modifier(ThemedBackground(grouped: true))
        }
    }

    @ViewBuilder private func rowsCard(_ rows: [Row]) -> some View {
        if rows.isEmpty {
            PopopxEmptyRow(title: Copy.groupsNoneTitle, note: Copy.groupsNoneNote)
        } else {
            ForEach(rows, id: \.chat.id) { row in
                PopopxContactRow(chat: row.chat, showAnonymousTag: true, avatarSize: PopopxMetrics.minHitTarget) {
                    ItemsModel.shared.loadOpenChat(row.chat.id)
                }
                if row.chat.id != rows.last?.chat.id {
                    PopopxRowSeparator(inset: PopopxMetrics.minHitTarget + PopopxMetrics.spaceS)
                }
            }
        }
    }

    private var groups: [Row] {
        chatModel.chats.compactMap { chat in
            guard case let .group(groupInfo, _) = chat.chatInfo,
                  groupInfo.businessChat == nil,
                  !groupInfo.isChannel,
                  groupInfo.membership.memberCurrent else { return nil }
            // "created by me" uses the model's own predicate, and the role rules are not recomputed here (POPOPXChat/ChatTypes.swift:3075).
            return Row(chat: chat, isOwner: groupInfo.isOwner)
        }
    }

    private var owned: [Row] { groups.filter(\.isOwner) }
    private var joined: [Row] { groups.filter { !$0.isOwner } }
}

// // MARK: - Channels I follow page

/// The channel test is written in one place only: the pinned row's number and this page's rows must say the same thing, otherwise the badge contradicts the list.
private func isPopopxChannel(_ chat: Chat) -> Bool {
    guard !chat.chatInfo.chatDeleted, !chat.chatInfo.contactCard else { return false }
    guard let groupInfo = chat.chatInfo.groupInfo else { return false }
    // `ChatInfo.isChannel` = `groupInfo?.useRelays == true`（POPOPXChat/ChatTypes.swift:2296）；
    // `memberCurrent` follows the same definition as the `groups` of the groups page above: a channel already left is no longer a "channel I follow".
    return chat.chatInfo.isChannel && groupInfo.membership.memberCurrent
}

@MainActor private struct PopopxChannelsPage: View {
    @EnvironmentObject private var chatModel: ChatModel

    /// The preview switch is the same cell as the Messages tab's (`ChatsListView.swift:146`): a user who turns message preview off does so to
    /// "not read content in the list", and this page must not bypass it and read one anyway, so when it is off the whole row gets no activity line.
    @AppStorage(DEFAULT_PRIVACY_SHOW_CHAT_PREVIEWS) private var showChatPreviews = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                if channels.isEmpty {
                    PopopxSectionCard {
                        PopopxEmptyRow(title: Copy.channelsNoteEmpty, note: Copy.channelsEmptyNote)
                    }
                } else {
                    PopopxSectionCard(Copy.channelsTitle) {
                        ForEach(channels) { chat in
                            PopopxChannelRow(chat: chat, showsPreview: showChatPreviews) {
                                ItemsModel.shared.loadOpenChat(chat.id)
                            }
                            if chat.id != channels.last?.id {
                                PopopxRowSeparator(inset: PopopxMetrics.minHitTarget + PopopxMetrics.spaceS)
                            }
                        }
                    }
                }
            }
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.channelsTitle)
        // There is only one real path to join a channel: channel link / QR code → `planAndConnect` → `apiConnectPlan` →
        // `.groupLink` → `apiConnect` (`NewChatView.swift:1320`, `:1522`). This button wires that existing
        // scan/paste page to here, and creates no new subscription mechanism.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: PopopxContactsRoute.joinChannel) {
                    Label(Copy.joinChannelEntry, systemImage: "qrcode.viewfinder")
                }
            }
        }
    }

    /// The order follows `chatModel.chats` itself, the same definition as the Messages tab (`ChatsListView.swift:418` does not start a second sort either).
    private var channels: [Chat] {
        // System config chats for the current user, to be hidden from UI — matched by kind and id.
        let systemConfigRefs = chatModel.systemConfigChatRefs()
        return chatModel.chats.filter { chat in
            if let ref = PopopxSystemChatRef(chatType: chat.chatInfo.chatType, apiId: chat.chatInfo.apiId),
               systemConfigRefs.contains(ref) { return false }
            return isPopopxChannel(chat)
        }
    }
}

/// One channel row: antenna symbol (identity) + name + latest activity time + unread, and opening it goes through the same `loadOpenChat` the groups page uses.
/// `@MainActor` + `@ObservedObject`: the unread count and the "latest item" are both `Chat`'s own `@Published`,
/// and without observing them they only move when the whole page recomputes (same as `PopopxChatRow` in `ChatsListView.swift`).
@MainActor private struct PopopxChannelRow: View {
    @ObservedObject var chat: Chat
    let showsPreview: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxAvatar(
                    chat: chat,
                    size: PopopxMetrics.minHitTarget,
                    icon: chat.chatInfo.groupInfo?.chatIconName
                )

                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.space2XS) {
                        // The channel's identity symbol: with no custom avatar the antenna is already in the avatar slot, and with a custom avatar
                        // it is this one that says "this is a one-way broadcast, not a group chat" (the symbol comes from ChatTypes.swift:5747).
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(PopopxType.microTag)
                            .imageScale(.medium)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .accessibilityHidden(true)
                        Text(chat.chatInfo.chatViewName)
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.label)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: PopopxMetrics.spaceXS)
                        timestamp
                    }

                    if let activity {
                        Text(activity)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                unreadBadge
            }
            .padding(.vertical, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityElement(children: .combine)
    }

    private var timestamp: Text {
        formatTimestampText(chat.chatItems.last?.meta.itemTs ?? chat.chatInfo.chatTs)
            .font(PopopxType.metric)
            .foregroundStyle(PopopxPalette.labelSecondary)
    }

    /// Returns nil when the preview is off (the row simply does not write that line), instead of inventing a "content hidden" placeholder;
    /// recalled/filtered items get the existing localised wording from `ChatItem.text` itself.
    private var activity: String? {
        guard showsPreview else { return nil }
        guard let item = chat.chatItems.last else { return Copy.channelNoActivity }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Copy.channelNoActivity : text
    }

    /// The unread definition is the same place as `PopopxContactRow`'s: `ChatStats.unreadCount`, and with no number it still counts as one unread.
    @ViewBuilder private var unreadBadge: some View {
        let stats = chat.chatStats
        if stats.unreadCount > 0 || stats.unreadChat {
            unreadCountText(stats.unreadCount > 0 ? stats.unreadCount : 1)
                .font(PopopxType.metricSmall)
                .foregroundStyle(PopopxPalette.onBrand)
                .padding(.horizontal, PopopxMetrics.spaceXS)
                .frame(minWidth: PopopxMetrics.spaceXL, minHeight: PopopxMetrics.spaceXL)
                .background(PopopxPalette.brand, in: .capsule)
                .accessibilityLabel(Copy.unreadA11y(max(stats.unreadCount, 1)))
        }
    }
}

// // MARK: - Service accounts page

/// The dedicated list of service accounts — bots and services that completed the POPOPX eco handshake.
/// Kept apart from ordinary contacts so the address book stays personal. The identification is the same
/// `PopopxEcoSessionStore.hasSession(for:)` check the main tab uses to filter them out of `contactChats`.
@MainActor private struct PopopxServiceAccountsPage: View {
    @EnvironmentObject private var chatModel: ChatModel
    @AppStorage(DEFAULT_PRIVACY_SHOW_CHAT_PREVIEWS) private var showChatPreviews = true

    @State private var unfollowingChat: Chat?
    @State private var toast = PopopxToastModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                if serviceAccounts.isEmpty {
                    PopopxSectionCard {
                        PopopxEmptyRow(title: Copy.serviceAccountsEmptyTitle, note: Copy.serviceAccountsEmptyNote)
                    }
                } else {
                    PopopxSectionCard(Copy.serviceAccountsSectionTitle, footnote: Copy.serviceAccountsSectionFootnote) {
                        ForEach(serviceAccounts) { chat in
                            PopopxServiceAccountRow(
                                chat: chat,
                                showsPreview: showChatPreviews,
                                open: { ItemsModel.shared.loadOpenChat(chat.id) },
                                unfollow: { unfollowingChat = chat }
                            )
                            if chat.id != serviceAccounts.last?.id {
                                PopopxRowSeparator(inset: PopopxMetrics.minHitTarget + PopopxMetrics.spaceS)
                            }
                        }
                    }
                }
            }
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.serviceAccountsPageTitle)
        .popopxToast(toast)
        .alert(Copy.serviceAccountUnfollowConfirmTitle, isPresented: Binding(
            get: { unfollowingChat != nil },
            set: { if !$0 { unfollowingChat = nil } }
        )) {
            Button(Copy.serviceAccountUnfollowConfirmCancel, role: .cancel) {
                unfollowingChat = nil
            }
            Button(Copy.serviceAccountUnfollowConfirmAction, role: .destructive) {
                if let chat = unfollowingChat {
                    let chatCopy = chat
                    unfollowingChat = nil
                    Task {
                        await deleteChat(chatCopy)
                        toast.show(Copy.serviceAccountUnfollowedToast, kind: .encrypted)
                    }
                }
            }
        } message: {
            Text(Copy.serviceAccountUnfollowConfirmNote)
        }
    }

    /// Service accounts: direct contacts that completed the eco session handshake.
    /// Same definition as `PopopxContactsView.serviceAccountChats` — the two must never disagree.
    private var serviceAccounts: [Chat] {
        chatModel.chats.filter { chat in
            guard !chat.chatInfo.chatDeleted, !chat.chatInfo.contactCard else { return false }
            guard case let .direct(contact) = chat.chatInfo else { return false }
            return contact.active && !contact.isContactCard && PopopxEcoSessionStore.hasSession(for: contact.contactId)
        }
    }
}

/// One service account row: briefcase symbol + name + last activity + unread badge.
/// The layout mirrors `PopopxChannelRow` (same timestamp position, same unread badge shape),
/// differing only in the leading icon — briefcase for "this is a service", antenna for "this is a broadcast channel".
@MainActor private struct PopopxServiceAccountRow: View {
    @ObservedObject var chat: Chat
    let showsPreview: Bool
    let open: () -> Void
    let unfollow: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxAvatar(
                    chat: chat,
                    size: PopopxMetrics.minHitTarget,
                    icon: "briefcase.fill"
                )

                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.space2XS) {
                        Image(systemName: "briefcase.fill")
                            .font(PopopxType.microTag)
                            .imageScale(.medium)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .accessibilityHidden(true)
                        Text(chat.chatInfo.chatViewName)
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.label)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: PopopxMetrics.spaceXS)
                        timestamp
                    }

                    if let activity {
                        Text(activity)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                unreadBadge
            }
            .padding(.vertical, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button(role: .destructive, action: unfollow) {
                Label(Copy.serviceAccountUnfollow, systemImage: "person.fill.minus")
            }
        }
    }

    private var timestamp: Text {
        formatTimestampText(chat.chatItems.last?.meta.itemTs ?? chat.chatInfo.chatTs)
            .font(PopopxType.metric)
            .foregroundStyle(PopopxPalette.labelSecondary)
    }

    private var activity: String? {
        guard showsPreview else { return nil }
        guard let item = chat.chatItems.last else { return Copy.serviceAccountNoActivity }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Copy.serviceAccountNoActivity : text
    }

    @ViewBuilder private var unreadBadge: some View {
        let stats = chat.chatStats
        if stats.unreadCount > 0 || stats.unreadChat {
            unreadCountText(stats.unreadCount > 0 ? stats.unreadCount : 1)
                .font(PopopxType.metricSmall)
                .foregroundStyle(PopopxPalette.onBrand)
                .padding(.horizontal, PopopxMetrics.spaceXS)
                .frame(minWidth: PopopxMetrics.spaceXL, minHeight: PopopxMetrics.spaceXL)
                .background(PopopxPalette.brand, in: .capsule)
                .accessibilityLabel(Copy.unreadA11y(max(stats.unreadCount, 1)))
        }
    }
}

// // MARK: - Group-by-anonymous-identity sheet

private struct PopopxIdentitySheet: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.dismiss) private var dismiss

    let grouping: PopopxIdentityGrouping
    let contacts: [Chat]
    let onGrouping: (PopopxIdentityGrouping) -> Void

    @State private var toast = PopopxToastModel()
    @State private var switchingUserId: Int64?

    var body: some View {
        PopopxSheetContainer(Copy.identitiesTitle, subtitle: Copy.identitiesSubtitle) {
            PopopxSectionCard(Copy.identityListTitle, footnote: Copy.identityHiddenNote) {
                if identities.isEmpty {
                    PopopxEmptyRow(title: Copy.identityEmptyTitle, note: Copy.identityEmptyNote)
                } else {
                    ForEach(identities) { info in
                        PopopxIdentityRow(
                            info: info,
                            unread: unread(for: info),
                            isActive: info.user.activeUser,
                            busy: switchingUserId == info.user.userId
                        ) {
                            Task { @MainActor in await switchTo(info.user) }
                        }
                        if info.id != identities.last?.id {
                            PopopxRowSeparator(inset: PopopxMetrics.minHitTarget + PopopxMetrics.spaceS)
                        }
                    }
                }
            }

            PopopxSectionCard(Copy.groupingTitle, footnote: Copy.groupingFootnote) {
                ForEach(PopopxIdentityGrouping.allCases, id: \.rawValue) { choice in
                    PopopxPickerRow(
                        choice.label,
                        value: Copy.groupingCount(count(for: choice)),
                        systemImage: choice == grouping ? "checkmark.circle.fill" : "circle",
                        tint: choice == grouping ? .brand : .neutral
                    ) {
                        PopopxHaptics.selection()
                        onGrouping(choice)
                    }
                    if choice.rawValue != PopopxIdentityGrouping.allCases.last?.rawValue {
                        PopopxRowSeparator(inset: 0)
                    }
                }
            }
        } footer: {
            PopopxButton(Copy.done, role: .secondary) { dismiss() }
                .padding(PopopxMetrics.spaceM)
        }
        .popopxToast(toast)
    }

    private var identities: [UserInfo] {
        chatModel.users.filter { !$0.user.hidden }
    }

    /// The unread definition copies `ChatModel.totalUnreadCountForAllUsers()` (Shared/Model/ChatModel.swift:1187):
    /// the current identity sums from its own chats (respecting each chat's notification setting, counting only unread or only mentioned), and other identities read the core-maintained
    /// `UserInfo.unreadCount` (the same definition as the old identity picker, Shared/Views/ChatList/UserPicker.swift:181).
    /// No second counting scheme is started here, otherwise the numbers in the sheet would contradict the badge and the icon badge.
    private func unread(for info: UserInfo) -> Int {
        guard info.user.activeUser else { return info.unreadCount }
        return chatModel.chats.reduce(0) { total, chat in
            switch chat.chatInfo.chatSettings?.enableNtfs {
            case .all: total + chat.chatStats.unreadCount
            case .mentions: total + chat.chatStats.unreadMentions
            default: total
            }
        }
    }

    private func count(for choice: PopopxIdentityGrouping) -> Int {
        switch choice {
        case .all: return contacts.count
        case .main: return contacts.filter { !$0.chatInfo.incognito }.count
        case .anonymous: return contacts.filter { $0.chatInfo.incognito }.count
        }
    }

    @MainActor private func switchTo(_ user: User) async {
        guard chatModel.chatRunning == true else {
            toast.show(Copy.engineNotReadyToast, kind: .danger)
            return
        }
        guard !user.activeUser, switchingUserId == nil else { return }
        switchingUserId = user.userId
        do {
            try await changeActiveUserAsync_(user.userId, viewPwd: nil)
            toast.show(Copy.identitySwitchedToast(user.displayName), kind: .encrypted)
            switchingUserId = nil
            dismiss()
        } catch {
            switchingUserId = nil
            PopopxHaptics.notice(.error)
            toast.show(Copy.identitySwitchFailedToast, kind: .danger)
        }
    }
}

private struct PopopxIdentityRow: View {
    let info: UserInfo
    let unread: Int
    let isActive: Bool
    let busy: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: PopopxMetrics.spaceS) {
                ProfileImage(imageStr: info.user.image, size: PopopxMetrics.minHitTarget, color: PopopxPalette.labelSecondary)
                    .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                    .background(PopopxPalette.cardHigh, in: .rect(cornerRadius: PopopxMetrics.radiusAvatar))
                    .clipShape(.rect(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous)
                            .strokeBorder(
                                isActive ? PopopxPalette.brand : PopopxPalette.hairlineInner,
                                lineWidth: isActive ? PopopxMetrics.stroke : PopopxMetrics.hairline
                            )
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(info.user.displayName)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(isActive ? Copy.identityActiveNote : Copy.identitySwitchNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(isActive ? PopopxPalette.brand : PopopxPalette.labelSecondary)
                }

                Spacer(minLength: PopopxMetrics.spaceXS)

                if busy {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(PopopxPalette.brand)
                        .accessibilityLabel(Copy.identitySwitchingA11y)
                } else if unread > 0 {
                    unreadCountText(unread)
                        .font(PopopxType.metricSmall)
                        .foregroundStyle(PopopxPalette.onBrand)
                        .padding(.horizontal, PopopxMetrics.spaceXS)
                        .frame(minWidth: PopopxMetrics.spaceXL, minHeight: PopopxMetrics.spaceXL)
                        .background(PopopxPalette.brand, in: .capsule)
                        .accessibilityLabel(Copy.unreadA11y(unread))
                }
            }
            .padding(.vertical, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(busy)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Copy

/// Every Chinese sentence on the page appears here exactly once.
private enum Copy {
    /// The two sentences added this round (real-device round 3) use "the English source sentence is the Key": by convention `en.lproj` is not written,
    /// a missing entry falls back to the Key itself, which is English. The remaining members are still Phase 4's direct Chinese writes and this round does not touch them.
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX contacts groups")
    }

    /// A sentence carrying a number always gets exactly one placeholder (`%d`); with 16 languages the word order differs, so several parameters cannot be laid out by position
    /// (same standard as `PopopxTelemetryCopy.fmt`).
    private static func fmt(_ value: String, _ argument: CVarArg) -> String {
        String(format: key(value), argument)
    }

    static let createGroupEntry = key("Create an encrypted group")
    static let pageTitle = key("Contacts")
    static let searchPrompt = key("Search contacts or groups")
    static let done = key("Done")

    static let newConnectionsTitle = key("New encrypted connections")
    static let newConnectionsNoteEmpty = key("No connection requests waiting for you")
    static func newConnectionsNote(_ count: Int) -> String { fmt("%lld requests waiting for you", count) }

    static let groupsTitle = key("My encrypted groups")
    static let groupsNoteEmpty = key("No encrypted groups yet")
    static func groupsNote(_ count: Int) -> String { fmt("%lld encrypted groups", count) }

    static let identitiesTitle = key("Group by anonymous identity")
    static let identitiesSubtitle = key("Switch the anonymous identity this device uses, or filter contacts by the identity a connection was made with")
    static func identitiesValue(_ count: Int) -> String { fmt("%lld identities", count) }

    static func badgeOnlineA11y(_ count: Int) -> String { fmt("%lld online encrypted connection requests waiting for you", count) }
    static func badgeMeshA11y(_ count: Int) -> String { fmt("%lld Bluetooth mesh pairings waiting for you", count) }
    static func unreadA11y(_ count: Int) -> String { fmt("%d unread", count) }
    static let badgeSeparator = "，"

    static let engineNotReadyNote = key("The encrypted session is not ready yet — browse the lists for now and open a chat again later")
    static let engineNotReadyToast = key("The encrypted session is not ready yet")

    static let groupingAll = key("All contacts")
    static let groupingMain = key("Main identity connections")
    static let groupingAnonymous = key("Anonymous identity connections")
    static func groupingActiveNote(_ label: String) -> String { fmt("Grouped by %@", label) }
    static let groupingClear = key("Clear")
    static let groupingTitle = key("Group by connection identity")
    static let groupingFootnote = key("Taken from each chat's own connection record: a connection made with an anonymous identity is listed under Anonymous identity connections")
    static func groupingCount(_ count: Int) -> String { fmt("%lld contacts", count) }
    static let anonymousTag = key("Anonymous identity")

    static let indexMenuLabel = key("Jump to a letter")
    static func indexJumpLabel(_ key: String) -> String { fmt("Jump to %@", key) }

    static let emptyTitle = key("Contacts are still empty")
    static let emptyNote = key("Paste an invitation link, scan a code, or come close to the other person in Add friends to get your first encrypted connection.")
    static let noMatchTitle = key("No matching people")
    static let noMatchNote = key("Try a different part of a name; groups and contacts are searched together.")

    // // The new encrypted connection page
    static let onlineSectionTitle = key("Online encrypted connection requests")
    static let onlineSectionFootnote = key("Accepting adds the other person to your contacts; accepting anonymously builds this connection under another identity.")
    static let onlineEmptyTitle = key("No requests waiting for confirmation")
    static let onlineEmptyNote = key("New encrypted connection requests appear here.")
    static let requestNote = key("Wants to set up an encrypted connection with you")
    static let accept = key("Accept")
    static let acceptIncognito = key("Accept anonymously")
    static let reject = key("Reject")
    static let acceptedToast = key("Accepted — setting up the encrypted connection")
    static let acceptedIncognitoToast = key("Accepted with an anonymous identity")
    static let rejectedToast = key("Rejected this connection request")

    static let meshSectionTitle = key("Bluetooth mesh pairings waiting for confirmation")
    static let meshFootnoteManual = key("Confirming is what binds this device's Bluetooth key to a POPOPX contact.")
    static let meshFootnoteAuto = key("The pairing policy is silent: the nearby exchange binds on its own when it finishes, so only requests that have not settled are listed here.")
    static let meshFootnoteOff = key("The Bluetooth mesh switch is off, so there are no pairings waiting for confirmation.")
    static let meshFuseOffTitle = key("Bluetooth mesh is off")
    static let meshFuseOffNote = key("Turn Bluetooth mesh on in Settings and pairing requests from nearby devices will appear here.")
    static let meshEmptyTitle = key("No pairings waiting for confirmation")
    static let meshEmptyNote = key("A mesh pairing request from a device in the same room appears here.")
    static func meshPeerTitle(_ key: String) -> String { fmt("Device %@", key) }
    static let meshReceivedA11y = key("Request received")
    static let meshApprove = key("Confirm binding")
    static let meshDecline = key("Decline")
    static let meshApprovedToast = key("This device's Bluetooth key is now bound")
    static let meshApproveFailedToast = key("Binding failed — ask the other device to send the request again")
    static let meshDeclinedToast = key("Pairing declined")

    static let pendingSectionTitle = key("Connections being set up")
    static let pendingSectionFootnote = key("These connections are not contacts yet, so they stay out of the contacts list and cannot be opened.")
    static let pendingEmptyTitle = key("No connections in progress")
    static let pendingEmptyNote = key("Connections in progress show up here after you send or accept an invitation link.")
    static let pendingUnnamedConnection = key("Unnamed connection")
    static let pendingConnectionNote = key("Waiting for the other side to confirm")

    // // Groups page
    static let groupsOwnedTitle = key("Groups you created")
    static let groupsJoinedTitle = key("Groups you joined")
    static let groupsSectionFootnote = key("Channels and shop groups are not part of Contacts; they appear only in their own lists.")
    static func memberCount(_ count: Int64) -> String { fmt("%lld members", count) }
    static let groupsEmptyTitle = key("No encrypted groups yet")
    /// This sentence originally pointed to the + in the Messages tab's top-right corner; once this page grew its own create entry that sentence became a false path,
    /// so it was reworded this round and, riding on that rewording, turned into a Key (under an English system it used to leak Chinese).
    static let groupsEmptyNote = key("Start one with the plus button in the top right corner.")
    static let groupsNoneTitle = key("None yet")
    static let groupsNoneNote = key("No groups in this category yet.")

    // // Channels page (added this round: the pinned row + the "channels I follow" page + "join channel")
    static let channelsTitle = key("Subscribed channels")
    static let channelsNoteEmpty = key("No channels yet")
    static func channelsNote(_ count: Int) -> String { fmt("%d channels you follow", count) }
    static let channelsEmptyNote = key("Use Join channel in the top right corner to open a channel from a link or a QR code, or create a public channel with the plus button on the Messages tab.")
    static let channelNoActivity = key("No messages in this channel yet")
    /// Reusing existing entries: `"Join channel"` (zh-Hans:3710) and `"Paste link / Scan"`
    /// (zh-Hans:4785) are already in the catalogues — each has 7 catalogues (de/es/fr/hu/it/ru/zh-Hans),
    /// and the remaining catalogues fall back to the English source sentence. The six newly coined sentences above are in no catalogue at all yet, waiting for a batch translation pass.
    static let joinChannelEntry = key("Join channel")
    static let joinChannelPageTitle = key("Paste link / Scan")

    // // Service accounts page (separated from ordinary contacts — eco-handshaked bots and services)
    static let serviceAccountsTitle = key("Service Accounts")
    static let serviceAccountsNoteEmpty = key("No service accounts followed yet")
    static func serviceAccountsNote(_ count: Int) -> String { fmt("%d service accounts", count) }
    static let serviceAccountsPageTitle = key("Service Accounts")
    static let serviceAccountsEmptyTitle = key("No service accounts yet")
    static let serviceAccountsEmptyNote = key("Service accounts you connect to through the POPOPX ecosystem will appear here, separate from your personal contacts.")
    static let serviceAccountsSectionTitle = key("Followed service accounts")
    static let serviceAccountsSectionFootnote = key("These are bots and services that completed the POPOPX ecosystem handshake. They are kept apart from your personal contacts.")
    static let serviceAccountUnfollow = key("Unfollow")
    static let serviceAccountUnfollowConfirmTitle = key("Unfollow this service account?")
    static let serviceAccountUnfollowConfirmNote = key("The conversation history will be removed and this service will no longer appear in your contacts. You can follow it again later.")
    static let serviceAccountUnfollowConfirmAction = key("Unfollow")
    static let serviceAccountUnfollowConfirmCancel = key("Keep")
    static let serviceAccountUnfollowedToast = key("Unfollowed")
    static let serviceAccountNoActivity = key("No messages yet")

    // // Identity sheet
    static let identityListTitle = key("Anonymous identities on this device")
    static let identityHiddenNote = key("Hidden identities that carry a password are not listed here; unlock them with the password on the Me tab, then switch.")
    static let identityEmptyTitle = key("Only one identity")
    static let identityEmptyNote = key("The encrypted session is not ready yet; the identity list appears once it is.")
    static let identityActiveNote = key("In use")
    static let identitySwitchNote = key("Tap to switch to this identity")
    static let identitySwitchingA11y = key("Switching identity")
    static func identitySwitchedToast(_ name: String) -> String { fmt("Switched to %@", name) }
    static let identitySwitchFailedToast = key("Switching identity failed — try again later")
}

// MARK: - Preview

#if DEBUG
struct PopopxContactsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxContactsView()
        }
        .environmentObject(ChatModel.shared)
        .environmentObject(AppTheme.shared)
    }
}

struct PopopxNewConnectionsPage_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxNewConnectionsPage()
        }
        .environmentObject(ChatModel.shared)
        .environmentObject(AppTheme.shared)
    }
}

struct PopopxGroupsPage_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxGroupsPage()
        }
        .environmentObject(ChatModel.shared)
        .environmentObject(AppTheme.shared)
    }
}
#endif
