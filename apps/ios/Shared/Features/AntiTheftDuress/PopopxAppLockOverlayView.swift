//
//  PopopxAppLockOverlayView.swift
//  POPOPX (iOS)
//
//  [Physical anti-snatch · interface layer] A full-screen frosted passcode overlay plus a silent loading transition layer. It is `PopopxAppLockState`
//  the only "face": module 1 (sensors/timeout/background) and module 2 (behaviour criteria) only raise the lock,
//  module 3 (dual passcodes) only checks the code and wipes; this middle layer is the single place where they meet.
//
//  ### The LA gate upstream in `ContentView` is a different layer; the two must not be merged
//  The gate in `ContentView` (`DEFAULT_PERFORM_LA` + `contentViewAccessAuthenticated` +
//  the background `DEFAULT_LA_LOCK_DELAY`, see `prefPerformLA` in `Shared/ContentView.swift`
//  (:46) and those two `contentViewAccessAuthenticated` checks) decides
//  **"who may enter this app"**: it happens on a cold start / when returning after the lock-screen delay, and the UI is upstream's own
//  `SetAppPasscodeView` / `LocalAuthView`, with unlocking going through `authorize()`.
//  This overlay decides **"is the phone in my hand right now"**: it happens while the app is already open and in use,
//  raised in-process by sensor/timeout/background events; the UI has only a 6-digit code and one biometric shortcut.
//  The two layers each stand on their own, and the order is fixed: first the LA gate lets people in, then the overlay is even on the table.
//  This file **neither calls nor modifies** `authorize()` — it grants access outright for `.unavailable`
//  (`authorize` in LocalAuthenticationUtils.swift:20-24): that is "device-unlock convenience" semantics, and a security overlay must not inherit it.
//  Likewise, this file adds no UserDefaults keys, touches no Keychain, and neither reads nor writes the two upstream passphrases.
//
//  ### The overlay's presence is decided by `coversContent`, the keyboard's visibility by `showsLockUI`; nobody may hand-assemble the conditions
//  `PopopxAppLockState` keeps the two questions apart (`PopopxAntiTheftMotionGuard.swift`, in the
//  `PopopxAppLockState` type comment and those two computed properties):
//  **Whether it covers** uses `coversContent` (= `isLocked`, true throughout the lock period, including the 1.2 s of silent self-destruct);
//  **What the overlay shows** uses `showsLockUI` (false while the wipe runs; then only breathing is allowed — no reason copy,
//  keyboard, error or "destroying"). Collapsing the two into one criterion was a real incident in this module:
//  the overlay vanished at the instant "erasing started", exposing the content straight to whoever was standing next to it.
//  This layer adds one more safeguard on top of those two criteria: the order in `submit(pin:)` when the duress code is hit is
//  `beginDuressFlow()` → wipe → `endDuressFlow()` → **`unlock()`** → and only then padding the time short of
//  `minimumFlowSeconds` up to that floor (`submit(pin:)` of `PopopxDuressAuthManager`).
//  That is, `isLocked` has already flipped once **before** `await` returns, and trusting only the upstream criterion would, during the padding stretch,
//  tear the overlay off once — and that tearing-off is the exposure. Therefore:
//  - presence = `lock.coversContent || model.silentFlow`;
//  - the breathing/keyboard choice = `model.silentFlow`, which takes both the local `phase` and the upstream `showsLockUI`,
//    because a silent flow may also be started from an entry this layer cannot see.
//  Only by taking the union of both criteria are both flip points covered.
//
//  ### Invariant: `.unlocked` and `.duress` must be word-for-word identical (read this before changing anything)
//  One keypad submit has only four outcomes, and two of them (normal code hit, duress code hit) **must be the same thing on screen**:
//  the same `case`, the same code, the same haptic, the same copy, the same duration. The reason is not aesthetics:
//  If `.duress` buzzed one extra time, came 200ms later, was a shade darker, or popped out "processing",
//  the coercer would know at a glance, or with a stopwatch, that the code pressed was exactly the one that should not be pressed.
//  This is not "inconsistent experience", it is self-exposure in front of someone. Therefore:
//  - the outcome branch is written `case .unlocked, .duress:`, both cases in one branch, leaving the compiler no room to split them;
//  - **no** completion haptic is fired during the flow (`PopopxHaptics.notice(.success)` must never appear in this branch);
//  - the breathing layer's copy and duration are decided by `PopopxDuressAuthManager.minimumFlowSeconds` and
//    the padding inside `submit`; this file is only responsible for "the animation lasts until `await` returns", it does not keep its own time;
//  - the only place a difference is allowed is `.wrong` (wrong code) and `.notConfigured` (no code set yet),
//    which by definition are not the duress path.
//  For the same reason, after `.wrong` retyping the same code in the original order must look exactly like the first time.
//
//  ### Why the breathing animation may only use opacity / scale (and why never a Timer)
//  The erase section of `submit` (`PopopxStorageWipe.wipe`) contains several heavy chunks **that run synchronously on the main thread**:
//  `chatCloseStore()` closing SQLite, `clearRenderedState` clearing ItemsModel, `resetChatCtrl()` +
//  `initializeChat(start:)` rebuilding the control layer — hundreds of milliseconds in total (the file-deletion part has deliberately been moved to the background,
//  see that `DispatchQueue.global(qos: .userInitiated)` block in `PopopxStorageWipe`;
//  but the rest still runs on the main actor).
//  An animation that pushes keyframes frame by frame with `Timer`/`DispatchSourceTimer` has its callbacks queued on the main thread,
//  so once the main thread is blocked it stops outright, and the first recovered frame "jumps" — leaving a visible stutter on screen.
//  While `opacity` and `transform` (`scaleEffect` lands on a CALayer) are **properties the render process can take over**:
//  once an animation is committed the render process advances it by itself, so it keeps breathing even if the main thread freezes.
//  So this file changes only those two properties, and commits the animation **before `await`**
//  (the one `withAnimation` in `send(reduceMotion:)` precedes any erase code; the panel has an extra
//  `onChange(of: silentFlow)` covering the case where the wipe is started from an entry outside this layer).
//  Under Reduce Motion nothing moves, but copy, duration and haptics are unchanged — the only permitted difference is "did it move",
//  and for the normal code and the duress code that is the same value.
//
//  ### Hit testing: visual occlusion does not count as blocking
//  The overlay itself swallows taps and drags (`contentShape` + empty `onTapGesture` + `DragGesture(minimumDistance: 0)`),
//  and the frosted layer catches them once more underneath. Without that drag gesture, the chat list below **can still be scrolled** behind the overlay
//  — seeing an overlay but being able to touch the content is the second least forgivable mistake for this screen.
//
//  ### Host wiring contract: mount only `popopxAppLockOverlay()`; no `if coversContent` in the host
//  This type decides for itself whether it covers; the host's only job is to mount it **unconditionally** (with no lock it is an empty `ZStack`,
//  produces no hit area, takes no part in layout, and its steady-state cost is zero). Writing
//  `if lock.coversContent { PopopxAppLockOverlayView() }` over in the host is wrong, and wrong in a hidden way:
//  `submit(pin:)` calls `unlock()` **before** the padding, and in that instant `coversContent` turns false,
//  so the host **plucks** the whole overlay out of the hierarchy — the internal "no removal while a flow is in flight" safeguard
//  never gets a say: the view is already gone and the phase in `@State` went with it. For the remaining 1.2 s at most,
//  the content sits directly in front of the coercer — exactly the exposure this module defines.
//  The criterion lives in the view rather than in the host so that at such a moment no host can pluck it out first.
//
//  ### What this file cannot do (honest limits; copy must not imply otherwise)
//  1. `PopopxScreenCaptureShieldView` moves only **the content it hosts itself** out of the screen-capture buffer
//     (for the mechanism and the private-canvas red lines see the header of `PopopxScreenCaptureShieldView.swift`,
//     and its sole-switch arrangement for `UITextField.isSecureTextEntry`).
//     The chat list covered by the overlay still lives in the main host layer, so a recording gets **their own** pixels —
//     frosted glass fools the eye, not the buffer. To truly keep the list out of recordings while locked, a window-level solution
//     (the `PopopxSecureWindowManager` kind) or removing the underlying views while locked has to carry that; this file does not pretend to have it.
//  2. The overlay is mounted on the host view's `overlay`, so it **cannot cover layers presented as sheet / fullScreenCover**
//     (they sit above this view in the window hierarchy). The host must mount it on the topmost window container,
//     and if a modal is in flight when the lock comes up, the host has to dismiss it first — that is wiring-side work.
//  3. `PIN` is a `String`, owned by ARC and not overwritable; this layer only promises to drop the reference as soon as the flow ends.
//     The copy that is actually zeroed lives in `PopopxDuressAuthManager.derive(secret:salt:iterations:)`
//     (`derive(secret:salt:iterations:)` of `PopopxDuressAuthManager`: the `Data` produced by the derivation
//     is zeroed in place by `defer { popopxSecureErase(&secret) }`).
//  4. Passphrase derivation runs PBKDF2 twice, so even the normal code waits the full 1.2 s — this is not a bug in this layer,
//     it is the reason `minimumFlowSeconds` exists: so that a real self-destruct hides behind the same lower bound.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts modifying project.pbxproj.
//  ⚠️ This file **adds no** `#Preview` / `PreviewProvider`: CI snapshot comparison would rule a new preview a failure.
//

