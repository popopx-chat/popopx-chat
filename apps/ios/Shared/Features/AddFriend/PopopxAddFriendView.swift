//
//  PopopxAddFriendView.swift
//  POPOPX (iOS)
//
//  Phase 3 item 2. — a WeChat-style 'Add friends' page. At the top a link input field that classifies in real time, below it two shortcut
//  buttons (paste to add / face-to-face add), my encrypted card bar, and below that three rows: Cabin plaza, Scan, Share invite link.
//
//  Routing has exactly one rule: `popopx:/` (including the hand-typed `popopx://` and the share form `https://popopx.chat/`) goes
//  through the offline gate of `PopopxMeshRuntime.shared.bridge` — module 2's `normalizedInviteLink` is the only prefix
//  gate, the command-line safe-character check lives inside it, so a pasted string can never enter `/_connect` without being greeted;
//  `simplex:/` and other online/legacy links are handed back to the app's existing `planAndConnect`. The link itself is never fabricated: the card QR code
//  and the share both use a real link freshly minted by `PopopxInviteLink.mintOneTime`; getting nil reports failure.
//
//  Red lines kept: do not touch project.pbxproj (this file is dragged into the target by hand); colours/spacing/fonts/materials/springs take only
//  tokens from PopopxTheme; controls use only the atom library already in Shared/Components, never a second button or text field;
//  the face-to-face entry gives a real degraded page below iOS 17 instead of a 'try again later'.
//

import SwiftUI
import UIKit
import AVFoundation
import CodeScanner
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - Link classification

/// The input field, the clipboard and Scan all share one classification result — the routing in the three places therefore cannot tell a different story.
private enum PopopxAddFriendLink: Hashable {
    /// The form the offline gate accepts. `normalizedInviteLink` also normalises `popopx://` and the share form into `popopx:/`.
    case offline
    /// Old schemes the core recognises, handed back to `planAndConnect`'s online path.
    case online
    /// Everything else: do not add.
    case unknown

    /// Prefixes of online/legacy links. This is a protocol-string check, not UI copy — the UI never shows these two words.
    private static let onlinePrefixes = [
        "simplex:/",
        "simplex://",
        "https://simplex.chat/",
        "http://simplex.chat/",
    ]

    static func classify(_ raw: String) -> PopopxAddFriendLink {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return .unknown }
        // The published share form is online by definition: its address is sealed, so this function
        // cannot see a mesh invite inside it even when one is there. `planAndConnect` opens it.
        // It has to be tested before the offline gate: `normalizedInviteLink` accepts every
        // `https://popopx.chat/` path, so a sealed `/i/v1/` link would otherwise be rewritten into a
        // `popopx:/` link and sent into the offline path, which then rejects it as an invalid link.
        if PopopxOpaqueInviteCodec.looksLikeOpaqueLink(link) { return .online }
        if PopopxOfflineBridge.normalizedInviteLink(link) != nil { return .offline }
        if onlinePrefixes.contains(where: { link.hasPrefix($0) }) { return .online }
        return .unknown
    }

    var canAdd: Bool { self != .unknown }

    /// The link body with leading and trailing whitespace removed; the same single value is sent into the gate and to the online path.
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Page

