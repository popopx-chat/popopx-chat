//
//  PopopxSecureSheetView.swift
//  POPOPX (iOS)
//
//  【模块五的内容面 + 模块六的阅读面】绝密窗口里用户实际看到的那一屏，
//  以及会话列表里那张锁起来的知识卡片（`PopopxSecureCardBubble`）。
//
//  ### 这一屏的四条硬约束，以及它们如何决定了形状
//  1. **永远只有黑底。** 不跟随浅色模式：`PopopxScreenCaptureShieldView` 给采集端画的是纯黑，
//     而内容面在浅色模式下会变成接近白的底 —— 那意味着"护盾"和"内容"的边界本身就是一条可被
//     录屏反推的信息（哪里亮，哪里就是字）。所以整个 surface 恒定深色，墨色也必须恒定：
//     见 `PopopxSecureSurface.ink`，那里写清了为什么调色板的 `onBrand`/`label` 两族都不能用
//     （它们随 colorScheme 翻转，深色模式下在本面上会得到一屏看不见的字）。
//  2. **状态机只有四个相位**：`reading` / `locked` / `burned` / `closed`。加起来是因为"打开被拒"
//     这一类**不在这个视图里表达**：`present` 在窗口建立之前就返回失败，反馈落点必须是用户
//     刚点的那张卡片（气泡自己显示 toast），而不是一个还没出现的窗口。
//  3. **明文不进 `Text` 之外的任何持久面**：不写日志、不进 `@State`、不做引用预览。
//     `text` 是 `private(set)`，只有 `invalidate()` 能把它清空。
//  4. **一切逐帧的东西在这里开、在这里关**：`PopopxAntiPhotoRenderView`、聚光/逐行、盲水印
//     都挂在 `reading` 相位下面。相位一离开 `reading`，这些视图随 SwiftUI 一起消失，
//     它们内部的 `PopopxFrameTicker` 也就 `stop()` 了 —— 这是"弹窗关闭立即停"在 UI 侧的落点，
//     不需要在这里再写一遍 teardown。
//
//  ### 读屏（VoiceOver）这一条是有意的取舍，不是遗漏
//  正文字体被 `.accessibilityHidden(true)` 排除在无障碍树之外。理由：VoiceOver 的朗读内容会进入
//  系统无障碍通道，而这条通道不在本特性的任何控制范围内（字幕、第三方开关控制、录屏里的 AX 高亮
//  都能把它带出屏幕）。代价同样明确：**读屏用户在这一条消息上读不到正文**。所以这一档必须在界面上
//  说清楚（`PopopxSecureCopy.accessibilityNote`），不能默默关掉——而"要不要为读屏开一条例外"
//  是产品裁定，不是这一层能自己定的默认值。
//
//  ### 为什么 `close` 是闭包而不是让视图直接叫单例
//  视图叫 `PopopxSecureWindowManager.shared` 也能跑，但那样这个文件就不能脱离单例做预览和断言。
//  闭包作为**视图/模型的入参**是 SwiftUI 的正常形状（`Button` 的 action 同理）；被禁止的是把闭包
//  存进 `Environment`（没有稳定身份，每次写入都会让整棵子树失效）。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import SwiftUI

// MARK: - 模型

/// 绝密窗口的可见状态。`@MainActor @Observable`：只有主线程会写它，
/// 而写它的四个入口（倒计时 tick、告警、销毁、断开）全在 `PopopxSecureWindowManager` 里。
@MainActor
@Observable
final class PopopxSecureSheetModel {
    /// 四个相位，互斥且覆盖全部可见状态。
    enum Phase: Hashable {
        /// 明文可读，倒计时在走，逐帧组件在跑。
        case reading
        /// 黑罩 + 原因，明文仍在内存里（只有 `leftForeground` 且关掉销毁时会停在这里）。
        /// 这一档只有一个动作：关闭并销毁。"解锁继续看"需要再走一次生物识别，
        /// 而那次应该由用户重新点卡片发起 —— 在视图里再造一条验证流程就等于造第二个状态机。
        case locked(reason: String)
        /// 明文已擦，窗口还留着是为了让用户看见**为什么**关。
        /// `reason` 为 nil = 正常看完/正常到点，没有要解释的事。
        /// 记录删没删、回执发没发，全由下面这两个值说，视图不替它们加任何保证。
        /// `deleted` = false 时**必须**说出来：这一格是"焚毁"这个声明里唯一可能没做到的部分，
        /// 蒙过去就等于让"这条已经被焚毁"变成一句不成立的声明。
        case burned(reason: String?, receiptCount: Int, deleted: Bool)
        /// 收尾中：视图正在消失，任何回调都不该再生效。
        case closed
    }

