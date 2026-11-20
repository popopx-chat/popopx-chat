//  PopopxBadgeDetailSheet.swift
//
//  【第五阶段 · 3】点亮态徽章的详情：这台设备凭什么说自己的流量在动态中继上，
//  以及订阅那一档唯一合法的出口（App 内"管理订阅"）。
//
//  ### 为什么这个面板里没有"刷新状态""连接测试"这类按钮
//  本徽章的真相只有两份：Keychain 里那条 `PopopxBadgeRecord`，和 StoreKit 给出的权益
//  （`PopopxBadgeManager.subscriptionSnapshot`）。没有任何服务端可以问。所以这里只呈现，
//  不假装检测——一个"测试节点连通性"的按钮要么是真的去测（本层没有可测的对象），
//  就是一个装饰，而装饰在合规上是要被追问的。
//
//  ### 对账摘要不是装饰
//  `receiptDigest` 是来源凭据（订阅 JWS 原文 / 兑换流水）的短摘要。它能对上的范围只有一件事：
//  本机记录的这一条徽章**当时**来自哪一份凭据。它不含凭据原文，也不可反查，
//  所以展示它是安全的；用户拿它跟自己的 App 购买记录核对时，比"来源：Apple 订阅"这句空话有用。
//
//  ### 订阅那一档的两条硬约束（审核口径）
//  - 续费状态只从 `Transaction`/`Product.SubscriptionInfo.Status` 读，不写、不猜；
//    读不到就明说"暂时读不到"，不显示"已续费"（`PopopxSubscriptionRenewalState.unknown`）。
//  - 取消续费只能走 `AppStore.showManageSubscriptions`（`PopopxStoreKitManager.manageSubscriptions()`），
//    app 内不自建取消入口、不自建退款入口。恢复购买同理走 `AppStore.sync()`，在付费墙那一页。
//
//  ### 这一页的第一按钮是「续或换档」，不是「关闭」
//  subtitle 那一行本来就在报剩余天数，读完的下一步只有两个：把这一段接上、或换一条路走。
//  所以 `onOpenPaywall` 给到时它排第一，且**不分来源**（订阅 / 通行证 / 券 / 点数兑换 / 体验都一样）；
//  上面那条"只能走 Apple 的管理页"的约束管的是**取消与退款**，与"再买一档"是两件事，
//  所以「管理订阅」仍留在第二排，两条都不退让。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI
import POPOPXChat