struct PopopxAddFriendView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    /// The true value of the kill switch has to be spoken on the Cabin row, so the runtime is observed instead of read once when pressing.
    @ObservedObject private var meshRuntime: PopopxMeshRuntime

    @State private var toast = PopopxToastModel()
    @State private var linkText = ""
    /// nil = nothing on the clipboard that can be classified as a link; non-nil is already a whitespace-trimmed normalised string.
    @State private var clipboardLink: String?
    @State private var showsScanner = false
    @State private var showsFaceToFace = false
    @State private var showsIdentityPicker = false
    @State private var showsQRCard = false
    @State private var mintingInvite = false
    @State private var qrInvite: PopopxMintedInvite?
    @State private var path: [PopopxAddFriendRoute] = []

    @MainActor init() {
        _meshRuntime = ObservedObject(wrappedValue: PopopxMeshRuntime.shared)
    }

    /// This page's half of the plaza author menu: its own toast and its own stack. Nothing else to update —
    /// the page shows no mesh table, the plaza re-reads the mirror, and the receipt for an invitation is
    /// the toast the core already shows, which is also what the "Add friend" flows above show for a link.
    @MainActor private var authorHost: PopopxCabinAuthor.Host {
        PopopxCabinAuthor.Host(
            runtime: meshRuntime,
            toast: toast,
            pushChat: { path.append(.privateChat(peerMeshPublicKeyHex: $0)) },
            refresh: {},
            beginOpening: {},
            endOpening: {}
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    PopopxAddFriendHeader()
                    PopopxLinkSearchBlock(text: $linkText, submit: { raw in await submit(raw) })
                    PopopxQuickActionsBlock(
                        clipboardLink: $clipboardLink,
                        onPaste: { await pasteAndConnect() },
                        onFaceToFace: { showsFaceToFace = true }
                    )
                    PopopxNameCardBar(
                        identityName: identityName,
                        minting: mintingInvite,
                        onSwitchIdentity: { showsIdentityPicker = true },
                        onShowQRCard: { Task { @MainActor in await presentQRCard() } }
                    )
                    PopopxFeatureRows(
                        fuseOn: meshRuntime.isFuseOn,
                        onPlaza: { path.append(.meshPlaza) },
                        onScan: { showsScanner = true },
                        onShare: { Task { @MainActor in await shareMyLink() } }
                    )
                }
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PopopxPalette.base)
            .navigationDestination(for: PopopxAddFriendRoute.self) { route in
                switch route {
                case .meshPlaza:
                    // The mounting copies that line in `PopopxCabinRoute.plaza`: the same single plaza model
                    // from the runtime, the same author menu, the same background. All three objects come
                    // from the runtime, and the page itself, when the fuse
                    // is closed, renders the 'closed' state, so this row is always tappable.
                    MeshPlazaView(
                        model: meshRuntime.plazaModel,
                        keepsRunningWhenHidden: true,
                        authorActions: PopopxCabinAuthor.plazaActions(host: authorHost)
                    )
                    .navigationTitle(Copy.plazaNavigationTitle)
                    .modifier(ThemedBackground(grouped: true))

                case let .privateChat(peerMeshPublicKeyHex):
                    // Same mount helper the Cabin drawer and the Cabin home tab push, so the page reached
                    // from "Add friend" cannot be a fourth variant of it.
                    PopopxCabinAuthor.privateChatView(
                        peerMeshPublicKeyHex: peerMeshPublicKeyHex,
                        runtime: meshRuntime
                    )
                }
            }
            .toolbar {
                if isPresented {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Copy.close) { dismiss() }
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.brand)
                            .frame(minHeight: PopopxMetrics.minHitTarget)
                            .buttonStyle(PopopxPressButtonStyle())
                    }
                }
            }
        }
        .background(PopopxPalette.base)
        .environmentObject(AppTheme.shared)
        .popopxToast(toast)
        .sheet(isPresented: $showsScanner) {
            PopopxScannerSheet(onScan: { scanned in
                linkText = scanned
                Task { @MainActor in await submit(scanned) }
            })
        }
        .sheet(isPresented: $showsFaceToFace) {
            if #available(iOS 17.0, *) {
                PopopxProximityAddContactView(nickname: nil)
            } else {
                PopopxFaceToFaceUnsupportedSheet()
            }
        }
        .sheet(isPresented: $showsIdentityPicker) {
            PopopxIdentityPickerSheet(showsPicker: $showsIdentityPicker)
        }
        .sheet(isPresented: $showsQRCard, onDismiss: { qrInvite = nil }) {
            if let invite = qrInvite {
                PopopxQRCardSheet(uri: invite.uri, identityName: identityName, originalURI: invite.original)
            }
        }
        .onAppear { refreshClipboard() }
        // The user most likely copies in another app and then switches back, so only the clipboard at the moment of returning to the foreground counts.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshClipboard()
        }
    }

    /// The identity name shared by the card bar and the QR card: an empty nickname is not guessed, it falls straight back to 'Unnamed identity'.
    private var identityName: String {
        let name = PopopxAddFriendLink.normalized(chatModel.currentUser?.displayName ?? "")
        return name.isEmpty ? Copy.unnamedIdentity : name
    }

    // MARK: Routing

    /// The single add-friend entry: the input field, paste and Scan paths all converge here.
    @MainActor private func submit(_ raw: String) async {
        let link = PopopxAddFriendLink.normalized(raw)
        // Asked before classification, not after: `classify` puts **every** `popopx://` string in the `.offline` bucket, because
        // `PopopxOfflineBridge.normalizedInviteLink` deliberately accepts the hand-typed `popopx://` form. An eco service/SSO link is
        // not an offline invite, and reaching `acceptOffline` with it would start a mesh pairing.
        if PopopxEcoDeepLinkHandler.handle(text: link) {
            linkText = ""
            return
        }
        switch PopopxAddFriendLink.classify(link) {
        case .offline:
            await acceptOffline(link)
        case .online:
            planAndConnect(link, theme: AppTheme.shared, dismiss: false)
            toast.show(Copy.onlineHandoffToast, kind: .encrypted)
        case .unknown:
            PopopxHaptics.notice(.error)
            toast.show(Copy.unrecognizedToast, kind: .danger)
        }
    }

    @MainActor private func acceptOffline(_ link: String) async {
        do {
            let acceptance = try await meshRuntime.bridge.acceptOfflineInviteLink(link)
            linkText = ""
            PopopxHaptics.notice(.success)
            switch acceptance.kind {
            case .confirmation:
                // What we consumed is the other side's invite: this side now waits for them to accept.
                toast.show(Copy.offlineConfirmationToast, kind: .mesh)
            case .invitation:
                // We take an invite to the other side's contact address: the connection is confirmed on their end.
                toast.show(Copy.offlineInvitationToast, kind: .mesh)
            }
        } catch let bridgeError {
            // `acceptOfflineInviteLink` is a typed throw (`throws(PopopxOfflineBridgeError)`),
            // so what we get here is that error itself, with no further downcast.
            if case .inviteLinkRejected = bridgeError {
                // What the gate rejects is never a link we minted, so it goes back to the online path instead of erroring in place.
                planAndConnect(link, theme: AppTheme.shared, dismiss: false)
                toast.show(Copy.onlineHandoffToast, kind: .encrypted)
            } else {
                logger.error("popopx add friend: offline accept failed: \(String(describing: bridgeError))")
                PopopxHaptics.notice(.error)
                toast.show(Copy.offlineFailedToast, kind: .danger)
            }
        }
    }

    @MainActor private func pasteAndConnect() async {
        // Read once more at the moment of the press: the clipboard may have changed after the button lit up.
        refreshClipboard()
        guard let link = clipboardLink else {
            PopopxHaptics.notice(.warning)
            toast.show(Copy.clipboardEmptyToast, kind: .danger)
            return
        }
        linkText = link
        await submit(link)
    }

    @MainActor private func refreshClipboard() {
        guard UIPasteboard.general.hasStrings, let raw = UIPasteboard.general.string else {
            clipboardLink = nil
            return
        }
        let link = PopopxAddFriendLink.normalized(raw)
        clipboardLink = PopopxAddFriendLink.classify(link).canAdd ? link : nil
    }

    // MARK: Minting

    /// Mint on use: a one-time link reused is meaningless, so the card and the share each mint once; not getting one is a failure.
    @MainActor private func mintInvite() async -> PopopxMintedInvite? {
        guard !mintingInvite else { return nil }
        mintingInvite = true
        let invite = await PopopxInviteLink.mintOneTime(incognito: false)
        mintingInvite = false
        if invite == nil {
            PopopxHaptics.notice(.error)
            toast.show(Copy.mintFailedToast, kind: .danger)
        }
        return invite
    }

    @MainActor private func presentQRCard() async {
        guard let invite = await mintInvite() else { return }
        qrInvite = invite
        showsQRCard = true
    }

    @MainActor private func shareMyLink() async {
        guard let invite = await mintInvite() else { return }
        showShareSheet(items: [invite.uri])
    }
}

