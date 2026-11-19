//  PopopxTrialWelcomeModal.swift
//
//  【第五阶段 · 2】先锋节点体验徽章的领取面板：3 天，一次，本机为限。
//
//  ### 这个面板只对一件事负责：把资格讲清楚，然后交出去
//  领或不领的唯一判据是 `PopopxBadgeManager.canClaimPioneerTrial`（`record == nil` 且 Keychain 里没有
//  `.trialGuard`）。没有资格时这里**不给一个只会报错的按钮**（本仓的既有规矩：能力未接线的入口一律禁用或
//  整条不出现，同 `PopopxPlusMenu` 对三个闭包的处理，PopopxTelemetryHeader.swift:365-384），
//  而是把"为什么不能领"说出来。
//
//  ### 三行诚实边界
//  - "每台设备限领一次"这件事由 DeviceCheck token 或本机安装指纹保证，**两者都只在本机生效**：
//    重装系统、刷机、或指纹那格 Keychain 被清空后，本层没有第二种办法拒绝第二次领取——
//    真的服务端黑名单要上传设备标识，与"零服务端账本、不收集标识符"的架构红线冲突。所以文案说
//    "本机限领一次"，不说"不可能领第二次"。
//  - 到期后的回落是"回到免费公共 SMP 节点"，不是断网：联系人、历史消息、群组、频道一概不动。
//    这句必须写死在面板里，因为它是用户按"领取"之前唯一真正想知道的事。
//  - 体验徽章与付费徽章是同一个 `PopopxBadgeRecord` 槽位：付费激活会**覆盖** source，
//    到期时间取两者较晚的那一个（`PopopxBadgeManager.activate` 的合并规则），所以不存在
//    "为了买正式徽章先浪费三天体验"的取舍。
//
//  商业侧名词一律走 `PopopxCommerceCopy`（全语种目录），解释性长句留在本文件的文件私有 `Copy` 里
//  用中文——这是本轮的本地化裁定：只有钱、退款、合规相关的字符串进 `.lproj`。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI
import POPOPXChat

struct PopopxTrialWelcomeModal: View {
    @Environment(\.dismiss) private var dismiss

    @State private var badge = PopopxBadgeManager.shared
    @State private var toast = PopopxToastModel()
    @State private var isClaiming = false
    /// 领取失败时的那一句原因。`nil` = 没失败过；不用布尔 + 字符串两个字段，避免"有布尔却没原因"的空态。
    @State private var failure: String?

    private static let trialDays = Int(PopopxCommerceLimits.trialSeconds / 86_400)

