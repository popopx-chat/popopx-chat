//
//  PopopxSettingsViews.swift
//  POPOPX (iOS)
//
//  【第四阶段】设置树的 popopx 版本：替换 Shared/Views/UserSettings/SettingsView.swift:305。
//  输入面与它逐字对齐（`showProgress`、`versionText`、`colorScheme`/`dismiss`/`ChatModel`/
//  `SceneDelegate` 环境），所以两处调用点各改一个词就能挂载：
//  Shared/Features/Me/PopopxMeView.swift:418 与 Shared/Views/ChatList/ChatListView.swift:112。
//
//  四条结构决定：
//
//  1. 本页不用 List，而是 ScrollView + 分组卡片（`PopopxSectionCard`）。推进去的子页面（隐私的两个开关、
//     通知、通话、服务器、数据、迁移）都在本次范围外，本页只负责入口：每行一律是真实 init、真实环境对象、
//     真实 Binding，没有占位行。
//     2026-11-20 起本页不再有「厢语离线组网」与「徽章与用量」两张卡：前者整块收进厢语页右上角
//     的 `PopopxCabinMeshSettingsSheet`，后者由「我」页顶部的动态徽章行与算力点钱包承接。
//     真机走查 三.1/三.4 再拿掉两张卡，本页只留入口，不留第二处同一个目的地：
//       · 「外观」整组 2026-11 曾上移到「我」栏的常用组，真机第 6 轮二.1 又落回本页
//         （`appearanceCard`，卡名与两行说法走英文原句 Key）；行尾那个主题名一直在本文件的
//         `PopopxSettingsValues.themeName`，两边读同一份 `currentThemeDefault`，不分第二套读数。
//       · 「帮助与关于」由卡片升格成真实页面 `PopopxHelpView`（同样只从「我」栏进），并补上
//         开源地址与隐私协议两行；`PopopxDisplayLanguageView` 是同一次升格带出的「显示语言」页。
//       · `privacyCard` 整卡 2026-11-20 删（真机第 6 轮二.2）：那张卡上剩的屏幕保护与链接去跟踪两枚
//         开关与 `PrivacySettings.swift:75`/`:88` 是同一批状态，现在直接摆在「我」栏的防线卡上。
//     · 真机第 8 轮 · 任务六（层级重排）：「网络与服务器」这张卡由一个入口变成三个平级入口。
//         「高级网络设置」与「网络连接」原先埋在「中继与服务器」那一页（`NetworkAndServers`）内部，
//         现在上提到这一级、原处删除；少一层，两条说法与那页剩下的行都没变（明细见 `networkCard`）。
//  2. 配色、字号、圆角、间距只取 Shared/Theme/PopopxTheme.swift 的 token；行控件按
//     Shared/Components 的原子库口径自己组，命中区由 `PopopxMetrics.minHitTarget` 兜住 44pt。
//     本页因此不读全 app 的主题对象 —— 子页面仍带着它们自己的背景修饰，那一次收敛另开一刀。
//  3. 「中继与服务器」那一行**不是**按值链接，而是普通 `Button`：点击只做一次
//     `settingsTrack.path.append(ServersDestination.networkAndServers)`。真机走查第 2 轮（2026-11-20）
//     的结论是登记位置不是那根杠杆 —— 登记写在本页（`8dea049d3` 之前）与上移到栈根（`8dea049d3`）
//     症状逐字相同（点了只重画本页、按返回才推入），而 ProtocolServersView.swift:295-298 写明
//     同一类型只保留最靠近栈根的那份登记，所以栈根才是正确位置；坏的是 `NavigationLink(value:)`
//     这一跳的激活。路径持有者是 `PopopxSettingsNavTrack`（Shared/Navigation/MainTabView.swift），
//     两个宿主各持一份并注入：MainTabView.swift:174 的「我」栏、ChatListView.swift:98 的
//     UserPickerSheetView。三页本身的登记仍留在各自栈根（ServersDestination / ProtocolServerSelection /
//     ChatRelaySelection），本页不再写登记，也不留注释误导下一个人。
//  4. 三行 `@AppStorage` 开关写的就是子页面同一个 key，不是第二套状态：屏幕保护、链接去跟踪、
//     通话强制中继。`@AppStorage` 自己跟随 UserDefaults 变化，两边永远同步。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖进 POPOPX (iOS) target —— 铁律禁止脚本改 project.pbxproj。
//

