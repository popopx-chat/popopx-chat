//
//  PopopxWeakDisplayLinkProxy.swift
//  POPOPX (iOS)
//
//  `CADisplayLink` 的弱引用代理 + 一个可确定性销毁的逐帧驱动器。
//
//  为什么要这一层：`CADisplayLink(target:selector:)` **强引用** target。直接把一个
//  SwiftUI 的宿主对象、或一个持有视图闭包的管理器交上去，就得到一条
//  `displayLink -> target -> closure -> view` 的环：弹窗关了，60Hz 的回调还在跑，
//  而且跑得比屏幕刷新还勤。这条环是"阅后即焚"这类短命容器最容易漏、又最难在泄漏检测器里
//  认出来的一类（它不长，它是永远不结束）。
//
//  代理只做一件事：把 `tick` 转发给一个 `weak` 目标，目标没了就顺手把自己从 runloop 上摘下来。
//  `forwardingTarget(for:)` 必须一并转发，否则 `CADisplayLink` 在真正发消息前会先问
//  `responds(to:)`，返回 nil 就等于"这个 target 不会处理 tick"，回调一次都不会来。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import QuartzCore
import UIKit

/// `CADisplayLink` 的弱代理。
final class PopopxWeakDisplayLinkProxy: NSObject {
    /// 真正的接收者。`weak` 是这只类存在的全部理由。
    private weak var target: (any PopopxDisplayLinkTicker)?

    /// 挂上去的那条 link，只为"目标没了能自己摘下来"而留。
    fileprivate weak var link: CADisplayLink?

    init(target: any PopopxDisplayLinkTicker) {
        self.target = target
        super.init()
    }

    /// `CADisplayLink` 用 selector 派发，所以这个方法必须能被 `@objc` 找到。
    @objc func tick(_ link: CADisplayLink) {
        guard let target else {
            // 目标已经释放。此刻不摘，下一次 tick 还是空转，而且 link 会一直把本代理
            // 钉在 runloop 上——正是我们要修的那个环。
            invalidate()
            return
        }
        target.displayLinkDidTick(link)
    }

    /// 代理必须替目标回答"我能不能转发这个 selector"，`CADisplayLink` 才肯把帧回调送过来。
    ///
    /// 只认 `tick` 这一个方法：协议只要求这一个，用 `target.responds(to:)` 反而要把协议挂到
    /// `NSObjectProtocol` 上，而本文件的接收方是纯 Swift 类，不该为了转发问题变成 OC 类。
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard aSelector == #selector(PopopxWeakDisplayLinkProxy.tick(_:)), target != nil else {
            // 答不上来时顺手自杀：一个永远不会被转发的代理留在 runloop 上没有意义。
            invalidate()
            return nil
        }
        return target
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }
}

/// 逐帧回调的接收方。用协议而不是 `AnyObject` + `responds(to:)` 反射，是为了让"谁在收帧"
/// 这件事在类型上看得出来。
protocol PopopxDisplayLinkTicker: AnyObject {
    func displayLinkDidTick(_ link: CADisplayLink)
}

// MARK: - 帧驱动器

/// 一条有明确生死的 `CADisplayLink`。
///
/// **线程约定**：本类不是 `@MainActor`，因为它要挂的正是主 runloop，而 `CADisplayLink` 的回调
/// 由那个 runloop 直接派发——套上 actor 只会让"在回调里同步取一次状态"变成一次跨 actor 跳转。
/// 约定改成写在文档里：只在主线程创建、`start`/`stop`；这个约定和它挂的 runloop 是同一件事，
/// 不是一份额外的规矩。
///
/// 三个约束决定了它的形状：
/// 1. **必须挂到正确的 runloop mode**。挂在 `.default` 上的话，手指一按住滚动就再也不 tick
///    ——而绝密弹窗里正有一个要按住的逐行阅读模式。所以默认 `.common`。
/// 2. **必须能被幂等地停掉**。`start()` → `stop()` → `start()` 是用户来回切开关的正常序列，
///    第二次 `start()` 绝不能造出第二条 link（那就是两个 60Hz 源，且第一条再也拿不到引用）。
/// 3. **退出时必须断开对宿主的强引用链**。`onFrame` 闭包由宿主传进来，宿主几乎一定是
///    `@MainActor` 对象，所以本类对它**只持 weak**，并且提供 `stop()` 让人能显式切断。
final class PopopxFrameTicker: PopopxDisplayLinkTicker {
    /// 每帧回调。参数是这一次与上一次的间隔（秒）——`CADisplayLink` 已经算好了，
    /// 自己拿时间戳相减只会得到一份和屏幕不同步的近似值。
    var onFrame: ((TimeInterval) -> Void)?

    /// 期望帧率上限。ProMotion 屏上 `preferredFrameRateRange` 让系统按内容自选 60/120；
    /// 这里传 60 表示"每分钟 60 次足够，别为此把 120Hz 拉满"。
    private let requestedFramesPerSecond: Int

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    /// 当前是否在跑。测试和 `deinit` 断言都看这一个值。
    var isRunning: Bool { link != nil }

    init(framesPerSecond: Int = 60) {
        requestedFramesPerSecond = max(1, framesPerSecond)
    }

    deinit {
        // 宿主松开本类之后这一步仍必须做：link 被 runloop 持有，会一直 tick 到进程结束。
        // `invalidate()` 是 runloop 操作，而本类按上面的约定只在主线程创建，deinit 也就在主线程。
        link?.invalidate()
    }

    /// 幂等启动。已经在跑就直接返回，不造第二条。
    func start() {
        guard link == nil else { return }
        lastTimestamp = 0
        let proxy = PopopxWeakDisplayLinkProxy(target: self)
        let link = CADisplayLink(target: proxy, selector: #selector(PopopxWeakDisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        // `preferredFrameRateRange` 是 iOS 15+；`frameInterval` 是它之前的等价物。
        // 这里不写 `#available` 分支去兼容 iOS 14 及以下：app 的编译下限已经在 17 之上
        // （`PopopxToast.swift:52` 的 `@Observable` 无门禁就是证据），多留一支死代码只会让
        // 这行在未来变成"没人验证过的分支"。
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(requestedFramesPerSecond) / 4,
            maximum: Float(requestedFramesPerSecond),
            preferred: Float(requestedFramesPerSecond)
        )
        // 代理对 link 是 weak，link 对代理是 strong —— 唯一的强引用在 runloop 手里。
        // 于是 `invalidate()` 之后没有任何人还留着代理，它随最后一个引用一起走。
        proxy.link = link
        self.link = link
    }

    /// 停掉并把闭包交出去，避免宿主已经没了还留着一个捕获它的闭包。
    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
    }

    func displayLinkDidTick(_ link: CADisplayLink) {
        // `stop()` 之后 runloop 可能还排着一帧。判据用同一份引用，不用 `isRunning` 再兜一层。
        guard self.link === link else { return }
        let delta = lastTimestamp == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        onFrame?(max(0, delta))
    }
}
