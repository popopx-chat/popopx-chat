//
//  PopopxSecureSheetView.swift
//  POPOPX (iOS)
//
//  [Module 5's content surface + module 6's reading surface] the screen a user actually sees inside the top-secret window,
//  and the locked knowledge card in the conversation list (`PopopxSecureCardBubble`).
//
//  ### The four hard constraints of this screen, and how they decided its shape
//  1. **Always a black background only.** It does not follow light mode: `PopopxScreenCaptureShieldView` draws pure black for the capture side,
//     while the content surface in light mode turns into a near-white background — that would make the boundary between "shield" and "content" itself a piece of information
//     a screen recording could infer back from (wherever it is bright, that is where the text is). So the whole surface is permanently dark, and the ink must be permanent too:
//     see `PopopxSecureSurface.ink`, which spells out why neither the palette's `onBrand` nor its `label` family can be used
//     (they flip with colorScheme, and in dark mode this surface would end up with a screen of invisible text).
//  2. **The state machine has only four phases**: `reading` / `locked` / `burned` / `closed`. They add up because "opening refused"
//     is a class **not expressed in this view**: `present` returns failure before the window is established, so the feedback must land on the card the user
//     has just tapped (the bubble shows the toast itself), not on a window that has not appeared yet.
//  3. **Plaintext enters no persistent surface outside `Text`**: no log writes, no `@State`, no quote preview.
//     `text` is `private(set)`, and only `invalidate()` can clear it.
//  4. **Everything frame-by-frame opens here and closes here**: `PopopxAntiPhotoRenderView`, spotlight/line-by-line, the blind watermark
//     are all hung under the `reading` phase. The moment the phase leaves `reading`, these views disappear along with SwiftUI,
//     and the `PopopxFrameTicker` inside them `stop()` — this is where "stop immediately when the sheet closes" lands on the UI side,
//     so no teardown needs to be written a second time here.
//
//  ### The screen-reader (VoiceOver) rule is a deliberate trade-off, not an omission
//  The body text is excluded from the accessibility tree by `.accessibilityHidden(true)`. Reason: what VoiceOver reads aloud enters
//  the system's accessibility channel, and that channel is outside this feature's control entirely (captions, third-party switch control, the AX highlight in a recording
//  can all carry it off the screen). The cost is equally explicit: **screen-reader users cannot read the body of this message**. So this setting must be stated
//  in the interface (`PopopxSecureCopy.accessibilityNote`) and cannot be switched off silently — and whether to open an exception for screen readers
//  is a product ruling, not a default this layer gets to set for itself.
//
//  ### Why `close` is a closure instead of letting the view call the singleton directly
//  The view calling `PopopxSecureWindowManager.shared` would also run, but then this file could not be previewed or asserted apart from the singleton.
//  A closure as **a view/model input parameter** is an ordinary SwiftUI shape (`Button`'s action likewise); what is forbidden is storing a closure
//  into `Environment` (it has no stable identity, and every write invalidates the whole subtree).
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import SwiftUI

// MARK: - The model

/// The top-secret window's visible state. `@MainActor @Observable`: only the main thread writes it,
/// and all four entry points that write it (countdown tick, alert, destruction, disconnection) are inside `PopopxSecureWindowManager`.
@MainActor
@Observable
final class PopopxSecureSheetModel {
    /// Four phases, mutually exclusive and covering every visible state.
    enum Phase: Hashable {
        /// Plaintext is readable, the countdown is running, the frame-by-frame components are running.
        case reading
        /// A black cover + the reason, with the plaintext still in memory (this is where it stops only when `leftForeground` and destruction is switched off).
        /// This tier has one action only: close and destroy. "Unlock to keep reading" would need another biometric round,
        /// and that one should be started by the user tapping the card again — building another verification flow in the view is building a second state machine.
        case locked(reason: String)
        /// The plaintext is already wiped; the window is kept so the user can see **why** it closed.
        /// `reason` being nil = read to the end / expired normally, there is nothing to explain.
        /// Whether the record was deleted and whether the receipt was sent are stated entirely by the two values below; the view adds no guarantee on their behalf.
        /// When `deleted` = false it **must** be said: this field is the only part of the "burned" claim that may not have been carried out,
        /// and glossing over it would turn "this one has already been burned" into a claim that does not hold.
        case burned(reason: String?, receiptCount: Int, deleted: Bool)
        /// Wrapping up: the view is disappearing, and no callback should take effect any more.
        case closed
    }

