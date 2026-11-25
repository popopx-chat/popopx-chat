package chat.popopx.common.signal

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Ported from apps/ios/Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift:1088-1205 and
// apps/ios/Shared/Features/BadgeCredits/PopopxSilentSignalingRouter.swift:57-81,128-137,760-773.
//
// This is the invisible signaling layer ONLY: the `::popopx_sys::` frame, its thirteen kinds, the
// group gate, and the seams the host binds to. Payload content validation (grant signatures, receipt
// fields, voucher state) belongs to `chat.popopx.common.commerce`; service-account frames belong to
// `chat.popopx.common.eco`. Nothing here edits or duplicates either.

object PopopxSignalLimits {
  /**
   * Payload ceiling (PopopxBadgeCreditsModels.swift:47): SMP shards on its own, but this layer
   * refuses to parse an oversized payload so a forged enormous base64 blob is never handed down to
   * be decoded. The encoder shares the same tier as the decoder (:725-731 of the router).
   */
  const val MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS = 1_024

  /** The ceiling on the outcome table; it exists only to stop unbounded growth (router:132). */
  const val MAXIMUM_OUTCOME_HISTORY = 64

  /** How many refused-inbound records the unbound gate keeps. Not an iOS number — iOS just logs. */
  const val MAXIMUM_UNBOUND_RECORDS = 32

  /**
   * MEASURED, not chosen: iOS sends every silent signal with `live: false` and `ttl: nil`
   * (PopopxSilentSignalingRouter.swift:675-676), so nothing disappears because of a server TTL —
   * the row is deleted afterwards by the INTERNAL delete (router:694-721). The value is kept as a
   * seam parameter so a future host change is a one-line decision, but the port pins it to null.
   */
  val DEFAULT_TTL_SECONDS: Int? = null

  /** Every silent send is `live = false` (router:675); a live signal would pin the peer's connection. */
  const val SIGNAL_IS_NEVER_LIVE = false
}

/**
 * The thirteen signaling kinds, with the wire strings spelled exactly as
 * PopopxBadgeCreditsModels.swift:1091-1125. The casing is part of the protocol: `parse` looks the
 * kind up by exact raw-value match (:1175), so a lower-case echo of a legal name is an unknown kind.
 */
enum class PopopxSignalKind(val raw: String) {
  // Models:1092-1095, the four badge legs. REQ payloads carry a voucherId, ACK payloads the
  // grant's base64url (router:727-757); neither is validated in this package.
  EXTERNAL_REDEEM_REQ("EXT_REDEEM_REQ"),
  EXTERNAL_REDEEM_ACK("EXT_REDEEM_ACK"),
  CHAT_REDEEM_REQ("CHAT_REDEEM_REQ"),
  CHAT_REDEEM_ACK("CHAT_REDEEM_ACK"),

  // Models:1096. The share-count source for a group red packet; in a group it is attributed by
  // `memberId` (router:185-186, 208-210).
  REDPACKET_CLAIMED("REDPACKET_CLAIMED"),

  /**
   * Models:1097-1100. The sixth kind added because the requirement asked for it. It only comes in
   * and never goes out: the receiving side deletes the row and keeps no book.
   */
  PROFILE_UNLOCKED("PROFILE_UNLOCKED"),

  /** Models:1101-1104. Payload `{chatInfoId}::{expiresAtMs}`, split on the LAST pair of `::`. */
  CHANNEL_SUB_ACK("CHANNEL_SUB_ACK"),

  /** Models:1105-1107. Payload `{channelId}:{credits}:{txHash}`; the txHash is the replay key. */
  CHANNEL_PAY_RCPT("CHANNEL_PAY_RCPT"),

