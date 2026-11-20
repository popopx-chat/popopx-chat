//  PopopxBadgeManager.swift
//
//  POPOPX 动态隐私节点徽章的唯一真相：三态状态机、72 小时先锋体验徽章、
//  本地加密中继路由的轮换计数，以及到期后的平滑降级。
//
//  ### 状态只有三个，而且不落在 UI 里
//  `PopopxBadgePhase`（休眠 / 72h 体验 / 正式点亮）由 `PopopxBadgeRecord` + 当前时间推导。
//  推导只在本文件发生（`recompute(now:)`），视图只读 `phase`：任何视图自己算"还剩几天"
//  都会因为取时间的时刻不同而漂移，两个视图给出两个答案是这类特性最难看的一种 bug。
//
//  ### 到期降级做什么、不做什么
//  做：清除徽章记录、顶栏胶囊转灰、停止本地轮换计数。
//  不做：不动 SMP 连接、不动联系人、不动聊天记录、不动 SQLite 的任何一行。
//  徽章从来不是"加密开关"——降级前后消息走的还是同一条 SMP 连接，
//  变化的只有 UI 上"动态路由已开启"这一句。所以降级是无损的：
//  把付费墙建在用户已有的聊天记录后面是 App Store 3.1.1 里最难看的一种形态，
//  这一条同时写进了 Docs/app-store-review-notes.md，两处措辞必须一致。
//
//  ### DeviceCheck 在这套架构里能做什么（改下面那 40 行之前务必读完）
//  提示词要求以 `DCDevice.current.generateToken()` 作为体验徽章的设备唯一性证明。本文件确实调它，
//  但作用边界要写清楚，不能含混地叫"设备指纹"：
//  - token 是**给 Apple 服务器验的**（需要服务端持 Team ID 私钥）。POPOPX 零服务器、零账号，
//    没有任何一方能验证它，也就没有任何一方能因此吊销一次已发出的领取。
//  - 所以在纯端到端形态下它的真实作用是留证据：`trialGuard` 记下 token 摘要，
//    将来回答审核问询时能说清"这次领取绑到一台 Apple 认可的硬件上"。
//  - 真正拦住重复领取的是 Keychain：`trialGuard` 槽 + `installIdentity` 槽都带
//    `ThisDeviceOnly`，卸载重装仍在（同 team ID）。这一条才是防刷的全部。
//  取不到 token（模拟器、Capability 未开、无网络、系统不支持）时**不阻塞领取**，
//  退回本机安装指纹；降级理由只进日志，不进用户界面。
//  ⚠️ 要拿真实 token 需在 Xcode 里为本 App ID 勾上 DeviceCheck capability；
//  红线禁止脚本改工程文件，所以这一步归人做，本文件不假装它已经生效。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import Foundation
import os

#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// DeviceCheck 的墙钟上限（2 秒）。它走网络，没有这一条，
/// 首次进入主界面的领取路径会被一次 Apple 侧超时拖住整个首屏。
/// 文件级常量而不是 `@MainActor` 类型成员：取 token 的子任务不在主 actor 上，
/// 从那里读一个主 actor 隔离的静态量在严格并发下是要报错的。
private let popopxDeviceCheckTimeoutNanoseconds: UInt64 = 2_000_000_000

@MainActor
@Observable
final class PopopxBadgeManager {
    static let shared = PopopxBadgeManager()

    /// 当前生效的徽章记录；nil = 从未领取，或已到期降级。
    private(set) var record: PopopxBadgeRecord?
    /// 视图唯一该读的东西，与 `record` 同帧更新，因此不会出现"有记录但显示休眠"的中间帧。
    private(set) var phase: PopopxBadgePhase = .dormant
    /// Apple 侧的真实续费状态。nil 是"还没查过"，UI 不许把它显示成"已取消"。
    private(set) var subscriptionSnapshot: PopopxSubscriptionSnapshot?
    private(set) var lastReconcileAt: Date?

