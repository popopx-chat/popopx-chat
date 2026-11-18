//
//  PopopxCameraGuardEngine.swift
//  POPOPX (iOS)
//
//  【模块三】绝密弹窗存续期间的前置摄像头值守：一次采集，三路判定。
//
//  这一层只做三件事，而且只做绝密弹窗打开的那几十秒：
//  1. 以最低功耗档开前置（`.vga640x480` + 10 FPS + 单帧回调、不落盘、不预览），弹窗关闭立刻
//     停流并释放。右上角那颗绿点是 iOS 给用户的知情权，"静默采集"在这台系统上不存在，
//     能承诺的只有"摄像头生命周期严格等于弹窗生命周期"。
//  2. 同一帧里同步跑：`VNDetectFaceRectanglesRequest`（人数）+ CoreML 目标检测（手机/相机）
//     + `PopopxGlareDetector`（镜头高光）。前两个请求交给同一个 `VNImageRequestHandler.perform`
//     才叫并行：Vision 会共用同一份图像预处理，分开跑等于把同一帧解码两遍。
//  3. 判定完把 `PopopxSecurityAlert` 投回主线程。**不自己处置**：锁屏、销毁、发回执
//     全在 `PopopxSecureWindowManager`，引擎只管"看见了什么"。
//
//  ### 模型缺失是正常状态，不是错误
//  `POPOPXAntiSpyDetector.mlmodelc` 要人工跑仓库根的 `scripts/setup_pretrained_coreml.py` 生成
//  （默认写到 `apps/ios/Resources/SecureEphemeral/`），再人工拖进 target
//  （红线：脚本不许碰 `.pbxproj`）。没拖进来时 `objectRequest` 是 nil，
//  本引擎自动只跑"人脸 + 高光"两路，并把 `startupNote` 如实交给界面显示
//  （"目标检测未启用，仅高光反射兜底在工作"），而不是假装一切正常。
//  高光那条正是为这一刻准备的兜底。
//
//  ### 三处如实收窄，别在外面宣传成四种能力
//  - **"主用户离开视角" ≠ 认脸**。本 SDK 的 `VNDetectFaceRectanglesRequest` 只有 `results`
//    一个属性（没有 `minFaceSize`/`accurateDetection` 这类可调项，已在 iPhoneSimulator27.2 SDK
//    头文件里核对过），它给的是框，不是身份。要区分"机主走了"和"换了一个人坐着"需要人脸嵌入
//    模型，而提示词的前提是"无需手动训练模型"。所以这一路判的是**连续 `primaryViewerGrace`
//    秒内一张脸都没有**，文案叫"机主离开视角"，不声称认得出是谁。
//  - **模拟器上这一路完全测不出来**：模拟器没有前置摄像头，`AVCaptureDevice.default(...)`
//    返回 nil，`xcodebuild test` 里本文件只能验到"拒绝启动并给出原因"。真机是唯一证据来源。
//  - **误报是设计的一部分**：0.40 置信度下，桌上一部手机、一个黑色长方形都可能命中。所以每条
//    告警都是**触发即熔断 + 用户可整档关掉**，界面文案只说"检出了什么"，不写"有人在偷拍你"。
//
//  ### 线程与销毁契约（提示词"Lifecycle & Memory Leak Prevention"的落点）
//  - `startMonitoring()` / `stopMonitoring()` 只允许主线程调（`precondition` 强制），
//    这样"停掉了没有"是同步可答的。
//  - 帧回调在 `com.popopx.vision.guard` 这条**串行**队列上；管线对象只被这条队列碰，
//    所以管线内部一把锁都不需要。需要锁的只有主线程写、队列读的那一个 `sessionActive` 标志，
//    以及投递时快照 `onAlert` 那一次。
//  - 停的顺序刻死：先把 `sessionActive` 置 false（排在队列里的残余帧看到这个标志直接丢），
//    再 `setSampleBufferDelegate(nil)`，再 `stopRunning()`，最后放掉会话与管线引用。
//    反过来写会得到"会话已停但回调还在进来"，那是最难查的一种崩溃。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import AVFoundation
import CoreML
import CoreVideo
import Foundation
import Vision