    var body: some View {
        PopopxSheetContainer(Copy.title, subtitle: Copy.subtitle) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                    hero
                    benefits
                    if badge.canClaimPioneerTrial || badge.record?.source == .pioneerTrial {
                        boundaries
                    }
                    if let failure {
                        notice(failure, tint: .danger)
                    }
                }
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.bottom, PopopxMetrics.spaceL)
            }
        } footer: {
            footerRow
        }
        .popopxToast(toast)
    }

    // MARK: 主视觉

    /// 一枚放大的胶囊态预览：让用户在按"领取"之前先看到顶栏会变成什么样。
    private var hero: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            PopopxBadgeCapsule(phase: badge.record?.source == .pioneerTrial
                                ? badge.phase
                                : .trial(expiresAt: Date().addingTimeInterval(PopopxCommerceLimits.trialSeconds))) {}
                .allowsHitTesting(false)
            Text(verbatim: Copy.heroNote(Self.trialDays))
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.meshInk.opacity(0.10), in: .rect(cornerRadius: PopopxMetrics.radiusCard))
    }

    private var benefits: some View {
        PopopxSectionCard(Copy.benefitsTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                bullet("chart.bar.xaxis", Copy.benefitStatusPanel)
                bullet("lock.shield", Copy.benefitRoute)
                bullet("clock.arrow.circlepath", Copy.benefitFallback(Self.trialDays))
                bullet("square.and.arrow.down.on.square", Copy.benefitKeepHistory)
            }
        }
    }

    private var boundaries: some View {
        PopopxSectionCard(Copy.boundaryTitle, footnote: Copy.boundaryFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                bullet("iphone", Copy.boundaryDevice)
                bullet("person.crop.circle.badge.xmark", Copy.boundaryNoAccount)
                bullet("tray.full", Copy.boundaryOneTime)
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: symbol)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.meshInk)
                .frame(width: PopopxMetrics.spaceXL)
            Text(verbatim: text)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func notice(_ text: String, tint: PopopxIconTint) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(tint.fill)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
        .padding(PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.fill.opacity(0.10), in: .rect(cornerRadius: PopopxMetrics.radiusControl))
    }

    // MARK: 出口

    @ViewBuilder private var footerRow: some View {
        if badge.record?.source == .pioneerTrial {
            // 已经在这台设备上领到过：本面板的角色只剩"说清它还在跑"，出口是详情。
            PopopxButton(Copy.openDetail, systemImage: "eye", role: .secondary) {
                dismiss()
            }
        } else if badge.canClaimPioneerTrial {
            PopopxButton(Copy.claim(Self.trialDays), systemImage: "sparkles", isLoading: isClaiming) {
                await claim()
            }
        } else {
            // 没资格：不摆一个只会报错的按钮，只解释。
            PopopxButton(Copy.close, role: .secondary) {
                dismiss()
            }
        }
    }

    private func claim() async {
        guard !isClaiming else { return }
        isClaiming = true
        defer { isClaiming = false }
        let issued = await PopopxBadgeManager.shared.issuePioneerTrialIfNeeded()
        if issued != nil {
            PopopxHaptics.notice(.success)
            toast.show(Copy.toastClaimed, kind: .encrypted)
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } else {
            // 走到这里只剩两种可能：并发下已经写过 guard，或 Keychain 那一次写入失败。
            // 两种都归一句"本机没能记下这次领取"，不假装知道是哪种，也不重试写第二遍。
            failure = Copy.claimFailed
            PopopxHaptics.notice(.error)
        }
    }
}

// MARK: - 文案

private extension PopopxTrialWelcomeModal {
    enum Copy {
        static let title = PopopxCommerceCopy.trialBadgeName
        static let subtitle = "先跑三天：不建账号、不绑卡，也不需要任何付费。"

        static func heroNote(_ days: Int) -> String { "领取后顶栏会长出这枚胶囊，\(days) 天内它一直呼吸。" }

        static let benefitsTitle = "这三天里会怎样"
        static let benefitStatusPanel = "徽章详情是一台只读本机的节点状态面板：档位、到期、对账摘要、本机计数。"
        static let benefitRoute = "加密中继路由：中继节点看不到会话内容，只搬运密文。"
        static func benefitFallback(_ days: Int) -> String { "第 \(days) 天到期后自动回到免费公共 SMP 节点，不会断线。" }
        static let benefitKeepHistory = "联系人、历史消息、群组、频道一概不动。"

        static let boundaryTitle = "边界"
        static let boundaryFootnote = "只说本层真能做到的那部分。"
        static let boundaryDevice = "领取记录只存在本机 Keychain 的独立一格（仅本机可读、首次解锁后有效），不上传任何设备标识。"
        static let boundaryNoAccount = "不需要账号，也不需要 Apple 付款。"
        static let boundaryOneTime = "本机限领一次。"

        static func claim(_ days: Int) -> String { "领取 \(days) 天体验徽章" }
        static let openDetail = "看徽章详情"
        static let close = "知道了"
        static let toastClaimed = "体验徽章已点亮"
        static let claimFailed = "本机没能记下这次领取，请稍后重试或检查设备存储空间。"
    }
}

// MARK: - Previews

/// 预览读的是真单例：`PopopxBadgeManager` 的 `init` 只从 Keychain 读那一条 `PopopxBadgeRecord`
/// （`PopopxBadgeManager.swift:65-71`），不联网、不起心跳，所以在模拟器里它是惰性的——
/// 显示哪一支取决于这台设备上有没有领过。真机上领过一次之后，本面板显示的是"已领"那一支。
struct PopopxTrialWelcomeDormant_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTrialWelcomeModal()
            .preferredColorScheme(.dark)
    }
}

struct PopopxTrialWelcomeLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTrialWelcomeModal()
            .preferredColorScheme(.light)
    }
}