    private(set) var text: String?
    private(set) var phase: Phase = .reading
    /// This tier can be raised by local payment (see `extendTotal(by:)`), so it is not a `let`;
    /// the write right still rests only with the manager, and the view cannot reach the half beyond the setter.
    private(set) var totalSeconds: Int
    private(set) var remainingSeconds: Int

    /// Reading mode (module 6). Spotlight by default: it needs no gesture the user must learn before it can be used.
    var readMode: PopopxSecureReadMode = .spotlight
    /// Anti rolling-shutter protection (module 6).
    var antiPhotoEnabled: Bool
    /// A one-sentence note on the guard state: which channel is missing and why. `PopopxCameraGuardEngine` and
    /// `PopopxCameraGuardFailure` both produce this string; this only takes care of displaying it.
    var guardNote: String?

    /// The session number inside the blind watermark. One per window, never reused after destruction — its forensic value is exactly "which viewing did this one leak from".
    let sessionIdentifier: String

    private let close: () -> Void
    /// The disconnection flag. Once `invalidate()` sets it, `requestClose()` becomes a permanent no-op.
    ///
    /// This is the precondition on which "double cleanup" can hold safely: `.onDisappear` and `dismissSecureWindow()` **both** fire,
    /// and without this flag the `onDisappear` SwiftUI emits when the window is torn down would, after destruction,
    /// walk "the user closed it deliberately" a second time, so the same message would be deleted twice and two receipts sent.
    private var isDisconnected = false

    /// A DEBUG-only "plaintext has been handed over" credential.
    ///
    /// Why `text` is not read directly: `@Observable` replaces `text` with a property carrying an observing accessor, and the accessor inherits the type's
    /// `@MainActor` isolation; while `deinit` is nonisolated in Swift 5 mode, so reading it does not compile
    /// （`main actor-isolated property 'text' can not be referenced from a nonisolated context`）。
    /// The box below is **an ordinary class with no isolation**, and a `let` reference takes no part in observation, so `deinit` can read it.
    ///
    /// It exists only in DEBUG and has exactly one write point (`erasePlaintext()`), on a line sitting right next to the real
    /// `text = nil`, so it does not become a second verdict to read from; reading it in `deinit` is safe too — being in `deinit`
    /// means nobody else holds this model any more, so no other thread is writing this box.
    #if DEBUG
    private final class EraseWitness { var plaintextGivenUp = false }
    private let eraseWitness = EraseWitness()
    #endif

    /// Clearing the plaintext goes through this single exit: bypassing it to write `text = nil` directly would make the deallocation assertion below say "never cleared".
    private func erasePlaintext() {
        text = nil
        #if DEBUG
        eraseWitness.plaintextGivenUp = true
        #endif
    }

    init(
        text: String,
        totalSeconds: Int,
        antiPhotoEnabled: Bool,
        close: @escaping () -> Void
    ) {
        self.text = text
        self.totalSeconds = totalSeconds
        self.remainingSeconds = totalSeconds
        self.antiPhotoEnabled = antiPhotoEnabled
        self.close = close
        self.sessionIdentifier = UUID().uuidString
    }

    deinit {
        #if DEBUG
        // Deallocation assertion: when the model is released the plaintext must already have been handed over (`erasePlaintext()` ran).
        // false means the destruction path was skipped — usually `burn(...)` or `invalidate()` was never called.
        print("[popopx.secure] sheet model released, plaintext given up = \(eraseWitness.plaintextGivenUp)")
        #endif
    }

