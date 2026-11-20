//  PopopxCreditsStoreView.swift
//
//  【第六阶段 · 1】算力点中心：余额、用途表、流水。这一页一分钱都不收。
//
//  ### 为什么这一页没有"充值"按钮
//  它有两张进来的门：付费墙（`PopopxBadgePaywallView`，见它的 `showsWallet`）的次要操作，
//  以及「我的 · 算力点中心」那一行。后一条下面并没有付费墙，所以"关掉这一页充值档就在下一层"
//  这句话并不总成立——但这一页仍然不挂充值：在这里再挂一张付费墙会得到 sheet 套 sheet 的
//  两层同价目表，两层的价格注释一旦改写就会分叉。
//  无条件的那条路归「我的」那一行（`PopopxMeView` 的 `badgeSheet = .paywall`，它存在正是因为顶栏胶囊
//  点亮之后就把点击交给徽章详情，再没有别的地方能打付费墙）。
//  所以这一页只回答两个问题：**我有多少**、**这些点能花在哪、花过多少**。
//
//  ### 余额与流水必须各自承认自己的不可靠
//  `PopopxCreditsWallet.needsReconcile` 由 `verifyLedgerConsistency()` 在余额与流水求和不一致时置真
//  （流水上限 240 条，所以老账被丢弃不算不一致，见那里的注释）。这一页把这个状态显示出来，
//  而不是显示一个"看起来正常"的数字：把不可信的余额静默花掉是更坏的结局。
//
//  ### 用途表的数字全部取自代码里已有的那一份
//  600/4500 来自 `PopopxNodeBadgePeriod.creditsCost`，20 来自
//  `PopopxCommerceLimits.extendedSecureWindowCost`，150 来自 `PopopxCosmetic.cost`，
//  红包面额来自 `PopopxCommerceLimits.redPacketAmounts`。这一页不允许出现第四个"多少点"的字面量：
//  表上的价格与真实扣款分叉是这类页面唯一致命的 bug。
//  只有两处例外并且必须例外：频道订阅价与资料卡解锁价由对端自己定，页面上因此不写数字，只写"由对方设定"。
//
//  ### 用途表里只有外观那两行能按
//  外观是这一页唯一"点数 → 本机效果"的一步到位：一档、一个价、一次扣完、没有下一步，
//  所以做成一颗按钮不需要再造一个 sheet。徽章要选周期、红包要选份数与落点、
//  频道与资料卡的门槛由对方定——这四样都有自己的面板，从这一页只能进不能在这儿办。
//  已解锁的那一行不再是按钮：再按一次只会得到一句"你已经有了"，那是这一族里最没用的反馈。
//
//  ### 流水行只读存进去的那句 note
//  `PopopxCreditsEntry.note` 是扣款/入账当时写下的中文句子（`PopopxCreditsCopy`），
//  所以本页不需要第二套"类别 → 文案"映射；`kind.sign` 给方向，`kind.isIncome` 给颜色，
//  两者都只在那一处定义。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI
import POPOPXChat

