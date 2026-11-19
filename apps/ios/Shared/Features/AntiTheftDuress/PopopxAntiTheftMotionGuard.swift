//
//  PopopxAntiTheftMotionGuard.swift
//  POPOPX (iOS)
//
//  【物理防抢夺 · 模块一】抢夺/跌落判据、超时无操作自动锁屏、切后台瞬时锁定，
//  以及整个 AntiTheftDuress 模块共用的那一个锁状态机 `PopopxAppLockState`。
//
//  本文件之所以承载"锁状态"而不只承载传感器：判据来自三处（传感器、行为、超时），
//  界面在第四处（遮罩），设置页在第五处。若每个来源各自持有一份"是否锁定"，就必然出现
//  "一处解锁、另一处仍锁"的半锁状态——那是能被绕开的那种锁，也是本模块唯一不能犯的错。
//  所以锁状态只有一份，放在最先被依赖的文件里，其余各段只读它、只经由 `lock(reason:)` 写它。
//
//  ### 传感器只锁、绝不擦
//  抢夺/跌落/行为这三条判据的**唯一**后果是拉起锁屏。它们不触发任何擦除，也不通向
//  `PopopxDuressAuthManager` 的自毁。理由是纯工程而非保守：20Hz 的加速度判据在车上、
//  跑步、桌角磕碰、把手机扔进包里这些场景里都会误报，而误报的代价必须是可以承受的——
//  重新输一次密码可以承受，数据没了不能。全模块只有"胁迫密码被正确键入"这一条路通向擦除，
//  那需要胁迫者主动按键，不存在误触发；设置页的"一键演练"走的是 `PopopxMotionCriteria`
//  的纯函数 + 合成样本，类型上就返回不了任何副作用。
//
//  ### 与上游 POPOPX Lock 的分工（不是重复实现）
//  `ContentView` 已经有一套完整的 LA 门：`DEFAULT_PERFORM_LA` + `contentViewAccessAuthenticated`
//  + 后台 `DEFAULT_LA_LOCK_DELAY`（默认 30 秒）+ `SetAppPasscodeView`（见 ContentView.swift:77-83、
//  :123-156）。那套门管的是"谁可以进 app"。本模块管的是"物理上手机已不在我手里"，
//  判据来源不同、时机不同，且**只加一层，不改它一层**：我们不调用也不修改
//  `authorize()`——它对 `.unavailable` 直接放权（LocalAuthenticationUtils.swift:24），
//  那是为"设备解锁便利性"写的语义，安全遮罩不许继承。
//
//  ### 采样率、坐标系与能耗
//  20Hz（50ms 一帧）。$G$ 用**原始加速度计读数**（含重力），因为自由落体的特征恰恰是
//  "含重力的合模长趋近 0"；若用 `deviceMotion.userAcceleration`（已减掉重力），失重段会读成
//  约 1g，判据整个反过来。这是选择 `accelerometer` 而不是 `deviceMotion` 的唯一原因。
//  分析跑在 `.main` 队列：20Hz × 几次浮点运算不足以卡帧，而 `PopopxAppLockState` 是
//  `@MainActor` 的，换到专用 OperationQueue 之后仍要跳回主线程，只是多送一个竞态窗口。
//  锁起来之后立刻停采（模块四节能要求），退后台也停——本模块零后台采样、零后台电量。
//
//  ### 为什么判据常数住在 `PopopxMotionCriteria` 而不是本类的 `static let`
//  一个 `@MainActor` 类的 `static let` 是 main-actor 隔离的，非隔离的纯函数（演练入口、
//  将来的单元测试）引用不到它，只能整类拉到主线程才能测。把门限和判定一起放进一个 enum，
//  它们就天然是 nonisolated 的，判定函数可以拿一段样本数组直接断言结论。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import SwiftUI
import UIKit
import CoreMotion

// MARK: - 本模块的 UserDefaults 键

