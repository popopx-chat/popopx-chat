//
//  PopopxContactsView.swift
//  POPOPX (iOS)
//
//  【第四阶段】Tab 2「通讯录」：顶部四张常驻（pinned）功能卡 —— 新的加密连接 / 我的加密群组 /
//  我关注的频道 / 按匿名身份分组 —— 下面是带 `.searchable`、右侧 A–Z 索引与 8pt 圆角头像的现代联系人列表。
//
//  数据来源（本工程没有 `ChatModel.contacts`，也没有 `ChatModel.invitations`，全部从会话列表派生）：
//  · 联系人 = `ChatModel.chats`（Shared/Model/ChatModel.swift:408）里 `.direct` 且
//    `contact.active` 的会话，排除规则照抄 ChatListView.swift:661 的
//    `!chat.chatInfo.chatDeleted && !chat.chatInfo.contactCard`；
//  · 群组 = `.group` 且 `businessChat == nil && !isChannel`（照抄 ChatListView.swift:1244 的 .groups 口径）；
//  · 频道 = `.group` 且 `ChatInfo.isChannel`（= `groupInfo?.useRelays == true`，POPOPXChat/ChatTypes.swift:2296）
//    且 `membership.memberCurrent`：群组那条口径按定义把频道排除在外，所以频道要自己的一页，
//    判据只写在 `isPopopxChannel(_:)` 一处（置顶那行的数字与页面里的行共用它）。
//  · 加密连接请求 = `chatType == .contactRequest`（ChatListView.swift:675），答复走
//    `acceptContactRequest` / `rejectContactRequest`（Shared/Model/POPOPXAPI.swift:1551 / :1574）；
//  · 厢语待确认配对 = `PopopxMeshRuntime.shared.bannerModel.requests`（PopopxMeshUI 里
//    `PopopxMeshBannerModel` 每 2 秒从 `ManualPairingManager.pendingRequests()` 读一次真值）。
//
//  两个角标怎么算（互不串口径，且永远不同时出现在同一色行里）：
//  · 靛紫实心徽章 = 未答复的在线加密连接请求条数（`contactRequestChats.count`）。它是「未读」而不是
//    消息数：本卡对应的页面就是这些请求，请求答复完角标就归零，没有第二套计数。§1.4 第 4 条禁止绿色
//    承载常驻状态，所以用 `brand`。
//  · 青绿描边徽章 = `bannerModel.requests.count`，且只在 `PopopxMeshRuntime.isFuseOn` 为真时才参与计算
//    —— 熔断关掉时 `bannerModel.stop()` 只清横幅不清队列镜像，读到的会是上一次开机的旧数字。
//    两个数字各说一条通道，因此按 §1.1 末句「需要同时展示两种通道时，用两个独立徽章」拆成两枚，
//    青绿那枚按 §2.2 永远带数字（`mesh` 实底在白卡上只有 2.98，不足以独立承载信息，故描边用 `meshInk`）。
//    刷新只有一条路径：`.task` 里在熔断为开时 `await bannerModel.refresh()` 立刻读一次真值，此后由
//    该模型自己的 2 秒轮询驱动（`@Published requests` → `@ObservedObject` → 本视图重算），
//    本文件不自建定时器，也不调用 `start()`/`stop()`（那两个方法归 `PopopxMeshKillSwitch` 管）。
//
//  索引降级说明（本工程中文显示名是常态，所以这里不做「只支持拉丁字母」的假索引）：
//  A–Z 取的是名字首个拉丁字母的大写，而中文先经 Foundation 的 `StringTransform.toLatin` 转成拼音、
//  再用 `stripDiacritics` 去掉声调，「张三」因此落在 Z、「艾明」落在 A —— 这是系统自带的转写，
//  不是内置拼音表。转写拿不到的字符（数字、标点、emoji、阿拉伯文/泰文等不转写的文字）全部落到
//  明确标为「#」的一节，永不丢弃；转写返回 nil 时退回原始首字符再判一次。
//
//  无障碍：行与卡是真正的控件，一律 ≥ `PopopxMetrics.minHitTarget`(44pt)；右侧 A–Z 索引是系统通讯录
//  同款的密集快捷条（27 个 44pt 段放不进一屏），因此它自己 `accessibilityHidden`，同一能力由导航栏
//  「按字母跳转」菜单以标准 44pt 菜单项提供；两枚角标各自带中文 `accessibilityLabel`。
//  Reduce Motion 走 `PopopxMotion`：开滚段/换组时弹簧直接换成瞬时值变化。
//
//  守的红线：不碰 project.pbxproj（本文件由人手工拖进 target）；颜色/间距/字号/材质/弹簧只取
//  PopopxTheme 的 token；控件优先复用 Shared/Components 的原子库，只有原子库形状不够时才用
//  token 现拼（下面 `PopopxFunctionRowLabel` 之所以不是 `PopopxPickerRow`：栈路径由第四阶段的
//  MainTabView 持有，卡片必须是 `NavigationLink(value:)`，而 `PopopxPickerRow` 只接受 action 闭包）；
//  界面中文只在文件末尾的 `Copy` 里出现一次；没有 TODO，没有假数据。
//
//  ⚠️ 交给 MainTabView 的一处集成点：会话页由 `ChatModel.chatId` 驱动（旧 ChatListView.swift:210-217
//  用 `NavigationStack(path:)` 映射它），本文件按既有约定调 `ItemsModel.shared.loadOpenChat(_:)`
//  打开会话；四栏壳的 `selection` 是私有 @State，通讯录这一栏无法把用户带到「消息」栏去。
//  需要 MainTabView 补 `.onChange(of: chatModel.chatId) { _, id in if id != nil { selection = .chats } }`
//  （或把 selection 暴露成 Binding），否则从通讯录点开会话只会在切到消息栏后才出现。
//

