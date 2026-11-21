//  PopopxStoreKitManager.swift
//
//  StoreKit 2 engine: loading the 9 SKUs, purchase, background renewal listening, entitlement reconciliation and restoring purchases.
//
//  The division of labour with `Shared/Views/Badges/BadgeStore.swift` (the upstream supporter badges) must be spelled out,
//  because both use StoreKit inside the same app yet mean the opposite:
//  BadgeStore hands the receipt to core for accounting (`apiCreateBadgeInvoice` + `apiPurchaseBadge`),
//  that is the path **with server-side bookkeeping**. This file hands nothing over — POPOPX has no account and no business server,
//  the receipt is only verified on-device and then minted into local credentials (voucher / compute credits / badge); `Transaction` is finished only after the local ledger write succeeds.
//  The two must never be mixed: this file never contains an `api*` call, and it recognises none of BadgeStore's product ids.
//  An unfamiliar product id goes through `finish()` rather than an error — it is somebody else's receipt, and keeping it only makes it be redelivered over and over.
//
//  The shape of the StoreKit API is copied from the pattern already in use in this repository (BadgeStore.swift:302/374/399/426/444/550),
//  not written from memory: what `Transaction.updates` yields item by item is a `VerificationResult<Transaction>`,
//  an unverified payload is still readable but never trustworthy, and this one criterion has to be exactly the same in both places.

import Foundation
import os
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

// // MARK: - Value types

/// The shape, inside this module, of one **verified** transaction.
///
/// `jwsRepresentation` exists only here and only in memory: what lands in the Keychain is always its digest
/// (`PopopxNodeVoucher.jwsDigest`). That JWS string carries Apple-ID linkage information;
/// keeping the whole of it on the device only moves the risk into our own backup, and it adds no value at all for local double-spend prevention.
struct PopopxStoreReceipt: Hashable, Sendable {
    let transactionId: UInt64
    let originalTransactionId: UInt64
    let productId: String
    let jwsRepresentation: String
    let purchasedAtMs: Int64
    /// Subscriptions get their expiry from Apple; consumables are nil (this module computes the validity window itself).
    let expiresAtMs: Int64?
    /// Apple refund / revocation. When true, this module treats that receipt as worthless.
    let isRevoked: Bool

    var sku: PopopxNodeBadgeSku? { PopopxNodeBadgeSku.sku(for: productId) }

    var digest: String { PopopxCommerceSignature.shortDigest(jwsRepresentation) }

    #if DEBUG
    /// The mark every locally minted receipt carries at its head. One definition, because the two ends of it — minting and judging —
    /// disagreeing is how a test purchase starts reporting itself as an Apple one.
    static let simulatedReceiptPrefix = "POPOPX-SANDBOX|"

    /// Whether this receipt was minted on this device instead of handed over by Apple, read **from the receipt itself**.
    /// A caller does not volunteer it: since the buy button took over the Debug settlement, by the time the result comes back
    /// the page no longer knows which end answered, and "this charge was not real" is a money fact that cannot depend on
    /// remembering to pass a flag. The transaction id's top nibble (`0xF`) says the same thing; this is the readable version.
    var isSimulatedSettlement: Bool { jwsRepresentation.hasPrefix(Self.simulatedReceiptPrefix) }
    #endif
}

/// The result of one `purchase` call. `.pending` is Ask to Buy or a family-purchase approval still waiting,
/// it is **not a failure**: the receipt will come again through `Transaction.updates`, so nothing is booked and nothing is finished here.
enum PopopxStorePurchaseOutcome: Hashable, Sendable {
    case purchased(PopopxStoreReceipt)
    case pending
    case cancelled
}

/// The real renewal state, taken from `Product.SubscriptionInfo.Status`.
/// Whether the badge is lit is Apple's call: the local record only carries "expiry time", the renewal switch belongs to Apple.
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

// // MARK: - Engine