// MARK: - 设置

/// 用户可以裁定的那几档。值类型：`startMonitoring` 把它整体快照进会话，
/// 会话中途不再读外部状态——帧回调里逐帧读设置会带来跨线程可见性问题，而收益是零。
struct PopopxCameraGuardSettings: Hashable, Sendable {
    /// CoreML 目标检测（需要模型已导入）。关掉 = 只跑人脸 + 高光。
    var objectDetectionEnabled = true
    /// 高光热点兜底引擎（纯 CoreImage/Accelerate，零包体积）。
    var glareDetectionEnabled = true
    /// 人数值守。关掉 = 完全不采集，本引擎只剩空壳（绿点也不会亮）。
    var faceGuardEnabled = true
    /// 出现第二张脸就告警。
    var alertOnSecondaryFace = true
    /// 连续多少秒一张脸都没有算"机主离开视角"。0.5 秒是提示词给的数；再短就开始
    /// 把"用户低头看东西"判成风险，再长就失去了意义。
    var primaryViewerGrace: TimeInterval = 0.5

    // 高光的判据阈值（亮度 245、面积占比、圆度 0.72）**不在这里**：它们住在
    // `PopopxGlareConfiguration.default` 里，界面也不提供数字调节。把整份 config 塞进本结构体会
    // 要求那个类型是 `Hashable`，也就是让本文件的形状取决于另一个模块的内部声明方式——
    // 少一处这种耦合，就少一处会静默错掉的接缝。

    static let `default` = PopopxCameraGuardSettings()

    /// 三路全关 = 不该开摄像头。这个判据由 `startMonitoring` 自己算，不只信调用方。
    var requiresCameraAccess: Bool {
        faceGuardEnabled || glareDetectionEnabled || objectDetectionEnabled
    }
}

// MARK: - 启动结果

/// 为什么没能开始值守。界面必须显示这一句，而不是"点了没反应"。
enum PopopxCameraGuardFailure: Error, Hashable, Sendable {
    /// 用户还没决定（`.notDetermined`）。本引擎**不主动弹系统权限框**：绝密弹窗打开的那一刻
    /// 弹一个权限框，等于在最不该打断用户的时机打断他。权限由设置页的显式按钮
    /// （`PopopxCameraGuardEngine.requestCameraAccess`）拿。
    case permissionNotDetermined
    /// 被拒（`.denied`）或受限（`.restricted`）。
    case permissionDenied
    /// 这台设备没有可用的前置摄像头（模拟器，或极少数机型）。
    case noFrontCamera
    /// 会话配不起来（其它进程占着摄像头，或设备无法配置）。
    case sessionUnavailable
    /// 按设置本来就不需要摄像头。
    case notRequired

    var reasonText: String {
        switch self {
        case .permissionNotDetermined: return "尚未授权摄像头"
        case .permissionDenied: return "摄像头权限已关闭，请到系统设置开启"
        case .noFrontCamera: return "这台设备没有前置摄像头"
        case .sessionUnavailable: return "摄像头正被其它 App 使用"
        case .notRequired: return "值守已按设置关闭"
        }
    }
}

// MARK: - 引擎

/// 前置摄像头值守。非 actor：公开方法约定主线程，帧分析全在专用串行队列。
final class PopopxCameraGuardEngine {
    /// 检出一个事件投一次。去重与熔断由窗口管理器做，本层不缓存、不重试。
    /// **只在主线程被调用**（管线已经做过一次 hop）。
    var onAlert: ((PopopxSecurityAlert) -> Void)?

    /// 按设置/权限启动时要用的设置。主线程读写。
    var settings: PopopxCameraGuardSettings = .default

    private let stateLock = NSLock()
    private var sessionActive = false
    private var session: PopopxCameraGuardSession?

    init() {}

