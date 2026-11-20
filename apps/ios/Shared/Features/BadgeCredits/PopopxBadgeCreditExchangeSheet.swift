//  PopopxBadgeCreditExchangeSheet.swift
//
//  【第五阶段 · 6b】算力点 → 徽章：600 点 / 30 天，4500 点 / 365 天，两条都写在这一个文件里。
//
//  ### 这一条腿不经过 Apple，所以它必须最诚实
//  算力点的来源只能是"此前已经通过 Apple 付过钱的充值"，所以兑换本身不产生新的 IAP：
//  审核视角下这是"花掉已有的余额"，不是"新的收入入口"。因此本面板从付费墙进来时挂在**次要操作**，
//  在这一页里也不放任何"更省钱""限时"的推销语（`PopopxBadgePaywallView.swift` 文件头同一判据）。
//
//  ### 扣点与点亮只有一个原子顺序，而且它不在本文件
//  `PopopxCreditsManager.exchangeCreditsForBadge(period:)` 先扣点、再点亮，点亮失败原额退回
//  （那条注释解释了为什么顺序不能反过来）。本面板因此**绝不**自己写 `.badgeRecord`、
//  也绝不自己 `debit`：两处各写一份，就可能出现"点花了、徽章没亮"或"徽章亮了、点没扣"。
//  视图在这里只做三件事：给出选中的档位、调用那一个函数、把结果如实说出来。
//
//  ### 叠加语义必须写在按钮旁边
//  `PopopxBadgeManager.activate` 取"更晚到期"而不是"更晚发行"：手里还剩 200 天时再兑一年，
//  那 200 天不会被抹掉。这句话如果不写在决策发生的地方，用户只能靠试。
//  同时不承诺"到期日 = 今天 + N 天"：已有剩余时实际到期更晚，页面直接给 `remainingDescription`。
//
//  ### 余额不够时给的是差额，不是一句"余额不足"
//  `insufficientCredits(balance:required:)` 的两个数字都在错误里，页面把它们算成"还差 N 点"，
//  并把出路指向付费墙的充值档 —— 关掉这一张就能看到，不叠第二层 sheet（叠上去会挡住刚看过的价格）。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI
import POPOPXChat

struct PopopxBadgeCreditExchangeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var credits = PopopxCreditsManager.shared
    @State private var badge = PopopxBadgeManager.shared

    @State private var period: PopopxNodeBadgePeriod = .monthly
    @State private var busy = false
    @State private var result: PopopxCreditExchangeResult?
    /// 点数不够时给自己挂的付费墙，理由见 footer 里 `Copy.topUp` 那一支的注释。
    @State private var showsPaywall = false

    var body: some View {
        PopopxSheetContainer(Copy.title, subtitle: Copy.subtitle) {
            content
        } footer: {
            footer
        }
        .sheet(isPresented: $showsPaywall) { PopopxBadgePaywallView() }
        .task { credits.loadIfNeeded() }
    }

    // MARK: 版面

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                balanceCard

                PopopxSectionCard(Copy.tiersTitle, footnote: Copy.stackFootnote) {
                    VStack(spacing: 0) {
                        PopopxRadioRow(Copy.tierTitle(period: .monthly),
                                       note: Copy.tierNote(period: .monthly),
                                       selected: period == .monthly) {
                            choose(.monthly)
                        }
                        Divider().overlay(PopopxPalette.separator)
                        PopopxRadioRow(Copy.tierTitle(period: .annual),
                                       note: Copy.tierNote(period: .annual),
                                       selected: period == .annual) {
                            choose(.annual)
                        }
                    }
                }

                if let result {
                    resultCard(result)
                }

                if badge.phase.isLit, let remaining = badge.remainingDescription {
                    PopopxSectionCard(Copy.currentTitle) {
                        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                            Text(verbatim: remaining)
                                .font(PopopxType.secondary)
                                .foregroundStyle(PopopxPalette.label)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: Copy.currentFootnote(period.days))
                                .font(PopopxType.microTag)
                                .foregroundStyle(PopopxPalette.labelHint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                boundaries
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    private var balanceCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            Text(PopopxCommerceCopy.creditsBalance)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelHint)
            Spacer()
            Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance))
                .font(PopopxType.display)
                .foregroundStyle(affordable ? PopopxPalette.label : PopopxPalette.dangerInk)
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.cardHigh, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
    }

    private func resultCard(_ result: PopopxCreditExchangeResult) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: result.success ? "checkmark.seal" : "exclamationmark.circle")
                    .font(PopopxType.secondary)
                    .foregroundStyle(result.success ? PopopxPalette.successInk : PopopxPalette.dangerInk)
                Text(verbatim: result.headline)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(result.success ? PopopxPalette.successInk : PopopxPalette.dangerInk)
            }
            Text(verbatim: result.detail)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            PopopxButton(Copy.exchange(period: period, cost: period.creditsCost),
                         systemImage: "sparkles",
                         isLoading: busy) {
                await exchange()
            }
            .disabled(busy)

            if !affordable, let shortfall {
                PopopxButton(Copy.topUp(shortfall), systemImage: "plus.circle", role: .ghost) {
                    // 这里原先写的是"关掉它，充值档就在下面那一页"——那句前提只成立一半：
                    // 本页有两条进路。付费墙 → 算力点中心 → 本页 那条，关掉确实回到充值档；
                    // 而 我的 → 算力点中心 → 本页 那条，关掉之后什么充值档都没有，
                    // 用户手里只剩一句"还差 200 点"。所以这一支自己挂一张付费墙。
                    // 同一个类型多开一个实例不会分叉价格：档位、顺序、句子全在
                    // `PopopxPaywallPlan` 与 `PopopxCommerceCopy` 那一处，这里一个字都不抄。
                    showsPaywall = true
                }
            }
            PopopxButton(Copy.close, role: .ghost) { dismiss() }
        }
    }

    // MARK: 判据

    private var affordable: Bool { credits.balance >= period.creditsCost }

    /// 差额只在这里算一次：按钮上的句子和结果卡里的句子都取自同一个数字。
    private var shortfall: Int? {
        affordable ? nil : period.creditsCost - credits.balance
    }

    // MARK: 动作

    private func choose(_ next: PopopxNodeBadgePeriod) {
        guard next != period else { return }
        period = next
        result = nil
        PopopxHaptics.selection()
    }

    private func exchange() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let chosen = period
        do {
            try credits.exchangeCreditsForBadge(period: chosen)
            PopopxHaptics.notice(.success)
            // 到期时间取兑换之后那一份，而不是"今天 + N 天"：已有剩余时两者不同。
            result = PopopxCreditExchangeResult(
                success: true,
                headline: Copy.exchanged(chosen),
                detail: badge.remainingDescription ?? Copy.exchangedDetail(chosen)
            )
        } catch let error as PopopxBadgeCreditsError {
            PopopxHaptics.notice(.error)
            result = PopopxCreditExchangeResult(
                success: false,
                headline: error.errorDescription ?? Copy.genericFailure,
                detail: Copy.reversedDetail(chosen)
            )
        } catch {
            PopopxHaptics.notice(.error)
            result = PopopxCreditExchangeResult(
                success: false,
                headline: PopopxBadgeCreditsError.keychainUnavailable.errorDescription ?? Copy.genericFailure,
                detail: Copy.reversedDetail(chosen)
            )
        }
    }
}