    /// Apart from the countdown reaching zero and the user closing it, the phase never changes on its own. `progress` feeds the progress bar, 0...1.
    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, Double(remainingSeconds) / Double(totalSeconds)))
    }

    var isReading: Bool {
        if case .reading = phase { return true }
        return false
    }

    // MARK: Written by the manager

    func updateRemainingSeconds(_ seconds: Int) {
        guard isReading, !isDisconnected else { return }
        remainingSeconds = max(0, seconds)
    }

    /// When local payment extends the window, the progress bar's denominator is raised along with it.
    ///
    /// Only this field needs to move: `remainingSeconds` belongs to the manager's clock, and the very next `tick()` rewrites it from the
    /// moved deadline. If the denominator is not raised too, the bar stays full all the way down and never shortens — the `progress` field
    /// has a `min(1, …)` that flattens it, so this bug never gets exposed as "over 100%",
    /// it only turns the one visualisation of the remaining time into a decorative bar.
    /// Shares the same guard as `updateRemainingSeconds`: in an already-burned / already-disconnected window there is nothing to extend.
    func extendTotal(by seconds: Int) {
        guard isReading, !isDisconnected else { return }
        totalSeconds += seconds
    }

    func lock(reason: String) {
        guard !isDisconnected else { return }
        phase = .locked(reason: reason)
        PopopxHaptics.notice(.warning)
    }

    /// Enter the "burned" phase. The plaintext is handed over here, without waiting for the window to be torn down.
    ///
    /// The parameters are given by the **manager** (see `PopopxSecureWindowManager.burn`); the model does not infer the deletion outcome:
    /// `deleted` can only ever come from one source of truth, "the host really obtained the itemId and issued the delete request".
    func burn(reason: String?, receiptCount: Int, deleted: Bool) {
        erasePlaintext()
        guard !isDisconnected else { return }
        phase = .burned(reason: reason, receiptCount: receiptCount, deleted: deleted)
    }

    /// The last step before teardown: cut the callbacks first, then hand over the plaintext.
    func invalidate() {
        isDisconnected = true
        erasePlaintext()
        phase = .closed
    }

    // MARK: Written by the view

    func requestClose() {
        // A single exit: whether it comes from the button, `onDisappear`, or the system back gesture, it only takes the host's one destruction path.
        guard !isDisconnected else { return }
        close()
    }
}

// MARK: - The view

