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
//     （ChatListView.swift:210-217）。这条绑定必须留在消息页内部，四栏壳才不会切断通知点开会话。
//     其余三栏里：通讯录与「我」只带行内 Sheet，由壳统一包 NavigationStack（:134、:152）；厢语
//     2026-11-20 起自己持有 `NavigationStack(path:)`，本轮起这一栏的根换成 `PopopxMeshPlazaRootView`
//     （自带根栈，落地即包内那份全屏广场，`PopopxCabinView.swift:218`），旧面板成了它的满高抽屉 ——
//     壳这里因此仍然只放裸页面（:148）：那条 async 推送要绑的 `path` 在抽屉里那一页自己身上。
//     「我 → 全部设置」那三个服务器子页的 `navigationDestination` 登记也挂在本栏的栈根（:159-165）：
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

// MARK: - 「全部设置」那棵栈的路径

/// 承载「全部设置」的那棵栈的路径持有者。两处宿主各 new 一份、互不共享：`MainTabView` 的「我」栏
/// 与 `UserPickerSheetView`（「添加朋友」→ 切身份 → 设置）。`PopopxSettingsView` 用
/// `@Environment(PopopxSettingsNavTrack.self)` 取用，**刻意不给默认值**：漏注入的宿主在开发期就崩，
/// 比留一行"点了不动"的死行好查。
///
/// 类型写在本文件而不是新文件：铁律禁止脚本改 `project.pbxproj`，新类型一律内聚进已编译文件。
///
/// 存在理由 —— 2026-11-20 真机走查第 2 轮结论：**登记位置不是那根杠杆**。
/// 「我 → 全部设置 → 中继与服务器」点下去只重画当前页、按返回才推入，两种写法都失败过：
/// ① 登记写在「全部设置」自己（`8dea049d3` 之前）② 登记上移到栈根（`8dea049d3`）。症状逐字相同，
/// 而 ProtocolServersView.swift:295-298 写明"同一类型只保留最靠近栈根的那份登记"，所以②才是正确位置。
/// 坏的不是解析，是 `NavigationLink(value:)` 这一跳的**激活**：它把"往栈的路径写一个值"和"按值找登记"
/// 绑在同一次点击里，点击一旦被行重建吃掉，值就留在待提交的事务里，下一次导航事件（返回）才冲出来。
/// 修法是把这一跳换成消息栏那条真机验证过的轨道同款的确定性推送：栈根持有显式路径
/// （`NavigationStack(path:)`），行体是普通 `Button`，点击只做一次状态赋值 —— 与
/// `ChatsListView.swift:209-212` 拿 `chatModel.chatId` 推开会话是同一个机制。
/// 再往下的四跳（yourServers / serverOperator / 协议服务器 / 聊天中继）仍是按值链接，由栈根那三个登记
/// 解析，它们与 `NetworkAndServers` 同处一个栈，是这条轨道唯一的按值段。
@MainActor
@Observable
final class PopopxSettingsNavTrack {
    var path = NavigationPath()
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

    /// 「我」栏那棵栈的路径：唯一一处按值轨道（服务器三页）由它承载，见 `PopopxSettingsNavTrack`。
    @State private var meTrack = PopopxSettingsNavTrack()

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

            // 厢语这一栏本轮起直接落在包内那一份全屏广场上：根是 `PopopxMeshPlazaRootView`
            // （`PopopxCabinView.swift`），它自己带根栈，壳这里仍然只放裸页面。旧厢语面板
            // （`PopopxCabinView`）不再是这一栏的根，而是根顶栏中间那一枚胶囊唤起的满高抽屉；
            // 抽屉里那一页继续自己持有 `NavigationStack(path:)`，理由没变，只是搬进了抽屉 ——
            // 它的私聊是"发出离线建联邀请之后再推一页"，动作是 async 的，只有绑在它自己栈上的
            // `path` 能在那之后推着走（`PopopxCabinView.swift:507` 那行 `NavigationStack(path: $path)`）；
            // 把它挂成根栈的一页要么两条导航条、要么那四处 `path.append` 全部落空，所以整块压在外面
            // 而不推进去。
            // 真机第 8 轮 · 任务一：这一栏全屏沉浸（底栏那四枚在根那一屏让开，由它自己声明），
            // 于是横切导航在这一栏只剩顶栏左上角那一枚返回键 —— 它写的就是下面这一份 `selection`。
            // 这里给绑定而不是新造一个路由对象：`selection` 本来就是选中栏的唯一事实（决定 3 与
            // 下面那条 `onChange(of: chatModel.chatId)` 写的都是它），再包一层 `@Observable` 就是
            // 第二个持有者；而 init 少传一个参数编译不过，比"按了不动"好查（同 `PopopxSettingsNavTrack`
            // 刻意不给默认值那条理由）。底栏的隐藏声明在它自己那一栏的内容里，不写在 `TabView` 上 ——
            // 挂 `TabView` 就得按 `selection` 算一个值，那一句会盖到 `ChatsListView.swift:268/275/285/405`
            // 那四处按页声明的 `.hidden` 上（前七轮真机走查认过的只有那四处这一种挂法）。
            PopopxMeshPlazaRootView(tabSelection: $selection)
                .tabItem { tabLabel(.cabin) }
                .tag(PopopxTab.cabin)

            NavigationStack(path: $meTrack.path) {
                PopopxMeView()
                    // 服务器三页的登记在栈根（口径同 NetworkAndServers.swift:214-216、
                    // ProtocolServersView.swift:295-298：同一类型只保留最靠近栈根的那份），
                    // 与 ChatListView.swift:120-128 那条旧轨道共用这三个类型、这三个函数。
                    // 「全部设置 → 中继与服务器」这一跳不再是按值链接，而是
                    // `Button { meTrack.path.append(.networkAndServers) }`，见 `PopopxSettingsNavTrack`。
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
            .environment(meTrack)
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
        // （PopopxContactsView.swift:243、:1067 → ChatModel.swift:113 写 :120），
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