import SwiftUI
import UIKit

// MARK: - Copy

/// Every sentence that appears on the overlay. Gathering them in one place is so that the invariant "the two branches must be word-for-word identical"
/// has literally one source in the text itself — strings written all over the layout will sooner or later see one branch changed by a single word.
///
/// This does **not** interpolate `PopopxDuressAuthManager.pinLength`: that is a `@MainActor` static value,
/// and reading it from a non-isolated global initialiser is a Swift 6 error. The two sentences with the digit count are composed on the fly in the panel's `dotsLabel`.
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

    // Cooldown layer. `%@` accepts only the one reading of `PopopxLockoutSchedule.phrase(_:)`; no other place may assemble its own set of numbers.
    static let lockedOutPrompt = NSLocalizedString("Disabled", comment: "")
    static let lockedOutFormat = NSLocalizedString("POPOPX is disabled. Try again in %@.", comment: "")
    static let lockedOutFootnote = NSLocalizedString("During this cooldown the keypad, Face ID and the mnemonic phrase are all refused.", comment: "")
    /// The sentence read to VoiceOver **contains no seconds**: see `PopopxLockPanel.lockedOut` for the reason.
    static let lockedOutVoiceOver = NSLocalizedString("POPOPX is disabled and cooling down. The keypad, Face ID and the mnemonic phrase are temporarily unavailable and come back automatically when the countdown ends.", comment: "")

    // The mnemonic cell. `mnemonicConsequence` must be visible **before the press**: it describes an irreversible deletion.
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

