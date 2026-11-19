//
//  PopopxSettingsViews.swift
//  POPOPX (iOS)
//
//  【第四阶段】设置树的 popopx 版本：替换 Shared/Views/UserSettings/SettingsView.swift:305。
//  输入面与它逐字对齐（`showProgress`、`versionText`、`colorScheme`/`dismiss`/`ChatModel`/
//  `SceneDelegate` 环境），所以两处调用点各改一个词就能挂载：
//  Shared/Features/Me/PopopxMeView.swift:395 与 Shared/Views/ChatList/ChatListView.swift:107。
//
//  四条结构决定：
//
//  1. 本页不用 List，而是 ScrollView + 分组卡片（`PopopxSectionCard`）。推进去的子页面
//     （外观、隐私、通知、通话、服务器、数据、迁移、帮助、关于、版本）都在本次范围外，
//     本页只负责入口：每行一律是真实 init、真实环境对象、真实 Binding，没有占位行。
//     2026-11-20 起本页不再有「厢语离线组网」与「徽章与用量」两张卡：前者整块收进厢语页右上角
//     的 `PopopxCabinMeshSettingsSheet`，后者由「我」页顶部的动态徽章行与算力点钱包承接。
//  2. 配色、字号、圆角、间距只取 Shared/Theme/PopopxTheme.swift 的 token；行控件按
//     Shared/Components 的原子库口径自己组，命中区由 `PopopxMetrics.minHitTarget` 兜住 44pt。
//     本页因此不读全 app 的主题对象 —— 子页面仍带着它们自己的背景修饰，那一次收敛另开一刀。
//  3. 服务器那一行按值推送（`ServersDestination`），但登记不在本页：本页是从「我」页用目标闭包
//     推进来的，闭包推进的页面自己写 `navigationDestination` 一行都不生效，「中继服务器」点了
//     只会重画「全部设置」根页面。三个登记 2026-11-20 上移到栈根 Shared/Navigation/MainTabView.swift:119-127，
//     与 ChatListView.swift:115-123 那条旧轨道共用同一组三个类型、同一个 `serversDestination(...)`。
//  4. 三行 `@AppStorage` 开关写的就是子页面同一个 key，不是第二套状态：屏幕保护、链接去跟踪、
//     通话强制中继。`@AppStorage` 自己跟随 UserDefaults 变化，两边永远同步。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖进 POPOPX (iOS) target —— 铁律禁止脚本改 project.pbxproj。
//

import SwiftUI
import StoreKit
import POPOPXChat

// MARK: - 根页面

