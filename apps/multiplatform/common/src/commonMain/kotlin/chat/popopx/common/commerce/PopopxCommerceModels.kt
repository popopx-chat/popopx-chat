package chat.popopx.common.commerce

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// The value types of the badge / compute-credit feature, ported from
// `apps/ios/Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift`. Field names, enum spellings and wire
// values are the iOS ones character for character: a voucher id, a ledger entry id and a digest are what the two
// platforms have to agree on, and a renamed field is a silent "no records found" after a device migration.
//
// Time is `Long` milliseconds since the epoch everywhere. iOS passes `Date` and injects `now` into every decision
// so a test can hit the expiry fallback (`:375-382`); the injection is the part worth keeping, so `nowMs` is a
// parameter here too, and where iOS reads the clock implicitly it is named in the signature instead.

// MARK: - Badge period and source

/**
 * The badge period (`:79-125`). Subscription, gift voucher and credit redemption all reuse it, so no second
 * spelling of "how long" can appear.
 */
enum class PopopxNodeBadgePeriod(val wireValue: String, val days: Int, val creditsCost: Int) {
  /**
   * Calendar-day count, used to derive the expiry when issuing locally — not the billing period, which belongs to
   * the store. `creditsCost` is the calibrated credit price, and 600 / 4_500 (not 30×20 / 365×20) is the measured
   * answer to "what does the yearly actually cost in this currency": the number is given once, here, and every
   * redemption page, store page and review doc comes back to it (`:93-101`).
   */
  @SerialName("monthly")
  MONTHLY("m", 30, 600),

  @SerialName("annual")
  ANNUAL("y", 365, 4_500);

  companion object {
    /** The single-letter URI form; anything else is not a period, and `null` means "reject the payload". */
    fun fromWire(raw: String?): PopopxNodeBadgePeriod? = when (raw) {
      "m" -> MONTHLY
      "y" -> ANNUAL
      else -> null
    }

    fun fromRawValue(raw: String?): PopopxNodeBadgePeriod? = when (raw) {
      "monthly" -> MONTHLY
      "annual" -> ANNUAL
      else -> null
    }
  }
}

/**
 * Where a badge came from (`:301-311`). Trial, subscription, one-off time pack, credit redemption, a voucher
 * gifted by someone else — the five sources light the same badge and differ only in who owns the renewal.
 */
enum class PopopxBadgeSource {
  @SerialName("pioneerTrial")
  PIONEER_TRIAL,

  @SerialName("appleSubscription")
  APPLE_SUBSCRIPTION,

  /** One-off time pack: pay once, get a stretch of time, no renewal switch, and not part of restore-purchase (`:304-305`). */
  @SerialName("storePass")
  STORE_PASS,

  @SerialName("creditsExchange")
  CREDITS_EXCHANGE,

  @SerialName("giftedVoucher")
  GIFTED_VOUCHER;

  /** Only the subscription tier is auto-renewed by the store; restore-purchase is meaningful for it alone (`:310`). */
  val renewsAutomatically: Boolean get() = this == APPLE_SUBSCRIPTION

  companion object {
    fun fromRawValue(raw: String?): PopopxBadgeSource? = when (raw) {
      "pioneerTrial" -> PIONEER_TRIAL
      "appleSubscription" -> APPLE_SUBSCRIPTION
      "storePass" -> STORE_PASS
      "creditsExchange" -> CREDITS_EXCHANGE
      "giftedVoucher" -> GIFTED_VOUCHER
      else -> null
    }
  }
}

// MARK: - Badge record and phase

/**
 * The persisted shape of one badge record (`:313-325`). Only `PopopxBadgeManager` ever writes it.
 */
