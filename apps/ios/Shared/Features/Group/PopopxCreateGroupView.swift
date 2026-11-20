//
//  PopopxCreateGroupView.swift
//  POPOPX (iOS)
//
//  「创建群组」的重写版，替代 Shared/Views/NewChat/AddGroupView.swift:13。
//
//  挂载点没动：两处仍然是零参构造（Shared/Views/NewChat/NewChatMenuButton.swift:93、
//  Shared/Features/Chats/ChatsListView.swift:264），本类型因此保留全默认值的合成 `init()`，
//  并且照旧从环境里取 `ChatModel`（Shared/Model/ChatModel.swift:387、:491）。`ChatModel` 与
//  旧主题对象都由 app 根注入，本文件不自己造第二个模型。
//
//  数据层只有一条路，全部是被逐个核对过声明的真函数，标签一律抄自声明处：
//  - 建群 = `apiNewGroup(incognito:groupProfile:)`（Shared/Model/POPOPXAPI.swift:1973）。它是同步
//    抛出的，旧页 :204 就是同一句 `try`，这里没有改成 await 抄近路。
//  - 建完群立刻照抄旧页 :205-213 的四步：`Task { await m.loadGroupMembers(gInfo) }`
//    （Shared/Model/ChatModel.swift:586）→ `m.addChat(Chat(chatInfo: .group(groupInfo:groupChatScope:),
//    chatItems: []))`（:603、Shared/Model/ChatModel.swift:1423、POPOPXChat/ChatTypes.swift:1996）→
//    `withAnimation { groupInfo = gInfo; chat = c }`。顺序与副作用一个没少。
//  - 邀请成员 = `apiAddMember(_:_:_:)`（Shared/Model/POPOPXAPI.swift:2019），循环与
//    `m.upsertGroupMember(gInfo, member)`（Shared/Model/ChatModel.swift:1341）逐字照抄那一页的
//    `inviteMembers()`（Shared/Views/Chat/Group/AddGroupMembersView.swift:170-184），失败也走它同一句
//    `showErrorAlert(error, ...)`（Shared/Views/ChatList/ChatListNavLink.swift:755）。
//  - 名单来源也是同一个表达式：`filterMembersToAdd(chatModel.groupMembers)`
//    （Shared/Model/POPOPXAPI.swift:2093），所以这一页不会自己另数一套人。
//  - 「这个联系人不能被请进用主名片建的群」沿用那一页的判据
//    （AddGroupMembersView.swift:196 的 `contact.contactConnIncognito`，
//    POPOPXChat/ChatTypes.swift:2695）：群还没建，"这会用哪个名片"就是本页那个隐身开关。
//  - 群组链接这一步不自建：隐身分支仍旧交回既有的 `GroupLinkView`
//    （Shared/Views/Chat/Group/GroupLinkView.swift:14），链接由它自己经 `apiCreateGroupLink`
//    （Shared/Model/POPOPXAPI.swift:2114）生成。这一页不写第二个建链接的按钮 —— 写就会有两个链接。
//  - 收尾照抄旧页 :40-45 与 :55-60：`DispatchQueue.main.asyncAfter(deadline: .now() + 0.5)` →
//    `dismissAllSheets(animated: true)`（Shared/Views/Helpers/DismissSheets.swift:23）→
//    `ItemsModel.shared.loadOpenChat(groupInfo.id)`（Shared/Model/ChatModel.swift:113）。那 0.5 秒
//    是旧页为了躲开 dismiss 与 push 抢同一次转场而留的，不是随手写的数字，原样保留。
//
//  路由（和旧页同一个分岔，只是多了一条"本页已经选过人"的近路）：
//  - 隐身建群 → 第二阶段仍是 `GroupLinkView`，与旧页 :48-62 完全一致；选人这一格随之清空并停用，
//    因为旧页的隐身分支本来就没有成员页。
//  - 非隐身、一个人都没选 → 第二阶段仍是旧页那一格 `AddGroupMembersViewCommon`
//    （Shared/Views/Chat/Group/AddGroupMembersView.swift:24，`creatingGroup: true`、
//    `showFooterCounter: false` 两个入参照旧页 :38-39 原样给），准入、偏好、角色、搜索、Skip 全在。
//  - 非隐身、在本页点了人 → 邀请就在本页发完，然后直接进那一次收尾；不再进那一页，
//    否则同一个人会被请两次。终态与旧页"进那一页、勾上、点邀请"完全相同：同一句 `apiAddMember`、
//    同一句 `upsertGroupMember`、同一句 0.5 秒后的 `loadOpenChat`。
//
//  与旧页的有意差别，都写在这里而不是藏在代码里：
//  1. 旧页 `onAppear` 后延时 1 秒强制把光标塞进群名输入框（:126-130）。那是 iOS 16 时代键盘焦点
//     bug 的绕法，它上面那段注释自己就警告过它可能卡住 app；这一页改用
//     `.scrollDismissesKeyboard(.interactively)`，让用户自己收键盘，不再抢焦点。
//  2. 旧页头像右侧那张 `create-group` 插图是 SimpleX 的美术资源（:92-98），品牌已换，这里换成
//     `PopopxBrandAsset.mark` 加本页的头像选择器；`ProfileImage`（旧页 :75）要靠旧主题对象才能
//     上色，这一页的头像不碰旧主题，直接从 base64 画。
//  3. 旧页的头像选择、名字校验、隐身存储三处动作一个没换：来源选择器仍是
//     `confirmationDialog` + `CameraImagePicker` / `LibraryImagePicker`
//     （Shared/Views/Helpers/ImagePicker.swift:188、:15），压缩仍是
//     `resizeImageToStrSize(cropToSquare(image), maxDataSize: 12500)`
//     （POPOPXChat/ImageUtils.swift:149、:120），校验仍是 `mkValidName` / `validDisplayName`
//     （Shared/Views/Onboarding/CreateProfile.swift:457、:453），开关写的仍是全 app 那一份
//     `@AppStorage(GROUP_DEFAULT_INCOGNITO, store: groupDefaults)`（POPOPXChat/AppGroup.swift:61、:72）。
//     只有"非法名"那一下从弹旧式 `createInvalidNameAlert`（:439）换成同一条 `alert` 加一个「改正」
//     按钮，按下去执行的就是那个 alert 主按钮的同一句赋值（`profile.displayName = mkValidName(...)`）。
//  4. 旧页 `history` 无脑写 `GroupPreference(enable: .on)`（:203，POPOPXChat/ChatTypes.swift:1916），
//     这一页把它做成真开关，默认值仍是开，并且同样在 `apiNewGroup` 之前写进 profile ——
//     用户不碰它时的结果与旧页逐字节相同。
//  5. 邀请失败时旧页停在成员页等用户重试；这一页在"本页已选人"那条路上会先把错误弹出来，然后
//     照样把群打开。理由是那条路上没有成员页可停，停在表单上再点一次就会建出第二个群 ——
//     进群之后从成员列表照样能重新邀请，这是同一条 `apiAddMember` 的可达路径，不是降级。
//
//  配色、字号、间距、圆角、材质全部取 Shared/Theme/PopopxTheme.swift 的 token；控件只用
//  Shared/Components/PopopxControls.swift 里已有的原子库，本文件不新造按钮或输入框。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖进 POPOPX (iOS) target —— 铁律禁止脚本改 project.pbxproj。
//

