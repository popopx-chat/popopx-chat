//  PopopxBadgeCapsuleView.swift
//
//  【第五阶段 · 1】顶栏的徽章胶囊，以及它的三态与三条出口。
//
//  ### 颜色为什么不是提示词里那三个裸值
//  提示词点了赛博青 #00F0FF / 翡翠绿 #10B981 / 冷雾灰 #6B7280。本仓的红线是"设计取值一律来自
//  `Shared/Theme/PopopxTheme.swift`，此文件内没有任何裸色值或裸字号"（同 `PopopxTelemetryHeader.swift:12-13`
//  的自述），而且裸青绿在深色模式下对比度不达标。所以按语义就近落进品牌档：
//  - 体验态 → `PopopxPalette.meshInk`（0x00705F / 0x00D2B8，近场青绿）：它是"还没走上正路"的那一档，
//    和近场/临时同一族，呼吸光晕由它承载；
//  - 点亮态 → `PopopxPalette.successInk`（0x1E7A34 / 0x30D158，翡翠绿墨）：即提示词要的"翡翠绿"，
//    取带暗色适配的那一档而不是裸 #10B981；
//  - 休眠态 → `PopopxPalette.labelSecondary` + `card` 底：休眠不是失败，措辞与配色都不给危险色
//    （`PopopxBadgePhase` 的注释就是这条判据的出处）。
//  这样三态在浅色与深色下都是"能读的同族色"，代价是不再逐位等于提示词的 HEX —— 这条取舍写在
//  验收报告里，由用户裁定要不要改回裸值。
//
//  ### 动效只在"真的有东西在变"时出现
//  - 体验态呼吸：它是要被注意到的临时态，Reduce Motion 下彻底静止（判据同 `PopopxStatusPill.restart()`，
//    `PopopxTelemetryHeader.swift:281-288`）；
//  - 点亮态旋转：只在**本机计数自增**那一次转满 360°（`onChange(of: rotationIndex)`），不做常驻自转 ——
//    一个永远在转的图标在无障碍里等于噪音，而"轮换"本身是离散事件，转一次刚好对上一次事实。
//
//  ### 三条出口，互不重叠
//  体验态 → 先锋体验弹窗（`PopopxTrialWelcomeModal`）；点亮态 → 徽章详情（`PopopxBadgeDetailSheet`）；
//  休眠态 → 购买页（`PopopxBadgePaywallView`）。判据只有 `phase` 一处，所以"过期了还能打开详情看倒计时"
//  这种自相矛盾的入口不可能出现。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI
import POPOPXChat

// MARK: - 纯呈现

/// 徽章胶囊本体：只吃 `phase` 与 `rotationIndex`，不读任何单例，因此可以脱离运行时单独预览与验证。
struct PopopxBadgeCapsule: View {
    let phase: PopopxBadgePhase
    var rotationIndex: Int = 0
    /// 顶栏宽度不够时退回"只留符号"，判据同 `PopopxDualStatusCapsule` 的 `ViewThatFits` 三档。
    var compact: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var spin: Double = 0

    var body: some View {
        Button(action: tapped) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                symbol
                if !compact {
                    Text(verbatim: label)
                        .font(PopopxType.secondary.weight(isLive ? .semibold : .regular))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? PopopxMetrics.spaceS : PopopxMetrics.spaceM)
            .frame(height: PopopxMetrics.space2XL)
            .frame(minWidth: compact ? PopopxMetrics.space2XL : 0)
            .background(isLive ? tint.opacity(0.10) : PopopxPalette.card, in: .capsule)
            .overlay {
                // 描边分两档：休眠是 0.5pt 的灰边，两枚"活着"的档位是 1.5pt 的同色实边
                // （`PopopxMetrics.stroke`）。宽度与不透明度一起分档，才够顶栏那条 48pt 高、
                // 挤着五个元素的行里一眼分出"这枚有东西在跑"。
                Capsule().strokeBorder(tint.opacity(isLive ? 0.85 : 0.25),
                                       lineWidth: isLive ? PopopxMetrics.stroke : PopopxMetrics.hairline)
            }
            // 微弱外发光：只给两档激活态，半径一格 `space2XS`。休眠不发光，
            // 深色模式下这圈同色光晕正是"已点亮"的主要线索。
            .shadow(color: isLive ? tint.opacity(0.35) : .clear, radius: PopopxMetrics.space2XS)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(hint)
        .accessibilityIdentifier("popopx.header.badge")
        .onAppear { restartBreathing() }
        .onChange(of: phase) { _, _ in restartBreathing() }
        .onChange(of: rotationIndex) { _, _ in rotateOnce() }
    }