    private(set) var text: String?
    private(set) var phase: Phase = .reading
    let totalSeconds: Int
    private(set) var remainingSeconds: Int

    /// 阅读模式（模块六）。默认聚光：它不需要用户先学会一个手势就能用。
    var readMode: PopopxSecureReadMode = .spotlight
    /// 防滚动快门（模块六）。
    var antiPhotoEnabled: Bool
    /// 值守状态的一句话说明：少了哪一路、为什么少。`PopopxCameraGuardEngine` 与
    /// `PopopxCameraGuardFailure` 都产这个字符串，这里只负责显示。
    var guardNote: String?

    /// 盲水印里的会话号。一次窗口一个，销毁后不重用——它的取证价值正是"这一条是从哪一次查看出去的"。
    let sessionIdentifier: String

    private let close: () -> Void
    /// 断开标记。`invalidate()` 置位之后，`requestClose()` 永久变成空操作。
    ///
    /// 这一条是"双重清理"能安全成立的前提：`.onDisappear` 和 `dismissSecureWindow()` 会**都**触发，
    /// 没有这个标志的话，窗口拆除时 SwiftUI 发出的 `onDisappear` 会在销毁之后
    /// 再走一遍"用户主动关闭"，于是同一条消息被删两次、回执发两条。
    private var isDisconnected = false

    /// DEBUG 专用的"明文已交出"凭据。
    ///
    /// 为什么不直接读 `text`：`@Observable` 把 `text` 换成带观察访问器的属性，访问器继承类的
    /// `@MainActor` 隔离；而 `deinit` 在 Swift 5 模式下是非隔离的，读它就编译不过
    /// （`main actor-isolated property 'text' can not be referenced from a nonisolated context`）。
    /// 下面这个盒子是**没有隔离的普通类**，而 `let` 引用不参与观察，所以 `deinit` 读得动。
    ///
    /// 它只有 DEBUG 才存在，且只有一个写点（`erasePlaintext()`），写的一行就挨着真正的
    /// `text = nil`，所以不会变成第二个判断口径；`deinit` 里读它也安全 —— 进到 `deinit`
    /// 就意味着已经没有别人持有这个模型，也就没有别的线程正在写这个盒子。
    #if DEBUG
    private final class EraseWitness { var plaintextGivenUp = false }
    private let eraseWitness = EraseWitness()
    #endif

    /// 清明文只走这一个出口：绕过它直接写 `text = nil` 会让下面的回收断言说"没清过"。
    private func erasePlaintext() {
        text = nil
        #if DEBUG
        eraseWitness.plaintextGivenUp = true
        #endif
    }

    init(
        text: String,
        totalSeconds: Int,
        antiPhotoEnabled: Bool,
        close: @escaping () -> Void
    ) {
        self.text = text
        self.totalSeconds = totalSeconds
        self.remainingSeconds = totalSeconds
        self.antiPhotoEnabled = antiPhotoEnabled
        self.close = close
        self.sessionIdentifier = UUID().uuidString
    }

    deinit {
        #if DEBUG
        // 回收断言：模型被释放时明文必须已经交出（`erasePlaintext()` 跑过）。
        // false 就是销毁路径被跳过 —— 通常是 `burn(...)` 或 `invalidate()` 没被调到。
        print("[popopx.secure] sheet model released, plaintext given up = \(eraseWitness.plaintextGivenUp)")
        #endif
    }