// MARK: - Size and motion constants

/// Only two kinds of numbers: sizes obtained by adding up `PopopxMetrics` tokens, and normalised factors that are **not spacing**
/// (opacity, scale factor, milliseconds per step). Hard-coding a spacing or a corner radius is rework, and so is calling them "sizes".
private enum PopopxLockLayout {
    /// Key side length: `minHitTarget` (44) is the hard floor, plus one `spaceS` step so it is not cramped.
    static let keySide: CGFloat = PopopxMetrics.minHitTarget + PopopxMetrics.spaceS
    static let keyGap: CGFloat = PopopxMetrics.spaceS
    static let dotSide: CGFloat = PopopxMetrics.spaceS
    static let dotGap: CGFloat = PopopxMetrics.spaceXS
    static let ringSide: CGFloat = PopopxMetrics.minHitTarget + PopopxMetrics.space2XL
}

private enum PopopxLockMotion {
    /// The two breathing ticks. opacity / scale only — see the "breathing animation" paragraph in the file header for why.
    static let breathScaleSmall: CGFloat = 0.94
    static let breathScaleLarge: CGFloat = 1.06
    static let breathDim: Double = 0.35
    static let breathBright: Double = 0.85
    /// Shake amplitude and per-step duration. The amplitude takes one spacing token step; duration is not spacing, so milliseconds are allowed.
    static let shakeAmplitude: CGFloat = PopopxMetrics.spaceS
    static let shakeStep: Duration = .milliseconds(80)
    /// A base colour pressed on top of the frost so that `label` holds up; leaving it slightly un-opaque is what makes the frost read as frost.
    static let backdropWash: Double = 0.72
}

// MARK: - Overlay state machine

/// The overlay's own state cell. **Only** the flow phase, the digits typed, the display copy and the two motion ticks.
///
/// Deliberately no `isLocked` and no trace of "which code this time": `PopopxAppLockState` is the one shared by the modules,
/// and once "which code" leaves a copy in the interface layer (a field like `wasDuress`),
/// sooner or later some line of interface code will read it — that is exactly how the invariant gets broken. There is nothing readable here.
@MainActor
@Observable
final class PopopxAppLockOverlayModel {
    enum Phase: Hashable {
        /// The keypad waits for a code to be entered.
        case keypad
        /// Submitted, breathing. Both the normal code and the duress code stop in this cell, and only in this cell.
        case breathing
        /// No dual passcodes configured yet: the degraded state with a single "Unlock" button.
        case minimalUnlock
        /// Brute-force cooldown in progress. Digit keys, Face ID and the mnemonic entry all refuse hits together,
        /// and the centre of the screen keeps only a countdown ticking once a second.
        case lockedOut
        /// The "reset with the 12-word mnemonic" cell: phrase + new code + retype, and after submit it goes into `completeUnlock()`.
        case mnemonicReset
    }

    /// Lock state, authentication, sensors — three shared singletons. `let`: this class only reads them and only writes them through public methods.
    let lock = PopopxAppLockState.shared
    let auth = PopopxDuressAuthManager.shared
    let motion = PopopxAntiTheftMotionGuard.shared

    private(set) var phase: Phase = .keypad
    /// The top line: **copied and frozen** when the lock screen appears, afterwards it does not follow `lock.reason`.
    /// Because `unlock()` clears `reason` to nil while the overlay still has to breathe for 1.2 s —
    /// binding it directly would be "the copy vanishing in mid-air", which is a visibly noticeable anomaly.
    private(set) var headline: String = PopopxLockCopy.headlineFallback
    private(set) var headSymbol: String = PopopxLockCopy.symbolFallback
    private(set) var wrongHint: String?
    /// Whether the biometric key shows. Computed once at the start and stored: `biometricsAvailable` builds a new
    /// `LAContext` on every call, so it cannot be asked frame by frame inside `body`.
    private(set) var showsBiometricKey = false
    var pin: String = ""
    private(set) var breath = false
    private(set) var shakeOffset: CGFloat = 0
    /// Used only as a trigger for "which failure this is"; the count itself never enters any visible copy.
    private(set) var wrongCount = 0

    private var submitTask: Task<Void, Never>?
    private var shakeTask: Task<Void, Never>?
    private var biometricRequested = false
    /// Whether this flow round has already committed the breathing animation to the animation system. See `setBreathing(_:reduceMotion:)`.
    private var breathStarted = false
    /// The **single** wake-up when the cooldown expires. Not a per-second heartbeat — the per-second tick is owned by the panel's `TimelineView`,
    /// see `startLockoutWatch()` for the reason.
    private var lockoutTask: Task<Void, Never>?

    // MARK: The three inputs of the mnemonic cell
    //
    // These three fields are the same kind of thing as the two codes on the settings page: **plaintext interface copies**. The manager reads them only in this cell,
    // during the single `resetEntryPinWithMnemonic` call, and afterwards (submit, back to keypad, overlay exit,
    // re-raising the lock) they are always cleared by `resetMnemonicForm()`. `mnemonicInput` matters most —
    // those 12 words have another readable copy in secure storage, so the one on screen should not outlive this single opportunity.
    var mnemonicInput = ""
    var newPin = ""
    var newPinConfirm = ""