import SwiftUI
import UIKit
import StoreKit
import POPOPXChat

// MARK: - 根页面

@MainActor
struct PopopxSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var chatModel: ChatModel

    /// 宿主栈的路径。只用于「中继与服务器」那一跳的确定性推送，见文件头决定 3。
    @Environment(PopopxSettingsNavTrack.self) private var settingsTrack

    /// `MigrateFromDevice` 通过它把迁移中的进度报回本页并盖住整屏（旧 SettingsView.swift:312/318）。
    @State private var showProgress: Bool = false

    var versionText: String? = appVersion

    /// 真机第 6 轮二.2 之后这张树里只剩通话这一枚：打码与去跟踪两枚连同那张「隐私与安全」卡
    /// 一起并进「我」栏的隐私与安全防线（`PopopxMeView.swift` 的 `securityEntries`，两个键本身不变）。
    /// 与 CallSettings.swift:15/31 同一批 key。
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
    }

    private var settingsTree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                headerCard
                appearanceCard
                callsAndNtfsCard
                networkCard
                dataCard
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

    // MARK: 外观与语言

    /// 真机第 6 轮二.1：这一组 2026-11 曾被整块升到「我」栏的常用组，现在落回设置树，位置就在
    /// 顶部卡之后 —— 也就是它本来在的位置。目的地、`ThemedBackground`、可用性门（`AppearanceSettings`
    /// 仍要求会话在跑）与行尾读数逐字照搬；`PopopxSettingsValues.themeName`/`languageName`
    /// 两个读数回到它们的供应者同一个文件里，跨文件引用少了一处。
    private var appearanceCard: some View {
        PopopxSectionCard(PopopxGeneralCopy.groupAppearance) {
            PopopxSettingsRowLink(
                PopopxGeneralCopy.appearanceRow,
                value: PopopxSettingsValues.themeName,
                systemImage: "sun.max",
                enabled: chatModel.chatRunning == true,
                hint: PopopxGeneralCopy.openHint
            ) {
                AppearanceSettings()
                    .navigationTitle(PopopxGeneralCopy.appearanceRow)
                    .modifier(ThemedBackground(grouped: true))
            }
            PopopxSettingsDivider()
            // 语言页不需要会话在跑：它开的是系统设置里本 app 的那一页，所以这一行既不 gating 也不禁用。
            PopopxSettingsRowLink(
                PopopxGeneralCopy.languageRow,
                systemImage: "character.bubble",
                hint: PopopxGeneralCopy.openHint
            ) {
                PopopxDisplayLanguageView()
                    .navigationTitle(PopopxGeneralCopy.languageRow)
            }
        }
    }

    // MARK: 通知与通话

    private var callsAndNtfsCard: some View {
        PopopxSectionCard(Copy.groupCalls) {
            // 真机第 6 轮二.1：本身份聊天偏好从「我」栏的常用组落回这里，紧挨着它管的那两件事
            // ——通知与通话。目的地与三个入参照旧，照 `ChatListView.swift:100-103` 的既有挂载点原样给。
            if let user = chatModel.currentUser {
                PopopxSettingsRowLink(
                    PopopxGeneralCopy.chatPreferences,
                    value: user.showNtfs ? PopopxGeneralCopy.notifyOn : PopopxGeneralCopy.notifyOff,
                    systemImage: "slider.horizontal.3",
                    hint: PopopxGeneralCopy.openHint
                ) {
                    PreferencesView(
                        profile: user.profile,
                        preferences: user.fullPreferences,
                        currentPreferences: user.fullPreferences
                    )
                    .navigationTitle(PopopxGeneralCopy.chatPreferences)
                    .modifier(ThemedBackground(grouped: true))
                }
                PopopxSettingsDivider()
            }
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

    /// 真机第 8 轮 · 任务六（层级重排）：这张卡从一个入口变成三个平级入口。
    /// 「Advanced network settings」与「Network connection」两行原先埋在「中继与服务器」那一页
    /// （`NetworkAndServers`）的最后两个 Section 里，现在上提到这一级并从原处删除；那一页只剩
    /// 服务器本身的行（预设服务器 / 你的服务器 / 保存）。
    /// 三行的推进机制不是随手选的，各有一条理由：
    /// · 「中继与服务器」= 普通 `Button` + 一次 `settingsTrack.path.append`（文件头决定 3）——
    ///   换成 `NavigationLink(value:)` 在真机上点了只重画本页，按返回才推入。
    /// · 「高级网络设置」= 目的地闭包的 `NavigationLink`（`PopopxSettingsRowLink`），与本页其余
    ///   每一行同一个机制：它不往路径里写值、由登记解析，所以不吃决定 3 那根坏掉的杠杆，点了即时推入。
    ///   可用性与原来一致：那一页要读写网络配置，会话没在跑就禁用（同 `callsAndNtfsCard` 的口径）。
    /// · 「网络连接」= 只读状态行。它在原来那一页里也不是入口而是一段读数，扁平化不给它造一个
    ///   不存在的去处，所以不给 chevron、不接点击。
    private var networkCard: some View {
        PopopxSectionCard(Copy.groupNetwork, footnote: Copy.networkFootnote) {
            // 普通 Button + 一次路径赋值，不是 `NavigationLink(value:)`：真机上那一跳点了只重画本页。
            Button {
                settingsTrack.path.append(ServersDestination.networkAndServers)
            } label: {
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
            PopopxSettingsDivider()
            PopopxSettingsRowLink(
                PopopxNetworkCopy.advancedRow,
                systemImage: "network",
                tint: .brand,
                enabled: chatModel.chatRunning == true,
                hint: PopopxGeneralCopy.openHint
            ) {
                AdvancedNetworkSettings()
                    .navigationTitle(PopopxNetworkCopy.advancedTitle)
                    .modifier(ThemedBackground(grouped: true))
            }
            PopopxSettingsDivider()
            PopopxNetworkStatusRow(
                type: chatModel.networkInfo.networkType,
                online: chatModel.networkInfo.online
            )
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

// MARK: - 行尾的两个共享读数

/// 「我」栏的常用组与本页都要在行尾写同一个真值，所以读数只留这一份，不分两套状态。
/// 词本身仍出自本文件的 `Copy`：那几个是设置树里既有的说法，换个页面读也是同一句，
/// 不会出现同一件事两处各写一套。
enum PopopxSettingsValues {
    /// 行尾写的就是 `currentThemeDefault` 里的真值（旧 SettingsView.swift:239 那个 `StringDefault`），
    /// 不是某一页记住的某个布尔。
    @MainActor static var themeName: String {
        switch currentThemeDefault.get() {
        case DefaultTheme.SYSTEM_THEME_NAME: return Copy.themeSystem
        case DefaultTheme.LIGHT.themeName: return Copy.themeLight
        case DefaultTheme.DARK.themeName: return Copy.themeDark
        case DefaultTheme.POPOPX.themeName: return Copy.themePopopx
        case DefaultTheme.BLACK.themeName: return Copy.themeBlack
        default: return Copy.themeCustom
        }
    }

    /// 本 app 当前用哪一种语言。推导与 `AppearanceSettings` 原先那一行逐字相同
    /// （系统给这个 app 选定的第一个本地化 + 它的可读语言名），但这里是自己算的，
    /// 不去读那个页面里的 private 计算属性。
    @MainActor static var languageName: String {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forIdentifier: lang)?.localizedCapitalized ?? lang
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
    private let hint: String
    private let destination: () -> Destination

    /// `hint` 是 VoiceOver 那一句"打开"：设置树里沿用本文件的中文常量，而升格出去的
    /// `PopopxHelpView` 走 Key 口径，所以它由调用方给，不在这里替两个页面决定说法。
    init(
        _ title: String,
        value: String? = nil,
        note: String? = nil,
        systemImage: String?,
        assetImage: String? = nil,
        tint: PopopxIconTint = .neutral,
        enabled: Bool = true,
        hint: String = Copy.openHint,
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
        self.hint = hint
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
        .accessibilityHint(Text(verbatim: hint))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 不导航、只做事的一行（评分、开源地址、联系团队、弹出文书）。
/// 它没有 `hint` 参数：这一行本来就不导航，去处由 `note` 自己说清。
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

/// 只读的一行：不导航、不按钮，行尾写一份真值读数加状态点。
/// 本轮带出它的是「网络连接」——那一行在 `NetworkAndServers` 里本来就不是入口，而是一段读数
/// （类型 + 在线点），上提到这里也不给它编一个不存在的去处。
/// 整行合成一个 VoiceOver 元素：读数与状态各归 `accessibilityValue` 与标题，不是一堆碎片。
@MainActor
private struct PopopxNetworkStatusRow: View {
    let type: UserNetworkType
    let online: Bool

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: symbol)
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxIconTint.neutral.ink)
                .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                .background(PopopxIconTint.neutral.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                .accessibilityHidden(true)
            Text(PopopxNetworkCopy.connectionRow)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopopxMetrics.spaceXS)
            Text(type.text)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            Circle()
                .fill(online ? PopopxIconTint.success.fill : PopopxIconTint.danger.fill)
                .frame(width: PopopxMetrics.spaceXS, height: PopopxMetrics.spaceXS)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(PopopxNetworkCopy.connectionRow))
        .accessibilityValue(
            Text(type.text)
                + Text(verbatim: " · ")
                + Text(verbatim: online ? PopopxNetworkCopy.online : PopopxNetworkCopy.offline)
        )
    }

    /// 图标跟着真实链路类型换：这份类型出自 `NetworkObserver.swift:44` 的接口判定，
    /// 状态点也一样，不在这里另算一套"有没有网"。
    private var symbol: String {
        switch type {
        case .wifi: "wifi"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .ethernet: "cable.connector"
        case .other: "network"
        case .none: "wifi.slash"
        }
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

// MARK: - 帮助与关于（三.4：由设置树里的一张卡升格成真实页面）

/// 原先那张 helpCard 的三个目的地原样搬过来，另加开源地址与隐私协议两行。
/// 页面只从「我」栏的常用组进，设置树里不再有第二份 —— 本页自己不带 `navigationTitle`，
/// 标题由推它的那一行给，避免两处写同一个说法。
@MainActor
struct PopopxHelpView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.dismiss) private var dismiss

    @State private var toast = PopopxToastModel()
    /// 隐私协议全文的开关。类型、Sheet、正文与引导第 4 屏逐字同一个：`PopopxLegalDocumentSheet`
    /// 是离线内置文书，这里不加载任何网页，也不复制第二份正文。
    @State private var document: PopopxLegalDocumentSheet.Document?

    /// 仓库地址是事实，不是文案：这一串不进任何译本，两处用的都是同一个常量。
    private static let repositoryURLString = "https://github.com/popopx-chat/popopx-chat"
    private static let repositoryURL = URL(string: PopopxHelpView.repositoryURLString)!

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                PopopxSectionCard {
                    PopopxSettingsRowLink(
                        PopopxHelpCopy.aboutRow,
                        systemImage: "info.circle",
                        hint: PopopxHelpCopy.openHint
                    ) {
                        POPOPXInfo(onboarding: false)
                            .navigationBarTitle(PopopxHelpCopy.aboutRow, displayMode: .inline)
                    }
                    PopopxSettingsDivider()
                    PopopxSettingsRowLink(
                        PopopxHelpCopy.versionRow,
                        value: appVersion.map { "v\($0)" },
                        systemImage: "number",
                        hint: PopopxHelpCopy.openHint
                    ) {
                        VersionView()
                            .navigationTitle(PopopxHelpCopy.versionRow)
                    }
                    PopopxSettingsDivider()
                    // 「怎么使用」与「最近更新」两行 2026-11-20 删：前者推的 `ChatHelp` 与后者推的
                    // `WhatsNewView` 都还在旧轨道上有人挂（消息栏与首次启动流程），设置树里这一份是第二个入口，
                    // 说的同一件事却比原页面少一层上下文。关于/版本/评价三行留着。
                    // 裁定 4：暂时隐藏"提问与提建议"入口（popopxTeamURL 当前指向上游默认中继，非 POPOPX 自有服务器）。
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
                        PopopxHelpCopy.rateRow,
                        note: PopopxHelpCopy.rateNote,
                        systemImage: "star"
                    ) {
                        requestReview()
                    }
                    PopopxSettingsDivider()
                    repositoryRow
                    PopopxSettingsDivider()
                    // 隐私协议是一本文书，不是一个页面，所以这一行不画 chevron：点开是 Sheet。
                    PopopxSettingsActionButton(
                        PopopxOnboardingCopy.privacyPolicy,
                        note: PopopxHelpCopy.privacyNote,
                        systemImage: "doc.text.fill"
                    ) {
                        PopopxHaptics.selection()
                        document = .privacy
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
        .toolbarBackground(PopopxMaterial.bar, for: .navigationBar)
        .sheet(item: $document) { doc in
            PopopxLegalDocumentSheet(document: doc)
                .presentationDetents([.medium, .large])
        }
        .popopxToast(toast)
    }

    /// 开源地址：整行点开系统浏览器，右端一枚复制键把同一串地址放进剪贴板并回执一句。
    /// 两个动作是并排的兄弟而不是藏起来的手势（长按/滑动手势在这一族行里没有任何提示）。
    /// 行尾那一格就是地址本身；`PopopxSettingsRowLabel` 的 value 最多两行，窄语种下有可能
    /// 被截断，所以完整值交给复制键兜住 —— 看不全也拿得走。
    private var repositoryRow: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Button(action: openRepository) {
                PopopxSettingsRowLabel(
                    title: PopopxHelpCopy.repositoryRow,
                    value: Self.repositoryURLString,
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    showsChevron: false
                )
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle())
            .accessibilityHint(Text(verbatim: PopopxHelpCopy.openInBrowserHint))

            Button(action: copyRepository) {
                Image(systemName: "doc.on.doc")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle())
            .accessibilityLabel(Text(verbatim: PopopxHelpCopy.copyAddress))
        }
    }

    /// 外部链接就是系统浏览器的事（口径同 PopopxCabinView.swift:2318 的 `UIApplication.shared.open` 与
    /// PopopxLocationPickerSheet.swift:763 的 `UIApplication.shared.open`）。
    private func openRepository() {
        PopopxHaptics.impact(.light)
        UIApplication.shared.open(Self.repositoryURL)
    }

    private func copyRepository() {
        UIPasteboard.general.string = Self.repositoryURLString
        PopopxHaptics.impact(.light)
        toast.show(PopopxHelpCopy.copiedAddress, kind: .success)
    }

    /// 评分由系统弹窗提交；拿不到 windowScene 就安静退出，不弹第二个自制的框。
    /// 这里不读 `@EnvironmentObject var sceneDelegate`（旧 SettingsView.swift:309 与 HEAD 那一行那样读）：
    /// 全 app 没有任何一处把 `SceneDelegate` 注入环境（唯一的 `.environmentObject(SceneDelegate())`
    /// 在本文件的预览里），环境对象读不到就是崩溃 —— 于是这一行了很久的风险不再跟着这一页搬过来。
    /// 改读既有的静态窗口句柄（口径同 ThemeManager.swift:130-144 与 POPOPXApp.swift:162）。
    private func requestReview() {
        guard let scene = SceneDelegate.windowStatic?.windowScene else { return }
        SKStoreReviewController.requestReview(in: scene)
    }

    /// 团队联系方式是 app 自己的链接：前台 `UIApplication.open` 会被系统丢掉，所以照旧走应用内连接流程
    /// （口径同旧 SettingsView.swift:516-523，`popopxTeamURL` 见 SettingsView.swift:23）。
    /// 它随上面 parked 的那一行一起搬到这里；这一页是被推进来的，所以 `dismiss()` 现在弹的是这一页。
    private func askTeam() {
        dismiss()
        DispatchQueue.main.async {
            chatModel.appOpenUrl = popopxTeamURL
        }
    }
}

// MARK: - 显示语言（三.4：app 语言的唯一入口）

/// iOS 把「这一个 app 用哪种语言」存在系统设置里，app 自己改不了，也不该自造一套语言选择器。
/// 所以这一页只说三件事：现在用的是哪一种、去哪儿改、什么时候生效。
@MainActor
struct PopopxDisplayLanguageView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                PopopxSectionCard {
                    PopopxSettingsRowLabel(
                        title: PopopxLanguageCopy.currentRow,
                        value: PopopxSettingsValues.languageName,
                        systemImage: "character.bubble",
                        showsChevron: false
                    )
                    .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                    PopopxSettingsDivider()
                    // 卡片内的行与行之间是 0 间距（`PopopxSectionCard` 的口径），三句正文与那一枚
                    // 按钮之间要有呼吸，所以它们自成一格 VStack，而不是散在卡片里。
                    VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                        Text(PopopxLanguageCopy.systemNote)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        PopopxButton(PopopxLanguageCopy.openSettings, systemImage: "gearshape") {
                            UIApplication.shared.open(appSettingsURL)
                        }
                        Text(PopopxLanguageCopy.relaunchNote)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
        .toolbarBackground(PopopxMaterial.bar, for: .navigationBar)
    }
}

