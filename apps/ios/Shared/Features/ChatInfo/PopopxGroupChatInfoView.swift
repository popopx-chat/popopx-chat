//
//  PopopxGroupChatInfoView.swift
//  POPOPX (iOS)
//
//  [Redesign] The group chat info page. One group card at the top (shared avatar, group name, full name, member count), then grouped cards below:
//  Group profile / Messages / Members / Dangerous actions. The input interface matches the old `Shared/Views/Chat/Group/GroupChatInfoView.swift`
//  exactly (same properties, same argument labels and order), so mounting it later only needs one word changed in ChatView.swift — the type name.
//
//  Three design decisions:
//  1. Only the real actions belonging to the "group" path are kept. In the old page the branches belonging to channel/relay (useRelays), member support, reporting,
//     businessChat are not carried over at all (the list is in the delivery report, all with the old line numbers).
//  2. Every row pushes a page that really exists, whose init was checked one by one; destructive actions all have a real confirmation step,
//     no placeholder buttons, and no comments standing in for code.
//  3. Colour, font size, corner radius and spacing only come from the tokens in Shared/Theme/PopopxTheme.swift; controls only use
//     the atom library already in Shared/Components. The copy is hard-coded Simplified Chinese, collected in the `Copy` at the end of the file.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand — the iron rule forbids scripts from modifying project.pbxproj.
//

import SwiftUI
import POPOPXChat

