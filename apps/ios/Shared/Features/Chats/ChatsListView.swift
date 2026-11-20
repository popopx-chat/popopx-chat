//
//  ChatsListView.swift
//  POPOPX (iOS)
//
//  【第四阶段 · Tab 1 消息】新版会话列表。
//
//  三段结构：顶部嵌第三阶段的 `PopopxTelemetryHeader`（身份切换 / 双模状态 / 「+」菜单），
//  中间是 全部 · 在线加密 · 厢语离线 · 频道 四枚胶囊过滤器，下面是每张卡片一行的会话列表。
//
//  栈的归属（这里按**已落地的** `Shared/Navigation/MainTabView.swift` 来，而不是按任务书的假设）：
//  MainTabView.swift:14-20 与 :76-79 明确决定"消息这一栏自己带 NavigationStack，其余三栏才由壳包"。
//  理由是本工程把"打开会话"翻成"推送一页"的唯一一处，是 `ChatModel.chatId`
//  （Shared/Model/ChatModel.swift:411）到栈路径的绑定（旧 ChatListView.swift:210-217）；
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
//  只取 PopopxTheme 的 token；不复用 `ChatListNavLink` / `ChatPreviewView` 这两个**视图**（旧主题），
//  但打开会话用的仍是真实的 `ChatView` 与它原有的五个入参（Shared/Views/ChatList/ChatListView.swift:637）。
//
//  会话行的左右滑动快捷操作（真机第 8 轮 · 任务七补回）：挂在这一行的 wrapper `PopopxChatRowSwipe` 上，
//  按钮清单逐条对照上游 `ChatListNavLink.swift` 移植 —— 复用视图会连旧卡片一起带回来，所以移植的是
//  清单与 API，画法走系统 `.swipeActions` + `Label`。
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

/// 顶部四枚胶囊。刻意不带图标：`全部` 在 §6 的图标词汇表里没有对应符号，而半套图标的过滤器
/// 比没有图标更像坏掉的设计；通道语义只由徽章承载。
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

    /// `isChannel` 说的是"这条会话是不是公共频道"，与走哪条通道无关：频道和群组一样只有 SMP
    /// 一条路（见 `channel(for:)` 里 `.group` 那一支），所以它不能从 `PopopxRowChannel` 推出来。
    func matches(_ channel: PopopxRowChannel, isChannel: Bool) -> Bool {
        switch self {
        case .all: true
        case .online: channel == .smp
        case .meshOffline: channel.isMeshBound
        case .channel: isChannel
        }
    }
}

// MARK: - 列表项

private struct PopopxChatEntry {
    let chat: Chat
    let channel: PopopxRowChannel
    /// 会话自己是不是频道（`ChatInfo.isChannel` = 群组的 `useRelays`，POPOPXChat/ChatTypes.swift:2296）。
    let isChannel: Bool
}

/// 邻居集合的"身份签名"：只取 peer id，不取 `lastSeenAt`/`hopCount` —— 后者每次广播都在变，
/// 拿它当 `.task(id:)` 的键会让绑定表每秒重读一遍 Keychain。
private struct PopopxMeshBindingKey: Equatable {
    let fuseOn: Bool
    let userId: Int64?
    let peerIDs: [String]
}

// MARK: - 页面

/// 先锋体验弹窗"问过没有"的那一格键名。写成文件级常量而不是 `@AppStorage("…")` 的字面量：
/// UserDefaults 的键要靠名字普查（自毁与迁移那几处按名字清点），散在装饰器里就搜不到归属。
private let popopxTrialWelcomeAskedKey = "popopx.commerce.trialWelcomeAsked"

