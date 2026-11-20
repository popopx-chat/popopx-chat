//  PopopxBadgePaywallView.swift
//
//  【第五阶段 · 4】付费墙：徽章的两条付款路径 + 礼品徽章券。这一页只卖徽章。
//
//  ### 这一页只有一种商品（真机第 8 轮 · 任务三）
//  算力点现金包（100 / 500 / 2000）整组搬到了「POPOPX 算力点」那一页
//  （`PopopxCreditsStoreView`，档位表现在是 `PopopxCreditPlan`）。搬走之前这一屏同时摆着
//  "订阅/通行证"（会再来扣钱或给一段时长）与"充值包"（换成可花的点数）两种互相冲突的商品，
//  用户在同一个列表里读到它们就会买错东西——那是商业化的 P0 事故，不是审美问题。
//  这一页只留一条与算力点有关的通路：**用已有算力点兑换徽章**（footer 那枚
//  `paywallUseCredits` → `PopopxBadgeCreditExchangeSheet`）。它是花掉已有余额的出口，
//  不是收钱的入口，所以永远摆在次要操作那一格；另有一枚 `creditsName` 按钮只是把用户送到
//  算力点那一页去充值，本页面上一张充值价目表都不画。
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
//     挂在档位脚注上，不塞进 CTA 下面当装饰。一次性时长档在**同一格**给
//     `PopopxCommerceCopy.oneTimePurchaseStatement`（一次付清、永不自动续费）：这两条付款路径的
//     续费事实相反，各说各的才不会被读成同一件事，所以「POPOPX 徽章」那一分段也按这两条各成一组。
//  2. **零赠送**：`PopopxCommerceCopy.noGiftBackStatement` 现在常驻**算力点那一页**的充值卡脚注
//     （见 `PopopxCreditsStoreView`），这一页已经没有充值档可挂；全页没有任何"加赠 X 算力点"的字样
//     （提示词的"纯净充值"红线）。
//  3. **虚拟币不跨平台**：算力点只能在本 app 内消耗，不提供任何形式的外部转移
//     （礼品卡是徽章券，不是算力点转账；红包是算力点，但只在双方会话内等额均分）。
//
//  ### 恢复购买的语义
//  `AppStore.sync()` 让 Apple 弹它自己的确认，本层只统计"这次实际恢复到了什么"
//  （`PopopxRestoreOutcome`：`restored(Int)` / `nothingToRestore` / `cancelled`）。
//  数字用 `%lld`（`String(format:)`），不写 `%d`： NSInteger/Int 的宽度在 32 位设备上会变。
//
//  ### 「用算力点兑换徽章」为什么留在这页
//  它是唯一一条"不经过 Apple"的徽章获取路径（资金来源是此前已经付费兑换过的点数），
//  因此必须走 `PopopxBadgeManager.activate(withCredits:)` 那唯一一处写 `.badgeRecord` 的入口，
//  并且和它一起被门禁覆盖。它放在**次要操作**那一格：它是"花掉已有余额"的出口，
//  不是"新的收入"的入口，摆成主 CTA 会误导用户以为算力点可以凭空获得。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI
import POPOPXChat

// MARK: - 版面模型

/// 付费墙的一个档位。刻意不带价格字段：价格属于运行时，档位属于设计。
///
/// 这里没有 `.credits` 那一族了（真机第 8 轮 · 任务三）：徽章页的版面模型如果还能装下一个
/// 充值包，"这一页只卖徽章"就只是一句注释而不是一个类型约束。删掉 case 之后，
/// 任何想把价目表搬回来的写法都会在 `switch` 上编译不过去。
struct PopopxPaywallSection: Identifiable, Hashable {
    enum Kind: Hashable {
        case subscription(PopopxNodeBadgePeriod)
        /// 一次性时长包：付一次给 `period.days` 天，**永不自动续费**。
        /// 与 `.subscription` 分开成两个 case（而不是订阅上加个 bool），是因为这两族的
        /// 续费文案、恢复语义、落账路径都不一样——用类型区分才会在漏写那一支时编译报错。
        case oneTimePass(PopopxNodeBadgePeriod)
        case giftCard(PopopxNodeBadgePeriod)
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
        case let .oneTimePass(period): period
        case let .giftCard(period): period
        }
    }

    /// 按钮动词按档位分：订阅是"点亮"，通行证是"买一次时长"，礼品是"买一张券"。
    /// 三个动作对用户来说是三件不同的事，共用一个"立即购买"会把"给他人买"读成"给自己买"。
    /// 通行证那一格走本地化 key：它是一条**新的付款路径**，不能借用上面任何一句中文常量
    /// （那三处是这一页既有文案，收口到 key 需要一并动 16 本目录，超出本轮范围）。
    var actionTitle: String {
        switch kind {
        case .subscription: "点亮"
        case .oneTimePass: PopopxCommerceCopy.passActionTitle
        case .giftCard: "购买礼品券"
        }
    }
}

