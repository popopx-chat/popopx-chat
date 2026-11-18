//
//  PopopxMeView.swift
//  POPOPX (iOS)
//
//  【第四阶段】Tab 4「我」。顶部一枚大的当前身份卡，下面五组分卡片：
//  身份 / 通用 / 隐私与安全 / 离线组网 / 关于（裁定 B、§2.3）。
//
//  结构上的三条决定：
//
//  1. 页面自己不放 NavigationStack —— 栈由 Shared/Navigation/MainTabView.swift:90-92 统一包好。
//     这里只往外推既有页面（`NavigationLink { 页面 }`，与 SettingsView.swift:405-424 同一种写法），
//     以及用 sheet 呈现自带栈的页面（`PopopxAddFriendView` 内部已有自己的 NavigationStack）。
//  2. 每一行都推到真实存在、且逐个核对过 init 与环境依赖的页面，没有占位行、没有 TODO。
//     `UserProfile` 依赖 `SaveableSettings`（见 PopopxProfileHost 的注释），所以照 app 现有的
//     挂载方式包一层再注入，避免 EnvironmentObject 缺失。
//  3. 离线组网那一组不新建第二套状态：开关与策略都经 `PopopxMeshRuntime.shared` 写回包里唯一的
//     kill switch / store；开关下面那块状态文字是 `verifiedActivitySnapshot()` 亲口回答的核验结果
//     （phase + 真在跑的蓝牙/界面组件 + 事件订阅数），不是 SwiftUI 自己记住的那个布尔。紧急抹除
//     只往既有的布防状态机里送轻触，确认弹窗仍由全 app 已挂载的那道门呈现，本页不写第二个 alert。
//
//  配色、字号、圆角、间距一律取 Shared/Theme/PopopxTheme.swift 的 token；控件只用
//  Shared/Components 里已有的原子库，没有新造按钮、开关或输入框。
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

    @State private var toast = PopopxToastModel()
    @State private var showsAddFriend = false
    @State private var showsPairingPolicy = false
    /// 「主页名片码」那张 Sheet 的开关（入口就在下面 `identityEntries` 第二组里）。
    @State private var showsProfileQR = false
    /// 本机加密个人主页的当前档位，形如「已配置 · 常驻名片」；`nil` = 还没读出来（首帧不给假状态）。
    @State private var profileStatusValue: String?

    /// 正在切换的身份编号；nil = 此刻没有切换在跑。切换期间不接受第二次点击，否则两次
    /// `setActiveUser` 会互相抢 `ChatModel.currentUser`。
    @State private var busyUserID: Int64?

    /// kill switch 亲口回答的核验快照；nil = 本次运行还没核验过（不替它猜一个默认值显示）。
    @State private var verifiedSnapshot: PopopxMeshActivitySnapshot?

    @MainActor init() {
        let runtime = PopopxMeshRuntime.shared
        _panicWipe = ObservedObject(wrappedValue: runtime.panicWipe)
        _panicArming = ObservedObject(wrappedValue: runtime.panicWipe.arming)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                identityCard
                identityEntries
                generalEntries
                privacyEntries
                meshEntries
                aboutEntries
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
            // 换身份、创建身份之后整组卡片会重排。Reduce Motion 下直接落位，不做弹簧。
            .popopxAnimation(PopopxSpring.fluid, value: chatModel.currentUser?.userId, reduceMotion: reduceMotion)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.pageTitle)
        .sheet(isPresented: $showsAddFriend) {
            PopopxAddFriendView()
        }
        .sheet(isPresented: $showsPairingPolicy) {
            pairingPolicySheet
        }
        .sheet(isPresented: $showsProfileQR) {
            // detents 归调用方（`ProfileQRCodeSheet.swift:19` 那条约定）。这张卡的内容是
            // 名片 + 模式选择 + 动作行，比聊天里那张位置卡高得多，0.8 是它与 `identityCard`
            // 同屏时不挤掉自己动作行的那一档。
            ProfileQRCodeSheet(identityName: chatModel.currentUser?.displayName ?? Copy.profileQRIdentityFallback)
                .presentationDetents([.fraction(0.8)])
        }
        .onChange(of: showsProfileQR) { _, opened in
            // 关掉名片码就重读一次档位：那张 Sheet 里的模式开关会改本机那份武装记录，
            // 入口行上那一格说的必须是现在真实的那一档。
            if !opened { Task { await refreshProfileStatus() } }
        }
        .popopxToast(toast)
        // 开关一翻就去核验。`.task(id:)` 在熔断镜像变化时重跑；稳定态下只多一次 actor hop。
        .task(id: meshRuntime.isFuseOn) {
            await refreshVerification(waitingForSettle: true)
        }
        // 入口行那一格的初值：进本页读一次，换身份再读一次。读不到就是"还没制作"，
        // 这一句必须是读出来的而不是猜的——`ProfileStorageManager.loadEditable()` 返回 nil
        // 才是唯一能说"未配置"的依据。
        .task(id: chatModel.currentUser?.userId) {
            await refreshProfileStatus()
        }
    }

    // MARK: 顶部身份卡

    @ViewBuilder private var identityCard: some View {
        if let user = chatModel.currentUser {
            PopopxIdentityCard(
                user: user,
                others: switchableOthers(of: user),
                lockedCount: lockedCount,
                busyUserID: busyUserID,
                onSwitch: { info in switchIdentity(to: info) },
                onCopyUserID: { copyUserID(user.userId) }
            )
        } else {
            emptyIdentityCard
        }
    }

    /// 真·空状态：没有 `currentUser` 时不摆假名片，只说明身份是什么，并给一个既有的创建页。
    private var emptyIdentityCard: some View {
        PopopxSectionCard(Copy.identityCardTitle, footnote: Copy.emptyFootnote) {
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
    /// 只认**还在有效期内**的那一份：`armingWindowSeconds` 一过它就推不出去了（ProfileAutoSender.swift:168 那一格会被清），
    /// 把过期显示成一个档位只会让人去关一个已经不存在的开关。
    private func refreshProfileStatus() async {
        let armed = ProfileAutoSender.shared.armedProfileScene
        if let armed, armed.expiresAt > Date() {
            profileStatusValue = "\(Copy.profileConfigured) · \(armed.mode.cardLabel)"
            return
        }
        guard let manifest = await ProfileStorageManager.shared.loadEditable() else {
            profileStatusValue = Copy.profileUnconfigured
            return
        }
        profileStatusValue = "\(Copy.profileConfigured) · \(manifest.sendMode.cardLabel)"
    }

    // MARK: 身份

    private var identityEntries: some View {
        PopopxSectionCard(Copy.groupIdentity) {
            PopopxMeRowLink(Copy.myProfile, systemImage: "person.text.rectangle", tint: .brand) {
                PopopxProfileHost()
            }
            PopopxMeDivider()
            // 加密个人主页：制作器用 `NavigationLink` 推上去，不是 Sheet —— 它自己不带导航容器
            //（`ProfileBuilderView.swift:434` 那一层的约定），推上去就白拿现成的返回键。
            // `value` 那一格是这台机器上主页的当前档位；读盘是 actor hop，放在 `.task` 里，
            // 不在 body 里同步读，否则每次重排这组卡片都会去问一次磁盘。
            PopopxMeRowLink(Copy.personalProfile, value: profileStatusValue, systemImage: "person.text.rectangle.fill", tint: .brand) {
                ProfileBuilderView()
                    .navigationTitle(Copy.personalProfile)
            }
            PopopxMeDivider()
            // 名片码是 Sheet 不是页面（`ProfileQRCodeSheet` 自带关闭键、dismiss 归调用方），
            // 所以这一行不能借上面那个 `PopopxMeRowLink`——它是 NavigationLink，推不开 Sheet。
            // 命框高度与 `PopopxMeRowLink` 对齐，两行看上去是同一族。
            PopopxPickerRow(Copy.personalProfileQR, systemImage: "qrcode.viewfinder", tint: .brand) {
                PopopxHaptics.impact(.light)
                showsProfileQR = true
            }
            .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
            .accessibilityIdentifier("popopx.me.profileQR")
            PopopxMeDivider()
            PopopxMeRowLink(
                Copy.manageIdentities,
                value: String(format: Copy.identityCountFormat, chatModel.users.count),
                systemImage: "person.crop.rectangle.stack"
            ) {
                UserProfilesView()
                    .navigationTitle(Copy.manageIdentities)
                    .modifier(ThemedBackground(grouped: true))
            }
        }
    }

    // MARK: 通用

    private var generalEntries: some View {
        PopopxSectionCard(Copy.groupGeneral) {
            PopopxPickerRow(Copy.addFriend, systemImage: "person.badge.plus", tint: .brand) {
                showsAddFriend = true
            }
            if let user = chatModel.currentUser {
                PopopxMeDivider()
                PopopxMeRowLink(
                    Copy.chatPreferences,
                    value: user.showNtfs ? Copy.notifyOn : Copy.notifyOff,
                    systemImage: "slider.horizontal.3"
                ) {
                    // 三个入参照 ChatListView.swift:95-98 的既有挂载点原样给。
                    PreferencesView(
                        profile: user.profile,
                        preferences: user.fullPreferences,
                        currentPreferences: user.fullPreferences
                    )
                    .navigationTitle(Copy.chatPreferences)
                    .modifier(ThemedBackground(grouped: true))
                }
            }
            PopopxMeDivider()
            PopopxMeRowLink(Copy.notifications, systemImage: "bell") {
                NotificationsView()
                    .navigationTitle(Copy.notifications)
                    .modifier(ThemedBackground(grouped: true))
            }
            PopopxMeDivider()
            PopopxMeRowLink(Copy.allSettings, systemImage: "gearshape") {
                PopopxSettingsView()
                    .navigationTitle(Copy.allSettings)
                    .modifier(ThemedBackground(grouped: true))
            }
        }
    }

    // MARK: 隐私与安全

    private var privacyEntries: some View {
        PopopxSectionCard(Copy.groupPrivacy) {
            PopopxMeRowLink(Copy.privacySettings, systemImage: "lock.shield", tint: .brand) {
                PrivacySettings()
                    .navigationTitle(Copy.privacySettings)
                    .modifier(ThemedBackground(grouped: true))
            }
        }
    }

    // MARK: 离线组网

    private var meshEntries: some View {
        PopopxSectionCard(Copy.groupMesh, footnote: Copy.meshFootnote) {
            PopopxToggleRow(
                Copy.fuseRow,
                note: Copy.fuseRowNote,
                systemImage: "antenna.radiowaves.left.and.right",
                tint: .mesh,
                isOn: fuseBinding
            )
            PopopxMeDivider()
            verificationBlock
            PopopxMeDivider()
            PopopxPickerRow(
                Copy.pairingPolicy,
                value: policyTitle(meshRuntime.pairingPolicy),
                systemImage: "person.2.wave.2.fill",
                tint: .mesh
            ) {
                PopopxHaptics.selection()
                showsPairingPolicy = true
            }
            PopopxMeDivider()
            PopopxMeRowLink(Copy.meshPrivacy, systemImage: "lock.shield.fill", tint: .mesh) {
                // 挂载方式照 SettingsView.swift:417-424：三个对象全部来自 runtime，页面自己在熔断
                // 关闭时渲染"已关闭"状态，所以这一行永远可以点。
                MeshPrivacySettingsView(
                    store: meshRuntime.mappingStore,
                    pairing: meshRuntime.pairing,
                    killSwitch: meshRuntime.killSwitch
                )
                .navigationTitle(Copy.meshPrivacy)
                .modifier(ThemedBackground(grouped: true))
            }
            PopopxMeDivider()
            panicBlock
        }
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

    /// 熔断开关只是"意愿"。这一行写的是运行态：phase、真在跑的蓝牙/界面组件数、事件订阅数，
    /// 全部来自 `PopopxMeshKillSwitch.verifiedActivitySnapshot()`（包里唯一的权威答案）。
    private var verificationBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "waveform.path")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.meshInk)
                    .accessibilityHidden(true)
                Text(Copy.verifyHeadline)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                PopopxButton(Copy.verifyAgain, systemImage: "arrow.clockwise", role: .ghost, fullWidth: false) {
                    await refreshVerification(waitingForSettle: false)
                }
            }
            Text(verifiedSentence)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PopopxMetrics.space2XS)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Copy.verifyHeadline))
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

    // MARK: 关于

    private var aboutEntries: some View {
        PopopxSectionCard(Copy.groupAbout, footnote: Copy.aboutFootnote) {
            PopopxMeRowLink(Copy.versionRow, value: appVersion, systemImage: "info.circle") {
                VersionView()
                    .navigationTitle(Copy.versionRow)
                    .modifier(ThemedBackground(grouped: true))
            }
        }
    }

    // MARK: 配对策略

    private var pairingPolicySheet: some View {
        NavigationStack {
            PopopxSheetContainer(Copy.pairingSheetTitle, subtitle: Copy.pairingSheetSubtitle) {
                PopopxSectionCard {
                    // 只枚举 `MeshPairingPolicy` 真实存在的两个 case（IdentityMappingStore.swift:24-30）。
                    ForEach(Array(MeshPairingPolicy.allCases.enumerated()), id: \.element) { index, policy in
                        if index > 0 {
                            PopopxMeDivider()
                        }
                        PopopxRadioRow(
                            policyTitle(policy),
                            note: policyNote(policy),
                            selected: meshRuntime.pairingPolicy == policy
                        ) {
                            PopopxHaptics.selection()
                            meshRuntime.setPairingPolicy(policy)
                            showsPairingPolicy = false
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsPairingPolicy = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: 行为

    /// 熔断只经 `requestFuse` 翻转 —— 那是唯一会带着 模块 1–7 一起启停的那条路
    /// （SettingsView.swift:630-635 同一个绑定）。
    private var fuseBinding: Binding<Bool> {
        Binding(
            get: { meshRuntime.isFuseOn },
            set: { meshRuntime.requestFuse($0) }
        )
    }

    /// 核验一次真实运行态。`waitingForSettle` 时给过渡态最多 5 × 250 ms 的等待窗口：
    /// `starting`/`stopping` 期间拿到的快照说的是"上一刻"，等它落到 on/off 才算答案。
    @MainActor private func refreshVerification(waitingForSettle: Bool) async {
        var snapshot = await meshRuntime.killSwitch.verifiedActivitySnapshot()
        if waitingForSettle {
            for _ in 0..<5 where snapshot.phase == .starting || snapshot.phase == .stopping {
                try? await Task.sleep(for: .milliseconds(250))
                snapshot = await meshRuntime.killSwitch.verifiedActivitySnapshot()
            }
        }
        verifiedSnapshot = snapshot
    }

    /// 开关说的话与蓝牙真实状态的关系，全在这里说清楚：宁可写"仍在运行"也不粉饰。
    private var verifiedSentence: String {
        guard let snapshot = verifiedSnapshot else { return Copy.verifyPending }
        var text: String
        switch snapshot.phase {
        case .off: text = Copy.phaseOff
        case .starting: text = Copy.phaseStarting
        case .on: text = Copy.phaseOn
        case .stopping: text = Copy.phaseStopping
        }
        if snapshot.isActive {
            text += String(
                format: Copy.busySuffixFormat,
                snapshot.runningRadioWork.count,
                snapshot.runningInterfaceWork.count
            )
        } else {
            text += Copy.quietSuffix
        }
        if let subscribers = snapshot.eventHubSubscribers {
            text += String(format: Copy.subscribersSuffixFormat, subscribers)
        }
        // 磁盘开关说"开"而 phase 不是 on（或反过来）就是一次没走完的启停，也可能是崩在中间。
        if snapshot.persistedSwitch != (snapshot.phase == .on) {
            text += Copy.mismatchSuffix
        }
        return text
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
    /// （POPOPXApp.swift:48 → POPOPXAPI.swift:3953-3970）挂在 app 根上、绑定同一个
    /// `isAwaitingConfirmation`。所以这里绝不写第二个 alert：写了就有两道确认抢同一个状态机，
    /// 而铁律要的是一次、且只有那一次确认。熔断关闭时那道门根本不存在
    /// （POPOPXAPI.swift:3962 的 `if runtime.isFuseOn`），所以这一行同时被禁用。
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

    private func policyTitle(_ policy: MeshPairingPolicy) -> String {
        switch policy {
        case .manualConfirm: return Copy.policyManual
        case .autoSilent: return Copy.policyAuto
        }
    }

    private func policyNote(_ policy: MeshPairingPolicy) -> String {
        switch policy {
        case .manualConfirm: return Copy.policyManualNote
        case .autoSilent: return Copy.policyAutoNote
        }
    }
}

// MARK: - 身份卡

@MainActor
private struct PopopxIdentityCard: View {
    private let user: User
    private let others: [UserInfo]
    private let lockedCount: Int
    private let busyUserID: Int64?
    private let onSwitch: (UserInfo) -> Void
    private let onCopyUserID: () async -> Void

    init(
        user: User,
        others: [UserInfo],
        lockedCount: Int,
        busyUserID: Int64?,
        onSwitch: @escaping (UserInfo) -> Void,
        onCopyUserID: @escaping () async -> Void
    ) {
        self.user = user
        self.others = others
        self.lockedCount = lockedCount
        self.busyUserID = busyUserID
        self.onSwitch = onSwitch
        self.onCopyUserID = onCopyUserID
    }

    /// 边长不写裸数字：大头像 = spaceXL × 2，切换器里的小头像 = spaceXL。
    private static let avatarSide: CGFloat = PopopxMetrics.spaceXL * 2
    private static let chipAvatarSide: CGFloat = PopopxMetrics.spaceXL

    /// 身份色是怎么派生出来的：全仓没有 `colorForProfile` 这一类按身份给色相的 helper（0 命中），
    /// 而 §1.1 里靛紫只说"在线身份"、青绿只说"离线厢语"，把青绿拿来当纯装饰就会伪造一条不存在
    /// 的传输通道。所以色相不动，只把 `brand` 压到 0.12 当这张卡的重心；上面的文字仍走 `label`，
    /// 对比度不受这层底影响。
    private static let identityWash = PopopxPalette.brand.opacity(0.12)

    var body: some View {
        PopopxSectionCard(Copy.identityCardTitle, footnote: footnote) {
            HStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
                PopopxMeAvatar(image: user.image, side: Self.avatarSide)
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(user.displayName)
                        .font(PopopxType.title)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsFullName {
                        Text(user.fullName)
                            .font(PopopxType.secondary)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    identityNumberLine
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .padding(PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.identityWash, in: .rect(cornerRadius: PopopxMetrics.radiusControl))

            if !others.isEmpty {
                PopopxMeDivider()
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
        }
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

            PopopxButton(
                Copy.copyUserID,
                systemImage: "doc.on.doc",
                role: .ghost,
                fullWidth: false,
                action: onCopyUserID
            )
        }
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

/// 头像。有 base64 就用既有的 `ProfileImage`，没有就落到品牌标记 —— 不画占位人形。
@MainActor
private struct PopopxMeAvatar: View {
    private let image: String?
    private let side: CGFloat

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
        // 头像在这页永远是装饰：身份名就在同一张卡上，不让 VoiceOver 念两遍。
        .accessibilityHidden(true)
    }
}

/// 「推一个既有页面」的一行。外观直接复用 `PopopxPickerRow`，但点击交给外层 `NavigationLink`：
/// 原子库里的行本身是个 `Button`，嵌套按钮会把链接的点击吃掉，所以这一行整体设为不可命中、
/// 也不进无障碍树，由链接自己带上同名的 label 与 hint（44pt 由 `minHitTarget` 兜住）。
@MainActor
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

/// 页面上每一句中文只在这里出现一次。
private enum Copy {
    static let pageTitle = "我"
    static let close = "关闭"
    static let linkHint = "打开"

    // 顶部身份卡
    static let identityCardTitle = "当前身份"
    static let identityNumberLabel = "身份编号"
    static let copyUserID = "复制编号"
    static let copiedUserID = "身份编号已复制"
    static let otherIdentities = "切换到其它身份"
    static let switchHint = "以这个身份继续"
    static let switchDone = "已切换身份"
    static let switchFailed = "切换失败，请稍后再试"
    static let switchNote = "加锁身份不在这里出现：切换它们需要输入查看密码。"
    static let switchNoteWithLockedFormat = "轻触头像即可切换；本机另有 %d 个加锁身份，需在「身份管理」里输入查看密码。"
    static let lockedOnlyNoteFormat = "本机另有 %d 个加锁身份，需在「身份管理」里输入查看密码后才能切换。"
    static let unreadBadgeFormat = "未读 %d 个"
    static let emptyTitle = "还没有激活的身份"
    static let emptyNote = "身份就是你在 popopx 里的匿名名片：一个昵称、一张头像、一份属于自己的会话库。创建一个就能开始聊天。"
    static let emptyFootnote = "创建身份不要求手机号或邮箱。"
    static let createIdentity = "创建新身份"

    // 分组标题
    static let groupIdentity = "身份"
    static let groupGeneral = "通用"
    static let groupPrivacy = "隐私与安全"
    static let groupMesh = "离线组网"
    static let groupAbout = "关于"

    // 身份
    static let myProfile = "我的资料"
    static let manageIdentities = "身份管理"
    static let identityCountFormat = "共 %d 个"

    // 加密个人主页（ProfileReaderView.md:59 的行名是「我的加密个人主页」，档位标签是「已配置 · <模式>」）
    static let personalProfile = "我的加密个人主页"
    static let personalProfileQR = "主页名片码"
    static let profileConfigured = "已配置"
    static let profileUnconfigured = "未制作"
    static let profileQRIdentityFallback = "未命名身份"

    // 通用
    static let addFriend = "添加朋友"
    static let chatPreferences = "聊天偏好"
    static let notifyOn = "通知已开"
    static let notifyOff = "此身份已静音"
    static let notifications = "通知"
    static let allSettings = "全部设置"

    // 隐私与安全
    static let privacySettings = "隐私与安全设置"

    // 离线组网
    static let meshFootnote = "总开关一关，蓝牙扫描、广播与中继全部停；本页其余行仍可查看，但不会启动任何蓝牙对象。"
    static let fuseRow = "厢语离线组网总开关"
    static let fuseRowNote = "关闭即熔断：所有厢语组件一起停。"
    static let verifyHeadline = "蓝牙实际状态"
    static let verifyAgain = "核验"
    static let verifyPending = "本次运行还没核验过，点「核验」读取真实运行态。"
    static let phaseOff = "已停止"
    static let phaseStarting = "启动中"
    static let phaseOn = "运行中"
    static let phaseStopping = "停止中"
    static let quietSuffix = "，没有任何组件在运行"
    static let busySuffixFormat = "，仍有蓝牙组件 %d 个、界面组件 %d 个在运行"
    static let subscribersSuffixFormat = "，事件订阅 %d 个"
    static let mismatchSuffix = "；开关与运行态暂不一致"
    static let pairingPolicy = "附近配对策略"
    static let pairingSheetTitle = "附近配对策略"
    static let pairingSheetSubtitle = "决定附近设备的蓝牙配对要不要你亲自确认。"
    static let policyManual = "配对前先问我"
    static let policyManualNote = "附近设备发起配对时弹出确认，你不点就永远不连接。"
    static let policyAuto = "静默配对"
    static let policyAutoNote = "蓝牙私有会话建立后自动完成配对，不再询问。"
    static let meshPrivacy = "厢语隐私与配对记录"

    // 危险行
    static let panicRow = "紧急抹除厢语数据"
    static let panicReady = "连击三次"
    static let panicTapsFormat = "已计 %d/3 次"
    static let panicAwaiting = "等待确认"
    static let panicWiping = "正在抹除…"
    static let panicDisabled = "熔断关闭时不可用"
    static let panicRowHint = "一秒内轻触三次才会布防"
    static let panicNote = "一秒内连击三次这一行才会布防，布防后由全 app 唯一的确认弹窗问你一次；取消即作废，绝不静默抹除。熔断关闭时这道确认不存在，这一行也随之停用。"

    // 关于
    static let versionRow = "版本与更新"
    static let aboutFootnote = "版本页同时给出本机版本与网络核心版本。"
}

// MARK: - Previews

#if DEBUG
#Preview("我 — 空状态") {
    NavigationStack {
        PopopxMeView()
    }
    .environmentObject(ChatModel.shared)
    .environmentObject(AppTheme.shared)
}

#Preview("我 — 已有身份") {
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
#endif
