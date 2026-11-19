//
//  ProfileBuilderView.swift
//  POPOPX (iOS)
//
//  【加密个人主页 · 模块二】制作器，和聊天「+」面板里那个轻量发送确认 Sheet。
//
//  三个类型，三种职责：
//
//  1. `ProfileBuilderViewModel` —— 本机草稿的唯一可编辑状态。载入走 `loadEditable()`，写回走
//     会抛错的 `saveEditable(_:)`；块的增删排序、图片/视频导入、失败原因的上屏都只在这一个类里。
//  2. `ProfileBuilderView` —— 制作器的版式。自己不带栈（`PopopxMeView.swift:10` 那条同一条规矩：
//     NavigationStack 由调用方统一包），底部那一横条是固定的：双模网络提示 + 保存 + 安全预览。
//  3. `ProfileSendModeSheet` —— 发送前那一次选择。它只读已保存的主页，改的是**这一次**的模式，
//     永远不回写 `manifest.json`。
//
//  ### 这一页里三件不显眼但要紧的事
//
//  1. **保存就是发送侧那道门**。`ProfileStorageManager.saveEditable(_:)` 先跑
//     `PopopxProfilePayload.make`（ProfileStorageManager.swift:257-261），所以一份存得下来的草稿
//     一定发得出去；反过来说，标题超限、块数超标、隐私档时长越界都会在这里以 `reasonText` 的
//     原话弹回来，界面上不许自己再造第二套句子。
//  2. **草稿的 `deliveryMode` 恒为 `.fullMedia`**。送达方式是发送那一刻由链路决定的，不是内容的
//     属性；草稿一旦带上 `.meshTextOnly`，`normalized()` 就会把用户的图文视频整批抹掉
//     （PersonalProfileModel.swift:247-261），而 `saveEditable` 写的正是传进去的那一份。
//  3. **更新内容不需要重新生成任何二维码**。`profileId` 只在第一次制作时生成、之后每次保存都
//     沿用同一个（见下面 `profileId` 那一行），而它是媒体目录的分格键、也是主页分发所指向的那个
//     稳定标识（PersonalProfileModel.swift:177），所以内容改动不动它。
//
//  配色、字号、圆角、间距一律取 Shared/Theme/PopopxTheme.swift 的 token；控件只用
//  Shared/Components 里已有的原子库。页面里每一句中文只在本文件的 `Copy` 出现一次。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖进 POPOPX (iOS) target —— 铁律禁止脚本改 project.pbxproj。
//

import AVFoundation
import SwiftUI
import UIKit

// MARK: - 块的稳定身份

/// `ForEach` 用的一行快照：稳定 id + 当前下标 + 内容。
/// id 不是下标也不是内容：下标在上下移动后会指向另一块内容，正在输入的那一格会跟着跳走；
/// 用内容当 id 则每敲一个字就是一次换身份。
struct ProfileBuilderBlockEntry: Identifiable {
    let id: UUID
    let index: Int
    let block: PopopxProfileBlock
}

// MARK: - 制作器状态

@MainActor
@Observable
final class ProfileBuilderViewModel {
    /// 隐私档可选的三档时长。值只在 `PopopxProfilePayload.ttlOptions`
    /// （PersonalProfileModel.swift:363）里定义一遍，这里不抄第二张表。
    static let ttlChoices: [Int] = PopopxProfilePayload.ttlOptions

    /// 隐私档的默认时长：三档的中间那一档；表被改空时退到协议下限，而不是硬编一个 300。
    static var defaultEphemeralTTL: Int {
        ttlChoices.isEmpty ? PopopxProfilePayload.minimumTTLSeconds : ttlChoices[ttlChoices.count / 2]
    }

    /// 相册交回来的 `UIImage` 先按这个质量编一次 JPEG。真正的压档（像素/质量两张梯子）在存储层，
    /// 那一张表归 `ProfileStorageManager`，这里只是把 `UIImage` 变成它能吃的字节。
    private static let pickedImageJPEGQuality: CGFloat = 0.9

