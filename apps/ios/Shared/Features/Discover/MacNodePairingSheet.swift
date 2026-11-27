//
//  MacNodePairingSheet.swift
//  POPOPX
//
//  Two ways to point this phone at a Mac (`disvcove_notes.md`, part four.2):
//
//  - **The official node's QR / code.** `PPXNODE1-<base64url(body)>.<base64url(signature)>`, where the body is the
//    node id, its Ed25519 public key and the one-time SMP invitation. The signature is checked before anything is
//    stored (`PopopxNodePairingOffer.decode`), so a scanned string cannot install a node the user did not pair with.
//  - **The local console bridge.** What `popopx-mac-node` exposes on `127.0.0.1:18920` for Linger / OpenClaw. The
//    app never opens that socket: the pairing half of this screen is a contract to copy into a tool on the same
//    Mac, and saying so is the honest thing to do about an address the phone cannot reach.
//
//  Three rules this screen keeps:
//
//  1. **The camera is released the instant it has the code, and again when the sheet goes away.** A viewfinder that
//     keeps running behind a confirmation card leaves the camera light on for a screen that no longer needs it, so
//     `PopopxNodeCameraView.teardown()` runs both from the recognition callback and from `dismantleUIView`.
//  2. **Bonding is not attaching.** `bond(_:)` only records the node. The conversation the commands travel through
//     is chosen here, by the user, from the chats that exist on this device — the app cannot tell "the chat I opened
//     for my Mac" apart from "the chat I opened for a person", and guessing would send control signals into
//     somebody's thread.
//  3. **The handshake is sent after the attach, never before.** A command with no destination cannot be delivered,
//     and a "paired!" tick that was never confirmed by the Mac would be a lie about the state of a machine.
//

import AVFoundation
import SwiftUI
import UIKit

// MARK: - Sheet

