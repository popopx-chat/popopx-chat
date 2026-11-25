//
//  PopopxScreenCaptureShieldView.swift
//  POPOPX (iOS)
//
//  [top-secret view-once · module four, capture side] two things, one file:
//  1. `PopopxScreenCaptureShieldView`: moves the content into the canvas the system cannot capture,
//     so screen recording / AirPlay / a capture card see black, while the naked eye sees something normal.
//  2. `PopopxCaptureMonitor` + `PopopxScreenCapture`: asks once per 60Hz frame "am I being captured right now",
//     plus two system notifications (screenshot, entering background), and produces `PopopxSecurityAlert`.
//
//  ### Where the shielding comes from (a mechanism, not mysticism)
//  Once `UITextField.isSecureTextEntry = true` is set, UIKit stops drawing the text with the field itself and starts a separate
//  private subview (`_UITextLayoutCanvasView`) to carry the text layer. That layer is marked by the system as "sensitive content"
//  and never enters the screen-capture buffer — why the keyboard stays out of recordings and password fields out of screenshots is this same road.
//  The only thing we do is put the SwiftUI content into that canvas as a subview, so the content inherits the canvas's exemption.
//
//  ### The boundary of the claims (only sentences that can prove themselves; this section may not be simplified to the words "anti-screenshot")
//  Covered (every one of them measured on a real device; "presumably" is not accepted):
//  - system built-in recording (ReplayKit, the Control Center long recording), AirPlay mirroring, wired digital audio/video capture: these paths share one
//    Surface composition, and content inside the canvas simply never enters that frame;
//  - the task-switcher snapshot and static screenshot's **content part** (same as above, but we do not claim separate credit for this path — see `.screenshotTaken` below).
//  Not covered, and the copy may not hint that it is:
//  - **another device photographing the screen**. The light is still on the panel and the shield cannot do one byte about that (that is `PopopxGlareDetector`
//    and `PopopxCameraGuardEngine`'s job, plus `PopopxAntiPhotoRenderView`'s time-sliced dot matrix);
//  - **capture the system does not know about**: jailbreak injection, modified firmware, hardware splitting the display signal out again. The criterion is "does the system admit
//  it is capturing"; if the system does not admit it there is no flag that can be read;
//  - **frames already recorded**. `.screenCaptured` can only make later frames black / destroy the message, it cannot reclaim the previous 0.5 seconds;
//  - the screenshot key combination itself produces no black-screen guarantee — so that path trips the fuse via `userDidTakeScreenshotNotification`
//    and falls back on destruction, not on shielding.
//
//  ### ⚠️⚠️ Private API and the App Store listing red line (2.5.1) — this block may not be "optimised" away ⚠️⚠️
//  The mechanism above depends on a **private view class**: underscore-prefixed, absent from every header, and Apple can rename it or change its structure at any time.
//  - The App Store review guidelines **2.5.1 explicitly forbid calling private APIs / private frameworks**. A static scan hits it just by matching the class-name string,
//    so "bet that the scan misses it" is not a grey-area manoeuvre, it is an operation that must go wrong.
//  - To this day Apple provides **no** public API that lets an app itself declare "exclude this view from screen capture".
//    iOS 18's "Protect Sensitive Information" (the system automatically masking during AirDrop / screen sharing) is **the system's own policy switch**,
//    it only applies to input interfaces the system judges security-sensitive, and it is not an exclusion interface handed to third-party apps.
//  - The conclusion, nailed down here: this file belongs to the **sideload / open-source build**, not to the App Store submission. To submit, the whole block must be replaced by
//    "detect + trip the fuse + destroy" (`PopopxCaptureMonitor`'s half is pure public API and can stay; the shielding half must be deleted).
//  - And precisely because it is a private surface, this file's attitude to it is "usable but not trusted": class-name criteria, re-mounting on every layout round, falling back to normal rendering when it is not found.
//    No assumption of the kind "this canvas will certainly be there" may ever be written into the code.
//
//  ### Threading and ownership contract
//  - The shield layer: both `UIViewRepresentable` methods run on the main thread; the host `UIHostingController` is strongly held by the Coordinator
//    (UIKit does not keep our content in the canvas on our behalf).
//  - `PopopxCaptureMonitor`: `@MainActor`, **held by `PopopxSecureWindowManager` for as long as the sheet lives**,
//    and `stop()` must be called before the sheet closes (`stop()` breaks `onAlert`, stops the ticker and removes the notification observers).
//    - It holds the window only **weakly**: the manager holds the window, the window holds the content, and the content holding the manager back would form a cycle.
//  - `PopopxScreenCapture`'s two criteria: written for main-thread calls (UIKit's trait/screen state never promised cross-thread consistency anyway),
//    but no `@MainActor` — the pre-check happens where there is "no window yet, no actor context", and putting an actor on it would force callers into
//    `Task { @MainActor in … }` just to ask "can I present right now". This convention is the same kind of convention as `PopopxFrameTicker`'s.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts modifying project.pbxproj.
//

