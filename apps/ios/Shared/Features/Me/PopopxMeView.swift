//
//  PopopxMeView.swift
//  POPOPX (iOS)
//
//  【第四阶段】Tab 4「我」。微信式信息架构：顶部一枚个人名片头，下面四组分卡片
//  资产与节点权益 / 加密主页与卡包 / 常用 / 隐私与安全防线（2026-11-20 重构裁定）。
//
//  结构上的五条决定：
//
//  1. 页面自己不放 NavigationStack —— 栈由 Shared/Navigation/MainTabView.swift:152-171 统一包好，
//     「中继与服务器」那三个值的 `navigationDestination` 也登记在那一层（值链接会被提到栈根，
//     写在「全部设置」自己身上一行都不生效）。
//     这里只往外推既有页面（`NavigationLink { 页面 }`，与 SettingsView.swift:405-424 同一种写法）。
//  2. 每一行都推到真实存在、且逐个核对过 init 与环境依赖的页面，没有占位行、没有 TODO。
//     `UserProfile` 依赖 `SaveableSettings`（见 PopopxProfileHost 的注释），所以照 app 现有的
//     挂载方式包一层再注入，避免 EnvironmentObject 缺失。
//  3. 本页只留与蓝牙无关的三击紧急抹除。离线组网的总闸、真实核验块与配对策略原先都在这第四张卡上，
//     2026-11-20 整块迁到厢语页右上角的设置中心（`PopopxCabinMeshSettingsSheet`，
//     `Shared/Features/Cabin/PopopxCabinView.swift`）；迁移是逐条等效的，四个落点都还经
//     `PopopxMeshRuntime.shared` 写回包里唯一的 kill switch / store / 绑定表，本页不分第二套状态。
//     紧急抹除留在这里：它抹的正是那一整套，而它只往既有的布防状态机里送轻触，确认弹窗仍由全 app
//     已挂载的那道门呈现，本页不写第二个 alert。
//  4. 这次重排只动"行住在哪个卡片里"，没有删掉任何一条既有路由：身份管理与主页名片码从行升格为
//     名片头的整行热区与二维码微标，其余行全部落在上面四组之中。「充值算力点」仍然是一枚无条件
//     入口（理由见下面 `badgeSheet` 那条注释）。2026-11-20 删掉的两行各有去处：「添加朋友」——
//     消息栏右上角「+」挂着同一个 `PopopxAddFriendView`（ChatsListView.swift:296-298）；「离线组网」
//     一行——厢语页设置中心，见决定 3。
//     真机走查 三.1/三.4 又动了常用组：「通知」与「版本」两行删掉，各有去处（全部设置 → 通知，
//     与 `PopopxHelpView` 里的版本页）；「外观与图标」「显示语言」「帮助与关于」三行从「全部设置」
//     那一二级页升上来。动的仍然只是"行住在哪个卡片里"，目的地一个都没新造，也没留第二个入口。
//  5. 徽章那一行的三条出口不另立判据：它 switch 的是 `phase.capsuleState` 这个共享枚举本身，
//     与顶栏入口 `PopopxBadgeHeaderEntry`（`PopopxBadgeSheet.entry(for:)`）读同一份状态、同一套分支，
//     将来加一档会在这里编译报错，而不是两处各说一套。
//
//  配色、字号、圆角、间距一律取 Shared/Theme/PopopxTheme.swift 的 token；控件只用
//  Shared/Components 里已有的原子库，没有新造按钮、开关或输入框（`PopopxIconBadge` 在原子库里
//  是 private，本页需要的辅助件全部内聚在这一个文件内）。文案一律英文原句即 Key，
//  新词条写进 16 个译本目录，`en.lproj` 不写冗余词条（读到 Key 本身就是英文）。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖进 POPOPX (iOS) target —— 铁律禁止脚本改 project.pbxproj。
//

import SwiftUI
import UIKit
import Foundation
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - 页面

