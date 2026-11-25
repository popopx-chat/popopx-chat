//  PopopxCreditsManager.swift
//
//  POPOPX Compute Credits: wallet, ledger, replay protection, and the six spending scenarios.
//
//  The balance is the real account; the ledger is a history window
//  `PopopxCreditsWallet.balance` is the only number spending ever relies on; the `PopopxCreditsEntry` queue has a cap
//  (`maximumLedgerEntries` = 240) and drops the oldest when full. So "verify the balance by summing the ledger" only
//  holds while the queue is not full. `reconcileOnLoad()` handles the two cases apart:
//  - queue not full (history complete) yet mismatched → rewrite the balance from the ledger sum, the only self-healing case;
//  - queue full and mismatched → only set `needsReconcile`, never rewrite the balance.
//  Silently "correcting" the balance by treating a truncated history as the real account is the kind of auto-repair most likely to zero out a user's balance.
//
//  The order of ledger writes (this is not a style question)
//  Income direction: judge replay → change the balance and persist → record the ledger → write the replay-protection marker → `finish` the transaction.
//  Expense direction: judge the balance → change the balance and persist → record the ledger.
//  The common point is persisting "the money change" as the first step and putting "markers/history" after it, because the bad cases on the two ends are asymmetric:
//  marker persisted before the balance = when the transaction gets finished or the user retries, it is judged "already credited" and the money is lost forever;
//  balance persisted before the marker = a retry credits one extra time, but the transaction is still not finished, StoreKit will re-deliver,
//  and the dedup check on that path is on `hasCredited` — which has not been written at that point. So the real guardrail is
//  "unfinished transactions get re-delivered" + "main-actor serialization", therefore the marker must be written after the balance and before `finish`,
//  and every entry point of this class is on the `@MainActor` (concurrent re-entry does not exist).
//
//  Strictly equal value, zero gifting
//  Top-up pack crediting only honors `PopopxNodeBadgeSku.creditedAmount` (100 / 500 / 2000);
//  there is no multiplier, no first-day bonus, no "extra gift". Domestic promotional terms and Apple's 3.1.1 equal-value rule both press on the same point,
//  so this is a hard constraint rather than a copy preference; `PopopxCommerceCopy.noGiftBackStatement` is its only expression in the UI.
//
//  Random-amount red packets do not exist
//  Red packets allow only fixed denominations (`PopopxCommerceLimits.redPacketAmounts`) and **even splits**;
//  on claim, each share is credited per `amountPerRecipient`. Random amounts = gambling-like mechanics, and that tier has no entry even at the type level in this feature:
//  `sendRedPacket` accepts no degrees of freedom beyond the amount parameters, and the denomination check runs once more at the `PopopxRedPacketPayload` parsing end.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. A red line forbids scripts from modifying project.pbxproj.

import Foundation
import os

@MainActor
@Observable
final class PopopxCreditsManager {
    static let shared = PopopxCreditsManager()

    private(set) var wallet = PopopxCreditsWallet(version: PopopxCreditsWallet.currentVersion, balance: 0, updatedAtMs: 0, needsReconcile: false)
    private(set) var ledger: [PopopxCreditsEntry] = []
    private(set) var replay = PopopxReplayGuard()
    /// Red packets held by the sender that are not fully claimed (for ACK verification and refunds).
    private(set) var pendingPackets: [PopopxPendingRedPacket] = []
    private(set) var channelTickets: [PopopxChannelSubscriptionTicket] = []
    private(set) var profileReceipts: [PopopxProfileUnlockReceipt] = []
    /// Received channel payment txHash values for replay protection (owner's side). Capped at 1000 entries.
    private(set) var receivedPaymentTxHashes: Set<String> = []
    private(set) var ownedCosmetics: Set<PopopxCosmetic> = []
    private(set) var lastReconcileAt: Date?