@MainActor
struct PopopxGroupChatInfoView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var chat: Chat
    @Binding var groupInfo: GroupInfo
    @Binding var scrollToItemId: ChatItem.ID?
    @Binding var composeState: ComposeState
    var onSearch: () -> Void
    @State private var localAlias: String

    /// Group link; nil = not created yet. onAppear reads the real state via `apiGetGroupLink`.
    @State private var groupLink: GroupLink?
    @State private var groupLinkMemberRole: GroupMemberRole = .member
    @State private var groupPreferences: FullGroupPreferences
    @State private var sendReceipts = SendReceipts.userDefault(true)
    @State private var sendReceiptsUserDefault = true
    @State private var progressIndicator = false
    @State private var memberFilter = ""
    @State private var confirm: PopopxGroupConfirm?
    @State private var removeTarget: GroupMember?
    @State private var toast = PopopxToastModel()

    /// The same rule as the old page: once active members exceed this number, read receipts are no longer sent.
    private static let receiptsMemberLimit = 20

    init(
        chat: Chat,
        groupInfo: Binding<GroupInfo>,
        scrollToItemId: Binding<ChatItem.ID?>,
        composeState: Binding<ComposeState>,
        onSearch: @escaping () -> Void,
        localAlias: String
    ) {
        self.chat = chat
        self._groupInfo = groupInfo
        self._scrollToItemId = scrollToItemId
        self._composeState = composeState
        self.onSearch = onSearch
        _localAlias = State(initialValue: localAlias)
        _groupPreferences = State(initialValue: groupInfo.wrappedValue.fullGroupPreferences)
    }

    // MARK: Members

    /// Active members (not left, not removed), ordered by role from highest to lowest. Same criterion as the old page :74-76.
    private var members: [GMember] {
        chatModel.groupMembers
            .filter { let s = $0.wrapped.memberStatus; return s != .memLeft && s != .memRemoved }
            .sorted { $0.wrapped.memberRole > $1.wrapped.memberRole }
    }

    private var visibleMembers: [GMember] {
        let s = memberFilter.trimmingCharacters(in: .whitespaces).localizedLowercase
        guard !s.isEmpty else { return members }
        return members.filter { $0.wrapped.localAliasAndFullName.localizedLowercase.contains(s) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    headerCard
                    renameCard
                    groupCard
                    subscriptionCard
                    messageCard
                    membersCard
                    dangerCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, PopopxMetrics.spaceS)
                .padding(.bottom, PopopxMetrics.space2XL)
                .popopxAnimation(PopopxSpring.fluid, value: members.count, reduceMotion: reduceMotion)
            }
            .background(PopopxPalette.base)
            .navigationTitle(Copy.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert(confirmTitle, isPresented: confirmPresented) {
            confirmActions
        } message: {
            Text(verbatim: confirmMessage)
        }
        .confirmationDialog(Copy.removeTitle, isPresented: removePresented, titleVisibility: .visible) {
            Button(Copy.removeWithMessages, role: .destructive) {
                if let mem = removeTarget { removeMember(groupInfo, mem, withMessages: true, dismiss: nil) }
            }
            Button(Copy.removeOnly, role: .destructive) {
                if let mem = removeTarget { removeMember(groupInfo, mem, withMessages: false, dismiss: nil) }
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(verbatim: removeTarget.map { String(format: Copy.removeMessageFormat, $0.chatViewName) } ?? "")
        }
        .onAppear { loadInitialState() }
        .disabled(progressIndicator)
        .opacity(progressIndicator ? 0.6 : 1)
        .overlay {
            if progressIndicator {
                Rectangle()
                    .fill(PopopxMaterial.bar)
                    .ignoresSafeArea()
                    .overlay(ProgressView().controlSize(.large).tint(PopopxPalette.brand))
            }
        }
        .popopxToast(toast)
    }

    // MARK: Top group card

    private var headerCard: some View {
        PopopxSectionCard {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                ChatInfoImage(chat: chat, size: PopopxMetrics.space2XL * 2)
                    .clipShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(groupInfo.displayName)
                        .font(PopopxType.title)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    let fullName = groupInfo.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !fullName.isEmpty && fullName != groupInfo.displayName {
                        Text(fullName)
                            .font(PopopxType.secondary)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(String(format: Copy.memberCountFormat, members.count + 1))
                        .font(PopopxType.metric)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let nextNtfMode = chat.chatInfo.nextNtfMode {
                PopopxGroupDivider()
                quickActions(nextNtfMode)
            }
        }
    }

    private func quickActions(_ nextNtfMode: MsgFilter) -> some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            PopopxGroupQuickAction(
                title: Copy.search,
                systemImage: "magnifyingglass",
                disabled: !groupInfo.ready || chat.chatItems.isEmpty
            ) {
                dismiss()
                onSearch()
            }
            PopopxGroupQuickAction(
                title: Copy.muteToggle,
                systemImage: nextNtfMode.iconFilled,
                disabled: !groupInfo.ready
            ) {
                toggleNotifications(chat, enableNtfs: nextNtfMode)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Group note name

    private var renameCard: some View {
        PopopxSectionCard(Copy.renameGroup, footnote: Copy.renameFootnote) {
            PopopxTextField(Copy.renameField, prompt: Copy.renameField, text: $localAlias, systemImage: "pencil") { _ in
                setGroupAlias()
            }
        }
    }

    // MARK: Group profile

    @ViewBuilder private var groupCard: some View {
        PopopxSectionCard(Copy.sectionGroup) {
            if groupInfo.isOwner {
                PopopxGroupRowLink(Copy.editProfile, systemImage: "pencil", tint: .brand) {
                    GroupProfileView(groupInfo: $groupInfo, groupProfile: groupInfo.groupProfile)
                        .navigationTitle(Copy.editProfile)
                }
                PopopxGroupDivider()
            }
            if groupInfo.groupProfile.description != nil || groupInfo.isOwner {
                PopopxGroupRowLink(
                    groupInfo.groupProfile.description == nil ? Copy.addWelcome : Copy.welcome,
                    systemImage: groupInfo.groupProfile.description == nil ? "plus.message" : "message",
                    tint: .brand
                ) {
                    GroupWelcomeView(
                        groupInfo: $groupInfo,
                        groupProfile: groupInfo.groupProfile,
                        welcomeText: groupInfo.groupProfile.description ?? ""
                    )
                    .navigationTitle(Copy.welcome)
                }
                PopopxGroupDivider()
            }
            PopopxGroupRowLink(Copy.preferences, systemImage: "switch.2") {
                GroupPreferencesView(
                    groupInfo: $groupInfo,
                    preferences: $groupPreferences,
                    currentPreferences: groupInfo.fullGroupPreferences,
                    creatingGroup: false,
                    savePreferences: { savePreferences() }
                )
                .navigationTitle(Copy.preferences)
            }
            if groupInfo.canAddMembers && groupInfo.businessChat == nil {
                PopopxGroupDivider()
                PopopxGroupRowLink(
                    groupLink == nil ? Copy.createLink : Copy.groupLink,
                    value: groupLink == nil ? Copy.linkAbsent : Copy.linkPresent,
                    systemImage: groupLink == nil ? "link.badge.plus" : "link"
                ) {
                    GroupLinkView(
                        groupId: groupInfo.groupId,
                        groupLink: $groupLink,
                        groupLinkMemberRole: $groupLinkMemberRole,
                        showTitle: false,
                        creatingGroup: false,
                        isChannel: groupInfo.useRelays,
                        groupInfo: groupInfo,
                        composeState: $composeState
                    )
                    .navigationTitle(Copy.groupLink)
                }
            }
        }
    }

    // MARK: Channel subscription threshold

    /// Only channels draw this cell (the criterion `GroupInfo.isChannel` = `publicGroup?.groupType == .channel`,
    /// ChatTypes.swift:3064, :3233). Private groups do not get it: the subscription semantics need someone who sets the price, and in a group the members are all masters to each other.
    ///
    /// The channel-owner branch pushes the real publishing page, **admins can enter too** (the criterion is the same one as the guard in `sendChannelAccess`:
    /// `popopxCanPublishChannelThreshold`); the member branch is read-only and shows the credential held on this device.
    /// Members do **not** subscribe or renew here, because the price is not on this device: the threshold is carried only by that card inside the channel,
    /// so putting a made-up number on this page would charge money nobody ever announced. That is why the copy points the entry back at that card.
    @ViewBuilder private var subscriptionCard: some View {
        if groupInfo.isChannel {
            PopopxSectionCard(Copy.sectionSubscription,
                              footnote: groupInfo.popopxCanPublishChannelThreshold ? nil : Copy.memberFootnote) {
                if groupInfo.popopxCanPublishChannelThreshold {
                    PopopxGroupRowLink(Copy.publishThreshold, systemImage: "lock", tint: .brand) {
                        PopopxChannelThresholdView(groupId: groupInfo.groupId,
                                                   channelTitle: groupInfo.displayName)
                            .navigationTitle(Copy.publishThreshold)
                    }
                } else {
                    PopopxPickerRow(Copy.subscriptionState,
                                    value: memberTicketValue,
                                    systemImage: memberTicketValue == nil ? "lock.open" : "lock.fill") { }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// The number on the right of the member side's cell: the validity date, or nil = this device holds no such credential.
    /// The key is `GroupInfo.id`, the same string that `ChatInfo.id` used when the card signed the credential (the group case of `ChatInfo`
    /// just forwards to `groupInfo.id`), so "subscribe in the channel" and "see the status on this page" necessarily point at the same ticket.
    private var memberTicketValue: String? {
        guard let ticket = PopopxCreditsManager.shared.ticket(forChannelId: groupInfo.id) else { return nil }
        return String(format: Copy.subscriptionValidFormat, PopopxCommerceFormat.date(ticket.expiresAtMs))
    }

    // MARK: Messages

    @ViewBuilder private var messageCard: some View {
        PopopxSectionCard(Copy.sectionMessage, footnote: Copy.retentionFootnote) {
            ChatTTLOption(chat: chat, progressIndicator: $progressIndicator)
            PopopxGroupDivider()
            receiptsBlock
        }
    }

    @ViewBuilder private var receiptsBlock: some View {
        if members.filter({ $0.wrapped.memberCurrent }).count > Self.receiptsMemberLimit {
            HStack(spacing: PopopxMetrics.spaceS) {
                Text(Copy.receipts)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Text(Copy.receiptsDisabled)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            }
            .padding(.vertical, PopopxMetrics.spaceXS)
        } else {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(Copy.receipts)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                    .padding(.bottom, PopopxMetrics.space2XS)
                PopopxSegmentedControl(
                    [
                        .init(selection: .yes, title: Copy.receiptsYes),
                        .init(selection: .no, title: Copy.receiptsNo),
                        .init(selection: .userDefault(sendReceiptsUserDefault), title: Copy.receiptsDefault)
                    ],
                    title: { receiptsOptionTitle($0) },
                    selection: $sendReceipts
                )
                .onChange(of: sendReceipts) { _, _ in setSendReceipts() }
            }
        }
    }

    // MARK: Members

    @ViewBuilder private var membersCard: some View {
        PopopxSectionCard(Copy.sectionMembers(String(format: Copy.memberCountSuffixFormat, members.count + 1))) {
            if groupInfo.canAddMembers {
                PopopxGroupRowLink(Copy.inviteMembers, systemImage: "person.fill.badge.plus", tint: .brand) {
                    AddGroupMembersView(chat: chat, groupInfo: groupInfo)
                        .navigationTitle(Copy.inviteMembers)
                        .onAppear {
                            Task { await chatModel.loadGroupMembers(groupInfo) }
                        }
                }
                PopopxGroupDivider()
            }
            PopopxTextField(Copy.searchMembers, prompt: Copy.searchMembers, text: $memberFilter, systemImage: "magnifyingglass")
                .padding(.bottom, PopopxMetrics.space2XS)

            selfMemberRow
            ForEach(visibleMembers) { member in
                PopopxGroupDivider()
                memberRow(member)
            }
        }
    }

    /// Own row: no navigation, no action menu, only the role.
    private var selfMemberRow: some View {
        let member = groupInfo.membership
        return HStack(spacing: PopopxMetrics.spaceS) {
            MemberProfileImage(member, size: PopopxMetrics.space2XL)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text("\(Copy.youPrefix) \(member.chatViewName)")
                    .font(PopopxType.body)
                    .foregroundStyle(member.memberIncognito ? PopopxPalette.brand : PopopxPalette.label)
                    .lineLimit(1)
                Text(Copy.youStatus)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: PopopxMetrics.spaceXS)
            PopopxGroupRoleChip(roleText(member.memberRole), emphasized: member.memberRole >= .admin)
        }
        .frame(minHeight: PopopxMetrics.minHitTarget)
        .contentShape(Rectangle())
    }

    private func memberRow(_ memberObject: GMember) -> some View {
        let member = memberObject.wrapped
        return HStack(spacing: PopopxMetrics.spaceS) {
            NavigationLink {
                GroupMemberInfoView(
                    groupInfo: groupInfo,
                    chat: chat,
                    groupMember: memberObject,
                    scrollToItemId: $scrollToItemId
                )
            } label: {
                HStack(spacing: PopopxMetrics.spaceS) {
                    MemberProfileImage(member, size: PopopxMetrics.space2XL)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                        Text(member.chatViewName)
                            .font(PopopxType.body)
                            .foregroundStyle(member.memberIncognito ? PopopxPalette.brand : PopopxPalette.label)
                            .lineLimit(1)
                        if let status = memberStatusText(member) {
                            Text(status)
                                .font(PopopxType.caption)
                                .foregroundStyle(PopopxPalette.labelSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: PopopxMetrics.spaceXS)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle())

            if memberActionPresent(member) {
                memberActionMenu(member)
            } else {
                PopopxGroupRoleChip(roleText(member.memberRole), emphasized: member.memberRole >= .admin)
            }
        }
        .frame(minHeight: PopopxMetrics.minHitTarget)
        .accessibilityElement(children: .contain)
    }

    private func memberActionPresent(_ member: GroupMember) -> Bool {
        groupInfo.canModerate || member.memberSettings.showMessages || member.blocked
    }

    @ViewBuilder private func memberActionMenu(_ member: GroupMember) -> some View {
        Menu {
            if member.memberRole != .relay {
                PopopxGroupRoleChipHeader(text: roleText(member.memberRole))
            }
            if member.memberSettings.showMessages {
                Button {
                    confirm = .blockMember(member)
                } label: {
                    Label(Copy.blockMember, systemImage: "hand.raised")
                }
            } else {
                Button {
                    confirm = .unblockMember(member)
                } label: {
                    Label(Copy.unblockMember, systemImage: "hand.raised.slash")
                }
            }
            if member.canBlockForAll(groupInfo: groupInfo) {
                if member.blockedByAdmin {
                    Button {
                        confirm = .unblockForAll(member)
                    } label: {
                        Label(Copy.unblockForAll, systemImage: "hand.raised.slash.fill")
                    }
                } else {
                    Button {
                        confirm = .blockForAll(member)
                    } label: {
                        Label(Copy.blockForAll, systemImage: "hand.raised.fill")
                    }
                }
            }
            if member.canBeRemoved(groupInfo: groupInfo) {
                Divider()
                Button(role: .destructive) {
                    removeTarget = member
                } label: {
                    Label(Copy.removeMember, systemImage: "trash")
                }
            }
        } label: {
            PopopxGroupRoleChip(roleText(member.memberRole), emphasized: member.memberRole >= .admin)
                .overlay(alignment: .topTrailing) {
                    if member.blockedByAdmin || !member.memberSettings.showMessages {
                        PopopxBlockedDot()
                    }
                }
        }
        .buttonStyle(PopopxPressButtonStyle())
    }

    // MARK: Dangerous actions

    @ViewBuilder private var dangerCard: some View {
        PopopxSectionCard(Copy.sectionDanger, footnote: Copy.dangerFootnote) {
            PopopxDangerRow(Copy.clearChat, systemImage: "gobackward") {
                confirm = .clearChat
            }
            PopopxGroupDivider()
            if groupInfo.membership.memberCurrentOrPending, leaveAllowed {
                PopopxDangerRow(Copy.leaveGroup, systemImage: "rectangle.portrait.and.arrow.right") {
                    confirm = .leaveGroup
                }
            }
            if groupInfo.canDelete {
                PopopxGroupDivider()
                PopopxDangerRow(Copy.deleteGroup, systemImage: "trash") {
                    confirm = .deleteGroup
                }
            }
        }
    }

    /// Same criterion as the old page :249-250: when you are the owner and the group has no other owner, leaving is not offered.
    private var leaveAllowed: Bool {
        !groupInfo.isOwner
            || members.contains { $0.wrapped.memberRole == .owner && $0.wrapped.groupMemberId != groupInfo.membership.groupMemberId }
    }

    // MARK: Behaviour

    private func loadInitialState() {
        if let currentUser = chatModel.currentUser {
            sendReceiptsUserDefault = currentUser.sendRcptsSmallGroups
        }
        sendReceipts = SendReceipts.fromBool(groupInfo.chatSettings.sendRcpts, userDefault: sendReceiptsUserDefault)
        do {
            if let gLink = try apiGetGroupLink(groupInfo.groupId) {
                groupLink = gLink
                groupLinkMemberRole = gLink.acceptMemberRole
            }
        } catch let error {
            logger.error("PopopxGroupChatInfoView apiGetGroupLink: \(responseError(error))")
        }
    }

    private func setGroupAlias() {
        let trimmed = localAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != groupInfo.localAlias else { return }
        Task { @MainActor in
            do {
                if let gInfo = try await apiSetGroupAlias(groupId: chat.chatInfo.apiId, localAlias: trimmed) {
                    chatModel.updateGroup(gInfo)
                    toast.show(Copy.renamed, kind: .success)
                }
            } catch {
                logger.error("PopopxGroupChatInfoView setGroupAlias error: \(responseError(error))")
                toast.show(Copy.renameFailed, kind: .danger)
            }
        }
    }

    private func setSendReceipts() {
        var chatSettings = chat.chatInfo.chatSettings ?? ChatSettings.defaults
        chatSettings.sendRcpts = sendReceipts.bool()
        updateChatSettings(chat, chatSettings: chatSettings)
    }

    private func receiptsOptionTitle(_ option: SendReceipts) -> String {
        switch option {
        case .yes: return Copy.receiptsYes
        case .no: return Copy.receiptsNo
        case .userDefault: return Copy.receiptsDefault
        }
    }

    private func savePreferences() {
        Task { @MainActor in
            do {
                var gp = groupInfo.groupProfile
                gp.groupPreferences = toGroupPreferences(groupPreferences)
                let gInfo = try await apiUpdateGroup(groupInfo.groupId, gp)
                groupInfo = gInfo
                chatModel.updateGroup(gInfo)
                toast.show(Copy.preferencesSaved, kind: .success)
            } catch {
                logger.error("PopopxGroupChatInfoView savePreferences error: \(responseError(error))")
                toast.show(Copy.preferencesFailed, kind: .danger)
            }
        }
    }

    private func deleteGroup() {
        Task { @MainActor in
            do {
                try await apiDeleteChat(type: chat.chatInfo.chatType, id: chat.chatInfo.apiId)
                dismiss()
                chatModel.chatId = nil
                chatModel.removeChat(chat.chatInfo.id)
            } catch {
                logger.error("PopopxGroupChatInfoView deleteGroup error: \(responseError(error))")
                toast.show(Copy.deleteFailed, kind: .danger)
            }
        }
    }

    private func clearChatMessages() {
        Task { @MainActor in
            await clearChat(chat)
            dismiss()
        }
    }

    private func leaveGroupFlow() {
        Task { @MainActor in
            await leaveGroup(chat.chatInfo.apiId)
            dismiss()
        }
    }

    private func blockMember(_ member: GroupMember) {
        toggleShowMemberMessages(groupInfo, member, false)
        toast.show(Copy.memberBlocked, kind: .success)
    }

    private func unblockMember(_ member: GroupMember) {
        toggleShowMemberMessages(groupInfo, member, true)
        toast.show(Copy.memberUnblocked, kind: .success)
    }

    private func blockForAll(_ member: GroupMember) {
        blockMemberForAll(groupInfo, member, true)
        toast.show(Copy.memberBlockedForAll, kind: .danger)
    }

    private func unblockForAll(_ member: GroupMember) {
        blockMemberForAll(groupInfo, member, false)
        toast.show(Copy.memberUnblockedForAll, kind: .success)
    }

    // MARK: Text derivation

    private func roleText(_ role: GroupMemberRole) -> String {
        switch role {
        case .owner: return Copy.roleOwner
        case .admin: return Copy.roleAdmin
        case .moderator: return Copy.roleModerator
        case .member: return Copy.roleMember
        case .observer: return Copy.roleObserver
        case .author: return Copy.roleAuthor
        case .relay: return Copy.roleRelay
        }
    }

    private func memberStatusText(_ member: GroupMember) -> String? {
        if member.blockedByAdmin { return Copy.statusBlockedAdmin }
        if !member.memberSettings.showMessages { return Copy.statusBlockedMe }
        if member.memberPending { return Copy.statusPending }
        if !member.memberCurrent { return Copy.statusNotJoined }
        return nil
    }

    private var confirmTitle: String {
        switch confirm {
        case .deleteGroup: return Copy.deleteConfirmTitle
        case .clearChat: return Copy.clearConfirmTitle
        case .leaveGroup: return Copy.leaveConfirmTitle
        case let .blockMember(m), let .blockForAll(m): return String(format: Copy.blockConfirmTitleFormat, m.chatViewName)
        case let .unblockMember(m), let .unblockForAll(m): return String(format: Copy.unblockConfirmTitleFormat, m.chatViewName)
        case .removeTarget: return Copy.removeTitle
        case nil: return ""
        }
    }

    private var confirmMessage: String {
        switch confirm {
        case .deleteGroup: return Copy.deleteConfirmMessage
        case .clearChat: return Copy.clearConfirmMessage
        case .leaveGroup: return Copy.leaveConfirmMessage
        case .blockMember, .blockForAll: return Copy.blockConfirmMessage
        case .unblockMember, .unblockForAll: return Copy.unblockConfirmMessage
        case .removeTarget: return ""
        case nil: return ""
        }
    }

    @ViewBuilder private var confirmActions: some View {
        switch confirm {
        case .deleteGroup:
            Button(Copy.delete, role: .destructive) { deleteGroup() }
            Button(Copy.cancel, role: .cancel) {}
        case .clearChat:
            Button(Copy.clear, role: .destructive) { clearChatMessages() }
            Button(Copy.cancel, role: .cancel) {}
        case .leaveGroup:
            Button(Copy.leave, role: .destructive) { leaveGroupFlow() }
            Button(Copy.cancel, role: .cancel) {}
        case let .blockMember(member):
            Button(Copy.block, role: .destructive) { blockMember(member) }
            Button(Copy.cancel, role: .cancel) {}
        case let .unblockMember(member):
            Button(Copy.unblock) { unblockMember(member) }
            Button(Copy.cancel, role: .cancel) {}
        case let .blockForAll(member):
            Button(Copy.block, role: .destructive) { blockForAll(member) }
            Button(Copy.cancel, role: .cancel) {}
        case let .unblockForAll(member):
            Button(Copy.unblock) { unblockForAll(member) }
            Button(Copy.cancel, role: .cancel) {}
        case .removeTarget, nil:
            EmptyView()
        }
    }

    private var confirmPresented: Binding<Bool> {
        Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })
    }

    private var removePresented: Binding<Bool> {
        Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })
    }
}

// // MARK: - Confirmation state

/// One action awaiting confirmation. The destructive ones (delete / clear / remove / block) all go through it to a real confirmation dialog.
private enum PopopxGroupConfirm: Identifiable, Hashable {
    case deleteGroup
    case clearChat
    case leaveGroup
    case blockMember(GroupMember)
    case unblockMember(GroupMember)
    case blockForAll(GroupMember)
    case unblockForAll(GroupMember)
    case removeTarget

    var id: String {
        switch self {
        case .deleteGroup: return "deleteGroup"
        case .clearChat: return "clearChat"
        case .leaveGroup: return "leaveGroup"
        case let .blockMember(m): return "blockMember-\(m.groupMemberId)"
        case let .unblockMember(m): return "unblockMember-\(m.groupMemberId)"
        case let .blockForAll(m): return "blockForAll-\(m.groupMemberId)"
        case let .unblockForAll(m): return "unblockForAll-\(m.groupMemberId)"
        case .removeTarget: return "removeTarget"
        }
    }
}

// // MARK: - Local components

/// The divider inside the card. The name is unique, to avoid clashing with a same-named helper in a parallel file.
private struct PopopxGroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

/// The two light actions in the header: search, mute. The whole thing is a Button with a 44pt hit target.
@MainActor
private struct PopopxGroupQuickAction: View {
    private let title: String
    private let systemImage: String
    private let disabled: Bool
    private let action: () -> Void

    init(title: String, systemImage: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: systemImage)
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                Text(title)
                    .font(PopopxType.meta)
            }
            .foregroundStyle(PopopxPalette.label)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// A row that pushes an existing page. The row body is made non-hittable and the outer NavigationLink takes the tap (the same writing as PopopxMeView).
@MainActor
private struct PopopxGroupRowLink<Destination: View>: View {
    private let title: String
    private let value: String?
    private let systemImage: String?
    private let tint: PopopxIconTint
    private let destination: () -> Destination

    init(
        _ title: String,
        value: String? = nil,
        systemImage: String? = nil,
        tint: PopopxIconTint = .neutral,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            PopopxPickerRow(title, value: value, systemImage: systemImage, tint: tint) { }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(verbatim: Copy.linkHint))
    }
}

/// Member role chip. owner/admin use the brand accent, the rest a neutral ground — no mesh, so as not to fake a transmission channel.
private struct PopopxGroupRoleChip: View {
    private let text: String
    private let emphasized: Bool

    init(_ text: String, emphasized: Bool = false) {
        self.text = text
        self.emphasized = emphasized
    }

    var body: some View {
        Text(text)
            .font(PopopxType.microTag)
            .foregroundStyle(emphasized ? PopopxPalette.brand : PopopxPalette.labelSecondary)
            .padding(.horizontal, PopopxMetrics.spaceXS)
            .padding(.vertical, PopopxMetrics.space2XS)
            .background(
                emphasized ? PopopxPalette.brand.opacity(0.12) : PopopxPalette.separator,
                in: .rect(cornerRadius: PopopxMetrics.radiusChip)
            )
            .accessibilityHidden(true)
    }
}

/// The role explanation at the top of the Menu (a non-button text line inside the menu items).
private struct PopopxGroupRoleChipHeader: View {
    private let text: String
    init(text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text)
    }
}