    // MARK: 可编辑状态（视图直接绑这几格）

    var title = ""
    var subtitle = ""
    var enableAntiSpyCamera = false
    /// 查看这份主页要收的算力点，0 = 免费。视图直接绑它（和上面那格同一个做法），落进清单时 0 变 nil。
    ///
    /// 这里没有"能不能收这个价"的校验：钱的边界在 `PopopxCreditsManager.unlockProfile` 那一侧，
    /// 制作器只负责把用户选的数原样带出去。
    var unlockCredits = 0

    // MARK: 只读状态

    private(set) var blocks: [PopopxProfileBlock] = []
    private(set) var blockIDs: [UUID] = []
    private(set) var sendMode: PopopxProfileSendMode = .standard
    private(set) var ttlSeconds = 0
    /// 媒体块在本机的原件地址（key = `mediaId`）。导入时、载入时各填一次，于是渲染那一段代码
    /// 不必为了拿一个路径而每帧去问一次 actor。
    private(set) var mediaURLs: [String: URL] = [:]
    private(set) var isReady = false
    private(set) var isSaving = false
    private(set) var mediaBusy = false
    private(set) var errorText: String?
    private(set) var noticeText: String?

    /// 回执由模型持有，视图只负责挂（`PopopxToast.swift:133` 那条要求挂在整屏最高处）。
    let toast = PopopxToastModel()

    private let store: ProfileStorageManager
    /// 一生成就固定下来，之后每次保存都沿用同一个：内容改动不动它，
    /// 所以按 `profileId` 分发的入口（主页二维码、媒体目录）不需要因为改内容而重建。
    private var profileId: String
    /// 切到常驻档会把 `ttlSeconds` 归零（协议只接受 0，PersonalProfileModel.swift:400-401），
    /// 但用户上一次选的时长要留下来：反复切模式不该悄悄改掉他的隐私设置。
    private var rememberedEphemeralTTL: Int

    init(store: ProfileStorageManager = .shared) {
        self.store = store
        self.profileId = PopopxProfileManifest.blank().profileId
        self.rememberedEphemeralTTL = Self.defaultEphemeralTTL
        // 草稿在那枚 actor 上读，不占主线程。读完之前界面是加载态（`isReady`），
        // 于是不存在"用户先敲了字、随后被盘上那一份覆盖掉"这一种竞态。
        Task { [weak self] in
            guard let self else { return }
            await self.loadDraft()
        }
    }

    // MARK: 派生的话

    var mediaCount: Int { blocks.reduce(0) { $0 + $1.mediaCount } }
    var imageCount: Int { blocks.filter { $0.media?.kind == .image }.count }
    var videoCount: Int { blocks.filter { $0.media?.kind == .video }.count }

    /// 还能不能再加一块。上限 24 是 `make` 说了算的，界面先把门关上，让用户听见的是同一句话。
    var canAddBlock: Bool { blocks.count < PopopxProfilePayload.maximumBlocks }
    var canSave: Bool { isReady && !isSaving && !mediaBusy }

    /// 身份卡下面那一行。超限时直接把协议层的原话当提示，不另造一句更轻的：
    /// 用户在这里看到的和保存失败时看到的是同一条。
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

    /// 模式卡片里那一行说明。常驻档那一句是产品规定的原话；隐私档那一句把计时起点说死，
    /// 因为"打开后才开始计时"正是这一档和常驻档唯一区别得清的地方。
    var policyNote: String {
        switch sendMode {
        case .standard: return Copy.standardNote
        case .ephemeral: return Copy.ephemeralNote
        }
    }

    /// 这一份草稿将来走 Mesh 会少掉什么。送达方式不在本页选（见 `draftManifest()` 那段注释），
    /// 所以这里只报"会省几个"，不给用户一个其实由链路决定的开关。
    var deliveryHint: String {
        mediaCount == 0 ? Copy.deliveryHintTextOnly : String(format: Copy.deliveryHintMediaFormat, mediaCount)
    }