    deinit {
        // 宿主漏调 `stopMonitoring()` 的最后一道兜底。放在这里而不是让 deinit 只打日志：
        // `AVCaptureSession` 被 runloop 之外的东西持有，会一直 tick 到进程结束。
        session?.teardown()
    }

    var isMonitoring: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessionActive
    }

    /// 上一次启动时**没能**跑起来的那一路，供界面如实说明。nil = 请求的几路都在跑。
    private(set) var startupNote: String?

    /// 模型没导入却开了目标检测——界面用它决定显示"目标检测未启用"还是什么都不显示。
    var startedWithoutModel: Bool {
        stateLock.lock()
        let running = session
        stateLock.unlock()
        return running.map { !$0.hasObjectDetector } ?? false
    }

    /// 开始值守。返回 nil = 成功；返回原因 = 没开始，界面直接显示 `reasonText`。
    ///
    /// 幂等：已在跑时第二次调用不会新建第二条会话（那等于两路采集抢一个摄像头，
    /// 而且第一条再也拿不到引用，`stopRunning` 无从调起）。
    @discardableResult
    func startMonitoring() -> PopopxCameraGuardFailure? {
        precondition(Thread.isMainThread, "PopopxCameraGuardEngine.startMonitoring 只允许在主线程调用")
        guard !isMonitoring else { return nil }
        let snapshot = settings
        guard snapshot.requiresCameraAccess else { return .notRequired }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: return .permissionNotDetermined
        case .denied, .restricted: return .permissionDenied
        @unknown default: return .permissionDenied
        }

        let pipeline = PopopxGuardPipeline(settings: snapshot, deliver: { [weak self] alert in
            // 帧队列 → 主线程。`onAlert` 在主线程可能被置 nil，所以到主线程后再取一次快照，
            // 而不是在队列上读一个跨线程可变引用。
            DispatchQueue.main.async {
                self?.stateLock.lock()
                let handler = self?.onAlert
                self?.stateLock.unlock()
                handler?(alert)
            }
        })
        let session: PopopxCameraGuardSession
        do {
            session = try PopopxCameraGuardSession(pipeline: pipeline, settings: snapshot)
        } catch let failure as PopopxCameraGuardFailure {
            return failure
        } catch {
            return .sessionUnavailable
        }

        stateLock.lock()
        sessionActive = true
        self.session = session
        stateLock.unlock()

        startupNote = pipeline.startupNote
        session.start()
        return nil
    }

    /// 停止值守并**确定性地**释放。顺序见文件头。
    func stopMonitoring() {
        precondition(Thread.isMainThread, "PopopxCameraGuardEngine.stopMonitoring 只允许在主线程调用")
        stateLock.lock()
        sessionActive = false
        let closing = session
        session = nil
        stateLock.unlock()
        closing?.teardown()
        startupNote = nil
    }

    /// 主动请求摄像头权限。绝密弹窗的打开流程**不**调它（理由见 `permissionNotDetermined`），
    /// 设置页给一个显式按钮调；授权后由调用方决定是否重开值守。
    static func requestCameraAccess(_ completed: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completed(granted) }
        }
    }
}

// MARK: - 管线

