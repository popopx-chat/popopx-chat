//
//  ProfileBuilderView.swift
//  POPOPX (iOS)
//
//  [Encrypted personal profile · module 2] The builder, and the lightweight send-confirmation sheet in the chat "+" panel.
//
//  Three types, three responsibilities:
//
//  1. `ProfileBuilderViewModel` — the only editable state of the local draft. Loading goes through `loadEditable()`, writing back goes through
//     the throwing `saveEditable(_:)`; adding, removing and reordering blocks, importing photos/videos and surfacing failure reasons all live in this one class.
//  2. `ProfileBuilderView` — the builder's layout. It carries no stack of its own (the same rule as `PopopxMeView.swift:10`:
//     the NavigationStack is wrapped uniformly by the caller), and the bottom bar is fixed: dual-mode network hint + save + safe preview.
//  3. `ProfileSendModeSheet` — that one choice before sending. It only reads the saved profile, and changes the mode of **this send**,
//     never writing back to `manifest.json`.
//
//  ### Three unobtrusive but critical things on this page
//
//  1. **Saving is the gate on the sending side**. `ProfileStorageManager.saveEditable(_:)` first runs
//     `PopopxProfilePayload.make` (ProfileStorageManager.swift:257-261), so a draft that can be saved
//     can certainly be sent; conversely, an over-long title, too many blocks or an out-of-range privacy duration all bounce back here as the
//     verbatim wording of `reasonText`, and the interface must not invent a second set of sentences.
//  2. **The draft's `deliveryMode` is always `.fullMedia`**. The delivery mode is decided by the route at the moment of sending; it is not a property
//     of the content; once a draft carries `.meshTextOnly`, `normalized()` wipes out the user's text, images and videos wholesale
//     (PersonalProfileModel.swift:247-261), and what `saveEditable` writes is exactly the copy passed into it.
//  3. **Updating content needs no QR code regenerated**. `profileId` is generated only at the first build and every later save reuses
//     the same one (see the `profileId` line below), and it is both the media directory's partition key and the stable identifier
//     that profile distribution points to (PersonalProfileModel.swift:177), so content edits do not touch it.
//
//  Colours, font sizes, corner radii and spacing all come from the tokens in Shared/Theme/PopopxTheme.swift; controls use only
//  the atom library already in Shared/Components. Every Chinese sentence on the page appears exactly once, in this file's `Copy`.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand — the iron rule forbids scripts changing project.pbxproj.
//

import AVFoundation
import SwiftUI
import UIKit

// MARK: - Stable block identity

/// A one-row snapshot used by `ForEach`: stable id + current index + content.
/// The id is neither the index nor the content: after a move up or down an index points at different content, and the cell being typed into jumps away;
/// while using content as the id means every keystroke is a change of identity.
struct ProfileBuilderBlockEntry: Identifiable {
    let id: UUID
    let index: Int
    let block: PopopxProfileBlock
}

// MARK: - Builder state

@MainActor
@Observable
final class ProfileBuilderViewModel {
    /// The three selectable durations of the privacy tier. The values are defined once, only in `PopopxProfilePayload.ttlOptions`
    /// (PersonalProfileModel.swift:363); no second table is copied here.
    static let ttlChoices: [Int] = PopopxProfilePayload.ttlOptions

    /// The default privacy-tier duration: the middle one of the three tiers; if the table is emptied it falls back to the protocol floor rather than hard-coding a 300.
    static var defaultEphemeralTTL: Int {
        ttlChoices.isEmpty ? PopopxProfilePayload.minimumTTLSeconds : ttlChoices[ttlChoices.count / 2]
    }

    /// The `UIImage` handed back by the photo library is first JPEG-encoded at this quality. The real compression ladder (the pixel and quality ladders) lives in the storage layer,
    /// and that table belongs to `ProfileStorageManager`; here we only turn a `UIImage` into bytes it can eat.
    private static let pickedImageJPEGQuality: CGFloat = 0.9

    // MARK: Editable state (the view binds these cells directly)

    var title = ""
    var subtitle = ""
    var enableAntiSpyCamera = false
    /// The credits charged to view this profile, 0 = free. The view binds it directly (same approach as the cell above), and 0 becomes nil when it lands in the manifest.
    ///
    /// There is no "may this price be charged" validation here: the money boundary is on the `PopopxCreditsManager.unlockProfile` side,
    /// and the builder is only responsible for carrying the number the user chose out unchanged.
    var unlockCredits = 0

    // MARK: Read-only state

    private(set) var blocks: [PopopxProfileBlock] = []
    private(set) var blockIDs: [UUID] = []
    private(set) var sendMode: PopopxProfileSendMode = .standard
    private(set) var ttlSeconds = 0
    /// The on-device original-file addresses of the media blocks (key = `mediaId`). Filled once on import and once on load, so the rendering code
    /// does not have to ask the actor once per frame just to get a path.
    private(set) var mediaURLs: [String: URL] = [:]
    private(set) var isReady = false
    private(set) var isSaving = false
    private(set) var mediaBusy = false
    private(set) var errorText: String?
    private(set) var noticeText: String?

    /// The model holds the receipt and the view only mounts it (`PopopxToast.swift:133` requires mounting at the highest point of the whole screen).
    let toast = PopopxToastModel()

    private let store: ProfileStorageManager
    /// Once generated it is fixed and every later save reuses the same one: content edits do not move it,
    /// so the entries distributed by `profileId` (the profile QR code, the media directory) need no rebuild because content changed.
    private var profileId: String
    /// Switching to the permanent tier zeroes `ttlSeconds` (the protocol accepts only 0, PersonalProfileModel.swift:400-401),
    /// but the duration the user last chose has to be kept: switching modes repeatedly must not quietly change their privacy setting.
    private var rememberedEphemeralTTL: Int

    init(store: ProfileStorageManager = .shared) {
        self.store = store
        self.profileId = PopopxProfileManifest.blank().profileId
        self.rememberedEphemeralTTL = Self.defaultEphemeralTTL
        // The draft is read on that actor, so the main thread is not occupied. Until it is read the interface is in the loading state (`isReady`),
        // so the race "the user typed first and was then overwritten by the copy on disk" cannot exist.
        Task { [weak self] in
            guard let self else { return }
            await self.loadDraft()
        }
    }

    // MARK: Derived copy

    var mediaCount: Int { blocks.reduce(0) { $0 + $1.mediaCount } }
    var imageCount: Int { blocks.filter { $0.media?.kind == .image }.count }
    var videoCount: Int { blocks.filter { $0.media?.kind == .video }.count }