// MARK: - 文案

/// 页面上每一句中文只在这里出现一次。
private enum Copy {
    static let pageTitle = NSLocalizedString("Settings", comment: "POPOPX settings tree")
    static let openHint = NSLocalizedString("Open", comment: "POPOPX settings tree")

    // 顶部
    static let legendOnline = NSLocalizedString("Online: over an SMP relay", comment: "POPOPX settings tree")
    static let legendMesh = NSLocalizedString("Offline: POPOPX Bluetooth mesh", comment: "POPOPX settings tree")
    static let legendNote = NSLocalizedString("Only one colour is used per row: you must be able to see at a glance which lane carried it.", comment: "POPOPX settings tree")

    // 外观 —— 这一组的卡名与两行说法 2026-11-20 从「我」栏落回本页，改用英文原句 Key
    // （见下面 `PopopxGeneralCopy`，16 个目录里早有译法）。这里只留主题本身的六个中文名，
    // `PopopxSettingsValues.themeName` 行尾读的就是它们，那不是可译的界面说法而是取值。
    static let themeSystem = NSLocalizedString("Follow system", comment: "POPOPX settings tree")
    static let themeLight = NSLocalizedString("Light", comment: "POPOPX settings tree")
    static let themeDark = NSLocalizedString("Dark", comment: "POPOPX settings tree")
    static let themePopopx = "popopx"
    static let themeBlack = NSLocalizedString("Pure black", comment: "POPOPX settings tree")
    static let themeCustom = NSLocalizedString("Customize theme", comment: "POPOPX settings tree")