import SwiftUI
import UIKit
import POPOPXChat

// MARK: - 页面

struct PopopxCreateGroupView: View {
    @EnvironmentObject private var m: ChatModel
    @AppStorage(GROUP_DEFAULT_INCOGNITO, store: groupDefaults) private var incognitoDefault = false

    /// 两个都非 nil 才进第二阶段，条件与旧页 :32 同。
    @State private var chat: Chat?
    @State private var groupInfo: GroupInfo?
    @State private var profile = GroupProfile(displayName: "", fullName: "")

    /// 本页的选人结果与角色，默认值与那一页同源（AddGroupMembersView.swift:33 `.member`）。
    @State private var selectedContacts: Set<Int64> = []
    @State private var selectedRole: GroupMemberRole = .member

    /// 隐身分支下由 `GroupLinkView` 自己读写的那对状态，旧页 :28-29 同对。
    @State private var groupLink: GroupLink?
    @State private var groupLinkMemberRole: GroupMemberRole = .member

    var body: some View {
        if let chat, let groupInfo {
            secondStage(chat: chat, groupInfo: groupInfo)
        } else {
            PopopxCreateGroupForm(
                profile: $profile,
                incognito: $incognitoDefault,
                historyEnabled: historyBinding,
                selectedContacts: $selectedContacts,
                selectedRole: $selectedRole,
                currentIdentityName: currentIdentityName,
                contacts: invitableContacts,
                onSubmit: { await createGroup() }
            )
        }
    }

    // MARK: 第二阶段（照抄旧页 body 的两个分支与那一次收尾）

