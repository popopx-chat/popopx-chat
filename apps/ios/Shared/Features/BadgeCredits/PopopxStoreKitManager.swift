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

    /// 已经处理过的交易 id。`Transaction.updates` 与一次前台购买可能给出同一笔交易两次，
    /// 落账两次 = 白送一份算力点，所以去重键必须是交易 id 而不是 product id。
    private var settledTransactionIds: Set<UInt64> = []
    private var deliveries: [UUID: @MainActor (PopopxStoreReceipt) async -> Void] = [:]
    private var updatesTask: Task<Void, Never>?

    private init() {}

    // MARK: 加载

    /// 动态拉取 7 个 SKU。价格永远以 `displayPrice` 为准（区域货币由 Apple 决定），
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
            productsLoadFailed = table.isEmpty
            lastLoadAt = Date()
        } catch {
            // 拉不到商品时保留旧表：一次网络抖动不该把已经显示出来的价格全部抹成兜底文案。
            productsLoadFailed = products.isEmpty
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
        guard let product = product(for: sku) else {
            await loadProducts(force: true)
            guard let reloaded = product(for: sku) else {
                return .failure(productsLoadFailed ? .storeUnavailable : .productNotFound(sku.productId))
            }
            return await purchaseResolved(reloaded)
        }
        return await purchaseResolved(product)
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