struct PopopxCreditsStoreView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var credits = PopopxCreditsManager.shared
    @State private var showsExchange = false
    /// 待确认的那一档外观。弹窗的可见性由它派生（下面那个 Binding），所以不存在
    /// "弹窗还开着但已经没人被确认"的中间帧——和资料卡解锁那一处同一个形状。
    @State private var pendingCosmetic: PopopxCosmetic?
    /// 上一次点数花费的结果，一句为止。它不叫"提示"也不自动消失：这一页是账本页，
    /// 用户需要看见"刚刚那 150 点确实记上了"，而一句会自己没掉的话等于没说。
    @State private var spendNote: String?

    var body: some View {
        PopopxSheetContainer(Copy.title, subtitle: PopopxCommerceCopy.nodeClusterTerm) {
            content
        } footer: {
            footer
        }
        .sheet(isPresented: $showsExchange) { PopopxBadgeCreditExchangeSheet() }
        .alert(Copy.unlockTitle, isPresented: unlockPrompt) {
            if let cosmetic = pendingCosmetic {
                Button(Copy.unlockConfirm(cosmetic)) { purchase(cosmetic) }
                Button(Copy.unlockCancel, role: .cancel) { pendingCosmetic = nil }
            }
        } message: {
            if let cosmetic = pendingCosmetic {
                Text(verbatim: Copy.unlockMessage(cosmetic: cosmetic, balance: credits.balance))
            }
        }
        .task { credits.loadIfNeeded() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                balanceCard

                if credits.wallet.needsReconcile {
                    reconcileNote
                }

                usesCard

                if let spendNote {
                    spendLine(spendNote)
                }

                pendingCard

                PopopxSectionCard(Copy.ledgerTitle, footnote: Copy.ledgerFootnote) {
                    VStack(spacing: 0) {
                        let entries = credits.recentEntries
                        if entries.isEmpty {
                            Text(verbatim: Copy.ledgerEmpty)
                                .font(PopopxType.caption)
                                .foregroundStyle(PopopxPalette.labelHint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, PopopxMetrics.spaceS)
                        } else {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                ledgerRow(entry)
                                if index < entries.count - 1 {
                                    Divider().overlay(PopopxPalette.separator)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    // MARK: 余额

    private var balanceCard: some View {
        // 品牌底上只用 onBrand 系：`label` 是那套深墨，压在 brand 上对比度会掉到不可读。
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(PopopxCommerceCopy.creditsBalance)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.onBrand.opacity(0.80))
            Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance))
                .font(PopopxType.display)
                .foregroundStyle(PopopxPalette.onBrand)
            Text(verbatim: Copy.updated(PopopxCommerceFormat.date(credits.wallet.updatedAtMs)))
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.onBrand.opacity(0.70))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PopopxMetrics.spaceM)
        .background(PopopxPalette.brand, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
    }

    private var reconcileNote: some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "exclamationmark.triangle")
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.dangerInk)
            Text(verbatim: Copy.reconcileBody)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.dangerInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.danger.opacity(0.12), in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .accessibilityElement(children: .combine)
    }

    // MARK: 用途表

    private var usesCard: some View {
        PopopxSectionCard(Copy.usesTitle, footnote: Copy.usesFootnote) {
            VStack(spacing: 0) {
                useRow("sparkles", Copy.useBadgeTitle,
                       Copy.useBadgeNote,
                       amount: "\(PopopxNodeBadgePeriod.monthly.creditsCost) / \(PopopxNodeBadgePeriod.annual.creditsCost)")
                divider
                useRow("gift", Copy.useVoucherTitle, Copy.useVoucherNote,
                       amount: "\(PopopxNodeBadgePeriod.monthly.creditsCost) / \(PopopxNodeBadgePeriod.annual.creditsCost)")
                divider
                useRow("envelope", Copy.usePacketTitle, Copy.usePacketNote,
                       amount: PopopxCommerceLimits.redPacketAmounts
                           .map(String.init)
                           .joined(separator: " / "))
                divider
                useRow("number", Copy.useChannelTitle, Copy.useChannelNote, amount: nil)
                divider
                useRow("person.crop.circle.badge.checkmark", Copy.useProfileTitle, Copy.useProfileNote, amount: nil)
                divider
                useRow("eye.slash", Copy.useWindowTitle, Copy.useWindowNote,
                       amount: "\(PopopxCommerceLimits.extendedSecureWindowCost)")
                divider
                // 逐条画分隔线而不是"每条前面都加一条"：新增一档外观时这里不会多出一条悬空的分隔线。
                ForEach(Array(PopopxCosmetic.allCases.enumerated()), id: \.element.id) { index, cosmetic in
                    if index > 0 { divider }
                    if credits.owns(cosmetic) {
                        useRow(cosmetic.symbol, cosmetic.displayName, Copy.owned, amount: "\(cosmetic.cost)")
                    } else {
                        // 只有没解锁的那一行才是按钮：已解锁那一档再按一次只会得到"你已经有了"，
                        // 而按下去只换来一句拒绝的按钮是这个 app 里最讨人嫌的一种东西。
                        Button { pendingCosmetic = cosmetic } label: {
                            useRow(cosmetic.symbol, cosmetic.displayName, cosmetic.effectNote,
                                   amount: "\(cosmetic.cost)")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text(verbatim: Copy.unlockHint(cosmetic)))
                    }
                }
            }
        }
    }

    private var divider: some View { Divider().overlay(PopopxPalette.separator) }

    /// 弹窗的开关只由 `pendingCosmetic` 派生。不留一个独立的 `showsUnlock` 布尔：
    /// 两处真值迟早分家，而分家之后的形状是"弹窗问着一档、按下去扣的是另一档"。
    private var unlockPrompt: Binding<Bool> {
        Binding(
            get: { pendingCosmetic != nil },
            set: { shown in if !shown { pendingCosmetic = nil } }
        )
    }

    /// 外观的扣点：只在用户点头之后发生，成与不成都留下一句话。
    ///
    /// 这一页是账本页，一句不留的花费等于让用户自己去翻流水确认那 150 点有没有记上。
    /// 解锁之后界面靠什么生效不在这里说：`owns(cosmetic)` 就是两处渲染读的那一个标志，
    /// 流水行 + 用途表那一行变成"已解锁"两件事已经把"生效了"表达完。
    private func purchase(_ cosmetic: PopopxCosmetic) {
        pendingCosmetic = nil
        do {
            try credits.purchase(cosmetic)
            PopopxHaptics.notice(.success)
            spendNote = Copy.unlockDone(cosmetic)
        } catch {
            PopopxHaptics.notice(.error)
            // 点数不足那一句由 `PopopxBadgeCreditsError.errorDescription` 给（句子里带着差额），
            // 这里不再补一个余额：两句话各说一个数时，用户不知道该信哪一个。
            spendNote = Copy.unlockFailed(error.localizedDescription)
        }
    }

    /// 上一笔花费的结果。刻意不套 `reconcileNote` 那套红色：那一路说的是"账对不上"，
    /// 这一句说的是"记上了"，两种颜色共用一个版面会让人分不清哪一条才是要紧的。
    private func spendLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "checkmark.circle")
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.successInk)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func useRow(_ symbol: String, _ title: String, _ note: String, amount: String?) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: symbol)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.brand)
                .frame(width: PopopxMetrics.spaceXL)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.label)
                Text(verbatim: note)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            if let amount {
                Text(verbatim: amount)
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            } else {
                Text(verbatim: Copy.setByPeer)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelHint)
            }
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .accessibilityElement(children: .combine)
    }

    // MARK: 未领完的红包

    @ViewBuilder private var pendingCard: some View {
        let total = credits.pendingPacketTotal
        if total > 0 {
            PopopxSectionCard(Copy.pendingTitle, footnote: Copy.pendingFootnote) {
                HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                    Text(verbatim: Copy.pendingCount(credits.pendingPackets.filter { !$0.settled }.count))
                        .font(PopopxType.secondary)
                        .foregroundStyle(PopopxPalette.label)
                    Spacer()
                    Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, total))
                        .font(PopopxType.metric)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
                .padding(.vertical, PopopxMetrics.spaceXS)
            }
        }
    }

    // MARK: 流水

    private func ledgerRow(_ entry: PopopxCreditsEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: entry.note)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: PopopxMetrics.spaceXS) {
                    Text(verbatim: PopopxCommerceFormat.date(entry.timestampMs))
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.labelHint)
                    if let after = entry.balanceAfter {
                        Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, after))
                            .font(PopopxType.microTag)
                            .foregroundStyle(PopopxPalette.labelHint)
                    }
                }
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            Text(verbatim: signedAmount(entry))
                .font(PopopxType.metric)
                .foregroundStyle(entry.kind.isIncome ? PopopxPalette.successInk : PopopxPalette.label)
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .accessibilityElement(children: .combine)
    }

    /// 符号只有一个来源：`kind.sign`。`adjustment` 的符号由条目自己带，所以那一条走 `amount` 正负。
    /// 负号统一用 U+2212（排版用的减号），不用连字符：两行流水并排时两种"负号"宽度不同。
    private func signedAmount(_ entry: PopopxCreditsEntry) -> String {
        guard let sign = entry.kind.sign else {
            return entry.amount >= 0 ? "+\(entry.amount)" : "−\(abs(entry.amount))"
        }
        return "\(sign > 0 ? "+" : "−")\(abs(entry.amount))"
    }

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            PopopxButton(Copy.exchange, systemImage: "sparkles", role: .secondary) {
                showsExchange = true
            }
            PopopxButton(Copy.close, role: .ghost) { dismiss() }
        }
    }
}

