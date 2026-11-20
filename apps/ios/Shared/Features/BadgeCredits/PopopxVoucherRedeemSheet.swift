//  PopopxVoucherRedeemSheet.swift
//
//  【第五阶段 · 6】兑换面板：把一串 `PPX1-…` 变成一次本机建连 + 一次等待对方确认。
//
//  ### 点"兑换"返回的不是结果，是"已发起"
//  `router.startExternalRedeem(code:)` 只做三件事：验码、验签、建一条 incognito connection。
//  REQ 要等 `contactConnected` 才发得出去（连接被对方接受之前载不动消息），ACK 更在后面，
//  所以本面板**订阅** `router.lastOutcome` 而不是把返回值当终态。把 `.initiated` 显示成
//  "兑换成功"是这个特性最容易被写错、也最容易被审核当成误导的地方。
//
//  ### 终态可能永远不来
//  对方可能已经不在这台设备上、可能删了 app、可能网络断了很久。因此：
//  - 这一页允许随时关掉，"等待对方确认"那一句必须说清**关掉不影响结果**；
//  - 不做超时、不承诺重试、不显示进度条。一次没有回音的兑换，诚实的答案就是"没有回音"。
//
//  ### 粘贴优先于手抄
//  `PopopxRedeemCode.normalized` 只去掉空白并修正前缀大小写——载荷本身是 base64url，
//  **大小写敏感**。所以界面上把"粘贴"做成一等按钮，并明写"请不要逐字符手抄"。
//  展示用 `grouped` 分段（可读），提交用原文（可解）。
//
//  ### 扫一扫为什么在本模块又写一遍
//  `PopopxAddFriendView.swift:519` 已有 `PopopxScannerSheet`，但它是 `private` 且把结果交给
//  "链接分类"那条路（离线门 / 在线邀请），兑换码既不是链接也不该走那个判类。
//  这里需要的只是"把相机取景框交给系统权限状态机"，所以按同一套授权/失败/重建流程写了第二份，
//  并在下面 `PopopxRedeemScanner` 的注释里写清它与第一份的差别（不共用是为了不改动已上机验证过的加好友页，
//  不是为了省一次 import）。
//  相机会话由本文件自持（`PopopxQRScannerView`），不用 `CodeScanner` 包：包里的
//  `ScannerViewController` 只在 `viewDidDisappear` 异步 `stopRunning()`，**从不放掉会话引用**，
//  而本项目的红线要求"识别成功与页面消失两处都必须 stopRunning 且置 nil"。
//  停止顺序抄 `Shared/Features/SecureEphemeral/PopopxCameraGuardEngine.swift:43`：
//  摘 delegate → stopRunning → 放引用；`dismantleUIView` 就是页面消失那一路的落点。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

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
        // 终态由路由器异步写入：这里只跟随，不推断。
        .onChange(of: router.lastOutcome) { _, outcome in
            if let outcome { stage = .initiated(outcome) }
        }
    }

    // MARK: 版面

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

    // MARK: 动作

    private func submit() async {
        let code = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, stage != .busy else { return }
        stage = .busy
        let outcome = await router.startExternalRedeem(code: code)
        stage = .initiated(outcome)
        if case .failed = outcome {
            PopopxHaptics.notice(.error)
        } else if case .redeemed = outcome {
            PopopxHaptics.notice(.success)
        }
    }

    private func pasteFromClipboard() {
        guard let raw = UIPasteboard.general.string, !raw.isEmpty else {
            stage = .localNote(Copy.clipboardEmpty)
            return
        }
        let normalized = PopopxRedeemCode.normalized(raw)
        guard PopopxRedeemCode.decode(normalized) != nil else {
            // 剪贴板里确实有文本，但它不是这一版本的码：先把内容放进去（用户可以自己核对），
            // 再说明为什么不接受，而不是把用户刚粘的东西丢掉。
            codeText = normalized
            stage = .localNote(Copy.clipboardNotCode)
            return
        }
        codeText = normalized
        stage = .idle
    }

    // MARK: 呈现细节

    private func symbol(for outcome: PopopxRedemptionOutcome) -> String {
        switch outcome {
        case .initiated: "hourglass"
        case .redeemed: "checkmark.seal"
        case .failed: "xmark.circle"
        }
    }

    private func color(for outcome: PopopxRedemptionOutcome) -> Color {
        switch outcome {
        case .initiated: PopopxPalette.labelSecondary
        case .redeemed: PopopxPalette.successInk
        case .failed: PopopxPalette.dangerInk
        }
    }

    /// 每一种终态都补一句"接下来会怎样"，而不只给一个词。
    private func gloss(_ outcome: PopopxRedemptionOutcome) -> String {
        switch outcome {
        case .initiated:
            Copy.glossInitiated
        case let .redeemed(period, _):
            Copy.glossRedeemed(period.days)
        case let .failed(error):
            Copy.glossFailure(error)
        }
    }
}

