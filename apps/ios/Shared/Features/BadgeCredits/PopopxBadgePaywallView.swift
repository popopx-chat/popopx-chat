//  PopopxBadgePaywallView.swift
//
//  【第五阶段 · 4】付费墙：订阅、礼品徽章、算力点充值，三条腿各自诚实。
//
//  ### 页面骨架是这个模块的财产，不是 StoreKit 的附属品
//  提示词指定的结构是"标题 + 副标题 + 分段卡片 + 利益点 + 价格行 + CTA + 次要操作"，
//  并且明令禁止 `if storeKitManager.products.isEmpty { ForEach(…) }` 这种"拿商品数组当页面骨架"的写法。
//  所以这里先把版面写成 `PopopxPaywallPlan.sections(tab:)` 那张固定的表（档位、顺序、标题、注释
//  全部由代码决定），StoreKit 只回答一个价格字符串；`PopopxNodeBadgeSku.allCases` 在本文件里
//  一次都没有出现。
//  商店还没准备好（离线、StoreKit 故障、首次加载在途）时，卡片照画、按钮照禁用，
//  价格位显示各 SKU 自带的 `fallbackPriceText` —— 那是**已知的标价**，不是猜的：
//  它等于 App Store Connect 里配置的 face value，一旦取到真价格就被 `displayPrice` 顶掉。
//  这样就不会出现"整页空白"或"按钮能点但什么都没发生"两种常见失败。
//
//  ### 三件必须说清的事，一件都不许含糊
//  1. **自动续费**：`PopopxCommerceCopy.renewalStatement`（3.1.2(c) 全文口径）只在订阅档出现，
//     挂在档位脚注上，不塞进 CTA 下面当装饰。
//  2. **零赠送**：`PopopxCommerceCopy.noGiftBackStatement` 常驻充值档脚注；
//     全页没有任何"加赠 X 算力点"的字样（提示词的"纯净充值"红线）。
//  3. **虚拟币不跨平台**：算力点只能在本 app 内消耗，不提供任何形式的外部转移
//     （礼品卡是徽章券，不是算力点转账；红包是算力点，但只在双方会话内等额均分）。
//
//  ### 恢复购买的语义
//  `AppStore.sync()` 让 Apple 弹它自己的确认，本层只统计"这次实际恢复到了什么"
//  （`PopopxRestoreOutcome`：`restored(Int)` / `nothingToRestore` / `cancelled`）。
//  数字用 `%lld`（`String(format:)`），不写 `%d`： NSInteger/Int 的宽度在 32 位设备上会变。
//
//  ### 用算力点兑换徽章那条腿
//  它是唯一一条"不经过 Apple"的获取路径（资金来源是此前已经付费兑换过的点数），
//  因此必须走 `PopopxBadgeManager.activate(withCredits:)` 那唯一一处写 `.badgeRecord` 的入口，
//  并且和它一起被门禁覆盖。本面板把它放在**次要操作**的位置：它是"花掉已有余额"的出口，
//  不是"新的收入"的入口，摆成主 CTA 会误导用户以为算力点可以凭空获得。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI
import POPOPXChat

// MARK: - 版面模型

/// 付费墙的一个档位。刻意不带价格字段：价格属于运行时，档位属于设计。
struct PopopxPaywallSection: Identifiable, Hashable {
    enum Kind: Hashable {
        case subscription(PopopxNodeBadgePeriod)
        case giftCard(PopopxNodeBadgePeriod)
        case credits(Int)
    }

    let kind: Kind
    let title: String
    let note: String?
    let badge: String?
    let sku: PopopxNodeBadgeSku

    var id: String { sku.productId }

    var period: PopopxNodeBadgePeriod? {
        switch kind {
        case let .subscription(period): period
        case let .giftCard(period): period
        case .credits: nil
        }
    }

    /// 按钮动词按档位分：订阅是"点亮"，礼品是"买一张券"，充值是"购买"。
    /// 三个动作对用户来说是三件不同的事，共用一个"立即购买"会把"给他人买"读成"给自己买"。
    var actionTitle: String {
        switch kind {
        case .subscription: "点亮"
        case .giftCard: "购买礼品券"
        case .credits: "购买"
        }
    }
}