    /// 隐身 = 既有的群组链接页；非隐身 = 既有的邀请成员页。
    /// 「在本页已经选过人」的情况根本不会走到这里 —— `createGroup()` 直接进收尾那一句。
    @ViewBuilder private func secondStage(chat: Chat, groupInfo: GroupInfo) -> some View {
        if groupInfo.membership.memberIncognito {
            GroupLinkView(
                groupId: groupInfo.groupId,
                groupLink: $groupLink,
                groupLinkMemberRole: $groupLinkMemberRole,
                showTitle: false,
                creatingGroup: true
            ) {
                finishCreating(groupInfo)
            }
            .navigationTitle(Copy.linkStageTitle)
        } else {
            AddGroupMembersViewCommon(
                chat: chat,
                groupInfo: groupInfo,
                creatingGroup: true,
                showFooterCounter: false
            ) { _ in
                finishCreating(groupInfo)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 旧页 :40-45 / :55-60 那一次收尾，一字不动：延时 0.5 秒 → 关掉所有 sheet → 打开这个群。
    @MainActor private func finishCreating(_ groupInfo: GroupInfo) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismissAllSheets(animated: true) {
                ItemsModel.shared.loadOpenChat(groupInfo.id)
            }
        }
    }

    // MARK: 数据来源

    /// 「谁会被分享」那句用的当前身份名，口径同旧页 :191；空昵称不猜，直接落到「未命名身份」。
    private var currentIdentityName: String {
        let name = m.currentUser?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? Copy.unnamedIdentity : name
    }

    /// 历史消息那一项的当前值。`groupPreferences` 还是 nil 时就是旧页写死的那个默认：开。
    private var historyEnabled: Bool {
        profile.groupPreferences?.history?.on ?? true
    }

    /// 写回 `GroupProfile.groupPreferences.history` —— 这是核心认识的字段，不是页面上的私有布尔
    /// （POPOPXChat/ChatTypes.swift:1851、:1916）。
    private var historyBinding: Binding<Bool> {
        Binding(
            get: { historyEnabled },
            set: { on in
                profile.groupPreferences = GroupPreferences(history: GroupPreference(enable: on ? .on : .off))
            }
        )
    }

    /// 名单 = 那一页的同一条 `filterMembersToAdd`（Shared/Model/POPOPXAPI.swift:2093）。
    /// 判据 `!incognitoDefault && contact.contactConnIncognito` 是 AddGroupMembersView.swift:196 那一句
    /// `!chat.chatInfo.incognito && contact.contactConnIncognito` 的建群前写法：`ChatInfo.incognito`
    /// 对群就是 `groupInfo.membership.memberIncognito`（POPOPXChat/ChatTypes.swift:2266），而它正是由
    /// 这个开关决定的，所以群还没建的时候，开关就是那一格的真值。
    private var invitableContacts: [PopopxInvitableContact] {
        filterMembersToAdd(m.groupMembers).map { contact in
            PopopxInvitableContact(
                id: contact.apiId,
                name: contact.displayName,
                imageStr: contact.image,
                inviteProhibited: !incognitoDefault && contact.contactConnIncognito
            )
        }
    }

    // MARK: 动作

    /// 旧页 `createGroup()`（:199-224）的四步原样保留，后面接上本页自己那条邀请近路。
    @MainActor private func createGroup() async {
        let created: GroupInfo
        do {
            profile.displayName = profile.displayName.trimmingCharacters(in: .whitespaces)
            profile.groupPreferences = GroupPreferences(history: GroupPreference(enable: historyEnabled ? .on : .off))
            let gInfo = try apiNewGroup(incognito: incognitoDefault, groupProfile: profile)
            Task {
                await m.loadGroupMembers(gInfo)
            }
            let c = Chat(chatInfo: .group(groupInfo: gInfo, groupChatScope: nil), chatItems: [])
            m.addChat(c)
            // 隐身本来就没有成员页；一个人都没选就照旧进那一页去挑。
            if incognitoDefault || selectedContacts.isEmpty {
                withAnimation {
                    groupInfo = gInfo
                    chat = c
                }
                return
            }
            created = gInfo
        } catch {
            dismissAllSheets(animated: true) {
                AlertManager.shared.showAlert(
                    Alert(
                        title: Text(Copy.errorTitle),
                        message: Text(verbatim: responseError(error))
                    )
                )
            }
            return
        }
        await inviteSelectedMembers(created)
        finishCreating(created)
    }

    /// 逐字照抄 AddGroupMembersView.swift:170-184 的 `inviteMembers()`：同一个 `apiAddMember`
    /// 循环、同一个 `upsertGroupMember`、同一个 `showErrorAlert`。错误弹完仍把群打开，
    /// 原因写在文件头第 5 条。
    @MainActor private func inviteSelectedMembers(_ gInfo: GroupInfo) async {
        do {
            for contactId in selectedContacts {
                let member = try await apiAddMember(gInfo.groupId, contactId, selectedRole)
                await MainActor.run { _ = m.upsertGroupMember(gInfo, member) }
            }
        } catch let error {
            showErrorAlert(error, Copy.inviteErrorTitle)
        }
    }
}

// MARK: - 名单里的一位

/// 这一屏只用到这四件事，所以在页面侧把 `Contact`（POPOPXChat/ChatTypes.swift:2629）投影成一个
/// 值类型；预览用字面量就能填满，不需要活的 `ChatModel`，也不需要网络。
private struct PopopxInvitableContact: Identifiable, Hashable {
    let id: Int64
    let name: String
    let imageStr: String?
    /// 与那一页同一个"不能请"判定；true 时点它是问一句，不是选人。
    let inviteProhibited: Bool
}

// MARK: - 表单

/// 纯绑定 + 展示：它不认识 `ChatModel`，也不碰任何 API，所以文件末尾的预览能用字面量把它填满。
private struct PopopxCreateGroupForm: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding private var profile: GroupProfile
    @Binding private var incognito: Bool
    @Binding private var historyEnabled: Bool
    @Binding private var selectedContacts: Set<Int64>
    @Binding private var selectedRole: GroupMemberRole
    private let currentIdentityName: String
    private let contacts: [PopopxInvitableContact]
    private let onSubmit: () async -> Void

