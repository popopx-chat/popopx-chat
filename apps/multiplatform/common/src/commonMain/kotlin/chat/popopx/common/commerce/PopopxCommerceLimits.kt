package chat.popopx.common.commerce

// MARK: - Limits and calibrated values

/**
 * Every calibration number the commerce layer shares, in one place — the Kotlin form of
 * `PopopxCommerceLimits` (`apps/ios/Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift:28-74`),
 * together with the per-payload caps iOS declares on each payload type (`:630-635`, `:742-747`, `:851-856`,
 * `:980-983`). Keeping them here is the whole point: every number in the review notes must grep back to this
 * object, and a second copy somewhere else is how the docs and the code start telling two stories.
 *
 * Durations are kept in the unit iOS uses (seconds for a duration, milliseconds for anything that lands in a
 * stored `…AtMs` field), so a ported line never silently changes units.
 */
object PopopxCommerceLimits {
  /** One day in the milliseconds every stored timestamp uses; iOS writes the literal (`PopopxBadgeManager.swift:264`). */
  const val DAY_MILLIS: Long = 86_400_000L

  /** The length of the 72-hour pioneer node trial badge (`PopopxBadgeCreditsModels.swift:30`). */
  const val TRIAL_SECONDS: Long = 72L * 60 * 60

  /**
   * The longest clock drift accepted when the trial badge expires back to the free public relays: a future-dated
   * expiry is a forged one (`:32`). Nothing in this port blocks on it — it is the ceiling a caller compares against.
   */
  const val MAXIMUM_CLOCK_SKEW_MS: Long = 15L * 60 * 1000

  /**
   * How many vouchers the local voucher wallet may hold (`:34`). The ceiling is real storage, not politeness:
   * the whole table is one keystore item, and [PopopxCommerceLimits] caps one such item at 4096 plain bytes.
   */
  const val MAXIMUM_VOUCHERS = 200

  /**
   * How many ledger rows are kept (`:36`); past it the oldest are dropped FIFO. The balance is never lost —
   * but see the KDoc on [PopopxCreditsManager]: a trimmed window is not a replayable audit chain.
   */
  const val MAXIMUM_LEDGER_ENTRIES = 240

  /** The ceiling on each of the three anti-replay sets (`:38`). */
  const val MAXIMUM_REPLAY_IDENTIFIERS = 2_000

  /** The balance ceiling (`:40`). Above it the data was altered: the wallet flags `needsReconcile` instead of truncating. */
  const val MAXIMUM_CREDIT_BALANCE = 100_000

  /** The largest single red-packet amount (`:42`). */
  const val MAXIMUM_PACKET_AMOUNT = 10_000

  /**
   * The longest red-packet or gift-card message (`:44`), counted as Unicode scalars after decoding — which is
   * exactly what iOS's `String.count` and [commerceLength] measure.
   */
  const val MAXIMUM_NOTE_CHARACTERS = 60

  /** The payload ceiling of one signalling line (`:48`); an oversized blob is refused before anything decodes it. */
  const val MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS = 1_024

  /** The byte length of the redemption-code checksum (`:50`). */
  const val CODE_CHECKSUM_BYTES = 2

  /** The ceiling of a custom profile-page or channel threshold, in credits (`:52`). */
  const val MAXIMUM_CREDITS_THRESHOLD = 100_000

  /** The digits a threshold input may use (`:54`), the same family of constraint as the profile payload's TTL cap. */
  const val MAXIMUM_THRESHOLD_DIGITS = 6

  /**
   * The fixed red-packet tiers (`:56`). Apple's 3.1.1 red line "no random amounts" lives here as data, and the
   * check runs again at the parser: a criterion that only exists in the UI can be pasted around.
   */
  val RED_PACKET_AMOUNTS = listOf(10, 50, 100, 500)

