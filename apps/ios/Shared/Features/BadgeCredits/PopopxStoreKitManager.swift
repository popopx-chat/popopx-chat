//  PopopxStoreKitManager.swift
//
//  StoreKit 2 引擎：9 个 SKU 的加载、购买、后台续费监听、权益核对与恢复购买。
//
//  与 `Shared/Views/Badges/BadgeStore.swift`（SimpleX 支持者徽章）的分工必须说清楚，
//  因为两者都在同一个 app 里用 StoreKit，语义却相反：
//  BadgeStore 把收据交给 core 入账（`apiCreateBadgeInvoice` + `apiPurchaseBadge`），
//  那是**有服务端记账**的一条路。本文件一条都不交——POPOPX 没有账号也没有业务服务器，
//  收据只在本机验签后铸成本地凭证（券 / 算力点 / 徽章），`Transaction` 在本地落账成功之后才 finish。
//  两件事因此不能混：本文件永不出现 `api*` 调用，BadgeStore 的 product id 也一个都不认。
//  认到陌生 product id 时走 `finish()` 而不是报错——那是别人家的收据，留着它只会反复重投。
//
//  StoreKit 的 API 形状抄自本仓库已在用的写法（BadgeStore.swift:302/374/399/426/444/550），
//  不凭记忆：`Transaction.updates` 逐条给的是 `VerificationResult<Transaction>`，
//  未验签的载荷仍可读但绝不可信，这一条判据在两处必须完全一致。

import Foundation
import os
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 值类型

/// 一笔**已验签**交易在本模块内的形态。
///
/// `jwsRepresentation` 只在这里、只在内存里存在：落 Keychain 的永远是它的摘要
/// （`PopopxNodeVoucher.jwsDigest`）。那串 JWS 里带着 Apple ID 关联信息，
/// 把它整段留在设备上只是把风险搬进自己的备份里，而它对本地防双花没有任何额外价值。
struct PopopxStoreReceipt: Hashable, Sendable {
    let transactionId: UInt64
    let originalTransactionId: UInt64
    let productId: String
    let jwsRepresentation: String
    let purchasedAtMs: Int64
    /// 订阅由 Apple 给到期时间；消耗型为 nil（本模块自己推算有效期）。
    let expiresAtMs: Int64?
    /// Apple 退款/撤销。为真时本模块一律按"这张收据不值钱"处理。
    let isRevoked: Bool

    var sku: PopopxNodeBadgeSku? { PopopxNodeBadgeSku.sku(for: productId) }

    var digest: String { PopopxCommerceSignature.shortDigest(jwsRepresentation) }
}

/// 一次 `purchase` 调用的结果。`.pending` 是 Ask to Buy 和家庭购买待批，
/// 它**不是失败**：收据会从 `Transaction.updates` 再来一次，所以这里绝不落账也不 finish。
enum PopopxStorePurchaseOutcome: Hashable, Sendable {
    case purchased(PopopxStoreReceipt)
    case pending
    case cancelled
}

/// 续费的真实状态，取自 `Product.SubscriptionInfo.Status`。
/// 徽章是否点亮以 Apple 为准：本地记录只负责"到期时间"，续费开关归 Apple。
struct PopopxSubscriptionSnapshot: Hashable, Sendable {
    var period: PopopxNodeBadgePeriod
    var isSubscribed: Bool
    var willAutoRenew: Bool
    var expiresAtMs: Int64?
    var state: PopopxSubscriptionRenewalState
}

enum PopopxSubscriptionRenewalState: Hashable, Sendable {
    case renewing
    case cancelled
    case billingRetry
    case ended
    case unknown
}

// MARK: - 引擎

/// StoreKit 2 的唯一入口。
///
/// 交付回调（`attachDelivery`）而不是让本类直接调用 Badge/Credits：
/// 三者都在 `@MainActor` 上，彼此持有会形成一条初始化环，
/// 而"谁先创建"会因为一次冷启动顺序变化而决定徽章有没有点亮——那是最难复现的一类 bug。
@MainActor
@Observable
final class PopopxStoreKitManager {
    static let shared = PopopxStoreKitManager()