@MainActor
struct PopopxMeView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 熔断、配对策略、抹除的唯一状态源就是 app 侧这个协调者（SettingsView.swift:627 同一个写法）。
    @ObservedObject private var meshRuntime = PopopxMeshRuntime.shared

    /// 紧急抹除的布防状态机本体：本页只往里送轻触，确认由既有的门弹。
    @ObservedObject private var panicWipe: PopopxPanicWipeManager
    @ObservedObject private var panicArming: PopopxPanicWipeArming

    /// 算力点账本：`@Observable` 单例，本页只读一格余额给入口行当副标题。
    @State private var credits = PopopxCreditsManager.shared

    @State private var toast = PopopxToastModel()
    /// 「主页名片码」那张 Sheet 的开关。入口是名片头右端的二维码微标（裁定 4：不再单占一行）。
    @State private var showsProfileQR = false
    /// 算力点生态的三张面板。徽章**详情**与**升级**现在也在本页有一行（微信式分组要求资产
    /// 直达），但它不自带判据，见上面结构决定 5 与下面 `routeBadge()`。
    @State private var showsCreditsStore = false
    @State private var showsRedeemCode = false
    @State private var showsGiftCard = false
    /// 付费墙在这里必须有第二个开关，尽管胶囊已经挂过它：胶囊按状态分发，
    /// `.activeLit` 那一档把点击交给徽章详情，于是**已经点亮的人再也没有地方买点数**。
    /// 而算力点中心那一页按它自己的文件头不挂付费墙。所以这一行是唯一的无条件入口。
    ///
    /// 三条出口（付费墙 / 体验说明 / 详情）收在一份 `PopopxBadgeSheet?` 里，与顶栏胶囊共用那个
    /// 载体（`PopopxBadgeSheetHost`）：以前这里是三条并列的 `.sheet(isPresented:)`，
    /// 体验弹窗点「看徽章详情」要在弹窗里再抬一张 sheet，系统直接丢掉，真机上就是"点了没反应"。
    @State private var badgeSheet: PopopxBadgeSheet?
    /// 名片卡右下角「添加新身份」那条快捷入口：走 push（本页就在 `NavigationStack(path:)` 里，
    /// `MainTabView.swift:152`），不弹 sheet —— 与 `UserProfilesView.swift:112-114` 那条同一写法。
    @State private var showsCreateIdentity = false
    /// 徽章运行时：`@Observable` 单例，与顶栏胶囊、徽章详情读同一份 `phase`，本页不分第二套状态。
    @State private var badge = PopopxBadgeManager.shared
    /// 本机未使用的礼品券张数。`PopopxP2PVoucherVault` 是 actor，只能在 `.task` 里 await 读，
    /// 不能在 body 里同步问它；读不到就留 0，这一行因此不会假装"有券"。
    @State private var unusedVouchers = 0
    /// 本机加密个人主页的当前档位，形如「已配置 · 常驻名片」；`nil` = 还没读出来（首帧不给假状态）。
    @State private var profileStatusValue: String?

    /// 正在切换的身份编号；nil = 此刻没有切换在跑。切换期间不接受第二次点击，否则两次
    /// `setActiveUser` 会互相抢 `ChatModel.currentUser`。
    @State private var busyUserID: Int64?

    /// 真机第 6 轮二.2 并进这张防线卡的两枚开关。键与设置页原先那两个绑定、与
    /// `PrivacySettings.swift:27`/`:18` 完全同一批（不是复制品）：打码那一枚
    /// `AppSettings.swift:45`、`:86` 导出与恢复配置时读的还是它，去跟踪那一枚由
    /// `ComposeView.swift:425` 在发消息前读。换宿主不换数据。
    @AppStorage(DEFAULT_PRIVACY_PROTECT_SCREEN) private var protectScreen = false
    @AppStorage(GROUP_DEFAULT_PRIVACY_SANITIZE_LINKS, store: groupDefaults) private var sanitizeLinks = false

    @MainActor init() {
        let runtime = PopopxMeshRuntime.shared
        _panicWipe = ObservedObject(wrappedValue: runtime.panicWipe)
        _panicArming = ObservedObject(wrappedValue: runtime.panicWipe.arming)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                nameCard
                assetEntries
                spaceEntries
                generalEntries
                securityEntries
                helpEntries
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 标题栏收掉之后，这一页的第一行就是名片卡本身。留白改由内容自己给：上边从 8 升到 24
            // （`spaceL`），让名片与状态栏之间是刻意的一段呼吸，而不是少了一行的空缺。
            .padding(.top, PopopxMetrics.spaceL)
            .padding(.bottom, PopopxMetrics.space2XL)
            // 换身份、创建身份之后整组卡片会重排。Reduce Motion 下直接落位，不做弹簧。
            .popopxAnimation(PopopxSpring.fluid, value: chatModel.currentUser?.userId, reduceMotion: reduceMotion)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.pageTitle)
        // 「我」那一行大标题不再占首屏（真机第 6 轮追加项，微信式留白）：系统标题栏整条隐藏，
        // 标题本身仍然声明着，VoiceOver 报得出这一页叫什么，只是不再画出一行。
        // 口径照消息页 `ChatsListView.swift:256`：隐藏只作用于栈的这一页，二级页自己声明可见 ——
        // 全部行链都过 `PopopxMeRowLink`，那里补了一处 `.toolbar(.visible, for: .navigationBar)`
        // 覆盖它推送的每一页；`showsCreateIdentity` 那一跳另有一处（:152 下面）。
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsProfileQR) {
            // detents 归调用方（`ProfileQRCodeSheet.swift:19` 那条约定）。这张卡的内容是
            // 名片 + 模式选择 + 动作行，比聊天里那张位置卡高得多，0.8 是它与 `nameCard`
            // 同屏时不挤掉自己动作行的那一档。
            ProfileQRCodeSheet(identityName: chatModel.currentUser?.displayName ?? Copy.profileQRIdentityFallback)
                .presentationDetents([.fraction(0.8)])
        }
        // 算力点生态的第二入口。detents 同样归调用方（上面那条约定）：购买页那一张要装下七档价格表，
        // 给 `.medium` 会让它在自己的表上滚动；兑换码最短，中档即可。
        .sheet(isPresented: $showsCreditsStore) {
            PopopxCreditsStoreView()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showsRedeemCode) {
            PopopxVoucherRedeemSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsGiftCard) {
            PopopxGiftBadgeCardSheet()
                .presentationDetents([.large])
        }
        // 徽章三条出口（付费墙 / 体验说明 / 详情）走顶栏胶囊那一个载体，detents 归载体。
        // 付费墙与算力点中心仍是两张平行的 Sheet，不是套娃：算力点中心那一行独立开（上面
        // `showsCreditsStore`），打开付费墙时它自己再挂「算力点中心」那一层
        // （`PopopxBadgePaywallView.swift:226`）。
        .popopxBadgeSheets($badgeSheet)
        // 「添加新身份」快捷入口的目标页：`CreateProfile` 自带标题与主题背景
        // （`Shared/Views/Onboarding/CreateProfile.swift:121`、`:122`），这里不重复装饰，
        // 只把主页收掉的那条标题栏在自己身上要回来 —— 这一跳不走 `PopopxMeRowLink`，
        // 所以可见性得单独声明，否则推进去是一页没有返回按钮的创建表单。
        .navigationDestination(isPresented: $showsCreateIdentity) {
            CreateProfile()
                .toolbar(.visible, for: .navigationBar)
        }
        .onChange(of: showsProfileQR) { _, opened in
            // 关掉名片码就重读一次档位：那张 Sheet 里的模式开关会改本机那份武装记录，
            // 入口行上那一格说的必须是现在真实的那一档。
            if !opened { Task { await refreshProfileStatus() } }
        }
        // 卡包那一行说的是"此刻还剩几张能用"，所以两张会动券的 Sheet 一关就重读一次：
        // 兑换把券写成已用、转赠把券交给对方，两者都不回调本页，只能回去问保险柜。
        .onChange(of: showsRedeemCode) { _, opened in
            if !opened { Task { await refreshVoucherCount() } }
        }
        .onChange(of: showsGiftCard) { _, opened in
            if !opened { Task { await refreshVoucherCount() } }
        }
        .popopxToast(toast)
        // 入口行那一格的初值：进本页读一次，换身份再读一次。读不到就是"还没制作"，
        // 这一句必须是读出来的而不是猜的——`ProfileStorageManager.loadEditable()` 返回 nil
        // 才是唯一能说"未配置"的依据。
        .task(id: chatModel.currentUser?.userId) {
            await refreshProfileStatus()
        }
        // 券是本机钥匙串里的东西，与切哪个身份无关，所以它只跟"进过这一页"绑定一次。
        .task {
            await refreshVoucherCount()
        }
    }

    // MARK: 顶部个人名片头

    @ViewBuilder private var nameCard: some View {
        if let user = chatModel.currentUser {
            PopopxIdentityCard(
                user: user,
                phase: badge.phase,
                others: switchableOthers(of: user),
                lockedCount: lockedCount,
                busyUserID: busyUserID,
                onSwitch: { info in switchIdentity(to: info) },
                onCopyUserID: { copyUserID(user.userId) },
                onShowProfileQR: {
                    PopopxHaptics.impact(.light)
                    showsProfileQR = true
                },
                onAddIdentity: { showsCreateIdentity = true }
            )
        } else {
            emptyIdentityCard
        }
    }

    /// 真·空状态：没有 `currentUser` 时不摆假名片，只说明身份是什么，并给一个既有的创建页。
    private var emptyIdentityCard: some View {
        PopopxSectionCard(footnote: Copy.emptyFootnote) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                PopopxMeAvatar(image: nil, side: PopopxMetrics.space2XL)
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.emptyTitle)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                    Text(Copy.emptyNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PopopxMeDivider()
            PopopxMeRowLink(Copy.createIdentity, systemImage: "person.crop.circle.badge.plus", tint: .brand) {
                CreateProfile()
            }
        }
    }

    /// 入口行那一格读出来的档位。优先级和这张主页实际的发送行为一致：
    /// **名片码留下的武装记录压过已保存的主页**——扫码自动推送用的就是那一档
    ///（`ProfileAutoSender.handleContactConnected(contactId:)`，ProfileAutoSender.swift:241），
    /// 所以标签跟着它说，而不是说一份这次并不会发出去的档位。
    /// 只认**还在有效期内**的那一份：`armingWindowSeconds` 一过它就推不出去了（ProfileAutoSender.swift:161 那一格会被清），
    /// 把过期显示成一个档位只会让人去关一个已经不存在的开关。
    private func refreshProfileStatus() async {
        let armed = ProfileAutoSender.shared.armedProfileScene
        if let armed, armed.expiresAt > Date() {
            profileStatusValue = "\(Copy.profileConfigured) · \(profileModeLabel(armed.mode))"
            return
        }
        guard let manifest = await ProfileStorageManager.shared.loadEditable() else {
            profileStatusValue = Copy.profileUnconfigured
            return
        }
        profileStatusValue = "\(Copy.profileConfigured) · \(profileModeLabel(manifest.sendMode))"
    }

    /// 档位怎么说归本页：`PersonalProfileModel.cardLabel` 是那两个模块内的中文常量，而本页要进
    /// 16 个语种，所以照同一个 `mode` 自己映射。两处读的是同一份档位，不会读出两种状态。
    private func profileModeLabel(_ mode: PopopxProfileSendMode) -> String {
        switch mode {
        case .ephemeral: return Copy.profileModeEphemeral
        case .standard: return Copy.profileModeStandard
        }
    }

    // MARK: 组 1 · 资产与节点权益

    private var assetEntries: some View {
        PopopxSectionCard(Copy.groupAssets, footnote: Copy.commerceFootnote) {
            PopopxPickerRow(Copy.creditsWallet, value: creditsBalanceTitle,
                            systemImage: "wallet.pass.fill", tint: .brand) {
                PopopxHaptics.selection()
                showsCreditsStore = true
            }
            PopopxMeDivider()
            PopopxPickerRow(Copy.badgeRow, value: badgeRowValue,
                            systemImage: "checkmark.shield.fill", tint: badge.phase.isLit ? .success : .neutral) {
                PopopxHaptics.selection()
                routeBadge()
            }
            .accessibilityIdentifier("popopx.me.badge")
            // 一步直达购买页的那枚胶囊。为什么不并进上面那一行：`PopopxPickerRow` 没有右侧插槽
            //（共享原子库是红线文件，它内部那枚图标底座 `PopopxIconBadge` 还是 file-private，
            // `PopopxControls.swift:315`），自己拼一行就等于重画原子，16 语种一拉长标题就露馅。
            // 所以它贴着同一张卡片、右对齐独立成行，用 `PopopxButton(fullWidth: false)` 拿到
            // 现成的品牌底色与 44pt 命中区。休眠态这一枚和整行的去处相同（都进购买页），
            // 差别只在于不用先猜"整行可点"。
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                PopopxButton(badgeActionTitle, role: .primary, fullWidth: false) {
                    badgeSheet = .paywall
                }
            }
            .padding(.top, PopopxMetrics.spaceS)
            PopopxMeDivider()
            // 无条件入口：整页只有这一行不看徽章状态就能打开面板，理由见上面 `badgeSheet`。
            // 真机第 8 轮拆页后它开的是**算力点中心**，不再是付费墙 —— 这一行的源文就是
            // "Top up Compute Credits"，商品动线拆分后还把它送进卖徽章的那一屏，正是本轮要修的混淆。
            PopopxPickerRow(Copy.purchaseCredits, systemImage: "cart.fill", tint: .brand) {
                PopopxHaptics.selection()
                showsCreditsStore = true
            }
            .accessibilityIdentifier("popopx.me.paywall")
        }
    }

    /// 徽章那一格说三档真话：休眠不写"0 天"，体验与正式不共用"剩余"这个词（口径同
    /// `PopopxBadgeCopy.remaining`）。天数一律向上取整，还剩一分钟不能说"0 天"。
    private var badgeRowValue: String {
        switch badge.phase {
        case .dormant:
            return Copy.badgeDormant
        case let .trial(expiresAt):
            return String(format: Copy.badgeTrialFormat, badgeDaysLeft(expiresAt))
        case let .active(_, expiresAt):
            return String(format: Copy.badgeRunningFormat, badgeDaysLeft(expiresAt))
        }
    }

    private func badgeDaysLeft(_ expiresAt: Date) -> Int {
        max(1, Int(ceil(max(0, expiresAt.timeIntervalSinceNow) / 86_400)))
    }

    /// 只有正式点亮态才配得上"续费"：体验期和休眠都还没开始扣费，对它们说"续费"是在编造
    /// 一段并不存在的订阅。判据用共享枚举 `capsuleState`，和 `routeBadge()` 同一份 —— 不能用
    /// `isLit`，它把体验期也算成"亮着"（`PopopxBadgeCreditsModels.swift:262`）。
    private var badgeActionTitle: String {
        switch badge.phase.capsuleState {
        case .activeLit: Copy.badgeRenew
        case .trialPulsing, .dormant: Copy.badgeBuy
        }
    }

    /// 判据只有 `PopopxBadgeSheet.entry(for:)` 这一份，顶栏胶囊走的也是它：三态 → 三出口在这里
    /// 收口，胶囊将来加一档，改那个函数会连带这里编译报错，而不是两处各说一套。
    private func routeBadge() {
        badgeSheet = PopopxBadgeSheet.entry(for: badge.phase.capsuleState)
    }

    // MARK: 组 2 · 加密主页与卡包

    private var spaceEntries: some View {
        PopopxSectionCard(Copy.groupSpace) {
            // 加密个人主页：制作器用 `NavigationLink` 推上去，不是 Sheet —— 它自己不带导航容器
            //（`ProfileBuilderView.swift:434` 那一层的约定），推上去就白拿现成的返回键。
            // `value` 那一格是这台机器上主页的当前档位；读盘是 actor hop，放在 `.task` 里，
            // 不在 body 里同步读，否则每次重排这组卡片都会去问一次磁盘。
            PopopxMeRowLink(Copy.personalProfile, value: profileStatusValue, systemImage: "person.text.rectangle.fill", tint: .brand) {
                ProfileBuilderView()
                    .navigationTitle(Copy.personalProfile)
            }
            PopopxMeDivider()
            PopopxMeRowLink(Copy.myProfile, systemImage: "person.text.rectangle", tint: .brand) {
                PopopxProfileHost()
            }
            PopopxMeDivider()
            giftVaultRow
        }
    }

    /// 卡包那一行是一条 `Menu`，不是一个页面：仓库里没有"卡包浏览页"这个视图，
    /// 只有转赠与兑换两张 Sheet，所以这一行把两个动作并成一次长按式的选择，
    /// 而不是再造一个只列本机券的第四页。行本体仍由 `PopopxPickerRow` 画，
    /// 但它自带的 `Button` 会吃掉菜单的点击，所以整行设为不可命中、交给外层 `Menu`。
    private var giftVaultRow: some View {
        Menu {
            Button(Copy.giftSend) {
                PopopxHaptics.selection()
                showsGiftCard = true
            }
            Button(Copy.redeemCode) {
                PopopxHaptics.selection()
                showsRedeemCode = true
            }
        } label: {
            PopopxPickerRow(Copy.giftVault, value: voucherValueTitle,
                            systemImage: "giftcard.fill", tint: .neutral) { }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(Text(verbatim: Copy.giftVault))
        .accessibilityValue(Text(verbatim: voucherValueTitle ?? ""))
        .accessibilityHint(Text(verbatim: Copy.giftMenuHint))
        .accessibilityIdentifier("popopx.me.giftVault")
    }

    /// 一格都没有就不显示数字：空卡包写"0 张可用"会让人以为系统里有个"张"的概念在等着凑。
    private var voucherValueTitle: String? {
        unusedVouchers > 0 ? String(format: Copy.vouchersAvailableFormat, unusedVouchers) : nil
    }

    @MainActor private func refreshVoucherCount() async {
        unusedVouchers = await PopopxP2PVoucherVault.shared.vouchers(state: .unused).count
    }

    // MARK: 组 3 · 常用

    private var generalEntries: some View {
        PopopxSectionCard(Copy.groupGeneral) {
            // 「添加朋友」这一行原先在这里，2026-11-20 删：消息栏右上角「+」已经挂着同一个
            // `PopopxAddFriendView`（ChatsListView.swift:296-298），同一件事不该在两处各有一个入口。
            // 真机第 6 轮二.1：聊天偏好、外观与图标、显示语言三行落回「全部设置」，帮助与关于
            // 升成整页最后一张卡（下面 `helpEntries`）。这一组于是只剩一件事——进全部设置。
            // 三行的目的地与装饰（`PreferencesView`/`AppearanceSettings`/`PopopxDisplayLanguageView`
            // 加各自的 `.navigationTitle` 与 `ThemedBackground`）原样搬走，一处参数没改，
            // 行尾那两个读数也回到它们本来的供应者 `PopopxSettingsValues` 同一个文件里。
            PopopxMeRowLink(Copy.settings, systemImage: "gearshape.fill") {
                PopopxPresenceGated(reason: Copy.presenceReasonSettings) {
                    PopopxSettingsView()
                        .navigationTitle(Copy.settings)
                        .modifier(ThemedBackground(grouped: true))
                }
            }
        }
    }

    // MARK: 组 5 · 帮助与关于（整页最后一张卡）

    /// 真机第 6 轮二.3：它原先是「常用」组里的尾行，头上还压着隐私防线，找开源地址与隐私政策
    /// 要往页面中间翻。现在它是最后一张卡——读完这一页，才是要不要相信它的地方。
    /// 卡片不给标题：组名与行名会是同一句话，微信那一页的最后一段也是这样只有一行。
    /// 目的地 `PopopxHelpView` 一字未动（开源地址与离线《POPOPX 隐私政策》阅读器都在那一页里）。
    private var helpEntries: some View {
        PopopxSectionCard {
            PopopxMeRowLink(Copy.helpRow, systemImage: "questionmark.circle") {
                PopopxHelpView()
                    .navigationTitle(Copy.helpRow)
            }
        }
    }

    // MARK: 组 4 · 隐私与安全防线

    /// 裁定 6：不把四件事压成一行。一行写"应用锁、双密码、防录屏、三击抹除"是不诚实的——
    /// 前两项分别在 `PrivacySettings` 与 `PopopxAntiTheftSettingsView` 两个页面里，最后一项
    /// 只活在本页这块卡上，任何一行都到不了另一行的目的地。所以拆成两行，各说各的去处。
    private var securityEntries: some View {
        PopopxSectionCard(Copy.groupSecurity) {
            PopopxMeRowLink(Copy.privacySettings, systemImage: "lock.shield.fill", tint: .brand) {
                PopopxPresenceGated(reason: Copy.presenceReasonPrivacy) {
                    PrivacySettings()
                        .navigationTitle(Copy.privacySettings)
                        .modifier(ThemedBackground(grouped: true))
                }
            }
            PopopxMeDivider()
            // 真机第 6 轮二.2：这两枚原先在「全部设置 → 隐私与安全」那张卡里。它们绑的两个键在
            // `PrivacySettings.swift:75`、`:88` 本来就各有一枚 `Toggle`，设置页那张卡只是同一批状态的
            // 第二处；本轮把它并进这张防线卡，两处于是变成「防线卡 + 隐私设置页」，能直接拨的不再藏在
            // 一次 push 后面。（要不要连隐私设置页里那两枚一起收口，已上报待裁定：那是上游的页面。）
            // 标题复用 16 个目录里已有的英文原句（`"Protect app screen"` / `"Remove link tracking"`），
            // 于是这一行与隐私设置页里那一枚说的是同一句话；两条说明是 POPOPX 自己的措辞，
            // 本轮转成 Key 并补齐 16 个译本（中文值就是设置页原来那两句）。
            // 应用锁（`PopopxLockView`）仍在隐私设置那一页里：它要 `prefPerformLA` 与
            // `currentLAMode` 两份绑定（`PrivacySettings.swift:60`），那些只有那一页自己造得出来，
            // 不在这里复刻第二套。
            PopopxToggleRow(
                Copy.protectScreenRow,
                note: Copy.protectScreenNote,
                systemImage: "eye.slash",
                tint: .neutral,
                isOn: $protectScreen
            )
            PopopxMeDivider()
            PopopxToggleRow(
                Copy.sanitizeLinksRow,
                note: Copy.sanitizeLinksNote,
                systemImage: "link.badge.plus",
                tint: .neutral,
                isOn: $sanitizeLinks
            )
            PopopxMeDivider()
            // 右侧的值只报"传感器那半边开没开"，不报双密码配没配：后者本身就是不想让旁人
            // 一眼看出来的信息，摆在第一层页面上等于替胁迫者做了排查。
            PopopxMeRowLink(
                Copy.antiTheft,
                value: PopopxAntiTheftMotionGuard.shared.enabled ? Copy.antiTheftOn : Copy.antiTheftOff,
                systemImage: "exclamationmark.shield.fill",
                tint: .brand
            ) {
                PopopxAntiTheftSettingsView()
                    .navigationTitle(Copy.antiTheft)
                    .modifier(ThemedBackground(grouped: true))
            }
            .accessibilityIdentifier("popopx.me.antiTheft")
            PopopxMeDivider()
            // 离线组网的总闸、真实核验块与配对策略原先都在这张卡上，2026-11-20 整块迁到
            // 厢语页右上角的设置中心（`PopopxCabinMeshSettingsSheet`）。这一张卡留的是与蓝牙
            // 无关的三道防线；三击抹除留在最后，因为它抹的正是迁走的那套 mesh 数据。
            panicBlock
        }
    }

    /// 余额这一格读账本本身，不读某一次购买回调里的数：面板关掉之后这一行必须自己变对。
    /// 装载不必在这里做——`PopopxCreditsManager.start()` 的第一行就是 `loadIfNeeded()`
    /// （PopopxCreditsManager.swift:79-86），而那一跳排在 `POPOPXApp.init()` 里。
    private var creditsBalanceTitle: String {
        String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance)
    }

    /// 危险行 + 它自己的说明合成一块，卡片里只占一个位置。
    private var panicBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            panicWipeRow
            Text(Copy.panicNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 唯一一行红色（§1.1 危险 = 系统红）：紧急抹除。它不自己弹确认。
    private var panicWipeRow: some View {
        PopopxPickerRow(
            Copy.panicRow,
            value: panicValue,
            systemImage: "exclamationmark.triangle.fill",
            tint: .danger
        ) {
            armPanicWipe()
        }
        .disabled(!meshRuntime.isFuseOn)
        .opacity(meshRuntime.isFuseOn ? 1 : 0.45)
        .accessibilityHint(Text(verbatim: Copy.panicRowHint))
    }

    /// 可切换的其它身份：与 UserPicker.swift:33-35 同一口径 —— 加锁（`user.hidden`，即有
    /// `viewPwdHash`）的身份不进切换器，因为这里传的是 `viewPwd: nil`，带着 nil 去切加锁身份只会
    /// 失败。加锁身份由「身份管理」页处理：它把搜索框当密码框用，走
    /// `changeActiveUserAsync_(_:viewPwd:)` 的真密码分支（UserProfilesView.swift:338 + :221）。
    private func switchableOthers(of user: User) -> [UserInfo] {
        chatModel.users
            .filter { !$0.user.hidden && $0.user.userId != user.userId }
            .sorted { $0.user.activeOrder > $1.user.activeOrder }
    }

    private var lockedCount: Int {
        chatModel.users.filter { $0.user.hidden }.count
    }

    @MainActor private func switchIdentity(to info: UserInfo) {
        guard busyUserID == nil else { return }
        busyUserID = info.user.userId
        Task { @MainActor in
            defer { busyUserID = nil }
            do {
                try await changeActiveUserAsync_(info.user.userId, viewPwd: nil)
                PopopxHaptics.notice(.success)
                toast.show(Copy.switchDone, kind: .encrypted)
            } catch {
                logger.error("popopx me: switching identity \(info.user.userId) failed: \(responseError(error))")
                PopopxHaptics.notice(.error)
                toast.show(Copy.switchFailed, kind: .danger)
            }
        }
    }

    @MainActor private func copyUserID(_ userID: Int64) {
        UIPasteboard.general.string = String(userID)
        PopopxHaptics.impact(.light)
        toast.show(Copy.copiedUserID, kind: .success)
    }

    /// 只往既有的布防状态机里送一次轻触：`PopopxPanicWipeArming.tap` 自己判定"一秒内正好三次"。
    /// 确认弹窗是 `PopopxPanicWipeGate` 的职责，而它已经由 `PopopxMeshPanicWipeMount`
    /// （POPOPXApp.swift:48 → POPOPXAPI.swift:4013-4030）挂在 app 根上、绑定同一个
    /// `isAwaitingConfirmation`。所以这里绝不写第二个 alert：写了就有两道确认抢同一个状态机，
    /// 而铁律要的是一次、且只有那一次确认。熔断关闭时那道门根本不存在
    /// （POPOPXAPI.swift:4022 的 `if runtime.isFuseOn`），所以这一行同时被禁用。
    @MainActor private func armPanicWipe() {
        guard meshRuntime.isFuseOn else { return }
        PopopxHaptics.impact(.light)
        _ = panicWipe.tap()
    }

    /// 行尾的值就是状态机此刻的真话，不是"我按过了吧"。
    private var panicValue: String {
        if panicWipe.isWiping { return Copy.panicWiping }
        if panicArming.isAwaitingConfirmation { return Copy.panicAwaiting }
        if !meshRuntime.isFuseOn { return Copy.panicDisabled }
        let taps = panicArming.tapCount
        return taps > 0 ? String(format: Copy.panicTapsFormat, taps) : Copy.panicReady
    }
}

