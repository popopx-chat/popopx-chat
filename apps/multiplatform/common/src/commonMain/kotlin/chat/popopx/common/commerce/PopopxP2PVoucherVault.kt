package chat.popopx.common.commerce

import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.crypto.randomBytes
import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer

/**
 * The origin of a voucher: it decides which identifier reconciliation uses, never how much the voucher is worth
 * (`PopopxP2PVoucherVault.swift:39-59`). The face value comes only from `period` or `creditsAmount`.
 *
 * The receipt half is deliberately a DIGEST, not a receipt: the billing lane is not ported into this module, and
 * the two numbers this vault actually needs from a purchase are the digest (which becomes the row's
 * `transactionId`, and therefore the ledger id a refund later keys on) and the receipt's own digest for
 * [jwsDigest]. A caller holding a real store receipt passes those two strings and nothing else.
 */
sealed class PopopxVoucherSource {
  abstract val transactionId: String
  abstract val jwsDigest: String

  /**
   * Minted from a signature-verified store receipt: `transactionId` is the receipt digest.
   *
   * Not a `data class`: the second parameter is the receipt TEXT, and only its short digest may be retained. A
   * property parameter would store the text for the life of the object, which is exactly what `:53-58` avoids.
   */
  class Receipt(override val transactionId: String, receiptTextDigestOf: String) : PopopxVoucherSource() {
    /**
     * The short digest of the receipt TEXT (`:53-58`), so the text itself never reaches storage. Only the first 16
     * hex characters of it are kept, which is what makes a reconciliation possible without holding Apple ID linking
     * information on disk.
     */
    override val jwsDigest: String = PopopxCommerceSignature.shortDigest(receiptTextDigestOf)
  }

  /** Minted from a ledger entry whose deduction succeeded (`giftVoucherExchange` / `creditGiftSent`). */
  data class CreditEntry(val id: String) : PopopxVoucherSource() {
    override val transactionId: String get() = id

    /** `credit.<entry id>` — the prefix is part of the reconciliation vocabulary and is copied verbatim (`:56`). */
    override val jwsDigest: String = PopopxCommerceSignature.shortDigest("credit.$id")
  }
}

/**
 * The local vault for gift-card vouchers and the anti-double-spend arbiter
 * (`PopopxP2PVoucherVault.swift:1-33`, `:63-417`).
 *
 * It holds **two families in one table**: badge vouchers (worth `period`) and compute-credit gift cards (worth
 * `creditsAmount`). One table is a deliberate choice, not a shortcut: the double-spend defence is "one actor, one
 * flip per voucher", and a second vault would be a second copy of the persist-first / rollback / undo logic — the
 * part that must never disagree between the two families. What stays separate is the value field, the grant type,
 * the grant slot and the code prefix, so no path can read a credit voucher as a badge or the other way round.
 *
 * ### iOS's actor, and what replaces it here
 * iOS makes "check state + write state + sign" uninterleavable by declaring the vault an `actor` and never awaiting
 * inside that turn. Here the same guarantee is the monitor: every method that reads and writes `issued` is
 * [Synchronized], and none of them calls out to anything that could re-enter. A second redemption request for the
 * same voucher therefore cannot read `unused` twice.
 *
 * ### The boundary, stated plainly (no overclaiming)
 * What this holds against: concurrent redemptions on THIS device, replaying the same code, redeeming again after a
 * lost ACK. What it does not: the giver forwarding the code to several people and redeeming **on another device** —
 * that would need a server keeping a global ledger, and zero servers is the premise of this feature (`:17-22`).
 *
 * ### What does not reach storage
 * The `PPX1-…` / `PPXC1-…` code text is never written: it is a withdrawal credential, and one backup restore would
 * turn every voucher that was never sent back into a withdrawable state. Only `codeDigest` is kept (`:24-31`). The
 * giver's message is not a field of the code either, so it needs its own table ([recordNote]).
 */