    /// Whether another block may still be added. The 24 limit is `make`'s call; the interface closes the door first so that the user hears the same sentence.
    var canAddBlock: Bool { blocks.count < PopopxProfilePayload.maximumBlocks }
    var canSave: Bool { isReady && !isSaving && !mediaBusy }

    /// The line under the identity card. When the limit is exceeded, the protocol layer's own wording is shown as the hint rather than a softer invented one:
    /// what the user sees here and what they see when saving fails are the same message.
    var identityFootnote: String {
        let used = title.count
        guard used > PopopxProfilePayload.maximumTitleCharacters else {
            return String(format: Copy.titleCountFormat, used, PopopxProfilePayload.maximumTitleCharacters)
        }
        return PopopxProfileError.oversizedTitle(characters: used).reasonText
    }

    var blocksFootnote: String {
        String(
            format: Copy.blocksCountFormat,
            blocks.count,
            PopopxProfilePayload.maximumBlocks,
            imageCount,
            videoCount
        )
    }

    /// The explanatory line inside the mode card. The permanent-tier sentence is the product's mandated wording; the privacy-tier sentence pins down where the clock starts,
    /// because "the timer starts only once it is opened" is precisely the one thing that tells this tier apart from the permanent tier.
    var policyNote: String {
        switch sendMode {
        case .standard: return Copy.standardNote
        case .ephemeral: return Copy.ephemeralNote
        }
    }

    /// What this draft would lose if it later goes over Mesh. The delivery mode is not chosen on this page (see the comment on `draftManifest()`),
    /// so this only reports "how many would be dropped", rather than handing the user a switch that the route actually decides.
    var deliveryHint: String {
        mediaCount == 0 ? Copy.deliveryHintTextOnly : String(format: Copy.deliveryHintMediaFormat, mediaCount)
    }

    // MARK: Loading

    private func loadDraft() async {
        let saved = await store.loadEditable()
        await apply(saved ?? PopopxProfileManifest.blank())
        noticeText = saved == nil ? Copy.noticeNoDraft : nil
        isReady = true
    }

    private func apply(_ manifest: PopopxProfileManifest) async {
        profileId = manifest.profileId
        title = manifest.title
        subtitle = manifest.subtitle ?? ""
        sendMode = manifest.sendMode
        ttlSeconds = manifest.ttlSeconds
        enableAntiSpyCamera = manifest.enableAntiSpyCamera
        // Brought back as it is, without snapping to a tier: the threshold is a custom number, and a legal value missing from the picker table (say 37) is still a decision the user made,
        // so quietly turning it into 20 or 0 while loading would be changing their price. The real boundary is on the debit side.
        unlockCredits = manifest.unlockCredits ?? 0
        blocks = manifest.blocks
        blockIDs = manifest.blocks.map { _ in UUID() }
        rememberedEphemeralTTL = manifest.sendMode == .ephemeral
            ? (Self.ttlChoices.contains(manifest.ttlSeconds) ? manifest.ttlSeconds : Self.defaultEphemeralTTL)
            : Self.defaultEphemeralTTL
        mediaURLs = [:]
        for block in manifest.blocks {
            guard let media = block.media else { continue }
            mediaURLs[media.mediaId] = await store.mediaURL(media, profileId: manifest.profileId)
        }
    }

    // MARK: Mode and duration

    /// Choosing the send mode. The property's write access is not exposed directly because the two tiers demand opposite things of `ttlSeconds`:
    /// the permanent tier must be 0 (`make` rejects any non-zero), and the privacy tier must fall within the three tiers.
    func select(sendMode mode: PopopxProfileSendMode) {
        guard mode != sendMode else { return }
        switch mode {
        case .standard:
            ttlSeconds = 0
        case .ephemeral:
            ttlSeconds = rememberedEphemeralTTL
        }
        sendMode = mode
        errorText = nil
    }

    func select(ttlSeconds seconds: Int) {
        guard Self.ttlChoices.contains(seconds) else { return }
        ttlSeconds = seconds
        rememberedEphemeralTTL = seconds
        errorText = nil
    }

    // MARK: Blocks

    var entries: [ProfileBuilderBlockEntry] {
        zip(blockIDs, blocks).enumerated().map { pair in
            ProfileBuilderBlockEntry(id: pair.element.0, index: pair.offset, block: pair.element.1)
        }
    }

