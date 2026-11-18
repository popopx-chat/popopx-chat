//
//  ProfileStorageManager.swift
//  POPOPX (iOS)
//
//  【加密个人主页 · 模块一之二】原件在沙盒里的位置，和"收件人首次打开之后"那把钟。
//
//  制作器/发送器/阅读器三个文件都只通过这一个 actor 碰磁盘：本机草稿走 `loadEditable` /
//  `saveEditable`，媒体走 `importImage` / `importVideo` / `loadMedia` / `removeMedia`，
//  计时走 `readState` / `markFirstOpened` / `forgetRead`。没有第二条路径，就没有第二套语义。
//
//  ### 硬边界
//  1. 只碰 `Application Support/PersonalProfile/`。app 现有的 `getDocumentsDirectory()` /
//     `getAppFilesDirectory()`（`FileUtils.swift:59`、`:253`）是 SimpleX 那套附件历史的领地，
//     两份历史互相不认识，谁也不许往对方那里写。app target 里没有现成的 Application Support
//     助手，所以这里自己从 `FileManager.default.urls(for:.applicationSupportDirectory,…)` 派生，
//     并且自己建中间目录。
//  2. 每个落盘文件都写 `[.atomic, .completeFileProtection]`，目录本身也补一遍
//     `FileAttributeKey.protectionKey = .complete`（写法的先例是 `PopopxMeshStorage.swift:109`）。
//     本文件是 app target 里第一处用到 `FileProtectionType` 的地方，所以"新写入"和"已存在的文件"
//     两条都要管：写选项只作用于那一次新建的 inode，`moveItem` 进来的媒体和 `createDirectory`
//     建出的目录各有各的默认属性。
//  3. `profileId` / `mediaId` 在收件方那一侧是**对端给的字符串**（`data=` 里的 JSON 字段）。
//     它们会进路径，也就会被 `removeMedia` 用来删文件，所以进路径之前必须过字符白名单——
//     否则一个 `../../` 就把删除权交出了这个沙盒目录。
//  4. 计时用的是墙钟（`Date().timeIntervalSince1970`），不是单调钟。绝密那条有 `PopopxSecureWindowManager`
//     的窗口生命周期可以依靠，而这一把钟要跨启动、跨会话、跨反复打开，只能落墙钟。墙钟能被机主
//     往回拨，所以 `now` 早于 `firstOpenedAt` 超过容差就判 `.clockRewound` 并按已销毁处理。
//     本文件不声称自己扛得住改表，只声称改表会被发现。
//  5. 计时记录按 `(chatId, itemId)` 键，不按 `profileId`：同一个人被重新发送一次就是一次全新的
//     阅读，一条已经烧掉的卡片不能因为对端重发而复活。`forgetRead` 删掉整条记录，销毁路径必须调它，
//     否则烧掉的行会因为记录还在而重新长出倒计时。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import AVFoundation
import Foundation
import UIKit

// MARK: - 阅读状态

/// 一张主页卡片在**某一条消息**上的阅读标识。
///
/// 键里带 chatId/itemId 而不是 profileId，理由见文件头第 5 条：重发的名片必须重新计时。
struct PopopxProfileReadKey: Hashable, Sendable, Codable {
    var chatId: Int64
    var itemId: Int64
}

/// 阅读时钟的四个相位。`firstOpenedAt` 在所有非 `unread` 分支里都带出来，界面因此可以
/// 自己算进度条，而不必再问一次存储。
enum PopopxProfileReadState: Hashable, Sendable {
    /// 从来没点开过（`ephemeral` 的计时此刻还没开始）。
    case unread
    /// 已点开，还在时限内。
    case counting(firstOpenedAt: TimeInterval, remainingSeconds: Int)
    /// 已点开且时限走完：内容必须按已销毁处理。
    case expired(firstOpenedAt: TimeInterval)
    /// 钟被往回拨过（或本机时间被时区/校时大幅改动）：内容同样按已销毁处理，宁可不给读。
    case clockRewound(firstOpenedAt: TimeInterval)
}