  // Models:1108-1115, the four compute-credit legs. Separate kinds rather than a flag because the
  // ACK carries a different signed type; the kind is what tells the receiving side which JSON to
  // decode. The two families never cross (router:457-458).
  CREDIT_EXT_REDEEM_REQ("CREDIT_EXT_REDEEM_REQ"),
  CREDIT_EXT_REDEEM_ACK("CREDIT_EXT_REDEEM_ACK"),
  CREDIT_CHAT_REDEEM_REQ("CREDIT_CHAT_REDEEM_REQ"),
  CREDIT_CHAT_REDEEM_ACK("CREDIT_CHAT_REDEEM_ACK"),

  /**
   * Models:1116-1125. Payload keeps the host's own three-part shape `{serviceId}::{action}::{payload}`;
   * the codec splits on the FIRST `::` only, so the two inner separators arrive unmangled.
   */
  NODE_CMD("NODE_CMD"),
  ;

  /**
   * The group whitelist, verbatim from Models:1131-1133. The criterion is not "signalling cannot be
   * received in a group" but that the pending-ACK ledger keeps its books per chatId: a redemption
   * ACK from a third person in the group would settle somebody else's entry (router:184-187, :61).
   * `NODE_CMD` is deliberately NOT in it: a node command addresses one machine, and a stray one in
   * a group would push somebody's Mac around in front of an audience (Models:1123-1124).
   */
  val acceptedInGroup: Boolean
    get() = this == REDPACKET_CLAIMED || this == CHANNEL_SUB_ACK || this == CHANNEL_PAY_RCPT

  /** Models:1142-1149, listed case by case with no default. */
  val isRequest: Boolean
    get() = this == EXTERNAL_REDEEM_REQ || this == CHAT_REDEEM_REQ ||
      this == CREDIT_EXT_REDEEM_REQ || this == CREDIT_CHAT_REDEEM_REQ

  /** The four legs that wait for an ACK of this device's own initiation (router:318, :353). */
  val isAcknowledgement: Boolean
    get() = this == EXTERNAL_REDEEM_ACK || this == CHAT_REDEEM_ACK ||
      this == CREDIT_EXT_REDEEM_ACK || this == CREDIT_CHAT_REDEEM_ACK

  companion object {
    fun from(raw: String): PopopxSignalKind? = entries.firstOrNull { it.raw == raw }
  }
}

/** One parsed signaling message (Models:1136-1150). */
data class PopopxSignal(val kind: PopopxSignalKind, val payload: String)

/**
 * Which conversation a signaling message lands in or leaves from. Carries only ids (router:57-61:
 * neither contact nor group object is safe to move across the app's concurrency domains).
 * Anything that is neither a direct nor a group conversation has no "person on the other side"
 * (router:73-80).
 */
enum class PopopxSignalChatKind {
  DIRECT,
  GROUP,

  /** Notes, contact requests, channels-as-such: signaling refuses these entirely (router:190). */
  OTHER,
  ;

  companion object {
    fun target(kind: PopopxSignalChatKind, chatId: Long): PopopxSignalTarget? = when (kind) {
      DIRECT -> PopopxSignalTarget.Contact(chatId)
      GROUP -> PopopxSignalTarget.Group(chatId)
      OTHER -> null
    }
  }
}

/** The router's `PopopxCommerceTarget` (router:62-81). Redemption signalling is always Contact. */
sealed class PopopxSignalTarget(val chatId: Long) {
  class Contact(chatId: Long) : PopopxSignalTarget(chatId)
  class Group(chatId: Long) : PopopxSignalTarget(chatId)

  val isGroup: Boolean get() = this is Group
}

/**
 * The signaling-level failures the router itself can produce, named after the host errors the
 * Swift cites at its refusal sites. The payload-level ones (`codeMalformed` before this layer,
 * badge/ledger errors) stay with the commerce package.
 */
enum class PopopxSignalFailure {
  /** Router:177, :393, :410, :465, :482 — the send or the connection did not go out. */
  CONNECTION_UNAVAILABLE,

  /** Router:324 — the peer's answer was refused; also the code-signature refusal at :390/:406/:478. */
  SIGNAL_REJECTED,

  /** Router:334, :359, :372 — the local secret store could not record the settlement. */
  KEYCHAIN_UNAVAILABLE,
}

