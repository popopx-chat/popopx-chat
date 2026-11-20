//
//  PopopxWeakDisplayLinkProxy.swift
//  POPOPX (iOS)
//
//  Weak-reference forwarder for `CADisplayLink` + a per-frame driver that can be destroyed deterministically.
//
//  Why this layer exists: `CADisplayLink(target:selector:)` holds the target with a **strong** reference. Handing over a
//  SwiftUI host object directly, or a manager that holds view closures, yields a
//  `displayLink -> target -> closure -> view` cycle: the sheet is closed and the 60Hz callback is still running,
//  and it runs even more often than the screen refreshes. This cycle is the easiest one to miss in short-lived containers such as view-once, and at the same time the hardest
//  to recognise in a leak detector (it is not long, it simply never ends).
//
//  The forwarder does one thing only: hand `tick` on to a `weak` target, and when the target is gone it detaches itself from the runloop.
//  `forwardingTarget(for:)` must forward as well, otherwise `CADisplayLink` first asks, before it really sends the message,
//  `responds(to:)`, and returning nil equals "this target will not handle tick", so not one callback arrives.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import QuartzCore
import UIKit

/// Weak forwarder for `CADisplayLink`.
final class PopopxWeakDisplayLinkProxy: NSObject {
    /// The real receiver. `weak` is the entire reason this class exists.
    private weak var target: (any PopopxDisplayLinkTicker)?

    /// The link it was attached to, kept only so that it can detach itself when the target is gone.
    fileprivate weak var link: CADisplayLink?

    init(target: any PopopxDisplayLinkTicker) {
        self.target = target
        super.init()
    }

    /// `CADisplayLink` dispatches by selector, so this method must be findable through `@objc`.
    @objc func tick(_ link: CADisplayLink) {
        guard let target else {
            // The target has already been released. If we do not detach at this point, the next tick still spins for nothing, and the link keeps pinning this forwarder
            // to the runloop -- exactly the cycle we are here to fix.
            invalidate()
            return
        }
        target.displayLinkDidTick(link)
    }

    /// The forwarder must answer "can I forward this selector" on the target's behalf before `CADisplayLink` is willing to deliver frame callbacks.
    ///
    /// Only `tick` is recognised: the protocol requires nothing else, and using `target.responds(to:)` would instead require attaching the protocol to
    /// `NSObjectProtocol`, while the receivers in this file are pure Swift classes that should not become OC classes just for a forwarding question.
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard aSelector == #selector(PopopxWeakDisplayLinkProxy.tick(_:)), target != nil else {
            // Detach right away when the answer cannot be given: a forwarder that will never be forwarded from has no business staying on the runloop.
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

/// The receiver of the per-frame callback. A protocol rather than `AnyObject` + `responds(to:)` reflection, so that the fact of "who is receiving frames"
/// can be seen in the types.
protocol PopopxDisplayLinkTicker: AnyObject {
    func displayLinkDidTick(_ link: CADisplayLink)
}

// MARK: - Frame driver

/// A `CADisplayLink` with an explicit life and death.
///
/// **Threading convention**: this class is not `@MainActor`, because what it has to attach to is precisely the main runloop, and the callbacks of `CADisplayLink`
/// are dispatched directly by that runloop -- putting an actor around it would only turn "read state synchronously inside the callback" into a cross-actor hop.
/// The convention is written into the documentation instead: create, `start`/`stop` only on the main thread; this convention and the runloop it attaches to are the same thing,
/// not an extra rule.
///
/// Three constraints determine its shape:
/// 1. **It must attach to the correct runloop mode**. Attached to `.default`, the moment a finger presses down for a scroll it never ticks again
///    -- and the top-secret sheet has exactly a press-and-hold line-by-line reading mode. Hence `.common` by default.
/// 2. **It must be stoppable idempotently**. `start()` -> `stop()` -> `start()` is the ordinary sequence when a user flips the switch back and forth,
///    and the second `start()` must never produce a second link (that would be two 60Hz sources, and the first one could never be referenced again).
/// 3. **On exit the strong reference chain to the host must be broken**. The `onFrame` closure is passed in by the host, which is almost certainly
///    a `@MainActor` object, so this class **holds it weakly only**, and it offers `stop()` so that a person can cut it explicitly.
final class PopopxFrameTicker: PopopxDisplayLinkTicker {
    /// Per-frame callback. The parameter is the interval between this frame and the previous one (seconds) -- `CADisplayLink` has already computed it,
    /// and subtracting timestamps ourselves would only yield an approximation that is out of step with the screen.
    var onFrame: ((TimeInterval) -> Void)?

    /// Expected frame-rate ceiling. On a ProMotion display `preferredFrameRateRange` lets the system pick 60/120 by content;
    /// passing 60 here means "60 times per minute is enough, do not push 120Hz up for this".
    private let requestedFramesPerSecond: Int

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    /// Whether it is running right now. Both the tests and the `deinit` assertion look at this one value.
    var isRunning: Bool { link != nil }

    init(framesPerSecond: Int = 60) {
        requestedFramesPerSecond = max(1, framesPerSecond)
    }

    deinit {
        // This step is still required after the host lets go of the class: the link is held by the runloop and will tick until the process ends.
        // `invalidate()` is a runloop operation, and since this class is created only on the main thread per the convention above, deinit happens on the main thread too.
        link?.invalidate()
    }

    /// Idempotent start. If it is already running, return immediately and do not build a second one.
    func start() {
        guard link == nil else { return }
        lastTimestamp = 0
        let proxy = PopopxWeakDisplayLinkProxy(target: self)
        let link = CADisplayLink(target: proxy, selector: #selector(PopopxWeakDisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        // `preferredFrameRateRange` is iOS 15+; `frameInterval` is its equivalent before that.
        // No `#available` branch here to support iOS 14 and below: the app's compilation floor is already above 17
        // (the ungated `@Observable` at `PopopxToast.swift:52` is the evidence), and keeping one more dead branch would only turn
        // this line in the future into "a branch nobody has verified".
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(requestedFramesPerSecond) / 4,
            maximum: Float(requestedFramesPerSecond),
            preferred: Float(requestedFramesPerSecond)
        )
        // The forwarder is weak to the link and the link is strong to the forwarder -- the only strong reference is in the runloop's hands.
        // So after `invalidate()` nobody still holds the forwarder, and it goes away with the last reference.
        proxy.link = link
        self.link = link
    }

    /// Stops and hands the closure back out, to avoid keeping a closure that captured the host after the host is already gone.
    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
    }

    func displayLinkDidTick(_ link: CADisplayLink) {
        // After `stop()` the runloop may still have one frame queued. The test uses the very same reference, without falling back on `isRunning` as well.
        guard self.link === link else { return }
        let delta = lastTimestamp == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        onFrame?(max(0, delta))
    }
}