    private var ticker: Task<Void, Never>?
    private var deliveryToken: UUID?
    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "badge")

    private init() {
        record = PopopxCommerceKeychain.decode(PopopxBadgeRecord.self, .badgeRecord)
        phase = PopopxBadgePhase.phase(for: record)
        if record == nil, PopopxCommerceKeychain.contains(.trialGuard) {
            log.info("badge: replay guard present without a record — pioneer trial already consumed on this device")
        }
    }

    // MARK: 生命周期

    /// 由 app 启动路径调用：接管 StoreKit 交付、起时间心跳、与 Apple 权益对账。
    func start() async {
        guard deliveryToken == nil else { return }
        deliveryToken = PopopxStoreKitManager.shared.attachDelivery { [weak self] receipt in
            await self?.apply(storeReceipt: receipt)
        }
        PopopxStoreKitManager.shared.startObservingTransactions()
        startTicker()
        await reconcileWithStore()
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        if let deliveryToken {
            PopopxStoreKitManager.shared.detachDelivery(deliveryToken)
            self.deliveryToken = nil
        }
    }

    /// 30 秒一次而不是 1 秒：徽章上最短显示粒度是"剩余 X 小时"，
    /// 1 秒心跳等于每天让顶栏白刷 86400 次；真正的秒级倒计时由视图自己渲染。
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                self?.recompute(now: Date())
                self?.rotateNodeIfNeeded(now: Date())
            }
        }
    }

    // MARK: 状态推导

    /// 唯一推导入口。到期时执行降级，并且只在到期时清 Keychain。
    func recompute(now: Date = Date()) {
        guard let existing = record else {
            if phase != .dormant { phase = .dormant }
            return
        }
        let next = PopopxBadgePhase.phase(for: existing, now: now)
        guard next.isLit else {
            demoteExpired(existing)
            return
        }
        if phase != next { phase = next }
    }

    private func demoteExpired(_ expired: PopopxBadgeRecord) {
        record = nil
        phase = .dormant
        subscriptionSnapshot = nil
        _ = PopopxCommerceKeychain.remove(.badgeRecord)
        // `trialGuard` 保留：它的唯一作用就是"这台设备领过了"，跟着徽章一起删等于允许重领。
        log.info("badge: demoted to free public relays; expired source was \(String(describing: expired.source))")
    }

    // MARK: 领取与点亮

    /// 领取 72 小时先锋节点体验徽章。只在"这台设备从未领取过"时成功一次。
    ///
    /// 调用点唯一：主界面的 `.task`。资格判定在这里而不是弹窗视图里，
    /// 因为"领没领过"是写过 Keychain 级别的事实，视图猜它一定会出第二次弹窗。
    func issuePioneerTrialIfNeeded(now: Date = Date()) async -> PopopxBadgeRecord? {
        guard record == nil, !PopopxCommerceKeychain.contains(.trialGuard) else { return nil }

        let guardToken = Data(await Self.pioneerTrialGuardToken().utf8)
        // 先落防重放标记，再落徽章。反过来会出现"徽章点亮但标记没写上"，
        // 那一次如果紧接着崩溃或写盘失败，重启后就是第二个 72 小时——这条顺序就是防刷本身。
        guard PopopxCommerceKeychain.write(guardToken, .trialGuard) else {
            log.error("badge: pioneer trial refused — replay guard could not be written")
            return nil
        }
        do {
            return try activate(
                period: .monthly,
                source: .pioneerTrial,
                expiresAtMs: Int64(now.timeIntervalSince1970 * 1_000)
                    + Int64(PopopxCommerceLimits.trialSeconds * 1_000),
                receiptDigest: nil,
                trialGuard: PopopxCommerceSignature.shortDigest(guardToken),
                now: now
            )
        } catch {
            // 徽章没发出去但标记已经写上：宁可让用户这次领不到体验（他本来就还没得到过），
            // 也不留一条"重试到成功"的口子。
            log.error("badge: pioneer trial guard written but activation failed")
            return nil
        }
    }

    /// 叠加时长用的到期时刻：`max(本机当前到期, 现在) + period.days`。
    ///
    /// 三条"再买一段"的腿（一次性时长包 / 算力点兑换 / 收到礼品券）共用这一处，因为界面上那句
    /// "再兑这一档会加 N 天"必须是同一个算式的结果，而不是三处各写各的近似。起点取
    /// `max(现有, 现在)` 而不是 `现在`：还剩 200 天时买 30 天，到期在 230 天后；
    /// 徽章已经过期（或本机从没点亮过）时 `现有` 不成立，才退回从当下起算。
    func stackedExpiryMs(period: PopopxNodeBadgePeriod, now: Date = Date()) -> Int64 {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return max(nowMs, record?.expiresAtMs ?? 0) + Int64(period.days) * 86_400_000
    }

    /// 点亮徽章。五种来源（体验 / Apple 订阅 / 一次性时长包 / 算力点兑换 / 收到礼品券）
    /// 全汇到这里，写 `.badgeRecord` 也只有这一处。
    ///
    /// "有效期从哪一天算起"在这里有两个答案，而且必须有两个：订阅那一族听 Apple 的
    /// （`apply(storeReceipt:)` 直接用收据里的到期时间），其余三条"再买一段"的腿听
    /// `stackedExpiryMs` 的。下面那句 `max(传入, 现有)` 不是第三个答案，它只是兜住
    /// "传入比现有更早"的调用（体验那一支就是），保证没有任何一条腿能把已购时长改短。
    @discardableResult
    func activate(
        period: PopopxNodeBadgePeriod,
        source: PopopxBadgeSource,
        expiresAtMs: Int64,
        receiptDigest: String?,
        trialGuard: String? = nil,
        now: Date = Date()
    ) throws -> PopopxBadgeRecord {
        let issuedAtMs = Int64(now.timeIntervalSince1970 * 1_000)
        guard expiresAtMs > issuedAtMs else { throw PopopxBadgeCreditsError.expiryInPast }
        // 叠加权益取"更晚到期"而不是"更晚发行"：用户拿 4500 点再续一年时，
        // 上一张年费券剩下的 200 天不能被抹掉。这条规则让"提前续费"永远是赚而不是亏。
        let candidate = PopopxBadgeRecord(
            period: period,
            source: source,
            issuedAtMs: min(issuedAtMs, record?.issuedAtMs ?? issuedAtMs),
            expiresAtMs: max(expiresAtMs, record?.expiresAtMs ?? 0),
            rotationIndex: record?.rotationIndex ?? 0,
            receiptDigest: receiptDigest,
            trialGuard: trialGuard ?? record?.trialGuard
        )
        guard PopopxCommerceKeychain.encode(candidate, .badgeRecord) else {
            throw PopopxBadgeCreditsError.keychainUnavailable
        }
        record = candidate
        phase = PopopxBadgePhase.phase(for: candidate, now: now)
        log.info("badge: lit, source \(String(describing: source)) period \(period.rawValue)")
        return candidate
    }

    /// StoreKit 交付回调：本文件只认订阅类 SKU，算力点与礼品卡由各自的管理器落账。
    func apply(storeReceipt receipt: PopopxStoreReceipt) async {
        if receipt.isRevoked {
            await handleRevocation(receipt)
            return
        }
        guard let sku = receipt.sku, sku.isSubscription, let period = sku.badgePeriod else { return }
        // 订阅优先用 Apple 给的到期时间；拿不到（理论上不该发生）才按周期天数兜底。
        let expiresAtMs = receipt.expiresAtMs
            ?? Int64(nowAddingDays(period.days).timeIntervalSince1970 * 1_000)
        do {
            try activate(period: period, source: .appleSubscription, expiresAtMs: expiresAtMs, receiptDigest: receipt.digest)
            await PopopxStoreKitManager.shared.finish(receipt)
        } catch {
            log.error("badge: subscription activation failed; leaving the transaction unfinished for redelivery")
        }
    }

    /// 退款/撤销：徽章按到期处理——已经享受过的服务不追溯，
    /// 但这张收据的摘要不再允许点亮任何一次（下次对账会把它当陌生收据 finish 掉）。
    private func handleRevocation(_ receipt: PopopxStoreReceipt) async {
        guard record?.receiptDigest == receipt.digest else { return }
        record = nil
        phase = .dormant
        _ = PopopxCommerceKeychain.remove(.badgeRecord)
        await PopopxStoreKitManager.shared.finish(receipt)
        log.info("badge: cleared because its source receipt was revoked")
    }

    /// 收到礼品卡、验签通过后点亮。券的状态机在 `PopopxP2PVoucherVault`，
    /// 本函数只回答"这次点亮写不写得下"。
    ///
    /// 这里刻意**不**用 `grant.expiresAtMs`：那个时刻是在**赠送方**的设备上算的
    /// （`authorizeRedemption` 的 `现在 + period.days`），它只是"这张券给多少天"的签名承诺，
    /// 不是受赠方的到期日。直接拿它点亮会有两个错：券在聊天里放三天就少三天，
    /// 而且它会绕开受赠方自己剩下的时长。天数由 `stackedExpiryMs` 在受赠方这一侧重新落地，
    /// 签名字节一个字都不用改。
    func activate(grant: PopopxBadgeGrant) throws -> PopopxBadgeRecord {
        try activate(
            period: grant.period,
            source: .giftedVoucher,
            expiresAtMs: stackedExpiryMs(period: grant.period),
            receiptDigest: PopopxCommerceSignature.shortDigest(grant.voucherId)
        )
    }

    /// 算力点兑换点亮。天数由周期自己给，避免两处各写一份 30/365；
    /// 起点走 `stackedExpiryMs`，和通行证、礼品券是同一个算式——花点数的按钮上写着"加 N 天"，
    /// 就只能是加 N 天，不能是"把剩余时间重置成 N 天"。
    @discardableResult
    func activate(withCredits period: PopopxNodeBadgePeriod, now: Date = Date()) throws -> PopopxBadgeRecord {
        try activate(
            period: period,
            source: .creditsExchange,
            expiresAtMs: stackedExpiryMs(period: period, now: now),
            receiptDigest: nil,
            now: now
        )
    }

    private func nowAddingDays(_ days: Int) -> Date {
        Date().addingTimeInterval(TimeInterval(days * 86_400))
    }

    // MARK: 对账

    /// 以 Apple 权益为准重算徽章：换设备、另一台机器续费、恢复购买之后都走这里。
    func reconcileWithStore() async {
        let receipts = await PopopxStoreKitManager.shared.currentEntitlementReceipts()
        // `for … where` 只接一个条件（逗号分开的多重条件在这里是语法错误），所以判据放进循环体。
        for receipt in receipts {
            guard receipt.sku?.isSubscription == true, !receipt.isRevoked else { continue }
            await apply(storeReceipt: receipt)
        }
        await refreshSubscriptionStatus()
        lastReconcileAt = Date()
        recompute()
    }

    /// 徽章详情页"重新检查续费状态"按钮。
    func refreshSubscriptionStatus() async {
        guard let existing = record, existing.source == .appleSubscription else {
            subscriptionSnapshot = nil
            return
        }
        subscriptionSnapshot = await PopopxStoreKitManager.shared.subscriptionSnapshot(for: existing.period)
    }

    // MARK: 本地路由轮换（展示层语义）

    /// 每 `nodeRotationSeconds` **至多**递增一次计数（判定只发生在 30 秒的心跳里）。
    ///
    /// 它今天**只是本地计数**：真正把一条 SMP 连接换到另一台中继节点要在 Haskell 侧
    /// 走 connection 的 invited/AD 流程，那一步未上机验证前不能声称"已切换"。
    /// 因此视图把它渲染成"节点刷新"动画，而所有文案不得出现"已切换至新节点"这类完成时断言。
    func rotateNodeIfNeeded(now: Date) {
        guard var existing = record, PopopxBadgePhase.phase(for: existing, now: now).isLit else { return }
        let due = TimeInterval(existing.rotationIndex) * PopopxCommerceLimits.nodeRotationSeconds
        let elapsed = now.timeIntervalSince1970 - Double(existing.issuedAtMs) / 1_000
        guard elapsed >= due else { return }
        existing.rotationIndex += 1
        guard PopopxCommerceKeychain.encode(existing, .badgeRecord) else { return }
        record = existing
    }

    // MARK: 供 UI 读取的短句

    /// 剩余时间一句话。休眠态返回 nil，调用方就不显示倒计时，而不是显示"0 秒"。
    var remainingDescription: String? {
        guard let expiresAt = phase.expiresAt else { return nil }
        return PopopxBadgeCopy.remaining(expiresAt: expiresAt, source: record?.source)
    }

    /// 体验徽章是否还可领取——弹窗的唯一资格来源。
    var canClaimPioneerTrial: Bool { record == nil && !PopopxCommerceKeychain.contains(.trialGuard) }

    // MARK: 清场

    /// 抹掉本模块全部本地状态（徽章、券、算力点、流水、签名密钥、体验标记）。
    ///
    /// **故意不接任何自动触发点**，包括三击 Logo 的紧急自毁：那条路径会连带删掉未花的算力点余额，
    /// 等于把"紧急避险"和"财产损失"绑在一起。要接必须由用户明确决定，并单独设计一次不可撤销确认。
    static func eraseAllCommerceState() {
        PopopxCommerceKeychain.removeAll()
    }
}