// MARK: - Push routes

private enum PopopxAddFriendRoute: Hashable {
    case meshPlaza
    /// Where a plaza author action lands: the package's 1:1 offline private chat for that peer's key.
    case privateChat(peerMeshPublicKeyHex: String)
}

// MARK: - Header

private struct PopopxAddFriendHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(Copy.pageTitle)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.label)
            Text(Copy.pageExplainer)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Search block

private struct PopopxLinkSearchBlock: View {
    @Binding var text: String
    let submit: (String) async -> Void

    private var link: PopopxAddFriendLink { PopopxAddFriendLink.classify(text) }

    var body: some View {
        PopopxSectionCard(Copy.searchTitle, footnote: Copy.searchFootnote) {
            PopopxTextField(
                Copy.linkHint,
                prompt: Copy.linkHint,
                text: $text,
                systemImage: "link",
                keyboard: .URL,
                onSubmit: { raw in Task { @MainActor in await submit(raw) } }
            )
            HStack(spacing: PopopxMetrics.spaceXS) {
                verdict
                    .frame(maxWidth: .infinity, alignment: .leading)
                PopopxButton(Copy.add, systemImage: "arrow.right.circle.fill", role: .primary, fullWidth: false) {
                    await submit(text)
                }
                .disabled(!link.canAdd)
            }
            .font(PopopxType.meta)
            .padding(.top, PopopxMetrics.spaceS)
        }
    }