/// The single entry point for StoreKit 2.
///
/// the delivery callback (`attachDelivery`) rather than letting this class call Badge/Credits directly:
/// all three live on `@MainActor`, holding each other forms an initialisation cycle,
/// and "who gets created first" would decide whether the badge lights up depending on one cold-start ordering change — that is the hardest kind of bug to reproduce.
@MainActor
@Observable
final class PopopxStoreKitManager {
    static let shared = PopopxStoreKitManager()

    /// product id → `Product`. An empty table does not mean "no in-app purchases", it may be a failed fetch,
    /// so callers must also read `productsLoadFailed` before deciding what the UI shows.
    private(set) var products: [String: Product] = [:]
    private(set) var isLoadingProducts = false
    private(set) var productsLoadFailed = false
    private(set) var lastLoadAt: Date?
    /// Product ids that were requested but Apple never returned (only meaningful when the most recent fetch **succeeded**).
    ///
    /// This difference set is what turns the "temporarily unavailable" toast into diagnosable information: an empty batch = the store is unreachable /
    /// the configuration file is not attached; only `com.popopx.badge.node.pass.30d` missing = that identifier does not exist at all
    /// in App Store Connect (or in the `.storekit` file). The two diseases read as the same sentence in the UI,
    /// only here can they be told apart, so it has to be recorded and said out loud in the log.
    private(set) var missingProductIDs: [String] = []
    /// The error thrown by the most recent fetch (`String(describing:)`). Logs and console only, never the user interface:
    /// Apple's error descriptions are English technical sentences, and throwing one straight at a user is another kind of undignified.
    private(set) var lastLoadError: String?
    /// Log. A product id is not a secret (it is right there in the App Store receipt); without it this investigation can only guess.
    /// `let` rather than `var`: `@Observable` only tracks mutable stored properties, so this line never enters view dependencies.
    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "storekit")

    /// Ids of transactions already handled. `Transaction.updates` and one foreground purchase can report the same transaction twice,
    /// and booking twice = compute credits given away for free, so the dedup key must be the transaction id, not the product id.
    private var settledTransactionIds: Set<UInt64> = []
    private var deliveries: [UUID: @MainActor (PopopxStoreReceipt) async -> Void] = [:]
    private var updatesTask: Task<Void, Never>?

    private init() {}

    // MARK: Loading

    /// Fetch all 9 SKUs dynamically (including the two non-renewing passes: one `Product.products(for:)` call
    /// passing consumable / autoRenewable / nonRenewable ids together is a usage Apple supports,
    /// the passes do **not** need a separate extra fetch — when something really breaks, "which ids were missing" is in `missingProductIDs`).
    /// Price always follows `displayPrice` (the local currency is Apple's decision),
    /// and `PopopxNodeBadgeSku.fallbackPriceText` only stands in when the fetch fails.
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
            // The difference set is computed in request order, so the order read out of the log matches the enum and the `.storekit` file, which makes word-by-word comparison easy.
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
            // When products cannot be fetched the old table is kept: one network fluke should not wipe every already-displayed price back to the fallback copy.
            productsLoadFailed = products.isEmpty
            // A throw has no "which ones were missing" fact (Apple returned not one word), so the difference set is cleared and the error is kept,
            // so that the `purchase` side can answer "whole batch failed" and "only this one is missing" as two different replies.
            missingProductIDs = []
            lastLoadError = String(describing: error)
            log.error("storekit: load products failed: \(String(describing: error), privacy: .public)")
        }
    }

    var isStoreReady: Bool { !products.isEmpty }

    func product(for sku: PopopxNodeBadgeSku) -> Product? { products[sku.productId] }

    /// Price text with a period, e.g. `"$49.99 / year"`.
    /// The suffix comes from `PopopxCommerceCopy` (the all-languages batch), because a word like "yearly" must be in the target language in review screenshots.
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
        // Passes get no period suffix: they are not "monthly/yearly", that statement is made by the non-renewing declaration on the tier.
        case .oneTimePass, .giftCard, .credits, .creditGiftCard: nil
        }
    }

    private func compact(_ price: String, suffix: String?) -> String {
        guard let suffix else { return price }
        return "\(price) \(suffix)"
    }

    // MARK: Purchase

    /// Purchase. On success returns a **verified** receipt; this function is only responsible for the StoreKit part,
    /// and `finish` is only reached after the caller has completed the booking (writing the badge / minting the voucher / adding compute credits) in the same transaction.
    func purchase(_ sku: PopopxNodeBadgeSku) async -> Result<PopopxStorePurchaseOutcome, PopopxBadgeCreditsError> {
        if product(for: sku) == nil { await loadProducts(force: true) }
        guard let reloaded = product(for: sku) else {
            // Three diseases need three sentences, otherwise the line "this item is temporarily unavailable (com.popopx.badge.node.pass.30d)"
            // can never be traced down on a real device: whole batch not fetched / fetch threw / only this one is missing.
            // `lastLoadError != nil` takes precedence over `productsLoadFailed`: if the forced refetch threw,
            // what is left in the table may be last time's stale goods, and then "the product does not exist" would be a lie.
            let loadBroke = productsLoadFailed || lastLoadError != nil
            let missing = self.missingProductIDs.joined(separator: " ")
            log.error("storekit: purchase refused for \(sku.productId, privacy: .public); loadBroke=\(loadBroke, privacy: .public) lastLoadError=\(self.lastLoadError ?? "none", privacy: .public) missing=[\(missing, privacy: .public)]")
            #if DEBUG
            // Debug only, and it answers the **same tap** the user already made: rather than refusing and waiting for a second,
            // Debug-only button to appear, the buy button itself settles locally. The reason is the one this line used to argue the other way with:
            // a side button leaves the tier's real CTA on a path the tester never walks, so what passes on the device is not the code that ships.
            // The safety of that reversal rests on three things, all kept here:
            // **one**, the gate is compile-time `#if DEBUG` plus the runtime opt-out below, so a Release archive cannot reach this line;
            // **two**, it only takes over the "Apple gave no product" case; anything that can go wrong later — the purchase sheet failing,
            // a receipt that will not verify — is still reported by `purchaseResolved` as itself, unfaked and undiverted;
            // **three**, "no money was actually charged" does not depend on the caller volunteering it — the locally minted receipt carries that itself
            // (see `PopopxStoreReceipt.isSimulatedSettlement`), and the page says it in its own words.
            if Self.simulatedSettlementEnabled {
                log.notice("storekit: DEBUG settlement for \(sku.productId, privacy: .public) instead of a refusal; loadBroke=\(loadBroke, privacy: .public)")
                return await purchaseSimulated(sku)
            }
            #endif
            return .failure(loadBroke ? .storeUnavailable : .productNotFound(sku.productId))
        }
        return await purchaseResolved(reloaded)
    }

    private func purchaseResolved(_ product: Product) async -> Result<PopopxStorePurchaseOutcome, PopopxBadgeCreditsError> {
        do {
            // No `appAccountToken`: in this architecture it has no server-side invoice to backfill,
            // and carrying an unclaimed UUID only adds a field to Apple's receipt that nobody can explain.
            switch try await product.purchase() {
            case let .success(verification):
                guard let receipt = Self.receipt(of: verification) else {
                    // A receipt that fails verification is neither booked nor finished: it is left for StoreKit to redeliver,
                    // silently finishing it is the same as quietly swallowing a real payment.
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

    // MARK: Sandbox purchases (only Debug builds compile this whole section)

    #if DEBUG
    /// Identifier prefix for simulated transactions: the top 4 bits are always `0xF`, so it is necessarily larger than any real Apple transaction id
    /// (live transaction ids do not exceed 2^61). Collision avoidance comes from the `UUID` below, not from this nibble —
    /// its purpose is that a user recognises at a glance in the Console, in `settledTransactionIds`, at a breakpoint:
    /// "this one was minted on this device, it does not exist on Apple's side at all", instead of having to reverse-engineer a digest to classify it.
    private static let simulatedTransactionPrefix: UInt64 = 0xF000_0000_0000_0000

    /// Whether a Debug build may settle a SKU the store does not carry (`purchase(_:)` takes the local leg, and the pages
    /// put the explanation on screen). Default is **on**, and the only way to turn it off is to launch with the
    /// `POPOPX_DISABLE_SANDBOX_SETTLEMENT` environment variable set — a runtime switch rather than a code edit because the thing
    /// worth reproducing is exactly the shape a device shows when nobody is watching: no local settlement, and then the real
    /// `.productNotFound` sentence, the one that used to be all a tester got.
    ///
    /// A `static var` rather than a `let`: `ProcessInfo.environment` is only meaningful once the process has started, and a `let`
    /// of a global-actor-isolated type initialises lazily anyway — saying it out loud is cheaper than letting whoever reads this guess.
    static var simulatedSettlementEnabled: Bool {
        ProcessInfo.processInfo.environment["POPOPX_DISABLE_SANDBOX_SETTLEMENT"] == nil
    }

    /// "The store really does not have this item" and "we have not asked the store yet" are two different things; confusing them costs the paywall
    /// a flash of the sandbox note on entry, gone 0.3 seconds later.
    ///
    /// `lastLoadError != nil` also counts as "asked": `lastLoadAt` is only assigned on the **success** branch, so
    /// the "whole batch threw" shape (common on a real device with no configuration file attached: the store just answers with an internal Store error)
    /// would never show that note if only `lastLoadAt` were trusted, and that is exactly the moment it is needed most.
    /// Since the buy button took over the local settlement, this function has one job left: deciding whether those two sentences belong on screen.
    /// It is deliberately **not** the criterion for whether a tap is settled locally — that answer lives in `purchase(_:)`, and a page
    /// that judged it too would put the same branch in two places that can disagree.
    func isMissingFromStore(_ sku: PopopxNodeBadgeSku) -> Bool {
        guard !isLoadingProducts else { return false }
        guard lastLoadAt != nil || lastLoadError != nil else { return false }
        return product(for: sku) == nil
    }

    /// The Debug settlement behind the buy button: **mint a receipt on this device**, and the booking code is not one line longer.
    ///
    /// Why it exists (a disease measured on a real device, not hypothetical): the `.storekit` configuration file is only injected at launch
    /// by the Xcode scheme; the package installed onto a device with `xcrun devicectl device install app` does not carry it,
    /// so `Product.products(for:)` hits the real store and answers for the seven SKUs App Store Connect knows about, while the five
    /// newest ones (the two one-time passes and the three credit gift cards) come back missing and their tiers were dead buttons —
    /// the whole commercial main path cannot be tested one step further on a real device.
    ///
    /// `purchase(_:)` calls this for the missing case; a caller should not pick it directly, because a page that offers it as its own
    /// button tests a path the shipped build does not contain.
    ///
    /// Aligned with the real path item by item (that is the entire reason this function exists, and any deviation must be written above it):
    /// - **Same receipt shape**: exactly the same field semantics as `receipt(of:)`. `expiresAtMs` also follows the same family of rules —
    ///   subscriptions get the expiry moment (on the real path Apple fills that one), non-renewing passes and consumables get `nil`
    ///   (Apple does not compute any expiry for non-renewing subscriptions at all; "how many days" was always this module's own fact).
    /// - **Same booking code**: the pass is lit on the spot by the caller (the paywall's `grantPass`), the same leg as a real purchase;
    ///   subscriptions and gift vouchers are booked on the real path by `Transaction.updates → deliver`, and the simulated path has no Apple stream,
    ///   so this place calls **the same** `deliver` once: the delivery callbacks are still `PopopxBadgeManager.apply(storeReceipt:)`
    ///   and `PopopxCreditsManager.apply(storeReceipt:)`, duration stacking (`stackedExpiryMs`),
    ///   Keychain writes (`.badgeRecord` / `.wallet` / `.vouchers`), the anti-redelivery gate, the haptic on success — not one of them missing.
    /// - **The pass family is not re-delivered**: the paywall already lit it once on the spot. `applyPass`'s digest gate would block a second pass,
    ///   but "caught by the gate" and "never delivered in the first place" are two orderings; the former makes Debug's booking order differ from the real path — not delivering is more honest.
    /// - **`finish` is a no-op**: the caller still calls `finish(receipt)`, which looks in the real transaction sequence for that id whose top nibble is
    ///   `0xF`, finds nothing and does nothing. There is no "pretend an Apple transaction was finished".
    ///
    /// Nothing irreversible is touched: no writes to `Transaction.*` (a locally minted receipt cannot enter Apple's ledger,
    /// so the three cold-start legs `recoverUnsettledPasses` / `reconcileWithStore` / `restorePurchases`
    /// never see it), so a restart neither gives away a second block of duration nor produces a "restored" ghost transaction;
    /// and the badge that does get lit is the real `.badgeRecord` cell, so it survives a restart — what is tested is exactly the state that ships.
    func purchaseSimulated(_ sku: PopopxNodeBadgeSku) async -> Result<PopopxStorePurchaseOutcome, PopopxBadgeCreditsError> {
        let mintedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        // A fresh code every time. The digest (`PopopxStoreReceipt.digest` = a short digest of the raw JWS) is exactly the anti-redelivery key on both the pass and the voucher
        // legs: reusing the same digest = the second sandbox purchase gets eaten by the gate, and the test ends up with
        // the illusion "money was added but no duration was", and that illusion looks a lot like a real bug.
        let nonce = UUID().uuidString
        let transactionId = Self.simulatedTransactionPrefix | UInt64.random(in: 0 ..< Self.simulatedTransactionPrefix)
        let expiresAtMs: Int64? = switch sku.kind {
        case let .subscription(period): mintedAtMs + Int64(period.days) * 86_400_000
        case .oneTimePass, .giftCard, .credits, .creditGiftCard: nil
        }
        let receipt = PopopxStoreReceipt(
            transactionId: transactionId,
            originalTransactionId: transactionId,
            productId: sku.productId,
            jwsRepresentation: "\(PopopxStoreReceipt.simulatedReceiptPrefix)\(sku.productId)|\(nonce)|\(mintedAtMs)",
            purchasedAtMs: mintedAtMs,
            expiresAtMs: expiresAtMs,
            isRevoked: false
        )
        // The same dedup table as the real path, but the **order** must not be copied from `purchaseResolved`: see the comments in the if/else below.
        if sku.oneTimePassPeriod == nil {
            // Subscriptions and gift vouchers: go through `deliver`, the very same entry `Transaction.updates` uses,
            // and let it dedup itself (`guard settledTransactionIds.insert(...).inserted else { return }`) before delivering.
            // If we registered first here, `deliver`'s own gate would lock it out — the symptom is "tapped sandbox,
            // nothing arrived", and this leg is precisely the only booking place these two families have on the real path; nobody would ever patch it.
            await deliver(receipt, sku: sku)
        } else {
            // Passes: on the real path the paywall lights them up on the spot (`grantPass`); this function does not deliver,
            // it only performs the registration step equivalent to `purchaseResolved`, so the dedup semantics do not fork between the two sources.
            settledTransactionIds.insert(transactionId)
        }
        log.notice("storekit: SANDBOX purchase minted on device for \(sku.productId, privacy: .public); no Apple transaction exists")
        return .success(.purchased(receipt))
    }
    #endif

    /// Booking: mark the transaction as finished. **Called only after the local write succeeded**,
    /// this is the only dividing line between "a consumable is not redeemed twice" and "money paid, nothing happened".
    func finish(_ receipt: PopopxStoreReceipt) async {
        for await transaction in Transaction.currentEntitlements {
            guard case let .verified(live) = transaction, live.id == receipt.transactionId else { continue }
            await live.finish()
            return
        }
        // Renewals and Ask-to-Buy settlements may no longer be in currentEntitlements (e.g. just revoked),
        // so finish once from unfinished instead, to keep the same transaction from being redelivered by updates over and over.
        for await transaction in Transaction.unfinished {
            guard case let .verified(live) = transaction, live.id == receipt.transactionId else { continue }
            await live.finish()
            return
        }
    }

    // MARK: Delivering subscriptions

    /// Register the booking callback and return a token; releasing the token does not unregister — `detachDelivery` must be called explicitly.
    @discardableResult
    func attachDelivery(_ handler: @escaping @MainActor (PopopxStoreReceipt) async -> Void) -> UUID {
        let token = UUID()
        deliveries[token] = handler
        return token
    }

    func detachDelivery(_ token: UUID) { deliveries.removeValue(forKey: token) }

    // MARK: Background renewal listener

    /// A resident listener. `Task.detached` rather than `Task { }`: this stream's lifetime belongs to the process,
    /// not to the view refresh that created it — attached to a view, one pop would lose the renewal notification.
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
        // Somebody else's receipt (the upstream badge family): finish it, do not let it sit in unfinished and be redelivered.
        guard let sku = receipt.sku else {
            if receipt.isRevoked { return }
            await manager.finishIgnoring(receipt)
            return
        }
        await manager.deliver(receipt, sku: sku)
    }

    /// A receipt for an SKU outside this module: finish only, never book.
    /// Look only in `unfinished` — a finished transaction cannot appear there again, which is exactly the proof that "nothing was left behind".
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
            // Refund: revoke what this receipt minted locally. The badge tier is handled by expiring it rather than snuffing it at once,
            // because "service the user already enjoyed is not clawed back", while compute credits must be clawed back (that is unspent balance).
            await notifyDeliveries(receipt)
            return
        }
        guard settledTransactionIds.insert(receipt.transactionId).inserted else { return }
        await notifyDeliveries(receipt)
    }

    private func notifyDeliveries(_ receipt: PopopxStoreReceipt) async {
        for handler in deliveries.values { await handler(receipt) }
    }

    // MARK: Entitlement reconciliation

    /// Open Apple's subscription management page. The shape (including the "take the scene holding keyWindow" step) is copied from
    /// `BadgeStore.manageSubscriptions()`（Shared/Views/Badges/BadgeStore.swift:461）——
    /// that is the StoreKit path already running in this repository, we do not start a second one. When no scene is found we do not raise:
    /// the job of this entry is "get the user over to Apple"; if we cannot get them there we do nothing, there is nothing to roll back.
    func manageSubscriptions() async {
        #if canImport(UIKit)
        // The whole class is already on `@MainActor`, no need to wrap another `MainActor.run` around it.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.windows.contains(where: \.isKeyWindow) }
        guard let scene else { return }
        _ = try? await AppStore.showManageSubscriptions(in: scene)
        #endif
    }

    /// A snapshot of current entitlements. Used for cold-start reconciliation: when this device's badge record lags behind Apple (device swap, restore, renewal on another device),
    /// this snapshot wins and overwrites the local record.
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

    /// Among the transactions not yet finished, the ones this module recognises.
    ///
    /// This sequence is the only hard evidence of "money paid, nothing booked locally": the module's iron rule is **book first, finish after**
    /// (seen in `purchase` and the two managers' `apply(storeReceipt:)`), so a receipt still sitting in `Transaction.unfinished`
    /// must be the one where the previous process died between "payment succeeded" and "local write".
    /// Handing it back to the delivery callback on cold start is the only fallback channel against "charged but never delivered"; once it is booked and finished
    /// it disappears from this sequence immediately, so this leg naturally never gives away a second entitlement.
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

    /// Subscription status (renewing / cancelled / billing retry / expired). For the "renewal status" line on the badge detail page.
    func subscriptionSnapshot(for period: PopopxNodeBadgePeriod) async -> PopopxSubscriptionSnapshot? {
        let sku: PopopxNodeBadgeSku = period == .annual ? .subscriptionAnnual : .subscriptionMonthly
        let resolved: Product?
        if let cached = product(for: sku) {
            resolved = cached
        } else {
            // The local name must not be `product`: it would shadow the method of the same name `product(for:)`,
            // and then every later table lookup becomes "call a `Product?`".
            await loadProducts(force: true)
            resolved = product(for: sku)
        }
        guard let resolved else { return nil }
        // Not written as `try await resolved.subscription?.status ?? []`:
        // an `await` on the right-hand side of `??` is a syntax error, and adding parentheses only to dodge it reads worse.
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
        // `.default` is a real sixth case (the unknown state Apple keeps in reserve), not a compiler fallback:
        // so this must be written `default` and not `@unknown default`; the criterion is copied from BadgeStore.swift:450.
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


    // MARK: Restoring purchases

    /// After `AppStore.sync()`, hand every entitlement **this module recognises** back to the subscribers for booking.
    /// Only auto-renewing subscriptions can be restored by Apple; consumables (vouchers and compute credits) are inherently non-restorable,
    /// and that difference must say the same sentence in the review document and in the UI — one place cannot say "restorable" while another says no.
    func restorePurchases() async -> Result<PopopxRestoreOutcome, PopopxBadgeCreditsError> {
        do {
            try await AppStore.sync()
        } catch {
            // The user cancelling on Apple's sign-in/confirmation panel is the normal case and must not be reported as a fault.
            // Not checking `SKError.Code`: that family of codes has no "cancelled" case (`.overlayCancelled` is a different matter),
            // and guessing a name would rot this path at compile time.
            if error is CancellationError { return .success(.cancelled) }
            return .failure(.purchaseFailed(error.localizedDescription))
        }
        var subscriptionReceipts: [PopopxStoreReceipt] = []
        var giftReceipts: [PopopxStoreReceipt] = []
        for receipt in await currentEntitlementReceipts(includeUnfinished: true) {
            guard let sku = receipt.sku else { continue }
            switch sku.kind {
            case .subscription: subscriptionReceipts.append(receipt)
            // Both gift-card families mint a *card*, and this leg is their only repair for "Apple charged, the process died before the vault wrote":
            // a consumable leaves both sequences the moment it is booked and finished, so a card already in hand cannot be minted twice here.
            case .giftCard, .creditGiftCard: giftReceipts.append(receipt)
            // One-off duration packs (non-renewing subscriptions) do not enter the restore flow: Apple never makes a "restore non-renewing" promise,
            // and the duration it lit is already in this device's badge record; redelivering it once would give away a second block of duration.
            case .oneTimePass, .credits: break   // A credit top-up is a wallet number, not an item: `apply` books and finishes it in one step, and it is spent as soon as it lands, so there is nothing here to hand back.
            }
        }
        for receipt in subscriptionReceipts + giftReceipts { await notifyDeliveries(receipt) }
        if !subscriptionReceipts.isEmpty { return .success(.restored(subscriptionReceipts.count)) }
        return .success(.nothingToRestore)
    }

    /// Whether some SKU was ever bought (for hints like "N gift cards already purchased").
    /// Goes through `Transaction.all` rather than `currentEntitlements`: a consumable is finished right after purchase,
    /// so it is never visible in `currentEntitlements`, and using that to judge "ever bought" yields false negatives.
    func hasPurchased(_ sku: PopopxNodeBadgeSku) async -> Bool {
        for await verification in Transaction.all {
            guard case let .verified(live) = verification, live.productID == sku.productId else { continue }
            return true
        }
        return false
    }

    // MARK: Verification

    /// The single verification entry: unverified always returns nil.
    /// `verification.unsafePayloadValue` appears exactly zero times in this file — that name means "unconfirmed".
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

    /// The dedup table. When cold start rebuilds entitlements it has to be able to push back into the processed set, otherwise the same transaction is delivered again by updates.
    func markSettled(_ transactionId: UInt64) { settledTransactionIds.insert(transactionId) }
}

// // MARK: - Restore result

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