/// 一帧进来的全部判定。不是 actor、没有锁：它只活在那条串行队列上，
/// 所有可变状态因此天然单线程。
final class PopopxGuardPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let settings: PopopxCameraGuardSettings
    private let deliver: (PopopxSecurityAlert) -> Void

    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let objectRequest: VNCoreMLRequest?
    private let glareDetector: PopopxGlareDetector?

    /// 界面要看的启动注记。构造时算完就不变，所以能放在 `let` 上、无需同步。
    let startupNote: String?

    /// 上一张"还看得见脸"的时刻。nil = 还没收到过任何一帧，此时绝不判离开
    /// （否则弹窗一开、第一帧未到就先烧一条告警）。
    private var lastFaceSeenAt: Date?
    /// 这一轮"看不见脸"是否已经报过。报过一次就静默，直到脸重新出现——
    /// 否则机主走开之后每帧一条，回执会把会话淹掉。
    private var primaryLossReported = false
    /// 上一次投递的事件与时刻：同一种告警在 `repeatSuppression` 窗口内不重复投。
    private var lastReport: (alert: PopopxSecurityAlert, at: Date)?
    /// 上一次单帧分析耗时，用来决定这一帧要不要跳过 CoreML。
    private var lastAnalysisDuration: TimeInterval = 0
    private var skipObjectDetectionThisFrame = false

    /// 单帧预算。10 FPS 的帧间隔是 100ms，但采集回调排到第 3 帧就已经开始丢画面了，
    /// 所以预算定在 60ms：超时就把下一帧的 CoreML 跳掉，形成 5Hz 的有效目标采样。
    /// 宁可少一路目标检测，也不能让帧队列排到弹窗关闭之后——那才是"绿点灭不掉"的真实成因。
    private static let frameBudget: TimeInterval = 0.06

    /// 同一种告警的最小间隔。熔断本身只发生一次，这条防的是熔断前那 200ms 里
    /// 同一事件被两路各报一次，生成两条一模一样的回执。
    private static let repeatSuppression: TimeInterval = 1.5

    /// 只取这一档人脸数的原因见文件头：不画框、不判身份，`boundingBox` 全程没用过。
    private static let secondaryFaceCount = 2

    init(settings: PopopxCameraGuardSettings, deliver: @escaping (PopopxSecurityAlert) -> Void) {
        self.settings = settings
        self.deliver = deliver
        self.objectRequest = settings.objectDetectionEnabled ? PopopxGuardPipeline.makeObjectRequest() : nil
        self.glareDetector = settings.glareDetectionEnabled ? PopopxGlareDetector() : nil

        if !settings.objectDetectionEnabled {
            startupNote = "目标检测已按设置关闭。"
        } else if objectRequest == nil {
            startupNote = "未找到 POPOPXAntiSpyDetector 模型，目标检测未启用，仅高光反射兜底在工作。"
        } else if settings.glareDetectionEnabled {
            startupNote = nil
        } else {
            startupNote = "高光反射兜底已按设置关闭。"
        }
        super.init()
    }

    var hasObjectDetector: Bool { objectRequest != nil }

    // MARK: 帧回调

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let beganAt = Date.now
        // `teardown()` 会先把本类从 output 上摘掉，所以正常情况下停流后不会再有帧进来。
        // 真进来也只可能是摘除前那一批，直接丢掉，不做任何判定、更不投递告警。
        guard CMSampleBufferGetNumSamples(sampleBuffer) >= 1 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var requests: [VNRequest] = []
        if settings.faceGuardEnabled { requests.append(faceRequest) }
        if let objectRequest, !skipObjectDetectionThisFrame { requests.append(objectRequest) }

        if !requests.isEmpty {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: Self.frameOrientation)
            do {
                try handler.perform(requests)
                if settings.faceGuardEnabled { evaluateFaces(at: beganAt) }
                if let objectRequest { evaluateObjects(objectRequest) }
            } catch {
                // 推理失败不熔断用户消息：那是引擎的问题，不是用户的安全事件。
                // 但也不能当没事：把"最后一次看见脸"往前推，否则连续失败会被误判成机主离开，
                // 于一帧推理错误变成一次阅后即焚。这一路的代价是"人数判定暂时失效"，写在这里而不是藏在日志里。
                lastFaceSeenAt = beganAt
            }
        }

        if let glareDetector {
            switch glareDetector.process(pixelBuffer) {
            case .clear: break
            case .glare: report(.lensGlareDetected, when: beganAt)
            }
        }

        lastAnalysisDuration = Date.now.timeIntervalSince(beganAt)
        skipObjectDetectionThisFrame = lastAnalysisDuration > Self.frameBudget
    }

    // MARK: 判定

    private func evaluateFaces(at now: Date) {
        let faces = (faceRequest.results ?? []).count
        if faces >= Self.secondaryFaceCount, settings.alertOnSecondaryFace {
            report(.secondaryFaceDetected, when: now)
        }
        guard settings.faceGuardEnabled else { return }
        if faces >= 1 {
            lastFaceSeenAt = now
            primaryLossReported = false
            return
        }
        guard let lastSeen = lastFaceSeenAt, !primaryLossReported else { return }
        guard now.timeIntervalSince(lastSeen) >= settings.primaryViewerGrace else { return }
        primaryLossReported = true
        report(.primaryViewerLost, when: now)
    }

    /// CoreML 的结果有两种可能形状，取决于导出时有没有走 `nms=True`：
    /// 有 NMS 头 → `VNRecognizedObjectObservation`（带框 + labels）；
    /// 纯分类头 → `VNClassificationObservation`。两条都写，是因为**脚本产出的形状不由本文件决定**，
    /// 而只写一条会在另一种导出方式下静默变成"值守开着却永不报警"。
    private func evaluateObjects(_ request: VNCoreMLRequest) {
        let observations = request.results ?? []
        var best: (object: PopopxGuardObject, confidence: Double)?

        func consider(label: String?, confidence: Double) {
            guard let label, let object = PopopxGuardObject.resolve(modelLabel: label) else { return }
            guard confidence >= object.threshold else { return }
            if best == nil || confidence > best!.confidence { best = (object, confidence) }
        }

        for observation in observations {
            if let detection = observation as? VNRecognizedObjectObservation {
                // 只取 `labels[].confidence`：`nms=True` 导出的模型里这就是该类别的最终得分。
                // 不乘 `detection.confidence`——两个数该怎么合并没有文档保证，一旦乘起来，
                // 0.40/0.55 这两档阈值就不再是可复现的判据，而是一串没人验证过的组合。
                for label in detection.labels {
                    consider(label: label.identifier, confidence: Double(label.confidence))
                }
            } else if let classification = observation as? VNClassificationObservation {
                consider(label: classification.identifier, confidence: Double(classification.confidence))
            }
        }

        if let best { report(.recordingDevice(best.object), when: Date.now) }
    }

    private func report(_ alert: PopopxSecurityAlert, when now: Date) {
        if let last = lastReport, last.alert == alert, now.timeIntervalSince(last.at) < Self.repeatSuppression {
            return
        }
        lastReport = (alert, now)
        deliver(alert)
    }

    // MARK: 模型

    /// 加载预编译模型；找不到或加载失败返回 nil，全链路降级。理由见文件头。
    private static func makeObjectRequest() -> VNCoreMLRequest? {
        guard let url = compiledModelURL() else { return nil }
        let configuration = MLModelConfiguration()
        // `.cpuAndNeuralEngine`：ANE 上这条 320x320 的模型才是个位数毫秒；
        // `.all` 让系统自选，选到 GPU 时功耗会顶到弹窗那几十秒的热降频阈值。
        configuration.computeUnits = .cpuAndNeuralEngine
        guard let model = try? MLModel(contentsOf: url, configuration: configuration),
              let visionModel = try? VNCoreMLModel(for: model) else { return nil }
        let request = VNCoreMLRequest(model: visionModel)
        // 模型按 320x320 方图导出，`.scaleFit` 保长宽比。我们只用"有没有手机"，
        // 从不还原 `boundingBox`，所以这里不需要一套会算错的坐标反变换。
        request.imageCropAndScaleOption = .scaleFit
        return request
    }

    /// 只认 `mlmodelc`：`.mlpackage` 是**源**，必须由 Xcode 在构建期编译进 app 才能被 `MLModel` 读。
    /// 一个裸 `.mlpackage` 躺在 bundle 里等于没有模型，而运行时也没有 Xcode 工具链可以现场编译。
    /// 找不到就返回 nil，交给降级路径 + `startupNote` 说清楚。
    private static func compiledModelURL() -> URL? {
        if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") {
            return url
        }
        // 脚本产物目录若被作为 folder reference 整体拷进 bundle，模型在那一层里。
        // 两条都试，因为这两种集成方式都合法，而选哪条是人工拖入时决定的。
        return Bundle.main.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: modelSubdirectory)
    }

    private static let modelName = "POPOPXAntiSpyDetector"
    private static let modelSubdirectory = "SecureEphemeral"

    /// 竖屏持机时前置摄像头送出的缓冲区朝向。这里唯一使用它的地方是"让 Vision 把人脸
    /// 转正"，而判定只看**框的数量**，所以这个值错一档最坏的后果是漏检一帧，不是坐标偏移。
    /// 不设 `connection.videoOrientation`（iOS 17 起已废弃，换成 `videoRotationAngle`
    /// 而后者只影响预览变换），也不做设备姿态跟踪：绝密弹窗本身是竖屏的。
    private static let frameOrientation = CGImagePropertyOrientation.right
}