    // MARK: 呈现片段

    /// 两档激活态把符号收进实心圆片：`mesh`+`onMesh`、`success`+`onSuccess` 是品牌档里
    /// 唯一两组"亮底深墨"的配对（浅色下白字压在 `#00A896` 上只有 2.98:1，文件头记过这条实测），
    /// 所以实心片上的墨色必须用这两组，不能沿用胶囊自身的 `*Ink`。
    @ViewBuilder private var symbol: some View {
        Group {
            switch phase.capsuleState {
            case .trialPulsing:
                Image(systemName: "sparkles")
                    .opacity(breathing ? 0.45 : 1)
                    .scaleEffect(breathing ? 0.85 : 1)
            case .activeLit:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(spin))
                    .animation(.linear(duration: 0.9), value: spin)
            case .dormant:
                Image(systemName: "circle.dashed")
            }
        }
        .font(PopopxType.microTag)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(isLive ? chipInk : tint)
        // nil 而不是 0：`.frame(width: 0)` 会把休眠态那枚 `circle.dashed` 直接压没。
        .frame(width: isLive ? PopopxMetrics.spaceL : nil, height: isLive ? PopopxMetrics.spaceL : nil)
        // 顶栏被长昵称挤窄时这个 frame 只会夹到更小的提案，实心色片连同下面的 `.circle` 底
        // 会一起变成横椭圆（真机第 3 轮的"外圈变形"）。锁死这一枚正方，文字档该让路仍由
        // `ViewThatFits` 决定，不改变顶栏的降级规则。
        .fixedSize()
        .background(isLive ? chipFill : Color.clear, in: .circle)
    }

    /// 休眠不是失败：不给危险色，只给中性墨（判据同文件头第三条）。
    private var isLive: Bool { phase.capsuleState != .dormant }

    private var tint: Color {
        switch phase.capsuleState {
        case .trialPulsing: PopopxPalette.meshInk
        case .activeLit: PopopxPalette.successInk
        case .dormant: PopopxPalette.labelSecondary
        }
    }

    private var chipFill: Color {
        switch phase.capsuleState {
        case .trialPulsing: PopopxPalette.mesh
        case .activeLit: PopopxPalette.success
        case .dormant: Color.clear
        }
    }

    private var chipInk: Color {
        switch phase.capsuleState {
        case .trialPulsing: PopopxPalette.onMesh
        case .activeLit: PopopxPalette.onSuccess
        case .dormant: PopopxPalette.labelSecondary
        }
    }

    /// 顶栏只放短句：体验态是时钟，点亮态是天数，休眠态说"免费节点"而不是"未激活"。
    /// 2026-11-20 真机第 2 轮起走词条（源文即 Key，16 译本，口径同 `PopopxTelemetryCopy`）；
    /// 顶栏在 393pt 上取的是只留符号那档，这两句只在宽屏出现，但 VoiceOver 与宽屏都必须能读。
    private var label: String {
        switch phase {
        case .dormant:
            return PopopxBadgeCapsuleCopy.dormant
        case let .trial(expiresAt):
            return PopopxBadgeCapsuleCopy.trial(PopopxBadgeCapsuleCopy.clock(expiresAt.timeIntervalSinceNow))
        case let .active(_, expiresAt):
            // 向上取整：还剩 1 分钟不能说"0 天"，那读起来像已经到期。
            let days = max(1, Int(ceil(max(0, expiresAt.timeIntervalSinceNow) / 86_400)))
            return PopopxBadgeCapsuleCopy.active(PopopxBadgeCapsuleCopy.daysClock(days))
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .dormant: PopopxBadgeCapsuleCopy.a11yDormant
        case let .trial(expiresAt):
            PopopxBadgeCapsuleCopy.a11yTrial(PopopxBadgeCapsuleCopy.clock(expiresAt.timeIntervalSinceNow))
        case let .active(_, expiresAt):
            PopopxBadgeCapsuleCopy.a11yActive(PopopxBadgeCapsuleCopy.clock(expiresAt.timeIntervalSinceNow))
        }
    }

    private var hint: String {
        switch phase.capsuleState {
        case .dormant: PopopxBadgeCapsuleCopy.hintDormant
        case .trialPulsing: PopopxBadgeCapsuleCopy.hintTrial
        case .activeLit: PopopxBadgeCapsuleCopy.hintActive
        }
    }

    private func tapped() {
        PopopxHaptics.selection()
        action()
    }

    /// 呼吸只属于体验态；其余两态进页面即归位，不留上一条状态的残留。
    private func restartBreathing() {
        guard phase.capsuleState == .trialPulsing, !reduceMotion else {
            breathing = false
            return
        }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathing = true }
    }

    /// 一次 360°：只改 `spin`，动画挂在符号的 `.animation(_:value:)` 上。
    /// 在同一次事务里"先减 360 再 withAnimation 归零"会被合并成一次赋值，圈就丢了。
    private func rotateOnce() {
        guard !reduceMotion else { return }
        spin -= 360
    }
}