    /// 倒计时归零/用户关闭之外，相位不会自己变。`progress` 给进度条，0...1。
    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, Double(remainingSeconds) / Double(totalSeconds)))
    }

    var isReading: Bool {
        if case .reading = phase { return true }
        return false
    }

    // MARK: 由管理器写入

    func updateRemainingSeconds(_ seconds: Int) {
        guard isReading, !isDisconnected else { return }
        remainingSeconds = max(0, seconds)
    }

    func lock(reason: String) {
        guard !isDisconnected else { return }
        phase = .locked(reason: reason)
        PopopxHaptics.notice(.warning)
    }

    /// 进入"已焚"相位。明文在这里就交出去，不等窗口拆除。
    ///
    /// 参数由**管理器**给（见 `PopopxSecureWindowManager.burn`），模型不自己推断删除结果：
    /// `deleted` 只可能是"宿主确实拿到 itemId 并发出了删除请求"这一种真值来源。
    func burn(reason: String?, receiptCount: Int, deleted: Bool) {
        erasePlaintext()
        guard !isDisconnected else { return }
        phase = .burned(reason: reason, receiptCount: receiptCount, deleted: deleted)
    }

    /// 拆除前的最后一步：先断回调，再交明文。
    func invalidate() {
        isDisconnected = true
        erasePlaintext()
        phase = .closed
    }

    // MARK: 由视图写入

    func requestClose() {
        // 单一出口：无论来自按钮、`onDisappear`、还是系统返回手势，都只走宿主那一条销毁路径。
        guard !isDisconnected else { return }
        close()
    }
}

// MARK: - 视图

