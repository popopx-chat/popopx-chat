package chat.popopx.common.copilot

import java.security.MessageDigest

/**
 * SHA-256 in lowercase hex, from `java.security`.
 *
 * The hex is written with a char loop rather than `String.format("%02x")` or a iterator of
 * `toString(16)`: `format` is locale-sensitive on Android and returns a padded, grouped string for
 * some locales, and this digest is the value the bundled weights are accepted or refused on.
 */
actual fun popopxSha256Hex(bytes: ByteArray): String {
  val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
  val hex = CharArray(digest.size * 2)
  var position = 0
  for (byte in digest) {
    val value = byte.toInt() and 0xFF
    hex[position++] = DIGITS[value ushr 4]
    hex[position++] = DIGITS[value and 0x0F]
  }
  return String(hex)
}

/** The hex alphabet, lowercase, as a constant so the loop above allocates nothing per byte. */
private const val DIGITS = "0123456789abcdef"

/**
 * Streaming variant: the digest of bytes as they are read, for an asset too large to hash from a
 * buffer the caller already holds. Kept here so the only two digest paths in this feature are the two
 * in this file.
 */
internal fun popopxSha256Update(digest: MessageDigest, buffer: ByteArray, count: Int) {
  digest.update(buffer, 0, count)
}

internal fun popopxNewSha256(): MessageDigest = MessageDigest.getInstance("SHA-256")

internal fun popopxSha256Hex(digest: MessageDigest): String = popopxSha256Hex(digest.digest())