  /**
   * The three compute-credit gift-card face values (`PopopxCreditPlan.giftPacks`,
   * `PopopxBadgeCreditsModels.swift:293-294`: `creditsGift100/500/2000`).
   *
   * iOS guards this at the TYPE level — `exchangeCreditsForCreditVoucher(pack:)` cannot be called with anything but
   * a `PopopxCreditPack`, and a pack only builds from an SKU that reports an amount (`:273-277`). The SKUs are the
   * App Store lane and are not ported to the foss build, so the guard moves from the signature to this list, read
   * at the one call site that can spend credits on a card. The rule it protects is the 1:1 face value: a 500-credit
   * card costs 500 credits, and any other ratio is a discount or a markup on the same denomination.
   */
  val CREDIT_GIFT_AMOUNTS = listOf(100, 500, 2_000)

  /** The most claimers in one equal group-chat split (`:58`). */
  const val MAXIMUM_PACKET_RECIPIENTS = 100

  /**
   * How long an unclaimed-out red packet hangs on the sender's side before its remainder may be refunded (`:60`).
   * Refunding early invents credits: the shares still in the group would be claimable against money already given back.
   */
  const val PACKET_CLAIM_GRACE_SECONDS: Long = 30L * 86_400

  /** The validity period of a channel subscription credential (`:64`), the same "one month" as the badge monthly tier. */
  const val CHANNEL_TICKET_SECONDS: Long = 30L * 86_400

  /** The duration and the price of the one-hour extended anti-peeping window (`:66-67`). */
  const val EXTENDED_SECURE_WINDOW_SECONDS: Long = 3_600L
  const val EXTENDED_SECURE_WINDOW_COST = 20

  /** The prices of the flowing-light avatar frame and the dark-gold QR business-card skin (`:69-70`). */
  const val AVATAR_FRAME_COST = 150
  const val QR_CARD_SKIN_COST = 150

  /** The shortest interval between two local route-rotation counts (`:72`); the heartbeat itself is 30 seconds. */
  const val NODE_ROTATION_SECONDS: Long = 15

  // MARK: Per-payload caps
  //
  // iOS spells these on each payload type. The names keep the field they govern, because two of the four cards
  // put a different limit on a same-looking number.

  /** `PopopxGiftCardPayload.maximumVoucherIdCharacters` (`:632`). A voucher id is a 36-character UUID string. */
  const val MAXIMUM_VOUCHER_ID_CHARACTERS = 40

  /** `PopopxRedPacketPayload.maximumPacketIdCharacters` (`:852`). The packet id IS a ledger entry id. */
  const val MAXIMUM_PACKET_ID_CHARACTERS = 40

  /** `maximumSignatureCharacters`, shared by all four payloads (`:633`, `:746`, `:855`, `:983`). */
  const val MAXIMUM_SIGNATURE_CHARACTERS = 180

  /** `maximumAmountDigits`, the credit-gift card and the red packet (`:744`, `:853`). */
  const val MAXIMUM_AMOUNT_DIGITS = 6

  /** `PopopxChannelAccessPayload.maximumPriceDigits` (`:981`). */
  const val MAXIMUM_PRICE_DIGITS = 6

  /** `PopopxRedPacketPayload.maximumRecipientsDigits` (`:854`). */
  const val MAXIMUM_RECIPIENTS_DIGITS = 3

  /** The digits any `…AtMs` field may use on the wire: 15 keeps the whole Int64 range out of reach (`:694`). */
  const val MAXIMUM_TIME_DIGITS = 15

  /** `PopopxChannelAccessPayload.maximumPublicKeyCharacters` (`:982`); an x9.63 key base64url is 86 characters. */
  const val MAXIMUM_PUBLIC_KEY_CHARACTERS = 120

  /** The largest redemption-code JSON body this layer will frame (`:570`, the same test that refuses a bigger one). */
  const val MAXIMUM_CODE_BODY_BYTES = 4_096

  /** The received channel-payment txHash set, capped on its own (`PopopxCreditsManager.swift:480-484`). */
  const val MAXIMUM_RECEIVED_PAYMENT_TX_HASHES = 1_000

