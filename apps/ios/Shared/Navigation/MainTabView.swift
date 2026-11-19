//
//  MainTabView.swift
//  POPOPX (iOS)
//
//  【第四阶段】底部四栏经典导航：消息 / 通讯录 / 厢语 / 我。
//
//  本工程此前没有底部导航 TabView：`Shared` 里 `TabView(selection:)` 只有 3 处，全是分页式内容轮播
//  （WhatsNewView.swift:819、ChatItemInfoView.swift:94、OnboardingCards.swift:146），主界面是
//  `ContentView` 直接铺 `ChatListView`。这个文件把根内容换成四栏壳，四个页面都由本阶段新建，
//  旧的 `Shared/Views/ChatList/ChatListView.swift` 原样保留、不再挂在根上。
//
//  三个结构决定：
//
//  1. **"消息"这一栏自己带 NavigationStack，其余三栏由本文件包装。**
//     打开会话的字段是 `ChatModel.chatId`（ChatModel.swift:411），写它的统一入口是
//     `ItemsModel.loadOpenChat(_:)`（ChatModel.swift:113，写点 :120）与 `loadOpenChatNoWait`（:139/:148），
//     调用方包括通知（NtfManager.swift:81）、deep link／建连（POPOPXAPI.swift:1091、:1825、:2182、:2849）、
//     附件打开（ChatModel.swift:1303）与新建联系人（CIMemberCreatedContactView.swift:29）。
//     而把该字段翻成"推送一页"的地方全工程只有一处：旧 ChatListView 的栈路径绑定
//     （ChatListView.swift:204-211）。这条绑定必须留在消息页内部，四栏壳才不会切断通知点开会话。
//     其余三栏里：通讯录与「我」只带行内 Sheet，由壳统一包 NavigationStack（:99、:111）；厢语
//     2026-11-20 起自己持有 `NavigationStack(path:)`（PopopxCabinView.swift:180），壳这里只放裸页面
//     （:107），因为它的广场频道页要靠自己的路径栈做程序化返回。
//     「我 → 全部设置」那三个服务器子页的 `navigationDestination` 登记也挂在本栏的栈根（:119-127）：
//     按值的链接只认承载它的那个栈，而设置页是从本页用目标闭包推进去的，闭包推进的页面自己写登记
//     一行都不生效 —— 这就是「中继服务器」点了只重画「全部设置」的根因。
//
//  2. **未读数字只用既有接口。** 消息栏的 tab 徽章走
//     `ChatModel.totalUnreadCountForAllUsers()`（ChatModel.swift:1187，含跨匿名身份聚合），
//     本文件不再算第二套未读口径；厢语/配对的待确认数在各自页面里呈现，不重复显示在标签上。
//
//  3. **跨栏点会话要先把栏切到"消息"。** 呈现会话的那棵栈在消息页内部（决定 1），所以其它页
//     调 `ItemsModel.shared.loadOpenChat(_:)` 之后，本文件用 `onChange(of: chatModel.chatId)`
//     把选中栏切过去；不接这一句，通讯录页的会话行在消息栏尚未访问过时不会有任何反应。
//
//  配色、字号、圆角一律取 `Shared/Theme/PopopxTheme.swift`（PopopxPalette / PopopxMetrics / PopopxType /
//  PopopxMaterial），此文件内没有裸色值或裸字号。标签写法刻意用 `TabView(selection:) + .tabItem`
//  （未废弃、iOS 17 可用），不用 iOS 18 才有的 `Tab {}` 构建器：主工程解析出的最低版本实测是
//  `IPHONEOS_DEPLOYMENT_TARGET = 17.0`（pbxproj 写 `$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)`，
//  `xcodebuild -showBuildSettings` 在 SDK iphonesimulator27.2 下解析为 17.0）；而
//  `PopopxMeshKit/Package.swift:9` 仍是 裁定 A 保留的 `.iOS(.v15)`，那是包侧的地板，够不到这里。
//  反过来，`tabBarMinimizeBehavior` 实测是 **iOS 26.0+**（门禁日志原话：
//  "'tabBarMinimizeBehavior' is only available in iOS 26.0 or newer"），17.0 的 target 上必须 gate，
//  见文件末尾 `popopxTabBarKept()`：那是一条真实存在的分支，不是死代码。
//
//  ⚠️ 另一个实测纠正：`ENABLE_PREVIEWS = NO` 并不豁免 `#Preview` 体的类型检查 —— Phase 4 门禁第一个
//  报错就出在厢语页的预览里。本文件的 `#Preview` 同样会被编译，改动它等同改动代码。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。铁律禁止脚本修改 project.pbxproj。
//