// MARK: - 顶部个人名片头

/// 微信式名片头：64pt 头像 + 粗体身份名 + 双模状态条，右端二维码微标与 `chevron.right`。
/// 整行（头像到状态条）推「身份管理」，二维码微标是并列的第二个按钮 —— 所以这两个按钮必须是
/// **兄弟**而不是嵌套：`Button` 套 `Button` 只会让外层吃掉点击，名片码就打不开了。
@MainActor
private struct PopopxIdentityCard: View {
    private let user: User
    private let phase: PopopxBadgePhase
    private let others: [UserInfo]
    private let lockedCount: Int
    private let busyUserID: Int64?
    private let onSwitch: (UserInfo) -> Void
    private let onCopyUserID: () async -> Void
    private let onShowProfileQR: () -> Void
    private let onAddIdentity: () -> Void

    init(
        user: User,
        phase: PopopxBadgePhase,
        others: [UserInfo],
        lockedCount: Int,
        busyUserID: Int64?,
        onSwitch: @escaping (UserInfo) -> Void,
        onCopyUserID: @escaping () async -> Void,
        onShowProfileQR: @escaping () -> Void,
        onAddIdentity: @escaping () -> Void
    ) {
        self.user = user
        self.phase = phase
        self.others = others
        self.lockedCount = lockedCount
        self.busyUserID = busyUserID
        self.onSwitch = onSwitch
        self.onCopyUserID = onCopyUserID
        self.onShowProfileQR = onShowProfileQR
        self.onAddIdentity = onAddIdentity
    }