import SwiftUI
import UIKit

// MARK: - Shield container

/// Puts the content into the canvas the system cannot capture. The implementation carrier of the full-screen black shield.
///
/// In usage it is just a transparent container: the content takes whatever size it is given (`maxWidth/maxHeight = .infinity`),
/// and the background colour is the caller's surface's business — the shield layer never paints itself, otherwise "the black under the message" gains one more source.
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

/// The bridging layer. The only thing the SwiftUI side does is hand the content to a `UIHostingController` and then let the field
/// move its view into the canvas; SwiftUI itself has no "exclude from capture" hook to go through.
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
        // Re-mount only when the host view changed (which almost never happens); on the normal path this is one reference comparison.
        if let hosted = context.coordinator.hostedContentView, !field.isHosting(hosted) {
            field.hostSecureContent(hosted)
        }
    }

    /// Holds the host controller strongly: the canvas only knows a view, and nobody else takes over the controller's lifetime.
    ///
    /// Deliberately does **not** `addChild` it to some UIViewController — in a `UIViewRepresentable` there is no such thing as
    /// "the controller this view belongs to", and at `makeUIView` time there is not even a window. One less parent-child link means
    /// traits (dark mode, content size category) propagate along the view chain rather than the controller chain, which UIKit does support;
    /// what it buys is not having to guess which ancestor controller is the nearest one.
    final class Coordinator {
        private let controller: UIHostingController<Content>?

        init(content: Content) {
            controller = UIHostingController(rootView: content)
            // The shield layer carries no background colour of its own: see the documentation of `PopopxScreenCaptureShieldView`.
            controller?.view?.backgroundColor = .clear
        }

        var hostedContentView: UIView? { controller?.view }

        func setContent(_ content: Content) {
            controller?.rootView = content
        }
    }
}

/// The secure text field that carries the canvas.
///
/// Four rules decide the shape of this class, each corresponding to the mechanism section above:
/// 1. `isSecureTextEntry = true` is the precondition for the canvas to exist, and the only source of the switch;
/// 2. assigning `text` once is what makes UIKit actually **build** that canvas (with empty text it is too lazy to build it); it is cleared immediately after building,
///    so the dot never appears on screen — for the cost and risk of clearing, see `clearTriggerTextIfCanvasSurvives(with:)`;
/// 3. `isHidden` must be false: a hidden field never reaches the step that builds the canvas;
/// 4. `isUserInteractionEnabled = false` is a hard constraint from the prompt (it is at the same time the laziest guarantee of "the keyboard never pops up and no selection handles appear").
///    The side effect is that `UIView`'s default hit testing removes the **whole subtree** because of this one flag,
///    so buttons, scrolling and long presses inside the canvas all become untappable. Below, an override of `hitTest(_:with:)` confines the non-interactivity
///    to the field's own level — the flag is not changed and the constraint is not changed, only the hit test keeps drilling further down.
private final class PopopxSecureCanvasField: UITextField {
    /// The placeholder text used to trigger building the canvas. One space: close to zero width, and under `textColor = .clear` it produces no visible pixel.
    private static let triggerText = " "

