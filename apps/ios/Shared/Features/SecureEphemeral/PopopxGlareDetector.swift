//
//  PopopxGlareDetector.swift
//  POPOPX (iOS)
//
//  【绝密阅后即焚 · 模块二】纯数学的镜头反光热点检测。有人拿第二台手机对着屏幕拍的时候，前置镜头
//  里那块镜头玻璃会返出一个极小、极亮、边界很圆的高光斑（specular hotspot）——本文件只认这一个物理
//  现象，全部算术走 Accelerate 的整数图像算子：零模型、零权重、零包体增量，CoreML 那条链路不在的时候
//  它是唯一还在工作的视觉检测，所以必须能独立跑，不依赖 `PopopxCameraGuardEngine` 里的任何符号。
//
//  ### 九个数字的物理理由（默认值就是 `PopopxGlareConfiguration.default`）
//  - `lumaThreshold = 245`：镜头反光打在 sensor 上是削顶的，真正的高光只落在 245~255 这一小段；
//    240 以下不过是"房间里有盏灯"。判定作用在**全量程** Y 上（视频量程先线性换算，见下面第 3 条）。
//  - `minimumAreaFraction = 0.0005`（0.05%，640x480 上约 15 px）：比这更小的亮点是热像素、坏点、
//    JPEG/HEVC 压缩噪声。它们的特征是**帧间会跳位置**，而反光是跟着手机走的稳态。
//  - `maximumAreaFraction = 0.035`（3.5%，640x480 上约 1075 px）：比这更大的过曝区是灯、窗、整屏过曝，
//    那是曝光问题不是有人在拍屏。这一档宁可漏报：误报会**销毁一条读了一半的绝密消息**，代价不对称。
//  - `minimumCircularity = 0.72`：圆形度 C = 4πA/P²，P 取**轮廓链长**（8 邻接：正交步算 1、斜步算 √2）。
//    合成帧实测：圆盘 0.91~1.00，3:1 的短粗条 0.51，85:1 的长条 0.15，锯齿块 0.07，方块 0.72~0.78。
//    老实说一句：这一档分得开"细长/锯齿"和"圆"，**分不开方块和圆盘**——它挡的是门缝漏光、传感器坏点列
//    那类拉长的形状，不是几何识别，别把它当成"认出圆形"来宣传。
//  - 面积比例按**整帧**面积算，但连通域在网格上跑，所以真正生效的下限是网格：640x480 上步长 7，
//    实测 ⌀14 px 及更小的亮盘一律报不出来（连"过半"那一格都填不满），⌀18 px 起才报。`minimumAreaFraction`
//    那道 0.05% 的门在 640x480 上等于摆设。要更小的可检尺寸就调 `maximumEdgeLength`，代价是连通域变慢。
//  - `consecutiveFramesToFire = 2`：单帧亮点可能是任何人转身、窗外车灯扫过。10fps 下两帧约 200ms，
//    正好是"举着手机对准屏幕"和"一晃而过"的分界。
//  - `meanLumaSurgeDelta = 40`：整帧均值一帧之内跳 40/255（约 16%）。这是闪光灯的**必要条件**，
//    不是充分条件——单靠这一条会误删消息，所以它必须和下面两个数字一起成立才算一次跃升。
//  - `surgeMinimumSaturation = 0.05`：同一帧还得有 ≥5% 的像素被 `lumaThreshold` 那条线顶到削顶。
//    这一条才是判别力所在：房间变亮、对着白墙，均值上得去但 245 那一段上不去（自动曝光会压回来），
//    闪光灯与激光对焦补光是直接烧穿一大片。它不要钱——和均值出自同一次直方图扫描。
//  - `surgeWarmupFrames = 10`：10fps 下起手 1 秒不判跃升。`AVCaptureSession` 跑起来之后曝光和白平衡
//    是**阶梯式**收敛的（不是一条平滑斜坡），头几帧里出现 40 点的均值台阶属于相机自己的动作。
//    一帧被 `refuse` 掉也会重新走这段闸门：`reset()` 把计数和均值基线一起清掉。
//  - `maximumEdgeLength = 96`：连通域只在降采样后的网格上跑（长边 ≤96，即 ≤9216 格）。640x480 上步长
//    取 7 → 网格 92x69。全帧只被 vImage 整数算子扫（直方图一遍、LUT 一遍、box 均值一遍），
//    Swift 循环只碰网格和 256 格直方图，不碰像素。
//
//  ### 与提示词点名 API 的一处**必要**偏离（不是风格选择，是这颗 SDK 里没有）
//  要求里点名 `vImageThreshold_LinearUp_Planar8` + `vImage_ConvertFromRawBuffer`（以及"整数均值降采样"）。
//  本机 SDK（macOS / iOS 27.2）的 vImage 头文件里已经没有 Threshold 族、`vImageReduceBy*`、
//  `vImage_Statistics_*`、`vImageAdd_*`、`vImage_ConvertFromRawBuffer` 了——`swiftc -typecheck` 直接报
//  "cannot find 'vImage_Threshold_LinearUp_Planar8' in scope"（实测，不是推测）。换成语义完全等价的
//  三件套，同样是纯 vImage、同样零模型：
//  - 二值化 → `vImageTableLookUp_Planar8`：256 项 LUT 写成"下标 > lumaThreshold 出 255，否则出 0"，
//    与 `Threshold_LinearUp` 逐像素等价，而且**不改源平面**（Threshold 族是原地写的，会动采集缓冲）。
//  - 降采样 → `vImageBoxConvolve_Planar8`：核尺寸 = 步长（必须奇数），它算的就是
//    `sum = (Σ + area/2) / area`——正是要求里的"整数均值"；边缘用 `kvImageEdgeExtend`。
//  - 帧均值 → `vImageHistogramCalculation_Planar8`：均值 = Σ(i·h[i]) / 像素数，256 次标量乘加，
//    顺带白拿"过曝像素数"，不需要第二趟全帧扫描。
//
//  ### 三个格式，其余一律判死（不猜）
//  `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` / `…FullRange` 直接取 Y 平面；
//  `kCVPixelFormatType_32BGRA` 用 BT.601 系数一次算出 Y。其它格式（含 422/444、10 bit、depth）
//  一律返回 `.clear` 并把原因留在 `lastSkipReason` 里——按未压缩字节偏移去猜一个"大概是亮度"的平面，
//  得到的是看起来能跑、实际上永远不报的引擎，那比明着不支持更坏。
//  视频量程的 Y 顶到 235，`245` 这条线在原始值上**永远点不亮**，所以二值化 cutoff 与上报均值都要
//  按 (v-16)·255/219 换算；不换算的话整条 hotspot 规则会在最常见的相机输出上静默失效。
//
//  ### 线程约定（本文件不加锁，理由写在这里）
//  这个类不是 actor，也没有 `NSLock`/`os_unfair_lock`。一次检测要跨"直方图 → LUT → box 均值 → 采样 →
//  连通域"复用同一批按帧尺寸预分配的缓冲，加锁挡不住真正的坏事情：两帧交错会拼出一张**由两帧各出一半
//  的掩码**，那种图上的"连续两帧"是假的。约定是：**调用方必须在同一条串行队列
//  （`com.popopx.vision.guard`）上创建并使用本实例**，不在其它队列并发访问，也不跨队列读
//  `lastSkipReason`。`PopopxCameraGuardEngine` 的 capture 回调本来就投递在那条队列上。
//
//  ### 闩锁（latching）行为 —— 报一次就够
//  `.glare` 只在**规则刚被满足**的那一刻返回一次：
//  光斑第 1 帧 → `.clear`；第 2 帧 → `.glare(.hotspot)`；第 3、4 帧光斑还在 → `.clear`（已闩锁，不刷屏
//  发回执）；中间来一帧"没有合格光斑且没有均值跃升"的证据 → 连续帧计数归零、闩锁解除；光斑再回来
//  都要重新攒满 `consecutiveFramesToFire` 帧。`reset()` 同样把这段历史清空——弹窗每次重新打开、
//  每次换一条绝密消息都**必须**调它，否则上一轮留下的闩锁会吃掉这一轮的第一次告警。
//  注意"已闩锁时返回 `.clear`"不等于"这一帧画面干净"，只代表这一轮已经报过；要区分两者请读
//  `lastSkipReason`（那是"读不到"）与证据本身（那是"读到了什么"）。
//
//  ### 实测成本（不是形容词，且可复现）
//  同一份本文件在 macOS 宿主上（`xcrun -sdk macosx swiftc -O`，arm64）跑合成帧：640x480 全量程双平面，
//  200 帧交替喂"⌀30 亮盘帧"和"均匀帧"（前者才走连通域与周长折线），`clock_gettime_nsec_np(CLOCK_MONOTONIC)`
//  逐帧计时：**mean 0.475 ms，p50 0.550 ms，p99 0.767 ms，max 1.15 ms**（本机实测于 2026-11-19）。
//  10fps 帧间隔 100 ms，占用约 0.5%。换一台机器数字会变，量级和"哪个分支贵"不会。
//  同一套合成帧还用来验规则本身（六条：变亮不削顶不报 / 削顶跃升报 / 闸门内不报 / 圆盘连续两帧报 /
//  单帧圆盘不报 / 闩锁只报一次）。这份试验台**没有进仓库**——它不属于任何 target，进仓库就是孤儿；
//  要复现，把本文件与 `PopopxSecurePayload.swift` 连同上面那段描述的四行帧生成代码一起编译即可。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import Accelerate
import CoreVideo
import Foundation