/// The top-secret window's content surface. Its only input is the model: no app type, no host closure,
/// so this file, together with the whole `SecureEphemeral/` directory, can be type-checked outside the Xcode project.
struct PopopxSecureSheetView: View {
    @Bindable private var model: PopopxSecureSheetModel
    /// The toast model belongs privately to this view: the top-secret window belongs to no chat page, so it cannot get the one the host injects.
    @State private var toastModel = PopopxToastModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: PopopxSecureSheetModel) {
        self.model = model
    }

    var body: some View {
        ZStack {
            PopopxSecureSurface.backdrop
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .popopxToast(toastModel)
        // When the window is torn down by outside forces (system gesture, scene switch) it must also take the same destruction path.
        // The double cleanup with `dismissSecureWindow()` is safe precisely because of `PopopxSecureSheetModel.isDisconnected`.
        .onDisappear { model.requestClose() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .reading:
            reading
        case .locked(let reason):
            PopopxSecureMask(text: reason, footnote: PopopxSecureCopy.lockFootnote) {
                model.requestClose()
            }
        case .burned(let reason, let receipts, let deleted):
            PopopxSecureMask(
                text: reason ?? PopopxSecureCopy.cardDestroyed,
                footnote: PopopxSecureCopy.burnFootnote(receipts: receipts, deleted: deleted)
            ) {
                model.requestClose()
            }
        case .closed:
            // An empty view: the window is being torn down, and drawing anything here would flash for one last frame.
            Color.clear
        }
    }

    // MARK: The reading surface

    private var reading: some View {
        VStack(spacing: PopopxMetrics.spaceL) {
            header
            readerArea
            controls
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.top, PopopxMetrics.spaceL)
        .padding(.bottom, PopopxMetrics.spaceM)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(PopopxPalette.brand)
                    .accessibilityHidden(true)
                Text(PopopxSecureCopy.cardTitle)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxSecureSurface.ink)
                Spacer(minLength: PopopxMetrics.spaceS)
                // Numbers use monospacedDigit: the layout does not jump when the countdown changes digit each second,
                // and a jumping layout would pull the user's gaze onto "how many seconds are left", straight into the line that is fading out.
                Text(PopopxSecureCopy.duration(model.remainingSeconds))
                    .font(PopopxType.metric)
                    .foregroundStyle(remainingInk)
                    .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("%lld seconds remaining", comment: ""), model.remainingSeconds)))
            }
            // `value:total:` (there is no `in:` label, `in:` is how `Slider` is written).
            ProgressView(value: Double(model.remainingSeconds), total: Double(max(1, model.totalSeconds)))
                .progressViewStyle(.linear)
                .tint(remainingInk)
                .accessibilityHidden(true)
                // The animation hangs on the progress bar itself, not on the whole header or the control area:
                // `value:` must live in the same place as "the number being animated", otherwise the once-per-second state change would also
                // make the title, the time copy and the icons interpolate together, and that is where the user reads text.
                // nil is passed when motion is switched off: a per-second 0.1 step is just noise under reduceMotion.
                .animation(reduceMotion ? nil : PopopxSpring.fluid, value: model.remainingSeconds)
        }
    }

    private var remainingInk: Color {
        // The last 5 seconds turn red. The threshold hugs `PopopxSecurePayload.minimumTTLSeconds` (=5):
        // the shortest tier lies entirely inside the "should already be warning" range, instead of a 15-second window that only changes face in its last 1/3.
        model.remainingSeconds <= 5 ? PopopxPalette.danger : PopopxSecureSurface.ink
    }

    /// The body area. Three things are stacked here: the reading-mode view, the anti rolling-shutter layer, the blind watermark.
    /// The order is **from inside outwards**: the watermark sits above the reading layer (what it must cover is "the final pixels on the screen"),
    /// and the anti-photo layer sits above the watermark (what it must interrupt is the rolling shutter sampling any row at all, including the watermark dots).
    private var readerArea: some View {
        Group {
            if let text = model.text {
                reader(for: text)
            } else {
                // Plaintext is gone yet still in `reading`: only a manager that missed a phase write gets here.
                // It keeps an empty black surface rather than crashing, and shows no hint either — a hint would nail the user's attention to "there should be text here".
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay {
            PopopxBlindWatermarkOverlay(sessionIdentifier: model.sessionIdentifier)
                .allowsHitTesting(false)
        }
        .overlay {
            PopopxAntiPhotoRenderView(isEnabled: model.antiPhotoEnabled)
                .allowsHitTesting(false)
        }
        // The whole plaintext block stays out of the accessibility tree; see the "screen reader" section of the file header: this is a trade-off, not an omission,
        // so it must at the same time be said in the interface (that `accessibilityNote` sentence inside `controls`).
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func reader(for text: String) -> some View {
        switch model.readMode {
        case .spotlight:
            PopopxSpotlightTextView(text: text, radius: PopopxSecureSurface.spotlightRadius)
        case .teleprompter:
            PopopxTeleprompterTextView(text: text)
        }
    }

    // MARK: The control surface

    private var controls: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            PopopxSegmentedControl(
                PopopxSecureReadMode.allCases.map { PopopxSegmentedControl<PopopxSecureReadMode>.Option(selection: $0, title: $0.title) },
                title: \.title,
                selection: $model.readMode
            )
            .onChange(of: model.readMode) { _, mode in
                // Switching modes without saying a word makes users think the rendering broke: the two modes interact completely differently (one follows the finger, one needs press-and-drag).
                toastModel.show(mode.note, kind: .mesh)
            }

            PopopxToggleRow(
                NSLocalizedString("Anti-rephoto vibration", comment: ""),
                note: PopopxSecureCopy.antiPhotoNote,
                systemImage: "camera.viewfinder",
                tint: .brand,
                isOn: $model.antiPhotoEnabled
            )

            if let note = model.guardNote {
                Label {
                    Text(note).font(PopopxType.caption)
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
                .foregroundStyle(PopopxSecureSurface.inkSecondary)
                .accessibilityElement(children: .combine)
            }

            Text(PopopxSecureCopy.accessibilityNote)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxSecureSurface.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // "Extend the anti-peep window with compute points": the points are deducted by the local ledger and the clock is moved by the manager, this layer only supplies a button to press.
            // Neither the duration nor the price is written into the copy; both are taken from `PopopxCommerceLimits`: the first decides how many seconds to move,
            // the second is exactly the amount deducted. The compute-point centre's use table already shows these two numbers once,
            // and copying each again here would be a third place to copy from.
            PopopxButton(
                PopopxSecureCopy.extendWindowTitle(
                    seconds: PopopxCommerceLimits.extendedSecureWindowSeconds,
                    cost: PopopxCommerceLimits.extendedSecureWindowCost
                ),
                systemImage: "hourglass",
                role: .secondary,
                fullWidth: true
            ) {
                // A failure must always be said out loud: the insufficient-points sentence comes from the ledger, "no session available to extend" comes from the manager.
                // A silent payment button is the ugliest thing in this family — all the user knows is that pressing it did nothing.
                if let failure = PopopxSecureWindowManager.shared.extendViewingWindow() {
                    toastModel.show(failure, kind: .danger)
                }
            }

            PopopxButton(
                NSLocalizedString("Close and destroy", comment: ""),
                systemImage: "lock.rectangle.stack",
                role: .destructive,
                fullWidth: true
            ) {
                model.requestClose()
            }
        }
    }
}

// MARK: - The overlay

/// The black-background overlay: the locked and burned phases share one layout.
///
/// `PopopxSectionCard` is deliberately not used: that card has shadows and a light background, it is designed for the content layer inside the app.
/// This screen is a security surface and keeps only "one sentence + one action"; every extra decoration costs a little of the certainty that "this is over".
private struct PopopxSecureMask: View {
    let text: String
    let footnote: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: PopopxMetrics.spaceM) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(PopopxPalette.brand)
                .accessibilityHidden(true)
            Text(text)
                .font(PopopxType.title)
                .foregroundStyle(PopopxSecureSurface.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(footnote)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxSecureSurface.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PopopxButton(NSLocalizedString("OK", comment: ""), systemImage: nil, role: .secondary, fullWidth: false) {
                action()
            }
            .padding(.top, PopopxMetrics.space2XS)
        }
        .padding(PopopxMetrics.spaceXL)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusSheet))
        .background(PopopxSecureSurface.cardFill)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Layout constants

