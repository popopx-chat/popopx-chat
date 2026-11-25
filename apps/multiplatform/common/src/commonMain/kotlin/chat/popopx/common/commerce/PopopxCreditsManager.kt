package chat.popopx.common.commerce

import chat.popopx.common.discover.PopopxDiscoverLedger
import chat.popopx.common.eco.PopopxCreditSource
import chat.popopx.common.platform.Log
import chat.popopx.common.platform.settings
import chat.popopx.common.platform.TAG
import com.russhwolf.settings.Settings
import kotlinx.serialization.builtins.serializer

/**
 * The compute-credit ledger and every money-moving scenario built on it — the Kotlin form of
 * `PopopxCreditsManager` (`apps/ios/Shared/Features/BadgeCredits/PopopxCreditsManager.swift`, all 690 lines read).
 *
 * ### The balance is the account; the ledger is a display window
 * `wallet.balance` is the only number spending ever relies on, and `ledger` keeps the last
 * [PopopxCommerceLimits.MAXIMUM_LEDGER_ENTRIES] rows, dropping the oldest (`:56`). "Sum the ledger to check the
 * balance" therefore only holds while the window is not full, and a tool that "repairs" a full window from its own
 * sum would zero out everybody's balance (`:8-14`). Hence the two reconciliation paths below, ported apart:
 *  - [loadIfNeeded]: history complete and mismatched → rebuild the balance from the sum, the ONLY self-healing case;
 *  - [verifyLedgerConsistency]: window full → flag, never rewrite.
 *
 * ### The write order, which is not a style question (`:16-26`)
 * Both directions change the balance and persist it FIRST, then append the row, then write the replay marker last:
 *  - a marker written before the balance means a retry is judged "already credited" and the money is gone;
 *  - a balance written before the marker means at most one extra row that the next reconcile trims.
 * A failed balance write rolls the in-memory change back and throws [PopopxBadgeCreditsError.KeychainUnavailable];
 * a failed ledger write only logs, because the row is history and the balance is money (`:184`).
 * iOS gets its uninterleaving from `@MainActor`; here every entry point is [Synchronized], which is the same
 * guarantee (one thread inside the class at a time) without an actor.
 *
 * ### Three deliberate deviations from the Swift, none of them a change of arithmetic
 * 1. **Ledger `note` text is a parameter.** iOS derives it from `PopopxCreditsCopy` (`:659-679`), which is
 *    NSLocalizedString sentences; `commonMain` has no localisation context at this seam, so the caller passes its
 *    own translated sentence. [PopopxCreditsCopy] below carries the English fallbacks so an unwired caller prints
 *    the same words iOS does.
 * 2. **The StoreKit legs are absent by ruling** (`:196-294`: `start/stop`, `apply(storeReceipt:)`, `clawBack`,
 *    `recallMintedVouchers`) and so is `exchangeCreditsForBadge` (`:300-309`), which lights a badge through
 *    `PopopxBadgeManager` — the foss build sells no in-app products, and a debit against a lane that cannot run is
 *    a lane that will be deleted with the caller. `PopopxCreditPack`'s type-level denomination guard becomes
 *    [PopopxCommerceLimits.CREDIT_GIFT_AMOUNTS], read where the SKU list used to be the type.
 * 3. **`verifyLedgerConsistency()` returns nothing on iOS** and sets the marker whenever the window is full. The
 *    port keeps that, but see the measured note on the function: the doc comment above it claims a comparison the
 *    code never makes.
 */