/// 键名口径跟仓库现状（裸 camelCase，无前缀，见 Shared/Views/UserSettings/SettingsView.swift:29-72
/// 的 `DEFAULT_*` 块——那是上游同名文件，不是本模块的 `PopopxAntiTheftSettingsView.swift`），
/// 但整套防盗键集中在**本文件**声明：一个模块的键散到宿主文件里，改名时就会漏掉一半。
let DEFAULT_ANTI_THEFT_ENABLED = "antiTheftEnabled"
let DEFAULT_ANTI_THEFT_SENSITIVITY = "antiTheftSensitivity"
let DEFAULT_ANTI_THEFT_INACTIVITY_SECONDS = "antiTheftInactivitySeconds"
let DEFAULT_ANTI_THEFT_INSTANT_BG_LOCK = "antiTheftInstantBackgroundLock"
/// 模块二（行为判据）用。
let DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED = "antiTheftBehaviorEnabled"
let DEFAULT_ANTI_THEFT_ANGLE_LIMIT = "antiTheftAngleLimitDegrees"
/// 模块三（双密码）用。
let DEFAULT_ANTI_THEFT_DURESS_ENABLED = "antiTheftDuressEnabled"
let DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED = "antiTheftBiometricsEnabled"
/// 第 10 次连续错误是否直接抹数据。默认关（键不存在时读出来就是 `false`），
/// 且必须由机主在设置页明确打开——这一格把"猜错十次"的代价从"锁一小时"换成"身份没了"。
/// 它**只**存这个 bool，不存任何凭据，但它是一条"这台设备开启过极端自毁"的指纹，
/// 所以和其余开关一样进下面那张清扫表。
let DEFAULT_ANTI_THEFT_TEN_STRIKE_WIPE = "antiTheftTenStrikeWipe"
/// 自毁后的重建模式（`.emptyProfile` / `.simulatedDecoy`）。
let DEFAULT_ANTI_THEFT_RETENTION_STRATEGY = "antiTheftRetentionStrategy"
/// 模块四（烟雾弹）用。
let DEFAULT_ANTI_THEFT_DECOY_ENABLED = "antiTheftDecoyEnabled"

/// 本模块**全部** UserDefaults 键，一个不漏。自毁路径靠这一张表清扫痕迹，
/// 所以新增键必须同时加进这里——散着写就会漏擦，而"漏擦的痕迹"正是本模块要消灭的东西。
let POPOPX_ANTI_THEFT_DEFAULT_KEYS: [String] = [
    DEFAULT_ANTI_THEFT_ENABLED,
    DEFAULT_ANTI_THEFT_SENSITIVITY,
    DEFAULT_ANTI_THEFT_INACTIVITY_SECONDS,
    DEFAULT_ANTI_THEFT_INSTANT_BG_LOCK,
    DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED,
    DEFAULT_ANTI_THEFT_ANGLE_LIMIT,
    DEFAULT_ANTI_THEFT_DURESS_ENABLED,
    DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED,
    DEFAULT_ANTI_THEFT_TEN_STRIKE_WIPE,
    DEFAULT_ANTI_THEFT_RETENTION_STRATEGY,
    DEFAULT_ANTI_THEFT_DECOY_ENABLED,
]

// MARK: - 锁原因

/// 锁是谁拉的。锁屏上那一行字、VoiceOver、以及"解锁后要不要再提示一次"都读它，
/// 所以它是一个封闭集合：加一个来源就是加一个 case，编译器会替我找出所有漏分支的地方。
enum PopopxLockReason: String, Hashable, Sendable, CaseIterable {
    /// 抢夺拽落：合加速度骤升 + 剧烈翻转。
    case snatch
    /// 自由落体后撞击。
    case freeFall
    /// 非本人操作的行为特征（模块二）。
    case behavior
    /// 超时未触碰屏幕。
    case inactivity
    /// 退过后台（`instantLockOnBackground`）。
    case background
    /// 用户手动，或模块二的强制重认证。
    case manual

    var userText: String {
        switch self {
        case .snatch: return "检测到剧烈拉扯，已锁定"
        case .freeFall: return "检测到跌落，已锁定"
        case .behavior: return "操作特征与平时不符，已锁定"
        case .inactivity: return "长时间无操作，已锁定"
        case .background: return "应用曾退入后台，已锁定"
        case .manual: return "已手动锁定"
        }
    }

    var symbolName: String {
        switch self {
        case .snatch: return "arrow.up.right.bold"
        case .freeFall: return "arrow.down.to.line.compact"
        case .behavior: return "hand.draw"
        case .inactivity: return "clock"
        case .background: return "moon.zzz"
        case .manual: return "lock"
        }
    }
}