    /// 边长不写裸数字：大头像 = spaceXL × 2（64pt），切换器里的小头像 = spaceXL。
    private static let avatarSide: CGFloat = PopopxMetrics.spaceXL * 2
    private static let chipAvatarSide: CGFloat = PopopxMetrics.spaceXL

    var body: some View {
        PopopxSectionCard(footnote: footnote) {
            HStack(spacing: PopopxMetrics.space2XS) {
                nameRow
                profileQRButton
                disclosureChevron
            }
            PopopxMeDivider()
            identityNumberLine
            if !others.isEmpty {
                PopopxMeDivider()
                switcher
            }
            PopopxMeDivider()
            addIdentityRow
        }
    }

    /// 「添加新身份」快捷入口，收在名片底部操作条的右端。真机反馈是这条路由太难找：原来要先推
    /// 「身份管理」、再点「添加档案」两步（`UserProfilesView.swift:87-97`），这一枚把它压成一步。
    /// 措辞复用既有词条 `Copy.createIdentity`（"Create a new identity"，16 个目录都已有译法），
    /// 所以本轮不新增 Key。动作走宿主登记的 push：`CreateProfile` 是一张 Form，
    /// 塞进 sheet 会丢返回手势，也与 `UserProfilesView.swift:112-114` 那条同一写法。
    private var addIdentityRow: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Spacer(minLength: PopopxMetrics.spaceXS)
            PopopxButton(Copy.createIdentity, systemImage: "person.badge.plus", role: .secondary, fullWidth: false) {
                PopopxHaptics.selection()
                onAddIdentity()
            }
        }
        .padding(.vertical, PopopxMetrics.space2XS)
        .accessibilityIdentifier("popopx.me.addIdentity")
    }

    private var nameRow: some View {
        NavigationLink {
            UserProfilesView()
                .navigationTitle(Copy.manageIdentities)
                .modifier(ThemedBackground(grouped: true))
        } label: {
            HStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
                PopopxMeAvatar(image: user.image, side: Self.avatarSide)
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(user.displayName)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsFullName {
                        Text(user.fullName)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PopopxMeStatusCapsule(phase: phase)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .padding(PopopxMetrics.space2XS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(verbatim: Copy.manageIdentitiesHint))
    }

    /// 名片码微标。44×44 的命框由 `minHitTarget` 兜住，图标本身只有 `spaceM`。
    private var profileQRButton: some View {
        Button(action: onShowProfileQR) {
            Image(systemName: "qrcode")
                .font(PopopxType.microTag)
                .imageScale(.large)
                .foregroundStyle(PopopxPalette.brand)
                .frame(width: PopopxMetrics.spaceM, height: PopopxMetrics.spaceM)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Text(verbatim: Copy.personalProfileQR))
        .accessibilityHint(Text(verbatim: Copy.linkHint))
        .accessibilityIdentifier("popopx.me.profileQR")
    }

    /// 装饰用的箭头：命框在左边的 `nameRow` 上，所以它自己不进无障碍树。
    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(PopopxPalette.labelHint)
            .accessibilityHidden(true)
    }

    private var switcher: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(Copy.otherIdentities)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PopopxMetrics.spaceS) {
                    ForEach(others) { info in
                        PopopxIdentityChip(
                            name: info.user.displayName,
                            image: info.user.image,
                            unread: info.unreadCount,
                            busy: busyUserID == info.user.userId,
                            action: { onSwitch(info) }
                        )
                    }
                }
                .padding(.vertical, PopopxMetrics.space2XS)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 昵称与全名相同（或全名为空）时不重复念一遍 —— 口径同 SettingsView.swift:690 的 `profileName`。
    private var showsFullName: Bool {
        !user.fullName.isEmpty && user.fullName != user.displayName
    }

    private var identityNumberLine: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.space2XS) {
                Text(Copy.identityNumberLabel)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Text(verbatim: "\(user.userId)")
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Copy.identityNumberLabel))
            .accessibilityValue(Text(verbatim: "\(user.userId)"))

            Spacer(minLength: PopopxMetrics.spaceXS)

            PopopxButton(
                Copy.copyUserID,
                systemImage: "doc.on.doc",
                role: .ghost,
                fullWidth: false,
                action: onCopyUserID
            )
        }
        .padding(PopopxMetrics.space2XS)
    }

    private var footnote: String? {
        if others.isEmpty {
            return lockedCount > 0 ? String(format: Copy.lockedOnlyNoteFormat, lockedCount) : nil
        }
        return lockedCount > 0
            ? String(format: Copy.switchNoteWithLockedFormat, lockedCount)
            : Copy.switchNote
    }
}

