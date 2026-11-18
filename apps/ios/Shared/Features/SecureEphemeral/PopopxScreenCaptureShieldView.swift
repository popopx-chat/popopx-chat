//
//  PopopxScreenCaptureShieldView.swift
//  POPOPX (iOS)
//
//  【绝密阅后即焚 · 模块四·采集侧】两件事，一个文件：
//  1. `PopopxScreenCaptureShieldView`：把内容搬进"系统采集不到"的那块画布里，
//     于是录屏 / AirPlay / 采集卡上看到的是黑的，而肉眼看是正常的。
//  2. `PopopxCaptureMonitor` + `PopopxScreenCapture`：60Hz 逐帧问一次"现在有没有在被采"，
//     加两条系统通知（截屏、进后台），产出 `PopopxSecurityAlert`。
//
//  ### 屏蔽是怎么来的（机制，不是玄学）
//  `UITextField.isSecureTextEntry = true` 之后，UIKit 不再用 field 自己画文字，而是另起一个
//  私有子 view（`_UITextLayoutCanvasView`）承载文字图层。那个图层被系统标成"敏感内容"，
//  不进屏幕采集那一路 buffer —— 键盘为什么不进录屏、密码框为什么不进截屏，走的就是同一条路。
//  我们做的事只有一件：把 SwiftUI 内容塞进那块画布当子 view，于是内容继承画布的豁免。
//
//  ### 主张的边界（只写能自证的句子；这一节不许被简化成"防截屏"三个字）
//  覆盖（都要求设备上是真机实测过，不接受"应该是"）：
//  - 系统内录（ReplayKit、控制中心长录屏）、AirPlay 镜像、有线数字影音采集：这几路共用同一套
//    Surface 合成，画布里的内容根本不进那份帧；
//  - 任务切换器快照与静态截图的**内容部分**（同上，但这一路我们不单独立功——见下面 `.screenshotTaken`）。
//  不覆盖，而且不许在文案里暗示覆盖：
//  - **拿另一台设备拍屏幕**。光还在屏幕上，屏蔽层对此一个字节都做不了（那是 `PopopxGlareDetector`
//    与 `PopopxCameraGuardEngine` 的活，以及 `PopopxAntiPhotoRenderView` 的分时复用点阵）；
//  - **系统不知道的采集**：越狱注入、改过的固件、把显示器信号再分一路出去的硬件。判据是"系统承不承认
//  自己在采"，系统不承认就没有任何 flag 可读；
//  - **已经录进去的帧**。`.screenCaptured` 只能让之后的帧变黑/让消息销毁，回收不了之前那 0.5 秒；
//  - 截屏组合键本身不产生黑屏保证——所以那一路靠 `userDidTakeScreenshotNotification` 熔断，
//    靠销毁兜底，而不是靠屏蔽。
//
//  ### ⚠️⚠️ 私有 API 与 App Store 上架红线（2.5.1）——这一段不许被"优化"掉 ⚠️⚠️
//  上面那套依赖的是一个**私有视图类**：下划线开头、不在任何 header 里、Apple 随时可以改名或换结构。
//  - App Store 审核指南 **2.5.1 明令禁止调用私有 API/私有框架**。静态扫描只要匹配类名字符串就能命中，
//    所以"赌它扫不出来"不是灰区操作，是必然出事的操作。
//  - Apple 到今天为止**没有**提供任何公开 API 能让 app 自己声明"这个 view 从屏幕采集中排除"。
//    iOS 18 的 "Protect Sensitive Information"（隔空投送/屏幕共享时系统自动打码）是**系统自己的策略开关**，
//    只作用于系统认定的安全输入界面，不是交给第三方 app 的排除接口。
//  - 结论，写死在这里：本文件属于**侧载 / 开源构建**，不属于 App Store 提交物。要提交就必须整块换成
//    "检测 + 熔断 + 销毁"（`PopopxCaptureMonitor` 那一半是纯公开 API，可以留；屏蔽这一半必须删）。
//  - 也正因为它是私有面，本文件对它的态度是"能用但不信任"：类名判据、逐轮布局重挂、找不到就退回正常渲染。
//    任何"这块画布一定会在"的假设都不许写进代码。
//
//  ### 线程与所有权契约
//  - 屏蔽层：`UIViewRepresentable` 的两个方法都在主线程；宿主 `UIHostingController` 由 Coordinator
//    强持有（UIKit 不会替我们把内容留在画布里）。
//  - `PopopxCaptureMonitor`：`@MainActor`，**由 `PopopxSecureWindowManager` 在弹窗存续期间持有**，
//    弹窗关闭前必须调 `stop()`（`stop()` 里会断掉 `onAlert`、停掉 ticker、摘掉通知观察）。
//    对 window 只持 **weak**：管理器持窗、窗持内容、内容再回头持管理器就成环。
//  - `PopopxScreenCapture` 的两个判据：按主线程调用写（UIKit 的 trait/screen 状态本来就不保证跨线程一致），
//    但不加 `@MainActor`——预检发生在"还没 window、还没 actor 上下文"的地方，套上 actor 只会把调用方逼成
//    `Task { @MainActor in … }` 才能问一句"现在能不能弹"。这条约定和 `PopopxFrameTicker` 是同一种约定。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import SwiftUI
import UIKit