/// 一个媒体块在本机的读取结果。三档而不是 `URL?`：卡片要能分清"没收到"和"收到了但读不出"，
/// 前者是链路问题（可以提示重发），后者是本机文件问题（只能提示已损坏）。
enum PopopxProfileMediaLoad: Hashable, Sendable {
    case loaded(URL)
    case missing(mediaId: String)
    case unreadable(mediaId: String, reason: String)
}

/// 这一层（导入、压缩、转码）会说出口的原因。和 `PopopxProfileError` 分开是刻意的：那一个是
/// 载荷/协议层的失败，改它等于改协议；这一个是本机加工环节的失败。两个枚举混在一起，
/// 协议层的 case 就会被本机错误污染。
enum PopopxProfileMediaError: Error, Hashable, Sendable {
    /// 给进来的字节根本不是一张能解码的图。
    case undecodableImage
    /// 压到最小档位仍然超过 `ProfileStorageManager.maximumImageBytes`。
    case oversizedImage(bytes: Int)
    /// 给进来的文件根本不是一段能解码的视频（或时长读不出来）。
    case undecodableVideo
    /// 转码没跑完，或设备给不出这个导出预设。
    case exportFailed(reason: String)
    /// 30 秒截断之后仍然超过 `ProfileStorageManager.maximumVideoBytes`。
    case oversizedVideo(bytes: Int)
    /// 标识不合法：`profileId` 过不了进路径前的字符白名单。
    case rejectedIdentifier

    /// 面向用户的一行中文。
    var reasonText: String {
        switch self {
        case .undecodableImage:
            return "这张图片无法读取，换一张试试"
        case let .oversizedImage(bytes):
            return "这张图片压到最小仍有 \(bytes / 1_024) KB，超出单图 \(ProfileStorageManager.maximumImageBytes / 1_024 / 1_024) MB 上限"
        case .undecodableVideo:
            return "这段视频无法读取，换一段试试"
        case let .exportFailed(reason):
            return "视频转码未完成（\(reason)）"
        case let .oversizedVideo(bytes):
            return "这段视频压到 \(ProfileStorageManager.maximumVideoSeconds) 秒后仍有 \(bytes / 1_024) KB，超出 \(ProfileStorageManager.maximumVideoBytes / 1_024 / 1_024) MB 上限"
        case .rejectedIdentifier:
            return "主页标识不合法，已拒绝写入"
        }
    }
}

// MARK: - 存储

