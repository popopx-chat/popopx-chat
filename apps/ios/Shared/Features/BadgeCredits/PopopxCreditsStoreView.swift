//  PopopxCreditsStoreView.swift
//
//  【第六阶段 · 1】算力点中心：余额、现金包充值、用途表、流水。
//
//  ### 这一页只有一种商品：POPOPX 算力点本身（真机第 8 轮 · 任务三）
//  屏上是四件事——**余额**、**100 / 500 / 2000 三档现金包**、**点数能花在哪**、**流水**。
//  徽章订阅、一次性通行证、礼品徽章券都不在这一页（它们归 `PopopxBadgePaywallView`，
//  那一页反过来也不再画任何充值价目表）。在此之前两屏各自同时摆着"会员"和"点数"两种商品，
//  用户在同一个列表里读就会买错：那是商业化的 P0，不是排版偏好。
//  这一页保留的唯一"与徽章有关"的东西是**花已有余额**的那条路（用途表第一行与 footer 那枚
//  `用算力点点亮徽章`，都开 `PopopxBadgeCreditExchangeSheet`）：它是这一页那一族消费场景的
//  出口，不是一张卖徽章的卡片——它不收钱，只花用户已经付过一次的点数。
//
//  ### 为什么充值挂在这一页而不是上一级
//  它有两张进来的门：「我的 · 算力点钱包」那一行，以及付费墙 footer 的 `creditsName` 按钮。
//  搬过来之前"这里一分钱都不收"的理由是"从付费墙进来会在下一层再画一张同价目表，两层注释
//  一旦改写就分叉"。现在现金包只在这一页出现，那一张同价目表的上一层根本不存在了，
//  分叉的可能性也随之消失——所以点数购买直接落在这里，用户在一个屏里看到余额和价目表，
//  买完立刻在同一屏看到余额变多，这条动线上没有第二张价目表可走错。
//  落账走 `PopopxCreditsManager.apply(storeReceipt:)`：那是后台交付流用的**同一个**入口，
//  面额、流水行、防重放（`entryId = receipt.digest`）与"先写账本、后 `finish`"的顺序全在那一处，
//  这一页不另写一套加钱逻辑。
//  无条件打徽章付费墙的那条路仍归「我的」那一行（`PopopxMeView` 的 `badgeSheet = .paywall`）。
//  ⚠️ 同一页那一行 `purchaseCredits`（"Top up Compute Credits"「充值算力点」）现在仍然指向
//  `.paywall`，而付费墙已经不卖现金包了——它应该改成开这一页（`showsCreditsStore`）。
//  `PopopxMeView.swift` 与 `PopopxBadgeCreditExchangeSheet.swift`（"去充值"同一处毛病）
//  都不在本轮的文件所有权里，留给持有者收口；本轮先保证**页面内部**不再有第二种商品。
//
//  ### 余额与流水必须各自承认自己的不可靠
//  `PopopxCreditsWallet.needsReconcile` 由 `verifyLedgerConsistency()` 在余额与流水求和不一致时置真
//  （流水上限 240 条，所以老账被丢弃不算不一致，见那里的注释）。这一页把这个状态显示出来，
//  而不是显示一个"看起来正常"的数字：把不可信的余额静默花掉是更坏的结局。
//
//  ### 用途表与充值表的数字全部取自代码里已有的那一份
//  现金包的面额来自 `PopopxCreditPlan`（它由 `PopopxNodeBadgeSku.creditedAmount` 派生，
//  也就是真正入账的那一个数）；600/4500 来自 `PopopxNodeBadgePeriod.creditsCost`，20 来自
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
    /// 现金包的价格与商品表。`@Observable` 的读侧就是这一页：拉到价格之前那一行显示
    /// SKU 自带的 `fallbackPriceText`（App Store Connect 里的 face value），按钮同时禁用，
    /// 于是"整页空白"和"按下去什么都没发生"两种失败都到不了用户手上（口径同付费墙）。
    @State private var store = PopopxStoreKitManager.shared
    @State private var showsExchange = false
    /// 正在走 StoreKit 的那一枚现金包。同一时刻只允许一笔，否则两笔的到账顺序无法向用户解释。
    @State private var busySkuId: String?
    /// 待确认的那一档外观。弹窗的可见性由它派生（下面那个 Binding），所以不存在
    /// "弹窗还开着但已经没人被确认"的中间帧——和资料卡解锁那一处同一个形状。
    @State private var pendingCosmetic: PopopxCosmetic?
    /// 上一次点数动作（充值或解锁外观）的结果，一句为止。它不叫"提示"也不自动消失：这一页是账本页，
    /// 用户需要看见"刚刚那 150 点确实记上了"、"刚买的那 500 点确实到了"，而一句会自己没掉的话等于没说。
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
        .task {
            credits.loadIfNeeded()
            await store.loadProducts()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                balanceCard

                if credits.wallet.needsReconcile {
                    reconcileNote
                }

                topUpCard

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

    // MARK: 充值（算力点现金包）

    /// 三档现金包：100 / 500 / 2000。这一张卡是这一页唯一收钱的地方，而它卖的东西只有一种——
    /// 算力点本身。档位表是 `PopopxCreditPlan`（面额由 SKU 的 `creditedAmount` 派生），
    /// 价格由 StoreKit 给，所以"行上写的面额"与"真正入账的面额"之间没有第三处可以各说各话。
    /// 脚注那句"绝不加赠"（`noGiftBackStatement`）原来常驻付费墙的充值档，整组搬过来之后它跟着搬。
    private var topUpCard: some View {
        PopopxSectionCard(PopopxCommerceCopy.creditsTopUpTitle,
                          footnote: PopopxCommerceCopy.noGiftBackStatement) {
            VStack(spacing: 0) {
                if !store.isStoreReady {
                    // 商店读不到：档位照画（面额是本模块的事实），价格位显示 SKU 自带的标价，
                    // 按钮禁用。这一句复用 `PopopxCommerceCopy.errorStoreUnavailable`——
                    // 16 本目录里已经有译文，不再新开一条源文。
                    Text(PopopxCommerceCopy.errorStoreUnavailable)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .padding(.bottom, PopopxMetrics.spaceXS)
                }
                ForEach(Array(PopopxCreditPlan.packs.enumerated()), id: \.element.id) { index, pack in
                    if index > 0 { divider }
                    packRow(pack)
                }
            }
        }
    }

    private func packRow(_ pack: PopopxCreditPack) -> some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Text(verbatim: pack.title)
                .font(PopopxType.emphasis)
                .foregroundStyle(PopopxPalette.label)
            Spacer(minLength: PopopxMetrics.spaceS)
            Button {
                Task { await buy(pack) }
            } label: {
                HStack(spacing: PopopxMetrics.space2XS) {
                    if busySkuId == pack.sku.productId {
                        ProgressView()
                    } else {
                        Text(verbatim: store.priceText(for: pack.sku, periodSuffix: false))
                        Image(systemName: "chevron.right")
                    }
                }
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.brand)
                .frame(minHeight: PopopxMetrics.minHitTarget)
            }
            .disabled(!store.isStoreReady || busySkuId != nil)
            .opacity(store.isStoreReady ? 1 : 0.5)
            .accessibilityLabel(Text(verbatim: pack.title))
            .accessibilityValue(Text(verbatim: store.priceText(for: pack.sku, periodSuffix: false)))
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
    }

    /// 买一档现金包。**加钱不在这页写**：拿到收据后交给 `PopopxCreditsManager.apply(storeReceipt:)`——
    /// 那是 StoreKit 后台交付流用的**同一个**入口，面额、流水行、防重放（`entryId = receipt.digest`）
    /// 以及"先写账本、后 `finish`"的顺序全在那一处，这一页再写一套就是一个会和重投分叉的第二真相源。
    /// 为什么前台这一笔要在这里直接调它：`PopopxStoreKitManager.purchase(_:)` 已经把交易 id 记进
    /// "本次已结算"集合，随后 `Transaction.updates` 那一次投递会被去重挡掉——不在这里落账，
    /// 用户看到的就是"钱付了、余额没动、什么都没有"，而下一层没有第二个人会来补。
    private func buy(_ pack: PopopxCreditPack) async {
        guard busySkuId == nil else { return }
        busySkuId = pack.sku.productId
        defer { busySkuId = nil }
        let before = credits.balance
        switch await store.purchase(pack.sku) {
        case let .success(.purchased(receipt)):
            await credits.apply(storeReceipt: receipt)
            if credits.balance != before {
                PopopxHaptics.notice(.success)
                spendNote = String(format: PopopxCommerceCopy.creditsTopUpGrantedFormat, pack.amount)
            } else {
                // 付款成了、本机没写进去（Keychain 写失败，或余额已经顶到上限被挡下）。
                // 这句话必须说出来而不是静默：交易没被 finish，下一次重投会把点数补上。
                PopopxHaptics.notice(.error)
                spendNote = PopopxCommerceCopy.creditsTopUpNotCredited
            }
        case .success(.pending):
            // Ask to Buy / 家庭批准：钱还没扣。说"已到账"是假话，说"失败"也是假话。
            spendNote = PopopxCommerceCopy.creditsTopUpPending
        case .success(.cancelled):
            // 取消不是错误：不震动、不标红，也不留一句"失败"在账本本页上。
            break
        case let .failure(error):
            PopopxHaptics.notice(.error)
            // 真话原样说出去（`PopopxBadgeCreditsError` 那一句本来就已经是本地化的、带差额的）。
            spendNote = error.errorDescription ?? PopopxCommerceCopy.errorStoreUnavailable
        }
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