/// Several visual constants of the security surface, kept in one place instead of scattered through the views: this screen's background and ink must match exactly across the overlay, the body,
/// and the list card, otherwise "did the overlay actually cover it" becomes a difference the eye has to judge.
enum PopopxSecureSurface {
    /// The whole-screen background: true black, and **constant**. Two reasons:
    /// 1. The shield also draws pure black for the capture side, and when the two disagree the content area's boundary is visible in a recording;
    /// 2. `PopopxPalette.base` is not used — in dark mode it really is `#000000`, but that **follows colorScheme**,
    ///    and this screen's black may not be flipped by any mode switch.
    static let backdrop = Color.black

    /// The ink on a security surface **must be constant**, so the palette's ink tokens cannot be used directly here:
    /// `PopopxPalette.onBrand` is `Color.popopx(light: 0xFFFFFF, dark: 0x0A0A1F)`,
    /// and in dark mode it is close to black — putting it on this surface would hand over a screen of top-secret content "invisible in dark mode",
    /// and dark mode is most people's default. The `label` family is the same (light mode `#111114`).
    ///
    /// So it goes through `Color.popopx(_:UInt32)`, the entry that does not flip with the mode: still inside the design system (the same
    /// ruling requires "only `PopopxPalette`/`Color.popopx`, no hand-written hex"), and it takes the non-flipping overload.
    /// The values align with the palette's dark tier, avoiding a second kind of white between the security surface and the app body.
    static let ink = Color.popopx(0xF4F4F6)
    static let inkSecondary = Color.popopx(0xA6A6B0)
    /// Used only for placeholders and the destroyed state. Aligned with `labelHint`, again so that no third kind of white appears on the security surface.
    static let inkTertiary = Color.popopx(0x8A8A94)

