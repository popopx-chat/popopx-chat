//
//  PopopxAntiTheftSettingsView.swift
//  POPOPX (iOS)
//
//  【物理防抢夺 + 双密码自毁 · 设置页】模块一（传感器/超时/后台锁）与模块三（常规码 +
//  胁迫码 + 自毁后重建）唯一的配置入口，外加一页"一键模拟演练"。
//  挂载位置：我 → 隐私与安全设置 → 本页（宿主写 `PopopxAntiTheftSettingsView()`）。
//
//  ### 为什么这一页住在"我 → 隐私与安全"下面，而不是新开一个入口
//  机主要找这个功能的时候，脑子里的问题是"谁能进这个 app、什么情况下它会自我了断"，而这两
//  句话在本 app 里已经各有答案住在那一格里了：`DEFAULT_PERFORM_LA`（ContentView.swift:46 读它、
//  PrivacySettings.swift:28 写它）管"谁能进"，`DEFAULT_LA_SELF_DESTRUCT` + `SetAppPasscodeView`
//  （PrivacySettings.swift:512、:595、:665 起）管"哪把码会触发自我了断"。模块一与模块三就是这两
//  件事的新增量，不是第三件新事。新开一个顶层入口会产生第二个"安全设置"，而第二个入口的代价在
//  这里比在别的页面大得多：胁迫场景下人是被逼着在几秒内找到那个开关的，两处都有 = 两处都找不到，
//  而"机主自己找不到"就是这个功能最坏的一种失效。模块一头注那条"只加一层，不改它一层"因此
//  在界面上同样成立：本页加在隐私与安全之后，既不动上游那道 LA 门，也不复制它的开关。
//
//  ### 为什么演练页吃纯函数，而不是"真的模拟一次"
//  "真的模拟一次"在这两个功能上是自相矛盾的：拽落的真实模拟必须真的把屏幕锁掉（把机主手里正在
//  用的 app 打断），而胁迫码的真实模拟必须真的把数据擦掉——后者不可撤销，一次演练就是一次事故。
//  所以演练页只走 `PopopxMotionCriteria.evaluate(samples:sensitivity:)` 配两串合成样本
//  （`syntheticSnatch()` / `syntheticFreeFall()`），以及 `PopopxDuressAuthManager.verify(pin:)`：
//  前两者是 nonisolated 静态纯函数，返回值 `PopopxMotionVerdict` 是值类型，类型上就携带不了任何
//  副作用；后者的文档注释（`PopopxDuressAuthManager.verify(pin:)`）写明"纯校验，零副作用"，通向擦除的那条
//  路是 `submit`，而本页从不调用它。真实流用的也是同一个 `evaluate`（模块一 receive() 里那一行），
//  所以演练报出来的门限不是"给看的那一套"，就是运行时用的那一套——这是这一页能自证的前提。
//
//  ### 为什么危险操作全部走二次确认，而不是滑动手势
//  本页唯一的不可逆动作是把两把码写进 Keychain（写错并忘记时，唯一出路是手上抄存的那 12 个
//  英文词；助记词本身没有任何找回通道，且创建身份不要求手机号/邮箱）与删除这两把码。
//  滑动手势是肌肉记忆动作，快、连续、没有停顿点，一次兜里的滑动就足以构成"确认"；而这两个后果都不接受这种触发概率。
//  所以这里一律是 `PopopxButton(role: .destructive)` + `confirmationDialog` 两段式：第一段是明确的
//  红色 CTA（它自己还带一次 `.medium` 触觉），第二段是系统级、必须再点一次、且带"取消"的独立弹窗。
//  两次输入之间屏幕内容不变，机主有整段时间反悔。第三处不可逆动作是「重新生成一组」——它作废的是
//  机主手上抄存的那一张纸，所以它在这两段**之前**还多一段：先在 Keychain 里过一次身份门
//  （`proveIdentityForRegenerate()`，与「查看」同一对方法），验过了才轮到那枚红色 CTA。
//  关掉双密码那一格也走同一条门：它的 `didSet` 会
//  删除胁迫码记录（`PopopxDuressAuthManager.duressEnabled` 的 `didSet`），所以本页把它包成"先问一次"的绑定，
//  而不是让开关一滑就生效。
//
//  ### 助记词是这一页新开的唯一一扇"明文门"，所以它的三件事都带成本说明
//  12 个英文词是本模块唯一一处可明文恢复的凭据：查看它要先当场验一次机主本人——输对进入密码，
//  或在「生物识别快捷解锁」开着时过一次 Face ID，而抄在纸上的
//  那一份等价于"知道这 12 个词的人可以重新设一把进入密码"。本页因此只做三件事——
//  生成（随进入密码一起，或自己按一次）、查看（每次都要重新验一次，不缓存）、重新生成
//  （红色二次确认：旧那张纸当场作废，而机主很可能正拿着它）。并且把后果写在明面上：
//  **用助记词重置进入密码会把应急擦除密码一并清成"未设置"**
//  （`PopopxDuressAuthManager.resetEntryPinWithMnemonic`）。这一句不是提示而是设计——能重置密码的人
//  不该同时保有一把他不知道的自毁入口。重置也**不消耗**助记词，想要"用后即焚"要自己按重新生成。
//  这三条在页面上各有一句人话，不靠实现细节替它们说话。
//
//  ### 版式与依赖
//  骨架照抄 Shared/Features/Me/PopopxMeView.swift：ScrollView + `PopopxSectionCard` 分组、
//  卡片内 `PopopxPickerRow`/`PopopxToggleRow`/`PopopxRadioRow`、页脚一句诚实说明，页面自身
//  **不装 NavigationStack**（栈由宿主给，见 PopopxMeView.swift:10-12 那条同样的裁定）。
//  配色、字号、圆角、间距只取 Shared/Theme/PopopxTheme.swift 的 token；提示只走 `PopopxToastModel`，
//  触觉只走 `PopopxHaptics`；本页不写死一处颜色与间距，也没有新造按钮或输入框。
//
//  ### 两行开关的接线方式（第二轮改造后已经接通，写清楚各自的生效路径）
//  "行为判据"与"仿真烟雾弹"这两格落的还是模块一里那两把键
//  （`DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED`、`DEFAULT_ANTI_THEFT_DECOY_ENABLED`），但两格各自的
//  生效方式不一样，混成一种写法就会有一格当场不生效：
//  - 行为判据：绑的是 `PopopxBehaviorGuard.shared.enabled` 本体（`@Bindable`），它自己的 `didSet`
//    写同一把键**并**调 `sync()`，所以翻完立即起停传感器。早先那一版绑 `@AppStorage`，
//    键写了、单例没收到，要等下次启动——一个看着拨了实际没生效的安全开关比没有开关更坏。
//  - 仿真烟雾弹：模块四在它内部现读那把键、**不订阅** UserDefaults 变更通知，并在注释里点名要求
//    "这一行的 action 必须调 `refreshFromDisk()`"。所以它仍是 `@AppStorage`（模块四没有可绑的
//    `@Observable` 属性），配一条 `onChange` 补上那一句调用。
//  两处的键都是本模块唯一的口径，不会出现第二份状态。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖进 POPOPX (iOS) target —— 铁律禁止脚本改 project.pbxproj。
//

import Foundation
import SwiftUI

// MARK: - 设置页

