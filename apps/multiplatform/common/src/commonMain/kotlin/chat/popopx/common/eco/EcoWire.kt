package chat.popopx.common.eco

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

// The wire readers shared by the eco frames (PopopxEcoModels.kt) and the channel envelope
// (PopopxChannelEnvelope.kt). On iOS both are `private` to their own file and are simply repeated;
// keeping one copy here is the only place the two can still disagree by accident, so the rule they
// implement is written once:
//
//   a value that is absent takes the default, a value that is present but of the wrong type or
//   malformed rejects the WHOLE frame. Nothing is coerced, clamped or skipped.

/** Signals a rejected frame. It carries no message because there is only ever one answer: drop it. */
internal class EcoReject : Exception()

internal fun JsonObject.string(key: String): String? =
  (this[key] as? JsonPrimitive)?.let { if (it.isString) it.content else throw EcoReject() }

internal fun JsonObject.stringOrThrow(key: String): String = string(key) ?: throw EcoReject()

/**
 * Numbers must arrive unquoted. `"42"` is a string to Swift's decoder too, so accepting it here would
 * let a frame through that the other platform throws away.
 */
internal fun JsonObject.long(key: String): Long? =
  (this[key] as? JsonPrimitive)?.let { if (it.isString) throw EcoReject() else it.content.toLongOrNull() ?: throw EcoReject() }

internal fun JsonObject.int(key: String): Int? =
  (this[key] as? JsonPrimitive)?.let { if (it.isString) throw EcoReject() else it.content.toIntOrNull() ?: throw EcoReject() }

internal fun JsonObject.boolean(key: String): Boolean? =
  (this[key] as? JsonPrimitive)?.let {
    if (it.isString) throw EcoReject()
    when (it.content) {
      "true" -> true
      "false" -> false
      else -> throw EcoReject()
    }
  }

internal fun JsonObject.child(key: String): JsonObject? = this[key]?.jsonObjectOrThrow()

internal fun JsonObject.array(key: String): JsonArray? {
  val element = this[key] ?: return null
  return element.jsonArrayOrThrow()
}

internal fun JsonElement.jsonObjectOrThrow(): JsonObject = this as? JsonObject ?: throw EcoReject()

internal fun JsonElement.jsonArrayOrThrow(): JsonArray = this as? JsonArray ?: throw EcoReject()

/**
 * A JsonObject that keeps the order it was given, which matters because the encoder's output is a
 * signature preimage on the commerce side and a comparable wire string in the tests here.
 */
internal fun ecoJsonObject(vararg pairs: Pair<String, JsonElement>): JsonObject =
  JsonObject(LinkedHashMap<String, JsonElement>().apply { putAll(pairs) })

/**
 * Split on runs of whitespace, dropping the empty pieces — the same shape Swift's
 * `split(whereSeparator: \.isWhitespace)` produces, and the reason this is written out rather than
 * done with a regex: `\s` is narrower than `Char.isWhitespace()`, and a frame tokenised differently on
 * the two platforms parses as two different things.
 */
internal fun String.ecoTokens(): List<String> {
  val out = ArrayList<String>()
  var index = 0
  while (index < length) {
    if (this[index].isWhitespace()) {
      index++
      continue
    }
    val start = index
    while (index < length && !this[index].isWhitespace()) index++
    out.add(substring(start, index))
  }
  return out
}