/// 名片头部的双模状态条：左段是在线传输（SMP），右段是节点权益档位。
/// 两段各读各的唯一真值源（传输口径沿用引导页那条已译好的 Key，权益读 `PopopxBadgeManager.phase`），
/// 本页不再判第三条通道。着色只用 `successInk` / `labelSecondary`：
/// §1.1 里青绿专指离线厢语，拿它给在线权益上色会伪造一条并不存在的传输通道。
private struct PopopxMeStatusCapsule: View {
    private let phase: PopopxBadgePhase

    init(phase: PopopxBadgePhase) {
        self.phase = phase
    }

    var body: some View {
        let tint = phase.isLit ? PopopxPalette.successInk : PopopxPalette.labelSecondary
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: "lock.fill")
                .font(PopopxType.microTag)
                .imageScale(.medium)
            Text(Copy.smpEncrypted)
                .font(PopopxType.microTag)
            Text(verbatim: "·")
                .font(PopopxType.microTag)
            Text(badgeWords)
                .font(PopopxType.microTag)
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, PopopxMetrics.spaceS)
        .padding(.vertical, PopopxMetrics.space2XS)
        .background(PopopxPalette.brand.opacity(0.10), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: PopopxMetrics.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(Copy.smpEncrypted), \(badgeWords)"))
    }

    /// 短到能跟在身份名后面不换行：休眠只说"未激活"，点亮与体验各说自己的天数。
    private var badgeWords: String {
        switch phase {
        case .dormant:
            return Copy.badgeDormant
        case let .trial(expiresAt):
            return String(format: Copy.badgeTrialShortFormat, Self.daysLeft(expiresAt))
        case let .active(_, expiresAt):
            return String(format: Copy.badgeActiveShortFormat, Self.daysLeft(expiresAt))
        }
    }

    private static func daysLeft(_ expiresAt: Date) -> Int {
        max(1, Int(ceil(max(0, expiresAt.timeIntervalSinceNow) / 86_400)))
    }
}