    /// The binding of a text block. The index is recomputed on every read and write, so after a move up or down this cell still points at its own content.
    func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { self.text(of: id) },
            set: { self.replaceText(id, with: $0) }
        )
    }

    func addTextBlock() {
        guard reserveBlockSlot() else { return }
        PopopxHaptics.impact(.light)
        insert(.text(""), at: blocks.count)
        noticeText = nil
        errorText = nil
    }

    func reorder(_ id: UUID, by delta: Int) {
        guard let from = blockIDs.firstIndex(of: id) else { return }
        let to = from + delta
        guard blocks.indices.contains(to) else { return }
        blocks.swapAt(from, to)
        blockIDs.swapAt(from, to)
        PopopxHaptics.impact(.light)
    }

    func delete(_ id: UUID) {
        guard let index = blockIDs.firstIndex(of: id), blocks.indices.contains(index) else { return }
        let block = blocks[index]
        blocks.remove(at: index)
        blockIDs.remove(at: index)
        if let media = block.media {
            let mediaId = media.mediaId
            let profileId = self.profileId
            // A deleted original must leave the disk at once, even at the cost of some **older** saved manifest pointing at a
            // mediaId that no longer exists: the `PopopxProfileMediaLoad.missing` branch exists for exactly this case,
            // and "the user deleted it but the original still lies in the sandbox" is the worse kind for a privacy feature.
            Task { await store.removeMedia(profileId: profileId, ids: [mediaId]) }
            mediaURLs.removeValue(forKey: mediaId)
        }
        PopopxHaptics.notice(.warning)
        errorText = nil
    }

    private func text(of id: UUID) -> String {
        guard let index = blockIDs.firstIndex(of: id), blocks.indices.contains(index),
              case let .text(body) = blocks[index]
        else { return "" }
        return body
    }

    private func replaceText(_ id: UUID, with value: String) {
        guard let index = blockIDs.firstIndex(of: id), blocks.indices.contains(index) else { return }
        blocks[index] = .text(value)
    }

    private func insert(_ block: PopopxProfileBlock, at index: Int) {
        blocks.insert(block, at: index)
        blockIDs.insert(UUID(), at: index)
    }

    /// The action proceeds only while the block count is below the limit. When it is full, the protocol's own sentence is pushed onto the interface instead of refusing silently.
    private func reserveBlockSlot() -> Bool {
        guard isReady, !mediaBusy else { return false }
        guard canAddBlock else {
            report(PopopxProfileError.tooManyBlocks(count: blocks.count), context: "add block")
            return false
        }
        return true
    }

    // MARK: Photo library

    /// Whatever comes back selected. The type follows the `UploadContent` actually chosen, not the button that was pressed:
    /// the default filter of the app's single photo-library wrapper lets through both images and videos (ImagePicker.swift:37),
    /// so "add image" and "add video" are the same action in the implementation, and putting two buttons there would be lying.
    func receivePicked(_ content: UploadContent) async {
        guard reserveBlockSlot() else { return }
        errorText = nil
        switch content {
        case let .video(_, url, _):
            await importVideo(from: url)
        default:
            await importImage(content.uiImage)
        }
    }

    private func importImage(_ image: UIImage) async {
        mediaBusy = true
        defer { mediaBusy = false }
        // Only a `UIImage` is available: that wrapper chain returns `.animatedImage` for any image it can decode
        // (ComposeView.swift:337-352), so the original URL cannot be had and a JPEG is encoded here first for the storage layer.
        guard let data = image.jpegData(compressionQuality: Self.pickedImageJPEGQuality) else {
            report(PopopxProfileMediaError.undecodableImage, context: "picked image")
            return
        }
        do {
            let media = try await store.importImage(data, profileId: profileId)
            await finishImport(media)
        } catch {
            report(error, context: "importImage")
        }
    }

    private func importVideo(from url: URL) async {
        mediaBusy = true
        defer { mediaBusy = false }
        do {
            // Transcoding runs on that actor, which also decides the 30-second cut-off and the 15 MB budget; here we only wait for the result.
            let media = try await store.importVideo(from: url, profileId: profileId)
            await finishImport(media)
        } catch {
            report(error, context: "importVideo")
        }
    }

    private func finishImport(_ media: PopopxProfileMedia) async {
        mediaURLs[media.mediaId] = await store.mediaURL(media, profileId: profileId)
        let block: PopopxProfileBlock = media.kind == .image ? .image(media) : .video(media)
        insert(block, at: blocks.count)
        noticeText = nil
        // Importing is not saving: the original is already on disk but the manifest is not written. This has to be said out loud, otherwise the user assumes
        // closing the page kept the content too. The haptic fires here rather than on the button: this chain is not inside a `PopopxButton` action.
        PopopxHaptics.notice(.success)
        toast.show(
            String(format: Copy.mediaAddedFormat, Copy.kind(media.kind), Self.sizeText(media.bytes)),
            kind: .success
        )
    }

    // MARK: Saving

    /// The full manifest of the current draft. `deliveryMode` is always `.fullMedia` and `omittedMediaCount` is always 0:
    /// those two cells are sending-time business, and letting `normalized()` see `.meshTextOnly` on this copy would be deleting the user's content.
    func draftManifest(updatedAt: TimeInterval) -> PopopxProfileManifest {
        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return PopopxProfileManifest(
            profileVersion: PopopxProfileManifest.version,
            profileId: profileId,
            title: title,
            subtitle: trimmedSubtitle.isEmpty ? nil : trimmedSubtitle,
            sendMode: sendMode,
            ttlSeconds: ttlSeconds,
            deliveryMode: .fullMedia,
            omittedMediaCount: 0,
            enableAntiSpyCamera: enableAntiSpyCamera,
            // 0 is stored as nil rather than writing `unlockCredits: 0` into the JSON: for the threshold, "never written" and "written but equal to zero"
            // must give the receiving side exactly the same behaviour (open directly), and every older profile is the "never written" case.
            unlockCredits: unlockCredits > 0 ? unlockCredits : nil,
            updatedAt: updatedAt,
            blocks: blocks
        )
    }

    /// Writing back to the device. Failures always surface with the typed error's own wording.
    func save() async {
        guard canSave else { return }
        errorText = nil
        isSaving = true
        let manifest = draftManifest(updatedAt: Date().timeIntervalSince1970).normalized()
        do {
            try await store.saveEditable(manifest)
            // The success path adds no further haptic: `PopopxButton` has already, when its isBusy falls back to false,
            // fired `notice(.success)` (PopopxControls.swift:171-178), so firing it again here would be two pieces of feedback.
            toast.show(Copy.savedToast, kind: .success)
        } catch {
            report(error, context: "saveEditable")
        }
        isSaving = false
    }

    // MARK: Safe preview

    /// The projection used for the preview; it **does not touch the draft**.
    ///
    /// The Mesh tier goes through `textOnly` and then `normalized()`, exactly the same path as a real send: dropping every image/video block,
    /// recording the dropped count in `omittedMediaCount`, then converging the invariants once more by mode (PersonalProfileModel.swift:214-231).
    /// The order cannot be reversed: `normalized()` only clamps `omittedMediaCount` into range; it computes the real count for nobody.
    func previewManifest(
        sendMode mode: PopopxProfileSendMode,
        delivery: PopopxProfileDelivery
    ) -> PopopxProfileManifest {
        var copy = draftManifest(updatedAt: Date().timeIntervalSince1970)
        copy.sendMode = mode
        copy.ttlSeconds = mode == .ephemeral
            ? (Self.ttlChoices.contains(ttlSeconds) ? ttlSeconds : Self.defaultEphemeralTTL)
            : 0
        if delivery == .meshTextOnly {
            copy = copy.textOnly
        }
        return copy.normalized()
    }

    // MARK: Surfacing failures

    /// The typed error's own wording. `PopopxProfileError` speaks for the protocol layer, `PopopxProfileMediaError` for the local processing layer,
    /// and neither may be swallowed: swallow one failure and the user will think the content has been saved.
    private func report(_ error: Error, context: String) {
        let text: String
        switch error {
        case let failure as PopopxProfileError:
            text = failure.reasonText
        case let failure as PopopxProfileMediaError:
            text = failure.reasonText
        default:
            text = String(format: Copy.unexpectedFormat, error.localizedDescription)
        }
        errorText = text
        logger.error("POPOPX profile builder: \(context, privacy: .public) failed: \(text, privacy: .public)")
        PopopxHaptics.notice(.error)
    }

    /// Sizes are formatted once, here: every byte count in the app goes through the binary mode of `ByteCountFormatter`
    /// (the same convention as CIVideoView.swift:320 and CIFileView.swift:41); the two `bytes / 1_024` spots inside error sentences belong to the storage layer.
    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

// MARK: - Builder page