    // MARK: 载入

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
        // 原样带回来，不贴档位：门槛是自定义数字，选择表里没有的合法值（比如 37）也是用户设过的决定，
        // 载入时悄悄改成 20 或 0 都是在改他的收费。真正的边界在扣点那一侧。
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

    // MARK: 模式与时长

    /// 选发送模式。不直接暴露属性的写入权，是因为两档对 `ttlSeconds` 的要求是相反的：
    /// 常驻档必须是 0（`make` 会拒任何非 0），隐私档必须落在三档里。
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

    // MARK: 块

    var entries: [ProfileBuilderBlockEntry] {
        zip(blockIDs, blocks).enumerated().map { pair in
            ProfileBuilderBlockEntry(id: pair.element.0, index: pair.offset, block: pair.element.1)
        }
    }

    /// 文字块的绑定。下标在每次读写时现算，所以上下移动之后这一格仍然指向它自己那块内容。
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
            // 删掉的原件必须立刻离开磁盘，哪怕代价是某一份**旧的**已保存清单可能指向一个已经不存在的
            // mediaId：`PopopxProfileMediaLoad.missing` 那一支就是为这种情况存在的，
            // 而"用户删了、原件还躺在沙盒里"在隐私功能里是更坏的那一种。
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

    /// 块数没到上限才让动作继续。满了就把协议那句原话顶到界面上，不静默拒绝。
    private func reserveBlockSlot() -> Bool {
        guard isReady, !mediaBusy else { return false }
        guard canAddBlock else {
            report(PopopxProfileError.tooManyBlocks(count: blocks.count), context: "add block")
            return false
        }
        return true
    }

    // MARK: 相册

    /// 选回来的东西。类型以真正选回来的 `UploadContent` 为准，而不是以按了哪个按钮为准：
    /// app 唯一那枚相册包装件的默认 filter 同时放行图片与视频（ImagePicker.swift:37），
    /// 所以"添加图片"和"添加视频"在实现上是同一个动作，摆两个按钮才是撒谎。
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
        // 只有 `UIImage` 可用：那条包装链路对任何能解码的图都回 `.animatedImage`
        // （ComposeView.swift:337-352），原件 URL 拿不到，所以这里先编一次 JPEG 交给存储层。
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
            // 转码在那枚 actor 上跑，30 秒截断与 15 MB 预算都由它判；这里只等结果。
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
        // 导入不是保存：原件已经落盘，但清单还没写。这一句必须说出来，否则用户会以为
        // 关掉页面内容也留住了。haptic 走这里而不是走按钮：这条链路不在 `PopopxButton` 的动作里。
        PopopxHaptics.notice(.success)
        toast.show(
            String(format: Copy.mediaAddedFormat, Copy.kind(media.kind), Self.sizeText(media.bytes)),
            kind: .success
        )
    }

    // MARK: 保存

    /// 当前草稿的完整清单。`deliveryMode` 恒为 `.fullMedia`、`omittedMediaCount` 恒为 0：
    /// 那两格是发送时的事，让 `normalized()` 在这一份上看到 `.meshTextOnly` 就等于删用户的内容。
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
            // 0 存成 nil，而不是 JSON 里写一个 `unlockCredits: 0`：门槛这格"没写过"和"写过但等于零"
            // 在收件方那边必须给出完全相同的行为（直接打开），而所有老主页就是"没写过"那一档。
            unlockCredits: unlockCredits > 0 ? unlockCredits : nil,
            updatedAt: updatedAt,
            blocks: blocks
        )
    }

    /// 写回本机。失败一律以 typed error 的原话上屏。
    func save() async {
        guard canSave else { return }
        errorText = nil
        isSaving = true
        let manifest = draftManifest(updatedAt: Date().timeIntervalSince1970).normalized()
        do {
            try await store.saveEditable(manifest)
            // 成功这一路不再补 haptic：`PopopxButton` 在自己的 isBusy 落回 false 时已经
            // `notice(.success)`（PopopxControls.swift:171-178），这里再发一次就是两次反馈。
            toast.show(Copy.savedToast, kind: .success)
        } catch {
            report(error, context: "saveEditable")
        }
        isSaving = false
    }

    // MARK: 安全预览

    /// 预览用的投影，**不动草稿**。
    ///
    /// Mesh 那一档走 `textOnly` 再走 `normalized()`，和真实发送完全同一条路径：剔掉所有图片/视频块、
    /// 把剔掉的个数记进 `omittedMediaCount`、再按模式收敛一次不变量（PersonalProfileModel.swift:214-231）。
    /// 顺序不能反：`normalized()` 只把 `omittedMediaCount` 钳进值域，不会替谁算出真实个数。
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

    // MARK: 失败上屏

    /// typed error 的原话。`PopopxProfileError` 说协议层，`PopopxProfileMediaError` 说本机加工层，
    /// 两个都不许吞：吞掉一次失败，用户就会以为内容已经存好了。
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
        logger.error("POPOPX profile builder: \(context, privacy: .public) 失败：\(text, privacy: .public)")
        PopopxHaptics.notice(.error)
    }

    /// 体积只在这里格式化一次：全 app 的字节数都走 `ByteCountFormatter` 的 binary 档
    /// （CIVideoView.swift:320、CIFileView.swift:41 同一口径），错误句子里那两处 `bytes / 1_024` 归存储层。
    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

