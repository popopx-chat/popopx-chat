//  PopopxVoucherRedeemSheet.swift
//
//  [Phase 5 · 6] Redeem panel: turns a `PPX1-…` (badge) or `PPXC1-…` (compute credit) string into one on-device connection setup + one wait for the peer's confirmation.
//
//  ### Pressing "redeem" returns not a result but "initiated"
//  `router.startExternalRedeem(code:)` does only three things: check the code, check the signature, create one incognito connection.
//  The REQ can only go out after `contactConnected` (before the peer accepts the connection it cannot carry messages), and the ACK is later still,
//  so this panel **subscribes** to `router.lastOutcome` instead of treating the return value as the final state. Showing `.initiated` as
//  "redeemed successfully" is the thing in this feature most easily written wrong, and most easily read by review as misleading.
//
//  ### The final state may never arrive
//  The other side may no longer be on that device, may have deleted the app, may have been offline for a long time. Therefore:
//  - this page may be closed at any time, and the "waiting for the other side to confirm" sentence must make clear **closing it does not affect the result**;
//  - no timeout, no promise of retry, no progress bar. For a redemption with no answer, the honest answer is "no answer".
//
//  ### Paste takes priority over copying by hand
//  `PopopxRedeemCode.normalized` only strips whitespace and fixes the prefix's case — the payload itself is base64url,
//  **case sensitive**. So the UI makes "paste" a first-class button and states plainly "please do not copy it out character by character".
//  Display uses the `grouped` segmentation (readable), submission uses the raw text (decodable).
//
//  ### Why the scanner is written again in this module
//  `PopopxAddFriendView.swift:519` already has `PopopxScannerSheet`, but it is `private` and hands the result to
//  the "link classification" path (offline gate / online invite), and a redemption code is neither a link nor should it go through that classification.
//  All that is needed here is "hand a camera viewfinder to the system permission state machine", so a second copy was written following the same authorisation/failure/rebuild flow,
//  and the comment on `PopopxRedeemScanner` below states its difference from the first one (not sharing it is to avoid changing the already device-verified add-friend page,
//  not to save one import).
//  The camera session is self-owned by this file (`PopopxQRScannerView`), and the `CodeScanner` package is not used: the package's
//  `ScannerViewController` only calls `stopRunning()` asynchronously in `viewDidDisappear` and **never releases the session reference**,
//  while this project's red line requires "both on successful recognition and on page disappearance must stopRunning and set to nil".
//  The stop order is copied from `Shared/Features/SecureEphemeral/PopopxCameraGuardEngine.swift:43`:
//  detach delegate → stopRunning → release the reference; `dismantleUIView` is the landing point of the page-disappearance path.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.

import SwiftUI
import AVFoundation
import UIKit
import POPOPXChat

struct PopopxVoucherRedeemSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var router = PopopxSilentSignalingRouter.shared
    @State private var badge = PopopxBadgeManager.shared
    @State private var codeText = ""
    @State private var showsScanner = false
    @State private var stage: PopopxRedeemStage = .idle

    var body: some View {
        PopopxSheetContainer(Copy.title, subtitle: Copy.subtitle) {
            content
        } footer: {
            footer
        }
        .sheet(isPresented: $showsScanner) {
            PopopxRedeemScanner { scanned in
                codeText = scanned
                Task { await submit() }
            }
        }
        // The final state is written asynchronously by the router: here we only follow it, never infer it.
        .onChange(of: router.lastOutcome) { _, outcome in
            if let outcome { stage = .initiated(outcome) }
        }
    }

    // // MARK: Layout

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                PopopxSectionCard(Copy.inputTitle, footnote: Copy.inputFootnote) {
                    VStack(spacing: PopopxMetrics.spaceXS) {
                        PopopxTextField(Copy.codeLabel, prompt: Copy.codePrompt, text: $codeText,
                                        keyboard: .default)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        HStack(spacing: PopopxMetrics.spaceS) {
                            PopopxButton(Copy.paste, systemImage: "doc.on.clipboard",
                                         role: .secondary, fullWidth: true) {
                        pasteFromClipboard()
                            }
                            PopopxButton(Copy.scan, systemImage: "qrcode.viewfinder",
                                         role: .secondary, fullWidth: true) {
                                showsScanner = true
                            }
                        }
                    }
                }

                statusCard

                boundaries
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch stage {
        case .idle, .busy:
            PopopxSectionCard(Copy.howTitle) {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                    step("1", Copy.howOne)
                    step("2", Copy.howTwo)
                    step("3", Copy.howThree)
                }
            }
        case let .initiated(outcome):
            resultCard(outcome)
        case let .localNote(text):
            PopopxSectionCard {
                Text(verbatim: text)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resultCard(_ outcome: PopopxRedemptionOutcome) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: symbol(for: outcome))
                    .font(PopopxType.emphasis)
                    .foregroundStyle(color(for: outcome))
                Text(verbatim: outcome.announcementText)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(color(for: outcome))
            }
            Text(verbatim: gloss(outcome))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // The extra line is badge-only on purpose: a badge has a *deadline* the user cannot recompute from the days just added
            // (it merges with the time already running), while the credit answer is one number and the balance sits on the store page behind this sheet.
            if case .redeemed = outcome, let description = badge.remainingDescription {
                Text(verbatim: description)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.meshInk)
            }
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }

    private var boundaries: some View {
        PopopxSectionCard(Copy.boundariesTitle, footnote: Copy.boundariesFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                bullet(Copy.boundaryOne)
                bullet(Copy.boundaryTwo)
                bullet(Copy.boundaryThree)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: "circle")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelHint)
                .frame(width: PopopxMetrics.spaceL, alignment: .leading)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Text(verbatim: index)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.onBrand)
                .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                .background(PopopxPalette.brand, in: .circle)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            PopopxButton(Copy.redeem, systemImage: "sparkles", isLoading: stage == .busy) {
                await submit()
            }
            .disabled(!stage.canSubmit)
            PopopxButton(Copy.close, role: .ghost) {
                dismiss()
            }
        }
    }

    // // MARK: Actions

    private func submit() async {
        // Normalising here is load-bearing, not cosmetic: `decode` normalises internally, so a lowercase `ppxc1-` used to reach the badge leg
        // and fail as "malformed". Routing on the prefix happens before either decoder, so the case fix has to come first.
        let code = PopopxRedeemCode.normalized(codeText)
        guard !code.isEmpty, stage != .busy else { return }
        // An eco service/SSO link is not a redemption code. Intercepted here rather than in the scanner closure so the camera path and
        // the paste path cannot disagree, and so that nothing is recorded as a failed code: the legs below would report a link this
        // sheet was never meant to read as an invalid voucher.
        if PopopxEcoDeepLinkHandler.handle(text: code) {
            codeText = ""
            return
        }
        stage = .busy
        // The prefix picks the leg, and only the leg: `decodeCredit` rejects a badge body and `decode` rejects a credit one,
        // so a code of the wrong family is refused outright instead of being redeemed as the other kind.
        let outcome = PopopxRedeemCode.prefix(of: code) == PopopxRedeemCode.creditPrefix
            ? await router.startExternalCreditRedeem(code: code)
            : await router.startExternalRedeem(code: code)
        stage = .initiated(outcome)
        switch outcome {
        case .failed: PopopxHaptics.notice(.error)
        case .redeemed, .redeemedCredits: PopopxHaptics.notice(.success)
        case .initiated: break
        }
    }

    private func pasteFromClipboard() {
        guard let raw = UIPasteboard.general.string, !raw.isEmpty else {
            stage = .localNote(Copy.clipboardEmpty)
            return
        }
        let normalized = PopopxRedeemCode.normalized(raw)
        guard PopopxRedeemCode.decode(normalized) != nil || PopopxRedeemCode.decodeCredit(normalized) != nil else {
            // The clipboard does hold text, but it is not this version of the code: put the content in first (so the user can check it themselves),
            // then explain why it is not accepted, rather than throwing away what the user just pasted.
            codeText = normalized
            stage = .localNote(Copy.clipboardNotCode)
            return
        }
        codeText = normalized
        stage = .idle
    }

    // // MARK: Presentation details

    private func symbol(for outcome: PopopxRedemptionOutcome) -> String {
        switch outcome {
        case .initiated: "hourglass"
        // Both success families take the same glyph: what differs between them is the sentence below it, not whether it landed.
        case .redeemed, .redeemedCredits: "checkmark.seal"
        case .failed: "xmark.circle"
        }
    }

    private func color(for outcome: PopopxRedemptionOutcome) -> Color {
        switch outcome {
        case .initiated: PopopxPalette.labelSecondary
        case .redeemed, .redeemedCredits: PopopxPalette.successInk
        case .failed: PopopxPalette.dangerInk
        }
    }

    /// Every final state gets one more sentence about "what happens next", instead of only a single word.
    private func gloss(_ outcome: PopopxRedemptionOutcome) -> String {
        switch outcome {
        case .initiated:
            Copy.glossInitiated
        case let .redeemed(period, _):
            Copy.glossRedeemed(period.days)
        case let .redeemedCredits(amount, _):
            Copy.glossRedeemedCredits(amount)
        case let .failed(error):
            Copy.glossFailure(error)
        }
    }
}