@MainActor
struct ProfileBuilderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = ProfileBuilderViewModel()
    @State private var showsLibrary = false
    @State private var showsPreview = false
    @State private var previewMode: PopopxProfileSendMode = .standard
    @State private var previewDelivery: PopopxProfileDelivery = .fullMedia

    init() {}

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                if model.isReady {
                    identitySection
                    policySection
                    blocksSection
                    addSection
                } else {
                    loadingCard
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.spaceL)
            // Expanding/collapsing the privacy-tier cell, and adding or removing blocks: under Reduce Motion they land directly.
            .popopxAnimation(PopopxSpring.fluid, value: model.sendMode, reduceMotion: reduceMotion)
            .popopxAnimation(PopopxSpring.snappy, value: model.blocks.count, reduceMotion: reduceMotion)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.pageTitle)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showsLibrary) { libraryPicker }
        .sheet(isPresented: $showsPreview) { previewSheet }
        .popopxToast(model.toast)
    }

    // MARK: Identity section

    private var identitySection: some View {
        @Bindable var model = model
        return PopopxSectionCard(Copy.identityGroup, footnote: model.identityFootnote) {
            PopopxTextField(
                Copy.titleLabel,
                prompt: Copy.titlePrompt,
                text: $model.title,
                systemImage: "person.text.rectangle"
            )
            .accessibilityIdentifier("popopx.profile.builder.title")
            PopopxBuilderDivider()
            PopopxTextField(
                Copy.subtitleLabel,
                prompt: Copy.subtitlePrompt,
                text: $model.subtitle,
                systemImage: "text.append"
            )
            .accessibilityIdentifier("popopx.profile.builder.subtitle")
        }
    }

    // MARK: Send permission and destruction policy

    private var policySection: some View {
        @Bindable var model = model
        return PopopxSectionCard(Copy.policyGroup) {
            PopopxProfileModeSegment(
                selection: Binding(get: { model.sendMode }, set: { model.select(sendMode: $0) }),
                identifier: "popopx.profile.builder.modeSegment"
            )
            if model.sendMode == .ephemeral {
                PopopxBuilderDivider()
                Text(Copy.ttlLabel)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PopopxProfileTTLSegment(
                    selection: Binding(get: { model.ttlSeconds }, set: { model.select(ttlSeconds: $0) }),
                    identifier: "popopx.profile.builder.ttlSegment"
                )
            }
            Text(model.policyNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, PopopxMetrics.space2XS)
            if model.sendMode == .ephemeral {
                PopopxBuilderDivider()
                PopopxToggleRow(
                    Copy.antiSpyToggle,
                    note: Copy.antiSpyNote,
                    systemImage: "camera.viewfinder",
                    tint: .brand,
                    isOn: $model.enableAntiSpyCamera
                )
                .accessibilityIdentifier("popopx.profile.builder.antiSpy")
            }
            PopopxBuilderDivider()
            // The charge threshold does not belong to the "privacy" family (what it changes is whether the recipient pays, not how long content stays),
            // so it does not follow the `sendMode == .ephemeral` branch: a permanent card may set a threshold just the same.
            Text(Copy.thresholdLabel)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            PopopxTextField(
                Copy.thresholdField,
                prompt: Copy.thresholdPrompt,
                text: unlockCreditsText,
                systemImage: "circle.hexagongrid.fill",
                keyboard: .numberPad
            )
            .accessibilityIdentifier("popopx.profile.builder.threshold")
            Text(Copy.thresholdNote(PopopxCommerceLimits.maximumCreditsThreshold))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Only one conversion between the threshold number field and the model: an empty field = 0 in the model = nil in the manifest.
    ///
    /// Deliberately no extra "charge or not" boolean stored in the model: those two truths will sooner or later divorce, and the shape after the divorce is
    /// "the switch says charge, the number is 0" — and the recipient gets a card they must unlock but that collects no money.
    private var unlockCreditsText: Binding<String> {
        Binding(
            get: { model.unlockCredits > 0 ? String(model.unlockCredits) : "" },
            set: { text in
                // Digits only: a mid-typing `-`, a space or a mistyped letter all count as not finished yet and are treated as 0 (free),
                // rather than explaining a half-finished input as some other number. Past the cap it sticks to the cap, with that sentence written in the comment below.
                let digits = text.filter(\.isNumber)
                let entered = Int(digits) ?? 0
                model.unlockCredits = min(entered, PopopxCommerceLimits.maximumCreditsThreshold)
            }
        )
    }

    // MARK: Text, image and video blocks

    private var blocksSection: some View {
        PopopxSectionCard(Copy.blocksGroup, footnote: model.blocksFootnote) {
            if model.entries.isEmpty {
                Text(Copy.emptyBlocks)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.entries) { entry in
                    blockRow(entry)
                    if entry.index < model.entries.count - 1 {
                        PopopxBuilderDivider()
                    }
                }
            }
            Text(model.deliveryHint)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.meshInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, PopopxMetrics.spaceXS)
            if model.mediaBusy {
                HStack(spacing: PopopxMetrics.spaceXS) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PopopxPalette.brand)
                    Text(Copy.mediaBusy)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                    Spacer(minLength: PopopxMetrics.spaceXS)
                }
                .padding(.top, PopopxMetrics.spaceXS)
            }
        }
    }

    @ViewBuilder private func blockRow(_ entry: ProfileBuilderBlockEntry) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            HStack(spacing: PopopxMetrics.space2XS) {
                Text(Copy.blockTitle(entry))
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                PopopxBuilderIconButton(
                    systemImage: "arrow.up",
                    label: Copy.moveUp,
                    disabled: entry.index == 0
                ) { model.reorder(entry.id, by: -1) }
                PopopxBuilderIconButton(
                    systemImage: "arrow.down",
                    label: Copy.moveDown,
                    disabled: entry.index == model.entries.count - 1
                ) { model.reorder(entry.id, by: 1) }
                PopopxBuilderIconButton(
                    systemImage: "trash",
                    label: Copy.removeBlock,
                    tint: .danger,
                    disabled: false
                ) { model.delete(entry.id) }
            }
            switch entry.block {
            case .text:
                // Two unobtrusive facts about `PopopxTextArea` are routed around here: its `label` never renders, it only goes into
                // `.accessibilityLabel` (PopopxControls.swift:283), so the block title is drawn by the row above;
                // And its line count is hard-coded as `lineLimit(3...8)` (PopopxControls.swift:271),
                // so a long bio starts scrolling internally after line 8; this page is not going to re-copy the control for it.
                PopopxTextArea(
                    Copy.blockTextA11y(entry.index + 1),
                    prompt: Copy.textPrompt,
                    text: model.textBinding(for: entry.id)
                )
            case let .image(media), let .video(media):
                mediaRow(media)
            }
        }
        .padding(.vertical, PopopxMetrics.space2XS)
    }

    private func mediaRow(_ media: PopopxProfileMedia) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            PopopxProfileImageTile(url: model.mediaURLs[media.mediaId], kind: media.kind)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(Copy.kind(media.kind))
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                Text(mediaMetaLine(media))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            }
            Spacer(minLength: PopopxMetrics.spaceXS)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The meta info reports only the two fields that really exist in the manifest. When the thumbnail cannot be decoded it does not write "original missing": size and duration never depend
    /// on a successful decode, so reporting a missing file would be a lie, and the real missing check runs on the reader side via `loadMedia`.
    private func mediaMetaLine(_ media: PopopxProfileMedia) -> String {
        var parts: [String] = []
        if let seconds = media.durationSeconds {
            parts.append(PopopxSecureCopy.duration(seconds))
        }
        parts.append(ProfileBuilderViewModel.sizeText(media.bytes))
        return parts.joined(separator: " · ")
    }

    // MARK: Add

    private var addSection: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            PopopxButton(Copy.addText, systemImage: "text.badge.plus", role: .secondary) {
                model.addTextBlock()
            }
            .accessibilityLabel(Copy.addTextFull)
            .accessibilityIdentifier("popopx.profile.builder.addText")
            .disabled(!model.canAddBlock || model.mediaBusy)

            PopopxButton(Copy.addMedia, systemImage: "photo.on.rectangle.angled", role: .secondary) {
                showsLibrary = true
            }
            .accessibilityLabel(Copy.addMediaFull)
            .accessibilityIdentifier("popopx.profile.builder.addMedia")
            .disabled(!model.canAddBlock || model.mediaBusy)
        }
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    // MARK: Bottom fixed bar

    private var bottomBar: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            if let error = model.errorText {
                Label {
                    Text(error)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PopopxPalette.danger)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let notice = model.noticeText {
                Text(notice)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Label {
                Text(Copy.meshNote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(PopopxPalette.meshInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxButton(Copy.save, systemImage: "lock.shield.fill", isLoading: model.isSaving) {
                    await model.save()
                }
                .accessibilityIdentifier("popopx.profile.builder.save")
                .disabled(!model.canSave)
                PopopxButton(Copy.preview, systemImage: "eye", role: .secondary) {
                    openPreview()
                }
                .accessibilityIdentifier("popopx.profile.builder.preview")
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.top, PopopxMetrics.spaceS)
        .padding(.bottom, PopopxMetrics.spaceS)
        .background(PopopxMaterial.bar)
    }

    private func openPreview() {
        previewMode = model.sendMode
        previewDelivery = .fullMedia
        showsPreview = true
    }

    // MARK: Photo album

    private var libraryPicker: some View {
        LibraryMediaListPicker(
            addMedia: { content in await model.receivePicked(content) },
            selectionLimit: 1
        ) { _ in
            await MainActor.run { showsLibrary = false }
        }
    }

    // MARK: Secure preview Sheet

    private var previewSheet: some View {
        let payload = PopopxProfilePayload(manifest: model.previewManifest(sendMode: previewMode, delivery: previewDelivery))
        return PopopxSheetContainer(Copy.previewTitle, subtitle: Copy.previewSubtitle) {
            PopopxProfileCloseButton { showsPreview = false }
            PopopxSectionCard(Copy.previewModeGroup) {
                PopopxProfileModeSegment(
                    selection: $previewMode,
                    identifier: "popopx.profile.builder.previewModeSegment"
                )
                if previewMode == .ephemeral {
                    PopopxBuilderDivider()
                    Text(Copy.previewTTL(PopopxSecureCopy.duration(payload.manifest.ttlSeconds)))
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(Copy.previewStandard)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            PopopxSectionCard(Copy.previewDeliveryGroup) {
                PopopxSegmentedControl(
                    [PopopxProfileDelivery.fullMedia, .meshTextOnly].map {
                        PopopxSegmentedControl<PopopxProfileDelivery>.Option(selection: $0, title: $0.badgeLabel)
                    },
                    title: \.badgeLabel,
                    selection: $previewDelivery
                )
                .accessibilityIdentifier("popopx.profile.builder.previewDelivery")
                Text(payload.manifest.deliveryMode.badgeLabel)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .padding(.top, PopopxMetrics.space2XS)
            }
            PopopxSectionCard(Copy.previewBodyGroup, footnote: footnote(for: payload)) {
                Text(payload.degradeLine)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, PopopxMetrics.spaceXS)
                PopopxProfileBlockRenderer(blocks: payload.manifest.blocks, mediaURLs: model.mediaURLs)
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The row at the bottom of the preview: over Mesh it reports how many were saved, online it reports the countdown basis. Both are real values from the manifest, not adjectives.
    private func footnote(for payload: PopopxProfilePayload) -> String {
        if payload.manifest.deliveryMode == .meshTextOnly {
            return String(format: Copy.previewOmittedFormat, payload.manifest.omittedMediaCount)
        }
        return payload.ttlText
    }

    private var loadingCard: some View {
        PopopxSectionCard(Copy.pageTitle) {
            HStack(spacing: PopopxMetrics.spaceS) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(PopopxPalette.brand)
                Text(Copy.loading)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .frame(minHeight: PopopxMetrics.minHitTarget)
        }
    }
}

// MARK: - Send confirmation Sheet

/// The lightweight confirmation opened by "Personal profile" in the chat input bar's "+" panel.
///
/// It only reads the saved profile, and the only thing it changes is **this one** send's `sendMode`/`ttlSeconds`: it never writes `manifest.json`,
/// so sending a view-once copy from the chat does not alter the profile's own standing settings (those belong to the builder).
/// dismiss and detents are both owned by the caller (the same ruling as `PopopxQRCardSheet.swift:13-15`).
@MainActor
struct ProfileSendModeSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let store: ProfileStorageManager
    private let onSend: (_ manifest: PopopxProfileManifest) -> Void

    @State private var draft: PopopxProfileManifest?
    @State private var isLoading = true
    @State private var sendMode: PopopxProfileSendMode = .standard
    @State private var ttlSeconds = ProfileBuilderViewModel.defaultEphemeralTTL
    @State private var errorText: String?

    init(
        store: ProfileStorageManager = .shared,
        onSend: @escaping (_ manifest: PopopxProfileManifest) -> Void
    ) {
        self.store = store
        self.onSend = onSend
    }

    var body: some View {
        PopopxSheetContainer(Copy.sendTitle, subtitle: Copy.sendSubtitle) {
            PopopxProfileCloseButton { dismiss() }
            summaryCard
            PopopxSectionCard(Copy.sendModeGroup) {
                PopopxProfileModeSegment(
                    selection: $sendMode,
                    identifier: "popopx.profile.sendSheet.modeSegment"
                )
                if sendMode == .ephemeral {
                    PopopxBuilderDivider()
                    PopopxProfileTTLSegment(
                        selection: $ttlSeconds,
                        identifier: "popopx.profile.sendSheet.ttlSegment"
                    )
                }
                Text(modeNote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, PopopxMetrics.space2XS)
            }
            if let blocked = blockedNote {
                PopopxSectionCard(Copy.sendBlockedGroup) {
                    Text(blocked)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let error = errorText {
                Label {
                    Text(error)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PopopxPalette.danger)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PopopxMetrics.gutter)
            }
        } footer: {
            PopopxButton(Copy.sendAction, systemImage: "paperplane.fill") {
                send()
            }
            .accessibilityIdentifier("popopx.profile.sendSheet.send")
            .disabled(!canSend)
            .padding(PopopxMetrics.spaceM)
        }
        // The saved profile is read only when it opens: the chat input bar builds this Sheet only after the user presses "Personal profile",
        // so it always gets whatever was on disk at the moment of the press. `.task` is cancelled automatically when the Sheet disappears, no onDisappear cleanup needed.
        .task { await load() }
    }

    private func load() async {
        let saved = await store.loadEditable()
        draft = saved
        if let saved {
            sendMode = saved.sendMode
            ttlSeconds = saved.sendMode == .ephemeral
                ? (ProfileBuilderViewModel.ttlChoices.contains(saved.ttlSeconds)
                    ? saved.ttlSeconds
                    : ProfileBuilderViewModel.defaultEphemeralTTL)
                : ProfileBuilderViewModel.defaultEphemeralTTL
        }
        errorText = nil
        isLoading = false
    }

    /// The current profile cell. When nothing was ever saved the whole cell is absent: that "first build and save it in Me → Encrypted personal profile" line is said once by the
    /// "Can't send for now" cell below; saying the same sentence in two places on one page makes users think there are two different problems.
    @ViewBuilder private var summaryCard: some View {
        if let draft {
            PopopxSectionCard(Copy.sendSummaryGroup) {
                Text(draft.title.isEmpty ? Copy.untitled : draft.title)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let subtitle = draft.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(PopopxType.secondary)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(String(
                    format: Copy.sendSummaryFormat,
                    draft.blocks.count,
                    draft.blocks.filter { $0.media?.kind == .image }.count,
                    draft.blocks.filter { $0.media?.kind == .video }.count
                ))
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .padding(.top, PopopxMetrics.space2XS)
            }
        } else if isLoading {
            PopopxSectionCard(Copy.sendSummaryGroup) {
                HStack(spacing: PopopxMetrics.spaceS) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PopopxPalette.brand)
                    Text(Copy.loading)
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                    Spacer(minLength: PopopxMetrics.spaceXS)
                }
                .frame(minHeight: PopopxMetrics.minHitTarget)
            }
        }
    }

    private var canSend: Bool {
        guard !isLoading, let draft else { return false }
        return !draft.blocks.isEmpty
    }

    /// The disabled-state explanation line: the two kinds of "can't send" get two different wordings, and merging them into one sentence makes the user guess what differs.
    private var blockedNote: String? {
        guard !isLoading else { return nil }
        guard let draft else { return Copy.sendMissingNote }
        return draft.blocks.isEmpty ? Copy.sendEmptyNote : nil
    }

    private var modeNote: String {
        switch sendMode {
        case .standard: return Copy.standardNote
        case .ephemeral: return Copy.ephemeralNote
        }
    }

    private func send() {
        guard var copy = draft else { return }
        errorText = nil
        copy.sendMode = sendMode
        copy.ttlSeconds = sendMode == .ephemeral && ProfileBuilderViewModel.ttlChoices.contains(ttlSeconds)
            ? ttlSeconds
            : 0
        copy.deliveryMode = .fullMedia
        do {
            // It goes through the single gate on the send side: `make` validates first and then normalizes, so what is handed over is exactly the manifest that will hit the network.
            let payload = try PopopxProfilePayload.make(copy)
            onSend(payload.manifest)
        } catch {
            let reason: String
            switch error {
            case let failure as PopopxProfileError: reason = failure.reasonText
            case let failure as PopopxProfileMediaError: reason = failure.reasonText
            default: reason = String(format: Copy.unexpectedFormat, error.localizedDescription)
            }
            errorText = reason
            logger.error("POPOPX profile send sheet: failed to build payload: \(reason, privacy: .public)")
            PopopxHaptics.notice(.error)
        }
    }
}

// MARK: - Read-only rendering of the blocks

/// Block content → UI. The secure preview uses precisely this part: one rendering logic, two kinds of input (the draft's blocks, the blocks the peer sent),
/// and no second copy of the UI. The original's address comes from the caller; this layer knows nothing about storage.
private struct PopopxProfileBlockRenderer: View {
    let blocks: [PopopxProfileBlock]
    let mediaURLs: [String: URL]

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            if blocks.isEmpty {
                Text(Copy.previewEmptyBody)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .text(body):
                    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        Text(Copy.emptyTextBlock)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelHint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(trimmed)
                            .font(PopopxType.body)
                            .foregroundStyle(PopopxPalette.label)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .image(media):
                    PopopxProfileImageTile(
                        url: mediaURLs[media.mediaId],
                        kind: .image,
                        layout: .body
                    )
                case let .video(media):
                    PopopxProfileImageTile(
                        url: mediaURLs[media.mediaId],
                        kind: .video,
                        layout: .body
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Thumbnails

/// The little tile of a media block that is visible on this device. Decoding leaves the main thread: a 2 MB JPEG and a 640×480 video track
/// should not occupy that frame while the list is scrolling.
private struct PopopxProfileImageTile: View {
    enum Layout {
        /// The square patch inside the editing area.
        case thumb
        /// The tile in the preview body that spreads out at the original image's aspect ratio.
        case body
    }

    private static let thumbSide: CGFloat = PopopxMetrics.spaceXL * 3
    private static let bodyPlaceholderHeight: CGFloat = PopopxMetrics.space2XL * 3
    private static let bodyMaxPixelSide: CGFloat = 480
    /// Which second of the video to take a frame from: 0.5 s dodges the black first frame and does not require the asset to be longer than half a second.
    private static let posterSeconds: Double = 0.5

    let url: URL?
    let kind: PopopxProfileMedia.Kind
    var layout: Layout = .thumb

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                switch layout {
                case .thumb:
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.thumbSide, height: Self.thumbSide)
                        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusChip, style: .continuous))
                case .body:
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
                }
            } else {
                placeholder
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: layout == .thumb ? PopopxMetrics.radiusChip : PopopxMetrics.radiusControl)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        // A decode failure leaves only an icon behind: the size and duration meta info comes from the manifest and does not depend on whether this frame can be drawn,
        // so this does not claim "original missing".
        .task(id: url) { image = await Self.decode(url: url, kind: kind) }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var placeholder: some View {
        switch layout {
        case .thumb:
            ZStack {
                PopopxPalette.separator
                Image(systemName: kind == .video ? "play.rectangle.fill" : "photo")
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelHint)
            }
            .frame(width: Self.thumbSide, height: Self.thumbSide)
            .clipShape(.rect(cornerRadius: PopopxMetrics.radiusChip, style: .continuous))
        case .body:
            ZStack {
                PopopxPalette.separator
                Label {
                    Text(Copy.kind(kind)).font(PopopxType.caption)
                } icon: {
                    Image(systemName: kind == .video ? "play.rectangle.fill" : "photo")
                }
                .foregroundStyle(PopopxPalette.labelHint)
            }
            .frame(maxWidth: .infinity, minHeight: Self.bodyPlaceholderHeight)
            .clipShape(.rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
        }
    }

    private static func decode(url: URL?, kind: PopopxProfileMedia.Kind) async -> UIImage? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) {
            switch kind {
            case .image:
                return UIImage(contentsOfFile: url.path)
            case .video:
                return await poster(of: url)
            }
        }.value
    }

    /// Video cover: `AVAssetImageGenerator.image(at:)` is the non-deprecated async path on iOS 17,
    /// with the size squeezed to under 480 - the patch has no use for the original's resolution.
    private static func poster(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: bodyMaxPixelSide, height: bodyMaxPixelSide)
        let at = CMTime(seconds: posterSeconds, preferredTimescale: 600)
        guard let result = try? await generator.image(at: at) else { return nil }
        return UIImage(cgImage: result.image)
    }
}