    private var hostedContentView: UIView?
    private weak var attachedCanvas: UIView?
    /// It means only "the canvas could not be found at the last determination", used to make the degraded rendering idempotent (this determination re-runs on every layout round).
    private var rendersNormally = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureAsSecureCanvasHost()
    }

    /// On the normal path this view is only created by code. The archive path is kept here instead of a `fatalError` so that "one day somebody
    /// pulls it out of a xib" shows up as "the shielding may fail but the interface is normal", not a crash during decoding — a top-secret sheet
    /// that crashes during archive decoding is harder to diagnose in the field than one that has no defence at all.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAsSecureCanvasHost()
    }

    /// Both inits run the same configuration, to avoid problems like "the archive one forgot to set one flag" that only a device can reveal.
    private func configureAsSecureCanvasHost() {
        isSecureTextEntry = true
        isUserInteractionEnabled = false
        isHidden = false
        textColor = .clear
        text = PopopxSecureCanvasField.triggerText
        // The placeholder text should not take part in any layout calculation.
        font = UIFont.systemFont(ofSize: 1)
        adjustsFontSizeToFitWidth = false
        backgroundColor = .clear
        clipsToBounds = false
        // The field itself should not be read out by VoiceOver as a "text field"; turning off this element does not affect the SwiftUI accessibility elements in the subtree.
        isAccessibilityElement = false
        accessibilityTraits = .none
    }

    // MARK: Layout and mounting

    /// No intrinsic size wanted: a UITextField with text reports a very small intrinsic size from the text,
    /// which would shrink the shield into a tiny capsule — the content is still protected, but what the user sees is a grain of text.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    /// Same as above: when asked "how big do you want to be", the answer is "as big as you give me".
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        size
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachHostedContentIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The layout round that enters the window may come before mounting (or may not _follow_ it at all): both paths point at the same idempotent entry.
        attachHostedContentIfNeeded()
    }

    /// Takes the content to be moved into the canvas. Handing over the same view repeatedly is a no-op, and `updateUIView` calls it every frame.
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

    /// Hit testing drills down to the host content (see item 4 of the class documentation).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isHidden == false, alpha > 0.01, !isUserInteractionEnabled,
              let hosted = hostedContentView
        else {
            return super.hitTest(point, with: event)
        }
        return hosted.hitTest(convert(point, to: hosted), with: event)
    }

    /// Belt and braces: even if hit testing one day steers focus onto the field itself, it cannot become first responder (the keyboard never pops up).
    override var canBecomeFirstResponder: Bool {
        false
    }

    // MARK: Canvas resolution

    /// Runs on every layout round: after `super.layoutSubviews()` UIKit may re-lay out that canvas according to the text size,
    /// so a one-off mount does not hold under that premise. The function must be idempotent, and the normal path costs a few reference comparisons.
    private func attachHostedContentIfNeeded() {
        guard let hosted = hostedContentView, window != nil, bounds.width > 0, bounds.height > 0 else {
            return
        }
        // (1) The chain is still there: only pull the size back.
        if let canvas = attachedCanvas, canvas.superview === self, hosted.superview === canvas {
            canvas.frame = bounds
            hosted.frame = CGRect(origin: .zero, size: canvas.bounds.size)
            return
        }
        // (1') It has already been determined that "this device's UIKit has no canvas we recognise": the content sits in our own subviews,
        // so it only needs to follow the layout instead of being searched for again every round.
        if rendersNormally, hosted.superview === self {
            hosted.frame = bounds
            return
        }
        attachedCanvas = nil
        hosted.removeFromSuperview()
        // (2) Look for the canvas.
        guard let canvas = PopopxSecureCanvasField.resolveCanvas(in: self) else {
            renderNormally(with: hosted)
            return
        }
        // (3) Attach it, and stretch the canvas to fill the field. The private view's internal layout is no contract, so the size is something only we can guarantee;
        //     conversely we do not touch its `clipsToBounds`, leaving UIKit to be the authority over this layer.
        canvas.addSubview(hosted)
        hosted.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.frame = bounds
        hosted.frame = CGRect(origin: .zero, size: canvas.bounds.size)
        attachedCanvas = canvas
        rendersNormally = false
        clearTriggerTextIfCanvasSurvives(with: canvas)
    }

    /// Class-name criterion + fallback.
    ///
    /// No subscripting (`subviews.first?.subviews.first`): the subview order was never a contract,
    /// and the failure shape of an order criterion is especially bad — the content gets mounted into a view that **still takes part in capture as usual**,
    /// everything looks normal on screen, everything looks normal in the screenshot, and only the log shows that nothing happened.
    /// The failure shape of the class-name criterion is "not found", which is exactly the one kind this file can respond to safely.
    private static func resolveCanvas(in field: UIView) -> UIView? {
        for candidate in field.subviews where isCanvas(candidate) {
            return candidate
        }
        for child in field.subviews {
            for candidate in child.subviews where isCanvas(candidate) {
                return candidate
            }
        }
        // Fallback: the deepest level inside the secure field's subtree.
        // Said plainly what the fallback buys: it buys "the content still renders inside the secure field, no crash and no blank",
        // it does **not** buy shielding — only the two class names above being hit means that canvas was obtained.
        return deepestSubview(of: field)
    }

    private static func isCanvas(_ view: UIView) -> Bool {
        NSStringFromClass(type(of: view)).hasSuffix("_UITextLayoutCanvasView")
    }

    /// Descends level by level with a depth cap of 8: guards against a self-loop in the private implementation, or a shared view being hung back up the chain.
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

    /// Clears the placeholder text that triggered the build — not one dot should be left on screen.
    ///
    /// But it cannot be cleared blindly: on some iOS versions the text is the precondition for the canvas existing, and clearing it makes UIKit take the canvas back too,
    /// and at that moment the content really does "disappear" (worse than degrading). So right after clearing, verify once that the canvas is still inside the field's subtree,
    /// and if it is not, flip the switch back; flipping it back stays invisible, because `textColor = .clear` and the host content sits on top of it.
    private func clearTriggerTextIfCanvasSurvives(with canvas: UIView) {
        guard let current = text, current.isEmpty == false else { return }
        text = ""
        if canvas.superview !== self {
            text = PopopxSecureCanvasField.triggerText
        }
    }

    /// Canvas not found → render normally.
    ///
    /// This is the most important degradation in this file: **never let the message become invisible just because the shield could not be obtained**.
    /// In front of the user there are only two options, "read the content but it may get recorded" and "read nothing at all", and the first is the acceptable one,
    /// because being recorded has `PopopxCaptureMonitor`'s fuse and destruction as a fallback, while "reading nothing" has no fallback at all.
    ///
    /// Deliberately **no** `.accessibilityHint`, no toast and no log line:
    /// - an accessibility hint would read "on this device the shielding has failed" out loud to anyone holding the phone, and write it into an accessibility tree that programs can read
    ///   — that is a free status broadcast handed to an attacker;
    /// - a toast or a log line would leave one more sentence unrelated to the body text on a top-secret screen, while this screen's whole design goal is to leave fewer words.
    /// The failure is detected by hand, once before shipping: open a top-secret message with screen recording running and see whether that path is black.
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