@Serializable
data class PopopxBadgeRecord(
  val period: PopopxNodeBadgePeriod,
  val source: PopopxBadgeSource,
  val issuedAtMs: Long,
  val expiresAtMs: Long,
  /** The node-route rotation counter; on a machine with no verified route move it is only a local count (`:319-320`). */
  val rotationIndex: Int,
  /** The first 16 hex characters of the source credential's SHA-256, for after-the-fact reconciliation (`:321-322`). */
  val receiptDigest: String? = null,
  /** The trial badge's anti-replay fingerprint (`:323-324`). */
  val trialGuard: String? = null,
)

/** The state capsule rendering needs, kept apart from [PopopxBadgePhase] so no view compares dates itself (`:327-335`). */
enum class PopopxBadgeCapsuleState { TRIAL_PULSING, ACTIVE_LIT, DORMANT }

/**
 * The badge's three states (`:337-383`). `DORMANT` is not "failure": it is the ordinary "using the free public
 * relay" state, and copy must not call it expired or not-activated.
 */
sealed class PopopxBadgePhase {
  abstract val capsuleState: PopopxBadgeCapsuleState
  abstract val isLit: Boolean

  /** Remaining seconds, clamped at 0; `nowMs` is injected rather than read so a test can sit past the deadline. */
  abstract fun remainingSeconds(nowMs: Long): Long

  /** The expiry instant in milliseconds, or null when dormant — a caller must not be able to render "1970" (`:367-373`). */
  abstract val expiresAtMs: Long?

  object Dormant : PopopxBadgePhase() {
    override val capsuleState: PopopxBadgeCapsuleState = PopopxBadgeCapsuleState.DORMANT
    override val isLit: Boolean = false
    override fun remainingSeconds(nowMs: Long): Long = 0
    override val expiresAtMs: Long? = null
  }

  data class Trial(override val expiresAtMs: Long) : PopopxBadgePhase() {
    override val capsuleState: PopopxBadgeCapsuleState = PopopxBadgeCapsuleState.TRIAL_PULSING
    override val isLit: Boolean = true
    override fun remainingSeconds(nowMs: Long): Long = maxOf(0L, (expiresAtMs - nowMs) / 1_000)
  }

  data class Active(val source: PopopxBadgeSource, override val expiresAtMs: Long) : PopopxBadgePhase() {
    override val capsuleState: PopopxBadgeCapsuleState = PopopxBadgeCapsuleState.ACTIVE_LIT
    override val isLit: Boolean = true
    override fun remainingSeconds(nowMs: Long): Long = maxOf(0L, (expiresAtMs - nowMs) / 1_000)
  }

  companion object {
    /**
     * Derivation from the record (`:375-382`), the only place the three states are computed. A record whose expiry
     * has passed is dormant, not "0 seconds left" — the caller cannot tell the two apart from a number.
     */
    fun phaseFor(record: PopopxBadgeRecord?, nowMs: Long): PopopxBadgePhase {
      val existing = record ?: return Dormant
      if (existing.expiresAtMs <= nowMs) return Dormant
      return if (existing.source == PopopxBadgeSource.PIONEER_TRIAL) Trial(existing.expiresAtMs)
      else Active(existing.source, existing.expiresAtMs)
    }
  }
}

// MARK: - Vouchers and grants

/**
 * The voucher's lifecycle (`:388-392`). `CONSUMED` exists only on the receiving side: the grant the peer returned
 * has already lit this device's badge, so the voucher has landed.
 */
enum class PopopxVoucherState {
  @SerialName("unused") UNUSED,

  @SerialName("redeemed") REDEEMED,

  @SerialName("consumed") CONSUMED,
}

/**
 * A transferable voucher minted locally — a gift badge **or** a compute-credit gift card, one table and one
 * double-spend arbiter for both (`:394-433`).
 *
 * `period` is nullable **because a credit voucher has no period at all**, and the optionality is what stops a
 * credit voucher from becoming a badge code: every badge path has to unwrap it and the unwrap fails there
 * (`:399-401`). `creditsAmount` is the mirror. Nothing infers the family from `period == null` — it is read from
 * [isCreditVoucher], so a half-filled row cannot pose as either (`:402-405`).
 *
 * `jwsDigest` is the digest of the source credential. The credential text itself is never stored: it carries
 * account-linking information, and keeping it in a backup only moves the risk (`:395-396`).
 */