// MARK: - The two-mode segmented control

/// The top-level dual-mode segmented control.
///
/// ⚠ The two labels come only out of the `title:` closure: what `PopopxSegmentedControl` draws is
/// `Text(title(option.selection))` (PopopxControls.swift:581), and the `Option.title` field is never
/// read from start to finish. So `Option.title` is only a note for humans; what actually reaches the screen is the closure.
private struct PopopxProfileModeSegment: View {
    let selection: Binding<PopopxProfileSendMode>
    let identifier: String

    var body: some View {
        PopopxSegmentedControl(
            // Standing stays on the left: `PopopxProfileManifest.blank()` defaults to that tier (PersonalProfileModel.swift:192-208),
            // and a skeleton with no content yet should not default to carrying "how long after opening it is destroyed".
            [PopopxProfileSendMode.standard, .ephemeral].map {
                PopopxSegmentedControl<PopopxProfileSendMode>.Option(selection: $0, title: $0.sheetLabel)
            },
            title: \.sheetLabel,
            selection: selection
        )
        .accessibilityIdentifier(identifier)
    }
}

/// The read-validity segmented control. Neither the values nor the labels of the three tiers are rewritten locally: values come from `PopopxProfilePayload.ttlOptions`,
/// and labels come from `PopopxSecureCopy.duration` - the only place in the whole app that formats durations.
private struct PopopxProfileTTLSegment: View {
    let selection: Binding<Int>
    let identifier: String