// MARK: - 屏蔽容器

/// 把内容放进"系统采集不到"的那块画布里。全屏黑屏屏蔽的实现载体。
///
/// 用法上它就是一个透明容器：内容要多大就多大（`maxWidth/maxHeight = .infinity`），
/// 背景色由调用方的表面负责——屏蔽层自己绝不涂色，否则"消息底下的黑"会多一个来源。
struct PopopxScreenCaptureShieldView<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        PopopxSecureCanvasRepresentable(content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 桥接层。SwiftUI 侧唯一做的事是把内容交给一个 `UIHostingController`，再让 field 把它的 view
/// 搬进画布；SwiftUI 自己没有任何"从采集中排除"的钩子可走。
private struct PopopxSecureCanvasRepresentable<Content: View>: UIViewRepresentable {
    let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeUIView(context: Context) -> PopopxSecureCanvasField {
        let field = PopopxSecureCanvasField()
        if let hosted = context.coordinator.hostedContentView {
            field.hostSecureContent(hosted)
        }
        return field
    }

    func updateUIView(_ field: PopopxSecureCanvasField, context: Context) {
        context.coordinator.setContent(content)
        // 只有换了宿主 view（几乎不会发生）才重挂；正常路径上这里是一次引用比较。
        if let hosted = context.coordinator.hostedContentView, !field.isHosting(hosted) {
            field.hostSecureContent(hosted)
        }
    }

    /// 强持有宿主控制器：画布只认 view，控制器的生命周期没人接管。
    ///
    /// 刻意**不**把它 `addChild` 到某个 UIViewController 上——`UIViewRepresentable` 里没有
    /// "本视图所属的控制器"这个东西，`makeUIView` 时连 window 都还没有。少一层父子关系意味着
    /// trait（深色模式、尺寸类别）由视图链而不是控制器链传播，UIKit 对此是有支持的；
    /// 换来的是不用去猜最近的祖先控制器是谁。
    final class Coordinator {
        private let controller: UIHostingController<Content>?

        init(content: Content) {
            controller = UIHostingController(rootView: content)
            // 屏蔽层不带自己的底色：见 `PopopxScreenCaptureShieldView` 的文档。
            controller?.view?.backgroundColor = .clear
        }

        var hostedContentView: UIView? { controller?.view }

        func setContent(_ content: Content) {
            controller?.rootView = content
        }
    }
}

/// 承载画布的 secure text field。
///
/// 四条规矩决定了这个类的形状，逐条对应上面机制那一段：
/// 1. `isSecureTextEntry = true` 是画布存在的前提，也是唯一的开关来源；
/// 2. `text` 赋一次值是让 UIKit 真的去**建**那块画布（空文本时它懒得不建）；建完立刻清空，
///    点就不会出现在屏幕上——清空的代价和风险见 `clearTriggerTextIfCanvasSurvives(with:)`；
/// 3. `isHidden` 必须为假：隐藏的 field 走不到建画布那一步；
/// 4. `isUserInteractionEnabled = false` 是提示词的硬约束（它同时是"永远不弹键盘、不出现选中柄"
///    最省事的保证）。副作用是 `UIView` 的默认命中测试会因为这一个 flag 把**整棵子树**摘掉，
///    于是画布里的按钮、滚动、长按全都点不到。下面用覆写 `hitTest(_:with:)` 把不可交互限制在
///    field 自己这一层——不改 flag，不改约束，只把命中继续往下钻。
private final class PopopxSecureCanvasField: UITextField {
    /// 触发建画布用的占位文字。一个空格：宽度接近 0，且在 `textColor = .clear` 下不产生可见像素。
    private static let triggerText = " "

    private var hostedContentView: UIView?
    private weak var attachedCanvas: UIView?
    /// 只表示"上一次判定时找不到画布"，用于把降级渲染做成幂等的（每轮布局都在重跑这个判定）。
    private var rendersNormally = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureAsSecureCanvasHost()
    }

    /// 本 view 正常路径上只由代码创建。归档路径留在这里而不是 `fatalError`，是为了让"有人哪天
    /// 从 xib 里把它拉出来"表现为"屏蔽可能失效但界面正常"，而不是解码阶段崩掉——一个会在
    /// 归档解码时崩溃的绝密弹窗，比一个不设防的绝密弹窗更难被现场诊断出来。
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAsSecureCanvasHost()
    }

    /// 两条 init 走同一个配置，避免"归档那一条少设了一个 flag"这种只有上机才能发现的问题。
    private func configureAsSecureCanvasHost() {
        isSecureTextEntry = true
        isUserInteractionEnabled = false
        isHidden = false
        textColor = .clear
        text = PopopxSecureCanvasField.triggerText
        // 占位文字不该参与任何布局计算。
        font = UIFont.systemFont(ofSize: 1)
        adjustsFontSizeToFitWidth = false
        backgroundColor = .clear
        clipsToBounds = false
        // field 自己不该被 VoiceOver 念成"文本栏"；关掉它这个元素不影响子树里的 SwiftUI 无障碍元素。
        isAccessibilityElement = false
        accessibilityTraits = .none
    }

    // MARK: 布局与挂载

    /// 不要固有尺寸：一个带文字的 UITextField 会按文字报一个很小的 intrinsic size，
    /// 那会让屏蔽层缩成一枚小胶囊——内容还是被保护了，但用户看到的是一粒字。
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    /// 同上：被问"你想要多大"时回答"你给多大我就要多大"。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        size
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachHostedContentIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 进窗的那一轮布局可能早于（也可能根本不_follow_）挂载：两条路都指向同一个幂等入口。
        attachHostedContentIfNeeded()
    }

    /// 收下要搬进画布的内容。重复交同一个 view 是 no-op，`updateUIView` 每帧都在调。
    func hostSecureContent(_ view: UIView) {
        guard hostedContentView !== view else { return }
        hostedContentView?.removeFromSuperview()
        hostedContentView = view
        attachedCanvas = nil
        rendersNormally = false
        setNeedsLayout()
        attachHostedContentIfNeeded()
    }

    func isHosting(_ view: UIView) -> Bool {
        hostedContentView === view
    }

    /// 命中测试下钻到宿主内容（见类文档第 4 条）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isHidden == false, alpha > 0.01, !isUserInteractionEnabled,
              let hosted = hostedContentView
        else {
            return super.hitTest(point, with: event)
        }
        return hosted.hitTest(convert(point, to: hosted), with: event)
    }

    /// 双保险：即便命中测试哪天把焦点引到 field 自己身上，它也当不成第一响应者（键盘永远不弹）。
    override var canBecomeFirstResponder: Bool {
        false
    }

    // MARK: 画布解析

    /// 每轮布局都跑：`super.layoutSubviews()` 之后 UIKit 有权按文字尺寸重排那块画布，
    /// 一次性的挂载在这个前提下不成立。函数必须是幂等的，正常路径的开销是几次引用比较。
    private func attachHostedContentIfNeeded() {
        guard let hosted = hostedContentView, window != nil, bounds.width > 0, bounds.height > 0 else {
            return
        }
        // (1) 链还在：只把尺寸拉回来。
        if let canvas = attachedCanvas, canvas.superview === self, hosted.superview === canvas {
            canvas.frame = bounds
            hosted.frame = CGRect(origin: .zero, size: canvas.bounds.size)
            return
        }
        // (1') 已经判定过"这台设备的 UIKit 里没有我们认识的画布"：内容就在自己子视图里，
        // 只需要跟着布局走，不必每轮重新找一遍。
        if rendersNormally, hosted.superview === self {
            hosted.frame = bounds
            return
        }
        attachedCanvas = nil
        hosted.removeFromSuperview()
        // (2) 找画布。
        guard let canvas = PopopxSecureCanvasField.resolveCanvas(in: self) else {
            renderNormally(with: hosted)
            return
        }
        // (3) 挂上去，并把画布撑满 field。私有 view 的内部布局不是契约，尺寸只能我们自己要保证；
        //     反过来我们不动它的 `clipsToBounds`，让 UIKit 对这块图层做主。
        canvas.addSubview(hosted)
        hosted.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.frame = bounds
        hosted.frame = CGRect(origin: .zero, size: canvas.bounds.size)
        attachedCanvas = canvas
        rendersNormally = false
        clearTriggerTextIfCanvasSurvives(with: canvas)
    }

    /// 类名判据 + 兜底。
    ///
    /// 不用下标（`subviews.first?.subviews.first`）：子 view 顺序从来不是契约，
    /// 而顺序判据的失败形状特别坏——内容被挂进一个**照常参与采集**的 view，
    /// 屏幕上看着一切正常，截屏里也一切正常，只有日志里什么都没发生。
    /// 类名判据的失败形状是"找不到"，那正是本文件唯一能安全响应的一种。
    private static func resolveCanvas(in field: UIView) -> UIView? {
        for candidate in field.subviews where isCanvas(candidate) {
            return candidate
        }
        for child in field.subviews {
            for candidate in child.subviews where isCanvas(candidate) {
                return candidate
            }
        }
        // 兜底：secure field 子树里最深的那一层。
        // 说清楚兜底买到什么：买到的是"内容仍然渲染在 secure field 里、不崩不空"，
        // **买不到屏蔽**——只有上面两个类名命中才叫拿到了那块画布。
        return deepestSubview(of: field)
    }

    private static func isCanvas(_ view: UIView) -> Bool {
        NSStringFromClass(type(of: view)).hasSuffix("_UITextLayoutCanvasView")
    }

    /// 逐层下探，深度上限 8：防的是私有实现里出现自环或被共享 view 挂回上层。
    private static func deepestSubview(of root: UIView) -> UIView? {
        var current: UIView = root
        var deepest: UIView?
        for _ in 0 ..< 8 {
            guard let next = current.subviews.first(where: { $0 !== current }) else { break }
            deepest = next
            current = next
        }
        return deepest
    }

    /// 把触发用的占位文字清掉——屏幕上一个点都不该有。
    ///
    /// 但不能盲清：某些 iOS 版本里，文字是画布存在的前提，清空会连同画布一起被 UIKit 收回去，
    /// 那一刻内容就真的"消失"了（比降级更糟）。所以清完立刻验一次画布还在不在 field 的子树里，
    /// 不在就把开关拨回去；拨回去也不可见，因为 `textColor = .clear`，而且宿主内容就在它上面。
    private func clearTriggerTextIfCanvasSurvives(with canvas: UIView) {
        guard let current = text, current.isEmpty == false else { return }
        text = ""
        if canvas.superview !== self {
            text = PopopxSecureCanvasField.triggerText
        }
    }

    /// 找不到画布 → 正常渲染。
    ///
    /// 这是本文件最重要的一条降级：**绝不因为屏蔽拿不到就让消息看不见**。
    /// 用户面前的选择只有"读到内容但可能被录走"和"读不到任何东西"两种，第一种才是可接受的，
    /// 因为录走的后果有 `PopopxCaptureMonitor` 的熔断与销毁兜底，而"读不到"没有任何兜底。
    ///
    /// 刻意**不加** `.accessibilityHint`、不弹 toast、不写日志：
    /// - 无障碍提示会把"这台设备上屏蔽失效了"念给任何拿着手机的人听，也写进能被程序读取的
    ///   无障碍树里——那是一条给攻击者的免费状态广播；
    /// - toast/日志会在绝密界面上多留一句和正文无关的话，而这一屏的全部设计目标就是少留字。
    /// 失效的检测方式是人工的、上线前做一次：开着录屏打开一条绝密消息，看那一路是不是黑的。
    private func renderNormally(with hosted: UIView) {
        guard hosted.superview !== self else {
            hosted.frame = bounds
            return
        }
        hosted.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(hosted)
        hosted.frame = bounds
        rendersNormally = true
    }
}

