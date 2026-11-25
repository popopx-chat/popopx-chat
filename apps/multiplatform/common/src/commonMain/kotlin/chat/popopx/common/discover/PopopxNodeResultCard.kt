package chat.popopx.common.discover

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * A result the node sent back, recognised on this device (DiscoverCatalogModels.swift:439-528).
 *
 * MEASURED, and it constrains every caller: this is a RENDERER, not a suppression rule
 * (:441-447). The host emits these lines UNMARKED — no `::popopx_sys::` prefix — so nothing but
 * shape identifies them, and a shape test can match something a person typed. That is why
 * [detect] is pure and the CALLER must gate it on "this text arrived from the paired node"
 * ([PopopxSubscriptionEngine.recordInboundText] takes the flag as an argument and never infers
 * it), and why a text that fails to decode must still render as the ordinary bubble it arrived
 * as. A typed "✅ anything" from an unpaired source is therefore NOT a card and NOT dropped.
 */
data class PopopxNodeResultCard(
  val id: String,
  val serviceId: PopopxNodeServiceId,
  val status: PopopxNodeResultStatus,
  val headline: String,
  val detail: String,
  val durationMilliseconds: Int?,
  val receivedAtMs: Long,
) {
  companion object {
    private const val FLAG_SUCCEEDED = "\u2705" // ✅
    private const val FLAG_DEGRADED = "\u26A0" // ⚠, optionally followed by U+FE0F — Swift switches
    // on `trimmed.first`, a GRAPHEME, so "⚠️" loses both scalars at once; UTF-16 has no such
    // notion, hence the explicit variation-selector step.
    private const val VARIATION_SELECTOR = '\uFE0F'
    private const val NAME_SEPARATOR = " ·" // the prefix the host prints: "<name> ·"
    private const val DURATION_SEPARATOR = " · "

    /**
     * `detect(text:fromPairedNode:now:)` (DiscoverCatalogModels.swift:476-514).
     *
     * Two Swift quirks are ported as they are, not fixed, because the host's real output always
     * has the space and fixing the second one would change stored cards:
     *  - `dropFirst(name.count + 3)` (:491) skips `" · "` assuming a space FOLLOWS the middle dot;
     *    `Shadow Chief of Staff ·Daily brief` loses the "D" (the head of the headline is eaten).
     *  - The trailing `" · <x> ms"` is lifted whenever the tail ENDS IN " ms" (:496-502), and the
     *    headline is truncated even if `<x>` never parses as an Int — so `" · cost 12 ms"` yields
     *    headline "" (card dropped) and `" · v 3 ms"` yields a card with no duration.
     *
     * Longest known engine name wins (:487-490): "Health Sentinel" and "Phantom Sentinel" share
     * their whole tail, and the host prints full names.
     */
    fun detect(text: String, fromPairedNode: Boolean, nowMs: Long): PopopxNodeResultCard? {
      if (!fromPairedNode) return null
      val trimmed = text.trim { it.isWhitespace() }
      if (trimmed.isEmpty()) return null
      val status: PopopxNodeResultStatus
      val afterFlagSource: String
      when {
        trimmed.startsWith(FLAG_SUCCEEDED) -> {
          status = PopopxNodeResultStatus.SUCCEEDED
          afterFlagSource = trimmed.substring(FLAG_SUCCEEDED.length)
        }
        trimmed.startsWith(FLAG_DEGRADED) -> {
          status = PopopxNodeResultStatus.DEGRADED
          afterFlagSource =
            if (trimmed.length > FLAG_DEGRADED.length && trimmed[FLAG_DEGRADED.length] == VARIATION_SELECTOR) {
              trimmed.substring(FLAG_DEGRADED.length + 1)
            } else {
              trimmed.substring(FLAG_DEGRADED.length)
            }
        }
        else -> return null
      }
      // Swift trims `.whitespaces` here, NOT newlines (:486) — "✅\nName · …" is not a card on
      // either platform because a newline survives and the prefix test fails.
      val afterFlag = afterFlagSource.trim { it == ' ' || it == '\t' }
      var service: PopopxNodeServiceId? = null
      for (candidate in PopopxNodeServiceId.entries) {
        if (!afterFlag.startsWith(candidate.nodeDisplayName + NAME_SEPARATOR)) continue
        val current = service
        if (current == null || candidate.nodeDisplayName.length > current.nodeDisplayName.length) service = candidate
      }
      val matched = service ?: return null
      val remainder = afterFlag
        .drop(matched.nodeDisplayName.length + 3) // the QUIRK, deliberately kept: eats one char if "·" is not followed by a space
        .trim { it == ' ' || it == '\t' }
      val lines = remainder.splitNewlines()
      var headline = (lines.firstOrNull() ?: "").trim { it == ' ' || it == '\t' }
      var duration: Int? = null
      val separatorIndex = headline.lastIndexOf(DURATION_SEPARATOR)
      if (separatorIndex >= 0) {
        val tail = headline.substring(separatorIndex + DURATION_SEPARATOR.length)
        if (tail.endsWith(" ms")) {
          duration = strictInt(tail.dropLast(3))
          headline = headline.substring(0, separatorIndex)
        }
      }
      if (headline.isEmpty()) return null
      val detail = lines.drop(1).joinToString("\n").trim { it.isWhitespace() }
      return PopopxNodeResultCard(
        // DEVIATION, unfixable here: Swift's `hashValue` is randomly seeded PER LAUNCH, so these
        // ids were never stable across restarts on iOS either — this card's identity is storage-
        // local dedup text, never a wire value. Kotlin's hashCode is stable per string, which is
        // strictly more stable than the thing mirrored.
        id = "${matched.rawValue}.$nowMs.${headline.hashCode() + detail.hashCode()}",
        serviceId = matched,
        status = status,
        headline = headline,
        detail = detail,
        durationMilliseconds = duration,
        receivedAtMs = nowMs,
      )
    }

    /**
     * `decode(command:now:)` (:518-528): a marked `NODE_CMD` that came BACK rather than from here
     * — a re-synced history row. The mark makes provenance real, so no `fromPairedNode` gate
     * applies; the action becomes the headline and the payload the detail, status always succeeded.
     */
    fun decodeCommand(command: PopopxNodeCommand, nowMs: Long): PopopxNodeResultCard = PopopxNodeResultCard(
      id = "${command.serviceId.rawValue}.$nowMs.${command.action.hashCode()}",
      serviceId = command.serviceId,
      status = PopopxNodeResultStatus.SUCCEEDED,
      headline = command.action,
      detail = command.payload,
      durationMilliseconds = null,
      receivedAtMs = nowMs,
    )

    /** Swift's `CharacterSet.newlines`: \n \r VT FF NEL LINE SEPARATOR PARAGRAPH SEPARATOR. */
    private fun String.splitNewlines(): List<String> {
      val out = ArrayList<String>()
      var start = 0
      var index = 0
      while (index < length) {
        if (isNewline(this[index])) {
          out.add(substring(start, index))
          start = index + 1
        }
        index++
      }
      out.add(substring(start, length))
      return out
    }

    private fun isNewline(char: Char): Boolean =
      char == '\n' || char == '\r' || char == '\u000B' || char == '\u000C' ||
        char == '\u0085' || char == '\u2028' || char == '\u2029'

    /**
     * Stored form for the inbox blob. Keys are the Swift Codable member names (:448), and a row
     * whose service id or status is not one of ours drops (an unknown Codable case throws), so a
     * future app's file can never smuggle a card this renderer would mis-draw.
     */
    fun fromJson(json: JsonObject): PopopxNodeResultCard? {
      val serviceId = PopopxNodeServiceId.from(json.stringOf("serviceId") ?: return null) ?: return null
      val status = PopopxNodeResultStatus.from(json.stringOf("status") ?: return null) ?: return null
      val id = json.stringOf("id") ?: return null
      val headline = json.stringOf("headline") ?: return null
      val detail = json.stringOf("detail") ?: return null
      val receivedAtMs = json.longOf("receivedAtMs") ?: return null
      val durationPrimitive = json["durationMilliseconds"] as? JsonPrimitive
      val duration =
        if (durationPrimitive == null || durationPrimitive is JsonNull || durationPrimitive.isString) null else durationPrimitive.content.toIntOrNull()
      return PopopxNodeResultCard(id, serviceId, status, headline, detail, duration, receivedAtMs)
    }

    fun toJson(card: PopopxNodeResultCard): JsonObject {
      val members = LinkedHashMap<String, JsonElement>()
      members["id"] = JsonPrimitive(card.id)
      members["serviceId"] = JsonPrimitive(card.serviceId.rawValue)
      members["status"] = JsonPrimitive(card.status.rawValue)
      members["headline"] = JsonPrimitive(card.headline)
      members["detail"] = JsonPrimitive(card.detail)
      card.durationMilliseconds?.let { members["durationMilliseconds"] = JsonPrimitive(it) }
      members["receivedAtMs"] = JsonPrimitive(card.receivedAtMs)
      return JsonObject(members)
    }

    private fun JsonObject.stringOf(key: String): String? =
      (this[key] as? JsonPrimitive)?.let { if (it.isString) it.content else null }

    private fun JsonObject.longOf(key: String): Long? =
      (this[key] as? JsonPrimitive)?.let { if (it.isString) null else it.content.toLongOrNull() }

    /** Optional sign, ASCII digits only. A leading "+" is refused outright: Swift's signed-string
     * intake has changed across versions, and the module's convention is to accept less, never more. */
    private fun strictInt(text: String): Int? {
      if (text.isEmpty()) return null
      var start = 0
      if (text[0] == '-') {
        if (text.length == 1) return null
        start = 1
      }
      for (index in start until text.length) if (text[index] !in '0'..'9') return null
      return text.toIntOrNull()
    }
  }
}

/** `PopopxNodeResultCard.Status` (DiscoverCatalogModels.swift:449-459). Raw values are Codable storage keys. */
enum class PopopxNodeResultStatus(val rawValue: String) {
  SUCCEEDED("succeeded"),
  DEGRADED("degraded"),
  ;

  val symbol: String
    get() = when (this) {
      SUCCEEDED -> "checkmark.seal.fill"
      DEGRADED -> "exclamationmark.triangle.fill"
    }

  companion object {
    fun from(rawValue: String): PopopxNodeResultStatus? = entries.firstOrNull { it.rawValue == rawValue }
  }
}