/// 绝密窗口内容面。入参只有模型：没有 app 类型、没有宿主闭包，
/// 因此本文件连同 `SecureEphemeral/` 整个目录都能脱离 Xcode 工程做类型检查。
struct PopopxSecureSheetView: View {
    @Bindable private var model: PopopxSecureSheetModel
    /// toast 模型是本视图私有的：绝密窗口不属于任何聊天页，拿不到宿主注进来的那一份。
    @State private var toastModel = PopopxToastModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: PopopxSecureSheetModel) {
        self.model = model
    }

    var body: some View {
        ZStack {
            PopopxSecureSurface.backdrop
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .popopxToast(toastModel)
        // 窗口被外力拆掉（系统手势、scene 切换）也要走同一条销毁路径。
        // 与 `dismissSecureWindow()` 的双重清理之所以安全，靠的是 `PopopxSecureSheetModel.isDisconnected`。
        .onDisappear { model.requestClose() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .reading:
            reading
        case .locked(let reason):
            PopopxSecureMask(text: reason, footnote: PopopxSecureCopy.lockFootnote) {
                model.requestClose()
            }
        case .burned(let reason, let receipts, let deleted):
            PopopxSecureMask(
                text: reason ?? PopopxSecureCopy.cardDestroyed,
                footnote: PopopxSecureCopy.burnFootnote(receipts: receipts, deleted: deleted)
            ) {
                model.requestClose()
            }
        case .closed:
            // 空视图：窗口正在被拆除，这里画任何东西都会在最后一帧闪一下。
            Color.clear
        }
    }

    // MARK: 阅读面

    private var reading: some View {
        VStack(spacing: PopopxMetrics.spaceL) {
            header
            readerArea
            controls
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.top, PopopxMetrics.spaceL)
        .padding(.bottom, PopopxMetrics.spaceM)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(PopopxPalette.brand)
                    .accessibilityHidden(true)
                Text(PopopxSecureCopy.cardTitle)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxSecureSurface.ink)
                Spacer(minLength: PopopxMetrics.spaceS)
                // 数字用 monospacedDigit：倒计时每秒换一位数时版面不跳，
                // 而版面一跳用户的视线就会被吸引到"还剩几秒"上去读那行正在淡出的字。
                Text(PopopxSecureCopy.duration(model.remainingSeconds))
                    .font(PopopxType.metric)
                    .foregroundStyle(remainingInk)
                    .accessibilityLabel("剩余 \(model.remainingSeconds) 秒")
            }
            // `value:total:`（没有 `in:` 这个标签，`in:` 是 `Slider` 的写法）。
            ProgressView(value: Double(model.remainingSeconds), total: Double(max(1, model.totalSeconds)))
                .progressViewStyle(.linear)
                .tint(remainingInk)
                .accessibilityHidden(true)
                // 动画挂在进度条自己身上，而不是挂在整块 header 或控制区上：
                // `value:` 要和"被动画的那个数"处在同一处，否则每秒一次的状态变更会连带
                // 让标题、时间文案、图标一起做一次插值，而那是用户读字的地方。
                // 关掉动效时传 nil：逐秒的 0.1 步长在 reduceMotion 下就是噪声。
                .animation(reduceMotion ? nil : PopopxSpring.fluid, value: model.remainingSeconds)
        }
    }

    private var remainingInk: Color {
        // 最后 5 秒转红。阈值贴着 `PopopxSecurePayload.minimumTTLSeconds`(=5) 走：
        // 最短的一档整个时长都落在"已经该提醒"的区间里，而不是让 15 秒的窗口只在最后 1/3 变脸。
        model.remainingSeconds <= 5 ? PopopxPalette.danger : PopopxSecureSurface.ink
    }

    /// 正文区。三种东西叠在这里：阅读模式视图、防滚动快门、盲水印。
    /// 顺序是**由内到外**：水印叠在阅读层之上（它要覆盖的是"屏幕上的最终像素"），
    /// 防拍照层叠在水印之上（它要打断的是卷帘快门对任何一行的采样，包括水印点阵）。
    private var readerArea: some View {
        Group {
            if let text = model.text {
                reader(for: text)
            } else {
                // 明文没了却还在 `reading`：只有管理器漏了相位写入才会到这里。
                // 留一个空的黑面而不是崩溃，也不显示任何提示——提示会把用户的注意力钉在"这里本该有字"。
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay {
            PopopxBlindWatermarkOverlay(sessionIdentifier: model.sessionIdentifier)
                .allowsHitTesting(false)
        }
        .overlay {
            PopopxAntiPhotoRenderView(isEnabled: model.antiPhotoEnabled)
                .allowsHitTesting(false)
        }
        // 明文整块不进无障碍树，理由见文件头"读屏"那一节：这一条是取舍，不是遗漏，
        // 所以它同时必须在界面上说出来（`controls` 里那句 `accessibilityNote`）。
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func reader(for text: String) -> some View {
        switch model.readMode {
        case .spotlight:
            PopopxSpotlightTextView(text: text, radius: PopopxSecureSurface.spotlightRadius)
        case .teleprompter:
            PopopxTeleprompterTextView(text: text)
        }
    }

    // MARK: 控制面

    private var controls: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            PopopxSegmentedControl(
                PopopxSecureReadMode.allCases.map { PopopxSegmentedControl<PopopxSecureReadMode>.Option(selection: $0, title: $0.title) },
                title: \.title,
                selection: $model.readMode
            )
            .onChange(of: model.readMode) { _, mode in
                // 换模式不说一句话，用户会以为是渲染坏了：两种模式的交互根本不同（一个跟手、一个要按住拖）。
                toastModel.show(mode.note, kind: .mesh)
            }

            PopopxToggleRow(
                "防拍照抖动",
                note: PopopxSecureCopy.antiPhotoNote,
                systemImage: "camera.viewfinder",
                tint: .brand,
                isOn: $model.antiPhotoEnabled
            )

            if let note = model.guardNote {
                Label {
                    Text(note).font(PopopxType.caption)
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
                .foregroundStyle(PopopxSecureSurface.inkSecondary)
                .accessibilityElement(children: .combine)
            }

            Text(PopopxSecureCopy.accessibilityNote)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxSecureSurface.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            PopopxButton(
                "关闭并销毁",
                systemImage: "lock.rectangle.stack",
                role: .destructive,
                fullWidth: true
            ) {
                model.requestClose()
            }
        }
    }
}

// MARK: - 遮罩

/// 黑底遮罩：锁屏与已焚两相共用一套版面。
///
/// 刻意不用 `PopopxSectionCard`：那套卡有阴影、有浅色底，是为 app 内的内容层设计的。
/// 这一屏是安全面，只留"一句话 + 一个动作"，多一个装饰就少一分"事情已经结束了"的确定感。
private struct PopopxSecureMask: View {
    let text: String
    let footnote: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: PopopxMetrics.spaceM) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(PopopxPalette.brand)
                .accessibilityHidden(true)
            Text(text)
                .font(PopopxType.title)
                .foregroundStyle(PopopxSecureSurface.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(footnote)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxSecureSurface.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PopopxButton("好", systemImage: nil, role: .secondary, fullWidth: false) {
                action()
            }
            .padding(.top, PopopxMetrics.space2XS)
        }
        .padding(PopopxMetrics.spaceXL)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusSheet))
        .background(PopopxSecureSurface.cardFill)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - 版面常量

