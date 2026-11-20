//
//  PopopxAppLockOverlayView.swift
//  POPOPX (iOS)
//
//  【物理防抢夺 · 界面层】全屏磨砂密码遮罩 + 静默加载过渡层。它是 `PopopxAppLockState`
//  唯一的"脸"：模块一（传感器/超时/后台）与模块二（行为判据）只负责把锁拉起来，
//  模块三（双密码）只负责判码与擦除，中间这一层是两者唯一交汇的地方。
//
//  ### 与上游 `ContentView` 的 LA 门是两层不同的东西，不许合并
//  `ContentView` 那套门（`DEFAULT_PERFORM_LA` + `contentViewAccessAuthenticated` +
//  后台 `DEFAULT_LA_LOCK_DELAY`，见 `Shared/ContentView.swift` 的 `prefPerformLA`
//  （:46）与 `contentViewAccessAuthenticated` 那两处判断）判的是
//  **"谁可以进这个 app"**：它发生在 app 冷启动 / 从锁屏延迟回来时，界面是上游自己的
//  `SetAppPasscodeView` / `LocalAuthView`，解锁动作走 `authorize()`。
//  本遮罩判的是 **"手机此刻是不是在我手里"**：它发生在 app 已经开着、正在用的当中，
//  由传感器/超时/后台事件在进程内拉起，界面上只有 6 位码和一把生物识别快捷。
//  两层各自独立成立，顺序也固定：先有 LA 门放人进来，才谈得上遮罩。
//  本文件**不调用也不修改** `authorize()`——它对 `.unavailable` 直接放权
//  （LocalAuthenticationUtils.swift:20-24 的 `authorize`），那是"设备解锁便利性"的语义，安全遮罩不许继承。
//  同理，本文件不新增任何 UserDefaults 键、不碰 Keychain、不读写上游那两条口令。
//
//  ### 遮罩的存在由 `coversContent` 判，键盘的显隐由 `showsLockUI` 判，谁都不许自己拼条件
//  `PopopxAppLockState` 把两个问题分开了（`PopopxAntiTheftMotionGuard.swift` 里
//  `PopopxAppLockState` 的类型注释与那两个计算属性）：
//  **盖不盖**用 `coversContent`（= `isLocked`，整个锁定期恒真，包括静默自毁那 1.2 秒）；
//  **遮罩上显示什么**用 `showsLockUI`（自毁进行中为假，那时只许呼吸，不许出现原因文案、
//  键盘、报错或"正在销毁"）。把两件事合成一个判据是本模块真实出过的事故：
//  遮罩在"开始擦除"那一瞬间消失，内容直接暴露给站在旁边的人。
//  本层在这两个判据之上还要补一刀：`submit(pin:)` 命中胁迫码时的顺序是
//  `beginDuressFlow()` → 擦除 → `endDuressFlow()` → **`unlock()`** → 最后才把不足
//  `minimumFlowSeconds` 的时间补齐（`PopopxDuressAuthManager` 的 `submit(pin:)`）。
//  也就是说 `await` 返回**之前** `isLocked` 已经翻过一次，只看上游判据会在补时那一段
//  把遮罩掀掉一次——掀掉那一下就是穿帮。所以：
//  - 存在性 = `lock.coversContent || model.silentFlow`；
//  - 呼吸/键盘的取舍 = `model.silentFlow`，它同时吃本地 `phase` 和上游 `showsLockUI`，
//    因为静默流程也可能由本层看不见的入口发起。
//  两个判据都取并集，两个翻转点才都盖得住。
//
//  ### 不变量：`.unlocked` 与 `.duress` 必须逐字相同（改之前先读这一段）
//  一次键盘提交只有四种结论，其中两种（常规码命中、胁迫码命中）**在界面上必须是同一件事**：
//  同一个 `case`、同一段代码、同一次触觉、同一句文案、同一个时长。理由不是美学：
//  如果 `.duress` 多震一下、晚 200ms、颜色深一点、或者蹦出"正在处理"四个字，
//  胁迫者只要看一眼、或者拿秒表量一下，就知道自己按下的正是那把不该按下的码。
//  这不是"体验不一致"，这是当着人的面自曝。所以：
//  - 结论分支写成 `case .unlocked, .duress:`，一个 case 一支，不给编译器留拆开的余地；
//  - 流程中**不**发任何完成触觉（`PopopxHaptics.notice(.success)` 一律不许出现在这一支）；
//  - 呼吸层的文案与时长由 `PopopxDuressAuthManager.minimumFlowSeconds` 与
//    `submit` 内部的补时决定，本文件只负责"动画持续到 `await` 返回"，不自己掐表；
//  - 唯一允许出现差异的是 `.wrong`（码不对）与 `.notConfigured`（还没设码），
//    它们按定义就不是胁迫路径。
//  同一道理，`.wrong` 之后按原顺序重输同一个码，画面必须与第一次一模一样。
//
//  ### 呼吸动画为什么只能用 opacity / scale（以及为什么绝不用 Timer）
//  `submit` 的擦除段（`PopopxStorageWipe.wipe`）里有几段**在主线程同步跑**的重活：
//  `chatCloseStore()` 关 SQLite、`clearRenderedState` 清 ItemsModel、`resetChatCtrl()` +
//  `initializeChat(start:)` 重建控制层——合计数百毫秒（删文件那一段已经刻意挪到后台，
//  见 `PopopxStorageWipe` 里那段 `DispatchQueue.global(qos: .userInitiated)`；
//  但剩下的仍在主 actor 上）。
//  用 `Timer`/`DispatchSourceTimer` 逐帧推关键帧的动画，其回调排在主线程队列上，
//  主线程一被占住就整段停住，恢复的那一帧是"跳"过去的——屏幕上留下一次可被看见的顿挫。
//  而 `opacity` 与 `transform`（`scaleEffect` 落到 CALayer 上）是**可托管属性**：
//  动画一经提交就由渲染进程自己推进，主线程卡死也照呼吸。
//  所以本文件只改这两个属性，并且**在 `await` 之前**把动画提交出去
//  （`send(reduceMotion:)` 里那一次 `withAnimation` 早于任何擦除代码；面板另有一条
//  `onChange(of: silentFlow)` 兜住"自毁由本层之外的入口发起"那种情况）。
//  Reduce Motion 下不动起来，但文案、时长、触觉一个都不改——差异只许出现在"有没有动"，
//  而这对常规码与胁迫码是同一个值。
//
//  ### 命中测试：视觉遮挡不算挡住
//  遮罩层自己吃掉点击与拖动（`contentShape` + 空 `onTapGesture` + `DragGesture(minimumDistance: 0)`），
//  磨砂层在它们下面再兜一次。少了那条拖动手势，底下的会话列表在遮罩后面**仍然能被滚走**
//  ——看见了遮罩却摸得着内容，是这个界面最不能犯的第二种错。
//
//  ### 宿主接线契约：只能挂 `popopxAppLockOverlay()`，不许在宿主里 `if coversContent`
//  本类型自己判断盖不盖，宿主唯一要做的是**无条件**挂上（没锁时它是一个空 `ZStack`，
//  不产生命中区、不参与布局、常态开销等于零）。在宿主那边写
//  `if lock.coversContent { PopopxAppLockOverlayView() }` 是错的，而且错得很隐蔽：
//  `submit(pin:)` 在补时**之前**就 `unlock()`，那一瞬间 `coversContent` 转假，
//  宿主于是把整个遮罩从层级里**摘掉**——本层内部那条"流程在飞就不许撤"的保险
//  根本来不及说话，视图已经没了，`@State` 里的相位也一起没了。剩下的最多 1.2 秒里
//  内容直接摆在胁迫者眼前，正是本模块定义的那一次穿帮。
//  判据装在视图里、而不是装在宿主里，为的就是这种时刻没有一个宿主能把它先摘掉。
//
//  ### 本文件做不到的事（诚实边界，不许在文案里暗示做到了）
//  1. `PopopxScreenCaptureShieldView` 只把**它自己承载的那部分内容**挪出屏幕采集 buffer
//     （机理与私有画布的红线见 `PopopxScreenCaptureShieldView.swift` 文件头，
//     以及它对 `UITextField.isSecureTextEntry` 的唯一开关约定）。
//     被遮罩盖住的会话列表仍在主宿主那一层，录屏拿到的是**它们自己**那一份像素——
//     磨砂只骗得过眼睛，骗不过 buffer。要真正做到"锁屏期间录不到列表"，得由窗口级方案
//     （`PopopxSecureWindowManager` 那一类）或锁屏时把底层视图摘掉来承担，本文件不假称有。
//  2. 遮罩挂在宿主视图的 `overlay` 上，因此**盖不住以 sheet / fullScreenCover 呈现的层**
//     （它们在窗口层级里位于本视图之上）。宿主必须挂在最顶层窗口容器上，
//     并且锁定时如果正有模态在飞，需要由宿主自己先收掉——这是接线侧的事。
//  3. `PIN` 是 `String`，归 ARC 管、覆写不了，本层只承诺"流程结束立刻丢引用"。
//     真正被清零的那一份拷贝在 `PopopxDuressAuthManager.derive(secret:salt:iterations:)` 里
//     （`PopopxDuressAuthManager` 的 `derive(secret:salt:iterations:)`：派生出的那份 `Data`
//     由 `defer { popopxSecureErase(&secret) }` 就地清零）。
//  4. 口令派生要跑两次 PBKDF2，常规码也要等满 1.2 秒——这不是本层的 bug，
//     是 `minimumFlowSeconds` 存在的原因：让真自毁藏在同一条下限里。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//  ⚠️ 本文件**不加** `#Preview` / `PreviewProvider`：CI 的快照比对会给新增预览判失败。
//

