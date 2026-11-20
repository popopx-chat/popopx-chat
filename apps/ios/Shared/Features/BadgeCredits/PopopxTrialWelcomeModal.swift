//  PopopxTrialWelcomeModal.swift
//
//  【第五阶段 · 2】先锋节点体验徽章的领取面板：3 天，一次，本机为限。
//
//  ### 这个面板只对一件事负责：把资格讲清楚，然后交出去
//  领或不领的唯一判据是 `PopopxBadgeManager.canClaimPioneerTrial`（`record == nil` 且 Keychain 里没有
//  `.trialGuard`）。没有资格时这里**不给一个只会报错的按钮**（本仓的既有规矩：能力未接线的入口一律禁用或
//  整条不出现，同 `PopopxPlusMenu` 对三个闭包的处理，PopopxTelemetryHeader.swift:425-444），
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
//  ### 第二条出口：档位与价格（`onOpenPaywall`）
//  三态都在免费那一步下面常驻一个 `.secondary` 按钮进付费墙。这条腿的存在理由不是"多一个入口"：
//  顶栏那枚胶囊在 iPhone 上恒定制（只留符号，见 `PopopxBadgeCapsule` 的 `showsBuySegment`），
//  体验态里想买东西的用户如果只能靠猜，就会在这页读到"3 天后回落免费节点"却找不到下一步。
//  换面板走的是宿主那一份 `.sheet(item:)` 载体，不是第二张 sheet —— 所以不存在 sheet 套 sheet。
//
//  商业侧名词一律走 `PopopxCommerceCopy`（全语种目录），解释性长句留在本文件的文件私有 `Copy` 里
//  用中文——这是本轮的本地化裁定：只有钱、退款、合规相关的字符串进 `.lproj`。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI
import POPOPXChat

struct PopopxTrialWelcomeModal: View {
    /// 出口「看徽章详情」的去向。宿主给了它就换到详情面板（`PopopxBadgeSheetHost` 那条 `.sheet(item:)`），
    /// 没给就退回原来的只关闭 —— 真机第 3 轮的 P0 是这个按钮以前只有 `dismiss()`，点了像没反应。
    var onOpenDetail: (() -> Void)? = nil
    /// 出口「看档位与价格」的去向。声明在 `onOpenDetail` **之后**：两个都是可选闭包，
    /// 谁在前只影响调用点的书写顺序，而宿主那处（`PopopxBadgeSheetHost`）是带标签写的，
    /// 所以这里加参数不会改变任何已有调用点的含义。默认 nil = 本面板只管免费那条腿。
    var onOpenPaywall: (() -> Void)? = nil

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
        VStack(spacing: PopopxMetrics.spaceXS) {
            if badge.record?.source == .pioneerTrial {
                // 已经在这台设备上领到过：本面板的角色只剩"说清它还在跑"，出口是详情。
                PopopxButton(Copy.openDetail, systemImage: "eye", role: .secondary) {
                    if let onOpenDetail {
                        onOpenDetail()
                    } else {
                        dismiss()
                    }
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

            // 付费出口在**三态都常驻**，而且永远排在免费那一步之后、用 `.secondary`：
            // 体验还剩 3 天而档位选择已经存在，这一页不给出口就等于让用户去顶栏碰运气；
            // 但把付费做成主按钮，就把这页从"讲清楚免费这条路"改成了收银台。
            // 宿主没给 `onOpenPaywall` 时整条不出现（能力未接线的入口一律不摆，见文件头第 7-9 行那条规矩）。
            if let onOpenPaywall {
                PopopxButton(PopopxCommerceCopy.choosePlanAction, systemImage: "creditcard", role: .secondary) {
                    onOpenPaywall()
                }
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
        static let subtitle = NSLocalizedString("Run it for three days first: no account, no card, nothing to pay.", comment: "trial welcome modal")

        static func heroNote(_ days: Int) -> String { String(format: NSLocalizedString("Once claimed, this capsule grows in the top bar and keeps breathing for %lld days.", comment: "trial welcome modal"), days) }

        static let benefitsTitle = NSLocalizedString("What these three days look like", comment: "trial welcome modal")
        static let benefitStatusPanel = NSLocalizedString("Badge details is a read-only node status panel on this device: tier, expiry, reconciliation summary, local counters.", comment: "trial welcome modal")
        static let benefitRoute = NSLocalizedString("Encrypted relay routing: relay nodes never see the conversation, they only carry ciphertext.", comment: "trial welcome modal")
        static func benefitFallback(_ days: Int) -> String { String(format: NSLocalizedString("When it expires on day %lld the badge falls back to the free public SMP relay automatically and the connection stays up.", comment: "trial welcome modal"), days) }
        static let benefitKeepHistory = NSLocalizedString("Contacts, message history, groups and channels are all left untouched.", comment: "trial welcome modal")

        static let boundaryTitle = NSLocalizedString("Boundaries", comment: "trial welcome modal")
        static let boundaryFootnote = NSLocalizedString("Only what this layer really guarantees.", comment: "trial welcome modal")
        static let boundaryDevice = NSLocalizedString("The claim is kept in its own Keychain item on this device (readable only here, valid after the first unlock). No device identifier is uploaded.", comment: "trial welcome modal")
        static let boundaryNoAccount = NSLocalizedString("No account needed, and no Apple payment.", comment: "trial welcome modal")
        static let boundaryOneTime = NSLocalizedString("One claim per device.", comment: "trial welcome modal")

        static func claim(_ days: Int) -> String { String(format: NSLocalizedString("Claim the %lld-day trial badge", comment: "trial welcome modal"), days) }
        static let openDetail = NSLocalizedString("See badge details", comment: "trial welcome modal")
        static let close = NSLocalizedString("Got it", comment: "trial welcome modal")
        static let toastClaimed = NSLocalizedString("Trial badge lit", comment: "trial welcome modal")
        static let claimFailed = NSLocalizedString("This device could not record the claim — try again later, or check the device's free storage.", comment: "trial welcome modal")
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
