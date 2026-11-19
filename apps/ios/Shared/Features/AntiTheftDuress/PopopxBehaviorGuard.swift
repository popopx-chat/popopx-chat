//
//  PopopxBehaviorGuard.swift
//  POPOPX (iOS)
//
//  【非本人操作 · 模块二】机主的握持姿态 + 机主的触摸手感 = 两条记忆；
//  当这两条记忆同时被打破，就把手机锁起来。
//
//  判据两条，**必须同时成立**才拉锁：
//  1. 握持倾角相对 EMA 基线**持续**偏移超过门限（默认 45°，设置页可调，存
//     `DEFAULT_ANTI_THEFT_ANGLE_LIMIT`）；
//  2. 同期出现高频不规则触摸（`UITouch.majorRadius` 相对机主本人异常偏大，或连续打在屏幕边缘）。
//  后果只有一个：`PopopxAppLockState.shared.lock(reason: .behavior)`
//  （`PopopxAntiTheftMotionGuard.swift:98-99` 把这个 case 的用途写成了"模块二"，本文件是它唯一的作者）。
//
//  ### 误判代价的边界：只能是"重新认证一次"，不能是"丢数据"
//  模块一头注（`PopopxAntiTheftMotionGuard.swift:13-19`）已经把分工写死：传感器判据只锁、绝不擦。
//  本文件严格遵守这条边界，并且**在调用图上根本不指向擦除**——全文件对模块三只有一句读调用
//  （`PopopxDuressAuthManager.shared.requestBiometricUnlock`，`PopopxDuressAuthManager.swift:2049`），
//  那条路自己也只通向"解锁"（成功时它已经 `unlock()`，见 `PopopxDuressAuthManager.swift:2067-2071`）。
//  行为判据比拽落/跌落更容易误报：拽落的误报需要一次 3g 冲击，而"姿势不对 + 手滑乱点"
//  在地铁上每天都能凑齐。所以本模块宁可把自己写得"只锁"——一次锁屏的代价是两秒钟，
//  一次误擦的代价是整个人的聊天记录，两者根本不在同一个数量级上，不值得交换。
//
//  ### EMA 基线为什么是 α=0.004（≈8.7 秒半衰期），而不是别的窗口
//  20Hz 沿用模块一同一档采样率（`PopopxMotionCriteria.sampleRateHz`，:328）。一阶低通的半衰期
//  是 `ln2 / α` 帧：α=0.004 → 173 帧 ≈ 8.7 秒。这个数是被两头夹出来的：
//  - 必须**明显慢于一次姿势变化**（人从坐到躺是 1–3 秒的事，约 20–60 帧）。若 α 取 0.05，
//    半衰期不到 0.7 秒，躺下的过程本身就把基线拖着走，偏差永远长不起来——判据自己吃掉自己。
//  - 必须**明显快于机主一天的习惯漂移**（手臂酸了慢慢换姿势，分钟级）。若 α 取 0.0002，
//    半衰期三分钟，机主自己会在半小时内被锁两次。
//  - 真正让这两头不矛盾的是**冻结条件**：偏差一旦超过 `0.6 × 门限`，基线停止学习
//    （`baselineFreezeFactor`）。小偷举着手机翻找的那几十秒里基线纹丝不动，
//    所以他永远学不成"新的机主"；而机主慢慢塌下去的那几度始终在冻结线以下，照样被学进去。
//
//  ### 为什么 45° 必须被"持续 6 秒"约束，光有角度一定会误锁
//  单看瞬时角度，横屏看视频、把手机竖起来贴耳朵、躺床上举着天花板，全都能在 1–2 秒内做出
//  >45° 的偏移，而这些都是最普通的用法——只用角度门限等于做一个"躺着就不能用"的功能。
//  加上"连续超过门限 ≥6 秒"之后：路过一次的姿势变化不够长；把手机抢过来翻看必然维持新姿势
//  几十秒以上，一定够。再叠加"触摸必须同时不正常"这一条（AND，不是 OR），
//  留下的误报窗口只有"用奇怪姿势稳定地盲打 6 秒以上"——那本来也是该问一次的情形。
//  反过来，角度够久但触摸正常，只升到 `.watching`（`evaluate` 里明写了这一档），不拦任何人。
//
//  ### 45 秒"稳定新姿势"自愈，以及它换来的代价（写清楚，不藏）
//  偏差很大但姿态本身很稳、且这 2 秒内没有任何异常触摸，连续 45 秒后把基线搬到当前姿态。
//  没有这一条，横屏看完一段视频之后，任何一次边缘误触都会立刻凑齐两个条件把人锁住——
//  那种功能用户会关掉，而关掉的功能安全性是零。代价要坦白：一个肯把手机在桌上稳放 45 秒
//  再动手的人，可以让基线跟着他的姿势走。但他跟着的只是**姿态**，触摸判据那条闸门一点没松，
//  而真正决定要不要拦人的是那条闸门；`authorizeSensitiveAction` 也只看 `suspicion`，
//  不看"基线是不是被谁搬过"。
//
//  ### 为什么用 `userAcceleration` 而不是原始加速度（和模块一恰好相反）
//  模块一量失重，必须用**含重力**的原始读数（`PopopxAntiTheftMotionGuard.swift:30-32` 解释了原因）。
//  本模块量"晃动"，要的是**减掉重力**的那一份：手机平放不动时原始合模长≈1g
//  （字段语义见 `PopopxAntiTheftMotionGuard.swift:298`），用原始值就会把"静止"读成"一直在晃"，判据反过来。
//  也正因为字段含义相反，这里**不复用** `PopopxMotionSample`：把 `userAcceleration` 塞进一个
//  文档写明"含重力"的 `g` 字段里，下一个读代码的人会按 1g 静置去理解它，那是个埋好的坑。
//  姿态角本身用 `gravity` 分量算（不含离心力，比 `attitude` 更稳，也不受航向漂移影响）。
//
//  ### 为什么另起一台 `CMMotionManager`
//  模块一那台（:531）已经占着 accelerometer + gyro 两路，而且它的 start/stop 跟着"锁定"走，
//  本文件的 start/stop 跟着"前台 + 锁定"走，时机不同。两件事塞进同一台机器上只会互相打断，
//  还要替对方操心副作用范围。两台实例各自 20Hz，合计仍远低于系统的功耗上限。
//
//  ### 为什么用 1Hz 心跳读锁状态，而不是让状态机叫我
//  `PopopxAppLockState` 是 `@Observable` 的，跨对象观察它要手写 `withObservationTracking` 递归
//  （等于在传感器类里塞一套 SwiftUI 的机制，而且重入时机不可控）。模块一走的是另一条路：
//  `lock`/`unlock` 里显式调 `PopopxAntiTheftMotionGuard.shared.lockedDidChange()`
//  （`PopopxAntiTheftMotionGuard.swift:174-176`、:186）。本模块同样需要"解锁沿"——那是重建
//  基线的唯一时机——但挂进那两个方法要改模块一，越界了。所以这里改成 1Hz 自轮询：
//  读一个 Bool 的成本低于一次触觉反馈，代价是解锁后最多 1 秒才开始重学，可以接受。
//
//  ### `.unavailable` 一律按"不放行"
//  上游的 `authorize()` 把 `.unavailable` 直接当认证成功（`LocalAuthenticationUtils.swift:24`），
//  那是为"设备解锁便利性"写的语义，本模块的在场核验不许继承它：生物识别不可用、被关掉、
//  或者已连续失败两次降级（`PopopxDuressAuthManager.swift:2052-2054`）时，一律 `completion(false)`
//  并且拉一次 `.manual` 锁（`PopopxAntiTheftMotionGuard.swift:104-105` 把"模块二的强制重认证"
//  明确划给了这个 case），让人从遮罩的键盘走——降级方向只能是更强的证明。
//  同理也不借用 `authenticate(reason:)`：它的 `.passcode` 分支把请求挂到
//  `ChatModel.shared.laRequest`（:47），那是"谁能进 app"的门，不是"此刻拿手机的是不是本人"的门。
//
//  ### 没有预览
//  本文件刻意不放 `#Preview` / `PreviewProvider`：新加预览会被 CI 的快照比对判失败，这是决定，不是遗漏。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import SwiftUI
import UIKit
import CoreMotion