/// 那张固定的表。
enum PopopxPaywallPlan {
    static func sections(tab: PopopxPaywallTab) -> [PopopxPaywallSection] {
        switch tab {
        case .myself:
            [
                PopopxPaywallSection(kind: .subscription(.monthly),
                                     title: "按月点亮",
                                     note: nil,
                                     badge: nil,
                                     sku: .subscriptionMonthly),
                PopopxPaywallSection(kind: .subscription(.annual),
                                     title: "按年点亮",
                                     note: "一年一档，中途到期前随时续",
                                     badge: nil,
                                     sku: .subscriptionAnnual)
            ]
        case .giftCard:
            [
                PopopxPaywallSection(kind: .giftCard(.monthly),
                                     title: "送 30 天徽章券",
                                     note: "生成一张券，对方凭码兑换；兑之前它可以一直留着。",
                                     badge: nil,
                                     sku: .giftMonthly),
                PopopxPaywallSection(kind: .giftCard(.annual),
                                     title: "送 365 天徽章券",
                                     note: "同一张券只能兑一次，兑换由对方设备本机确认。",
                                     badge: nil,
                                     sku: .giftAnnual)
            ]
        }
    }

    /// 充值档位永远排在订阅/礼品之后，跨 tab 不变 —— 它是"补充余额"，不是"选一种会员"。
    /// 面额只写一次（函数的实参），标题由本地化格式串生成：行上显示的那句话和 `Kind` 里那个数字
    /// 因此不可能各说各话。
    static let creditPacks: [PopopxPaywallSection] = [
        creditsPack(100, .credits100),
        creditsPack(500, .credits500),
        creditsPack(2_000, .credits2000)
    ]

    private static func creditsPack(_ amount: Int, _ sku: PopopxNodeBadgeSku) -> PopopxPaywallSection {
        PopopxPaywallSection(kind: .credits(amount),
                             title: String(format: PopopxCommerceCopy.creditsAmountFormat, amount),
                             note: nil,
                             badge: nil,
                             sku: sku)
    }
}

enum PopopxPaywallTab: String, CaseIterable, Hashable {
    case myself
    case giftCard

    var label: String {
        switch self {
        case .myself: PopopxCommerceCopy.paywallSelfTab
        case .giftCard: PopopxCommerceCopy.paywallGiftTab
        }
    }
}

// MARK: - 面板