// MARK: - 采集监测

/// 60Hz 逐帧轮询 + 系统通知，产出 `PopopxSecurityAlert`。弹窗存续期间由窗口管理器持有。
///
/// 三条信号，一条边沿规则：
/// - 逐帧读采集状态：`false → true` 那一次发 `.screenCaptured`；
/// - `userDidTakeScreenshotNotification` → `.screenshotTaken`（截屏组合键，公开 API 里唯一入口）；
/// - `didEnterBackgroundNotification` → `.leftForeground`（这一刻起任务切换器缩略图不再受控）。
///
/// **全部按边沿触发**：60Hz 轮询若逐帧发事件，就是每秒 60 条告警打进 `onAlert`，
/// 而 `onAlert` 那一侧要做的是销毁消息 + 发一条回执 —— 那是把熔断器变成 DoS 目标，
/// 回执还会在网络上排成一条队。`lastCaptured` 只记录"上一次轮询看到的值"，
/// 一次采集会话内只会有一条 `.screenCaptured`。
@MainActor
final class PopopxCaptureMonitor: NSObject {
    /// 告警出口。`stop()` 之后必须是 nil：管理器断开之后不该再有回调进来。
    var onAlert: ((PopopxSecurityAlert) -> Void)?

    /// 对 window 只持 weak（见文件头的所有权契约）。
    private weak var window: UIWindow?