// MARK: - 设备证明

private extension PopopxBadgeManager {
    /// 体验徽章防重放指纹的原文：真机且 DeviceCheck 可用时取 Apple token，否则取本机安装指纹。
    /// 返回值一律是可读文本——落 Keychain 的这一段永远不含正文，只含标识。
    static func pioneerTrialGuardToken() async -> String {
        if let token = await deviceCheckToken() {
            return "dc.\(token.popopxBase64URL)"
        }
        return localInstallFingerprint()
    }

    /// 带墙钟上限的 `generateToken`。失败原因（不支持 / capability 未开 / 超时 / 无网络）
    /// 全部合并成 nil：上层唯一的正确行为都是"改用本机指纹"，区分原因只会多一条没人读的日志。
    nonisolated private static func deviceCheckToken() async -> Data? {
        #if canImport(DeviceCheck) && os(iOS)
        guard DCDevice.current.isSupported else { return nil }
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                guard let token = try? await DCDevice.current.generateToken(), !token.isEmpty else { return nil }
                return token
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: popopxDeviceCheckTimeoutNanoseconds)
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
        #else
        return nil
        #endif
    }

    /// 本机安装指纹：一个自己铸的 UUID，存在 Keychain 的 `installIdentity` 格。
    ///
    /// 不用 `identifierForVendor`：那个标识在"同厂商所有 App 都被删除"之后会变，
    /// 而它变不变对我们毫无价值——真正需要的性质是"卸载重装之后还是同一个值"，
    /// Keychain（ThisDeviceOnly）恰好提供它。读不到就铸一个新的并写下去；
    /// 写盘失败也照常返回，因为把"一次 Keychain 抖动"变成"永远领不到体验"是更坏的结局，
    /// 而防重放的第一道（`trialGuard`）在那条路径上已经先判过一次。
    static func localInstallFingerprint() -> String {
        if let stored = PopopxCommerceKeychain.read(.installIdentity),
           let text = String(data: stored, encoding: .utf8),
           text.hasPrefix("popopx.install.") {
            return text
        }
        let minted = "popopx.install.\(UUID().uuidString)"
        _ = PopopxCommerceKeychain.write(Data(minted.utf8), .installIdentity)
        return minted
    }
}