struct MacNodePairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var data = DiscoverSubscriptionManager.shared
    @State private var mode: PopopxPairingMode = .official
    @State private var scannedCode: String?
    @State private var showsScanner = false
    @State private var showsPasteField = false
    @State private var pastedCode = ""
    @State private var showsConnectSheet = false
    @State private var showsChatPicker = false
    @State private var showsUnbondConfirmation = false
    @State private var handshakeRunning = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                    Picker(DiscoverCopy.pairingTitle, selection: $mode) {
                        Text(DiscoverCopy.officialSegment).tag(PopopxPairingMode.official)
                        Text(DiscoverCopy.bridgeSegment).tag(PopopxPairingMode.bridge)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, PopopxMetrics.gutter)
                    .padding(.top, PopopxMetrics.spaceXS)

                    switch mode {
                    case .official: officialPane
                    case .bridge: PopopxDiscoverBridgePane()
                    }

                    if let notice {
                        Text(notice)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.dangerInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, PopopxMetrics.gutter)
                    }
                }
                // This SDK's SwiftUI has no `accessibilityLiveRegion`, and a notice that appears without
                // the user touching anything is exactly what an announcement is for.
                .onChange(of: notice, initial: false) { _, message in
                    guard let message else { return }
                    AccessibilityNotification.Announcement(message).post()
                }
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .background(PopopxPalette.base)
            .navigationTitle(DiscoverCopy.pairingTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(DiscoverCopy.closeRoom) { dismiss() }
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
            }
        }
        .sheet(isPresented: $showsScanner) {
            PopopxNodeScannerSheet { code in
                showsScanner = false
                accept(code)
            }
        }
        .sheet(isPresented: $showsConnectSheet) {
            NewChatView(selection: .connect, showQRCodeScanner: false)
                .modifier(ThemedBackground(grouped: true))
        }
        .sheet(isPresented: $showsChatPicker) {
            PopopxNodeChatPicker { contactId, displayName in
                data.attach(contactId: contactId, displayName: displayName)
                showsChatPicker = false
                Task { await runHandshake() }
            }
        }
        .confirmationDialog(
            DiscoverCopy.confirmUnbond,
            isPresented: $showsUnbondConfirmation,
            titleVisibility: .visible
        ) {
            Button(DiscoverCopy.unbond, role: .destructive) {
                data.unbind()
                notice = nil
            }
            Button(DiscoverCopy.skipPicker, role: .cancel) {}
        } message: {
            Text(DiscoverCopy.unbondNotice)
        }
        .onAppear { data.loadIfNeeded() }
    }

    // MARK: Official pane

    @ViewBuilder private var officialPane: some View {
        if let offer = pendingOffer {
            PopopxNodeOfferConfirmCard(offer: offer, onBond: bond, onCancel: discardOffer)
        } else if data.binding == nil {
            PopopxSectionCard(nil) {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                    Text(DiscoverCopy.pairingIntro)
                        .font(PopopxType.secondary)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PopopxButton(DiscoverCopy.scanAction, systemImage: PopopxMacNodeVisual.cameraSymbol, role: .primary) {
                        notice = nil
                        showsScanner = true
                    }
                    PopopxButton(DiscoverCopy.pasteAction, systemImage: "doc.on.clipboard", role: .secondary) {
                        notice = nil
                        showsPasteField = true
                    }
                    if showsPasteField { pasteRow }
                }
            }
        } else {
            PopopxNodeBoundCard(
                binding: data.binding!,
                onOpenConnect: { showsConnectSheet = true },
                onPickChat: { showsChatPicker = true },
                onHandshake: { Task { await runHandshake() } },
                handshakeRunning: handshakeRunning,
                onUnbond: { showsUnbondConfirmation = true }
            )
        }
    }

    private var pasteRow: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            PopopxTextField(
                DiscoverCopy.pairingCodeLabel,
                prompt: "PPXNODE1-…",
                text: $pastedCode,
                systemImage: "textformat"
            )
            .environment(\.layoutDirection, .leftToRight)
            PopopxButton(DiscoverCopy.pasteAction, systemImage: "checkmark", role: .primary, fullWidth: false) {
                accept(pastedCode)
            }
        }
    }

    // MARK: Intents

    /// A code that decodes becomes an offer to confirm; one that does not is reported and
    /// dropped. Nothing is ever stored from a string that failed the signature check, and the
    /// reason shown is the node's own failure, not a generic "invalid".
    private func accept(_ candidate: String) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Before the pairing-offer decode: an eco service/SSO link is another protocol's payload, and letting it fall through would
        // report "pairing failed" over a link this sheet was never meant to read.
        if PopopxEcoDeepLinkHandler.handle(text: trimmed) {
            pastedCode = ""
            showsPasteField = false
            return
        }
        guard let offer = PopopxNodePairingOffer.decode(trimmed) else {
            pastedCode = ""
            showsPasteField = false
            notice = DiscoverCopy.pairingFailed
            return
        }
        pastedCode = ""
        showsPasteField = false
        scannedCode = offer.code
    }

    private func discardOffer() { scannedCode = nil }

    private var pendingOffer: PopopxNodePairingOffer? {
        guard let scannedCode else { return nil }
        return PopopxNodePairingOffer.decode(scannedCode)
    }

    private func bond() {
        guard let pendingOffer else { return }
        data.bond(pendingOffer)
        scannedCode = nil
        notice = String(format: DiscoverCopy.pairingSucceededFormat, pendingOffer.nodeId)
        // Bonding without a conversation is the half-done state, so the picker opens straight
        // away rather than waiting for the user to find the row.
        showsChatPicker = true
    }

    /// The one confirmation the whole flow can produce: the Mac answering a command this device
    /// sent it. `sendHandshake` only marks the binding confirmed when the SMP send succeeded,
    /// so a failure here says "not confirmed" instead of leaving a green tick behind.
    private func runHandshake() async {
        handshakeRunning = true
        let confirmed = await data.sendHandshake()
        handshakeRunning = false
        notice = confirmed ? nil : DiscoverCopy.sendFailed
    }
}

// MARK: - Modes

enum PopopxPairingMode: String, CaseIterable, Identifiable, Hashable {
    case official
    case bridge

    var id: String { rawValue }
}

// MARK: - Offer confirmation

struct PopopxNodeOfferConfirmCard: View {
    let offer: PopopxNodePairingOffer
    let onBond: () -> Void
    let onCancel: () -> Void