/// 一枚可点的其它身份。整颗就是 `Button`，44pt 高，VoiceOver 念名字 + "以这个身份继续"。
@MainActor
private struct PopopxIdentityChip: View {
    private let name: String
    private let image: String?
    private let unread: Int
    private let busy: Bool
    private let action: () -> Void

    init(name: String, image: String?, unread: Int, busy: Bool, action: @escaping () -> Void) {
        self.name = name
        self.image = image
        self.unread = unread
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PopopxMetrics.space2XS) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PopopxPalette.brand)
                        .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                } else {
                    PopopxMeAvatar(image: image, side: Self.chipAvatarSide)
                }
                Text(name)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(1)
                if unread > 0 {
                    unreadBadge
                }
            }
            .padding(.horizontal, PopopxMetrics.spaceS)
            // 44pt 是下限而不是定值：大号动态字体下这颗 chip 要能长高，不能裁掉名字。
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(busy)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(unread > 0 ? Text(verbatim: String(format: Copy.unreadBadgeFormat, unread)) : Text(verbatim: ""))
        .accessibilityHint(Text(verbatim: Copy.switchHint))
    }

    /// 未读口径直接取 `UserInfo.unreadCount`（ChatTypes.swift:104），本文件不再算第二套。
    /// 数字本身不进无障碍树：整颗 chip 已经把它念成 value。
    private var unreadBadge: some View {
        Text(verbatim: "\(unread)")
            .font(PopopxType.metricSmall)
            .foregroundStyle(PopopxPalette.onBrand)
            .padding(.horizontal, PopopxMetrics.space2XS)
            .frame(minWidth: PopopxMetrics.spaceL, minHeight: PopopxMetrics.space2XL / 2)
            .background(PopopxPalette.brand, in: Capsule())
            .accessibilityHidden(true)
    }

    private static let chipAvatarSide: CGFloat = PopopxMetrics.spaceXL
}

/// 头像。有 base64 就用既有的 `ProfileImage`，没有就落到品牌标记 —— 不画占位人形，
/// 也不画"按身份派生色相的几何渐变首字母"（裁定 5）：全仓没有 `colorForProfile` 这一类
/// 按身份给色相的 helper（0 命中），而 §1.1 里靛紫只说"在线身份"、青绿只说"离线厢语"，
/// 拿色相当纯装饰就会伪造一条并不存在的传输通道。宁可空着，不猜。
@MainActor
private struct PopopxMeAvatar: View {
    private let image: String?
    private let side: CGFloat

    /// 本机已解锁的外观。与外层同一个单例，不是第二份状态：这里只读 `owns`，
    /// 花费仍然只在算力点中心那一页发生。
    @State private var credits = PopopxCreditsManager.shared