@MainActor
struct PopopxAntiTheftSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 模块一的全部状态：开关、灵敏度、超时时档、后台即时锁，以及传感器自己的诊断读数。
    /// 这里是全仓唯一一处绑定它的界面，写它就走 `didSet` 落 UserDefaults，本页不另存一份布尔。
    @Bindable private var motion = PopopxAntiTheftMotionGuard.shared

    /// 模块三的全部状态：两把码的配置情况、生物识别开关、自毁后的重建模式。
    @Bindable private var duress = PopopxDuressAuthManager.shared

    @State private var toast = PopopxToastModel()

    /// 本机有没有生物识别能力。`biometricsAvailable` 每次读都会新建一个 `LAContext`
    /// （`PopopxDuressAuthManager.biometricsAvailable` 每次读都新建一个 `LAContext`），所以它是"进来问一次"而不是"每帧都问"。
    @State private var biometricsAvailable = false

    @State private var showsPinSheet = false
    @State private var showsTimeoutSheet = false

    /// 两段式确认的两个弹窗。
    @State private var showsCommitDialog = false
    @State private var showsClearDialog = false
    @State private var showsDuressOffDialog = false

    /// 四格口令输入。值只存在于这个 `@State` 里：写入成功、弹窗取消、离开本页时都会被清掉。
    /// 全页没有任何一处把它们的值送进 `logger`、`toast` 或 `UIPasteboard`。
    @State private var normalPin = ""
    @State private var normalConfirm = ""
    @State private var duressPin = ""
    @State private var duressConfirm = ""

    /// 原生入口码迁移：那两个 `...Active` 是进本页时现问 Keychain 得到的事实，都不为真时下面
    /// 那一整段卡片根本不渲染，本机没开过原生凭据的人不会莫名其妙被要一个密码。两者按构造互斥
    ///（`nativeSelfDestructGhostActive` 的定义里带着"入口码已经不在"），所以同一时刻只会出现一格。
    ///
    /// 它们不能复用 `pinField`：原生那两道码是**纯数字、4 到 16 位**——键盘只有 0-9 且写死
    /// `password.count < 16`（Shared/Views/LocalAuth/PasscodeEntry.swift:122-131），
    /// 提交键还额外要求不少于 4 位（同目录 PasscodeView.swift:81）；`pinField` 截到 6 位，
    /// 套上去会让一条 7 到 16 位的旧码永远输不完整、机主撞上"我明明输对了"那次拒绝。
    /// 存进去的是原文（Shared/Views/LocalAuth/SetAppPasscodeView.swift:37 `set(passcode)`），
    /// 所以比对必须由机主重新输一遍，无法从别处推导。
    @State private var nativeEntryPasswordActive = false
    @State private var nativeSelfDestructGhostActive = false
    @State private var nativePasscode = ""
    @State private var nativeSelfDestructCode = ""

    /// 写入过程中的错误文案：只装 `PopopxDuressSetupError.errorDescription` 原样那十五句，
    /// 本页不另写一份同义文案。
    @State private var pinFeedback: String?
    @State private var isWritingPins = false

    /// 模块二、模块四那两行的开关。两行各自怎么当场生效，见文件头"两行开关的接线方式"那一节：
    /// 行为判据直接绑单例（它的 `didSet` 负责写键 + `sync()`），仿真内容绑 `@AppStorage` 再配
    /// 一条 `onChange` 去叫模块四重读磁盘。
    ///
    /// 自毁方向是安全的：`PopopxAntiTheftSwitches.eraseAllTraces()` 先把两个单例的 `enabled` 拨假、
    /// 再删这批键，所以 `didSet` 回写的那一下不会让开关复活。
    @Bindable private var behavior = PopopxBehaviorGuard.shared
    @AppStorage(DEFAULT_ANTI_THEFT_DECOY_ENABLED) private var decoyEnabled = false

    // MARK: 「保留指定昵称」的身份点名（第二轮改造新增）
    //
    // 这一档存的是 `profileId` + `displayName` —— 身份信息，不是偏好，所以绝不能由界面凭空造一个
    // 0 号糊过去。列表的唯一真相来源是底层 `listUsersAsync()`，不是 `ChatModel.users`：后者可能还是
    // 启动时读的那份，而本页点错一个名字，自毁时就少删/多删一个真实身份。
    @State private var retainCandidates: [PopopxRetainCandidate] = []
    /// 拉过一次的标记。失败与"确实只有 0/1 个身份"在这一版里合并成同一个显示（防呆那一行），
    /// 理由见 `loadRetainCandidates()` 的注释——那是安全方向上的合并，不是偷懒。
    @State private var retainLoaded = false
    @State private var showsRetainSheet = false

    // MARK: 助记词的三份界面副本（值只活在这里，离开本页/查看成功后立刻清）
    //
    // 12 个英文词是**明文**，比那两把码更需要"用完就丢"：它不像 `PopopxDuressVerifier` 那样
    // 只有派生值，它本身就是能直接开门的东西。所以本页没有任何一处把它写进 `logger`、
    // `UIPasteboard`、`toast` 或任何持久化位置，也不在卡片上默认显示——必须过一次身份门
    // （输对当前进入密码，或在「生物识别快捷解锁」开着时让 Face ID 认出机主），
    // 才在这一个 `@State` 里出现一次。「重新生成一组」走的是同一对门，但它只取"证明"、
    // 不取词组：作废旧的那一张不需要先把旧的那一张摆到屏幕上。
    @State private var showsMnemonicSheet = false
    /// 「查看」与「重新生成」那一次性的进入密码输入。
    @State private var mnemonicUnlockPin = ""
    /// 验过之后拿到的那 12 个词（`revealMnemonic` 返回的已规范化单词数组，只为带序号显示；
    /// 比对从来不用这一份）。空数组 = 当前没有显示。
    @State private var mnemonicWords: [String] = []
    @State private var mnemonicFeedback: String?
    /// 这一格唯一的单飞开关：三问（密码查看、Face ID 查看、重新生成的证明）共用它，
    /// 所以任何一问在跑时其余两枚按钮自己变灰——一次只该有一个证明在飞行中。
    @State private var isReadingMnemonic = false
    /// 重新生成 = 旧那张纸当场作废，所以它和"写入两把码"一样是红色二次确认。
    /// 那一次确认只在身份门验过之后才出现，见 `proveIdentityForRegenerate()`。
    @State private var showsMnemonicRegenDialog = false
    /// 随进入密码一起生成的那一份新词组：设置成功后留在 sheet 上，等机主亲手点"我已抄存"。
    /// 不自动关 sheet —— 一弹出来就关掉，等于把唯一的抄存机会扔了。
    @State private var freshMnemonic: [String]?

    init() {}

    var body: some View {
        wrapped
    }

    /// 卡片本身。与下面 `wrapped` 分开写，是为了给类型检查器两个独立的推断上下文：
    /// 九张卡 + 四只 sheet + 四个确认框 + `task`/`onChange` 挂在同一条链上时，Swift 报的是
    /// "unable to type-check this expression in reasonable time"，而落点指向中间某行无辜的
    /// `Text(...)`——拆表达式是唯一修法，行为一行都不改。
    private var pageContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                masterCard
                sensitivityCard
                inactivityCard
                duressCard
                mnemonicCard
                lockoutCard
                rebuildCard
                drillCard
                riskCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
            // 灵敏度、档位、双密码配置状态都会改写这几张卡的说明文字。Reduce Motion 下直接落位。
            .popopxAnimation(PopopxSpring.fluid, value: animationKey, reduceMotion: reduceMotion)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.pageTitle)
        // 本页是被推进来的一级子页（我 → 隐私与安全 → 本页），标题走 inline 才不会把第一张卡顶出屏。
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 弹层与生命周期钩子。这一层里 `pageContent` 已经是一个敲定的不透明类型，所以下面这条长链
    /// 不必再把六张卡的类型一起推——上面 `pageContent` 记的那次 "unable to type-check this expression in reasonable
    /// time" 报在一行无辜的 `Text(...)` 上，病根是整条链只有一个推断上下文。行为一行都没改。
    private var wrapped: some View {
        pageContent
        .sheet(isPresented: $showsPinSheet) {
            pinSetupSheet
        }
        .sheet(isPresented: $showsTimeoutSheet) {
            timeoutSheet
        }
        .sheet(isPresented: $showsRetainSheet) {
            retainSheet
        }
        .sheet(isPresented: $showsMnemonicSheet) {
            mnemonicSheet
        }
        // 模块四现读那把键、不订阅变更通知，所以撤销/装载仿真内容必须由这一句去叫它重读磁盘。
        // 只挂在 `decoyEnabled` 上：另一格（行为判据）绑的是单例本体，它的 `didSet` 自己 `sync()`。
        .onChange(of: decoyEnabled) { _, _ in
            PopopxDecoyProfileGenerator.shared.refreshFromDisk()
        }
        // 写入前的红色二次确认。这个后果不可恢复，所以它必须由一次独立的、带"取消"的点击构成。
        .confirmationDialog(Copy.commitDialogTitle, isPresented: $showsCommitDialog, titleVisibility: .visible) {
            Button(Copy.commitDialogConfirm, role: .destructive) {
                Task { @MainActor in
                    await writePins()
                }
            }
            Button(Copy.cancel, role: .cancel) {
                clearPinFields()
            }
        } message: {
            Text(Copy.commitDialogMessage)
        }
        .confirmationDialog(Copy.clearDialogTitle, isPresented: $showsClearDialog, titleVisibility: .visible) {
            Button(Copy.clearDialogConfirm, role: .destructive) {
                clearAllPins()
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.clearDialogMessage)
        }
        .confirmationDialog(Copy.duressOffDialogTitle, isPresented: $showsDuressOffDialog, titleVisibility: .visible) {
            Button(Copy.duressOffDialogConfirm, role: .destructive) {
                duress.duressEnabled = false
                toast.show(Copy.duressOffDone, kind: .danger)
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.duressOffDialogMessage)
        }
        // 「重新生成」毁掉的是机主手上那张纸，而这个动作在页面上看起来只是点了一下按钮。
        // 所以它必须有一次独立、带"取消"、且把后果念一遍的第二击——与"写入两把码"同一道题。
        // 这一击排在身份验证**之后**：`proveIdentityForRegenerate()` 先证明按的人有机主的
        // 凭据，这里再证明他知道自己要作废什么。两道都不给缓存，所以取消之后再按会重新问一遍。
        .confirmationDialog(Copy.mnemonicRegenTitle, isPresented: $showsMnemonicRegenDialog, titleVisibility: .visible) {
            Button(Copy.mnemonicRegenConfirm, role: .destructive) {
                Task { @MainActor in
                    await regenerateMnemonic()
                }
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.mnemonicRegenMessage)
        }
        .popopxToast(toast)
        .task {
            // 每次进本页都问一次 Keychain 真实配置，而不是相信内存里那次缓存
            //（`refreshConfiguration` 自己的文档注释写明了为什么要重新读，而不是信内存那份缓存）。
            duress.refreshConfiguration()
            biometricsAvailable = duress.biometricsAvailable
            // 原生入口码 / 幽灵自毁码是否还在，同样只在这一句里问一次：它们是 Keychain 读数，
            // 放进 body 会让每次重绘都去访问一次 Keychain。
            nativeEntryPasswordActive = PopopxDuressAuthManager.nativeEntryPasswordActive
            nativeSelfDestructGhostActive = PopopxDuressAuthManager.nativeSelfDestructGhostActive
            // 身份列表同理：机主很可能就是"先去首页建一个马甲、再进来点这一档"，
            // 用上次那份列表判"只有一个身份"会把他挡在门外。
            await loadRetainCandidates()
        }
        .onChange(of: showsPinSheet) { _, opened in
            if !opened { clearPinFields() }
        }
        // 关掉查看弹层 = 那 12 个明文词从界面上消失。下一次要看必须重新验一次进入密码，
        // 本页没有任何一处把词组缓存到 `didSet`、UserDefaults 或"上次看过"的状态里。
        .onChange(of: showsMnemonicSheet) { _, opened in
            if !opened { clearMnemonicFields() }
        }
    }

    /// 动画的触发键：把会影响卡片文字的几个状态并成一个字符串，避免为每个状态各挂一次动画。
    ///
    /// 后三项是这一轮加的：助记词的"已设置/未设置"、十次抹除开关、当前失败次数，
    /// 三个都会改写卡片里的说明句子。漏掉任何一项，那一格会在状态已经变了之后仍留着上一句
    /// ——本页没有别的刷新时机（`task` 只在进场时跑一次），所以这个键就是唯一的驱动。
    ///
    /// **冷却剩余秒数故意不进这个键**：它是 `Date` 与存下来那个时刻的差，只有墙钟在动、
    /// 状态没动，放进键里既不会真的每秒变化（没有东西驱动重绘），又会误导后来人以为它在跳。
    /// 那一行的每秒刷新由 `cooldownRow` 自己的 `TimelineView` 负责。
    private var animationKey: String {
        "\(motion.enabled)-\(motion.sensitivity.wireValue)-\(duress.normalConfigured)-\(duress.duressConfigured)-\(duress.retentionStrategy.segmentIndex)-\(duress.retentionStrategy.retainedProfileId ?? -1)-\(duress.mnemonicConfigured)-\(duress.wipeOnTenthFailure)-\(duress.failedAttemptCount)"
    }

    // MARK: 总开关

    private var masterCard: some View {
        PopopxSectionCard(Copy.groupMaster, footnote: Copy.masterFootnote) {
            PopopxToggleRow(
                Copy.enabledRow,
                note: motion.enabled ? Copy.enabledNoteOn : Copy.enabledNoteOff,
                systemImage: "lock.shield.fill",
                tint: .brand,
                isOn: $motion.enabled
            )
            .accessibilityIdentifier("popopx.antiTheft.masterToggle")
            AntiTheftDivider()
            PopopxToggleRow(
                Copy.instantBgRow,
                note: Copy.instantBgNote,
                systemImage: "moon.zzz",
                tint: .neutral,
                isOn: $motion.instantLockOnBackground
            )
            AntiTheftDivider()
            // 生物识别不可用时这一行必须看得见但点不动，并且当场说明为什么：只把它藏起来，
            // 机主会以为这个功能不存在，然后在最需要它的时候找不到它。
            PopopxToggleRow(
                Copy.biometricsRow,
                note: biometricsNote,
                systemImage: "faceid",
                tint: .neutral,
                isOn: $duress.biometricsEnabled
            )
            .disabled(!biometricsAvailable)
            .opacity(biometricsAvailable ? 1 : 0.45)
            AntiTheftDivider()
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.lockNowRow)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                    Text(Copy.lockNowNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                PopopxButton(Copy.lockNowButton, systemImage: "lock", role: .secondary, fullWidth: false) {
                    lockManually()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PopopxMetrics.spaceXS)
        }
    }

    /// 连续失败降级的那一句用的是管理器自己的常数，不在这里另写一个 2。
    private var biometricsNote: String {
        if !biometricsAvailable {
            return Copy.biometricsNoteUnavailable
        }
        return String(
            format: Copy.biometricsNoteFormat,
            "\(PopopxDuressAuthManager.maxBiometricFailuresBeforeKeypad)"
        )
    }

    /// 手动锁一次。`PopopxLockReason.manual` 的后果就是"再认证一次"，与传感器判据同级，
    /// 所以这一枚按钮不需要确认弹窗：它不通向任何擦除。
    private func lockManually() {
        PopopxAppLockState.shared.lock(reason: .manual)
        PopopxHaptics.impact(.light)
        toast.show(Copy.lockNowDone, kind: .encrypted)
    }

    // MARK: 灵敏度

    /// 分段器的三个档就是枚举自己的 `allCases`，标签就是它自带的 `label`（三枚都是 ≤4 个汉字，
    /// `PopopxSegmentedControl` 内部那一行 `.lineLimit(1)` 在小屏上截不下更长的说法）。
    /// 元素类型写全是为了让 `Selection` 这个泛型参数当场定下来，不靠整段表达式反推。
    private var sensitivityOptions: [PopopxSegmentedControl<PopopxMotionSensitivity>.Option] {
        PopopxMotionSensitivity.allCases.map { .init(selection: $0, title: $0.label) }
    }

    private var sensitivityCard: some View {
        PopopxSectionCard(Copy.groupSensitivity, footnote: Copy.sensitivityFootnote) {
            PopopxSegmentedControl(
                sensitivityOptions,
                title: { $0.label },
                selection: $motion.sensitivity
            )
            .accessibilityIdentifier("popopx.antiTheft.sensitivity")
            .padding(.bottom, PopopxMetrics.spaceXS)

            // 这两行是本页"自证在做什么"的那一半：门限直接从 `PopopxMotionCriteria` 与档位的
            // `spikeG`/`spinOmega` 读出来，改判据常数这一页立刻跟着改写，不会出现界面与运行时
            // 各说一套门限。
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                thresholdLine(
                    Copy.thresholdHeadline,
                    String(
                        format: Copy.thresholdSpikeFormat,
                        fixed(motion.sensitivity.spikeG),
                        fixed(motion.sensitivity.spinOmega)
                    )
                )
                thresholdLine(
                    Copy.preconditionHeadline,
                    String(
                        format: Copy.preconditionFormat,
                        fixed(PopopxMotionCriteria.spikeRiseG),
                        fixed(PopopxMotionCriteria.calmLookback),
                        fixed(PopopxMotionCriteria.calmLowerG, digits: 2),
                        fixed(PopopxMotionCriteria.calmUpperG, digits: 2)
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AntiTheftDivider()
            PopopxToggleRow(
                Copy.behaviorRow,
                note: Copy.behaviorNote,
                systemImage: "hand.draw",
                tint: .neutral,
                isOn: $behavior.enabled
            )
            // 倾角门限：模块二唯一的数值判据。滑到多小都仍在它的 `sanitize` 区间内（15~75），
            // 越界值由它自己夹回来，本页不复算第二套上下限。
            AntiTheftDivider()
            PopopxSliderRow(
                Copy.angleRow,
                value: $behavior.angleLimitDegrees,
                in: PopopxBehaviorCriteria.minimumAngleLimitDegrees...PopopxBehaviorCriteria.maximumAngleLimitDegrees,
                step: 1,
                valueText: { "\(Int($0))°" }
            )
            .disabled(!behavior.enabled)
            .opacity(behavior.enabled ? 1 : 0.45)
            .accessibilityIdentifier("popopx.antiTheft.angleLimit")
            thresholdLine(Copy.angleHeadline, angleNoteText)
        }
    }

    /// 判据全文，四个数字全部取模块二自己的常数：本页自己复述一遍数字，就是给将来改常数的人留一个
    /// 会说谎的文案。方向口径也照 `PopopxBehaviorCriteria.evaluate` 的原样（严格大于门限，
    /// 持续秒数与触摸次数各自"达到即算"），不为了读起来顺而写成 ≥ / >。
    private var angleNoteText: String {
        String(
            format: Copy.angleFormat,
            fixed(PopopxBehaviorCriteria.minimumSustainedSeconds),
            fixed(PopopxBehaviorCriteria.irregularTouchWindow),
            "\(PopopxBehaviorCriteria.minimumIrregularTouches)"
        )
    }

    private func thresholdLine(_ headline: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Text(headline)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Text(value)
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopopxMetrics.space2XS)
        }
    }

    // MARK: 无操作锁屏时长
    //
    // 选 `PopopxPickerRow` + Sheet 内 `PopopxRadioRow`，而不是把五行 RadioRow 直接铺在页面上，
    // 理由有两层：一是仓库现状——所有"N 选一且每项都带解释"的档位（附近配对策略
    // `PopopxMeView.pairingPolicySheet` 与 `PopopxSettingsViews` 里同名的那一个）走的都是"入口行 + radio 表"这一条，
    // 沿用它是为了这一页看起来本来就是这个 app 的一部分；二是这一格一共五个档，铺在页面上会
    // 让"锁屏时长"这一组比它上面的双密码还长，排版重心就歪了。入口行尾还多带一个当前档位的标签，
    // 铺开来反而看不到"现在选的是哪个"。

    private var inactivityCard: some View {
        PopopxSectionCard(Copy.groupInactivity, footnote: Copy.inactivityFootnote) {
            PopopxPickerRow(
                Copy.inactivityRow,
                value: motion.inactivityTimeout.label,
                systemImage: "timer",
                tint: .brand
            ) {
                PopopxHaptics.selection()
                showsTimeoutSheet = true
            }
            .accessibilityIdentifier("popopx.antiTheft.inactivity")
            .accessibilityValue(motion.inactivityTimeout.label)
        }
    }

    private var timeoutSheet: some View {
        NavigationStack {
            PopopxSheetContainer(Copy.timeoutSheetTitle, subtitle: Copy.timeoutSheetSubtitle) {
                PopopxSectionCard {
                    ForEach(Array(PopopxInactivityTimeout.allCases.enumerated()), id: \.element) { index, timeout in
                        if index > 0 {
                            AntiTheftDivider()
                        }
                        PopopxRadioRow(
                            timeout.label,
                            note: timeoutNote(timeout),
                            selected: motion.inactivityTimeout == timeout
                        ) {
                            PopopxHaptics.selection()
                            motion.inactivityTimeout = timeout
                            showsTimeoutSheet = false
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsTimeoutSheet = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// 五个档各有自己的后果说明，`never` 那一档必须把风险写出来而不是只写"永不"。
    private func timeoutNote(_ timeout: PopopxInactivityTimeout) -> String {
        switch timeout {
        case .oneMinute: return Copy.timeoutNoteOne
        case .threeMinutes: return Copy.timeoutNoteThree
        case .fiveMinutes: return Copy.timeoutNoteFive
        case .fifteenMinutes: return Copy.timeoutNoteFifteen
        case .never: return Copy.timeoutNoteNever
        }
    }

    // MARK: 双密码

    private var duressCard: some View {
        PopopxSectionCard(Copy.groupDuress, footnote: Copy.duressFootnote) {
            PopopxToggleRow(
                Copy.duressSwitchRow,
                note: duressSwitchNote,
                systemImage: "exclamationmark.triangle.fill",
                tint: .danger,
                isOn: duressEnabledBinding
            )
            AntiTheftDivider()
            PopopxPickerRow(
                Copy.duressSetupRow,
                value: duressStatusValue,
                systemImage: "key.fill",
                tint: .brand
            ) {
                PopopxHaptics.impact(.light)
                duress.refreshConfiguration()
                nativeEntryPasswordActive = PopopxDuressAuthManager.nativeEntryPasswordActive
                nativeSelfDestructGhostActive = PopopxDuressAuthManager.nativeSelfDestructGhostActive
                showsPinSheet = true
            }
            .accessibilityIdentifier("popopx.antiTheft.duressEntry")
            .accessibilityValue(duressStatusValue)
            AntiTheftDivider()
            // 应急擦除密码单独那一行的状态，按简报口径只说两种话：已设置 / 未设置。
            // 它是 `duressConfigured` 的直接读数，而后者每次都由 `refreshConfiguration()`
            // 现问 Keychain——所以触发过一次应急擦除、再回到本页，这里会自己变成"未设置"，
            // 本页不需要额外记"刚刚自毁过"这种状态（记了反而会与 Keychain 打架）。
            thresholdLine(Copy.duressStateHeadline, duressStateValue)
            AntiTheftDivider()
            // 不可恢复的动作留成一行红 + 一次系统弹窗；`PopopxButton` 自己会读 isEnabled 降到 0.45。
            PopopxButton(
                Copy.duressClearRow,
                systemImage: "trash",
                role: .destructive
            ) {
                showsClearDialog = true
            }
            .disabled(!duress.normalConfigured && !duress.duressConfigured)
        }
    }

    /// 关掉这一格会删掉胁迫码记录（`PopopxDuressAuthManager.duressEnabled` 的 `didSet`），所以 `set` 只开弹窗、
    /// 不写值：真正的写入在 `confirmationDialog` 的红色那一支里。开的那一方向没有副作用，直接写。
    private var duressEnabledBinding: Binding<Bool> {
        Binding(
            get: { duress.duressEnabled },
            set: { newValue in
                if newValue {
                    duress.duressEnabled = true
                } else {
                    showsDuressOffDialog = true
                }
            }
        )
    }

    private var duressSwitchNote: String {
        duress.duressEnabled
            ? Copy.duressSwitchNoteOn
            : Copy.duressSwitchNoteOff
    }

    /// 行尾写的是 Keychain 里现在真的有什么，不是"我刚才设过了吧"。
    private var duressStatusValue: String {
        if !duress.normalConfigured {
            return Copy.duressStatusNone
        }
        return duress.duressConfigured ? Copy.duressStatusBoth : Copy.duressStatusNormalOnly
    }

    /// 应急擦除密码这一件事本身的状态。它的一切写入点都在模块三内部，且每一处都是跟着
    /// Keychain 的实际读数走的（`refreshConfiguration()` 现问、`setDuressPin` 写成功后置真、
    /// `clearDuressPin`/`duressEnabled` 的 `didSet`/降级那一步 `runDuressFlow` 置假）。
    /// 所以"触发过一次应急擦除、再回本页显示未设置"不是本页的判断，而是把 Keychain 的事实原样念出来。
    private var duressStateValue: String {
        duress.duressConfigured ? Copy.duressStateSet : Copy.duressStateUnset
    }

    // MARK: 12 词助记词

    /// 助记词那一格的状态，与 `duressStateValue` 同一个口径：**现问 Keychain**。
    /// `mnemonicConfigured` 要求"派生哈希 + 可回看明文"两条记录都在（管理器里那条与运算），
    /// 所以半新一旧的助记词在这里读作"未设置"，而不是显示一句"可以查看"再把机主送去撞一次失败。
    private var mnemonicStateValue: String {
        duress.mnemonicConfigured ? Copy.mnemonicStateSet : Copy.mnemonicStateUnset
    }

    /// Face ID 那道门现在能不能用。三条缺一不可，且与
    /// `PopopxDuressAuthManager.verifyIdentityWithBiometrics` 开头那三道 `guard` 一一对应：
    /// 少一条，弹层里那枚「用 Face ID 验证并显示」与那枚「用 Face ID 验证并重新生成」
    /// 按下去就只会得到一句"未通过"——两问共用这一道门，所以也共用这一条判断。
    /// - `duress.biometricsEnabled`：本页那个总开关。
    /// - `!duress.keypadRequired`：遮罩上刚连着失败两次，本次会话降级成"只认键盘码"。
    ///   这条降级同样管到设置页——它是"这段时间内生物识别不可信"，不是"锁屏那一面暂时不给"。
    /// - `biometricsAvailable`：本机现在判得出可用。这里用的是本页 `@State` 那份"进来问一次"的
    ///   读数；管理器那一版每次读都新建一个 `LAContext`，放进 body 就是每次重绘问一次。
    /// 冷却状态故意不在这里问，理由与那边相同：这两问都不吃失败计数，也就没有可归零的东西。
    private var mnemonicFaceIDOffered: Bool {
        duress.biometricsEnabled && !duress.keypadRequired && biometricsAvailable
    }

    /// 助记词那一行的行尾值。三个值而不是"已配置/未配置"两个：那道门开不开，机主在
    /// 这一行就该看见，而不是点进弹层才发现少了一枚按钮。
    private var mnemonicRowValue: String {
        guard duress.mnemonicConfigured else { return Copy.mnemonicRowGenerate }
        return mnemonicFaceIDOffered ? Copy.mnemonicRowRevealEither : Copy.mnemonicRowReveal
    }

    /// 「重新生成一组」这一问走哪道门，取值规则与上面那两枚「查看」按钮是同一套：
    /// - `.entryPin`：密码框里已经填够 6 位——走 `verifyEntryPin`，与「验证并显示」同一半实现。
    /// - `.biometric`：没填够，但 Face ID 那道门开着——走 `verifyIdentityWithBiometrics`。
    /// - `.unavailable`：两条都不满足，没有门可走。这一支**禁用**按钮，理由与 Face ID
    ///   那一枚只在真能通过时出现是同一条：一枚按下去只会报错的按钮不该存在于页面上。
    /// 填了 3 位、Face ID 又开着时算 `.biometric`：那半截密码不构成一条能走的路，
    /// 而"用 Face ID 也一样能过"是真的，机主随时可以改成打满 6 位换回密码那一道路。
    private enum MnemonicRegenDoor {
        case entryPin
        case biometric
        case unavailable
    }

    private var mnemonicRegenDoor: MnemonicRegenDoor {
        if PopopxDuressAuthManager.isValidPin(mnemonicUnlockPin) { return .entryPin }
        return mnemonicFaceIDOffered ? .biometric : .unavailable
    }

    /// 门写在按钮名字上，机主按下去之前就知道这一次要交的是什么。词法与「验证并显示」/
    /// 「用 Face ID 验证并显示」那一对齐：不带定语的"验证"就是指上面那个密码框。
    private var mnemonicRegenLabel: String {
        guard duress.mnemonicConfigured else { return Copy.mnemonicSheetGenerate }
        switch mnemonicRegenDoor {
        case .entryPin: return Copy.mnemonicSheetRegenerateVerified
        case .biometric: return Copy.mnemonicSheetRegenerateFaceID
        case .unavailable: return Copy.mnemonicSheetRegenerate
        }
    }

    private var mnemonicCard: some View {
        PopopxSectionCard(Copy.groupMnemonic, footnote: Copy.mnemonicFootnote) {
            thresholdLine(Copy.mnemonicStateHeadline, mnemonicStateValue)
            AntiTheftDivider()
            PopopxPickerRow(
                Copy.mnemonicRow,
                value: mnemonicRowValue,
                systemImage: "text.page.fill",
                tint: .brand
            ) {
                PopopxHaptics.impact(.light)
                duress.refreshConfiguration()
                clearMnemonicFields()
                freshMnemonic = nil
                showsMnemonicSheet = true
            }
            .accessibilityIdentifier("popopx.antiTheft.mnemonicEntry")
            .accessibilityValue(mnemonicRowValue)
            .disabled(!duress.normalConfigured)
            // 后果写在明面上，而不是等机主在锁屏上撞见：重置会把应急擦除密码清成"未设置"。
            // 这一句与 `lockoutCard` 那句红是本页仅有的两处 dangerInk 说明，两处都是不可逆方向。
            AntiTheftDivider()
            warningLine(Copy.mnemonicConsequence)
        }
    }

    /// 助记词的查看/生成弹层。
    ///
    /// 四条实现约定，都是这一格特有的：
    /// 1. **不给 `.textSelection(.enabled)`**：一选中就可能进系统剪贴板，而剪贴板会被其他 app
    ///    读到、也可能随 iCloud 同步到别的设备上。一张能明文恢复身份的词组不该被系统复制到
    ///    本模块管不着的地方，所以这一格只能"用眼睛抄"。
    /// 2. **关掉弹层即清空**（`onChange(of: showsMnemonicSheet)` → `clearMnemonicFields()`），
    ///    下一次要看必须重新验一次——进入密码或 Face ID，两道门都一样只当场有效。
    ///    本页不留"上次看过"的状态。
    /// 3. 那两枚按钮都不是"一点就亮"：密码那一道路要走一次约 355 ms 的 PBKDF2 派生，
    ///    Face ID 那一道路要等系统弹层收结果，所以两枚都带 `isLoading`；
    ///    不靠转场动画盖这段等待。
    /// 4. **「重新生成一组」先过同一对门**（`proveIdentityForRegenerate()`）：这一问作废的是
    ///    机主手上那张纸，旁人拿到已解锁的手机顺手点一下就够糟，所以那一次红色二次确认
    ///    只在身份验过之后才出现。顺序是"先验身份、再问确认"，两问各管一件事：
    ///    前者证明有权，后者证明有意。这一问不读取、不显示旧词组。
    private var mnemonicSheet: some View {
        NavigationStack {
            PopopxSheetContainer(Copy.mnemonicSheetTitle, subtitle: mnemonicSheetHint) {
                PopopxSectionCard(Copy.mnemonicSheetGroup, footnote: Copy.mnemonicSheetFootnote) {
                    if !mnemonicWords.isEmpty {
                        mnemonicWordGrid(mnemonicWords)
                        AntiTheftDivider()
                        PopopxButton(Copy.mnemonicSheetHide, systemImage: "eye.slash") {
                            clearMnemonicFields()
                        }
                    } else {
                        if duress.mnemonicConfigured {
                            pinField(Copy.mnemonicSheetPinLabel, prompt: Copy.pinPrompt, text: $mnemonicUnlockPin)
                            AntiTheftDivider()
                            PopopxButton(
                                Copy.mnemonicSheetReveal,
                                systemImage: "eye",
                                isLoading: isReadingMnemonic
                            ) {
                                await revealMnemonicNow()
                            }
                            .disabled(!PopopxDuressAuthManager.isValidPin(mnemonicUnlockPin))
                            .accessibilityIdentifier("popopx.antiTheft.mnemonicReveal")
                            // 另一道门只在它真能通过的时候出现。三个条件与
                            // `PopopxDuressAuthManager.verifyIdentityWithBiometrics` 那三道前置门
                            // 逐字对应——少一条，这里就是一枚按下去只会报错的按钮。
                            // 两枚按钮共用 `isReadingMnemonic`，所以任一条路在跑时另一枚自己变灰：
                            // 同一次点击只该交出去一份明文。
                            if mnemonicFaceIDOffered {
                                AntiTheftDivider()
                                PopopxButton(
                                    Copy.mnemonicSheetRevealFaceID,
                                    systemImage: "faceid",
                                    role: .secondary,
                                    isLoading: isReadingMnemonic
                                ) {
                                    await revealMnemonicWithFaceID()
                                }
                                .accessibilityIdentifier("popopx.antiTheft.mnemonicRevealFaceID")
                            }
                            AntiTheftDivider()
                        }
                        PopopxButton(
                            mnemonicRegenLabel,
                            systemImage: duress.mnemonicConfigured ? "arrow.triangle.2.circlepath" : "plus",
                            role: duress.mnemonicConfigured ? .destructive : .primary,
                            isLoading: isReadingMnemonic
                        ) {
                            // 还没有词组时这一次点击不毁掉任何东西，直接生成；已有词组时它毁掉的是
                            // 机主手上那张纸，所以先过一次与「查看」完全相同的身份门，
                            // 验过了才轮到那一次红色二次确认。
                            if duress.mnemonicConfigured {
                                await proveIdentityForRegenerate()
                            } else {
                                await regenerateMnemonic()
                            }
                        }
                        .disabled(duress.mnemonicConfigured && mnemonicRegenDoor == .unavailable)
                        .accessibilityIdentifier("popopx.antiTheft.mnemonicGenerate")
                    }
                    if let mnemonicFeedback {
                        AntiTheftDivider()
                        Text(mnemonicFeedback)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.dangerInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                PopopxSectionCard(Copy.mnemonicSheetPaperGroup, footnote: nil) {
                    warningLine(Copy.mnemonicSheetPaperNote)
                }
                if duress.mnemonicConfigured {
                    PopopxSectionCard(Copy.mnemonicSheetWhyGroup, footnote: nil) {
                        Text(Copy.mnemonicSheetWhyNoCount)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsMnemonicSheet = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// 写盘成功后那一张抄存页。它不提供任何输入框，也不提供"重新生成"：机主刚点过一次
    /// 「写入这两把码」，这一屏唯一要完成的事是把 12 个词抄到纸上。想换一组词，
    /// 关掉之后回到助记词那一格重做。
    ///
    /// 只提供 `.large` 一档 detent：那 12 个格子加两句说明在 `.medium` 上会被裁掉一半，
    /// 而一张裁掉了词的抄存页比没有这一屏更糟——机主会以为自已抄完了。
    private func mnemonicCaptureSheet(_ words: [String]) -> some View {
        NavigationStack {
            PopopxSheetContainer(Copy.mnemonicCaptureTitle, subtitle: Copy.mnemonicCaptureSubtitle) {
                PopopxSectionCard(Copy.mnemonicSheetGroup, footnote: Copy.mnemonicSheetFootnote) {
                    mnemonicWordGrid(words)
                }
                PopopxSectionCard(Copy.mnemonicSheetPaperGroup, footnote: nil) {
                    warningLine(Copy.mnemonicSheetPaperNote)
                }
            } footer: {
                PopopxButton(Copy.mnemonicCaptureDone, systemImage: "checkmark") {
                    showsPinSheet = false
                }
                .padding(PopopxMetrics.spaceM)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsPinSheet = false }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// 12 个词、带序号、两列。序号是必要的，不是装饰：抄错位置（把第 7 个词抄到第 6 格）
    /// 与抄错字母一样会让整条词组失效，而 BIP-39 的校验和只有 4 bit，挡不住这种错位。
    /// 两列用 `.flexible()`，不写最小宽度——`PopopxMetrics` 里没有这一类代币，
    /// 编一个数出来就是这一页承诺过的"不写死一处尺寸"的反面。
    ///
    /// 参数而不是直接读 `mnemonicWords`：回看那一屏与抄存那一屏用的是两份不同的 `@State`
    /// （前者用完即丢，后者要撑到机主亲手点「我已抄存」），排版这一段则必须完全一样。
    private func mnemonicWordGrid(_ words: [String]) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: PopopxMetrics.spaceXS), GridItem(.flexible(), spacing: PopopxMetrics.spaceXS)],
            spacing: PopopxMetrics.spaceXS
        ) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: PopopxMetrics.spaceXS) {
                    Text("\(index + 1)")
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.labelHint)
                        .frame(width: PopopxMetrics.spaceXL, alignment: .trailing)
                        .accessibilityHidden(true)
                    Text(word)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                    Spacer(minLength: PopopxMetrics.space2XS)
                }
                .padding(.vertical, PopopxMetrics.space2XS)
                .padding(.horizontal, PopopxMetrics.spaceXS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PopopxPalette.cardHigh, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.mnemonicGridLabel)
        .accessibilityIdentifier("popopx.antiTheft.mnemonicWords")
    }

    /// 弹层副标题要说的是"这一格现在真的能用什么"：Face ID 那道门没开时不许写"或 Face ID"，
    /// 否则机主会在一排按钮里找一个不存在的。
    private var mnemonicSheetHint: String {
        guard duress.mnemonicConfigured else { return Copy.mnemonicSheetHintNone }
        return mnemonicFaceIDOffered ? Copy.mnemonicSheetHintHaveBiometric : Copy.mnemonicSheetHintHave
    }

    // MARK: 渐进式防爆破

    private var lockoutStrikesValue: String {
        let strikes = duress.failedAttemptCount
        if strikes == 0 {
            return Copy.lockoutStrikesNone
        }
        return String(
            format: Copy.lockoutStrikesFormat,
            "\(strikes)",
            "\(duress.strikesUntilWipe)"
        )
    }

    /// 那张表**从表本体读出来**，不在这里另抄一遍数字：`PopopxLockoutSchedule` 改了，
    /// 这一句跟着改。抄一份就是给将来那个改表的人留一处会说不成立的话的文案。
    private var lockoutScheduleValue: String {
        let steps = [5, 6, 7, 8].map { attempt in
            String(
                format: Copy.lockoutStepFormat,
                "\(attempt)",
                PopopxLockoutSchedule.phrase(PopopxLockoutSchedule.lockoutSeconds(afterAttemptCount: attempt))
            )
        }
        return String(format: Copy.lockoutScheduleFormat, steps.joined(separator: " · "))
    }

    /// 冷却那一行每秒都要动，而"剩余秒数"是 `Date` 与存下来那个时刻的差、没有任何状态在变，
    /// 所以它不能靠 `animationKey` 驱动（见那里那条注释）。`TimelineView` 是这一格自己的心跳。
    private var cooldownRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = duress.lockoutEndsAt.map { $0.timeIntervalSince(context.date) } ?? 0
            thresholdLine(
                Copy.lockoutCoolingHeadline,
                remaining > 0
                    ? String(format: Copy.lockoutCoolingFormat, PopopxLockoutSchedule.phrase(remaining))
                    : Copy.lockoutCoolingIdle
            )
        }
    }

    private var lockoutCard: some View {
        PopopxSectionCard(Copy.groupLockout, footnote: Copy.lockoutFootnote) {
            thresholdLine(Copy.lockoutStrikesHeadline, lockoutStrikesValue)
            AntiTheftDivider()
            cooldownRow
            AntiTheftDivider()
            thresholdLine(Copy.lockoutScheduleHeadline, lockoutScheduleValue)
            AntiTheftDivider()
            PopopxToggleRow(
                Copy.lockoutTenStrikeRow,
                note: lockoutTenStrikeNote,
                systemImage: "exclamationmark.octagon.fill",
                tint: .danger,
                isOn: $duress.wipeOnTenthFailure
            )
            .accessibilityIdentifier("popopx.antiTheft.tenStrikeWipe")
            AntiTheftDivider()
            warningLine(Copy.lockoutTenStrikeWarning)
        }
    }

    /// 开与关说的是两件相反的事，所以两句分开写，不玩"前缀 + 共用后半句"那种拼接：
    /// 关掉那一档意味着第 10 次只是"再多锁一小时"，这一句必须让机主知道自己是**主动**放弃了抹除。
    private var lockoutTenStrikeNote: String {
        duress.wipeOnTenthFailure ? Copy.lockoutTenStrikeNoteOn : Copy.lockoutTenStrikeNoteOff
    }

    /// `riskLine` 的红色版本：本页只有"会被执行到的破坏性后果"配得上这个颜色。
    private func warningLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.dangerInk)
                .accessibilityHidden(true)
            Text(text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.dangerInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 查看助记词：交一次进入密码，换 12 个词。
    ///
    /// 密码在这一句之后立刻从界面上清掉（`mnemonicUnlockPin = ""`），**成功与失败都一样**：
    /// 这一格的目的只是"当场证明机主知道进入密码"，证明完那一份副本就该没了。
    /// 失败只把 `errorDescription` 原样显示，不做任何"第几位不对"之类的提示。
    private func revealMnemonicNow() async {
        let pin = mnemonicUnlockPin
        mnemonicUnlockPin = ""
        mnemonicFeedback = nil
        mnemonicWords = []
        guard PopopxDuressAuthManager.isValidPin(pin) else {
            mnemonicFeedback = PopopxDuressSetupError.entryPinRequired.errorDescription
            PopopxHaptics.notice(.warning)
            return
        }
        isReadingMnemonic = true
        defer { isReadingMnemonic = false }
        do {
            mnemonicWords = try await duress.revealMnemonic(unlockingWith: pin)
            PopopxHaptics.notice(.success)
            toast.show(Copy.mnemonicToastShown, kind: .encrypted)
        } catch let error as PopopxDuressSetupError {
            mnemonicFeedback = error.errorDescription
            clearMnemonicFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicToastRejected, kind: .danger)
        } catch {
            mnemonicFeedback = Copy.mnemonicUnexpectedFailure
            clearMnemonicFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicToastRejected, kind: .danger)
        }
    }

    /// 查看助记词的第二道门：Face ID。要交出去的东西与 `revealMnemonicNow` 完全相同，
    /// 所以收尾纪律也完全相同——先清掉上一屏残留（反馈文案与可能还亮着的词组），
    /// 失败只把 `errorDescription` 原样说一句，然后 `clearMnemonicFields()`。
    ///
    /// 这一条没有明文副本要清：密码不进这一路，`mnemonicUnlockPin` 保持原样，机主刚打的字
    /// 不该被另一枚按钮的失败没收。派生也不走这一路，所以这一次等待是系统弹层，不是三百毫秒。
    private func revealMnemonicWithFaceID() async {
        mnemonicFeedback = nil
        mnemonicWords = []
        isReadingMnemonic = true
        defer { isReadingMnemonic = false }
        do {
            mnemonicWords = try await duress.revealMnemonicWithBiometrics(reason: Copy.mnemonicSheetFaceIDReason)
            PopopxHaptics.notice(.success)
            toast.show(Copy.mnemonicToastShown, kind: .encrypted)
        } catch let error as PopopxDuressSetupError {
            mnemonicFeedback = error.errorDescription
            clearMnemonicFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicToastRejected, kind: .danger)
        } catch {
            mnemonicFeedback = Copy.mnemonicUnexpectedFailure
            clearMnemonicFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicToastRejected, kind: .danger)
        }
    }

    /// 「重新生成一组」那一次点击：先按 `mnemonicRegenDoor` 指定的那一道路证明机主本人，
    /// 验过了才把红色二次确认放出来。顺序是刻意的——先验身份、再问"你确定要作废那张纸吗"：
    /// 这一问要防的是旁人拿到已解锁的手机顺手点一下，而那一次点击连一次证明都不该拿到。
    ///
    /// 两道门调的是管理器里与「查看」同一对方法，所以两问的放行条件不许有差别。这里**不**读取、
    /// 也不显示旧词组：证明过就等于有权作废它，没有必要把上一张纸再摆到屏幕上来。
    ///
    /// 证明不缓存，与 `revealMnemonicNow` 同一条收尾纪律：密码当场从界面上清掉，成功与失败都一样。
    /// 所以取消那一次红色确认之后再按，会重新问一遍——上一次"我已经验过了"的状态不在这里留着。
    private func proveIdentityForRegenerate() async {
        mnemonicFeedback = nil
        // 与那两枚「查看」按钮同一件事：问之前重新读一遍 Keychain 的真实状态，
        // 别信内存里那份缓存——中途发生过自毁时，这里的 `mnemonicConfigured` 必须说得上话。
        duress.refreshConfiguration()
        isReadingMnemonic = true
        defer { isReadingMnemonic = false }
        do {
            switch mnemonicRegenDoor {
            case .entryPin:
                let pin = mnemonicUnlockPin
                mnemonicUnlockPin = ""
                try await duress.verifyEntryPin(pin)
            case .biometric:
                try await duress.verifyIdentityWithBiometrics(reason: Copy.mnemonicRegenFaceIDReason)
            case .unavailable:
                // 这一支的按钮是禁用的（见 `mnemonicRegenDoor`），正常到不了；真到了也直接返回，
                // 宁可什么都不做，也不"没有证明就放行"。
                return
            }
        } catch let error as PopopxDuressSetupError {
            mnemonicFeedback = error.errorDescription
            mnemonicUnlockPin = ""
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicRegenToastRejected, kind: .danger)
            return
        } catch {
            mnemonicFeedback = Copy.mnemonicRegenUnexpectedFailure
            mnemonicUnlockPin = ""
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicRegenToastRejected, kind: .danger)
            return
        }
        PopopxHaptics.notice(.success)
        showsMnemonicRegenDialog = true
    }

    /// 生成 / 重新生成助记词。成功就把新词组显示出来——这是机主唯一一次能抄到它的机会。
    ///
    /// 失败分支不重试、也不留半成品：管理器那边（`storeMnemonic`）任一半失败就整对回滚，
    /// 所以这里只需要照实说一句"没有生成"，不必判断"是不是只写进去了一半"。
    ///
    /// 调用它之前该已经过一次证明：`showsMnemonicRegenDialog` 那一支由
    /// `proveIdentityForRegenerate` 在验过身份之后才打开；`mnemonicConfigured` 还是 false 时
    /// 这一次点击不毁掉任何东西，所以那一条路不需要门。写入本身在管理器里不设门——
    /// 随进入密码一起生成第一组词组的那条路也走同一个方法，那道门在那边是无意义的。
    private func regenerateMnemonic() async {
        showsMnemonicRegenDialog = false
        mnemonicFeedback = nil
        mnemonicWords = []
        isReadingMnemonic = true
        defer { isReadingMnemonic = false }
        if let words = await duress.generateMnemonic() {
            mnemonicWords = words
            PopopxHaptics.notice(.success)
            toast.show(Copy.mnemonicToastGenerated, kind: .encrypted)
        } else {
            mnemonicFeedback = Copy.mnemonicGenerateFailed
            PopopxHaptics.notice(.error)
            toast.show(Copy.pinToastRejected, kind: .danger)
        }
        duress.refreshConfiguration()
    }

    /// 助记词与密码那三格一次性清空。与 `clearPinFields` 同一个理由：明文副本不该比
    /// 它的使用场合活得更久——这里甚至比那两把码更要紧，因为这一份是**可读的原文**。
    private func clearMnemonicFields() {
        mnemonicUnlockPin = ""
        mnemonicWords = []
        mnemonicFeedback = nil
        isReadingMnemonic = false
    }

    // MARK: 双密码设置 Sheet

    /// 同一个 sheet 位置上的两种互斥界面：填那两把码的表，与写盘成功后紧接着出现的抄存页。
    ///
    /// 分成两张、而不是在那张表里插一段 `if`：写入成功后那六个输入框已经没有任何待办，
    /// 把它们留着只等于再给一次「写入这两把码」的点击机会——那一次点击会用一把新盐把刚写进去的
    /// 东西再覆盖一遍，界面上却是一片"我刚才到底写了什么"。
    @ViewBuilder
    private var pinSetupSheet: some View {
        if let words = freshMnemonic {
            mnemonicCaptureSheet(words)
        } else {
            pinSetupFormSheet
        }
    }

    private var pinSetupFormSheet: some View {
        NavigationStack {
            PopopxSheetContainer(Copy.pinSheetTitle, subtitle: Copy.pinSheetSubtitle) {
                PopopxSectionCard(Copy.pinGroupNormal, footnote: Copy.pinNormalFootnote) {
                    pinField(Copy.pinNormalLabel, prompt: Copy.pinPrompt, text: $normalPin)
                    AntiTheftDivider()
                    pinField(Copy.pinNormalConfirmLabel, prompt: Copy.pinPrompt, text: $normalConfirm)
                    AntiTheftDivider()
                    pinStateLine(normalPin, confirming: normalConfirm)
                }
                // 这一段只在原生那两道旧凭据确实还留着时出现，且紧跟常规密码那一组：迁移就发生在
                // `setNormalPin` 里、任何写入之前（PopopxDuressAuthManager.swift:1358），
                // 放在胁迫码之后会让"先填旧密码"这个先后关系在页面上读不出来。
                // 两格互斥，由模块三那两个读数保证：入口码还在 → 要入口码；入口码已经没了、
                // 只剩一把按不动的自毁码 → 要那把自毁码。
                // 与 `pinField` 一样不送 `systemImage`/`keyboard:`——`isSecure` 那条分支不读它。
                if nativeEntryPasswordActive {
                    PopopxSectionCard(Copy.pinNativeGroup, footnote: Copy.pinNativeFootnote) {
                        nativePasscodeField(Copy.pinNativeLabel, prompt: Copy.pinNativePrompt, text: $nativePasscode)
                    }
                } else if nativeSelfDestructGhostActive {
                    PopopxSectionCard(Copy.pinNativeSDGroup, footnote: Copy.pinNativeSDFootnote) {
                        nativePasscodeField(
                            Copy.pinNativeSDLabel,
                            prompt: Copy.pinNativePrompt,
                            text: $nativeSelfDestructCode
                        )
                    }
                }
                PopopxSectionCard(Copy.pinGroupDuress, footnote: Copy.pinDuressFootnote) {
                    pinField(Copy.pinDuressLabel, prompt: Copy.pinPrompt, text: $duressPin)
                    AntiTheftDivider()
                    pinField(Copy.pinDuressConfirmLabel, prompt: Copy.pinPrompt, text: $duressConfirm)
                    AntiTheftDivider()
                    pinStateLine(duressPin, confirming: duressConfirm)
                }
                if let pinFeedback {
                    PopopxSectionCard {
                        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(PopopxType.microTag)
                                .imageScale(.medium)
                                .foregroundStyle(PopopxPalette.dangerInk)
                                .accessibilityHidden(true)
                            Text(pinFeedback)
                                .font(PopopxType.caption)
                                .foregroundStyle(PopopxPalette.dangerInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                PopopxSectionCard(Copy.pinIrreversibleGroup, footnote: nil) {
                    Text(Copy.pinIrreversibleNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                PopopxButton(
                    Copy.pinWriteButton,
                    systemImage: "lock.fill",
                    role: .destructive,
                    isLoading: isWritingPins
                ) {
                    showsCommitDialog = true
                }
                .padding(PopopxMetrics.spaceM)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsPinSheet = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// 六格数字码的输入框。用 `PopopxTextField(isSecure:)`：它内部是 `SecureField`，
    /// 因此不带历史候选、不自动纠错、也不参与系统的密码自动填充建议
    ///（PopopxControls.swift:237-241 那一条分支）。这里刻意不送 `systemImage`，也不给
    /// `keyboard:`：那条分支不读它，给了也是个不起眼的假承诺（详见提交说明）。
    private func pinField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        PopopxTextField(label, prompt: prompt, text: text, isSecure: true)
            .onChange(of: text.wrappedValue) { _, newValue in
                clampToDigits(text, newValue, maxLength: PopopxDuressAuthManager.pinLength)
            }
    }

    /// 只留 ASCII 数字、长度截到 `maxLength`。这是纯过滤，不回显：任何一格的值都不会出现在
    /// 文案里，界面上最多出现"填了几格 / 两格是否一致"这类与内容无关的事实。
    ///
    /// `maxLength` 必须是显式入参、不能写成默认值：默认参数表达式在 Swift 里于非隔离上下文求值，
    /// 而 `PopopxDuressAuthManager.pinLength` 随整个 `@MainActor` 类隔离，写成
    /// `maxLength: Int = PopopxDuressAuthManager.pinLength` 会当场报
    /// "main actor-isolated static property can not be referenced from a nonisolated context"
    /// （Swift 6 语言模式下直接是 error）。
    private func clampToDigits(_ target: Binding<String>, _ newValue: String, maxLength: Int) {
        let filtered = String(
            newValue
                .filter { PopopxDuressAuthManager.digits.contains($0) }
                .prefix(maxLength)
        )
        if filtered != newValue { target.wrappedValue = filtered }
    }

    /// 原生键盘写死的上限（Shared/Views/LocalAuth/PasscodeEntry.swift:125 `password.count < 16`，
    /// 同一件事还在 :131 把按键整个禁用掉）。
    private static let nativePasscodeMaxLength = 16

    /// 原生那两道旧码共用的输入格：同一个 `PopopxTextField(isSecure:)`，但截到原生键盘自己的
    /// 16 位上限，而不是双密码的 6 位。入口码与自毁码出自同一台键盘（同一个 `PasscodeEntry`），
    /// 所以长度与字符集完全同规，只有标签和说明不同。
    private func nativePasscodeField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        PopopxTextField(label, prompt: prompt, text: text, isSecure: true)
            .onChange(of: text.wrappedValue) { _, newValue in
                clampToDigits(text, newValue, maxLength: Self.nativePasscodeMaxLength)
            }
    }

    /// 两格之间的即时一致性：只说"一致/不一致"，不说值。误触是这一页最贵的错误，
    /// 让它在校验之前就可见。
    private func pinStateLine(_ first: String, confirming second: String) -> some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: stateSymbol(first: first, confirming: second))
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(stateInk(first: first, confirming: second))
                .accessibilityHidden(true)
            Text(stateSentence(first: first, confirming: second))
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopopxMetrics.space2XS)
        }
        .padding(.vertical, PopopxMetrics.space2XS)
    }

    private func stateSymbol(first: String, confirming second: String) -> String {
        if first.isEmpty { return "circle" }
        return (first == second && PopopxDuressAuthManager.isValidPin(first)) ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func stateInk(first: String, confirming second: String) -> Color {
        if first.isEmpty { return PopopxPalette.labelHint }
        return (first == second && PopopxDuressAuthManager.isValidPin(first))
            ? PopopxPalette.successInk
            : PopopxPalette.dangerInk
    }

    private func stateSentence(first: String, confirming second: String) -> String {
        if first.isEmpty {
            return String(format: Copy.pinStateEmptyFormat, "\(PopopxDuressAuthManager.pinLength)")
        }
        if !PopopxDuressAuthManager.isValidPin(first) {
            return String(format: Copy.pinStateShortFormat, "\(PopopxDuressAuthManager.pinLength)", "\(first.count)")
        }
        return first == second ? Copy.pinStateMatched : Copy.pinStateMismatched
    }

    /// 写入两把码。校验顺序照模块三的约束来：先本地判格式与"两把码相同"（这一层能当场给出
    /// `pinsMustDiffer` 的文案），再交给 `setNormalPin`/`setDuressPin`，让派生值层面那一道
    /// 真正的闸门（`setDuressPin` 里那次"用常规记录自己的盐再派生一遍"的常量时间比较）做最后一次判定。
    ///
    /// 原生入口码的迁移不用本页操心：它在 `setNormalPin` 内部、本地这两道校验之后、任何 Keychain
    /// 写入之前（PopopxDuressAuthManager.swift:1358-1363），所以旧码输错那一次连常规码都不会落盘。
    private func writePins() async {
        pinFeedback = nil
        guard PopopxDuressAuthManager.isValidPin(normalPin),
              PopopxDuressAuthManager.isValidPin(duressPin) else {
            pinFeedback = PopopxDuressSetupError.malformedPin.errorDescription
            PopopxHaptics.notice(.warning)
            toast.show(Copy.pinToastRejected, kind: .danger)
            return
        }
        // 本地这一道是"当场就能说的话"；管理器那一道是"最终算出来的话"。两句用的是同一个
        // enum 的同一个 case，所以不存在两份文案。
        guard normalPin != duressPin else {
            pinFeedback = PopopxDuressSetupError.pinsMustDiffer.errorDescription
            PopopxHaptics.notice(.warning)
            toast.show(Copy.pinToastRejected, kind: .danger)
            return
        }
        isWritingPins = true
        defer { isWritingPins = false }
        do {
            let generated = try await duress.setNormalPin(
                normalPin,
                confirming: normalConfirm,
                nativePasscode: nativePasscode,
                nativeSelfDestructCode: nativeSelfDestructCode
            )
            try await duress.setDuressPin(duressPin, confirming: duressConfirm)
            clearPinFields()
            // 这一次调用可能顺手生成了 12 个词（`setNormalPin` 只在"原本没有助记词"时生成，
            // 有则返回 nil，绝不覆盖手上那张纸）。返回了词组就**不关 sheet**：这一份数组是
            // 它们唯一一次以可读形式出现在界面上，一关掉就再也拼不回来——管理器那边留着派生值
            // 与可读原文两条记录，但"回看"那一条要重新过一次验证（进入密码或 Face ID）才走得到。
            if let generated, !generated.isEmpty {
                freshMnemonic = generated
            } else {
                showsPinSheet = false
            }
            PopopxHaptics.notice(.success)
            toast.show(Copy.pinToastWritten, kind: .encrypted)
        } catch let setup as PopopxDuressSetupError {
            // 十五句 `errorDescription` 原样显示，不重写、不加工。
            pinFeedback = setup.errorDescription
            clearPinFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.pinToastRejected, kind: .danger)
        } catch {
            // 到这里只剩非本模块的错误（理论上不该出现）。这一句同样不回显任何输入。
            pinFeedback = Copy.pinUnexpectedFailure
            clearPinFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.pinToastRejected, kind: .danger)
        }
    }

    private func clearAllPins() {
        duress.clearAllPins()
        clearPinFields()
        toast.show(Copy.duressCleared, kind: .danger)
    }

    /// 六个输入字段、那一句反馈，外加"顺手生成的 12 个词"一次性清空。口令的界面副本不该
    /// 比它的使用场合活得更久。
    /// 原生那两格（入口码、幽灵自毁码）也在其中，包括"旧码输错"那一次（两个
    /// `...Incorrect` 走同一个 catch）：宁可让机主重输一遍旧码，也不让它在页面上多活一次重绘。
    /// 两格在同一页上互斥（`nativeEntryPasswordActive` 与 `nativeSelfDestructGhostActive`
    /// 不可能同时为真），但清空不看这个条件——少写一行判断就多一个以后改错的机会。
    ///
    /// `freshMnemonic` 也在其中，因此 `writePins` 的成功分支必须是"先清、后赋值"：
    /// 反过来写等于刚抄下来就自己抹掉。
    private func clearPinFields() {
        normalPin = ""
        normalConfirm = ""
        duressPin = ""
        duressConfirm = ""
        nativePasscode = ""
        nativeSelfDestructCode = ""
        pinFeedback = nil
        freshMnemonic = nil
    }

    // MARK: 自毁后交出什么账号（保留策略，三选一）
    //
    // 模块三在这一版把两选一的 `PopopxDuressRebuildMode` 换成了带关联值的
    // `PopopxDuressRetentionStrategy`：带关联值就不能 `CaseIterable`，所以它自己的注释把口径写死了
    // ——"分段器由界面按 `segmentTitles` 的顺序拼，`segmentIndex` 是唯一的映射口径"。这里就照这一条做：
    // 分段器的 `Selection` 是下标 Int，三格标题一格不改地用模块三给的，回来只经
    // `fromSegmentIndex(_:)` 那一道闸（越界它自己回到默认档，本页不猜）。

    private var retentionOptions: [PopopxSegmentedControl<Int>.Option] {
        PopopxDuressRetentionStrategy.segmentTitles.enumerated()
            .map { .init(selection: $0.offset, title: $0.element) }
    }

    /// 界面下标 ⇄ 策略本体。写这条 `Binding` 是本页唯一改保留策略的地方。
    private var retentionBinding: Binding<Int> {
        Binding(
            get: { duress.retentionStrategy.segmentIndex },
            set: { duress.retentionStrategy = PopopxDuressRetentionStrategy.fromSegmentIndex($0) }
        )
    }

    private var rebuildCard: some View {
        PopopxSectionCard(Copy.groupRebuild, footnote: Copy.rebuildFootnote) {
            PopopxSegmentedControl(
                retentionOptions,
                title: { PopopxDuressRetentionStrategy.segmentTitles[$0] },
                selection: retentionBinding
            )
            .accessibilityIdentifier("popopx.antiTheft.rebuild")
            .padding(.bottom, PopopxMetrics.spaceXS)
            // 当前那一档的 `note` 直接来自枚举本身，本页不改写它。
            thresholdLine(Copy.rebuildCurrentHeadline, duress.retentionStrategy.note)
            // `.retainExistingProfile` 带着 `profileId` 与 `displayName` —— 那是身份信息，不是偏好，
            // 所以这一档必须由机主从**底层真实身份列表**里点一个名字才算数。列表来源是
            // `listUsersAsync()`（模块三自毁路径读的是同一个接口，两边看到同一份身份才是对的），
            // 不是 `ChatModel.users` 那份可能是启动时读的缓存。
            if duress.retentionStrategy.isRetainExisting {
                AntiTheftDivider()
                PopopxPickerRow(
                    Copy.retainRow,
                    value: retainValueText,
                    systemImage: "person.crop.circle",
                    tint: .brand
                ) {
                    PopopxHaptics.impact(.light)
                    Task { @MainActor in
                        await loadRetainCandidates()
                        showsRetainSheet = true
                    }
                }
                .accessibilityIdentifier("popopx.antiTheft.retainEntry")
                .accessibilityValue(retainValueText)
                // 防呆：只有一个身份时"保留指定昵称"和"什么都不保留"实际是同一件事，
                // 而机主以为他留了后手。所以这一条必须出现在他点入口行之前，不是之后。
                // 只在真的拉到过列表之后判：`retainCandidates.count` 在没加载过时是 0，
                // 拿它当"只有一个身份"会说谎。
                if retainLoaded, retainCandidates.count < 2 {
                    thresholdLine(Copy.retainFoolproofHeadline, Copy.retainFoolproofNote)
                }
            }
            AntiTheftDivider()
            PopopxToggleRow(
                Copy.decoyRow,
                note: Copy.decoyNote,
                systemImage: "circle.grid.2x2",
                tint: .neutral,
                isOn: $decoyEnabled
            )
        }
    }

    // MARK: 保留身份点名（选择器 + 数据源）
    //
    // 形状照 `timeoutSheet`：入口行 + sheet 内 radio 表 + 一个"关闭"，本页唯一的"N 选一"交互口径。
    // 与档位表的区别只有一处：这里的数据来自底层异步接口，所以"空列表"必须自己说一句人话，
    // 不能留一块空白让人以为功能坏了。

    /// 入口行行尾的当前值。没点名时明确写"尚未点名"，绝不回退成第一个身份的名字——
    /// 那会让机主以为已经选好了，而实际存的是 `profileId: 0` 那个空壳。
    private var retainValueText: String {
        if case .retainExistingProfile(_, let displayName) = duress.retentionStrategy,
           !displayName.isEmpty {
            return displayName
        }
        return Copy.retainUnchosen
    }

    /// 表头那一句：只有一个身份时换成防呆那句，两者互斥、不会同时出现。
    /// 名字刻意与 `Copy.retainSheetSubtitle` 错开——同名计算属性最容易在下一次改动里写成自我引用。
    private var retainSheetHint: String {
        retainLoaded && retainCandidates.count < 2 ? Copy.retainFoolproofNote : Copy.retainSheetSubtitle
    }

    private var retainSheet: some View {
        NavigationStack {
            PopopxSheetContainer(Copy.retainSheetTitle, subtitle: retainSheetHint) {
                PopopxSectionCard {
                    if retainCandidates.isEmpty {
                        Text(Copy.retainSheetEmpty)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, PopopxMetrics.spaceXS)
                    } else {
                        ForEach(Array(retainCandidates.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 {
                                AntiTheftDivider()
                            }
                            PopopxRadioRow(
                                candidate.name,
                                selected: duress.retentionStrategy.isRetainExisting
                                    && duress.retentionStrategy.retainedProfileId == candidate.id
                            ) {
                                PopopxHaptics.selection()
                                duress.retentionStrategy = .retainExistingProfile(
                                    profileId: candidate.id,
                                    displayName: candidate.name
                                )
                                showsRetainSheet = false
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsRetainSheet = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// 读一次底层身份列表。**只读**，不动任何配置。
    ///
    /// 为什么用 `listUsersAsync()` 而不是 `ChatModel.shared.users`：后者是模型里那份可能还是启动时
    /// 读的缓存，而这一格点下去的后果是"物理删除其余身份"——界面上少一行、底层就多删一个真人身份。
    /// 模块三自毁时执行的也是同一个接口，两边读同一个真相，选中的 id 到擦除那一刻仍然存在的概率才最高。
    ///
    /// 失败与"真的一个身份都没有"合并成同一个界面结论（空表文案 + 防呆那一行）：这里的正确行为是
    /// **让人选不了**，而不是弹一条错误横幅。真正的兜底在自毁那一侧——`profileId` 到那时已不存在，
    /// 模块三按简报要求安全降级为 `.simulatedDecoy` 全量重建，绝不卡白屏。
    private func loadRetainCandidates() async {
        do {
            let users = try await listUsersAsync()
            retainCandidates = users.map {
                PopopxRetainCandidate(id: $0.user.userId, name: $0.user.displayName)
            }
        } catch {
            retainCandidates = []
        }
        retainLoaded = true
    }

    // MARK: 演练入口

    private var drillCard: some View {
        PopopxSectionCard(Copy.groupDrill, footnote: Copy.drillFootnote) {
            AntiTheftRowLink(Copy.drillRow, systemImage: "play.circle.fill", tint: .brand) {
                PopopxAntiTheftDrillView()
                    .navigationTitle(Copy.drillPageTitle)
            }
            .accessibilityIdentifier("popopx.antiTheft.drillEntry")
        }
    }

    // MARK: 页脚风险说明

    /// 三句都是坏消息，三句都是真的。这一格的作用不是免责，而是让机主在按下"写入两把码"之前
    /// 已经知道自己放弃了什么、留下了什么。
    private var riskCard: some View {
        PopopxSectionCard(Copy.groupRisk) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                riskLine(Copy.riskIrreversible)
                riskLine(Copy.riskForensics)
                riskLine(Copy.riskFalsePositive)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func riskLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "questionmark.circle")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.labelHint)
                .accessibilityHidden(true)
            Text(text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 格式化

    /// 门限与读数一律用同一套格式化，`PopopxType.metric` 是等宽数字，跳动不会推挤排版。
    private func fixed(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}

// MARK: - 演练子页

/// 一键模拟演练。
///
/// **这一页的不变量（承重，不是装饰）**：本页只调用 `PopopxMotionCriteria` 的静态纯函数
/// （`evaluate(samples:sensitivity:)`、`syntheticSnatch()`、`syntheticFreeFall()`）与
/// `PopopxDuressAuthManager.verify(pin:)`。它没有任何一处引用 `PopopxAppLockState.lock(reason:)`、
/// `PopopxDuressAuthManager.submit(pin:)`、`PopopxStorageWipe`，也没有任何一处启动或停止传感器。
/// 类型层面这是可以检查的：`evaluate` 返回 `PopopxMotionVerdict`（值类型，携带不了副作用），
/// `verify` 的注释写明"纯校验，零副作用"，而通向抹除的那条路只有 `submit`
///（`submit(pin:)` 里命中 `.duress` 才走 `runDuressWipe(mode:)`）。拽落/跌落判据即使在真实流里命中，后果也只是
/// `lock(reason:)`，永远不通向擦除（模块一头注那一节）——演练连那一步都不做。
/// 所以：演练不锁屏、不擦数据、不动 Keychain、不读真实传感器。
@MainActor
private struct PopopxAntiTheftDrillView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 结果面板自己画一层卡面，所以要按模式决定它带影子还是带发丝高亮（`popopxCardElevation`
    /// 的那一条裁定）。
    @Environment(\.colorScheme) private var colorScheme

    /// 只读它，不写它：演练页没有一处在改模块一的开关或判据。
    @Bindable private var motion = PopopxAntiTheftMotionGuard.shared
    @Bindable private var duress = PopopxDuressAuthManager.shared

    @State private var toast = PopopxToastModel()

    /// 两串合成样本的判定结果。存的是 `PopopxMotionVerdict` 本体而不是写好的一句话，
    /// 所以屏幕上那句话永远是刚刚算出来的那一个。
    @State private var snatchRun: AntiTheftDrillRun?
    @State private var freeFallRun: AntiTheftDrillRun?

    @State private var drillPin = ""
    @State private var drillOutcome: PopopxDuressAuthOutcome?
    @State private var drillFeedback: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                invariantCard
                sensorCard
                snatchCard
                freeFallCard
                duressDrillCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
            .popopxAnimation(PopopxSpring.fluid, value: animationKey, reduceMotion: reduceMotion)
        }
        .background(PopopxPalette.base)
        .navigationBarTitleDisplayMode(.inline)
        .popopxToast(toast)
    }

    private var animationKey: String {
        // `?? 0` 把两个 Optional 钉成 Int：直接插 Optional 得到的是调试描述（编译器当场警告），
        // 那串东西每轮演练都可能变，动画键就会自己抖。没跑过的槽位固定读作 0。
        "\(snatchRun?.verdict.hashValue ?? 0)-\(freeFallRun?.verdict.hashValue ?? 0)-\(motion.sensitivity.wireValue)-\(drillOutcome != nil)"
    }

    // MARK: 不变量声明

    private var invariantCard: some View {
        PopopxSectionCard(Copy.drillInvariantGroup, footnote: Copy.drillInvariantFootnote) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "checkmark.shield.fill")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.successInk)
                    .accessibilityHidden(true)
                Text(Copy.drillInvariantLine)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 本机传感器

    private var sensorCard: some View {
        PopopxSectionCard(Copy.drillSensorGroup, footnote: Copy.drillSensorFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                thresholdLine(
                    Copy.drillSensorAvailableHeadline,
                    motion.motionAvailable ? Copy.drillSensorAvailableYes : Copy.drillSensorAvailableNo
                )
                thresholdLine(Copy.drillSensorRunningHeadline, motion.isRunning ? Copy.drillRunningYes : Copy.drillRunningNo)
                thresholdLine(Copy.drillPeakGHeadline, fixed(motion.peakG, digits: 2))
                thresholdLine(Copy.drillPeakOmegaHeadline, fixed(motion.peakOmega, digits: 2))
                thresholdLine(Copy.drillVerdictHeadline, liveVerdictSentence)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: Copy.drillSensorGroup))
        }
    }

    private var liveVerdictSentence: String {
        guard let verdict = motion.lastVerdict else {
            return Copy.drillVerdictNone
        }
        return verdictSentence(verdict)
    }

    // MARK: 拽落演练

    private var snatchCard: some View {
        PopopxSectionCard(Copy.drillSnatchGroup, footnote: Copy.drillSnatchFootnote) {
            PopopxButton(Copy.drillSnatchRun, systemImage: PopopxLockReason.snatch.symbolName, role: .secondary) {
                runSnatchDrill()
            }
            if let run = snatchRun {
                AntiTheftDivider()
                resultPlate(for: run)
            }
        }
    }

    private func runSnatchDrill() {
        // 合成样本 + 静态纯函数。这里没有、也不允许出现任何 `lock(reason:)`。
        let samples = PopopxMotionCriteria.syntheticSnatch()
        let verdict = PopopxMotionCriteria.evaluate(samples: samples, sensitivity: motion.sensitivity)
        snatchRun = AntiTheftDrillRun(
            verdict: verdict,
            sampleCount: samples.count,
            peakG: samples.map(\.g).max() ?? 0,
            peakOmega: samples.map(\.omega).max() ?? 0,
            thresholdG: motion.sensitivity.spikeG,
            thresholdOmega: motion.sensitivity.spinOmega
        )
        // 触觉只是这一行字出来的那一下的收据，不是"手机在震=已锁定"的那种暗示。
        PopopxHaptics.notice(verdict.isHit ? .warning : .success)
    }

    // MARK: 跌落演练

    private var freeFallCard: some View {
        PopopxSectionCard(Copy.drillFreeFallGroup, footnote: Copy.drillFreeFallFootnote) {
            PopopxButton(Copy.drillFreeFallRun, systemImage: PopopxLockReason.freeFall.symbolName, role: .secondary) {
                runFreeFallDrill()
            }
            if let run = freeFallRun {
                AntiTheftDivider()
                resultPlate(for: run)
            }
        }
    }

    private func runFreeFallDrill() {
        let samples = PopopxMotionCriteria.syntheticFreeFall()
        let verdict = PopopxMotionCriteria.evaluate(samples: samples, sensitivity: motion.sensitivity)
        // 跌落的门限是 `PopopxMotionCriteria` 的固定常数，与灵敏度档位无关，所以这里报的
        // 门限直接取那几个 static，而不是档位值。
        freeFallRun = AntiTheftDrillRun(
            verdict: verdict,
            sampleCount: samples.count,
            peakG: samples.map(\.g).max() ?? 0,
            peakOmega: samples.map(\.omega).max() ?? 0,
            thresholdG: PopopxMotionCriteria.impactG,
            thresholdOmega: nil
        )
        PopopxHaptics.notice(verdict.isHit ? .warning : .success)
    }

    // MARK: 结果面板

    /// 一次演练的结果：结论、峰值对门限、以及"当前档位是否会触发"。
    private func resultPlate(for run: AntiTheftDrillRun) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            Text(run.verdict.isHit ? Copy.drillWillTrigger : Copy.drillWillNotTrigger)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(run.verdict.isHit ? PopopxPalette.label : PopopxPalette.labelSecondary)
            Text(verdictSentence(run.verdict))
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)

            gauge(
                Copy.drillGaugeG,
                value: "\(fixed(run.peakG, digits: 2)) / \(fixed(run.thresholdG, digits: 2))",
                fraction: run.peakG / run.thresholdG
            )
            // `thresholdOmega == nil` 说的是"这一条判据根本不看角速度"。那就只报峰值，
            // 不画一条自己造出来的比例条——跌落的判定里没有任何 ω 门限（见 `freeFallVerdict`）。
            if let thresholdOmega = run.thresholdOmega {
                gauge(
                    Copy.drillGaugeOmega,
                    value: "\(fixed(run.peakOmega, digits: 2)) / \(fixed(thresholdOmega, digits: 2))",
                    fraction: run.peakOmega / thresholdOmega
                )
            } else {
                thresholdLine(Copy.drillOmegaNoThresholdHeadline, fixed(run.peakOmega, digits: 2))
            }

            Text(String(format: Copy.drillSampleCountFormat, "\(run.sampleCount)"))
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PopopxMetrics.spaceS)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .popopxCardElevation(colorScheme: colorScheme)
        .accessibilityElement(children: .combine)
    }

    /// 门限对照条。超过门限只是"会再认证一次"，所以用品牌色而不是危险红：
    /// 这个 app 里红色只说不可恢复的那几件事。
    private func gauge(_ label: String, value: String, fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        return VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Text(label)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Spacer(minLength: PopopxMetrics.space2XS)
                Text(value)
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(PopopxPalette.separator)
                    Rectangle().fill(PopopxPalette.brand)
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .frame(height: PopopxMetrics.spaceXS)
            .clipShape(.rect(cornerRadius: PopopxMetrics.space2XS))
            .accessibilityHidden(true)
        }
    }

    private func thresholdLine(_ headline: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Text(headline)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Text(value)
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.label)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopopxMetrics.space2XS)
        }
    }

    // MARK: 胁迫码演练

    private var duressDrillCard: some View {
        PopopxSectionCard(Copy.drillDuressGroup, footnote: Copy.drillDuressFootnote) {
            PopopxTextField(Copy.drillDuressFieldLabel, prompt: Copy.drillDuressFieldPrompt, text: $drillPin, isSecure: true)
                .onChange(of: drillPin) { _, newValue in
                    let filtered = String(
                        newValue
                            .filter { PopopxDuressAuthManager.digits.contains($0) }
                            .prefix(PopopxDuressAuthManager.pinLength)
                    )
                    if filtered != newValue { drillPin = filtered }
                }
            PopopxButton(Copy.drillDuressRun, systemImage: "number", role: .primary) {
                await runDuressDrill()
            }
            .padding(.top, PopopxMetrics.spaceXS)

            if let outcome = drillOutcome {
                AntiTheftDivider()
                Text(outcomeSentence(outcome))
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let drillFeedback {
                Text(drillFeedback)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 只调 `verify(pin:)`。它不会擦除、不会装烟雾弹、也不会解掉任何锁；通向抹除的那一条
    /// 是 `submit(pin:)`，本页不引用它。校验之后立刻清掉输入框里的那一份副本。
    private func runDuressDrill() async {
        let pin = drillPin
        drillPin = ""
        drillOutcome = nil
        drillFeedback = nil
        guard PopopxDuressAuthManager.isValidPin(pin) else {
            drillFeedback = PopopxDuressSetupError.malformedPin.errorDescription
            PopopxHaptics.notice(.warning)
            return
        }
        guard duress.normalConfigured else {
            drillOutcome = .notConfigured
            return
        }
        let outcome = await duress.verify(pin: pin)
        drillOutcome = outcome
        // 命中胁迫码时不庆祝：那一格说的是"这串码会抹掉你的数据"。
        PopopxHaptics.notice(outcome == .duress ? .warning : .success)
        toast.show(Copy.drillDuressNoEraseToast, kind: .success)
    }

    private func outcomeSentence(_ outcome: PopopxDuressAuthOutcome) -> String {
        switch outcome {
        case .unlocked: return Copy.drillOutcomeNormal
        case .duress: return Copy.drillOutcomeDuress
        case .wrong: return Copy.drillOutcomeWrong
        case .notConfigured: return Copy.drillOutcomeNotConfigured
        case .lockedOut: return Copy.drillOutcomeLockedOut
        }
    }

    /// 结论那一句话：数字来自判据本体，句式来自本页。
    private func verdictSentence(_ verdict: PopopxMotionVerdict) -> String {
        switch verdict {
        case .none:
            return Copy.drillVerdictNone
        case .snatch(let g, let omega):
            return String(format: Copy.drillVerdictSnatchFormat, fixed(g, digits: 2), fixed(omega, digits: 2))
        case .freeFall(let peakG, let weightlessMs):
            return String(
                format: Copy.drillVerdictFreeFallFormat,
                fixed(peakG, digits: 2),
                "\(Int(weightlessMs.rounded()))"
            )
        }
    }

    private func fixed(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}

// MARK: - 一次演练的判定

/// 存判定的输入与输出，不存结论文案：结论每次从 `verdict` 现推，所以档位一改，
/// 上一次的演练结果不会以一句话的形式留在屏幕上说不成立的话。
private struct AntiTheftDrillRun {
    let verdict: PopopxMotionVerdict
    let sampleCount: Int
    let peakG: Double
    let peakOmega: Double
    /// 对照用的门限：拽落是当前档位的 `spikeG`/`spinOmega`，跌落只有固定常数 `impactG`，
    /// 那一条判据不看角速度，所以 `thresholdOmega` 给 nil。
    let thresholdG: Double
    let thresholdOmega: Double?
}

// MARK: - 行

/// 推一个既有页面。形状照 `PopopxMeRowLink`（PopopxMeView.swift）那一个：外观复用 `PopopxPickerRow`，
/// 但点击归外层 `NavigationLink`——原子库那一行自己是个 `Button`，嵌套按钮会把链接的点击吃掉，
/// 所以整行设为不可命中、也不进无障碍树，由链接自己带上同名的 label 与 hint。
@MainActor
private struct AntiTheftRowLink<Destination: View>: View {
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
        .accessibilityHint(Text(verbatim: Copy.drillOpenHint))
    }
}

/// 卡片内的分隔线。`PopopxControls.swift:853` 里那条同名的只在 `#if DEBUG` 的画廊作用域里，
/// 而 `PopopxMeDivider`、`PopopxSettingsDivider` 各自带了一枚私有的，本页照同一口径。
/// 「点名保留哪个匿名身份」这一格里的一行：底层 `users` 的一次投影，只带界面需要的两样东西。
/// id 用底层的 `Int64` 原样，不自造 UUID、不做任何换算——这张表与 `PopopxDuressRetentionStrategy`
/// 里存的 `profileId` 必须是同一个数，中间隔一层映射就是出错的地方。
private struct PopopxRetainCandidate: Identifiable, Hashable {
    let id: Int64
    let name: String
}

private struct AntiTheftDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - 文案

/// 页面上每一句中文只在这里出现一次。双密码写入与助记词查看那十五句失败文案不在这里：那十五句是
/// `PopopxDuressSetupError.errorDescription` 原样引用的，抄一份过来就会出现两套说法。
private enum Copy {
    static let pageTitle = "防盗锁定与自毁"
    static let close = "关闭"
    /// 与 `close` 是两件事：`close` 是"离开这个弹层"，`cancel` 是"不要执行这一步不可恢复的操作"。
    static let cancel = "取消"

    // 总开关
    static let groupMaster = "防盗锁定"
    static let masterFootnote = "这三格说的都是「锁」，没有一格通向擦数据：本页任何开关被打开，都不会让手机自己抹掉自己。"
    static let enabledRow = "启用防盗锁定"
    static let enabledNoteOn = "传感器正在按 20Hz 采样；锁起来之后立刻停采，退到后台也停。"
    static let enabledNoteOff = "已关闭：不采样、不计时，拽落与跌落判据此刻完全不运行。"
    static let instantBgRow = "切到后台立即锁定"
    static let instantBgNote = "回到前台的第一帧就是锁屏，不闪内容。关掉它仍然受下面的无操作时长约束。"
    static let biometricsRow = "生物识别快捷解锁"
    static let biometricsNoteUnavailable = "这台设备没有可用的 Face ID / Touch ID，锁屏会直接要 6 位键盘码。"
    static let biometricsNoteFormat = "只证明「是本人」，证明不了「用的是哪把码」，所以它永远不通向自毁。连续失败 %@ 次后，本次会话只认键盘码。"
    static let lockNowRow = "现在锁一次"
    static let lockNowButton = "锁定"
    static let lockNowNote = "立即拉起锁屏并要求重新认证，与传感器命中时的后果完全一样。它不会擦除任何东西。"
    static let lockNowDone = "已锁定，回到 app 需重新认证"

    // 灵敏度
    static let groupSensitivity = "判据灵敏度"
    static let sensitivityFootnote = "档位只改拽落的两条门限。跌落那条（失重后撞击）用的是固定常数，换档不会改变它。"
    static let thresholdHeadline = "门限"
    static let thresholdSpikeFormat = "G > %@ 且 ω > %@ rad/s"
    static let preconditionHeadline = "附加前提"
    static let preconditionFormat = "相邻两帧至少涨 %@ g；命中前 %@ 秒平均落在 %@–%@ g（正常持握区间）"
    static let behaviorRow = "非本人操作特征"
    static let behaviorNote = "绑的是行为判据本体：翻这一格当场起停传感器，不落等到下次启动。它只提级到「再认证一次」，绝不通向擦除。"
    static let angleRow = "倾角门限"
    static let angleHeadline = "判据"
    static let angleFormat = "偏离角度大于所选门限、并连续 %@ 秒以上，同时 %@ 秒内出现 %@ 次以上不规则触摸，才判为可疑并锁屏。调小更敏感，误判的代价只是重新认证一次。"

    // 无操作时长
    static let groupInactivity = "无操作自动锁屏"
    static let inactivityRow = "锁屏前空等多久"
    static let inactivityFootnote = "计时只看屏幕上有没有触碰。锁起来之后计时器就停了，不会在锁屏后面继续数。"
    static let timeoutSheetTitle = "无操作自动锁屏"
    static let timeoutSheetSubtitle = "离开手机多久之后自动收起来。越短越安全，也越容易被一次搁置打断。"
    static let timeoutNoteOne = "最安全：搁在桌上回个消息就要重新认证。"
    static let timeoutNoteThree = "默认档：上厕所、倒杯水这个量级不会被锁。"
    static let timeoutNoteFive = "适合手机长时间摆在眼前但不碰的场合。"
    static let timeoutNoteFifteen = "接近不锁：只有明显离开才会收起。"
    static let timeoutNoteNever = "永不：这一条判据不再起作用，只剩下传感器与后台那两条。"

    // 双密码
    static let groupDuress = "双密码自毁"
    static let duressFootnote = "常规码开门，胁迫码开门并且立刻抹掉这台设备上的身份。两把码必须不同，否则「交出哪一把」是同一件事。"
    static let duressSwitchRow = "启用双密码自毁"
    static let duressSwitchNoteOn = "已启用：胁迫码存在时会走抹除那一条路。关掉会当场删除胁迫码记录。"
    static let duressSwitchNoteOff = "已停用：胁迫码记录已删除，任何键盘输入都不会再通向抹除。"
    static let duressSetupRow = "设置常规码与胁迫码"
    static let duressStatusNone = "未设置"
    static let duressStateHeadline = "应急擦除密码"
    static let duressStateSet = "已设置"
    static let duressStateUnset = "未设置"
    static let duressStatusNormalOnly = "只有常规码"
    static let duressStatusBoth = "两把码都已设置"
    static let duressClearRow = "解除双密码"
    static let duressCleared = "两把码的记录已删除"
    static let duressOffDialogTitle = "关掉双密码自毁？"
    static let duressOffDialogConfirm = "关掉并删除胁迫码"
    static let duressOffDialogMessage = "胁迫码记录会立刻从安全存储里删除，之后任何输入都不会再触发抹除。常规码留着。想再开需要重新设一次两把码。"
    static let duressOffDone = "双密码已停用，胁迫码记录已删除"
    static let clearDialogTitle = "解除双密码？"
    static let clearDialogConfirm = "删除两把码"
    static let clearDialogMessage = "常规码与胁迫码的记录都会被删除，锁屏回到只有 app 自身那道认证门。这一步不可撤销，但不删除任何聊天数据。"

    static let pinSheetTitle = "设置双密码"
    static let pinSheetSubtitle = "每把码都要输两遍：写错的后果是不可恢复的。"
    static let pinGroupNormal = "常规密码"
    static let pinGroupDuress = "胁迫密码"
    static let pinNormalFootnote = "这把码只是开门，与上游那道 app 密码门作用相同。"
    static let pinDuressFootnote = "这把码在开门的同时抹掉这台设备上的身份。它与常规码相同会被直接拒绝。"
    static let pinNormalLabel = "常规密码"
    static let pinNormalConfirmLabel = "再输一遍常规密码"
    static let pinDuressLabel = "胁迫密码"
    static let pinDuressConfirmLabel = "再输一遍胁迫密码"
    static let pinPrompt = "6 位数字"
    // 原生入口码那一段：只有 Keychain 里确实还留着旧码时才会渲染，所以这三句平时看不见。
    static let pinNativeGroup = "关闭 app 自带的入口密码"
    static let pinNativeLabel = "原有的入口密码"
    static let pinNativePrompt = "4 到 16 位数字"
    static let pinNativeFootnote = "这台设备还开着 app 自带的入口密码：解锁时它会先弹一次自己的键盘，POPOPX 再弹一次，两个键盘干的是同一件事。填对它，我们把它关掉，今后只认上面那把常规码。跟着一起关掉的还有那把只有这台旧键盘才输得进去的自毁码——旧键盘没了它就没有输入口，留着只会让隐私设置那一格显示「已启用」。这一步不重建数据库钥匙，聊天数据一个字都不动；想再要回来，得去「隐私与安全」那页重新设置一次。"
    // 幽灵自毁码那一段：入口码已经不在了、只剩一把输不进去的自毁码时才会渲染，和上面三段互斥。
    // 提示语共用 `pinNativePrompt`——两把码出自同一台键盘（同一个 `PasscodeEntry`），格式同规。
    static let pinNativeSDGroup = "关闭残留的自毁密码"
    static let pinNativeSDLabel = "原有的自毁密码"
    static let pinNativeSDFootnote = "这台设备上留着一把旧的自毁密码，可它只有 app 自带的那台键盘才输得进去，而那台键盘已经不弹了——它现在既触发不了也看不见，只会让隐私设置那一格显示「已启用」。填对它，我们把它连同那一格一起关掉；填错则这次什么都不改，上面两把新码也不会落盘。如果认证方式还停在「app 密码」那一档，也会一并退回系统认证。这一步不重建数据库钥匙，聊天数据一个字都不动。"
    static let pinIrreversibleGroup = "写下去之前"
    static let pinIrreversibleNote = "这两把码只以派生值存在，本机不存原文。忘记进入密码时唯一的出路是手上抄存的那 12 个英文词，而助记词本身没有任何找回通道——所以这一次写入会顺手生成一份，抄不抄在你。确认弹窗里那一次点击就是这个后果的最后一道门。"
    static let pinWriteButton = "写入两把码"
    static let pinStateEmptyFormat = "还没输入，需要恰好 %@ 位数字"
    static let pinStateShortFormat = "已填 %@ 位中的 %@ 位"
    static let pinStateMatched = "两次一致"
    static let pinStateMismatched = "两次不一致"
    static let pinToastWritten = "两把码已写入安全存储"
    static let pinToastRejected = "没有写入，原因见上方"
    static let pinUnexpectedFailure = "写入失败，请稍后再试"
    static let commitDialogTitle = "确认写入这两把码？"
    static let commitDialogConfirm = "确认写入"
    static let commitDialogMessage = "覆盖现有的常规码或胁迫码之后无法撤销、无法找回。请再核对两遍输入，尤其是手指是否被屏幕油膜带偏过一位。"

    // 12 词助记词
    static let groupMnemonic = "12 词恢复助记词"
    static let mnemonicFootnote = "忘记进入密码时唯一的出路：在锁屏上输对这 12 个英文词，就能设一把新的进入密码。词组由本机生成，安全存储里同时留着它的派生值（供锁屏比对）和可读原文（只供本页回看）。"
    static let mnemonicStateHeadline = "助记词"
    static let mnemonicStateSet = "已生成"
    static let mnemonicStateUnset = "未生成"
    static let mnemonicRow = "查看或重新生成"
    static let mnemonicRowReveal = "需验进入密码"
    /// 只有 `mnemonicFaceIDOffered` 为真时才用得上这一句：那道门没开时行尾不许提 Face ID。
    static let mnemonicRowRevealEither = "需验进入密码或 Face ID"
    static let mnemonicRowGenerate = "现在生成"
    static let mnemonicConsequence = "用助记词在锁屏上重置进入密码，会连带把应急擦除密码清成「未设置」：那把码从此不存在，交出去也不会抹掉任何数据。重置完请回到上一页重新设置一次应急擦除密码。"
    static let mnemonicSheetTitle = "12 词恢复助记词"
    static let mnemonicSheetHintHave = "先输一次当前进入密码，词组才会显示；「重新生成一组」要的也是这一道门。这一问不计入锁屏那一道失败计数，理由见下方说明。"
    static let mnemonicSheetHintHaveBiometric = "先输一次当前进入密码，或用 Face ID 证明一次，词组才会显示；「重新生成一组」也是这两道门里任一道过了就行。这一问不计入锁屏那一道失败计数，理由见下方说明。"
    static let mnemonicSheetHintNone = "这台设备还没有助记词。生成一次，当场把 12 个英文词抄在纸上。"
    static let mnemonicSheetGroup = "词组"
    static let mnemonicSheetFootnote = "词表是标准 BIP-39 英文词表（2048 个词），12 个词由 16 字节随机数加 4 位校验和导出，顺序与拼写都要照抄。派生用 PBKDF2-HMAC-SHA256、10 万次迭代，所以点一下会等三分之一秒左右，那不是卡住；Face ID 那一枚等的是系统弹层，同样不是卡住。"
    static let mnemonicSheetPinLabel = "当前进入密码"
    static let mnemonicSheetReveal = "验证并显示"
    /// 与上面那一句成对：两枚按钮各写清自己用的是哪道门，机主才知道按的是哪一问。
    static let mnemonicSheetRevealFaceID = "用 Face ID 验证并显示"
    /// 系统 Face ID 弹层上那一句说明。按苹果的写法不写 app 名（系统自己带），
    /// 只说这一问要干什么：不是"解锁"，是"把 12 个词显示出来"。
    static let mnemonicSheetFaceIDReason = "显示你的 12 词恢复助记词"
    static let mnemonicSheetHide = "隐藏词组"
    static let mnemonicSheetGenerate = "生成 12 词助记词"
    /// 没有一道门能走时的那一句（按钮此时是禁用的）。
    static let mnemonicSheetRegenerate = "重新生成一组"
    /// 上面那两枚「查看」按钮的同一套词法：不带定语的"验证"就是指那个密码框。
    static let mnemonicSheetRegenerateVerified = "验证并重新生成"
    static let mnemonicSheetRegenerateFaceID = "用 Face ID 验证并重新生成"
    /// 系统 Face ID 弹层上那一句说明，与「查看」那一问成对：这一问要干的事不是"把词显示出来"，
    /// 是"作废旧的、换一组新的"。同样不写 app 名。
    static let mnemonicRegenFaceIDReason = "重新生成你的 12 词恢复助记词"
    static let mnemonicSheetPaperGroup = "抄下来"
    static let mnemonicSheetPaperNote = "关掉这一格之后，本机再无任何途径把这 12 个词显示出来——除非下次你还能过验证那一关：输对当前进入密码，或在「生物识别快捷解锁」开着时让机器认出你。请当场抄在纸上：不要截图，不要手打进任何云备忘录，也不要指望系统剪贴板。这一格因此不开放选中文字，一旦选中就可能进了剪贴板，而剪贴板会被别的 app 读到、也可能随 iCloud 同步到别的设备。"
    static let mnemonicSheetWhyGroup = "为什么这一问不计次"
    static let mnemonicSheetWhyNoCount = "为什么这里的失败不进冷却表：这一问要防的是「忘了词的机主」，不是「拿着手机猜的人」。如果它计次，设置页就变成第二个可以猜的入口，而机主一次抄错（12 个词抄错位是常事）会把自己锁进 1 小时冷却，正好落在最不该被锁的地方。真正通向重置的那一问在锁屏上，那一道才计次。"
    static let mnemonicRegenTitle = "作废旧的 12 个词？"
    static let mnemonicRegenConfirm = "作废旧词组并生成"
    static let mnemonicRegenMessage = "身份已经验过，这一击不会再问第二次。旧词组会立刻从安全存储里删除，抄在纸上的那一份同时作废。新的 12 个词只在这一屏完整显示一次，进入密码与应急擦除密码都不受影响。"
    static let mnemonicGridLabel = "12 个英文助记词，带序号两列排列"
    static let mnemonicToastShown = "词组已显示，关掉这一格即消失"
    static let mnemonicToastRejected = "没有显示，原因见上方"
    /// 「重新生成」那一问的失败播报与上面那句不许共用：这一问失败时没有"没显示出来的东西"，
    /// 只有一桩没做成的生成。
    static let mnemonicRegenToastRejected = "没有重新生成，原因见上方"
    /// 与 `mnemonicUnexpectedFailure` 分成两句：那一句说的是"把词组读回来"，
    /// 这一句说的是"过身份门"，而这一条路连读都没开始读。
    static let mnemonicRegenUnexpectedFailure = "验证失败，请稍后再试"
    static let mnemonicToastGenerated = "助记词已生成，请当场抄存"
    static let mnemonicGenerateFailed = "没有生成：安全存储写入失败，本机仍是没有助记词的状态"
    static let mnemonicUnexpectedFailure = "读取失败，请稍后再试"
    static let mnemonicCaptureTitle = "抄存这 12 个词"
    static let mnemonicCaptureSubtitle = "两把码已经写进去了。这一屏是它们对应的助记词第一次、也可能是最后一次完整显示。"
    static let mnemonicCaptureDone = "我已抄存，关闭"

    // 渐进式防爆破
    static let groupLockout = "连续输错的冷却"
    static let lockoutFootnote = "这一张表同时管着数字键盘、Face ID 与助记词那三个入口，因为它们验证的是同一件事：机主本人。前 4 次只震一下、不锁，手滑和油膜带偏一位不该被当成攻击。计数存在安全存储里，杀掉进程再打开还在。"
    static let lockoutStrikesHeadline = "当前失败计数"
    static let lockoutStrikesNone = "无"
    static let lockoutStrikesFormat = "已连错 %@ 次 · 距第 10 次还差 %@ 次"
    static let lockoutCoolingHeadline = "冷却剩余"
    static let lockoutCoolingFormat = "%@ 后可再输"
    static let lockoutCoolingIdle = "不在冷却"
    static let lockoutScheduleHeadline = "递增表"
    static let lockoutStepFormat = "第 %@ 次 %@"
    static let lockoutScheduleFormat = "%@ · 第 9 次起每次 1 小时"
    static let lockoutTenStrikeRow = "连续 10 次输错即抹掉数据"
    static let lockoutTenStrikeNoteOn = "已开启：第 10 次输错会静默走完与应急擦除密码完全相同的抹除与重建流程，屏幕上不会先弹任何警告。"
    static let lockoutTenStrikeNoteOff = "已关闭（默认）：第 10 次及以后每次只锁 1 小时，数据不动。"
    static let lockoutTenStrikeWarning = "开着这一档，就要接受两件事：一个拿到已解锁手机、并有 10 次机会的人可能替你抹掉身份；你自己也可能在黑暗中数到第 10 次。误触的代价（家人乱按、孩子试玩、自己抄错助记词连错十次）由这一次明确的点击承担。"

    // 重建模式
    static let groupRebuild = "自毁之后"
    static let rebuildFootnote = "抹完之后交出什么样的账号由这一格决定。头一档要点名保留哪个身份才算数，那里头是身份信息，不是偏好。"
    static let rebuildCurrentHeadline = "当前选择"
    static let retainRow = "点名保留哪个匿名身份"
    static let retainUnchosen = "尚未点名"
    static let retainFoolproofHeadline = "还缺一个马甲"
    static let retainFoolproofNote = "本机现在只有 1 个（甚至 0 个）匿名身份，「保留指定昵称」就没有第二个人可留。先在首页左上角创建一个日常马甲，再回来点名它。"
    static let retainSheetTitle = "保留哪个身份"
    static let retainSheetSubtitle = "自毁时只留下你点名的这一个；其余身份连同其会话与厢语蓝牙映射一起物理删除。"
    static let retainSheetEmpty = "没读到底层身份列表：聊天核心此刻不可用，或这台设备上确实一个身份都没有。关掉本页重进一次，或先回首页确认账号已就绪。"
    static let decoyRow = "仿真烟雾弹内容"
    static let decoyNote = "这一格只决定交出哪一种账号，不影响抹除本身；翻动它会立刻叫仿真内容生成器重读一次，不用等它自己刷新。"

    // 演练入口
    static let groupDrill = "一键模拟演练"
    static let drillRow = "演练：拽落、跌落、胁迫码"
    static let drillOpenHint = "打开"
    static let drillFootnote = "演练只把固定的合成样本喂给与真实运行时同一段判据，不锁屏、不擦除、不读你手上的传感器。"

    // 演练子页
    static let drillPageTitle = "模拟演练"
    static let drillInvariantGroup = "这一页不会做的事"
    static let drillInvariantLine = "不锁屏、不擦数据、不写 Keychain、不停或启传感器。"
    static let drillInvariantFootnote = "实现上的保证是类型级别的：这一页只调用判据的静态纯函数与 verify(pin:)，而后者被明确定义为零副作用；通向抹除的那个方法在本页没有任何引用点。"

    static let drillSensorGroup = "本机传感器现状"
    static let drillSensorFootnote = "读数是传感器监护器自己攒下来的：本次运行以来的峰值，命中过一次判定才会有结论。它不是演练算出来的那两个数。"
    static let drillSensorAvailableHeadline = "传感器可用"
    static let drillSensorAvailableYes = "可用"
    static let drillSensorAvailableNo = "不可用"
    static let drillSensorRunningHeadline = "正在采样"
    static let drillRunningYes = "在跑"
    static let drillRunningNo = "没在跑"
    static let drillPeakGHeadline = "峰值 G（含重力）"
    static let drillPeakOmegaHeadline = "峰值 ω（rad/s）"
    static let drillVerdictHeadline = "最近一次判定"
    static let drillVerdictNone = "本次运行还没有判定过"

    static let drillSnatchGroup = "拽落演练"
    static let drillSnatchRun = "跑一次拽落样本"
    static let drillSnatchFootnote = "样本：10 帧 1.0 g 的正常持握，紧接一帧 3.6 g / 8.2 rad/s 的骤升。真实判据要求的就是这种「先安静、再猛的一下」。"
    static let drillFreeFallGroup = "跌落演练"
    static let drillFreeFallRun = "跑一次跌落样本"
    static let drillFreeFallFootnote = "样本：150 ms 失重（0.06 g），随后 3.1 g 冲击。跌落那条判据不看灵敏度档位，所以换档不会改变这里的结论。"
    static let drillWillTrigger = "会触发锁定"
    static let drillWillNotTrigger = "不会触发锁定"
    static let drillGaugeG = "峰值 G 对门限"
    static let drillGaugeOmega = "峰值 ω 对门限"
    static let drillOmegaNoThresholdHeadline = "峰值 ω（rad/s）· 本条判据不看它"
    static let drillSampleCountFormat = "样本 %@ 帧 · 20Hz"
    static let drillVerdictSnatchFormat = "拽落命中：G %@、ω %@ rad/s"
    static let drillVerdictFreeFallFormat = "跌落命中：冲击峰值 G %@，失重持续 %@ ms"

    static let drillDuressGroup = "胁迫码演练"
    static let drillDuressFieldLabel = "输入一串码来验证"
    static let drillDuressFieldPrompt = "6 位数字"
    static let drillDuressRun = "只校验，不提交"
    static let drillDuressFootnote = "演练不会真的擦除：这一格只问「这串码命中的是哪一把」，用的是纯校验的那一个方法，通向抹除的那一条路不在这里被调用。"
    static let drillDuressNoEraseToast = "演练完成，未触发任何抹除"
    static let drillOutcomeNormal = "命中的是常规码——真实情况下它只开门，不动任何数据。"
    static let drillOutcomeDuress = "命中的是胁迫码——真实情况下它会抹掉这台设备上的身份。演练没有执行任何抹除。"
    static let drillOutcomeWrong = "两把都不匹配——真实情况下它只会再要一次输入。"
    static let drillOutcomeNotConfigured = "这台设备还没设置常规码，所以没有可比对的记录。"
    static let drillOutcomeLockedOut = "演练走的是只读比对，它不查冷却表，所以这一句在这一页永远出现不了：它存在只是因为那个结果多了一种可能，而编译器要求把话说完整。锁屏上那一格才是冷却真正落地的地方。"

    // 页脚风险说明
    static let groupRisk = "这一套不能保护你什么"
    static let riskIrreversible = "数据一经胁迫码抹除就不可恢复：没有备份提示，没有撤销，没有找回通道。演练页不会、也无法让你试错一次。"
    static let riskForensics = "自毁依赖 SimpleX 的关库与文件删除。操作系统曾经把这些页面渲染进缓存的那部分，不保证已经无法被取证手段恢复——本模块把可恢复的内容压到很小，但不承诺为零。"
    static let riskFalsePositive = "传感器判据一定会误报：过减速带、把手机扔进包里、桌角磕一下都可能命中。正因为它会误报，它的后果永远被限制在「再认证一次」，绝不通向擦除。"
}