// MARK: - 锁状态机（全模块唯一一份）

/// 锁的状态，以及"胁迫流程正在进行"这一格。
///
/// 这里有两个问题必须分开问，答错任何一个都是事故：
/// 1. **遮罩在不在屏幕上** —— 只要 `isLocked` 就在，包括静默自毁那 1.2 秒在内。
///    这是 `coversContent`。曾经把这两件事合成一个 `shielded = isLocked && !duress`，
///    于是"开始擦除"那一瞬间遮罩消失、内容直接暴露给站在旁边的人——正好是要防的那件事。
/// 2. **遮罩上显示什么** —— 平时是防盗文案加键盘；自毁进行中只许呼吸，
///    不许出现文案变化、报错或"正在销毁"。这是 `showsLockUI`。
///
/// 所以：盖内容用 `coversContent`，切界面内容用 `showsLockUI`，谁都不许自己拼条件。
@MainActor
@Observable
final class PopopxAppLockState {
    static let shared = PopopxAppLockState()

    private(set) var isLocked = false
    private(set) var reason: PopopxLockReason?
    private(set) var lockedAt: Date?

    /// 胁迫自毁进行中：界面照常呼吸，不许出现任何异常反馈。
    private(set) var duressSilentFlow = false

    /// 内容是否被盖住（以及是否要屏蔽截屏/录屏）。整个锁定期都是 true。
    /// 它的定义里**不能有 `duressSilentFlow`**，理由见类型注释。
    var coversContent: Bool { isLocked }

    /// 遮罩上是否显示"为什么锁了 + 键盘"。静默自毁期间为 false，此时只有呼吸动画。
    var showsLockUI: Bool { isLocked && !duressSilentFlow }

    /// 上一次交互的时刻。用 `Date` 而不是累计秒数，因为屏幕熄灭时定时器会被系统节流，
    /// 累计会低估真实空闲时长。
    private(set) var lastInteractionAt = Date()

    private init() {}

    /// 拉锁。已经锁着时幂等：传感器在 50ms 内会连送多个命中样本，
    /// 每次都改 `reason` 会让锁屏文案在两种说法之间跳。
    func lock(reason: PopopxLockReason) {
        guard !isLocked else { return }
        isLocked = true
        self.reason = reason
        lockedAt = Date()
        // 由状态机自己通知传感器停采，而不是指望某个宿主视图记得调：
        // 模块一要求"锁定后立即停止采样"，忘了这一步等于在锁屏后面继续跑 20Hz。
        PopopxAntiTheftMotionGuard.shared.lockedDidChange()
    }

    /// 解锁。只有认证模块（经遮罩）可以调它。
    func unlock() {
        isLocked = false
        reason = nil
        lockedAt = nil
        duressSilentFlow = false
        noteInteraction()
        PopopxAntiTheftMotionGuard.shared.lockedDidChange()
    }

    /// 一次真实触碰。触摸监听器和键盘都调它。
    func noteInteraction() {
        lastInteractionAt = Date()
    }

    /// 进入静默自毁流程。已在流程中时返回 false，调用方必须放弃这一次：
    /// 两次并发擦除会把"stop → close → delete → init → start"这个顺序打乱，
    /// 那条链不可重入。
    @discardableResult
    func beginDuressFlow() -> Bool {
        guard !duressSilentFlow else { return false }
        duressSilentFlow = true
        return true
    }

    func endDuressFlow() {
        duressSilentFlow = false
    }

    var idleSeconds: TimeInterval {
        Date().timeIntervalSince(lastInteractionAt)
    }
}

// MARK: - 档位