    /// The overlay background: a very deep indigo violet, giving "this is not an ordinary page" a little warmth, but not forming a second palette.
    static let cardFill = Color.popopx(light: 0x1A1030, dark: 0x140C26)
    /// The list card background: the same family as the overlay, one tier lighter, so that hierarchy stays readable inside the conversation list.
    static let cardBubbleFill = Color.popopx(light: 0x241640, dark: 0x1B1132)

    /// The clear-area radius of spotlight mode. 45pt is the tier the prompt specifies, and it is a size one fingertip can cover while a line stays readable
    /// (`PopopxMetrics.minHitTarget`'s 44pt is the floor for "tappable", not the same thing as the diameter of the "readable" window).
    static let spotlightRadius: CGFloat = 45
}

// MARK: - The list card

/// The top-secret card in the conversation list (module 5's "render as a dedicated deep indigo lock-shield card, exposing plaintext in the list is strictly forbidden").
///
/// The colours do not take the bubble's scheme: `PopopxBubbleInk` is `private` inside `PopopxMessageBubble.swift`,
/// so it cannot be reached across files (this was measured, not guessed), and a top-secret card should not change colour with channel or send direction anyway —
/// it is the only "security surface" on this screen, with two fixed inks for light and dark (`PopopxSecureSurface`).
struct PopopxSecureCardBubble: View {
    enum State: Hashable {
        /// Can be opened.
        case locked
        /// The payload parses but cannot be decrypted (altered / wrong key): it stays in the list, but can never be opened.
        case damaged
        /// This device cannot match the record's origin (the conversation id or the message id is missing). That is not the same thing as "corrupted":
        /// the ciphertext may be intact, this device simply does not know which row to delete, so no entry point to open it is ever given.
        case unlocated
    }

    let ttlText: String
    let state: State
    var incoming: Bool = false
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: PopopxMetrics.spaceS) {
                mark
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(title)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(ink)
                    Text(subtitle)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxSecureSurface.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: PopopxMetrics.spaceS)
                if state == .locked {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PopopxSecureSurface.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, PopopxMetrics.spaceM)
            .padding(.vertical, PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(.rect(cornerRadius: PopopxMetrics.radiusCard))
            .background(cardFill)
            .popopxCardElevation(colorScheme: colorScheme)
        }
        .buttonStyle(.plain)
        .disabled(state != .locked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier(incoming ? "popopx.bubble.secure" : "popopx.bubble.secure.outgoing")
    }

    private var mark: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(state == .damaged ? PopopxPalette.danger : PopopxPalette.brand)
            .frame(width: PopopxMetrics.space2XL - PopopxMetrics.spaceS)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .locked: "lock.shield.fill"
        // Corrupted = this is a security event, so the shield must carry an exclamation mark; a missing origin is not a security event,
        // the device has simply lost that memory, so it borrows the list's "unavailable" question-mark folder instead of minting a third shield.
        case .damaged: "exclamationmark.shield.fill"
        case .unlocated: "questionmark.folder"
        }
    }

    private var title: String {
        switch state {
        case .locked: return PopopxSecureCopy.cardTitle
        case .damaged: return NSLocalizedString("Top secret message is damaged", comment: "")
        case .unlocated: return NSLocalizedString("Top secret message cannot be opened", comment: "")
        }
    }

    private var subtitle: String {
        switch state {
        case .locked: return PopopxSecureCopy.cardLockedHint + " · " + ttlText
        case .damaged: return NSLocalizedString("The ciphertext or the key is incomplete, so it cannot be decrypted", comment: "")
        case .unlocated: return NSLocalizedString("This device has no trace of where the record was stored, so the message cannot be located", comment: "")
        }
    }

    private var accessibilityText: String {
        switch state {
        case .locked: return String(format: NSLocalizedString("Top secret, burn after reading, %@, a tap needs biometric unlock", comment: ""), ttlText)
        case .damaged: return NSLocalizedString("The top secret message is damaged and cannot be opened", comment: "")
        case .unlocated: return NSLocalizedString("The top secret message cannot be opened; this device cannot locate the record", comment: "")
        }
    }

    private var ink: Color {
        // "Corrupted" must be read clearly, so its ink is not lowered; "cannot be opened" is an accomplished fact, lowered one tier so it does not compete with corrupted for attention.
        state == .unlocated ? PopopxSecureSurface.inkTertiary : PopopxSecureSurface.ink
    }

    private var cardFill: Color {
        state == .unlocated
            ? PopopxSecureSurface.cardBubbleFill.opacity(0.55)
            : PopopxSecureSurface.cardBubbleFill
    }

    private func handleTap() {
        guard state == .locked else { return }
        PopopxHaptics.impact(.medium)
        onOpen()
    }
}