struct PopopxBadgeDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var badge = PopopxBadgeManager.shared
    @State private var statusBusy = false
    @State private var statusFailure: String?

    /// 「档位与价格」那一条主操作的去处，由宿主（`PopopxBadgeSheetHost`）给。
    /// 给不到就整条不摆：一个只会报错的按钮比没有按钮更坏，理由同 `PopopxTrialWelcomeModal` 那一处。
    var onOpenPaywall: (() -> Void)? = nil

    var body: some View {
        PopopxSheetContainer(Copy.title, subtitle: badge.remainingDescription ?? Copy.dormantSubtitle) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                    statusCard
                    if let record = badge.record {
                        provenance(record)
                        if record.source == .appleSubscription {
                            subscriptionCard
                        }
                        rotationCard(record)
                    }
                    boundaries
                }
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.bottom, PopopxMetrics.spaceL)
            }
        } footer: {
            footerRow
        }
        .task { await refreshSubscription() }
    }

    // MARK: 状态

    private var statusCard: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            PopopxBadgeCapsule(phase: badge.phase, rotationIndex: badge.record?.rotationIndex ?? 0) {}
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(verbatim: Copy.stateTitle(badge.phase.capsuleState))
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                if let description = badge.remainingDescription {
                    Text(verbatim: description)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PopopxMetrics.spaceS)
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }

    /// 来源与到期。全部取自本机那一条记录，一次网络请求都不发。
    private func provenance(_ record: PopopxBadgeRecord) -> some View {
        PopopxSectionCard(Copy.provenanceTitle) {
            VStack(spacing: PopopxMetrics.spaceXS) {
                row(Copy.sourceRow, record.source.displayName)
                row(Copy.periodRow, Copy.period(record))
                row(Copy.issuedRow, PopopxCommerceFormat.date(record.issuedAtMs))
                row(Copy.expiresRow, PopopxCommerceFormat.date(record.expiresAtMs))
                if let digest = record.receiptDigest {
                    row(Copy.digestRow, digest, monospaced: true)
                }
            }
        }
    }

    private func rotationCard(_ record: PopopxBadgeRecord) -> some View {
        PopopxSectionCard(Copy.rotationTitle, footnote: Copy.rotationFootnote) {
            VStack(spacing: PopopxMetrics.spaceXS) {
                row(Copy.rotationCountRow, "\(record.rotationIndex)")
                row(Copy.rotationEveryRow,
                    "≥ \(Int(PopopxCommerceLimits.nodeRotationSeconds)) 秒")
            }
        }
    }

    // MARK: 订阅

    @ViewBuilder private var subscriptionCard: some View {
        let snapshot = badge.subscriptionSnapshot
        PopopxSectionCard(Copy.subscriptionTitle, footnote: Copy.subscriptionFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                row(Copy.renewalRow, renewalWords(snapshot?.state))
                if let snapshot {
                    row(Copy.autoRenewRow, snapshot.willAutoRenew ? Copy.yes : Copy.no)
                    if let expiresAtMs = snapshot.expiresAtMs {
                        row(Copy.renewsAtRow, PopopxCommerceFormat.date(expiresAtMs))
                    }
                }
                if let statusFailure {
                    Text(verbatim: statusFailure)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var boundaries: some View {
        PopopxSectionCard(Copy.boundaryTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                note(Copy.boundaryLocal)
                note(Copy.boundaryFallback)
                note(Copy.boundaryNoProbe)
            }
        }
    }

    @ViewBuilder private var footerRow: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            // 主操作：进付费墙「续或换档」。这一条**按来源不分叉**（订阅 / 通行证 / 礼品券 /
            // 点数兑换 / 体验都给它），理由是这一页的 subtitle 已经在报剩余天数，而"接下来怎么办"
            // 在五种来源上是同一个问题：要么把这一段接上，要么换一条路走。
            // 以前这页对非订阅来源只有一个「关闭」——用户读完"还剩 3 天"之后没有任何下一步。
            if let onOpenPaywall {
                PopopxButton(PopopxCommerceCopy.renewOrChangePlanAction,
                             systemImage: "arrow.triangle.2.circlepath") {
                    onOpenPaywall()
                }
            }
            if badge.record?.source == .appleSubscription {
                // 自动续费那一族的"关掉/改档"在 Apple 那边，这条留在第二排而不是换成主操作：
                // 取消续费与换套餐是两件事，前者不需要重新付费，混成一句会误导。
                PopopxButton(Copy.manageSubscriptions, systemImage: "creditcard",
                             role: .secondary, isLoading: statusBusy) {
                    await PopopxStoreKitManager.shared.manageSubscriptions()
                }
            } else {
                PopopxButton(Copy.close, role: .secondary) {
                    dismiss()
                }
            }
        }
    }

    // MARK: 组成件

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Text(verbatim: label)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Spacer(minLength: PopopxMetrics.spaceS)
            Text(verbatim: value)
                .font(monospaced ? PopopxType.metricSmall : PopopxType.secondary)
                .foregroundStyle(PopopxPalette.label)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "checkmark.seal")
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.successInk)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 续费档位说人话。`unknown` 不是"没续费"，是"这次没读到"，措辞必须分开。
    private func renewalWords(_ state: PopopxSubscriptionRenewalState?) -> String {
        switch state ?? .unknown {
        case .renewing: Copy.renewing
        case .cancelled: Copy.cancelledAtPeriodEnd
        case .billingRetry: Copy.billingRetry
        case .ended: Copy.ended
        case .unknown: Copy.unknown
        }
    }

    private func refreshSubscription() async {
        guard badge.record?.source == .appleSubscription else { return }
        statusBusy = true
        defer { statusBusy = false }
        await badge.refreshSubscriptionStatus()
        // 读回来是 nil 也照样说清楚：这条腿的失败不是报错，是"暂时读不到"。
        statusFailure = badge.subscriptionSnapshot == nil ? Copy.statusUnavailable : nil
    }
}

// MARK: - 来源的中文名

private extension PopopxBadgeSource {
    /// 五档来源的措辞。判据与 `PopopxBadgeManager` 的写入一一对应，不另造第六种说法。
    /// 通行证那一格走 `PopopxCommerceCopy`：它是这一轮新增的来源，本轮红线禁止在代码里落新的裸中文
    /// （上面四格是既有文案，收口到 key 要一并动 16 本目录，不在本轮范围）。
    var displayName: String {
        switch self {
        case .pioneerTrial: "先锋节点体验徽章"
        case .appleSubscription: "App Store 订阅"
        case .storePass: PopopxCommerceCopy.passSourceName
        case .creditsExchange: "算力点兑换"
        case .giftedVoucher: "收到的礼品卡"
        }
    }
}

