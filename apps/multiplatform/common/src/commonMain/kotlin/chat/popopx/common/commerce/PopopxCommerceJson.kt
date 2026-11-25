package chat.popopx.common.commerce

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// The wire layer of this module.
//
// Two jobs, deliberately kept apart:
//
//  1. `PopopxSwiftJson` writes a redemption-code body BYTE-FOR-BYTE as Swift's `JSONEncoder` with
//     `.sortedKeys` writes it (`PopopxBadgeCreditsModels.swift:567-568`, `:1506-1508`). Those bytes are the
//     preimage of the giver's ECDSA signature and the input of the code's checksum, so a writer that differed in
//     any of the five things listed below produces a code that THIS device decodes and every OTHER device reads as
//     a checksum failure. kotlinx' default writer is not that writer (it does not escape `/`), which is why this
//     file exists.
//  2. The strict readers below implement the same rule the eco frames use: a value that is absent takes its
//     default, a value that is present but of the wrong type or malformed rejects the WHOLE structure. Nothing is
//     coerced, clamped or skipped — an envelope whose `signature` arrived as `"42"` must not parse.

/** Signals a rejected structure. It carries no message because there is only one answer: drop it. */
internal class CommerceReject : Exception()

/** The reader used for this device's own persisted rows; unknown keys are ignored so a newer build can be downgraded. */
internal val commerceJson: Json = Json { ignoreUnknownKeys = true }

/**
 * The byte-faithful `JSONEncoder([.sortedKeys])` body writer.
 *
 * Measured against Apple's output with `/usr/bin/swift` 6.4.2, and pinned in
 * `desktopTest/kotlin/chat/popopx/app/commerce/PopopxCommerceSwiftVectors.kt`:
 *  - keys in ascending order, no whitespace anywhere;
 *  - `"` → `\"`, `\` → `\\`, `/` → `\/` (this one is what makes a hand-written writer necessary);
 *  - `\b \f \n \r \t` get their short escapes, every other character below U+0020 becomes `\u00xx` with LOWER-CASE
 *    hex digits;
 *  - non-ASCII is written raw, not `\u`-escaped, and is NOT re-encoded — a surrogate pair passes through as it came;
 *  - a null field is omitted entirely (`Optional.none` in Swift's encoder), which is why "no period" and
 *    "period = something falsy" can never be confused in a credit envelope.
 *
 * Integers only: this module has no decimal money anywhere, so there is no float formatting to reproduce.
 */
internal object PopopxSwiftJson {
  /** One JSON object: `fields` may be in any order and may carry nulls. */
  fun body(fields: List<Pair<String, Any?>>): String {
    val kept = ArrayList<Pair<String, String>>(fields.size)
    for (field in fields) {
      val value = field.second ?: continue
      kept.add(field.first to literal(value))
    }
    kept.sortBy { it.first }
    return buildString {
      append('{')
      kept.forEachIndexed { index, (key, value) ->
        if (index > 0) append(',')
        append(quote(key))
        append(':')
        append(value)
      }
      append('}')
    }
  }

  private fun literal(value: Any): String = when (value) {
    is String -> quote(value)
    is Int -> value.toString()
    is Long -> value.toString()
    is Boolean -> value.toString()
    else -> throw CommerceReject()
  }

  private fun quote(text: String): String = buildString(text.length + 2) {
    append('"')
    for (character in text) {
      // Everything outside the list below goes out as it came in, non-ASCII included: Foundation writes UTF-8, not
      // `\u` escapes, and re-encoding a surrogate pair here would change the bytes the signature covers.
      when (character) {
        '"' -> append("\\\"")
        '\\' -> append("\\\\")
        '/' -> append("\\/")
        '\b' -> append("\\b")
        '\u000C' -> append("\\f")
        '\n' -> append("\\n")
        '\r' -> append("\\r")
        '\t' -> append("\\t")
        else -> if (character.code < 0x20) append(unicodeEscape(character.code)) else append(character)
      }
    }
    append('"')
  }

  /** `\u00xx`, lower-case hex digits, exactly as Foundation prints the control characters that have no short form. */
  private fun unicodeEscape(code: Int): String {
    val digits = "0123456789abcdef"
    return "\\u00${digits[code shr 4]}${digits[code and 0x0F]}"
  }
}

// MARK: strict readers

internal fun JsonObject.commerceString(key: String): String? =
  (this[key] as? JsonPrimitive)?.let { if (it.isString) it.content else throw CommerceReject() }

internal fun JsonObject.commerceStringOrThrow(key: String): String = commerceString(key) ?: throw CommerceReject()

/** Numbers must arrive unquoted; `"42"` is a string to Swift's decoder too. */
internal fun JsonObject.commerceLong(key: String): Long? =
  (this[key] as? JsonPrimitive)?.let { if (it.isString) throw CommerceReject() else it.content.toLongOrNull() ?: throw CommerceReject() }

internal fun JsonObject.commerceLongOrThrow(key: String): Long = commerceLong(key) ?: throw CommerceReject()

internal fun JsonObject.commerceInt(key: String): Int? =
  (this[key] as? JsonPrimitive)?.let { if (it.isString) throw CommerceReject() else it.content.toIntOrNull() ?: throw CommerceReject() }

internal fun JsonObject.commerceIntOrThrow(key: String): Int = commerceInt(key) ?: throw CommerceReject()

internal fun JsonObject.commerceBoolean(key: String): Boolean? =
  (this[key] as? JsonPrimitive)?.let {
    if (it.isString) throw CommerceReject()
    when (it.content) {
      "true" -> true
      "false" -> false
      else -> throw CommerceReject()
    }
  }

internal fun JsonObject.commerceChild(key: String): JsonObject? = this[key]?.commerceObjectOrThrow()

internal fun JsonObject.commerceArray(key: String): JsonArray? {
  val element = this[key] ?: return null
  return element.commerceArrayOrThrow()
}

internal fun JsonElement.commerceObjectOrThrow(): JsonObject = this as? JsonObject ?: throw CommerceReject()

internal fun JsonElement.commerceArrayOrThrow(): JsonArray = this as? JsonArray ?: throw CommerceReject()

/** A `JsonObject` that keeps the order it was given, so a persisted row can be compared as a string in tests. */
internal fun commerceJsonObject(vararg pairs: Pair<String, JsonElement>): JsonObject =
  JsonObject(LinkedHashMap<String, JsonElement>().apply { putAll(pairs) })

/**
 * Parse a whole JSON object, rejecting anything that is not an object.
 *
 * `Json.parseToJsonElement` is the only entry point this module uses: a body is either one object or it is not a
 * body, and a lenient reader would accept the truncated text a mistyped code decodes to.
 */
internal fun commerceParse(text: String): JsonObject {
  val element = try {
    commerceJson.parseToJsonElement(text)
  } catch (e: Exception) {
    throw CommerceReject()
  }
  return element.commerceObjectOrThrow()
}