    // 隐私与安全 —— 整卡 2026-11-20 删（真机第 6 轮二.2）：这两枚开关与
    // `PrivacySettings.swift:75`、`:88` 是同一批状态，现在直接摆在「我」栏那张防线卡上，
    // 说法也随之改为那两个页面共用的英文 Key（见 `PopopxMeView.swift` 的 `protectScreenRow` 等）。
    // 这里不再留任何无人挂的中文常量。

    // 通知与通话
    static let groupCalls = NSLocalizedString("Notifications and calls", comment: "POPOPX settings tree")
    static let notificationsRow = NSLocalizedString("Notifications", comment: "POPOPX settings tree")
    static let ntfsOff = NSLocalizedString("No server", comment: "POPOPX settings tree")
    static let ntfsPeriodic = NSLocalizedString("Periodic checks", comment: "POPOPX settings tree")
    static let ntfsInstant = NSLocalizedString("Instant notifications", comment: "POPOPX settings tree")
    static let callsRow = NSLocalizedString("Audio and video calls", comment: "POPOPX settings tree")
    static let relayCallsRow = NSLocalizedString("Force calls through a relay", comment: "POPOPX settings tree")
    static let relayCallsNoteOn = NSLocalizedString("A relay protects your IP address, but it can see how long a call lasts.", comment: "POPOPX settings tree")
    static let relayCallsNoteOff = NSLocalizedString("The relay is used only when it is necessary; the other side may see your IP address.", comment: "POPOPX settings tree")