    var body: some View {
        PopopxSectionCard(DiscoverCopy.pairingConfirmTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                PopopxDiscoverDetailFactRow(label: DiscoverCopy.pairingNodeLabel, value: offer.nodeId, valueIsLTR: true)
                PopopxDiscoverDetailFactRow(
                    label: DiscoverCopy.pairingKeyLabel,
                    value: String(offer.publicKeyBase64URL.prefix(12)) + "…",
                    valueIsLTR: true
                )
                PopopxDiscoverDetailFactRow(
                    label: DiscoverCopy.pairingExpiresLabel,
                    value: DiscoverCopy.pairingExpiresIn(
                        max(0, Int((offer.expiresAtMs - nowMs) / 1_000))
                    )
                )
                Text(DiscoverCopy.pairingConfirmHint)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .fixedSize(horizontal: false, vertical: true)
                PopopxButton(DiscoverCopy.pairingBondAction, systemImage: "link", role: .primary) {
                    onBond()
                }
                PopopxButton(DiscoverCopy.skipPicker, role: .ghost) {
                    onCancel()
                }
            }
        }
    }

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}

// MARK: - Bound state

struct PopopxNodeBoundCard: View {
    let binding: PopopxMacNodeBinding
    let onOpenConnect: () -> Void
    let onPickChat: () -> Void
    let onHandshake: () -> Void
    let handshakeRunning: Bool
    let onUnbond: () -> Void

    var body: some View {
        PopopxSectionCard(DiscoverCopy.pairingBoundTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                PopopxDiscoverDetailFactRow(label: DiscoverCopy.pairingNodeLabel, value: binding.nodeId, valueIsLTR: true)
                PopopxDiscoverDetailFactRow(
                    label: DiscoverCopy.pairingChatLabel,
                    value: binding.contactDisplayName ?? DiscoverCopy.roomNeedsChat
                )
                PopopxDiscoverDetailFactRow(
                    label: DiscoverCopy.pairingProofLabel,
                    value: binding.handshakeConfirmed ? DiscoverCopy.pairingProofConfirmed : DiscoverCopy.pairingProofWaiting
                )
                PopopxDiscoverDetailNote(
                    text: DiscoverCopy.pairingFingerprintNote(binding.offerFingerprint),
                    systemImage: "fingerprint"
                )

                if binding.contactId == nil {
                    // Two ways to get a conversation: open a fresh one with the node's own
                    // invitation, or point the binding at a chat that already exists.
                    PopopxButton(DiscoverCopy.pairingOpenChatAction, systemImage: "link.badge.plus", role: .primary) {
                        onOpenConnect()
                    }
                    PopopxButton(DiscoverCopy.pairingPickChatAction, systemImage: "list.bullet", role: .secondary) {
                        onPickChat()
                    }
                } else {
                    PopopxButton(
                        DiscoverCopy.pairingRetryAction,
                        systemImage: "arrow.2.circlepath",
                        role: .secondary,
                        isLoading: handshakeRunning
                    ) {
                        onHandshake()
                    }
                    PopopxButton(DiscoverCopy.pairingPickChatAction, systemImage: "list.bullet", role: .ghost) {
                        onPickChat()
                    }
                }

                PopopxButton(DiscoverCopy.unbond, systemImage: "trash", role: .destructive, fullWidth: false) {
                    onUnbond()
                }
                Text(DiscoverCopy.unbondNotice)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Chat picker

/// The list the user chooses the node's conversation from.
///
/// Direct chats only, current identity only, and no filtering by name: the Mac's chat is
/// whatever the user happened to call it, and a search box here would suggest that the app
/// knows which one it is.
struct PopopxNodeChatPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var chatModel = ChatModel.shared

    let onPick: (Int64, String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if contacts.isEmpty {
                    PopopxDiscoverEmptyState(searching: false)
                        .padding(.top, PopopxMetrics.space2XL)
                } else {
                    List {
                        ForEach(contacts) { contact in
                            Button {
                                onPick(contact.contactId, contact.displayName)
                            } label: {
                                HStack(spacing: PopopxMetrics.spaceS) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.system(size: 14))
                                        .foregroundStyle(PopopxPalette.labelSecondary)
                                        .frame(width: 24)
                                    Text(contact.displayName)
                                        .font(PopopxType.body)
                                        .foregroundStyle(PopopxPalette.label)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if contact.contactId == bindingContactId {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundStyle(PopopxPalette.brand)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(DiscoverCopy.chooseChatTitle)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(DiscoverCopy.chooseChatTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(DiscoverCopy.skipPicker) { dismiss() }
                        .font(PopopxType.meta)
                }
            }
        }
    }

    private var bindingContactId: Int64? { DiscoverSubscriptionManager.shared.binding?.contactId }

    private struct PickableContact: Identifiable, Hashable {
        let contactId: Int64
        let displayName: String

        var id: Int64 { contactId }
    }

    /// `ChatModel.chats` holds every conversation type; only `.direct` rows have a contact id
    /// a command can be addressed to. Deleted chats are skipped because a message to one of
    /// them does not go anywhere, which is the whole point of attaching.
    private var contacts: [PickableContact] {
        chatModel.chats.compactMap { chat in
            guard case let .direct(contact) = chat.chatInfo, contact.active, !contact.chatDeleted else { return nil }
            return PickableContact(contactId: contact.contactId, displayName: chat.chatInfo.displayName)
        }
    }
}

// MARK: - Scanner

/// The camera sheet. It owns no state beyond "a code was seen", and the code travels straight
/// to the caller, which decides whether it is a node at all.
struct PopopxNodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var denied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    let onCode: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                if denied {
                    VStack(spacing: PopopxMetrics.spaceS) {
                        Image(systemName: "camera")
                            .font(.system(size: 28))
                            .foregroundStyle(PopopxPalette.labelHint)
                        Text(DiscoverCopy.cameraDenied)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, PopopxMetrics.gutter)
                    }
                } else {
                    PopopxNodeCameraPreview { code in
                        // Released at the instant of recognition: the preview's `teardown` stops
                        // the session and drops its layers, so the indicator light goes out while
                        // this sheet is still on screen and the caller swaps in the confirmation card.
                        onCode(code)
                    }
                    .ignoresSafeArea()

                    VStack {
                        PopopxNodeScannerFrame()
                        Spacer()
                    }
                }
            }
            .background(Color.black)
            .navigationTitle(DiscoverCopy.scanAction)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(DiscoverCopy.skipPicker) { dismiss() }
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.onBrand)
                }
            }
            .onAppear { requestAccess() }
        }
    }

    private func requestAccess() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                if !granted { denied = true }
            }
        }
    }
}

