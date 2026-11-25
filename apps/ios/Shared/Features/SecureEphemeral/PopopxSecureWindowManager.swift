//
//  PopopxSecureWindowManager.swift
//  POPOPX (iOS)
//
//  [Module 5's host side] Standalone window + biometrics pre-check + destruction orchestration.
//
//  This is the only place in the whole feature that "owns a plaintext once". The plaintext is born at `payload.open()` and dies at
//  `popopxSecureErase`, held throughout by this class's one `Data?` alone; `PopopxSecureSheetModel`
//  gets an **already decoded String** (a value type that disappears together with the window), and the list only ever holds ciphertext rows.
//  "sole holder" is not a style question: one more holder is one more place that can forget to erase.
//
//  ### Why the host contract goes through the `.shared` singleton instead of Environment
//  Physically deleting the record and sending the acknowledgement must be provided by the host (`apiDeleteChatItems` / `apiSendMessages` are both in the app target),
//  and SwiftUI's Environment **cannot hold closures** (a closure has no stable identity, and every write invalidates the whole subtree —
//  `swiftui-expert-skill`'s hard rule). Therefore:
//  - the bubble view only needs a `PopopxSecurePayload` (a pure value), and rendering needs no host;
//  - tapping the card runs `await PopopxSecureWindowManager.shared.present(payload:target:)`,
//    whose argument is a pure-value `PopopxSecureChatTarget`, and **the return value is the failure reason**: the card is the place the user tapped,
//    so the feedback must land there, not on a window that has not appeared yet;
//  - the closures (deletion, sending the acknowledgement) are installed once with `install(host:)` in `POPOPXApp.init()`, the same shape as this repository's
//    `PopopxMeshRuntime.shared` / `ChatModel.shared`.
//  A side benefit: the whole `Shared/Features/SecureEphemeral/` directory imports no app type,
//  so `swiftc -typecheck` can verify it outside the Xcode project — in this repository that amounts to testability for free.
//
//  ### fail-closed: if it cannot be installed it is not shown
//  When `hostHooks == nil`, `present` returns `.hostNotInstalled` directly. Reason: a top-secret message that "cannot be destroyed after reading
//  and cannot send an acknowledgement when something goes wrong" is more dangerous than a message nobody sees — it makes people believe this mechanism is working.
//  A Release build attached by a debugger (`PopopxAntiDebug.allowsSecurePresentation == false`) is refused on the same grounds.
//
//  ### Two state flags, each with its own reason to exist
//  - `isSessionActive`: the plaintext and the side channels (countdown, camera attendance, screen-recording polling) are still alive.
//    It is the first statement in **every** inbound callback.
//  - `isWindowOpen`: the window still exists. After a destruction alert has run "erase plaintext + delete record + send acknowledgement", the window is kept a further
//    `burnLingerSeconds` so that "why it closed" can be finished; during that time the session is already dead but the window is still open.
//  Merging them into a single flag would immediately produce two bug classes: either the user cannot see the destruction reason, or during the three lingering seconds
//  a second tap on the card opens a second session (which is why `present` tests `isWindowOpen`, not `isSessionActive`).
//
//  ### The countdown uses a monotonic clock
//  `ProcessInfo.processInfo.systemUptime` (counted since boot, includes sleep, changing the system time does not affect it).
//  With a wall clock, setting the time back one hour would let you read a top-secret message for free — this is the thing in this feature easiest to write wrong casually
//  and hardest to spot in review, so it is written in the file header.
//  The honest boundary: while the app is suspended this path gets no ticks, so the plaintext lives past the TTL in the background until the process resumes.
//  That is exactly the reason `leftForeground` destruction exists by default; see `PopopxSecureSettings.destructiveOnBackground`.
//
//  ### Three verified UIKit facts (all three were written wrong in version one and corrected against the SDK headers)
//  - A standalone window uses `UIWindow(windowScene:)` (iOS 13+). `initWithFrame:` is marked deprecated from iOS 26,
//    and `UIWindow(screen:viewerIdentifier:)` simply does not exist at this project's iOS 17 floor.
//  - `UIWindow.Level` is a `CGFloat` typed extensible enum and **does not support `+`**:
//    `.alert + 1` does not compile, so you must go through `UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)`.
//  - A `@MainActor` class's `deinit` is **not** a main-thread isolation domain: calling actor methods inside it is a hard error
//    (rejected under `-swift-version 5` as well), so the wrap-up can only go through `dismissSecureWindow()`.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import AVFoundation
import LocalAuthentication
import SwiftUI
import UIKit

