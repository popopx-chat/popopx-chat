//
//  PopopxGroupChatInfoView.swift
//  POPOPX (iOS)
//
//  【重设计】群聊信息页。顶部一张群卡（共享头像、群名、全称、成员数），下面分组的卡片：
//  群资料 / 消息 / 成员 / 危险操作。输入接口与旧的 `Shared/Views/Chat/Group/GroupChatInfoView.swift`
//  完全一致（同样的属性、同样的参数标签与顺序），所以之后只需在 ChatView.swift 里把类型名改一个词即可挂载。
//
//  三条设计决定：
//  1. 只保留"群"这条路径的真实动作。旧页里属于频道/relay（useRelays）、成员支持、举报、
//     businessChat 的分支一律不带过来（清单见交付报告，都标了旧行号）。
//  2. 每一行推的都是真实存在、逐个核对过 init 的页面；破坏性动作都有真实确认步骤，
//     没有占位按钮、没有用注释代替代码。
//  3. 配色、字号、圆角、间距只取 Shared/Theme/PopopxTheme.swift 的 token；控件只用
//     Shared/Components 里已有的原子库。文案是硬编码简体中文，集中在文件末尾的 `Copy`。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖进 POPOPX (iOS) target —— 铁律禁止脚本改 project.pbxproj。
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

    /// 群链接；nil = 尚未创建。onAppear 经 `apiGetGroupLink` 读真实状态。
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

    /// 与旧页同一口径：活跃成员超过这个数就不再发已读回执。
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

    // MARK: 成员

    /// 活跃成员（未离开、未被移出），按角色从高到低。口径同旧页 :74-76。
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

    // MARK: 顶部群卡

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

    // MARK: 群备注名

    private var renameCard: some View {
        PopopxSectionCard(Copy.renameGroup, footnote: Copy.renameFootnote) {
            PopopxTextField(Copy.renameField, prompt: Copy.renameField, text: $localAlias, systemImage: "pencil") { _ in
                setGroupAlias()
            }
        }
    }

    // MARK: 群资料

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

    // MARK: 频道订阅门槛

    /// 只有频道画这一格（判据 `GroupInfo.isChannel` = `publicGroup?.groupType == .channel`，
    /// ChatTypes.swift:3064、:3233）。私人群不给：订阅这个语义需要一个"定价的人"，而群里的成员彼此都是主人。
    ///
    /// 频道主这一支推的是真正的发布页，**管理员也能进**（判据与 `sendChannelAccess` 的守卫同一份：
    /// `popopxCanPublishChannelThreshold`）；成员这一支只读，显示本机那张凭证。
    /// 成员**不在这里**订阅或续订，原因是价格不在本机：门槛只有频道里那条卡片带着，
    /// 在这一页凭空摆一个数字，扣的就是没人宣布过的钱。所以文案把入口指回那条卡片。
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

    /// 成员侧那一格右边的数：有效期，或 nil = 本机没有这张凭证。
    /// 键用 `GroupInfo.id`，与卡片签凭证时用的 `ChatInfo.id` 同一个串（`ChatInfo` 的 group 那一档
    /// 就是转发给 `groupInfo.id`），所以"在频道里订阅"与"在这一页看到状态"必然指向同一张票。
    private var memberTicketValue: String? {
        guard let ticket = PopopxCreditsManager.shared.ticket(forChannelId: groupInfo.id) else { return nil }
        return String(format: Copy.subscriptionValidFormat, PopopxCommerceFormat.date(ticket.expiresAtMs))
    }

    // MARK: 消息

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

    // MARK: 成员

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

    /// 自己这一行：不导航、不显示操作菜单，只有角色。
    private var selfMemberRow: some View {
        let member = groupInfo.membership
        return HStack(spacing: PopopxMetrics.spaceS) {
            MemberProfileImage(member, size: PopopxMetrics.space2XL)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text("\(Copy.youPrefix)\(member.chatViewName)")
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

    // MARK: 危险操作

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

    /// 与旧页 :249-250 同口径：群主且群里没有别的 owner 时不给退出。
    private var leaveAllowed: Bool {
        !groupInfo.isOwner
            || members.contains { $0.wrapped.memberRole == .owner && $0.wrapped.groupMemberId != groupInfo.membership.groupMemberId }
    }

    // MARK: 行为

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

    // MARK: 文本派生

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

// MARK: - 确认状态

/// 一个待确认的动作。破坏性的（删除/清空/移出/屏蔽）都经它走真实的确认弹窗。
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

// MARK: - 局部组件

/// 卡片内的分隔线。名字唯一，避开与并行文件里同名 helper 的冲突。
private struct PopopxGroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

/// 头部两个轻操作：搜索、静音。整颗是 Button，44pt 命中区。
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

/// 推进一个既有页面的行。行本体设为不可命中，由外层 NavigationLink 接管点击（同 PopopxMeView 的写法）。
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

/// 成员角色 chip。owner/admin 用 brand 强调，其余用中性底色 —— 不用 mesh，免得伪造一条传输通道。
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

/// Menu 顶部的角色说明（菜单项里放一个非按钮的文本行）。
private struct PopopxGroupRoleChipHeader: View {
    private let text: String
    init(text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text)
    }
}

/// 已屏蔽的小圆点，叠在角色 chip 右上角。
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

/// 危险行。文字与图标都用 dangerInk，点击后由调用方弹真实确认。
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

// MARK: - 文案

/// 页面上每一句中文只在这里出现一次。
private enum Copy {
    static let pageTitle = "群信息"
    static let cancel = "取消"
    static let linkHint = "打开"

    // 顶部群卡
    static let memberCountFormat = "%d 位成员"
    static let search = "搜索"
    static let muteToggle = "静音"

    // 备注名
    static let renameGroup = "群备注名"
    static let renameField = "设置群备注名"
    static let renameFootnote = "备注名只保存在你这台设备上，不会通知其它成员。"
    static let renamed = "群备注名已更新"
    static let renameFailed = "改名失败，请稍后再试"

    // 分组标题
    static let sectionGroup = "群资料"
    static func sectionMembers(_ suffix: String) -> String { "成员\(suffix)" }
    static let memberCountSuffixFormat = "（%d）"
    static let sectionMessage = "消息"
    static let sectionDanger = "危险操作"

    // 群资料
    static let editProfile = "编辑群资料"
    static let addWelcome = "添加欢迎消息"
    static let welcome = "欢迎消息"
    static let preferences = "群偏好设置"
    static let preferencesSaved = "群偏好已保存"
    static let preferencesFailed = "保存失败，请稍后再试"
    static let createLink = "创建群链接"
    static let groupLink = "群链接"
    static let linkAbsent = "未创建"
    static let linkPresent = "已创建"

    // 频道订阅门槛
    static let sectionSubscription = "频道订阅"
    static let memberFootnote = "订阅在频道里那条门槛卡片上完成：价格由频道主发布，本机没有定价权。"
    static let publishThreshold = "发布订阅门槛"
    static let subscriptionState = "订阅凭证"
    static let subscriptionValidFormat = "有效至 %@"

    // 消息
    static let retentionFootnote = "设置消息在这台设备上自动删除的时间。"
    static let receipts = "已读回执"
    static let receiptsYes = "发送"
    static let receiptsNo = "不发送"
    static let receiptsDefault = "跟随默认"
    static let receiptsDisabled = "成员较多，已关闭"

    // 成员
    static let inviteMembers = "邀请成员"
    static let searchMembers = "搜索成员"
    static let youPrefix = "你："
    static let youStatus = "此设备"

    static let roleOwner = "群主"
    static let roleAdmin = "管理员"
    static let roleModerator = "协管员"
    static let roleMember = "成员"
    static let roleObserver = "只读"
    static let roleAuthor = "作者"
    static let roleRelay = "中继"

    static let statusBlockedAdmin = "已被管理员屏蔽"
    static let statusBlockedMe = "已对你屏蔽"
    static let statusPending = "等待加入"
    static let statusNotJoined = "尚未加入"

    // 成员操作
    static let blockMember = "屏蔽此人"
    static let unblockMember = "取消屏蔽"
    static let blockForAll = "对所有人屏蔽"
    static let unblockForAll = "对所有人取消屏蔽"
    static let removeMember = "移出群聊"
    static let memberBlocked = "已屏蔽该成员"
    static let memberUnblocked = "已取消屏蔽"
    static let memberBlockedForAll = "已对所有人屏蔽该成员"
    static let memberUnblockedForAll = "已对所有人取消屏蔽"

    // 移出确认
    static let removeTitle = "移出成员？"
    static let removeWithMessages = "移出并删除消息"
    static let removeOnly = "仅移出"
    static let removeMessageFormat = "%@ 将被移出群聊，此操作无法撤销。"

    // 危险操作
    static let clearChat = "清空对话"
    static let leaveGroup = "退出群聊"
    static let deleteGroup = "删除群聊"
    static let dangerFootnote = "以下操作都会先让你确认一次。"

    static let deleteConfirmTitle = "删除群聊？"
    static let deleteConfirmMessage = "群聊将为所有成员删除，此操作无法撤销。"
    static let delete = "删除"
    static let deleteFailed = "删除失败，请稍后再试"

    static let clearConfirmTitle = "清空对话？"
    static let clearConfirmMessage = "所有消息将从你这台设备删除，此操作无法撤销，且只影响你自己。"
    static let clear = "清空"

    static let leaveConfirmTitle = "退出群聊？"
    static let leaveConfirmMessage = "你将不再收到这个群的消息，聊天历史会保留。"
    static let leave = "退出"

    static let blockConfirmTitleFormat = "屏蔽 %@？"
    static let unblockConfirmTitleFormat = "取消屏蔽 %@？"
    static let blockConfirmMessage = "此人的新消息将被隐藏。"
    static let unblockConfirmMessage = "此人的消息将重新显示。"
    static let block = "屏蔽"
    static let unblock = "取消屏蔽"
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
