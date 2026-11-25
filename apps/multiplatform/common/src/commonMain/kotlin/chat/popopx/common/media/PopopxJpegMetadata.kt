package chat.popopx.common.media

import java.io.ByteArrayOutputStream
import java.io.File

// Second-layer identity-metadata scrub for the JPEG this engine writes.
//
// The re-encode is what actually removes EXIF (a `Bitmap.compress` stream carries no camera block), exactly as on
// iOS, where recompressing through ImageIO is the sanitizer. This file is the insurance policy for that claim: it
// walks the marker list and drops the segments that name the device, the place or the editor, and it is reachable
// from desktopTest, so the claim is checked off-device instead of asserted in a comment.
//
// Kept on purpose: APP0/JFIF (framing), the ICC profile in APP2 (colour fidelity — the Haskell resize path keeps it
// too), every coding segment, everything from the start-of-stream marker onward, and the bytes after
// end-of-stream, which iOS also leaves alone.
// Dropped: APP1/Exif (model, GPS, orientation, and the thumbnail embedded inside it), APP1/XMP, APP1/MPF,
// APP0/JFXX (the grayscale thumbnail extension), APP12, APP13, and any other APP2 or any COM.

internal object PopopxJpegMetadata {
  private const val SOI = 0xFFD8
  private const val EOI = 0xFFD9
  private const val SOS = 0xFFDA
  private const val TEM = 0xFF01
  private const val APP0 = 0xFFE0
  private const val APP1 = 0xFFE1
  private const val APP2 = 0xFFE2
  private const val APP12 = 0xFFEC
  private const val APP13 = 0xFFED
  private const val COM = 0xFFFE

  fun isJpeg(bytes: ByteArray): Boolean =
    bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()

  /** True when the stream still carries a segment that can name a device, a place or an editor. */
  fun hasIdentityMetadata(bytes: ByteArray): Boolean = strip(bytes) != null

  /** Rewrites [file] in place. Returns the number of bytes removed, 0 when it was clean or unreadable. */
  fun stripFromFile(file: File): Int {
    if (!file.isFile) return 0
    val bytes = runCatching { file.readBytes() }.getOrNull() ?: return 0
    val stripped = strip(bytes) ?: return 0
    return runCatching { file.writeBytes(stripped) }.fold({ bytes.size - stripped.size }, { 0 })
  }

  /**
   * Null when there is nothing to remove or the header cannot be parsed, so every failure mode leaves the file
   * untouched instead of producing a truncated image.
   */
  fun strip(bytes: ByteArray): ByteArray? {
    if (!isJpeg(bytes)) return null
    val out = ByteArrayOutputStream(bytes.size)
    out.write(bytes, 0, 2)
    var offset = 2
    var dropped = 0
    while (offset + 2 <= bytes.size) {
      if (bytes[offset] != 0xFF.toByte()) return null
      val marker = 0xFF00 or (bytes[offset + 1].toInt() and 0xFF)
      if (marker == SOS || marker == EOI) {
        out.write(bytes, offset, bytes.size - offset)
        return if (dropped == 0) null else out.toByteArray()
      }
      if (isStandalone(marker)) {
        out.write(bytes, offset, 2)
        offset += 2
        continue
      }
      if (offset + 4 > bytes.size) return null
      val length = (bytes[offset + 2].toInt() and 0xFF shl 8) or (bytes[offset + 3].toInt() and 0xFF)
      // `length` counts itself but not the two marker bytes.
      if (length < 2 || offset + 2 + length > bytes.size) return null
      val payload = bytes.copyOfRange(offset + 4, minOf(offset + 2 + length, bytes.size))
      if (isIdentitySegment(marker, payload)) {
        dropped += 2 + length
      } else {
        out.write(bytes, offset, 2 + length)
      }
      offset += 2 + length
    }
    return null
  }

  /** Markers with no length field: RSTn, TEM, and the two that delimit the stream. */
  private fun isStandalone(marker: Int): Boolean =
    marker == SOI || marker == TEM || (marker in 0xFFD0..0xFFD7)

  private fun isIdentitySegment(marker: Int, payload: ByteArray): Boolean = when (marker) {
    APP1 -> starts(payload, "Exif") || starts(payload, "http://ns.adobe.com/xap/1.0/") || starts(payload, "MPF")
    APP0 -> starts(payload, "JFXX")
    APP2 -> !starts(payload, "ICC_PROFILE")
    APP12, APP13, COM -> true
    else -> false
  }

  private fun starts(bytes: ByteArray, prefix: String): Boolean {
    if (bytes.size < prefix.length) return false
    for (i in prefix.indices) if (bytes[i] != prefix[i].code.toByte()) return false
    return true
  }
}