import SwiftUI
import UIKit

// MARK: - 文案

/// 遮罩上会出现的每一句话。集中一处，是为了让"两支必须逐字相同"这条不变量
/// 在字面上就只有一份来源——散在布局里写字符串，迟早有一支被改掉一个字。
///
/// 这里**不**插值 `PopopxDuressAuthManager.pinLength`：那是个 `@MainActor` 静态量，
/// 从非隔离的全局初始化里读它是 Swift 6 的错。带位数的两句在面板的 `dotsLabel` 里现拼。
private enum PopopxLockCopy {
    static let headlineFallback = NSLocalizedString("Locked", comment: "")
    static let symbolFallback = "lock"
    static let prompt = NSLocalizedString("Enter your unlock passcode", comment: "")
    static let breathing = NSLocalizedString("Unlocking…", comment: "")
    static let wrong = NSLocalizedString("Wrong passcode, please enter it again", comment: "")
    static let send = NSLocalizedString("Confirm", comment: "")
    static let keypad = NSLocalizedString("Numeric passcode keypad", comment: "")
    static let delete = NSLocalizedString("Delete the last digit", comment: "")
    static let biometric = NSLocalizedString("Unlock with Face ID or Touch ID", comment: "")
    static let biometricReason = NSLocalizedString("Unlock POPOPX", comment: "")
    static let minimalPrompt = NSLocalizedString("No unlock passcode is set on this device yet", comment: "")
    static let minimalNote = NSLocalizedString("This device has no unlock passcode yet — unlock first, then turn it on under Settings.", comment: "")
    static let minimalUnlock = NSLocalizedString("Unlock", comment: "")

    // 冷却层。`%@` 只吃 `PopopxLockoutSchedule.phrase(_:)` 那一种读法，别处不许另拼一套数字。
    static let lockedOutPrompt = NSLocalizedString("Disabled", comment: "")
    static let lockedOutFormat = NSLocalizedString("POPOPX is disabled. Try again in %@.", comment: "")
    static let lockedOutFootnote = NSLocalizedString("During this cooldown the keypad, Face ID and the mnemonic phrase are all refused.", comment: "")
    /// 读给 VoiceOver 的那一句**不含秒数**：理由见 `PopopxLockPanel.lockedOut`。
    static let lockedOutVoiceOver = NSLocalizedString("POPOPX is disabled and cooling down. The keypad, Face ID and the mnemonic phrase are temporarily unavailable and come back automatically when the countdown ends.", comment: "")

    // 助记词那一格。`mnemonicConsequence` 必须在**按下之前**就看得见：它说的是一次不可逆的删除。
    static let mnemonicEntry = NSLocalizedString("Forgot the passcode? Reset with the 12-word mnemonic phrase", comment: "")
    static let mnemonicPrompt = NSLocalizedString("Use the 12-word mnemonic phrase", comment: "")
    static let mnemonicPhraseField = NSLocalizedString("12 mnemonic words", comment: "")
    static let mnemonicPhrasePrompt = NSLocalizedString("Type them in order; spaces or newlines between the words both work", comment: "")
    static let mnemonicNewPinField = NSLocalizedString("New entry passcode", comment: "")
    static let mnemonicConfirmField = NSLocalizedString("Re-enter the new entry passcode", comment: "")
    static let mnemonicConsequence = NSLocalizedString("Resetting also clears the emergency wipe passcode to unset — after that, that code no longer exists.", comment: "")
    static let mnemonicSubmit = NSLocalizedString("Reset the entry passcode", comment: "")
    static let mnemonicCancel = NSLocalizedString("Back to the keypad", comment: "")
    static let mnemonicFailed = NSLocalizedString("The reset did not complete; try again later", comment: "")
}

// MARK: - 尺寸与动效常量

/// 只有两种数字：由 `PopopxMetrics` 代币相加得到的尺寸，以及**不是间距**的归一化系数
/// （透明度、缩放倍率、每步毫秒数）。写死一个间距或圆角就是返工，把它们称作"尺寸"也是。
private enum PopopxLockLayout {
    /// 单键边长：`minHitTarget`（44）是硬下限，再加一档 `spaceS` 才不挤。
    static let keySide: CGFloat = PopopxMetrics.minHitTarget + PopopxMetrics.spaceS
    static let keyGap: CGFloat = PopopxMetrics.spaceS
    static let dotSide: CGFloat = PopopxMetrics.spaceS
    static let dotGap: CGFloat = PopopxMetrics.spaceXS
    static let ringSide: CGFloat = PopopxMetrics.minHitTarget + PopopxMetrics.space2XL
}

private enum PopopxLockMotion {
    /// 呼吸的两个刻度。只有 opacity / scale——理由见文件头"呼吸动画"那一段。
    static let breathScaleSmall: CGFloat = 0.94
    static let breathScaleLarge: CGFloat = 1.06
    static let breathDim: Double = 0.35
    static let breathBright: Double = 0.85
    /// 抖动幅度与每步时长。幅度取一档间距代币，时长不是间距，故允许写毫秒。
    static let shakeAmplitude: CGFloat = PopopxMetrics.spaceS
    static let shakeStep: Duration = .milliseconds(80)
    /// 磨砂之上再压一层底色，让 `label` 站得住；留一点不完全遮住，磨砂才看得出是磨砂。
    static let backdropWash: Double = 0.72
}

// MARK: - 遮罩状态机

