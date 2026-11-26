package chat.popopx.common.mesh

/**
 * Byte helpers the mesh codec needs, shaped after the Swift side so the two ports read alike:
 * `Data(popopxHex:)` / `Data.popopxHex` (apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Protocol/
 * PopopxMeshIdentity.swift:66-91) and the big-endian field writes in `PopopxMeshProtocol.swift`.
 */

private const val HEX_DIGITS = "0123456789abcdef"

/**
 * ASCII hex only. Swift's side is looser than it looks — `Character.isHexDigit` follows the Unicode
 * `Hex_Digit` property, so iOS's `isMeshPublicKey` admits fullwidth forms and `UInt8(_, radix: 16)`
 * then refuses them. Refusing at the door accepts strictly less and cannot drop a frame iOS keeps.
 */
private fun hexDigit(character: Char): Int = when (character) {
  in '0'..'9' -> character - '0'
  in 'a'..'f' -> character - 'a' + 10
  in 'A'..'F' -> character - 'A' + 10
  else -> -1
}

/** Lower-case hex, the form `SYS_POPOPX_ACK:` and the announce payload carry. */
fun ByteArray.meshHex(): String {
  val out = CharArray(size * 2)
  var at = 0
  for (byte in this) {
    val value = byte.toInt() and 0xFF
    out[at++] = HEX_DIGITS[value ushr 4]
    out[at++] = HEX_DIGITS[value and 0x0F]
  }
  return String(out)
}

/**
 * nil for an odd length or a character that is not a hex digit — Swift's `UInt8(_, radix: 16)`
 * returns nil there, and the iOS decoder's contract is "refuse, do not guess".
 */
fun String.meshHexToBytes(): ByteArray? {
  if (length % 2 != 0) return null
  val out = ByteArray(length / 2)
  var index = 0
  while (index < length) {
    val high = hexDigit(this[index])
    val low = hexDigit(this[index + 1])
    if (high < 0 || low < 0) return null
    out[index / 2] = ((high shl 4) or low).toByte()
    index += 2
  }
  return out
}

/** True for exactly 64 hex characters — a mesh public key, as iOS checks it (`isMeshPublicKey`). */
fun String.isMeshPublicKey(): Boolean = length == 64 && all { hexDigit(it) >= 0 }

/** The 8 big-endian bytes of a field that Swift writes with `withUnsafeBytes(of: bigEndian)`. */
internal fun Long.bigEndianBytes(): ByteArray =
  ByteArray(8) { index -> (this ushr (56 - 8 * index)).toByte() }

internal fun Int.bigEndianBytes(size: Int): ByteArray =
  ByteArray(size) { index -> (this ushr (8 * (size - 1 - index))).toByte() }

internal fun ByteArray.u64At(offset: Int): Long {
  var value = 0L
  for (index in 0 until 8) value = (value shl 8) or (this[offset + index].toLong() and 0xFF)
  return value
}

/** Big-endian accumulation, which is how `PopopxMeshPeerID.u64` and the fragment key read ids. */
internal fun ByteArray.u64(): Long {
  var value = 0L
  for (byte in this) value = (value shl 8) or (byte.toLong() and 0xFF)
  return value
}

internal fun sha256(input: ByteArray): ByteArray =
  java.security.MessageDigest.getInstance("SHA-256").digest(input)