// MARK: - 配置

/// 检测器的全部可调项。越界的值不会崩，进 `init` 时被夹住（夹完仍不合法的组合只会导致永不触发，
/// 不会误触发）。
struct PopopxGlareConfiguration: Hashable, Sendable {
    /// 过曝判定线，作用在**全量程** Y 上（视频量程会先换算）。
    var lumaThreshold: Int32
    /// 光斑面积下限，占整帧面积的比例。
    var minimumAreaFraction: Double
    /// 光斑面积上限，占整帧面积的比例。
    var maximumAreaFraction: Double
    /// 圆形度下限，C = 4πA / P²。
    var minimumCircularity: Double
    /// 连续多少帧出现合格光斑才报。
    var consecutiveFramesToFire: Int
    /// 整帧均值相对上一帧的跃升阈值（0...255 单位）。
    ///
    /// 它**不单独成立**：一条只有"跳了 40 点"的销毁规则，会被把手机从大腿上拿起来这个动作触发。
    /// 闪光灯的特征是"跳"而且"削顶"，所以判定要和 `surgeMinimumSaturation` 同时成立。
    var meanLumaSurgeDelta: Double
    /// 跃升之外还要求的**过曝比例**：同一帧里被 `lumaThreshold` 那条线点亮的像素占整帧的比例。
    /// 这是把"有人在闪光/补光"和"画面整体变亮"分开的唯一一道免费证据（同一个直方图里就能数出来）。
    var surgeMinimumSaturation: Double
    /// 前多少帧**不参与**跃升判定。相机起手要收敛曝光和白平衡，头一秒内的均值台阶是它自己造成的。
    var surgeWarmupFrames: Int
    /// 连通域网格的长边上限。
    var maximumEdgeLength: Int

    static let `default` = PopopxGlareConfiguration(
        lumaThreshold: 245,
        minimumAreaFraction: 0.0005,
        maximumAreaFraction: 0.035,
        minimumCircularity: 0.72,
        consecutiveFramesToFire: 2,
        meanLumaSurgeDelta: 40,
        surgeMinimumSaturation: 0.05,
        surgeWarmupFrames: 10,
        maximumEdgeLength: 96
    )
}

// MARK: - 证据与结论