class PopopxP2PVoucherVault(
  private val defaults: Settings = settings,
  private val store: PopopxCommerceStore = PopopxCommerceStore(defaults),
  private val signature: PopopxCommerceSignature = PopopxCommerceSignature(defaults),
  private val nowMs: () -> Long = { commerceNowMs() },
) {
  private val issued = ArrayList<PopopxNodeVoucher>()

  /** Receiving side: the grant text the peer brought back inside the ACK, keyed by voucher id (`:66-69`). */
  private val received = LinkedHashMap<String, PopopxBadgeGrant>()
  private val receivedCredits = LinkedHashMap<String, PopopxCreditsGrant>()

  /** The giver's message for one card, keyed by voucher id (`:73-79`). */
  private val notes = LinkedHashMap<String, String>()
  private var loaded = false

  /** Restore all four tables. Idempotent; every entry point calls it. */
  private fun loadIfNeeded() {
    if (loaded) return
    loaded = true
    issued.addAll(store.readList(PopopxNodeVoucher.serializer(), PopopxCommerceKeys.VOUCHERS))
    received.putAll(store.readMap(String.serializer(), PopopxBadgeGrant.serializer(), PopopxCommerceKeys.GRANTS))
    receivedCredits.putAll(store.readMap(String.serializer(), PopopxCreditsGrant.serializer(), PopopxCommerceKeys.CREDIT_GRANTS))
    notes.putAll(store.readMap(String.serializer(), String.serializer(), PopopxCommerceKeys.VOUCHER_NOTES))
  }

  // MARK: minting

  /**
   * Mint `quantity` badge vouchers in one go (`:97-118`).
   *
   * The quantity cap exists for exactly one reason: the whole table lives in one slot, and 200 is the dividing line
   * between a real batch ("buy 200 gift cards at once") and "writing 50,000 random numbers into a password string".
   * Exceeding it must go through several receipts, not by raising the cap.
   */
  @Synchronized
  fun mint(period: PopopxNodeBadgePeriod, quantity: Int, source: PopopxVoucherSource): List<PopopxNodeVoucher> {
    loadIfNeeded()
    val mintedAt = preparedBatch(quantity, PopopxBadgeCreditsError.VoucherUnavailable)
    val minted = (0 until quantity).map {
      PopopxNodeVoucher(
        voucherId = newVoucherId(),
        period = period,
        creditsAmount = null,
        state = PopopxVoucherState.UNUSED,
        mintedAtMs = mintedAt,
        transactionId = source.transactionId,
        jwsDigest = source.jwsDigest,
      )
    }
    return commit(minted, PopopxBadgeCreditsError.VoucherUnavailable)
  }

  /**
   * Mint `quantity` compute-credit gift cards (`:120-145`). Same batching, same persist-first rule, same arbiter as
   * a badge voucher — which is the point: one voucher id can only ever be flipped once no matter which family it
   * belongs to, so a code cannot be redeemed twice by trying it first as a badge and then as credits.
   *
   * `creditsAmount` is a pack face value, never a number typed by a user: a freely typed amount would turn a gift
   * card into a money-transfer instrument, which is exactly the tier the red-packet rule stays under.
   */
  @Synchronized
  fun mintCredit(creditsAmount: Int, quantity: Int, source: PopopxVoucherSource): List<PopopxNodeVoucher> {
    loadIfNeeded()
    if (creditsAmount <= 0) throw PopopxBadgeCreditsError.CreditVoucherUnavailable
    val mintedAt = preparedBatch(quantity, PopopxBadgeCreditsError.CreditVoucherUnavailable)
    val minted = (0 until quantity).map {
      PopopxNodeVoucher(
        voucherId = newVoucherId(),
        period = null,
        creditsAmount = creditsAmount,
        state = PopopxVoucherState.UNUSED,
        mintedAtMs = mintedAt,
        transactionId = source.transactionId,
        jwsDigest = source.jwsDigest,
      )
    }
    return commit(minted, PopopxBadgeCreditsError.CreditVoucherUnavailable)
  }

  /** The batch gate both mints share, returning the mint timestamp (`:147-152`). */
  private fun preparedBatch(quantity: Int, unavailable: PopopxBadgeCreditsError): Long {
    if (quantity < 1 || quantity > PopopxCommerceLimits.MAXIMUM_VOUCHERS) throw unavailable
    if (issued.size + quantity > PopopxCommerceLimits.MAXIMUM_VOUCHERS) throw unavailable
    return nowMs()
  }

  /**
   * Append and persist BEFORE returning the rows (`:154-164`). Persist first: if a voucher handed to the UI was
   * never written, the user sees it gone at the next entry while the receipt for it has already been finished —
   * the exact shape of "paid and received nothing". A failed write rolls the in-memory table back.
   */
  private fun commit(minted: List<PopopxNodeVoucher>, unavailable: PopopxBadgeCreditsError): List<PopopxNodeVoucher> {
    issued.addAll(minted)
    if (store.writeList(PopopxNodeVoucher.serializer(), PopopxCommerceKeys.VOUCHERS, issued)) return minted
    issued.removeAll(minted.toSet())
    throw unavailable
  }

  /** A voucher id is a UUID string, lower-cased: 36 characters, which is what the 40-character parse cap is sized against. */
  private fun newVoucherId(): String = commerceNewUuid()

  // MARK: reading the table

  /** Credit rows of one state, or of every state when `state` is null (`:168-173`). */
  @Synchronized
  fun creditVouchers(state: PopopxVoucherState? = null): List<PopopxNodeVoucher> {
    loadIfNeeded()
    return issued.filter { it.isCreditVoucher && (state == null || it.state == state) }
  }

  /** Every row, both families (`:175-179`). */
  @Synchronized
  fun vouchers(state: PopopxVoucherState? = null): List<PopopxNodeVoucher> {
    loadIfNeeded()
    return if (state == null) issued.toList() else issued.filter { it.state == state }
  }

  /**
   * Badge rows only — the entry point every badge call site uses, so "which rows may become a `PPX1-` code" is
   * answered in ONE place instead of at each `filter { it.period != null }` (`:181-186`).
   */
  @Synchronized
  fun badgeVouchers(state: PopopxVoucherState? = null): List<PopopxNodeVoucher> {
    loadIfNeeded()
    return issued.filter { !it.isCreditVoucher && (state == null || it.state == state) }
  }

  @Synchronized
  fun voucher(voucherId: String): PopopxNodeVoucher? {
    loadIfNeeded()
    return issued.firstOrNull { it.voucherId == voucherId }
  }

  /**
   * Record the digest carried inside a code: "this voucher was sent out". The code itself is not stored (`:193-199`).
   * A failed persist leaves the in-memory row changed, which is iOS's behaviour too — the digest is traceability,
   * not an entitlement, and the row it belongs to is still `unused`.
   */
  @Synchronized
  fun recordCodeDigest(digest: String, voucherId: String) {
    loadIfNeeded()
    val index = issued.indexOfFirst { it.voucherId == voucherId }
    if (index < 0) return
    issued[index] = issued[index].copy(codeDigest = digest)
    store.writeList(PopopxNodeVoucher.serializer(), PopopxCommerceKeys.VOUCHERS, issued)
  }

  /** The giver's message for one card, or `""` when nothing was stored (`:201-206`). */
  @Synchronized
  fun note(voucherId: String): String {
    loadIfNeeded()
    return notes[voucherId] ?: ""
  }

  /**
   * Attach one message to a batch of freshly minted cards and persist it before returning (`:208-233`).
   *
   * A batch takes ONE message on purpose: the text belongs to the purchase, and nothing here guesses a different
   * sentence per card. Ids with no row are skipped rather than written, so the table can never outlive the
   * vouchers it describes. An empty message DELETES the row instead of storing "", which keeps "the giver typed
   * nothing" and "this card predates the table" one readable state. A failed write rolls back.
   */
  @Synchronized
  fun recordNote(note: String, voucherIds: List<String>): Boolean {
    loadIfNeeded()
    val clipped = note.commercePrefix(PopopxCommerceLimits.MAXIMUM_NOTE_CHARACTERS)
    val ids = voucherIds.filter { id -> issued.any { it.voucherId == id } }.toSet()
    if (ids.isEmpty()) return false
    val rollback = LinkedHashMap(notes)
    for (id in ids) {
      if (clipped.isEmpty()) notes.remove(id) else notes[id] = clipped
    }
    if (store.writeMap(String.serializer(), String.serializer(), PopopxCommerceKeys.VOUCHER_NOTES, notes)) return true
    notes.clear()
    notes.putAll(rollback)
    return false
  }

  /**
   * The giver voids a voucher that has not been sent out yet (`:235-258`).
   *
   * A redeemed voucher CANNOT be deleted: that is an entitlement somebody else paid for, and deleting the record
   * would not make their badge disappear, it would only leave reconciliation one row short. The message goes with
   * the row. Both tables are written only after both in-memory changes succeeded, and either failure puts both back:
   * half a delete persisted is a card that came back with its message gone, or a message that outlived its card.
   */
  @Synchronized
  fun discard(voucherId: String): Boolean {
    loadIfNeeded()
    val index = issued.indexOfFirst { it.voucherId == voucherId }
    if (index < 0 || issued[index].state != PopopxVoucherState.UNUSED) return false
    val rollbackVouchers = issued.toMutableList()
    val rollbackNotes = LinkedHashMap(notes)
    issued.removeAt(index)
    notes.remove(voucherId)
    if (store.writeList(PopopxNodeVoucher.serializer(), PopopxCommerceKeys.VOUCHERS, issued) &&
      store.writeMap(String.serializer(), String.serializer(), PopopxCommerceKeys.VOUCHER_NOTES, notes)
    ) {
      return true
    }
    issued.clear()
    issued.addAll(rollbackVouchers)
    notes.clear()
    notes.putAll(rollbackNotes)
    store.writeList(PopopxNodeVoucher.serializer(), PopopxCommerceKeys.VOUCHERS, issued)
    store.writeMap(String.serializer(), String.serializer(), PopopxCommerceKeys.VOUCHER_NOTES, notes)
    return false
  }

  // MARK: arbitration

  /**
   * The badge redemption entry point, and the only place a badge voucher's state may ever be flipped (`:260-288`).
   * Null means "this voucher has already been redeemed", which is an answer the caller must report back to the
   * other side honestly rather than an exception.
   *
   * `codeDigestSource` is supplied by the caller: a one-time-link redemption passes "the code text", an in-session
   * card redemption passes that signalling text verbatim. Both are only evidence of WHICH code redeemed this
   * voucher; neither takes part in the liveness decision.
   */
  @Synchronized
  fun authorizeRedemption(voucherId: String, codeDigestSource: String): PopopxBadgeGrant? {
    loadIfNeeded()
    val index = issued.indexOfFirst { it.voucherId == voucherId }
    if (index < 0) return null
    if (issued[index].state != PopopxVoucherState.UNUSED) return null
    // A credit voucher has no period, so it cannot be authorised as a badge — the second lock; the first is that a
    // `PPXC1-` code never decodes into a badge envelope at all.
    val period = issued[index].period ?: return null
    val grantedAt = nowMs()
    // This computes "now + N days" on the GIVER's machine. It enters the signed payload as a promise of how many
    // days the voucher gives; the recipient does NOT use it as their own expiry, they re-land the days with
    // `PopopxBadgeManager.stackedExpiryMs` (`:279-287`).
    val expiresAt = grantedAt + period.days.toLong() * 86_400_000L
    if (!markRedeemed(index, grantedAt, codeDigestSource)) return null
    return signGrant(voucherId, period, grantedAt, expiresAt)
  }

  /** The credit twin of [authorizeRedemption], the same single uninterleaved turn: check, flip, persist, sign (`:290-302`). */
  @Synchronized
  fun authorizeCreditRedemption(voucherId: String, codeDigestSource: String): PopopxCreditsGrant? {
    loadIfNeeded()
    val index = issued.indexOfFirst { it.voucherId == voucherId }
    if (index < 0) return null
    if (issued[index].state != PopopxVoucherState.UNUSED) return null
    val amount = issued[index].creditsAmount ?: return null
    val grantedAt = nowMs()
    if (!markRedeemed(index, grantedAt, codeDigestSource)) return null
    return signCreditGrant(voucherId, amount, grantedAt)
  }

  /**
   * Flip one row to `redeemed` and persist it BEFORE anything is signed (`:304-319`). In the reverse order a failed
   * write would leave a voucher that is "already granted but still unused" — that is what a double spend really is.
   * False means the row was reverted and the caller must hand back null: better the recipient sees "the redemption
   * did not go through, retry" than that they hold a grant the local record no longer acknowledges.
   */
  private fun markRedeemed(index: Int, nowMs: Long, codeDigestSource: String): Boolean {
    val before = issued[index]
    issued[index] = before.copy(
      state = PopopxVoucherState.REDEEMED,
      redeemedAtMs = nowMs,
      codeDigest = PopopxCommerceSignature.shortDigest(codeDigestSource),
    )
    if (store.writeList(PopopxNodeVoucher.serializer(), PopopxCommerceKeys.VOUCHERS, issued)) return true
    issued[index] = before
    return false
  }

  /**
   * The grant text (`:321-345`). The canonical `grant` string carries four fields only — no free-form copy, no
   * invite link — because once a signature covers mutable text, one character changed by the other party stops
   * matching, and that is a perfectly legitimate content change.
   *
   * An empty public key means this device's signing key could not be fetched. At that point you must never sign a
   * grant whose public-key field is empty: verification on the recipient's side fails every time, and the user sees
   * only "the other party did not confirm this redemption" while what is broken is this device's storage.
   */
  private fun signGrant(voucherId: String, period: PopopxNodeBadgePeriod, grantedAtMs: Long, expiresAtMs: Long): PopopxBadgeGrant? {
    val publicKey = signature.localPublicKeyBase64URL()
    if (publicKey.isEmpty()) return null
    val text = signature.signatureBase64URL(
      PopopxCommerceSignature.canonicalGrant(voucherId, period, grantedAtMs, expiresAtMs),
    ) ?: return null
    return PopopxBadgeGrant(voucherId, period, grantedAtMs, expiresAtMs, publicKey, text)
  }

  /** The credit twin: three fields, `kind: "credit_grant"`, so a badge grant's signature never verifies as one over credits (`:347-366`). */
  private fun signCreditGrant(voucherId: String, creditsAmount: Int, grantedAtMs: Long): PopopxCreditsGrant? {
    val publicKey = signature.localPublicKeyBase64URL()
    if (publicKey.isEmpty()) return null
    val text = signature.signatureBase64URL(
      PopopxCommerceSignature.canonicalCreditGrant(voucherId, creditsAmount, grantedAtMs),
    ) ?: return null
    return PopopxCreditsGrant(voucherId, creditsAmount, grantedAtMs, publicKey, text)
  }

  // MARK: receiving side

  /**
   * After the ACK arrives, verify the signature FIRST and then store (`:371-378`). A forged grant that entered the
   * local record would let the later activation light a badge nobody ever paid for.
   */
  @Synchronized
  fun record(grant: PopopxBadgeGrant): Boolean {
    loadIfNeeded()
    if (!grant.isSignatureValid) return false
    received[grant.voucherId] = grant
    return store.writeMap(String.serializer(), PopopxBadgeGrant.serializer(), PopopxCommerceKeys.GRANTS, received)
  }

  @Synchronized
  fun grant(voucherId: String): PopopxBadgeGrant? {
    loadIfNeeded()
    return received[voucherId]
  }

  /** All valid grants on the receiving side: verified once when they came in, never verified again, kept for reconciliation display (`:385-389`). */
  @Synchronized
  fun receivedGrants(): List<PopopxBadgeGrant> {
    loadIfNeeded()
    return received.values.sortedByDescending { it.grantedAtMs }
  }

  /** Storing a credit grant: verify first, then write — this time the thing at stake is the number itself (`:397-405`). */
  @Synchronized
  fun recordCredit(grant: PopopxCreditsGrant): Boolean {
    loadIfNeeded()
    if (!grant.isSignatureValid) return false
    receivedCredits[grant.voucherId] = grant
    return store.writeMap(String.serializer(), PopopxCreditsGrant.serializer(), PopopxCommerceKeys.CREDIT_GRANTS, receivedCredits)
  }

  @Synchronized
  fun creditGrant(voucherId: String): PopopxCreditsGrant? {
    loadIfNeeded()
    return receivedCredits[voucherId]
  }

  @Synchronized
  fun receivedCreditGrants(): List<PopopxCreditsGrant> {
    loadIfNeeded()
    return receivedCredits.values.sortedByDescending { it.grantedAtMs }
  }

  /**
   * The minted count of one family, for the panel's "N vouchers available". Not an iOS method: the iOS view reads
   * `vouchers(state:)?.count`, and a Kotlin view of the same panel must not have to load the whole table to answer
   * a number, so it is exposed rather than recomputed at the call site.
   */
  @Synchronized
  fun count(state: PopopxVoucherState? = null, credit: Boolean): Int {
    loadIfNeeded()
    return issued.count { (state == null || it.state == state) && it.isCreditVoucher == credit }
  }

  companion object {
    val shared: PopopxP2PVoucherVault = PopopxP2PVoucherVault()
  }
}
