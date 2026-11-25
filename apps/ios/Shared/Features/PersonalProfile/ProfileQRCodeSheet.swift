//
//  ProfileQRCodeSheet.swift
//  POPOPX (iOS)
//
//  [Encrypted personal profile · module 3] The dedicated profile card code. A card with a Wallet feel: purple brand background + the current anonymous identity +
//  the QR code + the tier this code distributes; inside the card you can switch directly between "permanent card / view-once after opening", and this tier is **armed**
//  for the "automatic push after a scan establishes the connection" (`ProfileAutoSender.shared`).
//
//  The interface's shape is copied wholesale from `Shared/Features/AddFriend/PopopxQRCardSheet.swift` (it is this project's only
//  pass card): `passCard` / `passSurface` / `passGradient` / `qrPlate` / `qrInk` / `linkPreview` /
//  `securityNote` / `closeButton` / `actionRow` + `private enum Copy`. No visual rule is reinvented here,
//  only three things are added: the mode segments, the arming state, and saving to the photo library.
//
//  ### Red lines (the ones this file must obey)
//  - **This file must be dragged into the POPOPX (iOS) target by hand; modifying project.pbxproj with a script is forbidden.**
//  - The QR code only uses the existing `POPOPXLinkQRCode` (`Shared/Views/NewChat/QRCode.swift:37`), not one line of
//    CIFilter is written here; colour/spacing/font/material all come from `PopopxTheme`; sharing only uses `showShareSheet(items:)`
//    (`Shared/Views/Helpers/ShareSheet.swift:27`), with no new activityViewController variant.
//  - The Sheet installs no navigation container of its own and brings no header bar; dismiss belongs to `PopopxSheetContainer`'s caller
//    (the ruling at PopopxQRCardSheet.swift:13-15), but this page supplies one close button (same practice as :174-182).
//  - Every Chinese sentence appears once only, inside `Copy`.
//
//  ### The QR code carries a "contact address", not the profile itself (a conclusion already measured in practice, the WHY is one line)
//  `POPOPXLinkQRCode` internally runs `uri` through `popopxChatLink()` once more (QRCode.swift:44 →
//  APITypes.swift:194-198), and that function only replaces the `popopx:/` prefix; feeding `popopx://profile?…` in directly gets it
//  rewritten into `https://popopx.chat//profile?…` (the extra slash is the second `/` left over after it swaps `popopx:/` for
//  `https://popopx.chat/`), and scanning yields an address this app cannot route to. So this code carries
//  the contact address minted by `PopopxInviteLink.mintOneTime`, while the profile is sent as another message by `ProfileAutoSender` after the connection.
//  The one passed in is already in the form `popopxChatLink` produced (PopopxTelemetryHeader.swift:418), so running it through again is the identity,
//  and that is the precondition on which this reuse holds, not a coincidence.
//
//  ### What this code can and cannot do in airplane mode (no pretending there is an offline hook)
//  It is still a real `/_connect` invite: underneath `PopopxInviteLink.mintOneTime` is
//  `apiAddContact(incognito:)` (POPOPXAPI.swift:1050), the same command as module 6's first offline-pairing step
//  (`PopopxMeshChatCore.createOfflineInvite`, and what POPOPXAPI.swift:3470-3474 hands back is
//  `CreatedConnLink.connFullLink`). **But it cannot deliver the profile over Bluetooth**: the invite string of the Cabin road needs the
//  `PopopxOfflineBridge.generateOfflineInviteLink(meshPublicKeyHex:incognito:)`
//  (`PopopxOfflineBridge.swift:141`) **peer's Cabin public key**, and a static code sitting on a screen waiting to be scanned cannot know in advance
//  which device will scan it (every call site in the live app obtains that public key from a real near-field session:
//  ManualPairingManager.swift:136/:151, PopopxProximityEngine.swift:641/:643). Nor is the bridge itself open to the app layer:
//  it is constructed exactly once inside `PopopxMeshRuntime`'s private init (POPOPXAPI.swift:3777).
//  So this card **does not call** the offline bridge, it only states this honestly below the card; offline, the profile that cannot be sent is handled by
//  `ProfileAutoSender`'s downgrade branch (plain text), not by this code.
//
//  ### Where the arming state is stored (the other half of the same ruling)
//  `scene=personal_profile` does not go into the URI: the string `apiAddContact` returns belongs to the Rust core, `popopxChatLink` rewrites
//  the prefix, and the offline bridge again forbids `$ \ " '` (PopopxOfflineBridge.swift:104), so it is **local** arming metadata,
//  stored in `ProfileAutoSender.shared.armedProfileScene` and consumed by the existing `contactConnected` hook.
//  This field on the page is only a **display mirror** of that state: the true value always sits on the sender's side, and this view writes no second copy.
//

