//
//  ProfileReaderView.swift
//  POPOPX (iOS)
//
//  【加密个人主页 · 模块四之二】接收侧的全屏阅读器，加上它自己的窗口宿主。
//
//  三个类型，三种职责，互不越界：
//
//  1. `ProfileReaderHost` —— 本特性**自己的** `UIWindow` 宿主。刻意不复用
//     `PopopxSecureWindowManager.shared.present(payload:target:)`：那一个的入参是
//     `PopopxSecurePayload`、根视图是写死的 `PopopxSecureShieldedContent(model:)`，而且它的
//     `sessionAlreadyOpen` 闸门（PopopxSecureWindowManager.swift:240）和绝密那条链路共用一个
//     `isWindowOpen`——名片点开会让绝密打不开，绝密点开会让名片打不开，两边都不是产品意图。
//     这里照搬的只有三样：窗口配方（:297-309 的 `.alert + 1`）、计时器形状（:492-519 的 0.1s
//     `.common` mode Timer）、以及"起不来必须说出来"的降级注记（:481-486）。
//  2. `PopopxProfileReaderModel` —— 阅读期间的全部可见状态：相位、剩余秒数、媒体槽、明文的生命周期。
//  3. `ProfileReaderView` —— 版式。护盾、盲水印、倒计时横幅、离线降级横幅都挂在这一层。
//
//  ### 这把钟为什么是"墙钟定死线、单调钟走刻度"
//  起点必须是**落盘的** `firstOpenedAt`（`ProfileStorageManager.markFirstOpened`），否则退出重进
//  就白送一个全新的时限。落盘墙钟唯一的弱点是机主改表，所以每一 tick 都拿
//  `ProcessInfo.systemUptime` 推一个"此刻应当是几点"，与真实墙钟相差超过容差即按已销毁处理——
//  这正是存储层用 `.clockRewound` 表达的那件事（ProfileStorageManager.swift:534-536），
//  视图层不许对它视而不见。`systemUptime` 只用来量**刻度**，从来不用来定**死线**。
//
//  ### 焚毁这条路上有三件事，缺一件就是撒谎
//  1. 明文：`memset_s` 覆写本模型持有的那一份 `Data`（`popopxSecureErase` 的同一手法，见
//     PopopxSecurePayload.swift:446-463）。SwiftUI 拿走的 `String` 归 ARC 管，本层不承诺覆写它
//     ——同 `PopopxSecurePayload.swift:42-46` 写明的诚实边界。
//  2. 媒体：`ProfileStorageManager.removeAllMedia(profileId:)`，连目录一起摘。
//  3. 本机记录：`apiDeleteChatItems(mode: .cidmInternal)`（调用点形状抄 Shared/POPOPXApp.swift:64-86，
//     只删本机这一份、不向对方广播）。第三条**可能失败**（离线、DB 抢锁）。失败了必须在焚毁页上
//     说出来，因为"这条已经焚毁"这句话里唯一可能没做到的就是它——动机同
//     `PopopxSecureChatTarget.isDeletable`（PopopxSecureWindowManager.swift:75-83）。
//
//  ### 出站的那一条不计时、不焚毁
//  `incoming == false` 的名片是**机主自己发出去**的那一份：它的 `profileId` 就是机主主页的媒体目录
//  （`ProfileStorageManager` 按 profileId 分格），按收件方的规则去 `removeAllMedia` 等于把用户自己的
//  图文视频删掉。所以下面每一次计时、每一回销毁都带 `privacyRead` 这一道闸，而它只在收件方向为真。
//
//  ### 已经焚过的键在本会话内不许复活
//  销毁路径要调 `forgetRead`（记录留着会长出倒计时，ProfileStorageManager.swift:452-456），可记录一没，
//  `readState` 就回到 `.unread`——卡片于是重新长出"未点开"，再点一次就是全新一个时限。所以本类另留
//  一份进程内的 `burnedKeys`：DB 删除成功时它只是双保险，删除失败时它是唯一还站得住的那道门。
//  跨启动不承诺——那一格靠的是 DB 删除本身，本文件不假称自己有别的保证。
//
//  配色、字号、圆角、间距一律取 Shared/Theme/PopopxTheme.swift 的 token；控件只用
//  Shared/Components 里已有的原子库；安全外壳一律复用 Shared/Features/SecureEphemeral 那一套。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖进 POPOPX (iOS) target —— 红线禁止脚本改 project.pbxproj。
//

import AVFoundation
import POPOPXChat
import SwiftUI
import UIKit

// MARK: - 打开失败

/// `present` 能拒绝的全部理由。一条 = 一句必须让用户看见的话，静默拒绝是最坏的失败形状。
enum PopopxProfilePresentFailure: Hashable, Sendable {
    /// 已经有一个名片窗口开着。名片**不支持叠窗口**：两份明文同屏等于把"阅后即焚"变成"阅后即混"。
    case sessionAlreadyOpen
    /// 打开之前就看到屏幕正在被录制/镜像。
    case screenCaptured
    /// 反调试判据不肯放行（本进程正被跟踪）。
    case antiDebugBlocked
    /// 这份主页要求前置镜头值守，而摄像头权限没拿到。没有值守的隐私名片等于没锁的门。
    case cameraPermissionDenied
    /// 取不到可承载窗口的 `UIWindowScene`（在后台、或场景还没建好）。
    case noPresentationContext
    /// 这把钟已经走完了：时限归零、钟被回拨、24 小时未读的兜底、或本会话内已经焚过。
    case readClockExpired
    /// 载荷本身不成形状：版本不认识、时长越界、内容全空。
    case payloadRejected(reason: String)

    /// 卡片/toast 上那句人话。判据同 `PopopxSecurityAlert.reasonText`：说清"哪一类拦住了"，
    /// 不预测后果、不承诺补救。
    var reasonText: String {
        switch self {
        case .sessionAlreadyOpen: return NSLocalizedString("A profile page is already open — close it first", comment: "profile open refusal")
        case .screenCaptured: return NSLocalizedString("The screen is being recorded or mirrored, so opening was refused", comment: "profile open refusal")
        case .antiDebugBlocked: return NSLocalizedString("This device is being traced by a debugger, so opening was refused", comment: "profile open refusal")
        case .cameraPermissionDenied: return NSLocalizedString("This profile page requires camera watch; allow camera access first", comment: "profile open refusal")
        case .noPresentationContext: return NSLocalizedString("There is no interface available to show this profile page in", comment: "profile open refusal")
        case .readClockExpired: return NSLocalizedString("The reading window for this profile page has expired", comment: "profile open refusal")
        case let .payloadRejected(reason): return reason
        }
    }
}

// MARK: - 内容槽