/// 判据灵敏度。`wireValue` 是存进 UserDefaults 的字符串，与 `rawValue` 恰好相同但职责不同：
/// `rawValue` 归本地存档，`wireValue` 归这套配置的对外口径，所以逐条写死而不是 `rawValue`。
enum PopopxMotionSensitivity: String, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high

    var wireValue: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    static func fromStored(_ raw: String?) -> PopopxMotionSensitivity {
        allCases.first { $0.wireValue == raw } ?? .medium
    }

    /// 分段器标签。`PopopxSegmentedControl` 只给一行（PopopxControls.swift:589 的
    /// `.lineLimit(1)`），长一点的中文在小屏上会被省略号截断。
    var label: String {
        switch self {
        case .low: return "较迟钝"
        case .medium: return "标准"
        case .high: return "较灵敏"
        }
    }

    /// 拽落峰值门限 $G$：较迟钝 3.8、标准 3.0、较灵敏 2.5。
    var spikeG: Double {
        switch self {
        case .low: return 3.8
        case .medium: return 3.0
        case .high: return 2.5
        }
    }

    /// 翻转角速度门限 $\omega$，rad/s。三档共用一个值：拽落时手腕会翻，走路摆臂不会，
    /// 这个量的区分度已经够用；跟着灵敏度一起缩只会把误报率一起放大。
    var spinOmega: Double {
        6.5
    }
}

/// 无操作自动锁屏的档位。`never` 的秒数是 0，存进 UserDefaults 也是 0，
/// 因此"永不"与"读不到键"必须靠 `object(forKey:) != nil` 区分——见下面的 getter。
enum PopopxInactivityTimeout: Int, CaseIterable, Hashable, Sendable {
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case never = 0

    var label: String {
        switch self {
        case .oneMinute: return "1 分钟"
        case .threeMinutes: return "3 分钟"
        case .fiveMinutes: return "5 分钟"
        case .fifteenMinutes: return "15 分钟"
        case .never: return "永不"
        }
    }

    var seconds: Int {
        rawValue
    }

    /// 默认 3 分钟。不拿 `never` 当默认：这个开关的意义是"离开手机一会儿自动收起来"，
    /// 默认关掉等于功能不存在。
    static let defaultValue: PopopxInactivityTimeout = .threeMinutes

    static func fromStored(seconds: Int?) -> PopopxInactivityTimeout {
        guard let seconds else { return defaultValue }
        return allCases.first { $0.rawValue == seconds } ?? defaultValue
    }
}

// MARK: - 样本与结论

/// 一帧观测量。时刻用 `Date`：真实样本与演练样本因此可以进同一个判定函数。
struct PopopxMotionSample: Hashable, Sendable {
    let at: Date
    /// 三轴合成加速度模长，单位 g，**含重力**。
    let g: Double
    /// 三轴角速度模长，单位 rad/s。
    let omega: Double
}

/// 一段样本的结论。
enum PopopxMotionVerdict: Hashable, Sendable {
    case none
    case snatch(g: Double, omega: Double)
    case freeFall(peakG: Double, weightlessMs: Double)

    var lockReason: PopopxLockReason? {
        switch self {
        case .none: return nil
        case .snatch: return .snatch
        case .freeFall: return .freeFall
        }
    }

    var isHit: Bool {
        if case .none = self { return false }
        return true
    }
}

// MARK: - 判据本体（非隔离、无副作用：真实流与演练共用同一段代码）

enum PopopxMotionCriteria {
    /// 采样率。20Hz = 50ms 一帧，够抓 120ms 的失重段（至少 2 帧），又不必上 100Hz 烧电。
    static let sampleRateHz: Double = 20

    /// 失重门限。静止时合模长≈1.0g，自由落体≈0g；0.25g 留出传感器零偏与轻微姿态抖动的
    /// 余量，又不至于把"轻轻放下"读成失重。
    static let weightlessG: Double = 0.25

    /// 失重要连续多久才算数。短于三帧（含首尾）一律不算。
    static let weightlessMinimum: TimeInterval = 0.120

    /// 失重段结束后，撞击必须在多久以内出现才算同一次跌落。
    static let impactWindow: TimeInterval = 0.600

    /// 撞击峰值门限。
    static let impactG: Double = 2.2

    /// 拽落需要"骤升"：相邻两帧合模长至少要涨这么多。只比绝对值的话，
    /// 把手机从桌上端起来那一下就到 2.5g 了。
    static let spikeRiseG: Double = 1.2

    /// 判定前的"平静"前提：命中帧往前数这段时间的平均合模长必须落在 0.85–1.20g，
    /// 也就是此前手机大致处于正常持握。车过减速带、跑步摆臂的平均加速度本来就远离 1g，
    /// 判据在这一步把它们挡掉。
    static let calmLookback: TimeInterval = 0.5
    static let calmLowerG: Double = 0.85
    static let calmUpperG: Double = 1.20