/// 遮罩自己的那一格状态。**只有**流程相位、已输数字、显示用的文案与两个动效刻度。
///
/// 刻意不写 `isLocked`、也不写任何"这次是哪把码"的痕迹：`PopopxAppLockState` 是模块共用的
/// 那一份，而"哪把码"这件事一旦在界面层留了副本（一个 `wasDuress` 之类的字段），
/// 就迟早会有一行界面代码去读它——那正是不变量被破坏的方式。这里没有可读的东西。
@MainActor
@Observable
final class PopopxAppLockOverlayModel {
    enum Phase: Hashable {
        /// 键盘等着输码。
        case keypad
        /// 已提交，呼吸中。常规码与胁迫码都停在这一格，且只有这一格。
        case breathing
        /// 还没设过双密码：只有一个"解锁"按钮的降级态。
        case minimalUnlock
        /// 防爆破冷却中。数字键、Face ID、助记词入口三样一起不接命中，
        /// 画面中央只剩一个每秒一跳的倒计时。
        case lockedOut
        /// 「用 12 词助记词重置」那一格：词组 + 新码 + 再输一遍，提交后进 `completeUnlock()`。
        case mnemonicReset
    }

    /// 锁状态、认证、传感器——三个共享单例。`let`：本类只读它们、只经由公开方法写它们。
    let lock = PopopxAppLockState.shared
    let auth = PopopxDuressAuthManager.shared
    let motion = PopopxAntiTheftMotionGuard.shared

    private(set) var phase: Phase = .keypad
    /// 顶部那一行：锁屏出现时就**抄死**，之后不跟 `lock.reason` 走。
    /// 因为 `unlock()` 会把 `reason` 清成 nil，而遮罩还要继续呼吸 1.2 秒——
    /// 直接绑定就是"文案在半空里自己消失"，那是一次肉眼可见的异常。
    private(set) var headline: String = PopopxLockCopy.headlineFallback
    private(set) var headSymbol: String = PopopxLockCopy.symbolFallback
    private(set) var wrongHint: String?
    /// 生物识别键是否显示。开局算一次存下来：`biometricsAvailable` 每次调用都要新建一个
    /// `LAContext`，不能在 `body` 里逐帧问。
    private(set) var showsBiometricKey = false
    var pin: String = ""
    private(set) var breath = false
    private(set) var shakeOffset: CGFloat = 0
    /// 只当"错误发生了第几次"的触发器用；计数本身不进任何可见文案。
    private(set) var wrongCount = 0

    private var submitTask: Task<Void, Never>?
    private var shakeTask: Task<Void, Never>?
    private var biometricRequested = false
    /// 本轮流程是否已经把呼吸提交给动画系统。见 `setBreathing(_:reduceMotion:)`。
    private var breathStarted = false
    /// 冷却到点的那**一次**唤醒。不是每秒心跳——每秒那一跳由面板的 `TimelineView` 自己负责，
    /// 见 `startLockoutWatch()` 的理由。
    private var lockoutTask: Task<Void, Never>?

    // MARK: 助记词那一格的三个输入
    //
    // 这三个字段和设置页那两把码是同一类东西：**明文的界面副本**。管理器只在这一格
    // 的一次 `resetEntryPinWithMnemonic` 调用里读它们，之后（提交、退回键盘、遮罩退场、
    // 重新拉锁）一律由 `resetMnemonicForm()` 清掉。`mnemonicInput` 尤其要紧——
    // 那 12 个词在安全存储里另有一份可读副本，界面上这一份不该比这一次机会活得更久。
    var mnemonicInput = ""
    var newPin = ""
    var newPinConfirm = ""

    /// 「忘记密码？使用 12 词助记词重置」那一行给不给。三个条件缺一不可：
    /// 词组真的在（不在就没有可校验的东西）、常规码记录还在（重置写的就是它）、
    /// 并且当前不在冷却（冷却期内三样输入口一起关掉，这是那张表的定义）。
    var canOfferMnemonicReset: Bool {
        auth.mnemonicConfigured && auth.normalConfigured && !auth.isLockedOut
    }

    var canSubmitMnemonicReset: Bool {
        !PopopxBIP39.normalizedWords(mnemonicInput).isEmpty
            && newPin.count == PopopxDuressAuthManager.pinLength
            && newPin == newPinConfirm
    }

    /// 面板每秒问一次"还剩多久"。它读的是 `context.date`，不是 `Date()`：
    /// 一个 `TimelineView` 的调度时刻和一次自行取来的当前时间可以差几十毫秒，
    /// 显示的数字因此应当只来自那一个被调度的时刻。
    func lockoutRemaining(at date: Date) -> TimeInterval {
        guard let endsAt = auth.lockoutEndsAt else { return 0 }
        return max(0, endsAt.timeIntervalSince(date))
    }

    /// 是否处于"只呼吸、什么都不显示"的那一格。两条来源，缺一不可：
    /// 1. 本地 `phase == .breathing`——本层刚提交过密码，常规码也要静默满 1.2 秒；
    /// 2. 上游静默自毁在飞（`lock.isLocked && !lock.showsLockUI`）——这条路可能由本层
    ///    看不见的入口发起，只认本地状态就会在自毁中间把键盘端回去。
    /// 见文件头那一段：`coversContent` 管盖不盖，`showsLockUI` 管键盘显不显，
    /// 本层把它们和本地 `phase` 取并集，才盖得住 `unlock()` 与补时那两个翻转点。
    var silentFlow: Bool {
        phase == .breathing || (lock.isLocked && !lock.showsLockUI)
    }

    /// 遮罩在不在。`coversContent` 负责"锁着就必须盖住"，`silentFlow` 负责
    /// "流程在飞的时候谁都不许把遮罩拿走"——`submit` 在补时之前就先 `unlock()` 了，
    /// 少了后半句，遮罩会在自毁的最后几百毫秒自己掀掉。
    var presents: Bool {
        lock.coversContent || silentFlow
    }

    var canSend: Bool {
        pin.count == PopopxDuressAuthManager.pinLength
    }

    // MARK: 生命周期

    /// 遮罩开始呈现。**幂等**，且被 `initial: true` 的 `onChange` 在挂载时调一次：
    /// 冷启动恰好落在已锁状态上时，没有别的路径会把 `phase` 摆正。
    func begin() {
        guard phase != .breathing else { return }
        pin = ""
        wrongHint = nil
        shakeOffset = 0
        stopBreathing()
        resetMnemonicForm()
        biometricRequested = false
        // Keychain 可能在别的会话里被改过（自毁就是这种改动），每次进遮罩重问一遍。
        auth.refreshConfiguration()
        if let reason = lock.reason {
            headline = reason.userText
            headSymbol = reason.symbolName
        }
        showsBiometricKey = auth.prefersBiometricUnlock
        // 冷却的判断放在"有没有常规码"之前：这张表拦的是**输入口**，与拦下的是哪一把码无关。
        // 冷启动落在冷却中段也走这一支——`lockoutEndsAt` 落盘在安全存储里，就是为了这一刻。
        if auth.isLockedOut {
            phase = .lockedOut
            startLockoutWatch()
        } else if auth.normalConfigured {
            phase = .keypad
            requestBiometricsIfNeeded()
        } else {
            phase = .minimalUnlock
        }
        // 锁已经拉起来了，再确认一次停采。传感器侧的 `trigger` 自己会停，但模块二、
        // 手动锁定、超时那几条路不经过模块一的停采点——`lockedDidChange()` 是唯一的统一出口。
        motion.lockedDidChange()
    }

    /// 遮罩退场后收尾，下一次拉锁从干净的键盘开始。
    func endPresenting() {
        guard phase != .breathing else { return }
        pin = ""
        wrongHint = nil
        shakeOffset = 0
        stopBreathing()
        lockoutTask?.cancel()
        lockoutTask = nil
        resetMnemonicForm()
        phase = .keypad
        biometricRequested = false
    }

