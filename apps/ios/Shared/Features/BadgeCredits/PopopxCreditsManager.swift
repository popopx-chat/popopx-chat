//  PopopxCreditsManager.swift
//
//  POPOPX 算力点（Compute Credits）：钱包、流水、防重放，以及六个消费场景。
//
//  ### 余额是真账，流水是历史窗口
//  `PopopxCreditsWallet.balance` 是花钱时唯一依据的数；`PopopxCreditsEntry` 那条队列有上限
//  （`maximumLedgerEntries` = 240），满了就丢最旧的。于是"用流水求和校验余额"只在
//  队列没满时成立。`reconcileOnLoad()` 按这条区分处理：
//  - 队列不满（历史完整）而对不上 → 以流水求和为准改写余额，这是唯一能自愈的情形；
//  - 队列已满而对不上 → 只置 `needsReconcile`，绝不改写余额。
//  静默把一段被截断的历史当成真账来"修正"余额，是最容易把用户余额清零的那种自动修复。
//
//  ### 记账写入的顺序（这不是风格问题）
//  收入方向：判重放 → 改余额并落盘 → 记流水 → 写防重放标记 → `finish` 交易。
//  支出方向：判余额 → 改余额并落盘 → 记流水。
//  共同点是把"钱的变化"放在第一步落盘、把"标记/历史"放在后面，因为两头的坏情况不对称：
//  标记先落而余额没落 = 交易被 finish 或用户重试时判成"已入账"，钱永久丢了；
//  余额先落而标记没落 = 重试时多入一次账，但交易仍未 finish，StoreKit 会再投一次，
//  而那一条路径上的判重是在 `hasCredited` 上——它此时还没写。所以真正的护栏是
//  "未 finish 的交易会重投"+"主 actor 串行"，因此标记必须写在余额之后、`finish` 之前，
//  并且这个类的所有入口都在 `@MainActor` 上（不存在并发重入）。
//
//  ### 严格等额，零赠送
//  充值包入账只认 `PopopxNodeBadgeSku.creditedAmount`（100 / 500 / 2000），
//  没有任何倍率、首日加成、"额外赠送"。国内促销条款与苹果 3.1.1 的等额性两头都踩在同一处，
//  所以这条是硬约束而不是文案偏好；`PopopxCommerceCopy.noGiftBackStatement` 是它在 UI 上的唯一表述。
//
//  ### 随机金额红包不存在
//  红包只允许固定面额（`PopopxCommerceLimits.redPacketAmounts`）与**均分**，
//  领取时按 `amountPerRecipient` 逐份入账。随机金额=带赌博属性，那一档在本特性里从类型层面就没有入口：
//  `sendRedPacket` 不收金额参数以外的自由度，面额判据在 `PopopxRedPacketPayload` 解析端还会再判一次。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import Foundation
import os

@MainActor
@Observable
final class PopopxCreditsManager {
    static let shared = PopopxCreditsManager()

    private(set) var wallet = PopopxCreditsWallet(version: PopopxCreditsWallet.currentVersion, balance: 0, updatedAtMs: 0, needsReconcile: false)
    private(set) var ledger: [PopopxCreditsEntry] = []
    private(set) var replay = PopopxReplayGuard()
    /// 发送方持有的未领完红包（用于校验 ACK、退款）。
    private(set) var pendingPackets: [PopopxPendingRedPacket] = []
    private(set) var channelTickets: [PopopxChannelSubscriptionTicket] = []
    private(set) var profileReceipts: [PopopxProfileUnlockReceipt] = []
    private(set) var ownedCosmetics: Set<PopopxCosmetic> = []
    private(set) var lastReconcileAt: Date?

