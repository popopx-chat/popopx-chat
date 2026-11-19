//
//  ChatsListView.swift
//  POPOPX (iOS)
//
//  【第四阶段 · Tab 1 消息】新版会话列表。
//
//  三段结构：顶部嵌第三阶段的 `PopopxTelemetryHeader`（身份切换 / 双模状态 / 「+」菜单），
//  中间是 全部 · 在线加密 · 厢语离线 三枚胶囊过滤器，下面是每张卡片一行的会话列表。
//
//  栈的归属（这里按**已落地的** `Shared/Navigation/MainTabView.swift` 来，而不是按任务书的假设）：
//  MainTabView.swift:14-20 与 :76-79 明确决定"消息这一栏自己带 NavigationStack，其余三栏才由壳包"。
//  理由是本工程把"打开会话"翻成"推送一页"的唯一一处，是 `ChatModel.chatId`
//  （Shared/Model/ChatModel.swift:411）到栈路径的绑定（旧 ChatListView.swift:204-211）；
//  而 `chatId` 的写入口是 `ItemsModel.loadOpenChat`（:113）/`loadOpenChatNoWait`（:139），
//  调用方包括通知（Shared/Model/NtfManager.swift:81）、deep link／建连（Shared/Model/POPOPXAPI.swift:1091
//  /:1825/:2182/:2849）、附件打开（ChatModel.swift:1303）与新建联系人。绑定一旦挪到壳里，
//  通知点开会话就静默失效 —— 所以本页自己建栈，`.searchable`、`navigationDestination`、弹层归本页。
//  若日后 MainTabView 改为给消息栏包栈，需要一起删掉本文件的 `NavigationStack(path: chatPath)`。
//
//  通道徽章的判定表（Docs/popopx-brand-spec.md §2.2，一行只出现一枚，紫青绝不同行混用 §1.1）：
//
//  | 判定依据                                   | 徽章                                             |
//  |--------------------------------------------|--------------------------------------------------|
//  | 已绑定厢语 + 有邻居路由（15 秒内听到过）    | `meshInk` + `antenna.radiowaves.left.and.right` + `· N`（数字必出，§1.4 第 3 条）|
//  | 已绑定厢语 + 无路由（射频关 / 无邻居 / 超窗）| `labelSecondary` + `clock` + 「待中继」            |
//  | 未绑定厢语，SMP 连接已就绪（本机单聊与群组/频道）  | `brand` + `lock.shield.fill`                       |
//  | 未绑定厢语，SMP 也未就绪（含只读观察的群）         | 「未连通」（无图标，`clock` 只留给「待中继」）      |
//  | 绑定表尚未读完                               | 「读取中」（不替用户猜通道）                       |
//  | 本机笔记 / 待接受的联系 / 无效数据                  | 不显示徽章（没有任何通道可说）                      |
//
//  唯一的一次 actor hop：`IdentityMappingStore` 是 actor，逐行 `await` 会把列表打成串行队列，
//  所以只在 `reloadMeshBindings()` 里读一次 `allMappings()`，压成 `[contactId: meshPublicKeyHex]`
//  （同一联系人多条绑定时取 `updatedAt` 最新的那条），跳数则从已观察的
//  `PopopxMeshStateSource.state` 里同步查。刷新时机 = 保险丝、当前身份、邻居集合三者之一变化。
//
//  守的红线：不碰 project.pbxproj（本文件需人工拖入 POPOPX (iOS) target）；颜色/间距/字号/弹簧
//  只取 PopopxTheme 的 token；不复用 `ChatListNavLink` / `ChatPreviewView`（旧主题），但打开会话
//  用的仍是真实的 `ChatView` 与它原有的五个入参（Shared/Views/ChatList/ChatListView.swift:631）。
//

import SwiftUI
import UIKit   // `imageFromBase64` 返回的是 UIImage（ImageUtils.swift:431）；与 PopopxMeView.swift:28 同一写法
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - 通道判定值