    /// Whether to offer the "Forgot your code? Reset with the 12-word mnemonic" line. All three conditions are required:
    /// the phrase really is there (without it there is nothing to verify), the normal-code record is still there (reset writes to it),
    /// and we are not currently in cooldown (during cooldown all three input doors close together — that is the definition of that table).
    var canOfferMnemonicReset: Bool {
        auth.mnemonicConfigured && auth.normalConfigured && !auth.isLockedOut
    }

    var canSubmitMnemonicReset: Bool {
        !PopopxBIP39.normalizedWords(mnemonicInput).isEmpty
            && newPin.count == PopopxDuressAuthManager.pinLength
            && newPin == newPinConfirm
    }

    /// The panel asks once a second "how much is left". It reads `context.date`, not `Date()`:
    /// a `TimelineView`'s scheduled instant and a self-fetched current time can differ by tens of milliseconds,
    /// so the displayed number should come only from that one scheduled instant.
    func lockoutRemaining(at date: Date) -> TimeInterval {
        guard let endsAt = auth.lockoutEndsAt else { return 0 }
        return max(0, endsAt.timeIntervalSince(date))
    }

    /// Whether we are in the "breathe only, show nothing" cell. Two sources, both required:
    /// 1. local `phase == .breathing` — this layer just submitted a password, and the normal code too must stay silent for the full 1.2 s;
    /// 2. an upstream silent self-destruct in flight (`lock.isLocked && !lock.showsLockUI`) — this path may be started
    ///    from an entry this layer cannot see, and trusting only local state would hand the keypad back mid-wipe.
    /// See the file-header paragraph: `coversContent` governs whether it covers, `showsLockUI` governs whether the keypad shows,
    /// and this layer unions them with the local `phase` so that both flip points, `unlock()` and the padding, are covered.
    var silentFlow: Bool {
        phase == .breathing || (lock.isLocked && !lock.showsLockUI)
    }

    /// Whether the overlay is present. `coversContent` is responsible for "locked means it must cover", `silentFlow` for
    /// "nobody may take the overlay away while a flow is in flight" — `submit` calls `unlock()` before the padding,
    /// and without the second half the overlay would tear itself off during the last few hundred milliseconds of the wipe.
    var presents: Bool {
        lock.coversContent || silentFlow
    }

    var canSend: Bool {
        pin.count == PopopxDuressAuthManager.pinLength
    }

    // MARK: Lifecycle

    /// The overlay starts presenting. **Idempotent**, and called once on mount by the `initial: true` `onChange`:
    /// when a cold start happens to land on an already-locked state, no other path would put `phase` right.
    func begin() {
        guard phase != .breathing else { return }
        pin = ""
        wrongHint = nil
        shakeOffset = 0
        stopBreathing()
        resetMnemonicForm()
        biometricRequested = false
        // The Keychain may have been changed in another session (a self-destruct is such a change), so it is asked again on every entry to the overlay.
        auth.refreshConfiguration()
        if let reason = lock.reason {
            headline = reason.userText
            headSymbol = reason.symbolName
        }
        showsBiometricKey = auth.prefersBiometricUnlock
        // The cooldown check comes before "is there a normal code": this table gates the **input doors**, regardless of which code it is stopping.
        // A cold start landing mid-cooldown takes this branch too — `lockoutEndsAt` is persisted in secure storage precisely for this moment.
        if auth.isLockedOut {
            phase = .lockedOut
            startLockoutWatch()
        } else if auth.normalConfigured {
            phase = .keypad
            requestBiometricsIfNeeded()
        } else {
            phase = .minimalUnlock
        }
        // The lock is already raised, so confirm the sampling stop once more. The sensor-side `trigger` stops itself, but module 2,
        // manual lock and timeout do not pass module 1's sampling-stop point — `lockedDidChange()` is the only unified exit.
        motion.lockedDidChange()
    }

    /// Wrap-up after the overlay exits, so the next lock starts from a clean keypad.
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

    // MARK: Keypad

    /// Whether the keypad is interactive. Besides `phase` it also asks `silentFlow`: a silent self-destruct may be started from an entry
    /// this layer cannot see, in which case `phase` still sits at `.keypad` while the screen has no keypad left —
    /// an invisible but tappable key is worse than one that does not respond.
    var keypadLive: Bool { phase == .keypad && !silentFlow }

    func tapDigit(_ digit: Int) {
        guard keypadLive, pin.count < PopopxDuressAuthManager.pinLength else { return }
        // Typing a code is also "a person acting", so it gives the timeout criterion a beat, lest the lock be raised again halfway through typing.
        lock.noteInteraction()
        wrongHint = nil
        pin += String(digit)
    }

    func tapDelete() {
        guard keypadLive, !pin.isEmpty else { return }
        lock.noteInteraction()
        pin.removeLast()
    }