    var body: some View {
        PopopxSegmentedControl(
            ProfileBuilderViewModel.ttlChoices.map {
                PopopxSegmentedControl<Int>.Option(selection: $0, title: PopopxSecureCopy.duration($0))
            },
            title: { PopopxSecureCopy.duration($0) },
            selection: selection
        )
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Inline small parts

/// The divider inside the card. The identically named one at `PopopxControls.swift:853` sits only inside the `#if DEBUG` gallery, out of reach.
private struct PopopxBuilderDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

/// The icon button in the block row header. The whole thing is a `Button`, 44pt is backed by `minHitTarget`, and the accessibility label uses the full Chinese wording.
private struct PopopxBuilderIconButton: View {
    private let systemImage: String
    private let label: String
    private let tint: PopopxIconTint
    private let disabled: Bool
    private let action: () -> Void

    init(
        systemImage: String,
        label: String,
        tint: PopopxIconTint = .neutral,
        disabled: Bool,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = label
        self.tint = tint
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(PopopxType.meta)
                .foregroundStyle(ink)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(Text(verbatim: label))
    }

    /// The ink color of the neutral tier as it lands on the card: `labelHint` is 3.42:1, enough only for decoration; this one is a thing you press.
    private var ink: Color {
        switch tint {
        case .brand: PopopxPalette.brand
        case .mesh: PopopxPalette.meshInk
        case .danger: PopopxPalette.dangerInk
        case .success: PopopxPalette.successInk
        case .neutral: PopopxPalette.labelSecondary
        }
    }
}

/// The close button inside the Sheet. `PopopxSheetContainer` carries no header bar of its own (the ruling at PopopxControls.swift:715-717
/// says dismissal belongs to the caller), so this page supplies its own button, written the same way as `PopopxQRCardSheet.swift:174-182`.
private struct PopopxProfileCloseButton: View {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Spacer(minLength: PopopxMetrics.spaceXS)
            PopopxButton(Copy.close, systemImage: "xmark", role: .secondary, fullWidth: false, action: action)
        }
        .padding(.horizontal, PopopxMetrics.gutter)
    }
}