/// 安全面的几处视觉常量。放在一处而不是散进视图里：这一屏的底色与墨色必须在遮罩、正文、
/// 列表卡片三处完全一致，否则"遮罩到底盖住了没有"就变成要肉眼去辨的差别。
enum PopopxSecureSurface {
    /// 整屏底：真黑，且**恒定**。两个理由：
    /// 1. 护盾给采集端画的也是纯黑，两边不一致时录屏里能看出内容区的边界；
    /// 2. 不用 `PopopxPalette.base`——它在深色模式确实是 `#000000`，但那是**跟随 colorScheme** 的，
    ///    而这一屏的黑不允许被任何模式开关翻掉。
    static let backdrop = Color.black

    /// 安全面上的墨色**必须恒定**，所以这里不能直接用调色板里的 ink token：
    /// `PopopxPalette.onBrand` 是 `Color.popopx(light: 0xFFFFFF, dark: 0x0A0A1F)`，
    /// 在深色模式里它接近黑——放进本面就等于交出一屏"深色模式下看不见"的绝密内容，
    /// 而深色模式才是多数人的默认。`label` 一族同理（浅色模式 `#111114`）。
    ///
    /// 所以走 `Color.popopx(_:UInt32)` 这个不随模式翻转的入口：仍然在设计系统内（同一条
    /// 裁定要求"只用 `PopopxPalette`/`Color.popopx`，不手写十六进制"），取的是不翻转的那一个重载。
    /// 数值与调色板的深色档对齐，避免安全面和 app 主体之间出现第二种白。
    static let ink = Color.popopx(0xF4F4F6)
    static let inkSecondary = Color.popopx(0xA6A6B0)
    /// 只用于占位与已销毁态。对齐 `labelHint`，同样是为了不在安全面上出现第三种白。
    static let inkTertiary = Color.popopx(0x8A8A94)

    /// 遮罩底：极深的靛紫，给"这不是普通页面"一点温度，但不构成第二套配色。
    static let cardFill = Color.popopx(light: 0x1A1030, dark: 0x140C26)
    /// 列表卡片底：和遮罩同族、浅一档，保证在会话列表里读得出层次。
    static let cardBubbleFill = Color.popopx(light: 0x241640, dark: 0x1B1132)

    /// 聚光模式的清晰区半径。45pt 是提示词指定的档位，也是单指腹能盖住、又读得下一行的尺寸
    /// （`PopopxMetrics.minHitTarget` 的 44pt 是"可点"的下限，和"可读"的窗口直径不是同一件事）。
    static let spotlightRadius: CGFloat = 45
}

// MARK: - 列表卡片

/// 会话列表里的绝密卡片（模块五的"以专用深度靛紫锁盾卡片渲染，严禁在列表中暴露明文"）。
///
/// 颜色不接气泡那一套：`PopopxBubbleInk` 在 `PopopxMessageBubble.swift` 里是 `private`，
/// 跨文件拿不到（这条是实测，不是猜的），而绝密卡片本来也不该跟着通道/发送方向换色——
/// 它是这块屏幕上唯一一处"安全表面"，深浅两套固定墨（`PopopxSecureSurface`）。
struct PopopxSecureCardBubble: View {
    enum State: Hashable {
        /// 可打开。
        case locked
        /// 载荷解析得出来但解不开（被改过/密钥不对）：留在列表里，但永远打不开。
        case damaged
        /// 本机对不上这条记录的出处（会话 id 或消息 id 缺失）。它和"损坏"不是一回事：
        /// 密文可能是完好的，只是这台设备不知道该去删哪一行，所以永远不给打开的入口。
        case unlocated
    }

