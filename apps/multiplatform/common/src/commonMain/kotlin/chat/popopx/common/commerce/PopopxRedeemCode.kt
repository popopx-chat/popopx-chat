package chat.popopx.common.commerce

import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.base64UrlEncode
import chat.popopx.common.crypto.sha256

/**
 * The codec for both redemption-code families: `PPX1-…` badge codes and `PPXC1-…` compute-credit codes
 * (`PopopxBadgeCreditsModels.swift:533-617`).
 *
 * ### Why the code carries a checksum
 * [decode] verifies two bytes BEFORE parsing the JSON, so one mistyped character lands straight on "this code is
 * not right" instead of "the JSON was unreadable". The first can prompt the user to retry; the second can only
 * report an internal error (`:535-536`).
 *
 * The two families share the framing — checksum ‖ sorted-key JSON, base64url — on purpose: the framing is the
 * fragile part, and a fix applied to one family and not the other is a code that stops decoding. What stays
 * separate is the prefix and the envelope type, so nothing here is generic over "which family": the caller names it
 * (`:538-540`).
 */
object PopopxRedeemCode {
  /** The badge prefix (`:542`). */
  const val PREFIX = "PPX1-"

  /**
   * The compute-credit prefix (`:543-545`). It differs from the badge prefix at the THIRD character, so a
   * `hasPrefix` test for either can never match the other family, and a mistyped `C` fails the checksum rather than
   * silently crossing over.
   */
  const val CREDIT_PREFIX = "PPXC1-"

  /** Every prefix this codec recognises, used by [normalized] and [grouped] only (`:547-548`). */
  val PREFIXES = listOf(PREFIX, CREDIT_PREFIX)

  /**
   * The group width for split display (`:550-551`): 8 characters, and five groups fit one screen exactly. Display
   * only — a copy always hands over the ungrouped text, because grouping inserts the spaces a human reads and a
   * paste must not carry.
   */
  const val DISPLAY_GROUP_WIDTH = PopopxCommerceLimits.DISPLAY_GROUP_WIDTH

  /** `PPX1-` framing of a badge envelope (`:553`). */
  fun encode(envelope: PopopxRedeemEnvelope): String? = frame(envelope.bodyBytes(), PREFIX)

  /** `PPXC1-` framing of a credit envelope (`:555`). */
  fun encodeCredit(envelope: PopopxCreditRedeemEnvelope): String? = frame(envelope.bodyBytes(), CREDIT_PREFIX)

  /** Badge family only: a credit code handed here is `null`, which the router reports as "malformed code" (`:557`). */
  fun decode(code: String): PopopxRedeemEnvelope? = unframe(code, PREFIX) { PopopxRedeemEnvelope.parse(it) }

  /**
   * Named apart from [decode] rather than left to overload resolution (`:559-561`): a call site that stops
   * compiling because type inference changed is a worse trade than one more name.
   */
  fun decodeCredit(code: String): PopopxCreditRedeemEnvelope? =
    unframe(code, CREDIT_PREFIX) { PopopxCreditRedeemEnvelope.parse(it) }

  /** Which family a (normalised) code belongs to, or null when it is neither (`:563-564`). */
  fun prefixOf(code: String): String? = PREFIXES.firstOrNull { code.startsWith(it) }

  /** `prefix + base64url(sha256(body)[0…1] ‖ body)`, or null when the body is over the cap (`:566-574`). */
  private fun frame(body: ByteArray, prefix: String): String? {
    if (body.isEmpty()) return null
    // The cap is on the JSON body, not on the finished code: 4 KB is what a QR panel and a keychain row can both
    // hold, and a bigger envelope must be refused before any of its bytes are committed to a code.
    if (body.size > PopopxCommerceLimits.MAXIMUM_CODE_BODY_BYTES) return null
    val digest = sha256(body)
    val payload = ByteArray(PopopxCommerceLimits.CODE_CHECKSUM_BYTES + body.size)
    digest.copyInto(payload, 0, 0, PopopxCommerceLimits.CODE_CHECKSUM_BYTES)
    body.copyInto(payload, PopopxCommerceLimits.CODE_CHECKSUM_BYTES)
    return prefix + base64UrlEncode(payload)
  }

  /** The reverse, with the checksum gate in front of the parse (`:576-586`). */
  private fun <T> unframe(code: String, prefix: String, parse: (ByteArray) -> T?): T? {
    val stripped = normalized(code)
    if (!stripped.startsWith(prefix)) return null
    val body = stripped.substring(prefix.length)
    if (body.isEmpty()) return null
    val payload = base64UrlDecode(body) ?: return null
    // Strictly greater, not greater-or-equal: a payload that is ONLY a checksum has no body to parse, and framing
    // it would be a code that decodes into "empty JSON".
    if (payload.size <= PopopxCommerceLimits.CODE_CHECKSUM_BYTES) return null
    val checksum = payload.copyOfRange(0, PopopxCommerceLimits.CODE_CHECKSUM_BYTES)
    val json = payload.copyOfRange(PopopxCommerceLimits.CODE_CHECKSUM_BYTES, payload.size)
    val digest = sha256(json)
    for (index in checksum.indices) {
      if (checksum[index] != digest[index]) return null
    }
    return parse(json)
  }

  /**
   * Normalisation: it removes **only** whitespace and prefix-case differences (`:588-598`).
   *
   * The base64url alphabet itself contains `-`, so deleting `-` as a separator would silently corrupt the payload —
   * whitespace is therefore the ONLY possible separator, and the UI must display to that constraint. Two measured
   * traps follow, and both are pinned by tests:
   *  - a trailing `-AAAA` is KEPT, not stripped;
   *  - the body's case is NOT fixed. Only the prefix's is. A code whose whole body was upper-cased by some
   *    clipboard still normalises, still base64-decodes (base64url is case-sensitive but a lower-case alphabet maps
   *    onto a valid stream of other bytes) and then fails the checksum, which is the honest answer: "this code is
   *    not right", not "here is a different voucher".
   */
  fun normalized(raw: String): String {
    var text = raw.removingCommerceWhitespace()
    for (known in PREFIXES) {
      // The two prefixes are case-insensitively distinct too, so at most one branch can fire.
      if (text.uppercase().startsWith(known.uppercase())) {
        text = known + text.substring(known.length)
      }
    }
    return text
  }

  /**
   * The grouped form a human copies by hand: `PPX1-ABCD1234 EFGH…` (`:600-613`).
   *
   * Note what iOS does and what this therefore must reproduce: the GROUPING IS OVER THE WHOLE BODY, spaces
   * included, so a body that already contains a space renders with two of them side by side (`abcdefgh ij` becomes
   * `abcdefgh` + ` ` + ` ij`). An "empty body" returns the code unchanged rather than a prefix and a stray space.
   */
  fun grouped(code: String): String {
    val head = prefixOf(code)
    val body = if (head == null) code else code.substring(head.length)
    if (body.isEmpty()) return code
    val groups = ArrayList<String>()
    var index = 0
    while (index < body.length) {
      var end = index
      var taken = 0
      while (end < body.length && taken < DISPLAY_GROUP_WIDTH) {
        end += Character.charCount(body.codePointAt(end))
        taken++
      }
      groups.add(body.substring(index, end))
      index = end
    }
    return (head ?: "") + groups.joinToString(separator = " ")
  }

  /** What gets copied for the user: prefix + the original ungrouped text (`:615-616`). */
  fun clipboardValue(code: String): String = code
}