// MARK: - 制作器页面

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
            // 展开/收起隐私档那一格、以及块的增减：Reduce Motion 下直接落位。
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

    // MARK: 身份区

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

    // MARK: 发送权限与销毁策略

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
            // 收费门槛这一档不属于"隐私"那一族（它改变的是收件人要不要付钱，不是内容留多久），
            // 所以它不跟着 `sendMode == .ephemeral` 那一支走：常驻名片同样可以设门槛。
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

    /// 门槛数字框与模型之间只做一次换算：框里留空 = 模型里的 0 = 清单里的 nil。
    ///
    /// 刻意不在模型里再存一格"要不要收费"的布尔：那两处真值迟早会分家，而分家之后的形状是
    /// "开关说收费、数字是 0"——收件人那边就得到一个要点开却收不到钱的卡片。
    private var unlockCreditsText: Binding<String> {
        Binding(
            get: { model.unlockCredits > 0 ? String(model.unlockCredits) : "" },
            set: { text in
                // 只认数字：打字打到一半的 `-`、空格、误触的字母都当成还没写完，按 0（免费）处理，
                // 而不是把半截输入解释成别的数。超出上限就贴到上限，那句话写在下面的注释里。
                let digits = text.filter(\.isNumber)
                let entered = Int(digits) ?? 0
                model.unlockCredits = min(entered, PopopxCommerceLimits.maximumCreditsThreshold)
            }
        )
    }

    // MARK: 图文视频块

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
                // `PopopxTextArea` 有两个不显眼的事实，都在这里绕过去：它的 `label` 不上屏、只进
                // `.accessibilityLabel`（PopopxControls.swift:283），所以块标题由上面那一行自己画；
                // 而它的行数是写死的 `lineLimit(3...8)`（PopopxControls.swift:271），
                // 长的自我介绍会在第 8 行之后开始内滚，这一页不打算为重抄一遍控件。
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

    /// 元信息只报 manifest 里真有的两格。缩略图解不出来时不写"原件缺失"：体积与时长都不依赖
    /// 解码成功，报缺失就成了撒谎，而真正的缺失判定在阅读器那一侧走 `loadMedia`。
    private func mediaMetaLine(_ media: PopopxProfileMedia) -> String {
        var parts: [String] = []
        if let seconds = media.durationSeconds {
            parts.append(PopopxSecureCopy.duration(seconds))
        }
        parts.append(ProfileBuilderViewModel.sizeText(media.bytes))
        return parts.joined(separator: " · ")
    }

    // MARK: 添加

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

    // MARK: 底部固定条

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

    // MARK: 相册

    private var libraryPicker: some View {
        LibraryMediaListPicker(
            addMedia: { content in await model.receivePicked(content) },
            selectionLimit: 1
        ) { _ in
            await MainActor.run { showsLibrary = false }
        }
    }

    // MARK: 安全预览 Sheet

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

    /// 预览底部那一行：Mesh 就报省了几个，在线就报倒计时口径。两条都是清单里的真值，不是形容词。
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