/// The blocked dot, overlaid on the top-right corner of the role chip.
private struct PopopxBlockedDot: View {
    var body: some View {
        Circle()
            .fill(PopopxPalette.dangerFill)
            .frame(width: PopopxMetrics.space2XS, height: PopopxMetrics.space2XS)
            .overlay(Circle().strokeBorder(PopopxPalette.card, lineWidth: PopopxMetrics.hairline))
            .offset(x: PopopxMetrics.space2XS / 2, y: PopopxMetrics.space2XS / 2)
            .accessibilityHidden(true)
    }
}

/// A dangerous row. Text and icon both use dangerInk; after the tap the caller shows a real confirmation.
@MainActor
private struct PopopxDangerRow: View {
    private let title: String
    private let systemImage: String
    private let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PopopxMetrics.spaceS) {
                Image(systemName: systemImage)
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                Text(title)
                    .font(PopopxType.sectionHeader)
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .foregroundStyle(PopopxPalette.dangerInk)
            .padding(.vertical, PopopxMetrics.spaceXS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: .medium))
    }
}

// // MARK: - Copy

/// Every Chinese sentence on the page appears exactly once, here.
private enum Copy {
    static let pageTitle = NSLocalizedString("Group info", comment: "")
    static let cancel = NSLocalizedString("Cancel", comment: "")
    static let linkHint = NSLocalizedString("Open", comment: "")