    // 网络与服务器
    static let groupNetwork = NSLocalizedString("Network and servers", comment: "POPOPX settings tree")
    static let serversRow = NSLocalizedString("Relays and servers", comment: "POPOPX settings tree")
    static let networkFootnote = NSLocalizedString("Going back asks you once whether to save; if you do not save, the last core configuration stays in effect.", comment: "POPOPX settings tree")

    // 数据与迁移
    static let groupData = NSLocalizedString("Data and migration", comment: "POPOPX settings tree")
    static let chatDataRow = NSLocalizedString("Chat data", comment: "POPOPX settings tree")
    static let dataFootnote = NSLocalizedString("Retention, export and encryption are all here; a migration hands your entire device identity to another device, so do not quit midway.", comment: "POPOPX settings tree")
    static let migrateRow = NSLocalizedString("Migrate to another device", comment: "POPOPX settings tree")
    static let migrateRunning = NSLocalizedString("Migration in progress", comment: "POPOPX settings tree")

    // 帮助与关于 —— 整卡 2026-11 升格成 `PopopxHelpView`，标题与说明改为该页 `PopopxHelpCopy`
    // 的英文原句 Key。这里只剩裁定 4 尚未裁定那一行的两条文案，所以它们暂时无人挂（见
    // `PopopxHelpView` 里注释掉的那一行）；开放那一步要先把这两句改成 Key，
    // 中文常量在这一页不再有用。
    static let askTeamRow = NSLocalizedString("Questions and feedback", comment: "POPOPX settings tree")
    static let askTeamNote = NSLocalizedString("Connect to this account inside the app: no browser, no email.", comment: "POPOPX settings tree")
}