// // MARK: - Stage

/// The panel's own four-cell state. `.busy` and `.result` are kept apart because "this machine has finished answering"
/// and "still waiting for the other side's machine to answer" are two different things, and merging them into one cell would show a stale result while waiting.
enum PopopxRedeemStage: Hashable {
    case idle
    case busy
    case initiated(PopopxRedemptionOutcome)
    /// A refusal the local machine can settle on its own (the clipboard is empty): it does not borrow `PopopxBadgeCreditsError`'s wording,
    /// because those sentences all assume "there is a code", and here there is no code at all.
    case localNote(String)

    var canSubmit: Bool {
        switch self {
        case .busy: false
        default: true
        }
    }
}

// // MARK: - Scan

/// The redemption-code viewfinder. It differs from the one in `PopopxAddFriendView` in exactly one place: no link classification here,
/// whatever is scanned is handed to the caller as it is (reason in the file header). The authorisation state machine, failure rebuild and placeholder stay consistent.
struct PopopxRedeemScanner: View {
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cameraStatus: AVAuthorizationStatus?
    /// Changing the id once means rebuilding the viewfinder (`makeUIView`/`dismantleUIView` each run once): that is the only way to retry a session that will not start.
    @State private var scanAttempt = 0
    @State private var failureNote: String?

    var body: some View {
        PopopxSheetContainer(ScannerCopy.scan, subtitle: ScannerCopy.subtitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                content
                if let failureNote {
                    Text(verbatim: failureNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            PopopxButton(ScannerCopy.close, role: .secondary) { dismiss() }
                .padding(PopopxMetrics.spaceM)
        }
        .task { await ensureCameraAccess() }
    }

    @ViewBuilder private var content: some View {
        switch cameraStatus {
        case .authorized:
            PopopxQRScannerView(onScan: receiveScan, onFailure: reportScannerFailure)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: PopopxMetrics.radiusCard))
                .id(scanAttempt)
        case .notDetermined:
            // `.task` has already raised the system authorisation sheet, so this cell is the few frames behind that sheet.
            placeholder(systemImage: "camera", text: ScannerCopy.cameraStarting)
        case .denied:
            placeholder(systemImage: "video.slash",
                        text: ScannerCopy.cameraDenied,
                        actionTitle: ScannerCopy.openSettings,
                        action: { UIApplication.shared.open(appSettingsURL) })
        case .restricted:
            placeholder(systemImage: "nosign", text: ScannerCopy.cameraRestricted)
        default:
            placeholder(systemImage: "questionmark", text: ScannerCopy.cameraUnknown)
        }
    }

    private func placeholder(systemImage: String, text: String,
                             actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: systemImage)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let run = action {
                PopopxButton(actionTitle, systemImage: "gearshape", role: .secondary, fullWidth: false) {
                    run()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .padding(PopopxMetrics.spaceM)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }

    @MainActor private func ensureCameraAccess() async {
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            status = granted ? .authorized : .denied
        }
        cameraStatus = status
    }

    private func receiveScan(_ text: String) {
        // The session has already been stopped and released inside the callback (see `PopopxQRScannerView`); this only takes the viewfinder out of the hierarchy
        // and then hands over the raw text. Reversing the order would run the `onScan` path while the camera is still on.
        dismiss()
        onScan(text)
    }

    /// When it will not start (no rear camera / session in use) only one sentence and **at most two** rebuilds are kept: changing `scanAttempt` makes SwiftUI
    /// dismantle first and then make, and the old session is already stopped at that step, so a second one never piles up.
    /// Without a cap, a device that can never start the camera would loop here forever — each turn is one authorisation check plus one session construction.
    private func reportScannerFailure(_ reason: String) {
        failureNote = String(format: ScannerCopy.scanFailedFormat, reason)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == cameraStatus else {
            // The permission is gone at this moment (the user turned it off in Settings, or the system revoked it): take the whole viewfinder off stage instead of rebuilding it.
            cameraStatus = status
            return
        }
        if scanAttempt < Self.maximumScannerRebuilds {
            scanAttempt += 1
        }
    }