// MARK: - 怀疑度

/// 本模块对"现在拿手机的是不是机主"的唯一结论。三段而不是一个 0–1 的分：
/// 分段器、徽章、宿主的门都要一个能一眼读懂的说法，而连续分数最后一定会被
/// 谁随手 `> 0.5` 这样切掉，切在哪儿还没人负责。
///
/// `label` 短到 2 个汉字是给 `PopopxSegmentedControl` 用的——那里只有 `.lineLimit(1)`
/// （`PopopxControls.swift:589`），长文案在小屏上会被省略号截成半句。
enum PopopxSuspicion: String, CaseIterable, Hashable, Sendable {
    case calm
    case watching
    case suspicious

    var label: String {
        switch self {
        case .calm: "正常"
        case .watching: "留意"
        case .suspicious: "可疑"
        }
    }

    var symbolName: String {
        switch self {
        case .calm: "checkmark.seal"
        case .watching: "eye"
        case .suspicious: "exclamationmark.shield"
        }
    }

    /// 只在本文件内部用来"取更严重的那一个"。不对外：对外暴露分数排序只会引来
    /// `rank >= 1` 这种绕过枚举的写法。
    private var rank: Int {
        switch self {
        case .calm: 0
        case .watching: 1
        case .suspicious: 2
        }
    }

    fileprivate func escalated(with other: PopopxSuspicion) -> PopopxSuspicion {
        other.rank > rank ? other : self
    }
}

// MARK: - 姿态读数

/// 握持姿态的两个分量，单位：度。
///
/// 本模块从不解释"绝对角度是多少度"，只量**与自己的基线差了多少**：CoreMotion 各分量在
/// 不同机型、不同 `CMAttitudeReferenceFrame` 下的正负号差异，因此不会传染到判据上。
struct PopopxAttitude: Hashable, Sendable {
    /// 绕 x 轴：前后仰。
    var pitchDegrees: Double
    /// 绕 y 轴：左右歪。
    var rollDegrees: Double

    static let zero = PopopxAttitude(pitchDegrees: 0, rollDegrees: 0)

    init(pitchDegrees: Double, rollDegrees: Double) {
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
    }

    init(radiansPitch: Double, radiansRoll: Double) {
        self.init(
            pitchDegrees: radiansPitch * 180 / Double.pi,
            rollDegrees: radiansRoll * 180 / Double.pi
        )
    }

