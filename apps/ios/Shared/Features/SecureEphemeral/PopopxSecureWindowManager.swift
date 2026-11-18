//
//  PopopxSecureWindowManager.swift
//  POPOPX (iOS)
//
//  【模块五的宿主侧】独立窗口 + 生物识别前置检查 + 销毁编排。
//
//  这是整个特性里唯一"拥有一次明文"的地方。明文从 `payload.open()` 出生，到
//  `popopxSecureErase` 死亡，全程只被本类的这一个 `Data?` 持有；`PopopxSecureSheetModel`
//  拿到的是**已经解码好的 String**（值类型，随窗口一起消失），列表里则永远只有密文行。
//  "唯一持有者"不是风格问题：多一处持有，就多一处会忘了擦的地方。
//
//  ### 为什么宿主契约走 `.shared` 单例而不是 Environment
//  物理删除记录和发回执必须由宿主提供（`apiDeleteChatItems` / `apiSendMessages` 都在 app target 里），
//  而 SwiftUI 的 Environment 里**不能放闭包**（闭包没有稳定身份，每次写入都会让整棵子树失效——
//  `swiftui-expert-skill` 的硬规矩）。所以：
//  - 气泡视图只需要 `PopopxSecurePayload`（纯值），渲染不需要宿主；
//  - 轻触卡片时 `await PopopxSecureWindowManager.shared.present(payload:target:)`，
//    参数是一个纯值的 `PopopxSecureChatTarget`，**返回值就是失败原因**：卡片是用户点的那一处，
//    反馈必须落在那里，而不是落在一个还没出现的窗口上；
//  - 闭包（删除、发回执）在 `POPOPXApp.init()` 里 `install(host:)` 一次，和本仓库
//    `PopopxMeshRuntime.shared` / `ChatModel.shared` 同一个形状。
//  附带的好处：`Shared/Features/SecureEphemeral/` 整个目录不 import 任何 app 类型，
//  于是 `swiftc -typecheck` 能脱离 Xcode 工程验证它——在本仓库这等于免费的可测性。
//
//  ### fail-closed：装不起就不给看
//  `hostHooks == nil` 时 `present` 直接返回 `.hostNotInstalled`。理由：一条"看完不能销毁、
//  出事也不能发回执"的绝密消息，比一条看不到的消息更危险——它会让人以为这套机制在起作用。
//  Release 包被调试器附加（`PopopxAntiDebug.allowsSecurePresentation == false`）同理拒绝。
//
//  ### 两个状态标志，各自存在的理由
//  - `isSessionActive`：明文与侧信道（倒计时、摄像头值守、录屏轮询）还活着。
//    **所有**入站回调的第一句都是它。
//  - `isWindowOpen`：窗口还存在。销毁告警走完"擦明文 + 删记录 + 发回执"之后，窗口要再留
//    `burnLingerSeconds` 把"为什么关"说完；这段时间里会话已经死了，但窗口还开着。
//  合成一个标志会立刻出两类 bug：要么用户看不到销毁原因，要么在 lingering 的三秒里
//  第二次点卡片能开出第二个会话（所以 `present` 判的是 `isWindowOpen`，不是 `isSessionActive`）。
//
//  ### 倒计时用单调钟
//  `ProcessInfo.processInfo.systemUptime`（自启动起算、含睡眠、改系统时间不影响它）。
//  用墙钟的话，把时间往后调 1 小时就能白看一条绝密消息——这是本特性最容易随手写错、
//  又最难在评审里看出来的地方，所以写在文件头。
//  诚实的边界：app 被挂起时这一路没有 tick，明文会在后台活过 TTL 直到进程恢复。
//  这正是 `leftForeground` 默认销毁存在的理由，见 `PopopxSecureSettings.destructiveOnBackground`。
//
//  ### 三条已核对的 UIKit 事实（都曾在第一版里写错，靠 SDK 头文件纠正）
//  - 独立窗口用 `UIWindow(windowScene:)`（iOS 13+）。`initWithFrame:` 在 iOS 26 起已标废弃，
//    而 `UIWindow(screen:viewerIdentifier:)` 在本工程 iOS 17 下限上根本不存在。
//  - `UIWindow.Level` 是 `CGFloat` 的 typed extensible enum，**不支持 `+`**：
//    `.alert + 1` 编译不过，必须走 `UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)`。
//  - `@MainActor` 类的 `deinit` **不是**主线程隔离域：里面调 actor 方法是硬错误
//    （`-swift-version 5` 也一样拒），所以收尾只能走 `dismissSecureWindow()`。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import AVFoundation
import LocalAuthentication
import SwiftUI
import UIKit