/// 一条结论是靠哪个规则说出来的。两条规则的处置完全一样（销毁 + 回执），分开只是为了日志可读、
/// 以及调阈值时知道自己在动哪一条。
enum PopopxGlareReason: String, Hashable, Sendable {
    /// 连续帧的圆形过曝光斑——对着屏幕的那台手机的镜头。
    case hotspot
    /// 整帧均值一帧内跃升，**且**同帧有足够大面积削顶——闪光灯或激光对焦补光。
    case lumaSurge
}

/// 判定时那一帧的量化证据。字段全是**这一帧**的测量值，不是一段窗口的平均，
/// 这样回执出问题时能对着原始帧复核。
struct PopopxGlareEvidence: Hashable, Sendable {
    var reason: PopopxGlareReason
    /// 通过面积窗 + 圆形度两道的斑点个数。`.lumaSurge` 时这个数可以是 0（闪光灯整帧过曝，
    /// 没有斑点能过面积上限那一道）。
    var hotspotCount: Int
    /// 合格斑点里最大的那个占整帧面积的比例，0...1。没有合格斑点时是 0。
    var largestAreaFraction: Double
    /// 合格斑点里最好的圆形度，钳在 0...1（数字形状的面积/周长估计会略微超过 1）。
    var bestCircularity: Double
    /// 当前帧的全量程均值亮度，0...255。
    var meanLuma: Double
    /// 这一帧被 `lumaThreshold` 那条线点亮的像素占整帧的比例，0...1。它和 `meanLuma` 出自同一次
    /// 直方图扫描。留着它是为了事后能复核：跃升那一条规则要求它一起成立，误报查案时第一眼要看的就是它。
    var saturatedFraction: Double
    /// 上一帧的均值亮度。第一帧没有上一帧，是 nil——**不是** 0，0 会让第一帧看起来像一次巨大跃升。
    var previousMeanLuma: Double?
    /// 这一帧被判定的时刻。取的是处理时刻，不是采集时刻：调用方要的是"我们什么时候看见的"。
    var sampledAt: Date
}

/// 一帧的结论。
enum PopopxGlareVerdict: Hashable, Sendable {
    case clear
    case glare(PopopxGlareEvidence)

    /// 有没有触发。`guard case .glare` 写多了会漏掉未来新增的 case，这里收口。
    var isGlare: Bool {
        if case .glare = self { return true }
        return false
    }

    /// 交给检测引擎上报的告警。两条规则都落在 `.lensGlareDetected` 这一格：
    /// `PopopxSecurityAlert` 里只有这一格是"视觉高光"语义，均值跃升**不能**借用
    /// `.recordingDevice(_:)`——那个 case 携带一个 CoreML 认出的物体，兜底引擎没有物体可带，
    /// 硬凑一个就是在伪造模型结论。
    var securityAlert: PopopxSecurityAlert? {
        switch self {
        case .clear: return nil
        case .glare: return .lensGlareDetected
        }
    }
}

/// 这一帧**没被检测**的原因。它和 `.clear` 是两件事：`.clear` 是"看了，画面干净"，
/// 这里是"看不了"。留在 `PopopxGlareDetector.lastSkipReason` 上让降级可观测，
/// 而不是只在注释里自称诚实。
enum PopopxGlareSkipReason: String, Hashable, Sendable {
    /// 像素格式不在支持名单里。
    case unsupportedPixelFormat
    /// 锁不住基址，或锁住了却拿不到平面指针。
    case baseAddressUnavailable
    /// 宽高退化（0 或 1），网格无从谈起。
    case emptyFrame
    /// vImage/内存准备失败（缓冲分配不了、算子返回错误、box 核临时缓冲尺寸非法）。
    case accelerationFailed
}

// MARK: - 检测器

/// 纯算术的镜头反光热点检测器。
///
/// **不是线程安全的**，也不试图是：全部内部状态（均值基线、连续帧计数、闩锁、按帧尺寸预分配的缓冲）
/// 只允许在一条串行队列上被碰，理由见文件头的"线程约定"。
final class PopopxGlareDetector {
    // MARK: 对外表面

    /// 生效中的配置（已夹过界）。想换阈值就换一个实例：`configuration` 是 `let`，
    /// 因为半路改阈值会让已经攒了一半的连续帧计数对应到另一套判据上。
    var configuration: PopopxGlareConfiguration { settings }

    /// 最近一次"这一帧没被检测"的原因；成功检测一帧后回 nil。
    private(set) var lastSkipReason: PopopxGlareSkipReason?

    // MARK: 生效值与预编译表

    private let settings: PopopxGlareConfiguration
    /// 全量程二值化 LUT：下标 > threshold 出 255。
    private let fullRangeBinarisation: [UInt8]
    /// 视频量程二值化 LUT：先把 (v-16)·255/219 的判定线折回原始值。
    private let videoRangeBinarisation: [UInt8]
    /// BT.601 luma 权重，按 `kCVPixelFormatType_32BGRA` 的**物理字节序** B,G,R,A 排。
    /// 权重和 29+150+77 = 256，配 divisor 256 / post_bias 128 做四舍五入：纯白 → 255（不会被取整
    /// 抽到 245 以下），纯红 → 77，纯绿 → 150，纯蓝 → 29。这条字节序是**实测**出来的（合成 BGRA 帧），
    /// 不是照抄文档里 "ARGB" 那个容易误导的函数名。
    private let bgraLumaMatrix: [Int16] = [29, 150, 77, 0]

    // MARK: 帧尺寸派生量（只在尺寸变化时重算）

    private var frameWidth = 0
    private var frameHeight = 0
    private var stride = 1
    private var kernelSize = 1
    private var gridWidth = 0
    private var gridHeight = 0
    private var cellCount = 0

    // MARK: 缓冲（每帧复用，尺寸变化才重新分配）