    /// 分析窗口。2 秒覆盖 120ms 失重 + 600ms 撞击窗 + 拽落所需的 0.5s 平静回看。
    static let analysisWindow: TimeInterval = 2.0
    static let maxWindowSamples: Int = 40

    /// 对一段样本做判定。跌落优先于拽落：手机正在落地时先按落地处理，
    /// 因为落地那一记冲击同时也满足拽落的"骤升"，两条判据在同一次事件里并不互斥。
    static func evaluate(
        samples: [PopopxMotionSample],
        sensitivity: PopopxMotionSensitivity
    ) -> PopopxMotionVerdict {
        guard samples.count >= 3 else { return .none }
        if let fall = freeFallVerdict(samples: samples) { return fall }
        return snatchVerdict(samples: samples, sensitivity: sensitivity)
    }

    private static func snatchVerdict(
        samples: [PopopxMotionSample],
        sensitivity: PopopxMotionSensitivity
    ) -> PopopxMotionVerdict {
        var index = samples.count - 1
        while index > 0 {
            let hit = samples[index]
            let previous = samples[index - 1]
            if hit.g > sensitivity.spikeG,
               hit.g - previous.g >= spikeRiseG,
               hit.omega > sensitivity.spinOmega,
               calmBefore(samples: samples, upTo: index) {
                return .snatch(g: hit.g, omega: hit.omega)
            }
            index -= 1
        }
        return .none
    }

    private static func freeFallVerdict(samples: [PopopxMotionSample]) -> PopopxMotionVerdict? {
        var index = 0
        while index < samples.count {
            guard samples[index].g < weightlessG else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < samples.count, samples[end + 1].g < weightlessG {
                end += 1
            }
            let weightless = samples[end].at.timeIntervalSince(samples[index].at)
            guard weightless >= weightlessMinimum else {
                index = end + 1
                continue
            }
            let limit = samples[end].at.addingTimeInterval(impactWindow)
            var cursor = end + 1
            while cursor < samples.count, samples[cursor].at <= limit {
                if samples[cursor].g > impactG {
                    return .freeFall(peakG: samples[cursor].g, weightlessMs: weightless * 1_000)
                }
                cursor += 1
            }
            index = end + 1
        }
        return nil
    }

    /// 命中帧之前的若干帧是否处于正常持握区间。
    private static func calmBefore(samples: [PopopxMotionSample], upTo index: Int) -> Bool {
        guard index > 0 else { return false }
        let from = samples[index].at.addingTimeInterval(-calmLookback)
        var total = 0.0
        var count = 0
        var cursor = index - 1
        while cursor >= 0, samples[cursor].at >= from {
            total += samples[cursor].g
            count += 1
            cursor -= 1
        }
        guard count >= 2 else { return false }
        let mean = total / Double(count)
        return mean >= calmLowerG && mean <= calmUpperG
    }

    /// 演练用：一段合成的拽落样本。
    static func syntheticSnatch(at start: Date = Date()) -> [PopopxMotionSample] {
        var samples: [PopopxMotionSample] = []
        for step in 0..<10 {
            samples.append(PopopxMotionSample(
                at: start.addingTimeInterval(Double(step) * 0.05),
                g: 1.0,
                omega: 0.4
            ))
        }
        samples.append(PopopxMotionSample(
            at: start.addingTimeInterval(0.50),
            g: 3.6,
            omega: 8.2
        ))
        return samples
    }

    /// 演练用：先 200ms 失重、再 3.1g 冲击的合成跌落样本。
    static func syntheticFreeFall(at start: Date = Date()) -> [PopopxMotionSample] {
        var samples: [PopopxMotionSample] = []
        for step in 0..<4 {
            samples.append(PopopxMotionSample(
                at: start.addingTimeInterval(Double(step) * 0.05),
                g: 0.98,
                omega: 0.2
            ))
        }
        for step in 0..<4 {
            samples.append(PopopxMotionSample(
                at: start.addingTimeInterval(0.20 + Double(step) * 0.05),
                g: 0.06,
                omega: 1.1
            ))
        }
        samples.append(PopopxMotionSample(
            at: start.addingTimeInterval(0.42),
            g: 3.1,
            omega: 5.4
        ))
        return samples
    }
}

