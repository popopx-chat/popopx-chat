package chat.popopx.common.cfgsec

import chat.popopx.common.crypto.ed25519Verify
import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.crypto.sha256
import java.util.zip.DataFormatException
import java.util.zip.Inflater
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Trust anchor, field readers and the zlib inflate, ported from
// apps/ios/Shared/Features/ServerConfigSync/PopopxServerClusterConfig.swift:372-731 and :1062-1142.

/** The keys this device believes. A list rather than one key so a rotation can ship before it is used. */
object PopopxServerConfigTrust {
  /**
   * Production signing key, lowercase hex of the 32-byte public half. Its private half lives outside this
   * repository, which is the whole point of pinning a key instead of deriving it from the payload.
   * The matching key id, derived rather than declared, is `k-ad1dc5463a`.
   */
  val signingPublicKeyHexes: List<String> = listOf(
    "d3941ecfa89f4e6d916cebc103a79fe3b6dd37ca8bbbc2087f70d7dece5aab6e",
  )

  /** The signature domain: a signature for another payload kind cannot be replayed as a configuration. */
  val signatureDomain: ByteArray = "popopx|popx_srv_cfg_v1|".encodeToByteArray()

  /**
   * Parsed once per process. A malformed constant surfaces as "nothing verifies" rather than as a crash
   * inside a message handler, and an empty list therefore fails closed.
   */
  val signingPublicKeys: List<ByteArray> = signingPublicKeyHexes.mapNotNull { hex ->
    decodeKeyHex(hex)?.takeIf { it.size == PopopxServerConfigLimits.SIGNING_KEY_CHARACTERS / 2 }
  }

  /**
   * Verifies and reports *which* key accepted, because the payload's `kid` is checked against that key.
   *
   * The list is a parameter with the pinned keys as its default so that a test can drive the whole pipeline —
   * decode, verify, inflate, parse — over a frame signed by a key it generated itself. Without that seam the
   * signature step is the one part of this module no test can pass, since no test holds the production private
   * half, and every downstream branch would have to be reached through `classify` instead.
   */
  fun verify(signature: ByteArray, message: ByteArray, keys: List<ByteArray> = signingPublicKeys): Int? {
    if (signature.size != PopopxServerConfigLimits.SIGNATURE_BYTE_COUNT) return null
    return keys.indices.firstOrNull { ed25519Verify(keys[it], message, signature) }
  }

  /** `k-` plus the first ten hex characters of SHA-256 over the raw public key. */
  fun keyId(publicKey: ByteArray): String =
    PopopxServerConfigLimits.KEY_ID_PREFIX + hexEncode(sha256(publicKey))
      .substring(0, PopopxServerConfigLimits.KEY_ID_HASH_CHARACTERS)

  fun keyIdFromHex(hex: String): String? {
    val raw = decodeKeyHex(hex) ?: return null
    return if (raw.size == PopopxServerConfigLimits.SIGNING_KEY_CHARACTERS / 2) keyId(raw) else null
  }

  /** Strict hex: even length, at most 256 characters, hex digits only. */
  fun decodeKeyHex(hex: String): ByteArray? {
    if (hex.length % 2 != 0 || hex.length > 256) return null
    val bytes = ByteArray(hex.length / 2)
    var index = 0
    var out = 0
    while (index < hex.length) {
      val high = Character.digit(hex[index], 16)
      val low = Character.digit(hex[index + 1], 16)
      if (high < 0 || low < 0) return null
      bytes[out++] = ((high shl 4) or low).toByte()
      index += 2
    }
    return bytes
  }
}

/**
 * Reads a JSON element without the casts and the number-kind guessing recurring at every call site.
 *
 * The integer test is the reason this is its own object: a JSON `true` must not read as generation one, and
 * `1e3` is a different *type* of claim rather than 1000 spelled another way. Only an unquoted integral
 * literal passes, and the ceiling is compared on the exact integer rather than on a double, because
 * 9 007 199 254 740 993 and 9 007 199 254 740 992 are the same double.
 */
object PopopxServerConfigField {
  private const val HEX_CHARACTERS = "0123456789abcdef"
  private const val DIGIT_CHARACTERS = "0123456789"

  /** kotlinx parses strictly, which is what iOS's `JSONSerialization` does with no options set. */
  internal val json = Json { isLenient = false; ignoreUnknownKeys = true }