/// 一格里媒体在本机的可见状态。`missing`/`unreadable` 必须**说话**，不给空白格子：
/// 空白会让人以为"对方发了张看不见的图"，而真实情况是本机没留原件——两件事的下一步动作完全不同。
enum PopopxProfileReaderMedia: Hashable {
    /// 还没向存储问过路径。
    case pending
    /// 厢语降级省掉的那一格：永远不显示，只作为降级横幅里那个数字的存在证明。
    case omitted
    /// 本机没有原件（`missing`），或原件在但读不出（`unreadable`）。
    case unavailable(kind: PopopxProfileMedia.Kind, reason: String)
    case image(URL)
    case video(URL)
}

/// 阅读器里的一行。`id` 用块下标：一份清单在一次阅读里不会增删，下标因此是稳定身份。
struct PopopxProfileReaderEntry: Identifiable {
    let id: Int
    let block: PopopxProfileBlock
    var media: PopopxProfileReaderMedia
}

// MARK: - 阅读器状态

/// 阅读期间的全部可见状态。`@MainActor`：写它的只有 tick、告警、关闭三条路，全在主线程。
@MainActor
@Observable
final class PopopxProfileReaderModel {
    /// 三个相位，互斥且覆盖全部可见状态。与绝密那一档（`PopopxSecureSheetModel.Phase`，
    /// PopopxSecureSheetView.swift:49-64）的差别是有意的：本特性**不提供**"黑罩但不销毁"的
    /// `locked` 相位，因为名片没有"再走一次生物识别然后回来"这条路，留一个锁屏相位
    /// 就是让用户对着一屏黑猜自己还能不能读回来。
    enum Phase: Hashable {
        /// 正文可读，隐私档的倒计时在走。
        case reading
        /// 明文已擦，窗口还留着是为了让用户看见**为什么**关。`reason` 为 nil = 正常看完/正常到点。
        case burned(reason: String?)
        /// 收尾中：视图正在消失，任何回调都不该再生效。
        case closing
    }

    /// 墙钟与单调钟允许差多久。2 秒盖得住自动校时的微调，盖不住"把时间调回十分钟前"
    /// （容差取值与 `ProfileStorageManager.clockRewindTolerance` 同一档，判据也同一套）。
    static let clockJumpTolerance: TimeInterval = 2
    /// 焚毁页停留多久再拆窗口。太短等于没解释，太长挡路。
    static let burnNoticeSeconds: Double = 1.6

    /// 这一次阅读要不要走"打开后计时并销毁"。只有收件方向的隐私名片为真，理由见文件头。
    let privacyRead: Bool
    let totalSeconds: Int
    let deliveryMode: PopopxProfileDelivery
    let omittedMediaCount: Int
    /// 盲水印的会话号：一次窗口一个，销毁后不重用（取证价值同 `PopopxSecureSheetModel.sessionIdentifier`
    /// ——它回答的是"这一份是从哪一次查看出去的"）。
    let sessionIdentifier: String

    private(set) var phase: Phase = .reading
    private(set) var remainingSeconds: Int
    private(set) var title: String
    private(set) var subtitle: String?
    private(set) var entries: [PopopxProfileReaderEntry]

    /// 值守少了一路、为什么少。`nil` = 没有要说的。**不许**在这上面加"检测运行中"的假承诺：
    /// 引擎给什么就显示什么（`PopopxCameraGuardEngine.startupNote` 连"模型不在"都如实报，:269）。
    var guardNote: String?
    /// 触发焚毁的那一句（`PopopxSecurityAlert.reasonText` 或改表说明）。
    private(set) var burnedBy: String?
    /// 本机记录删掉了没有。`nil` = 还没回话。**false 必须在界面上说出来**。
    private(set) var localRecordDeleted: Bool?
    /// 清理还在跑。隐私档烧得快时界面要说"正在清理"，不能假装已经清完。
    private(set) var isCleaning = false

    /// 死线：持久化墙钟的 `firstOpenedAt + ttl`。**不**由 `systemUptime` 推出来。
    private let deadlineWallClock: TimeInterval?
    /// 开窗那一刻的墙钟与单调钟，用来把"改表"和"时间真的走了"分开。
    private let anchorWallClock: TimeInterval
    private let anchorUptime: TimeInterval

    private let profileId: String
    /// 本模型持有的那一份明文。视图拿到的是从这里现算的 `String`，擦掉的是这一格 `Data`。
    private var plaintext: Data?
    private let close: () -> Void
    /// 焚毁的清理动作交给宿主：本类不碰窗口、不碰存储、不碰 DB。
    var onBurn: (() -> Void)?

    private var isErased = false
    private var hasBurned = false
    private var mediaIsLoading = false

    #if DEBUG
    /// 单见证的"明文已交出"凭据。为什么不直接读 `title`/`entries`：`@Observable` 给它们套上继承
    /// `@MainActor` 的观察访问器，而 `deinit` 是非隔离的，读它就编译不过——同一个坑记在
    /// PopopxSecureSheetView.swift:90-103。这个盒子是没有隔离的普通类，`let` 引用又不参与观察，
    /// 于是 `deinit` 读得动；它只有 DEBUG 存在，只有一个写点（`eraseForClose()`）。
    private final class EraseWitness {
        var plaintextGivenUp = false
    }

    private let eraseWitness = EraseWitness()
    #endif

    init(
        payload: PopopxProfilePayload,
        firstOpenedAt: TimeInterval?,
        privacyRead: Bool,
        close: @escaping () -> Void
    ) {
        let manifest = payload.manifest
        self.privacyRead = privacyRead
        self.totalSeconds = manifest.ttlSeconds
        self.deliveryMode = manifest.deliveryMode
        self.omittedMediaCount = manifest.omittedMediaCount
        self.profileId = manifest.profileId
        self.title = manifest.title
        self.subtitle = manifest.subtitle
        self.sessionIdentifier = UUID().uuidString
        self.close = close

        var rows: [PopopxProfileReaderEntry] = []
        rows.reserveCapacity(manifest.blocks.count)
        for (index, block) in manifest.blocks.enumerated() {
            rows.append(
                PopopxProfileReaderEntry(
                    id: index,
                    block: block,
                    media: Self.initialSlot(of: block, delivery: manifest.deliveryMode)
                )
            )
        }
        self.entries = rows

        // 明文只留一份可覆写的缓冲：标题 + 副标题 + 全部文字块。它是显示用的源，
        // 也是焚毁时必须 memset_s 的那一格。
        var joined = manifest.title
        if let subtitle = manifest.subtitle, !subtitle.isEmpty { joined += "\n" + subtitle }
        for block in manifest.blocks {
            if case let .text(body) = block { joined += "\n" + body }
        }
        self.plaintext = joined.isEmpty ? nil : Data(joined.utf8)

        let now = Date().timeIntervalSince1970
        self.anchorWallClock = now
        self.anchorUptime = ProcessInfo.processInfo.systemUptime

        let deadline: TimeInterval?
        if privacyRead, let firstOpenedAt, firstOpenedAt.isFinite, firstOpenedAt > 0 {
            deadline = firstOpenedAt + Double(manifest.ttlSeconds)
        } else {
            deadline = nil
        }
        self.deadlineWallClock = deadline
        if let deadline {
            self.remainingSeconds = max(0, Int((deadline - now).rounded(.up)))
        } else {
            self.remainingSeconds = 0
        }
    }