// MARK: - 外观行的符号与效果句

/// 名字与价格都取自 `PopopxCosmetic` 自己；这里只补"页面上怎么画它"这一层，
/// 因为那是本视图的呈现细节，不该写进值类型。
private extension PopopxCosmetic {
    var symbol: String {
        switch self {
        case .auroraShieldAvatarFrame: "theatermasks"
        case .darkGoldQRCardSkin: "qr"
        }
    }

    var effectNote: String {
        switch self {
        case .auroraShieldAvatarFrame: "本机头像渲染生效，不上传。"
        case .darkGoldQRCardSkin: "本机二维码卡面配色，不上传。"
        }
    }
}

// MARK: - 文案

private extension PopopxCreditsStoreView {
    enum Copy {
        static let title = PopopxCommerceCopy.creditsName
        static func updated(_ date: String) -> String { "更新于 \(date)" }
        static let reconcileBody = "这台设备上的流水与余额对不上。余额仍然按流水求和给出，但先不要大额兑换：等一次对账完成后再看。"
        static let usesTitle = "算力点能花在哪"
        static let usesFootnote = "价格全部取自代码里已有的那一处，这一页不另写一份。频道与资料卡的门槛由对方设定，所以这里不写数字。"
        static let setByPeer = "由对方设定"
        static let useBadgeTitle = "点亮徽章"
        static let useBadgeNote = "30 天 / 365 天两档，与已有剩余时间取更晚到期。"
        static let useVoucherTitle = "兑换礼品卡券"
        static let useVoucherNote = "同一价格换算成一张可送出的券，可一次换多张。"
        static let usePacketTitle = "发算力点红包"
        static let usePacketNote = "只有固定面额，均分给领取的人；未领完的部分自动退回。"
        static let useChannelTitle = "订阅频道"
        static let useChannelNote = "每个频道自己定价，价格由频道主设定。"
        static let useProfileTitle = "解锁加密资料卡"
        static let useProfileNote = "门槛由号主在资料卡上设定，解锁后本机留收据。"
        static let useWindowTitle = "绝密消息延长防窥窗口"
        static let useWindowNote = "把默认查看窗口延长 1 小时，只影响本机渲染。"
        static let owned = "已解锁 · 本机生效"
        static let unlockTitle = "解锁这一档外观"
        static func unlockConfirm(_ cosmetic: PopopxCosmetic) -> String { "花费 \(cosmetic.cost) 点" }
        static let unlockCancel = "取消"
        /// 价、余额、效果三句在同一行里说完，因为这是点下"花费"之前唯一一次说明机会。
        /// `effectNote` 取自下面那个私有扩展（"本机生效，不上传"），与列表里那句是同一句。
        static func unlockMessage(cosmetic: PopopxCosmetic, balance: Int) -> String {
            "\(cosmetic.displayName)：\(cosmetic.effectNote) 当前余额 \(balance) 点，解锁一次性扣 \(cosmetic.cost) 点，不退。"
        }
        static func unlockHint(_ cosmetic: PopopxCosmetic) -> String { "解锁这一档外观，\(cosmetic.cost) 算力点" }
        static func unlockDone(_ cosmetic: PopopxCosmetic) -> String { "已解锁\(cosmetic.displayName)，本机生效。" }
        static func unlockFailed(_ reason: String) -> String { "没有解锁：\(reason)" }
        static let ledgerTitle = "流水"
        static let ledgerFootnote = "最近 240 条；更早的记录会被丢弃，余额本身不丢。"
        static let ledgerEmpty = "还没有任何一笔。"
        static let pendingTitle = "没领完的红包"
        static let pendingFootnote = "这部分点数仍记在你名下；过期未领的部分自动退回余额。"
        static func pendingCount(_ n: Int) -> String { "\(n) 个红包" }
        static let exchange = "用算力点点亮徽章"
        static let close = "关闭"
    }
}

// MARK: - Previews

struct PopopxCreditsStoreDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxCreditsStoreView()
            .preferredColorScheme(.dark)
    }
}

struct PopopxCreditsStoreLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxCreditsStoreView()
            .preferredColorScheme(.light)
    }
}