// MARK: - Capture monitoring

/// 60Hz frame-by-frame polling + system notifications, producing `PopopxSecurityAlert`. Held by the window manager while the sheet lives.
///
/// Three signals and one edge rule:
/// - read the capture state every frame: the `false → true` transition fires `.screenCaptured`;
/// - `userDidTakeScreenshotNotification` → `.screenshotTaken` (the screenshot key combination, the only entry point in public API);
/// - `didEnterBackgroundNotification` → `.leftForeground` (from this moment the task-switcher thumbnail is no longer under control).
///
/// **All triggered on edges**: if 60Hz polling fired an event every frame that would be 60 alerts a second pouring into `onAlert`,
/// and what the `onAlert` side does is destroy the message + send a receipt — that turns the circuit breaker into a DoS target,
/// and the receipts would also queue up on the network. `lastCaptured` records only "the value the last poll saw",
/// so one capture session produces only one `.screenCaptured`.
@MainActor
final class PopopxCaptureMonitor: NSObject {
    /// The alert outlet. It must be nil after `stop()`: once the manager has disconnected, no callback should still come in.
    var onAlert: ((PopopxSecurityAlert) -> Void)?

    /// Holds the window only weakly (see the ownership contract at the top of the file).
    private weak var window: UIWindow?

    private var ticker: PopopxFrameTicker?
    private var lastCaptured = false
    private var observersInstalled = false