    // MARK: 键盘

    /// 键盘是否可交互。`phase` 之外还要问 `silentFlow`：静默自毁可能由本层看不见的入口
    /// 发起，那一刻 `phase` 还停在 `.keypad`，而画面上已经没有键盘了——
    /// 看不见却按得动的键，比按不动更糟。
    var keypadLive: Bool { phase == .keypad && !silentFlow }

    func tapDigit(_ digit: Int) {
        guard keypadLive, pin.count < PopopxDuressAuthManager.pinLength else { return }
        // 输码也是"人在操作"，给超时判据一个节拍，免得输到一半又被拉一次锁。
        lock.noteInteraction()
        wrongHint = nil
        pin += String(digit)
    }

    func tapDelete() {
        guard keypadLive, !pin.isEmpty else { return }
        lock.noteInteraction()
        pin.removeLast()
    }

    /// 确认键。唯一的提交入口——不做"输满 6 位自动提交"，因为自动提交会把
    /// 呼吸起点绑在最后一次按键上，而显式提交把它绑在一个确定发生过的动作上。
    func send(reduceMotion: Bool) {
        guard keypadLive, canSend else { return }
        lock.noteInteraction()
        let entered = pin
        phase = .breathing
        // 动画**在这里**提交，不等 `onChange`：Task 体会被排到主 actor 队列上，
        // 它和一次视图更新谁先跑没有保证，而这条动画必须赶在擦除段占住主线程之前交给
        // 渲染进程（文件头"呼吸动画"那一段）。`setBreathing` 幂等，面板随后那次调用是空转。
        setBreathing(true, reduceMotion: reduceMotion)
        submitTask = Task { [weak self] in
            guard let self else { return }
            // 不自己掐表：`submit` 内部已经把不足 `minimumFlowSeconds` 的时间补到末尾。
            let outcome = await self.auth.submit(pin: entered)
            self.finish(outcome: outcome)
        }
    }

    func retryBiometrics() {
        guard keypadLive else { return }
        lock.noteInteraction()
        biometricRequested = false
        requestBiometricsIfNeeded()
    }

    /// 降级态的那一个按钮：还没有任何密码可言，直接交回界面。
    func unlockWithoutPin() {
        pin = ""
        phase = .keypad
        lock.unlock()
        motion.lockedDidChange()
    }

    // MARK: 助记词重置

    func beginMnemonicReset() {
        guard keypadLive, canOfferMnemonicReset else { return }
        lock.noteInteraction()
        resetMnemonicForm()
        wrongHint = nil
        phase = .mnemonicReset
    }

    func cancelMnemonicReset() {
        guard phase == .mnemonicReset else { return }
        resetMnemonicForm()
        wrongHint = nil
        phase = .keypad
    }

    /// 提交那 12 个词。校验、写新码、清应急擦除密码、清冷却计数全部在
    /// `PopopxDuressAuthManager.resetEntryPinWithMnemonic` 里做完，本层只管界面。
    ///
    /// **先清界面副本、后 `await`**：这一次调用可能要走三百多毫秒（两次 10 万次派生），
    /// 那期间键盘上还留着明文的风险比"失败后要重输一遍"大得多。失败时管理器会给出
    /// 那十五句里的一句，机主照着再输一次就行。
    ///
    /// 结构不合法（`mnemonicMalformed`）也在这一格解释：`canSubmitMnemonicReset` 只看
    /// "有没有输过东西"，不看词数与拼法。把不合法的输入用"按钮按不动"来表达，
    /// 机主读到的是"这个按钮坏了"；让管理器说出"需要 12 个标准英文词"才是一句能照着做的话。
    func submitMnemonicReset() async {
        guard phase == .mnemonicReset, canSubmitMnemonicReset else { return }
        lock.noteInteraction()
        let phrase = mnemonicInput
        let candidate = newPin
        let confirmed = newPinConfirm
        resetMnemonicForm()
        pin = ""
        do {
            try await auth.resetEntryPinWithMnemonic(phrase: phrase, newPin: candidate, confirmingPin: confirmed)
            mnemonicResetSucceeded()
        } catch let error as PopopxDuressSetupError {
            wrongHint = error.errorDescription
            PopopxHaptics.notice(.error)
            // 不问"抛出来的是不是 `lockedOut`"，直接问冷却表：这一次错的助记词可能刚好
            // 把第 5 次踩出来（`settleWrongAttempt` 在抛 `.mnemonicIncorrect` 之前就跑过了），
            // 那时错误句是"助记词不正确"，而输入口已经该关上了。
            if auth.isLockedOut {
                phase = .lockedOut
                startLockoutWatch()
            } else {
                phase = .mnemonicReset
            }
        } catch {
            wrongHint = PopopxLockCopy.mnemonicFailed
            phase = .mnemonicReset
            PopopxHaptics.notice(.error)
        }
    }

    /// 重置成功之后的收尾，走的是与"一次成功解锁"完全相同的那一段。
    ///
    /// 为什么可以直接进去、不再逼机主用刚设的码在键盘上验一遍：这一条路**在类型上就
    /// 不可能是胁迫码**——`resetEntryPinWithMnemonic` 的末尾把应急擦除密码删了，
    /// 交出那把码的人不会再抹掉任何数据，所以这里没有"替胁迫者念出结论"的风险。
    /// 而逼一个刚丢过密码的人立刻盲打一把 3 秒前才设的码，只会把"重置到底成没成"
    /// 变成第二个疑问。
    private func mnemonicResetSucceeded() {
        auth.refreshConfiguration()
        wrongHint = nil
        phase = .keypad
        completeUnlock()
    }

    /// 三个输入框一次性收回。凡是从 `phase == .mnemonicReset` 出去的路口都要过这里。
    private func resetMnemonicForm() {
        mnemonicInput = ""
        newPin = ""
        newPinConfirm = ""
    }

    // MARK: 冷却