    /// 只有大头像那一档描边：芯片档的 `side` 是 `spaceXL`，1.5pt 的双色环在那个尺寸上
    /// 糊成一圈脏边，看不出"外观"反而看出"渲染坏了"。阈值写成两倍而不是直接比 `avatarSide`，
    /// 是为了不在同一个类型里再抄一遍外层那两个尺寸常量。
    private static let ringMinimumSide: CGFloat = PopopxMetrics.spaceXL * 2

    private var wearsAuroraFrame: Bool {
        side >= Self.ringMinimumSide && credits.owns(.auroraShieldAvatarFrame)
    }

    init(image: String?, side: CGFloat) {
        self.image = image
        self.side = side
    }

    var body: some View {
        Group {
            if imageFromBase64(image) != nil {
                // `color:` 走 UserPicker.swift:44 同一个值：`ProfileImage` 内部按
                // `asAnotherColorFromSecondaryVariant` 映射这张图在分组背景上的深浅，换掉它就错。
                ProfileImage(imageStr: image, size: side, color: Color(uiColor: .tertiarySystemGroupedBackground))
            } else {
                Image(PopopxBrandAsset.mark)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous))
            }
        }
        .frame(width: side, height: side)
        // 「极光盾头像框」：只描在本机自己的头像外面。这一族头像类型只画本机身份
        // （联系人和群的头像各有各的类型），所以算力点中心那句"本机头像渲染生效，不上传"
        // 在这里是结构成立的，不需要再判一次方向。
        // `strokeBorder` 而不是 `stroke`：前者向内吃线宽，头像尺寸不会被撑大，
        // 同一张卡上的身份名与地址不会因为买了外观而挪一行。
        // 两个色停在环上对角走，起点仍是 `PopopxPalette.brand`：这一档不替换品牌色，只加一圈。
        .overlay {
            if wearsAuroraFrame {
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [PopopxPalette.brand, Self.auroraFrameEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: PopopxMetrics.stroke
                    )
            }
        }
        // 头像在这页永远是装饰：身份名就在同一张卡上，不让 VoiceOver 念两遍。
        .accessibilityHidden(true)
    }

    /// 极光盾的终点色（青）。这一档唯一不在 `PopopxPalette` 里的值，也是整个商业特性里
    /// 装饰色就该待处的位置：只有这一处读它，别处要用就得先解锁再描边，而不是一份共享 token。
    private static let auroraFrameEnd = Color.popopx(light: 0x1F8A70, dark: 0x4FD8B6)
}

/// 「推一个既有页面」的一行。外观直接复用 `PopopxPickerRow`，但点击交给外层 `NavigationLink`：
/// 原子库里的行本身是个 `Button`，嵌套按钮会把链接的点击吃掉，所以这一行整体设为不可命中、
/// 也不进无障碍树，由链接自己带上同名的 label 与 hint（44pt 由 `minHitTarget` 兜住）。
@MainActor
/// 敏感页面的"在场核验"外壳（防盗模块二）。通不过就**一帧正文都不画**。
///
/// 为什么不拦在 `NavigationLink` 上：这一族的行是目标式链接，拦推送要改整个 Me 页的
/// 导航结构；而 `.suspicious` 的语义是"手机可能正握在别人手里"，晚一帧渲染正文就是泄露。
/// 被拒时模块二已经把用户落到全屏遮罩上，所以这里只需要 `dismiss()` 把自己退掉，
/// 不必再画一条"已拒绝"——多一个提示就多一个可被胁迫者读到的信号。
private struct PopopxPresenceGated<Content: View>: View {
    private let reason: String
    private let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var allowed = false

    init(reason: String, @ViewBuilder content: @escaping () -> Content) {
        self.reason = reason
        self.content = content
    }

    var body: some View {
        if allowed {
            content()
        } else {
            // 与页面底色同色的空壳：不能是空白页，也不能是转圈——两者都在传递"被拦下了"。
            Color.clear
                .task {
                    if await PopopxBehaviorGuard.shared.authorized(reason: reason) {
                        allowed = true
                    } else {
                        dismiss()
                    }
                }
        }
    }
}

private struct PopopxMeRowLink<Destination: View>: View {
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
            // 主页把整条标题栏收掉了（微信式首屏），而"隐藏"会随这一层的工具条偏好渗进推进去的页面 ——
            // 消息页同一件事的做法是在目的地自己声明可见（`ChatsListView.swift:408`）。全部行链都过
            // 这里，所以一句就够：子页面各自的 `.navigationTitle` 照旧生效，返回按钮一个不少。
            destination()
                .toolbar(.visible, for: .navigationBar)
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

/// 卡片内的分隔线。`PopopxControls.swift:853` 里那条同名的只在 `#if DEBUG` 的画廊里，够不着。
private struct PopopxMeDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

/// `UserProfile` 需要环境里的 `SaveableSettings`（UserProfile.swift:16，body 里写 `ss.profileSave`），
/// 而那个对象只在挂载它的子树里现造（ChatListView.swift:81 建、:159 注入）。照同一个做法包一层，
/// 否则推进去就是 EnvironmentObject 缺失。
private struct PopopxProfileHost: View {
    @StateObject private var settings = SaveableSettings()