    @State private var chosenImage: UIImage? = nil
    @State private var showsChooseSource = false
    @State private var showsImagePicker = false
    @State private var showsTakePhoto = false
    @State private var showsInvalidNameAlert = false
    @State private var showsProhibitedAlert = false
    @State private var showsRolePicker = false

    /// 边长不写裸数字：大头像 = `space2XL × 2`，芯片里的小头像 = `spaceXL`，同 PopopxMeView 的取法。
    private static let avatarSide: CGFloat = PopopxMetrics.space2XL * 2
    private static let chipAvatarSide: CGFloat = PopopxMetrics.spaceXL

    init(
        profile: Binding<GroupProfile>,
        incognito: Binding<Bool>,
        historyEnabled: Binding<Bool>,
        selectedContacts: Binding<Set<Int64>>,
        selectedRole: Binding<GroupMemberRole>,
        currentIdentityName: String,
        contacts: [PopopxInvitableContact],
        onSubmit: @escaping () async -> Void
    ) {
        self._profile = profile
        self._incognito = incognito
        self._historyEnabled = historyEnabled
        self._selectedContacts = selectedContacts
        self._selectedRole = selectedRole
        self.currentIdentityName = currentIdentityName
        self.contacts = contacts
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    headerBlock
                    avatarCard
                    nameCard
                    identityCard
                    membersCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, PopopxMetrics.spaceS)
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .scrollDismissesKeyboard(.interactively)
            ctaBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PopopxPalette.base)
        // 隐身开关一翻，成员那一格整格换内容；Reduce Motion 下直接落位。
        .popopxAnimation(PopopxSpring.fluid, value: incognito, reduceMotion: reduceMotion)
        .confirmationDialog(Copy.avatarDialogTitle, isPresented: $showsChooseSource, titleVisibility: .visible) {
            Button(Copy.takePicture) { showsTakePhoto = true }
            Button(Copy.chooseFromLibrary) { showsImagePicker = true }
            Button(Copy.cancel, role: .cancel) { }
        }
        .fullScreenCover(isPresented: $showsTakePhoto) {
            ZStack {
                PopopxPalette.base.ignoresSafeArea()
                CameraImagePicker(image: $chosenImage)
            }
        }
        .sheet(isPresented: $showsImagePicker) {
            LibraryImagePicker(image: $chosenImage) { _ in
                await MainActor.run {
                    showsImagePicker = false
                }
            }
        }
        .sheet(isPresented: $showsRolePicker) {
            roleSheet
        }
        .alert(Copy.invalidNameTitle, isPresented: $showsInvalidNameAlert) {
            // 按下去就是旧页那个 alert 主按钮的同一句赋值（CreateProfile.swift:447）。
            Button(Copy.fixName) { profile.displayName = mkValidName(profile.displayName) }
            Button(Copy.cancel, role: .cancel) { }
        } message: {
            Text(Copy.invalidNameBody)
        }
        .alert(Copy.prohibitedTitle, isPresented: $showsProhibitedAlert) {
            Button(Copy.gotIt) { }
        } message: {
            Text(Copy.prohibitedBody)
        }
        // 选完图立刻裁方 + 压缩，再写进 profile.image —— 旧页 :155-164 同一句。
        .onChange(of: chosenImage) { _, image in
            Task {
                let resized: String? = if let image {
                    await resizeImageToStrSize(cropToSquare(image), maxDataSize: 12500)
                } else {
                    nil
                }
                await MainActor.run { profile.image = resized }
            }
        }
        // 隐身那条路上没有成员页，所以开关一翻就把已选的人清掉，不留一份永远不会生效的选中状态。
        .onChange(of: incognito) { _, on in
            if on { selectedContacts.removeAll() }
        }
    }

    // MARK: 标题块

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(Copy.pageTitle)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.label)
            Text(Copy.pageExplainer)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    // MARK: 头像

    private var avatarCard: some View {
        PopopxSectionCard(Copy.avatarTitle, footnote: Copy.avatarFootnote) {
            HStack(alignment: .center, spacing: PopopxMetrics.spaceM) {
                avatarButton
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(profile.image == nil ? Copy.avatarEmptyState : Copy.avatarChosenState)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if profile.image != nil {
                        PopopxButton(
                            Copy.avatarRemove,
                            systemImage: "trash",
                            role: .secondary,
                            fullWidth: false
                        ) {
                            profile.image = nil
                            chosenImage = nil
                        }
                        .padding(.top, PopopxMetrics.space2XS)
                    }
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Self.avatarSide)
        }
    }

    /// 整颗头像就是入口，点开的是旧页那同一个来源选择器（拍照 / 照片库）。
    private var avatarButton: some View {
        Button {
            showsChooseSource = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                PopopxGroupAvatar(imageStr: profile.image, side: Self.avatarSide)
                Image(systemName: "camera.fill")
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.onBrand)
                    .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                    .background(PopopxPalette.brand, in: Circle())
                    .overlay(
                        Circle().strokeBorder(PopopxPalette.card, lineWidth: PopopxMetrics.divider)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Copy.avatarPickLabel)
    }

    // MARK: 名字

    private var nameCard: some View {
        PopopxSectionCard(Copy.nameTitle, footnote: Copy.nameFootnote) {
            PopopxTextField(
                Copy.nameFieldLabel,
                prompt: Copy.nameFieldPrompt,
                text: $profile.displayName,
                systemImage: "person.3.fill",
                onSubmit: { _ in
                    if canCreate { Task { await onSubmit() } }
                }
            )
            PopopxFormDivider()
            PopopxTextField(
                Copy.fullNameFieldLabel,
                prompt: Copy.fullNameFieldPrompt,
                text: $profile.fullName,
                systemImage: "textformat"
            )
            PopopxFormDivider()
            PopopxTextField(
                Copy.shortDescrFieldLabel,
                prompt: Copy.shortDescrFieldPrompt,
                text: shortDescrBinding,
                systemImage: "caption"
            )
            if nameNeedsFix {
                PopopxFormDivider()
                PopopxPickerRow(
                    Copy.nameFixRow,
                    value: Copy.nameFixHint,
                    systemImage: "exclamationmark.circle.fill",
                    tint: .danger
                ) {
                    showsInvalidNameAlert = true
                }
            }
        }
    }

    /// `shortDescr` 在核心里是可空字段：空串一律写回 nil，不留一个空字符串假装"有简介"。
    private var shortDescrBinding: Binding<String> {
        Binding(
            get: { profile.shortDescr ?? "" },
            set: { value in
                profile.shortDescr = value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
            }
        )
    }

    /// 「会被核心改写、但还没改正」的那一刻。判据与旧页 :170-171 同一句。
    private var nameNeedsFix: Bool {
        let name = profile.displayName.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name != mkValidName(name)
    }

    /// 能不能建群，口径同旧页 :226-229：去空白、非空、且核心不会改写它。
    private var canCreate: Bool {
        let name = profile.displayName.trimmingCharacters(in: .whitespaces)
        return name != "" && validDisplayName(name)
    }

    // MARK: 名片与历史

    private var identityCard: some View {
        PopopxSectionCard(Copy.identityTitle, footnote: sharedProfileNote) {
            PopopxToggleRow(
                Copy.incognitoRow,
                note: Copy.incognitoNote,
                systemImage: "theatermasks.fill",
                tint: .brand,
                isOn: $incognito
            )
            PopopxFormDivider()
            PopopxCheckbox(Copy.historyRow, note: Copy.historyNote, isOn: $historyEnabled)
            PopopxFormDivider()
            Text(Copy.decentralizedNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, PopopxMetrics.space2XS)
        }
    }

    /// 「谁会被分享」随开关变，两句话都是旧页 :190-197 那一个函数在说的两件事。
    private var sharedProfileNote: String {
        if incognito {
            return Copy.sharedRandomProfileNote
        }
        return String(format: Copy.sharedNamedProfileFormat, "『\(currentIdentityName)』")
    }

    // MARK: 成员

    private var membersCard: some View {
        PopopxSectionCard(membersTitle, footnote: membersFootnote) {
            if incognito {
                incognitoMembersNote
            } else {
                PopopxPickerRow(
                    Copy.roleRow,
                    value: roleLabel(selectedRole),
                    systemImage: "person.badge.key.fill",
                    tint: .brand
                ) {
                    showsRolePicker = true
                }
                PopopxFormDivider()
                memberChips
                PopopxFormDivider()
                Text(String(format: Copy.selectedCountFormat, selectedContacts.count))
                    .font(PopopxType.meta)
                    .foregroundStyle(selectedContacts.isEmpty ? PopopxPalette.labelHint : PopopxPalette.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, PopopxMetrics.space2XS)
                    .accessibilityHidden(true)
            }
        }
    }

    /// 芯片条本身是横向滚的：联系人可能很多，纵向铺开会把后面两格挤出屏幕。
    @ViewBuilder private var memberChips: some View {
        if contacts.isEmpty {
            Text(Copy.membersEmpty)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, PopopxMetrics.space2XS)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PopopxMetrics.spaceS) {
                    ForEach(contacts) { contact in
                        PopopxMemberChip(
                            name: contact.name,
                            imageStr: contact.imageStr,
                            selected: selectedContacts.contains(contact.id),
                            prohibited: contact.inviteProhibited,
                            avatarSide: Self.chipAvatarSide
                        ) {
                            tap(contact)
                        }
                    }
                }
                .padding(.vertical, PopopxMetrics.space2XS)
            }
        }
    }

    /// 三个分支都来自那一页的 `contactCheckView`（AddGroupMembersView.swift:196-206）：
    /// 不能请 → 问一句；已选 → 去掉；没选 → 加上。
    private func tap(_ contact: PopopxInvitableContact) {
        if contact.inviteProhibited {
            showsProhibitedAlert = true
            return
        }
        if selectedContacts.contains(contact.id) {
            selectedContacts.remove(contact.id)
        } else {
            selectedContacts.insert(contact.id)
        }
    }

    private var membersTitle: String {
        if incognito { return Copy.membersTitleIncognito }
        return String(format: Copy.membersTitleFormat, contacts.count)
    }

    private var membersFootnote: String {
        if incognito { return Copy.membersFootnoteIncognito }
        return contacts.isEmpty ? Copy.membersEmptyFootnote : Copy.membersFootnoteInvite
    }

    private var incognitoMembersNote: some View {
        Label(Copy.membersIncognitoNote, systemImage: "theatermasks.fill")
            .font(PopopxType.meta)
            .foregroundStyle(PopopxPalette.labelSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, PopopxMetrics.space2XS)
    }

    // MARK: 角色

    /// 角色档位用那一页同一个 `GroupMemberRole.supportedRoles`
    /// （POPOPXChat/ChatTypes.swift:3664、AddGroupMembersView.swift:187）；建群的人自己就是群主，
    /// 所以那一页 `<= membership.memberRole` 那道过滤在这一步不会筛掉任何一档。
    private var roleSheet: some View {
        PopopxSheetContainer(Copy.roleSheetTitle, subtitle: Copy.roleSheetSubtitle) {
            PopopxSectionCard {
                ForEach(Array(GroupMemberRole.supportedRoles.enumerated()), id: \.element) { index, role in
                    if index > 0 {
                        PopopxFormDivider()
                    }
                    PopopxRadioRow(roleLabel(role), note: roleNote(role), selected: selectedRole == role) {
                        selectedRole = role
                        showsRolePicker = false
                    }
                }
            }
        } footer: {
            PopopxButton(Copy.done, role: .secondary) { showsRolePicker = false }
                .padding(PopopxMetrics.spaceM)
        }
    }

    /// `GroupMemberRole` 七个 case 全部列出来，缺一个就是编译错误。
    private func roleLabel(_ role: GroupMemberRole) -> String {
        switch role {
        case .relay: return Copy.roleRelay
        case .observer: return Copy.roleObserver
        case .author: return Copy.roleAuthor
        case .member: return Copy.roleMember
        case .moderator: return Copy.roleModerator
        case .admin: return Copy.roleAdmin
        case .owner: return Copy.roleOwner
        }
    }

    /// 每一档在本页这件事上的实际后果，说的是"他进群之后能干什么"。
    private func roleNote(_ role: GroupMemberRole) -> String {
        switch role {
        case .relay: return Copy.roleNoteRelay
        case .observer: return Copy.roleNoteObserver
        case .author: return Copy.roleNoteAuthor
        case .member: return Copy.roleNoteMember
        case .moderator: return Copy.roleNoteModerator
        case .admin: return Copy.roleNoteAdmin
        case .owner: return Copy.roleNoteOwner
        }
    }

    // MARK: 常驻主操作

    private var ctaBar: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            PopopxButton(Copy.createCTA, systemImage: "checkmark.circle.fill") {
                await onSubmit()
            }
            .disabled(!canCreate)
            Text(nextStepNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity)
        .background(PopopxMaterial.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PopopxPalette.separator)
                .frame(maxWidth: .infinity)
                .frame(height: PopopxMetrics.hairline)
        }
    }

    /// 这一行说的就是按下之后真会发生的那一步。
    private var nextStepNote: String {
        if incognito { return Copy.nextStepLink }
        if !selectedContacts.isEmpty { return Copy.nextStepInviteInline }
        if contacts.isEmpty { return Copy.nextStepNoContacts }
        return Copy.nextStepMembers
    }
}

