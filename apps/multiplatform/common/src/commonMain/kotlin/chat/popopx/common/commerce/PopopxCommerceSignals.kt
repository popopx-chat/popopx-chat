package chat.popopx.common.commerce

import chat.popopx.common.eco.PopopxEcoMarker
import chat.popopx.common.eco.PopopxEcoUplink

// The invisible-signalling layer: the kinds this feature answers for, the `::popopx_sys::` codec, and the single
// render-suppression predicate. Ported from `PopopxBadgeCreditsModels.swift:1088-1205`.

/**
 * The signalling kinds (`:1091-1134`). The strings line up with the spec character for character:
 * `::popopx_sys::` + upper-case name + `::` + payload.
 */
enum class PopopxCommerceSignalKind(val rawValue: String) {
  EXTERNAL_REDEEM_REQUEST("EXT_REDEEM_REQ"),
  EXTERNAL_REDEEM_ACK("EXT_REDEEM_ACK"),
  CHAT_REDEEM_REQUEST("CHAT_REDEEM_REQ"),
  CHAT_REDEEM_ACK("CHAT_REDEEM_ACK"),
  REDPACKET_CLAIMED("REDPACKET_CLAIMED"),

  /**
   * The profile-card unlock receipt — the sixth kind added because the requirement asked for it (`:1097-1100`).
   * It only comes in and never goes out: the receiver deletes the row and touches no UI, because "who viewed your
   * profile page" stops being silent the moment it becomes a durable record.
   */
  PROFILE_UNLOCKED("PROFILE_UNLOCKED"),

  /**
   * The channel redemption receipt (`:1101-1104`). Payload is `{chatInfoId}::{expiresAtMs}`, split on the LAST pair
   * of `::` by the caller, because the conversation key itself looks like `#<local row number>` and only the
   * trailing part is guaranteed to be a number.
   */
  CHANNEL_SUB_ACK("CHANNEL_SUB_ACK"),

  /** Member pays → channel owner credits; payload `{channelId}:{credits}:{txHash}` (`:1105-1107`). */
  CHANNEL_PAY_RCPT("CHANNEL_PAY_RCPT"),

  /** The four compute-credit legs, separate kinds rather than a flag, because the ACK carries a different signed type (`:1108-1115`). */
  CREDIT_EXT_REDEEM_REQ("CREDIT_EXT_REDEEM_REQ"),
  CREDIT_EXT_REDEEM_ACK("CREDIT_EXT_REDEEM_ACK"),
  CREDIT_CHAT_REDEEM_REQ("CREDIT_CHAT_REDEEM_REQ"),
  CREDIT_CHAT_REDEEM_ACK("CREDIT_CHAT_REDEEM_ACK"),

  /**
   * A command to, or a receipt from, this user's own Mac node (`:1116-1125`). The payload keeps the host's own
   * three-part shape `{serviceId}::{action}::{payload}`, i.e. the full wire is
   * `::popopx_sys::NODE_CMD::shadow_cos::briefing::{…}` — [PopopxSysMarker.parse] splits on the FIRST `::` only, so
   * the two inner separators belong to the payload and arrive unmangled.
   */
  NODE_CMD("NODE_CMD");

  /**
   * Only these three may be picked up inside a group or channel (`:1127-1133`). The reason is not "signalling cannot
   * be received in a group": `awaitingAcks` keeps its books per chatId, so a redemption ACK from a third person in
   * the group would settle somebody else's entry. Packet receipts and channel receipts are keyed by packetId /
   * conversation key instead, which is what makes them safe.
   */
  val acceptedInGroup: Boolean
    get() = this == REDPACKET_CLAIMED || this == CHANNEL_SUB_ACK || this == CHANNEL_PAY_RCPT

  /** The four REQ legs plus nothing else: an ACK, a receipt and a node command are all answers (`:1142-1149`). */
  val isRequest: Boolean
    get() = this == EXTERNAL_REDEEM_REQUEST || this == CHAT_REDEEM_REQUEST ||
      this == CREDIT_EXT_REDEEM_REQ || this == CREDIT_CHAT_REDEEM_REQ

  companion object {
    fun fromRawValue(raw: String?): PopopxCommerceSignalKind? = values().firstOrNull { it.rawValue == raw }
  }
}