// MARK: - 传感器监护器

@MainActor
@Observable
final class PopopxAntiTheftMotionGuard {
    static let shared = PopopxAntiTheftMotionGuard()

    /// 命中之后的冷却。锁已拉起、传感器也已停采，这个窗口的真正作用是防止同一次事件
    /// 在"解锁 → 立刻又命中"的循环里反复拉锁。
    static let triggerCooldown: TimeInterval = 5

    // MARK: 对外状态

    private(set) var isRunning = false
    private(set) var lastVerdict: PopopxMotionVerdict?
    /// 诊断读数：窗口内的峰值。设置页拿它解释"刚才那一下为什么没触发"。
    private(set) var peakG: Double = 0
    private(set) var peakOmega: Double = 0
    /// 本机传感器是否可用。模拟器上 `isAccelerometerAvailable == false`，
    /// 设置页据此显示"本机不可用"，而不是假装在跑。
    private(set) var motionAvailable = false

    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            UserDefaults.standard.set(enabled, forKey: DEFAULT_ANTI_THEFT_ENABLED)
            sync()
        }
    }

    var sensitivity: PopopxMotionSensitivity {
        didSet {
            guard oldValue != sensitivity else { return }
            UserDefaults.standard.set(sensitivity.wireValue, forKey: DEFAULT_ANTI_THEFT_SENSITIVITY)
        }
    }

    var inactivityTimeout: PopopxInactivityTimeout {
        didSet {
            guard oldValue != inactivityTimeout else { return }
            UserDefaults.standard.set(inactivityTimeout.seconds, forKey: DEFAULT_ANTI_THEFT_INACTIVITY_SECONDS)
        }
    }

    var instantLockOnBackground: Bool {
        didSet {
            guard oldValue != instantLockOnBackground else { return }
            UserDefaults.standard.set(instantLockOnBackground, forKey: DEFAULT_ANTI_THEFT_INSTANT_BG_LOCK)
        }
    }

    // MARK: 内部

    private let manager = CMMotionManager()
    private var window: [PopopxMotionSample] = []
    /// 两条流各自回调，把最近一次的角速度与当前这帧加速度配对：最大 50ms 错位，
    /// 相对 6.5 rad/s 的门限影响可以忽略，换来的是不必自己维护重采样。
    private var latestOmega: Double = 0
    private var lastTriggerAt: Date?
    private var inactivityTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// 后台事件到前台之后才拉锁：退进后台时用户已经看不见遮罩，
    /// 在后台改状态只会让回前台的第一帧闪一下内容。
    private var lockPendingOnActive = false

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: DEFAULT_ANTI_THEFT_ENABLED)
        sensitivity = PopopxMotionSensitivity.fromStored(defaults.string(forKey: DEFAULT_ANTI_THEFT_SENSITIVITY))
        inactivityTimeout = PopopxInactivityTimeout.fromStored(
            seconds: defaults.object(forKey: DEFAULT_ANTI_THEFT_INACTIVITY_SECONDS) == nil
                ? nil
                : defaults.integer(forKey: DEFAULT_ANTI_THEFT_INACTIVITY_SECONDS)
        )
        instantLockOnBackground = defaults.object(forKey: DEFAULT_ANTI_THEFT_INSTANT_BG_LOCK) == nil
            ? true
            : defaults.bool(forKey: DEFAULT_ANTI_THEFT_INSTANT_BG_LOCK)
        motionAvailable = manager.isAccelerometerAvailable && manager.isGyroAvailable
    }

    // MARK: 生命周期

    /// 由设置项决定开或停。幂等。
    func sync() {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard enabled, !isRunning else { return }
        guard motionAvailable else { return }
        installObserversIfNeeded()
        startSampling()
        startInactivityTimer()
        isRunning = true
    }

    /// 停采 + 停表 + 摘通知。锁状态本身不在这里改：停表是因为不必再测，锁该继续锁。
    func stop() {
        guard isRunning else { return }
        stopSampling()
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        removeObservers()
        window.removeAll()
        latestOmega = 0
        isRunning = false
    }

    /// 锁状态变了要告知传感器：模块一要求"锁定后立即停止采样"。
    func lockedDidChange() {
        guard enabled, isRunning else { return }
        if PopopxAppLockState.shared.isLocked {
            stopSampling()
        } else {
            startSampling()
        }
    }

    private func startSampling() {
        let interval = 1.0 / PopopxMotionCriteria.sampleRateHz
        manager.accelerometerUpdateInterval = interval
        manager.gyroUpdateInterval = interval
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let acceleration = data?.acceleration else { return }
            // 回调已经在 `.main` 队列上，`assumeIsolated` 只是把这件事告诉类型系统，
            // 不额外排队，因此 20Hz 的判定不会一帧一帧地往后推。
            MainActor.assumeIsolated {
                self.receive(acceleration)
            }
        }
        manager.startGyroUpdates(to: .main) { [weak self] data, _ in
            guard let self, let rate = data?.rotationRate else { return }
            let omega = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z)
            MainActor.assumeIsolated {
                self.latestOmega = omega
            }
        }
    }

    private func stopSampling() {
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
    }

    // MARK: 判据入口

    private func receive(_ acceleration: CMAcceleration) {
        let g = sqrt(
            acceleration.x * acceleration.x
                + acceleration.y * acceleration.y
                + acceleration.z * acceleration.z
        )
        // `CMMotionManager` 的 timestamp 是开机以来的秒，与 `Date` 无公共原点；这里用回调
        // 时刻作样本时刻。判定只看相邻样本的时间差，两套时钟不必互相换算。
        let sample = PopopxMotionSample(at: Date(), g: g, omega: latestOmega)
        append(sample)
        if g > peakG { peakG = g }
        if latestOmega > peakOmega { peakOmega = latestOmega }
        let state = PopopxAppLockState.shared
        guard !state.isLocked else { return }
        if let at = lastTriggerAt, Date().timeIntervalSince(at) < Self.triggerCooldown { return }

        let verdict = PopopxMotionCriteria.evaluate(samples: window, sensitivity: sensitivity)
        lastVerdict = verdict
        guard verdict.isHit else { return }
        lastTriggerAt = Date()
        trigger(verdict, state: state)
    }

    private func append(_ sample: PopopxMotionSample) {
        window.append(sample)
        let cutoff = sample.at.addingTimeInterval(-PopopxMotionCriteria.analysisWindow)
        while let first = window.first,
              first.at < cutoff || window.count > PopopxMotionCriteria.maxWindowSamples {
            window.removeFirst()
        }
    }

    private func trigger(_ verdict: PopopxMotionVerdict, state: PopopxAppLockState) {
        guard let reason = verdict.lockReason else { return }
        state.lock(reason: reason)
        PopopxHaptics.notice(.warning)
        logger.debug("anti-theft: locked by \(reason.rawValue)")
        stopSampling()
    }

    // MARK: 超时与后台

    private func startInactivityTimer() {
        inactivityTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.checkInactivity()
            }
        }
        // `.common` 模式：键盘弹出时主 runloop 处于 eventTracking 模式，不跑普通定时器，
        // 而那正是最需要拉锁的时刻。
        RunLoop.main.add(timer, forMode: .common)
        inactivityTimer = timer
    }

    private func checkInactivity() {
        guard enabled, inactivityTimeout != .never else { return }
        let state = PopopxAppLockState.shared
        guard !state.isLocked, !state.duressSilentFlow else { return }
        guard state.idleSeconds >= Double(inactivityTimeout.seconds) else { return }
        state.lock(reason: .inactivity)
        stopSampling()
        logger.debug("anti-theft: locked after \(Int(state.idleSeconds))s idle")
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleDidEnterBackground()
            }
        }
        let active = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleDidBecomeActive()
            }
        }
        observers = [background, active]
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    private func handleDidEnterBackground() {
        // 零后台耗电：无论是否开启瞬时锁定，进后台都停采。
        stopSampling()
        guard enabled, instantLockOnBackground else { return }
        lockPendingOnActive = true
    }

    private func handleDidBecomeActive() {
        if lockPendingOnActive {
            lockPendingOnActive = false
            let state = PopopxAppLockState.shared
            if !state.isLocked, !state.duressSilentFlow {
                state.lock(reason: .background)
            }
        }
        guard enabled, isRunning, !PopopxAppLockState.shared.isLocked, motionAvailable else { return }
        startSampling()
    }
}