// MARK: - Copy

/// Every Chinese sentence on the two pages appears exactly once, here. The two product-mandated verbatim lines (`standardNote`, `meshNote`)
/// and the two mode labels of `PopopxProfileSendMode.sheetLabel` all appear only in this one place,
/// so they cannot fork away from the payload layer's two lines of text.
private enum Copy {
    static let pageTitle = NSLocalizedString("My encrypted profile page", comment: "")
    static let loading = NSLocalizedString("Reading the profile saved on this device…", comment: "")
    static let close = NSLocalizedString("Close", comment: "")

    // Identity section
    static let identityGroup = NSLocalizedString("Identity", comment: "")
    static let titleLabel = NSLocalizedString("Profile title", comment: "")
    static let titlePrompt = NSLocalizedString("The big line on the card", comment: "")
    static let subtitleLabel = NSLocalizedString("Subtitle", comment: "")
    static let subtitlePrompt = NSLocalizedString("Optional: one line about yourself", comment: "")
    static let titleCountFormat = NSLocalizedString("Title %1$lld / %2$lld characters", comment: "")
    static let noticeNoDraft = NSLocalizedString("No profile has been saved on this device yet. What is below stays only after you tap Save profile for the first time.", comment: "")

    // Sending permission and destruction policy
    static let policyGroup = NSLocalizedString("Sending permission and destruction policy", comment: "")
    static let standardNote = NSLocalizedString("Friends keep no destruction timer: they can open your text, images and video as often as they like.", comment: "")
    static let ephemeralNote = NSLocalizedString("The reading window starts counting when the friend opens it; when it ends, the content on this device and the image and video originals are destroyed together.", comment: "")
    static let ttlLabel = NSLocalizedString("Reading window", comment: "")
    static let antiSpyToggle = NSLocalizedString("Force on the anti-peeping camera check", comment: "")
    static let antiSpyNote = NSLocalizedString("Only takes effect in burn-after-reading: the front camera check starts on their device when they open it, and the camera permission is requested by their device at that moment.", comment: "")

