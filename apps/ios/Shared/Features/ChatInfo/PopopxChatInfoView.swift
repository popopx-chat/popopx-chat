//
//  PopopxChatInfoView.swift
//  POPOPX (iOS)
//
//  【第五阶段】1:1 联系人会话信息页重写，替代 Shared/Views/Chat/ChatInfoView.swift:94。
//  挂载方式：把 Shared/Views/Chat/ChatView.swift:476 的 `ChatInfoView(` 改成
//  `PopopxChatInfoView(` 就够了 —— 六个外部参数标签、类型与顺序和旧页逐字一致
//  （chat / contact / localAlias / featuresAllowed / currentFeaturesAllowed / onSearch），
//  环境依赖也照旧声明：ChatModel、AppTheme、\.dismiss。
//
//  AppTheme 这一行只保留声明、不读它的任何颜色（裁定 B：颜色只来自 PopopxTheme）：
//  本页推进去的旧目的地各自有 `@EnvironmentObject var theme: AppTheme`
//  （VerifyCodeView.swift:14、ContactPreferencesView.swift:17、ChatInfoView.swift:931、
//  ChatInfoView.swift:1291），环境由根上注入（Shared/POPOPXApp.swift:44）自动向下传递，
//  保留声明只是为了这份输入面与旧页完全同形。
//
//  版式：顶部一枚联系人卡（头像 + 校验盾 + 名字/全名 + popopx 名 + 简介 + 连接状态 +
//  本机备注名输入），下面 ScrollView 里六组 PopopxSectionCard：连接与安全 / 聊天 /
//  自动删除 / 地址 / 服务器 / 危险操作。旧页是 List + 8 段，这里改成与新品牌其它页面
//  （PopopxMeView、PopopxContactsView）同一族的卡片滚动布局。
//
//  数据来源全是既有函数，本页不写第二条链路：
//  · 进页面一次读三份事实 —— apiContactInfo（Shared/Model/POPOPXAPI.swift:947）给
//    ConnectionStats 与这条连接所用的随机身份，apiGetContactCode（:1013）给校验码与最新
//    Contact；两份事实不一致时用后者回写 chat.chatInfo。
//  · 备注名 apiSetContactAlias（:1448）、偏好 apiSetContactPrefs（:1442）、校验码
//    apiVerifyContact（:1025）、更换/中止更换接收地址 apiSwitchContact（:977）/
//    apiAbortSwitchContact（:989）、清除记录 clearChat（:1363）、静音与回执
//    toggleNotifications / updateChatSettings（Shared/Views/Chat/ChatView.swift:3361 / :3373）；
//  · 修复连接走 syncContactConnection（Shared/Views/Chat/ChatInfoView.swift:726），
//    删除联系人走 deleteContactDialog（:1139，两级确认，第二级是 DeleteActiveContactDialog :1289）；
//  · 订阅状态只读 ChatModel.chatSubStatus（Shared/Model/ChatModel.swift:413），服务器地址读
//    ConnectionStats（POPOPXChat/APITypes.swift:568）的 rcv/sndQueuesInfo，主机名走
//    serverHost（Shared/Views/Chat/ChatInfoView.swift:54）；
//  · 头像与简介复用 ProfileImage（Shared/Views/Helpers/ProfileImage.swift:13）、
//    NameWithBadge（Shared/Views/Helpers/NameBadge.swift:23）、contactPopopxNameView 与
//    ProfileDescriptionView（Shared/Views/Chat/ChatItem/MsgContentView.swift:382）。
//
//  配色纪律（§1.1）：这一页讲的只有在线 SMP 通道，靛紫就是"在线加密"，所以全页不出现青绿；
//  绿色不承载常驻状态（§1.4 第 4 条），"已连接"用 brand，错误用 dangerInk。
//  破坏性行（清除记录 / 删除联系人）一律 dangerInk 标题 + danger 徽章，并且各自保留真实确认：
//  清除 = Alert 二次确认；删除 = ActionSheet + 第二张表单页，没有任何一步是静默的。
//  签名细节（§2.4 每屏一个）：头像右下角那枚校验盾，只有 contact.verified 为真才出现，
//  实底 brand + 墨 onBrand（§1.4 第 1 条），带一圈 card 色描边把它从照片里剥出来；静态，无动画。
//
//  未搬过来的旧行（都是 developer tools 门后的调试分支，逐条见交付说明）：
//  「For console」整段（旧 :274-293，含 Local name / Database ID / Debug delivery）、
//  强制重新协商加密（旧 :532-539 与其 alert 分支 :335-343 和 :1114-1121）、
//  队列调试信息（旧 :281-291 与 :1123-1137）、以及一个声明后从未被读写的死状态
//  showConnectContactViaAddressDialog（旧 :111）。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖进 POPOPX (iOS) target —— 铁律禁止脚本改 project.pbxproj。
//

import Foundation
import SwiftUI
import UIKit
import POPOPXChat

// MARK: - 页内提示

/// 本页会弹的五种东西。删除联系人链路要求 `SomeAlert`，所以它作为其中一支原样接住。
private enum PopopxChatInfoAlert: Identifiable {
    case clearChat
    case networkStatus(SubscriptionStatus)
    case switchAddress
    case abortSwitchAddress
    case someAlert(SomeAlert)