// MARK: - 一位联系人

/// 整颗就是 `Button`：选中态靠描边 + 勾，不靠透明度，所以深色下也分得清。
private struct PopopxMemberChip: View {
    let name: String
    let imageStr: String?
    let selected: Bool
    let prohibited: Bool
    let avatarSide: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PopopxMetrics.space2XS) {
                PopopxGroupAvatar(imageStr: imageStr, side: avatarSide)
                Text(name)
                    .font(PopopxType.meta)
                    .foregroundStyle(selected ? PopopxPalette.label : PopopxPalette.labelSecondary)
                    .lineLimit(1)
                Image(systemName: symbolName)
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(symbolColor)
            }
            .padding(.horizontal, PopopxMetrics.spaceXS)
            // 44pt 是下限而不是定值：这一行还要装得下大号动态字体。
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(
                selected ? PopopxPalette.separator : PopopxPalette.cardHigh,
                in: .rect(cornerRadius: PopopxMetrics.radiusChip)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusChip)
                    .strokeBorder(
                        selected ? PopopxPalette.brand : PopopxPalette.hairlineInner,
                        lineWidth: selected ? PopopxMetrics.stroke : PopopxMetrics.hairline
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(selected ? Copy.a11ySelected : Copy.a11yUnselected)
        .accessibilityHint(prohibited ? Text(verbatim: Copy.a11yProhibitedHint) : Text(verbatim: Copy.a11yToggleHint))
    }

    /// 两个勾的图标名与那一页一致（AddGroupMembersView.swift:198-204），颜色改成本页 token。
    private var symbolName: String {
        if prohibited { return "theatermasks.circle.fill" }
        return selected ? "checkmark.circle.fill" : "circle"
    }

    private var symbolColor: Color {
        if prohibited { return PopopxPalette.dangerInk }
        return selected ? PopopxPalette.brand : PopopxPalette.labelHint
    }
}