    private var loaded = false
    private var deliveryToken: UUID?
    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "credits")

    private init() {}

    var balance: Int { wallet.balance }

    // MARK: 载入

    /// 从 Keychain 恢复全部状态。幂等，可在任何入口调用。
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        wallet = PopopxCommerceKeychain.decode(PopopxCreditsWallet.self, .wallet)
            ?? PopopxCreditsWallet(version: PopopxCreditsWallet.currentVersion, balance: 0, updatedAtMs: Int64(Date().timeIntervalSince1970 * 1_000), needsReconcile: false)
        ledger = PopopxCommerceKeychain.decode([PopopxCreditsEntry].self, .ledger) ?? []
        replay = PopopxCommerceKeychain.decode(PopopxReplayGuard.self, .replayGuard) ?? PopopxReplayGuard()
        pendingPackets = PopopxCommerceKeychain.decode([PopopxPendingRedPacket].self, .pendingPackets) ?? []
        channelTickets = PopopxCommerceKeychain.decode([PopopxChannelSubscriptionTicket].self, .channelTickets) ?? []
        profileReceipts = PopopxCommerceKeychain.decode([PopopxProfileUnlockReceipt].self, .profileReceipts) ?? []
        ownedCosmetics = Set(PopopxCommerceKeychain.decode([PopopxCosmetic].self, .cosmetics) ?? [])
        reconcileOnLoad()
    }

    /// 由 app 启动路径调用：接住充值包与礼品卡收据的交付。
    func start() async {
        guard deliveryToken == nil else { return }
        loadIfNeeded()
        deliveryToken = PopopxStoreKitManager.shared.attachDelivery { [weak self] receipt in
            await self?.apply(storeReceipt: receipt)
        }
        _ = await refundSettledPackets(now: Date())
    }

    func stop() {
        if let deliveryToken {
            PopopxStoreKitManager.shared.detachDelivery(deliveryToken)
            self.deliveryToken = nil
        }
    }

    // MARK: 对账

    private func reconcileOnLoad() {
        guard ledger.count < PopopxCommerceLimits.maximumLedgerEntries else { return }
        let sum = ledger.reduce(0) { $0 + $1.amount }
        guard sum != wallet.balance else { return }
        // 先取差值再改写：写在后面就永远打印 0，那行日志等于自毁证据。
        let delta = sum - wallet.balance
        // 历史完整却对不上：以流水为准，并把这一条写在日志里（不是屏幕上）。
        // 走到这里通常意味着上一次写盘被中断，或者用户装过修改余额的工具。
        wallet.balance = max(0, min(sum, PopopxCommerceLimits.maximumCreditBalance))
        wallet.needsReconcile = false
        log.info("credits: balance rebuilt from a complete ledger; delta was \(delta)")
        _ = saveWallet()
    }

    /// 详情页的"重新检查"：余额与流水对不上且历史被截断时才置标记。
    func verifyLedgerConsistency() {
        loadIfNeeded()
        guard ledger.count >= PopopxCommerceLimits.maximumLedgerEntries else { return }
        wallet.needsReconcile = true
        lastReconcileAt = Date()
        _ = saveWallet()
    }

    // MARK: 记账原语

    /// 收入。`amount` 必须为正；上限判据在这里，任何调用方都绕不过去。
    @discardableResult
    private func credit(_ amount: Int, kind: PopopxCreditsEntryKind, note: String, entryId: String? = nil) throws -> PopopxCreditsEntry {
        loadIfNeeded()
        guard amount > 0 else { throw PopopxBadgeCreditsError.signalRejected }
        guard wallet.balance + amount <= PopopxCommerceLimits.maximumCreditBalance else {
            throw PopopxBadgeCreditsError.creditBalanceTooHigh(maximum: PopopxCommerceLimits.maximumCreditBalance)
        }
        wallet.balance += amount
        wallet.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        wallet.needsReconcile = false
        guard saveWallet() else {
            wallet.balance -= amount
            throw PopopxBadgeCreditsError.keychainUnavailable
        }
        return appendEntry(
            PopopxCreditsEntry(
                id: entryId ?? UUID().uuidString.lowercased(),
                amount: amount,
                kind: kind,
                note: note,
                timestampMs: wallet.updatedAtMs,
                balanceAfter: wallet.balance
            )
        )
    }

    /// 支出。`amount` 传正数，符号由 `kind.sign` 决定，所以一笔钱的正负在工程里只有一个来源。
    @discardableResult
    private func debit(_ amount: Int, kind: PopopxCreditsEntryKind, note: String, entryId: String? = nil) throws -> PopopxCreditsEntry {
        loadIfNeeded()
        guard amount > 0, let sign = kind.sign, sign < 0 else { throw PopopxBadgeCreditsError.signalRejected }
        guard wallet.balance >= amount else {
            throw PopopxBadgeCreditsError.insufficientCredits(balance: wallet.balance, required: amount)
        }
        wallet.balance -= amount
        wallet.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        guard saveWallet() else {
            wallet.balance += amount
            throw PopopxBadgeCreditsError.keychainUnavailable
        }
        return appendEntry(
            PopopxCreditsEntry(
                id: entryId ?? UUID().uuidString.lowercased(),
                amount: sign * amount,
                kind: kind,
                note: note,
                timestampMs: wallet.updatedAtMs,
                balanceAfter: wallet.balance
            )
        )
    }

    @discardableResult
    private func appendEntry(_ entry: PopopxCreditsEntry) -> PopopxCreditsEntry {
        ledger.append(entry)
        if ledger.count > PopopxCommerceLimits.maximumLedgerEntries {
            ledger.removeFirst(ledger.count - PopopxCommerceLimits.maximumLedgerEntries)
        }
        if !saveLedger() { log.error("credits: ledger persistence failed; balance stays authoritative") }
        return entry
    }

    private func saveWallet() -> Bool { PopopxCommerceKeychain.encode(wallet, .wallet) }
    private func saveLedger() -> Bool { PopopxCommerceKeychain.encode(ledger, .ledger) }
    private func saveReplay() { _ = PopopxCommerceKeychain.encode(replay, .replayGuard) }
    private func savePackets() { _ = PopopxCommerceKeychain.encode(pendingPackets, .pendingPackets) }
    private func saveTickets() { _ = PopopxCommerceKeychain.encode(channelTickets, .channelTickets) }
    private func saveProfileReceipts() { _ = PopopxCommerceKeychain.encode(profileReceipts, .profileReceipts) }
    private func saveCosmetics() { _ = PopopxCommerceKeychain.encode(Array(ownedCosmetics), .cosmetics) }

    // MARK: 收据入账（StoreKit 交付）

    /// 只处理充值包与礼品卡两类 SKU；订阅类由 `PopopxBadgeManager` 负责，这里一次都不碰徽章。
    func apply(storeReceipt receipt: PopopxStoreReceipt) async {
        loadIfNeeded()
        guard let sku = receipt.sku else { return }
        if receipt.isRevoked {
            // 退款的算力点必须追溯（那是没花掉的余额）；已经花掉的部分不追回，
            // 记录一条 `adjustment` 说明原因，而不是悄悄改数字。
            await clawBack(receipt)
            return
        }
        guard !replay.hasCredited(transactionHash: receipt.digest) else {
            await PopopxStoreKitManager.shared.finish(receipt)
            return
        }
        switch sku.kind {
        case let .credits(amount):
            // 失败就不 finish：`Transaction.unfinished` 会重投，钱还在 Apple 手里，
            // 这比"扣了钱什么都没得到"或"什么都没得到但交易已结"都体面。
            do {
                _ = try credit(amount, kind: .storePurchase, note: PopopxCreditsCopy.purchasedPack(amount), entryId: receipt.digest)
            } catch {
                log.error("credits: pack could not be credited; leaving the transaction unfinished")
                return
            }
        case let .giftCard(period):
            // 礼品卡是"付钱买券"，钱由 Apple 收，本端不碰余额——这里绝不做任何 debit。
            // 铸券失败与充值包失败同理：不 finish，等重投。
            do {
                _ = try await PopopxP2PVoucherVault.shared.mint(period: period, quantity: 1, source: .receipt(receipt))
            } catch {
                log.error("credits: gift voucher minting failed; leaving the transaction unfinished")
                return
            }
        case .subscription:
            // 订阅由 `PopopxBadgeManager` 的交付回调点亮。两处都挂同一个流，
            // 各自只认自己那一族 SKU，所以一笔收据只会被一个管理者落账。
            return
        }
        replay.credit(transactionHash: receipt.digest)
        saveReplay()
        await PopopxStoreKitManager.shared.finish(receipt)
    }

    /// 退款追溯：从余额里扣回那笔入账，扣不完就扣到零，并留一条 `adjustment`。
    private func clawBack(_ receipt: PopopxStoreReceipt) async {
        guard let sku = receipt.sku, let amount = sku.creditedAmount,
              ledger.contains(where: { $0.id == receipt.digest })
        else {
            await PopopxStoreKitManager.shared.finish(receipt)
            return
        }
        let clawed = min(amount, wallet.balance)
        wallet.balance -= clawed
        wallet.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        _ = saveWallet()
        _ = appendEntry(
            PopopxCreditsEntry(
                id: "refund.\(receipt.digest)",
                amount: -clawed,
                kind: .adjustment,
                note: PopopxCreditsCopy.refundClawback(shortfall: amount - clawed),
                timestampMs: wallet.updatedAtMs,
                balanceAfter: wallet.balance
            )
        )
        await PopopxStoreKitManager.shared.finish(receipt)
        log.info("credits: clawed back a refunded pack")
    }

    // MARK: 场景一 · 算力点兑换徽章

    /// 600 点 / 30 天，4500 点 / 365 天。先扣点、后点亮：
    /// 点亮失败时点数原样退回，避免"点花了、徽章没亮"这种两头不认的状态。
    func exchangeCreditsForBadge(period: PopopxNodeBadgePeriod) throws {
        loadIfNeeded()
        let entry = try debit(period.creditsCost, kind: .badgeExchange, note: PopopxCreditsCopy.badgeExchange(period))
        do {
            _ = try PopopxBadgeManager.shared.activate(withCredits: period)
        } catch {
            _ = try? credit(-entry.amount, kind: .adjustment, note: PopopxCreditsCopy.reversedExchange, entryId: "reverse.\(entry.id)")
            throw error
        }
    }

    // MARK: 场景二 · 算力点兑换礼品卡券

    /// 扣点成功后才铸券；铸券失败立刻退点。券的码由 `PopopxSilentSignalingRouter` 现铸，
    /// 本函数只负责"这张券值不值钱"。
    func exchangeCreditsForVoucher(period: PopopxNodeBadgePeriod, quantity: Int) async throws -> [PopopxNodeVoucher] {
        loadIfNeeded()
        let total = period.creditsCost * max(1, quantity)
        let entry = try debit(total, kind: .giftVoucherExchange, note: PopopxCreditsCopy.voucherExchange(period: period, quantity: quantity))
        do {
            let minted = try await PopopxP2PVoucherVault.shared.mint(period: period, quantity: quantity, source: .creditEntry(id: entry.id))
            return minted
        } catch {
            _ = try? credit(total, kind: .adjustment, note: PopopxCreditsCopy.reversedExchange, entryId: "reverse.\(entry.id)")
            throw error
        }
    }

    // MARK: 场景三 · 算力点红包（固定面额、均分）

    /// 发一个红包：一次扣全额，逐份领取时才真正落到对方账上，
    /// 本端留下 `PopopxPendingRedPacket` 用于对账与退款。
    ///
    /// `recipientCount` 是**均分份数**：`amount` 必须能被它整除，否则这份红包在类型层面就造不出来——
    /// 与其在领取时出现"最后一份多一块"的舍入，不如在发送时就拒绝这个组合。
    func sendRedPacket(amount: Int, recipientCount: Int, note: String) throws -> PopopxPendingRedPacket {
        loadIfNeeded()
        guard PopopxCommerceLimits.redPacketAmounts.contains(amount),
              amount <= PopopxCommerceLimits.maximumPacketAmount,
              recipientCount >= 1,
              recipientCount <= PopopxCommerceLimits.maximumPacketRecipients,
              amount % recipientCount == 0
        else { throw PopopxBadgeCreditsError.signalRejected }
        let perRecipient = amount / recipientCount
        let entry = try debit(amount, kind: .redPacketSent, note: PopopxCreditsCopy.packetSent(amount: amount, recipients: recipientCount))
        let packet = PopopxPendingRedPacket(
            packetId: entry.id,
            amount: amount,
            note: note,
            recipientCount: recipientCount,
            claimedCount: 0,
            createdAtMs: entry.timestampMs,
            amountPerRecipient: perRecipient,
            settled: false
        )
        pendingPackets.append(packet)
        savePackets()
        return packet
    }

    /// 领一份红包。防重放以 `packetId` 为准：同一条 ACK 重投、或对方重复推送，都只会入账一次。
    /// 领取方是"每个收件人各自领自己那一份"，所以这里记的是本设备的领取历史，不是全局份额。
    func claimRedPacket(packetId: String, amountPerRecipient: Int, note: String) throws -> Bool {
        loadIfNeeded()
        guard !replay.hasClaimed(packetId: packetId) else { return false }
        _ = try credit(amountPerRecipient, kind: .redPacketReceived, note: PopopxCreditsCopy.packetReceived(note: note), entryId: "claim.\(packetId)")
        replay.claim(packetId: packetId)
        saveReplay()
        return true
    }

    /// 本机是否已经拆开过这一份。气泡用它决定显示"拆开"还是"已领取"：
    /// 判据与 `claimRedPacket` 是同一条（重放保护那一份），视图自己记状态会在进程重启后退回"可拆"。
    func hasClaimed(packetId: String) -> Bool {
        loadIfNeeded()
        return replay.hasClaimed(packetId: packetId)
    }

    /// 这张礼品卡是否已在本机核销过。写在兑换成功的那一步（`PopopxSilentSignalingRouter` 收到 ACK 之后），
    /// 于是气泡能长期停在"已兑换"，也不会再对同一枚券发第二次请求——赠方那边有 `redeemed` 状态兜底，
    /// 但让对方替你挡掉一次无谓的往返不是这一层的办法。
    func markRedeemed(voucherId: String) {
        loadIfNeeded()
        guard !replay.hasRedeemed(voucherId: voucherId) else { return }
        replay.redeem(voucherId: voucherId)
        saveReplay()
    }

    func hasRedeemed(voucherId: String) -> Bool {
        loadIfNeeded()
        return replay.hasRedeemed(voucherId: voucherId)
    }

    /// 发送方视角的那一笔挂起单（气泡上的"已领 n/N 份"）。不是本机的单子返回 nil——
    /// 同一条 packetId 出现在别人的聊天里时，这里不该显示出任何份数。
    func pendingPacket(packetId: String) -> PopopxPendingRedPacket? {
        loadIfNeeded()
        return pendingPackets.first { $0.packetId == packetId }
    }

    /// 发送侧收到 `REDPACKET_CLAIMED` 回执时调用：只累加份数，不碰余额（钱在发送时已经扣掉了）。
    ///
    /// 群红包必须按成员去重：回执是一串可重放的文本，同一个人再发一条就会把 `claimedCount`
    /// 顶到份数以上，退款被算成 0——被坑的是发送方，而他没有任何办法察觉。
    /// 份数也一并夹在 `recipientCount`：超出的回执不改变任何金额，就不该改变任何账目显示。
    /// `memberKey` 为 nil（direct）时无从去重，那一侧由领取端自己的重放保护兜底。
    func recordClaim(packetId: String, memberKey: String? = nil) {
        loadIfNeeded()
        guard let index = pendingPackets.firstIndex(where: { $0.packetId == packetId }) else { return }
        var packet = pendingPackets[index]
        guard packet.claimedCount < packet.recipientCount else { return }
        if let memberKey {
            var keys = packet.claimKeys ?? []
            guard !keys.contains(memberKey) else { return }
            keys.append(memberKey)
            packet.claimKeys = keys
        }
        packet.claimedCount += 1
        pendingPackets[index] = packet
        savePackets()
    }

    /// 未领完的红包退款。两个触发点：**份数领满**，或**宽限期已过**（`claimGraceEndsAtMs`）。
    /// 差额必须退，否则发送方永远悬着一笔钱——那是这个特性里最容易变成投诉的一处。
    /// 但领满之前不能退：退了之后群里剩下的份额仍会被领走，那一份点数是谁也没出的。
    /// 群红包没人领、单份红包对方一直没上线，都走宽限期那一条。
    @discardableResult
    func refundSettledPackets(now: Date) async -> Int {
        loadIfNeeded()
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        var refunded = 0
        for index in pendingPackets.indices where !pendingPackets[index].settled {
            let packet = pendingPackets[index]
            guard packet.isFullyClaimed || nowMs >= packet.claimGraceEndsAtMs else { continue }
            let refundable = packet.refundableAmount
            guard refundable > 0 else { continue }
            pendingPackets[index].settled = true
            _ = try? credit(refundable, kind: .redPacketRefund, note: PopopxCreditsCopy.packetRefund(refundable), entryId: "refund.\(packet.packetId)")
            refunded += refundable
        }
        savePackets()
        if refunded > 0 { log.info("credits: refunded unclaimed red packet remainder") }
        return refunded
    }

    // MARK: 场景四 · 频道订阅

    /// 订阅一个频道：点数由频道主定价，有效期一格 `channelTicketSeconds`（30 天，与徽章月档同长，
    /// 免得用户在两处看到两种"一个月"）。
    ///
    /// 已有有效票时是**叠加**而不是替换：提前续费的人不该把没用完的天数白丢掉——点数已经扣了。
    /// 与徽章激活同一句话："取更晚到期"。
    /// `price == 0` 不进这里：那是"这个频道免费"，由调用方直接放行，扣 0 点只会留下一条假流水。
    /// `issuerPublicKeyBase64URL` 是这条卡片的签名公钥，原样存进票里：它是防冒充比对的那一半本机记录
    /// （判据在 `channelIssuerConflict`），不参与任何签名验证——签名的真伪在渲染侧已经判过了。
    func subscribeToChannel(channelId: String, channelTitle: String, price: Int,
                            issuerPublicKeyBase64URL: String) throws -> PopopxChannelSubscriptionTicket {
        loadIfNeeded()
        guard price >= 1, price <= PopopxCommerceLimits.maximumCreditsThreshold else { throw PopopxBadgeCreditsError.signalRejected }
        let entry = try debit(price, kind: .channelSubscription, note: PopopxCreditsCopy.channelSubscribed(channelTitle))
        let renewedFromMs = channelTickets.first { $0.channelId == channelId }?.expiresAtMs ?? 0
        let ticket = PopopxChannelSubscriptionTicket(
            channelId: channelId,
            channelTitle: channelTitle,
            price: price,
            paidAtMs: entry.timestampMs,
            expiresAtMs: max(entry.timestampMs, renewedFromMs) + Int64(PopopxCommerceLimits.channelTicketSeconds * 1_000),
            transactionId: entry.id,
            issuerPublicKeyBase64URL: issuerPublicKeyBase64URL.isEmpty ? nil : issuerPublicKeyBase64URL
        )
        channelTickets.removeAll { $0.channelId == channelId }
        channelTickets.append(ticket)
        saveTickets()
        return ticket
    }

    /// 这台设备在这个频道**付过一次钱**的发布者，与眼前这条卡片的签名公钥对不对得上。
    ///
    /// 为什么只能这样判：频道的消息在成员侧是 `CIDirection.channelRcv`，那一个档**不带** `GroupMember`
    /// （`ChatTypes.swift:4421-4422`，`groupMemberId` 对它是 nil，:4440-4442），所以"发这条的人是什么角色"
    /// 在 Swift 层没有任何可读的数；`ChatInfo.id` 又是本机行号（`"#"+groupId`，:3059），跨设备不通用，
    /// 把它签进卡片也只能签出一个对方设备上不存在的东西。核心侧没有可比的权威公钥——本模块的签名密钥
    /// 是 P256 的商业密钥，和 SMP 连接不是同一套钥匙。
    ///
    /// 于是这一条判据的实际覆盖面是诚实的：**已经付过一次的那个人**不会被第二把钥匙的卡片再烧一次点。
    /// 第一次付费之前无从比对（没有可比的那一份记录），那一个窗口要靠发布侧的角色闸
    /// （`sendChannelAccess`）+ 界面只把订阅按钮给验得过签名的卡片，剩下的是本模块记录在案的残留风险。
    /// 旧票没有记公钥，一律返回"不冲突"：不能因为升级前的账本缺字段就把人挡在外面。
    func channelIssuerConflict(channelId: String, issuerPublicKeyBase64URL: String) -> Bool {
        loadIfNeeded()
        guard let pinned = channelTickets.first(where: { $0.channelId == channelId })?.issuerPublicKeyBase64URL,
              !pinned.isEmpty, !issuerPublicKeyBase64URL.isEmpty
        else { return false }
        return pinned != issuerPublicKeyBase64URL
    }

    func ticket(forChannelId channelId: String) -> PopopxChannelSubscriptionTicket? {
        loadIfNeeded()
        return channelTickets.first { $0.channelId == channelId && $0.isValid(at: Date()) }
    }

    // MARK: 场景五 · 解锁受保护的资料卡

    func unlockProfile(profileId: String, chatId: Int64, itemId: Int64, price: Int) throws -> PopopxProfileUnlockReceipt {
        loadIfNeeded()
        guard price >= 1, price <= PopopxCommerceLimits.maximumCreditsThreshold else { throw PopopxBadgeCreditsError.signalRejected }
        guard !hasUnlocked(profileId: profileId, chatId: chatId, itemId: itemId) else {
            throw PopopxBadgeCreditsError.signalRejected
        }
        let entry = try debit(price, kind: .profileUnlock, note: PopopxCreditsCopy.profileUnlocked)
        let receipt = PopopxProfileUnlockReceipt(
            profileId: profileId,
            chatId: chatId,
            itemId: itemId,
            price: price,
            unlockedAtMs: entry.timestampMs,
            transactionId: entry.id
        )
        profileReceipts.append(receipt)
        saveProfileReceipts()
        return receipt
    }

    /// 三个字段一起判：资料卡可以转发、也可以在同一条会话里多次出现，
    /// 只按 `profileId` 判会让"在 A 会话解锁过"变成"B 会话也免费"。
    func hasUnlocked(profileId: String, chatId: Int64, itemId: Int64) -> Bool {
        loadIfNeeded()
        return profileReceipts.contains { $0.profileId == profileId && $0.chatId == chatId && $0.itemId == itemId }
    }

    // MARK: 场景六 · 高级兑换（扩展防窥窗 / 装饰）

    /// 20 点换 1 小时的扩展防窥窗口。返回秒数给 `PopopxSecureWindowManager`，
    /// 本函数不 import 那一层——窗口怎么计时是它的契约，这里只卖时长。
    func purchaseExtendedSecureWindow() throws -> Int {
        loadIfNeeded()
        _ = try debit(PopopxCommerceLimits.extendedSecureWindowCost, kind: .secureWindow, note: PopopxCreditsCopy.secureWindow)
        return PopopxCommerceLimits.extendedSecureWindowSeconds
    }

    func purchase(_ cosmetic: PopopxCosmetic) throws {
        loadIfNeeded()
        guard !ownedCosmetics.contains(cosmetic) else { throw PopopxBadgeCreditsError.signalRejected }
        _ = try debit(cosmetic.cost, kind: .cosmetic, note: PopopxCreditsCopy.cosmetic(cosmetic))
        ownedCosmetics.insert(cosmetic)
        saveCosmetics()
    }

    func owns(_ cosmetic: PopopxCosmetic) -> Bool {
        loadIfNeeded()
        return ownedCosmetics.contains(cosmetic)
    }

    // MARK: 展示

    /// 流水按时间倒序给 UI；不做分页——上限就是 240 条。
    var recentEntries: [PopopxCreditsEntry] {
        loadIfNeeded()
        return ledger.reversed()
    }

    var pendingPacketTotal: Int {
        loadIfNeeded()
        return pendingPackets.filter { !$0.settled }.reduce(0) { $0 + $1.refundableAmount }
    }
}