    let ttlText: String
    let state: State
    var incoming: Bool = false
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: PopopxMetrics.spaceS) {
                mark
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(title)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(ink)
                    Text(subtitle)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxSecureSurface.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: PopopxMetrics.spaceS)
                if state == .locked {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PopopxSecureSurface.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, PopopxMetrics.spaceM)
            .padding(.vertical, PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(.rect(cornerRadius: PopopxMetrics.radiusCard))
            .background(cardFill)
            .popopxCardElevation(colorScheme: colorScheme)
        }
        .buttonStyle(.plain)
        .disabled(state != .locked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier(incoming ? "popopx.bubble.secure" : "popopx.bubble.secure.outgoing")
    }

    private var mark: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(state == .damaged ? PopopxPalette.danger : PopopxPalette.brand)
            .frame(width: PopopxMetrics.space2XL - PopopxMetrics.spaceS)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .locked: "lock.shield.fill"
        // 损坏 = 这是一次安全事件，盾牌上必须带惊叹号；找不到出处不是安全事件，
        // 只是这台设备失忆了，所以它借用列表里那枚"不可用"的问号文件夹，不新造第三枚盾。
        case .damaged: "exclamationmark.shield.fill"
        case .unlocated: "questionmark.folder"
        }
    }

    private var title: String {
        switch state {
        case .locked: return PopopxSecureCopy.cardTitle
        case .damaged: return "绝密消息已损坏"
        case .unlocated: return "绝密消息不可打开"
        }
    }

    private var subtitle: String {
        switch state {
        case .locked: return PopopxSecureCopy.cardLockedHint + " · " + ttlText
        case .damaged: return "密文或密钥不完整，无法解密"
        case .unlocated: return "本机没有这条记录的出处，无法定位到消息"
        }
    }

    private var accessibilityText: String {
        switch state {
        case .locked: return "绝密阅后即焚，\(ttlText)，轻触后需生物识别"
        case .damaged: return "绝密消息已损坏，无法打开"
        case .unlocated: return "绝密消息不可打开，本机定位不到这条记录"
        }
    }

    private var ink: Color {
        // "损坏"要人读清楚，墨色不降；"不可打开"是一个既成事实，降一档免得和损坏抢注意力。
        state == .unlocated ? PopopxSecureSurface.inkTertiary : PopopxSecureSurface.ink
    }

    private var cardFill: Color {
        state == .unlocated
            ? PopopxSecureSurface.cardBubbleFill.opacity(0.55)
            : PopopxSecureSurface.cardBubbleFill
    }

    private func handleTap() {
        guard state == .locked else { return }
        PopopxHaptics.impact(.medium)
        onOpen()
    }
}

private extension PopopxSecureCopy {
    /// 这一句、`lockFootnote`、`burntWithReceipt`、`antiPhotoNote` 是这个文件独有的文案，
    /// 不塞进载荷文件里：载荷那一层的文案要被卡片、回执、气泡三处共用，
    /// 而这几条只属于"窗口已经打开之后"的世界。
    ///
    /// 用 `private extension` 而不是直接写字符串常量：`PopopxSecureCopy` 的其它成员在
    /// 载荷文件里，读代码的人在两处之间跳的时候，名字必须看起来是同一族。
    static let accessibilityNote = "本条消息不向读屏（VoiceOver）提供正文。"
    static let lockFootnote = "风险仍在。关闭会销毁这条消息。"
    static let burntQuietly = "本机记录已删除。"
    /// 唯一一句"这一条没做到"的话。它排在回执之前且互斥：既然记录没删成，
    /// 通知对方"已销毁"就是一句假话，所以这一档连回执的措辞都不给。
    static let burntWithoutDeletion = "明文已从内存擦除，但本机没能定位到这条记录：未删除。"
    static func burntWithReceipt(count: Int) -> String {
        count == 1 ? "本机记录已删除，并已通知对方。" : "本机记录已删除，已发出 \(count) 条通知。"
    }
    /// 已焚相位的副标题：三种真实结果各说一种，不做乐观合并。
    static func burnFootnote(receipts: Int, deleted: Bool) -> String {
        guard deleted else { return burntWithoutDeletion }
        return receipts > 0 ? burntWithReceipt(count: receipts) : burntQuietly
    }
    static let antiPhotoNote = "高频抖动可干扰卷帘快门翻拍，会增加功耗与发热。"
}

#Preview("popopx secure card") {
    // 三档状态一次看全：能打开、解不开、本机定位不到。后两档都必须读得出"这不是可以重试的事"，
    // 所以符号、墨色、副标题三处同时变，只靠降透明度是不够的。
    VStack(spacing: PopopxMetrics.spaceS) {
        PopopxSecureCardBubble(ttlText: PopopxSecureCopy.duration(60), state: .locked) {}
        PopopxSecureCardBubble(ttlText: PopopxSecureCopy.duration(60), state: .damaged) {}
        PopopxSecureCardBubble(ttlText: PopopxSecureCopy.duration(60), state: .unlocated) {}
    }
    .padding(PopopxMetrics.gutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(PopopxPalette.base)
}