import Foundation
import SwiftUI
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - A–Z 分桶

/// 名字 → 索引键。唯一的一处「拼音/首字母」判定，列表分组与右侧索引条共用，二者不可能各说各话。
private enum PopopxContactIndex {
    /// 非拉丁可转写名字的落点，界面上直接以这个字符为节标题。
    static let other = "#"

    static func key(forName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return other }
        // 转写失败（返回 nil）时退回原串，保证「判不出来」只会落到 #，不会漏掉一条联系人。
        let transliterated = trimmed
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? trimmed
        let source = transliterated.isEmpty ? trimmed : transliterated
        // 只看首字符：数字/标点/emoji/不被转写的文字一律进 “#”，不会被「跳过几个字符找字母」误纳。
        guard let first = source.first else { return other }
        let upper = String(first).uppercased()
        guard upper.count == 1, let scalar = upper.unicodeScalars.first,
              scalar.value >= 65, scalar.value <= 90 else { return other }
        return upper
    }
}

// MARK: - 路由与分组状态

private enum PopopxContactsRoute: Hashable {
    case newConnections
    case groups
    case channels
    /// 「加入频道」：落在既有的扫描／粘贴链接页（同一页在「消息」栏右上角的 + 里也已挂载，
    /// `ChatsListView.swift:270-275`）。频道链接走的仍是 app 原有的 `planAndConnect` →
    /// `apiConnectPlan` → `.groupLink` 那一条真路径（`NewChatView.swift:1320`、`:1522`）。
    case joinChannel
}