struct PopopxBadgePaywallView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var store = PopopxStoreKitManager.shared
    @State private var toast = PopopxToastModel()

    @State private var tab: PopopxPaywallTab = .myself
    @State private var busySkuId: String?
    @State private var showsRedeem = false
    @State private var showsCreditExchange = false
    @State private var showsWallet = false
    /// 礼品档买完之后自动去的那一页，以及该页要预填的档位（用户不用重新选）。
    @State private var showsGiftQueue = false
    @State private var giftQueuePeriod: PopopxNodeBadgePeriod = .monthly
    @State private var isRestoring = false

    var body: some View {
        PopopxSheetContainer(PopopxCommerceCopy.paywallTitle,
                             subtitle: PopopxCommerceCopy.nodeClusterTerm) {
            content
        } footer: {
            footer
        }
        .popopxToast(toast)
        .sheet(isPresented: $showsRedeem) { PopopxVoucherRedeemSheet() }
        .sheet(isPresented: $showsCreditExchange) { PopopxBadgeCreditExchangeSheet() }
        .sheet(isPresented: $showsWallet) { PopopxCreditsStoreView() }
        .sheet(isPresented: $showsGiftQueue) { PopopxGiftBadgeCardSheet(period: giftQueuePeriod) }
        .task { await store.loadProducts() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                PopopxSegmentedControl(
                    PopopxPaywallTab.allCases.map { .init(selection: $0, title: $0.label) },
                    title: { $0.label },
                    selection: $tab
                )

                if !store.isStoreReady {
                    storeUnavailableNote
                }

                ForEach(PopopxPaywallPlan.sections(tab: tab)) { section in
                    tierCard(section)
                }

                benefitStrip

                creditsSection
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    // MARK: 档位卡

    private func tierCard(_ section: PopopxPaywallSection) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(verbatim: section.title)
                        .font(PopopxType.title)
                        .foregroundStyle(PopopxPalette.onBrand)
                    if let note = section.note {
                        Text(verbatim: note)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.onBrand.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: PopopxMetrics.spaceS)
                if let badge = savingBadge(for: section) {
                    Text(verbatim: badge)
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.onBrand)
                        .padding(.horizontal, PopopxMetrics.spaceXS)
                        .padding(.vertical, PopopxMetrics.space2XS)
                        .background(PopopxPalette.onBrand.opacity(0.18), in: .capsule)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                // 价格与"/月 · /年"后缀由 `priceText(for:periodSuffix:)` 一次给出：
                // `suffix(for:)` 是 PopopxStoreKitManager 的私有方法，本面板不复制它那套措辞。
                Text(verbatim: store.priceText(for: section.sku, periodSuffix: section.sku.isSubscription))
                    .font(PopopxType.display)
                    .foregroundStyle(PopopxPalette.onBrand)
                Spacer(minLength: PopopxMetrics.spaceS)
                Button {
                    Task { await buy(section.sku) }
                } label: {
                    Text(verbatim: busySkuId == section.sku.productId ? Copy.working : section.actionTitle)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.brand)
                        .padding(.horizontal, PopopxMetrics.spaceM)
                        .frame(height: PopopxMetrics.minHitTarget)
                        .background(PopopxPalette.card, in: .capsule)
                }
                .disabled(!store.isStoreReady || busySkuId != nil)
                .opacity(store.isStoreReady ? 1 : 0.5)
                .accessibilityLabel(Text(verbatim: "\(section.actionTitle) \(section.title)"))
            }

            if section.sku.isSubscription {
                Text(PopopxCommerceCopy.renewalStatement)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.onBrand.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.brand, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
    }

    /// 折扣徽章。年档那一句"省 X%"是**按两份实时标价算出来的**，不是写死的数字：
    /// 一旦调价，写死的 "33%" 立刻变成一句假话（当前配置 6.99×12 对 49.99 实际是 40%），
    /// 而"省多少"是审核与广告 both 会核对的陈述。价格还没读到时宁可不显示徽章 —— 宁缺毋假。
    private func savingBadge(for section: PopopxPaywallSection) -> String? {
        if case .subscription(.annual) = section.kind {
            guard let monthly = store.product(for: .subscriptionMonthly)?.price,
                  let annual = store.product(for: .subscriptionAnnual)?.price,
                  monthly > 0 else { return nil }
            let fullPrice = monthly * 12
            let saved = fullPrice - annual
            guard saved > 0 else { return nil }
            let percent = NSDecimalNumber(decimal: saved / fullPrice).doubleValue * 100
            guard percent >= 1 else { return nil }
            return String(format: PopopxCommerceCopy.savePercentFormat, Int(percent.rounded()))
        }
        return section.badge
    }

    /// 五条利益点，每条都对应一个本模块真做出来的东西：徽章胶囊（`PopopxBadgeCapsuleView`）、
    /// 节点状态面板（`PopopxBadgeDetailSheet`）、礼品卡与红包（`PopopxCommerceCards` / 路由器）。
    /// 措辞红线两条：不出现任何 VPN/代理词汇，也**不再出现任何未落地的收益**
    /// （"高并发优先调度""动态轮换 IP""1GB 专属大文件"三项在 2026-11-19 的产品裁定里撤下——
    /// 判据与残留风险见 `Docs/app-store-review-notes.md` 第 1 节那张表）。
    private var benefitStrip: some View {
        PopopxSectionCard(Copy.benefitsTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                benefit("seal.fill", Copy.benefitBadge)
                benefit("chart.bar.xaxis", Copy.benefitStatusPanel)
                benefit("qrcode", Copy.benefitCards)
                benefit("lock.shield", Copy.benefitNoRead)
                benefit("person.2.slash", Copy.benefitNoAccount)
            }
        }
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: symbol)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.brand)
                .frame(width: PopopxMetrics.spaceXL)
            Text(verbatim: text)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 充值

    private var creditsSection: some View {
        PopopxSectionCard(Copy.creditsTitle, footnote: PopopxCommerceCopy.noGiftBackStatement) {
            VStack(spacing: PopopxMetrics.spaceXS) {
                ForEach(PopopxPaywallPlan.creditPacks) { pack in
                    HStack(spacing: PopopxMetrics.spaceS) {
                        // 面额来自 `PopopxPaywallPlan` 的那张表，价格来自 StoreKit：
                        // 这一行没有第三处可以写数字的地方，所以"行上写的"与"实际到账的"不可能分叉。
                        Text(verbatim: pack.title)
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.label)
                        Spacer(minLength: PopopxMetrics.spaceS)
                        Button {
                            Task { await buy(pack.sku) }
                        } label: {
                            HStack(spacing: PopopxMetrics.space2XS) {
                                Text(verbatim: store.priceText(for: pack.sku, periodSuffix: false))
                                Image(systemName: "chevron.right")
                            }
                            .font(PopopxType.secondary)
                            .foregroundStyle(PopopxPalette.brand)
                            .frame(minHeight: PopopxMetrics.minHitTarget)
                        }
                        .disabled(!store.isStoreReady || busySkuId != nil)
                    }
                    .padding(.vertical, PopopxMetrics.spaceXS)
                    if pack.id != PopopxPaywallPlan.creditPacks.last?.id {
                        Divider().overlay(PopopxPalette.separator)
                    }
                }
            }
        }
    }

    private var storeUnavailableNote: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "wifi.slash").foregroundStyle(PopopxPalette.labelHint)
            Text(verbatim: Copy.storeUnavailable).font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
        .padding(PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.separator.opacity(0.5), in: .rect(cornerRadius: PopopxMetrics.radiusControl))
    }

    // MARK: 次要操作

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxButton(PopopxCommerceCopy.paywallRedeemEntry, systemImage: "qrcode.viewfinder",
                             role: .secondary, fullWidth: true) {
                    showsRedeem = true
                }
                PopopxButton(PopopxCommerceCopy.paywallUseCredits, systemImage: "sparkles",
                             role: .secondary, fullWidth: true) {
                    showsCreditExchange = true
                }
            }
            HStack(spacing: PopopxMetrics.spaceL) {
                Button(PopopxCommerceCopy.paywallRestore) {
                    Task { await restore() }
                }
                .disabled(isRestoring)
                Button(Copy.wallet) { showsWallet = true }
                Button(Copy.close) { dismiss() }
            }
            .font(PopopxType.caption)
            .foregroundStyle(PopopxPalette.brand)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: 动作

    private func buy(_ sku: PopopxNodeBadgeSku) async {
        guard busySkuId == nil else { return }
        busySkuId = sku.productId
        defer { busySkuId = nil }
        let result = await store.purchase(sku)
        switch result {
        case .success(.purchased):
            // 到账这件事由交付回调（`PopopxCreditsManager.apply(storeReceipt:)` 与
            // `PopopxBadgeManager.apply(storeReceipt:)`）负责，本面板只报告"这一笔付过了"。
            // 所以这里绝不写余额、绝不写 `.badgeRecord`：写了就会和回调那一份互相覆盖。
            PopopxHaptics.notice(.success)
            toast.show(Copy.purchased(sku), kind: .encrypted)
            if case let .giftCard(period) = sku.kind {
                // 礼品档：券在交付回调里铸好，这一页直接把用户送到能看见它的那一页。
                giftQueuePeriod = period
                showsGiftQueue = true
            }
        case .success(.pending):
            toast.show(Copy.pending, kind: .success)
        case .success(.cancelled):
            break
        case let .failure(error):
            // 取消不是错误，不震动、不标红；真失败才把 `PopopxBadgeCreditsError` 那句话原样说出去。
            toast.show(error.errorDescription ?? Copy.genericFailure, kind: .danger)
        }
    }

    private func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        switch await store.restorePurchases() {
        case let .success(outcome):
            // 计数只用来选语气：`restored(Int)` 走"恢复到了"那一份文案，
            // 零恢复与用户取消各说各的，不合成一句"完成"。
            if case .restored = outcome {
                toast.show(outcome.announcementText, kind: .encrypted)
            } else {
                toast.show(outcome.announcementText, kind: .success)
            }
        case let .failure(error):
            toast.show(error.errorDescription ?? Copy.genericFailure, kind: .danger)
        }
    }
}