    /// 冷却到点时把画面交回键盘的**一次性**闹钟。
    ///
    /// 为什么不是每秒一跳的心跳：那一跳由面板里的 `TimelineView` 负责，它自己会随剩余
    /// 时间归零而停。两个都要，就有了两个"现在几点"的口径，而它们迟早会说不一样的话。
    /// `+0.25` 是留给取整的余量：`phrase(_:)` 向上取整，界面上"0 秒"之后还剩几百毫秒是常态，
    /// 到点再问一次 `isLockedOut`，还锁着就重挂一次闹钟。
    private func startLockoutWatch() {
        lockoutTask?.cancel()
        let remaining = auth.lockoutRemainingSeconds
        guard remaining > 0 else {
            if phase == .lockedOut { phase = .keypad }
            return
        }
        lockoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining + 0.25))
            guard let self, !Task.isCancelled else { return }
            guard self.phase == .lockedOut else { return }
            if self.auth.isLockedOut {
                self.startLockoutWatch()
            } else {
                self.wrongHint = nil
                self.phase = .keypad
                // 交回键盘的那一瞬间不重放 Face ID：机主刚被这道表拦下，
                // 弹一条系统认证条只会让他以为"锁解了"。让他自己按。
            }
        }
    }

    // MARK: 动效（由面板把 Reduce Motion 传进来：本类不是 View，拿不到 environment）

    /// 起/停呼吸。**幂等**：一次提交流程里最多只有一次 `repeatForever` 被提交出去，
    /// 中途重新 `withAnimation` 会让环在半路上重起一个周期——那是一次肉眼可见的顿。
    ///
    /// 启动只发生在 `send(reduceMotion:)` 里、任何 `await` 之前，于是动画一经提交就在
    /// 渲染进程手上；随后主线程被 `chatCloseStore()` / `initializeChat()` 占住数百毫秒，
    /// 呼吸照旧（见文件头：只有 opacity / scale 这类可托管属性撑得住那种时刻）。
    func setBreathing(_ on: Bool, reduceMotion: Bool) {
        guard on else {
            stopBreathing()
            return
        }
        guard !breathStarted else { return }
        breathStarted = true
        PopopxMotion.withAnimation(
            PopopxSpring.fluid.repeatForever(autoreverses: true),
            reduceMotion: reduceMotion
        ) {
            breath = true
        }
    }

    /// 停呼吸：值和"已提交"标记一起收回。漏掉标记的话，下一次提交就不再起动画了。
    private func stopBreathing() {
        breathStarted = false
        breath = false
    }

    /// 一次水平抖动。Reduce Motion 下整段不做——这是"差异"，但它在常规码与胁迫码上是
    /// 同一个值（同一台设备、同一次 `.wrong`），因此不构成穿帮。
    func shake(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        shakeTask?.cancel()
        let amplitude = PopopxLockMotion.shakeAmplitude
        shakeTask = Task { [weak self] in
            for step in [-1.0, 1.0, -0.5, 0.0] {
                if Task.isCancelled { return }
                PopopxMotion.withAnimation(PopopxSpring.snappy, reduceMotion: reduceMotion) {
                    self?.shakeOffset = CGFloat(step) * amplitude
                }
                try? await Task.sleep(for: PopopxLockMotion.shakeStep)
            }
        }
    }

    // MARK: 内部

    private func requestBiometricsIfNeeded() {
        guard showsBiometricKey, !biometricRequested else { return }
        biometricRequested = true
        auth.requestBiometricUnlock(reason: PopopxLockCopy.biometricReason) { [weak self] granted in
            // 回调线程由 LocalAuthentication 决定（管理器内部会跳回主 actor，但它的
            // `completion` 类型不承诺这件事），这里再跳一次，不猜线程。
            Task { @MainActor [weak self] in
                self?.biometricFinished(granted: granted)
            }
        }
    }

    private func biometricFinished(granted: Bool) {
        // false 只意味着"该把键盘交出来了"——键盘就在底下，什么都不必改。
        guard granted else { return }
        // 成功时管理器**已经** `unlock()` 并把失败计数清零了（`PopopxDuressAuthManager` 的 `requestBiometricUnlock(reason:completion:)` 注释），
        // 这里不重复改锁状态，只做界面收尾 + 恢复采样。
        pin = ""
        wrongHint = nil
        phase = .keypad
        motion.lockedDidChange()
    }

    private func finish(outcome: PopopxDuressAuthOutcome) {
        submitTask = nil
        switch outcome {
        case .unlocked, .duress:
            // ⚠️⚠️ 不变量（文件头有完整理由）：这两支**必须是同一个 case、同一段代码**。
            // 不许在这里加 `if outcome == .duress`，不许加日志、触觉、文案、延时、颜色。
            // 界面拿到的是"一次成功的解锁"，仅此而已。
            completeUnlock()
        case .wrong:
            pin = ""
            stopBreathing()
            phase = .keypad
            wrongHint = PopopxLockCopy.wrong
            PopopxHaptics.notice(.error)
            // 抖动由面板在 `wrongCount` 变化时用它的 environment 发起。
            wrongCount += 1
        case .notConfigured:
            // 还没设双密码（或 Keychain 在别处被清了）。绝不把用户永久锁在门外。
            pin = ""
            stopBreathing()
            wrongHint = nil
            phase = .minimalUnlock
        case .lockedOut:
            // 第 5 次起走这一支（以及"已经在冷却里又按了一次确认"）。它**不是**一条错误提示：
            // 键盘、面容、助记词那三个输入口一起收掉，中央只剩一个每秒一跳的倒计时。
            // 触觉与 `.wrong` 那一次不同（那里是 `notice(.error)`），但两者在"这一把没开门"
            // 这件事上完全一致，常规码与胁迫码走的是同一段代码，因此不构成穿帮。
            pin = ""
            stopBreathing()
            wrongHint = nil
            resetMnemonicForm()
            phase = .lockedOut
            startLockoutWatch()
            PopopxHaptics.notice(.warning)
        }
    }

    /// 顺序是承重的：先把失败计数清掉、再解铃、最后才告知传感器"锁没了"。
    /// `lockedDidChange()` 读的是 `isLocked`，放在 `unlock()` 之前它就会照旧停采。
    /// `unlock()` 自己也已经告知过一次（`PopopxAppLockState` 在解铃末尾直接调
    /// `PopopxAntiTheftMotionGuard.shared.lockedDidChange()`）——这一句因此是显式的第二次，
    /// 留着是为了让"锁的两条边缘都要告知传感器"这件事在本文件里也看得见，
    /// 而不是寄在别人的实现细节上。
    private func completeUnlock() {
        auth.resetBiometricFailures()
        lock.unlock()
        motion.lockedDidChange()
        // 冷却闹钟与助记词那三个明文副本跟着这一次成功一起收掉。`endPresenting()` 也会做
        // 同样的事，但那一句要等 `coversContent` 翻过来才跑，而 `submit` 在补时之前就 `unlock()`
        // 了——中间那几百毫秒里闹钟仍在、词组仍在界面上。这一句把它提前。
        lockoutTask?.cancel()
        lockoutTask = nil
        resetMnemonicForm()
        // `submit` 的胁迫分支内部已经 unlock() 过一次（`submit(pin:)` 里那句 `PopopxAppLockState.shared.unlock()`），
        // 上面那一句因此可能是第二次——`unlock()` 只是几个赋值，重复调用无副作用。
        // 保留它，是为了让两支**共用同一段代码**这件事没有例外：常规码那一路不会自己解铃。
        pin = ""
        stopBreathing()
        wrongHint = nil
        phase = .keypad
    }
}

// MARK: - 遮罩本体

/// 全屏磨砂遮罩。`init()` 无参：状态一律来自 `PopopxAppLockState.shared`，
/// 宿主唯一要做的事就是把它挂在最顶层窗口容器上。
struct PopopxAppLockOverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = PopopxAppLockOverlayModel()
    private let lock = PopopxAppLockState.shared

    init() {}

    var body: some View {
        ZStack {
            if model.presents {
                layers
                    .transition(.opacity)
                    .accessibilityIdentifier("popopx.lock.overlay")
            }
        }
        .popopxAnimation(PopopxSpring.fluid, value: model.presents, reduceMotion: reduceMotion)
        .onChange(of: lock.coversContent, initial: true) { _, covers in
            if covers {
                model.begin()
            } else if !model.silentFlow {
                // 锁放开 ≠ 流程结束：`submit` 在补时之前就先 `unlock()` 了，
                // 这时候收状态会把还在呼吸的遮罩当场掀掉。见文件头那两个翻转点。
                model.endPresenting()
            }
        }
        .onChange(of: model.presents) { _, presenting in
            guard presenting else { return }
            // 遮罩是"另一屏"。`argument: nil` 让 VoiceOver 落到新界面上的第一个元素，
            // 而不是停在被盖住的列表那一行。
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    /// 两层：磨砂底（在外层 SwiftUI 树里，material 一定能真的糊出背景）+
    /// 被采集屏蔽保护的面板。为什么这么分，见文件头"诚实边界"第 1 条。
    ///
    /// `@MainActor`：面板要读 `PopopxDuressAuthManager` 上的隔离常量，而**只有**计算属性
    /// 可以标隔离——本类型整体不标，是为了让 `init()` 保持非隔离，
    /// 从而能被非隔离的 `popopxAppLockOverlay()` 直接构造。
    @MainActor private var layers: some View {
        ZStack {
            backdrop
            PopopxScreenCaptureShieldView {
                PopopxLockPanel(model: model)
            }
        }
    }

    /// 吃掉一切命中的底。三层保险，缺一层就有摸得着的内容：
    /// material 与色洗本身、`contentShape`（把命中区从"有像素的地方"扩到整个矩形）、
    /// 空点击 + 零距拖动两条手势（不给底下的滚动视图留任何机会）。
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(PopopxMaterial.bar)
            Rectangle().fill(PopopxPalette.base.opacity(PopopxLockMotion.backdropWash))
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}
        .gesture(DragGesture(minimumDistance: 0))
        .accessibilityHidden(true)
    }
}