    /// 二值化后的整帧掩码（紧凑 rowBytes = 宽）。
    private let maskPlane = PopopxBytePlane()
    /// box 均值后的整帧图（同上，与掩码**不能**同一块：box 卷积不支持原地）。
    private let smoothedPlane = PopopxBytePlane()
    /// 交织格式算出来的 Y 平面。双平面格式用不到它。
    private let lumaPlane = PopopxBytePlane()
    /// vImage box 卷积的工作区，尺寸按算子的问法要。
    private let convolutionScratch = PopopxBytePlane()
    private var grid: [UInt8] = []
    private var labels: [Int32] = []
    /// 边界格标记（1 = 这一格是自己周长折线的一部分）。每帧先清零再标，O(格数) 一次覆写。
    private var boundaryCells: [UInt8] = []
    private var unionParent: [Int32] = []
    private var blobArea: [Int32] = []
    /// 周长累加，单位千分之一格边长（见 `orthogonalStep`）。
    private var blobPerimeter: [Int32] = []
    private var histogram: [vImagePixelCount] = [vImagePixelCount](repeating: 0, count: 256)

    // MARK: 帧间历史

    private var previousMeanLumaValue: Double?
    private var hotspotStreak = 0
    private var episodeReported = false
    /// 已经**成功分析过**的帧数（被 `refuse` 掉的那些帧不计：它们没给出亮度）。只用来喂
    /// `surgeWarmupFrames` 那一道闸门。
    private var analyzedFrames = 0

    // MARK: 生命周期

    init(configuration: PopopxGlareConfiguration = .default) {
        var sanitized = configuration
        sanitized.lumaThreshold = min(max(configuration.lumaThreshold, 0), 255)
        sanitized.consecutiveFramesToFire = max(1, configuration.consecutiveFramesToFire)
        // 网格太小会把光斑平均成一片糊；8 是"连 1x1  speck 都还没被抹掉"的下限。
        sanitized.maximumEdgeLength = max(8, configuration.maximumEdgeLength)
        sanitized.minimumAreaFraction = min(max(configuration.minimumAreaFraction, 0), 1)
        sanitized.maximumAreaFraction = min(max(configuration.maximumAreaFraction, 0), 1)
        sanitized.minimumCircularity = min(max(configuration.minimumCircularity, 0), 1)
        sanitized.meanLumaSurgeDelta = max(0, configuration.meanLumaSurgeDelta)
        sanitized.surgeMinimumSaturation = min(max(configuration.surgeMinimumSaturation, 0), 1)
        // 0 = 允许第一帧之后就判跃升。那是最危险的一种配置（AE 还没收敛就在数台阶），所以下限留 1，
        // 至少要求见过一帧基线；默认值是 10 帧。
        sanitized.surgeWarmupFrames = max(1, configuration.surgeWarmupFrames)
        settings = sanitized

        // "Luma > threshold" 折成 LUT 下标就是 threshold + 1 起全 255。
        fullRangeBinarisation = PopopxGlareDetector.binarisationTable(cutoff: Int(sanitized.lumaThreshold) + 1)
        // 视频量程：全量程值 f 对应原始值 v = 16 + f·219/255，所以判定线折回 v 再取整。
        let videoCutoff = Int((16 + Double(sanitized.lumaThreshold) * 219 / 255).rounded(.down)) + 1
        videoRangeBinarisation = PopopxGlareDetector.binarisationTable(cutoff: videoCutoff)
    }

    /// 清空帧间历史。弹窗每次打开、每次换一条绝密消息都要调：不调的话上一轮的闩锁会吃掉
    /// 这一轮的第一次告警，而那次告警正是销毁消息的那一下。
    func reset() {
        previousMeanLumaValue = nil
        hotspotStreak = 0
        episodeReported = false
        // 计数也要归零：每次弹窗打开都是一次新的起手，AE 会重新收敛一遍。
        analyzedFrames = 0
    }

    // MARK: 主流程

    /// 处理一帧相机图像。见文件头"闩锁行为"：`.glare` 只在规则**刚被满足**那一帧出现一次。
    func process(_ pixelBuffer: CVPixelBuffer) -> PopopxGlareVerdict {
        let width = Int(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int(CVPixelBufferGetHeight(pixelBuffer))
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        // 3 而不是 1：网格、面积窗、box 核的奇数化在个位数尺寸上没有意义，直接判"看不了"。
        guard width > 3, height > 3 else { return refuse(with: .emptyFrame) }

        // 本文件从不写回采集缓冲，所以先要只读锁（GPU 驻留的缓冲在只读模式下能少一次拷贝）。
        // 某些缓冲拒绝只读锁定，退化成普通锁即可——我们仍然只是不写它。
        var lockFlags = CVPixelBufferLockFlags.readOnly
        if CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) != kCVReturnSuccess {
            lockFlags = []
            guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else {
                return refuse(with: .baseAddressUnavailable)
            }
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags) }

        // 拿到"Y 平面 + 它的 rowBytes + 它是不是视频量程"。BGRA 走一次 BT.601 矩阵乘到自己的缓冲里。
        var planeBase: UnsafeMutableRawPointer?
        var planeRowBytes = 0
        var isVideoRange = false
        switch format {
        case OSType(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
             OSType(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange):
            guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
                  let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                return refuse(with: .baseAddressUnavailable)
            }
            planeBase = yBase
            planeRowBytes = Int(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
            isVideoRange = format == OSType(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        case OSType(kCVPixelFormatType_32BGRA):
            guard let bgraBase = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                return refuse(with: .baseAddressUnavailable)
            }
            guard let computed = lumaPlane.reserve(width * height) else { return refuse(with: .accelerationFailed) }
            var source = vImage_Buffer(data: bgraBase, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: Int(CVPixelBufferGetBytesPerRow(pixelBuffer)))
            var destination = vImage_Buffer(data: computed, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width)
            let error = bgraLumaMatrix.withUnsafeBufferPointer { weights -> Int in
                guard let address = weights.baseAddress else { return PopopxVImage.lostBuffer }
                return vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &destination, address,
                                                             256, nil, 128, PopopxVImage.noFlags)
            }
            guard error == PopopxVImage.noError else { return refuse(with: .accelerationFailed) }
            planeBase = computed
            planeRowBytes = width
            isVideoRange = false
        default:
            return refuse(with: .unsupportedPixelFormat)
        }
        guard let base = planeBase, planeRowBytes >= width else { return refuse(with: .baseAddressUnavailable) }
        guard prepare(width: width, height: height) else { return refuse(with: .accelerationFailed) }