/// 整页 `@MainActor`：与 `MainTabView.swift:77`、`PopopxMeView.swift:36`、
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
    /// 2026-11-20 真机第 2 轮裁定的「放大镜 + 可折叠搜索行」：默认收起，点开才占一行。
    /// 收起时把 `searchText` 清掉，避免一个看不见却还在过滤列表的条件。
    @State private var showsSearchRow = false
    /// 身份切换器只**写**这个值，真正的切换由下面的 `switchIdentity` 做（顶栏刻意不自己切）。
    @State private var currentUserId: Int64?
    @State private var showsAddFriend = false
    @State private var showsCreateGroup = false
    @State private var showsCreateChannel = false
    @State private var showsScan = false
    /// 创建频道页里「Configure relays」那一行按值推到 `NetworkAndServers`（`AddChannelView.swift:85`），
    /// 与「我」栏那棵栈同一口径（`MainTabView.swift:121`）：谁承载栈，谁持有 `SaveableSettings`。
    @StateObject private var serversSettings = SaveableSettings()
    /// 3 天先锋体验徽章的告知弹窗：只问一次，关掉就不再打扰。
    /// 这一格只表"问过没有"；"这台设备领过没有"在 Keychain 的 `trialGuard` 里
    /// （`PopopxBadgeManager.canClaimPioneerTrial` 读的就是它），所以清掉这一格不会让人多领一次。
    @AppStorage(popopxTrialWelcomeAskedKey) private var trialWelcomeAsked = false
    /// 徽章三条出口的载体状态（体验说明 / 详情 / 付费墙）；这一页只会自己抬 `.trial`，
    /// 另外两档由弹窗里的出口切换（`PopopxBadgeSheetHost`）。
    @State private var badgeSheet: PopopxBadgeSheet?
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
    /// ChatListView.swift:210-217：字段非空即压上一页，返回即写回 nil。路径元素用 `Bool`
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
        let rows = entries.filter { filter.matches($0.channel, isChannel: $0.isChannel) }
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
        // 「消息」那一行大标题连同 `.searchable` 抽屉一起撤掉（真机第 2 轮第 1 项）：
        // 系统标题栏整条隐藏，第一行改由 `chrome` 里的统一顶栏承担，搜索收进可折叠行。
        // 隐藏只作用于栈的这一页 —— `PopopxChatRoomDestination` 自己声明标题栏可见，
        // 返回按钮与页内导航不受影响。
        .toolbar(.hidden, for: .navigationBar)
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
                // 新建对话框同样收起底栏（真机第 2 轮第 2 项，口径同 `chatRoom()`）。
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showsScan) {
            NewChatView(selection: .connect, showQRCodeScanner: true)
                .navigationTitle(Copy.scanTitle)
                .modifier(ThemedBackground(grouped: true))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .tabBar)
        }
        // 创建频道：同一个 `AddChannelView`（旧「新建聊天」菜单里那一枚，:97-101），挂载写法照抄上面
        // `showsCreateGroup` 那一处 —— 同样的推页、同样的 `ThemedBackground`、同样收起底栏。
        // 它内部那一行「Configure relays」是按 `ServersDestination` 值推的（AddChannelView.swift:85），
        // 所以这三条登记必须挂在栈根（口径同 MainTabView.swift:159-167：同一类型只保留最靠近栈根的登记）。
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
        // 先锋体验徽章的告知弹窗。挂在这一页而不是 `POPOPXApp` 那一层：这里已经有会话栈，
        // sheet 才挂得住；`PopopxTrialWelcomeModal` 自己带"领取"按钮和失败原因，
        // 所以这一层只决定"要不要问这一次"，不替它领。
        // 三张徽章面板走同一个载体：弹窗里点「看徽章详情」要换到详情页，
        // 换 `item` 就行，不必在这一层再挂第二条 sheet。
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

    // MARK: 顶栏 + 过滤器

    private var chrome: some View {
        VStack(spacing: 0) {
            PopopxTelemetryHeader(
                currentUserId: $currentUserId,
                identities: switchableIdentities,
                telemetry: telemetry,
                onAddFriend: { showsAddFriend = true },
                onStartGroupChat: { showsCreateGroup = true },
                onCreateChannel: { showsCreateChannel = true },
                onScan: { showsScan = true }
            )
            if showsSearchRow {
                PopopxChatSearchRow(text: $searchText, onClose: closeSearchRow)
                    .transition(.opacity)
            } else {
                PopopxChatFilterBar(
                    selection: $filter,
                    counts: counts(of: searchedEntries()),
                    onSearch: { popopxToggleSearch(open: true) }
                )
            }
            Rectangle()
                .fill(PopopxPalette.separator)
                .frame(height: PopopxMetrics.divider)
        }
        .background(PopopxMaterial.bar)
    }

    /// 展开/收起搜索行。动画走品牌弹簧，Reduce Motion 由 `popopxAnimation` 那侧统一管。
    private func popopxToggleSearch(open: Bool) {
        withAnimation(PopopxSpring.snappy) { showsSearchRow = open }
        PopopxHaptics.selection()
    }

    /// 收起一定要清条件：留着关键词，用户看到的是一条"莫名其妙少了几行"的列表。
    private func closeSearchRow() {
        searchText = ""
        popopxToggleSearch(open: false)
    }

    // MARK: 行

    /// 一行 = `PopopxChatRowSwipe`（卡片本身 + 左右滑动快捷操作）+ 这一行的行内几何。
    ///
    /// 行内边距、分隔线、行背景三句留在原处不动：滑动按钮挂在**行内容**上，改的是内容而不是行的几何，
    /// `PopopxMetrics.gutter` 仍是唯一的 gutter 来源。为什么手势要下沉到 wrapper 而不是就地挂在
    /// `Button` 上，见 `PopopxChatRowSwipe` 的类型注释。
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

    /// 目的地：id 从 `chatId` 现读，`PopopxChatRoomDestination` 再按 id 取会话。
    /// 栈路径翻出来的那一页。两个分支都要挂到，所以包一层 `Group`：
    /// "会话已经不在了"那一屏同样是对话框栈里的一页，底栏该收就得收。
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
        // 真机第 2 轮第 2 项：进对话框就收起底部四栏。这一句挂在"被推入的那一页"上，
        // 不是挂在列表上，所以返回时系统按作用域自己收回 —— 列表页底栏照旧四栏。
        // 通讯录与厢语打开会话也走这里：它们都只写 `ChatModel.chatId`，
        // 由 `MainTabView.swift:186` 把栏切到"消息"后由本页的栈呈现，全 app 只有这一个对话框出口。
        .toolbar(.hidden, for: .tabBar)
        // 顶栏那一行在列表页被整条隐藏（上面 `chatList`），对话框必须自己声明可见，
        // 否则返回按钮和 ChatView 的标题栏一起没了。
        .toolbar(.visible, for: .navigationBar)
    }

    // MARK: 数据

    /// 与旧列表同一条排除规则（Shared/Views/ChatList/ChatListView.swift:661）。
    private func searchedEntries() -> [PopopxChatEntry] {
        let query = searchText.trimmed.localizedLowercase
        var entries: [PopopxChatEntry] = []
        entries.reserveCapacity(chatModel.chats.count)
        for chat in chatModel.chats {
            let info = chat.chatInfo
            guard !info.chatDeleted, !info.contactCard else { continue }
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

    /// 首启那一次体验徽章的告知：两个条件都成立才问，问完就落那一格 UserDefaults。
    ///
    /// `canClaimPioneerTrial` 读的是"没有徽章记录 + Keychain 里没有 trialGuard"，
    /// 而那份记录在 `PopopxBadgeManager` 的 `init()` 里就同步取好了（PopopxBadgeManager.swift:65-71），
    /// 所以这里不必等 `start()`：`start()` 装的是 StoreKit 交付与心跳，和这一格判定无关。
    /// 已经领过的人、已经到期降级的人、已经问过的人，都从这里直接返回，不弹窗、不读盘、不发东西。
    private func presentTrialWelcomeIfNeeded() {
        guard !trialWelcomeAsked else { return }
        guard PopopxBadgeManager.shared.canClaimPioneerTrial else { return }
        trialWelcomeAsked = true
        badgeSheet = .trial
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

    /// 可切换的身份：与 UserPicker.swift:33-35（同 `PopopxMeView.swift:514-516`）一个口径 ——
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
    /// 行尾钉住的搜索入口，nil 就不画。刻意不放进横向滚动区：它在整行最右，
    /// 滚到任何一个筛选胶囊时都点得到（真机第 2 轮裁定「放大镜 + 可折叠搜索行」）。
    var onSearch: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 横向滚动而不是换行：无障碍字号下筛选胶囊放不进一行，截断比滚动更糟。
        // 四枚胶囊在 iPhone 15 Pro（393pt）Large 字号下的占有账（内边距 12×2=24、汉字按 1em≈17pt、
        // 数字 metricSmall≈7pt、胶囊间距 spaceXS=8）：全部 69、在线加密 103、厢语离线 103、频道 69
        // → 内容 344 + 间距 24 = 368，加滚动区内的 gutter 16 与尾部 8 = 392；放大镜那一枚钉在滚动区
        // 外面（44 + 尾部 12 = 56），整行需要 448 —— 393 装不下，缺口 55pt，第四枚要横扫一下才全露。
        // 三枚时同一笔账是 371，还留 22pt。结论：不换行、不加第二行，靠已有的横向滚动承载，
        // 并且第四枚刻意取最短的正确说法（「频道」两个汉字，与「全部」同宽）。
        // 行尾那枚放大镜钉在滚动区外面：HStack 先把固定宽度的一端排好，ScrollView 吃剩下的，
        // 所以把搜索入口包在这一层外面不会让整行的档位测量出错（顶栏那一簇就是被
        // `ViewThatFits` 之外的 `.fixedSize()` 坑过，同一个教训）。
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PopopxMetrics.spaceXS) {
                    ForEach(PopopxChatFilter.allCases) { option in
                        capsule(option)
                    }
                }
                .padding(.leading, PopopxMetrics.gutter)
                .padding(.trailing, onSearch == nil ? PopopxMetrics.gutter : PopopxMetrics.spaceXS)
                .padding(.vertical, PopopxMetrics.space2XS)
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
}

// MARK: - 可折叠搜索行

/// 顶栏第 2 轮裁定的那一行：放大镜点开才出现，绑定同一个 `searchText`，
/// 所以过滤逻辑（`searchedEntries()`）一行都没改，只是从 `.searchable` 抽屉搬进了页面自己的一行。
/// 输入框不设圆角卡片以外的装饰：44pt 命中、`gutter` 对齐列表内容，收起条件在右侧。
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
        // 展开即聚焦：这一步让"点开搜索"和"开始输入"合成一次操作，收起来时同步交还键盘。
        .onAppear { focused = true }
        .onDisappear { focused = false }
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

// MARK: - 会话行的滑动快捷操作

/// 真机第 8 轮 · 任务七：把上一轮改版漏掉的左右滑动快捷操作**挂回来**。
///
/// 功能面是逐条对照 `Shared/Views/ChatList/ChatListNavLink.swift` 移植的，不是新设计：
/// 每个 `chatType` 有哪几枚、顺序如何、点下去走哪个既有 API、要不要确认框，都与上游一致。
///
/// 为什么要有这一层 wrapper，而不是在 `ChatsListView.row(_:)` 里就地挂 `.swipeActions`：
/// 滑动按钮里有几样东西需要**每行一份**的呈现状态 —— `deleteContactDialog` 要求
/// `SomeAlert` / `SomeActionSheet` / `SomeSheet` 三个回调通道（Shared/Views/Chat/ChatInfoView.swift:1139），
/// 「List」那一枚要把 `TagSheetRoot` 开在本行的 sheet 上，contactConnection 的「Name」同理。
/// 挂在页面上就变成全列表共用一格状态，两行不同的确认框会互相顶掉；上游同样是把状态留在
/// 行内容自己身上（`ChatListNavLink` 的 `@State alert/actionSheet/sheet`），这里同形。
///
/// 行内容仍然是 `Button`，不换 `NavigationLink`：`Tests iOS/Tests_iOS.swift:428-454` 命中这一行靠的是
/// 行内 `staticTexts` 与 `PopopxChatRow` 上的 `popopx.row` 锚点，换控件会改这一行的 AX 形状；
/// 而且打开会话只有 `ChatModel.chatId` 一条路（见文件头"栈的归属"），换成值推送会切断通知点开。
///
/// `allowsFullSwipe: false`：本 fork 的删除/清空一律走确认框（上游也不用 `role:`，见
/// `ChatListNavLink.swift:385-401`），整滑只是把最边上一枚"摔"下去，对一件还需要确认的事没有意义，
/// 还会和卡片圆角打架。这是相对上游（`allowsFullSwipe: true`）唯一的一处手势收窄。
@MainActor private struct PopopxChatRowSwipe: View {
    @EnvironmentObject private var chatModel: ChatModel
    @ObservedObject var chat: Chat
    let channel: PopopxRowChannel
    let showsPreview: Bool

    /// 「List」按钮的承载页要读它；注入方式与旧列表同一处（ChatListView.swift:185）一致。
    @StateObject private var chatTagsModel = ChatTagsModel.shared

    /// 三样通道 + 一格 sheet，全是本行自己的。
    /// `alert` / `actionSheet` / `sheet` 是 `deleteContactDialog` 要求的三个回调通道
    /// （Shared/Views/Chat/ChatInfoView.swift:1139）；「More」的动作表和第二级确认走同一对通道。
    /// `sheet` 同时承载 `DeleteActiveContactDialog` 与「List」的 `TagSheetRoot` —— 两者本来就
    /// 互斥（同一行同一刻只会有一张），合并成一条 `.sheet` 是为了不在同一个视图上叠两个呈现层。
    @State private var alert: SomeAlert?
    @State private var actionSheet: SomeActionSheet?
    @State private var sheet: SomeSheet<AnyView>?
    @State private var showContactConnectionInfo = false

    /// 滑动按钮的五档颜色，全部取 `PopopxPalette` 已有的语义 token（主题文件是红线，不新增颜色）。
    /// 上游的 `.orange` / `.yellow` / `.mint` 在本 fork 没有对应 token，按语义就近映射：
    /// `primary`→`brand`、`green`→`success`、`red`→`danger`、`orange`(清空，不可撤回但不删实体)→`dangerInk`、
    /// 无 tint 与 `yellow`/`mint`/`indigo`（次要或中性）→`neutral`。
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
                // 读不懂的数据：上游这一行也没有滑动按钮，只有点开看原始 JSON
                // （ChatListNavLink.swift:641-651），此处同形 —— 不给一枚点了什么都不知道的按钮。
                rowCard
            }
        }
        .alert(item: $alert) { $0.alert }
        // 删除联系人的两级确认与「More」的动作表都是 ActionSheet —— 这是 `deleteContactDialog`
        // 要求的接口形态，本 fork 的同一链路也是这么挂的（PopopxChatInfoView.swift:175）。
        .actionSheet(item: $actionSheet) { $0.actionSheet }
        // 一条 `.sheet` 同时承载 `DeleteActiveContactDialog`（第二级删除确认）与「List」的
        // `TagSheetRoot`：这两张面板本来就互斥，叠两条 `.sheet` 只会多一个呈现层。
        .sheet(item: $sheet) { someSheet in
            someSheet.content
                .presentationDetents([.fraction(someSheet.fraction)])
        }
    }

    // MARK: 卡片与打开

    /// 卡片本体与 tap 行为一行都没改：还是 `PopopxChatRow`，还是 `PopopxPressButtonStyle`，
    /// 还是"点行只做既有约定那一件事"——`ItemsModel.loadOpenChat` 先读消息，250ms 后写
    /// `ChatModel.chatId`（ChatModel.swift:113-139），栈路径绑定随即把它翻成一页；
    /// 与通知点开走的是同一条路，本文件不维护第二份"打开了哪条会话"的状态。
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

    /// 会话能不能打开，判据照抄旧列表同一处（Shared/Views/ChatList/ChatListView.swift:568），
    /// 从 `ChatsListView` 原样搬进来，一个条件都没动。
    private var openable: Bool {
        chatModel.chatRunning == true && !chatModel.deletedChats.contains(chat.chatInfo.id)
    }

    private func open() {
        guard openable else { return }
        PopopxHaptics.impact(.light)
        ItemsModel.shared.loadOpenChat(chat.chatInfo.id)
    }

    // MARK: 按 chatType 的挂载表

    /// 单聊。
    ///
    /// 联系人名片那一行不用特判：`searchedEntries()` 已把它连同 `chatDeleted` 一起摘掉
    /// （本文件 :413 那一处 `!info.chatDeleted, !info.contactCard`），上游
    /// `ChatListNavLink.swift:98-120` 那一支在这里没有对应物。
    ///
    /// 有等待确认的入呼时左侧三枚整组撤掉（上游 `:128` 的 `.if(!contact.nextAcceptContactRequest)`）：
    /// 还没接受的联系没有"已读/置顶/静音"可说。
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
                        // 群成员递过来的直连邀请：接受/拒绝走的是 `acceptMemberContactRequest` 那一对，
                        // 与联系请求那一对不是同一条 API（ComposeView.swift:567-570 同一分岔）。
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

    /// 群组与频道：三档 `memberStatus` 各挂各的，与上游 `groupNavLink` 同一分岔。
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

    /// 已加入群组的右侧按钮表。计数逻辑逐句照抄上游 `ChatListNavLink.swift:268-298`：
    /// 超过 3 枚时 iOS 只画得下 3 枚（Apple FB25316763），多出来的收进「More」动作表里。
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
                // 已经不在群里了：删除这一枚直接给，不再塞进「More」里等第二下。
                deleteGroupChatButton(groupInfo)
                moreOptionsButton(false, groupInfo)
            } else {
                moreOptionsButton(true, groupInfo)
            }
        }
    }

    /// 私密笔记目录：左侧只有「已读/未读」，右侧只有「清空」——上游同两处
    /// （`ChatListNavLink.swift:311-318`）。置顶/静音对只给自己看的目录没有意义，没有频道也没有
    /// 可撤的入呼，所以这两组按钮少，不是漏挂。
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

    /// 还没有接受的人：只有接受/隐身接受/拒绝。没有左侧 —— 还没建立的会话没有已读与静音。
    private func contactRequestRow(_ cReq: UserContactRequest) -> some View {
        rowCard.swipeActions(edge: .trailing, allowsFullSwipe: false) {
            acceptContactRequestButton(cReq.apiId, incognito: false)
            if !chatModel.addressShortLinkDataSet {
                acceptContactRequestButton(cReq.apiId, incognito: true)
            }
            rejectContactRequestButton(cReq.apiId)
        }
    }

    /// 建连中：删除这条连接，外加打开它的详情（上游 `showContactConnectionInfo` 那一枚「Name」）。
    /// sheet 挂在这一支而不是 `body` 上：只有这一类会话需要它，与上游 `:543` 同一位置。
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

    // MARK: 已读 / 置顶 / 静音

    /// 已读 / 未读。判定与 `PopopxUnreadMark` 同一口径（`chatStats.unreadCount` / `unreadChat`），
    /// 所以徽章亮着未读时这一枚必定写「已读」，反之必定写「未读」，两处不会各说各话。
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

    /// 置顶 == `favorite`（`apiSetChatSettings`，ChatView.swift:3460）。本 fork 的协议里没有
    /// 「隐藏」这一档，所以只有开与关两枚，不发明第三种状态。
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

    /// 静音。档位与文案都不在这里重写：`chatInfo.nextNtfMode` 给下一档（all→mentions/none、
    /// mentions→none、none→all），`MsgFilter.text(mentions:)` 给"静音 / 全部静音 / 取消静音"三种说法，
    /// `iconFilled` 给图标；没有下一档（读不懂的设置）时这一枚不出现，与上游一致。
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

    // MARK: 列表 / 清空 / 删除

    /// 「列表」：把这枚会话归到哪个标签下，用的还是 app 原有的 `TagSheetRoot`（标签编辑器与列表都在里面）。
    private func tagChatButton() -> some View {
        Button {
            PopopxHaptics.selection()
            setTagChatSheet()
        } label: {
            Label(Copy.swipeList, systemImage: "tag.fill")
        }
        .tint(Self.neutral)
    }

    /// 分数高度照抄上游算法（`ChatListNavLink.swift:412-427`）：4 行留白 + 每枚标签 44pt，上限 0.62。
    /// 屏高读宿主窗口而不是 `UIScreen.main`（iOS 16 起废弃）；拿不到就退回 0.62 这个上限本身。
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

    /// 删除联系人：两级确认，第二级是"保留会话/删除联系人 + 通知对方/不通知"那一屏。
    /// 这条链路要求三个回调通道，所以下面三个 state 必须留在本行。
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

    /// 「加入」：invited 档的群与频道。隐身进来的那枚换面具图标，与上游同一判据。
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

    /// 「更多」：超过 3 枚时收进动作表。表内容与上游 `moreOptionsButton`（:429-460）逐句同形。
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

    // MARK: 入呼与建连

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

    // MARK: 确认框

    // 五段确认框的英文原句逐字照抄上游 `ChatListNavLink.swift:560-632`：这些 Key 在 16 个语种目录里
    // 已经有译文，重写一遍只会多出一组没人翻的键，让同一件事在两个界面说两种话。

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

    /// 空状态必须说清"为什么是空的"：这四档的解释各不相同，任何一档都不给"敬请期待"。
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
        case .channel:
            return Copy.emptyChannelDetail
        }
    }
}