// MARK: - 头像

/// 有 base64 就画真的那张图，没有就落到品牌标记 —— 不画占位人形，也不借旧主题上色。
private struct PopopxGroupAvatar: View {
    let imageStr: String?
    let side: CGFloat

    var body: some View {
        Group {
            if let uiImage = imageFromBase64(imageStr) {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(.rect(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous))
            } else {
                Image(PopopxBrandAsset.mark)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(PopopxMetrics.space2XS)
                    .frame(width: side, height: side)
                    .background(
                        PopopxPalette.separator,
                        in: .rect(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous)
                    )
            }
        }
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        // 头像在这一屏是装饰：名字就在同一颗芯片上，不让 VoiceOver 念第二遍。
        .accessibilityHidden(true)
    }
}

// MARK: - 卡片内分隔线

private struct PopopxFormDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - Previews

#if DEBUG
/// 只预览第一阶段那张表单：它的输入全是字面量，没有活模型、没有网络、也没有蓝牙。
/// 顶层的 `PopopxCreateGroupView` 本身不给预览 —— 它的 `@EnvironmentObject` 是 `ChatModel`
/// （Shared/Model/ChatModel.swift:387），那只能通过真实 app 的启动流程填充，预览里塞一份活的
/// 共享模型就是伪造运行状态。
private struct PopopxCreateGroupFormPreviewHost: View {
    @State private var profile = GroupProfile(
        displayName: "Weekend Riders",
        fullName: "Weekend Ride",
        shortDescr: "City rides, Saturday mornings"
    )
    @State private var incognito = false
    @State private var historyEnabled = true
    @State private var selected: Set<Int64> = [2]
    @State private var role: GroupMemberRole = .member