    /// Whether it is being captured at this moment. Read synchronously, and it **does not** start or change the polling; the cost is walking the scene table on every call.
    var isCapturedNow: Bool {
        PopopxScreenCapture.isCaptured(in: window)
    }

    /// Attaches the CADisplayLink + notifications. Idempotent: repeated calls never create a second 60Hz source and never register observers twice.
    func start(in window: UIWindow?) {
        self.window = window
        installObservers()
        if ticker == nil {
            let ticker = PopopxFrameTicker(framesPerSecond: 60)
            // The closure is only called on the main thread (`PopopxFrameTicker`'s convention), so the state can be read synchronously here;
            // the weak capture is there not to close the manager → monitor → ticker → closure → manager cycle.
            ticker.onFrame = { [weak self] _ in
                self?.pollCaptureStateOnce()
            }
            ticker.start()
            self.ticker = ticker
        }
        // First record the current value once: the caller already pre-checked with `PopopxScreenCapture.anyScreenIsCaptured` **before opening the sheet**
        // and refused, so if it is already "capturing" at this point, counting that as a false→true edge would destroy a message the user has not even seen again.
        lastCaptured = PopopxScreenCapture.isCaptured(in: window)
    }

    /// Idempotent stop: stops the ticker (breaking `onFrame` along the way), removes the observers, releases `onAlert`.
    /// Listening again afterwards requires a fresh `start(in:)` and a fresh assignment of `onAlert` — this is deliberate:
    /// a monitor that "comes back to life carrying its old callback" cannot be reused safely.
    func stop() {
        ticker?.stop()
        ticker = nil
        NotificationCenter.default.removeObserver(self)
        observersInstalled = false
        onAlert = nil
        lastCaptured = false
        window = nil
    }

    // MARK: Polling

    private func pollCaptureStateOnce() {
        let captured = PopopxScreenCapture.isCaptured(in: window)
        defer { lastCaptured = captured }
        guard captured, !lastCaptured else { return }
        onAlert?(.screenCaptured)
    }

    // MARK: System notifications

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

    /// Screenshot: the system posts this one only after the user really pressed the key combination (or a three-finger gesture, an Apple Pencil screenshot, the kinds of screenshot the system recognises)
    /// . It is an **after-the-fact** notification — the image has already landed in the photo library / clipboard. So the value of this tier lies entirely in the fuse:
    /// destroy and send a receipt immediately, rather than "prevent the screenshot".
    @objc private func screenshotNotified() {
        onAlert?(.screenshotTaken)
    }

    /// Entering background: from this moment the snapshot cache and the task-switcher thumbnails are no longer under our control.
    /// Use `didEnterBackground` rather than `willResignActive`: the latter also fires when a notification banner is pulled down, on the Control Center,
    /// or the Face ID prompt — moments when "the screen has not been handed to anybody else" — and destroying on those would turn normal use into collateral damage.
    @objc private func didEnterBackgroundNotified() {
        onAlert?(.leftForeground)
    }