  /** The character width of a redemption-code display group (`PopopxBadgeCreditsModels.swift:552`). */
  const val DISPLAY_GROUP_WIDTH = 8
}

/**
 * Character count in Unicode scalars, which is what Swift's `String.count` reports for these payloads and what
 * every cap above is written against. Java's `length` counts UTF-16 units, so an emoji note would be measured
 * twice; the caps are character limits, not code-unit limits.
 */
internal fun String.commerceLength(): Int = codePointCount(0, length)

/**
 * The scalar-truncating form of Swift's `String(note.unicodeScalars.prefix(n))`, the operation every free-text
 * field in this module goes through before it is signed or stored. Truncating at a code-unit boundary would
 * cut a surrogate pair in half and hand the remainder to a decoder that cannot represent it.
 */
internal fun String.commercePrefix(characters: Int): String {
  if (characters <= 0) return ""
  if (commerceLength() <= characters) return this
  var index = 0
  var counted = 0
  while (index < length && counted < characters) {
    val high = codePointAt(index)
    index += Character.charCount(high)
    counted++
  }
  return substring(0, index)
}

/**
 * The wall clock in milliseconds, the equivalent of Swift's `Int64(Date().timeIntervalSince1970 * 1_000)`.
 *
 * Every decision that can be tested reads an injected `nowMs` instead of calling this, exactly as iOS injects
 * `now` into `PopopxBadgePhase.phase(for:now:)` (`PopopxBadgeCreditsModels.swift:375-376`); this function is what
 * the managers fall back to when nobody supplied one.
 */
internal fun commerceNowMs(): Long = System.currentTimeMillis()

/**
 * A UUID v4 string, lower-cased (`UUID().uuidString.lowercased()`), which is what every identifier in this module
 * is: a ledger row id, a voucher id, and therefore the 36-character width the 40-character parse caps are sized
 * against (`PopopxP2PVoucherVault.swift:305-311`). One mint for the whole module, because a ledger id a refund
 * later keys on has to be the same shape the parser will accept.
 */
internal fun commerceNewUuid(): String {
  val bytes = chat.popopx.common.crypto.randomBytes(16)
  bytes[6] = ((bytes[6].toInt() and 0x0F) or 0x40).toByte()
  bytes[8] = ((bytes[8].toInt() and 0x3F) or 0x80).toByte()
  val hex = chat.popopx.common.crypto.hexEncode(bytes)
  return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}"
}

/**
 * The character class Swift's `CharacterSet.whitespacesAndNewlines` names, spelled out because neither platform's
 * convenience predicate matches it: `Char.isWhitespace()` accepts U+001C–U+001F, which this set does NOT contain,
 * and rejects U+00A0, U+1680, U+2000, U+2028, U+2029, U+202F and U+3000, which it does. Measured with
 * `/usr/bin/swift` 6.4.2 over the whole Latin-1 and General-Punctuation range.
 *
 * It matters in exactly one place, `PopopxRedeemCode.normalized`, where the character set decides which characters
 * a pasted code loses: an over-eager set silently deletes a byte of the base64url payload and every code the user
 * ever pastes back fails its checksum.
 */
internal fun commerceIsSwiftWhitespace(codePoint: Int): Boolean = when (codePoint) {
  0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x0085, 0x00A0, 0x1680 -> true
  0x2000, 0x2028, 0x2029, 0x202F, 0x3000 -> true
  else -> false
}

/**
 * Swift's `String.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }` — scalar-by-scalar,
 * so a surrogate pair either survives whole or is filtered whole; no code unit is ever dropped on its own.
 */
internal fun String.removingCommerceWhitespace(): String {
  val out = StringBuilder(length)
  var index = 0
  while (index < length) {
    val codePoint = codePointAt(index)
    if (!commerceIsSwiftWhitespace(codePoint)) out.appendCodePoint(codePoint)
    index += Character.charCount(codePoint)
  }
  return out.toString()
}