@Serializable
data class PopopxNodeVoucher(
  val voucherId: String,
  val period: PopopxNodeBadgePeriod? = null,
  val creditsAmount: Int? = null,
  val state: PopopxVoucherState,
  val mintedAtMs: Long,
  val transactionId: String,
  val jwsDigest: String,
  /** The digest of the redemption code — the code text is never persisted (`:410-411`). */
  val codeDigest: String? = null,
  val redeemedAtMs: Long? = null,
  /** A field only the receiver has: the authorisation text the peer ACKed back (`:413-414`). */
  val grantBase64URL: String? = null,
) {
  val isRedeemable: Boolean get() = state == PopopxVoucherState.UNUSED

  val isCreditVoucher: Boolean get() = creditsAmount != null

  /**
   * The day count the badge screens print (`:422-427`). `0` is unreachable there by construction — those lists come
   * from `badgeVouchers()`, which drops the credit rows — but it answers a number instead of trapping because a
   * wrong figure is corrected by the next refresh while a crash leaves the user holding a page that will not open.
   */
  val badgeDays: Int get() = period?.days ?: 0

  /** The face value the credit screens print, the exact twin of [badgeDays] for the exact same reason (`:429-432`). */
  val creditFaceValue: Int get() = creditsAmount ?: 0
}

/**
 * The letter of authorisation for a compute-credit gift card (`:435-458`).
 *
 * A separate type rather than a grant with an optional period, because the two attest different facts: a badge
 * grants a deadline computed from the giver's clock, credits grant a number and **never expire**. Carrying
 * `expiresAtMs = 0` for credits would give "when does this run out" two answers in one struct, and since the
 * signature covers the canonical bytes a reused type would also let a badge signature be replayed as a credit grant.
 */
@Serializable
data class PopopxCreditsGrant(
  val voucherId: String,
  val creditsAmount: Int,
  val grantedAtMs: Long,
  /** The x9.63 public key of the giver's local key, unpadded base64url. */
  val giverPublicKey: String,
  /** The ECDSA P-256 signature over [canonicalBytes]: DER, unpadded base64url. */
  val signature: String,
) {
  fun canonicalBytes(): ByteArray = PopopxCommerceSignature.canonicalCreditGrant(voucherId, creditsAmount, grantedAtMs)

  val isSignatureValid: Boolean
    get() = PopopxCommerceSignature.shared.verify(signature, canonicalBytes(), giverPublicKey)
}

/**
 * The voucher's letter of authorisation (`:460-479`): signed locally by the giver, returned to the redeemer with
 * the ACK, and the redeemer lights the badge from it. Because the signature covers the canonical bytes, changing
 * the period from `m` to `y` fails verification on the spot.
 */
@Serializable
data class PopopxBadgeGrant(
  val voucherId: String,
  val period: PopopxNodeBadgePeriod,
  val grantedAtMs: Long,
  val expiresAtMs: Long,
  val giverPublicKey: String,
  val signature: String,
) {
  fun canonicalBytes(): ByteArray =
    PopopxCommerceSignature.canonicalGrant(voucherId, period, grantedAtMs, expiresAtMs)

  val isSignatureValid: Boolean
    get() = PopopxCommerceSignature.shared.verify(signature, canonicalBytes(), giverPublicKey)
}

// MARK: - Redemption envelopes

/**
 * What a `PPX1-…` badge code holds: a one-time connection link + a voucher's identity + the giver's key (`:481-504`).
 *
 * The body JSON is written and read by hand, not by the default serializer, because those bytes are the signature
 * preimage: `period` goes out as its rawValue `monthly` (never the URI letter `m`), keys are sorted, `/` is escaped
 * as `\/`. See [bodyBytes] and [parse], and the pinned Apple vectors.
 */