/// 真机第 6 轮二.1 从「我」栏常用组落回设置树的三行说法。口径与那一页一致：**英文原句就是 Key**。
/// 七条里有六条是现成词条——整段从 `PopopxMeView.swift` 的 `Copy` 里原样搬来，源文一字未改，
/// 译本一条都不用动；唯一新增的是这组的卡名。`en.lproj` 不写（读不到词条就回落 Key 本身，那就是英文）。
private enum PopopxGeneralCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX settings tree")
    }

    /// 只有这一枚是本轮新增的 Key；其余全部复用。
    static let groupAppearance = key("Appearance and language")
    static let appearanceRow = key("Appearance and icons")
    static let languageRow = key("Display language")
    /// 刻意不叫 `"Chat preferences"`：那个 Key 在 16 个目录里已经属于别的页面，中文值是
    /// 「聊天偏好设置」。复用等于让这一行的说法由别人决定，所以源文唯一化（算力点生态同一条约定）。
    static let chatPreferences = key("Chat preferences for this identity")
    static let notifyOn = key("Notifications on")
    static let notifyOff = key("This identity is muted")
    /// 行尾的 VoiceOver 提示：中文值与上面那个中文 `Copy.openHint` 同为「打开」，说法不两样。
    static let openHint = key("Open")
}