// MARK: - 面板

/// 遮罩上唯一的一块内容：顶部那一行锁原因、6 个点、以及随相位切换的键盘/呼吸/降级态。
///
/// 版式的**反抖动**约定：键盘在呼吸期间只是 `opacity(0)` 占位、不卸载，
/// 于是面板高度全程不变。任何一次 reflow 都会在胁迫者眼前动一下——而"动一下"
/// 正是本模块唯一要避免的东西。
@MainActor
private struct PopopxLockPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable private var model: PopopxAppLockOverlayModel

    init(model: PopopxAppLockOverlayModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: PopopxMetrics.spaceXL) {
            header
            Spacer(minLength: PopopxMetrics.spaceL)
            dots
            hint
            stage
        }
        .padding(.top, PopopxMetrics.spaceS)
        .padding(.bottom, PopopxMetrics.spaceL)
        .padding(.horizontal, PopopxMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: model.shakeOffset)
        .onChange(of: model.silentFlow) { _, flow in
            model.setBreathing(flow, reduceMotion: reduceMotion)
        }
        .onChange(of: model.wrongCount) { _, _ in
            model.shake(reduceMotion: reduceMotion)
        }
        .onChange(of: model.phase) { _, phase in
            // 冷却那一格换掉的是整个舞台：键盘不在了，Face ID 也不接了。看不见的机主
            // 只会得到"按不动了"这一个事实，所以推进去一次 `.layoutChanged`，让焦点落到
            // 新格上、念 `lockedOut` 那句静态标签（不含秒数，理由见那里的说明）。
            // 只报"进"不报"出"：出冷却换回键盘时上一句往往还没念完，再推一次会把自已完成的话掐断。
            if phase == .lockedOut {
                UIAccessibility.post(notification: .layoutChanged, argument: nil)
            }
        }
        .accessibilityIdentifier("popopx.lock.panel")
    }

    // MARK: 顶部

    private var header: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                Image(systemName: model.headSymbol)
                    .font(PopopxType.sectionHeader)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.label)
                    .accessibilityHidden(true)
                Text(model.headline)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, PopopxMetrics.spaceXS)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .background(PopopxPalette.card, in: RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                    .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            )
            Text(subline)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// 面板实际呈现的五种格。`breathing` 由 `model.silentFlow` 决定：它同时吃本地 `phase`
    /// 和上游 `showsLockUI`，所以"自毁在飞、但本层没提交过密码"那种情况也落在这一格里。
    /// 副标题、进度点朗读、舞台切换全部只读这一个判据——三个地方各拼一次条件，
    /// 迟早拼出自相矛盾的画面。
    enum StageKind: Hashable {
        case keypad
        case breathing
        case minimal
        case lockedOut
        case mnemonic
    }

    private var stageKind: StageKind {
        if model.silentFlow { return .breathing }
        switch model.phase {
        case .keypad: return .keypad
        // 被上一行吃掉，写在这里只为穷尽：本地 `.breathing` 一定让 `silentFlow` 为真。
        case .breathing: return .breathing
        case .minimalUnlock: return .minimal
        case .lockedOut: return .lockedOut
        case .mnemonicReset: return .mnemonic
        }
    }

    /// 冷却与助记词那两格不显示进度点：那六个点是"6 位数字里第几位"，
    /// 而这两格一个没有输入、一个用文本框输入。隐藏而不是删掉，是为了让面板高度
    /// 在这五格之间保持完全一致（文件头那条反抖动约定）。
    private var showsDots: Bool {
        stageKind == .keypad || stageKind == .breathing || stageKind == .minimal
    }

    /// 三个相位各有一句副标题。呼吸那一句对常规码与胁迫码是同一句——见不变量。
    private var subline: String {
        switch stageKind {
        case .keypad: return PopopxLockCopy.prompt
        case .breathing: return PopopxLockCopy.breathing
        case .minimal: return PopopxLockCopy.minimalPrompt
        case .lockedOut: return PopopxLockCopy.lockedOutPrompt
        case .mnemonic: return PopopxLockCopy.mnemonicPrompt
        }
    }

    // MARK: 进度点

    private var dots: some View {
        HStack(spacing: PopopxLockLayout.dotGap) {
            ForEach(0..<PopopxDuressAuthManager.pinLength, id: \.self) { index in
                dot(filled: index < model.pin.count)
            }
        }
        .opacity(showsDots ? 1 : 0)
        .accessibilityHidden(!showsDots)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dotsLabel)
        .accessibilityIdentifier("popopx.lock.dots")
    }

    private func dot(filled: Bool) -> some View {
        Circle()
            .fill(filled ? PopopxPalette.label : Color.clear)
            .frame(
                width: PopopxLockLayout.dotSide,
                height: PopopxLockLayout.dotSide
            )
            .overlay(
                Circle().strokeBorder(
                    filled ? Color.clear : PopopxPalette.labelHint,
                    lineWidth: PopopxMetrics.stroke
                )
            )
    }

    /// 点位说给 VoiceOver 听。里面**只有个数**，永远不含任何一位数字本身。
    private var dotsLabel: String {
        let total = PopopxDuressAuthManager.pinLength
        if stageKind == .breathing {
            return PopopxLockCopy.breathing
        }
        if model.pin.count == total {
            return String(format: NSLocalizedString("All %lld digits entered", comment: ""), total)
        }
        return String(format: NSLocalizedString("%1$lld of %2$lld digits entered", comment: ""), model.pin.count, total)
    }

    /// 占位常显：提示出现/消失不许让下面的键盘跳一下。
    private var hint: some View {
        Text(model.wrongHint ?? " ")
            .font(PopopxType.caption)
            .foregroundStyle(PopopxPalette.dangerInk)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .opacity(model.wrongHint == nil ? 0 : 1)
            .accessibilityHidden(model.wrongHint == nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 舞台

    /// 键盘始终在场（必要时透明），呼吸层、降级层、冷却层与助记词层叠在它上面——
    /// 高度因此恒定。`allowsHitTesting(stageKind == .keypad)` 这一句顺带完成了简报要的
    /// "冷却期内禁用数字键盘、Face ID 与助记词按钮"：那三样全都长在键盘这一层里，
    /// 层被关掉命中，三样一起关掉，不需要各写一个 `if`（各写一个就会漏写第四个）。
    private var stage: some View {
        ZStack {
            keypad
                .opacity(stageKind == .keypad ? 1 : 0)
                // `opacity(0)` 不关掉命中：不写这一句，呼吸期间那 10 个看不见的键照样能按。
                .allowsHitTesting(stageKind == .keypad)
                .accessibilityHidden(stageKind != .keypad)
            if stageKind == .breathing {
                breathing
            }
            if stageKind == .minimal {
                minimalUnlock
            }
            if stageKind == .lockedOut {
                lockedOut
            }
            if stageKind == .mnemonic {
                mnemonicReset
            }
        }
        .frame(maxWidth: .infinity)
        .popopxAnimation(PopopxSpring.fluid, value: stageKind, reduceMotion: reduceMotion)
    }

    private var keypad: some View {
        VStack(spacing: PopopxLockLayout.keyGap) {
            digitRow(1, 2, 3)
            digitRow(4, 5, 6)
            digitRow(7, 8, 9)
            HStack(spacing: PopopxLockLayout.keyGap) {
                leadingSlot
                PopopxLockKey(model: model, kind: .digit(0))
                    .accessibilityIdentifier("popopx.lock.digit.0")
                PopopxLockKey(model: model, kind: .delete)
                    .accessibilityIdentifier("popopx.lock.deleteKey")
            }
            sendButton
            // 「忘记密码」那一行只在词组真的存在时占这一格。它会不会在会话中途出现/消失
            // 进而顶动面板高度？不会：`mnemonicConfigured` 只在设置页与抹除流程里变，
            // 而这两种时刻遮罩都不在 `.keypad` 这一格上。
            if model.canOfferMnemonicReset {
                mnemonicEntry
            }
        }
        // 冷却、呼吸、降级、助记词那四格里键盘都不该被 VoiceOver 摸到（`stageKind != .keypad`
        // 时它已整层不接命中）；`disabled` 再补一道，把"看不见却还能聚焦"这条路也关掉。
        .disabled(!model.keypadLive)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PopopxLockCopy.keypad)
        .accessibilityIdentifier("popopx.lock.keypad")
    }

    private func digitRow(_ a: Int, _ b: Int, _ c: Int) -> some View {
        HStack(spacing: PopopxLockLayout.keyGap) {
            PopopxLockKey(model: model, kind: .digit(a))
                .accessibilityIdentifier("popopx.lock.digit.\(a)")
            PopopxLockKey(model: model, kind: .digit(b))
                .accessibilityIdentifier("popopx.lock.digit.\(b)")
            PopopxLockKey(model: model, kind: .digit(c))
                .accessibilityIdentifier("popopx.lock.digit.\(c)")
        }
    }

    /// 左下那一格：能走生物识别就给它，否则留一个同尺寸的占位，`0` 才在中间。
    @ViewBuilder private var leadingSlot: some View {
        if model.showsBiometricKey {
            PopopxLockKey(model: model, kind: .biometric)
                .accessibilityIdentifier("popopx.lock.biometricKey")
        } else {
            Color.clear
                .frame(width: PopopxLockLayout.keySide, height: PopopxLockLayout.keySide)
                .accessibilityHidden(true)
        }
    }

    /// 确认键**不用** `PopopxButton`：那一个在动作返回时会闪一次绿色对勾并补一发
    /// `notice(.success)`（`PopopxButton` 的 `flashSuccess()`）。给一次刚结束的**自毁**
    /// 打勾，等于替胁迫者把结论念出来；给"码不对"打勾，则是当场自证按钮没在判码。
    /// 样式照 `PopopxButton` 的 label 那一套代币来画，只是没有回执。
    private var sendButton: some View {
        Button {
            model.send(reduceMotion: reduceMotion)
        } label: {
            HStack(spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                Text(PopopxLockCopy.send)
            }
            .font(PopopxType.emphasis)
            .foregroundStyle(sendInk)
            .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget)
            .background(sendFill, in: RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(
                        model.canSend ? Color.clear : PopopxPalette.labelHint,
                        lineWidth: PopopxMetrics.divider
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: .light))
        .disabled(!model.canSend)
        .accessibilityLabel(PopopxLockCopy.send)
        .accessibilityIdentifier("popopx.lock.sendButton")
    }

    private var sendFill: Color {
        model.canSend ? PopopxPalette.brand : PopopxPalette.card
    }

    private var sendInk: Color {
        model.canSend ? PopopxPalette.onBrand : PopopxPalette.labelSecondary
    }

    // MARK: 呼吸层

    /// 只有一个环（scale + opacity）和系统转圈。**没有**"正在处理""正在清除"之类的字：
    /// 那些话对常规码是多余，对胁迫码是自首。
    private var breathing: some View {
        ZStack {
            Circle()
                .strokeBorder(PopopxPalette.brand, lineWidth: PopopxMetrics.stroke)
                .frame(
                    width: PopopxLockLayout.ringSide,
                    height: PopopxLockLayout.ringSide
                )
                .scaleEffect(model.breath ? PopopxLockMotion.breathScaleLarge : PopopxLockMotion.breathScaleSmall)
                .opacity(model.breath ? PopopxLockMotion.breathDim : PopopxLockMotion.breathBright)
            Circle()
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
                .frame(
                    width: PopopxLockLayout.ringSide,
                    height: PopopxLockLayout.ringSide
                )
            ProgressView()
                .controlSize(.regular)
                .tint(PopopxPalette.brand)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PopopxLockCopy.breathing)
        .accessibilityIdentifier("popopx.lock.breathing")
    }

    // MARK: 降级层

    /// `.notConfigured`：一个按钮，什么都不多做。这一支**不可能**是胁迫路径
    /// （没设常规码就不会有胁迫码，见 `PopopxDuressAuthManager.setDuressPin` 的
    /// `normalPinRequiredFirst`），所以这里可以放心用带回执的 `PopopxButton`。
    private var minimalUnlock: some View {
        VStack(spacing: PopopxMetrics.spaceM) {
            Text(PopopxLockCopy.minimalNote)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PopopxButton(PopopxLockCopy.minimalUnlock, systemImage: "lock.open", fullWidth: false) {
                model.unlockWithoutPin()
            }
            .accessibilityIdentifier("popopx.lock.minimalUnlock")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 冷却层

    /// 冷却期中央那一块。**每秒一跳由 `TimelineView` 提供**，不是本层的心跳任务：
    /// 数字是 `auth.lockoutEndsAt` 与"这一帧被调度的时刻"之差，读的就是它自己那一份时间，
    /// 因此遮罩被系统短暂挂起再回来也不会跳到错的秒数上。
    ///
    /// 字体：`PopopxType.title`（`.title2` + semibold）再叠 `.monospacedDigit()`。
    /// 任务要的是"等宽字体实时倒计时"，而 `PopopxType` 里没有更大的等宽档——
    /// `metric` 是 `.footnote`、`metricSmall` 是 `.caption2`，都不该出现在屏幕正中。
    /// 所以这里不改字号、只换数字形态：等宽在这个位置的作用只有一个，就是每秒跳一位时
    /// 后面的汉字不许左右移动（那会是一次肉眼可见的 reflow，正是这一屏唯一要避免的事）。
    ///
    /// 那串数字对 VoiceOver 是隐藏的：每秒变化的标签会被反复朗读，而朗读一遍"4 分 59 秒"
    /// 与朗读一遍"4 分 58 秒"对听的人没有任何区别。静态那一句 + 进这一格时的一次
    /// `.layoutChanged`（见 `PopopxLockPanel.body`）才是读得懂的版本。
    private var lockedOut: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = model.lockoutRemaining(at: context.date)
            VStack(spacing: PopopxMetrics.spaceS) {
                Image(systemName: "lock.circle")
                    .font(PopopxType.title)
                    .imageScale(.large)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .accessibilityHidden(true)
                Text(String(format: PopopxLockCopy.lockedOutFormat, PopopxLockoutSchedule.phrase(remaining)))
                    .font(PopopxType.title.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PopopxPalette.label)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("popopx.lock.lockoutCountdown")
                Text(PopopxLockCopy.lockedOutFootnote)
                    .font(PopopxType.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PopopxLockCopy.lockedOutVoiceOver)
        }
    }

    // MARK: 助记词层

    /// 「忘记密码」那一行。它是键盘的一部分（而不是键盘外面多出来的一块），
    /// 为的是冷却期里那一层整块不接命中时，它跟着一起消失——
    /// 单独挂在外面就要在这里再补一个 `if`，而补的那个 `if` 迟早会漏。
    private var mnemonicEntry: some View {
        Button {
            model.beginMnemonicReset()
        } label: {
            Text(PopopxLockCopy.mnemonicEntry)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.brand)
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: .light))
        .accessibilityIdentifier("popopx.lock.mnemonicEntry")
    }

    /// 那 12 个词的输入格 + 两遍新码。提交键不用 `PopopxButton`，理由见 `mnemonicSubmitKey`。
    private var mnemonicReset: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            PopopxTextArea(
                PopopxLockCopy.mnemonicPhraseField,
                prompt: PopopxLockCopy.mnemonicPhrasePrompt,
                text: $model.mnemonicInput
            )
            .accessibilityIdentifier("popopx.lock.mnemonicPhraseField")
            PopopxTextField(
                PopopxLockCopy.mnemonicNewPinField,
                prompt: pinPrompt,
                text: $model.newPin,
                isSecure: true
            )
            .onChange(of: model.newPin) { _, entered in clampPin($model.newPin, entered) }
            PopopxTextField(
                PopopxLockCopy.mnemonicConfirmField,
                prompt: pinPrompt,
                text: $model.newPinConfirm,
                isSecure: true
            )
            .onChange(of: model.newPinConfirm) { _, entered in clampPin($model.newPinConfirm, entered) }
            Text(PopopxLockCopy.mnemonicConsequence)
                .font(PopopxType.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(PopopxPalette.dangerInk)
                .fixedSize(horizontal: false, vertical: true)
            mnemonicSubmitKey
            PopopxButton(PopopxLockCopy.mnemonicCancel, systemImage: "chevron.left", role: .ghost) {
                model.cancelMnemonicReset()
            }
            .accessibilityIdentifier("popopx.lock.mnemonicCancel")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PopopxLockCopy.mnemonicPrompt)
        .accessibilityIdentifier("popopx.lock.mnemonicForm")
    }

    /// 位数提示现拼，不写死"6 位数字"：`PopopxDuressAuthManager.pinLength` 改了，
    /// 这一句要跟着改（文件头那条"两支必须逐字相同"的不变量在这里同样成立）。
    private var pinPrompt: String {
        String(format: NSLocalizedString("Enter exactly %lld digits", comment: ""), PopopxDuressAuthManager.pinLength)
    }

    /// 数字格只留数字、只留 `pinLength` 位。过滤器是唯一防线而不是锦上添花：
    /// `PopopxTextField(isSecure:)` 走的是 `SecureField` 那一支，它**不读** `keyboard:`
    /// 参数（`PopopxControls.swift:237-241`——只有 `TextField` 那一支挂了 `.keyboardType`），
    /// 所以这两格弹出的是全键盘，机主能敲进字母和标点。
    ///
    /// 拿 `Binding` 而不是一个 `String` 参数：两格共用这一个函数，若按值传进来再写回
    /// 同一个字段，"新码"和"确认码"就会互相覆盖。与设置页 `clampToDigits` 同形。
    /// 只在确实滤掉了东西时才回写，避免每次输入都触发一次无谓的状态变更。
    private func clampPin(_ target: Binding<String>, _ entered: String) {
        let kept = String(
            entered
                .filter { PopopxDuressAuthManager.digits.contains($0) }
                .prefix(PopopxDuressAuthManager.pinLength)
        )
        if kept != entered { target.wrappedValue = kept }
    }

    /// 提交那颗键。画法与 `sendButton` 共用同一套代币，也因此同样**不能**用 `PopopxButton`：
    /// 那一个在动作返回时闪一次绿勾再补一发 `notice(.success)`，而"重置失败"也是一次
    /// 动作返回。给一次没成功的重置打勾，机主会以为新码已经生效——
    /// 走到键盘前按不动的那一刻才知道没有，比从一开始就不打勾糟糕得多。
    private var mnemonicSubmitKey: some View {
        Button {
            Task { await model.submitMnemonicReset() }
        } label: {
            HStack(spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "key.fill")
                    .fontWeight(.semibold)
                Text(PopopxLockCopy.mnemonicSubmit)
            }
            .font(PopopxType.emphasis)
            .foregroundStyle(model.canSubmitMnemonicReset ? PopopxPalette.onBrand : PopopxPalette.labelSecondary)
            .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget)
            .background(
                model.canSubmitMnemonicReset ? PopopxPalette.brand : PopopxPalette.card,
                in: RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(
                        model.canSubmitMnemonicReset ? Color.clear : PopopxPalette.labelHint,
                        lineWidth: PopopxMetrics.divider
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: .light))
        .disabled(!model.canSubmitMnemonicReset)
        .accessibilityLabel(PopopxLockCopy.mnemonicSubmit)
        .accessibilityIdentifier("popopx.lock.mnemonicSubmit")
    }
}