    private static let maximumScannerRebuilds = 2
}

// // MARK: - Self-owned viewfinder

/// A `UIViewRepresentable` wrapping one `AVCaptureSession`, QR only. This layer was written instead of using a third-party package
/// so that both moments named in the red line (recognition succeeded, page disappeared) have stop code **visible inside this file**.
/// The lifecycle has only one path that could leak: `makeUIView` starts the session and `dismantleUIView` stops it and releases the reference,
/// and SwiftUI takes the latter both when the `id` changes and when the view is unloaded, so page disappearance needs no extra manual stop.
private struct PopopxQRScannerView: UIViewRepresentable {
    let onScan: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> PopopxQRScannerCoordinator {
        PopopxQRScannerCoordinator(onScan: onScan, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> PopopxQRPreviewView {
        let view = PopopxQRPreviewView()
        context.coordinator.start(preview: view)
        return view
    }

    /// There is no session-lifetime state to pass down, so this is empty. The two callbacks are remembered by the coordinator only at the one `makeUIView` call:
    /// they capture `@State`'s storage reference, and the new closures swapped in by a parent re-render point at the same cell, so an old closure cannot write to the wrong place.
    func updateUIView(_ uiView: PopopxQRPreviewView, context: Context) {}

    static func dismantleUIView(_ view: PopopxQRPreviewView, coordinator: PopopxQRScannerCoordinator) {
        coordinator.stop()
        view.detachSession()
    }
}

/// The preview layer is provided by `layerClass`, so this view itself does not hold the session, it only offers the attach and detach two hooks.
private final class PopopxQRPreviewView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

    func attach(_ session: AVCaptureSession) {
        previewLayer?.session = session
    }

    func detachSession() {
        previewLayer?.session = nil
    }
}

private final class PopopxQRScannerCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let onScan: (String) -> Void
    private let onFailure: (String) -> Void
    private var session: AVCaptureSession?
    /// One capture delivers a result once only: `AVCaptureMetadataOutput` calls back every frame, and without a gate the redemption code would be handed over several times.
    private var handled = false

    init(onScan: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        self.onScan = onScan
        self.onFailure = onFailure
    }

    func start(preview: PopopxQRPreviewView) {
        let built = AVCaptureSession()
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), built.canAddInput(input) else {
            onFailure(ScannerCopy.cameraUnavailable)
            return
        }
        let output = AVCaptureMetadataOutput()
        guard built.canAddOutput(output) else {
            onFailure(ScannerCopy.cameraUnavailable)
            return
        }
        built.beginConfiguration()
        built.addInput(input)
        built.addOutput(output)
        // QR only: a redemption code is a long base64url string printed under either prefix, other symbologies have nothing to map to here, and recognising one more just adds a decoding path that can go wrong.
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: .main)
        built.commitConfiguration()
        preview.attach(built)
        session = built
        // `startRunning()` is a blocking call, so putting it on the main thread would stall this frame's layout (the same reason as this project's other camera paths).
        DispatchQueue.global(qos: .userInitiated).async {
            built.startRunning()
        }
    }

    /// Stop order: detach the delegate first (from then on no callback can come in), then `stopRunning`, then release the reference.
    /// Reversed, the late frame arriving during `stopRunning` would call back holding a session that has already begun being torn down.
    func stop() {
        guard let session else { return }
        self.session = nil
        for case let output as AVCaptureMetadataOutput in session.outputs {
            output.setMetadataObjectsDelegate(nil, queue: nil)
        }
        let wasRunning = session.isRunning
        DispatchQueue.global(qos: .userInitiated).async {
            if wasRunning { session.stopRunning() }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !handled,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let text = object.stringValue, !text.isEmpty
        else { return }
        handled = true
        // Red line: the successful-recognition path must also stop the session first, then deliver the result.
        stop()
        onScan(text)
    }
}


// // MARK: - Copy