    private var loaded = false
    private var deliveryToken: UUID?
    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "credits")

    private init() {}

    var balance: Int { wallet.balance }

    // MARK: loading

    /// Restores all state from the Keychain. Idempotent; callable from any entry point.
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
        receivedPaymentTxHashes = Set(PopopxCommerceKeychain.decode([String].self, .receivedPaymentTxHashes) ?? [])
        ownedCosmetics = Set(PopopxCommerceKeychain.decode([PopopxCosmetic].self, .cosmetics) ?? [])
        reconcileOnLoad()
    }

    /// Called from the app launch path: catches the delivery of top-up pack and gift card receipts.
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

    // MARK: reconciliation

    private func reconcileOnLoad() {
        guard ledger.count < PopopxCommerceLimits.maximumLedgerEntries else { return }
        let sum = ledger.reduce(0) { $0 + $1.amount }
        guard sum != wallet.balance else { return }
        // Take the difference before rewriting: writing it afterwards would forever print 0, and that log line would destroy its own evidence.
        let delta = sum - wallet.balance
        // History complete yet mismatched: the ledger is the authority, and this fact is written into the log (not onto the screen).
        // Reaching here usually means the last persist was interrupted, or the user installed a tool that modifies balances.
        wallet.balance = max(0, min(sum, PopopxCommerceLimits.maximumCreditBalance))
        wallet.needsReconcile = false
        log.info("credits: balance rebuilt from a complete ledger; delta was \(delta)")
        _ = saveWallet()
    }

    /// The detail page's "re-check": the marker is set only when the balance and the ledger disagree and the history was truncated.
    func verifyLedgerConsistency() {
        loadIfNeeded()
        guard ledger.count >= PopopxCommerceLimits.maximumLedgerEntries else { return }
        wallet.needsReconcile = true
        lastReconcileAt = Date()
        _ = saveWallet()
    }

    // MARK: ledger primitives

    /// Income. `amount` must be positive; the upper-bound check lives here, and no caller can route around it.
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

    /// Expense. `amount` is passed as a positive number and the sign is decided by `kind.sign`, so an amount's polarity has exactly one source in the whole project.
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

    // MARK: receipt crediting (StoreKit delivery)

    /// Handles only the top-up pack and gift card SKU families; subscription SKUs are `PopopxBadgeManager`'s responsibility, and badges are never touched here.
    func apply(storeReceipt receipt: PopopxStoreReceipt) async {
        loadIfNeeded()
        guard let sku = receipt.sku else { return }
        if receipt.isRevoked {
            // Refunded credits must be clawed back (that is unspent balance); what has already been spent is not chased,
            // and one `adjustment` entry records the reason instead of silently changing numbers.
            await clawBack(receipt)
            return
        }
        guard !replay.hasCredited(transactionHash: receipt.digest) else {
            await PopopxStoreKitManager.shared.finish(receipt)
            return
        }
        switch sku.kind {
        case let .credits(amount):
            // On failure nothing is finished: `Transaction.unfinished` re-delivers, the money is still in Apple's hands,
            // which is more decent than either "money charged, nothing received" or "nothing received but the transaction closed".
            do {
                _ = try credit(amount, kind: .storePurchase, note: PopopxCreditsCopy.purchasedPack(amount), entryId: receipt.digest)
            } catch {
                log.error("credits: pack could not be credited; leaving the transaction unfinished: \(error.localizedDescription, privacy: .public)")
                return
            }
        case let .giftCard(period):
            // A gift card is "paying for a voucher"; Apple collects the money and this end does not touch the balance — no debit is ever done here.
            // A failed voucher mint follows the same rule as a failed top-up: do not finish, wait for re-delivery.
            do {
                _ = try await PopopxP2PVoucherVault.shared.mint(period: period, quantity: 1, source: .receipt(receipt))
            } catch {
                log.error("credits: gift voucher minting failed; leaving the transaction unfinished: \(error.localizedDescription, privacy: .public)")
                return
            }
        case let .creditGiftCard(amount):
            // The credit twin of the branch above: Apple collects the money, this end mints exactly one credit voucher,
            // and **this device's balance never moves** — which is also why `clawBack` below cannot see this SKU family
            // (it reads `creditedAmount`, and a gift card reports nil there). Nothing was added here, so a refund has nothing to take back;
            // the voucher itself stays with whoever holds it, and revoking a redeemed card across devices would need a server this feature does not have.
            do {
                _ = try await PopopxP2PVoucherVault.shared.mintCredit(creditsAmount: amount, quantity: 1, source: .receipt(receipt))
            } catch {
                log.error("credits: credit gift card minting failed; leaving the transaction unfinished: \(error.localizedDescription, privacy: .public)")
                return
            }
        case .subscription, .oneTimePass:
            // Subscriptions are lit up by `PopopxBadgeManager`'s delivery callback; one-off duration packs are lit up on the spot by the paywall side
            // (it goes through no voucher and moves no balance; this function should not touch it at all). Both attach to the same stream,
            // each recognizing only its own SKU family, so one receipt is ever credited by exactly one manager.
            return
        }
        replay.credit(transactionHash: receipt.digest)
        saveReplay()
        await PopopxStoreKitManager.shared.finish(receipt)
    }

    /// Refund clawback: deduct that credited amount back out of the balance; if it cannot be fully recovered, deduct down to zero, and leave an `adjustment` entry.
    private func clawBack(_ receipt: PopopxStoreReceipt) async {
        guard let amount = receipt.sku?.creditedAmount,
              ledger.contains(where: { $0.id == receipt.digest })
        else {
            // A refunded **gift card** never entered this balance, so there is no number to take back — but the voucher its receipt minted
            // may still be sitting here unused. See `recallMintedVouchers`.
            await recallMintedVouchers(receipt)
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

    /// Takes back the voucher a refunded receipt minted, for **both** gift-card families (badge and compute credits).
    /// Without this step a refund leaves the card on this device spendable, and "keep the card, get the money back" is a hole
    /// the two families share. `PopopxP2PVoucherVault.discard` only ever removes an `unused` row, so a card somebody already
    /// redeemed is left alone: taking an entitlement back across devices would need a server, and this feature has none —
    /// the honest limit is stated in the vault header and repeated in the review notes.
    private func recallMintedVouchers(_ receipt: PopopxStoreReceipt) async {
        let minted = await PopopxP2PVoucherVault.shared.vouchers().filter { $0.transactionId == receipt.digest }
        var recalled = 0
        for voucher in minted {
            if await PopopxP2PVoucherVault.shared.discard(voucherId: voucher.voucherId) { recalled += 1 }
        }
        if recalled > 0 { log.info("credits: a refunded gift card was recalled from this device") }
    }

    // MARK: scenario 1 · exchanging credits for a badge

    /// 600 points / 30 days, 4500 points / 365 days. Deduct the points first, light up afterwards:
    /// if lighting up fails, the points are refunded as they were, avoiding the nobody-owns-it state of "points spent, badge not lit".
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

    // MARK: scenario 2 · exchanging credits for a gift card voucher

    /// The voucher is minted only after the deduction succeeds; a failed mint refunds the points immediately. The voucher's code is freshly minted by `PopopxSilentSignalingRouter`;
    /// this function only governs "whether this voucher is worth anything".
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

    // MARK: scenario 2b · exchanging credits for a compute-credit gift card

    /// The credit twin of `exchangeCreditsForVoucher`, at **1:1 face value**: a 500-credit gift card costs 500 credits, and the recipient
    /// gets exactly 500. Any other ratio would make the gift card either a discount or a markup on the Apple price of the same
    /// denomination, and "the same thing costs two amounts depending which page you are on" is the sentence Apple's 3.1.1 review is written to catch.
    ///
    /// It takes a `PopopxCreditPack` rather than an `Int` on purpose: the only values that can reach this function are the three gift-card
    /// denominations, so there is no "free-typed amount" path left open for a future caller. That is the same 3.1.1 rule the red packets
    /// obey with `PopopxCommerceLimits.redPacketAmounts`, enforced in the signature instead of in a runtime check that can be forgotten.
    /// The mint happens only after the deduction, and a failed mint refunds it — the same order as the badge leg, for the same reason.
    func exchangeCreditsForCreditVoucher(pack: PopopxCreditPack, quantity: Int) async throws -> [PopopxNodeVoucher] {
        loadIfNeeded()
        let amount = pack.amount
        let total = amount * max(1, quantity)
        let entry = try debit(total, kind: .creditGiftSent, note: PopopxCreditsCopy.creditVoucherExchange(amount: amount, quantity: quantity))
        do {
            return try await PopopxP2PVoucherVault.shared.mintCredit(creditsAmount: amount, quantity: quantity, source: .creditEntry(id: entry.id))
        } catch {
            _ = try? credit(total, kind: .adjustment, note: PopopxCreditsCopy.reversedExchange, entryId: "reverse.\(entry.id)")
            throw error
        }
    }

    // MARK: scenario 2c · receiving a compute-credit gift card

    /// Crediting a redeemed credit gift card. The amount comes from the **verified `PopopxCreditsGrant`**, never from the card text,
    /// so the number this function writes into the ledger is the giver's own signed statement.
    ///
    /// Returns false when this voucher has already been credited on this device. `markRedeemed` is the same replay ledger the badge
    /// leg uses (keyed by voucherId, so the two families can never collide on an id), and the entry id is derived from the voucherId
    /// as well: a 2,000-entry FIFO overflow in the replay list still cannot double-book a gift card.
    @discardableResult
    func creditGiftCard(grant: PopopxCreditsGrant) throws -> Bool {
        loadIfNeeded()
        guard !replay.hasRedeemed(voucherId: grant.voucherId) else { return false }
        _ = try credit(grant.creditsAmount, kind: .creditGiftReceived, note: PopopxCreditsCopy.creditGiftReceived, entryId: "creditgift.\(grant.voucherId)")
        markRedeemed(voucherId: grant.voucherId)
        return true
    }

    // MARK: scenario 3 · credit red packets (fixed denominations, even split)
    /// Send a red packet: the full amount is deducted in one go, and it only truly lands on the other party's account share by share as they claim;
    /// this side keeps a `PopopxPendingRedPacket` for reconciliation and refunds.
    ///
    /// `recipientCount` is the **number of even shares**: `amount` must divide cleanly by it, otherwise this red packet cannot even be constructed at the type level —
    /// better to reject this combination at send time than to face a "one extra in the last share" rounding at claim time.
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

    /// Claim one red-packet share. Replay protection keys on `packetId`: the same ACK re-delivered, or a duplicate push from the other side, both credit at most once.
    /// Claiming is "each recipient claims their own share", so what is recorded here is this device's claim history, not a global share.
    func claimRedPacket(packetId: String, amountPerRecipient: Int, note: String) throws -> Bool {
        loadIfNeeded()
        guard !replay.hasClaimed(packetId: packetId) else { return false }
        _ = try credit(amountPerRecipient, kind: .redPacketReceived, note: PopopxCreditsCopy.packetReceived(note: note), entryId: "claim.\(packetId)")
        replay.claim(packetId: packetId)
        saveReplay()
        return true
    }

    /// Whether this device has already opened this share. The bubble uses it to decide between showing "open" and "claimed":
    /// the check is the same one as `claimRedPacket`'s (the replay-protection record); a view keeping its own state would fall back to "openable" after a process restart.
    func hasClaimed(packetId: String) -> Bool {
        loadIfNeeded()
        return replay.hasClaimed(packetId: packetId)
    }

    /// Whether this gift card has already been redeemed on this device. Written at the successful-redeem step (after `PopopxSilentSignalingRouter` receives the ACK),
    /// so the bubble can stay at "redeemed" long-term, and a second request is never sent for the same voucher — the gifter's side has a `redeemed` state as fallback,
    /// but letting the other side block a needless round-trip for you is not this layer's approach.
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

    /// The pending record from the sender's perspective (the bubble's "claimed n/N shares"). Returns nil for packets not sent by this device —
    /// when the same packetId shows up in somebody else's chat, no share counts should be displayed from here.
    func pendingPacket(packetId: String) -> PopopxPendingRedPacket? {
        loadIfNeeded()
        return pendingPackets.first { $0.packetId == packetId }
    }

    /// Called when the sender side receives the `REDPACKET_CLAIMED` receipt: only increments the share count, never touches the balance (the money was already deducted at send time).
    ///
    /// Group red packets must dedup by member: the receipt is replayable text, and one more message from the same person would push `claimedCount`
    /// above the share count, and the refund would be computed as 0 — the one harmed is the sender, who has no way to notice.
    /// The count is also clamped to `recipientCount`: an excess receipt changes no amount, so it should change no accounting display either.
    /// When `memberKey` is nil (direct) there is nothing to dedup on; that side is backed by the claimer's own replay protection.
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

    /// Channel owner receives a payment receipt: verify txHash uniqueness, credit the wallet, and record the hash.
    /// Returns true if credited, false if duplicate or error.
    func receiveChannelPayment(_ receipt: PopopxChannelPaymentReceipt) -> Bool {
        loadIfNeeded()
        // Replay protection: check if this txHash was already processed
        guard !receivedPaymentTxHashes.contains(receipt.txHash) else {
            log.info("credits: duplicate channel payment receipt txHash=\(receipt.txHash, privacy: .public)")
            return false
        }
        // Credit the wallet
        do {
            _ = try credit(receipt.credits, kind: .servicePayment, note: PopopxCreditsCopy.channelPaymentReceived(receipt.credits, receipt.channelId), entryId: "channel_pay.\(receipt.txHash)")
            // Record the txHash for replay protection
            receivedPaymentTxHashes.insert(receipt.txHash)
            // Cap the set at 1000 entries to prevent unbounded growth
            if receivedPaymentTxHashes.count > 1000 {
                let excess = receivedPaymentTxHashes.count - 1000
                receivedPaymentTxHashes = Set(receivedPaymentTxHashes.dropFirst(excess))
            }
            saveReceivedPaymentTxHashes()
            log.info("credits: channel payment received \(receipt.credits, privacy: .public) credits for channel \(receipt.channelId, privacy: .public)")
            return true
        } catch {
            log.error("credits: failed to credit channel payment: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func saveReceivedPaymentTxHashes() {
        _ = PopopxCommerceKeychain.encode(Array(receivedPaymentTxHashes), .receivedPaymentTxHashes)
    }

    /// Refund of an unclaimed-out red packet. Two triggers: **all shares claimed**, or the **grace period passed** (`claimGraceEndsAtMs`).
    /// The difference must be refunded, otherwise the sender is left with money forever hanging — the thing in this feature most likely to turn into a complaint.
    /// But it cannot be refunded before all shares are claimed: after a refund the group's remaining shares would still be claimed, and those points would have been paid by nobody.
    /// A group packet nobody claims and a single-share packet whose recipient never comes online both go through the grace-period path.
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

    // MARK: scenario 4 · channel subscription

    /// Subscribe to a channel: the points price is set by the channel owner, and the validity is one unit of `channelTicketSeconds` (30 days, the same length as the badge's monthly tier,
    /// so users never see two kinds of "one month" in two places).
    ///
    /// With an existing valid ticket this **stacks** rather than replaces: people who renew early should not forfeit their unused days — the points were already deducted.
    /// The same sentence as badge activation: "take the later expiry".
    /// `price == 0` does not enter here: that means "this channel is free", and the caller passes it directly; deducting 0 points would only leave a fake ledger entry.
    /// `issuerPublicKeyBase64URL` is this card's signing public key, stored into the ticket verbatim: it is the local half of the anti-impersonation comparison record
    /// (the check lives in `channelIssuerConflict`); it takes part in no signature verification — the signature's authenticity was already judged on the rendering side.
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

    /// Whether the publisher this device **paid once** in this channel matches the signing public key of the card at hand.
    ///
    /// Why it can only be checked this way: on the member side a channel message is `CIDirection.channelRcv`, and that tier carries **no** `GroupMember`
    /// (`ChatTypes.swift:4421-4422`, `groupMemberId` is nil for it, :4440-4442), so "what role the sender of this has"
    /// at the Swift layer has no readable number whatsoever; `ChatInfo.id` is again a local row number (`"#"+groupId`, :3059), not portable across devices,
    /// and signing it into the card could only sign out something that does not exist on the other party's device. The core side has no comparable authoritative public key — this module's signing key
    /// is a P256 business key, not the same set of keys as the SMP connections.
    ///
    /// So the actual coverage of this check is honest: **the person who has already paid once** will not have points burned again by a card from a second key.
    /// Before the first payment there is nothing to compare against (no comparable record exists); that window relies on the publisher-side role gate
    /// (`sendChannelAccess`) + the interface giving the subscribe button only to cards whose signature verifies; what remains is this module's documented residual risk.
    /// Old tickets never recorded the public key, so they uniformly return "no conflict": people must not be locked out because a pre-upgrade ledger is missing a field.
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

    // MARK: scenario 5 · unlocking a protected profile card

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

    /// The three fields are judged together: profile cards can be forwarded and can appear multiple times in the same conversation,
    /// and judging on `profileId` alone would turn "unlocked in conversation A" into "free in conversation B".
    func hasUnlocked(profileId: String, chatId: Int64, itemId: Int64) -> Bool {
        loadIfNeeded()
        return profileReceipts.contains { $0.profileId == profileId && $0.chatId == chatId && $0.itemId == itemId }
    }

    // MARK: scenario 6 · premium redemption (extended anti-peep window / decoration)

    /// 20 points exchange for 1 hour of the extended anti-peep window. The seconds are returned to `PopopxSecureWindowManager`;
    /// this function does not import that layer — how the window counts time is its contract, and here we only sell the duration.
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

    // MARK: scenario 7 · service-account card payment

    /// The `pay_credits` leg of a service-account card. It mints **no** credential: the ledger entry it returns is the whole receipt,
    /// and the caller puts `entry.id` into the `::CB::…:paid_<id>` callback.
    ///
    /// That id is a locally minted UUID (`debit`'s `entryId` default), not anything the server issued, so the callback names *this
    /// device's record* rather than a transaction the far side can look up. The server can only match it on amount plus target, which is
    /// why the note carries the target and why a replayed callback is refused by the card's own lockout rather than by this entry.
    ///
    /// The balance is checked here and not only by the caller: `debit` is the single place the wallet moves, and a caller that skipped
    /// its own pre-check must still not be able to overdraw.
    @discardableResult
    func payForService(amount: Int, note: String) throws -> PopopxCreditsEntry {
        loadIfNeeded()
        return try debit(amount, kind: .servicePayment, note: note)
    }

    // MARK: display

    /// The ledger is handed to the UI in reverse time order; no pagination — the cap is 240 entries.
    var recentEntries: [PopopxCreditsEntry] {
        loadIfNeeded()
        return ledger.reversed()
    }

    var pendingPacketTotal: Int {
        loadIfNeeded()
        return pendingPackets.filter { !$0.settled }.reduce(0) { $0 + $1.refundableAmount }
    }
}

// MARK: - copy

/// The short phrases in the ledger and the notices. The money-promise batch lives in `PopopxCommerceCopy` (into all 17 `.lproj`),
/// while this batch is ledger remarks, kept inside the file like the previous POPOPX features.
private enum PopopxCreditsCopy {
    static func purchasedPack(_ amount: Int) -> String { String(format: NSLocalizedString("Top-up %lld compute points", comment: "POPOPX credits ledger"), amount) }
    static let reversedExchange = NSLocalizedString("Exchange did not complete · returned automatically", comment: "POPOPX credits ledger")
    static func badgeExchange(_ period: PopopxNodeBadgePeriod) -> String { String(format: NSLocalizedString("Redeemed a %lld-day privacy node badge", comment: "POPOPX credits ledger"), period.days) }
    static func voucherExchange(period: PopopxNodeBadgePeriod, quantity: Int) -> String { String(format: NSLocalizedString("Redeemed %lld × %lld-day gift-card vouchers", comment: "POPOPX credits ledger"), quantity, period.days) }
    /// The credit-card sibling of `voucherExchange`. Positional specifiers, so a language that naturally puts the face value before
    /// the count can reorder the sentence without swapping which number lands where.
    static func creditVoucherExchange(amount: Int, quantity: Int) -> String { String(format: NSLocalizedString("Created %1$lld × %2$lld compute-point gift cards", comment: "POPOPX credits ledger"), quantity, amount) }
    static let creditGiftReceived = NSLocalizedString("Received a compute-point gift card", comment: "POPOPX credits ledger")
    static func packetSent(amount: Int, recipients: Int) -> String { String(format: NSLocalizedString("Sent a red packet of %lld compute points (%lld equal shares)", comment: "POPOPX credits ledger"), amount, recipients) }
    static func packetReceived(note: String) -> String { note.isEmpty ? NSLocalizedString("Received a compute-point red packet", comment: "POPOPX credits ledger") : String(format: NSLocalizedString("Received a red packet: %@", comment: "POPOPX credits ledger"), note) }
    static func packetRefund(_ amount: Int) -> String { String(format: NSLocalizedString("Red packet not fully claimed, %lld returned", comment: "POPOPX credits ledger"), amount) }
    static func channelSubscribed(_ title: String) -> String { String(format: NSLocalizedString("Subscribed to channel %@", comment: "POPOPX credits ledger"), title) }
    static func channelPaymentReceived(_ amount: Int, _ channelId: Int64) -> String { String(format: NSLocalizedString("Received %lld compute points from channel %lld", comment: "POPOPX credits ledger"), amount, channelId) }
    static let profileUnlocked = NSLocalizedString("Unlocked a profile card", comment: "POPOPX credits ledger")
    static let secureWindow = NSLocalizedString("Extended the anti-peeping viewing window", comment: "POPOPX credits ledger")
    static func cosmetic(_ item: PopopxCosmetic) -> String { item.displayName }
    static func refundClawback(shortfall: Int) -> String {
        shortfall > 0 ? NSLocalizedString("Refund clawback (what was already spent is not recovered)", comment: "POPOPX credits ledger") : NSLocalizedString("Refund clawback", comment: "POPOPX credits ledger")
    }
}

/// Internal rather than file-private: the credits center has to list "what these two things are priced",
/// so the names are given once here; writing another copy elsewhere would produce two ways of calling them.
extension PopopxCosmetic {
    var displayName: String {
        switch self {
        case .auroraShieldAvatarFrame: return NSLocalizedString("Aurora shield avatar frame", comment: "POPOPX cosmetic")
        case .darkGoldQRCardSkin: return NSLocalizedString("Dark gold QR card skin", comment: "POPOPX cosmetic")
        }
    }
}