    // // Top group card
    static let memberCountFormat = NSLocalizedString("%lld members", comment: "")
    static let search = NSLocalizedString("Search", comment: "")
    static let muteToggle = NSLocalizedString("Mute", comment: "")

    // // Note name
    static let renameGroup = NSLocalizedString("Group alias", comment: "")
    static let renameField = NSLocalizedString("Set group alias", comment: "")
    static let renameFootnote = NSLocalizedString("The alias is stored only on this device; other members are not notified.", comment: "")
    static let renamed = NSLocalizedString("Group alias updated", comment: "")
    static let renameFailed = NSLocalizedString("Renaming failed, please try again later", comment: "")

    // // Section titles
    static let sectionGroup = NSLocalizedString("Group details", comment: "")
    static func sectionMembers(_ suffix: String) -> String { String(format: NSLocalizedString("Members %@", comment: ""), suffix) }
    static let memberCountSuffixFormat = NSLocalizedString("(%lld)", comment: "")
    static let sectionMessage = NSLocalizedString("Messages", comment: "")
    static let sectionDanger = NSLocalizedString("Dangerous actions", comment: "")

    // // Group profile
    static let editProfile = NSLocalizedString("Edit group details", comment: "")
    static let addWelcome = NSLocalizedString("Add welcome message", comment: "")
    static let welcome = NSLocalizedString("Welcome message", comment: "")
    static let preferences = NSLocalizedString("Group preferences", comment: "")
    static let preferencesSaved = NSLocalizedString("Group preferences saved", comment: "")
    static let preferencesFailed = NSLocalizedString("Saving failed, please try again later", comment: "")
    static let createLink = NSLocalizedString("Create group link", comment: "")
    static let groupLink = NSLocalizedString("Group link", comment: "")
    static let linkAbsent = NSLocalizedString("Not created", comment: "")
    static let linkPresent = NSLocalizedString("Created", comment: "")