// MARK: - 文案

/// 流水与提示里的短语。涉钱承诺那一批在 `PopopxCommerceCopy`（进全部 17 个 `.lproj`），
/// 这一批是流水备注，与前面几个 POPOPX 特性一样留在文件内。
private enum PopopxCreditsCopy {
    static func purchasedPack(_ amount: Int) -> String { "充值 \(amount) 算力点" }
    static let reversedExchange = "兑换未成立 · 自动退回"
    static func badgeExchange(_ period: PopopxNodeBadgePeriod) -> String { "兑换 \(period.days) 天隐私节点徽章" }
    static func voucherExchange(period: PopopxNodeBadgePeriod, quantity: Int) -> String { "兑换 \(quantity) 张 \(period.days) 天礼品卡券" }
    static func packetSent(amount: Int, recipients: Int) -> String { "发出算力点红包 \(amount)（\(recipients) 份均分）" }
    static func packetReceived(note: String) -> String { note.isEmpty ? "收到算力点红包" : "收到红包：\(note)" }
    static func packetRefund(_ amount: Int) -> String { "红包未领完，退回 \(amount)" }
    static func channelSubscribed(_ title: String) -> String { "订阅频道 \(title)" }
    static let profileUnlocked = "解锁资料卡"
    static let secureWindow = "扩展防窥查看窗口"
    static func cosmetic(_ item: PopopxCosmetic) -> String { item.displayName }
    static func refundClawback(shortfall: Int) -> String {
        shortfall > 0 ? "退款扣回（已花掉的部分不追回）" : "退款扣回"
    }
}

/// 内部可见而不是文件私有：算力点中心要列出"这两样东西叫什么价"，
/// 名字在这里给一次，别处再写一份就会出现两种叫法。
extension PopopxCosmetic {
    var displayName: String {
        switch self {
        case .auroraShieldAvatarFrame: return "极光盾头像边框"
        case .darkGoldQRCardSkin: return "暗金二维码卡面"
        }
    }
}