/// 一行会话当前的通道结论。值类型，判定集中在 `ChatsListView.channel(for:)`，
/// 徽章只负责把它画出来 —— 画法和结论不可能各说各话。
enum PopopxRowChannel: Hashable {
    /// SMP 公网在线（靛紫锁）。
    case smp
    /// 厢语离线且有实时路由。`hops` 是网格最后测到的跳数，0 = 本机持有链路。
    case mesh(hops: Int)
    /// 已绑定厢语，但这一刻没有可用路由：等邻居出现即可发。
    case awaitingRelay
    /// 厢语未绑定、SMP 也没接通。
    case unreachable
    /// 绑定表还没读完，任何通道结论都为时过早。
    case checking
    /// 这条会话没有任何通道（本机笔记、读不懂的数据）。
    case none

    /// 「厢语离线」这一档收的是**已绑定**的联系人，无论此刻有没有路由：
    /// 过滤器回答"这条会话走不走厢语"，徽章才回答"这一刻走不走得通"。
    var isMeshBound: Bool {
        switch self {
        case .mesh, .awaitingRelay: true
        default: false
        }
    }
}

// MARK: - 过滤器

/// 顶部三枚胶囊。刻意不带图标：`全部` 在 §6 的图标词汇表里没有对应符号，而半套图标的过滤器
/// 比没有图标更像坏掉的设计；通道语义只由徽章承载。
enum PopopxChatFilter: Int, CaseIterable, Identifiable {
    case all
    case online
    case meshOffline

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: Copy.filterAll
        case .online: Copy.filterOnline
        case .meshOffline: Copy.filterMeshOffline
        }
    }

    func matches(_ channel: PopopxRowChannel) -> Bool {
        switch self {
        case .all: true
        case .online: channel == .smp
        case .meshOffline: channel.isMeshBound
        }
    }
}

// MARK: - 列表项

private struct PopopxChatEntry {
    let chat: Chat
    let channel: PopopxRowChannel
}

/// 邻居集合的"身份签名"：只取 peer id，不取 `lastSeenAt`/`hopCount` —— 后者每次广播都在变，
/// 拿它当 `.task(id:)` 的键会让绑定表每秒重读一遍 Keychain。
private struct PopopxMeshBindingKey: Equatable {
    let fuseOn: Bool
    let userId: Int64?
    let peerIDs: [String]
}

// MARK: - 页面

/// 整页 `@MainActor`：与 `MainTabView.swift:76`、`PopopxMeView.swift:36`、
/// `PopopxProximityAddContactView.swift:39` 同一写法，这样页内的同步小助手
/// （判定通道、震动、写 @State）都不必再各自标注，也不会踩隔离相关的警告。
@MainActor
struct ChatsListView: View {
    @EnvironmentObject private var chatModel: ChatModel

    /// 两个都是 runtime 的既有单例：`isFuseOn` 与 `stateSource.state` 才是徽章的真值来源。
    @ObservedObject private var runtime: PopopxMeshRuntime
    @ObservedObject private var meshState: PopopxMeshStateSource

    @AppStorage(DEFAULT_PRIVACY_SHOW_CHAT_PREVIEWS) private var showChatPreviews = true

    @State private var telemetry: PopopxTelemetryModel
    @State private var toast = PopopxToastModel()
    @State private var filter: PopopxChatFilter = .all
    @State private var searchText = ""
    /// 身份切换器只**写**这个值，真正的切换由下面的 `switchIdentity` 做（顶栏刻意不自己切）。
    @State private var currentUserId: Int64?
    @State private var showsAddFriend = false
    @State private var showsCreateGroup = false
    @State private var showsScan = false
    /// 切换进行中的身份 id：`changeActiveUserAsync_` 会重载会话，二次进入只会把状态搅乱。
    @State private var switchingUserId: Int64?
    /// contactId → meshPublicKeyHex，一次 actor hop 读出来的整表。
    @State private var meshBindings: [Int64: String] = [:]
    @State private var meshBindingsLoaded = false
    /// 徽章的"新鲜度"用的是渲染时的这个时刻，而不是 `Date.now`：只有状态变化才会重画视图，
    /// 所以配一个 5 秒的轮询把静默超窗的邻居自己褪成「待中继」。
    @State private var clock = Date.now