    /// product id → `Product`。空表不等于"没有内购"，可能是拉取失败，
    /// 所以调用方必须同时读 `productsLoadFailed` 才能决定 UI 显示什么。
    private(set) var products: [String: Product] = [:]
    private(set) var isLoadingProducts = false
    private(set) var productsLoadFailed = false
    private(set) var lastLoadAt: Date?
    /// 请求了但 Apple 一次都没返回的 product id（仅在最近一次拉取**成功**时有意义）。
    ///
    /// 这条差集是把"暂不可用"这句 toast 变成可诊断信息的那一处：整批为空 = 商店连不上 /
    /// 配置文件没挂上；只缺 `com.popopx.badge.node.pass.30d` 这一个 = 这个 identifier 在
    /// App Store Connect（或 `.storekit`）里根本不存在。两种病因在 UI 上是同一句话，
    /// 只有这里能分开，所以它必须被记下来、被日志说出来。
    private(set) var missingProductIDs: [String] = []
    /// 最近一次拉取抛出的错误（`String(describing:)`）。只进日志与控制台，不进用户界面：
    /// Apple 的错误描述是英文技术语句，直接抛给用户是另一种不体面。
    private(set) var lastLoadError: String?
    /// 日志。product id 不是秘密（它就在 App Store 的收据里），缺了它这次排查就只能靠猜。
    /// `let` 而不是 `var`：`@Observable` 只跟踪可变存储属性，这一条因此不进视图依赖。
    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "storekit")

    /// 已经处理过的交易 id。`Transaction.updates` 与一次前台购买可能给出同一笔交易两次，
    /// 落账两次 = 白送一份算力点，所以去重键必须是交易 id 而不是 product id。
    private var settledTransactionIds: Set<UInt64> = []
    private var deliveries: [UUID: @MainActor (PopopxStoreReceipt) async -> Void] = [:]
    private var updatesTask: Task<Void, Never>?

    private init() {}

    // MARK: 加载

    /// 动态拉取全部 9 个 SKU（含两个 non-renewing 通行证：`Product.products(for:)` 一次调用
    /// 混着传 consumable / autoRenewable / nonRenewable 三类 id 是 Apple 支持的用法，
    /// 通行证**不**需要单独再拉一次——真出问题时"漏了哪几个 id"看 `missingProductIDs`）。
    /// 价格永远以 `displayPrice` 为准（区域货币由 Apple 决定），
    /// `PopopxNodeBadgeSku.fallbackPriceText` 只在拉取失败时占位。
    func loadProducts(force: Bool = false) async {
        if !force, !products.isEmpty, let lastLoadAt, Date().timeIntervalSince(lastLoadAt) < 600 { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let fetched = try await Product.products(for: PopopxNodeBadgeSku.productIds)
            var table: [String: Product] = [:]
            for product in fetched where PopopxNodeBadgeSku.sku(for: product.id) != nil {
                table[product.id] = product
            }
            products = table
            // 差集按请求顺序算，日志里读出来的顺序与枚举、与 `.storekit` 一致，便于逐字比对。
            missingProductIDs = PopopxNodeBadgeSku.productIds.filter { table[$0] == nil }
            lastLoadError = nil
            productsLoadFailed = table.isEmpty
            lastLoadAt = Date()
            if missingProductIDs.isEmpty {
                log.notice("storekit: all \(PopopxNodeBadgeSku.productIds.count, privacy: .public) SKUs loaded")
            } else {
                let missing = self.missingProductIDs.joined(separator: " ")
                self.log.notice("storekit: loaded \(table.count, privacy: .public)/\(PopopxNodeBadgeSku.productIds.count, privacy: .public) SKUs; missing: \(missing, privacy: .public)")
            }
        } catch {
            // 拉不到商品时保留旧表：一次网络抖动不该把已经显示出来的价格全部抹成兜底文案。
            productsLoadFailed = products.isEmpty
            // 抛错这一次没有"缺哪几个"这个事实（Apple 一个字都没回），所以差集清空、错误留下，
            // 让 `purchase` 那侧能把"整批失败"和"只缺这一个"分成两种答复。
            missingProductIDs = []
            lastLoadError = String(describing: error)
            log.error("storekit: load products failed: \(String(describing: error), privacy: .public)")
        }
    }

    var isStoreReady: Bool { !products.isEmpty }

    func product(for sku: PopopxNodeBadgeSku) -> Product? { products[sku.productId] }

    /// 带周期的价格文案，例如 `"$49.99 / year"`。
    /// 后缀走 `PopopxCommerceCopy`（全语种那一批），因为"每年"这种词在审核截图里必须是目标语言。
    func priceText(for sku: PopopxNodeBadgeSku, periodSuffix: Bool = true) -> String {
        guard let product = product(for: sku) else {
            return periodSuffix ? compact(sku.fallbackPriceText, suffix: suffix(for: sku)) : sku.fallbackPriceText
        }
        let head = product.displayPrice
        return periodSuffix ? compact(head, suffix: suffix(for: sku)) : head
    }

    private func suffix(for sku: PopopxNodeBadgeSku) -> String? {
        switch sku.kind {
        case .subscription(.annual): PopopxCommerceCopy.pricePerYear
        case .subscription(.monthly): PopopxCommerceCopy.pricePerMonth
        // 通行证不给周期后缀：它不是"每月/每年"，那一句话由档位上的非续订声明说。
        case .oneTimePass, .giftCard, .credits: nil
        }
    }

    private func compact(_ price: String, suffix: String?) -> String {
        guard let suffix else { return price }
        return "\(price) \(suffix)"
    }

    // MARK: 购买

    /// 购买。成功返回**已验签**的收据；本函数只负责 StoreKit 这一段，
    /// 落账（写徽章 / 铸券 / 加算力点）由调用方在同一事务里完成后才会 `finish`。
    func purchase(_ sku: PopopxNodeBadgeSku) async -> Result<PopopxStorePurchaseOutcome, PopopxBadgeCreditsError> {
        if product(for: sku) == nil { await loadProducts(force: true) }
        guard let reloaded = product(for: sku) else {
            // 三种病因要说三种话，否则"该商品暂不可用（com.popopx.badge.node.pass.30d）"这一句
            // 在真机上永远查不下去：整批拉不到 / 拉取抛错 / 只缺这一个。
            // `lastLoadError != nil` 优先于 `productsLoadFailed`：强制重拉那一次如果抛了错，
            // 表里留下的可能是上一次的旧货，此时"商品不存在"是句假话。
            let loadBroke = productsLoadFailed || lastLoadError != nil
            let missing = self.missingProductIDs.joined(separator: " ")
            log.error("storekit: purchase refused for \(sku.productId, privacy: .public); loadBroke=\(loadBroke, privacy: .public) lastLoadError=\(self.lastLoadError ?? "none", privacy: .public) missing=[\(missing, privacy: .public)]")
            // 这一句拒绝在 Debug 构建上不是死路：付费墙在拿到 `.productNotFound` 之前就已经按
            // `isMissingFromStore(_:)` 摆出了沙盒那颗按钮（见下面"沙盒购买"那一节）。
            // 这里**不**自动降级成沙盒成交——真实 CTA 在 Debug 与 Release 必须指同一件事，
            // 否则"点了买、其实没付钱"这件事只有翻代码的人才知道。
            return .failure(loadBroke ? .storeUnavailable : .productNotFound(sku.productId))
        }
        return await purchaseResolved(reloaded)
    }

    private func purchaseResolved(_ product: Product) async -> Result<PopopxStorePurchaseOutcome, PopopxBadgeCreditsError> {
        do {
            // 不带 `appAccountToken`：它在这套架构里没有对应的服务端发票可回填，
            // 带上一个没人认领的 UUID 只会让 Apple 的收据里多一段解释不了的字段。
            switch try await product.purchase() {
            case let .success(verification):
                guard let receipt = Self.receipt(of: verification) else {
                    // 验不过的收据不落账、也不 finish：留给 StoreKit 重投，
                    // 静默 finish 等于把一笔真实付款悄悄吃掉。
                    return .failure(.verificationFailed)
                }
                settledTransactionIds.insert(receipt.transactionId)
                return .success(.purchased(receipt))
            case .pending:
                return .success(.pending)
            case .userCancelled:
                return .success(.cancelled)
            @unknown default:
                return .failure(.purchaseFailed("unknown"))
            }
        } catch {
            return .failure(.purchaseFailed(error.localizedDescription))
        }
    }

    // MARK: 沙盒购买（只有 Debug 构建会编译进这一整段）

    #if DEBUG
    /// 模拟交易的标识前缀：高 4 位恒为 `0xF`，因此它必然大于任何一笔真实 Apple 交易号
    /// （现网交易号不超过 2^61）。防碰撞靠的是下面那个 `UUID`，不是这一位——
    /// 它的作用是让用户在 Console 里、在 `settledTransactionIds` 里、在断点里一眼认出
    /// "这一笔是本机铸的，Apple 那侧根本不存在"，不必再靠反推摘要来分类。
    private static let simulatedTransactionPrefix: UInt64 = 0xF000_0000_0000_0000

    /// 「商店确实没有这一件」与「还没问过商店」是两件事，混起来的代价是付费墙一进来
    /// 就闪一下沙盒按钮、然后在 0.3 秒后消失。
    ///
    /// `lastLoadError != nil` 也算"问过了"：`lastLoadAt` 只在**成功**分支赋值，所以
    /// "整批抛错"这一种形态（真机没挂配置文件时很常见：商店直接回一个 Store 内部错误）
    /// 只认 `lastLoadAt` 的话就永远不出按钮，而这恰好是最需要它的一次。
    func isMissingFromStore(_ sku: PopopxNodeBadgeSku) -> Bool {
        guard !isLoadingProducts else { return false }
        guard lastLoadAt != nil || lastLoadError != nil else { return false }
        return product(for: sku) == nil
    }

    /// Debug 构建的第二条购买通路：**本机铸一张收据**，落账一行都不新写。
    ///
    /// 为什么要它（真机实测的病因，不是假想）：`.storekit` 配置文件只随 Xcode 的 scheme
    /// 启动注入，`xcrun devicectl device install app` 装到真机的那个包不带它，
    /// 于是 `Product.products(for:)` 打到真实/沙盒商店，9 个 SKU 一个都取不到，
    /// 付费墙与算力点页的每一颗按钮都是死的——整条商业主链路在真机上下一步都测不了。
    ///
    /// 与真实路径逐条对齐（这是这个函数存在的全部意义，任何一处偏离都得写在这上面）：
    /// - **收据同形**：走的是与 `receipt(of:)` 完全一样的字段语义。`expiresAtMs` 也按同一族规则给——
    ///   订阅给到期时刻（真实路径上那一位由 Apple 填），非续订通行证与消耗型给 `nil`
    ///   （Apple 对非续订订阅根本不算到期，"给多少天"本来就是这个模块的事实）。
    /// - **落账同一条代码**：通行证由调用方（付费墙 `grantPass`）当场点亮，与真实购买同一条腿；
    ///   订阅与礼品券在真实路径上由 `Transaction.updates → deliver` 落账，模拟通路没有 Apple 那条流，
    ///   所以这里补一次**同一个** `deliver`：交付回调仍是 `PopopxBadgeManager.apply(storeReceipt:)`
    ///   与 `PopopxCreditsManager.apply(storeReceipt:)`，时长叠加（`stackedExpiryMs`）、
    ///   Keychain 写入（`.badgeRecord` / `.wallet` / `.vouchers`）、防重投门禁、成功后震动，一道不少。
    /// - **通行证那一族不补投递**：付费墙已经当场点亮过一次。`applyPass` 的摘要门禁会挡掉第二遍，
    ///   但"靠门禁兜住"和"根本不投"是两种顺序，前者让 Debug 的落账次序与真实路径不同——不投更诚实。
    /// - **`finish` 是空转**：调用方照例会 `finish(receipt)`，它只在真实交易序列里找那个高 4 位为
    ///   `0xF` 的号，找不到就什么都不做。不存在"假装 finish 了一笔 Apple 交易"。
    ///
    /// 不可逆的东西一个都不碰：不写 `Transaction.*`（本机铸的收据进不了 Apple 的账本，
    /// 因此冷启动那三条腿 `recoverUnsettledPasses` / `reconcileWithStore` / `restorePurchases`
    /// 都看不见它），于是重启既不会白送第二段时长，也不会冒出一笔"恢复到的"幽灵交易；
    /// 而点亮的那个徽章就是真实的那一格 `.badgeRecord`，所以它重启还在——测的就是要上线的那一份状态。
    func purchaseSimulated(_ sku: PopopxNodeBadgeSku) async -> Result<PopopxStorePurchaseOutcome, PopopxBadgeCreditsError> {
        let mintedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        // 每次一张新码。摘要（`PopopxStoreReceipt.digest` = JWS 原文的短摘要）正是通行证与券
        // 两条腿上的防重投键：复用同一个摘要 = 第二次沙盒购买被门禁吃掉，测试会得到
        // "加了钱却没加时长"的假象，而那假象看起来像一个真 bug。
        let nonce = UUID().uuidString
        let transactionId = Self.simulatedTransactionPrefix | UInt64.random(in: 0 ..< Self.simulatedTransactionPrefix)
        let expiresAtMs: Int64? = switch sku.kind {
        case let .subscription(period): mintedAtMs + Int64(period.days) * 86_400_000
        case .oneTimePass, .giftCard, .credits: nil
        }
        let receipt = PopopxStoreReceipt(
            transactionId: transactionId,
            originalTransactionId: transactionId,
            productId: sku.productId,
            jwsRepresentation: "POPOPX-SANDBOX|\(sku.productId)|\(nonce)|\(mintedAtMs)",
            purchasedAtMs: mintedAtMs,
            expiresAtMs: expiresAtMs,
            isRevoked: false
        )
        // 与真实路径同一条去重表，但**顺序**不能照抄 `purchaseResolved`：见下面 if/else 的注释。
        if sku.oneTimePassPeriod == nil {
            // 订阅与礼品券：走与 `Transaction.updates` 完全同一个入口 `deliver`，
            // 由它自己去重（`guard settledTransactionIds.insert(...).inserted else { return }`）再投递。
            // 这里若先登记一次，`deliver` 那一道门禁会把它自己挡在门外——症状是"点了沙盒、
            // 什么都不到账"，而这条腿恰恰是这两族在真实路径上唯一的落账处，绝不会有人补。
            await deliver(receipt, sku: sku)
        } else {
            // 通行证：真实路径由付费墙当场点亮（`grantPass`），本函数不投递，只做
            // 与 `purchaseResolved` 等价的那一步登记，让去重语义在两种来源之间不分叉。
            settledTransactionIds.insert(transactionId)
        }
        log.notice("storekit: SANDBOX purchase minted on device for \(sku.productId, privacy: .public); no Apple transaction exists")
        return .success(.purchased(receipt))
    }
    #endif

    /// 落账：把交易标记为已完成。**只在本地写入成功之后调用**，
    /// 这是"消耗型商品不被重复兑现"与"付款后什么都没发生"之间唯一的分界线。
    func finish(_ receipt: PopopxStoreReceipt) async {
        for await transaction in Transaction.currentEntitlements {
            guard case let .verified(live) = transaction, live.id == receipt.transactionId else { continue }
            await live.finish()
            return
        }
        // 订阅续费与 Ask to Buy 的成交可能已经不在 currentEntitlements 里（例如刚被撤销），
        // 那就从 unfinished 补一次 finish，避免同一笔交易被 updates 反复投递。
        for await transaction in Transaction.unfinished {
            guard case let .verified(live) = transaction, live.id == receipt.transactionId else { continue }
            await live.finish()
            return
        }
    }

    // MARK: 交付订阅

    /// 注册落账回调，返回一个 token；token 被释放不代表注销，必须显式 `detachDelivery`。
    @discardableResult
    func attachDelivery(_ handler: @escaping @MainActor (PopopxStoreReceipt) async -> Void) -> UUID {
        let token = UUID()
        deliveries[token] = handler
        return token
    }

    func detachDelivery(_ token: UUID) { deliveries.removeValue(forKey: token) }

    // MARK: 后台续费监听

    /// 常驻监听。`Task.detached` 而不是 `Task { }`：这个流的生命周期属于进程，
    /// 不属于创建它的那一次视图刷新——挂在视图上的话，一次 pop 就会把续费通知弄丢。
    func startObservingTransactions() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached { [weak self] in
            for await verification in Transaction.updates {
                guard let receipt = Self.receipt(of: verification) else { continue }
                await Self.handleUpdate(receipt, in: self)
            }
        }
    }

    func stopObservingTransactions() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    private static func handleUpdate(_ receipt: PopopxStoreReceipt, in manager: PopopxStoreKitManager?) async {
        guard let manager else { return }
        // 别人的收据（SimpleX 徽章那一族）：finish 掉，别让它一直留在 unfinished 里重投。
        guard let sku = receipt.sku else {
            if receipt.isRevoked { return }
            await manager.finishIgnoring(receipt)
            return
        }
        await manager.deliver(receipt, sku: sku)
    }

    /// 非本模块 SKU 的收据：只 finish，不落账。
    /// 只从 `unfinished` 里找——已 finish 的交易不会再出现在那里，这正是"没有遗留"的证明。
    private func finishIgnoring(_ receipt: PopopxStoreReceipt) async {
        settledTransactionIds.insert(receipt.transactionId)
        for await verification in Transaction.unfinished {
            guard case let .verified(live) = verification, live.id == receipt.transactionId else { continue }
            await live.finish()
            return
        }
    }

    private func deliver(_ receipt: PopopxStoreReceipt, sku: PopopxNodeBadgeSku) async {
        if receipt.isRevoked {
            // 退款：撤销本地由这张收据铸出的东西。徽章这一档按到期处理而不是立刻熄灭，
            // 理由是"用户已经享受过的服务不追溯"，而算力点必须追溯（那是没花掉的余额）。
            await notifyDeliveries(receipt)
            return
        }
        guard settledTransactionIds.insert(receipt.transactionId).inserted else { return }
        await notifyDeliveries(receipt)
    }

    private func notifyDeliveries(_ receipt: PopopxStoreReceipt) async {
        for handler in deliveries.values { await handler(receipt) }
    }

    // MARK: 权益核对

    /// 打开 Apple 的订阅管理页。形态（含"取 keyWindow 所在 scene"这一步）抄自
    /// `BadgeStore.manageSubscriptions()`（Shared/Views/Badges/BadgeStore.swift:461）——
    /// 那是本仓库已在跑的 StoreKit 路径，不另起一套。找不到 scene 时不报错：
    /// 这个入口的作用是"把用户送到 Apple 那里去"，送不到就不动，没有需要回滚的东西。
    func manageSubscriptions() async {
        #if canImport(UIKit)
        // 整个类已在 `@MainActor` 上，不需要再套一层 `MainActor.run`。
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.windows.contains(where: \.isKeyWindow) }
        guard let scene else { return }
        _ = try? await AppStore.showManageSubscriptions(in: scene)
        #endif
    }

    /// 当前权益快照。用于冷启动对账：本机的徽章记录落后于 Apple（换机、恢复、另一台设备续费）时，
    /// 以这一份为准覆盖本地记录。
    func currentEntitlementReceipts(includeUnfinished: Bool = false) async -> [PopopxStoreReceipt] {
        var collected: [PopopxStoreReceipt] = []
        var seen: Set<UInt64> = []
        let sequences: [Transaction.Transactions] = includeUnfinished
            ? [Transaction.currentEntitlements, Transaction.unfinished]
            : [Transaction.currentEntitlements]
        for sequence in sequences {
            for await verification in sequence {
                guard let receipt = Self.receipt(of: verification),
                      receipt.sku != nil,
                      seen.insert(receipt.transactionId).inserted
                else { continue }
                collected.append(receipt)
            }
        }
        return collected
    }

    /// 还没 finish 的交易里本模块认得的那些。
    ///
    /// 这一条序列是"钱已付、本地没落账"的唯一硬证据：本模块的铁律是**先落账、后 finish**
    /// （见 `purchase` 与两个管理器的 `apply(storeReceipt:)`），所以还留在 `Transaction.unfinished`
    /// 里的收据，一定是上一次进程死在"付款成功 → 本地写入"之间的那一笔。
    /// 冷启动把它交回交付回调，就是"能扣款、不发货"唯一的兜底通道；一旦落账成功并 finish，
    /// 它立刻从这条序列里消失，因此这条腿天然不会白送第二份权益。
    func unfinishedReceipts() async -> [PopopxStoreReceipt] {
        var collected: [PopopxStoreReceipt] = []
        var seen: Set<UInt64> = []
        for await verification in Transaction.unfinished {
            guard let receipt = Self.receipt(of: verification), receipt.sku != nil,
                  seen.insert(receipt.transactionId).inserted
            else { continue }
            collected.append(receipt)
        }
        return collected
    }

    /// 订阅状态（续费中/已取消/扣费重试/已结束）。给徽章详情页那句"续费状态"用。
    func subscriptionSnapshot(for period: PopopxNodeBadgePeriod) async -> PopopxSubscriptionSnapshot? {
        let sku: PopopxNodeBadgeSku = period == .annual ? .subscriptionAnnual : .subscriptionMonthly
        let resolved: Product?
        if let cached = product(for: sku) {
            resolved = cached
        } else {
            // 局部名不能叫 `product`：它会遮住同名的 `product(for:)` 方法，
            // 于是后面每次查表都变成"调用一个 Product?"。
            await loadProducts(force: true)
            resolved = product(for: sku)
        }
        guard let resolved else { return nil }
        // 不写成 `try await resolved.subscription?.status ?? []`：
        // `await` 落在 `??` 右侧是语法错误，加括号只是为了绕开它，读起来更绕。
        var statuses: [Product.SubscriptionInfo.Status] = []
        do {
            if let subscription = resolved.subscription {
                statuses = try await subscription.status
            }
        } catch {
            return nil
        }
        guard let status = statuses.first else { return nil }
        let renewalKnown: Bool
        let willRenew: Bool
        if case .verified(let renewalInfo) = status.renewalInfo {
            renewalKnown = true
            willRenew = renewalInfo.willAutoRenew
        } else {
            renewalKnown = false
            willRenew = false
        }
        guard case .verified(let transaction) = status.transaction else { return nil }
        let state: PopopxSubscriptionRenewalState = switch status.state {
        case .subscribed: willRenew ? .renewing : .cancelled
        case .inBillingRetryPeriod, .inGracePeriod: .billingRetry
        case .expired, .revoked: .ended
        // `.default` 是真实存在的第 6 档（Apple 保留的未知状态），不是编译器兜底：
        // 所以这里必须写 `default` 而不是 `@unknown default`，判据抄 BadgeStore.swift:450。
        default: .unknown
        }
        return PopopxSubscriptionSnapshot(
            period: period,
            isSubscribed: status.state == .subscribed,
            willAutoRenew: renewalKnown ? willRenew : false,
            expiresAtMs: Int64(transaction.expirationDate?.timeIntervalSince1970 ?? transaction.purchaseDate.timeIntervalSince1970) * 1_000,
            state: state
        )
    }


    // MARK: 恢复购买

    /// `AppStore.sync()` 之后把**本模块认得的**权益全部交回给订阅者落账。
    /// 只有自动续期订阅能被 Apple 恢复；消耗型（券与算力点）本来就不可恢复，
    /// 这一条差异必须在审核文档与 UI 里说同一句话，不能一处说"可恢复"一处说不行。
    func restorePurchases() async -> Result<PopopxRestoreOutcome, PopopxBadgeCreditsError> {
        do {
            try await AppStore.sync()
        } catch {
            // 用户在 Apple 的登录/确认面板上取消是常态，不能报成故障。
            // 不判 `SKError.Code`：那族错误码里没有 "cancelled" 这一档（`.overlayCancelled` 是另一回事），
            // 猜一个名字会让这条路径在编译期就烂掉。
            if error is CancellationError { return .success(.cancelled) }
            return .failure(.purchaseFailed(error.localizedDescription))
        }
        var subscriptionReceipts: [PopopxStoreReceipt] = []
        var giftReceipts: [PopopxStoreReceipt] = []
        for receipt in await currentEntitlementReceipts(includeUnfinished: true) {
            guard let sku = receipt.sku else { continue }
            switch sku.kind {
            case .subscription: subscriptionReceipts.append(receipt)
            case .giftCard: giftReceipts.append(receipt)
            // 一次性时长包（非续订订阅）不进恢复流程：Apple 那侧就没有"恢复非续订"这条承诺，
            // 而且它点亮过的时长已经落在这台设备的徽章记录里，重投一次就是白送一段时长。
            case .oneTimePass, .credits: break   // 消耗型点数充值同理，见上面那条注释。
            }
        }
        for receipt in subscriptionReceipts + giftReceipts { await notifyDeliveries(receipt) }
        if !subscriptionReceipts.isEmpty { return .success(.restored(subscriptionReceipts.count)) }
        return .success(.nothingToRestore)
    }

    /// 是否曾经买过某个 SKU（给"礼品卡已买过 N 张"这类提示用）。
    /// 走 `Transaction.all` 而不是 `currentEntitlements`：消耗型买完就 finish，
    /// 在 `currentEntitlements` 里永远看不到，用它判断"买过"会得到假阴性。
    func hasPurchased(_ sku: PopopxNodeBadgeSku) async -> Bool {
        for await verification in Transaction.all {
            guard case let .verified(live) = verification, live.productID == sku.productId else { continue }
            return true
        }
        return false
    }

    // MARK: 验签

    /// 唯一的验签入口：未验签一律返回 nil。
    /// `verification.unsafePayloadValue` 在本文件一次都不出现——那个名字的意思就是"未经确认"。
    nonisolated static func receipt(of verification: VerificationResult<Transaction>) -> PopopxStoreReceipt? {
        guard case let .verified(transaction) = verification else { return nil }
        return PopopxStoreReceipt(
            transactionId: transaction.id,
            originalTransactionId: transaction.originalID,
            productId: transaction.productID,
            jwsRepresentation: verification.jwsRepresentation,
            purchasedAtMs: Int64(transaction.purchaseDate.timeIntervalSince1970 * 1_000),
            expiresAtMs: transaction.expirationDate.map { Int64($0.timeIntervalSince1970 * 1_000) },
            isRevoked: transaction.revocationDate != nil
        )
    }

    /// 去重表。冷启动重建权益时要能塞回已处理集合，否则同笔交易会被 updates 再交付一次。
    func markSettled(_ transactionId: UInt64) { settledTransactionIds.insert(transactionId) }
}

// MARK: - 恢复结果

enum PopopxRestoreOutcome: Hashable, Sendable {
    case restored(Int)
    case nothingToRestore
    case cancelled

    var announcementText: String {
        switch self {
        case let .restored(count):
            count == 1 ? PopopxCommerceCopy.restoredOne : PopopxCommerceCopy.restoredMany
                .replacingOccurrences(of: "%lld", with: String(count))
        case .nothingToRestore: PopopxCommerceCopy.restoredNothing
        case .cancelled: PopopxCommerceCopy.errorPurchaseCancelled
        }
    }
}

private extension PopopxCommerceCopy {
    static let restoredOne = NSLocalizedString("Your subscription was restored.", comment: "restore result")
    static let restoredMany = NSLocalizedString("%lld purchases were restored.", comment: "restore result")
    static let restoredNothing = NSLocalizedString("Nothing to restore for this item.", comment: "restore result")
}