    private var ticker: PopopxFrameTicker?
    private var lastCaptured = false
    private var observersInstalled = false

    /// 此刻是否正在被采集。同步读，**不会**因此启动或改变轮询；代价是每次调用都要过一遍场景表。
    var isCapturedNow: Bool {
        PopopxScreenCapture.isCaptured(in: window)
    }

    /// 挂 CADisplayLink + 通知。幂等：重复调用不会造出第二条 60Hz 源，也不会重复注册观察者。
    func start(in window: UIWindow?) {
        self.window = window
        installObservers()
        if ticker == nil {
            let ticker = PopopxFrameTicker(framesPerSecond: 60)
            // 闭包只在主线程被调（`PopopxFrameTicker` 的约定），所以这里可以直接同步读状态；
            // weak 捕获是为了不断成 manager → monitor → ticker → closure → manager 这条环。
            ticker.onFrame = { [weak self] _ in
                self?.pollCaptureStateOnce()
            }
            ticker.start()
            self.ticker = ticker
        }
        // 起手先记一次当前值：调用方在**打开弹窗之前**已经用 `PopopxScreenCapture.anyScreenIsCaptured`
        // 预检过并拒绝过了，此刻若已经是"采集中"，把它算成一次 false→true 边沿就是重复销毁一条还没看到的消息。
        lastCaptured = PopopxScreenCapture.isCaptured(in: window)
    }