    // // Channel subscription threshold
    static let sectionSubscription = NSLocalizedString("Channel subscription", comment: "")
    static let memberFootnote = NSLocalizedString("Subscribing happens on the gate card in the channel: the channel owner publishes the price, this device has no say in it.", comment: "")
    static let publishThreshold = NSLocalizedString("Publish subscription gate", comment: "")
    static let subscriptionState = NSLocalizedString("Subscription ticket", comment: "")
    static let subscriptionValidFormat = NSLocalizedString("Valid until %@", comment: "")

    // // Messages
    static let retentionFootnote = NSLocalizedString("Sets when messages are deleted automatically on this device.", comment: "")
    static let receipts = NSLocalizedString("Read receipts", comment: "")
    static let receiptsYes = NSLocalizedString("Send", comment: "")
    static let receiptsNo = NSLocalizedString("Do not send", comment: "")
    static let receiptsDefault = NSLocalizedString("Follow default", comment: "")
    static let receiptsDisabled = NSLocalizedString("Turned off because this group has many members", comment: "")

    // // Members
    static let inviteMembers = NSLocalizedString("Invite members", comment: "")
    static let searchMembers = NSLocalizedString("Search members", comment: "")
    static let youPrefix = NSLocalizedString("You:", comment: "")
    static let youStatus = NSLocalizedString("This device", comment: "")