    /// The confirm key. The only submit entry — there is no "auto-submit after 6 digits", because auto-submit would bind
    /// the breathing start to the last keypress, whereas an explicit submit binds it to an action that certainly happened.
    func send(reduceMotion: Bool) {
        guard keypadLive, canSend else { return }
        lock.noteInteraction()
        let entered = pin
        phase = .breathing
        // The animation is committed **here**, without waiting for `onChange`: the Task body is queued on the main actor,
        // and there is no guarantee whether it or a view update runs first, while this animation must be handed to
        // the render process before the erase section occupies the main thread (the "breathing animation" paragraph in the header). `setBreathing` is idempotent, so the panel's later call spins empty.
        setBreathing(true, reduceMotion: reduceMotion)
        submitTask = Task { [weak self] in
            guard let self else { return }
            // Does not keep its own time: `submit` already pads the shortfall below `minimumFlowSeconds` at the end.
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

    /// The single button of the degraded state: there is no password to speak of yet, so hand it straight back to the interface.
    func unlockWithoutPin() {
        pin = ""
        phase = .keypad
        lock.unlock()
        motion.lockedDidChange()
    }

    // MARK: Mnemonic reset

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

    /// Submitting those 12 words. Verification, writing the new code, clearing the emergency wipe password and clearing the cooldown counter are all done
    /// inside `PopopxDuressAuthManager.resetEntryPinWithMnemonic`; this layer only handles the interface.
    ///
    /// **Clear the interface copies first, then `await`**: this call may take over three hundred milliseconds (two 100k-round derivations),
    /// and during that time the risk of leaving plaintext on the keypad is far greater than "having to retype after a failure". On failure the manager returns
    /// one of those fifteen sentences, and the owner just retypes accordingly.
    ///
    /// Malformed structure (`mnemonicMalformed`) is also explained in this cell: `canSubmitMnemonicReset` only looks at
    /// "was anything typed", not at word count or spelling. Expressing invalid input as "the button won't press"
    /// makes the owner read "this button is broken"; only the manager saying "12 standard English words required" is a sentence one can act on.
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
            // Instead of asking "was the thrown error `lockedOut`", ask the cooldown table directly: this wrong mnemonic may well
            // have just landed as the 5th attempt (`settleWrongAttempt` already ran before throwing `.mnemonicIncorrect`),
            // in which case the error sentence is "mnemonic incorrect" while the input doors should already be shut.
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

    /// The wrap-up after a successful reset runs exactly the same section as "one successful unlock".
    ///
    /// Why it can go straight in without forcing the owner to verify the just-set code on the keypad: this path is
    /// **impossible by type to be a duress code** — the end of `resetEntryPinWithMnemonic` deletes the emergency wipe password,
    /// so whoever handed over that code can no longer wipe any data, and there is no risk here of "reading the verdict out for the coercer".
    /// And forcing someone who just lost their password to blindly type a code set three seconds ago only turns "did the reset work at all"
    /// into a second doubt.
    private func mnemonicResetSucceeded() {
        auth.refreshConfiguration()
        wrongHint = nil
        phase = .keypad
        completeUnlock()
    }

    /// All three input fields are taken back at once. Every exit from `phase == .mnemonicReset` passes through here.
    private func resetMnemonicForm() {
        mnemonicInput = ""
        newPin = ""
        newPinConfirm = ""
    }

    // MARK: Cooldown

    /// A **one-shot** alarm that hands the screen back to the keypad when the cooldown expires.
    ///
    /// Why it is not a per-second heartbeat: that tick is owned by the panel's `TimelineView`, which stops by itself as the remaining
    /// time reaches zero. Wanting both gives two notions of "what time is it now", and they will sooner or later say different things.
    /// `+0.25` is slack left for rounding: `phrase(_:)` rounds up, so a few hundred milliseconds left after the UI shows "0 s" is normal;
    /// on expiry `isLockedOut` is asked once more, and if still locked the alarm is rearmed.
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
                // The instant the keypad is handed back does not replay Face ID: the owner was just stopped by this table,
                // popping a system authentication sheet would only make him think "the lock is off". Let him press it himself.
            }
        }
    }

    // MARK: Motion (the panel passes Reduce Motion in: this class is not a View and cannot reach the environment)

    /// Start/stop the breathing. **Idempotent**: at most one `repeatForever` is committed per submit flow,
    /// re-issuing `withAnimation` halfway would restart the ring's cycle mid-flight — that is a visible stutter.
    ///
    /// Starting happens only inside `send(reduceMotion:)`, before any `await`, so once committed the animation is in
    /// the render process's hands; afterwards the main thread is occupied by `chatCloseStore()` / `initializeChat()` for hundreds of milliseconds,
    /// and the breathing goes on regardless (see the file header: only properties the render process can take over, like opacity / scale, survive that moment).
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

    /// Stopping the breathing: the value and the "committed" flag are withdrawn together. Missing the flag would leave the next submission without an animation.
    private func stopBreathing() {
        breathStarted = false
        breath = false
    }

    /// One horizontal shake. Under Reduce Motion the whole thing is skipped — this is a "difference", but it is the same value
    /// for the normal code and the duress code (same device, same `.wrong`), so it does not constitute an exposure.
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

    // MARK: Internal

    private func requestBiometricsIfNeeded() {
        guard showsBiometricKey, !biometricRequested else { return }
        biometricRequested = true
        auth.requestBiometricUnlock(reason: PopopxLockCopy.biometricReason) { [weak self] granted in
            // The callback thread is decided by LocalAuthentication (the manager hops back to the main actor internally, but its
            // `completion` type does not promise that), so we hop once more here rather than guessing the thread.
            Task { @MainActor [weak self] in
                self?.biometricFinished(granted: granted)
            }
        }
    }

    private func biometricFinished(granted: Bool) {
        // false only means "the keypad should be handed over" — the keypad is right underneath and nothing has to change.
        guard granted else { return }
        // On success the manager has **already** called `unlock()` and zeroed the failure counter (the comment on `requestBiometricUnlock(reason:completion:)` of `PopopxDuressAuthManager`),
        // so this does not repeat the lock-state change; it only finishes the interface work and resumes sampling.
        pin = ""
        wrongHint = nil
        phase = .keypad
        motion.lockedDidChange()
    }

    private func finish(outcome: PopopxDuressAuthOutcome) {
        submitTask = nil
        switch outcome {
        case .unlocked, .duress:
            // ⚠️⚠️ Invariant (full reasoning in the file header): these two branches **must be the same case, the same code**.
            // No `if outcome == .duress` here, and no added logging, haptics, copy, delay or colour.
            // The interface gets "a successful unlock", nothing more.
            completeUnlock()
        case .wrong:
            pin = ""
            stopBreathing()
            phase = .keypad
            wrongHint = PopopxLockCopy.wrong
            PopopxHaptics.notice(.error)
            // The shake is started by the panel, using its own environment, when `wrongCount` changes.
            wrongCount += 1
        case .notConfigured:
            // No dual passcodes set yet (or the Keychain was cleared elsewhere). The user must never be locked out permanently.
            pin = ""
            stopBreathing()
            wrongHint = nil
            phase = .minimalUnlock
        case .lockedOut:
            // From the 5th attempt on this branch runs (also "confirm pressed again while already in cooldown"). It is **not** an error message:
            // the keypad, Face ID and the mnemonic inputs all close together, leaving only a once-a-second countdown in the centre.
            // The haptic differs from the `.wrong` one (there it is `notice(.error)`), but both agree entirely on "this attempt did not open the door",
            // and the normal code and the duress code run the same code, so it does not constitute an exposure.
            pin = ""
            stopBreathing()
            wrongHint = nil
            resetMnemonicForm()
            phase = .lockedOut
            startLockoutWatch()
            PopopxHaptics.notice(.warning)
        }
    }

    /// The order is load-bearing: clear the failure count first, then unlock, and only then tell the sensors "the lock is gone".
    /// `lockedDidChange()` reads `isLocked`; placed before `unlock()` it would stop sampling as before.
    /// `unlock()` itself has already notified once (`PopopxAppLockState` calls directly at the end of unlocking,
    /// `PopopxAntiTheftMotionGuard.shared.lockedDidChange()`) — so this line is an explicit second time,
    /// kept so that "both edges of the lock must notify the sensors" is also visible in this file,
    /// rather than resting on someone else's implementation details.
    private func completeUnlock() {
        auth.resetBiometricFailures()
        lock.unlock()
        motion.lockedDidChange()
        // The cooldown alarm and the three plaintext mnemonic copies are cleared along with this success. `endPresenting()` would do
        // the same thing, but that line waits for `coversContent` to flip, and `submit` calls `unlock()` before the padding —
        // in those few hundred milliseconds the alarm is still armed and the phrase is still on screen. This line moves it earlier.
        lockoutTask?.cancel()
        lockoutTask = nil
        resetMnemonicForm()
        // `submit`'s duress branch has already called unlock() once internally (the `PopopxAppLockState.shared.unlock()` inside `submit(pin:)`),
        // so the line above may be the second time — `unlock()` is just a few assignments, and repeated calls have no side effects.
        // It is kept so that "the two branches **share the same code**" has no exception: the normal-code path does not unlock by itself.
        pin = ""
        stopBreathing()
        wrongHint = nil
        phase = .keypad
    }
}