import POPOPXChat
import SwiftUI
import UIKit

/// The profile card code. Marked `@MainActor` because it reads and writes `ProfileAutoSender` (that is a main-actor singleton) —
/// the same approach as `ProfileSendModeSheet` (ProfileBuilderView.swift:818) in the same feature.
@MainActor
struct ProfileQRCodeSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var toast = PopopxToastModel()

    private let identityName: String
    private let store: ProfileStorageManager

    /// The minted contact address (in the `https://popopx.chat/…` form). `nil` = not minted yet, and the QR field is a placeholder.
    @State private var invite: String?
    /// The pre-generated QR bitmap. It exists for two reasons: a screenshot archive must have a code that can be scanned (`QRCode`'s own
    /// `.task` does not run on `makeScreenshot`'s off-screen rendering path), and no after-image of the old code remains after a re-mint.
    @State private var qrBitmap: UIImage?
    /// The failure reason of minting the link. `apiAddContact` swallows errors and returns only nil (POPOPXAPI.swift:1050), so this sentence
    /// can only be given here; it is also the reason the "Retry" button exists in the placeholder field.
    @State private var mintFailure: String?
    @State private var isMinting = false

    /// The profile saved on this device. It decides whether the automatic push after arming has any content to send (if not, the sender refuses with
    /// `.noSavedProfile`), so this must be stated clearly on the card.
    @State private var saved: PopopxProfileManifest?
    @State private var isLoadingProfile = true

    /// The tier this code distributes. The initial value is taken from the saved profile's own field (the same origin as `ProfileSendModeSheet`,
    /// ProfileBuilderView.swift:901-:908), and when nothing was saved it rests on the permanent tier.
    @State private var sendMode: PopopxProfileSendMode = .standard
    @State private var ttlSeconds = ProfileBuilderViewModel.defaultEphemeralTTL

    /// The display mirror of `armedProfileScene`. See the file-header section.
    @State private var armedScene: PopopxArmedProfileScene?

    init(identityName: String, store: ProfileStorageManager = .shared) {
        self.identityName = identityName
        self.store = store
    }

    var body: some View {
        PopopxSheetContainer(Copy.sheetTitle, subtitle: Copy.sheetSubtitle) {
            closeButton
            passCard
            modeCard
            offlineNote
        } footer: {
            actionRow
        }
        .popopxToast(toast)
        // The link is minted and the disk read only when it opens: a code sitting on the screen that reused the link from the previous opening
        // would have a `PendingContactConnection` long since consumed by a scan — the "one-time" of a one-time link is the core's business,
        // and what can be guaranteed here is "a new one on every opening". `.task` cancels itself when the Sheet disappears, so no onDisappear tidy-up is needed.
        .task {
            await loadProfile()
            await mint()
        }
    }

    // MARK: - The pass card body

    private var passCard: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.issuerOverline)
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.onBrand)
                    Text(identityName)
                        .font(PopopxType.title)
                        .foregroundStyle(PopopxPalette.onBrand)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    modeBadge
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Image(PopopxBrandAsset.mark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                    .clipShape(.rect(cornerRadius: PopopxMetrics.radiusChip, style: .continuous))
                    .accessibilityHidden(true)
            }

            qrPlate
        }
        .padding(PopopxMetrics.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { passSurface }
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusSheet, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .popopxCardElevation(colorScheme: colorScheme)
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    /// The brand background uses only `brand` itself and its darker tier, with no purple→blue gradient (a verbatim copy of the gradient
    /// exception at `PopopxQRCardSheet.swift:93-111`: `label` underneath, and `onBrand` still above 4.5:1 at both ends).
    private var passSurface: some View {
        ZStack {
            PopopxPalette.label
            Rectangle().fill(passGradient)
        }
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusSheet, style: .continuous))
    }

    private var passGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: PopopxPalette.brand, location: 0),
                .init(color: PopopxPalette.brand.opacity(0.92), location: 0.45),
                .init(color: PopopxPalette.brand.opacity(Pass.dimOpacity(for: colorScheme)), location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The mode label on the card: which tier this QR code will distribute. The copy comes from the payload layer
    /// (`PopopxProfileSendMode.cardLabel`, PersonalProfileModel.swift:61), and the duration from
    /// `PopopxSecureCopy.duration` (PopopxSecurePayload.swift:357) — no second table is copied here.
    private var modeBadge: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: sendMode == .ephemeral ? "hourglass" : "person.badge.plus")
                .font(PopopxType.microTag)
            Text(badgeText)
                .font(PopopxType.microTag)
        }
        .foregroundStyle(PopopxPalette.onBrand)
        .padding(.horizontal, PopopxMetrics.spaceXS)
        .padding(.vertical, PopopxMetrics.space2XS)
        .background(PopopxMaterial.chip, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.badgeAccessibility)
        .accessibilityValue(badgeText)
    }

    private var badgeText: String {
        sendMode == .ephemeral
            ? "\(sendMode.cardLabel) · \(PopopxSecureCopy.duration(effectiveTTLSeconds))"
            : sendMode.cardLabel
    }

    /// The duration that is really armed and sent out. The `standard` tier is always 0 (the reading on the protocol side,
    /// PersonalProfileModel.swift:399-406), so choosing it in the interface does not count.
    private var effectiveTTLSeconds: Int {
        sendMode == .ephemeral ? ttlSeconds : 0
    }

    // MARK: - The QR panel

    private var qrPlate: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            if let invite {
                POPOPXLinkQRCode(uri: invite, withLogo: true, tintColor: qrInk)
                    .environment(\.fixedQRCode, qrBitmap)
                    .aspectRatio(1, contentMode: .fit)

                Text(linkPreview(invite))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                qrPlaceholder
            }
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.qrAccessibilityLabel)
        .accessibilityValue(invite ?? Copy.qrNotReadyValue)
    }

    /// The field shown before minting completes. Failure and still-minting speak two different sentences (mixing "network unreachable" with "wait a moment" would make the user wait for nothing).
    private var qrPlaceholder: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            if let mintFailure {
                Label {
                    Text(mintFailure)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PopopxPalette.danger)
                }
                PopopxButton(Copy.retry, systemImage: "arrow.clockwise", role: .secondary) {
                    await mint()
                }
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .tint(PopopxPalette.brand)
                Text(Copy.minting)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: Pass.qrPlaceholderHeight)
    }

    /// Scanning reads luminance difference, not brand polish: the code always sits on the `card` surface (a copy of
    /// the conclusion at PopopxQRCardSheet.swift:115-117).
    private var qrInk: UIColor {
        UIColor(PopopxPalette.brand).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        )
    }

    private func linkPreview(_ uri: String) -> String {
        uri.count > Pass.linkPreviewCharacters
            ? String(uri.prefix(Pass.linkPreviewCharacters)) + "…"
            : uri
    }

    // MARK: - Mode and arming

    private var modeCard: some View {
        PopopxSectionCard(Copy.modeGroup, footnote: Copy.armFootnote) {
            PopopxSegmentedControl(
                [PopopxProfileSendMode.standard, .ephemeral].map {
                    PopopxSegmentedControl<PopopxProfileSendMode>.Option(selection: $0, title: $0.sheetLabel)
                },
                title: \.sheetLabel,
                selection: modeSelection
            )
            .accessibilityIdentifier("popopx.profile.qr.modeSegment")

            if sendMode == .ephemeral {
                inlineDivider
                PopopxSegmentedControl(
                    ProfileBuilderViewModel.ttlChoices.map {
                        PopopxSegmentedControl<Int>.Option(selection: $0, title: PopopxSecureCopy.duration($0))
                    },
                    title: { PopopxSecureCopy.duration($0) },
                    selection: ttlSelection
                )
                .accessibilityIdentifier("popopx.profile.qr.ttlSegment")
            }

            Text(modeNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, PopopxMetrics.space2XS)

            if saved == nil && !isLoadingProfile {
                Text(Copy.noSavedProfileNote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, PopopxMetrics.space2XS)
            }

            inlineDivider

            HStack(spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(armedScene == nil ? Copy.armIdle : armedSummary)
                        .font(PopopxType.meta)
                        .foregroundStyle(armedScene == nil ? PopopxPalette.labelSecondary : PopopxPalette.brand)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                if armedScene != nil {
                    PopopxButton(Copy.cancelArmed, systemImage: "xmark.circle", role: .secondary, fullWidth: false) {
                        cancelArming()
                    }
                    .accessibilityIdentifier("popopx.profile.qr.cancelArmed")
                }
            }
            .frame(minHeight: PopopxMetrics.minHitTarget)
        }
    }

    /// The arming-state echo line. It reads a snapshot of the sender's true value rather than the interface guessing: the expiry time is decided over there
    /// (`ProfileAutoSender.armingWindowSeconds`), and this only reads it out.
    private var armedSummary: String {
        guard let armedScene else { return Copy.armIdle }
        let remaining = Int(armedScene.expiresAt.timeIntervalSinceNow)
        guard remaining > 0 else { return Copy.armExpired }
        let minutes = remaining / 60 + 1
        guard armedScene.mode == .ephemeral else {
            return String(format: Copy.armActiveStandardFormat, armedScene.mode.cardLabel, minutes)
        }
        return String(
            format: Copy.armActiveEphemeralFormat,
            armedScene.mode.cardLabel,
            minutes,
            PopopxSecureCopy.duration(armedScene.ttlSeconds)
        )
    }

    /// Switching is arming. It goes through the `Binding` setter rather than `.onChange`: `.onChange` would count that **programmatic**
    /// assignment made by `loadProfile()` as a user intention too, so merely opening this Sheet would silently arm one automatic push.
    private var modeSelection: Binding<PopopxProfileSendMode> {
        Binding(get: { sendMode }, set: { arm(mode: $0, ttl: ttlSeconds) })
    }

    private var ttlSelection: Binding<Int> {
        Binding(get: { ttlSeconds }, set: { arm(mode: sendMode, ttl: $0) })
    }

    private func arm(mode: PopopxProfileSendMode, ttl: Int) {
        sendMode = mode
        ttlSeconds = ttl
        // Why `ttlIsBoundToContact: true`: the duration shown on this card face is the duration the other side gets.
        // Choosing "5 minutes" but sending it out with the saved profile's own 60 seconds would be making the user lie about a code.
        ProfileAutoSender.shared.armProfileScene(mode: mode, ttlSeconds: ttl, ttlIsBoundToContact: true)
        armedScene = ProfileAutoSender.shared.armedProfileScene
        // `.success` rather than `.encrypted`/`.mesh`: arming is a local state change, and neither link has been touched yet.
        toast.show(Copy.armToast, kind: .success)
        PopopxHaptics.notice(.success)
    }

    private func cancelArming() {
        ProfileAutoSender.shared.cancelArmedProfileScene()
        armedScene = nil
        toast.show(Copy.cancelArmedToast, kind: .success)
        PopopxHaptics.notice(.warning)
    }

    private var modeNote: String {
        switch sendMode {
        case .standard: return Copy.standardNote
        case .ephemeral: return Copy.ephemeralNote
        }
    }

    private var inlineDivider: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }

    // MARK: - Notes and actions

    private var offlineNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "lock.shield.fill")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.brand)
            Text(Copy.securityNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    private var closeButton: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Spacer(minLength: PopopxMetrics.spaceXS)
            PopopxButton(Copy.close, systemImage: "xmark", role: .secondary, fullWidth: false) {
                // Closing does **not** cancel the arming: this card's usage is "show → put away → wait for the other side to scan".
                // The arming is only ever closed off in two places: `cancelArmedProfileScene()` and the sender's own validity period.
                dismiss()
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    private var actionRow: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            PopopxButton(Copy.share, systemImage: "square.and.arrow.up", role: .primary, isLoading: isMinting) {
                share()
            }
            .accessibilityIdentifier("popopx.profile.qr.share")
            PopopxButton(Copy.saveAlbum, systemImage: "square.and.arrow.down", role: .secondary, fullWidth: false) {
                saveToAlbum()
            }
            .accessibilityIdentifier("popopx.profile.qr.saveAlbum")
            .disabled(invite == nil)
            PopopxButton(Copy.regen, systemImage: "arrow.clockwise", role: .ghost, fullWidth: false) {
                await mint()
            }
            .accessibilityIdentifier("popopx.profile.qr.regen")
        }
        .padding(PopopxMetrics.spaceM)
    }

    // MARK: - Action implementations

    /// Mint a one-time connection link. **It does not concatenate the string itself**: underneath `PopopxInviteLink.mintOneTime` is
    /// `apiAddContact(incognito:)` + `popopxChatUri(short:)` + `popopxChatLink`
    /// (PopopxTelemetryHeader.swift:416-418), and what comes back is already in the `https://popopx.chat/…` form.
    /// On failure `apiAddContact` does not throw, it only returns nil (POPOPXAPI.swift:1050), so visible feedback must be given here.
    private func mint() async {
        guard !isMinting else { return }
        isMinting = true
        defer { isMinting = false }
        invite = nil
        qrBitmap = nil
        mintFailure = nil
        guard let minted = await PopopxInviteLink.mintOneTime(incognito: incognitoGroupDefault.get()) else {
            mintFailure = Copy.mintFailedNote
            logger.error("POPOPX profile QR: the one-time connection link could not be created (apiAddContact returned nil)")
            PopopxHaptics.notice(.error)
            return
        }
        invite = minted.uri
        // The same errorLevel rule as `POPOPXLinkQRCode` (QRCode.swift:44 `small: uri.count < 200`
        // → :105 `small ? "M" : "L"`), so the injected bitmap and the one the view would draw itself are exactly the same code.
        qrBitmap = await generateImage(minted.uri, tintColor: qrInk, errorLevel: minted.uri.count < 200 ? "M" : "L")
        PopopxHaptics.notice(.success)
    }

    private func loadProfile() async {
        let loaded = await store.loadEditable()
        saved = loaded
        if let loaded {
            sendMode = loaded.sendMode
            ttlSeconds = loaded.sendMode == .ephemeral
                ? (ProfileBuilderViewModel.ttlChoices.contains(loaded.ttlSeconds)
                    ? loaded.ttlSeconds
                    : ProfileBuilderViewModel.defaultEphemeralTTL)
                : ProfileBuilderViewModel.defaultEphemeralTTL
        }
        armedScene = ProfileAutoSender.shared.armedProfileScene
        isLoadingProfile = false
    }

    /// The whole card image. `fixedQRCode` has already been injected (:215), so the off-screen render is a real code —
    /// without this step `makeScreenshot` would capture the blank of a `QRCode` field that was never generated (the
    /// `.task` at QRCode.swift:105 does not run on UIHostingController's rendering path).
    private func cardImage() -> UIImage {
        passCard.makeScreenshot()
    }

    /// What is shared is the whole card image (identity + mode + code), not a bare link. The code at `PopopxQRCardSheet.swift:196-198`
    /// shares a uri string, because its entire interface is one line of a link; if what is shared here, after being passed on once,
    /// can no longer be recognised as whose code it is, an anonymous invite link spreading through a chat tool is worse than a sentence.
    private func share() {
        guard let invite else {
            toast.show(Copy.noLinkToast, kind: .danger)
            return
        }
        // `makeScreenshot()`, given no size, takes the hosting controller's `intrinsicContentSize`
        // (QRCode.swift:131-:136); when that value is 0 it hands back a zero-sized image, and sharing leaves nothing but a blank attachment.
        // The link is the same code in another form, so using it as a fallback never leaves the user unable to send anything.
        let card = cardImage()
        showShareSheet(items: card.size.width > 1 ? [card] : [invite])
    }

    /// Saving to the photo library uses the live app's `UIImageWriteToSavedPhotosAlbum` (ChatView.swift:2725 is this project's only
    /// precedent, there is no PHPhotoLibrary request path). The permission string `NSPhotoLibraryAddUsageDescription`
    /// is already supplied by the build setting's INFOPLIST_KEY_*, and this file does not touch Info.plist.
    private func saveToAlbum() {
        guard invite != nil else { return }
        let card = cardImage()
        guard card.size.width > 1 else {
            toast.show(Copy.blankCardToast, kind: .danger)
            return
        }
        UIImageWriteToSavedPhotosAlbum(card, nil, nil, nil)
        toast.show(Copy.savedToast, kind: .success)
        PopopxHaptics.notice(.success)
    }
}