// // MARK: - Host contract

/// Where a top-secret message sits in the host's data model. A pure value containing no app type: so this directory can be type-checked outside the project,
/// and the host (`PopopxBubbleMount` on the bubble side) maps the **recipient's own** `ChatInfo.id` in at the call site.
struct PopopxSecureChatTarget: Hashable, Sendable {
    /// The host's chat key, taken verbatim from `ChatInfo.id` (`POPOPXChat/ChatTypes.swift:2104`-`:2112`,
    /// each `ChatInfo` branch supplies it itself, e.g. `"@\(contactId)"`).
    ///
    /// Why only this one cell is carried, rather than `chatType` + `chatApiId` for the host to stitch back together:
    /// assembling a key would mean rewriting `ChatInfo.id`'s implementation inside this feature. Once that implementation drifts from upstream
    /// (for instance upstream changes `contactConnection`'s prefix), the delete request would **silently hit a different chat** —
    /// this is the one direction in this mechanism where being wrong raises no error, so only the value the generating side itself produced is used.
    /// It is looked up through `chatModel.getChat(chatId)`, and `chatType` / `apiId` / the group's `scope` are all on that record.
    let chatId: String
    /// The itemId of that message; nil = the host cannot supply it.
    ///
    /// This cell decides whether "physical deletion" can be done at all. When it cannot be supplied this class **does not lie about deleting**: the overlay states
    /// "plaintext erased, local record not deleted" (see `PopopxSecureCopy.burntWithoutDeletion`).
    /// This is not decoration: showing "it was not deleted" is the precondition for the sentence "this one has already been burned" to remain true.
    let itemId: Int64?

    /// Whether the record to be deleted can be located.
    var isDeletable: Bool { itemId != nil }
}

/// The two things the host must provide, both called on the **main thread**.
struct PopopxSecureHostHooks {
    /// Physically deletes the local record. Host implementation: `apiDeleteChatItems(mode: cidmInternal)` + `ChatModel.removeChatItem`.
    ///
    /// Only responsible for starting, not for waiting: this class does not wait for its result, because "plaintext erased" and "queue deleted" are two different things,
    /// the former already done before the call returns, the latter a network/DB matter.
    var deleteItem: (_ target: PopopxSecureChatTarget) -> Void
    /// Sends one security acknowledgement. The host implementation goes through the existing send chain, so online SMP and offline mesh are both covered automatically.
    var sendReceipt: (_ text: String, _ target: PopopxSecureChatTarget) -> Void
}

/// Session-level security tiers. Deliberately not written to `UserDefaults`: the default of every one of these is "most conservative", and once they became persistable switches
/// one would also have to answer "after the user turns the guard off, should the bubble keep a trace of that" — which is the next feature's scope, not this file's.
struct PopopxSecureSettings: Hashable, Sendable {
    /// Whether `leftForeground` also destroys.
    ///
    /// Even switched off it is still **not** the safe choice: see the file header's "the honest boundary" — while suspended the countdown does not move,
    /// and the plaintext lives past the TTL. So in the UI this tier either cannot be turned off, or turning it off must show that sentence to the user along with it.
    var destructiveOnBackground = true
    /// Whether to start front-camera attendance (module 3). Off = screenshot/screen-recording detection only (module 4).
    var cameraGuardEnabled = true
    /// The whole-tier switch for the CoreML path (when the model was not imported the engine degrades on its own, and this switch is the user's off switch).
    var objectDetectionEnabled = true
    /// The whole-tier switch for the specular-highlight fallback path.
    var glareDetectionEnabled = true
    /// Whether rolling-shutter defence (module 6) is on by default.
    var antiPhotoEnabled = true

    static let `default` = PopopxSecureSettings()
}