    /// 幂等停：停 ticker（顺带断掉 `onFrame`）、摘观察者、交回 `onAlert`。
    /// 之后再要监听必须重新 `start(in:)` 并重新赋 `onAlert`——这是有意的：
    /// 一个"自己会带着旧回调复活"的监测器无法被安全地复用。
    func stop() {
        ticker?.stop()
        ticker = nil
        NotificationCenter.default.removeObserver(self)
        observersInstalled = false
        onAlert = nil
        lastCaptured = false
        window = nil
    }

    // MARK: 轮询

    private func pollCaptureStateOnce() {
        let captured = PopopxScreenCapture.isCaptured(in: window)
        defer { lastCaptured = captured }
        guard captured, !lastCaptured else { return }
        onAlert?(.screenCaptured)
    }

    // MARK: 系统通知

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(screenshotNotified),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(didEnterBackgroundNotified),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    /// 截屏：系统只在用户真的按下组合键（或三指手势、Apple Pencil 截屏这类被系统认定的截屏）之后
    /// 发这一条。它是**事后**通知——图片已经落进相册/剪贴板了。所以这一档的价值全在熔断：
    /// 立刻销毁并回执，而不是"阻止截屏"。
    @objc private func screenshotNotified() {
        onAlert?(.screenshotTaken)
    }