// MARK: - 文案

private extension PopopxBadgeDetailSheet {
    enum Copy {
        static let title = PopopxCommerceCopy.badgeProductName
        static let dormantSubtitle = "当前使用免费公共 SMP 节点。"

        static func stateTitle(_ state: PopopxBadgeCapsuleState) -> String {
            switch state {
            case .trialPulsing: "体验中"
            case .activeLit: "徽章已点亮"
            case .dormant: "未点亮"
            }
        }

        static let provenanceTitle = "本机记录"
        static let sourceRow = "来源"
        static let periodRow = "档位"

        /// 「档位」那一格的值。源文是英文原句、英文原句就是 Key（写法同 `PopopxBadgeCapsuleView.swift`
        /// 的 `PopopxBadgeCapsuleCopy`）：`en.lproj` 按约定不写，16 个译本目录各写各的。
        ///
        /// 判据用来源而不是天数 —— `PopopxBadgeManager.swift:152` 给先锋体验写下的 `period` 是
        /// `.monthly`（体验只是借月度档那个形态登记，到期时刻另按 `PopopxCommerceLimits.trialSeconds`
        /// 算），所以照 `record.period.days` 印出来就是把 3 天的体验说成 30 天，真机第 5 轮报的
        /// 正是这一格。天数从 `trialSeconds` 现算，与到期时刻同一口径，不引入第二个数字。
        static func period(_ record: PopopxBadgeRecord) -> String {
            if record.source == .pioneerTrial {
                let trialDays = max(1, Int(ceil(PopopxCommerceLimits.trialSeconds / 86_400)))
                return String(format: key("%lld days (Pioneer Trial)"), trialDays)
            }
            return String(format: key("%lld days"), record.period.days)
        }

        private static func key(_ value: String) -> String {
            NSLocalizedString(value, comment: "POPOPX badge detail")
        }
        static let issuedRow = "生效"
        static let expiresRow = "到期"
        static let digestRow = "对账摘要"

        static let rotationTitle = "节点状态面板"
        static let rotationFootnote = "这一格只是本机计数：徽章点亮期间每固定间隔自增一次，没有任何中继节点因为它而改变。"
        static let rotationCountRow = "本机计数"
        static let rotationEveryRow = "间隔"

        static let subscriptionTitle = "订阅"
        static let subscriptionFootnote = PopopxCommerceCopy.renewalStatement
        static let renewalRow = "续费状态"
        static let autoRenewRow = "自动续费"
        static let renewsAtRow = "下一次"
        static let renewing = "自动续费中"
        static let cancelledAtPeriodEnd = "已取消，本期末了后不再续费"
        static let billingRetry = "扣款待重试"
        static let ended = "已结束"
        static let unknown = "暂时读不到"
        static let yes = "开"
        static let no = "关"
        static let statusUnavailable = "这一次没能读到 Apple 的续费状态；下面的档位是按本机记录显示的。"
        static let manageSubscriptions = "管理订阅"

        static let boundaryTitle = "这块徽章的边界"
        static let boundaryLocal = "徽章、券、算力点都只存在本机；没有任何服务器可以查询或撤销它。"
        static let boundaryFallback = "到期后自动回到免费公共 SMP 节点，联系人和历史消息都不动。"
        static let boundaryNoProbe = "本页不做连通性测试：没有可问的服务器，所以也不摆一个装饰性的检测按钮。"

        static let close = "关闭"
    }
}

// MARK: - 时间格式

/// 详情页的时间一律到日，不带秒：用户在这里要核对的是"哪天到期"，不是"几点几分"。
/// `PopopxBadgeManager` 里那个同用途的格式化是私有的，本模块不共用一份可变 formatter，
/// 所以每个视图文件各留一份只读的（`DateFormatter` 在这里不是热点，一天最多渲染几条）。
enum PopopxCommerceFormat {
    private static let dayMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func date(_ milliseconds: Int64) -> String {
        dayMonth.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }

    /// 倒计时到分。红包、券这类"要当场看还剩多少"的场合用它。
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = total % 86_400 / 3_600
        let minutes = total % 3_600 / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分"
    }
}

// MARK: - Previews

struct PopopxBadgeDetailDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeDetailSheet()
            .preferredColorScheme(.dark)
    }
}

struct PopopxBadgeDetailLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeDetailSheet()
            .preferredColorScheme(.light)
    }
}