private extension PopopxVoucherRedeemSheet {
    enum Copy {
        static let title = NSLocalizedString("Redeem a gift code", comment: "")
        static let subtitle = NSLocalizedString("With a redemption code, receive on this device what the other side gifted.", comment: "")
        static let inputTitle = NSLocalizedString("Redemption code", comment: "")
        static let inputFootnote = NSLocalizedString("A long string that starts with PPX1- or PPXC1-. Paste it; do not retype it by hand: it is case-sensitive and one wrong character means verification fails.", comment: "")
        static let codeLabel = NSLocalizedString("Redemption code", comment: "")
        static let codePrompt = "PPX1- / PPXC1-…"
        static let paste = NSLocalizedString("Paste", comment: "")
        static let scan = NSLocalizedString("Scan", comment: "")
        static let redeem = NSLocalizedString("Redeem", comment: "")
        static let close = NSLocalizedString("Close", comment: "")
        static let howTitle = NSLocalizedString("What happens", comment: "")
        static let howOne = NSLocalizedString("This device first verifies the signature inside the code, then connects to the gifter's device and sends the redemption request.", comment: "")
        static let howTwo = NSLocalizedString("The other side confirms the voucher has not been redeemed yet, then signs an authorization and sends it back.", comment: "")
        static let howThree = NSLocalizedString("Once that authorization checks out, this device records the badge or the credits, and the one-time connection is deleted.", comment: "")
        static let boundariesTitle = NSLocalizedString("What this screen promises, and what it does not", comment: "")
        static let boundariesFootnote = NSLocalizedString("Only what this layer can actually deliver.", comment: "")
        static let boundaryOne = NSLocalizedString("Network needed: redeeming exchanges two messages with the gifter's device.", comment: "")
        static let boundaryTwo = NSLocalizedString("A voucher redeems once; submitting it again reports it as already redeemed.", comment: "")
        static let boundaryThree = NSLocalizedString("On success the badge or the credits land on this device even if this page has already been closed.", comment: "")
        static let glossInitiated = NSLocalizedString("The request is on its way. Wait for the gifter's device to confirm — you can close this page, and the capsule lights up by itself once it lands.", comment: "")
        static func glossRedeemed(_ days: Int) -> String { String(format: NSLocalizedString("Lit up %lld days, written into this device's badge record and merged with any remaining time.", comment: ""), days) }
        /// The credit twin of the sentence above, phrased the same way because the two events are the same event on two families of card.
        /// It says "do not expire" because that is the one difference a reader would otherwise assume carried over from a badge.
        static func glossRedeemedCredits(_ credits: Int) -> String { String(format: NSLocalizedString("Added %lld Compute Credits, written into this device's credit balance; they do not expire.", comment: ""), credits) }
        static func glossFailure(_ error: PopopxBadgeCreditsError) -> String {
            switch error {
            case .codeMalformed: NSLocalizedString("This code cannot be decoded: it may be truncated, mistyped, or not from this version.", comment: "")
            case .signalRejected: NSLocalizedString("The signature does not verify: this code is not the voucher that was issued.", comment: "")
            case .connectionUnavailable: NSLocalizedString("Cannot reach the gifter's device: the link may have expired — ask the other side for a new voucher.", comment: "")
            case .voucherAlreadyRedeemed: NSLocalizedString("This voucher has already been redeemed.", comment: "")
            default: NSLocalizedString("That did not complete; you can try again later.", comment: "")
            }
        }
        static let clipboardEmpty = NSLocalizedString("The clipboard is empty.", comment: "")
        static let clipboardNotCode = NSLocalizedString("The clipboard text does not look like a redemption code (it must start with PPX1- or PPXC1-). It has been placed in the field — check it, then tap Redeem again.", comment: "")
    }
}

private enum ScannerCopy {
    static let scan = NSLocalizedString("Scan", comment: "")
    static let subtitle = NSLocalizedString("Put the redemption code's QR code inside the viewfinder.", comment: "")
    static let close = NSLocalizedString("Close", comment: "")
    static let cameraStarting = NSLocalizedString("Requesting camera access…", comment: "")
    static let cameraDenied = NSLocalizedString("Camera access is turned off; enable it in the system settings", comment: "")
    static let cameraRestricted = NSLocalizedString("The camera is not available on this device.", comment: "")
    static let cameraUnknown = NSLocalizedString("The camera status cannot be read right now.", comment: "")
    static let openSettings = NSLocalizedString("Open System Settings", comment: "")
    static let scanFailedFormat = NSLocalizedString("Scan failed: %@. You can paste the code instead.", comment: "")
    static let cameraUnavailable = NSLocalizedString("The capture session cannot start (the camera is busy or there is no rear camera)", comment: "")
}

// MARK: - Previews

struct PopopxVoucherRedeemSheetDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxVoucherRedeemSheet()
            .preferredColorScheme(.dark)
    }
}

struct PopopxVoucherRedeemSheetLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxVoucherRedeemSheet()
            .preferredColorScheme(.light)
    }
}
