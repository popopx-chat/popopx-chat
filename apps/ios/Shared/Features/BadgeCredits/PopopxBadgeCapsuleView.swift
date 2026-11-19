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
//    `PopopxTelemetryHeader.swift:277-284`）；
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
                        .font(PopopxType.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? PopopxMetrics.spaceS : PopopxMetrics.spaceM)
            .frame(height: PopopxMetrics.space2XL)
            .frame(minWidth: compact ? PopopxMetrics.space2XL : 0)
            .background(PopopxPalette.card, in: .capsule)
            .overlay {
                Capsule().strokeBorder(tint.opacity(phase.capsuleState == .dormant ? 0.25 : 0.55),
                                       lineWidth: PopopxMetrics.hairline)
            }
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

    @ViewBuilder private var symbol: some View {
        switch phase.capsuleState {
        case .trialPulsing:
            Image(systemName: "sparkles")
                .font(PopopxType.microTag)
                .symbolRenderingMode(.hierarchical)
                .opacity(breathing ? 0.45 : 1)
                .scaleEffect(breathing ? 0.85 : 1)
        case .activeLit:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(PopopxType.microTag)
                .symbolRenderingMode(.hierarchical)
                .rotationEffect(.degrees(spin))
                .animation(.linear(duration: 0.9), value: spin)
        case .dormant:
            Image(systemName: "circle.dashed")
                .font(PopopxType.microTag)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var tint: Color {
        switch phase.capsuleState {
        case .trialPulsing: PopopxPalette.meshInk
        case .activeLit: PopopxPalette.successInk
        case .dormant: PopopxPalette.labelSecondary
        }
    }

    /// 顶栏只放短句：体验态是时钟，点亮态是天数，休眠态说"免费节点"而不是"未激活"。
    private var label: String {
        switch phase {
        case .dormant:
            return "免费节点"
        case let .trial(expiresAt):
            return "体验 \(PopopxBadgeCopy.remainingClock(expiresAt.timeIntervalSinceNow))"
        case let .active(_, expiresAt):
            // 向上取整：还剩 1 分钟不能说"0 天"，那读起来像已经到期。
            let days = Int(ceil(max(0, expiresAt.timeIntervalSinceNow) / 86_400))
            return "加密路由 · \(max(1, days)) 天"
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .dormant: "POPOPX 隐私节点：当前使用免费公共节点"
        case let .trial(expiresAt): "POPOPX 先锋节点体验：\(PopopxBadgeCopy.remainingClock(expiresAt.timeIntervalSinceNow))后到期"
        case let .active(source, expiresAt): "POPOPX 动态隐私节点徽章已点亮：\(PopopxBadgeCopy.remaining(expiresAt: expiresAt, source: source))"
        }
    }

    private var hint: String {
        switch phase.capsuleState {
        case .dormant: "轻点查看开启方式"
        case .trialPulsing: "轻点查看体验说明"
        case .activeLit: "轻点查看徽章详情"
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
    @State private var showsTrial = false
    @State private var showsDetail = false
    @State private var showsPaywall = false

    var body: some View {
        PopopxBadgeCapsule(
            phase: badge.phase,
            rotationIndex: badge.record?.rotationIndex ?? 0,
            compact: compact
        ) {
            route()
        }
        .sheet(isPresented: $showsTrial) {
            PopopxTrialWelcomeModal()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsDetail) {
            PopopxBadgeDetailSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsPaywall) {
            PopopxBadgePaywallView()
                .presentationDetents([.large])
        }
    }

    private func route() {
        switch badge.phase.capsuleState {
        case .dormant: showsPaywall = true
        case .trialPulsing: showsTrial = true
        case .activeLit: showsDetail = true
        }
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