// MARK: - The overlay itself

/// A full-screen frosted overlay. `init()` takes no arguments: state always comes from `PopopxAppLockState.shared`,
/// and the host's only job is to mount it on the topmost window container.
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
                // Releasing the lock ≠ the flow being over: `submit` calls `unlock()` before the padding,
                // and clearing state at that moment would tear off an overlay that is still breathing. See the two flip points in the file header.
                model.endPresenting()
            }
        }
        .onChange(of: model.presents) { _, presenting in
            guard presenting else { return }
            // The overlay is "another screen". `argument: nil` makes VoiceOver land on the first element of the new interface,
            // instead of staying on the row of the list it covers.
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    /// Two layers: the frosted base (in the outer SwiftUI tree, where the material really can blur the background) +
    /// the panel protected by the capture shield. Why it is split this way: see item 1 of the "honest limits" in the file header.
    ///
    /// `@MainActor`: the panel reads isolated constants on `PopopxDuressAuthManager`, and **only** computed properties
    /// may be marked isolated — the type as a whole is unmarked so that `init()` stays non-isolated,
    /// and can therefore be constructed directly by the non-isolated `popopxAppLockOverlay()`.
    @MainActor private var layers: some View {
        ZStack {
            backdrop
            PopopxScreenCaptureShieldView {
                PopopxLockPanel(model: model)
            }
        }
    }

    /// A base that swallows every hit. Three layers of insurance; miss one and content becomes reachable:
    /// the material and the colour wash themselves, `contentShape` (widening the hit area from "where there are pixels" to the whole rectangle),
    /// and the empty tap + zero-distance drag gestures (leaving the scrolling view underneath no chance at all).
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

// MARK: - Panel

/// The only content on the overlay: the lock-reason line at the top, 6 dots, and the keypad/breathing/degraded state switching with the phase.
///
/// The layout's **anti-reflow** convention: during breathing the keypad merely sits there at `opacity(0)`, it is not unmounted,
/// so the panel height never changes. Any reflow moves something in front of the coercer — and "moving"
/// is precisely the one thing this module must avoid.
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
            // The cooldown cell replaces the whole stage: the keypad is gone and Face ID no longer accepts hits. An owner who cannot see
            // would get only the bare fact "nothing presses any more", so one `.layoutChanged` is pushed to let focus land on
            // the new cell and read the static `lockedOut` label (no seconds; see the note there for why).
            // Only "entering" is announced, not "leaving": when the cooldown ends and the keypad returns, the previous sentence has usually not finished, and pushing again would cut off the sentence it was still speaking.
            if phase == .lockedOut {
                UIAccessibility.post(notification: .layoutChanged, argument: nil)
            }
        }
        .accessibilityIdentifier("popopx.lock.panel")
    }

    // MARK: Top

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

    /// The five cells the panel actually presents. `breathing` is decided by `model.silentFlow`, which takes both the local `phase`
    /// and the upstream `showsLockUI`, so the case "a wipe is in flight but this layer never submitted a password" also lands in this cell.
    /// Subtitle, progress-dot announcement and stage switching all read only this one criterion — assembling the condition
    /// in three places will sooner or later produce a self-contradicting screen.
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
        // Consumed by the line above; written here only for exhaustiveness: local `.breathing` always makes `silentFlow` true.
        case .breathing: return .breathing
        case .minimalUnlock: return .minimal
        case .lockedOut: return .lockedOut
        case .mnemonicReset: return .mnemonic
        }
    }

    /// The cooldown and mnemonic cells show no progress dots: those six dots mean "which of the 6 digits",
    /// and of these two cells one has no input at all while the other types into text fields. Hidden rather than removed so that the panel height
    /// stays exactly the same across all five cells (the anti-reflow convention in the file header).
    private var showsDots: Bool {
        stageKind == .keypad || stageKind == .breathing || stageKind == .minimal
    }

    /// Each of the three phases has its own subtitle. The breathing sentence is the same one for the normal code and the duress code — see the invariant.
    private var subline: String {
        switch stageKind {
        case .keypad: return PopopxLockCopy.prompt
        case .breathing: return PopopxLockCopy.breathing
        case .minimal: return PopopxLockCopy.minimalPrompt
        case .lockedOut: return PopopxLockCopy.lockedOutPrompt
        case .mnemonic: return PopopxLockCopy.mnemonicPrompt
        }
    }

    // MARK: Progress dots

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

    /// The dot positions spoken to VoiceOver. It contains **only a count** and never any of the digits themselves.
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

    /// The placeholder always shows: a hint appearing or disappearing must not make the keypad below jump.
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

    // MARK: Stage

    /// The keypad is always present (transparent when it must be), with the breathing, degraded, cooldown and mnemonic layers stacked on top —
    /// so the height is constant. This `allowsHitTesting(stageKind == .keypad)` line also delivers what the brief asked for:
    /// "disable the digit keypad, Face ID and the mnemonic button during cooldown" — all three live inside the keypad layer,
    /// so turning off hits for the layer turns off all three with no `if` per item (one `if` each means the fourth gets missed).
    private var stage: some View {
        ZStack {
            keypad
                .opacity(stageKind == .keypad ? 1 : 0)
                // `opacity(0)` does not disable hit testing: without this line the 10 invisible keys would still be pressable while breathing.
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
            // The "forgot password" line occupies this cell only when the phrase really exists. Could it appear or disappear mid-session
            // and push the panel height about? No: `mnemonicConfigured` changes only on the settings page and in the wipe flow,
            // and at both of those moments the overlay is not in the `.keypad` cell.
            if model.canOfferMnemonicReset {
                mnemonicEntry
            }
        }
        // In the cooldown, breathing, degraded and mnemonic cells the keypad should not be reachable by VoiceOver (when `stageKind != .keypad`
        // the whole layer already refuses hits); `disabled` adds one more gate, closing the "invisible but still focusable" road too.
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

    /// The bottom-left cell: the biometric key if it can be used, otherwise a same-size placeholder, so that `0` sits in the middle.
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

    /// The confirm key does **not** use `PopopxButton`: that one flashes a green check when the action returns and adds one
    /// `notice(.success)` (`flashSuccess()` of `PopopxButton`). Ticking a **self-destruct** that just ended
    /// is reading the verdict out for the coercer; ticking "wrong code" would prove on the spot that the button is not judging codes.
    /// The style is drawn from the same token set as `PopopxButton`'s label, only without the receipt.
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

    // MARK: Breathing layer

    /// Only a ring (scale + opacity) and the system spinner. There are **no** words like "processing" or "clearing":
    /// for the normal code they are redundant, for the duress code they are a confession.
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

    // MARK: Degraded layer

    /// `.notConfigured`: one button, nothing more done. This branch **cannot** be the duress path
    /// (no normal code set means no duress code; see the
    /// `normalPinRequiredFirst` of `PopopxDuressAuthManager.setDuressPin`), so a receipt-returning `PopopxButton` is safe to use here.
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

    // MARK: Cooldown layer

    /// The block in the centre during cooldown. **The per-second tick comes from `TimelineView`**, not from a heartbeat task in this layer:
    /// the number is the difference between `auth.lockoutEndsAt` and "the instant this frame was scheduled", reading its own time,
    /// so even if the system suspends the overlay briefly, it will not jump to a wrong number of seconds when it comes back.
    ///
    /// Font: `PopopxType.title` (`.title2` + semibold) with `.monospacedDigit()` layered on top.
    /// The task asked for "a monospaced live countdown font", and `PopopxType` has no larger monospaced step —
    /// `metric` is `.footnote` and `metricSmall` is `.caption2`; neither belongs in the centre of the screen.
    /// So the font size is not changed here, only the digit shape: monospacing at this position does exactly one thing, which is that as the digits tick each second
    /// the characters behind them are not allowed to drift sideways (that would be a visible reflow, precisely the one thing this screen must avoid).
    ///
    /// That number string is hidden from VoiceOver: a label changing every second gets reread over and over, and hearing "4 min 59 s" once
    /// is no different for the listener from hearing "4 min 58 s" once. The static sentence plus, on entering this cell, a single
    /// `.layoutChanged` (see `PopopxLockPanel.body`) is the version that is actually understandable.
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

    // MARK: Mnemonic layer

    /// The "forgot password" line. It is part of the keypad (not an extra block outside it),
    /// so that when the whole keypad layer refuses hits during cooldown, it disappears along with it —
    /// mounted separately outside would need another `if` here, and that extra `if` will be missed sooner or later.
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

    /// The input cell for those 12 words + the new code typed twice. The submit key does not use `PopopxButton`; see `mnemonicSubmitKey` for why.
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

    /// The digit-count hint is composed on the fly rather than hard-coding "6 digits": if `PopopxDuressAuthManager.pinLength` changes,
    /// this sentence has to change with it (the "the two branches must be word-for-word identical" invariant from the file header holds here too).
    private var pinPrompt: String {
        String(format: NSLocalizedString("Enter exactly %lld digits", comment: ""), PopopxDuressAuthManager.pinLength)
    }

    /// The digit fields keep only digits and only `pinLength` of them. The filter is the only line of defence, not a nicety:
    /// `PopopxTextField(isSecure:)` takes the `SecureField` branch, which **does not read** the `keyboard:`
    /// argument (`PopopxControls.swift:237-241` — only the `TextField` branch attaches `.keyboardType`),
    /// so these two cells bring up the full keyboard and the owner can type letters and punctuation.
    ///
    /// Taking a `Binding` rather than a `String` parameter: the two cells share this one function, and passing a value in then writing back to
    /// the same field would make "new code" and "confirm code" overwrite each other. Same shape as `clampToDigits` on the settings page.
    /// Writing back only when something really was filtered out, so that every keystroke does not trigger a pointless state change.
    private func clampPin(_ target: Binding<String>, _ entered: String) {
        let kept = String(
            entered
                .filter { PopopxDuressAuthManager.digits.contains($0) }
                .prefix(PopopxDuressAuthManager.pinLength)
        )
        if kept != entered { target.wrappedValue = kept }
    }

    /// The submit key. It shares the same token set as `sendButton`, and for that same reason it **must not** use `PopopxButton`:
    /// that one flashes a green check when the action returns and adds a `notice(.success)`, and "reset failed" is also an
    /// action returning. Ticking a reset that did not succeed makes the owner think the new code already took effect —
    /// learning otherwise only when the keypad refuses to respond is far worse than never ticking at all.
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

// MARK: - A single key

/// One round key on the keypad. `Kind` states "which key this is", and the glyph, the accessible copy and the action all derive from it —
/// the branch is never decided from the glyph string, because that would let changing the icon change the behaviour as a side effect.
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
        // The single source of key feedback: pressing gives `PopopxHaptics.impact(.light)` plus one scale
        // (`makeBody` of `PopopxPressButtonStyle` / `PopopxPressBody`), with the hit area guaranteed by `keySide` (≥ `minHitTarget`).
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
            // The icon is the same one the settings page row uses (`faceid` in `PopopxAntiTheftSettingsView`).
            // The manager exposes only a `prefersBiometricUnlock` boolean and does not surface `LAContext.biometryType`,
            // so this layer cannot tell Face ID from Touch ID — it can only reuse the glyph the repo has already chosen,
            // rather than inventing a "generic biometric" icon of its own, otherwise the same thing would look different on two pages.
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

// MARK: - Mounting

extension View {
    /// Mount it on the topmost window container. While locked it covers everything; when unlocked it produces no view cost at all.
    ///
    /// **It must be mounted unconditionally**; do not wrap another `if lock.coversContent` around it in the host:
    /// `submit(pin:)` calls `unlock()` before the padding, so the host's `if` would pluck the whole overlay away
    /// with a few hundred milliseconds of the wipe left (its `@State` along with it), and that moment is the exposure.
    /// For the full reasoning see the "host wiring contract" in the file header.
    func popopxAppLockOverlay() -> some View {
        overlay {
            PopopxAppLockOverlayView()
        }
    }
}