/// Reasons a top-secret message cannot be opened. `present` **returns** it for the card that called it to display,
/// it must not be just "tapped and nothing happened".
enum PopopxSecurePresentationFailure: Error, Hashable, Sendable {
    /// The host is not installed. The user cannot see this one (a code integration problem), but it must be searchable in the debug build's logs.
    case hostNotInstalled
    /// The screen is being recorded/mirrored: showing plaintext on a picture that is being recorded is unacceptable.
    case screenCaptured
    /// A debugger attach was detected in a Release build.
    case debuggerAttached
    /// Biometrics unavailable (nothing enrolled, or the system refused).
    case biometricsUnavailable
    /// The user cancelled biometrics.
    case biometricsCancelled
    /// Biometrics failed (no match).
    case biometricsFailed
    /// The ciphertext was altered, the key is wrong, or the length is invalid: the payload itself is broken.
    case payloadDamaged(PopopxSecureError)
    /// No scene can carry the window (the scene is switching, or in a multi-scene state there is no foreground active window).
    case noPresentationContext
    /// One is already being viewed. No queueing, no stacking: two plaintexts on the screen at once is not "view-once".
    case sessionAlreadyOpen

    var userText: String {
        switch self {
        case .hostNotInstalled: return NSLocalizedString("The secure module is not ready, so the secure content was refused", comment: "")
        case .screenCaptured: return NSLocalizedString("The screen is being recorded or mirrored, so it was refused", comment: "")
        case .debuggerAttached: return NSLocalizedString("A debugging environment was detected, so the secure content was refused", comment: "")
        case .biometricsUnavailable: return NSLocalizedString("This device has no usable biometrics, so secure messages cannot be opened", comment: "")
        case .biometricsCancelled: return NSLocalizedString("Verification cancelled", comment: "")
        case .biometricsFailed: return NSLocalizedString("Biometric verification did not pass", comment: "")
        case .payloadDamaged: return PopopxSecureCopy.cardDamaged
        case .noPresentationContext: return NSLocalizedString("The current interface state cannot host a secure window", comment: "")
        case .sessionAlreadyOpen: return NSLocalizedString("A secure message is already being viewed", comment: "")
        }
    }

    /// Whether this card should be marked "damaged" for good. Only mark it when the payload itself is at fault -
    /// the user cancelling the verification, or the screen being recorded, must never turn a normal message into a grey dead block in the list:
    /// that is putting the environment's fault on the message's head, and it hides the fact that "this one is actually still readable".
    var marksCardDamaged: Bool {
        if case .payloadDamaged = self { return true }
        return false
    }
}

// MARK: - Manager

/// The sole owner of the top-secret window. `@MainActor`: the window, biometrics, destruction and UI are all on the main thread;
/// the only thing leaving the main thread is the frame queue of `PopopxCameraGuardEngine`, and it already hops the results back itself.
@MainActor
final class PopopxSecureWindowManager {
    static let shared = PopopxSecureWindowManager()

    /// Whether the plaintext and the side channel are still alive. See "the two status flags" at the file head.
    private var isSessionActive = false
    /// Whether the window exists. `present` uses it to refuse concurrent sessions.
    private var isWindowOpen = false

    private var window: UIWindow?
    private var sheetModel: PopopxSecureSheetModel?
    private var guardEngine: PopopxCameraGuardEngine?
    private var captureMonitor: PopopxCaptureMonitor?
    private var countdownTimer: Timer?
    private var burnTimer: Timer?
    private var foregroundObserver: NSObjectProtocol?
    private var hostHooks: PopopxSecureHostHooks?
    private var settings = PopopxSecureSettings.default

    /// The message this session corresponds to. Kept in the manager rather than in the model: on the destruction path the model may already have been detached by SwiftUI,
    /// and "which record to delete" must not be lost along with the UI.
    private var activeTarget: PopopxSecureChatTarget?

    /// The sole holder of the plaintext. `private`, no getter: the only way to get the plaintext from outside is the already-decoded String inside `sheetModel`,
    /// and it is released together with the window.
    private var plaintext: Data?

    /// Deadline (`systemUptime` seconds). 0 = no session.
    private var deadlineUptime: Double = 0

    private init() {}