data class PopopxRedeemEnvelope(
  val inviteLink: String,
  val voucherId: String,
  val period: PopopxNodeBadgePeriod,
  val mintedAtMs: Long,
  /** 16 random bytes; tells two codes for the same voucher apart (`:490-491`). */
  val nonce: String,
  val giverPublicKey: String,
  val signature: String,
) {
  fun canonicalBytes(): ByteArray =
    PopopxCommerceSignature.canonicalCode(voucherId, period, mintedAtMs, nonce, inviteLink)

  val isSignatureValid: Boolean
    get() = PopopxCommerceSignature.shared.verify(signature, canonicalBytes(), giverPublicKey)

  /** The exact `JSONEncoder([.sortedKeys])` preimage of [canonicalBytes]'s signature. */
  fun bodyBytes(): ByteArray = PopopxSwiftJson.body(
    listOf(
      "inviteLink" to inviteLink,
      "voucherId" to voucherId,
      "period" to period.name.lowercase(),
      "mintedAtMs" to mintedAtMs,
      "nonce" to nonce,
      "giverPublicKey" to giverPublicKey,
      "signature" to signature,
    ),
  ).encodeToByteArray()

  companion object {
    /** Strict: a missing or mistyped field rejects the whole envelope. */
    fun parse(body: ByteArray): PopopxRedeemEnvelope? = try {
      val object_ = commerceParse(body.decodeToString())
      val period = PopopxNodeBadgePeriod.fromRawValue(object_.commerceStringOrThrow("period")) ?: throw CommerceReject()
      PopopxRedeemEnvelope(
        inviteLink = object_.commerceStringOrThrow("inviteLink"),
        voucherId = object_.commerceStringOrThrow("voucherId"),
        period = period,
        mintedAtMs = object_.commerceLongOrThrow("mintedAtMs"),
        nonce = object_.commerceStringOrThrow("nonce"),
        giverPublicKey = object_.commerceStringOrThrow("giverPublicKey"),
        signature = object_.commerceStringOrThrow("signature"),
      )
    } catch (e: Exception) {
      null
    }
  }
}

/**
 * The credit twin of [PopopxRedeemEnvelope] (`:506-531`). It has **no period field**, which is the type-level half
 * of "a `PPXC1-` code can never light a badge": the badge path decodes into the envelope above and cannot build one
 * from these bytes, and the canonical `kind` differs too, so a signature over one never verifies as the other.
 */
data class PopopxCreditRedeemEnvelope(
  val inviteLink: String,
  val voucherId: String,
  val creditsAmount: Int,
  val mintedAtMs: Long,
  val nonce: String,
  val giverPublicKey: String,
  val signature: String,
) {
  fun canonicalBytes(): ByteArray =
    PopopxCommerceSignature.canonicalCreditCode(voucherId, creditsAmount, mintedAtMs, nonce, inviteLink)

  val isSignatureValid: Boolean
    get() = PopopxCommerceSignature.shared.verify(signature, canonicalBytes(), giverPublicKey)

  fun bodyBytes(): ByteArray = PopopxSwiftJson.body(
    listOf(
      "creditsAmount" to creditsAmount,
      "inviteLink" to inviteLink,
      "voucherId" to voucherId,
      "mintedAtMs" to mintedAtMs,
      "nonce" to nonce,
      "giverPublicKey" to giverPublicKey,
      "signature" to signature,
    ),
  ).encodeToByteArray()

  companion object {
    fun parse(body: ByteArray): PopopxCreditRedeemEnvelope? = try {
      val object_ = commerceParse(body.decodeToString())
      PopopxCreditRedeemEnvelope(
        inviteLink = object_.commerceStringOrThrow("inviteLink"),
        voucherId = object_.commerceStringOrThrow("voucherId"),
        creditsAmount = object_.commerceIntOrThrow("creditsAmount"),
        mintedAtMs = object_.commerceLongOrThrow("mintedAtMs"),
        nonce = object_.commerceStringOrThrow("nonce"),
        giverPublicKey = object_.commerceStringOrThrow("giverPublicKey"),
        signature = object_.commerceStringOrThrow("signature"),
      )
    } catch (e: Exception) {
      null
    }
  }
}