    var body: some View {
        PopopxCreateGroupForm(
            profile: $profile,
            incognito: $incognito,
            historyEnabled: $historyEnabled,
            selectedContacts: $selected,
            selectedRole: $role,
            currentIdentityName: "Ah Qing",
            contacts: [
                PopopxInvitableContact(id: 1, name: "Xiao Zhou", imageStr: nil, inviteProhibited: false),
                PopopxInvitableContact(id: 2, name: "Ah He", imageStr: nil, inviteProhibited: false),
                PopopxInvitableContact(id: 3, name: "Lin Er", imageStr: nil, inviteProhibited: true),
                PopopxInvitableContact(id: 4, name: "Lao Zhou", imageStr: nil, inviteProhibited: false),
            ],
            onSubmit: { }
        )
    }
}

struct PopopxCreateGroupView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxCreateGroupFormPreviewHost()
        }
    }
}
#endif

// MARK: - 文案

/// 页面上每一句中文只在这里出现一次。
private enum Copy {
    static let pageTitle = NSLocalizedString("Create group", comment: "")
    static let pageExplainer = NSLocalizedString("A group has no profile on any server: it exists only on its members' devices. Set the name and the avatar first, then decide who to invite.", comment: "")

    static let avatarTitle = NSLocalizedString("Group avatar", comment: "")
    static let avatarFootnote = NSLocalizedString("The avatar syncs only between this device and the members' devices. It is uploaded to no server.", comment: "")
    static let avatarPickLabel = NSLocalizedString("Choose the group avatar", comment: "")
    static let avatarRemove = NSLocalizedString("Remove the avatar", comment: "")
    static let avatarEmptyState = NSLocalizedString("No avatar has been chosen; the popopx mark is in use.", comment: "")
    static let avatarChosenState = NSLocalizedString("Chosen. It is cropped to a square and compressed before saving.", comment: "")
    static let avatarDialogTitle = NSLocalizedString("Group avatar", comment: "")
    static let takePicture = NSLocalizedString("Take picture", comment: "")
    static let chooseFromLibrary = NSLocalizedString("Choose from library", comment: "")
    static let cancel = NSLocalizedString("Cancel", comment: "")

    static let nameTitle = NSLocalizedString("Name", comment: "")
    static let nameFootnote = NSLocalizedString("The group name is the line shown in the chat list; the display name and the one-line summary appear only when you open the group profile.", comment: "")
    static let nameFieldLabel = NSLocalizedString("Group name", comment: "")
    static let nameFieldPrompt = NSLocalizedString("Enter the group name", comment: "")
    static let fullNameFieldLabel = NSLocalizedString("Display name", comment: "")
    static let fullNameFieldPrompt = NSLocalizedString("Optional, the full name in the group profile", comment: "")
    static let shortDescrFieldLabel = NSLocalizedString("One-line summary", comment: "")
    static let shortDescrFieldPrompt = NSLocalizedString("Optional", comment: "")
    static let nameFixRow = NSLocalizedString("The group name contains illegal characters", comment: "")
    static let nameFixHint = NSLocalizedString("Tap to fix", comment: "")
    static let invalidNameTitle = NSLocalizedString("The name is not valid", comment: "")
    static let invalidNameBody = NSLocalizedString("The core does not accept some of the characters in the group name. Fixing it removes them.", comment: "")
    static let fixName = NSLocalizedString("Fix", comment: "")