    deinit {
        // This class is the `shared` singleton, so it normally never deinits.
        //
        // Here you **must not** call `captureMonitor?.stop()` / `guardEngine?.stopMonitoring()` / `stopChannels()`:
        // the `deinit` of an `@MainActor` class is not inside the main-thread isolation domain, and Swift judges that as an error rather than a warning
        // (the first version was written exactly like that and was blocked by the type checker). This is exactly the enforced form of
        // the convention that "cleanup must go through `dismissSecureWindow()`"; the real release happens in `dismissSecureWindow()` and in those two objects' own
        // `deinit`s (`PopopxCameraGuardSession` and `PopopxFrameTicker` each carry a reclaim assertion).
        //
        // The two isolation-free things that can and should be done: erase the plaintext, and stop the timer.
        popopxSecureErase(&plaintext)
        countdownTimer?.invalidate()
        burnTimer?.invalidate()
    }

    // MARK: Assembly

    /// The host installs once in `POPOPXApp.init()`; that is enough. A later install overwrites an earlier one: the app may have several host scenes,
    /// and the one assembled last is the one currently in effect.
    func install(host: PopopxSecureHostHooks, settings: PopopxSecureSettings = .default) {
        hostHooks = host
        self.settings = settings
    }

    // MARK: Presenting

    /// Runs all the prechecks and presents the top-secret window. Returning nil = shown; returning a failure reason = nothing was opened.
    ///
    /// The order is deliberate, and every step can refuse:
    /// 1. whether a window is up (including the lingering period, hence the `isWindowOpen` check)
    /// 2. whether the host is installed (refuse if it is not; see fail-closed at the file head)
    /// 3. whether the screen is being recorded - one synchronous read of `isCaptured` refuses one frame earlier than waiting for the 60Hz poll
    /// 4. anti-debug
    /// 5. camera permission (asked here only when it has never been asked; see the comment below - it must come before the window)
    /// 6. take the window scene (refuse if there is none, no "fall back to the first screen"); it comes after the permission,
    ///    because the permission dialog can hang for an uncertain time and the scene should only be taken at the very moment the window is really opened
    /// 7. biometrics
    /// 8. **decryption comes after the check passes and before the window is shown**, with no await in between:
    ///    decrypting before verifying leaves the plaintext alive for an extra stretch nobody is watching, and during the few hundred milliseconds
    ///    of the FaceID dialog there should be no content on the screen at all.
    /// 9. the camera guard and the screen-recording poll start only after the window is visible - the landing point of the hard constraint "runs only while the dialog is visible".
    func present(payload: PopopxSecurePayload, target: PopopxSecureChatTarget) async -> PopopxSecurePresentationFailure? {
        guard !isWindowOpen else { return .sessionAlreadyOpen }
        guard hostHooks != nil else { return .hostNotInstalled }
        guard !PopopxScreenCapture.anyScreenIsCaptured else { return .screenCaptured }
        guard PopopxAntiDebug.allowsSecurePresentation else { return .debuggerAttached }

        // The camera permission must be asked here, not by waiting for `startMonitoring()` to report `.permissionNotDetermined`:
        // that chain only reads the status and never starts authorization, so if we do not ask on our own initiative, on a freshly installed machine the picture-level guard
        // **never turns on** (the system dialog offers one chance only, and it can be triggered only by `requestAccess`).
        // And it must come before the window: the top-secret window's level is `.alert + 1`, so the permission box would be pressed underneath it,
        // and the user would neither see the box nor be able to tap "Allow".
        if settings.cameraGuardEnabled,
           AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            await Self.awaitCameraAccess()
        }

        guard let scene = Self.currentWindowScene() else { return .noPresentationContext }

        switch await verifyBiometrics() {
        case .success: break
        case .cancelled: return .biometricsCancelled
        case .unavailable: return .biometricsUnavailable
        case .failed: return .biometricsFailed
        }