// MARK: - 会话

/// 一条采集会话的生命周期对象。`teardown()` 之后它不再持有任何系统资源。
final class PopopxCameraGuardSession {
    private let captureSession = AVCaptureSession()
    private let pipeline: PopopxGuardPipeline
    private let videoQueue: DispatchQueue
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureVideoDataOutput?
    private var tornDown = false

    var hasObjectDetector: Bool { pipeline.hasObjectDetector }

    init(pipeline: PopopxGuardPipeline, settings: PopopxCameraGuardSettings) throws {
        self.pipeline = pipeline
        // 队列名是这个特性在 Console.app 里唯一的身份，别改。
        self.videoQueue = DispatchQueue(
            label: "com.popopx.vision.guard",
            qos: .userInitiated,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
        guard settings.requiresCameraAccess else { throw PopopxCameraGuardFailure.notRequired }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        else { throw PopopxCameraGuardFailure.noFrontCamera }

        captureSession.beginConfiguration()
        // `.vga640x480`：提示词指定的档位，也是这颗摄像头上最小的可用档位。
        // 不支持就不设 preset（而不是抛错）：preset 是"要多大画面"，
        // 而"值守要不要跑"只取决于能不能拿到帧。
        if captureSession.canSetSessionPreset(.vga640x480) {
            captureSession.sessionPreset = .vga640x480
        }

        do {
            try Self.applyPowerSavingFrameRate(to: device)
        } catch {
            captureSession.commitConfiguration()
            throw PopopxCameraGuardFailure.sessionUnavailable
        }

        // `AVCaptureDeviceInput(device:)` 是 throwing 而非 failable（第一版按 `guard let` 写会被
        // 编译器当场拒绝），所以这里必须 try；失败原因统一归到"会话配不起来"。
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            captureSession.commitConfiguration()
            throw PopopxCameraGuardFailure.sessionUnavailable
        }
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw PopopxCameraGuardFailure.sessionUnavailable
        }
        captureSession.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // 迟到的帧直接丢：值守要的是"现在有没有第二张脸"，排队的旧帧只会给出过期答案，
        // 并且把停流之后的回调排到弹窗关闭之后。
        output.alwaysDiscardsLateVideoFrames = true
        // **必须是 FullRange**：`PopopxGlareDetector` 的阈值是 `Luma > 245`，
        // 而 VideoRange 的亮度上限是 235 —— 用错这一行不会报错、不会崩溃，
        // 只会让高光那一整路永远不触发。两个格式的区别就写在这一行的注释里。
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        output.setSampleBufferDelegate(pipeline, queue: videoQueue)
        guard captureSession.canAddOutput(output) else {
            output.setSampleBufferDelegate(nil, queue: nil)
            captureSession.commitConfiguration()
            throw PopopxCameraGuardFailure.sessionUnavailable
        }
        captureSession.addOutput(output)