@MainActor
struct PopopxSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var chatModel: ChatModel
    @EnvironmentObject private var sceneDelegate: SceneDelegate

    /// `MigrateFromDevice` 通过它把迁移中的进度报回本页并盖住整屏（旧 SettingsView.swift:312/318）。
    @State private var showProgress: Bool = false

    var versionText: String? = appVersion

    /// 与 PrivacySettings.swift:27/75、:18/88、CallSettings.swift:15/31 同一批 key。
    @AppStorage(DEFAULT_PRIVACY_PROTECT_SCREEN) private var protectScreen = false
    @AppStorage(GROUP_DEFAULT_PRIVACY_SANITIZE_LINKS, store: groupDefaults) private var sanitizeLinks = false
    @AppStorage(DEFAULT_WEBRTC_POLICY_RELAY) private var webrtcPolicyRelay = true

    /// 外部只认两种写法：`PopopxSettingsView()` 与 `PopopxSettingsView(versionText:)`。
    /// 写显式 init 是为了让 `@State`/包装属性保持 private。
    init(versionText: String? = appVersion) {
        self.versionText = versionText
    }

    var body: some View {
        ZStack {
            settingsTree
            if showProgress {
                progressOverlay
            }
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.pageTitle)
        .toolbarBackground(PopopxMaterial.bar, for: .navigationBar)
        // 「中继与服务器」那一行按值推送（`NavigationLink(value:)`，见 networkCard），而按值的链接
        // 只认"承载它的那个栈"的登记：本页是从「我」页用目标闭包推进来的，闭包推进的页面自己写
        // `navigationDestination` 一行都不生效（口径同 NetworkAndServers.swift:214-216、
        // spec/client/navigation.md "Servers pages push by value, registered at the stack root"）。
        // 所以这三个登记 2026-11-20 上移到 Shared/Navigation/MainTabView.swift:119-127，与
        // ChatListView.swift:115-123 那条旧轨道共用同一组三个类型、同一个 `serversDestination(...)`。
        // 这里留着注释，是为了下一个加服务器子页的人不再往本页写登记。
    }

    private var settingsTree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                headerCard
                appearanceCard
                privacyCard
                callsAndNtfsCard
                networkCard
                dataCard
                helpCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
    }

    // MARK: 顶部：版本与双色语言

    private var headerCard: some View {
        PopopxSectionCard {
            HStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
                // 字标有浅色与深色两套图，这一行是全页唯一必须读 colorScheme 的地方；
                // resizable 的图必须给外框上限，否则它会把整张卡撑开。
                Image(PopopxBrandAsset.wordmark(for: colorScheme))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(
                        maxWidth: PopopxMetrics.space2XL * 3,
                        maxHeight: PopopxMetrics.spaceL,
                        alignment: .leading
                    )
                    .accessibilityHidden(true)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Text(verbatim: "v\(versionText ?? "?") (\(appBuild ?? "?"))")
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PopopxSettingsDivider()

            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                legendChip(
                    systemImage: "lock.shield.fill",
                    title: Copy.legendOnline,
                    fill: PopopxPalette.brand,
                    ink: PopopxPalette.onBrand
                )
                legendChip(
                    systemImage: "antenna.radiowaves.left.and.right",
                    title: Copy.legendMesh,
                    fill: PopopxPalette.mesh,
                    ink: PopopxPalette.onMesh
                )
                Text(Copy.legendNote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendChip(systemImage: String, title: String, fill: Color, ink: Color) -> some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: systemImage)
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(ink)
                .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                .background(fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                .accessibilityHidden(true)
            Text(title)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.label)
            Spacer(minLength: PopopxMetrics.spaceXS)
        }
    }

    // MARK: 外观

    private var appearanceCard: some View {
        PopopxSectionCard(Copy.groupAppearance) {
            PopopxSettingsRowLink(
                Copy.appearanceRow,
                value: appearanceValue,
                systemImage: "sun.max",
                enabled: chatModel.chatRunning == true
            ) {
                AppearanceSettings()
                    .navigationTitle(Copy.appearanceRow)
            }
        }
    }

    /// 行尾写的就是 `currentThemeDefault` 里的真值（旧 SettingsView.swift:239 那个 `StringDefault`），
    /// 不是本页记住的某个布尔。
    private var appearanceValue: String {
        switch currentThemeDefault.get() {
        case DefaultTheme.SYSTEM_THEME_NAME: return Copy.themeSystem
        case DefaultTheme.LIGHT.themeName: return Copy.themeLight
        case DefaultTheme.DARK.themeName: return Copy.themeDark
        case DefaultTheme.POPOPX.themeName: return Copy.themePopopx
        case DefaultTheme.BLACK.themeName: return Copy.themeBlack
        default: return Copy.themeCustom
        }
    }

    // MARK: 隐私与安全

    private var privacyCard: some View {
        PopopxSectionCard(Copy.groupPrivacy) {
            PopopxSettingsRowLink(
                Copy.privacyRow,
                systemImage: "lock.shield",
                enabled: chatModel.chatRunning == true
            ) {
                PrivacySettings()
                    .navigationTitle(Copy.privacyRow)
            }
            PopopxSettingsDivider()
            PopopxToggleRow(
                Copy.protectScreenRow,
                note: Copy.protectScreenNote,
                systemImage: "eye.slash",
                tint: .neutral,
                isOn: $protectScreen
            )
            PopopxSettingsDivider()
            PopopxToggleRow(
                Copy.sanitizeLinksRow,
                note: Copy.sanitizeLinksNote,
                systemImage: "link.badge.plus",
                tint: .neutral,
                isOn: $sanitizeLinks
            )
        }
    }

    // MARK: 通知与通话

    private var callsAndNtfsCard: some View {
        PopopxSectionCard(Copy.groupCalls) {
            PopopxSettingsRowLink(
                Copy.notificationsRow,
                value: notificationValue,
                systemImage: notificationIcon,
                enabled: chatModel.chatRunning == true
            ) {
                NotificationsView()
                    .navigationTitle(Copy.notificationsRow)
            }
            PopopxSettingsDivider()
            PopopxSettingsRowLink(
                Copy.callsRow,
                systemImage: "video",
                enabled: chatModel.chatRunning == true
            ) {
                CallSettings()
                    .navigationTitle(Copy.callsRow)
            }
            PopopxSettingsDivider()
            PopopxToggleRow(
                Copy.relayCallsRow,
                note: webrtcPolicyRelay ? Copy.relayCallsNoteOn : Copy.relayCallsNoteOff,
                systemImage: "network",
                tint: .neutral,
                isOn: $webrtcPolicyRelay
            )
        }
    }

    /// 通知模式来自 `chatModel.notificationMode`（ChatModel.swift:435），三个 case 全覆盖。
    private var notificationValue: String {
        switch chatModel.notificationMode {
        case .off: return Copy.ntfsOff
        case .periodic: return Copy.ntfsPeriodic
        case .instant: return Copy.ntfsInstant
        }
    }

    /// 图标跟着模式换，但不引入第二套配色：旧页那三处系统黄/绿（SettingsView.swift:606-610）
    /// 不是 token，这里统一落回中性色。
    private var notificationIcon: String {
        switch chatModel.notificationMode {
        case .off: return "bell.slash"
        case .periodic: return "timer"
        case .instant: return "bolt.fill"
        }
    }

    // MARK: 网络与服务器

    private var networkCard: some View {
        PopopxSectionCard(Copy.groupNetwork, footnote: Copy.networkFootnote) {
            NavigationLink(value: ServersDestination.networkAndServers) {
                PopopxSettingsRowLabel(
                    title: Copy.serversRow,
                    systemImage: "externaldrive.connected.to.line.below",
                    tint: .brand
                )
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle())
            .accessibilityHint(Text(verbatim: Copy.openHint))
            .disabled(chatModel.chatRunning != true)
            .opacity(chatModel.chatRunning == true ? 1 : 0.45)
        }
    }

    // MARK: 数据与迁移

    private var dataCard: some View {
        PopopxSectionCard(Copy.groupData, footnote: Copy.dataFootnote) {
            PopopxSettingsRowLink(
                Copy.chatDataRow,
                systemImage: chatModel.chatDbEncrypted == false ? "exclamationmark.triangle.fill" : "internaldrive",
                tint: chatModel.chatDbEncrypted == false ? .danger : .neutral
            ) {
                DatabaseView(dismissSettingsSheet: dismiss, chatItemTTL: chatModel.chatItemTTL)
                    .navigationTitle(Copy.chatDataRow)
            }
            PopopxSettingsDivider()
            PopopxSettingsRowLink(
                Copy.migrateRow,
                note: showProgress ? Copy.migrateRunning : nil,
                systemImage: "tray.and.arrow.up"
            ) {
                MigrateFromDevice(showProgressOnSettings: $showProgress)
                    .navigationTitle(Copy.migrateRow)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: 帮助与关于

    private var helpCard: some View {
        PopopxSectionCard(Copy.groupHelp) {
            // 「怎么使用」与「最近更新」两行 2026-11-20 删：前者推的 `ChatHelp` 与后者推的
            // `WhatsNewView` 都还在旧轨道上有人挂（消息栏与首次启动流程），设置树里这一份是第二个入口，
            // 说的同一件事却比原页面少一层上下文。关于/版本/评价三行留着。
            PopopxSettingsRowLink(Copy.aboutRow, systemImage: "info.circle") {
                POPOPXInfo(onboarding: false)
                    .navigationBarTitle(Copy.aboutRow, displayMode: .inline)
            }
            PopopxSettingsDivider()
            PopopxSettingsRowLink(
                Copy.versionRow,
                value: versionText.map { "v\($0)" },
                systemImage: "number"
            ) {
                VersionView()
                    .navigationTitle(Copy.versionRow)
            }
            PopopxSettingsDivider()
            // 裁定 4：暂时隐藏"提问与提建议"入口（popopxTeamURL 当前指向上游 SimpleX 中继，非 POPOPX 自有服务器）。
            // 后续接入 popopx 官方通道后再开放。askTeam() 函数保留，按钮注释掉。
            // PopopxSettingsActionButton(
            //     Copy.askTeamRow,
            //     note: Copy.askTeamNote,
            //     systemImage: "envelope",
            //     enabled: chatModel.chatRunning == true
            // ) {
            //     askTeam()
            // }
            // PopopxSettingsDivider()
            PopopxSettingsActionButton(
                Copy.rateRow,
                note: Copy.rateNote,
                systemImage: "star"
            ) {
                requestReview()
            }
        }
    }

    /// 团队联系方式是 app 自己的链接：前台 `UIApplication.open` 会被系统丢掉，所以照旧走应用内连接流程
    /// （口径同旧 SettingsView.swift:516-523，`popopxTeamURL` 见 SettingsView.swift:23）。
    private func askTeam() {
        dismiss()
        DispatchQueue.main.async {
            chatModel.appOpenUrl = popopxTeamURL
        }
    }

    private func requestReview() {
        guard let scene = sceneDelegate.windowScene else { return }
        SKStoreReviewController.requestReview(in: scene)
    }

    // MARK: 迁移进度遮罩

    private var progressOverlay: some View {
        ZStack {
            PopopxPalette.base
                .opacity(0.72)
            ProgressView()
                .controlSize(.large)
                .tint(PopopxPalette.brand)
                .padding(PopopxMetrics.spaceL)
                .background(PopopxPalette.cardHigh, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Copy.migrateRunning))
    }
}

// MARK: - 行

/// 一行的内容本体：不是 Button，链接与按钮各自决定点击归谁。
@MainActor
struct PopopxSettingsRowLabel: View {
    let title: String
    var value: String?
    var note: String?
    var systemImage: String?
    var assetImage: String?
    var tint: PopopxIconTint = .neutral
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            artwork
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PopopxMetrics.spaceXS)
            if let value {
                Text(value)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .accessibilityHidden(true)
            }
        }
    }

    /// 两种图形共用同一个 `spaceXL` 外框（PopopxTheme.swift:162），也和原子库的
    /// `PopopxIconBadge` 同尺寸（PopopxControls.swift:315-327）：换图标不会让行高跳一下。
    @ViewBuilder private var artwork: some View {
        if let assetImage {
            Image(assetImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                .accessibilityHidden(true)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(tint.ink)
                .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                .background(tint.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                .accessibilityHidden(true)
        }
    }
}

/// 推一个既有页面。
@MainActor
private struct PopopxSettingsRowLink<Destination: View>: View {
    private let label: PopopxSettingsRowLabel
    private let enabled: Bool
    private let destination: () -> Destination

    init(
        _ title: String,
        value: String? = nil,
        note: String? = nil,
        systemImage: String?,
        assetImage: String? = nil,
        tint: PopopxIconTint = .neutral,
        enabled: Bool = true,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.label = PopopxSettingsRowLabel(
            title: title,
            value: value,
            note: note,
            systemImage: systemImage,
            assetImage: assetImage,
            tint: tint
        )
        self.enabled = enabled
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            label
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(verbatim: Copy.openHint))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 不导航、只做事的一行（评分、联系团队）。
@MainActor
private struct PopopxSettingsActionButton: View {
    private let label: PopopxSettingsRowLabel
    private let enabled: Bool
    private let action: () -> Void

    init(
        _ title: String,
        value: String? = nil,
        note: String? = nil,
        systemImage: String,
        tint: PopopxIconTint = .neutral,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.label = PopopxSettingsRowLabel(
            title: title,
            value: value,
            note: note,
            systemImage: systemImage,
            tint: tint,
            showsChevron: false
        )
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 卡片内的分隔线：一条 `PopopxMetrics.divider` 高的发丝线，上下各留 `spaceXS`。
private struct PopopxSettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - 文案

/// 页面上每一句中文只在这里出现一次。
private enum Copy {
    static let pageTitle = "设置"
    static let openHint = "打开"

    // 顶部
    static let legendOnline = "在线：走 SMP 中继"
    static let legendMesh = "离线：厢语蓝牙组网"
    static let legendNote = "同一行只会用一种颜色：哪条通道搬运了它，这一点必须一眼分得清。"

    // 外观
    static let groupAppearance = "外观"
    static let appearanceRow = "外观与图标"
    static let themeSystem = "跟随系统"
    static let themeLight = "浅色"
    static let themeDark = "深色"
    static let themePopopx = "popopx"
    static let themeBlack = "纯黑"
    static let themeCustom = "自定义主题"

    // 隐私与安全
    static let groupPrivacy = "隐私与安全"
    static let privacyRow = "隐私设置"
    static let protectScreenRow = "退到后台时打码"
    static let protectScreenNote = "应用不在前台时，整个界面替换成占位条：切换器预览与截图里读不到聊天内容，切回来即恢复。"
    static let sanitizeLinksRow = "去掉链接里的跟踪参数"
    static let sanitizeLinksNote = "编辑消息时就把要发出去的链接去掉已知的跟踪字段，对方收到的那条不再带着你的来源。"

    // 通知与通话
    static let groupCalls = "通知与通话"
    static let notificationsRow = "通知"
    static let ntfsOff = "不经服务器"
    static let ntfsPeriodic = "定时唤醒"
    static let ntfsInstant = "即时推送"
    static let callsRow = "音频与视频通话"
    static let relayCallsRow = "通话强制走中继"
    static let relayCallsNoteOn = "中继保护你的 IP，但它能看到通话时长。"
    static let relayCallsNoteOff = "只在必要时用中继，对方有可能看到你的 IP。"

    // 网络与服务器
    static let groupNetwork = "网络与服务器"
    static let serversRow = "中继与服务器"
    static let networkFootnote = "改完在返回时问一次要不要保存；不保存就沿用上一次的核心配置。"

    // 数据与迁移
    static let groupData = "数据与迁移"
    static let chatDataRow = "聊天数据"
    static let dataFootnote = "保留期、导出与加密都在这里；迁移会把整个本机身份交给另一台设备，中途不要退出。"
    static let migrateRow = "迁移到另一台设备"
    static let migrateRunning = "迁移进行中"

    // 帮助与关于
    static let groupHelp = "帮助与关于"
    static let aboutRow = "关于 popopx"
    static let versionRow = "版本"
    static let askTeamRow = "提问与提建议"
    static let askTeamNote = "在应用内连接这个账号，不开浏览器，也不走邮件。"
    static let rateRow = "给应用评分"
    static let rateNote = "由系统弹窗提交，一年里只会弹几次；没弹也不影响任何功能。"
}

// MARK: - Previews

#if DEBUG
/// 画布只呈现本页根视图：它自己读的环境就这两个。推进去的子页面另外要全 app 的主题对象，
/// 那是那条红线名单禁止在本页出现的名字，也不该在预览里造一个假的 —— 所以预览不覆盖子页面。
/// `SceneDelegate()` 在这里只为满足环境查找，它的 `windowScene` 是 nil，评分那一行会自己退出。
struct PopopxSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxSettingsView(versionText: "7.1")
        }
        .environmentObject(ChatModel.shared)
        .environmentObject(SceneDelegate())
    }
}
#endif