        var opened: Data
        do {
            opened = try payload.open()
        } catch let error as PopopxSecureError {
            return .payloadDamaged(error)
        } catch {
            return .payloadDamaged(.decryptionFailed)
        }
        // Decoding + UTF-8 validation are finished inside the same synchronous section, so the exposure window of `plaintext` equals the lifetime of the window itself.
        guard let text = String(data: opened, encoding: .utf8), !text.isEmpty else {
            popopxSecureErase(&opened)
            // This is not `decryptionFailed`: reaching this line means the tag has already been verified and the key is exactly this message's key.
            return .payloadDamaged(.unusablePlaintext)
        }

        isSessionActive = true
        isWindowOpen = true
        plaintext = opened
        activeTarget = target
        deadlineUptime = ProcessInfo.processInfo.systemUptime + Double(payload.ttlSeconds)

        let model = PopopxSecureSheetModel(
            text: text,
            totalSeconds: payload.ttlSeconds,
            antiPhotoEnabled: settings.antiPhotoEnabled,
            close: { [weak self] in self?.closeAndBurn() }
        )
        sheetModel = model

        let controller = UIHostingController(rootView: PopopxSecureShieldedContent(model: model))
        // The background must be black: `UIHostingController`'s default colour is system grey, and the top-secret window wants "all black except the content",
        // and the shield view paints a black ground itself too - leaving a grey system background is leaving a hole where "outside the content area is not pure black".
        controller.view.backgroundColor = .black
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        // `.alert + 1`: the top-secret window must sit above every dialog inside the app (photo album/location pickers, system permission boxes),
        // otherwise one system dialog would cover the plaintext underneath while the countdown keeps going, and the user coming back would see only "destroyed".
        // `UIWindow.Level` does not support `+`, so this goes through rawValue.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        // Appearance follows the host window: a standalone window takes the device appearance by default, and this would be out of step when the app forces light/dark.
        // It must be read **before** `isHidden = false`, otherwise it reads itself (we are already the keyWindow).
        window.overrideUserInterfaceStyle = Self.inheritedInterfaceStyle(from: scene)
        window.isHidden = false
        self.window = window