    /// 与基线的偏差，度。两个分量各自绕回 (-180°, 180°] 再取欧氏长度：
    /// 握持是二维量，前后 32° + 左右 32° 合起来就是 45°，这比"任一分量超 45"更贴人的直觉，
    /// 也不会被单一分量的高频抖动带偏。
    func deviationDegrees(from other: PopopxAttitude) -> Double {
        let pitch = Self.wrappedDegrees(pitchDegrees - other.pitchDegrees)
        let roll = Self.wrappedDegrees(rollDegrees - other.rollDegrees)
        return sqrt(pitch * pitch + roll * roll)
    }

    /// 把角度差折进 (-180, 180]。不做这一步的话，从 +179° 到 -179° 会算出 358° 的"巨大变化"，
    /// 而它其实只转了 2°。
    static func wrappedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}

// MARK: - 一帧姿态偏差（内部诊断样本）

/// 只住在本文件里：给"持续了多少秒"提供可以倒着数的窗口。
private struct PopopxAngleSample {
    let at: Date
    let deviationDegrees: Double
}

// MARK: - 判据本体（非隔离、无副作用：真实流、演练、将来的单测共用同一段代码）

/// 常量和判定都放这里，理由与模块一相同（`PopopxAntiTheftMotionGuard.swift:37-40`）：
/// `@MainActor` 类的 `static let` 是主 actor 隔离的，非隔离的纯函数与演练入口引用不到。
enum PopopxBehaviorCriteria {
    // MARK: 门限

    /// 默认 45°。写在这里而不是散在设置页里，是为了让"读不到键"有一个唯一答案。
    static let defaultAngleLimitDegrees: Double = 45
    /// 滑块区间。低于 15° 时正常走路摆臂就能触发；高于 75° 时手机已被抢到手反向握着也不报。
    static let minimumAngleLimitDegrees: Double = 15
    static let maximumAngleLimitDegrees: Double = 75

    /// 偏移要连续多久才算"疑似"。见头注《为什么 45° 必须被"持续 6 秒"约束》。
    static let minimumSustainedSeconds: Double = 6

    /// 迟滞：回落但仍在此比例之上时不算断开，手一抖就把计时归零的话，
    /// 6 秒的持续条件永远凑不齐——那正好是本判据唯一不能犯的错（永不触发）。
    static let releaseFactor: Double = 0.85

    /// 基线冻结线：偏差超过 `门限 × 此比例` 后不再学习（头注《EMA 基线》第三条）。
    static let baselineFreezeFactor: Double = 0.6

    /// 升到 `.watching` 的"接近"比例。低于门限也先攒着证据，不给用户看任何东西。
    static let approachingFactor: Double = 0.6

    // MARK: 基线学习

    /// 姿态 EMA 系数。半衰期 = ln2 / α 帧 ≈ 173 帧 ≈ 8.7 秒（推导见头注）。
    static let baselineAlpha: Double = 0.004

    /// 触摸半径 EMA 系数。触摸是Hz 级的人类事件，取 0.25 表示"大约四次之前的手感还有一半权重"。
    static let radiusAlpha: Double = 0.25

    /// 自愈：偏差大、姿态稳、且这 2 秒内零异常触摸，连续这么多秒后把基线搬到当前姿态。
    static let relearnHoldSeconds: Double = 45
    /// "姿态稳"的判据：相邻两帧的偏差不再变化超过这个数。
    static let relearnDriftDegrees: Double = 2.0

    // MARK: 触摸动力学

    /// 不规则触摸的计数窗口。2 秒内 4 次 = 2Hz 的乱点，人手正常翻聊天不会这样。
    static let irregularTouchWindow: Double = 2
    static let minimumIrregularTouches: Int = 4
    /// 相对判据：比机主自己的指腹半径大这么多倍就算异常（戴手套、湿手会整体变大，所以要有基线）。
    static let radiusAnomalyFactor: Double = 1.6
    /// 绝对兜底：掌根、大腿、口袋内壁的读数能到 15pt 以上。纯相对判据在"基线本身被大半径污染"
    /// 时会失效，所以留一条不看基线的硬线。
    static let minimumRadiusAnomalyPoints: Double = 9.5
    /// 超过这个值的东西不当手指，不参与学习（耳机线、纸巾、屏幕贴膜翘边）。
    static let maximumPlausibleRadiusPoints: Double = 20

    // MARK: 晃动与离手（只提级到"留意"，永远不单独拉锁）

    /// `userAcceleration` 合模长超过此值算一次剧烈晃动。走路约 0.2g、跑步约 0.6g、
    /// 甩手拽包能到 2g，1.6 落在"有意晃动"这一侧。
    static let shakeG: Double = 1.6
    /// 合模长小于此值算静止（含手机平放桌面）。
    static let stillG: Double = 0.08
    /// 静止之后重新超过此值 = 又被拿起来，落手事件在这一刻成立。
    static let resumeG: Double = 0.35
    /// 静止且无人触碰屏幕多久算"短暂离手"。
    static let handOffStillSeconds: Double = 4
    /// 事件之后多长时间内至少保持"留意"。25 秒 ≈ 抢手机、解屏、开始翻这一串的合理时长。
    static let armHoldSeconds: Double = 25

    // MARK: 缓冲

    /// 倒着数持续时长的窗口。比 `minimumSustainedSeconds` 宽得多，但内存封顶（20Hz × 13 秒）。
    static let trendSeconds: Double = 13
    static let maxTrendSamples: Int = 260

    // MARK: 纯函数

