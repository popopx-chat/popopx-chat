package chat.popopx.common.mesh

import java.math.BigDecimal
import java.math.BigInteger

/**
 * The payload a mesh chat message travels in: sorted-key JSON, the same bytes iOS writes with
 * `JSONEncoder` + `[.sortedKeys]` (`Events/PopopxMeshEvents.swift:44-76`, encoded at
 * `PopopxMeshEngine.swift:1201-1205`).
 *
 * Kotlin cannot borrow a serialiser's field order here, because iOS' order comes from key sorting
 * rather than declaration order, and the receiving half is stricter than a lenient map lookup would
 * be. Every rule in [decode] was measured against the iOS decoder with crafted documents - the
 * `envelopeDecode.*` block of the cross-platform vector file - rather than assumed.
 */
class PopopxMeshEnvelope(
  val id: String,
  /** Wall-clock millis. Unsigned 64-bit held in a Long, so compare with java.lang.Long.compareUnsigned. */
  val sentAt: Long,
  val kind: Kind,
  val body: String,
) {
  enum class Kind(val wire: String) {
    TEXT("text"),
    CONTROL("control"),
    ;

    companion object {
      fun of(wire: String): Kind? = entries.firstOrNull { it.wire == wire }
    }
  }

  /** Nil for a TEXT envelope as well as for a CONTROL body that is not a frame. */
  val controlFrame: PopopxMeshControlFrame?
    get() = if (kind == Kind.CONTROL) PopopxMeshControlFrame.of(body) else null

  override fun equals(other: Any?): Boolean =
    other is PopopxMeshEnvelope &&
      other.id == id &&
      other.sentAt == sentAt &&
      other.kind == kind &&
      other.body == body

  override fun hashCode(): Int {
    var result = id.hashCode()
    result = 31 * result + sentAt.hashCode()
    result = 31 * result + kind.hashCode()
    result = 31 * result + body.hashCode()
    return result
  }

  override fun toString(): String =
    "PopopxMeshEnvelope(id=$id, sentAt=${java.lang.Long.toUnsignedString(sentAt)}, kind=${kind.wire}, body=$body)"

  companion object {
    /** Key order is the sorted order iOS emits, and `sentAt` is a bare unsigned integer. */
    fun encode(envelope: PopopxMeshEnvelope): ByteArray =
      buildString {
        append("{\"body\":")
        append(jsonString(envelope.body))
        append(",\"id\":")
        append(jsonString(envelope.id))
        append(",\"kind\":\"")
        append(envelope.kind.wire)
        append("\",\"sentAt\":")
        append(java.lang.Long.toUnsignedString(envelope.sentAt))
        append('}')
      }.toByteArray(Charsets.UTF_8)

    fun decode(data: ByteArray): PopopxMeshEnvelope? = decode(data.toString(Charsets.UTF_8))

    /**
     * nil unless the document is exactly what iOS' JSONDecoder accepts for this shape.
     *
     * Measured: a required member of the wrong type, an unknown kind, a missing member, trailing
     * content after the object, a raw control character inside a string, a bad unicode escape and a
     * non-integer sentAt are all rejections. A leading UTF-8 BOM, whitespace wherever JSON allows
     * it, and unrecognised keys are all accepted.
     */
    fun decode(json: String): PopopxMeshEnvelope? {
      val fields = JsonFlatReader(json).readObject() ?: return null
      val body = (fields["body"] as? JsonValue.Str)?.text ?: return null
      val id = (fields["id"] as? JsonValue.Str)?.text ?: return null
      val wire = (fields["kind"] as? JsonValue.Str)?.text ?: return null
      val kind = Kind.of(wire) ?: return null
      val number = fields["sentAt"] as? JsonValue.Num ?: return null
      val sentAt = unsignedInteger(number.literal) ?: return null
      return PopopxMeshEnvelope(id = id, sentAt = sentAt, kind = kind, body = body)
    }

    fun text(id: String, body: String): PopopxMeshEnvelope =
      PopopxMeshEnvelope(id = id, sentAt = PopopxMeshPacket.nowMillis(), kind = Kind.TEXT, body = body)

    fun control(id: String, frame: PopopxMeshControlFrame): PopopxMeshEnvelope =
      PopopxMeshEnvelope(id = id, sentAt = PopopxMeshPacket.nowMillis(), kind = Kind.CONTROL, body = frame.text)

    /**
     * A JSON string literal, escaped the way Swift's encoder escapes it.
     *
     * The set is measured, not inferred from the JSON spec: Swift uses the short forms for the five
     * printable escapes, writes every other character below 0x20 as lower-case `\u00xx`, escapes the
     * solidus (which most encoders leave alone), and leaves 0x7F, NBSP, the apostrophe, U+2028,
     * U+2029 and everything outside the BMP unescaped. A different set would still decode, but it
     * would not be the bytes the sender hashed, and the envelope id is what dedup and ACK key on.
     */
    fun jsonString(value: String): String {
      val out = StringBuilder(value.length + 2)
      out.append('"')
      for (char in value) {
        val code = char.code
        when {
          char == '"' -> out.append("\\\"")
          char == '\\' -> out.append("\\\\")
          char == '/' -> out.append("\\/")
          char == '\n' -> out.append("\\n")
          char == '\r' -> out.append("\\r")
          char == '\t' -> out.append("\\t")
          code == 0x08 -> out.append("\\b")
          code == 0x0C -> out.append("\\f")
          code < 0x20 -> out.append("\\u00").append(hexNibble(code shr 4)).append(hexNibble(code and 0x0F))
          else -> out.append(char)
        }
      }
      out.append('"')
      return out.toString()
    }

    /**
     * The literal a peer put in `sentAt`, read the way Swift's `UInt64` JSON decoding reads it.
     *
     * The grammar is JSON's own, so `01` is not a number and `1.` is not either; both were measured
     * as rejections. What is surprising is that `1e3` and `1000.0` are accepted and land on 1000,
     * while `1.5` and `1e-1` are refused: the value has to be an exact integer, not merely written
     * without a dot. Negative and over 2^64-1 are refused, and the returned Long carries the
     * unsigned bits, so a value above Long.MAX_VALUE is not an error.
     */
    internal fun unsignedInteger(literal: String): Long? {
      if (!JSON_NUMBER_GRAMMAR.matches(literal)) return null
      val value = runCatching { BigDecimal(literal).toBigIntegerExact() }.getOrNull() ?: return null
      if (value.signum() < 0 || value.bitLength() > 64) return null
      return value.toLong()
    }

    private const val HEX = "0123456789abcdef"

    private fun hexNibble(value: Int): Char = HEX[value and 0x0F]
  }
}