        startSideChannels(in: window, model: model)
        startCountdown()
        PopopxHaptics.notice(.success)
        return nil
    }

    // MARK: Extending the viewing window

    /// The only entry point for "extend the anti-peeping window with credits". Called by the one button inside the window; the view does not move the clock itself.
    ///
    /// Neither the duration nor the price is written out again here: both come from that single place in `PopopxCommerceLimits`
    /// (`extendedSecureWindowSeconds` / `extendedSecureWindowCost`), and the latter is the very same number the deduction side uses.
    /// Until now these two fields had no consumer at all in the code; with this chain connected, "how long the extension lasts" and "how many credits are spent"
    /// for the first time sit under the same truth as the words written on the button.
    ///
    /// The order is **first confirm the session is still alive, then deduct, then move the clock**; all three steps are on the main thread with no `await` in between,
    /// so the whole block is one synchronous unit: neither "the credits were taken but the clock did not move", nor the other way round.
    /// The session check must come before the deduction: during those lingering seconds the window is still there but `isSessionActive` is already false,
    /// and pressing then can only get "there is no session left to extend" - it must not take the credits.
    ///
    /// Only this device's side of the clock moves: the `ttl` in the payload is minted by the sender, and an extension writes back into no message,
    /// changes none of the other side's receipts and produces no signalling either - the credits centre's "only affects rendering on this device" describes exactly this shape.
    ///
    /// Returns nil = extended; otherwise a sentence that can be displayed directly. The insufficient-credits sentence comes from the ledger itself,
    /// and the balance is not copied a second time here: two places each stating a balance is where this kind of page forks most easily.
    func extendViewingWindow() -> String? {
        guard isSessionActive, isWindowOpen, let model = sheetModel, model.isReading else {
            return PopopxSecureCopy.extendWindowClosed
        }
        do {
            _ = try PopopxCreditsManager.shared.purchaseExtendedSecureWindow()
        } catch {
            return error.localizedDescription
        }
        let seconds = PopopxCommerceLimits.extendedSecureWindowSeconds
        deadlineUptime += Double(seconds)
        model.extendTotal(by: seconds)
        // Run one tick immediately: the `Timer`'s next fire waits a full interval, and during that time `remainingSeconds`
        // is still the pre-extension number while `totalSeconds` has already grown, so the progress bar would shrink first and then snap back.
        tick()
        PopopxHaptics.notice(.success)
        return nil
    }

    // MARK: Cleanup

    /// The user closing it on purpose, or the countdown reaching zero: burned the same way - the "burn" of "view-once" is not decided by the user.
    /// No security receipt is sent: finishing a normal read is not a security event, and sending one would only make the other side think something went wrong.
    /// And no lingering is left: there is nothing to explain, and one more black screen only blocks the way.
    private func closeAndBurn() {
        burn(reason: nil, receipt: nil, linger: false)
    }

    /// The only path to burning.
    ///
    /// **Erase first, then delete, then send**: the plaintext is already out of memory before the local record is deleted, so the worst outcome of "delete failed"
    /// is a ciphertext that cannot be opened, not plaintext still sitting in memory.
    /// Take the host closures into local values first: if on the destruction path `hostHooks` becomes nil, `?` would make this message
    /// silently neither deleted nor sent - which is exactly the "the user thinks it was destroyed" scenario.
    ///
    /// `willDestroy` must be read **before** `stopChannels()`: during those lingering seconds the user tapping "OK" walks
    /// through this function again, while "delete the record" and "send the receipt" belong only to the moment the session dies, and happen once.
    /// The consequence of missing this gate is not a crash: **the same message deleted twice, the other side receiving two identical alerts**.
    private func burn(reason: String?, receipt: String?, linger: Bool) {
        guard isSessionActive || isWindowOpen else { return }
        let willDestroy = isSessionActive
        let target = activeTarget
        let hooks = hostHooks
        stopChannels()

        guard willDestroy else {
            dismissSecureWindow()
            return
        }
        let deleted = target?.isDeletable ?? false
        if deleted, let target {
            hooks?.deleteItem(target)
        }
        if let receipt, let target {
            hooks?.sendReceipt(receipt, target)
        }
        sheetModel?.burn(reason: reason, receiptCount: receipt == nil ? 0 : 1, deleted: deleted)

        if linger {
            scheduleBurnTeardown()
        } else {
            dismissSecureWindow()
        }
    }

    /// Closes the top-secret window and **deterministically** releases everything. Idempotent: repeated calls do it once.
    ///
    /// Order: first `stopChannels()` (drop the flag → stop the timers → detach the notifications → stop the poll → stop the guard → erase the plaintext),
    /// then hand the model back, and finally tear down the window.
    /// Erasing the plaintext comes **before** tearing down the window: as `UIHostingController` comes down SwiftUI still reads the view state once,
    /// and that one read must see an already-empty model.
    func dismissSecureWindow() {
        stopChannels()
        guard isWindowOpen else { return }
        isWindowOpen = false

        sheetModel?.invalidate()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        sheetModel = nil
        activeTarget = nil

        #if DEBUG
        // Reclaim assertions: after the session ends these must all be empty. On a real device, problems like "the green dot is still lit" or "the window is still there"
        // all turn into a searchable log line here first.
        print("[popopx.secure] session closed: engine=\(guardEngine == nil) monitor=\(captureMonitor == nil) plaintext=\(plaintext == nil) window=\(window == nil)")
        #endif
    }

    /// Stops only the half that "reads the plaintext and occupies hardware": the countdown, the destruction delay, background notifications, screen-recording polling, the camera guard and the plaintext itself.
    /// The window is left up, not torn down: the destruction alert has to finish saying "why it closed" first.
    ///
    /// The guard stops after the screen-recording poll, and both come **before** erasing the plaintext: those two objects hold callbacks, and the callbacks read the plaintext;
    /// written the other way round you get "the plaintext is gone but frames are still being received", and that receiving chain can still deliver alerts.
    private func stopChannels() {
        guard isSessionActive else { return }
        isSessionActive = false

        countdownTimer?.invalidate()
        countdownTimer = nil
        burnTimer?.invalidate()
        burnTimer = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }

        captureMonitor?.stop()
        captureMonitor = nil
        // For the guard's internal stop order (flag → detach delegate → stopRunning → release the reference) see
        // `PopopxCameraGuardEngine.stopMonitoring()`; here the only job is to stop holding on to it.
        guardEngine?.stopMonitoring()
        guardEngine = nil

        deadlineUptime = 0
        popopxSecureErase(&plaintext)
    }

    /// The burned phase stays a few seconds before the window comes down, so the user can see clearly which class of risk triggered the destruction.
    /// During that time there is no plaintext, no camera and no countdown; all that remains is a black background and one sentence.
    private func scheduleBurnTeardown() {
        let timer = Timer(timeInterval: Self.burnLingerSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissSecureWindow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        burnTimer = timer
    }

    /// 3 seconds. Enough to finish reading two lines of text (the mask copy in `PopopxSecureCopy` runs to about 20 Chinese characters at its longest),
    /// and short enough that nobody thinks the app froze. Pinning it at this point has one more layer: it is shorter than the shortest TTL tier (5 seconds),
    /// so this delay can never make "being destroyed" look like it lives longer than the message itself.
    private static let burnLingerSeconds: TimeInterval = 3

    // MARK: Events

    /// Three sources share one entry point: screenshot/screen recording (module four), the camera guard (module three), the countdown reaching zero.
    private func handle(_ alert: PopopxSecurityAlert) {
        guard isSessionActive else { return }
        let destroys = alert.destroysMessage
            || (alert == .leftForeground && settings.destructiveOnBackground)

        guard destroys else {
            // Lock only, do not destroy: the countdown keeps running (see `PopopxSecureSettings.destructiveOnBackground` for the reason),
            // and the only action at this tier is to close and destroy - "unlock and keep reading" would need another biometrics run,
            // which should be started by the user tapping the card again, not by building another state machine here.
            sheetModel?.lock(reason: alert.reasonText)
            PopopxHaptics.notice(.warning)
            return
        }
        PopopxHaptics.notice(.error)
        burn(reason: alert.reasonText, receipt: alert.receiptText, linger: true)
    }

    // MARK: Side channel

    private func startSideChannels(in window: UIWindow, model: PopopxSecureSheetModel) {
        let monitor = PopopxCaptureMonitor()
        monitor.onAlert = { [weak self] alert in
            Task { @MainActor in self?.handle(alert) }
        }
        monitor.start(in: window)
        captureMonitor = monitor

        // Going to the background = `leftForeground`. The one alert that may be "lock only, no destroy"; see `PopopxSecureSettings` for the reason.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handle(.leftForeground) }
        }

        guard settings.cameraGuardEnabled else {
            model.guardNote = NSLocalizedString("Camera guard is switched off in settings; only screenshot and screen-recording detection is running.", comment: "")
            return
        }
        let engine = PopopxCameraGuardEngine()
        engine.onAlert = { [weak self] alert in
            Task { @MainActor in self?.handle(alert) }
        }
        engine.settings = PopopxCameraGuardSettings(
            objectDetectionEnabled: settings.objectDetectionEnabled,
            glareDetectionEnabled: settings.glareDetectionEnabled
        )
        // Failing to start cannot be treated as nothing happening: which leg is missing, and why, must be shown to the user.
        if let failure = engine.startMonitoring() {
            model.guardNote = failure.reasonText
        } else {
            model.guardNote = engine.startupNote
        }
        guardEngine = engine
    }

    // MARK: Countdown

    private func startCountdown() {
        // Run it once synchronously first: the `Timer`'s first fire waits a full interval, and in those 0.1 seconds the UI would show the minted
        // `remainingSeconds = totalSeconds` rather than the tier the payload really gave.
        tick()
        // A 0.1s `Timer` instead of a 60Hz `CADisplayLink`: what the countdown wants is "destroy when the time is up",
        // and frame-by-frame driving only occupies one extra runloop source, while the displayed number changing once a second is enough.
        // (module six's spotlight/line-by-line rendering really does need frames; over there it uses `PopopxFrameTicker`.)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // The closure does not capture the model: `tick()` reads from `sheetModel` every time, and when the model is gone it simply does no work.
        // Strongly capturing a copy here only adds one more owner to the plaintext's entry object.
        // `.common` mode: it must also run while a finger holds a scroll. Attached to `.default`, the user, in line-by-line reading mode,
        // would find the countdown stopped during the pressing-and-dragging stretch - that is a real path where a message is read for nothing.
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func tick() {
        guard isSessionActive, let model = sheetModel else { return }
        let remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            model.updateRemainingSeconds(0)
            closeAndBurn()
            return
        }
        model.updateRemainingSeconds(Int(remaining.rounded(.up)))
    }

    // MARK: Biometrics

    private enum BiometricResult { case success, cancelled, unavailable, failed }

    /// Uses `.deviceOwnerAuthenticationWithBiometrics`, and does **not** reuse the app's existing `systemAuthenticate`:
    /// that one allows the device passcode, and a passcode can be watched being typed by a bystander, which conflicts head-on with "top-secret".
    /// Better that someone with no enrolled biometrics cannot read it than downgrading to a passcode.
    ///
    /// The `LAContext` result is not cached: caching it once amounts to downgrading biometrics into a launch-time gate,
    /// while the risk window of a top-secret message is in **every single view**.
    private func verifyBiometrics() async -> BiometricResult {
        let context = LAContext()
        var statusError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &statusError) else {
            return .unavailable
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: PopopxSecureCopy.biometricReason
            ) ? .success : .failed
        } catch let error as LAError {
            switch error.code {
            // Cancel = the user never meant to look. That and "cannot be opened" are two different things: the UI gives one "try again" and the other "this one is already ruined".
            case .userCancel, .systemCancel, .appCancel, .userFallback:
                return .cancelled
            // This device cannot offer biometrics: no downgrade to a passcode (see the comment above), refuse outright.
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet:
                return .unavailable
            // The rest (.authenticationFailed / .invalidContext / .notInteractive and anything added later)
            // are all handled as "this time it did not pass", without guessing each one's specific meaning.
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    // MARK: Environment resolution

    /// The scene that carries the window. When no active scene can be found it returns nil so the caller **refuses to present**,
    /// instead of "falling back to the first screen" - a top-secret window opened on another screen is throwing the plaintext onto someone else's table.
    /// The residual risk is already closed off: the external-screen/mirroring leg is refused before presenting by `isCaptured` (step 3 of the order),
    /// so there is no need to build a second layer of screen selection here.
    private static func currentWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) { return active }
        // An inactive but existing scene can carry it too: at the moment the user taps the card the app must still be in the foreground,
        // and failing to get an active one can only be the instant when the scene is switching.
        return scenes.first(where: { $0.activationState == .foregroundInactive })
    }

    /// Waits only for "asked", not for the answer. The authorization status is read once more by `startMonitoring()` itself -
    /// that chain already has to judge `.permissionDenied` and write the result into `guardNote` to show the user,
    /// and judging it a second time here would only produce a second account of it.
    private static func awaitCameraAccess() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PopopxCameraGuardEngine.requestCameraAccess { _ in continuation.resume() }
        }
    }

    private static func inheritedInterfaceStyle(from scene: UIWindowScene) -> UIUserInterfaceStyle {
        scene.keyWindow?.overrideUserInterfaceStyle
            ?? scene.windows.first?.overrideUserInterfaceStyle
            ?? .unspecified
    }
}

// MARK: - The sentence for an extended window

private extension PopopxSecureCopy {
    /// The sentence for when there is no session left to extend. It appears only during the lingering stretch where "the window is still open, the session is already dead",
    /// so it is not written as "extension failed": failure makes people think retrying helps, and here retrying never helps.
    static let extendWindowClosed = NSLocalizedString("This message has no time left to extend.", comment: "")
}

// MARK: - Window content

/// The window's root view: a black-screen shield wrapping the top-secret content.
///
/// A separate type rather than assembling one on the spot inside `present`, so that the generic parameter
/// `PopopxScreenCaptureShieldView<PopopxSecureSheetView>` lands on a concrete declaration -
/// a type name assembled on the spot exists only in the type checker's diagnostics, so later on there is no place to look at it or change it.
struct PopopxSecureShieldedContent: View {
    let model: PopopxSecureSheetModel

    var body: some View {
        PopopxScreenCaptureShieldView {
            PopopxSecureSheetView(model: model)
        }
    }
}