  fun objectOf(body: ByteArray): JsonObject {
    val element = try {
      json.parseToJsonElement(body.decodeToString())
    } catch (e: Exception) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.BODY_NOT_JSON)
    }
    return element as? JsonObject
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.BODY_NOT_OBJECT)
  }

  /** An absent roster is an empty one; anything else keeps its own reason. */
  fun rows(
    value: JsonElement?,
    ceiling: Int,
    invalid: PopopxServerConfigRejection,
    tooLarge: PopopxServerConfigRejection,
  ): List<JsonElement> {
    if (value == null) return emptyList()
    val rows = value as? JsonArray ?: throw PopopxServerConfigRefused(invalid)
    if (rows.size > ceiling) throw PopopxServerConfigRefused(tooLarge)
    return rows.toList()
  }

  fun integer(value: JsonElement?): Long? {
    val primitive = value as? JsonPrimitive ?: return null
    if (primitive.isString) return null
    if (primitive is JsonNull) return null
    val exact = primitive.content.toLongOrNull() ?: return null
    if (exact < 0 || exact > PopopxServerConfigLimits.MAXIMUM_COUNTER_VALUE) return null
    return exact
  }

  /** A counter field: a JSON integer, at least one, bounded so it survives a double round trip. */
  fun counter(value: JsonElement?): Long? = integer(value)?.takeIf { it >= 1 }

  fun text(value: JsonElement?): String? {
    val primitive = value as? JsonPrimitive ?: return null
    return if (primitive.isString) primitive.content else null
  }

  fun strings(value: JsonElement?): List<String>? {
    val rows = value as? JsonArray ?: return null
    return rows.map { text(it) ?: return null }
  }

  /**
   * `ack` travels as the string `"on"`/`"off"` in the operator's config format while the generator's parser
   * also accepts a JSON boolean. Both are read; `1` is refused, because a truthy number is a different
   * agreement about what the field means rather than another spelling of the same one.
   */
  fun flag(value: JsonElement?): Boolean? {
    val primitive = value as? JsonPrimitive ?: return null
    if (!primitive.isString) {
      if (primitive.content == "true") return true
      if (primitive.content == "false") return false
      return null
    }
    return when (primitive.content) {
      "on" -> true
      "off" -> false
      else -> null
    }
  }

  internal fun isHex(text: String): Boolean = text.all { HEX_CHARACTERS.contains(it) }

  internal fun isDigit(text: String): Boolean = text.all { DIGIT_CHARACTERS.contains(it) }

  internal fun isBase64UrlChar(ch: Char): Boolean =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".contains(ch)

  internal fun isStandardBase64Char(ch: Char): Boolean =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".contains(ch)
}

/**
 * zlib decompression under a hard output ceiling, with the framing checked here rather than by the decoder.
 *
 * The ceiling, the truncation and the trailing bytes are three different refusals and they must stay three,
 * because they name three different defects: a bomb, a cut line, and a second stream glued onto a signed
 * one. Every non-success path refuses, and no path returns partial output.
 */
object PopopxServerConfigInflator {
  fun inflate(source: ByteArray): ByteArray {
    // Two header bytes plus a four-byte trailer, and nothing in between, is the smallest real stream.
    if (source.size < 6 || !hasZlibHeader(source)) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.DEFLATE_HEADER_INVALID)
    }
    // One byte above the ceiling, so "exactly at the limit" succeeds and "over it" is a detected condition.
    val capacity = PopopxServerConfigLimits.MAXIMUM_INFLATED_BYTES + 1
    val destination = ByteArray(capacity)
    val trailer = bigEndianUInt32(source, source.size - 4)
    val inflater = Inflater(true)
    try {
      inflater.setInput(source, 2, source.size - 6)
      var produced = 0
      while (!inflater.finished()) {
        val room = capacity - produced
        if (room == 0) throw PopopxServerConfigRefused(PopopxServerConfigRejection.DEFLATE_OVER_CAP)
        val count = try {
          inflater.inflate(destination, produced, room)
        } catch (e: DataFormatException) {
          // A corrupt stream and one that stops mid-block both surface here; which name is logged is a
          // diagnostic, not a decision — neither path may return bytes.
          throw PopopxServerConfigRefused(
            if (inflater.needsInput()) PopopxServerConfigRejection.DEFLATE_TRUNCATED
            else PopopxServerConfigRejection.DEFLATE_FAILED,
          )
        }
        produced += count
        if (count == 0 && !inflater.finished()) {
          throw PopopxServerConfigRefused(
            if (inflater.needsInput()) PopopxServerConfigRejection.DEFLATE_TRUNCATED
            else PopopxServerConfigRejection.DEFLATE_FAILED,
          )
        }
      }
      if (produced > PopopxServerConfigLimits.MAXIMUM_INFLATED_BYTES) {
        throw PopopxServerConfigRefused(PopopxServerConfigRejection.DEFLATE_OVER_CAP)
      }
      // Nothing may follow the deflate stream inside the payload: the generator refuses to sign that, and
      // this device refuses to read it.
      if (inflater.remaining != 0) throw PopopxServerConfigRefused(PopopxServerConfigRejection.DEFLATE_TRAILING_BYTES)
      if (adler32(destination, produced) != trailer) {
        throw PopopxServerConfigRefused(PopopxServerConfigRejection.CHECKSUM_MISMATCH)
      }
      return destination.copyOf(produced)
    } finally {
      inflater.end()
    }
  }

  /**
   * RFC 1950's two-byte header check: method 8, window within 32 KiB, no preset dictionary, header
   * checksum divisible by 31. The specific `0x78 0xDA` a level-9 stream produces is deliberately not
   * required: FLEVEL is informational, and demanding one byte string would refuse a valid frame built by
   * any other zlib.
   */
  internal fun hasZlibHeader(data: ByteArray): Boolean {
    if (data.size < 2) return false
    val first = data[0].toInt() and 0xFF
    val second = data[1].toInt() and 0xFF
    if (first and 0x0F != 8) return false
    if (first shr 4 >= 8) return false
    if (second and 0x20 != 0) return false
    return (((first shl 8) or second) % 31) == 0
  }

  /** The trailer as RFC 1950 stores it: big-endian. */
  internal fun bigEndianUInt32(bytes: ByteArray, at: Int): Long {
    if (at < 0 || at + 4 > bytes.size) return -1L
    var value = 0L
    for (index in at until at + 4) value = (value shl 8) or (bytes[index].toLong() and 0xFF)
    return value
  }

  /** RFC 1950's checksum over the inflated bytes, computed here rather than trusted from the decoder. */
  internal fun adler32(bytes: ByteArray, count: Int): Long {
    var low = 1L
    var high = 0L
    for (index in 0 until count) {
      low = (low + (bytes[index].toLong() and 0xFF)) % 65521L
      high = (high + low) % 65521L
    }
    return (high shl 16) or low
  }
}