        var sourcePlane = vImage_Buffer(data: base, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: planeRowBytes)

        // 二值化用哪张表，取决于这帧是视频量程还是全量程。先挑出来：第 1 步数"过曝比例"要用**同一张**
        // 表，两处各挑一份的话，报了 `.lumaSurge` 却说不清是按哪条线数的削顶像素。
        let table = isVideoRange ? videoRangeBinarisation : fullRangeBinarisation

        // 1) 一次直方图扫描同时给出均值和过曝比例。必须在二值化**之前**读，二值化之后只剩 0 和 255。
        guard let luma = frameLumaStats(of: &sourcePlane, videoRange: isVideoRange, saturatingTable: table) else {
            return refuse(with: .accelerationFailed)
        }
        let meanLuma = luma.meanLuma

        // 2) 二值化到自有缓冲（LUT 不改源平面，所以只读锁是安全的）。
        guard let maskBase = maskPlane.base else { return refuse(with: .accelerationFailed) }
        var maskBuffer = vImage_Buffer(data: maskBase, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width)
        let binarised = table.withUnsafeBufferPointer { entries -> Int in
            guard let address = entries.baseAddress else { return PopopxVImage.lostBuffer }
            return vImageTableLookUp_Planar8(&sourcePlane, &maskBuffer, address, PopopxVImage.noFlags)
        }
        guard binarised == PopopxVImage.noError else { return refuse(with: .accelerationFailed) }

        // 3) 整数均值降采样 + "过半"再二值化 → 网格。
        guard reduceMaskToGrid(mask: &maskBuffer) else { return refuse(with: .accelerationFailed) }

        // 4) 连通域 + 面积窗 + 圆形度。
        let hotspots = analyseBlobs()

        // 5) 两条规则 + 闩锁。
        //
        // 跃升那一条要三件事同时成立：**跳够**（`meanLumaSurgeDelta`）、**削顶够广**
        // （`surgeMinimumSaturation`）、**已经过了起手那几帧**（`surgeWarmupFrames`）。
        // 只留"跳够"的话，这条规则的误报源至少有三个，而且每一个都会白删掉一条读了一半的绝密消息：
        // 相机起手的自动曝光收敛（台阶可以一次给几十点）、把镜头从脸上挪开对着白墙/窗户/天花板、
        // 从暗处走进亮处。它们的共同点是"整帧变亮但没烧穿"——均值上得去，`>245` 那一段上不去；
        // 而闪光灯和激光补光是真削顶，一秒内可以把 10%~60% 的帧推到顶格。
        let surgeArmed = analyzedFrames > settings.surgeWarmupFrames
        let surged: Bool
        if surgeArmed, let previous = previousMeanLumaValue {
            surged = meanLuma - previous >= settings.meanLumaSurgeDelta
                  && luma.saturatedFraction >= settings.surgeMinimumSaturation
        } else {
            surged = false
        }
        if hotspots.count > 0 {
            hotspotStreak += 1
        } else {
            hotspotStreak = 0
        }
        // "这一帧什么证据都没有"才解闩：光斑还在、或还在跃升，都不解——解了就会每帧重复发回执。
        if hotspots.count == 0 && !surged {
            episodeReported = false
        }
        lastSkipReason = nil
        let previousMean = previousMeanLumaValue
        previousMeanLumaValue = meanLuma
        analyzedFrames += 1