    deinit {
        #if DEBUG
        // 回收断言：模型被释放时明文必须已经交出。false 说明销毁/关闭路径被跳过了——
        // 通常是宿主拆窗口时漏调 `eraseForClose()`。
        if !eraseWitness.plaintextGivenUp {
            assertionFailure("PopopxProfileReaderModel was released without giving up the plaintext: the destroy or close path was skipped")
        }
        #endif
    }

    // MARK: 投影

    var isReading: Bool {
        if case .reading = phase { return true }
        return false
    }

    var isBurned: Bool {
        if case .burned = phase { return true }
        return false
    }

    /// 已经走掉的比例（0…1）。常驻档没有钟，给 1 表示"进度条不该出现"。
    var progress: Double {
        guard privacyRead, totalSeconds > 0 else { return 1 }
        return 1 - min(1, max(0, Double(remainingSeconds) / Double(totalSeconds)))
    }

    // MARK: 生命周期

    /// 开窗。相位从创建起就是 `.reading`，这一步只作为"窗口已经可见"的那个点：宿主在此之后
    /// 才允许起侧信道（"值守只在窗口可见期间运行"这条硬约束的落点）。
    func open() {
        phase = .reading
    }

    /// 逐 tick。返回 false = 这把钟不再需要被问（已焚、已关、或本来就没有钟），宿主据此停表。
    ///
    /// 刻度用 `ProcessInfo.systemUptime`（改表动不了它），死线用持久化墙钟（退出重进不重置）。
    /// 两者对不上超过容差就说明墙钟被改过——按已销毁处理，而不是挑对读数有利的那一边。
    @discardableResult
    func tick(now wall: Date = Date()) -> Bool {
        guard privacyRead, isReading, let deadlineWallClock else { return false }
        let wallNow = wall.timeIntervalSince1970
        let monotonicEstimate = anchorWallClock + (ProcessInfo.processInfo.systemUptime - anchorUptime)
        guard abs(wallNow - monotonicEstimate) <= Self.clockJumpTolerance else {
            beginBurn(reason: Copy.burnedByClockRewound)
            return false
        }
        let remaining = deadlineWallClock - wallNow
        guard remaining > 0 else {
            remainingSeconds = 0
            beginBurn(reason: nil)
            return false
        }
        // 上取整：向下取整等于每次跨秒都白送最多 1 秒，与 `deriveState` 同一口径。
        remainingSeconds = Int(remaining.rounded(.up))
        return true
    }

    /// 安全告警。名片这一侧不提供"锁住但留着"的中间态：任何一路命中就是焚毁，因为这里没有
    /// 第二次生物识别可以让用户走回来（与绝密那条的差别见 `Phase` 的注释）。
    func handle(_ alert: PopopxSecurityAlert) {
        guard isReading else { return }
        beginBurn(reason: alert.reasonText)
    }

    /// 用户按关闭。隐私档的关闭**同样**是焚毁："阅后即焚"的"焚"不由用户决定
    /// （同 `PopopxSecureWindowManager` 的 `closeAndBurn` 那条裁定）。
    func requestClose() {
        guard isReading else { return }
        if privacyRead {
            beginBurn(reason: nil)
        } else {
            phase = .closing
            eraseForClose()
            close()
        }
    }

    /// 走到焚毁：先停正文、擦明文，再把清理动作交给宿主。幂等——第二次调用不再触发 `onBurn`。
    func beginBurn(reason: String?) {
        guard !hasBurned else { return }
        hasBurned = true
        burnedBy = reason
        phase = .burned(reason: reason)
        eraseForClose()
        onBurn?()
    }

    /// 清理已开始（界面上的"正在清理"）。
    func beginCleaning() {
        isCleaning = true
    }

    /// 清理回话。`deletedLocalRecord` 为 nil = 还没定论，界面上那两句都不许说。
    func reportCleaning(deletedLocalRecord: Bool?) {
        if let deletedLocalRecord { localRecordDeleted = deletedLocalRecord }
        isCleaning = false
    }

    /// 清明文只走这一个出口：绕过它直接改字段会让 `deinit` 的回收断言说"没清过"。幂等。
    func eraseForClose() {
        guard !isErased else { return }
        isErased = true
        title = ""
        subtitle = nil
        entries = []
        // 必须在 `plaintext` 这个 l-value 上直接取可变字节：先 `if var copy = plaintext`
        // 会把缓冲共享出去，memset 落在副本上、原件一个字节没动
        //（`PopopxSecurePayload.swift:453-462` 记的同一件事，那里也是同一个写法）。
        popopxSecureErase(&plaintext)
        #if DEBUG
        eraseWitness.plaintextGivenUp = true
        #endif
    }

    // MARK: 媒体

    /// 把还没拿到路径的媒体块问一遍存储。可重入：第二次调用直接返回，不会把同一批路径问两遍。
    ///
    /// 这里只取 `URL`，一个字节都不读——解码在贴片自己的 `.task` 里离开主线程。
    func loadMissingMedia() async {
        guard !mediaIsLoading, !isErased else { return }
        mediaIsLoading = true
        defer { mediaIsLoading = false }
        let storage = ProfileStorageManager.shared
        for entry in entries {
            guard case .pending = entry.media else { continue }
            guard let media = Self.media(of: entry.block) else { continue }
            let loaded = await storage.loadMedia(media, profileId: profileId)
            // 视图可能已经消失、内容可能已经被擦：每一跳之后都重新判一次再写。
            if Task.isCancelled || isErased { return }
            let next: PopopxProfileReaderMedia
            switch loaded {
            case let .loaded(url):
                switch media.kind {
                case .image: next = .image(url)
                case .video: next = .video(url)
                }
            case .missing:
                next = .unavailable(kind: media.kind, reason: Copy.mediaMissing)
            case let .unreadable(_, reason):
                next = .unavailable(kind: media.kind, reason: reason)
            }
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].media = next
            }
        }
    }

    /// 初值。降级档里媒体块已经在 `normalized()` 那一步被整批剔掉了，这里留的 `.omitted`
    /// 只兜"对端直接送来一个 meshTextOnly + 媒体块"的畸形组合——它也不许显示成空白格。
    private static func initialSlot(
        of block: PopopxProfileBlock,
        delivery: PopopxProfileDelivery
    ) -> PopopxProfileReaderMedia {
        switch block {
        case .text:
            return .pending
        case .image, .video:
            return delivery == .meshTextOnly ? .omitted : .pending
        }
    }

    private static func media(of block: PopopxProfileBlock) -> PopopxProfileMedia? {
        switch block {
        case .text: return nil
        case let .image(media): return media
        case let .video(media): return media
        }
    }
}