/// 「按匿名身份分组」的实际口径：会话自己是匿名连接（`ChatInfo.incognito`）还是主身份直连。
/// 这是本工程唯一真实存在的「身份 ↔ 联系人」数据：`ChatData` 上没有 userId 字段
/// （POPOPXChat/ChatTypes.swift:2539），跨身份的联系人名下只能靠 `chatModel.users` 的未读数呈现。
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

    /// 熔断真值在 runtime（Shared/Model/POPOPXAPI.swift:3640），配对队列在 bannerModel。
    /// 两者都是进程级单例，和 Phase 3 一样在 `@MainActor init()` 里装进 `@ObservedObject`。
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
        // `ScrollViewReader` 包在最外层：右侧密集索引条和导航栏的「按字母跳转」菜单共用同一个 proxy
        // 与同一份 keys，两条入口的跳转行为因此不可能不一致。
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
                // 密集索引条（每段 ~16pt，27 段放不进 44pt 的要求）的无障碍等价物：
                // 同一份 keys，系统菜单自带 44pt 命中区。
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
                case .joinChannel:
                    // 与「消息」栏 + 菜单里「扫一扫」同一页、同一挂载写法（`ChatsListView.swift:270-275`），
                    // 差别只在标题：这一枚的来意是"用链接或二维码加入一个频道"，标题要说清两件事。
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
                                // 旧通讯录同一手（Shared/Views/Contacts/ContactListNavLink.swift:56）：
                                // 先收起整屏弹层，再把要开的会话交给既有的换栏入口。
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

    /// 置顶的四张功能卡 + 当前分组状态。作为 pinned section header 常驻，列表从它下面滚过。
    private var pinnedFunctions: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            PopopxSectionCard {
                // 卡 1：新的加密连接。两枚独立徽章 = 两条通道（§1.1 末句、§2.2）。
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

                // 卡 2：我的加密群组。
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

                // 卡 3：我关注的频道。频道在本工程就是"用中继转发的公开群组"
                // （`ChatInfo.isChannel` = `groupInfo?.useRelays == true`，POPOPXChat/ChatTypes.swift:2296），
                // 上一条 `contactChats` 的口径把它排除在通讯录与群组页之外，所以它需要自己的一行。
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

                // 卡 4：按匿名身份分组 —— 弹层，所以能用 action 闭包的原子控件。
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

    // MARK: 计数与筛选

    private var searching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

    /// 加密连接请求：`.contactRequest` 会话。排除规则与主列表同源，避免已删/名片会话混进角标。
    private var contactRequestChats: [Chat] {
        chatModel.chats.filter { chat in
            !chat.chatInfo.chatDeleted
                && !chat.chatInfo.contactCard
                && chat.chatInfo.chatType == .contactRequest
        }
    }

    private var contactRequestCount: Int { contactRequestChats.count }

    /// 厢语待确认配对。熔断关闭时一律算 0：见文件头「两个角标怎么算」。
    private var meshPendingCount: Int { meshRuntime.isFuseOn ? meshBanner.requests.count : 0 }

    /// 联系人 + 加密群组的统一口径（通讯录的主列表）。
    private var contactChats: [Chat] {
        chatModel.chats.filter { chat in
            guard !chat.chatInfo.chatDeleted, !chat.chatInfo.contactCard else { return false }
            switch chat.chatInfo {
            case let .direct(contact):
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

    /// 频道：判据与下面的频道页共用同一个 `isPopopxChannel`，两处不可能各说各话。
    private var channelChats: [Chat] {
        chatModel.chats.filter(isPopopxChannel)
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

    /// 搜索命中口径照抄 ChatListView.swift:663-672：视图名 / 昵称 / 全名，大小写不敏感。
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

    // MARK: 文案用的读数

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

    private var identityValue: String {
        Copy.identitiesValue(visibleIdentities.count)
    }

    /// 隐藏身份需要查看口令才能切换（`User.hidden` = `viewPwdHash != nil`），本页不收口令，
    /// 所以按 `UserPicker` 的既有做法把它们排除在列表外，并在弹层里写明原因。
    private var visibleIdentities: [UserInfo] {
        chatModel.users.filter { !$0.user.hidden }
    }

    private var accessibilityBadges: String {
        var parts: [String] = []
        if contactRequestCount > 0 { parts.append(Copy.badgeOnlineA11y(contactRequestCount)) }
        if meshPendingCount > 0 { parts.append(Copy.badgeMeshA11y(meshPendingCount)) }
        return parts.joined(separator: Copy.badgeSeparator)
    }

    /// 头像随 Dynamic Type 放大，`radiusAvatar` 恒为 8pt（本次规格点名的圆角）。
    private var avatarSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? PopopxMetrics.space2XL
            : PopopxMetrics.minHitTarget
    }

    // MARK: 行为

    private func scroll(to key: String, in proxy: ScrollViewProxy) {
        PopopxHaptics.selection()
        PopopxMotion.withAnimation(PopopxSpring.fluid, reduceMotion: reduceMotion) {
            proxy.scrollTo(key, anchor: .top)
        }
    }

    /// 只读一次真值；之后的更新由 `PopopxMeshBannerModel` 自己的 2 秒轮询负责（见文件头）。
    @MainActor private func refreshMeshPending() async {
        guard meshRuntime.isFuseOn else { return }
        await meshBanner.refresh()
    }
}

private struct PopopxContactSection {
    let key: String
    let chats: [Chat]
}

// MARK: - 置顶功能卡的一行

/// 与 `PopopxPickerRow` 同尺寸（32pt 方形图标徽章 + 标题 + 尾部 + `chevron.right`），
/// 但尾部换成调用方的徽章，并且整行是 `NavigationLink` 的 label。
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

// MARK: - 两枚通道徽章

/// 在线加密（SMP）：`brand` 实底 + `onBrand`，永远带数字。
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

/// 离线厢语：`card` 底 + `meshInk` 描边与文字（§1.4 第 3 条：青绿实底不足 3.0，颜色不独立承载信息）。
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

// MARK: - 联系人行

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

                    // 匿名连接是「这条关系挂在哪个身份上」的事实，用中性色标注，
                    // 不与 brand（未读）或 mesh（青绿专属通道）争色。
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

    /// 未读口径直接复用 `ChatStats`（既有字段），显示文本复用 `unreadCountText`（ChatPreviewView.swift:554），
    /// 颜色按 §1.4 第 4 条取 `brand`，不用绿色。
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

/// 8pt 圆角头像。本工程头像是 base64 串而不是文件，所以只能走既有的 `ProfileImage`；
/// 它内部按用户自己的 `DEFAULT_PROFILE_IMAGE_CORNER_RADIUS` 偏好裁剪，本层再套一个 `radiusAvatar`
/// 的方形容器：偏好更圆时容器不起作用（圆的图裁不出角），偏好更方时统一收到 8pt。
/// 仓库里没有「身份 → 颜色」的助手函数（colorForProfile/identityColor/profileColor 全 0 命中），
/// 而 §1.1 规定颜色只承载通道语义，因此这里刻意不做「每人一色」，占位图标一律 `brand`（在线 SMP 列表）。
private struct PopopxAvatar: View {
    let chat: Chat
    let size: CGFloat
    var tint: Color = PopopxPalette.brand
    /// 没有自定义头像时用哪个符号。默认 `nil` = 保持原样的人像符号；频道页传 `chatIconName`
    /// （公共频道是天线条，`POPOPXChat/ChatTypes.swift:3091`），这样头像位说的就是会话自己的类型。
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

// MARK: - 右侧 A–Z 索引

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
        // 密集快捷条不满足 44pt，因此对辅助技术隐藏，同一能力由导航栏的「按字母跳转」菜单承担。
        .accessibilityHidden(true)
    }
}

// MARK: - 通知条 / 空态

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

// MARK: - 新的加密连接页

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

    /// 正在建立中的连接。它们的名字来自核心（`PendingContactConnection.displayName` 是本地化英文
    /// 短语），本页不翻译它们，因此只以本机可说的状态呈现，且不可点开（会话还没成立）。
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

/// 一条在线加密连接请求：三个动作都走既有 API，按钮形状用原子库的自适应网格。
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

    /// `acceptContactRequest` 自带 `inProgress` 绑定（POPOPXAPI.swift:1551），成功后
    /// `ChatModel` 会把这条请求换成联系人会话，本行随列表消失。
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

/// 一条厢语待确认配对。这里的每一处颜色都是青绿家族，且不出现 `brand` —— 一行只说一条通道。
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
                    // `mesh` 实底只能配 `onMesh`（亮青底放白字/深青字都读不出，见 PopopxTheme.swift:83）。
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
            // 模块 3 是类型化抛出（`throws(PopopxPairingError)`）；失败绝不静默。
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

// MARK: - 我的加密群组页

private struct PopopxGroupsPage: View {
    @EnvironmentObject private var chatModel: ChatModel

    /// 右上角「创建加密群组」的去处：与「消息」栏右上角那条同一个页面、同一个目的地
    /// （`ChatsListView` 的 `showsCreateGroup`），挂载方式照抄 `NewChatMenuButton.swift:89-93`。
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
        // 真机反馈：这一页只有"已有群组"，一个建群的入口都没有，要退回上一级去「消息」栏的 + 里找。
        // 空态那一行原本也是这么说的（`groupsEmptyNote`），所以这一枚把那条路搬到眼前，
        // 空态文案随之改成不再指路的说法。
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
            // 「我创建的」用模型自己的谓词，不在此重算角色规则（POPOPXChat/ChatTypes.swift:3075）。
            return Row(chat: chat, isOwner: groupInfo.isOwner)
        }
    }

    private var owned: [Row] { groups.filter(\.isOwner) }
    private var joined: [Row] { groups.filter { !$0.isOwner } }
}