        if !episodeReported {
            if hotspotStreak >= settings.consecutiveFramesToFire {
                episodeReported = true
                return .glare(evidence(reason: .hotspot, hotspots: hotspots, luma: luma,
                                       previousMeanLuma: previousMean))
            }
            if surged {
                episodeReported = true
                return .glare(evidence(reason: .lumaSurge, hotspots: hotspots, luma: luma,
                                       previousMeanLuma: previousMean))
            }
        }
        return .clear
    }

    /// 把这一帧量到的东西装成证据。两条规则共用同一批测量值：`reason` 说的是"凭哪一条判的"，
    /// 剩下的字段说的是"那一帧到底长什么样"，分开写就会出现两个版本的真相。
    private func evidence(reason: PopopxGlareReason, hotspots: HotspotSummary,
                          luma: FrameLumaStats, previousMeanLuma: Double?) -> PopopxGlareEvidence {
        PopopxGlareEvidence(reason: reason,
                            hotspotCount: hotspots.count,
                            largestAreaFraction: hotspots.largestAreaFraction,
                            bestCircularity: hotspots.bestCircularity,
                            meanLuma: luma.meanLuma,
                            saturatedFraction: luma.saturatedFraction,
                            previousMeanLuma: previousMeanLuma,
                            sampledAt: Date())
    }

    // MARK: 帧准备

    /// 按帧尺寸重算步长/网格并按需分配缓冲。返回 false 表示这一帧看不了（内存或算子拒绝）。
    ///
    /// 只在尺寸真的变了时重新分配：相机帧尺寸在一次会话里是常量，`reserve` 又是"只增不减"，
    /// 于是稳态下每帧零分配。尺寸缩小时刻意不收缩内存——还回去再要回来只会多一次 VM fault。
    private func prepare(width: Int, height: Int) -> Bool {
        if width != frameWidth || height != frameHeight {
            frameWidth = width
            frameHeight = height
            let longest = max(width, height)
            // 向上取整保证网格长边 ≤ maximumEdgeLength；再抬到奇数，因为 box 卷积只收奇数核。
            var step = (longest + settings.maximumEdgeLength - 1) / settings.maximumEdgeLength
            if step < 1 { step = 1 }
            if step % 2 == 0 { step += 1 }
            stride = step
            // 核不许比图还大（退化尺寸下步长会超过短边）。
            var kernel = min(step, max(1, min(width, height)))
            if kernel % 2 == 0 { kernel -= 1 }
            kernelSize = max(1, kernel)
            gridWidth = (width + stride - 1) / stride
            gridHeight = (height + stride - 1) / stride
            cellCount = gridWidth * gridHeight
            grid = [UInt8](repeating: 0, count: cellCount)
            labels = [Int32](repeating: 0, count: cellCount)
            boundaryCells = [UInt8](repeating: 0, count: cellCount)
            // 标签最多 cellCount 个，并查集/面积/周长用 1 基下标，所以 +1。
            unionParent = [Int32](repeating: 0, count: cellCount + 1)
            blobArea = [Int32](repeating: 0, count: cellCount + 1)
            blobPerimeter = [Int32](repeating: 0, count: cellCount + 1)
        }
        guard maskPlane.reserve(width * height) != nil, smoothedPlane.reserve(width * height) != nil else { return false }
        guard kernelSize > 1 else { return true }  // 步长 1 时不做卷积，用不到工作区。
        var maskBuffer = vImage_Buffer(data: maskPlane.base, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width)
        var smoothBuffer = vImage_Buffer(data: smoothedPlane.base, height: vImagePixelCount(height),
                                         width: vImagePixelCount(width), rowBytes: width)
        let request = vImageBoxConvolve_Planar8(&maskBuffer, &smoothBuffer, nil, 0, 0,
                                                UInt32(kernelSize), UInt32(kernelSize), 0,
                                                PopopxVImage.tempBufferSize)
        guard request >= 0 else { return false }
        return convolutionScratch.reserve(Int(request)) != nil
    }

    // MARK: 均值

    /// 一帧的两个亮度量，都出自**同一次**直方图扫描。
    private struct FrameLumaStats {
        /// 全量程均值，0...255。
        var meanLuma: Double
        /// 被判定线点亮的那部分像素，0...1。
        var saturatedFraction: Double
    }

    /// 全帧均值亮度（返回**全量程** 0...255 单位）+ 过曝比例。
    ///
    /// 用直方图而不是统计算子：这个 SDK 没有 `vImage_Statistics_*`，而直方图是同样一遍 SIMD 扫描，
    /// 乘加只发生在 256 个桶上。单位统一成"全量程"很关键——否则切换一次像素格式就会在均值上
    /// 造成一次十几点的台阶，被 surge 规则当成闪光灯。
    ///
    /// 过曝比例数的是**原始桶**、判据用传进来的那张二值化表：表说亮的桶，就是掩码里点亮的那些像素，
    /// 所以视频量程的换算在这里不必再做第二遍，也不可能和掩码判到两条不同的线上去。
    private func frameLumaStats(of plane: inout vImage_Buffer, videoRange: Bool,
                                saturatingTable table: [UInt8]) -> FrameLumaStats? {
        histogram.zeroInPlace()
        let error = histogram.withUnsafeMutableBufferPointer { entries -> Int in
            guard let address = entries.baseAddress else { return PopopxVImage.lostBuffer }
            return vImageHistogramCalculation_Planar8(&plane, address, PopopxVImage.noFlags)
        }
        guard error == PopopxVImage.noError else { return nil }
        var weighted = 0.0
        var counted = 0.0
        var clipped = 0.0
        for (value, occurrences) in histogram.enumerated() {
            guard occurrences > 0 else { continue }
            weighted += Double(value) * Double(occurrences)
            counted += Double(occurrences)
            if table[value] == PopopxGlareDetector.maskOn { clipped += Double(occurrences) }
        }
        guard counted > 0 else { return nil }
        let raw = weighted / counted
        let mean: Double
        if videoRange {
            mean = min(max((raw - 16) * 255 / 219, 0), 255)
        } else {
            mean = min(max(raw, 0), 255)
        }
        return FrameLumaStats(meanLuma: mean, saturatedFraction: clipped / counted)
    }

    // MARK: 降采样

    /// box 整数均值 + "过半"再二值化，把整帧掩码折成网格。返回 false 表示算子失败。
    ///
    /// 采样中心取 `col*stride + stride/2`，与奇数核的覆盖范围正好一一对齐： interior 格就是
    /// 一个不重不漏的 `stride × stride` 块的整数均值。最后不足半格的尾巴靠 `kvImageEdgeExtend`
    /// 把边像素复制进来，等价于"尾巴格的均值被边角重复略微带偏"，误差量级是尾巴宽度/整宽。
    private func reduceMaskToGrid(mask: inout vImage_Buffer) -> Bool {
        let smoothingNeeded = kernelSize > 1
        if smoothingNeeded {
            guard let smoothBase = smoothedPlane.base, let scratch = convolutionScratch.base else { return false }
            var smoothBuffer = vImage_Buffer(data: smoothBase, height: vImagePixelCount(frameHeight),
                                             width: vImagePixelCount(frameWidth), rowBytes: frameWidth)
            let error = vImageBoxConvolve_Planar8(&mask, &smoothBuffer, scratch, 0, 0,
                                                  UInt32(kernelSize), UInt32(kernelSize), 0,
                                                  PopopxVImage.edgeExtend)
            guard error == PopopxVImage.noError else { return false }
        }
        // 步长 1 时不卷积，直接读掩码本身：那时"块均值"就是像素本身。
        let sampleBase = smoothingNeeded ? smoothedPlane.bytes : maskPlane.bytes
        guard let sampleBase else { return false }
        let rowStride = frameWidth
        let halfPoint = PopopxGlareDetector.gridHalfPoint
        var cell = 0
        for row in 0 ..< gridHeight {
            let centerY = min(row * stride + stride / 2, frameHeight - 1)
            let rowStart = centerY * rowStride
            for column in 0 ..< gridWidth {
                let centerX = min(column * stride + stride / 2, frameWidth - 1)
                grid[cell] = sampleBase[rowStart + centerX] >= halfPoint ? 255 : 0
                cell += 1
            }
        }
        return true
    }

    // MARK: 连通域

    /// 两遍并查集连通域标记 → 每块面积与周长 → 面积窗 + 圆形度过滤。
    ///
    /// 只在网格上跑（`cellCount` ≤ `maximumEdgeLength²` 量级），像素级的活儿全在上面三步交给 vImage 了。
    /// 面积单位是格，周长是 8 邻接链长（格单位，定点）；C = 4πA/P² 两边同单位，不必换算回像素。
    private func analyseBlobs() -> HotspotSummary {
        var summary = HotspotSummary()
        guard cellCount > 0 else { return summary }
        // 上一帧的标签必须抹干净：第一遍只写"这帧亮着的格"，暗格留着旧标签会被下一格当成邻接继承过来，
        // 于是两帧之间会串出一条根本不存在的光斑。`assign` 不重新分配，只覆写。
        labels.zeroInPlace()
        var nextLabel: Int32 = 1

        // 第一遍：从左到右、从上到下，能继承就继承，两边都有就并。
        for row in 0 ..< gridHeight {
            let rowStart = row * gridWidth
            for column in 0 ..< gridWidth {
                let index = rowStart + column
                guard grid[index] != 0 else { continue }
                let above = row > 0 ? labels[index - gridWidth] : 0
                let behind = column > 0 ? labels[index - 1] : 0
                if above == 0 && behind == 0 {
                    labels[index] = nextLabel
                    unionParent[Int(nextLabel)] = nextLabel
                    nextLabel += 1
                } else if above == 0 {
                    labels[index] = behind
                } else if behind == 0 {
                    labels[index] = above
                } else {
                    labels[index] = above
                    merge(above, behind)
                }
            }
        }

        // 第二遍：把每个格的标签压到根，顺手数面积（此时 labels 全是指向根的 1 基下标）。
        for index in 0 ..< cellCount {
            let label = labels[index]
            guard label != 0 else { continue }
            let root = root(of: label)
            labels[index] = root
            blobArea[Int(root)] += 1
        }

        // 周长：8 邻接链长（正交步 1，斜步 √2），**不是**数"有几个边界边"。
        // 数边界边是 L1 度量：45° 的斜边被走成阶梯，每条斜边算成 2 格而不是 √2 格，对圆盘系统性
        // 高估 4/π 倍，于是 C = 4πA/P² 的上限从 1 掉到 π²/16 ≈ 0.62。那样 `minimumCircularity = 0.72`
        // 会把所有真圆斑一律否掉，反倒是轴对齐的方块（0.785）能过门——规则整个反过来。实测见文件头。
        boundaryCells.zeroInPlace()
        for row in 0 ..< gridHeight {
            let rowStart = row * gridWidth
            for column in 0 ..< gridWidth {
                let index = rowStart + column
                let label = labels[index]
                guard label != 0 else { continue }
                let openUp = row == 0 || labels[index - gridWidth] != label
                let openDown = row == gridHeight - 1 || labels[index + gridWidth] != label
                let openLeft = column == 0 || labels[index - 1] != label
                let openRight = column == gridWidth - 1 || labels[index + 1] != label
                if openUp || openDown || openLeft || openRight { boundaryCells[index] = 1 }
            }
        }
        // 每对相邻的边界格只数一次：只看四个"前方"方向（右、下、右下、左下）。要求同标签，
        // 否则两块贴在一起的光斑会互相借周长。
        for row in 0 ..< gridHeight {
            let rowStart = row * gridWidth
            for column in 0 ..< gridWidth {
                let index = rowStart + column
                guard boundaryCells[index] != 0 else { continue }
                let label = labels[index]
                var steps = 0
                if column + 1 < gridWidth, boundaryCells[index + 1] != 0, labels[index + 1] == label {
                    steps += PopopxGlareDetector.orthogonalStep
                }
                if row + 1 < gridHeight {
                    if boundaryCells[index + gridWidth] != 0, labels[index + gridWidth] == label {
                        steps += PopopxGlareDetector.orthogonalStep
                    }
                    if column > 0, boundaryCells[index + gridWidth - 1] != 0, labels[index + gridWidth - 1] == label {
                        steps += PopopxGlareDetector.diagonalStep
                    }
                    if column + 1 < gridWidth, boundaryCells[index + gridWidth + 1] != 0,
                        labels[index + gridWidth + 1] == label {
                        steps += PopopxGlareDetector.diagonalStep
                    }
                }
                blobPerimeter[Int(label)] += Int32(steps)
            }
        }

        // 筛选。面积比例的分母是**网格**格数：一格代表 stride×stride 个像素，而网格铺满整帧，
        // 所以 格数/总格数 就是 像素数/整帧像素数——要求里"按真实帧面积量"的就是这一步，
        // 不需要再乘 stride²（乘了反而在宽高不整除步长时偏大）。
        let totalCells = Double(gridWidth * gridHeight)
        let minimum = settings.minimumAreaFraction
        let maximum = settings.maximumAreaFraction
        for label in 1 ..< nextLabel {
            let area = blobArea[Int(label)]
            // 用完就地清零，代替每帧 memset 整个数组：标签数是格数的子集，这里省的是 O(格数)。
            blobArea[Int(label)] = 0
            let perimeter = blobPerimeter[Int(label)]
            blobPerimeter[Int(label)] = 0
            // 一格孤点没有相邻边界格 → 周长 0；它也会被面积窗先否掉，这里只是别让 0 除。
            guard area > 0, perimeter > 0 else { continue }
            let fraction = Double(area) / totalCells
            guard fraction >= minimum, fraction <= maximum else { continue }
            // 周长是千分之一格边长，换成格单位再进 C = 4πA/P²（C 对单位不敏感，但两边必须同单位）。
            let edges = Double(perimeter) / Double(PopopxGlareDetector.perimeterUnit)
            let circularity = min(1, (4 * Double.pi * Double(area)) / (edges * edges))
            guard circularity >= settings.minimumCircularity else { continue }
            summary.count += 1
            summary.largestAreaFraction = max(summary.largestAreaFraction, fraction)
            summary.bestCircularity = max(summary.bestCircularity, circularity)
        }
        return summary
    }

    /// 查根。并查集只把**较大**的根挂到**较小**的根下面（见 `merge`），下标单调下降，不可能成环，
    /// 所以这里不需要迭代次数上限来防死循环。顺带做路径压缩。
    private func root(of label: Int32) -> Int32 {
        var current = label
        while unionParent[Int(current)] != current {
            let grandparent = unionParent[Int(current)]
            unionParent[Int(current)] = unionParent[Int(grandparent)]
            current = grandparent
        }
        return current
    }

    private func merge(_ first: Int32, _ second: Int32) {
        let firstRoot = root(of: first)
        let secondRoot = root(of: second)
        guard firstRoot != secondRoot else { return }
        if firstRoot < secondRoot {
            unionParent[Int(secondRoot)] = firstRoot
        } else {
            unionParent[Int(firstRoot)] = secondRoot
        }
    }

    // MARK: 降级

    /// 这一帧看不了。返回 `.clear`，但把原因留下，并且**清掉帧间历史**：
    /// 一段读不出来的帧等于"这段没看见"，连续帧计数必须重新攒；均值基线也不能拿旧帧冒充，
    /// 否则恢复后的第一帧会因为中间那几帧的曝光变化被判成一次假闪光。
    private func refuse(with reason: PopopxGlareSkipReason) -> PopopxGlareVerdict {
        lastSkipReason = reason
        reset()
        return .clear
    }

    // MARK: 表

    /// "过半"判定用的门限：box 之后的值是 `stride²` 个掩码像素的整数均值，掩码只有 0/255，
    /// 所以"过半"= 均值 ≥ 127.5 = 均值 ≥ 128。
    private static let gridHalfPoint: UInt8 = 128

    /// 掩码与二值化表里"点亮"那一档的值（另一档是 0）。数过曝像素的那一道判的就是它。
    private static let maskOn: UInt8 = 255

    /// 链长的定点单位：1 格边长 = 1000。整数累加器比每格一次浮点加便宜，而且这里要的精度很浅——
    /// √2 取 1.414 与真值差 0.00007，落在 C 的第五位小数上。
    private static let perimeterUnit = 1000
    private static let orthogonalStep = 1000
    private static let diagonalStep = 1414

    private static func binarisationTable(cutoff: Int) -> [UInt8] {
        let clipped = min(max(cutoff, 0), 256)
        return (0 ... 255).map { $0 >= clipped ? 255 : 0 }
    }
}