private extension PopopxBadgePaywallView {
    enum Copy {
        static let working = "处理中…"
        static let close = "关闭"
        static let wallet = "算力点"
        static let benefitsTitle = "点亮之后"
        static let benefitBadge = "顶栏点亮这枚专属徽章：它只在徽章有效期内出现，到期自动收回。"
        static let benefitStatusPanel = "徽章详情是本机的节点状态面板：档位、到期、对账摘要、本机计数，只读、不上传。"
        static let benefitCards = "徽章可以做成二维码礼品卡点对点转赠；算力点红包发给好友，对方在本机拆开。"
        static let benefitNoRead = "中继节点只搬运密文：它看不到会话内容，也拿不到联系人列表。"
        static let benefitNoAccount = "没有账号、没有中心账本：徽章、券、算力点全部存在这台设备的 Keychain 里。"
        static let creditsTitle = PopopxCommerceCopy.creditsName
        static let storeUnavailable = "商店暂时读不到：卡片照旧显示为标价，恢复网络后可以购买。"
        static let pending = "等待 Apple 确认这笔购买，完成后徽章会自动点亮。"
        static let genericFailure = "这次没有完成。"
        static func purchased(_ sku: PopopxNodeBadgeSku) -> String {
            switch sku.kind {
            case let .subscription(period):
                "已购买 · 徽章点亮 \(period.days) 天"
            case let .giftCard(period):
                "礼品券已生成 · \(period.days) 天"
            case let .credits(amount):
                "已到账 \(amount) 算力点"
            }
        }
    }
}

// MARK: - Previews

struct PopopxBadgePaywallDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgePaywallView()
            .preferredColorScheme(.dark)
    }
}

struct PopopxBadgePaywallLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgePaywallView()
            .preferredColorScheme(.light)
    }
}