private extension PopopxSecureCopy {
    /// This sentence, `lockFootnote`, `burntWithReceipt` and `antiPhotoNote` are copy unique to this file,
    /// and are not stuffed into the payload file: the payload layer's copy has to be shared by the card, the receipt and the bubble,
    /// while these few belong only to the world after the window has already opened.
    ///
    /// A `private extension` is used rather than raw string constants: `PopopxSecureCopy`'s other members live in
    /// the payload file, and when a reader jumps between the two places the names must look like the same family.
    static let accessibilityNote = NSLocalizedString("This message does not give its text to the screen reader (VoiceOver).", comment: "")
    static let lockFootnote = NSLocalizedString("The risk is still there. Closing destroys this message.", comment: "")
    static let burntQuietly = NSLocalizedString("The record on this device was deleted.", comment: "")
    /// The one sentence admitting "this one did not get done". It ranks before the receipt and is mutually exclusive with it: since the record was not deleted,
    /// telling the other side "destroyed" would be a false statement, so this tier is not even given the receipt's wording.
    static let burntWithoutDeletion = NSLocalizedString("The plaintext was erased from memory, but this device could not locate the record: it was not deleted.", comment: "")
    static func burntWithReceipt(count: Int) -> String {
        count == 1 ? NSLocalizedString("The record on this device was deleted and the other side was notified.", comment: "") : String(format: NSLocalizedString("The record on this device was deleted, with %lld notifications sent.", comment: ""), count)
    }
    /// The burned phase's subtitle: each of the three real outcomes says its own, with no optimistic merging.
    static func burnFootnote(receipts: Int, deleted: Bool) -> String {
        guard deleted else { return burntWithoutDeletion }
        return receipts > 0 ? burntWithReceipt(count: receipts) : burntQuietly
    }
    static let antiPhotoNote = NSLocalizedString("Rapid vibration interferes with rolling-shutter re-photography. It also increases power use and heat.", comment: "")
    /// The extend button's one-line label. The duration goes through `PopopxSecureCopy.duration`, so if
    /// `PopopxCommerceLimits.extendedSecureWindowSeconds` is later changed to 1800, this automatically becomes "30 minutes".
    static func extendWindowTitle(seconds: Int, cost: Int) -> String {
        String(format: NSLocalizedString("Extend by %1$@ · %2$lld Compute Credits", comment: ""), duration(seconds), cost)
    }
}

struct PopopxSecureCardBubbleStates_Previews: PreviewProvider {
    static var previews: some View {
        // All three states visible at once: openable, undecryptable, unlocatable on this device. The last two must both read as "this is not something you can retry",
        // so symbol, ink and subtitle change together in three places; lowering opacity alone is not enough.
        VStack(spacing: PopopxMetrics.spaceS) {
            PopopxSecureCardBubble(ttlText: PopopxSecureCopy.duration(60), state: .locked) {}
            PopopxSecureCardBubble(ttlText: PopopxSecureCopy.duration(60), state: .damaged) {}
            PopopxSecureCardBubble(ttlText: PopopxSecureCopy.duration(60), state: .unlocated) {}
        }
        .padding(PopopxMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PopopxPalette.base)
    }
}