struct PopopxNodeScannerFrame: View {
    var body: some View {
        RoundedRectangle(cornerRadius: PopopxMetrics.radiusSheet)
            .strokeBorder(PopopxPalette.onBrand.opacity(0.85), lineWidth: 2)
            .frame(width: 220, height: 220)
            .padding(.top, PopopxMetrics.space2XL)
            .accessibilityHidden(true)
    }
}

// MARK: - Camera plumbing

struct PopopxNodeCameraPreview: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> PopopxNodeCameraCoordinator {
        PopopxNodeCameraCoordinator(onCode: onCode)
    }

    func makeUIView(context: Context) -> PopopxNodeCameraView {
        let view = PopopxNodeCameraView()
        context.coordinator.stopCapture = { view.teardown() }
        view.start(delegate: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: PopopxNodeCameraView, context: Context) {}

    /// SwiftUI's second release point, after the sheet's own disappearance: whatever route took
    /// the view away, the session stops here too.
    static func dismantleUIView(_ uiView: PopopxNodeCameraView, coordinator: PopopxNodeCameraCoordinator) {
        uiView.teardown()
    }
}

/// The delegate lives outside the view so that the capture callback has one obvious hop to the
/// main actor: the queue that AVFoundation calls back on owns nothing the UI can touch.
final class PopopxNodeCameraCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let onCode: (String) -> Void
    /// Wired by `makeUIView` to the view's own `teardown`, so the capture stops on the queue
    /// AVFoundation is already calling back on.
    var stopCapture: (() -> Void)?

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              code.type == .qr,
              let value = code.stringValue,
              !value.isEmpty else { return }
        // Recognition is the moment to stop: one code is all pairing needs, and the camera
        // indicator must not stay lit while the confirmation card replaces this sheet.
        stopCapture?()
        let receive = onCode
        Task { @MainActor in
            receive(value)
        }
    }
}