// MARK: - 宿主契约

/// 一条绝密消息在宿主数据模型里的位置。纯值、不含 app 类型：本目录因此可以脱离工程做类型检查，
/// 由宿主（气泡那侧的 `PopopxBubbleMount`）在调用点把**收件方自己**的 `ChatInfo.id` 映射进来。
struct PopopxSecureChatTarget: Hashable, Sendable {
    /// 宿主的会话键，原样取 `ChatInfo.id`（`POPOPXChat/ChatTypes.swift:2104`-`:2112`，
    /// 每个 `ChatInfo` 分支各自给出，如 `"@\(contactId)"`）。
    ///
    /// 为什么只带这一格，而不是带 `chatType` + `chatApiId` 两份再让宿主拼回去：
    /// 拼键等于在本特性里重写一遍 `ChatInfo.id` 的实现。那实现一旦和上游漂移
    /// （比如上游改了 `contactConnection` 的前缀），删除请求会**静默打到另一个会话上**——
    /// 这是这套机制里唯一一处"错了也不报错"的方向，所以宁可只用生成方自己产出的那一个值。
    /// 由 `chatModel.getChat(chatId)` 反查，`chatType` / `apiId` / 群里的 `scope` 全都在那一条记录上。
    let chatId: String
    /// 该条消息的 itemId；nil = 宿主给不出。
    ///
    /// 这一格决定了"物理删除"能不能做。给不出时本类**不谎称删了**：遮罩会写明
    /// "明文已擦除、本机记录未删除"（见 `PopopxSecureCopy.burntWithoutDeletion`）。
    /// 这不是装饰：把"没删成"显示出来是"这条已经被焚毁"这句话仍然成立的前提。
    let itemId: Int64?

    /// 能不能定位到要删的那条记录。
    var isDeletable: Bool { itemId != nil }
}

/// 宿主必须提供的两件事，都在**主线程**被调用。
struct PopopxSecureHostHooks {
    /// 物理删除本地记录。宿主实现：`apiDeleteChatItems(mode: cidmInternal)` + `ChatModel.removeChatItem`。
    ///
    /// 只负责发起，不必等待：本类不等它的结果，因为"明文已擦"与"队列已删"是两件事，
    /// 前者在调用返回之前已经完成，后者是网络/DB 的事。
    var deleteItem: (_ target: PopopxSecureChatTarget) -> Void
    /// 发一条安全回执。宿主实现走既有发送链，因此在线 SMP 与离线 mesh 双模自动都覆盖。
    var sendReceipt: (_ text: String, _ target: PopopxSecureChatTarget) -> Void
}

/// 会话级安全档位。刻意不落 `UserDefaults`：这几条的默认值全是"最保守"的，一旦做成可持久化的开关，
/// 就得同时回答"用户关掉值守之后要不要在气泡上留痕"——那是下一个特性的范围，不是这个文件的。
struct PopopxSecureSettings: Hashable, Sendable {
    /// `leftForeground` 是否也销毁。
    ///
    /// 关掉之后仍然**不是**安全的选择：见文件头"诚实的边界"——挂起时倒计时不动，
    /// 明文会活过 TTL。所以界面里这一档要么不给关，要么关的时候必须把这句话一起显示给用户。
    var destructiveOnBackground = true
    /// 是否启动前置摄像头值守（模块三）。关掉 = 只保留截屏/录屏检测（模块四）。
    var cameraGuardEnabled = true
    /// CoreML 那一路的整档开关（模型没导入时引擎自己会降级，这个开关是给用户的关闭入口）。
    var objectDetectionEnabled = true
    /// 高光兜底那一路的整档开关。
    var glareDetectionEnabled = true
    /// 防滚动快门（模块六）是否默认开。
    var antiPhotoEnabled = true

    static let `default` = PopopxSecureSettings()
}