    static let roleOwner = NSLocalizedString("Owner", comment: "")
    static let roleAdmin = NSLocalizedString("Admin", comment: "")
    static let roleModerator = NSLocalizedString("Moderator", comment: "")
    static let roleMember = NSLocalizedString("Member", comment: "")
    static let roleObserver = NSLocalizedString("Read-only", comment: "")
    static let roleAuthor = NSLocalizedString("Author", comment: "")
    static let roleRelay = NSLocalizedString("Relay", comment: "")

    static let statusBlockedAdmin = NSLocalizedString("Blocked by an admin", comment: "")
    static let statusBlockedMe = NSLocalizedString("Blocked for you", comment: "")
    static let statusPending = NSLocalizedString("Waiting to join", comment: "")
    static let statusNotJoined = NSLocalizedString("Not joined yet", comment: "")

    // // Member actions
    static let blockMember = NSLocalizedString("Block this member", comment: "")
    static let unblockMember = NSLocalizedString("Unblock", comment: "")
    static let blockForAll = NSLocalizedString("Block for everyone", comment: "")
    static let unblockForAll = NSLocalizedString("Unblock for everyone", comment: "")
    static let removeMember = NSLocalizedString("Remove from group", comment: "")
    static let memberBlocked = NSLocalizedString("Member blocked", comment: "")
    static let memberUnblocked = NSLocalizedString("Member unblocked", comment: "")
    static let memberBlockedForAll = NSLocalizedString("Member blocked for everyone", comment: "")
    static let memberUnblockedForAll = NSLocalizedString("Member unblocked for everyone", comment: "")