final class PopopxNodeCameraView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var session: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "popopx.discover.node.camera")
    private var running = false

    var previewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

    /// Back camera, QR only, session wired on a background queue (`AVCaptureSession.startRunning`
    /// blocks and must not run on the main thread), preview attached on the main thread.
    func start(delegate: AVCaptureMetadataOutputObjectsDelegate) {
        guard !running else { return }
        let session = AVCaptureSession()
        self.session = session
        captureQueue.async { [weak self] in
            guard let self else { return }
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(delegate, queue: self.captureQueue)
                if output.availableMetadataObjectTypes.contains(.qr) {
                    output.metadataObjectTypes = [.qr]
                }
            }
            guard !self.running else { return }
            self.running = true
            session.startRunning()
            DispatchQueue.main.async {
                self.previewLayer?.session = session
                self.previewLayer?.videoGravity = .resizeAspectFill
            }
        }
    }

    /// Detach, stop, drop. In that order: `stopRunning` blocks its queue, and leaving the
    /// preview layer pointed at a dead session keeps the last frame on screen as though the
    /// camera were still live.
    func teardown() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewLayer?.session = nil
        }
        captureQueue.async { [weak self] in
            guard let self, let session = self.session else { return }
            self.running = false
            session.stopRunning()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            self.session = nil
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { teardown() }
    }
}

// MARK: - Bridge pane

/// The Linger / OpenClaw contract, as `popopx-mac-node` publishes it.
///
/// It is readable and copyable, and nothing more. The app does not open a socket to
/// `127.0.0.1:18920` — on a phone that address is the phone, and pretending the field were a
/// connection test would report "unreachable" about the device in the user's hand.
struct PopopxDiscoverBridgePane: View {
    @State private var copied = false

    var body: some View {
        PopopxSectionCard(DiscoverCopy.bridgeTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Text(DiscoverCopy.bridgeIntro)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                PopopxDiscoverDetailFactRow(label: DiscoverCopy.bridgeAddressLabel, value: Self.address, valueIsLTR: true)
                PopopxDiscoverDetailFactRow(label: DiscoverCopy.bridgeTokenLabel, value: Self.tokenContract, valueIsLTR: true)

                PopopxDiscoverDetailNote(text: DiscoverCopy.bridgeTokenHint, systemImage: "key")
                PopopxDiscoverDetailNote(text: DiscoverCopy.bridgeSecretHint, systemImage: "number")
                PopopxDiscoverDetailNote(text: DiscoverCopy.bridgeLocalOnlyNote, systemImage: "wifi.slash")

                PopopxButton(copied ? DiscoverCopy.copiedNotice : DiscoverCopy.copyAddress, systemImage: "doc.on.doc", role: .secondary, fullWidth: false) {
                    UIPasteboard.general.string = Self.address
                    copied = true
                    PopopxHaptics.impact(.light)
                }
            }
        }
    }

    static var address: String {
        "http://\(PopopxNodeWire.consoleHost):\(PopopxNodeWire.consolePort)/"
    }

    static var tokenContract: String {
        "\(PopopxNodeWire.consoleTokenHeader): $PPX_BRIDGE_SECRET · ?\(PopopxNodeWire.consoleTokenQueryItem)=$PPX_BRIDGE_SECRET"
    }
}

// MARK: - Copy

extension DiscoverCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "discover node pairing")
    }

    static let pairingCodeLabel = key("Pairing code")
    static let pairingConfirmTitle = key("Bond this Mac")
    static let pairingConfirmHint = key(
        "The code carries the node's own address and the public key its replies must be signed with. It expires; bonding does not use the address up."
    )
    static let pairingBondAction = key("Bond")
    static let pairingNodeLabel = key("Node")
    static let pairingKeyLabel = key("Key")
    static let pairingExpiresLabel = key("Code expires")
    static let pairingChatLabel = key("Conversation")
    static let pairingProofLabel = key("Proof")
    static let pairingProofConfirmed = key("Confirmed by the Mac")
    static let pairingProofWaiting = key("Waiting for the Mac to answer")
    static let pairingBoundTitle = key("Bonded Mac")
    static let pairingOpenChatAction = key("Open the conversation with it")
    static let pairingPickChatAction = key("Choose the conversation")
    static let pairingRetryAction = key("Ask the Mac to confirm")

    static func pairingFingerprintNote(_ fingerprint: String) -> String {
        String(format: key("This device keeps only the fingerprint %@ of the code it was shown."), fingerprint)
    }

    static func pairingExpiresIn(_ seconds: Int) -> String {
        String(format: key("in %lld s"), Int64(max(0, seconds)))
    }

    static let bridgeLocalOnlyNote = key(
        "This address is on the Mac itself. The app shows it so a tool running there can be configured; it does not connect to it."
    )
}