    deinit {
        // `stop()` is a main-actor isolated method and cannot be called from deinit (Swift forbids it explicitly), so inside deinit only
        // this one action that needs no isolated context is performed. NotificationCenter's observers are registered per object, and removing them does not touch any
        // stored property. The CADisplayLink needs no care: `ticker` is released together with this object, and `PopopxFrameTicker.deinit`
        // takes the link off the runloop by itself.
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Static criteria

/// Static criteria for the "pre-check" before opening the sheet (there is no window yet, so it has to be askable with nothing).
///
/// The capture criteria use public API only, and this type contains not one line of private surface — which is also why it is the only part of this file that can be moved wholesale into the submitted build.
enum PopopxScreenCapture {
    /// Any screen this app currently occupies is being captured. Use this one when there is no window to ask (the pre-check, the settings-page switch explanation).
    static var anyScreenIsCaptured: Bool {
        UIApplication.shared.connectedScenes.contains(where: sceneIsCaptured(_:))
    }

    /// The screen the given window sits on takes priority, and the remaining screens get a sweep as a fallback.
    ///
    /// Why **polling** rather than `UIScreen.isCapturedNotification` or KVO (this is a design decision, not a shortcut):
    /// - that notification is posted **per UIScreen**, its documented semantics are "this screen's mirroring/capture state changed", and it promises nothing
    ///   about the scene-level criterion from iOS 17 onwards (`UITraitCollection.sceneCaptureState`),
    ///   and on the multi-screen / external display side it may not be posted at all;
    /// - KVO is worse: `isCaptured` is a computed property that asks the kernel every time, with no KVO-compliance documentation,
    ///   and relying on it means resting a security criterion on "it happens to send willChange";
    /// - notifications are delivered asynchronously, while this criterion wants "from the system starting to capture to us tripping the fuse, at most a few milliseconds apart" —
    ///   only frame-by-frame reading nails the upper bound to a single display frame (≈16.7ms at 60Hz).
    /// The cost of one read: walking the scene table (normally 1 entry) + one trait query + one BOOL read, which can be paid every frame.
    static func isCaptured(in window: UIWindow?) -> Bool {
        guard let window else { return anyScreenIsCaptured }
        // The window's own trait is the nearest first-hand information (UIKit recomputes it when a scene changes screen).
        if window.traitCollection.sceneCaptureState == .active { return true }
        guard let scene = window.windowScene else { return anyScreenIsCaptured }
        if scene.traitCollection.sceneCaptureState == .active { return true }
        if scene.screen.isCaptured { return true }
        // Sweep the other scenes too: the top-secret window may sit on screen A while the capture happens on screen B of the same device, and it is still a capture.
        return anyScreenIsCaptured
    }

    /// The scene-level criterion (the correct answer on iOS 17+) takes priority, and the screen-level legacy flag patches the gaps.
    ///
    /// Both are needed because their taking-effect timing is not guaranteed to agree: the trait propagates per scene, and the instant AirPlay is connected
    /// it may still be `.unspecified`; `screen.isCaptured` is the old screen-level flag whose header already states "use `sceneCaptureState` instead"
    /// (the marker is to-be-deprecated, the Swift side raises no warning for it today, and the value is still produced).
    /// `.unspecified` is never treated as "not capturing" — the criterion takes the union, and false positives are absorbed by the caller's fuse cost (destroying one message),
    /// while a missed detection is something nobody can make up for.
    private static func sceneIsCaptured(_ scene: UIScene) -> Bool {
        guard let windowScene = scene as? UIWindowScene else { return false }
        if windowScene.traitCollection.sceneCaptureState == .active { return true }
        return windowScene.screen.isCaptured
    }
}