// MARK: - 阶段

/// 面板自己的四格状态。`.busy` 与 `.result` 分开，是因为"这一台机器已经回答完了"
/// 和"还在等对方那台机器回答"是两件不同的事，混成一格就会在等待期间显示旧结果。
enum PopopxRedeemStage: Hashable {
    case idle
    case busy
    case initiated(PopopxRedemptionOutcome)
    /// 本机就能判掉的拒绝（剪贴板是空的）：不借用 `PopopxBadgeCreditsError` 的措辞，
    /// 因为那几句都假设"有一串码"，而这里根本没有码。
    case localNote(String)

    var canSubmit: Bool {
        switch self {
        case .busy: false
        default: true
        }
    }
}

// MARK: - 扫一扫

/// 兑换码取景框。与 `PopopxAddFriendView` 里那份的差别只有一处：这里不做链接分类，
/// 扫到什么就原样交给调用方（理由见文件头）。授权状态机、失败重建与占位保持一致。
struct PopopxRedeemScanner: View {
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cameraStatus: AVAuthorizationStatus?
    /// 换一次 id 就是重建取景框（`makeUIView`/`dismantleUIView` 各走一遍）：会话起不来只能这样重试。
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
            // `.task` 已经把系统授权弹窗发出去了，这一格就是弹窗后面的那几帧。
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
        // 会话已经在回调里停掉并放掉了（见 `PopopxQRScannerView`），这里只负责把取景框从层级里摘走，
        // 再把原文交出去。顺序反过来会让 `onScan` 那一路在相机还开着的时候跑。
        dismiss()
        onScan(text)
    }

    /// 起不来（无后置摄像头 / 会话被占用）只留一句话与**至多两次**重建：换 `scanAttempt` 会让 SwiftUI
    /// 先 dismantle 再 make，旧会话在那一步就已经停了，不会攒出第二个。
    /// 不设上限的话，一台永远起不了相机的设备会在这儿无限循环——每一圈都是一次授权检查加一次会话构造。
    private func reportScannerFailure(_ reason: String) {
        failureNote = String(format: ScannerCopy.scanFailedFormat, reason)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == cameraStatus else {
            // 权限在这一刻没了（用户在设置里关掉，或系统撤销）：让取景框整块下台，别再去重建它。
            cameraStatus = status
            return
        }
        if scanAttempt < Self.maximumScannerRebuilds {
            scanAttempt += 1
        }
    }

    private static let maximumScannerRebuilds = 2
}

// MARK: - 自持的取景框

/// `UIViewRepresentable` 包一个 `AVCaptureSession`，只做 QR。写这一层而不是用第三方包，
/// 是为了让红线里那两条时刻（识别成功、页面消失）都有**本文件里看得见**的停止代码。
/// 生命周期只有一条路径会漏：`makeUIView` 起了会话、`dismantleUIView` 停下并放引用，
/// SwiftUI 在换 `id` 与卸载视图时都会走后者，所以页面消失不需要再补一个手动 stop。
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

    /// 没有要往下传的会话期状态，所以这里是空的。两个回调只在 `makeUIView` 那一次被协调者记住：
    /// 它们捕获的是 `@State` 的存储引用，父视图重渲染换出的新闭包指向同一格，旧闭包不会写错地方。
    func updateUIView(_ uiView: PopopxQRPreviewView, context: Context) {}

    static func dismantleUIView(_ view: PopopxQRPreviewView, coordinator: PopopxQRScannerCoordinator) {
        coordinator.stop()
        view.detachSession()
    }
}