// MARK: - Ledger categories

/**
 * The ledger categories and their signs (`:1210-1253`). `sign` is defined once here and the UI's plus/minus and
 * colours both derive from it.
 *
 * Three kinds answer `null`, for two different reasons, and the difference is what makes the switch worth reading
 * case by case: `storePurchase` and `redPacketReceived` are pure income, so `credit` adds the number as given and
 * never consults `sign` (`:127-135`); `adjustment` is the one kind that can go EITHER way — a refund clawback and
 * an exchange reversal are both negative, a top-up that had to be undone later is not — so the entry carries its
 * own polarity (`:1235`). A negative `sign` is the gate [PopopxCreditsManager] uses to refuse a spend against an
 * income category, so an amount's polarity has exactly one source in the whole project (`:152-156`).
 */
enum class PopopxCreditsEntryKind(val wireValue: String, val sign: Int?) {
  @SerialName("storePurchase")
  STORE_PURCHASE("storePurchase", null),

  @SerialName("badgeExchange")
  BADGE_EXCHANGE("badgeExchange", -1),

  @SerialName("giftVoucherExchange")
  GIFT_VOUCHER_EXCHANGE("giftVoucherExchange", -1),

  /** Paying credits to mint a compute-credit gift card. A spend, and nothing in this module ever reverses it (`:1214-1216`). */
  @SerialName("creditGiftSent")
  CREDIT_GIFT_SENT("creditGiftSent", -1),

  /** Receiving credits from someone else's gift card: the only credit leg this device gains without a store purchase (`:1217-1218`). */
  @SerialName("creditGiftReceived")
  CREDIT_GIFT_RECEIVED("creditGiftReceived", 1),

  @SerialName("redPacketSent")
  RED_PACKET_SENT("redPacketSent", -1),

  @SerialName("redPacketReceived")
  RED_PACKET_RECEIVED("redPacketReceived", null),

  @SerialName("redPacketRefund")
  RED_PACKET_REFUND("redPacketRefund", 1),

  @SerialName("channelSubscription")
  CHANNEL_SUBSCRIPTION("channelSubscription", -1),

  /**
   * Paying a service account for something its card button sells. Deliberately NOT [CHANNEL_SUBSCRIPTION]: that leg
   * mints a local ticket with an expiry, this one only produces a ledger row whose id goes into the callback
   * (`:1222-1227`).
   */
  @SerialName("servicePayment")
  SERVICE_PAYMENT("servicePayment", -1),

  @SerialName("profileUnlock")
  PROFILE_UNLOCK("profileUnlock", -1),

  @SerialName("secureWindow")
  SECURE_WINDOW("secureWindow", -1),

  @SerialName("cosmetic")
  COSMETIC("cosmetic", -1),

  /** Either direction, so [sign] is null and the entry carries its own polarity (`:1235`). */
  @SerialName("adjustment")
  ADJUSTMENT("adjustment", null);

  /**
   * Listed case by case with no fallback (`:1245-1252`): a new ledger category has to be answered for here.
   * Note it is NOT the same set as [sign] — a refund and a gift card in are income, an `adjustment` can be either.
   */
  val isIncome: Boolean
    get() = when (this) {
      STORE_PURCHASE, RED_PACKET_RECEIVED, RED_PACKET_REFUND, CREDIT_GIFT_RECEIVED -> true
      BADGE_EXCHANGE, GIFT_VOUCHER_EXCHANGE, CREDIT_GIFT_SENT, RED_PACKET_SENT, CHANNEL_SUBSCRIPTION,
      SERVICE_PAYMENT, PROFILE_UNLOCK, SECURE_WINDOW, COSMETIC, ADJUSTMENT -> false
    }