// MARK: - The card's own geometry

/// The two numbers a pass card needs and the design system does not have (following the `Pass` style of `PopopxQRCardSheet.swift:209-218`).
private enum Pass {
    static let linkPreviewCharacters = 28
    /// The placeholder field is the same height as the real code, so the card does not jump when the link mints successfully.
    static let qrPlaceholderHeight: CGFloat = 180

    /// Light mode fades further (the tail must read as a deep indigo edge), dark mode fades less (there the ink is near black, so the tail has to be the bright end).
    static func dimOpacity(for scheme: ColorScheme) -> Double {
        scheme == .light ? 0.55 : 0.70
    }
}

// MARK: - Copy

/// Every Chinese sentence on the card appears exactly once, here (the `private enum Copy` rule at `PopopxQRCardSheet.swift:223-233`).
private enum Copy {
    static let sheetTitle = NSLocalizedString("My profile card code", comment: "")
    static let sheetSubtitle = NSLocalizedString("Show this code: once they scan it and connect, they receive your encrypted profile automatically", comment: "")
    static let issuerOverline = NSLocalizedString("Anonymous identity", comment: "")

    static let qrAccessibilityLabel = NSLocalizedString("Profile card QR code", comment: "")
    static let qrNotReadyValue = NSLocalizedString("Not generated yet", comment: "")
    static let badgeAccessibility = NSLocalizedString("The profile mode this code will distribute", comment: "")