/// 预览层由 `layerClass` 提供，所以这个视图本身不持有会话，只提供挂/摘两个口。
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
    /// 一次取景只交一次结果：`AVCaptureMetadataOutput` 每帧都回调，不拦住会把兑换码交好几遍。
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
        // 只认 QR：兑换码是 `PPX1-…` 长串，其它码制在这里没有对应物，多认一种只是多一条会出错的解码路。
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: .main)
        built.commitConfiguration()
        preview.attach(built)
        session = built
        // `startRunning()` 是阻塞调用，放主线程会卡住这一帧的布局（本项目其它相机路径同一个理由）。
        DispatchQueue.global(qos: .userInitiated).async {
            built.startRunning()
        }
    }

    /// 停止顺序：先摘 delegate（回调从此不会再进来），再 `stopRunning`，最后放掉引用。
    /// 顺序反过来的话，`stopRunning` 期间迟到的那一帧会拿着一个已经开始拆的会话回调。
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
        // 红线：识别成功这一路也必须先停会话、再交结果。
        stop()
        onScan(text)
    }
}


// MARK: - 文案

private extension PopopxVoucherRedeemSheet {
    enum Copy {
        static let title = NSLocalizedString("Redeem a badge voucher", comment: "")
        static let subtitle = NSLocalizedString("With a redemption code, light up on this device the badge the other side gifted.", comment: "")
        static let inputTitle = NSLocalizedString("Redemption code", comment: "")
        static let inputFootnote = NSLocalizedString("A long string that starts with PPX1-. Paste it; do not retype it by hand: it is case-sensitive and one wrong character means verification fails.", comment: "")
        static let codeLabel = NSLocalizedString("Redemption code", comment: "")
        static let codePrompt = "PPX1-…"
        static let paste = NSLocalizedString("Paste", comment: "")
        static let scan = NSLocalizedString("Scan", comment: "")
        static let redeem = NSLocalizedString("Redeem", comment: "")
        static let close = NSLocalizedString("Close", comment: "")
        static let howTitle = NSLocalizedString("What happens", comment: "")
        static let howOne = NSLocalizedString("This device first verifies the signature inside the code, then connects to the gifter's device and sends the redemption request.", comment: "")
        static let howTwo = NSLocalizedString("The other side confirms the voucher has not been redeemed yet, then signs an authorization and sends it back.", comment: "")
        static let howThree = NSLocalizedString("Once that authorization checks out, the badge lights up on this device and the one-time connection is deleted.", comment: "")
        static let boundariesTitle = NSLocalizedString("What this screen promises, and what it does not", comment: "")
        static let boundariesFootnote = NSLocalizedString("Only what this layer can actually deliver.", comment: "")
        static let boundaryOne = NSLocalizedString("Network needed: redeeming exchanges two messages with the gifter's device.", comment: "")
        static let boundaryTwo = NSLocalizedString("A voucher redeems once; submitting it again reports it as already redeemed.", comment: "")
        static let boundaryThree = NSLocalizedString("On success the badge lights up automatically, even if this page has already been closed.", comment: "")
        static let glossInitiated = NSLocalizedString("The request is on its way. Wait for the gifter's device to confirm — you can close this page, and the capsule lights up by itself once it lands.", comment: "")
        static func glossRedeemed(_ days: Int) -> String { String(format: NSLocalizedString("Lit up %lld days, written into this device's badge record and merged with any remaining time.", comment: ""), days) }
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
        static let clipboardNotCode = NSLocalizedString("The clipboard text does not look like a redemption code (it must start with PPX1-). It has been placed in the field — check it, then tap Redeem again.", comment: "")
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