/// 打不开绝密消息的原因。由 `present` **返回**给调用它的那张卡片显示，
/// 不能只是"点了没反应"。
enum PopopxSecurePresentationFailure: Error, Hashable, Sendable {
    /// 宿主没装。用户看不到这条（代码集成问题），但 debug 包日志里必须能搜到。
    case hostNotInstalled
    /// 屏幕正被录制/镜像：在被录下来的画面上显示明文是不可接受的。
    case screenCaptured
    /// Release 包检测到调试器附加。
    case debuggerAttached
    /// 生物识别不可用（没录入，或系统拒绝）。
    case biometricsUnavailable
    /// 用户取消了生物识别。
    case biometricsCancelled
    /// 生物识别失败（匹配不上）。
    case biometricsFailed
    /// 密文被改过、密钥不对、或长度不合法：载荷本身坏了。
    case payloadDamaged(PopopxSecureError)
    /// 取不到可承载窗口的 scene（scene 正在切换，或多 scene 状态下没有前台活跃窗口）。
    case noPresentationContext
    /// 已经有一条在看了。不排队、不叠加：两条明文同时在屏幕上不是"阅后即焚"。
    case sessionAlreadyOpen

    var userText: String {
        switch self {
        case .hostNotInstalled: return "安全模块未就绪，已拒绝显示绝密内容"
        case .screenCaptured: return "检测到屏幕正在被录制或镜像，已拒绝显示"
        case .debuggerAttached: return "检测到调试环境，已拒绝显示绝密内容"
        case .biometricsUnavailable: return "这台设备没有可用的生物识别，无法打开绝密消息"
        case .biometricsCancelled: return "已取消验证"
        case .biometricsFailed: return "生物识别未通过"
        case .payloadDamaged: return PopopxSecureCopy.cardDamaged
        case .noPresentationContext: return "当前界面状态无法打开绝密窗口"
        case .sessionAlreadyOpen: return "已有一条绝密消息在查看中"
        }
    }

    /// 该不该把这张卡片永久标成"已损坏"。只有载荷本身有问题才标——
    /// 用户取消验证、或屏幕正在被录制，都不该让一条正常消息在列表里变成灰色废块：
    /// 那是把环境的错记到消息头上，而且会掩盖"这条其实还能看"的事实。
    var marksCardDamaged: Bool {
        if case .payloadDamaged = self { return true }
        return false
    }
}

// MARK: - 管理器

/// 绝密窗口的唯一所有者。`@MainActor`：窗口、生物识别、销毁、UI 全在主线程；
/// 唯一离开主线程的是 `PopopxCameraGuardEngine` 的帧队列，而它自己已经把结果 hop 回来了。
@MainActor
final class PopopxSecureWindowManager {
    static let shared = PopopxSecureWindowManager()

    /// 明文与侧信道是否还活着。见文件头"两个状态标志"。
    private var isSessionActive = false
    /// 窗口是否存在。`present` 用它拒绝并发会话。
    private var isWindowOpen = false

    private var window: UIWindow?
    private var sheetModel: PopopxSecureSheetModel?
    private var guardEngine: PopopxCameraGuardEngine?
    private var captureMonitor: PopopxCaptureMonitor?
    private var countdownTimer: Timer?
    private var burnTimer: Timer?
    private var foregroundObserver: NSObjectProtocol?
    private var hostHooks: PopopxSecureHostHooks?
    private var settings = PopopxSecureSettings.default

    /// 本次会话对应的那条消息。放在管理器而不是模型里：销毁路径上模型可能已经被 SwiftUI 断开，
    /// 而"删哪条记录"不能跟着 UI 一起丢。
    private var activeTarget: PopopxSecureChatTarget?

    /// 明文的唯一持有者。`private`、无 getter：外部拿到明文的唯一途径是 `sheetModel`
    /// 里那个已经解码好的 String，而它随窗口一起释放。
    private var plaintext: Data?

    /// 截止时刻（`systemUptime` 秒）。0 = 没有会话。
    private var deadlineUptime: Double = 0

    private init() {}

    deinit {
        // 本类是 `shared` 单例，正常永不 deinit。
        //
        // 这里**不能**调 `captureMonitor?.stop()` / `guardEngine?.stopMonitoring()` / `stopChannels()`：
        // `@MainActor` 类的 `deinit` 不在主线程隔离域里，Swift 把这判成错误而不是警告
        // （第一版就是这么写的，被类型检查挡下）。这正是"收尾必须走 `dismissSecureWindow()`"
        // 这条约定的强制形式；真正的释放发生在 `dismissSecureWindow()` 和那两个对象自己的
        // `deinit` 里（`PopopxCameraGuardSession`、`PopopxFrameTicker` 各带回收断言）。
        //
        // 能做且该做的两件无需隔离的事：把明文擦掉，把计时器停掉。
        popopxSecureErase(&plaintext)
        countdownTimer?.invalidate()
        burnTimer?.invalidate()
    }