    // Viewing threshold (credits)
    static let thresholdLabel = NSLocalizedString("Viewing threshold", comment: "")
    static let thresholdField = NSLocalizedString("Compute Credits", comment: "")
    static let thresholdPrompt = NSLocalizedString("Empty = free to view", comment: "")
    static func thresholdNote(_ maximum: Int) -> String {
        String(format: NSLocalizedString("They see this number first when they open the card, and it is only then taken from the balance on their own device. Empty or 0 is free to view; the limit is %lld and a larger number snaps to it. The threshold travels with the card - neither side of POPOPX can change it for them.", comment: ""), maximum)
    }

    // Images, text and video
    static let blocksGroup = NSLocalizedString("Text, images and video", comment: "")
    static let blocksCountFormat = NSLocalizedString("Blocks %1$lld / %2$lld · Images %3$lld · Videos %4$lld", comment: "")
    static let emptyBlocks = NSLocalizedString("No content blocks yet. Add a text block first, then images and video.", comment: "")
    static let addText = NSLocalizedString("Text", comment: "")
    static let addMedia = NSLocalizedString("Image / video", comment: "")
    static let addTextFull = NSLocalizedString("Add text block", comment: "")
    static let addMediaFull = NSLocalizedString("Add image or video block", comment: "")
    static let textPrompt = NSLocalizedString("Write a short introduction", comment: "")
    static let mediaBusy = NSLocalizedString("Compressing images and converting video…", comment: "")
    static let moveUp = NSLocalizedString("Move up", comment: "")
    static let moveDown = NSLocalizedString("Move down", comment: "")
    static let removeBlock = NSLocalizedString("Delete this block", comment: "")
    static let kindImage = NSLocalizedString("Image", comment: "")
    static let kindVideo = NSLocalizedString("Video", comment: "")
    static let emptyTextBlock = NSLocalizedString("(Empty text block)", comment: "")

    // Bottom fixed bar
    static let meshNote = NSLocalizedString("In offline Bluetooth Mesh mode images and video are filtered out automatically; only the fast text-only encrypted card is pushed.", comment: "")
    static let deliveryHintTextOnly = NSLocalizedString("This profile is text only, so the online and the offline Bluetooth Mesh paths send exactly the same thing.", comment: "")
    static let deliveryHintMediaFormat = NSLocalizedString("This profile has %lld image or video blocks: they are skipped automatically on the offline Bluetooth Mesh path, which sends the text-only version.", comment: "")
    static let save = NSLocalizedString("Save profile", comment: "")
    static let preview = NSLocalizedString("Safe preview", comment: "")
    static let savedToast = NSLocalizedString("Saved on this device", comment: "")
    static let mediaAddedFormat = NSLocalizedString("Added %1$@ (%2$@); it enters the manifest only when you tap Save profile", comment: "")

    // Secure preview
    static let previewTitle = NSLocalizedString("Safe preview", comment: "")
    static let previewSubtitle = NSLocalizedString("What the same content sends out under the four combinations; the draft is left untouched.", comment: "")
    static let previewModeGroup = NSLocalizedString("Sending mode", comment: "")
    static let previewDeliveryGroup = NSLocalizedString("Network mode", comment: "")
    static let previewBodyGroup = NSLocalizedString("What they can see", comment: "")
    static func previewTTL(_ duration: String) -> String {
        String(format: NSLocalizedString("Counting %@ from the moment they open it; when it ends, this local copy is destroyed.", comment: ""), duration)
    }
    static let previewStandard = NSLocalizedString("Standing card: they can open it again and again, with no countdown and no camera check.", comment: "")
    static let previewOmittedFormat = NSLocalizedString("This send skips %lld image or video blocks and sends the text-only version.", comment: "")
    static let previewEmptyBody = NSLocalizedString("No content blocks to show in this combination.", comment: "")

    // Send confirmation Sheet
    static let sendTitle = NSLocalizedString("Send your profile", comment: "")
    static let sendSubtitle = NSLocalizedString("Confirm these two settings before sending; the saved profile is not changed by this.", comment: "")
    static let sendSummaryGroup = NSLocalizedString("Current profile", comment: "")
    static let sendModeGroup = NSLocalizedString("This send", comment: "")
    static let sendBlockedGroup = NSLocalizedString("Cannot send right now", comment: "")
    static let sendAction = NSLocalizedString("Send", comment: "")
    static let untitled = NSLocalizedString("Untitled profile", comment: "")
    static let sendSummaryFormat = NSLocalizedString("Blocks %1$lld · Images %2$lld · Videos %3$lld", comment: "")
    static let sendMissingNote = NSLocalizedString("No profile has been saved on this device yet. Make one in Me → My encrypted profile page and save it, then come back to send.", comment: "")
    static let sendEmptyNote = NSLocalizedString("This profile has no content blocks yet; add text, an image or a video before you can send it.", comment: "")

    // Fallback sentence: it is only ever said when a non-typed error is actually hit.
    static let unexpectedFormat = NSLocalizedString("Action not completed: %@", comment: "")

    static func kind(_ kind: PopopxProfileMedia.Kind) -> String {
        switch kind {
        case .image: return kindImage
        case .video: return kindVideo
        }
    }

    static func blockTitle(_ entry: ProfileBuilderBlockEntry) -> String {
        let position = entry.index + 1
        switch entry.block {
        case .text: return String(format: NSLocalizedString("Text block %lld", comment: ""), position)
        case .image: return String(format: NSLocalizedString("Image %lld", comment: ""), position)
        case .video: return String(format: NSLocalizedString("Video %lld", comment: ""), position)
        }
    }

    static func blockTextA11y(_ position: Int) -> String {
        String(format: NSLocalizedString("Body of text block %lld", comment: ""), position)
    }
}

// MARK: - Previews

#if DEBUG
struct ProfileBuilderView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ProfileBuilderView()
        }
    }
}

struct ProfileSendModeSheet_Previews: PreviewProvider {
    static var previews: some View {
        ProfileSendModeSheet { _ in }
            .padding(.horizontal, PopopxMetrics.space2XS)
    }
}
#endif