// MARK: - 我关注的频道页

/// 频道判据只写一处：置顶那行的数字和这一页的行必须说同一件事，否则角标会和列表打脸。
private func isPopopxChannel(_ chat: Chat) -> Bool {
    guard !chat.chatInfo.chatDeleted, !chat.chatInfo.contactCard else { return false }
    guard let groupInfo = chat.chatInfo.groupInfo else { return false }
    // `ChatInfo.isChannel` = `groupInfo?.useRelays == true`（POPOPXChat/ChatTypes.swift:2296）；
    // `memberCurrent` 与上面群组页 `groups` 同一条口径：已经退出的不再算"关注的频道"。
    return chat.chatInfo.isChannel && groupInfo.membership.memberCurrent
}

@MainActor private struct PopopxChannelsPage: View {
    @EnvironmentObject private var chatModel: ChatModel

    /// 预览开关与「消息」栏那一格是同一格（`ChatsListView.swift:146`）：用户关掉消息预览是为了
    /// "不在列表里读内容"，这一页不能绕过它自己去读一条，所以关掉时整行不给活动那一行。
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
        // 加入频道的真路径只有一条：频道链接／二维码 → `planAndConnect` → `apiConnectPlan` →
        // `.groupLink` → `apiConnect`（`NewChatView.swift:1320`、`:1522`）。这一枚把那条已有的
        // 扫描／粘贴页接到这里，不新造任何订阅机制。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: PopopxContactsRoute.joinChannel) {
                    Label(Copy.joinChannelEntry, systemImage: "qrcode.viewfinder")
                }
            }
        }
    }

    /// 顺序沿用 `chatModel.chats` 本身，与「消息」栏同一口径（`ChatsListView.swift:418` 也没另起一套排序）。
    private var channels: [Chat] { chatModel.chats.filter(isPopopxChannel) }
}