class PopopxCreditsManager(
  private val defaults: Settings = settings,
  private val store: PopopxCommerceStore = PopopxCommerceStore(defaults),
  private val vault: PopopxP2PVoucherVault = PopopxP2PVoucherVault(defaults, store),
  /** The wall clock in milliseconds; injected so the grace-period and stacking legs are testable (`:498`). */
  private val nowMs: () -> Long = { commerceNowMs() },
  private val newId: () -> String = { commerceNewUuid() },
) : PopopxCreditSource {

  // MARK: State (`:43-53`)

  private var wallet: PopopxCreditsWallet =
    PopopxCreditsWallet(PopopxCreditsWallet.CURRENT_VERSION, 0, 0, false)
  private var ledger: MutableList<PopopxCreditsEntry> = mutableListOf()
  private var replay: PopopxReplayGuard = PopopxReplayGuard()
  private var pendingPackets: MutableList<PopopxPendingRedPacket> = mutableListOf()
  private var channelTickets: MutableList<PopopxChannelSubscriptionTicket> = mutableListOf()
  private var profileReceipts: MutableList<PopopxProfileUnlockReceipt> = mutableListOf()

  /**
   * The OWNER-side replay set for channel payments (`:51`). It is NOT [replay]: iOS keeps this one separately and
   * caps it at 1000 (`:476`), because a channel is paid txHash by txHash for as long as it exists, while the
   * shared guard is a 2000-wide window over three different vocabularies.
   */
  private var receivedPaymentTxHashes: MutableSet<String> = mutableSetOf()
  private var ownedCosmetics: MutableSet<PopopxCosmetic> = mutableSetOf()
  private var loaded = false

  /** `balance` (`:61`) — the only number spending reads. */
  override val balance: Int
    get() {
      loadIfNeeded()
      return wallet.balance
    }

  /** `wallet.needsReconcile`: the screen's "this account needs a check" marker, never a silent correction. */
  val needsReconcile: Boolean
    get() {
      loadIfNeeded()
      return wallet.needsReconcile
    }

  /** `ledger` (`:45`): the retained window, oldest first. A copy — views must not append to the book. */
  val entries: List<PopopxCreditsEntry>
    get() {
      loadIfNeeded()
      return ledger.toList()
    }

  /** `recentEntries` (`:644-647`): reverse time order, no pagination, because the cap is 240 rows. */
  val recentEntries: List<PopopxCreditsEntry>
    get() {
      loadIfNeeded()
      return ledger.reversed()
    }

  /** `pendingPacketTotal` (`:649-652`): the credits still hanging in packets that have not settled. */
  val pendingPacketTotal: Int
    get() {
      loadIfNeeded()
      return pendingPackets.filter { !it.settled }.sumOf { it.refundableAmount }
    }

  // MARK: Loading

  /** `loadIfNeeded` (`:66-79`). Idempotent; every entry point calls it, including the read-only ones. */
  @Synchronized
  fun loadIfNeeded() {
    if (loaded) return
    loaded = true
    wallet = store.readWallet()
      ?: PopopxCreditsWallet(PopopxCreditsWallet.CURRENT_VERSION, 0, nowMs(), false)
    ledger = store.readList(PopopxCreditsEntry.serializer(), PopopxCommerceKeys.LEDGER)
    replay = store.readObject(PopopxReplayGuard.serializer(), PopopxCommerceKeys.REPLAY_GUARD) ?: PopopxReplayGuard()
    pendingPackets = store.readList(PopopxPendingRedPacket.serializer(), PopopxCommerceKeys.PENDING_PACKETS)
    channelTickets = store.readList(PopopxChannelSubscriptionTicket.serializer(), PopopxCommerceKeys.CHANNEL_TICKETS)
    profileReceipts = store.readList(PopopxProfileUnlockReceipt.serializer(), PopopxCommerceKeys.PROFILE_RECEIPTS)
    receivedPaymentTxHashes = store.readStringSet(PopopxCommerceKeys.RECEIVED_PAYMENT_TX_HASHES)
    ownedCosmetics = store.readList(String.serializer(), PopopxCommerceKeys.COSMETICS)
      .mapNotNull { PopopxCosmetic.fromWire(it) }.toMutableSet()
    reconcileOnLoad()
  }

  /**
   * `reconcileOnLoad` (`:100-112`): the only case that may rewrite the balance is a COMPLETE history that
   * disagrees with it — usually an interrupted persist, or a tool that edits the number.
   *
   * The log line is written BEFORE the rewrite (`:104-110`), because computing the delta afterwards would print 0
   * forever and the line would destroy its own evidence. Not ported: the delta is not returned either, matching
   * iOS, which has nothing to hand the caller at load time.
   */
  private fun reconcileOnLoad() {
    if (ledger.size >= PopopxCommerceLimits.MAXIMUM_LEDGER_ENTRIES) return
    val sum = ledger.sumOf { it.amount }
    if (sum == wallet.balance) return
    Log.i(TAG, "credits: balance rebuilt from a complete ledger; delta was ${sum - wallet.balance}")
    wallet.balance = maxOf(0, minOf(sum, PopopxCommerceLimits.MAXIMUM_CREDIT_BALANCE))
    wallet.needsReconcile = false
    saveWallet()
  }

  /**
   * `verifyLedgerConsistency` (`:115-121`) — MEASURED, and the measurement contradicts the doc comment above the
   * Swift original (`:114`): the function does NOT compare the sum with the balance. It sets the marker whenever
   * the window is full, because past the cap the two can no longer be expected to agree, and the flag is then the
   * honest answer to "is this book trustworthy". Ported as the code behaves, since the alternative would be a
   * second, Kotlin-only rule the iOS screen has never seen.
   */
  @Synchronized
  fun verifyLedgerConsistency() {
    loadIfNeeded()
    if (ledger.size < PopopxCommerceLimits.MAXIMUM_LEDGER_ENTRIES) return
    wallet.needsReconcile = true
    saveWallet()
  }

  // MARK: The ledger primitives (`:127-186`)

  /**
   * Income (`:127-150`). `amount` is taken as given and must be positive: [PopopxCreditsEntryKind.sign] is NOT
   * consulted here, which is why three income kinds report a null sign — `storePurchase` and `redPacketReceived`
   * are pure income and a sign on them would be a second, contradictable source of the polarity.
   */
  private fun credit(amount: Int, kind: PopopxCreditsEntryKind, note: String, entryId: String? = null): PopopxCreditsEntry {
    loadIfNeeded()
    if (amount <= 0) throw PopopxBadgeCreditsError.SignalRejected
    if (wallet.balance + amount > PopopxCommerceLimits.MAXIMUM_CREDIT_BALANCE) {
      throw PopopxBadgeCreditsError.CreditBalanceTooHigh(PopopxCommerceLimits.MAXIMUM_CREDIT_BALANCE)
    }
    wallet.balance += amount
    wallet.updatedAtMs = nowMs()
    wallet.needsReconcile = false
    if (!saveWallet()) {
      wallet.balance -= amount
      throw PopopxBadgeCreditsError.KeychainUnavailable
    }
    return appendEntry(PopopxCreditsEntry(entryId ?: newId(), amount, kind, note, wallet.updatedAtMs, wallet.balance))
  }

  /**
   * Expense (`:154-176`). The caller always passes a POSITIVE number and the sign comes from the category, so an
   * amount's polarity has exactly one source in the whole feature (`:152`). A kind with no sign — or a positive one
   * — is refused here rather than at the display layer.
   */
  private fun debit(amount: Int, kind: PopopxCreditsEntryKind, note: String, entryId: String? = null): PopopxCreditsEntry {
    loadIfNeeded()
    val sign = kind.sign
    if (amount <= 0 || sign == null || sign >= 0) throw PopopxBadgeCreditsError.SignalRejected
    if (wallet.balance < amount) {
      throw PopopxBadgeCreditsError.InsufficientCredits(wallet.balance, amount)
    }
    wallet.balance -= amount
    wallet.updatedAtMs = nowMs()
    if (!saveWallet()) {
      wallet.balance += amount
      throw PopopxBadgeCreditsError.KeychainUnavailable
    }
    return appendEntry(PopopxCreditsEntry(entryId ?: newId(), sign * amount, kind, note, wallet.updatedAtMs, wallet.balance))
  }

  /** `appendEntry` (`:178-186`): the FIFO trim, then a ledger write whose failure is only logged. */
  private fun appendEntry(entry: PopopxCreditsEntry): PopopxCreditsEntry {
    ledger.add(entry)
    if (ledger.size > PopopxCommerceLimits.MAXIMUM_LEDGER_ENTRIES) {
      repeat(ledger.size - PopopxCommerceLimits.MAXIMUM_LEDGER_ENTRIES) { ledger.removeAt(0) }
    }
    if (!saveLedger()) Log.w(TAG, "credits: ledger persistence failed; balance stays authoritative")
    return entry
  }

  private fun saveWallet(): Boolean = store.writeWallet(wallet)

  private fun saveLedger(): Boolean =
    store.writeList(PopopxCreditsEntry.serializer(), PopopxCommerceKeys.LEDGER, ledger)

  private fun saveReplay() {
    store.writeObject(replay, PopopxReplayGuard.serializer(), PopopxCommerceKeys.REPLAY_GUARD)
  }

  private fun savePackets() {
    store.writeList(PopopxPendingRedPacket.serializer(), PopopxCommerceKeys.PENDING_PACKETS, pendingPackets)
  }

  private fun saveTickets() {
    store.writeList(PopopxChannelSubscriptionTicket.serializer(), PopopxCommerceKeys.CHANNEL_TICKETS, channelTickets)
  }

  private fun saveProfileReceipts() {
    store.writeList(PopopxProfileUnlockReceipt.serializer(), PopopxCommerceKeys.PROFILE_RECEIPTS, profileReceipts)
  }

  private fun saveCosmetics() {
    store.writeList(String.serializer(), PopopxCommerceKeys.COSMETICS, ownedCosmetics.map { it.wireValue })
  }

  private fun saveReceivedPaymentTxHashes() {
    store.writeStringSet(PopopxCommerceKeys.RECEIVED_PAYMENT_TX_HASHES, receivedPaymentTxHashes.toList())
  }

  // MARK: Scenario · exchanging credits for a voucher (`:311-349`)

  /**
   * Credits out, `quantity` badge gift vouchers in. The voucher is minted only AFTER the debit succeeds and a
   * failed mint refunds it (`:320-325`), which is the order that leaves no "paid and received nothing" state.
   *
   * The refund is an [PopopxCreditsEntryKind.ADJUSTMENT] income keyed `reverse.<entry id>`, so the reversal itself
   * is replay-proof. Note the voucher's source is the debit's entry id: `PopopxVoucherSource.CreditEntry`, whose
   * `transactionId` is what reconciliation later matches.
   */
  @Synchronized
  fun exchangeCreditsForVoucher(period: PopopxNodeBadgePeriod, quantity: Int, note: String): List<PopopxNodeVoucher> {
    loadIfNeeded()
    val total = period.creditsCost * maxOf(1, quantity)
    val entry = debit(total, PopopxCreditsEntryKind.GIFT_VOUCHER_EXCHANGE, note)
    return try {
      vault.mint(period, quantity, PopopxVoucherSource.CreditEntry(entry.id))
    } catch (e: PopopxBadgeCreditsError) {
      reverse(entry.id, total)
      throw e
    }
  }

  /**
   * Credits out, `quantity` compute-credit gift cards in, at **1:1 face value** (`:330-332`): a 500-credit card
   * costs 500 credits and the recipient receives 500. Any other ratio is a discount or a markup on the same
   * denomination, which is the tier the equal-value rule is written to catch.
   *
   * The face value is checked against [PopopxCommerceLimits.CREDIT_GIFT_AMOUNTS] rather than against a pack type —
   * see deviation 2 in the class KDoc. A free-typed amount is refused here, so there is no path from this ledger to
   * a money-transfer instrument.
   */
  @Synchronized
  fun exchangeCreditsForCreditVoucher(creditsAmount: Int, quantity: Int, note: String): List<PopopxNodeVoucher> {
    loadIfNeeded()
    if (!PopopxCommerceLimits.CREDIT_GIFT_AMOUNTS.contains(creditsAmount)) throw PopopxBadgeCreditsError.SignalRejected
    val total = creditsAmount * maxOf(1, quantity)
    val entry = debit(total, PopopxCreditsEntryKind.CREDIT_GIFT_SENT, note)
    return try {
      vault.mintCredit(creditsAmount, quantity, PopopxVoucherSource.CreditEntry(entry.id))
    } catch (e: PopopxBadgeCreditsError) {
      reverse(entry.id, total)
      throw e
    }
  }

  /** The `reverse.<entry id>` refund both exchanges share (`:306`, `:323`, `:346`). */
  private fun reverse(entryId: String, amount: Int) {
    try {
      credit(amount, PopopxCreditsEntryKind.ADJUSTMENT, PopopxCreditsCopy.reversedExchange, "reverse.$entryId")
    } catch (e: PopopxBadgeCreditsError) {
      // The exchange already failed; a failed refund on top of it is reported by the ledger flag, not by a second
      // exception replacing the first, which is what iOS's `try?` does.
      wallet.needsReconcile = true
      saveWallet()
    }
  }

  // MARK: Scenario · receiving a compute-credit gift card (`:351-366`)

  /**
   * Crediting a redeemed card. The amount comes from the **verified [PopopxCreditsGrant]** — never from the card
   * text — so the number written here is the giver's own signed statement (`:353-355`).
   *
   * False means "this voucher was already credited on this device". The replay marker is written AFTER the credit,
   * in iOS's order (`:363-364`): a credit that failed must stay retryable, and a marker written first would make the
   * money disappear. Both key on `voucherId`, which is why a badge code and a credit code can never collide.
   */
  @Synchronized
  fun creditGiftCard(grant: PopopxCreditsGrant, note: String = PopopxCreditsCopy.creditGiftReceived): Boolean {
    loadIfNeeded()
    if (replay.hasRedeemed(grant.voucherId)) return false
    credit(grant.creditsAmount, PopopxCreditsEntryKind.CREDIT_GIFT_RECEIVED, note, "creditgift.${grant.voucherId}")
    markRedeemed(grant.voucherId)
    return true
  }

  /** `markRedeemed` (`:420-425`): written by the receive path after the ACK, so a bubble can stay "redeemed". */
  @Synchronized
  fun markRedeemed(voucherId: String) {
    loadIfNeeded()
    if (replay.hasRedeemed(voucherId)) return
    replay.redeem(voucherId)
    saveReplay()
  }

  @Synchronized
  fun hasRedeemed(voucherId: String): Boolean {
    loadIfNeeded()
    return replay.hasRedeemed(voucherId)
  }

  // MARK: Scenario · red packets (`:368-514`)

  /**
   * Send a packet: the whole amount is debited in one go and lands on the other side share by share, while this
   * side keeps a [PopopxPendingRedPacket] for the ACK reconciliation and the refund (`:369-370`).
   *
   * `recipientCount` is the number of EVEN shares. `amount % recipientCount != 0` is refused (`:380-381`) rather
   * than rounded: an uneven split is a gambling-shaped mechanic in one case and an accounting error in the other,
   * and this layer refuses to be either. The checks run again here even though the payload parser and the sheet run
   * them, because `sendRedPacket` is the function that moves money.
   */
  @Synchronized
  fun sendRedPacket(amount: Int, recipientCount: Int, message: String, note: String): PopopxPendingRedPacket {
    loadIfNeeded()
    if (!PopopxCommerceLimits.RED_PACKET_AMOUNTS.contains(amount)) throw PopopxBadgeCreditsError.SignalRejected
    if (amount > PopopxCommerceLimits.MAXIMUM_PACKET_AMOUNT) throw PopopxBadgeCreditsError.SignalRejected
    if (recipientCount < 1) throw PopopxBadgeCreditsError.SignalRejected
    if (recipientCount > PopopxCommerceLimits.MAXIMUM_PACKET_RECIPIENTS) throw PopopxBadgeCreditsError.SignalRejected
    if (amount % recipientCount != 0) throw PopopxBadgeCreditsError.SignalRejected
    val entry = debit(amount, PopopxCreditsEntryKind.RED_PACKET_SENT, note)
    val packet = PopopxPendingRedPacket(
      packetId = entry.id,
      amount = amount,
      note = message,
      recipientCount = recipientCount,
      claimedCount = 0,
      createdAtMs = entry.timestampMs,
      amountPerRecipient = amount / recipientCount,
      settled = false,
    )
    pendingPackets.add(packet)
    savePackets()
    return packet
  }

  /**
   * Claim one share on the RECEIVER's side (`:401-408`). Replay keys on `packetId`, which is the SENDER's ledger
   * entry id, so a re-delivered ACK or a duplicate push credits at most once (`:399-400`).
   *
   * The share amount is a parameter because the receiver's client learns it from the verified payload, not from
   * this device: the sender's split is the other side's arithmetic.
   */
  @Synchronized
  fun claimRedPacket(packetId: String, amountPerRecipient: Int, note: String): Boolean {
    loadIfNeeded()
    if (replay.hasClaimed(packetId)) return false
    credit(amountPerRecipient, PopopxCreditsEntryKind.RED_PACKET_RECEIVED, note, "claim.$packetId")
    replay.claim(packetId)
    saveReplay()
    return true
  }

  /** `hasClaimed` (`:412-415`): the bubble asks the replay record, never its own view state, so a restart cannot turn "claimed" back into "open". */
  @Synchronized
  fun hasClaimed(packetId: String): Boolean {
    loadIfNeeded()
    return replay.hasClaimed(packetId)
  }

  /**
   * `pendingPacket` (`:434-437`): the sender's view of its own packet, and null for a packet this device did not
   * send — the same id appearing in somebody else's chat must not display a share count from here.
   */
  @Synchronized
  fun pendingPacket(packetId: String): PopopxPendingRedPacket? {
    loadIfNeeded()
    return pendingPackets.firstOrNull { it.packetId == packetId }
  }

  /**
   * The SENDER's side of a `REDPACKET_CLAIMED` receipt (`:445-459`): increments a share count and touches no
   * balance, because the money left at send time.
   *
   * Two gates, both protecting the refund rather than the claim (`:441-444`): the count stops at `recipientCount`
   * so a replayed receipt cannot push the refund to 0, and a `memberKey` that is already present is ignored, which
   * is what makes one group member's re-sent message harmless. A null key (a direct packet) has nothing to dedupe
   * on and is backed by the claimer's own replay guard instead.
   */
  @Synchronized
  fun recordClaim(packetId: String, memberKey: String? = null) {
    loadIfNeeded()
    val packet = pendingPackets.firstOrNull { it.packetId == packetId } ?: return
    if (packet.claimedCount >= packet.recipientCount) return
    if (memberKey != null) {
      val keys = packet.claimKeys ?: mutableListOf()
      if (keys.contains(memberKey)) return
      packet.claimKeys = (keys + memberKey).toMutableList()
    }
    packet.claimedCount += 1
    savePackets()
  }

  /**
   * `refundSettledPackets` (`:497-514`): returns the number of credits given back, not the number of packets.
   *
   * Two triggers, and the second one is the reason an unclaimed packet does not strand money: every share claimed,
   * or the grace period passed (`:493-496`). It may NOT refund while shares are still outstanding, because those
   * shares would then be claimable against money already returned. The packet is marked `settled` BEFORE the
   * credit, and the credit failure is swallowed (`:508`), which biases towards never refunding twice.
   */
  @Synchronized
  fun refundSettledPackets(nowMs: Long = this.nowMs()): Int {
    loadIfNeeded()
    var refunded = 0
    for (packet in pendingPackets) {
      if (packet.settled) continue
      if (!(packet.isFullyClaimed || nowMs >= packet.claimGraceEndsAtMs)) continue
      val refundable = packet.refundableAmount
      if (refundable <= 0) continue
      packet.settled = true
      try {
        credit(refundable, PopopxCreditsEntryKind.RED_PACKET_REFUND, PopopxCreditsCopy.packetRefund(refundable), "refund.${packet.packetId}")
        refunded += refundable
      } catch (e: PopopxBadgeCreditsError) {
        // An over-ceiling or unwritable refund leaves the packet settled and the credits unreturned, exactly as
        // iOS's `try?` does: a packet that is retried after a partial refund is the worse of the two errors.
        Log.w(TAG, "credits: a packet refund could not be booked")
      }
    }
    savePackets()
    if (refunded > 0) Log.i(TAG, "credits: refunded unclaimed red packet remainder")
    return refunded
  }

  // MARK: Scenario · channel subscription, member side (`:516-545`)

  /**
   * Pay a channel's own price for one `channelTicketSeconds` cycle (30 days — the same length as the badge's
   * monthly tier, so no user ever sees two kinds of "one month" in two places, `:518-519`).
   *
   * An existing valid ticket **stacks** rather than replaces (`:521-522`): the days already paid for were debited
   * already. `price == 0` never reaches this function — a free channel is a caller-side decision, and a 0-credit
   * row would be a fake entry in the book (`:523`).
   */
  @Synchronized
  fun subscribeToChannel(
    channelId: String,
    channelTitle: String,
    price: Int,
    issuerPublicKeyBase64URL: String,
    note: String,
  ): PopopxChannelSubscriptionTicket {
    loadIfNeeded()
    if (price < 1 || price > PopopxCommerceLimits.MAXIMUM_CREDITS_THRESHOLD) throw PopopxBadgeCreditsError.SignalRejected
    val entry = debit(price, PopopxCreditsEntryKind.CHANNEL_SUBSCRIPTION, note)
    val renewedFromMs = channelTickets.firstOrNull { it.channelId == channelId }?.expiresAtMs ?: 0L
    val ticket = PopopxChannelSubscriptionTicket(
      channelId = channelId,
      channelTitle = channelTitle,
      price = price,
      paidAtMs = entry.timestampMs,
      expiresAtMs = maxOf(entry.timestampMs, renewedFromMs) + PopopxCommerceLimits.CHANNEL_TICKET_SECONDS * 1_000,
      transactionId = entry.id,
      // An empty key stores as null so a card without a declared issuer does not pin the channel to "" (`:539`).
      issuerPublicKeyBase64URL = issuerPublicKeyBase64URL.ifEmpty { null },
    )
    channelTickets.removeAll { it.channelId == channelId }
    channelTickets.add(ticket)
    saveTickets()
    return ticket
  }

  /**
   * `channelIssuerConflict` (`:559-565`): one paid ticket, one publisher key.
   *
   * Why it can only be checked this way (`:547-557`): a channel message on the member side carries no group member
   * row, and `ChatInfo.id` is a local row number that does not exist on the other device, so there is no
   * authoritative "who runs this channel" for this layer to read. What the check honestly covers is **the person who
   * has already paid once**: a second key cannot burn their credits a second time. Before the first payment there is
   * no record to compare against, and the ticket's issuer field participates in no signature verification — the
   * signature was already judged where the card was rendered.
   *
   * MEASURED: unlike [validTicket], this does NOT ask whether the ticket is still live — an expired subscription
   * still pins the key it was paid against. Ported as written.
   */
  @Synchronized
  fun channelIssuerConflict(channelId: String, issuerPublicKeyBase64URL: String): Boolean {
    loadIfNeeded()
    val pinned = channelTickets.firstOrNull { it.channelId == channelId }?.issuerPublicKeyBase64URL
    if (pinned.isNullOrEmpty() || issuerPublicKeyBase64URL.isEmpty()) return false
    return pinned != issuerPublicKeyBase64URL
  }

  /** `ticket(forChannelId:)` (`:567-570`): only a ticket that has not expired answers, and `now` is injected here rather than read (`:13` of this file's model). */
  @Synchronized
  fun validTicket(channelId: String, nowMs: Long = this.nowMs()): PopopxChannelSubscriptionTicket? {
    loadIfNeeded()
    return channelTickets.firstOrNull { it.channelId == channelId && it.isValidAt(nowMs) }
  }

  // MARK: Scenario · channel payment receipt, owner side (`:461-491`)

  /**
   * The channel owner books a member's payment. Returns false for a duplicate txHash or a refused credit.
   *
   * The replay key is the on-chain txHash and the entry id is `channel_pay.<txHash>`, because the chain is the only
   * identifier both sides can see (`:465-466`). The credit kind is [PopopxCreditsEntryKind.SERVICE_PAYMENT]
   * (`:472`) — MEASURED. The kind's `sign` is -1, but [credit] never consults it, so the stored row is POSITIVE like
   * every other income row and the sum of the window still agrees with the balance. The polarity a `-1` sign carries
   * is spent-side bookkeeping only; a payment received on the owner's side is recorded as income under a spending
   * category name, which is what the display layer has to know and nothing else.
   *
   * DEVIATION (one direction, no arithmetic): iOS trims this set with `Set.dropFirst` (`:478`), which removes an
   * arbitrary 1000-boundary member because a Swift `Set` has no order. A persisted Kotlin set is rebuilt from a
   * list, so this drops the OLDEST recorded hash — the same bound, the same "old transactions stop being
   * remembered" semantics, and an order a test can assert.
   */
  @Synchronized
  fun receiveChannelPayment(receipt: PopopxChannelPaymentReceipt): Boolean {
    loadIfNeeded()
    if (receivedPaymentTxHashes.contains(receipt.txHash)) {
      Log.i(TAG, "credits: duplicate channel payment receipt")
      return false
    }
    return try {
      credit(
        receipt.credits,
        PopopxCreditsEntryKind.SERVICE_PAYMENT,
        PopopxCreditsCopy.channelPaymentReceived(receipt.credits, receipt.channelId),
        "channel_pay.${receipt.txHash}",
      )
      receivedPaymentTxHashes.add(receipt.txHash)
      val excess = receivedPaymentTxHashes.size - PopopxCommerceLimits.MAXIMUM_RECEIVED_PAYMENT_TX_HASHES
      if (excess > 0) receivedPaymentTxHashes.removeAll(receivedPaymentTxHashes.take(excess).toSet())
      saveReceivedPaymentTxHashes()
      true
    } catch (e: PopopxBadgeCreditsError) {
      Log.w(TAG, "credits: channel payment could not be credited")
      false
    }
  }

  @Synchronized
  fun hasReceivedPayment(txHash: String): Boolean {
    loadIfNeeded()
    return receivedPaymentTxHashes.contains(txHash)
  }

  // MARK: Scenario · unlocking a protected profile card (`:572-599`)

  /**
   * Unlock one profile card. The dedupe key is `profileId + chatId + itemId` TOGETHER (`:594-598`): profile cards
   * are forwardable and can appear several times in one conversation, so judging on `profileId` alone would turn
   * "unlocked in conversation A" into "free in conversation B".
   */
  @Synchronized
  fun unlockProfile(profileId: String, chatId: Long, itemId: Long, price: Int, note: String): PopopxProfileUnlockReceipt {
    loadIfNeeded()
    if (price < 1 || price > PopopxCommerceLimits.MAXIMUM_CREDITS_THRESHOLD) throw PopopxBadgeCreditsError.SignalRejected
    if (hasUnlocked(profileId, chatId, itemId)) throw PopopxBadgeCreditsError.SignalRejected
    val entry = debit(price, PopopxCreditsEntryKind.PROFILE_UNLOCK, note)
    val receipt = PopopxProfileUnlockReceipt(profileId, chatId, itemId, price, entry.timestampMs, entry.id)
    profileReceipts.add(receipt)
    saveProfileReceipts()
    return receipt
  }

  @Synchronized
  fun hasUnlocked(profileId: String, chatId: Long, itemId: Long): Boolean {
    loadIfNeeded()
    return profileReceipts.any { it.profileId == profileId && it.chatId == chatId && it.itemId == itemId }
  }

  // MARK: Scenario · premium redemption (`:601-622`)

  /**
   * 20 credits for one hour of the extended anti-peeping window. Returns the SECONDS the caller may add to its own
   * window (`:605-609`): how the window counts time is that layer's contract, and this function only sells the
   * duration, so it imports nothing from it.
   */
  @Synchronized
  fun purchaseExtendedSecureWindow(note: String = PopopxCreditsCopy.secureWindow): Long {
    loadIfNeeded()
    debit(PopopxCommerceLimits.EXTENDED_SECURE_WINDOW_COST, PopopxCreditsEntryKind.SECURE_WINDOW, note)
    return PopopxCommerceLimits.EXTENDED_SECURE_WINDOW_SECONDS
  }

  /**
   * `purchase(cosmetic:)` (`:611-617`): the ledger row is the only receipt. These are applied by local rendering,
   * never uploaded and never verified, so the anti-double-purchase check is this set and nothing else (`:578`).
   */
  @Synchronized
  fun purchase(cosmetic: PopopxCosmetic, note: String = cosmetic.wireValue) {
    loadIfNeeded()
    if (ownedCosmetics.contains(cosmetic)) throw PopopxBadgeCreditsError.SignalRejected
    debit(cosmetic.cost, PopopxCreditsEntryKind.COSMETIC, note)
    ownedCosmetics.add(cosmetic)
    saveCosmetics()
  }

  @Synchronized
  fun owns(cosmetic: PopopxCosmetic): Boolean {
    loadIfNeeded()
    return ownedCosmetics.contains(cosmetic)
  }

  // MARK: Scenario · service-account card payment (`:624-639`)

  /**
   * The `pay_credits` leg of a service-account card button, and the ONLY place in this module where a ledger id
   * leaves the device: the caller puts the returned entry id into the `::CB::…:paid_<id>` callback (`:626-627`).
   *
   * That id is minted here, not issued by the service account, so the callback names *this device's record* and the
   * far side can only match it by amount plus target — which is why the note carries the target and why a replayed
   * callback is stopped by the card's own lockout rather than by this row (`:629-631`).
   *
   * iOS's version throws; the [PopopxCreditSource] seam this class implements answers "did the payment happen" with
   * null, and the eco action runner has no exception path at that seam, so the refusal is converted here and the
   * reason stays in this file. The balance check is inside [debit] and not only in the caller: a caller that skips
   * its own pre-check must still not be able to overdraw (`:633-634`).
   */
  override fun payForService(amount: Int, note: String): String? {
    loadIfNeeded()
    return try {
      debit(amount, PopopxCreditsEntryKind.SERVICE_PAYMENT, note).id
    } catch (e: PopopxBadgeCreditsError) {
      null
    }
  }

  // MARK: Wipe (`:539-542` of the Swift's `PopopxCommerceKeychain`-adjacent wipe)

  /** Forget the whole wallet: the ledger, the packets, the tickets, the receipts, the guard and this device's rows. */
  @Synchronized
  fun wipe() {
    store.wipeAll()
    wallet = PopopxCreditsWallet(PopopxCreditsWallet.CURRENT_VERSION, 0, nowMs(), false)
    ledger = mutableListOf()
    replay = PopopxReplayGuard()
    pendingPackets = mutableListOf()
    channelTickets = mutableListOf()
    profileReceipts = mutableListOf()
    receivedPaymentTxHashes = mutableSetOf()
    ownedCosmetics = mutableSetOf()
    loaded = true
  }

  // MARK: Seams

  /**
   * The Discover engine's view of this ledger.
   *
   * A separate object rather than a second interface on this class, because the two ask the same question with
   * different answers: eco's [PopopxCreditSource.payForService] returns the entry id (its callback needs the
   * receipt), discover's `PopopxDiscoverLedger.payForService` returns whether the charge happened (its engine only
   * decides whether to write the activation row). One member cannot be overridden with two return types, so this
   * class keeps the richer contract and the adapter narrows it.
   */
  fun discoverLedger(): PopopxDiscoverLedger = DiscoverView(this)

  /**
   * Whether this device can mint a signed grant at all — the sheets ask before building a form the user cannot finish.
   *
   * Read through THIS instance's store rather than [PopopxCommerceSignature.shared]: the answer must be about the
   * wallet the caller is looking at. A test-isolated instance asking the global keychain would report a key its own
   * ledger cannot sign with.
   */
  fun canSign(): Boolean = PopopxCommerceSignature(defaults).hasSigningKey()

  private class DiscoverView(private val manager: PopopxCreditsManager) : PopopxDiscoverLedger {
    override val balance: Int get() = manager.balance

    override fun payForService(amount: Int, note: String): Boolean = manager.payForService(amount, note) != null
  }

  companion object {
    /** The one instance the app wires: platform defaults, keystore-backed, iOS's `shared` (`:40`). */
    val shared: PopopxCreditsManager = PopopxCreditsManager()
  }
}