    // MARK: 装配

    /// 宿主在 `POPOPXApp.init()` 装一次即可。后装覆盖先装：app 里可能出现多个宿主 scene，
    /// 最后装配的那个才是当前有效的。
    func install(host: PopopxSecureHostHooks, settings: PopopxSecureSettings = .default) {
        hostHooks = host
        self.settings = settings
    }

    // MARK: 呈现

    /// 走完前置检查并弹出绝密窗口。返回 nil = 已显示；返回失败原因 = 什么都没打开。
    ///
    /// 顺序是刻意的，每一步都可能拒：
    /// 1. 有没有窗口在（含 lingering 期，所以判 `isWindowOpen`）
    /// 2. 宿主装了没有（没装就拒，见文件头 fail-closed）
    /// 3. 屏幕在不在被录制——一次同步读 `isCaptured`，比等 60Hz 轮询早一帧拒掉
    /// 4. 反调试
    /// 5. 摄像头权限（只有没问过时才在这里问，见下面那条注释——它必须排在窗口之前）
    /// 6. 取窗口 scene（取不到就拒，不"退回第一块屏"）；排在权限之后，
    ///    因为权限弹框会挂起不确定的时间，scene 要等到真要开窗那一刻再取
    /// 7. 生物识别
    /// 8. **解密排在验证通过之后、窗口显示之前**，中间没有任何 await：
    ///    先解密再验证等于把明文多留一段无人看守的时间，而 FaceID 弹框那几百毫秒里
    ///    屏幕上本来就不该有任何内容。
    /// 9. 窗口可见之后才开摄像头值守与录屏轮询——"只在弹窗可见期间运行"这条硬约束的落点。
    func present(payload: PopopxSecurePayload, target: PopopxSecureChatTarget) async -> PopopxSecurePresentationFailure? {
        guard !isWindowOpen else { return .sessionAlreadyOpen }
        guard hostHooks != nil else { return .hostNotInstalled }
        guard !PopopxScreenCapture.anyScreenIsCaptured else { return .screenCaptured }
        guard PopopxAntiDebug.allowsSecurePresentation else { return .debuggerAttached }

        // 摄像头权限必须在这里问，而不是等 `startMonitoring()` 报 `.permissionNotDetermined`：
        // 那条链路只读状态、从不发起授权，所以不主动问的话，全新安装的机器上画面级值守
        // **永远不会开起来**（系统弹框只有一次机会，且只能由 `requestAccess` 触发）。
        // 而它必须排在窗口之前：绝密窗口的 level 是 `.alert + 1`，权限框会被压在它下面，
        // 那时用户既看不见这个框、也点不到"允许"。
        if settings.cameraGuardEnabled,
           AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            await Self.awaitCameraAccess()
        }

        guard let scene = Self.currentWindowScene() else { return .noPresentationContext }

        switch await verifyBiometrics() {
        case .success: break
        case .cancelled: return .biometricsCancelled
        case .unavailable: return .biometricsUnavailable
        case .failed: return .biometricsFailed
        }

        var opened: Data
        do {
            opened = try payload.open()
        } catch let error as PopopxSecureError {
            return .payloadDamaged(error)
        } catch {
            return .payloadDamaged(.decryptionFailed)
        }
        // 解码 + UTF-8 校验都在同一个同步段里做完，`plaintext` 的暴露窗口等于窗口本身的寿命。
        guard let text = String(data: opened, encoding: .utf8), !text.isEmpty else {
            popopxSecureErase(&opened)
            // 这里不是 `decryptionFailed`：能走到这一句说明 tag 已经验过、密钥就是这条消息的密钥。
            return .payloadDamaged(.unusablePlaintext)
        }

        isSessionActive = true
        isWindowOpen = true
        plaintext = opened
        activeTarget = target
        deadlineUptime = ProcessInfo.processInfo.systemUptime + Double(payload.ttlSeconds)

        let model = PopopxSecureSheetModel(
            text: text,
            totalSeconds: payload.ttlSeconds,
            antiPhotoEnabled: settings.antiPhotoEnabled,
            close: { [weak self] in self?.closeAndBurn() }
        )
        sheetModel = model