    // // Removal confirmation
    static let removeTitle = NSLocalizedString("Remove member?", comment: "")
    static let removeWithMessages = NSLocalizedString("Remove and delete messages", comment: "")
    static let removeOnly = NSLocalizedString("Remove only", comment: "")
    static let removeMessageFormat = NSLocalizedString("%@ will be removed from this group; this cannot be undone.", comment: "")

    // // Dangerous actions
    static let clearChat = NSLocalizedString("Clear conversation", comment: "")
    static let leaveGroup = NSLocalizedString("Leave group", comment: "")
    static let deleteGroup = NSLocalizedString("Delete group", comment: "")
    static let dangerFootnote = NSLocalizedString("Every action below asks you to confirm once first.", comment: "")

    static let deleteConfirmTitle = NSLocalizedString("Delete group?", comment: "")
    static let deleteConfirmMessage = NSLocalizedString("The group is deleted for every member; this cannot be undone.", comment: "")
    static let delete = NSLocalizedString("Delete", comment: "")
    static let deleteFailed = NSLocalizedString("Delete failed, please try again later", comment: "")

    static let clearConfirmTitle = NSLocalizedString("Clear conversation?", comment: "")
    static let clearConfirmMessage = NSLocalizedString("All messages are deleted from this device; this cannot be undone and affects only you.", comment: "")
    static let clear = NSLocalizedString("Clear", comment: "")