// MARK: - 结果

/// 兑换的一句话结果。`detail` 是第二句"接下来会怎样"，不给只言片语的"失败"。
struct PopopxCreditExchangeResult: Hashable {
    let success: Bool
    let headline: String
    let detail: String
}

// MARK: - 文案

private extension PopopxBadgeCreditExchangeSheet {
    enum Copy {
        static let title = NSLocalizedString("Light up a badge with Compute Credits", comment: "")
        static let subtitle = NSLocalizedString("Compute Credits spent on this page turn into an active encrypted relay route.", comment: "")
        static let tiersTitle = NSLocalizedString("Which tier to exchange for", comment: "")
        static let stackFootnote = NSLocalizedString("Remaining time is never erased: after an exchange the expiry is the later of the two.", comment: "")
        static func tierTitle(period: PopopxNodeBadgePeriod) -> String {
            String(format: NSLocalizedString("%1$lld days · %2$lld Compute Credits", comment: ""), period.days, period.creditsCost)
        }
        static func tierNote(period: PopopxNodeBadgePeriod) -> String {
            switch period {
            case .monthly: String(format: NSLocalizedString("Counted as %lld days; you can exchange again any time before expiry.", comment: ""), period.days)
            case .annual: String(format: NSLocalizedString("Counted as %lld days; this also merges with any remaining time.", comment: ""), period.days)
            }
        }
        static let currentTitle = NSLocalizedString("Current badge", comment: "")
        static func currentFootnote(_ days: Int) -> String { String(format: NSLocalizedString("Exchanging this tier again adds %lld days instead of restarting from today.", comment: ""), days) }
        static func exchange(period: PopopxNodeBadgePeriod, cost: Int) -> String {
            String(format: NSLocalizedString("Spend %1$lld Compute Credits · light up %2$lld days", comment: ""), cost, period.days)
        }
        static func topUp(_ shortfall: Int) -> String { String(format: NSLocalizedString("%lld Compute Credits short · go to top up", comment: ""), shortfall) }
        static let close = NSLocalizedString("Close", comment: "")
        static func exchanged(_ period: PopopxNodeBadgePeriod) -> String { String(format: NSLocalizedString("Lit up %lld days", comment: ""), period.days) }
        static func exchangedDetail(_ period: PopopxNodeBadgePeriod) -> String {
            NSLocalizedString("The credits were deducted and the badge was written to this device's Keychain.", comment: "")
        }
        static func reversedDetail(_ period: PopopxNodeBadgePeriod) -> String {
            String(format: NSLocalizedString("This exchange did not take effect; %lld Compute Credits were refunded exactly, and the balance is unchanged.", comment: ""), period.creditsCost)
        }
        static let genericFailure = NSLocalizedString("That did not complete.", comment: "")
        static let boundariesTitle = NSLocalizedString("What this screen promises, and what it does not", comment: "")
        static let boundariesFootnote = NSLocalizedString("Exchanges do not go through Apple, so this page has to say things more plainly than any advertisement.", comment: "")
        static let boundaryOne = NSLocalizedString("Compute Credits can only be spent inside this app — they cannot be gifted, cashed out or moved to another device.", comment: "")
        static let boundaryTwo = NSLocalizedString("Credits are not refundable once exchanged; if lighting up fails, the code refunds the full amount, and this page never charges a second time on its own.", comment: "")
        static let boundaryThree = NSLocalizedString("When a badge expires you only fall back to the free public relay: contacts, conversation history, groups and channels are all kept.", comment: "")
    }
}

// MARK: - Previews

struct PopopxBadgeCreditExchangeDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeCreditExchangeSheet()
            .preferredColorScheme(.dark)
    }
}

struct PopopxBadgeCreditExchangeLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeCreditExchangeSheet()
            .preferredColorScheme(.light)
    }
}