    var body: some View {
        UserProfile()
            .navigationTitle(Copy.myProfile)
            .modifier(ThemedBackground(grouped: true))
            .environmentObject(settings)
    }
}

// MARK: - 文案

/// 页面上每一句看得见的（或 VoiceOver 念得出的）话都只在这里出现一次，并且一律走
/// `NSLocalizedString`：**英文原句就是 Key**，与引导页、算力点生态同一套做法。
/// 新词条写进 `bg/cs/de/es/fi/fr/hu/it/ja/nl/pl/ru/th/tr/uk/zh-Hans` 共 16 个译本目录，
/// `en.lproj` 不写（读不到词条就回落 Key 本身，那就是英文）。
/// 两个 Key 是刻意复用的既有词条 —— `"Settings"`、`"SMP end-to-end encrypted"`：
/// 它们在 16 个目录里都已经有译法，且中文值正是本页要显示的那句。
private enum Copy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX Me tab")
    }

    static let pageTitle = key("Me")
    static let linkHint = key("Open")

    // 顶部个人名片头
    static let identityNumberLabel = key("Identity number")
    static let copyUserID = key("Copy number")
    static let copiedUserID = key("Identity number copied")
    static let manageIdentities = key("Manage identities")
    static let manageIdentitiesHint = key("Opens the identity list on this device")
    static let smpEncrypted = NSLocalizedString("SMP end-to-end encrypted", comment: "Me: transport segment of the name card status capsule")
    static let otherIdentities = key("Switch to another identity")
    static let switchHint = key("Continue as this identity")
    static let switchDone = key("Identity switched")
    static let switchFailed = key("Switch failed. Try again later.")
    static let switchNote = key("Locked identities are not listed here: switching to them needs the view password.")
    static let switchNoteWithLockedFormat = NSLocalizedString("Tap an avatar to switch; this device has %d locked identities that need the view password in Manage identities.", comment: "Me: identity switcher footnote")
    static let lockedOnlyNoteFormat = NSLocalizedString("This device has %d locked identities that need the view password before you can switch.", comment: "Me: identity switcher footnote, no switchable identity")
    static let unreadBadgeFormat = NSLocalizedString("%d unread", comment: "Me: unread count spoken on an identity chip")
    static let emptyTitle = key("No active identity yet")
    static let emptyNote = key("An identity is your anonymous card on popopx: a display name, an avatar and a message store of its own. Create one and you can start chatting.")
    static let emptyFootnote = key("Creating an identity asks for no phone number and no email.")
    static let createIdentity = key("Create a new identity")

    // 组标题
    static let groupAssets = key("Assets and node benefits")
    /// 2026-11-20 换源文：这一组里原来那一行「离线组网」整块迁到厢语页，标题再说"离线组网"
    /// 就是替别人占一个说法。旧 Key `"Personal space and offline mesh"` 在代码里残留 0。
    static let groupSpace = key("Encrypted profile and card vault")
    static let groupGeneral = key("Everyday")
    static let groupSecurity = key("Privacy and security defences")

    // 组 1 · 算力点与徽章
    static let creditsWallet = key("Compute Credits wallet")
    static let badgeRow = key("Dynamic privacy node badge")
    static let badgeDormant = key("Not activated")
    static let badgeTrialFormat = NSLocalizedString("Trial: %d days left", comment: "Me: badge row value, pioneer trial")
    static let badgeRunningFormat = NSLocalizedString("Running: %d days left", comment: "Me: badge row value, active badge")
    static let badgeTrialShortFormat = NSLocalizedString("Trial %d days", comment: "Me: name card capsule, pioneer trial")
    static let badgeActiveShortFormat = NSLocalizedString("Routing %d days", comment: "Me: name card capsule, active badge")
    /// 「充值」而不是「购买算力点礼包」：这一档没有任何赠送，句子也不能暗示有。
    static let purchaseCredits = key("Top up Compute Credits")
    /// 徽章行右侧那一枚直达购买/续费的胶囊。词要短到能压在 393pt 宽度里，
    /// 所以是「购买」「续费」两个词，不是「立即购买正式徽章」那一句（那一句在弹窗里）。
    static let badgeBuy = key("Buy")
    static let badgeRenew = key("Renew")

    // 组 2 · 加密个人主页与卡包
    static let myProfile = key("My profile")
    static let personalProfile = key("My encrypted profile page")
    static let personalProfileQR = key("Profile card code")
    static let profileConfigured = key("Configured")
    static let profileUnconfigured = key("Not created yet")
    static let profileModeEphemeral = key("Burn after reading")
    static let profileModeStandard = key("Persistent card")
    static let profileQRIdentityFallback = key("Unnamed identity")
    static let giftVault = key("Gift badge cards and redemption")
    static let giftSend = key("Gift a badge card")
    static let redeemCode = key("Redeem a code")
    static let vouchersAvailableFormat = NSLocalizedString("%d available", comment: "Me: unused gift vouchers on this device")
    static let giftMenuHint = key("Lets you gift a badge card or redeem a code")

    // 组 3 · 常用
    // 「聊天偏好」「外观与图标」「显示语言」三行 2026-11-20 落回「全部设置」（真机第 6 轮二.1）：
    // 源文与 `notifyOn`/`notifyOff` 两个值说法一起搬进
    // `Shared/Features/Settings/PopopxSettingsViews.swift` 的 `PopopxGeneralCopy`，Key 一字未改，
    // 16 个译本原地不动，所以这一页不再引用这四条。刻意不叫 `"Chat preferences"` 那条理由跟着
    // 那一行走：`"Chat preferences"` 这个 Key 在 16 个目录里属于别的页面，中文值是「聊天偏好设置」，
    // 源文必须保持唯一化。
    static let settings = NSLocalizedString("Settings", comment: "Me: reuses the existing all-catalog term")
    // 「通知」那一行 2026-11 删：唯一入口收在 常用 → 全部设置 → 通知；「版本」那一行随
    // `PopopxHelpView` 升格 —— 旧 Key `"Notifications"` 与 `"Version and updates"` 在本页不再有引用，
    // 两个词条本身仍属于别的页面，译本不动。
    /// 「帮助与关于」现在是整页最后一张卡的唯一一行（见上面 `helpEntries`），说法没变。
    static let helpRow = key("Help and about")

    // 组 4 · 隐私与安全防线
    static let privacySettings = key("Privacy and security settings")
    /// 两枚开关的标题复用 16 个目录里已有的原句 —— 它们与 `PrivacySettings.swift:75`/`:88`
    /// 那两枚 `Toggle` 是同一个开关，说法必须同一个 Key，不再由这一页另起一句中文。
    static let protectScreenRow = key("Protect app screen")
    static let sanitizeLinksRow = key("Remove link tracking")
    /// 两条说明是设置页原来那两句中文，本轮转成 Key 并补齐 16 个译本（中文值逐字沿用）。
    static let protectScreenNote = key("While the app is in the background its whole interface is replaced by a placeholder, so the app switcher and screenshots show no chat content.")
    static let sanitizeLinksNote = key("Tracking fields are stripped from links while you compose a message, so what the other side receives carries no trace of your source.")
    static let antiTheft = key("Anti-theft lock")
    static let antiTheftOn = key("Turned on")
    static let antiTheftOff = key("Turned off")
    /// 在场核验的理由文案：它进的是系统生物识别提示框，所以同样是看得见的文案。
    static let presenceReasonPrivacy = key("Confirm this is you before opening privacy and security settings")
    static let presenceReasonSettings = key("Confirm this is you before opening settings")
    static let commerceFootnote = key("Credits and badges live only in this device's keychain: no server keeps the ledger, and neither side can change it remotely.")

    // 危险行
    static let panicRow = key("Erase offline mesh data now")
    static let panicReady = key("Triple tap")
    static let panicTapsFormat = NSLocalizedString("%d/3 taps counted", comment: "Me: panic wipe arming progress")
    static let panicAwaiting = key("Waiting for confirmation")
    static let panicWiping = key("Erasing…")
    static let panicDisabled = key("Unavailable while the fuse is closed")
    static let panicRowHint = key("Three taps within one second arm it")
    static let panicNote = key("Three taps on this row within one second arm the wipe; the app's single confirmation dialog then asks you once. Cancelling voids it — nothing is ever erased silently. While the fuse is closed that dialog does not exist, so this row is disabled too.")
}

// MARK: - Previews

#if DEBUG
struct PopopxMeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxMeView()
        }
        .environmentObject(ChatModel.shared)
        .environmentObject(AppTheme.shared)
    }
}

struct PopopxMeViewPopulated_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxMeView()
        }
        .environmentObject(ChatModel.shared)
        .environmentObject(AppTheme.shared)
        .onAppear {
            // 预览可以没有活数据：这里只把既有的 sampleData 交给共享模型，
            // 空状态那张卡本身没有造假数据（上一张预览就是它的真实样子）。
            if ChatModel.shared.currentUser == nil {
                ChatModel.shared.currentUser = User.sampleData
                ChatModel.shared.users = [UserInfo.sampleData]
            }
        }
    }
}
#endif