// MARK: - 「网络与服务器」那张卡的新文案（英文原句即 Key）

/// 真机第 8 轮 · 任务六上提来的两行。口径同 `PopopxGeneralCopy`：**英文原句就是 Key**，
/// 而且这里五条引用全是现成词条——它们本来就是 `NetworkAndServers.swift` 那两段的原话，整段搬上来
/// 时源文一字未改，所以 16 个目录一条都不用动（`en.lproj` 不写，读不到词条就回落 Key 本身）。
private enum PopopxNetworkCopy {
    /// 行标题：原先那一行 `Text("Advanced network settings")` 的说法（中文值「高级网络设置」）。
    static let advancedRow = NSLocalizedString("Advanced network settings", comment: "POPOPX settings tree")
    /// 被推页面的标题：原先给 `AdvancedNetworkSettings` 的 `.navigationTitle("Advanced settings")`
    /// （中文值「高级设置」）——行与页的说法各一句，和上提之前逐字相同。
    static let advancedTitle = NSLocalizedString("Advanced settings", comment: "POPOPX settings tree")
    /// 状态行标题：原先那一段的 Section header `Text("Network connection")`（中文值「网络连接」）。
    static let connectionRow = NSLocalizedString("Network connection", comment: "POPOPX settings tree")
    /// 状态点的 VoiceOver 读数：链路类型那一半已经是现成词条（`UserNetworkType.text`：
    /// "WiFi"/"Cellular"/"Wired ethernet"/"Other"/"No network connection"），这里只补在线与否
    /// （中文值正是「在线」「离线」，与顶部图例那两行同一个说法）。
    static let online = NSLocalizedString("Online", comment: "POPOPX settings tree")
    static let offline = NSLocalizedString("Offline", comment: "POPOPX settings tree")
}