import SwiftUI
import POPOPXChat

// MARK: - 栏目

/// 四个栏目。`Hashable` 的枚举值直接作为 `TabView` 的 selection，避免用裸 Int 排序。
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

    /// 图标只承载识别，不承载颜色：选中色由 `tint` 统一给（§1.1 颜色只说通道语义）。
    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .contacts: return "person.2"
        case .cabin: return "antenna.radiowaves.left.and.right"
        case .me: return "person.crop.circle"
        }
    }
}

// MARK: - 四栏壳

@MainActor
struct MainTabView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @State private var selection: PopopxTab = .chats

    /// 「我 → 全部设置 → 中继与服务器」这条轨道的服务器内存副本，口径同 ChatListView.swift:83：
    /// 谁承载栈，谁就持有 `SaveableSettings`，`serversDestination` 的闭包绑的就是这一份。
    /// 页面自己在返回时问"要不要保存"（NetworkAndServers.swift:149），本文件不管保存。
    @StateObject private var meshServers = SaveableSettings()

    var body: some View {
        TabView(selection: $selection) {
            // 消息：自带 NavigationStack（见文件头决定 1）。
            ChatsListView()
                .tabItem { tabLabel(.chats) }
                .tag(PopopxTab.chats)
                .badge(unreadCount)

            NavigationStack {
                PopopxContactsView()
            }
            .tabItem { tabLabel(.contacts) }
            .tag(PopopxTab.contacts)

            // 厢语自带推送栈：这一页的私聊是"发出离线建联邀请之后再推一页"，动作是 async 的，
            // 只有绑定在自己栈上的 `path` 能在那之后推着走（`PopopxCabinView.swift:134`）。
            PopopxCabinView()
                .tabItem { tabLabel(.cabin) }
                .tag(PopopxTab.cabin)

            NavigationStack {
                PopopxMeView()
                    // 服务器三页的登记必须在栈根，不能由「全部设置」自己登记：那一页是「我」用
                    // 目标闭包推进去的，而闭包推进的页面自己写的 `navigationDestination` 不生效
                    // （口径同 NetworkAndServers.swift:214-216、spec/client/navigation.md
                    // "Servers pages push by value, registered at the stack root"）。
                    // 写在壳里，「我 → 全部设置 → 中继与服务器」这条新轨道就与
                    // ChatListView.swift:115-123 那条旧轨道共用同一组三个类型、同一个函数。
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
        // 决定 3：任何一栏点了会话，都要落到"消息"栏去呈现。
        // 会话页由 `ChatModel.chatId` 驱动，而把它翻成推送页的栈在消息页内部（文件头决定 1）；
        // 通讯录页按同一约定调 `ItemsModel.shared.loadOpenChat(_:)`
        // （PopopxContactsView.swift:226、:1067 → ChatModel.swift:113 写 :120），
        // 若消息栏还没被访问过，那棵栈还不存在，这个 onChange 就是唯一的接住点。
        .onChange(of: chatModel.chatId) { _, chatId in
            if chatId != nil { selection = .chats }
        }
    }

    /// 未读数：`ChatModel.chats`（ChatModel.swift:408）每次变更都会重算。口径直接复用既有函数
    /// `totalUnreadCountForAllUsers()`（ChatModel.swift:1187，见 spec/state.md#totalUnreadCountForAllUsers）：
    /// 它按每个会话的 `enableNtfs`（全部 / 仅提及）取相应计数，再累加非当前身份的 `users[].unreadCount`。
    /// 本文件不再算第二套未读口径。
    private var unreadCount: Int { chatModel.totalUnreadCountForAllUsers() }

    private func tabLabel(_ tab: PopopxTab) -> some View {
        Label(tab.title, systemImage: tab.symbol)
    }
}

// MARK: - 底栏行为

private extension View {
    /// iOS 26 起底部栏会在滚动时自动折叠；四栏经典导航要它一直站着。
    /// 17–25 上这个 API 不存在，而那些版本本来也没有折叠行为，所以原样返回。
    @ViewBuilder
    func popopxTabBarKept() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.never)
        } else {
            self
        }
    }
}

// MARK: - 文案

enum PopopxMainTabCopy {
    static let chats = "消息"
    static let contacts = "通讯录"
    static let cabin = "厢语"
    static let me = "我"
}

// MARK: - Previews

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
            .environmentObject(ChatModel.shared)
            .environmentObject(AppTheme.shared)
    }
}