  companion object {
    fun fromWire(raw: String?): PopopxCreditsEntryKind? = values().firstOrNull { it.wireValue == raw }
  }
}

/**
 * One ledger row (`:1255-1264`). `id` doubles as the anti-replay key, so it is at once the accounting primary key
 * and the dedupe key — which is why derived ids (`refund.<digest>`, `claim.<packetId>`, `channel_pay.<txHash>`)
 * are copied verbatim from iOS and are NOT free to rename.
 */
@Serializable
data class PopopxCreditsEntry(
  val id: String,
  val amount: Int,
  val kind: PopopxCreditsEntryKind,
  val note: String,
  val timestampMs: Long,
  /** The balance snapshot after the entry; null for rows written before the field existed, and the UI hides the line then. */
  val balanceAfter: Int? = null,
)

/**
 * The wallet (`:1266-1276`). It lives in secure storage, not in a file: if a tool tampers with the balance on this
 * device, what it tampers with is ciphertext, not a plaintext plist.
 */
@Serializable
data class PopopxCreditsWallet(
  val version: Int,
  var balance: Int,
  var updatedAtMs: Long,
  /**
   * Set when the balance and the ledger disagree. Better to show "needs reconcile" than to silently spend a wrong
   * book as a balance (`:1274-1275`).
   */
  var needsReconcile: Boolean,
) {
  companion object {
    const val CURRENT_VERSION = 1

    fun empty(nowMs: Long): PopopxCreditsWallet =
      PopopxCreditsWallet(CURRENT_VERSION, 0, nowMs, false)
  }
}

/**
 * A red packet that has not been fully claimed, held by the SENDER for ACK checking and refund (`:1278-1307`).
 */
@Serializable
data class PopopxPendingRedPacket(
  val packetId: String,
  val amount: Int,
  val note: String,
  val recipientCount: Int,
  var claimedCount: Int,
  val createdAtMs: Long,
  /** The amount one person is owed in an even split; for a single-share packet it equals `amount`. */
  val amountPerRecipient: Int,
  var settled: Boolean,
  /**
   * The group members who already ACKed (`:1289-1293`). Nullable and absent-by-default on purpose: a direct packet
   * has no notion of a member, and an absent key must not read as "nobody claimed". It is only a **dedupe set** —
   * the refund amount comes from [claimedCount].
   */
  var claimKeys: List<String>? = null,
) {
  val isFullyClaimed: Boolean get() = claimedCount >= recipientCount || settled

  /**
   * The earliest moment this side may refund the remainder (`:1299-1301`). Refunding earlier would let the shares
   * still sitting in the group be claimed afterwards, and those credits would be created out of nothing.
   */
  val claimGraceEndsAtMs: Long get() = createdAtMs + PopopxCommerceLimits.PACKET_CLAIM_GRACE_SECONDS * 1_000

  /** The unclaimed part, computable only on this side because no server holds a fallback ledger (`:1303-1306`). */
  val refundableAmount: Int get() = maxOf(0, amount - claimedCount * amountPerRecipient)
}

/**
 * A channel subscription credential (`:1309-1327`). The owner sets the price, a member who paid locally holds a
 * ticket with an expiry.
 */
@Serializable
data class PopopxChannelSubscriptionTicket(
  val channelId: String,
  val channelTitle: String,
  val price: Int,
  val paidAtMs: Long,
  val expiresAtMs: Long,
  val transactionId: String,
  /**
   * The publisher key of the card this ticket was signed against (`:1317-1320`). Nullable for compatibility: a
   * pre-upgrade ticket's JSON has no such key, and a non-optional field would fail the decode of the WHOLE array,
   * turning everybody's "subscribed" into never having subscribed. Old tickets take no part in the anti-impersonation
   * comparison.
   */
  val issuerPublicKeyBase64URL: String? = null,
) {
  fun isValidAt(nowMs: Long): Boolean = expiresAtMs > nowMs
}