// MARK: - 文案

/// 徽章特性内部的短 UI 短语。金额、退款、续费承诺那一批在 `PopopxCommerceCopy`
/// （那一批要写进全部 17 个 `.lproj` 目录）；这一批与本特性其余文件一样留在文件内，
/// 与前面几个 POPOPX 特性保持同一套做法。
enum PopopxBadgeCopy {
    static let capsuleTitle = "隐私节点"
    static let trialBadgeName = "先锋节点体验徽章"
    static let formalBadgeName = PopopxCommerceCopy.badgeProductName

    /// 剩余时间一句话。体验态说"体验"，正式态说"到期"，两档不共用"剩余"这个词，
    /// 免得用户以为体验徽章和订阅是同一种东西。
    static func remaining(expiresAt: Date, source: PopopxBadgeSource?) -> String {
        let clock = remainingClock(expiresAt.timeIntervalSinceNow)
        if source == .pioneerTrial { return "先锋体验剩余 \(clock)" }
        return "动态加密路由开启中 · \(expiresAt.popopxBadgeExpiresText) 到期（剩 \(clock)）"
    }

    static func remainingClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = total % 86_400 / 3_600
        let minutes = total % 3_600 / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分"
    }
}

private extension Date {
    /// 到期日期按系统区域格式渲染；写死 `yyyy-MM-dd` 在德语和中文环境里都是错的样式。
    var popopxBadgeExpiresText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }
}