/**
 * What one redemption flow looks like from the signaling layer (router:87-108, trimmed to what this
 * package can honestly know). The terminal `redeemed(period)` / `redeemedCredits(amount)` states
 * are the commerce package's to produce — they need the verified grant — so they arrive back here
 * as [Completed] with the voucher id only.
 */
sealed class PopopxRedemptionOutcome {
  /** Connection built and REQ on its way; NOT yet a redemption (router:88-90, :385-386). */
  data object Initiated : PopopxRedemptionOutcome()

  /** Commerce settled this voucher; what the badge or credit was is not this layer's business. */
  data class Completed(val voucherId: String) : PopopxRedemptionOutcome()

  data class Failed(val reason: PopopxSignalFailure) : PopopxRedemptionOutcome()
}

/**
 * The entry waiting for `contactConnected` (router:762-767). `signalWire` stores the whole string
 * rather than re-assembling it on send: assembling once more adds one more place that could differ
 * from what was sent, and these two must be byte-for-byte identical.
 */
data class PopopxPendingRedeem(val voucherId: String, val signalWire: String)

/**
 * The entry whose REQ has been sent and is waiting for the ACK (router:769-773).
 * `deletesContactAfterAck` separates the two kinds of redemption: the one-time link one has to
 * delete the contact along with it (no trace left), while the in-conversation gift card one must
 * never delete it — that is the friend itself.
 */
data class PopopxInflightRedeem(val voucherId: String, val deletesContactAfterAck: Boolean)

/** Storage slots of this layer. */
object PopopxSignalKeys {
  /**
   * The pending-REQ table. iOS keeps it in the Keychain's `ephemeralConnections` slot
   * (router:139-141, :157-162) so a killed process can still finish the flow. Deviation, stated in
   * the report: it lives in plain settings here, because the table carries only a voucher id and a
   * wire string that is already public code text — no key material.
   */
  const val PENDING_REDEEMS = "popopx.signal.pendingRedeems"

  val ALL_SETTINGS_KEYS = listOf(PENDING_REDEEMS)
}

/**
 * Code-point count. A deliberate duplicate of `ecoLength` in
 * `chat.popopx.common.eco.PopopxEcoModels.kt:68`: every `PopopxSignalLimits` cap is measured in
 * code points, the conservative side of Swift's grapheme-cluster `String.count` (same reasoning as
 * the eco header at PopopxEcoModels.kt:14-19). Flagged for dedupe once the packages settle.
 */
internal fun String.signalLength(): Int = codePointCount(0, length)

/** The persisted shape of the pending-REQ table. Tolerant by construction: it never throws. */
internal object PopopxPendingRedeemWire {
  private val json = Json { ignoreUnknownKeys = true }

  fun encode(entries: Map<Long, PopopxPendingRedeem>): String {
    val obj = LinkedHashMap<String, JsonElement>()
    for ((connectionId, entry) in entries) {
      obj[connectionId.toString()] = JsonObject(
        linkedMapOf(
          "v" to JsonPrimitive(entry.voucherId),
          "w" to JsonPrimitive(entry.signalWire),
        )
      )
    }
    return JsonObject(obj).toString()
  }

  fun decode(text: String?): Map<Long, PopopxPendingRedeem> {
    if (text.isNullOrEmpty()) return emptyMap()
    val element = try {
      json.parseToJsonElement(text)
    } catch (e: Exception) {
      return emptyMap()
    }
    val obj = element as? JsonObject ?: return emptyMap()
    val result = LinkedHashMap<Long, PopopxPendingRedeem>()
    for ((key, value) in obj) {
      val connectionId = key.toLongOrNull() ?: continue
      val entry = value as? JsonObject ?: continue
      val voucherId = (entry["v"] as? JsonPrimitive)?.content ?: continue
      val wire = (entry["w"] as? JsonPrimitive)?.content ?: continue
      result[connectionId] = PopopxPendingRedeem(voucherId, wire)
    }
    return result
  }
}