// MARK: - 两页的新文案（英文原句即 Key）

/// `PopopxHelpView` 的文案。口径同「我」栏：英文原句就是 Key，新词条写进
/// `bg/cs/de/es/fi/fr/hu/it/ja/nl/pl/ru/th/tr/uk/zh-Hans` 共 16 个目录，`en.lproj` 不写。
/// 上面那个 `Copy` 是设置树的中文常量表，这一页不再往里加英文句子。
private enum PopopxHelpCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX help")
    }

    static let aboutRow = key("About popopx")
    /// 复用既有词条：这个 Key 在 16 个目录里都已经有译法，中文值正是「版本」。
    static let versionRow = key("Version and updates")
    /// 导航行的 VoiceOver 提示：同样复用既有词条（中文值正是「打开」），
    /// 因为这一页不像设置树那样有本文件的中文常量可借。
    static let openHint = NSLocalizedString("Open", comment: "Help: reuses the existing all-catalog term")
    static let rateRow = key("Rate the app")
    static let rateNote = key("The system shows this dialog only a few times a year. If nothing appears, nothing is broken.")
    static let repositoryRow = key("Source code")
    /// 隐私协议那一行的标题直接取 `PopopxOnboardingCopy.privacyPolicy`：行与文书标题必须逐字同一句。
    static let privacyNote = key("The full text is bundled with the app and opened here, offline.")
    static let openInBrowserHint = key("Opens in your browser")
    static let copyAddress = key("Copy address")
    static let copiedAddress = key("Repository address copied")
}

/// `PopopxDisplayLanguageView` 的文案，同一套 Key 口径。
private enum PopopxLanguageCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX display language")
    }

    static let currentRow = key("Current language")
    static let systemNote = key("iOS keeps the language of each app separately, in the system settings; POPOPX does not store it.")
    /// 复用既有词条：这个 Key 在 16 个目录里都已经有译法。
    static let openSettings = NSLocalizedString("Open Settings", comment: "Display language: reuses the existing all-catalog term")
    static let relaunchNote = key("Close POPOPX and open it again for the new language to take effect.")
}

// MARK: - Previews

#if DEBUG
/// 画布只呈现本页根视图：它自己读的环境就这两个。推进去的子页面另外要全 app 的主题对象，
/// 那是那条红线名单禁止在本页出现的名字，也不该在预览里造一个假的 —— 所以预览不覆盖子页面。
struct PopopxSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxSettingsView(versionText: "7.1")
        }
        .environment(PopopxSettingsNavTrack())
        .environmentObject(ChatModel.shared)
    }
}

/// 升格出来的两页。它们只需要 `ChatModel`（应用根注入的那一个）：评分那一行读的是
/// `SceneDelegate.windowStatic`，不是环境对象，所以画布里不必造一个假的委托。
struct PopopxHelpView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxHelpView()
                .navigationTitle("Help and about")
        }
        .environmentObject(ChatModel.shared)
    }
}

struct PopopxDisplayLanguageView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxDisplayLanguageView()
                .navigationTitle("Display language")
        }
    }
}
#endif