// MARK: - 内部类型

extension PopopxGlareDetector {
    /// 合格光斑的统计结果。三个字段直接进 `PopopxGlareEvidence`。
    struct HotspotSummary {
        var count = 0
        var largestAreaFraction = 0.0
        var bestCircularity = 0.0
    }
}

/// 一块只在"变大"时重新分配的裸缓冲。
///
/// 为什么不用 `[UInt8]`：vImage 的入参是 `vImage_Buffer`，要同时指向 2~3 块互不重叠的缓冲，
/// 用 Swift 数组就得把三层 `withUnsafeMutableBufferPointer` 套起来，而借用检查器不允许
/// 同一作用域里同时借出多个数组——最后是同样的裸指针，外加一堆只为绕过借用检查的嵌套闭包。
/// 裸分配还能对齐到 64 字节，vImage 的 NEON 路径吃这个。
/// 分配失败时 `allocate` 会直接终止进程（stdlib 不给失败返回），这是本文件唯一的硬终止路径；
/// 一帧 VGA 掩码是 300 KB 量级，走到那一步的进程也活不了下一次相机回调，不值得为它编一条假的降级。
private final class PopopxBytePlane {
    private(set) var base: UnsafeMutableRawPointer?
    private(set) var capacityBytes = 0

    /// 保证至少能放 `bytes` 个字节，返回基址。
    func reserve(_ bytes: Int) -> UnsafeMutableRawPointer? {
        guard bytes > 0 else { return base }
        if bytes > capacityBytes {
            base?.deallocate()
            base = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
            capacityBytes = bytes
        }
        return base
    }