/** The receipt left after unlocking a protected profile page (`:1329-1339`). */
@Serializable
data class PopopxProfileUnlockReceipt(
  val profileId: String,
  val chatId: Long,
  val itemId: Long,
  val price: Int,
  val unlockedAtMs: Long,
  val transactionId: String,
)

/**
 * Channel payment receipt: member pays, channel owner credits (`:1341-1368`). The txHash gives the replay protection
 * on the owner's side.
 */
data class PopopxChannelPaymentReceipt(
  val channelId: Long,
  val credits: Int,
  val txHash: String,
  val paidAtMs: Long,
) {
  /** `{channelId}:{credits}:{txHash}` (`:1364-1367`). */
  fun wireString(): String = "$channelId:$credits:$txHash"

  companion object {
    /**
     * Split on the first two colons (`:1350-1355`): `maxSplits: 2` in Swift means the THIRD part keeps every
     * remaining colon, so a hash containing `:` survives. A missing or non-numeric first two parts rejects.
     */
    fun parse(payload: String, nowMs: Long = commerceNowMs()): PopopxChannelPaymentReceipt? {
      val parts = payload.split(':', limit = 3)
      if (parts.size != 3) return null
      val channelId = parts[0].toLongOrNull() ?: return null
      val credits = parts[1].toIntOrNull() ?: return null
      return PopopxChannelPaymentReceipt(channelId, credits, parts[2], nowMs)
    }
  }
}

/** High-tier appearance redemptions (`:1370-1383`): applied by local rendering, never uploaded, never verified. */
enum class PopopxCosmetic(val wireValue: String, val cost: Int) {
  AURORA_SHIELD_AVATAR_FRAME("auroraShieldAvatarFrame", PopopxCommerceLimits.AVATAR_FRAME_COST),
  DARK_GOLD_QR_CARD_SKIN("darkGoldQRCardSkin", PopopxCommerceLimits.QR_CARD_SKIN_COST);

  companion object {
    fun fromWire(raw: String?): PopopxCosmetic? = values().firstOrNull { it.wireValue == raw }
  }
}

/**
 * The anti-replay sets: packet ids claimed, voucher ids redeemed, transaction hashes credited (`:1385-1406`).
 *
 * The three lists share one ceiling and drop the OLDEST when it is exceeded — the row that falls off the front
 * stands for a transaction that finished long ago. Over the ceiling, an identifier is no longer remembered, so the
 * guard is a window, not a promise: see [PopopxCreditsManager]'s note on the ledger being a history window too.
 */
@Serializable
data class PopopxReplayGuard(
  val claimedPacketIds: MutableList<String> = mutableListOf(),
  val redeemedVoucherIds: MutableList<String> = mutableListOf(),
  val creditedTransactionHashes: MutableList<String> = mutableListOf(),
) {
  fun claim(packetId: String) { append(claimedPacketIds, packetId) }

  fun redeem(voucherId: String) { append(redeemedVoucherIds, voucherId) }

  fun credit(transactionHash: String) { append(creditedTransactionHashes, transactionHash) }

  fun hasClaimed(packetId: String): Boolean = claimedPacketIds.contains(packetId)

  fun hasRedeemed(voucherId: String): Boolean = redeemedVoucherIds.contains(voucherId)

  fun hasCredited(transactionHash: String): Boolean = creditedTransactionHashes.contains(transactionHash)

  private fun append(list: MutableList<String>, value: String) {
    if (list.contains(value)) return
    list.add(value)
    val overflow = list.size - PopopxCommerceLimits.MAXIMUM_REPLAY_IDENTIFIERS
    if (overflow > 0) repeat(overflow) { list.removeAt(0) }
  }
}