/// 一行频道：天线符号（身份）+ 名称 + 最新活动时间 + 未读，点开走群组页那同一条 `loadOpenChat`。
/// `@MainActor` + `@ObservedObject`：未读与"最新一条"都是 `Chat` 自己的 `@Published`，
/// 不观察就只有整页重算时才动（同 `ChatsListView.swift` 的 `PopopxChatRow`）。
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
                        // 频道的身份符号：没有自定义头像时天线已经在头像位上，有自定义头像时
                        // 由这一枚说"这是一路单向广播，不是群聊"（符号取自 ChatTypes.swift:5747）。
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

    /// 关掉预览时返回 nil（整行不写那一行），而不是编一句"内容已隐藏"占位；
    /// 撤回／过滤过的条目由 `ChatItem.text` 自己给出既有的本地化说法。
    private var activity: String? {
        guard showsPreview else { return nil }
        guard let item = chat.chatItems.last else { return Copy.channelNoActivity }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Copy.channelNoActivity : text
    }

    /// 未读口径与 `PopopxContactRow` 同一处：`ChatStats.unreadCount`，没有数字时也算一条未读。
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

// MARK: - 按匿名身份分组弹层

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

    /// 未读口径照抄 `ChatModel.totalUnreadCountForAllUsers()`（Shared/Model/ChatModel.swift:1187）：
    /// 当前身份从自己的会话累加（并按各会话的通知设置只数未读或未提及），其它身份读核心维护的
    /// `UserInfo.unreadCount`（旧身份选择器同一口径，Shared/Views/ChatList/UserPicker.swift:181）。
    /// 这里不另起一套计数，否则弹层里的数字和角标/图标徽标会互相打脸。
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