// MARK: - 单个键

/// 键盘上的一颗圆键。`Kind` 说清"这是哪一颗"，符号、可达文案、动作都从它派生——
/// 不拿符号字符串去判分支，那样改图标就会顺手改掉行为。
@MainActor
private struct PopopxLockKey: View {
    enum Kind {
        case digit(Int)
        case delete
        case biometric
    }

    let model: PopopxAppLockOverlayModel
    let kind: Kind

    var body: some View {
        Button {
            press()
        } label: {
            content
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.label)
                .frame(
                    width: PopopxLockLayout.keySide,
                    height: PopopxLockLayout.keySide
                )
                .background(PopopxPalette.card, in: Circle())
                .overlay(
                    Circle().strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
                )
                .contentShape(Circle())
        }
        // 按键反馈的唯一来源：按下即 `PopopxHaptics.impact(.light)` + 一次缩放
        //（`PopopxPressButtonStyle` 的 `makeBody` / `PopopxPressBody`），命中区由 `keySide`（≥ `minHitTarget`）保证。
        .buttonStyle(PopopxPressButtonStyle(feedback: .light))
        .accessibilityLabel(labelText)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case let .digit(value):
            Text(String(value))
        case .delete:
            Image(systemName: "delete.left")
                .imageScale(.large)
        case .biometric:
            // 图标跟设置页那一行用同一个（`PopopxAntiTheftSettingsView` 的 `faceid`）。
            // 管理器只给一个 `prefersBiometricUnlock` 布尔，没有把 `LAContext.biometryType`
            // 透出来，所以本层分不出面容还是指纹——只能沿用仓库已经选定那个字形，
            // 不自己再造一个"通用生物识别"图标，否则同一件事在两个页面上长得不一样。
            Image(systemName: "faceid")
                .imageScale(.large)
        }
    }

    private var labelText: String {
        switch kind {
        case let .digit(value): return String(value)
        case .delete: return PopopxLockCopy.delete
        case .biometric: return PopopxLockCopy.biometric
        }
    }

    private func press() {
        switch kind {
        case let .digit(value):
            model.tapDigit(value)
        case .delete:
            model.tapDelete()
        case .biometric:
            model.retryBiometrics()
        }
    }
}

// MARK: - 挂载

extension View {
    /// 挂在最顶层窗口容器上。锁着时盖住一切，没锁时不产生任何视图开销。
    ///
    /// **必须无条件挂**，不许在宿主外面再套一层 `if lock.coversContent`：
    /// `submit(pin:)` 在补时之前就 `unlock()` 了，宿主那一层 `if` 会在自毁还剩
    /// 几百毫秒时把遮罩整个摘掉（连带它的 `@State`），那一下就是穿帮。
    /// 完整理由见文件头"宿主接线契约"。
    func popopxAppLockOverlay() -> some View {
        overlay {
            PopopxAppLockOverlayView()
        }
    }
}