// MARK: - 全局触摸节拍

/// 一个只观察、永不参与识别的手势识别器：给超时判据提供"用户还在碰屏幕"这一事实。
///
/// 为什么不用 SwiftUI 侧的方案：`.onTapGesture` 会吃掉点击，`DragGesture(minimumDistance: 0)`
/// 同样与列表滚动争抢；交换 `UIApplication.sendEvent` 是苹果明令禁止的手法。
/// 一个从不进入 `.began` 状态的识别器既拿得到 `touchesBegan`，又不会取消任何人的触摸。
///
/// 挂在 `SceneDelegate.windowStatic`（AppDelegate.swift:135-145 已有这个静态句柄）上，
/// 因此不需要新增 scene，也不需要动 project.pbxproj。
final class PopopxTouchBeat: UIGestureRecognizer {
    private static weak var installedIn: UIWindow?
    /// 边缘带判据：触点离屏幕中心的最长归一化分量。0.90 = 四边各 5% 的环带
    /// （390pt 宽 ≈ 每边 20pt，844pt 高 ≈ 每边 42pt）。
    /// 为什么不是更窄：抢夺时机主的手多半还握着边，太窄等于把模块二那一半判据关掉；
    /// 为什么不更宽：状态栏与 Home 指示条是正常人天天点的地方，那半边一旦误报，
    /// "姿态歪 + 边缘触摸"这两条就会在日常使用中自己凑齐。
    static let edgeBandThreshold: Double = 0.90
    /// 每喂这么多指就报一次边缘占比：只计数不打印，验收时才看得见读数。
    private static let telemetryEvery = 25
    private static var telemetryTouches = 0
    private static var telemetryEdgeTouches = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // 只记时刻、不改状态：状态保持 `.possible`，系统随后把它判为 `.failed`，
        // 期间没有任何视图因为这个识别器收不到触摸。
        PopopxAppLockState.shared.noteInteraction()
        // 逐指转交给模块二（倾斜 + 非常规触摸的组合判据）。它要的是 `UITouch.majorRadius`
        // 和"这一下是不是打在边上"，两者都只有这里拿得到：模块二不知道视图尺寸，
        // 也不该自己去读窗口。它内部第一行就 `guard enabled, isRunning`，
        // 所以关闭状态下这条循环只是几次浮点除法。
        guard let view = self.view else { return }
        let size = view.bounds.size
        let edgeReady = size.width > 0 && size.height > 0
        for touch in touches {
            let radius = Double(touch.majorRadius)
            var edge = false
            if edgeReady {
                let point = touch.location(in: view)
                let nx = abs(Double(point.x) / Double(size.width) - 0.5) * 2
                let ny = abs(Double(point.y) / Double(size.height) - 0.5) * 2
                edge = max(nx, ny) >= Self.edgeBandThreshold
            }
            PopopxBehaviorGuard.shared.noteTouch(majorRadius: radius, edge: edge)
            Self.telemetryTouches += 1
            if edge { Self.telemetryEdgeTouches += 1 }
            if Self.telemetryTouches >= Self.telemetryEvery {
                logger.debug(
                    "anti-theft touch telemetry: \(Self.telemetryEdgeTouches)/\(Self.telemetryTouches) in edge band"
                )
                Self.telemetryTouches = 0
                Self.telemetryEdgeTouches = 0
            }
        }
    }

    /// 幂等安装。窗口换了（例如分屏、重建）就重装一次。
    @MainActor
    static func install(in window: UIWindow?) {
        guard let window else { return }
        if let existing = window.gestureRecognizers?.first(where: { $0 is PopopxTouchBeat }) {
            window.removeGestureRecognizer(existing)
        }
        let beat = PopopxTouchBeat(target: nil, action: nil)
        beat.cancelsTouchesInView = false
        beat.delaysTouchesBegan = false
        beat.delaysTouchesEnded = false
        window.addGestureRecognizer(beat)
        installedIn = window
    }
}