    // `fileprivate` 而不是 `private`：`maxMeshHops` 除了本页判定，还要被同文件的
    // `PopopxChatFilterBar` 与 `PopopxChatsEmptyState` 引用，而 Swift 的 `private` 只覆盖
    // 同一类型（含其同文件扩展）内部，跨类型引用会直接"inaccessible due to 'private'"。
    /// 跳数上限直接引模块 5 的常量（`PopopxMeshConfig.fragmentRelayTtlCap`），不在此重写 7。
    fileprivate static let maxMeshHops = Int(PopopxMeshConfig.default.fragmentRelayTtlCap)
    /// 15 秒：与模块 4 判「蓝牙不可达」用的同一个窗口，读自配置。
    private static let reachabilityTimeout = PopopxMeshConfig.default.peerReachabilityTimeout
    private static let meshPollSeconds: Double = 5

    @MainActor init() {
        let runtime = PopopxMeshRuntime.shared
        _runtime = ObservedObject(wrappedValue: runtime)
        _meshState = ObservedObject(wrappedValue: runtime.stateSource)
        _currentUserId = State(initialValue: ChatModel.shared.currentUser?.userId)
        // 用 `.shared` 而不是新建：顶栏渲染在这里，而"近场在跑"由面对面页写进来（PopopxProximityAddContactView 的 begin/finish）。
        _telemetry = State(initialValue: .shared)
    }

    var body: some View {
        NavigationStack(path: chatPath) {
            chatList
        }
        .background(PopopxPalette.base)
    }

    /// `ChatModel.chatId`（Shared/Model/ChatModel.swift:411）→ 栈路径。形与语义照抄旧
    /// ChatListView.swift:204-211：字段非空即压上一页，返回即写回 nil。路径元素用 `Bool`
    /// （旧代码同一个类型）：本页只需要"有没有打开的会话"这个信号，具体哪一条永远从 `chatId`
    /// 现读，因此不存在两份真值。
    private var chatPath: Binding<[Bool]> {
        Binding(
            get: { chatModel.chatId != nil ? [true] : [] },
            set: { path in if path.isEmpty { chatModel.chatId = nil } }
        )
    }

    @ViewBuilder private var chatList: some View {
        let entries = searchedEntries()
        let rows = entries.filter { filter.matches($0.channel) }
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
                emptyState(searching: !searchText.trimmed.isEmpty, hasAnyChat: !chatModel.chats.isEmpty)
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
        .navigationTitle(Copy.tabTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: Copy.searchPrompt)
        .safeAreaInset(edge: .top, spacing: 0) { chrome }
        // 打开会话：目的地类型与旧的五个入参一字不改照抄（见 `PopopxChatRoomDestination`）。
        .navigationDestination(for: Bool.self) { _ in chatRoom() }
        // 「+」菜单里的两项，走 app 里已有的两个真实页面。
        // `ThemedBackground` 是旧主题接口：被推送的是旧页面，让它按自己的主题铺底才不会糊成一片，
        // 挂载方式照抄 Shared/Views/NewChat/NewChatMenuButton.swift:89 与 :93。
        .navigationDestination(isPresented: $showsCreateGroup) {
            PopopxCreateGroupView()
                .navigationTitle(Copy.createGroupTitle)
                .modifier(ThemedBackground(grouped: true))
        }
        .navigationDestination(isPresented: $showsScan) {
            NewChatView(selection: .connect, showQRCodeScanner: true)
                .navigationTitle(Copy.scanTitle)
                .modifier(ThemedBackground(grouped: true))
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showsAddFriend) {
            PopopxAddFriendView()
        }
        .popopxToast(toast)
        .task { await startTelemetry() }
        .task(id: meshBindingKey) { await reloadMeshBindings() }
        .task(id: runtime.isFuseOn) { await pollMeshFreshness() }
        .onChange(of: currentUserId) { _, userId in
            Task { @MainActor in await switchIdentity(to: userId) }
        }
        .onChange(of: chatModel.currentUser?.userId) { _, userId in
            currentUserId = userId
        }
    }