// MARK: - 发送确认 Sheet

/// 聊天输入栏「+」面板里"个人主页"点开的那一枚轻量确认。
///
/// 它只读已保存的主页，改的只有**这一次**的 `sendMode`/`ttlSeconds`：绝不写 `manifest.json`，
/// 所以从聊天里发一份阅后即焚版，不会把主页本身的常驻设置改掉（那归制作器）。
/// dismiss 与 detents 都由调用方拥有（同 `PopopxQRCardSheet.swift:13-15` 那条裁定）。
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
        // 打开时才去读那一份已保存的主页：这枚 Sheet 由聊天输入栏在用户按下"个人主页"之后才建出来，
        // 拿到的永远是按下那一刻磁盘上的内容。`.task` 随 Sheet 消失自动取消，不需要 onDisappear 收尾。
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

    /// 当前主页那一格。没保存过时整格不出现：那句"先在「我 → 加密个人主页」里做好并保存"由下面
    /// 「暂时发不了」那一格说一次就够，同一页两处说同一句话会让用户以为有两种不同的毛病。
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

    /// 禁用态那一行说明：两种"发不了"讲两种话，合成一句就等于让用户自己去猜差在哪。
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
            // 走发送侧那道唯一的门：`make` 先验后规范化，交出去的就是真正会上网络的那一份清单。
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
            logger.error("POPOPX profile send sheet: 组装载荷失败：\(reason, privacy: .public)")
            PopopxHaptics.notice(.error)
        }
    }
}

// MARK: - 块的只读渲染

/// 块内容 → 界面。安全预览用的就是这一段：同一份渲染逻辑，两种入参（草稿的块、对方送来的块），
/// 不复制第二份 UI。原件地址由调用方给，这一层不认识存储。
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

// MARK: - 缩略图

/// 一块媒体在本机看得见的那一小格。解码离开主线程：一张 2 MB 的 JPEG 与一段 640×480 的视频轨，
/// 都不该在列表滚起来的时候占住那一帧。
private struct PopopxProfileImageTile: View {
    enum Layout {
        /// 编辑区里那一枚方形贴片。
        case thumb
        /// 预览正文里按原图比例铺开的一格。
        case body
    }

    private static let thumbSide: CGFloat = PopopxMetrics.spaceXL * 3
    private static let bodyPlaceholderHeight: CGFloat = PopopxMetrics.space2XL * 3
    private static let bodyMaxPixelSide: CGFloat = 480
    /// 视频取第几秒的一帧：0.5 秒既躲开了首帧黑场，也不要求素材长于半秒。
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
        // 解码失败只留下一枚符号：体积与时长那些元信息来自清单，不依赖这一帧能不能画出来，
        // 所以这里不宣称"原件缺失"。
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

    /// 视频封面：`AVAssetImageGenerator.image(at:)` 是 iOS 17 上那条不废弃的异步路，
    /// 尺寸压到 480 以内 —— 贴片用不着原片的分辨率。
    private static func poster(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: bodyMaxPixelSide, height: bodyMaxPixelSide)
        let at = CMTime(seconds: posterSeconds, preferredTimescale: 600)
        guard let result = try? await generator.image(at: at) else { return nil }
        return UIImage(cgImage: result.image)
    }
}