    /// 把任意输入折进合法区间。NaN / 负数 / 被改坏的存档都从这一条路变成可用值，
    /// 而不是让 0 门限把功能变成"一直锁"。
    static func sanitize(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return defaultAngleLimitDegrees }
        return min(max(degrees, minimumAngleLimitDegrees), maximumAngleLimitDegrees)
    }

    /// 三轴合成模长。写成 `Double(...)` 是为了不依赖 SDK 把 CoreMotion 的字段声明成
    /// `Double` 还是 `Float`——两种情况下这个泛型初始化都存在。
    static func magnitude(_ acceleration: CMAcceleration) -> Double {
        let x = Double(acceleration.x)
        let y = Double(acceleration.y)
        let z = Double(acceleration.z)
        return sqrt(x * x + y * y + z * z)
    }

    /// 从最新一帧往回数"倾角连续超过门限"的秒数。
    ///
    /// 这是持续时长的**唯一**算法：真实流和演练共用它，所以不会出现"演练里会触发、
    /// 真机上不触发"。它只认均匀采样（20Hz，见 `PopopxMotionCriteria.sampleRateHz`），
    /// 调用方保证缓冲区里是连续帧——停采时缓冲区会被清空。
    /// 另外，从数组倒着数而不是自己累加，意味着"停帧"只会让时长不变或回落，绝不会凭空上涨。
    static func trailingSustainedSeconds(
        deviations: [Double],
        sampleInterval: Double,
        limit: Double
    ) -> Double {
        guard !deviations.isEmpty, sampleInterval > 0, limit > 0 else { return 0 }
        let release = limit * releaseFactor
        var cursor = deviations.count - 1
        var overLimitSamples = 0
        while cursor >= 0 {
            let value = deviations[cursor]
            if value > limit {
                overLimitSamples += 1
                cursor -= 1
                continue
            }
            // 落在迟滞带里：不算断，也不计入时长。
            if value > release {
                cursor -= 1
                continue
            }
            // 真的回落了（NaN 也走这条，坏样本只会让判据变保守）。
            break
        }
        return Double(overLimitSamples) * sampleInterval
    }

    /// 判定本体。三条输入全是标量，所以可以拿一段数字直接断言结论，零副作用。
    ///
    /// 单调性说明（给演练页解释结果用）：抬高 `angleLimit` 只会让结论变轻，
    /// 加长 `sustainedSeconds` 或 `irregularTouches` 只会让结论变重，不存在第三条路。
    static func evaluate(
        deviationDegrees: Double,
        sustainedSeconds: Double,
        irregularTouches: Int,
        angleLimit: Double
    ) -> PopopxSuspicion {
        guard deviationDegrees.isFinite, deviationDegrees > 0 else {
            // 没有角度证据。光有乱触最多"留意"：小孩玩游戏、口袋误触都不该被当成抢夺者。
            return irregularTouches >= minimumIrregularTouches ? .watching : .calm
        }
        let limit = sanitize(angleLimit)
        let noisy = irregularTouches >= minimumIrregularTouches
        let over = deviationDegrees > limit
        let sustained = over && sustainedSeconds >= minimumSustainedSeconds
        if sustained, noisy { return .suspicious }
        // 偏得够久但触摸正常：大概率是机主自己换了姿势，只观察，不拦人。
        if sustained { return .watching }
        if over || noisy || deviationDegrees >= limit * approachingFactor { return .watching }
        return .calm
    }
}

// MARK: - 行为监护器

@MainActor
@Observable
final class PopopxBehaviorGuard {
    static let shared = PopopxBehaviorGuard()

    /// 命中后的冷却。与 `PopopxAntiTheftMotionGuard.swift:487` 同值，是为了让
    /// "解锁之后 5 秒内不再拉锁"在全模块只有一口径。真正防"解锁—立刻又锁"的是
    /// `updateSampling()` 里那次基线重建，这里只是第二道保险。
    static let triggerCooldown: TimeInterval = 5

    // MARK: 对外状态