    /// The classification result doubles as the 'can this be added' explanation, so the three levels each have their own colour, with no grey fallback.
    @ViewBuilder private var verdict: some View {
        switch link {
        case .offline:
            Label(Copy.addableVerdict, systemImage: "checkmark.seal.fill")
                .foregroundStyle(PopopxPalette.brand)
        case .online:
            Label(Copy.onlineVerdict, systemImage: "cloud.fill")
                .foregroundStyle(PopopxPalette.labelSecondary)
        case .unknown:
            Text(Copy.linkHint)
                .foregroundStyle(PopopxPalette.labelHint)
        }
    }
}

// MARK: - Quick actions

private struct PopopxQuickActionsBlock: View {
    @Binding var clipboardLink: String?
    let onPaste: () async -> Void
    let onFaceToFace: () -> Void

    var body: some View {
        PopopxSectionCard(Copy.quickActionsTitle) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    PopopxButton(Copy.pasteAction, systemImage: "doc.on.clipboard", role: .secondary) {
                        await onPaste()
                    }
                    .disabled(clipboardLink == nil)
                    HStack(spacing: PopopxMetrics.space2XS) {
                        if clipboardLink != nil {
                            PopopxBreathingDot()
                        }
                        Text(clipboardLink == nil ? Copy.pasteNoteEmpty : Copy.pasteNoteReady)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .padding(.leading, PopopxMetrics.space2XS)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    PopopxButton(Copy.faceToFaceAction, systemImage: "dot.radiowaves.left.and.right", role: .primary) {
                        onFaceToFace()
                    }
                    Text(Copy.faceToFaceSubtitle)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, PopopxMetrics.space2XS)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Teal breathing dot: it lights only when the clipboard really holds an addable link. Under Reduce Motion a still dot is drawn —
/// a dot that never moves is still a dot; a breath that never stops is the problem.
private struct PopopxBreathingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(PopopxPalette.meshInk)
            .frame(width: PopopxMetrics.spaceXS, height: PopopxMetrics.spaceXS)
            .opacity(reduceMotion ? 1 : (expanded ? 0.4 : 1))
            .scaleEffect(reduceMotion ? 1 : (expanded ? 0.65 : 1.1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    expanded = true
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Name card bar

private struct PopopxNameCardBar: View {
    let identityName: String
    let minting: Bool
    let onSwitchIdentity: () -> Void
    let onShowQRCard: () -> Void

    var body: some View {
        PopopxSectionCard(Copy.nameCardTitle) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                circleButton(
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .neutral,
                    label: Copy.switchIdentityLabel,
                    busy: false,
                    action: onSwitchIdentity
                )
                VStack(spacing: PopopxMetrics.space2XS) {
                    Text(identityName)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(1)
                    Text(Copy.nameCardNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
                .frame(maxWidth: .infinity)
                circleButton(
                    systemImage: "qrcode",
                    tint: .brand,
                    label: Copy.qrCardLabel,
                    busy: minting,
                    action: onShowQRCard
                )
            }
            .frame(minHeight: PopopxMetrics.minHitTarget)
        }
    }

    /// The two round buttons are mirror-symmetric, so the identity name in the middle is truly centred rather than pushed to one side.
    private func circleButton(
        systemImage: String,
        tint: PopopxIconTint,
        label: String,
        busy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(PopopxType.microTag)
                        .imageScale(.large)
                }
            }
            .foregroundStyle(tint.ink)
            .tint(tint.ink)
            .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
            .background(tint.fill, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(busy)
        .accessibilityLabel(label)
    }
}

// MARK: - Feature rows

private struct PopopxFeatureRows: View {
    let fuseOn: Bool
    let onPlaza: () -> Void
    let onScan: () -> Void
    let onShare: () -> Void

    var body: some View {
        PopopxSectionCard(Copy.moreTitle) {
            // Turning the fuse off only changes what this row says, not whether it opens: the plaza page renders the closed state itself.
            PopopxPickerRow(
                Copy.plazaRow,
                value: fuseOn ? nil : Copy.fuseOffValue,
                systemImage: "antenna.radiowaves.left.and.right",
                tint: .mesh,
                action: onPlaza
            )
            rowSeparator
            PopopxPickerRow(Copy.scanRow, systemImage: "qrcode.viewfinder", tint: .neutral, action: onScan)
            rowSeparator
            PopopxPickerRow(Copy.shareRow, systemImage: "square.and.arrow.up", tint: .brand, action: onShare)
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - Scanner sheet

private struct PopopxScannerSheet: View {
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cameraStatus: AVAuthorizationStatus?
    /// Changing the id once rebuilds `CodeScannerView`: failures where the session has already ended (badInput etc.) can only be retried this way.
    @State private var scanAttempt = 0
    @State private var failureNote: String?

    var body: some View {
        PopopxSheetContainer(Copy.scanRow, subtitle: Copy.scannerSubtitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                content
                if let failureNote {
                    Text(failureNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            PopopxButton(Copy.close, role: .secondary) { dismiss() }
                .padding(PopopxMetrics.spaceM)
        }
        .task { await ensureCameraAccess() }
    }

    @ViewBuilder private var content: some View {
        switch cameraStatus {
        case .authorized:
            CodeScannerView(codeTypes: [.qr], scanMode: .oncePerCode, completion: handleScan)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: PopopxMetrics.radiusCard))
                .id(scanAttempt)
        case .notDetermined:
            // `.task` has already presented the system permission sheet, so this cell is the few frames behind that sheet.
            placeholder(systemImage: "camera", text: Copy.cameraStarting)
        case .denied:
            placeholder(
                systemImage: "video.slash",
                text: Copy.cameraDenied,
                actionTitle: Copy.openSettings,
                action: { UIApplication.shared.open(appSettingsURL) }
            )
        case .restricted:
            placeholder(systemImage: "nosign", text: Copy.cameraRestricted)
        default:
            // A status not read yet (nil) and any status the system adds in the future both land here, instead of leaving an empty cell.
            placeholder(systemImage: "questionmark", text: Copy.cameraUnknown)
        }
    }

    private func placeholder(
        systemImage: String,
        text: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        PopopxScannerPlaceholder(
            systemImage: systemImage,
            text: text,
            actionTitle: actionTitle,
            action: action
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

    private func handleScan(_ result: Result<ScanResult, ScanError>) {
        switch result {
        case let .success(scan):
            failureNote = nil
            onScan(scan.string)
            dismiss()
        case let .failure(error):
            failureNote = String(format: Copy.scanFailedFormat, error.localizedDescription)
            switch error {
            case .permissionDenied:
                // The user denied permission inside the camera session: handed back to the switch above, which says 'go to system settings'; retrying is pointless.
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            default:
                // badInput / badOutput / initError all mean the session itself never started; rebuilding it once is more useful than an error.
                scanAttempt += 1
            }
        }
    }
}

private struct PopopxScannerPlaceholder: View {
    let systemImage: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: systemImage)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Text(text)
                .font(PopopxType.meta)
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
}

// MARK: - Face to face, below iOS 17

/// The face-to-face add's two engines (`PopopxProximityAddContactView`) need iOS 17's NearbyInteraction. The degraded page
/// offers another road that works, not a 'not supported'.
private struct PopopxFaceToFaceUnsupportedSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PopopxSheetContainer(Copy.faceToFaceAction) {
            Label(Copy.faceToFaceUnsupported, systemImage: "exclamationmark.circle")
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            // Dismiss this one and the Scan row sits right below on the page; no need to grab a presentation slot on the user's behalf.
            PopopxButton(Copy.gotIt, role: .secondary) { dismiss() }
                .padding(PopopxMetrics.spaceM)
        }
    }
}

// MARK: - Identity picker

/// Reuses the existing `UserPicker`: `changeActiveUserAsync_`, which switches identity, lives only in that one place; no second copy is rewritten here.
private struct PopopxIdentityPickerSheet: View {
    @Binding var showsPicker: Bool

    @State private var nestedSheet: UserPickerSheet?

    var body: some View {
        UserPicker(userPickerShown: $showsPicker, activeSheet: $nestedSheet)
            .appSheet(item: $nestedSheet) { sheet in
                UserPickerSheetView(sheet: sheet)
            }
    }
}

// MARK: - Copy

/// Every Chinese sentence on the page appears exactly once, here.
private enum Copy {
    static let pageTitle = NSLocalizedString("Add Friend", comment: "")
    static let pageExplainer = NSLocalizedString("An invitation link is a one-time encrypted address: whoever opens it can start a connection with you. Links starting with popopx: reach the other side over the Bluetooth mesh relay when there is no internet.", comment: "")
    static let close = NSLocalizedString("Close", comment: "")
    static let gotIt = NSLocalizedString("Got it", comment: "")

    static let searchTitle = NSLocalizedString("Invitation link", comment: "")
    static let linkHint = NSLocalizedString("Paste or type a POPOPX invitation link", comment: "")
    static let searchFootnote = NSLocalizedString("Addable = this device's offline gate opens the connection directly; online invitation = handed to the encrypted server.", comment: "")
    static let add = NSLocalizedString("Add", comment: "")
    static let addableVerdict = NSLocalizedString("Addable", comment: "")
    static let onlineVerdict = NSLocalizedString("Online invitation", comment: "")

    static let quickActionsTitle = NSLocalizedString("Quick ways to add", comment: "")
    static let pasteAction = NSLocalizedString("Paste to add", comment: "")
    static let pasteNoteReady = NSLocalizedString("The clipboard holds an addable link", comment: "")
    static let pasteNoteEmpty = NSLocalizedString("No invitation link in the clipboard yet", comment: "")
    static let faceToFaceAction = NSLocalizedString("Add face to face", comment: "")
    static let faceToFaceSubtitle = NSLocalizedString("Move close and it senses automatically, or tap the top to connect", comment: "")
    static let faceToFaceUnsupported = NSLocalizedString("This system version does not support face-to-face adding; use Scan QR code instead", comment: "")

    static let nameCardTitle = NSLocalizedString("My encrypted card", comment: "")
    static let nameCardNote = NSLocalizedString("Sent from the current anonymous identity", comment: "")
    static let unnamedIdentity = NSLocalizedString("Unnamed identity", comment: "")
    static let switchIdentityLabel = NSLocalizedString("Switch anonymous identity", comment: "")
    static let qrCardLabel = NSLocalizedString("Show my QR code card", comment: "")

    static let moreTitle = NSLocalizedString("More ways", comment: "")
    static let plazaRow = NSLocalizedString("Find nearby groups and channels over the Bluetooth mesh", comment: "")
    /// The plaza page's title. The rest of the sentences in this file are still written directly in Chinese (turning the whole page into keys is a separate round); this one is closed off first:
    /// The Cabin's top-left corner now pushes the same page (`PopopxCabinView.swift`'s `.plaza`); both places share
    /// key `Nearby mesh plaza`, with one sentence in each of the 16 translation directories, so a non-Chinese system no longer leaks a Chinese title.
    static let plazaNavigationTitle = NSLocalizedString("Nearby mesh plaza", comment: "POPOPX nearby mesh plaza")
    static let fuseOffValue = NSLocalizedString("Closed by the fuse", comment: "")
    static let scanRow = NSLocalizedString("Scan QR code", comment: "")
    static let shareRow = NSLocalizedString("Share my secure invitation link", comment: "")

    static let scannerSubtitle = NSLocalizedString("Only the invitation link inside the code is read; nothing else leaves this device.", comment: "")
    static let cameraStarting = NSLocalizedString("Preparing the camera…", comment: "")
    static let cameraDenied = NSLocalizedString("Camera access is turned off; enable it in the system settings", comment: "")
    static let cameraRestricted = NSLocalizedString("The camera is not available on this device", comment: "")
    static let cameraUnknown = NSLocalizedString("This device's camera status is unknown", comment: "")
    static let openSettings = NSLocalizedString("Open Settings", comment: "")
    static let scanFailedFormat = NSLocalizedString("Nothing read; aim at the QR code and try again: %@", comment: "")

    static let offlineConfirmationToast = NSLocalizedString("Their invitation was accepted; waiting for them to let you in", comment: "")
    static let offlineInvitationToast = NSLocalizedString("A connection has been started; see the contact's details", comment: "")
    static let onlineHandoffToast = NSLocalizedString("Handed to the online encrypted channel to connect", comment: "")
    static let unrecognizedToast = NSLocalizedString("This is neither a POPOPX link nor an online invitation link", comment: "")
    static let offlineFailedToast = NSLocalizedString("The offline connection failed; please try again later", comment: "")
    static let mintFailedToast = NSLocalizedString("Could not create the link", comment: "")
    static let clipboardEmptyToast = NSLocalizedString("No usable link in the clipboard", comment: "")
}

struct PopopxAddFriendView_Previews: PreviewProvider {
    static var previews: some View {
        PopopxAddFriendView()
            .environmentObject(ChatModel.shared)
            .environmentObject(AppTheme.shared)
    }
}