        Self.applyAutoFocus(to: device)

        self.input = input
        self.output = output
        captureSession.commitConfiguration()
    }

    deinit {
        #if DEBUG
        // 回收断言：会话被 ARC 放掉时流必须已经停了。还在跑 = 有人漏了 `stopMonitoring()`，
        // 真机上的表现是"绝密弹窗早关了，摄像头绿点还亮着"。
        precondition(!captureSession.isRunning, "PopopxCameraGuardSession 释放时采集流仍在运行：stopMonitoring() 漏调")
        #endif
        // deinit 里只做无需主线程保证的收尾；带 `precondition(Thread.isMainThread)` 的
        // `teardown()` 只能由 `stopMonitoring()` 调，ARC 落在哪个线程不由我们决定。
        output?.setSampleBufferDelegate(nil, queue: nil)
        if captureSession.isRunning { captureSession.stopRunning() }
    }

    func start() {
        // 同步阻塞调用线程约几十毫秒。它不异步是刻意的：`isMonitoring` 必须与绿点同一时刻为真，
        // 否则弹窗已经在显示而值守还没起来，中间那一段就是真的"裸奔窗口"。
        captureSession.startRunning()
    }

    /// 顺序刻死，见 `stopMonitoring()`。幂等：重复调用只做一次。
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        output?.setSampleBufferDelegate(nil, queue: nil)
        if captureSession.isRunning { captureSession.stopRunning() }
        captureSession.beginConfiguration()
        if let input { captureSession.removeInput(input) }
        if let output { captureSession.removeOutput(output) }
        captureSession.commitConfiguration()
        self.input = nil
        self.output = nil
    }

    /// 目标帧率。10 FPS 是提示词给的档，也是"第二个人头凑过来"的物理下限：
    /// 一个人从画面外进到画面内，10 FPS 下大约 3~4 帧，够判定；再多只是白烧电和发热。
    private static let targetFramesPerSecond: Float64 = 10

    /// 把帧率钉在 10 FPS。
    ///
    /// **分辨率不在这里管**：它由 `.vga640x480` 这个 preset 决定，那正是 Apple 给的选分辨率的入口。
    /// 手动设 `activeFormat` 看着更省电，但 `activeFormat` 有一条只能真机验证的规则——格式必须被
    /// 当前 preset 支持，否则抛 `NSInvalidArgumentException`（ObjC 异常，Swift 的 `catch` 接不住，
    /// 于是表现为"打开绝密弹窗即崩"）。而模拟器没有前置摄像头，这条崩溃路径在本工程的任何
    /// 自动化里都跑不到。所以这里只留一个能确定的控制：帧率。
    ///
    /// 当前 `activeFormat` 不支持 10 FPS 时**只跳过帧率设置**，不放弃值守：帧率高一点是多耗电，
    /// 而"因为挑不到格式就整个不值守"是一次安全检查变成静默失效——那正是本文件反复在防的那类 bug。
    private static func applyPowerSavingFrameRate(to device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        guard supportsTargetFrameRate(in: device.activeFormat) else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(targetFramesPerSecond))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    /// 帧率区间要**两头**都盖住 10：`minFrameDuration <= 0.1s <= maxFrameDuration`。
    /// 只查一头是常见的错法——那样会把"最高只能到 5FPS"的格式判成可用，
    /// 然后 `activeVideoMinFrameDuration` 设进去不生效（或抛异常）。
    private static func supportsTargetFrameRate(in format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains { range in
            range.minFrameDuration.seconds <= 1.0 / targetFramesPerSecond
                && range.maxFrameDuration.seconds >= 1.0 / targetFramesPerSecond
        }
    }

    /// 自动对焦。不支持就跳过：值守不需要清晰画面，只需要数得清"有几个亮斑、有几张脸"。
    /// 写在代码里的理由是：它属于"删掉也照样跑、只是判据变差"的那类设置，
    /// 下一次读到这段的人需要知道它是有意的。
    ///
    /// `lockForConfiguration()` 在这里必须真检错误：`unlock` 在未持锁时调用会抛 ObjC 异常，
    /// 所以 `try?` + 无条件 `unlock` 是一个"看起来无害、实则把一次权限抖动变成崩溃"的写法。
    private static func applyAutoFocus(to device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.continuousAutoFocus) else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.focusMode = .continuousAutoFocus
        device.unlockForConfiguration()
    }
}