    var id: String {
        switch self {
        case .clearChat: return "popopxChatInfo.clearChat"
        case let .networkStatus(status): return "popopxChatInfo.networkStatus \(status)"
        case .switchAddress: return "popopxChatInfo.switchAddress"
        case .abortSwitchAddress: return "popopxChatInfo.abortSwitchAddress"
        case let .someAlert(alert): return "popopxChatInfo.someAlert \(alert.id)"
        }
    }
}

// MARK: - 页面

@MainActor
struct PopopxChatInfoView: View {
    // MARK: 输入面（与 ChatInfoView 同形，一个词即可挂载）

    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss: DismissAction
    @ObservedObject var chat: Chat
    @State var contact: Contact
    @State var localAlias: String
    @State var featuresAllowed: ContactFeaturesAllowed
    @State var currentFeaturesAllowed: ContactFeaturesAllowed
    var onSearch: () -> Void

    // MARK: 本页自己的状态

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var connectionStats: ConnectionStats? = nil
    @State private var customUserProfile: Profile? = nil
    @State private var connectionCode: String? = nil
    @State private var alert: PopopxChatInfoAlert? = nil
    @State private var actionSheet: SomeActionSheet? = nil
    @State private var sheet: SomeSheet<AnyView>? = nil
    @State private var sendReceipts = SendReceipts.userDefault(true)
    @State private var sendReceiptsUserDefault = true
    @State private var progressIndicator = false
    @State private var toast = PopopxToastModel()
    @FocusState private var aliasFocused: Bool

    /// 头像边长取 4pt 格子上的一档：space2XL × 2 = 96。
    private static let avatarSide: CGFloat = PopopxMetrics.space2XL * 2