    /// 进后台：这一刻起快照缓存与任务切换器缩略图都不再受我们控制。
    /// 用 `didEnterBackground` 而不是 `willResignActive`：后者在通知横幅下拉、控制中心、
    /// Face ID 认证弹窗这些"屏幕还没让给别人"的时刻也会响，按它销毁会把正常使用变成误伤。
    @objc private func didEnterBackgroundNotified() {
        onAlert?(.leftForeground)
    }

    deinit {
        // `stop()` 是主 actor 隔离的方法，deinit 里调不了（Swift 明确禁止），所以在 deinit 里只做
        // 这一件不需要隔离上下文的动作。NotificationCenter 的观察者是按对象登记的，摘掉不需要碰任何
        // 存储属性。CADisplayLink 不用管：`ticker` 随本对象一起释放，`PopopxFrameTicker.deinit`
        // 自己会把 link 从 runloop 上摘下来。
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - 静态判据

/// 供打开弹窗前"预检"用的静态判据（此时还没有 window，所以要能空着问）。
///
/// 采集判据只用公开 API，本类型里没有一行私有面——这也是本文件唯一可以整块搬进提交版的部分。
enum PopopxScreenCapture {
    /// 本 app 当前占着的任意一块屏正在被采集。没有 window 可问时（预检、设置页开关说明）用这一个。
    static var anyScreenIsCaptured: Bool {
        UIApplication.shared.connectedScenes.contains(where: sceneIsCaptured(_:))
    }

    /// 指定 window 所在那一屏优先，其余屏兜一遍。
    ///
    /// 为什么是**轮询**而不是 `UIScreen.isCapturedNotification` 或 KVO（这条是设计决定，不是偷懒）：
    /// - 那条通知是**按 UIScreen** 发的，文档语义是"这块屏的镜像/采集状态变了"，它对
    ///   iOS 17 起的场景级判据（`UITraitCollection.sceneCaptureState`）没有任何承诺，
    ///   多屏/外接屏那一侧还可能压根不发；
    /// - KVO 更不行：`isCaptured` 是一个每次都要问内核的计算属性，没有 KVO 合规性文档，
    ///   靠它等于把安全判据压在"碰巧会发 willChange"上；
    /// - 通知是异步投递的，而这里的判据要的是"从系统开始采集到我们把消息熔断，最多差几毫秒"——
    ///   只有逐帧读能把上界钉死在一个显示帧（60Hz 下 ≈16.7ms）。
    /// 一次读的成本：遍历场景表（正常就是 1 条）+ 一次 trait 查询 + 一次 BOOL 读，可以每帧付。
    static func isCaptured(in window: UIWindow?) -> Bool {
        guard let window else { return anyScreenIsCaptured }
        // window 自己的 trait 是离它最近的一手信息（场景换屏时 UIKit 会重算它）。
        if window.traitCollection.sceneCaptureState == .active { return true }
        guard let scene = window.windowScene else { return anyScreenIsCaptured }
        if scene.traitCollection.sceneCaptureState == .active { return true }
        if scene.screen.isCaptured { return true }
        // 其余场景也过一遍：绝密窗口挂在 A 屏，采集发生在同一台设备的 B 屏上，仍然是采集。
        return anyScreenIsCaptured
    }

    /// 场景级判据（iOS 17+ 的正解）优先，屏级 legacy 标志补漏。
    ///
    /// 两个都要，是因为它们的生效时机不保证一致：trait 是按场景传播的，AirPlay 刚接上的那一瞬
    /// 可能还是 `.unspecified`；`screen.isCaptured` 是屏级的旧标志，头文件已经写明"改用
    /// `sceneCaptureState`"（标记是 to-be-deprecated，Swift 侧目前不报警告，值也仍然给得出）。
    /// `.unspecified` 一律不当成"没在采"——判据取并集，误报由调用方的熔断代价（销毁一条消息）来吸收，
    /// 漏报没有人能补。
    private static func sceneIsCaptured(_ scene: UIScene) -> Bool {
        guard let windowScene = scene as? UIWindowScene else { return false }
        if windowScene.traitCollection.sceneCaptureState == .active { return true }
        return windowScene.screen.isCaptured
    }
}