/// 主页的本机存储与阅读时钟。`actor` 而不是 `@MainActor class`：媒体导入是几分钟量级的
/// 编码工作（在后台线程跑），而阅读计时会被气泡每秒问一次，两者必须在同一个串行域里但都不该
/// 占用主线程。
actor ProfileStorageManager {
    static let shared = ProfileStorageManager()

    // MARK: 预算

    /// 单张图片压缩后的字节上限（2 MiB）。相册原图动辄 8 MB 以上，而名片要一次会话里推好几张。
    static let maximumImageBytes = 2 * 1024 * 1024
    /// 单个视频导出后的字节上限（15 MiB）。Mesh 走的是纯文字，所以这个上限约束的是 XFTP 那一跳。
    static let maximumVideoBytes = 15 * 1024 * 1024
    /// 视频时长上限（秒）。截断而不是拒绝：用户拍的 3 分钟视频里，名片用得上的就是开头那几秒。
    static let maximumVideoSeconds = 30

    /// 图片压缩的两张表：外层按最长边降档，内层按质量降档。
    ///
    /// 先缩像素再降质量、而不是把 `jpegData(compressionQuality:)` 一路降到 0.05：低质量优先会先
    /// 把图压成一团马赛克再抱怨体积，像素优先保住的是一张看得清的略小的图。
    private static let imagePixelLadder: [Int] = [2_560, 1_920, 1_440, 1_080, 800, 600]
    private static let imageQualities: [CGFloat] = [0.85, 0.7, 0.55, 0.4]

    /// 墙钟回拨的容差。2 秒盖得住自动校时的微调，又盖不住"把时间调回十分钟前"这种
    /// 想让倒计时重新变长的操作——那种必须落到 `.clockRewound`。
    private static let clockRewindTolerance: TimeInterval = 2

    /// 进路径的标识允许的字符数上限（UUID 是 36，留一倍余量给别家实现）。
    private static let maximumIdentifierCharacters = 64

    // MARK: 路径

    /// `Application Support/PersonalProfile/`。app target 里没有现成的 Application Support 助手，
    /// 所以这里自己派生；拿不到就退回 `temporaryDirectory`——宁可不落永久区，也不 `!` 一个可能为
    /// nil 的 URL（`FileUtils.swift:59` 那种写法在扩展卷没挂上时就是崩溃，本文件不重复这个错误）。
    static var rootDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (support ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static let directoryName = "PersonalProfile"
    private static let editableName = "manifest.json"
    private static let readStateName = "read-state.json"
    private static let mediaDirectoryName = "media"

    /// 过不了字符白名单的对端标识统统落到这个目录名里：那个目录永远是空的，于是读到的结果是
    /// `.missing`、删掉的是零个文件。既不放行越界路径，也不为此多开一条能抛错的分支。
    private static let rejectedIdentifierPlaceholder = "invalid"

    private static var editableURL: URL { rootDirectory.appendingPathComponent(editableName) }
    private static var readStateURL: URL { rootDirectory.appendingPathComponent(readStateName) }

    private static func mediaDirectory(profileId: String) -> URL {
        rootDirectory
            .appendingPathComponent(mediaDirectoryName, isDirectory: true)
            .appendingPathComponent(safeComponent(profileId, fallback: rejectedIdentifierPlaceholder), isDirectory: true)
    }

    private static func fileExtension(for kind: PopopxProfileMedia.Kind) -> String {
        switch kind {
        case .image: return "jpg"
        case .video: return "mp4"
        }
    }

    /// 路径里的一个组件。只允许 `[A-Za-z0-9-_]`：`.` 不在内，所以 `..`、`.`、以及任何带点的
    /// 变体都会被整串顶替成 fallback，`/` 更不可能进来。
    private static func safeComponent(_ raw: String, fallback: String) -> String {
        guard !raw.isEmpty, raw.count <= maximumIdentifierCharacters else { return fallback }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return fallback }
        return raw
    }

    /// 能不能原样当路径组件用。写得过的才允许往沙盒里落盘；读的一侧不需要这道门，
    /// 因为 `safeComponent` 已经把越界值顶替成一个必然为空的目录名。
    private static func isSafeIdentifier(_ raw: String) -> Bool {
        !raw.isEmpty && safeComponent(raw, fallback: rejectedIdentifierPlaceholder) == raw
    }

    // MARK: 落盘属性

    /// 建目录并给它 `.complete` 保护。已存在时 `createDirectory(withIntermediateDirectories:true)`
    /// 是幂等的，属性也一样，所以每次写入前都可以无脑调一次。
    private static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        applyProtection(at: url)
    }

    /// 原子写 + `.complete` 保护。`Data.write` 的 `.completeFileProtection` 只保证**这一次新建**的
    /// inode 带上保护，覆盖不了"文件早就存在、属性是别的"这一种（`.atomic` 会换新 inode，但目录属性
    /// 和 `moveItem` 进来的媒体仍要补），所以写完再显式补一遍属性。
    private static func write(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        applyProtection(at: url)
    }

    /// 补设属性。失败只记日志、不抛：在不支持数据保护的卷上（模拟器、外接卷）这一句注定失败，
    /// 而"因为设不上保护就拒绝保存主页"会让整条功能在开发机上看起来是坏的。真机上这一句必成，
    /// 失败的那一次在日志里留痕。
    private static func applyProtection(at url: URL) {
        do {
            try FileManager.default.setAttributes(
                [FileAttributeKey.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        } catch {
            logger.error("POPOPX profile: 无法为 \(url.lastPathComponent, privacy: .public) 设置 complete 文件保护：\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func discard(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("POPOPX profile: 临时文件没删掉 \(url.lastPathComponent, privacy: .public)：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 本机草稿

    /// 读本机的可编辑草稿。返回 nil 有两种情况：还没存过，或者文件读不得（版本不认识、JSON 坏了、
    /// 超出预算）。**两种都不删文件**：一份解不开的草稿是取证线索，静默抹掉用户的图文是第二次事故。
    func loadEditable() -> PopopxProfileManifest? {
        let url = Self.editableURL
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("POPOPX profile: 草稿读不出来（\(error.localizedDescription, privacy: .public)）")
            return nil
        }
        guard let manifest = PopopxProfileManifest.decoded(json: data) else {
            logger.error("POPOPX profile: 草稿内容不合法，保留原文件不覆盖")
            return nil
        }
        return manifest
    }

    /// 存本机草稿。
    ///
    /// 写入的是**传进来的那一份**、不是 `normalized()` 的副本：`deliveryMode` 是发送时的决定
    /// 而不是内容的属性，规范化会因为 `.meshTextOnly` 抹掉所有媒体块——存一次就把用户做的图删了，
    /// 是不能接受的。校验走 `PopopxProfilePayload.make` 这同一道门：草稿必须**发得出去**，
    /// 在保存时就报错比在点发送时报错便宜得多。
    func saveEditable(_ manifest: PopopxProfileManifest) throws {
        _ = try PopopxProfilePayload.make(manifest)
        let data = try manifest.encodedJSON()
        try Self.write(data, to: Self.editableURL)
    }

    // MARK: 媒体

    /// 图片：解码 → 按像素/质量两张表压到 2 MiB 以内 → 落盘。
    ///
    /// 一律 JPEG（不跟随 `ImageUtils.swift:97` 那个"有 alpha 就存 PNG"的判断）：名片要的是可预测
    /// 的体积，而 PNG 对相册照片根本压不下去。**重新编码这一步顺带把 EXIF/GPS 全部丢掉**——这不是
    /// 副作用而是目的：一张带拍摄坐标的原图进进主页，等于把用户的位置挂在他自己的名片上。
    func importImage(_ data: Data, profileId: String) throws -> PopopxProfileMedia {
        guard Self.isSafeIdentifier(profileId) else { throw PopopxProfileMediaError.rejectedIdentifier }
        guard let image = UIImage(data: data) else { throw PopopxProfileMediaError.undecodableImage }
        let jpeg = try Self.compress(image: image)
        let media = PopopxProfileMedia(
            mediaId: UUID().uuidString.lowercased(),
            kind: .image,
            bytes: jpeg.count,
            durationSeconds: nil,
            caption: nil
        )
        try Self.write(jpeg, to: mediaURL(media, profileId: profileId))
        return media
    }

    /// 像素优先、质量其次的压缩循环。跑完所有档位仍超标才拒（见 `imagePixelLadder` 那段）。
    private static func compress(image: UIImage) throws -> Data {
        var current = image
        var lastBytes = 0
        for side in imagePixelLadder {
            current = current.popopxProfileScaled(maximumPixelSide: side)
            for quality in imageQualities {
                guard let encoded = current.jpegData(compressionQuality: quality) else {
                    throw PopopxProfileMediaError.undecodableImage
                }
                lastBytes = encoded.count
                if encoded.count <= maximumImageBytes { return encoded }
            }
        }
        throw PopopxProfileMediaError.oversizedImage(bytes: lastBytes)
    }

    /// 视频：截断到 30 秒 → 转码 → 15 MiB 预算内才留。
    ///
    /// 转码沿用 app 已有的那个选择（`ImageUtils.swift:350`-`:363` 的 `AVAssetExportSession` +
    /// `AVAssetExportPreset640x480`）：那条预设输出 H.264，是全 app 唯一跑过实机验证的导出路径，
    /// 换一份新的编码配置就等于在本特性里开第二条没人验过的链路。
    /// `metadataItemFilter = .forSharing()` 同样是跟着它走的：创作者、设备型号、录制位置都在这段
    /// 元数据里，主页视频不该带着它们出门。
    func importVideo(from url: URL, profileId: String) async throws -> PopopxProfileMedia {
        guard Self.isSafeIdentifier(profileId) else { throw PopopxProfileMediaError.rejectedIdentifier }
        let directory = Self.mediaDirectory(profileId: profileId)
        try Self.ensureDirectory(directory)
        let mediaId = UUID().uuidString.lowercased()
        let output = directory.appendingPathComponent("\(mediaId).\(Self.fileExtension(for: .video))")
        // 导出器要求输出文件不存在，而且它自己写出来的文件不带我们要的保护属性，
        // 所以先导到同目录的临时名、补设保护、再改名成正式名（同卷改名是原子的）。
        let temporary = directory.appendingPathComponent("\(mediaId).exporting.mp4")
        var committed = false
        defer { if !committed { Self.discard(temporary) } }

        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw PopopxProfileMediaError.undecodableVideo
        }
        guard duration.seconds.isFinite, duration.seconds > 0 else {
            throw PopopxProfileMediaError.undecodableVideo
        }
        let seconds = min(duration.seconds, Double(Self.maximumVideoSeconds))
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset640x480) else {
            throw PopopxProfileMediaError.exportFailed(reason: "设备不支持 640×480 导出预设")
        }
        session.outputURL = temporary
        session.outputFileType = .mp4
        session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        await session.export()
        guard session.status == .completed else {
            throw PopopxProfileMediaError.exportFailed(reason: session.error?.localizedDescription ?? "导出状态未完成")
        }
        let exported = (try? FileManager.default.attributesOfItem(atPath: temporary.path)) ?? [:]
        guard let bytes = (exported[.size] as? NSNumber)?.int64Value, bytes > 0 else {
            throw PopopxProfileMediaError.exportFailed(reason: "导出结果为空")
        }
        guard bytes <= Int64(Self.maximumVideoBytes) else {
            throw PopopxProfileMediaError.oversizedVideo(bytes: Int(bytes))
        }
        if FileManager.default.fileExists(atPath: output.path) {
            // mediaId 是新生成的 UUID，撞不上；撞上了说明本机状态有问题，让新文件覆盖旧文件比
            // 抛一个用户看不懂的错更有用。
            Self.discard(output)
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            throw PopopxProfileMediaError.exportFailed(reason: error.localizedDescription)
        }
        Self.applyProtection(at: output)
        committed = true
        return PopopxProfileMedia(
            mediaId: mediaId,
            kind: .video,
            bytes: Int(bytes),
            durationSeconds: Int(seconds.rounded()),
            caption: nil
        )
    }

    /// 某个媒体块在本机的路径。扩展名由 `kind` 决定、永远不来自网络上那段 JSON，所以路径的后缀
    /// 这一侧也是不可控输入够不着的。
    func mediaURL(_ media: PopopxProfileMedia, profileId: String) -> URL {
        Self.mediaDirectory(profileId: profileId)
            .appendingPathComponent("\(Self.safeComponent(media.mediaId, fallback: Self.rejectedIdentifierPlaceholder)).\(Self.fileExtension(for: media.kind))")
    }

    /// 只判"在不在、能不能读、是不是空的"，不把字节读进内存：一段 15 MiB 的视频由界面那一侧
    /// 按需加载，这一层替它整块读一遍只会把内存花光而什么也没多证明。
    func loadMedia(_ media: PopopxProfileMedia, profileId: String) -> PopopxProfileMediaLoad {
        let url = mediaURL(media, profileId: profileId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing(mediaId: media.mediaId)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .unreadable(mediaId: media.mediaId, reason: "文件不可读")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attributes else {
            return .unreadable(mediaId: media.mediaId, reason: "读不到文件属性")
        }
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return .unreadable(mediaId: media.mediaId, reason: "读不到文件大小")
        }
        guard size > 0 else {
            return .unreadable(mediaId: media.mediaId, reason: "文件内容为空")
        }
        return .loaded(url)
    }

    /// 按 id 删。签名里只有 id、没有 `kind`，所以正式名和 `.exporting.mp4` 那个临时名都要能命中：
    /// 用 `id.` 前缀匹配而不是拼一个具体扩展名。
    func removeMedia(profileId: String, ids: [String]) {
        let directory = Self.mediaDirectory(profileId: profileId)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let wanted = Set(ids.map { Self.safeComponent($0, fallback: Self.rejectedIdentifierPlaceholder) + "." })
        for entry in entries where wanted.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
            Self.discard(entry)
        }
    }

    /// 烧掉一整份主页的全部原件（阅后即焚到点、或 panic 清理）。连目录一起摘，
    /// 省得留下一个空目录让 `removeAllMedia` 的调用方误以为还有东西在。
    func removeAllMedia(profileId: String) {
        let directory = Self.mediaDirectory(profileId: profileId)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        Self.discard(directory)
    }

    // MARK: 阅读时钟

    /// 一张卡片当前的阅读状态。
    ///
    /// 第一次问到某个 key 时，会把这一次给的 `ttlSeconds` **绑到记录上**：`markFirstOpened` 的
    /// 签名里没有任何时长参数，它只能从这条绑定里取值。副作用落在这个方向上是有意的——
    /// 气泡每次重绘都会调本函数，所以真正点开之前，绑定一定已经写好了。
    func readState(_ key: PopopxProfileReadKey, ttlSeconds: Int, now: Date) -> PopopxProfileReadState {
        let stored = stateTable()[Self.stateKey(key)] ?? Record(ttlSeconds: nil, firstOpenedAt: nil)
        guard let openedAt = stored.firstOpenedAt else {
            if stored.ttlSeconds != ttlSeconds {
                setRecord(Record(ttlSeconds: ttlSeconds, firstOpenedAt: nil), for: key)
            }
            return .unread
        }
        return Self.deriveState(firstOpenedAt: openedAt, ttlSeconds: ttlSeconds, now: now)
    }

    /// 记下"第一次打开"的时刻。重复调用是幂等的：已经记过的卡片**沿用原来的起始时间**，
    /// 于是退出重进、切后台再回来都刷不出一个新的时限——这正是"打开后计时"要防的那件事。
    func markFirstOpened(_ key: PopopxProfileReadKey) -> PopopxProfileReadState {
        let now = Date()
        let stored = stateTable()[Self.stateKey(key)] ?? Record(ttlSeconds: nil, firstOpenedAt: nil)
        let openedAt = stored.firstOpenedAt ?? now.timeIntervalSince1970
        setRecord(Record(ttlSeconds: stored.ttlSeconds, firstOpenedAt: openedAt), for: key)
        return Self.deriveState(firstOpenedAt: openedAt, ttlSeconds: stored.ttlSeconds, now: now)
    }

    /// 抹掉一张卡片的阅读记录。销毁路径必须调它：记录留着，卡片就会在下次渲染时重新长出倒计时。
    func forgetRead(_ key: PopopxProfileReadKey) {
        guard stateTable()[Self.stateKey(key)] != nil else { return }
        setRecord(nil, for: key)
    }

    // MARK: 阅读状态的持久化

    private struct Record: Codable, Hashable {
        var ttlSeconds: Int?
        var firstOpenedAt: TimeInterval?
    }

    /// 内存里的一份表，第一次用时从盘上拉。落盘是每次改完就写，所以这里的缓存和文件在成功路径上
    /// 始终一致；例外见 `stateFileIsUnreadable`。
    private var records: [String: Record]?

    /// 盘上有一个**存在但解不开**的状态文件。那种文件是这份时钟唯一的残骸：本会话照常按内存计时，
    /// 但不再往那个路径上写，免得把"用户已经烧掉过哪些卡片"的现场彻底换成一坨新数据。
    private var stateFileIsUnreadable = false

    private static func stateKey(_ key: PopopxProfileReadKey) -> String {
        "\(key.chatId):\(key.itemId)"
    }

    private func stateTable() -> [String: Record] {
        if let records { return records }
        var loaded: [String: Record] = [:]
        let url = Self.readStateURL
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
                loaded = decoded
            } else {
                // 文件在但整段解不开：合成 Codable 的字典是"全有或全无"的，救不出半条记录。
                stateFileIsUnreadable = true
                logger.error("POPOPX profile: 阅读状态文件解不开，本会话从空表开始且不再覆写该文件")
            }
        }
        records = loaded
        return loaded
    }

    /// 改表并写盘。本层三个计时接口都不抛错（`readState` 每秒被气泡问一次，`markFirstOpened`
    /// 点在用户手指下面），所以写盘失败只能记日志。
    ///
    /// 这条弱点必须写出来：写盘失败后本会话仍以内存为准、一切正常，但**重启后计时会退回
    /// `unread`**，收件人就又能读一次。这是墙钟 + 文件存储的固有代价，不假称自己有
    /// 绝密那条链路的单调保证。
    private func setRecord(_ record: Record?, for key: PopopxProfileReadKey) {
        var table = stateTable()
        let id = Self.stateKey(key)
        if let record {
            table[id] = record
        } else {
            table.removeValue(forKey: id)
        }
        records = table
        guard !stateFileIsUnreadable else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try Self.write(try encoder.encode(table), to: Self.readStateURL)
        } catch {
            logger.error("POPOPX profile: 阅读状态写盘失败（\(error.localizedDescription, privacy: .public)）；重启后计时可能退回未读")
        }
    }

    /// 由起始时刻算出当前相位。
    ///
    /// 这把钟只对 `ephemeral` 有意义：常驻名片不许走它（`PopopxProfilePayload.isEphemeral`
    /// 是唯一门禁），因为这里任何一格答"时限已到"，界面那一侧的动作就是删内容。
    ///
    /// `ttlSeconds` 传 nil 只在一条路径上可达：`markFirstOpened` 被冷调用（从没按
    /// "先 `readState` 绑时长、再点开"的顺序走）。那种情况给 0 秒剩余而不是猜一个更长的时限——
    /// 隐私语义上宁短勿长，而且下一次带真实时长的 `readState` 会立刻把正确的剩余秒数算回来。
    private static func deriveState(firstOpenedAt: TimeInterval, ttlSeconds: Int?, now: Date) -> PopopxProfileReadState {
        // 记录本身可能是坏文件里剩下的值（0、负、NaN）。那种情况下不存在"还剩多久"可言，
        // 按已到时限处理，而不是放行一次全新的完整时限。
        guard firstOpenedAt.isFinite, firstOpenedAt > 0 else { return .expired(firstOpenedAt: 0) }
        let elapsed = now.timeIntervalSince1970 - firstOpenedAt
        guard elapsed.isFinite else { return .expired(firstOpenedAt: firstOpenedAt) }
        if elapsed < -clockRewindTolerance {
            return .clockRewound(firstOpenedAt: firstOpenedAt)
        }
        guard let ttl = ttlSeconds else {
            return .counting(firstOpenedAt: firstOpenedAt, remainingSeconds: 0)
        }
        let passed = max(0, elapsed)
        // 先按值域判死再转 `Int`：一个早到 1970 年之前的起点会让 `Int(passed)` 直接 trap，
        // 而"早就过期"本来就是这个值域问题的正确答案。
        guard passed < Double(ttl + 1) else { return .expired(firstOpenedAt: firstOpenedAt) }
        // 上取整：向下取整等于每次跨秒都白送最多 1 秒，上取整则是提前判死。
        let remaining = ttl - Int(passed.rounded(.up))
        guard remaining > 0 else { return .expired(firstOpenedAt: firstOpenedAt) }
        return .counting(firstOpenedAt: firstOpenedAt, remainingSeconds: remaining)
    }
}

// MARK: - 图片缩放

extension UIImage {
    /// 等比缩到最长边不超过 `side` 像素；已经够小就原样返回（不做一次毫无产出的重画）。
    fileprivate func popopxProfileScaled(maximumPixelSide side: Int) -> UIImage {
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        guard pixels.width > 1, pixels.height > 1, side > 0 else { return self }
        let longest = max(pixels.width, pixels.height)
        guard longest > Double(side) else { return self }
        let factor = Double(side) / longest
        let target = CGSize(
            width: max(1, floor(pixels.width * factor)),
            height: max(1, floor(pixels.height * factor))
        )
        let format = UIGraphicsImageRendererFormat.default()
        // `scale = 1`：这里的目标尺寸就是像素尺寸，别让渲染器又按屏幕倍率乘一遍——那等于白缩。
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            self.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