// MARK: - 聊天室目的页

/// 真实目的页：`ChatView` 与它的五个入参照抄 `Shared/Views/ChatList/ChatListView.swift:637`。
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
    /// 顶栏那一行的文案在 `PopopxTelemetryCopy`；这里只剩筛选条与本页 own 的短句。
    /// 源文是英文原句、英文原句就是 Key（`en.lproj` 按约定不写），16 个译本目录各写译法。
    static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX chat list")
    }

    static let searchPrompt = key("Search conversations")
    static let searchOpen = key("Search")
    static let searchClear = key("Clear the search text")
    static let searchClose = key("Close search")
    static let filterGroupLabel = "会话通道过滤"
    static let filterAll = "全部"
    static let filterOnline = "在线加密"
    static let filterMeshOffline = "厢语离线"
    /// 第四枚胶囊复用既有词条：`"Channels"` 在已有译文的 7 个目录（de/es/fr/hu/it/ru/zh-Hans，
    /// zh-Hans 里就是「频道」，:1324）里都已经在，其余目录与 en 一样回落原句本身（英文）。
    /// 而且它是本轮四枚里最短的正确说法（两个汉字，与「全部」同宽，见筛选条的宽度账）。
    static let filterChannel = key("Channels")

    /// 与「通讯录 → 我的加密群组」右上角那一枚同一个目的地，因此共用同一个 Key：
    /// 两处标题不可能再各说一句（`PopopxContactsView` 的 `createGroupEntry`）。
    static let createGroupTitle = key("Create an encrypted group")
    /// 创建频道页的标题。`AddChannelView` 自己那一行按钮与旧菜单的标题都是这一句
    /// （`Shared/Views/NewChat/NewChatMenuButton.swift:99`），不再新造一句。
    static let createChannelTitle = key("Create public channel")
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
    static let emptyChannelDetail = key("No channels yet. Create a public channel with the plus button above, or join one from a link or a QR code.")

    static let serviceStarting = "加密服务正在启动，稍候即可打开会话。"
    static let serviceDisconnected = "加密服务已停止：可在「设置 → 聊天数据」启动，或直接重启应用；期间会话打不开。"
    static let chatGone = "这条会话已被删除，或还没加载完成。"

    // 滑动快捷操作。这十七个 Key 全部沿用上游 `ChatListNavLink.swift` 的英文原句：
    // 它们已经在 16 个语种的目录里（zh-Hans 里分别是「已读 / 未读 / 最喜欢 / 取消最喜欢 / 清除 /
    // 删除 / 加入 / 离开 / 接受 / 接受隐身聊天 / 拒绝 / 列表 / 更多 / 存档举报 / 名称 /
    // 清除群组？/ 清除或删除群组？」），本页不另起一套说法。
    // 静音那一枚不在这里：它的三种说法（Mute / Mute all / Unmute）由 `MsgFilter.text(mentions:)`
    // 自己给，重写一遍只会让聊天信息页与列表各说一套。
    // ⚠️ 已知瑕疵，不在这轮修：`"Favorite"` / `"Unfav."` 这两个 Key 的 zh 译法是上游带进来的
    // 「最喜欢」/「取消最喜欢」，这一枚按钮做的事是**置顶**，该翻成「置顶」/「取消置顶」。
    // 换一个新 Key 只会更糟（没有译文的键在中文界面里直接露出英文原句），所以要改的是目录里这两行的
    // 值，不是这里的键名 —— 而 `.lproj/Localizable.strings` 本轮是红线。
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