        let controller = UIHostingController(rootView: PopopxSecureShieldedContent(model: model))
        // 背景必须是黑：`UIHostingController` 的默认底色是系统灰，绝密窗口要的是"除内容外全黑"，
        // 而护盾视图自己画的也是黑底——留一个灰色系统底色等于留一个"内容区外不是纯黑"的破口。
        controller.view.backgroundColor = .black
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        // `.alert + 1`：绝密窗口必须压在 app 内所有弹窗（相册/位置选择器、系统权限框）之上，
        // 否则一次系统弹窗就把明文盖在下面、倒计时照走，用户回来只看到一句"已销毁"。
        // `UIWindow.Level` 不支持 `+`，所以走 rawValue。
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        // 外观跟随宿主窗口：一个孤立窗口默认拿设备外观，app 里强制浅色/深色时这里会错位。
        // 必须在 `isHidden = false` **之前**读，否则读到自己（我们已经是 keyWindow）。
        window.overrideUserInterfaceStyle = Self.inheritedInterfaceStyle(from: scene)
        window.isHidden = false
        self.window = window

        startSideChannels(in: window, model: model)
        startCountdown()
        PopopxHaptics.notice(.success)
        return nil
    }

    // MARK: 收尾

    /// 用户主动关闭、或倒计时归零：一样焚毁——"阅后即焚"的"焚"不由用户决定。
    /// 不发安全回执：正常看完不是安全事件，发出去只会让对面以为出事了。
    /// 也不留 lingering：没什么要解释的，多留一个黑屏只是挡路。
    private func closeAndBurn() {
        burn(reason: nil, receipt: nil, linger: false)
    }

    /// 焚毁的唯一路径。
    ///
    /// **先擦再删再发**：本地记录被删掉之前明文已经不在内存里，这样"删除失败"的最坏结果
    /// 是留下一条打不开的密文，而不是留下一段还在内存里的明文。
    /// 宿主闭包先取成局部量：销毁路径上如果 `hostHooks` 被改成 nil，`?` 会让这条消息
    /// 静默地既不删也不发——那正是"用户以为销毁了"的场景。
    ///
    /// `willDestroy` 必须在 `stopChannels()` **之前**读：lingering 那几秒里用户按"好"会再走一遍
    /// 这个函数，而"删除记录"和"发回执"只属于会话死亡的那一刻，做一次。
    /// 少了这道闸的后果不是崩，是**同一条消息删两次、对面收到两条一模一样的告警**。
    private func burn(reason: String?, receipt: String?, linger: Bool) {
        guard isSessionActive || isWindowOpen else { return }
        let willDestroy = isSessionActive
        let target = activeTarget
        let hooks = hostHooks
        stopChannels()

        guard willDestroy else {
            dismissSecureWindow()
            return
        }
        let deleted = target?.isDeletable ?? false
        if deleted, let target {
            hooks?.deleteItem(target)
        }
        if let receipt, let target {
            hooks?.sendReceipt(receipt, target)
        }
        sheetModel?.burn(reason: reason, receiptCount: receipt == nil ? 0 : 1, deleted: deleted)

        if linger {
            scheduleBurnTeardown()
        } else {
            dismissSecureWindow()
        }
    }

    /// 关闭绝密窗口并**确定性地**释放一切。幂等：重复调用只做一次。
    ///
    /// 顺序：先 `stopChannels()`（落标志 → 停计时 → 摘通知 → 停轮询 → 停值守 → 擦明文），
    /// 再交还模型，最后拆窗口。
    /// 擦明文排在拆窗口**之前**：`UIHostingController` 拆下去时 SwiftUI 还会读一次视图状态，
    /// 那一次读必须读到已经空了的模型。
    func dismissSecureWindow() {
        stopChannels()
        guard isWindowOpen else { return }
        isWindowOpen = false

        sheetModel?.invalidate()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        sheetModel = nil
        activeTarget = nil

        #if DEBUG
        // 回收断言：会话结束后这几样必须都是空的。真机上"绿点还亮着""窗口还在"这类问题
        // 全部会先在这里变成一条能搜到的日志。
        print("[popopx.secure] session closed: engine=\(guardEngine == nil) monitor=\(captureMonitor == nil) plaintext=\(plaintext == nil) window=\(window == nil)")
        #endif
    }

    /// 只停"会读明文、会占硬件"的那一半：倒计时、销毁延时、后台通知、录屏轮询、摄像头值守、明文本体。
    /// 窗口留着不拆——销毁告警得先把"为什么关"说完。
    ///
    /// 值守排在录屏轮询之后停、且都在擦明文**之前**：这两个对象持有回调，而回调读的是明文；
    /// 反过来写会得到"明文已没了但还在收帧"，收帧那条链路仍可能把告警投进来。
    private func stopChannels() {
        guard isSessionActive else { return }
        isSessionActive = false

        countdownTimer?.invalidate()
        countdownTimer = nil
        burnTimer?.invalidate()
        burnTimer = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }

        captureMonitor?.stop()
        captureMonitor = nil
        // 值守内部的停止顺序（标志 → 摘 delegate → stopRunning → 放引用）见
        // `PopopxCameraGuardEngine.stopMonitoring()`，这里只负责不再持有它。
        guardEngine?.stopMonitoring()
        guardEngine = nil

        deadlineUptime = 0
        popopxSecureErase(&plaintext)
    }

    /// 已焚相位停留几秒再拆窗口，让用户看清是"哪一类风险"触发了销毁。
    /// 这段时间没有明文、没有摄像头、没有倒计时，剩下的只有一块黑底和一句话。
    private func scheduleBurnTeardown() {
        let timer = Timer(timeInterval: Self.burnLingerSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissSecureWindow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        burnTimer = timer
    }

    /// 3 秒。够读完两行字（`PopopxSecureCopy` 的遮罩文案最长约 20 个汉字），
    /// 又短到不会让人以为 app 卡住。定在这一点上还有一层：它比最短一档 TTL(5 秒) 短，
    /// 所以这条延时永远不会让"销毁"这件事看起来比消息本身活得更久。
    private static let burnLingerSeconds: TimeInterval = 3

    // MARK: 事件

    /// 三个来源共用一个入口：截屏/录屏（模块四）、摄像头值守（模块三）、倒计时归零。
    private func handle(_ alert: PopopxSecurityAlert) {
        guard isSessionActive else { return }
        let destroys = alert.destroysMessage
            || (alert == .leftForeground && settings.destructiveOnBackground)

        guard destroys else {
            // 只锁不销毁：倒计时继续走（理由见 `PopopxSecureSettings.destructiveOnBackground`），
            // 且这一档唯一的动作是关闭并销毁——"解锁继续看"得再走一次生物识别，
            // 那应该由用户重新点卡片发起，而不是在这里再造一个状态机。
            sheetModel?.lock(reason: alert.reasonText)
            PopopxHaptics.notice(.warning)
            return
        }
        PopopxHaptics.notice(.error)
        burn(reason: alert.reasonText, receipt: alert.receiptText, linger: true)
    }

    // MARK: 侧信道

    private func startSideChannels(in window: UIWindow, model: PopopxSecureSheetModel) {
        let monitor = PopopxCaptureMonitor()
        monitor.onAlert = { [weak self] alert in
            Task { @MainActor in self?.handle(alert) }
        }
        monitor.start(in: window)
        captureMonitor = monitor

        // 进后台 = `leftForeground`。唯一一条可能"只锁不销毁"的告警，理由见 `PopopxSecureSettings`。
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handle(.leftForeground) }
        }

        guard settings.cameraGuardEnabled else {
            model.guardNote = "摄像头值守已按设置关闭，仅截屏/录屏检测在工作。"
            return
        }
        let engine = PopopxCameraGuardEngine()
        engine.onAlert = { [weak self] alert in
            Task { @MainActor in self?.handle(alert) }
        }
        engine.settings = PopopxCameraGuardSettings(
            objectDetectionEnabled: settings.objectDetectionEnabled,
            glareDetectionEnabled: settings.glareDetectionEnabled
        )
        // 起不来不能当没事：少了哪一路、为什么少，必须让用户看见。
        if let failure = engine.startMonitoring() {
            model.guardNote = failure.reasonText
        } else {
            model.guardNote = engine.startupNote
        }
        guardEngine = engine
    }

    // MARK: 倒计时

    private func startCountdown() {
        // 先同步走一次：`Timer` 第一次触发要等满一个间隔，那 0.1 秒里界面会显示铸造时的
        // `remainingSeconds = totalSeconds`，而不是载荷真正给的那一档。
        tick()
        // 0.1s 的 `Timer` 而不是 60Hz 的 `CADisplayLink`：倒计时要的是"到点就销毁"，
        // 逐帧驱动只会多占一个 runloop 源，而显示用的数字一秒变一次就够。
        // （模块六的聚光/逐行渲染确实需要逐帧，那边用的是 `PopopxFrameTicker`。）
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // 闭包不捕获模型：`tick()` 每次都从 `sheetModel` 读，模型没了它自然就不干活。
        // 在这里强捕获一份只是多给明文的入口对象加一个持有者。
        // `.common` mode：手指按住滚动时也要走。挂 `.default` 的话，用户在逐行阅读模式里
        // 按住拖动的那段时间倒计时是停的——那是一条消息白看的真实路径。
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func tick() {
        guard isSessionActive, let model = sheetModel else { return }
        let remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            model.updateRemainingSeconds(0)
            closeAndBurn()
            return
        }
        model.updateRemainingSeconds(Int(remaining.rounded(.up)))
    }

    // MARK: 生物识别

    private enum BiometricResult { case success, cancelled, unavailable, failed }

    /// 用 `.deviceOwnerAuthenticationWithBiometrics`，**不**复用 app 现有的 `systemAuthenticate`：
    /// 那条允许设备密码，而密码会被旁人看着输入，与"绝密"直接冲突。
    /// 宁可让没录生物特征的人看不了，也不降级到密码。
    ///
    /// `LAContext` 的结果不缓存：缓存一次就等于把生物识别降级成启动期门禁，
    /// 而绝密消息的风险窗口在**每一次查看**。
    private func verifyBiometrics() async -> BiometricResult {
        let context = LAContext()
        var statusError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &statusError) else {
            return .unavailable
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: PopopxSecureCopy.biometricReason
            ) ? .success : .failed
        } catch let error as LAError {
            switch error.code {
            // 取消 = 用户没打算看。与"解不开"是两件事，界面上一个给"再试一次"，一个给"这条已经毁了"。
            case .userCancel, .systemCancel, .appCancel, .userFallback:
                return .cancelled
            // 这台设备给不出生物识别：不降级到密码（见上面那条注释），直接拒。
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet:
                return .unavailable
            // 剩下的（.authenticationFailed / .invalidContext / .notInteractive 以及以后新增的）
            // 统一按"这一次没通过"处理，不猜每条的具体含义。
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    // MARK: 环境解析

    /// 承载窗口的 scene。取不到活跃 scene 时返回 nil 让调用方**拒绝呈现**，
    /// 而不是"退回第一块屏"——绝密窗口开在别的屏上等于把明文投到别人桌上。
    /// 残留风险已收敛：外接屏/镜像那一路由 `isCaptured` 在呈现前就拒（顺序第 3 步），
    /// 所以这里不需要再造一层屏选择。
    private static func currentWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) { return active }
        // 非活跃但已存在的 scene 也可以承载：用户点卡片那一刻 app 必然还在前台，
        // 拿不到 active 只可能是 scene 正在切换的瞬间。
        return scenes.first(where: { $0.activationState == .foregroundInactive })
    }

    /// 只等"问完了"，不看答案。授权状态由 `startMonitoring()` 自己再读一次——
    /// 那条链路本来就要判 `.permissionDenied` 并把结果写成 `guardNote` 显示给用户，
    /// 在这里再判一遍只会得到第二个说法。
    private static func awaitCameraAccess() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PopopxCameraGuardEngine.requestCameraAccess { _ in continuation.resume() }
        }
    }

    private static func inheritedInterfaceStyle(from scene: UIWindowScene) -> UIUserInterfaceStyle {
        scene.keyWindow?.overrideUserInterfaceStyle
            ?? scene.windows.first?.overrideUserInterfaceStyle
            ?? .unspecified
    }
}

// MARK: - 窗口内容

/// 窗口的根视图：黑屏护盾包着绝密内容。
///
/// 单独一个类型而不是在 `present` 里现场拼，是为了让泛型参数
/// `PopopxScreenCaptureShieldView<PopopxSecureSheetView>` 落在一个具体声明上——
/// 现场拼出来的类型名只存在于类型检查器的诊断里，日后要看/要改都没有落点。
struct PopopxSecureShieldedContent: View {
    let model: PopopxSecureSheetModel

    var body: some View {
        PopopxScreenCaptureShieldView {
            PopopxSecureSheetView(model: model)
        }
    }
}