// MARK: - 两个模式分段器

/// 顶层双模式分段器。
///
/// ⚠️ 两个标签只从 `title:` 那个闭包里出来：`PopopxSegmentedControl` 画的是
/// `Text(title(option.selection))`（PopopxControls.swift:581），`Option.title` 那一格从头到尾
/// 没有被读过。所以 `Option.title` 只是给人看的备注，真正上屏的是闭包。
private struct PopopxProfileModeSegment: View {
    let selection: Binding<PopopxProfileSendMode>
    let identifier: String

    var body: some View {
        PopopxSegmentedControl(
            // 常驻在左：`PopopxProfileManifest.blank()` 默认落在那一档（PersonalProfileModel.swift:192-208），
            // 一份还没写内容的骨架不该默认带上"打开后多久销毁"。
            [PopopxProfileSendMode.standard, .ephemeral].map {
                PopopxSegmentedControl<PopopxProfileSendMode>.Option(selection: $0, title: $0.sheetLabel)
            },
            title: \.sheetLabel,
            selection: selection
        )
        .accessibilityIdentifier(identifier)
    }
}

/// 阅读有效期分段器。三档的值和标签都不在本地重写：值来自 `PopopxProfilePayload.ttlOptions`，
/// 标签来自 `PopopxSecureCopy.duration` —— 全 app 的时长格式化只有那一处。
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

// MARK: - 行内小件

/// 卡片内的分隔线。`PopopxControls.swift:853` 那条同名的只在 `#if DEBUG` 的画廊里，够不着。
private struct PopopxBuilderDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

/// 块行头部的图标按钮。整颗是 `Button`，44pt 由 `minHitTarget` 兜住，无障碍标签用中文全称。
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

    /// 中性那一档落在卡片上的墨色：`labelHint` 是 3.42:1，只够装饰；这一颗是要按的东西。
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

/// Sheet 里那一枚关闭钮。`PopopxSheetContainer` 自己不带头部栏（PopopxControls.swift:715-717
/// 那条裁定：dismissal 归调用方），所以本页自己给一颗，写法同 `PopopxQRCardSheet.swift:174-182`。
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

// MARK: - 文案

/// 两个页面上每一句中文只在这里出现一次。两条产品规定的原话（`standardNote`、`meshNote`）
/// 与 `PopopxProfileSendMode.sheetLabel` 的两个模式标签都只在这一处出现一次，
/// 因此不会和载荷层那两行字分叉。
private enum Copy {
    static let pageTitle = "加密个人主页"
    static let loading = "正在读取本机主页…"
    static let close = "关闭"

    // 身份区
    static let identityGroup = "身份"
    static let titleLabel = "主页标题"
    static let titlePrompt = "名片上那一行大字"
    static let subtitleLabel = "副标题"
    static let subtitlePrompt = "可留空：一句话说明你自己"
    static let titleCountFormat = "标题 %d / %d 个字"
    static let noticeNoDraft = "本机还没有保存过的主页。下面的内容第一次点「保存主页」之后才会留下来。"

    // 发送权限与销毁策略
    static let policyGroup = "发送权限与销毁策略"
    static let standardNote = "好友接收后不设销毁时间，可随时频繁打开查看你的图文与视频。"
    static let ephemeralNote = "阅读有效期在好友点击打开后起计，到点后本机内容与图片、视频原件一并销毁。"
    static let ttlLabel = "阅读有效期"
    static let antiSpyToggle = "强制开启防窥防偷拍镜头检测"
    static let antiSpyNote = "只在阅后即焚时生效：对方打开阅读时才在其设备上启用前置镜头检测，摄像头权限由对方设备届时请求。"