    /// 只有连接可用时这些行才谈得上生效（旧页 :207 同一条门）。
    private var connectionUsable: Bool { contact.ready && contact.active }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    headerCard
                    quickActionsCard
                    securityCard
                    chatCard
                    ttlCard
                    if let contactLink = contact.contactLink {
                        addressCard(contactLink)
                    }
                    if contact.ready && contact.active {
                        serversCard
                    }
                    dangerCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, PopopxMetrics.spaceS)
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .background(PopopxPalette.base)
            .popopxAnimation(PopopxSpring.snappy, value: progressIndicator, reduceMotion: reduceMotion)
            .opacity(progressIndicator ? 0.6 : 1)
            .disabled(progressIndicator)
            .overlay(alignment: .center) {
                if progressIndicator {
                    ProgressView()
                        .controlSize(.large)
                        .tint(PopopxPalette.brand)
                        .padding(PopopxMetrics.spaceM)
                        .background(PopopxMaterial.bar, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                        .accessibilityLabel(Text(verbatim: Copy.working))
                }
            }
            .navigationTitle(Copy.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.close) { dismiss() }
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.brand)
                }
            }
        }
        .onAppear {
            loadContactInfo()
        }
        .alert(item: $alert) { item in
            switch item {
            case .clearChat: return clearChatAlert()
            case let .networkStatus(status): return networkStatusAlert(status)
            case .switchAddress: return switchAddressAlert(switchContactAddress)
            case .abortSwitchAddress: return abortSwitchAddressAlert(abortSwitchContactAddress)
            case let .someAlert(a): return a.alert
            }
        }
        .actionSheet(item: $actionSheet) { $0.actionSheet }
        .sheet(item: $sheet) { someSheet in
            someSheet.content
                .presentationDetents([.fraction(someSheet.fraction)])
        }
        .onDisappear {
            if currentFeaturesAllowed != featuresAllowed {
                showAlert(
                    title: Copy.savePrefsTitle,
                    message: Copy.savePrefsMessage,
                    buttonTitle: Copy.savePrefsButton,
                    buttonAction: { saveContactPreferences() },
                    cancelButton: true
                )
            }
        }
        .popopxToast(toast)
    }

    // MARK: 顶部联系人卡

    private var headerCard: some View {
        PopopxSectionCard {
            VStack(spacing: PopopxMetrics.spaceS) {
                avatar
                nameBlock
                ProfileDescriptionView(
                    shortDescr: chat.chatInfo.shortDescr,
                    description: chat.chatInfo.profileDescription
                )
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, PopopxMetrics.spaceXS)

            PopopxChatInfoDivider()
            aliasField
        }
    }

    /// 头像。有 base64 就走既有 `ProfileImage`，没有就落到品牌标记；校验盾只挂在有图的情况之外
    /// 也一律挂右下角，因为它说的是连接，不是照片。
    private var avatar: some View {
        PopopxChatInfoAvatar(image: chat.chatInfo.image, side: Self.avatarSide)
            .overlay(alignment: .bottomTrailing) {
                if contact.verified {
                    verifiedChip
                }
            }
    }

    private var verifiedChip: some View {
        Image(systemName: "checkmark.shield.fill")
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(PopopxIconTint.brand.ink)
            .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
            .background(PopopxIconTint.brand.fill, in: Circle())
            .overlay(Circle().strokeBorder(PopopxPalette.card, lineWidth: PopopxMetrics.divider))
            .padding(PopopxMetrics.space2XS)
            .accessibilityLabel(Text(verbatim: Copy.verifiedShieldHint))
    }

    private var nameBlock: some View {
        let badge = chat.chatInfo.nameBadge
        let shownName = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: PopopxMetrics.space2XS) {
            NameWithBadge(
                Text(shownName)
                    .font(PopopxType.title)
                    .foregroundStyle(PopopxPalette.label),
                badge,
                .title2
            ) {
                if let badge {
                    showBadgeInfoAlert(shownName, badge)
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)

            if showsFullName {
                Text(chat.chatInfo.fullName)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            contactPopopxNameView(contact) { contact = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var showsFullName: Bool {
        let fullName = chat.chatInfo.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !fullName.isEmpty
            && fullName != contact.displayName
            && fullName != contact.profile.displayName
    }

    /// 连接状态。措辞只说这份 Contact 真具备的事实：`ready`/`sndReady` 来自 activeConn 的
    /// connStatus（POPOPXChat/ChatTypes.swift:2657-2660），失败来自 connFailedErr（:2813）。
    private var statusLine: some View {
        let state = connectionState
        return HStack(spacing: PopopxMetrics.space2XS) {
            Circle()
                .fill(state.dot)
                .frame(width: PopopxMetrics.space2XS, height: PopopxMetrics.space2XS)
            Text(state.words)
                .font(PopopxType.microTag)
                .foregroundStyle(state.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private var connectionState: (words: String, ink: Color, dot: Color) {
        if !contact.active {
            return (Copy.stateDeleted, PopopxPalette.dangerInk, PopopxPalette.dangerFill)
        }
        if contact.activeConn?.connFailedErr != nil {
            return (Copy.stateFailed, PopopxPalette.dangerInk, PopopxPalette.danger)
        }
        if contact.ready {
            return (Copy.stateReady, PopopxPalette.brand, PopopxPalette.brand)
        }
        if contact.sndReady {
            return (Copy.stateSndReady, PopopxPalette.brand, PopopxPalette.brand)
        }
        if contact.activeConn == nil {
            return (Copy.stateNoConnection, PopopxPalette.labelSecondary, PopopxPalette.labelHint)
        }
        return (Copy.stateConnecting, PopopxPalette.labelSecondary, PopopxPalette.labelHint)
    }

    /// 本机备注名。失焦即写回，和旧页 :408-415 同一条落库时机（不改焦点就不发请求）。
    private var aliasField: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "pencil")
                .font(PopopxType.body)
                .foregroundStyle(aliasFocused ? PopopxPalette.brand : PopopxPalette.labelSecondary)
                .frame(width: PopopxMetrics.spaceXL)
                .accessibilityHidden(true)
            TextField(Copy.aliasPrompt, text: $localAlias)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.label)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .disableAutocorrection(true)
                .focused($aliasFocused)
                .onSubmit {
                    setContactAlias()
                }
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .frame(minHeight: PopopxMetrics.minHitTarget)
        .background(PopopxPalette.base, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(
                    aliasFocused ? PopopxPalette.brand : PopopxPalette.labelHint,
                    lineWidth: aliasFocused ? PopopxMetrics.stroke : PopopxMetrics.divider
                )
        )
        .onChange(of: aliasFocused) { _, focused in
            if !focused {
                setContactAlias()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Copy.aliasLabel))
    }

    // MARK: 快捷动作

    private var quickActionsCard: some View {
        PopopxSectionCard {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxChatInfoTile(
                    title: Copy.search,
                    systemImage: "magnifyingglass",
                    tint: .brand,
                    enabled: contact.ready && !chat.chatItems.isEmpty
                ) {
                    dismiss()
                    onSearch()
                }

                PopopxChatInfoCallTile(
                    chat: chat,
                    contact: contact,
                    connectionStats: $connectionStats,
                    media: .audio,
                    showAlert: { alert = .someAlert($0) }
                )

                PopopxChatInfoCallTile(
                    chat: chat,
                    contact: contact,
                    connectionStats: $connectionStats,
                    media: .video,
                    showAlert: { alert = .someAlert($0) }
                )

                if let nextNtfMode = chat.chatInfo.nextNtfMode {
                    PopopxChatInfoTile(
                        title: nextNtfMode == .all ? Copy.unmute : Copy.mute,
                        systemImage: nextNtfMode.iconFilled,
                        tint: .neutral,
                        enabled: connectionUsable
                    ) {
                        toggleNotifications(chat, enableNtfs: nextNtfMode)
                    }
                }
            }
        }
    }

    // MARK: 连接与安全

    private var securityCard: some View {
        PopopxSectionCard(Copy.groupSecurity, footnote: Copy.securityFootnote) {
            if let code = connectionCode {
                PopopxChatInfoRowLink(
                    title: contact.verified ? Copy.viewCode : Copy.verifyCode,
                    value: contact.verified ? Copy.verifiedOn : nil,
                    systemImage: contact.verified ? "checkmark.shield.fill" : "shield.lefthalf.filled",
                    tint: .brand
                ) {
                    VerifyCodeView(
                        displayName: contact.displayName,
                        connectionCode: code,
                        connectionVerified: contact.verified,
                        verify: { codeToCheck in
                            verifyConnectionCode(codeToCheck)
                        }
                    )
                    .navigationTitle(Copy.securityCodePage)
                    .navigationBarTitleDisplayMode(.inline)
                }
                PopopxChatInfoDivider()
            }

            if contact.activeConn != nil {
                PopopxChatInfoRow(
                    title: Copy.e2e,
                    value: contact.activeConn?.connPQEnabled == true ? Copy.pqResistant : Copy.pqStandard,
                    systemImage: "lock.shield.fill",
                    tint: .brand
                )
                PopopxChatInfoDivider()
            }

            if let profile = customUserProfile {
                PopopxChatInfoRow(
                    title: Copy.incognitoProfile,
                    value: profile.chatViewName,
                    note: Copy.incognitoNote,
                    systemImage: "person.crop.circle.badge.questionmark"
                )
                PopopxChatInfoDivider()
            }

            if connectionStats?.ratchetSyncAllowed == true {
                PopopxChatInfoRow(
                    title: Copy.fixConnection,
                    note: Copy.fixConnectionNote,
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    tint: .brand,
                    action: {
                        syncConnection()
                    }
                )
            }
        }
        .disabled(!connectionUsable)
        .opacity(connectionUsable ? 1 : 0.45)
    }

    // MARK: 聊天

    private var chatCard: some View {
        PopopxSectionCard(Copy.groupChat) {
            PopopxChatInfoRowLink(title: Copy.contactPreferences, systemImage: "switch.2", tint: .brand) {
                ContactPreferencesView(
                    contact: $contact,
                    featuresAllowed: $featuresAllowed,
                    currentFeaturesAllowed: $currentFeaturesAllowed,
                    savePreferences: { saveContactPreferences() }
                )
                .navigationTitle(Copy.contactPreferences)
                .navigationBarTitleDisplayMode(.large)
            }

            PopopxChatInfoDivider()
            receiptsBlock
            PopopxChatInfoDivider()

            PopopxChatInfoRowLink(title: Copy.wallpaper, systemImage: "photo.on.rectangle", tint: .brand) {
                ChatWallpaperEditorSheet(chat: chat)
            }
        }
        .disabled(!connectionUsable)
        .opacity(connectionUsable ? 1 : 0.45)
    }

    /// 已读回执三档。选项就是 `SendReceipts`（Shared/Views/Chat/ChatInfoView.swift:62）本身，
    /// 第三档的默认值读的是当前身份的 `sendRcptsContacts`（POPOPXChat/ChatTypes.swift:48），
    /// 所以它显示的是"跟的是哪条默认"，不是猜的。
    private var receiptsBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxChatInfoRowBadge(systemName: "checkmark.message", tint: .brand)
                Text(Copy.sendReceipts)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            Text(Copy.sendReceiptsNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PopopxSegmentedControl(
                [
                    .init(selection: SendReceipts.yes, title: receiptWords(.yes)),
                    .init(selection: SendReceipts.no, title: receiptWords(.no)),
                    .init(
                        selection: SendReceipts.userDefault(sendReceiptsUserDefault),
                        title: receiptWords(.userDefault(sendReceiptsUserDefault))
                    )
                ],
                title: receiptWords,
                selection: $sendReceipts
            )
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .onChange(of: sendReceipts) { _, choice in
            setSendReceipts(choice)
        }
    }

    private func receiptWords(_ choice: SendReceipts) -> String {
        switch choice {
        case .yes: return Copy.receiptYes
        case .no: return Copy.receiptNo
        case let .userDefault(on): return on ? Copy.receiptDefaultOn : Copy.receiptDefaultOff
        }
    }

    // MARK: 自动删除

    /// 这一行的控件与确认逻辑是旧页那颗 `ChatTTLOption`（Shared/Views/Chat/ChatInfoView.swift:664）：
    /// 它自己会先弹确认，再 `setChatTTL` + 重载会话，失败回滚。中文说明由本页 footnote 给。
    private var ttlCard: some View {
        PopopxSectionCard(Copy.groupTTL, footnote: Copy.ttlFootnote) {
            ChatTTLOption(chat: chat, progressIndicator: $progressIndicator)
                .padding(.vertical, PopopxMetrics.space2XS)
        }
    }

    // MARK: 地址

    private func addressCard(_ contactLink: String) -> some View {
        PopopxSectionCard(Copy.groupAddress, footnote: Copy.addressFootnote(contact.displayName)) {
            VStack(spacing: PopopxMetrics.spaceS) {
                POPOPXLinkQRCode(uri: contactLink)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(PopopxMetrics.spaceM)
                    .frame(maxWidth: PopopxMetrics.space2XL * 5)

                PopopxButton(Copy.shareAddress, systemImage: "square.and.arrow.up", role: .secondary) {
                    showShareSheet(items: [popopxChatLink(contactLink)])
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: 服务器

    private var serversCard: some View {
        PopopxSectionCard(Copy.groupServers, footnote: Copy.serversFootnote) {
            if let status = chatModel.chatSubStatus {
                let words = networkStatusWords(status)
                PopopxChatInfoRow(
                    title: Copy.networkStatus,
                    value: words.text,
                    systemImage: status.imageName,
                    tint: words.tint,
                    action: {
                        alert = .networkStatus(status)
                    }
                )
            }

            if let connStats = connectionStats {
                PopopxChatInfoDivider()
                PopopxChatInfoRow(
                    title: Copy.switchAddress,
                    note: Copy.switchAddressNote,
                    systemImage: "arrow.triangle.2.circlepath",
                    enabled: switchAddressAllowed(connStats),
                    action: {
                        alert = .switchAddress
                    }
                )

                if connStats.rcvQueuesInfo.contains(where: { $0.rcvSwitchStatus != nil }) {
                    PopopxChatInfoDivider()
                    PopopxChatInfoRow(
                        title: Copy.abortSwitch,
                        systemImage: "arrow.counterclockwise",
                        enabled: abortSwitchAllowed(connStats),
                        action: {
                            alert = .abortSwitchAddress
                        }
                    )
                }

                let receiving = connStats.rcvQueuesInfo.map { $0.rcvServer }
                if !receiving.isEmpty {
                    PopopxChatInfoDivider()
                    serverRow(Copy.receivingVia, receiving, "arrow.down.circle")
                }

                let sending = connStats.sndQueuesInfo.map { $0.sndServer }
                if !sending.isEmpty {
                    PopopxChatInfoDivider()
                    serverRow(Copy.sendingVia, sending, "arrow.up.circle")
                }
            }
        }
    }

    /// 服务器行：显示第一个中继主机名，点击把整份列表复制走（旧页 :41-52 的 `smpServers`
    /// 就是这个动作，只是版式换了）。主机名走 `serverHost`（旧 :54），去掉前缀不自己拼规则。
    private func serverRow(_ title: String, _ servers: [String], _ systemImage: String) -> some View {
        PopopxChatInfoRow(
            title: title,
            value: serverHost(servers[0]),
            note: servers.count > 1 ? String(format: Copy.moreServersFormat, servers.count) : nil,
            systemImage: systemImage,
            action: {
                copyServers(servers.joined(separator: ";"))
            }
        )
    }

    private func networkStatusWords(_ status: SubscriptionStatus) -> (text: String, tint: PopopxIconTint) {
        switch status {
        case .active: return (Copy.netActive, .brand)
        case .pending: return (Copy.netPending, .neutral)
        case .removed(_): return (Copy.netRemoved, .danger)
        case .noSub: return (Copy.netNoSub, .neutral)
        }
    }

    private func switchAddressAllowed(_ stats: ConnectionStats) -> Bool {
        !stats.rcvQueuesInfo.contains { $0.rcvSwitchStatus != nil } && !stats.ratchetSyncSendProhibited
    }

    private func abortSwitchAllowed(_ stats: ConnectionStats) -> Bool {
        !stats.rcvQueuesInfo.contains { $0.rcvSwitchStatus != nil && !$0.canAbortSwitch }
            && !stats.ratchetSyncSendProhibited
    }

    // MARK: 危险操作

    private var dangerCard: some View {
        PopopxSectionCard(Copy.groupDanger, footnote: Copy.dangerFootnote) {
            PopopxChatInfoRow(
                title: Copy.clearHistory,
                note: Copy.clearHistoryNote,
                systemImage: "gobackward",
                tint: .danger,
                action: {
                    alert = .clearChat
                }
            )

            PopopxChatInfoDivider()

            PopopxChatInfoRow(
                title: Copy.deleteContact,
                note: Copy.deleteContactNote,
                systemImage: "person.badge.minus",
                tint: .danger,
                action: {
                    deleteContactDialog(
                        chat,
                        contact,
                        dismissToChatList: true,
                        showAlert: { someAlert in alert = .someAlert(someAlert) },
                        showActionSheet: { someActionSheet in actionSheet = someActionSheet },
                        showSheetContent: { someSheet in sheet = someSheet }
                    )
                }
            )
        }
    }

    // MARK: 行为

    private func loadContactInfo() {
        if let currentUser = chatModel.currentUser {
            sendReceiptsUserDefault = currentUser.sendRcptsContacts
        }
        sendReceipts = SendReceipts.fromBool(
            contact.chatSettings.sendRcpts,
            userDefault: sendReceiptsUserDefault
        )
        Task {
            do {
                let (stats, profile) = try await apiContactInfo(chat.chatInfo.apiId)
                let (latestContact, code) = try await apiGetContactCode(chat.chatInfo.apiId)
                connectionStats = stats
                customUserProfile = profile
                connectionCode = code
                if contact.activeConn?.connectionCode != latestContact.activeConn?.connectionCode {
                    chat.chatInfo = .direct(contact: latestContact)
                }
            } catch let error {
                logger.error("apiContactInfo or apiGetContactCode error: \(responseError(error))")
            }
        }
    }

    private func setContactAlias() {
        Task {
            do {
                if let updated = try await apiSetContactAlias(
                    contactId: chat.chatInfo.apiId,
                    localAlias: localAlias
                ) {
                    chatModel.updateContact(updated)
                }
            } catch {
                logger.error("setContactAlias error: \(responseError(error))")
            }
        }
    }

    private func verifyConnectionCode(_ code: String?) -> (Bool, String)? {
        guard let result = apiVerifyContact(chat.chatInfo.apiId, connectionCode: code) else { return nil }
        contact.activeConn?.connectionCode = result.0
            ? SecurityCode(securityCode: result.1, verifiedAt: .now)
            : nil
        connectionCode = result.1
        DispatchQueue.main.async {
            chat.chatInfo = .direct(contact: contact)
        }
        return result
    }

    private func setSendReceipts(_ choice: SendReceipts) {
        var chatSettings = chat.chatInfo.chatSettings ?? ChatSettings.defaults
        chatSettings.sendRcpts = choice.bool()
        updateChatSettings(chat, chatSettings: chatSettings)
    }

    private func saveContactPreferences() {
        Task {
            do {
                let prefs = contactFeaturesAllowedToPrefs(featuresAllowed)
                if let updated = try await apiSetContactPrefs(contactId: contact.contactId, preferences: prefs) {
                    contact = updated
                    chatModel.updateContact(updated)
                    currentFeaturesAllowed = featuresAllowed
                }
            } catch {
                logger.error("ContactPreferencesView apiSetContactPrefs error: \(responseError(error))")
            }
        }
    }

    private func syncConnection() {
        Task {
            if let stats = await syncContactConnection(contact, force: false) {
                connectionStats = stats
                dismiss()
            }
        }
    }

    private func switchContactAddress() {
        Task {
            do {
                let stats = try apiSwitchContact(contactId: contact.apiId)
                connectionStats = stats
                chatModel.updateContactConnectionStats(contact, stats)
                dismiss()
            } catch let error {
                logger.error("switchContactAddress apiSwitchContact error: \(responseError(error))")
                showErrorAlert(error, Copy.errorSwitchAddress)
            }
        }
    }

    private func abortSwitchContactAddress() {
        Task {
            do {
                let stats = try apiAbortSwitchContact(contact.apiId)
                connectionStats = stats
                chatModel.updateContactConnectionStats(contact, stats)
            } catch let error {
                logger.error("abortSwitchContactAddress apiAbortSwitchContact error: \(responseError(error))")
                showErrorAlert(error, Copy.errorAbortSwitch)
            }
        }
    }

    private func copyServers(_ text: String) {
        UIPasteboard.general.string = text
        PopopxHaptics.impact(.light)
        toast.show(Copy.copiedServers, kind: .encrypted)
    }

    // MARK: 提示

    private func clearChatAlert() -> Alert {
        Alert(
            title: Text(Copy.clearConfirmTitle),
            message: Text(Copy.clearConfirmMessage(chat.chatInfo.displayName)),
            primaryButton: .destructive(Text(Copy.clearConfirmButton)) {
                Task {
                    await clearChat(chat)
                    dismiss()
                }
            },
            secondaryButton: .cancel()
        )
    }

    private func networkStatusAlert(_ status: SubscriptionStatus) -> Alert {
        Alert(
            title: Text(Copy.networkStatusTitle),
            message: Text(status.statusExplanation)
        )
    }
}

// MARK: - 行与卡内原子件

/// 卡片内分隔线。原子库里那条同名的只在 `#if DEBUG` 画廊里（Shared/Components/PopopxControls.swift:853）。
private struct PopopxChatInfoDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

/// 行首的 SF Symbol 徽章：实底与压在它上面的墨成对取自 `PopopxIconTint`（§2.5 第 2 条），
/// 库里的同枚徽章是私有的（PopopxControls.swift:315），这里按同一形状现拼。
private struct PopopxChatInfoRowBadge: View {
    let systemName: String
    let tint: PopopxIconTint

    var body: some View {
        Image(systemName: systemName)
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(tint.ink)
            .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
            .background(tint.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            .accessibilityHidden(true)
    }
}

/// 画在卡面上的墨：`PopopxIconTint.ink` 说的是"压在实底上的墨"，两者不能混用，
/// 否则 light 模式下白压在白卡上等于看不见。
private enum PopopxChatInfoInk {
    static func onCard(_ tint: PopopxIconTint) -> Color {
        switch tint {
        case .brand: return PopopxPalette.brand
        case .mesh: return PopopxPalette.meshInk
        case .danger: return PopopxPalette.dangerInk
        case .success: return PopopxPalette.successInk
        case .neutral: return PopopxPalette.label
        }
    }
}

private struct PopopxChatInfoRowLabel: View {
    let title: String
    var note: String?
    /// 危险行的标题要一眼看见，所以墨由调用方给：普通行 label，危险行 dangerInk。
    var titleInk: Color = PopopxPalette.label

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(title)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(titleInk)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 一行。有 action 才是按钮，没有就是纯读数 —— 不存在"点了没反应"的行。
private struct PopopxChatInfoRow: View {
    let title: String
    var value: String?
    var note: String?
    var systemImage: String?
    var tint: PopopxIconTint = .neutral
    var enabled = true
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                label
                    .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            if let systemImage {
                PopopxChatInfoRowBadge(systemName: systemImage, tint: tint)
            }
            PopopxChatInfoRowLabel(
                title: title,
                note: note,
                titleInk: tint == .danger ? PopopxPalette.dangerInk : PopopxPalette.label
            )
            Spacer(minLength: PopopxMetrics.spaceXS)
            if let value {
                Text(value)
                    .font(PopopxType.meta)
                    .foregroundStyle(tint == .danger ? PopopxPalette.dangerInk : PopopxPalette.labelSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
    }
}

/// 推到既有页面的一行。导航由 `NavigationLink` 拥有，所以整行不是 Button：
/// 原子库那枚 `PopopxPickerRow` 自身是 Button，嵌进链接会把点击吃掉。
private struct PopopxChatInfoRowLink<Destination: View>: View {
    let title: String
    var value: String?
    var systemImage: String?
    var tint: PopopxIconTint = .brand
    let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: PopopxMetrics.spaceS) {
                if let systemImage {
                    PopopxChatInfoRowBadge(systemName: systemImage, tint: tint)
                }
                Text(title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                if let value {
                    Text(value)
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, PopopxMetrics.spaceXS)
            .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(verbatim: Copy.opensHint))
    }
}

/// 快捷动作那一格：图标在上、字在下，整格 44pt 起跳。
private struct PopopxChatInfoTile: View {
    let title: String
    let systemImage: String
    let tint: PopopxIconTint
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: systemImage)
                    .font(PopopxType.body)
                    .imageScale(.large)
                Text(title)
                    .font(PopopxType.microTag)
            }
            .foregroundStyle(enabled ? PopopxChatInfoInk.onCard(tint) : PopopxPalette.labelHint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .padding(.vertical, PopopxMetrics.spaceXS)
            .background(PopopxPalette.base, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(PopopxPalette.labelHint, lineWidth: PopopxMetrics.divider)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(Text(verbatim: title))
    }
}

/// 通话格。判定树与旧页那颗 `CallButton`（Shared/Views/Chat/ChatInfoView.swift:784-899）逐条对应，
/// 只是把版式换成 popopx 的格子：能不能打、为什么不能打、要不要先修复连接，说的都是真判断。
@MainActor
private struct PopopxChatInfoCallTile: View {
    let chat: Chat
    let contact: Contact
    @Binding var connectionStats: ConnectionStats?
    let media: CallMediaType
    let showAlert: (SomeAlert) -> Void

    var body: some View {
        PopopxChatInfoTile(
            title: words.text,
            systemImage: words.symbol,
            tint: .brand,
            enabled: canCall
        ) {
            fire()
        }
        .disabled(ChatModel.shared.activeCall != nil)
    }

    private var words: (text: String, symbol: String) {
        media == .audio ? (Copy.callAudio, "phone.fill") : (Copy.callVideo, "video.fill")
    }

    private var canCall: Bool {
        contact.ready && contact.active
            && chat.chatInfo.featureEnabled(.calls)
            && ChatModel.shared.activeCall == nil
    }

    private func fire() {
        if canCall {
            callWhenReady()
        } else if contact.sendMsgToConnect {
            notify(Copy.cantCallTitle, Copy.sendMsgToEnable)
        } else if !contact.active {
            notify(Copy.cantCallTitle, Copy.contactDeleted)
        } else if !contact.ready {
            notify(Copy.cantCallTitle, Copy.contactNotReady)
        } else if !chat.chatInfo.featureEnabled(.calls) {
            switch chat.chatInfo.showEnableCallsAlert {
            case .userEnable:
                showAlert(SomeAlert(
                    alert: Alert(
                        title: Text(Copy.allowCallsTitle),
                        message: Text(Copy.allowCallsMessage),
                        primaryButton: .default(Text(Copy.allow)) {
                            allowFeatureToContact(contact, .calls)
                        },
                        secondaryButton: .cancel()
                    ),
                    id: "popopxChatInfo.allowCalls"
                ))
            case .askContact:
                notify(Copy.callsProhibited, Copy.callsAskContact)
            case .other:
                notify(Copy.callsProhibited, Copy.callsCheckBoth)
            }
        } else {
            notify(Copy.cantCallTitle, nil)
        }
    }

    private func callWhenReady() {
        guard let connStats = connectionStats else { return }
        if connStats.ratchetSyncState == .ok {
            if CallController.useCallKit() {
                CallController.shared.startCall(contact, media)
            } else {
                // 不走 CallKit 时配色会被通话改掉，先把弹层收掉再发起，理由同旧页 :804-807。
                dismissAllSheets(animated: true) {
                    CallController.shared.startCall(contact, media)
                }
            }
        } else if connStats.ratchetSyncAllowed {
            showAlert(SomeAlert(
                alert: Alert(
                    title: Text(Copy.fixConnectionTitle),
                    message: Text(Copy.fixConnectionMessage),
                    primaryButton: .default(Text(Copy.fix)) {
                        Task {
                            if let stats = await syncContactConnection(contact, force: false) {
                                connectionStats = stats
                            }
                        }
                    },
                    secondaryButton: .cancel()
                ),
                id: "popopxChatInfo.fixConnection"
            ))
        } else {
            notify(Copy.cantCallTitle, Copy.renegotiationInProgress)
        }
    }

    private func notify(_ title: String, _ message: String?) {
        showAlert(SomeAlert(
            alert: message.map { Alert(title: Text(title), message: Text($0)) } ?? Alert(title: Text(title)),
            id: "popopxChatInfo.\(title)"
        ))
    }
}

/// 头像。有 base64 就用既有 `ProfileImage`，没有就落到品牌标记 —— 不画占位人形。
@MainActor
private struct PopopxChatInfoAvatar: View {
    let image: String?
    let side: CGFloat

    var body: some View {
        Group {
            if imageFromBase64(image) != nil {
                // `color:` 与 PopopxMeView.swift:745 同一个值：`ProfileImage` 内部按
                // asAnotherColorFromSecondaryVariant 映射这张图在分组背景上的深浅。
                ProfileImage(imageStr: image, size: side, color: Color(uiColor: .tertiarySystemGroupedBackground))
            } else {
                Image(PopopxBrandAsset.mark)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - 文案

/// 页面上每一句中文只在这里出现一次。
private enum Copy {
    static let pageTitle = "联系人"
    static let close = "完成"
    static let working = "正在处理"
    static let opensHint = "打开"
    static let verifiedOn = "已校验"

    // 顶部卡
    static let verifiedShieldHint = "这条连接已通过安全码校验"
    static let aliasLabel = "本机备注名"
    static let aliasPrompt = "给这个联系人起个本机名字"
    static let stateReady = "已连接"
    static let stateSndReady = "发送通道已就绪"
    static let stateConnecting = "连接中，稍后再来看"
    static let stateNoConnection = "还没有可用连接"
    static let stateFailed = "连接失败"
    static let stateDeleted = "联系人已删除"

    // 快捷动作
    static let search = "搜索"
    static let callAudio = "语音"
    static let callVideo = "视频"
    static let mute = "静音"
    static let unmute = "取消静音"

    // 连接与安全
    static let groupSecurity = "连接与安全"
    static let securityFootnote = "安全码要两台设备当面比对，比对上了才算校验完成。"
    static let verifyCode = "校验安全码"
    static let viewCode = "查看安全码"
    static let securityCodePage = "安全码"
    static let e2e = "端到端加密"
    static let pqResistant = "抗量子"
    static let pqStandard = "标准"
    static let incognitoProfile = "本次连接用的身份"
    static let incognitoNote = "这条连接不是用你的主身份建立的。"
    static let fixConnection = "修复连接"
    static let fixConnectionNote = "重新协商加密，完成后回到会话。"

    // 聊天
    static let groupChat = "聊天"
    static let contactPreferences = "联系人偏好"
    static let wallpaper = "聊天背景"
    static let sendReceipts = "已读回执"
    static let sendReceiptsNote = "只影响这个会话，不改全局设置。"
    static let receiptYes = "发送"
    static let receiptNo = "不发送"
    static let receiptDefaultOn = "跟随默认（开）"
    static let receiptDefaultOff = "跟随默认（关）"

    // 自动删除
    static let groupTTL = "自动删除"
    static let ttlFootnote = "把本会话的消息从这台设备上删掉，改完之后会重新载入会话。"

    // 地址
    static let groupAddress = "连接地址"
    static func addressFootnote(_ name: String) -> String {
        "把这个地址发给对方，对方就能与「\(name)」建立连接。"
    }
    static let shareAddress = "分享地址"

    // 服务器
    static let groupServers = "服务器"
    static let serversFootnote = "中继主机名可复制，用于排查连接问题。"
    static let networkStatus = "网络状态"
    static let netActive = "已订阅"
    static let netPending = "连接中"
    static let netRemoved = "已出错"
    static let netNoSub = "未订阅"
    static let networkStatusTitle = "网络状态"
    static let switchAddress = "更换接收地址"
    static let switchAddressNote = "换一个服务器接收，对方上线后完成。"
    static let abortSwitch = "中止更换地址"
    static let receivingVia = "接收中继"
    static let sendingVia = "发送中继"
    static let moreServersFormat = "共 %d 个，点击复制全部"
    static let copiedServers = "服务器地址已复制"
    static let errorSwitchAddress = "更换接收地址失败"
    static let errorAbortSwitch = "中止更换地址失败"

    // 危险操作
    static let groupDanger = "危险操作"
    static let dangerFootnote = "删除与清除都只影响这台设备上的你自己，除非你在第二步选择了通知对方。"
    static let clearHistory = "清除会话记录"
    static let clearHistoryNote = "只删本机这一侧，对方仍保留。"
    static let clearConfirmTitle = "清除会话记录？"
    static func clearConfirmMessage(_ name: String) -> String {
        "「\(name)」的全部消息会从这台设备上删除，无法撤销；对方那一份不受影响。"
    }
    static let clearConfirmButton = "清除"
    static let deleteContact = "删除联系人"
    static let deleteContactNote = "下一步会问你只删会话，还是连联系人一起删。"

    // 离开本页时未保存的偏好
    static let savePrefsTitle = "保存偏好？"
    static let savePrefsMessage = "改动还没发出去，发出去才会通知对方。"
    static let savePrefsButton = "保存并通知联系人"

    // 通话判定
    static let cantCallTitle = "无法发起通话"
    static let sendMsgToEnable = "先给对方发一条消息，通话才会打开。"
    static let contactDeleted = "联系人已删除。"
    static let contactNotReady = "正在建立连接，请稍后再试。"
    static let allowCallsTitle = "允许通话？"
    static let allowCallsMessage = "需要允许联系人向你发起通话，你才能打过去。"
    static let allow = "允许"
    static let callsProhibited = "通话被禁止"
    static let callsAskContact = "请让对方先开启通话。"
    static let callsCheckBoth = "请检查你与对方的偏好。"
    static let fixConnectionTitle = "先修复连接？"
    static let fixConnectionMessage = "这条连接的加密需要重新协商。"
    static let fix = "修复"
    static let renegotiationInProgress = "加密正在重新协商，稍后再试。"
}

// MARK: - Previews

#if DEBUG
struct PopopxChatInfoView_Previews: PreviewProvider {
    static var previews: some View {
        PopopxChatInfoView(
            chat: Chat(chatInfo: ChatInfo.sampleData.direct, chatItems: []),
            contact: Contact.sampleData,
            localAlias: "",
            featuresAllowed: contactUserPrefsToFeaturesAllowed(Contact.sampleData.mergedPreferences),
            currentFeaturesAllowed: contactUserPrefsToFeaturesAllowed(Contact.sampleData.mergedPreferences),
            onSearch: {}
        )
        .environmentObject(ChatModel.shared)
        .environmentObject(AppTheme.shared)
    }
}
#endif