    static let minting = NSLocalizedString("Creating the one-time connection link…", comment: "")
    static let retry = NSLocalizedString("Retry", comment: "")
    static let mintFailedNote = NSLocalizedString("The link was not created: check your network and tap Retry.", comment: "")

    static let modeGroup = NSLocalizedString("Which tier this code distributes", comment: "")
    static let standardNote = NSLocalizedString("Standing card: no destruction time once your contact receives it, and the text, images and video stay openable at any time.", comment: "")
    static let ephemeralNote = NSLocalizedString("Burn after reading: the window starts the moment your contact opens it, and at the deadline this device's copy and the original are destroyed together.", comment: "")
    static let noSavedProfileNote = NSLocalizedString("No profile has been saved on this device yet. Arming it now would push nothing — build and save one under Me → Encrypted profile first.", comment: "")

    static let armFootnote = NSLocalizedString("Switching arms it: after the scan connects, this device sends that tier on its own, with no extra tap in the chat.", comment: "")
    static let armIdle = NSLocalizedString("No auto-push is armed right now.", comment: "")
    static let armExpired = NSLocalizedString("The arming has expired: switch the mode or the duration once to arm it again.", comment: "")
    static let armActiveStandardFormat = NSLocalizedString("Armed: after the scan connects, %1$@ is pushed automatically, valid for about %2$lld minutes", comment: "")
    static let armActiveEphemeralFormat = NSLocalizedString("Armed: after the scan connects, %1$@ is pushed automatically, valid for about %2$lld minutes, burn-after-read time %3$@", comment: "")
    static let armToast = NSLocalizedString("This code is armed: they get this tier automatically once the scan connects", comment: "")
    static let cancelArmed = NSLocalizedString("Cancel auto-push", comment: "")
    static let cancelArmedToast = NSLocalizedString("Scan auto-push cancelled", comment: "")

    static let securityNote = NSLocalizedString("This link only sets up a one-time encrypted connection — anyone who gets it can start a connection with you, so do not publish it. The QR code carries no profile content: the content goes out as a single message only after the connection exists.", comment: "")

    static let close = NSLocalizedString("Close", comment: "")
    static let share = NSLocalizedString("Share", comment: "")
    static let saveAlbum = NSLocalizedString("Save to Photos", comment: "")
    static let regen = NSLocalizedString("New code", comment: "")
    static let savedToast = NSLocalizedString("Saved to Photos (the first time it asks for write access)", comment: "")
    static let noLinkToast = NSLocalizedString("The link is not ready yet, so there is nothing to share.", comment: "")
    static let blankCardToast = NSLocalizedString("The card is not laid out yet; wait a moment and save again.", comment: "")
}

// MARK: - Preview

#if DEBUG
struct ProfileQRCodeSheet_Previews: PreviewProvider {
    static var previews: some View {
        ProfileQRCodeSheet(identityName: "Ink Courier")
    }
}
#endif