    static let leaveConfirmTitle = NSLocalizedString("Leave group?", comment: "")
    static let leaveConfirmMessage = NSLocalizedString("You will no longer receive this group's messages; the chat history is kept.", comment: "")
    static let leave = NSLocalizedString("Leave", comment: "")

    static let blockConfirmTitleFormat = NSLocalizedString("Block %@?", comment: "")
    static let unblockConfirmTitleFormat = NSLocalizedString("Unblock %@?", comment: "")
    static let blockConfirmMessage = NSLocalizedString("This person's new messages will be hidden.", comment: "")
    static let unblockConfirmMessage = NSLocalizedString("This person's messages will be shown again.", comment: "")
    static let block = NSLocalizedString("Block", comment: "")
    static let unblock = NSLocalizedString("Unblock", comment: "")
}

// MARK: - Previews

#if DEBUG
struct PopopxGroupChatInfoView_Previews: PreviewProvider {
    static var previews: some View {
        PopopxGroupChatInfoView(
            chat: Chat(chatInfo: ChatInfo.sampleData.group, chatItems: []),
            groupInfo: Binding.constant(GroupInfo.sampleData),
            scrollToItemId: Binding.constant(nil),
            composeState: Binding.constant(ComposeState()),
            onSearch: {},
            localAlias: ""
        )
        .environmentObject(ChatModel.shared)
    }
}
#endif