/// 付费墙的**档位组**：一个组标题 + 它下面那几张卡。
///
/// 徽章那一分段分成两组，是因为那一屏同时摆着两条付款路径，而它们的续费事实**相反**：
/// 订阅到点自动扣下一次，通行证付一次就结束。混在一张无标题的列表里，用户很容易把
/// "按年点亮"和"365 天通行证"读成同一件事的两种写法，等到账单上出现第二次扣款才发现不是。
/// 组标题只说这一件需要说清的事，卡面上的脚注（`renewalStatement` /
/// `oneTimePurchaseStatement`）仍在各自卡内重复一次——标题管"分组"，脚注管"这一张卡"。
struct PopopxPaywallGroup: Identifiable {
    let id: String
    /// `nil` = 这一组不需要标题（礼品 tab 整组同一族，加标题反而是噪音）。
    let title: String?
    let sections: [PopopxPaywallSection]
}

/// 那张固定的表。
enum PopopxPaywallPlan {
    /// 分组视图的唯一来源。`sections(tab:)` 是它的摊平版本，留给"只关心有哪些档位"的读法。
    static func groups(tab: PopopxPaywallTab) -> [PopopxPaywallGroup] {
        switch tab {
        case .badge:
            [
                // 第一组：会到点自动扣钱的那两档。
                PopopxPaywallGroup(id: "recurring",
                                   title: PopopxCommerceCopy.paywallAutoRenewGroupTitle,
                                   sections: [
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
                                   ]),
                // 第二组：付一次结束的那两档。标题与上一组相反，卡面脚注也相反（见 `tierCard`）。
                // 时长与订阅组同周期（30/365 天），价格也是同一档 $6.99 / $49.99 ——
                // 两条路径的差别只在"会不会自动续费"，不在能拿到什么。
                PopopxPaywallGroup(id: "oneTime",
                                   title: PopopxCommerceCopy.paywallOneTimeGroupTitle,
                                   sections: [
                                       passSection(.monthly, .pass30Days),
                                       passSection(.annual, .pass365Days)
                                   ])
            ]
        case .giftCard:
            [
                PopopxPaywallGroup(id: "gift", title: nil, sections: [
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
                ])
            ]
        }
    }

    /// 通行证档位卡：标题由本地化格式串生成（"30-day pass" / "365-day pass"），
    /// 天数只有 `PopopxNodeBadgePeriod` 那一处来源，行上写的与真正发放的不可能分叉。
    private static func passSection(_ period: PopopxNodeBadgePeriod, _ sku: PopopxNodeBadgeSku) -> PopopxPaywallSection {
        PopopxPaywallSection(kind: .oneTimePass(period),
                             title: String(format: PopopxCommerceCopy.passTierTitleFormat, period.days),
                             note: nil,
                             badge: nil,
                             sku: sku)
    }

    static func sections(tab: PopopxPaywallTab) -> [PopopxPaywallSection] {
        groups(tab: tab).flatMap(\.sections)
    }

    // 算力点现金包那张表原来就在 `PopopxPaywallPlan` 里（`creditPacks` / `creditsPack(_:_:)`）。
    // 真机第 8 轮 · 任务三把它整组搬到算力点那一页，现在它的家是 `PopopxCreditPlan`
    // （`PopopxBadgeCreditsModels.swift`）：徽章页的模型里再留一份充值档位，
    // 就是下一次"两种商品混在同一屏"的起点。
}

/// 付费墙的两个分段。名字跟着商品走，不跟着"给谁"走：
/// `.badge` 是给自己这台设备买徽章，`.giftCard` 是买一张送给别人的券。
/// 原来那一个 case 叫 `myself`、标题是 "For myself"（「为自己」），在屏幕上既不说明卖什么、
/// 也不说明买到之后归谁——真机第 8 轮 · 任务三把它连同充值档一起收掉了。
enum PopopxPaywallTab: String, CaseIterable, Hashable {
    case badge
    case giftCard

    var label: String {
        switch self {
        case .badge: PopopxCommerceCopy.paywallBadgeTab
        case .giftCard: PopopxCommerceCopy.paywallGiftTab
        }
    }
}

// MARK: - 面板