    // 查看门槛（算力点）
    static let thresholdLabel = "查看门槛"
    static let thresholdField = "算力点"
    static let thresholdPrompt = "留空 = 免费查看"
    static func thresholdNote(_ maximum: Int) -> String {
        "对方点开这张名片时会先看见这个数，确认后才从他自己那台设备的余额里扣。留空或 0 就是免费看；上限 \(maximum) 点，写了更大的数会贴到上限。门槛跟着名片走，POPOPX 没有任何一侧能替对方改它。"
    }

    // 图文与视频
    static let blocksGroup = "图文与视频"
    static let blocksCountFormat = "内容块 %d / %d · 图片 %d 张 · 视频 %d 段"
    static let emptyBlocks = "还没有内容块。可以先加一段文字，再补图片和视频。"
    static let addText = "文字"
    static let addMedia = "图片 / 视频"
    static let addTextFull = "添加文字块"
    static let addMediaFull = "添加图片或视频块"
    static let textPrompt = "写一段自我介绍"
    static let mediaBusy = "正在压缩图片、转码视频…"
    static let moveUp = "上移"
    static let moveDown = "下移"
    static let removeBlock = "删除此块"
    static let kindImage = "图片"
    static let kindVideo = "视频"
    static let emptyTextBlock = "（空文字块）"

    // 底部固定条
    static let meshNote = "无网蓝牙 Mesh 模式下将自动过滤图片与视频，仅极速推送纯文字版加密名片。"
    static let deliveryHintTextOnly = "这份主页只有文字，在线与无网蓝牙 Mesh 送出的内容是同一份。"
    static let deliveryHintMediaFormat = "这份主页有 %d 个图片/视频块：走无网蓝牙 Mesh 时会被自动省去，只送纯文字版。"
    static let save = "保存主页"
    static let preview = "安全预览"
    static let savedToast = "已保存到本机"
    static let mediaAddedFormat = "已添加%@（%@），点「保存主页」才会写进清单"

    // 安全预览
    static let previewTitle = "安全预览"
    static let previewSubtitle = "同一份内容在四种组合下会送出去什么；草稿不会被动。"
    static let previewModeGroup = "发送模式"
    static let previewDeliveryGroup = "网络模式"
    static let previewBodyGroup = "对方看得到的内容"
    static func previewTTL(_ duration: String) -> String {
        "对方点击打开后起计 \(duration)，到点销毁本机这一份。"
    }
    static let previewStandard = "常驻名片：对方可反复打开，不启动倒计时，也不启动镜头检测。"
    static let previewOmittedFormat = "本次将省去 %d 个图片/视频块，只送出纯文字版。"
    static let previewEmptyBody = "这一档下没有可显示的内容块。"

    // 发送确认 Sheet
    static let sendTitle = "发送个人主页"
    static let sendSubtitle = "发送前确认这两档；已保存的主页不会因此改动。"
    static let sendSummaryGroup = "当前主页"
    static let sendModeGroup = "本次发送"
    static let sendBlockedGroup = "暂时发不了"
    static let sendAction = "发送"
    static let untitled = "未命名主页"
    static let sendSummaryFormat = "内容块 %d 个 · 图片 %d 张 · 视频 %d 段"
    static let sendMissingNote = "本机还没有保存过的主页。先在「我 → 加密个人主页」里做好并保存，再回来发送。"
    static let sendEmptyNote = "这份主页还没有任何内容块，加了文字、图片或视频之后才能发送。"

    // 兜底句：只有真撞上非类型化错误才会说到它。
    static let unexpectedFormat = "操作未完成：%@"

    static func kind(_ kind: PopopxProfileMedia.Kind) -> String {
        switch kind {
        case .image: return kindImage
        case .video: return kindVideo
        }
    }

    static func blockTitle(_ entry: ProfileBuilderBlockEntry) -> String {
        let position = entry.index + 1
        switch entry.block {
        case .text: return String(format: "文字块 %d", position)
        case .image: return String(format: "图片 %d", position)
        case .video: return String(format: "视频 %d", position)
        }
    }

    static func blockTextA11y(_ position: Int) -> String {
        "文字块 \(position) 正文"
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