/// 页面上每一句中文只在这里出现一次。
private enum Copy {
    /// 本轮（真机第 3 轮）新增的两句话走「英文原句即 Key」：`en.lproj` 按约定不写，
    /// 读不到词条就回落 Key 本身，那就是英文。其余成员仍是 Phase 4 的中文直写，本轮不动。
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX contacts groups")
    }

    /// 带数字的句子一律只给一个占位符（`%d`），16 种语序不同不能靠位置排多个参数
    /// （口径同 `PopopxTelemetryCopy.fmt`）。
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

    // 新的加密连接页
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

    // 群组页
    static let groupsOwnedTitle = key("Groups you created")
    static let groupsJoinedTitle = key("Groups you joined")
    static let groupsSectionFootnote = key("Channels and shop groups are not part of Contacts; they appear only in their own lists.")
    static func memberCount(_ count: Int64) -> String { fmt("%lld members", count) }
    static let groupsEmptyTitle = key("No encrypted groups yet")
    /// 这一句原来指路到「消息」栏右上角的 + ；这一页自己长出创建入口后那句话就成了假路，
    /// 所以随本轮改词，并借这次改词转成 Key（英文系统下原来会露出中文）。
    static let groupsEmptyNote = key("Start one with the plus button in the top right corner.")
    static let groupsNoneTitle = key("None yet")
    static let groupsNoneNote = key("No groups in this category yet.")

    // 频道页（本轮新增：置顶那一行 + 「我关注的频道」页 + 「加入频道」）
    static let channelsTitle = key("Subscribed channels")
    static let channelsNoteEmpty = key("No channels yet")
    static func channelsNote(_ count: Int) -> String { fmt("%d channels you follow", count) }
    static let channelsEmptyNote = key("Use Join channel in the top right corner to open a channel from a link or a QR code, or create a public channel with the plus button on the Messages tab.")
    static let channelNoActivity = key("No messages in this channel yet")
    /// 复用既有词条：`"Join channel"`（zh-Hans:3710「加入频道」）与 `"Paste link / Scan"`
    /// （zh-Hans:4785「粘贴链接 / 扫描」）都已经在目录里 —— 各有 7 个目录（de/es/fr/hu/it/ru/zh-Hans），
    /// 其余目录回落英文原句。上面六句新造的还哪本目录都没有，等集中补译。
    static let joinChannelEntry = key("Join channel")
    static let joinChannelPageTitle = key("Paste link / Scan")

    // 身份弹层
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