struct PopopxBadgePaywallView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var store = PopopxStoreKitManager.shared
    /// 通行证落账要用它（`activate` 是"唯一一处写 `.badgeRecord`"的那个入口），
    /// 同时它也让这一页在点亮之后立刻读到新的 phase —— `@Observable` 的读侧就是这一页自己。
    @State private var badge = PopopxBadgeManager.shared
    @State private var toast = PopopxToastModel()

    @State private var tab: PopopxPaywallTab = .badge
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

                ForEach(PopopxPaywallPlan.groups(tab: tab)) { group in
                    if let title = group.title {
                        groupHeader(title)
                    }
                    ForEach(group.sections) { section in
                        tierCard(section)
                    }
                }

                benefitStrip
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    // MARK: 档位卡

    /// 组标题。刻意**不**进 `PopopxSectionCard`：那是给"浅色卡里几行"用的，
    /// 把两张品牌色档卡塞进一张浅色卡会再套一层圆角，读起来像设置页而不是价目表。
    /// 这里只做一件事——把"会不会自动续费"这一族区别提到卡片之上，让扫视顺序先遇到它。
    private func groupHeader(_ title: String) -> some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Text(verbatim: title)
                .font(PopopxType.emphasis)
                .foregroundStyle(PopopxPalette.label)
            Spacer(minLength: PopopxMetrics.spaceS)
        }
        .padding(.top, PopopxMetrics.spaceXS)
        .accessibilityAddTraits(.isHeader)
    }

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

            if let statement = renewalStatement(for: section) {
                Text(verbatim: statement)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.onBrand.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.brand, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
    }

    /// 卡面那一格"这一档到底会不会再来扣钱"。两句话占**同一个位置**、用同一套排版，
    /// 于是两条付款路径并排扫视时，唯一的差别就是这句话本身——这是 3.1.2(c) 要的形态。
    /// 按 `kind` 穷尽而不是问 `sku.isSubscription`：将来再加一族时，编译器会逼着这里表态。
    private func renewalStatement(for section: PopopxPaywallSection) -> String? {
        switch section.kind {
        case .subscription: PopopxCommerceCopy.renewalStatement
        case .oneTimePass: PopopxCommerceCopy.oneTimePurchaseStatement
        case .giftCard: nil
        }
    }

    /// 折扣徽章。年档那一句"省 X%"是**按两份实时标价算出来的**，不是写死的数字：
    /// 一旦调价，写死的 "33%" 立刻变成一句假话（当前配置 6.99×12 对 49.99 实际是 40%），
    /// 而"省多少"是审核与广告 both 会核对的陈述。价格还没读到时宁可不显示徽章 —— 宁缺毋假。
    /// 订阅年档与**通行证年档**走同一条算法（见 `percentSaved`）：两族都是"一次覆盖一整年 vs
    /// 按月买十二次"的对比，基准一样，所以徽章口径也必须一样。
    private func savingBadge(for section: PopopxPaywallSection) -> String? {
        switch section.kind {
        case .subscription(.annual):
            percentSaved(monthly: .subscriptionMonthly, annual: .subscriptionAnnual)
        case .oneTimePass(.annual):
            percentSaved(monthly: .pass30Days, annual: .pass365Days)
        default:
            section.badge
        }
    }

    /// 「按月买 12 次」对「一次买一年」省下的百分比文案。`months` 固定取 12：
    /// 两个 SKU 的周期都是 30 天与 365 天，而 30×12=360 天略少于 365 天，
    /// 因此这句话是**保守**的（把多出来的 5 天算进"省"里，是这一类对比的通行口径，不是夸大）。
    private func percentSaved(monthly monthlySku: PopopxNodeBadgeSku, annual annualSku: PopopxNodeBadgeSku) -> String? {
        guard let monthly = store.product(for: monthlySku)?.price,
              let annual = store.product(for: annualSku)?.price,
              monthly > 0 else { return nil }
        let fullPrice = monthly * 12
        let saved = fullPrice - annual
        guard saved > 0 else { return nil }
        let percent = NSDecimalNumber(decimal: saved / fullPrice).doubleValue * 100
        guard percent >= 1 else { return nil }
        return String(format: PopopxCommerceCopy.savePercentFormat, Int(percent.rounded()))
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

    // MARK: 商店未就绪

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
                // 这一枚是本页通往「POPOPX 算力点」那一页的唯一入口，所以用商品全名而不是裸的
                // "算力点"三个字：名字与那一页的标题逐字相同，用户才知道点下去会落到哪一屏。
                // 现金价目表本身不在这一页（真机第 8 轮 · 任务三）。
                Button(PopopxCommerceCopy.creditsName) { showsWallet = true }
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
        case let .success(.purchased(receipt)):
            // 一次性时长包**必须在这一笔的返回路径上当场点亮**。判据是这一族的交付路径本身：
            // 管理器的两条落账腿都不接它（`PopopxBadgeManager.apply(storeReceipt:)` 按
            // `isSubscription` 过滤，`PopopxCreditsManager.apply(storeReceipt:)` 对 `.oneTimePass`
            // 直接 return），恢复流程也把它排除在重投之外（Apple 对非续订订阅不承诺"恢复"语义，
            // 按时长重投一次就是白送一段时长）。也就是说：这笔钱付完之后，除了这里没有第二处会点亮它。
            // 等一个不存在的回调 = 用户白付一次钱，那是这个模块复盘过三次的原罪。
            // 点亮仍只走唯一入口 `PopopxBadgeManager.activate`；这里只负责算到期时刻（见 `grantPass`）。
            if let period = sku.oneTimePassPeriod, await grantPass(period, receipt: receipt) == false {
                return
            }
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

    /// 时长包落账。**唯一写 `.badgeRecord` 的入口仍然是 `PopopxBadgeManager.activate`**，
    /// 这一层只负责取到期时刻：`badge.stackedExpiryMs(period:)` = `max(now, 本机当前到期) + period.days`。
    /// 取 `max(now, 当前到期)` 而不是 `now` 起步，是为了让通行证永远**叠加**在剩余时间之上——
    /// 徽章还剩 200 天时买 30 天通行证，到期是 230 天后，不是 30 天后。
    /// 这个算式在工程里只有一份：通行证、算力点兑换、礼品券三条腿都调它
    /// （`PopopxBadgeManager.stackedExpiryMs`），界面上"再加 N 天"和落账用的是同一个数。
    /// （`activate` 内部那一句 `max(传入, 现有)` 的合并语义一个字都不动；这里传的是已经算好的时刻，
    /// 两道 max 叠在一起只会得到同一个结果，不会重复计时。）
    /// 顺序是本模块对"钱付了但什么都没发生"唯一的防线：**先点亮，后 `finish`**。
    /// 点亮失败就不 finish，那笔交易留在 Apple 侧，用户下次还能再拿到它。
    private func grantPass(_ period: PopopxNodeBadgePeriod, receipt: PopopxStoreReceipt) async -> Bool {
        do {
            try badge.activate(period: period, source: .storePass,
                               expiresAtMs: badge.stackedExpiryMs(period: period),
                               receiptDigest: receipt.digest)
        } catch {
            // 把真话原样说出去（Keychain 写不进去、时钟被拨到过去，是两句不同的话）。
            // `catch` 绑定的是 `any Error`，`errorDescription` 只能经 `LocalizedError` 取到；
            // 上面 `case let .failure(error)` 那两处不用绕，是因为 Result 的失败类型已经是具体的。
            PopopxHaptics.notice(.error)
            toast.show((error as? LocalizedError)?.errorDescription ?? Copy.genericFailure, kind: .danger)
            return false
        }
        await store.finish(receipt)
        return true
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
        static let benefitsTitle = "点亮之后"
        static let benefitBadge = "顶栏点亮这枚专属徽章：它只在徽章有效期内出现，到期自动收回。"
        static let benefitStatusPanel = "徽章详情是本机的节点状态面板：档位、到期、对账摘要、本机计数，只读、不上传。"
        static let benefitCards = "徽章可以做成二维码礼品卡点对点转赠；算力点红包发给好友，对方在本机拆开。"
        static let benefitNoRead = "中继节点只搬运密文：它看不到会话内容，也拿不到联系人列表。"
        static let benefitNoAccount = "没有账号、没有中心账本：徽章、券、算力点全部存在这台设备的 Keychain 里。"
        // 原来这里还有 `wallet = "算力点"` 与 `creditsTitle = creditsName` 两条，服务于充值卡；
        // 充值整组搬走之后它们没有读者了（`Copy` 里留一句没人读的中文常量就是下一轮漏翻的来源）。
        static let storeUnavailable = "商店暂时读不到：卡片照旧显示为标价，恢复网络后可以购买。"
        static let pending = "等待 Apple 确认这笔购买，完成后徽章会自动点亮。"
        static let genericFailure = "这次没有完成。"
        static func purchased(_ sku: PopopxNodeBadgeSku) -> String {
            switch sku.kind {
            case let .subscription(period):
                "已购买 · 徽章点亮 \(period.days) 天"
            case let .oneTimePass(period):
                // 通行证到账那一句走本地化 key（新句子，不进上面那组中文常量）。
                String(format: PopopxCommerceCopy.passGrantedFormat, period.days)
            case let .giftCard(period):
                "礼品券已生成 · \(period.days) 天"
            case let .credits(amount):
                // 这一页已经没有充值档，所以这一支在当前版面下走不到；留着是因为 `switch`
                // 必须对 `PopopxNodeBadgeSkuKind` 穷尽——真到账的那一句在算力点那一页
                // （`PopopxCreditsStoreView.topUpCard`），它读的是本地化 key，不是这里。
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