    /// 行为判据总开关。默认关闭，口径同模块一的 `DEFAULT_ANTI_THEFT_ENABLED`
    /// （`PopopxAntiTheftMotionGuard.swift:545`：读不到键就是 false）——
    /// 不像 `instantLockOnBackground`（:552-554）默认开：那条没有误判成本，这条有。
    ///
    /// ⚠️ `didSet` 会把值写回 UserDefaults，所以自毁清扫必须"先拨开关、再删键"
    /// （见 `PopopxDuressAuthManager.swift` 里的 `PopopxAntiTheftSwitches.eraseAllTraces()`，那里正是这么调本属性的）。
    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            UserDefaults.standard.set(enabled, forKey: DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED)
            sync()
        }
    }

    /// 设置页滑块的取值。越界输入会被夹回来（夹回来那一次重入 `didSet` 时两值相等，直接落盘）。
    var angleLimitDegrees: Double {
        didSet {
            let clamped = PopopxBehaviorCriteria.sanitize(angleLimitDegrees)
            if clamped != angleLimitDegrees {
                angleLimitDegrees = clamped
                return
            }
            guard oldValue != clamped else { return }
            UserDefaults.standard.set(clamped, forKey: DEFAULT_ANTI_THEFT_ANGLE_LIMIT)
            // 门限变了，之前那段"持续"是按旧尺子量的，不作数。
            resetDeviationRun()
        }
    }

    private(set) var suspicion: PopopxSuspicion = .calm
    private(set) var isBaselineCaptured = false
    /// 诊断读数：当前握持姿态 / 基线 / 两者之差。
    private(set) var currentAngle = PopopxAttitude.zero
    private(set) var baselineAngle = PopopxAttitude.zero
    private(set) var deviationDegrees: Double = 0
    /// 倾角已连续超过门限多久。0 表示"没在超"。
    private(set) var sustainedDeviationSeconds: Double = 0
    /// 当前 2 秒窗口里的不规则触摸数。
    private(set) var irregularTouchCount: Int = 0
    private(set) var isRunning = false
    /// 模拟器上 `isDeviceMotionAvailable == false`，设置页据此显示"本机不可用"，而不是假装在跑。
    private(set) var motionAvailable = false
    // 事件记录：模块二的两条辅助判据，只提级、不拉锁。
    private(set) var peakWobbleG: Double = 0
    private(set) var lastViolentShakeAt: Date?
    private(set) var lastHandOffAt: Date?
    private(set) var lastTriggerAt: Date?

    // MARK: 内部

    private let manager = CMMotionManager()
    private var trend: [PopopxAngleSample] = []
    private var irregularTouchMoments: [Date] = []
    /// 机主自己的指腹半径 EMA。0 = 还没学过。
    private var typicalRadius: Double = 0
    private var previousDeviation: Double = 0
    private var settledSeconds: Double = 0
    private var stillRunSeconds: Double = 0
    /// 已经静止够久、正在等"又被拿起来"这一动作来确认落手事件。
    private var setDownPending = false
    private var lastTouchAt = Date()
    private var lastSampleAt: Date?
    private var samplingActive = false
    /// 上一拍锁着没锁着。用来抓"由锁到不锁"那一沿——重建基线的唯一时机。
    private var wasLocked = false
    /// 前台标志。`scenePhase` 是 SwiftUI 侧的量，这个类不是 View，
    /// 所以用 `UIApplication.didBecomeActive/didEnterBackground` 两条通知实现同一条硬约束
    /// （照 `PopopxAntiTheftMotionGuard.swift:690-741` 的写法）。
    private var appIsActive = true
    private var heartbeat: Timer?
    private var observers: [NSObjectProtocol] = []
    /// 一次只许有一个认证弹窗。叠两次 Face ID 不是"更保险"，是让宿主拿到两个互相矛盾的回调。
    private var awaitingAuthorization = false

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED) == nil
            ? false
            : defaults.bool(forKey: DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED)
        angleLimitDegrees = PopopxBehaviorCriteria.sanitize(
            defaults.object(forKey: DEFAULT_ANTI_THEFT_ANGLE_LIMIT) == nil
                ? PopopxBehaviorCriteria.defaultAngleLimitDegrees
                : defaults.double(forKey: DEFAULT_ANTI_THEFT_ANGLE_LIMIT)
        )
        motionAvailable = manager.isDeviceMotionAvailable
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
        startHeartbeat()
        isRunning = true
        appIsActive = true
        updateSampling()
    }

    /// 停采 + 停表 + 摘通知。基线**不清**：退一次后台就该重新学握姿，
    /// 等于这个功能在每个 app 切换之后都失效几十秒。
    ///
    /// 锁状态本身不在这里改（模块一 :574-584 同理）：停表是因为不必再测，锁该继续锁。
    func stop() {
        // 关掉之后不许留着一道"看不见"的门：宿主的敏感动作核验必须回到放行状态。
        suspicion = .calm
        awaitingAuthorization = false
        guard isRunning else { return }
        stopSampling()
        heartbeat?.invalidate()
        heartbeat = nil
        removeObservers()
        resetDeviationRun()
        irregularTouchMoments.removeAll()
        irregularTouchCount = 0
        peakWobbleG = 0
        lastViolentShakeAt = nil
        lastHandOffAt = nil
        setDownPending = false
        stillRunSeconds = 0
        lastSampleAt = nil
        wasLocked = false
        isRunning = false
    }

    /// 忘掉关于机主的全部记忆（握姿基线 + 指腹手感），从下一帧重新学。
    ///
    /// 只允许在"本人刚刚证明过在场"的时刻调：设置页的按钮、解锁的那一沿、
    /// `authorizeSensitiveAction` 成功的那一次。它把 `suspicion` 清零，所以如果有人
    /// 在没被拦的情况下拿到手机，进设置页按这个键就能关掉判据——而进设置页正是被这道
    /// 判据守着的高危动作，链条在这里是闭合的。
    func resetBaseline() {
        isBaselineCaptured = false
        baselineAngle = .zero
        currentAngle = .zero
        typicalRadius = 0
        lastTouchAt = Date()
        resetDeviationRun()
        irregularTouchMoments.removeAll()
        irregularTouchCount = 0
        peakWobbleG = 0
        lastViolentShakeAt = nil
        lastHandOffAt = nil
        suspicion = .calm
    }

    // MARK: 触摸动力学入口

    /// `UITouch.majorRadius` 的喂入口。由 `PopopxTouchBeat`（模块一 :754——它在 `touchesBegan`
    /// 里既喂 `noteInteraction()`（:771），也逐指算出边缘占比后转交本模块（:788））
    /// 或宿主在自己的 `touchesBegan` 里调用。
    ///
    /// 本文件只消费参数，不改那个识别器：它的定位是"只观察、永不参与识别"，
    /// 往里加识别逻辑会把两个模块的生死绑在一起。
    ///
    /// - Parameters:
    ///   - majorRadius: 触点半径（点）。传 0 表示宿主拿不到这个值——此时只用边缘判据，
    ///     绝不因为"半径异常"误判，缺数据只可能让判据变松、不可能变紧。
    ///   - edge: 触点是否落在屏幕边缘带内（由宿主判定，本模块不知道视图尺寸）。
    func noteTouch(majorRadius: Double, edge: Bool) {
        guard enabled, isRunning, !PopopxAppLockState.shared.isLocked else { return }
        let now = Date()
        lastTouchAt = now
        let radius = majorRadius.isFinite ? max(0, majorRadius) : 0
        // 学"这根手指多大"：只学落在合理区间内的读数，掌根/大腿不进基线。
        if radius > 0, radius <= PopopxBehaviorCriteria.maximumPlausibleRadiusPoints {
            if typicalRadius > 0 {
                typicalRadius += PopopxBehaviorCriteria.radiusAlpha * (radius - typicalRadius)
            } else {
                typicalRadius = radius
            }
        }
        let oversized = radius > 0
            && radius > max(
                typicalRadius * PopopxBehaviorCriteria.radiusAnomalyFactor,
                PopopxBehaviorCriteria.minimumRadiusAnomalyPoints
            )
        if edge || oversized {
            irregularTouchMoments.append(now)
        }
        pruneTouchMoments(now: now)
        refreshSuspicion(now: now)
    }

    // MARK: 高危动作在场核验门

    /// 宿主在"进入设置页 / 导出密钥 / 查看绝密消息"之前调用。
    ///
    /// 只有 `.suspicious` 才拦；`.calm`、`.watching` 一律立刻放行——
    /// 一道需要思考要不要调用的门，最后一定被跳过，所以它必须几乎不添麻烦。
    /// `completion(true)` 只意味着"可以做了"，认证本身已经在这里做完（生物识别成功时
    /// 模块二顺手解掉了锁，见 `PopopxDuressAuthManager.swift:2067-2071`）。
    /// 返回 `false` 时宿主应当**什么都不做**：人已经落到遮罩上，会从键盘走一遍。
    func authorizeSensitiveAction(
        reason: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard enabled, suspicion == .suspicious else {
            completion(true)
            return
        }
        let state = PopopxAppLockState.shared
        // 已经锁着、或正在静默自毁：不要再叠一层认证。遮罩才是那道门，
        // 而 `duressSilentFlow` 期间任何额外弹窗都是当着胁迫者面喊"这密码不对劲"。
        guard !state.isLocked, !state.duressSilentFlow, !awaitingAuthorization else {
            completion(false)
            return
        }
        let auth = PopopxDuressAuthManager.shared
        // `.unavailable` 按不放行处理（见头注）。`prefersBiometricUnlock` 已经把
        // "关了生物识别 / 连续失败降级 / 没配常规码"三种情况都折进去了
        // （`PopopxDuressAuthManager.swift:1156-1161`）。
        guard auth.prefersBiometricUnlock, auth.biometricsAvailable else {
            denyAndLock()
            completion(false)
            return
        }
        awaitingAuthorization = true
        auth.requestBiometricUnlock(reason: reason) { granted in
            // 模块二两条 completion 路径都在主线程上：guard 那条在 `@MainActor` 方法里同步调，
            // 另一条包在 `Task { @MainActor in }` 里（`PopopxDuressAuthManager.swift:2057-2073`）。
            // `assumeIsolated` 只是把这件事告诉类型系统，不额外排队
            // （同模块一 `PopopxAntiTheftMotionGuard.swift:602-604`、`AudioRecPlay.swift:53`）。
            MainActor.assumeIsolated {
                self.awaitingAuthorization = false
                if granted {
                    // 本人已当面证明在场：怀疑清零，并按此刻的握姿重新学。
                    self.resetBaseline()
                } else {
                    self.denyAndLock()
                }
                completion(granted)
            }
        }
    }

    /// `authorizeSensitiveAction` 的 async 外形，给已经在 `async` 流程里的宿主用
    /// （`exportArchive()`、绝密卡片那两处）。语义与回调版**逐字相同**，包括"只有
    /// `.suspicious` 才拦"和"返回 false 时宿主什么都不做"——本方法只换外形，不加判断。
    func authorized(reason: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            authorizeSensitiveAction(reason: reason) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// 设置页"一键演练"的唯一入口。**只吃数字、只回结论**：不碰锁状态、不触发认证、
    /// 不通向任何擦除。判据本体在 `PopopxBehaviorCriteria.evaluate`，与真实流同一段代码。
    nonisolated static func evaluate(
        deviationDegrees: Double,
        sustainedSeconds: Double,
        irregularTouches: Int,
        angleLimit: Double
    ) -> PopopxSuspicion {
        PopopxBehaviorCriteria.evaluate(
            deviationDegrees: deviationDegrees,
            sustainedSeconds: sustainedSeconds,
            irregularTouches: irregularTouches,
            angleLimit: angleLimit
        )
    }

    // MARK: 采样开关

    /// 唯一的采样闸门：总开关开着、在跑、传感器可用、在前台、没被锁——五件事同时成立才真的采。
    /// 任一条件不成立立刻停采（零后台耗电，模块一 :35 的节能要求在这里同样成立）。
    private func updateSampling() {
        let state = PopopxAppLockState.shared
        let shouldSample = enabled
            && isRunning
            && motionAvailable
            && appIsActive
            && !state.isLocked
            && !state.duressSilentFlow
        if shouldSample {
            startSampling()
        } else {
            stopSampling()
        }
        if wasLocked, !state.isLocked {
            // 遮罩刚被解开 = 本人刚当面证明过一次身份。按此刻的握姿重建基线，
            // 否则"躺着解锁 → 6 秒后又锁"会把人逼到把功能关掉。
            resetBaseline()
        }
        wasLocked = state.isLocked
    }

    private func startSampling() {
        guard !samplingActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / PopopxMotionCriteria.sampleRateHz
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let motion = data else { return }
            // 回调已经在 `.main` 队列上，`assumeIsolated` 只是把这件事告诉类型系统。
            MainActor.assumeIsolated {
                self.receive(motion)
            }
        }
        samplingActive = true
    }

    private func stopSampling() {
        guard samplingActive else { return }
        manager.stopDeviceMotionUpdates()
        samplingActive = false
        trend.removeAll()
        lastSampleAt = nil
        // 停采期间的时长不能算进"持续偏移"，所以整个偏移状态一起归零。
        resetDeviationRun()
        settledSeconds = 0
        setDownPending = false
        stillRunSeconds = 0
    }

    // MARK: 每帧

    private func receive(_ motion: CMDeviceMotion) {
        let now = Date()
        let interval = min(max(lastSampleAt.map { now.timeIntervalSince($0) } ?? sampleInterval, 0), 0.5)
        lastSampleAt = now

        // 1) 触摸证据先过期，再参与本轮判定：陈旧的乱触不该拉锁。
        pruneTouchMoments(now: now)

        // 2) 剧烈晃动与短暂离手。两者都只提级到"留意"，永不单独拉锁，
        //    所以这里的门槛做得偏敏感是安全的。
        let wobble = PopopxBehaviorCriteria.magnitude(motion.userAcceleration)
        if wobble.isFinite {
            if wobble > peakWobbleG { peakWobbleG = wobble }
            if wobble >= PopopxBehaviorCriteria.shakeG {
                lastViolentShakeAt = now
                setDownPending = false
                stillRunSeconds = 0
            } else if wobble <= PopopxBehaviorCriteria.stillG {
                stillRunSeconds += interval
                if stillRunSeconds >= PopopxBehaviorCriteria.handOffStillSeconds,
                   now.timeIntervalSince(lastTouchAt) >= PopopxBehaviorCriteria.handOffStillSeconds {
                    setDownPending = true
                }
            } else {
                if setDownPending, wobble >= PopopxBehaviorCriteria.resumeG {
                    // 静置之后又动了：刚才那一段"手机不在手里"结束，现在拿着它的人需要多看看。
                    lastHandOffAt = now
                    setDownPending = false
                }
                stillRunSeconds = 0
            }
        }

        // 3) 握持姿态。用 `gravity` 而不是 `attitude`：前者直接来自加速度计，不受航向漂移影响。
        let gravity = motion.gravity
        let gx = Double(gravity.x)
        let gy = Double(gravity.y)
        let gz = Double(gravity.z)
        guard gx.isFinite, gy.isFinite, gz.isFinite else { return }
        // `atan2` 在全象限有界连续（手机竖直朝天时 gz→0 也不出 NaN），
        // 换成 asin 或在 gz 上除法就会在姿态奇点上炸出假的大偏差。
        let angle = PopopxAttitude(
            radiansPitch: atan2(-gy, gz),
            radiansRoll: atan2(gx, gz)
        )
        currentAngle = angle
        guard isBaselineCaptured else {
            // 第一帧只当种子。此刻一定还在前台且没锁，所以拿到手机的就是机主本人。
            baselineAngle = angle
            isBaselineCaptured = true
            previousDeviation = 0
            return
        }

        let limit = angleLimitDegrees
        let deviation = angle.deviationDegrees(from: baselineAngle)
        deviationDegrees = deviation

        // 4) 基线学习：只在"看起来还是本人"的小偏差区里慢慢跟（大偏差区冻结，见头注）。
        if deviation < limit * PopopxBehaviorCriteria.baselineFreezeFactor {
            baselineAngle = blended(
                from: baselineAngle,
                toward: angle,
                alpha: PopopxBehaviorCriteria.baselineAlpha
            )
        }

        // 5) 持续时长：从环形缓冲倒着数，唯一算法（见 `trailingSustainedSeconds`）。
        trend.append(PopopxAngleSample(at: now, deviationDegrees: deviation))
        pruneTrend(now: now)
        sustainedDeviationSeconds = PopopxBehaviorCriteria.trailingSustainedSeconds(
            deviations: trend.map(\.deviationDegrees),
            sampleInterval: sampleInterval,
            limit: limit
        )

        // 6) 45 秒"稳定新姿势"自愈（代价与理由见头注，写得很直白）。
        let steady = abs(deviation - previousDeviation) <= PopopxBehaviorCriteria.relearnDriftDegrees
        if deviation >= limit * PopopxBehaviorCriteria.baselineFreezeFactor,
           steady,
           irregularTouchCount == 0 {
            settledSeconds += interval
            if settledSeconds >= PopopxBehaviorCriteria.relearnHoldSeconds {
                baselineAngle = angle
                settledSeconds = 0
                sustainedDeviationSeconds = 0
            }
        } else {
            settledSeconds = 0
        }
        previousDeviation = deviation

        // 7) 结论，以及唯一允许的副作用。
        refreshSuspicion(now: now)
        guard suspicion == .suspicious else { return }
        let state = PopopxAppLockState.shared
        guard !state.isLocked, !state.duressSilentFlow else { return }
        if let at = lastTriggerAt, now.timeIntervalSince(at) < Self.triggerCooldown { return }
        lastTriggerAt = now
        // 传感器只锁。这里能调到的、以及本文件允许调到的，到此为止。
        state.lock(reason: .behavior)
        PopopxHaptics.notice(.warning)
        // 字符串必须是一条字面量：`os` 的 `debug` 重载走 `OSLogMessage`，
        // 中间出现 `+` 拼接就退化成 `StaticString?` 那次重载，编译不过。而 `debug` 的参数是
        // `@autoclosure`，所以插值里的属性必须写 `self.`（模块一 :660 没插值属性，碰不到这条）。
        // 日志里没有个人信息，只有三个数字——它们足够解释"刚才为什么锁了"。
        logger.debug(
            "behavior: locked, deviation \(Int(deviation)) over limit \(Int(limit)), \(self.irregularTouchCount) irregular touches"
        )
        stopSampling()
    }

    private var sampleInterval: Double {
        1.0 / PopopxMotionCriteria.sampleRateHz
    }

    /// 逐分量 EMA，差值先绕回 (-180, 180] 再加权：直接对角度做加权平均会在 ±180° 附近炸飞。
    private func blended(
        from base: PopopxAttitude,
        toward angle: PopopxAttitude,
        alpha: Double
    ) -> PopopxAttitude {
        let pitch = PopopxAttitude.wrappedDegrees(angle.pitchDegrees - base.pitchDegrees)
        let roll = PopopxAttitude.wrappedDegrees(angle.rollDegrees - base.rollDegrees)
        return PopopxAttitude(
            pitchDegrees: base.pitchDegrees + alpha * pitch,
            rollDegrees: base.rollDegrees + alpha * roll
        )
    }

    private func pruneTrend(now: Date) {
        let cutoff = now.addingTimeInterval(-PopopxBehaviorCriteria.trendSeconds)
        while let first = trend.first, first.at < cutoff || trend.count > PopopxBehaviorCriteria.maxTrendSamples {
            trend.removeFirst()
        }
    }

    private func pruneTouchMoments(now: Date) {
        let cutoff = now.addingTimeInterval(-PopopxBehaviorCriteria.irregularTouchWindow)
        while let first = irregularTouchMoments.first, first < cutoff {
            irregularTouchMoments.removeFirst()
        }
        irregularTouchCount = irregularTouchMoments.count
    }

    private func resetDeviationRun() {
        deviationDegrees = 0
        sustainedDeviationSeconds = 0
        previousDeviation = 0
        trend.removeAll()
    }

    /// 纯函数的结论 + 事件（晃动/离手）的提级。事件只往上抬，绝不往下压：
    /// 一次剧烈晃动不该让已经成立的角度判据变松。
    private func refreshSuspicion(now: Date) {
        let evaluated = Self.evaluate(
            deviationDegrees: deviationDegrees,
            sustainedSeconds: sustainedDeviationSeconds,
            irregularTouches: irregularTouchCount,
            angleLimit: angleLimitDegrees
        )
        var result = evaluated
        if armedByEvent(now: now) {
            result = result.escalated(with: .watching)
        }
        if result != suspicion { suspicion = result }
    }

    private func armedByEvent(now: Date) -> Bool {
        for date in [lastViolentShakeAt, lastHandOffAt] {
            if let date, now.timeIntervalSince(date) <= PopopxBehaviorCriteria.armHoldSeconds {
                return true
            }
        }
        return false
    }

    /// 拦下高危动作，并把人交给遮罩上的键盘。仍然是"只锁"：不碰任何数据。
    private func denyAndLock() {
        let state = PopopxAppLockState.shared
        guard !state.duressSilentFlow else { return }
        guard !state.isLocked else { return }
        // `.manual` 而不是 `.behavior`：模块一 :104-105 把"模块二的强制重认证"划给了它。
        state.lock(reason: .manual)
    }

    // MARK: 心跳

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.beat()
            }
        }
        // `.common` 模式：键盘弹出时主 runloop 在 eventTracking 模式，不跑普通定时器，
        // 而那正是最需要看住锁状态的时候（同模块一 :674-676）。
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// 1Hz 一拍。传感器停摆时（锁屏、掉帧、系统节流）由它保证证据会过期、状态会复位。
    private func beat() {
        updateSampling()
        guard enabled, isRunning, samplingActive else { return }
        let now = Date()
        pruneTouchMoments(now: now)
        pruneTrend(now: now)
        sustainedDeviationSeconds = PopopxBehaviorCriteria.trailingSustainedSeconds(
            deviations: trend.map(\.deviationDegrees),
            sampleInterval: sampleInterval,
            limit: angleLimitDegrees
        )
        refreshSuspicion(now: now)
    }

    // MARK: 通知（add 在 start、remove 在 stop，与模块一 :684-716 同一纪律）

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
        // 锁屏/来电也会走这一条：那时用户已经看不见界面，不该再攒触摸证据。
        let resign = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleDidEnterBackground()
            }
        }
        observers = [background, active, resign]
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    private func handleDidEnterBackground() {
        // 零后台耗电：无论锁没锁，离开前台立刻停采。
        appIsActive = false
        awaitingAuthorization = false
        updateSampling()
    }

    private func handleDidBecomeActive() {
        appIsActive = true
        updateSampling()
    }
}