    // MARK: 顶栏 + 过滤器

    private var chrome: some View {
        VStack(spacing: 0) {
            PopopxTelemetryHeader(
                currentUserId: $currentUserId,
                identities: switchableIdentities,
                telemetry: telemetry,
                onAddFriend: { showsAddFriend = true },
                onStartGroupChat: { showsCreateGroup = true },
                onScan: { showsScan = true }
            )
            PopopxChatFilterBar(
                selection: $filter,
                counts: counts(of: searchedEntries())
            )
            Rectangle()
                .fill(PopopxPalette.separator)
                .frame(height: PopopxMetrics.divider)
        }
        .background(PopopxMaterial.bar)
    }

    // MARK: 行

    @ViewBuilder private func row(_ entry: PopopxChatEntry) -> some View {
        let chat = entry.chat
        Button {
            open(chat)
        } label: {
            PopopxChatRow(chat: chat, channel: entry.channel, showsPreview: showChatPreviews)
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .disabled(!canOpen(chat))
        .opacity(canOpen(chat) ? 1 : 0.5)
        .listRowInsets(EdgeInsets(
            top: PopopxMetrics.space2XS,
            leading: PopopxMetrics.gutter,
            bottom: PopopxMetrics.space2XS,
            trailing: PopopxMetrics.gutter
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// 会话能不能打开，照抄旧列表同一处判据（Shared/Views/ChatList/ChatListView.swift:562）。
    private func canOpen(_ chat: Chat) -> Bool {
        chatModel.chatRunning == true && !chatModel.deletedChats.contains(chat.chatInfo.id)
    }

    /// 点行只做既有约定那一件事：`ItemsModel.loadOpenChat` 先读消息，250ms 后写
    /// `ChatModel.chatId`（ChatModel.swift:113-139），栈路径绑定随即把它翻成一页 —— 与通知
    /// 点开走的是同一条路，本文件不再维护第二份"打开了哪条会话"的状态。
    private func open(_ chat: Chat) {
        guard canOpen(chat) else { return }
        PopopxHaptics.impact(.light)
        ItemsModel.shared.loadOpenChat(chat.chatInfo.id)
    }

    /// 目的地：id 从 `chatId` 现读，`PopopxChatRoomDestination` 再按 id 取会话。
    @ViewBuilder private func chatRoom() -> some View {
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

    // MARK: 数据

    /// 与旧列表同一条排除规则（Shared/Views/ChatList/ChatListView.swift:655）。
    private func searchedEntries() -> [PopopxChatEntry] {
        let query = searchText.trimmed.localizedLowercase
        var entries: [PopopxChatEntry] = []
        entries.reserveCapacity(chatModel.chats.count)
        for chat in chatModel.chats {
            let info = chat.chatInfo
            guard !info.chatDeleted, !info.contactCard else { continue }
            if !query.isEmpty, !info.chatViewName.localizedLowercase.contains(query) { continue }
            entries.append(PopopxChatEntry(chat: chat, channel: channel(for: chat)))
        }
        return entries
    }

    private func counts(of entries: [PopopxChatEntry]) -> [PopopxChatFilter: Int] {
        var counts: [PopopxChatFilter: Int] = [:]
        for option in PopopxChatFilter.allCases {
            counts[option] = entries.filter { option.matches($0.channel) }.count
        }
        return counts
    }

    /// 通道判定。顺序即优先级：保险丝 → 绑定表 → 绑定 → 射频 → 邻居路由 → 新鲜度。
    private func channel(for chat: Chat) -> PopopxRowChannel {
        // SMP 那一侧的判据取 `chatInfo.sndReady`（POPOPXChat/ChatTypes.swift:2156）：它的语义正是
        // "这条会话现在能不能走 SMP"，且 contactRequest / contactConnection 天然为 false、
        // 本机笔记天然为 true，不需要在本文件重写一遍各 case 的判定。
        let smpReady = chat.chatInfo.sndReady
        switch chat.chatInfo {
        case let .direct(contact):
            return directChannel(contactId: contact.contactId, smpReady: smpReady)
        case .group:
            // 群组与频道只有 SMP 公网这一条路：厢语离线不中继群播，所以不给青色。
            return smpReady ? .smp : .unreachable
        case .local, .contactRequest, .contactConnection, .invalidJSON:
            // 本机笔记不过任何通道；还没建立的联系也没有任何通道可承诺。
            return .none
        }
    }

    private func directChannel(contactId: Int64, smpReady: Bool) -> PopopxRowChannel {
        // 保险丝关着：绑定表里的键一条都不作数，此刻真实的通道只有 SMP。
        guard runtime.isFuseOn else { return smpReady ? .smp : .unreachable }
        guard meshBindingsLoaded else { return .checking }
        guard let hex = meshBindings[contactId] else { return smpReady ? .smp : .unreachable }
        guard meshState.state.radioState.isUsable else { return .awaitingRelay }
        guard let peer = meshState.state.peer(withHex: hex) else { return .awaitingRelay }
        // 跳数超出 TTL 上限、或静默超过模块 4 的可达窗口，都不再是一张能承诺送达的跳数徽章。
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
            // 只认已经指向真实联系人的绑定：还在等配对结果的行 `contactId` 就是 nil
            // （`isPending` 的定义，IdentityMappingStore.swift:62），它没有会话可对应。
            guard let contactId = mapping.contactId else { continue }
            // 同一联系人有多条绑定时只认最新一条（`allMappings()` 按 createdAt 排过序，
            // 但同一联系人可能被改绑多次，所以这里再按 updatedAt 取新）。
            if let seen = newestUpdate[contactId], seen >= mapping.updatedAt { continue }
            newestUpdate[contactId] = mapping.updatedAt
            bindings[contactId] = mapping.meshPublicKeyHex
        }
        // 读表期间保险丝可能被拨断：那一局的结论不能再写回界面。
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

    /// 顶栏只把选中的 userId 写回来，切换（api 层重载会话、重建整棵聊天视图树）归这里 ——
    /// `Shared/Navigation/PopopxTelemetryHeader.swift:187-188` 就是按这个分工写的。
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
            // 失败要把切换器拨回真实身份，否则顶栏会一直显示一个没有生效的选择。
            currentUserId = chatModel.currentUser?.userId
            logger.error("popopx chats: switching identity \(userId) failed: \(responseError(error))")
            PopopxHaptics.notice(.error)
            toast.show(Copy.identitySwitchFailed, kind: .danger)
        }
    }

    /// 可切换的身份：与 UserPicker.swift:33-35（同 `PopopxMeView.swift:465-467`）一个口径 ——
    /// 加锁的身份（`user.hidden`，即有 `viewPwdHash`）不进切换器，因为这里传的是 `viewPwd: nil`，
    /// 带着 nil 去切加锁身份只会失败；加锁身份归「我」页的身份管理。
    /// 但当前身份必须在表里，否则顶栏会把自己的名字显示成"未选择"。顺序同 UserPicker
    /// （`activeOrder` 倒序），两处列表不会各说各话。
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

    // MARK: 空状态

    private func emptyState(searching: Bool, hasAnyChat: Bool) -> some View {
        PopopxChatsEmptyState(
            searching: searching,
            query: searchText.trimmed,
            hasAnyChat: hasAnyChat,
            filter: filter,
            fuseOn: runtime.isFuseOn,
            radioUsable: meshState.state.radioState.isUsable,
            bindingsLoaded: meshBindingsLoaded
        )
    }
}

// MARK: - 胶囊过滤器

@MainActor private struct PopopxChatFilterBar: View {
    @Binding var selection: PopopxChatFilter
    let counts: [PopopxChatFilter: Int]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 横向滚动而不是换行：无障碍字号下三枚中文胶囊放不进一行，截断比滚动更糟。
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                ForEach(PopopxChatFilter.allCases) { option in
                    capsule(option)
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.vertical, PopopxMetrics.space2XS)
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
}

// MARK: - 会话行

@MainActor private struct PopopxChatRow: View {
    @ObservedObject var chat: Chat
    let channel: PopopxRowChannel
    let showsPreview: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 头像边长取 `space2XL`（48pt）：徽章在右栏，行高由内容决定，44pt 命中区由外层 `minHeight` 保证。
    private var avatarSide: CGFloat { PopopxMetrics.space2XL }

    /// 可访问性字号下预览让出第二行 —— 一行只显示一行的话，大字号用户看到的永远是截断。
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
        // 验收锚点：行的 AX 形状会随屏宽和模态层变（375pt 冷启实测：列表画着两行，行标题只剩 staticText，
        // 唯一带群名的"按钮"是导航标题 220x32），用例需要一个不随语言、不随形状变的把手。
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
            // 时间戳用 `metric`：PopopxTheme.swift:203-204 明确"跳数、时延、时间戳走等宽数字"，
            // 列表每分钟刷新才不会左右抖动。
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

// MARK: - 通道徽章

@MainActor private struct PopopxChannelBadge: View {
    let channel: PopopxRowChannel

    var body: some View {
        switch channel {
        case .smp:
            label(symbol: Copy.smpSymbol, text: nil, tint: PopopxPalette.brand, spoken: Copy.channelSmp)
        case let .mesh(hops):
            // §1.4 第 3 条：跳数徽章永远带数字，颜色只是装饰。
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

    /// 只有一枚徽章的行元素：图标是装饰，语义一律由 `accessibilityLabel` 说清楚。
    @ViewBuilder private func label(symbol: String?, text: String?, tint: Color, spoken: String) -> some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            if let symbol {
                // §6：徽章符号不低于 medium 重量；与 PopopxControls.swift:320-322 同一写法。
                Image(systemName: symbol)
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            if let text {
                // 数字用 `metric`（等宽），中文说明用 `microTag`。
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

// MARK: - 未读标记

@MainActor private struct PopopxUnreadMark: View {
    @ObservedObject var chat: Chat

    /// 未读不用 `brand`：一行里青紫不得同色（§1.1），而通道徽章才是这行的颜色承载者。
    /// 反相的 `label` 底 + `card` 墨在两种模式下都远高于 4.5:1，且不携带任何通道语义。
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

// MARK: - 空状态

@MainActor private struct PopopxChatsEmptyState: View {
    let searching: Bool
    let query: String
    let hasAnyChat: Bool
    let filter: PopopxChatFilter
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

    /// 空状态必须说清"为什么是空的"：这三档的解释各不相同，任何一档都不给"敬请期待"。
    private var detail: String {
        if searching { return Copy.emptySearchDetail(query) }
        if !hasAnyChat { return Copy.emptyNoneDetail }
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
        }
    }
}

// MARK: - 聊天室目的页

/// 真实目的页：`ChatView` 与它的五个入参照抄 `Shared/Views/ChatList/ChatListView.swift:631`。
/// 按 id 现取，会话在打开前被删掉时说实话，不给一个空壳聊天室。
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

// MARK: - 文案

/// 用户可见的中文一律在这里声明一次（§2.5 第 3 条：原子控件库不内置文案，页面自己给）。
private enum Copy {
    static let tabTitle = "消息"
    static let searchPrompt = "搜索会话名称"
    static let filterGroupLabel = "会话通道过滤"
    static let filterAll = "全部"
    static let filterOnline = "在线加密"
    static let filterMeshOffline = "厢语离线"

    static let createGroupTitle = "发起群聊"
    static let scanTitle = "扫一扫"

    // 徽章：图标词汇表固定下来的三个符号（§6），一行只出现一枚。
    static let smpSymbol = "lock.shield.fill"
    static let meshSymbol = "antenna.radiowaves.left.and.right"
    static let relaySymbol = "clock"

    static let channelSmp = "SMP 在线加密"
    static let awaitingRelay = "待中继"
    static let unreachable = "未连通"
    static let checking = "读取中"

    static func hopsSuffix(_ hops: Int) -> String { "· \(hops)" }
    static func channelMesh(_ hops: Int) -> String {
        hops == 0 ? "厢语离线，直连（0 跳）" : "厢语离线，\(hops) 跳"
    }
    static func filterValue(_ count: Int, hopCap: Int, isMesh: Bool) -> String {
        isMesh
            ? "\(count) 个已绑定会话，中继上限 \(hopCap) 跳"
            : "\(count) 个会话"
    }

    static func unreadCount(_ count: Int) -> String { "未读 \(count) 条" }
    static let unreadDot = "有未读消息"

    static let previewHidden = "已关闭消息预览"
    static let noMessagesYet = "还没有消息"
    static let noNotesYet = "还没有笔记"
    static let deletedContent = "这条消息已撤回"
    static let noTextContent = "（无文字内容）"
    static let monogramFallback = "？"

    static let emptySearchTitle = "没有匹配的会话"
    static let emptyNoneTitle = "还没有会话"
    static let emptyFilteredTitle = "这一档里暂时没有会话"

    static func emptySearchDetail(_ query: String) -> String { "没有名字里带「\(query)」的会话。换个词，或切回「全部」。" }
    static let emptyNoneDetail = "点右上角「+」添加朋友、发起群聊或扫一扫，第一条会话会出现在这里。"
    static let emptyAllDetail = "会话都在回收中，稍后刷新。"
    static let emptyOnlineDetail = "已就绪的 SMP 连接都会带靛紫锁徽章；未接通的联系只出现在「全部」。"
    static let emptyMeshFuseOffDetail = "厢语离线组网已关闭。打开顶部的总开关后，已绑定蓝牙身份的联系人才会回到这一档。"
    static let emptyMeshLoadingDetail = "正在读取本机保存的厢语身份绑定表。"
    static let emptyMeshRadioOffDetail = "蓝牙当前不可用，已绑定的联系人会以「待中继」等待；射频恢复后自动给出跳数。"
    static func emptyMeshDetail(_ hopCap: Int) -> String { "还没有绑定厢语蓝牙身份的联系人。面对面加友或扫一扫建连后，这里会出现最多 \(hopCap) 跳的离线会话。" }

    static let serviceStarting = "加密服务正在启动，稍候即可打开会话。"
    static let serviceDisconnected = "加密服务已停止：可在「设置 → 聊天数据」启动，或直接重启应用；期间会话打不开。"
    static let chatGone = "这条会话已被删除，或还没加载完成。"

    static let unnamedIdentity = "未命名身份"
    static func identitySwitched(_ name: String) -> String { "已切换到身份 \(name)" }
    static let identitySwitchFailed = "身份切换失败，请重试"
}

// MARK: - Previews

#if DEBUG
// 栈由本页自己建（见文件头"栈的归属"），预览因此不再包 NavigationStack。
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