// MARK: - 挂载件

/// 读运行时单例、并把三态接到三条出口的那一层。顶栏（`PopopxTelemetryHeader`）与"我的"页都用它，
/// 于是入口判据全国内只有一份。
struct PopopxBadgeCapsuleView: View {
    /// 顶栏在窄屏传 true：只留符号，中文不截断。
    var compact: Bool = false

    @State private var badge = PopopxBadgeManager.shared
    @State private var sheet: PopopxBadgeSheet?

    var body: some View {
        PopopxBadgeCapsule(
            phase: badge.phase,
            rotationIndex: badge.record?.rotationIndex ?? 0,
            compact: compact
        ) {
            route()
        }
        .popopxBadgeSheets($sheet)
    }

    private func route() {
        switch badge.phase.capsuleState {
        case .dormant: sheet = .paywall
        case .trialPulsing: sheet = .trial
        case .activeLit: sheet = .detail
        }
    }
}

// MARK: - 三条出口的单一 sheet 载体

/// 徽章的三条出口（付费墙 / 体验说明 / 详情）。
///
/// 以前这三张是挂在同一层上的三个 `.sheet(isPresented:)`：真机第 3 轮点「看徽章详情」没反应，
/// 就是因为体验弹窗里那个按钮只能 `dismiss()` —— 在同一层再抬一张 sheet 属于 sheet 套 sheet，
/// 系统会静默丢掉第二次呈现，界面看起来就是"点了没反应"。收成一个 `.sheet(item:)` 之后，
/// 换面板只是改 `item`，sheet 不关不换、内容原地切到详情页。
enum PopopxBadgeSheet: String, Identifiable {
    case paywall
    case trial
    case detail

    var id: String { rawValue }
}

/// 载体内容：`detents` 照原来那三张各档不动（付费墙和礼品卡一样吃 `.large`）。
struct PopopxBadgeSheetHost: View {
    @Binding var sheet: PopopxBadgeSheet?

    var body: some View {
        switch sheet {
        case .paywall:
            PopopxBadgePaywallView()
                .presentationDetents([.large])
        case .trial:
            PopopxTrialWelcomeModal(onOpenDetail: { sheet = .detail })
                .presentationDetents([.medium, .large])
        case .detail:
            PopopxBadgeDetailSheet()
                .presentationDetents([.medium, .large])
        case .none:
            EmptyView()
        }
    }
}