// MARK: - 窗口宿主

/// 名片自己的全屏窗口宿主。与 `PopopxSecureWindowManager` 的分工写在本文件头部；
/// 一句话版：**那个管理器不该知道名片的存在**。
@MainActor
final class ProfileReaderHost {
    static let shared = ProfileReaderHost()

    /// 本会话内已经焚过的键。作用见文件头"已经焚过的键在本会话内不许复活"。
    private(set) var burnedKeys: Set<PopopxProfileReadKey> = []

    private var window: UIWindow?
    private var model: PopopxProfileReaderModel?
    private var countdownTimer: Timer?
    private var captureMonitor: PopopxCaptureMonitor?
    private var guardEngine: PopopxCameraGuardEngine?
    private var dismissTask: Task<Void, Never>?

    var isPresented: Bool { window != nil }

    /// 这张卡片在本会话内是不是已经焚过了。卡片用它挡掉"记录被 forget 之后重新长出未读"。
    func isBurned(_ key: PopopxProfileReadKey) -> Bool { burnedKeys.contains(key) }

    private init() {}

    /// 打开一份主页。返回 nil = 已显示；返回值 = 被拦下的理由，调用方（卡片）**必须**把它显示出来。
    func present(
        payload: PopopxProfilePayload,
        target: PopopxProfileReadKey,
        incoming: Bool,
        createdAt: Date
    ) async -> PopopxProfilePresentFailure? {
        guard !isPresented else { return .sessionAlreadyOpen }
        if let rejected = Self.validate(payload) { return rejected }
        // 出站的那一条不查这本账：它从没被本特性焚过，机主自己的名片也不该被收件规则抹掉。
        if incoming, isBurned(target) { return .readClockExpired }

        let privacyRead = payload.isEphemeral && incoming
        var firstOpenedAt: TimeInterval?
        if privacyRead {
            // 三条预检的顺序是有意的：前两条是纯读，第三条会弹系统框，而系统框必须排在
            // 开窗之前（名片窗口的 level 是 `.alert + 1`，会把权限框压在下面——:245-253 同判据）。
            //
            // 计划里写的是 `UIScreen.main.isCaptured`，这里按现网裁定替换成
            // `PopopxScreenCapture.anyScreenIsCaptured`：前者已废弃且读的是"全局那块屏"，
            // 多屏/外接屏下会漏判（PopopxScreenCaptureShieldView.swift:457-464 已把判据定在场景级）。
            guard !PopopxScreenCapture.anyScreenIsCaptured else { return .screenCaptured }
            guard PopopxAntiDebug.allowsSecurePresentation else { return .antiDebugBlocked }
            if payload.manifest.enableAntiSpyCamera, let denied = await Self.ensureCameraAccess() {
                return denied
            }
            switch await Self.openingClock(payload: payload, target: target, createdAt: createdAt) {
            case let .opened(openedAt):
                firstOpenedAt = openedAt
            case .blocked:
                return .readClockExpired
            }
        }

        guard let scene = Self.currentWindowScene() else { return .noPresentationContext }

        let model = PopopxProfileReaderModel(
            payload: payload,
            firstOpenedAt: firstOpenedAt,
            privacyRead: privacyRead,
            close: { [weak self] in self?.dismissProfileWindow() }
        )
        model.onBurn = { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.destroyLocalCopy(payload: payload, target: target, privacyRead: privacyRead)
            }
            // 归零或告警都要自动关闭：解释留一屏的时间，然后拆窗。
            dismissTask?.cancel()
            dismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.autoDismissNanoseconds)
                guard !Task.isCancelled else { return }
                self?.dismissProfileWindow()
            }
        }
        model.open()
        self.model = model

        let window = UIWindow(windowScene: scene)
        window.rootViewController = Self.hostController(for: model)
        // 抄 PopopxSecureWindowManager.swift:299-302：`.alert + 1` 才压得住 app 内的系统弹窗，
        // 否则一次相册/权限框就把正文盖在下面、倒计时照走。`UIWindow.Level` 不支持 `+`，走 rawValue。
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        // 外观跟随宿主窗口：孤立窗口默认拿设备外观，app 强制浅/深色时这里会错位。
        // 必须在 `isHidden = false` 之前读，否则读到自己。
        if let host = scene.windows.first(where: \.isKeyWindow) {
            window.overrideUserInterfaceStyle = host.overrideUserInterfaceStyle
        }
        window.isHidden = false
        self.window = window

        if privacyRead {
            startSideChannels(in: window, model: model, antiSpy: payload.manifest.enableAntiSpyCamera)
            startCountdown()
        }
        PopopxHaptics.notice(.success)
        return nil
    }

    /// 拆窗口。幂等：没开过就是空操作。四件事都必须做——停表、停侧信道、擦明文、再丢窗口。
    func dismissProfileWindow() {
        dismissTask?.cancel()
        dismissTask = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        // `stop()` 会把 `onAlert` 置 nil（PopopxScreenCaptureShieldView.swift:393-399）：
        // 一个"自己会带着旧回调复活"的监测器没法安全复用，所以拆完就丢。
        captureMonitor?.stop()
        captureMonitor = nil
        // `startMonitoring`/`stopMonitoring` 都带主线程 precondition
        //（PopopxCameraGuardEngine.swift:159、:202）；本类是 `@MainActor`，这里就在主线程上。
        guardEngine?.stopMonitoring()
        guardEngine = nil
        // 顺序：先擦明文再丢引用。反过来的话 DEBUG 的回收断言会在拆窗那一刻炸出来，
        // 而那一次是真的"没擦就放"。
        model?.eraseForClose()
        model = nil
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    // MARK: 校验与时钟

    /// 载荷形状的最后一道复核。`parse` 已经量过一遍，这一道挡的是**别的入口**递进来的载荷
    /// （扫码、深链）——那几个入口拿到的是字符串，不一定经过 `parse`。
    private static func validate(_ payload: PopopxProfilePayload) -> PopopxProfilePresentFailure? {
        guard payload.manifest.profileVersion == PopopxProfileManifest.version else {
            return .payloadRejected(reason: PopopxProfileError.unknownVersion(payload.manifest.profileVersion).reasonText)
        }
        if payload.isEphemeral {
            guard (PopopxProfilePayload.minimumTTLSeconds...PopopxProfilePayload.maximumTTLSeconds)
                .contains(payload.manifest.ttlSeconds) else {
                return .payloadRejected(reason: PopopxProfileError.invalidTTL(payload.manifest.ttlSeconds).reasonText)
            }
        }
        let hasTitle = !payload.manifest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = payload.manifest.blocks.contains { block in
            switch block {
            case let .text(body): return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image, .video: return true
            }
        }
        guard hasTitle || hasBody else { return .payloadRejected(reason: Copy.emptyProfile) }
        return nil
    }

    /// `openingClock` 的结论：可以读（带起点），或者该拒。
    private enum OpeningClock {
        case opened(TimeInterval)
        case blocked
    }

    /// 把 `firstOpenedAt` 落盘并取回这把钟的起点。
    ///
    /// ⚠️ 调用顺序是硬要求而不是风格：`markFirstOpened` 在**冷记录**上可能给出
    /// `counting(remainingSeconds: 0)`——它的签名里没有时长参数，只能读 `readState` 绑过的那一格
    ///（ProfileStorageManager.swift:428-437 与 :525-539 记的同一件事）。所以这里点完之后
    /// **必须再问一次 `readState`** 才敢信它给的剩余秒数。
    private static func openingClock(
        payload: PopopxProfilePayload,
        target: PopopxProfileReadKey,
        createdAt: Date
    ) async -> OpeningClock {
        let ttl = payload.manifest.ttlSeconds
        let now = Date()
        // 第一步：先把 ttl 绑到记录上（第一次问某个 key 时 `readState` 会写这一格）。
        let before = await ProfileStorageManager.shared.readState(target, ttlSeconds: ttl, now: now)
        switch before {
        case .expired, .clockRewound:
            return .blocked
        case .counting(let openedAt, let remaining):
            // 已有起点：沿用同一格，绝不重置。退出重进、切后台再回来都刷不出新时限。
            guard remaining > 0 else { return .blocked }
            _ = await ProfileStorageManager.shared.markFirstOpened(target)   // 幂等
            return .opened(openedAt)
        case .unread:
            // 24 小时未读的兜底。展示层那条规则归卡片，但**打开这一侧**也必须挡，否则一张
            // 显示为已焚的卡片还是能读出全新一个时限。常量放在卡片那一侧（展示层策略），
            // 这里引用同一个值，不出现第二张表。
            if now.timeIntervalSince1970 - createdAt.timeIntervalSince1970 > ProfileCardBubbleView.unreadAutoBurnAfter {
                return .blocked
            }
            _ = await ProfileStorageManager.shared.markFirstOpened(target)
            // 冷记录上 markFirstOpened 的返回值不可信（见上面那段），再读一次定死。
            let settled = await ProfileStorageManager.shared.readState(target, ttlSeconds: ttl, now: Date())
            switch settled {
            case .unread:
                // 刚刚 mark 过却还回 `.unread`：写盘失败一类的本机异常。给一个"此刻起计"的起点，
                // 而不是拒绝打开——拒绝会让用户以为功能坏了，而这把钟本来就是从这一刻开始的。
                return .opened(now.timeIntervalSince1970)
            case let .counting(openedAt, remaining):
                return remaining > 0 ? .opened(openedAt) : .blocked
            case .expired, .clockRewound:
                return .blocked
            }
        }
    }

    // MARK: 权限与场景

    /// 只在"从没问过"的时代请求权限。已经 denied 时不去骚扰系统（那条路不会再弹框），直接给人话。
    private static func ensureCameraAccess() async -> PopopxProfilePresentFailure? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return nil
        case .notDetermined:
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                PopopxCameraGuardEngine.requestCameraAccess { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? nil : .cameraPermissionDenied
        case .denied, .restricted:
            return .cameraPermissionDenied
        @unknown default:
            return .cameraPermissionDenied
        }
    }

    private static func currentWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) { return active }
        // 与 `PopopxSecureWindowManager.currentWindowScene()`（:567-572）同一判据：拿不到 active
        // 只可能是 scene 正在切换的瞬间，`foregroundInactive` 一样能承载窗口。多一级 `scenes.first`
        // 兜底是这里唯一比它松的地方——窗口建出来只是排在 scene 里，用户回到前台才看得见，
        // 而 `present` 前两道预检已经把"看不见就不许开"的门守住了。
        // （不写"排除已归档 scene"：`UIScene.ActivationState` 没有 `.archived` 这一档，实测编译不过。）
        return scenes.first(where: { $0.activationState == .foregroundInactive }) ?? scenes.first
    }

    private static func hostController(for model: PopopxProfileReaderModel) -> UIViewController {
        let controller = UIHostingController(rootView: PopopxProfileReaderRootView(model: model))
        // 隐私档要纯黑底：护盾给采集端画的也是黑，留一个系统灰底等于留一个"内容区外不是纯黑"
        // 的破口（同 :294-296）。常驻档用 `base`，那一档本来就是普通页面。
        controller.view.backgroundColor = model.privacyRead ? .black : UIColor(PopopxPalette.base)
        return controller
    }

    // MARK: 侧信道与倒计时

    private func startSideChannels(in window: UIWindow, model: PopopxProfileReaderModel, antiSpy: Bool) {
        let monitor = PopopxCaptureMonitor()
        monitor.onAlert = { [weak self, weak model] alert in
            self?.handleAlert(alert, model: model)
        }
        monitor.start(in: window)
        captureMonitor = monitor

        guard antiSpy else {
            // 这份主页没要求镜头值守：把"少了哪一路"说清楚，而不是留一个看起来像在跑的图标。
            model.guardNote = Copy.antiSpyOffNote
            return
        }
        let engine = PopopxCameraGuardEngine()
        engine.onAlert = { [weak self, weak model] alert in
            self?.handleAlert(alert, model: model)
        }
        // 起不来不能当没事：少了哪一路、为什么少必须让用户看见（抄 :481-486 那条裁定）。
        // 模型没导入时 `startupNote` 自己会说出"目标检测未启用，仅高光反射兜底在工作"，
        // 这一层不许把它抹成"防护已开启"。
        if let failure = engine.startMonitoring() {
            model.guardNote = failure.reasonText
        } else {
            model.guardNote = engine.startupNote
        }
        guardEngine = engine
    }

    private func handleAlert(_ alert: PopopxSecurityAlert, model: PopopxProfileReaderModel?) {
        guard let model, model.isReading else { return }
        PopopxHaptics.notice(.error)
        model.handle(alert)
    }

    /// 0.1s 的 `Timer` + `.common` mode：形状抄 PopopxSecureWindowManager.swift:492-507。
    /// 手指按住滚动时也要走——挂 `.default` 的话，用户拖动名片的那段时间倒计时是停的。
    private func startCountdown() {
        tick()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func tick() {
        guard let model else { return }
        // 模型自己判到点并触发 `onBurn`；返回 false 就是这把钟不用再问了。
        if !model.tick() {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    /// 焚毁的三件事：媒体、阅读记录、本机那一条消息。DB 那一步的成败要回到模型，
    /// 界面上那句"本机记录没删成"才有依据。
    private func destroyLocalCopy(
        payload: PopopxProfilePayload,
        target: PopopxProfileReadKey,
        privacyRead: Bool
    ) async {
        guard privacyRead else { return }
        model?.beginCleaning()
        burnedKeys.insert(target)
        let storage = ProfileStorageManager.shared
        await storage.removeAllMedia(profileId: payload.manifest.profileId)
        // 记录必须抹掉：留着它，卡片会在下次渲染时重新长出倒计时（ProfileStorageManager.swift:452-456）。
        // 抹掉之后 `readState` 回 `.unread`，那一格由上面 `burnedKeys` 这本进程内的账接住。
        await storage.forgetRead(target)
        let deleted = await Self.deleteChatRow(target: target)
        model?.reportCleaning(deletedLocalRecord: deleted)
    }

    /// 物理删除本机那一条会话项。调用点形状抄 Shared/POPOPXApp.swift:64-86。
    ///
    /// `PopopxProfileReadKey.chatId` 是 `Int64`（= `ChatInfo.apiId`），而 `ChatModel.getChat(_:)`
    /// 收的是 `ChatInfo.id` 那个 String 键，所以这里按 `apiId` 在现有会话里找那一条，不自己拼
    /// `"@\(id)"` 一类的键——拼键等于在本特性里重写一遍 `ChatInfo.id` 的实现（理由同
    /// `PopopxSecureWindowManager.swift:66-72`）。找不到就只报 error 并把 `false` 交回去：
    /// 宁可这一条没删成**并且说出来**，也不能拿猜出来的键去删别人家的行。
    private static func deleteChatRow(target: PopopxProfileReadKey) async -> Bool {
        let model = ChatModel.shared
        guard let chat = model.chats.first(where: { $0.chatInfo.apiId == target.chatId }) else {
            logger.error("POPOPX profile: no chat found for apiId \(target.chatId); the local record was not deleted")
            return false
        }
        do {
            // `.cidmInternal` = 只删本机这一份，不向对方广播删除（同 POPOPXApp.swift:65-73）。
            let deletions = try await apiDeleteChatItems(
                type: chat.chatInfo.chatType,
                id: chat.chatInfo.apiId,
                scope: chat.chatInfo.groupChatScope(),
                itemIds: [target.itemId],
                mode: .cidmInternal
            )
            for deletion in deletions {
                if let toItem = deletion.toChatItem {
                    _ = model.upsertChatItem(chat.chatInfo, toItem.chatItem)
                } else {
                    model.removeChatItem(chat.chatInfo, deletion.deletedChatItem.chatItem)
                }
                model.updateChatInfo(deletion.deletedChatItem.chatInfo)
            }
            return true
        } catch {
            // 这条日志是验收口径："看完但没删掉"的全部发生次数都由它统计。
            logger.error("POPOPX profile: apiDeleteChatItems failed \(responseError(error))")
            return false
        }
    }

    /// 焚毁页停留时长（纳秒）。放在这里是因为只有本类会拆窗口。
    private static var autoDismissNanoseconds: UInt64 {
        UInt64(PopopxProfileReaderModel.burnNoticeSeconds * 1_000_000_000)
    }
}

// MARK: - 阅读状态的投影

/// 这一组投影被两个文件共用（卡片在这里判"该不该画成已焚毁"），所以是 `internal` 而不是
/// `private extension`——`private` 在扩展上等于"本文件私有"，卡片那份文件拿不到。
extension PopopxProfileReadState {
    /// 这一格是否已经不该再读了。卡片与宿主共用这一条判据，免得两处对"过期"各有定义。
    var blocksReading: Bool {
        switch self {
        case .unread, .counting: return false
        case .expired, .clockRewound: return true
        }
    }
}

// MARK: - 窗口根视图

/// 窗口根。隐私档从**外面**包一层护盾：护盾的职责是把内容搬进"系统采集不到"的那块画布，
/// 内容自己在里面滚，正合它的用法（PopopxScreenCaptureShieldView.swift:61-76）。
private struct PopopxProfileReaderRootView: View {
    private let model: PopopxProfileReaderModel

    init(model: PopopxProfileReaderModel) {
        self.model = model
    }

    var body: some View {
        if model.privacyRead {
            PopopxScreenCaptureShieldView {
                ProfileReaderView(model: model)
            }
            .background(Color.black)
        } else {
            ProfileReaderView(model: model)
        }
    }
}

// MARK: - 阅读器版式

/// 名片的阅读面。
///
/// 版式自己手搭而不套 `PopopxSheetContainer`：那一个把内容整块包进 `ScrollView`
/// （PopopxControls.swift:758-763），而这里的图片格要放 `ZoomableScrollView`（也是一个
/// `UIScrollView`）——ScrollView 套 ScrollView 在 gesture 期就是"滚不动"或"抢滚"。
/// 手搭的代价是顶栏与圆角要自己画，先例就是 `PopopxSecureSheetView` 干的同一件事。
@MainActor
struct ProfileReaderView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable private var model: PopopxProfileReaderModel

    init(model: PopopxProfileReaderModel) {
        self.model = model
    }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            columns
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // 盲水印。这里**叠在最上层**：它自己的注释（PopopxAntiPhotoRenderView.swift:817-821）
            // 说该画在正文底下，但现网真实的用法是 `.overlay` 盖在上头
            //（PopopxSecureSheetView.swift:299-302），跟随真实用法而不是注释。
            if model.privacyRead {
                PopopxBlindWatermarkOverlay(sessionIdentifier: model.sessionIdentifier)
                    .allowsHitTesting(false)
            }
        }
        .task { await model.loadMissingMedia() }
    }

    private var backdrop: some View {
        (model.privacyRead ? Color.black : PopopxPalette.base)
            .ignoresSafeArea()
    }

    private var columns: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.deliveryMode == .meshTextOnly {
                meshBanner
            }
            if model.privacyRead {
                safetyBanner
            }
            scrollArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if !model.isReading {
                closingCover
            }
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(headline)
                    .font(PopopxType.title)
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = model.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(PopopxType.meta)
                        .foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            closeButton
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.top, PopopxMetrics.spaceS)
        .padding(.bottom, PopopxMetrics.spaceXS)
    }

    /// 标题为空时给一个占位词：标题来自对端，里面完全可能整串是空白。
    private var headline: String {
        let trimmed = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Copy.untitled : trimmed
    }

    private var closeButton: some View {
        Button {
            model.requestClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .background(closeFill, in: .circle)
                .overlay(
                    Circle().strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.close)
        .accessibilityIdentifier(model.privacyRead ? "popopx.profile.reader.close" : "popopx.profile.reader.standard.close")
    }

    private var closeFill: Color {
        model.privacyRead ? Color.popopx(0xFFFFFF, opacity: 0.08) : PopopxPalette.cardHigh
    }

    // MARK: 横幅

    /// 厢语离线降级横幅。逐字文案是产品定的，只允许这一处出现。
    private var meshBanner: some View {
        Label {
            Text(Copy.meshOmitted(model.omittedMediaCount))
                .font(PopopxType.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "antenna.radiowaves.left.and.right")
        }
        .foregroundStyle(model.privacyRead ? PopopxSurface.ink : PopopxPalette.meshInk)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PopopxMetrics.spaceS)
        .padding(.vertical, PopopxMetrics.spaceXS)
        .background(
            PopopxPalette.mesh.opacity(model.privacyRead ? 0.18 : 0.12),
            in: .rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
        )
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.bottom, PopopxMetrics.spaceXS)
    }

    /// 隐私档顶部**常驻**的倒计时安全横幅。归零之前它一直在：还剩多少秒必须由屏幕自己说，
    /// 而不是等用户去猜焚毁是什么时候发生的。
    private var safetyBanner: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "timer")
                    .font(PopopxType.meta)
                    .accessibilityHidden(true)
                Text(Copy.countdown(model.remainingSeconds))
                    .font(PopopxType.metric)
                    .accessibilityLabel(Copy.countdownSpoken(model.remainingSeconds))
                Spacer(minLength: PopopxMetrics.spaceXS)
                Text(Copy.countdownTotal(model.totalSeconds))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxSurface.inkTertiary)
            }
            .foregroundStyle(countdownInk)
            // 进度条不用 GeometryReader：`scaleEffect(anchor: .leading)` 就能把一条 Capsule
            // 按剩余比例收掉，而布局宽度不受影响（GeometryReader 会让这一格自己吃掉空间）。
            ZStack(alignment: .leading) {
                Capsule().fill(Color.popopx(0xFFFFFF, opacity: 0.14))
                Capsule()
                    .fill(countdownInk)
                    .scaleEffect(x: max(0.002, 1 - model.progress), y: 1, anchor: .leading)
            }
            .frame(height: PopopxMetrics.space2XS)
            // 走设计系统的开关而不是裸 `.animation`：减弱动态那一条判断只许存在于 `PopopxMotion` 里。
            .popopxAnimation(PopopxSpring.fluid, value: model.remainingSeconds, reduceMotion: reduceMotion)
            if let guardNote = model.guardNote {
                // 降级的实话：少了哪一路就说少了哪一路，不许假装检测有效。
                Label {
                    Text(guardNote)
                        .font(PopopxType.microTag)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
                .foregroundStyle(PopopxSurface.inkSecondary)
                .padding(.top, PopopxMetrics.space2XS)
            }
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .padding(.vertical, PopopxMetrics.spaceXS)
        .background(
            PopopxSurface.cardFill,
            in: .rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
        )
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.bottom, PopopxMetrics.spaceXS)
    }

    private var countdownInk: Color {
        // 最后 5 秒转红。阈值与绝密那一档同一档（PopopxSecureSheetView.swift:278-282 的判据）。
        model.remainingSeconds <= 5 ? PopopxPalette.danger : PopopxSurface.ink
    }

    // MARK: 正文（自己管滚动）

    private var scrollArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                ForEach(model.entries) { entry in
                    row(for: entry)
                }
                if model.entries.isEmpty {
                    Text(Copy.emptyBody)
                        .font(PopopxType.meta)
                        .foregroundStyle(secondaryInk)
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func row(for entry: PopopxProfileReaderEntry) -> some View {
        switch entry.block {
        case let .text(body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let isEmpty = trimmed.isEmpty
            Text(isEmpty ? Copy.emptyTextBlock : trimmed)
                .font(isEmpty ? PopopxType.caption : PopopxType.body)
                .foregroundStyle(isEmpty ? tertiaryInk : ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .image(media):
            PopopxProfileMediaTile(
                kind: media.kind,
                caption: media.caption,
                bytes: media.bytes,
                durationSeconds: nil,
                state: entry.media
            )
        case let .video(media):
            PopopxProfileMediaTile(
                kind: media.kind,
                caption: media.caption,
                bytes: media.bytes,
                durationSeconds: media.durationSeconds,
                state: entry.media
            )
        }
    }

    // MARK: 焚毁盖层

    private var closingCover: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(PopopxPalette.brand)
                .accessibilityHidden(true)
            Text(model.isBurned ? Copy.burnedTitle : Copy.closingTitle)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(ink)
            if let burnedBy = model.burnedBy {
                Text(burnedBy)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxSurface.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            if model.isCleaning {
                Text(Copy.cleaning)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxSurface.inkTertiary)
            } else if model.localRecordDeleted == false {
                // 必须说出来：这一格是"已焚毁"这个声明里唯一可能没做到的部分，蒙过去就等于
                // 让那句声明不再成立（动机同 PopopxSecureWindowManager.swift:75-83）。
                Text(Copy.burnedWithoutDeletion)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(PopopxMetrics.spaceL)
        .frame(maxWidth: .infinity)
        .background(PopopxSurface.cardFill, in: .rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous))
        .padding(.horizontal, PopopxMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(backdrop)
        .accessibilityElement(children: .combine)
    }

    // MARK: 墨色

    /// 安全面上的墨色必须恒定：调色板那几支跟着 colorScheme 翻转，深色模式里 `onBrand` 接近黑、
    /// 浅色模式里 `label` 接近黑，混进护盾就是一屏"某个模式下看不见的名片"。
    /// 所以这里走不翻转的 `Color.popopx(_:)` 重载（同 `PopopxSecureSurface` 那条裁定，
    /// PopopxSecureSheetView.swift:421-434）。
    private var ink: Color {
        model.privacyRead ? PopopxSurface.ink : PopopxPalette.label
    }

    private var secondaryInk: Color {
        model.privacyRead ? PopopxSurface.inkSecondary : PopopxPalette.labelSecondary
    }

    private var tertiaryInk: Color {
        model.privacyRead ? PopopxSurface.inkTertiary : PopopxPalette.labelHint
    }
}

/// 阅读器这一屏的固定表面。与 `PopopxSecureSurface` 同族但**不同源**：绝密那一面是保险柜的门，
/// 名片这一面是可以反复查阅的东西，两处共用一组常量迟早让一次改动同时改掉两个特性。
private enum PopopxSurface {
    static let ink = Color.popopx(0xF4F4F6)
    static let inkSecondary = Color.popopx(0xA6A6B0)
    static let inkTertiary = Color.popopx(0x8A8A94)
    static let cardFill = Color.popopx(light: 0x1A1030, dark: 0x140C26)
}

// MARK: - 媒体贴片

/// 一格媒体。图片可缩放（复用现网 `ZoomableScrollView`，Shared/Views/ZoomableScrollView.swift:12），
/// 视频复用现网 `VideoPlayerView`（Shared/Views/Helpers/VideoPlayerView.swift:12，
/// 内联用法先例 CIVideoView.swift:209）——本特性不新造播放器，也不新造缩放器。
private struct PopopxProfileMediaTile: View {
    /// 缩放区的高度上限：两屏高的图会把倒计时那一栏顶出屏幕。
    private static let mediaMaxHeight: CGFloat = 420
    private static let mediaMinHeight: CGFloat = PopopxMetrics.space2XL * 3
    /// 视频格按 4:3 留位：导出预设就是 `AVAssetExportPreset640x480`（ProfileStorageManager.swift:332），
    /// 按它的实际比例留位，不另猜一个 16:9。
    private static let videoAspectRatio: CGFloat = 640.0 / 480.0

    let kind: PopopxProfileMedia.Kind
    let caption: String?
    let bytes: Int
    var durationSeconds: Int?
    let state: PopopxProfileReaderMedia

    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            media
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 解码离开主线程：一张 2 MiB 的 JPEG 不该在滚起来的时候占住那一帧。
        .task(id: url) { image = await Self.decode(url: url, kind: kind) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var media: some View {
        switch state {
        case .pending:
            placeholder(systemImage: kind == .video ? "play.rectangle" : "photo", note: Copy.loadingMedia)
        case .omitted:
            // 降级省掉的格子正常不会走到这里（上层已经按 `.meshTextOnly` 只排文字）。
            // 真走到了也不画空白格，而是画成"本机没有原件"——那正是它此刻的事实。
            placeholder(systemImage: "photo", note: Copy.mediaMissing)
        case let .unavailable(_, reason):
            placeholder(systemImage: "exclamationmark.triangle", note: reason)
        case .image:
            if let image {
                ZoomableScrollView {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: Self.mediaMinHeight, maxHeight: Self.mediaMaxHeight)
                .clipShape(.rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
            } else {
                placeholder(systemImage: "photo", note: Copy.mediaUnreadable)
            }
        case let .video(url):
            VideoPlayerView(
                player: VideoPlayerView.getOrCreatePlayer(url, false),
                url: url,
                showControls: true
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(Self.videoAspectRatio, contentMode: .fit)
            .clipShape(.rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
        }
    }

    @ViewBuilder private var footer: some View {
        let meta = Self.metaText(bytes: bytes, durationSeconds: durationSeconds)
        if let caption, !caption.isEmpty {
            Text(caption)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !meta.isEmpty {
            Text(meta)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelHint)
        }
    }

    private var url: URL? {
        switch state {
        case let .image(url): return url
        case let .video(url): return url
        case .pending, .omitted, .unavailable: return nil
        }
    }

    private func placeholder(systemImage: String, note: String) -> some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: systemImage)
                .font(PopopxType.title)
                .accessibilityHidden(true)
            Text(note)
                .font(PopopxType.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(PopopxPalette.labelHint)
        .frame(maxWidth: .infinity, minHeight: Self.mediaMinHeight)
        .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }

    private static func metaText(bytes: Int, durationSeconds: Int?) -> String {
        var parts: [String] = []
        if bytes > 0 { parts.append("\(max(1, bytes / 1_024)) KB") }
        if let durationSeconds { parts.append(PopopxSecureCopy.duration(durationSeconds)) }
        return parts.joined(separator: " · ")
    }

    /// 只有图片需要解码：视频的轨由 `AVPlayerViewController` 自己拉，这里再解一次就是白花一遍内存。
    private static func decode(url: URL?, kind: PopopxProfileMedia.Kind) async -> UIImage? {
        guard let url, kind == .image else { return nil }
        return await Task.detached(priority: .utility) {
            UIImage(contentsOfFile: url.path)
        }.value
    }
}

// MARK: - 文案

private enum Copy {
    static let untitled = NSLocalizedString("Untitled profile page", comment: "reader title fallback")
    static let close = NSLocalizedString("Close", comment: "reader close button")
    static let emptyProfile = NSLocalizedString("This profile page has nothing to show", comment: "reader empty state")
    static let emptyBody = NSLocalizedString("This profile page has no content blocks.", comment: "reader empty state")
    static let emptyTextBlock = NSLocalizedString("(empty text block)", comment: "reader empty block placeholder")
    static let loadingMedia = NSLocalizedString("Reading the original kept on this device…", comment: "reader media placeholder")
    static let mediaMissing = NSLocalizedString("Media not kept on this device: this slot was never written here when the message arrived", comment: "reader media placeholder")
    static let mediaUnreadable = NSLocalizedString("Media not kept on this device: the local file cannot be read", comment: "reader media placeholder")
    static let cleaning = NSLocalizedString("Deleting the local record and the originals…", comment: "reader burn progress")
    static let burnedTitle = NSLocalizedString("Burned after reading", comment: "reader closing sheet title")
    static let closingTitle = NSLocalizedString("Closing", comment: "reader closing sheet title")
    static let burnedWithoutDeletion = NSLocalizedString("The plaintext and the originals were cleared, but this device's message row could not be deleted; open the chat again to confirm", comment: "reader burn warning")
    static let burnedByClockRewound = NSLocalizedString("This device's clock was changed; the content was destroyed", comment: "reader burn reason")
    static let antiSpyOffNote = NSLocalizedString("This profile page does not use the front camera watch; only screenshot and screen recording detection stay on.", comment: "reader privacy note")

    /// 厢语降级那一句是逐字文案，只允许这一处出现。
    static func meshOmitted(_ count: Int) -> String {
        String(format: NSLocalizedString("Received offline over the Bluetooth mesh; %lld images or videos were skipped automatically to keep delivery fast with no network", comment: "reader degraded delivery banner"), count)
    }

    static func countdown(_ seconds: Int) -> String { String(format: NSLocalizedString("Burn after reading · %lld seconds left", comment: "reader countdown"), seconds) }
    static func countdownSpoken(_ seconds: Int) -> String { String(format: NSLocalizedString("Burn-after-reading countdown, %lld seconds left", comment: "reader countdown, spoken"), seconds) }
    static func countdownTotal(_ seconds: Int) -> String { String(format: NSLocalizedString("Readable for %@ after opening", comment: "reader countdown total"), PopopxSecureCopy.duration(seconds)) }
}