    /// 按字节读写这块缓冲（采样循环用）。
    var bytes: UnsafeMutablePointer<UInt8>? {
        base?.assumingMemoryBound(to: UInt8.self)
    }

    deinit {
        base?.deallocate()
    }
}

/// vImage 的标志与返回码在这个 SDK 的 Swift 界面里是 `UInt32`/`Int` 的散装常量，
/// 直接混用会得到 "cannot convert" 而不是一个好错误。集中一处做宽度转换，
/// `truncatingIfNeeded` 保证不会因为符号宽度而 trap。
private enum PopopxVImage {
    static let noFlags: UInt32 = UInt32(truncatingIfNeeded: kvImageNoFlags)
    static let edgeExtend: UInt32 = UInt32(truncatingIfNeeded: kvImageEdgeExtend)
    static let tempBufferSize: UInt32 = UInt32(truncatingIfNeeded: kvImageGetTempBufferSize
                                               | kvImageEdgeExtend)
    static let noError: Int = kvImageNoError
    /// 缓冲指针为空时用的错误码。这种状态在本文件里构造不出来（数组都有固定长度），
    /// 但也不许用 `!` 或 `assert` 蒙过去：release 包里 `assert` 会被裁掉，那样就变成带着空指针继续跑。
    static let lostBuffer: Int = kvImageMemoryAllocationError
}

private extension Array where Element: FixedWidthInteger {
    /// 就地清零，**不**换一块新内存。
    ///
    /// 这批数组（标签、直方图）每帧都要抹一遍，写成 `labels = [Int32](repeating:count:)` 就是每帧一次
    /// malloc + 一次页错误——"每帧零分配"这条硬约束崩就在这行上。为什么不用 `assign(repeating:count:)`：
    /// 它语义正好，但这个 SDK 的 stdlib 里没有（`swiftc -typecheck` 报 "has no member 'assign'"，实测）。
    mutating func zeroInPlace() {
        withUnsafeMutableBufferPointer { pointer in
            pointer.update(repeating: 0)
        }
    }
}