    static let identityTitle = NSLocalizedString("Profile card and history", comment: "")
    static let incognitoRow = NSLocalizedString("Create the group incognito", comment: "")
    static let incognitoNote = NSLocalizedString("A new random profile card joins the group, and the usual profile card of this device does not appear in the member list.", comment: "")
    static let sharedRandomProfileNote = NSLocalizedString("The new random profile card will be shared.", comment: "")
    static let sharedNamedProfileFormat = NSLocalizedString("Your profile card %@ will be shared.", comment: "")
    static let decentralizedNote = NSLocalizedString("Completely decentralized; only members can see it.", comment: "")
    static let historyRow = NSLocalizedString("Share message history with new members", comment: "")
    static let historyNote = NSLocalizedString("When this is off, someone who just joined sees only the messages that come after.", comment: "")

    static let membersTitleFormat = NSLocalizedString("Who to invite (%lld contacts can be invited on this device)", comment: "")
    static let membersTitleIncognito = NSLocalizedString("Who to invite", comment: "")
    static let membersFootnoteInvite = NSLocalizedString("Tap a contact to select them. Whoever is selected here is invited as soon as the group is created; select no one and the next step is the picker page.", comment: "")
    static let membersFootnoteIncognito = NSLocalizedString("Creating a group incognito sends no directed invitations: once the group exists you get a group link, and whoever has the link joins.", comment: "")
    static let membersEmpty = NSLocalizedString("There are no contacts on this device yet. Create the group first, then let people join through the group link.", comment: "")
    static let membersEmptyFootnote = NSLocalizedString("There are no contacts to invite yet. After the group exists you can let people join through the group link.", comment: "")
    static let membersIncognitoNote = NSLocalizedString("An incognito group grows through its group link; this step sends no directed invitations.", comment: "")
    static let selectedCountFormat = NSLocalizedString("%lld selected", comment: "")
    static let prohibitedTitle = NSLocalizedString("This contact cannot be invited", comment: "")
    static let prohibitedBody = NSLocalizedString("You and this contact use an incognito profile card between you. Inviting them into a group created with your main profile card would connect the two lines. Create the group with that card instead, or use a group link.", comment: "")
    static let gotIt = NSLocalizedString("OK", comment: "")

    static let roleRow = NSLocalizedString("New member role", comment: "")
    static let roleSheetTitle = NSLocalizedString("New member role", comment: "")
    static let roleSheetSubtitle = NSLocalizedString("What they can do once they have joined. Whoever creates the group is the owner and can grant any of the tiers below.", comment: "")
    static let done = NSLocalizedString("Done", comment: "")
    static let roleRelay = NSLocalizedString("relay", comment: "")
    static let roleObserver = NSLocalizedString("observer", comment: "")
    static let roleAuthor = NSLocalizedString("author", comment: "")
    static let roleMember = NSLocalizedString("member", comment: "")
    static let roleModerator = NSLocalizedString("moderator", comment: "")
    static let roleAdmin = NSLocalizedString("admin", comment: "")
    static let roleOwner = NSLocalizedString("owner", comment: "")
    static let roleNoteRelay = NSLocalizedString("Only relays inside the group and takes no part in the chat.", comment: "")
    static let roleNoteObserver = NSLocalizedString("Can read, cannot send messages.", comment: "")
    static let roleNoteAuthor = NSLocalizedString("Can send messages, cannot manage anyone else.", comment: "")
    static let roleNoteMember = NSLocalizedString("Can send messages and invite new members.", comment: "")
    static let roleNoteModerator = NSLocalizedString("Above members: can delete other people's messages and remove them.", comment: "")
    static let roleNoteAdmin = NSLocalizedString("Above moderators: can change the group profile and the roles.", comment: "")
    static let roleNoteOwner = NSLocalizedString("The highest tier in the group; you hold it yourself because you created the group.", comment: "")

    static let createCTA = NSLocalizedString("Create group", comment: "")
    static let nextStepMembers = NSLocalizedString("Next: pick people on the members page, or skip it.", comment: "")
    static let nextStepInviteInline = NSLocalizedString("Next: create the group, invite the contacts you selected here right away, then open the group.", comment: "")
    static let nextStepNoContacts = NSLocalizedString("Next: create the group, then produce a group entry you can share.", comment: "")
    static let nextStepLink = NSLocalizedString("Incognito group: the next step produces the group link directly.", comment: "")
    static let unnamedIdentity = NSLocalizedString("Unnamed identity", comment: "")

    static let errorTitle = NSLocalizedString("Creating the group failed", comment: "")
    static let inviteErrorTitle = NSLocalizedString("Adding members failed", comment: "")
    static let linkStageTitle = NSLocalizedString("Group link", comment: "")

    static let a11ySelected = NSLocalizedString("Selected", comment: "")
    static let a11yUnselected = NSLocalizedString("Not selected", comment: "")
    static let a11yToggleHint = NSLocalizedString("Add to or remove from the invitation list", comment: "")
    static let a11yProhibitedHint = NSLocalizedString("This contact cannot be invited into the group", comment: "")
}