/**
 * The English fallbacks for the sentences iOS attaches to the rows it writes itself
 * (`PopopxCreditsManager.swift:659-675`, each one an NSLocalizedString). A caller with a translation table passes
 * its own sentence as the `note` parameter and never reads these; a caller without one prints what iOS prints.
 * They are NOT a localisation batch — the translated money copy lives in the app's resources, as on iOS.
 */
object PopopxCreditsCopy {
  val reversedExchange: String = "Exchange did not complete · returned automatically"
  val creditGiftReceived: String = "Received a compute-point gift card"
  val profileUnlocked: String = "Unlocked a profile card"
  val secureWindow: String = "Extended the anti-peeping viewing window"

  fun voucherExchange(period: PopopxNodeBadgePeriod, quantity: Int): String =
    "Redeemed $quantity × ${period.days}-day gift-card vouchers"

  fun creditVoucherExchange(amount: Int, quantity: Int): String = "Created $quantity × $amount compute-point gift cards"

  fun packetSent(amount: Int, recipients: Int): String =
    "Sent a red packet of $amount compute points ($recipients equal shares)"

  fun packetReceived(note: String): String =
    if (note.isEmpty()) "Received a compute-point red packet" else "Received a red packet: $note"

  fun packetRefund(amount: Int): String = "Red packet not fully claimed, $amount returned"

  fun channelSubscribed(title: String): String = "Subscribed to channel $title"

  fun channelPaymentReceived(amount: Int, channelId: Long): String =
    "Received $amount compute points from channel $channelId"
}