extension View {
    /// 把徽章三条出口挂到调用方：宿主只需要一份 `PopopxBadgeSheet?` 状态。
    /// 参数不能叫 `sheet`——那会盖掉 `View.sheet(item:)` 本身，编译器只会说"这不是函数"。
    func popopxBadgeSheets(_ badgeSheet: Binding<PopopxBadgeSheet?>) -> some View {
        sheet(item: badgeSheet) { _ in PopopxBadgeSheetHost(sheet: badgeSheet) }
    }
}

// MARK: - Previews

private struct PopopxBadgeCapsuleGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
            PopopxBadgeCapsule(phase: .trial(expiresAt: Date().addingTimeInterval(82_000))) {}
            PopopxBadgeCapsule(phase: .active(source: .appleSubscription,
                                              expiresAt: Date().addingTimeInterval(1_200_000)),
                               rotationIndex: 1) {}
            PopopxBadgeCapsule(phase: .dormant) {}
            PopopxBadgeCapsule(phase: .active(source: .creditsExchange,
                                              expiresAt: Date().addingTimeInterval(3_600)),
                               compact: true) {}
        }
        .padding(PopopxMetrics.spaceM)
        .background(PopopxPalette.base)
    }
}

struct PopopxBadgeCapsuleDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeCapsuleGallery()
            .preferredColorScheme(.dark)
    }
}

struct PopopxBadgeCapsuleLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeCapsuleGallery()
            .preferredColorScheme(.light)
    }
}

// MARK: - 顶栏短句

/// 顶栏这一枚胶囊的全部措辞。源文是英文原句，英文原句就是 Key（写法同 `PopopxTelemetryCopy`）：
/// `en.lproj` 按约定不写，回落 Key 本身就是英文，16 个译本目录各写各的译法。
///
/// 2026-11-20 真机第 2 轮对"中文残留"的裁定是**只翻顶栏这一处**，所以这里只收顶栏会读到的
/// 三句状态、三句 VoiceOver、三句提示和那个剩余时间；BadgeCredits 其余模块（扣点弹窗、详情页）
/// 的中文 Copy 一律保持原样，`PopopxBadgeCopy.remainingClock` 也照旧服务详情页。
private enum PopopxBadgeCapsuleCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX badge capsule")
    }

    static let dormant = key("Free node")
    static func trial(_ left: String) -> String { String(format: key("Trial %@"), left) }
    static func active(_ left: String) -> String { String(format: key("Encrypted routing · %@"), left) }

    static let a11yDormant = key("POPOPX privacy node: free relay")
    static func a11yTrial(_ left: String) -> String {
        String(format: key("POPOPX pioneer node trial: %@ left"), left)
    }
    static func a11yActive(_ left: String) -> String {
        String(format: key("POPOPX dynamic privacy node is lit: %@ left"), left)
    }

    static let hintDormant = key("Tap to see how to turn it on")
    static let hintTrial = key("Tap to read what the trial includes")
    static let hintActive = key("Tap to open badge details")

    /// 顶栏的剩余时间只留两个最大单位，且每个组合都是一个完整 Key：`"3 d 2 h"` 这种两段拼接
    /// 在 16 种语序里会翻车（俄语、匈牙利语会把它倒过来），所以宁可五句短句。
    /// 单位写在词条里而不是代码里，译本可以自己的缩写规则为准。
    static func clock(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(max(0, interval) / 60)))
        let days = minutes / 1_440
        let hours = minutes % 1_440 / 60
        let mins = minutes % 60
        if days > 0 {
            return hours > 0
                ? String(format: key("%1$d d %2$d h"), days, hours)
                : daysClock(days)
        }
        if hours > 0 {
            return mins > 0
                ? String(format: key("%1$d h %2$d min"), hours, mins)
                : String(format: key("%d h"), hours)
        }
        return String(format: key("%d min"), mins)
    }

    static func daysClock(_ days: Int) -> String { String(format: key("%d d"), days) }
}