/** One parsed signalling message: the kind and its payload (a voucher id, a grant's base64url, or a packet id) (`:1136-1150`). */
data class PopopxCommerceSignal(val kind: PopopxCommerceSignalKind, val payload: String)

/**
 * The `::popopx_sys::` codec (`:1152-1205`).
 *
 * Why [parse] requires the WHOLE line rather than a `contains`: `contains` would turn a sentence like "look at this
 * screenshot of ::popopx_sys::" into an executable signalling message. Whole-line equality is the only safe parsing
 * boundary, and the renderer's suppression logic shares exactly this one copy of the criterion.
 */
object PopopxSysMarker {
  const val MARKER = "::popopx_sys::"

  fun wireString(signal: PopopxCommerceSignal): String = "$MARKER${signal.kind.rawValue}::${signal.payload}"

  fun wireString(kind: PopopxCommerceSignalKind, payload: String): String = "$MARKER${kind.rawValue}::$payload"

  /**
   * Split on the FIRST `::` after the marker (`:1168-1173`): a type name can never contain a colon, nor can a
   * grant's base64url. Using a limited split would also accept `EXT_REDEEM_REQ:abc` (one colon) as legal, and after
   * slicing out a type name that does not exist the offset would then be forced into the payload — the easiest
   * place to slip silently out of alignment.
   */
  fun parse(wholeText: String): PopopxCommerceSignal? {
    // `trimmingCharacters(in:)` cuts from both ends only, so the helper must not re-filter the inside — whitespace
    // that belongs to a payload survives.
    val trimmed = trimCommerceWhitespace(wholeText)
    if (!trimmed.startsWith(MARKER)) return null
    val rest = trimmed.substring(MARKER.length)
    val separator = rest.indexOf("::")
    if (separator < 0) return null
    val kindText = rest.substring(0, separator)
    val payload = rest.substring(separator + 2)
    val kind = PopopxCommerceSignalKind.fromRawValue(kindText) ?: return null
    if (payload.isEmpty()) return null
    if (payload.commerceLength() > PopopxCommerceLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS) return null
    return PopopxCommerceSignal(kind, payload)
  }

  /**
   * The entry point of render suppression: a hit means the whole line never reaches a bubble, a preview or being
   * read aloud (`:1182-1204`).
   *
   * It also answers for `::POPOPX_ECO::` frames and for the three eco uplink lines, so that there is ONE criterion
   * shared by every suppression site; a second criterion in a second place is how one site ends up showing a frame
   * the others hide.
   *
   * iOS ORs in a fourth term, `PopopxServerConfigWire.isControlText` (the signed server-cluster pair, which carries
   * no marker and exceeds the payload ceiling above, so it is judged by its own prefix test). That type has no
   * Kotlin counterpart yet — see the note in this module's report; adding the term here later is a one-line change
   * and MUST NOT be done by widening [parse], which would accept oversized payloads for every kind.
   */
  fun isSignalText(text: String): Boolean =
    parse(text) != null || PopopxEcoMarker.isControlText(text) || PopopxEcoUplink.isUplinkText(text)

  /** `trimmingCharacters(in: .whitespacesAndNewlines)` over the SAME measured character class as [PopopxRedeemCode.normalized]. */
  private fun trimCommerceWhitespace(text: String): String {
    var start = 0
    var end = text.length
    while (start < end && commerceIsSwiftWhitespace(text.codePointAt(start))) {
      start += Character.charCount(text.codePointAt(start))
    }
    while (end > start) {
      val codePoint = text.codePointBefore(end)
      val width = Character.charCount(codePoint)
      if (!commerceIsSwiftWhitespace(codePoint)) break
      end -= width
    }
    return text.substring(start, end)
  }
}

/** `Character.codePointBefore(index)`: the scalar that ENDS at `index`, so a trailing surrogate pair is measured whole. */
private fun String.codePointBefore(index: Int): Int {
  val low = this[index - 1]
  return if (low.isLowSurrogate() && index >= 2 && this[index - 2].isHighSurrogate()) {
    Character.toCodePoint(this[index - 2], low)
  } else {
    low.code
  }
}