/** What a JSON member value can be. Only [Str] and [Num] can ever satisfy an envelope field. */
internal sealed class JsonValue {
  class Str(val text: String) : JsonValue()
  class Num(val literal: String) : JsonValue()
  class Bool(val value: Boolean) : JsonValue()
  object Null : JsonValue()

  /** An object or an array: syntactically fine, and the wrong type for every field here. */
  object Nested : JsonValue()
}

/**
 * The smallest reader that reproduces iOS' `JSONDecoder` for this document.
 *
 * Deliberately flat: an envelope has four scalar fields, and a nested value only has to be skipped
 * correctly so that `{"body":{...}}` fails as a *type* mismatch rather than as a parse error, which
 * is what iOS does. Numbers keep their literal text because `sentAt` is judged the way Swift judges
 * it, as an integer value rather than as a double that happens to look whole.
 *
 * Duplicate keys are the one place where a hand-written reader would drift: iOS keeps the **first**
 * occurrence and never looks at the rest, measured with `duplicateBody` (a then b yields a),
 * `dupBodyThree` (a b c yields a), `dupId` (i1 then i2 yields i1) and, for the negative side,
 * `dupBodyBadThenGood` and `dupSentAtBadThenGood` both refused because the *first* value was the
 * wrong type while `dupKindValidThenBogus` and `dupSentAtGoodThenBad` decoded. Taking the last,
 * which is what a map built from a parsed dictionary does, would accept a frame iOS drops.
 */
internal class JsonFlatReader(private val text: String) {
  private var pos = 0

  fun readObject(): Map<String, JsonValue>? {
    skipWhitespace()
    // Measured: iOS' decoder strips a leading BOM to work out the encoding. Only the BOM directly
    // before the object was probed, so the whitespace handling around it is grammar, not measurement.
    if (pos < text.length && text[pos] == '﻿') pos += 1
    skipWhitespace()
    if (!consume('{')) return null
    val members = LinkedHashMap<String, JsonValue>()
    skipWhitespace()
    if (consume('}')) return if (restIsBlank()) members else null
    while (true) {
      skipWhitespace()
      val key = readString() ?: return null
      skipWhitespace()
      if (!consume(':')) return null
      skipWhitespace()
      val value = readValue() ?: return null
      if (!members.containsKey(key)) members[key] = value
      skipWhitespace()
      if (consume(',')) continue
      if (consume('}')) return if (restIsBlank()) members else null
      return null
    }
  }

  private fun readValue(): JsonValue? {
    if (pos >= text.length) return null
    return when (text[pos]) {
      '"' -> readString()?.let { JsonValue.Str(it) }
      '{', '[' -> if (skipNested()) JsonValue.Nested else null
      else -> {
        if (text.startsWith("true", pos)) {
          pos += 4
          JsonValue.Bool(true)
        } else if (text.startsWith("false", pos)) {
          pos += 5
          JsonValue.Bool(false)
        } else if (text.startsWith("null", pos)) {
          pos += 4
          JsonValue.Null
        } else {
          readNumber()
        }
      }
    }
  }

  private fun readNumber(): JsonValue? {
    val start = pos
    while (pos < text.length && text[pos] in NUMBER_CHARS) pos += 1
    if (pos == start) return null
    val literal = text.substring(start, pos)
    return if (JSON_NUMBER_GRAMMAR.matches(literal)) JsonValue.Num(literal) else null
  }

  /** A string member, quoted, with Swift's escapes and Swift's refusal of a raw control character. */
  private fun readString(): String? {
    if (!consume('"')) return null
    val out = StringBuilder()
    while (pos < text.length) {
      val char = text[pos]
      when {
        char == '"' -> {
          pos += 1
          return out.toString()
        }
        char == '\\' -> {
          pos += 1
          if (pos >= text.length) return null
          val escape = text[pos]
          pos += 1
          when (escape) {
            '"' -> out.append('"')
            '\\' -> out.append('\\')
            '/' -> out.append('/')
            'b' -> out.append('\b')
            'f' -> out.append(FF)
            'n' -> out.append('\n')
            'r' -> out.append('\r')
            't' -> out.append('\t')
            'u' -> {
              // Exactly four hex digits, and nothing else: a short tail or a non-hex digit is a
              // rejection rather than a replacement character, which is what `badUnicodeEscape`
              // measured.
              if (pos + 4 > text.length) return null
              val digits = text.substring(pos, pos + 4)
              val code = digits.toIntOrNull(radix = 16) ?: return null
              if (digits.any { it !in HEX_DIGITS }) return null
              pos += 4
              out.append(code.toChar())
            }
            else -> return null
          }
        }
        else -> {
          // A raw control character inside a string is invalid JSON, and iOS refuses it rather than
          // sanitising it (`controlInString`).
          if (char.code < 0x20) return null
          out.append(char)
          pos += 1
        }
      }
    }
    return null
  }

  /** Consumes a balanced object or array and reports whether it was balanced. */
  private fun skipNested(): Boolean {
    var depth = 0
    var inString = false
    var escaped = false
    while (pos < text.length) {
      val char = text[pos]
      pos += 1
      when {
        inString -> {
          if (escaped) escaped = false
          else if (char == '\\') escaped = true
          else if (char == '"') inString = false
          else if (char.code < 0x20) return false
        }
        char == '"' -> inString = true
        char == '{' || char == '[' -> depth += 1
        char == '}' || char == ']' -> {
          depth -= 1
          if (depth == 0) return true
          if (depth < 0) return false
        }
      }
    }
    return false
  }

  private fun consume(char: Char): Boolean {
    if (pos >= text.length || text[pos] != char) return false
    pos += 1
    return true
  }

  private fun skipWhitespace() {
    while (pos < text.length && text[pos] in JSON_WHITESPACE) pos += 1
  }

  /** Nothing but whitespace may follow the closing brace: `trailingGarbage` and `trailingObject`. */
  private fun restIsBlank(): Boolean {
    skipWhitespace()
    return pos == text.length
  }

  private companion object {
    val FF = 12.toChar()
    const val JSON_WHITESPACE = " \t\n\r"
    // Swift's scanner accepts exactly these for a number, so "abc" or "+1" never even becomes a Num.
    const val NUMBER_CHARS = "-+.eE0123456789"
    const val HEX_DIGITS = "0123456789abcdefABCDEF"
  }
}

/**
 * JSON's own number grammar, and the reason two of the measured rejections are not type errors.
 *
 * `01` and `1.` are not numbers at all, so the member is absent rather than wrong-typed, and
 * `sentAtLeadingZero`/`sentAtTrailingDot` come back nil for the missing-field rule.
 */
internal val JSON_NUMBER_GRAMMAR = Regex("-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?")
