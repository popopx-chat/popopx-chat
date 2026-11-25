package chat.popopx.common.media

// Content-first classification probes, ported from the `identify`/`looksLikeText` half of
// apps/ios/Shared/Features/MediaCompression/PopopxMediaEngine.swift:225-267.
//
// iOS asks ImageIO, AVFoundation and PDFKit; none of those exist here, so the equivalents are the container
// signatures themselves plus two real format walks (GIF blocks, PNG/WebP chunks). Reading the bytes rather
// than the extension is the property that matters and it is preserved: a JPEG renamed `.dat` is still caught
// as an image, and a ZIP renamed `.txt` is still kept out of the container.
//
// Where a walk cannot finish inside the prefix it was given, the answer is the conservative one. For an
// animated container "conservative" means pass it through untouched, because the alternative is re-encoding a
// multi-frame GIF into a single-frame JPEG, which destroys the attachment to save bytes.

internal const val POPOPX_MEDIA_TEXT_PROBE_BYTES = 2048
internal const val POPOPX_MEDIA_FORMAT_PROBE_BYTES = 65_536

private fun ascii(value: String): ByteArray = value.encodeToByteArray()

private fun matchesAt(data: ByteArray, offset: Int, signature: ByteArray): Boolean {
  if (offset < 0 || offset + signature.size > data.size) return false
  for (index in signature.indices) {
    if (data[offset + index] != signature[index]) return false
  }
  return true
}

private fun fourCC(data: ByteArray, offset: Int): String? {
  if (offset < 0 || offset + 4 > data.size) return null
  return String(data, offset, 4, Charsets.ISO_8859_1)
}

private fun littleInt(data: ByteArray, offset: Int): Int? {
  if (offset < 0 || offset + 4 > data.size) return null
  return (data[offset].toInt() and 0xFF) or
    ((data[offset + 1].toInt() and 0xFF) shl 8) or
    ((data[offset + 2].toInt() and 0xFF) shl 16) or
    ((data[offset + 3].toInt() and 0xFF) shl 24)
}

// MARK: - Text

/**
 * A document is text only when its first block carries no stray control bytes; this is what keeps a
 * ZIP-based format out of the container. Byte-for-byte the iOS rule, including the escape byte 0x1B that is
 * allowed through and the UTF-8 BOM that short-circuits the whole scan.
 */
internal fun popopxLooksLikeText(head: ByteArray): Boolean {
  if (head.isEmpty()) return false
  if (matchesAt(head, 0, byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()))) return true
  for (byte in head) {
    val value = byte.toInt() and 0xFF
    if (value < 0x09 || (value > 0x0D && value < 0x20 && value != 0x1B)) return false
  }
  return true
}

// MARK: - Images

private val JPEG_START = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte())
private val PNG_START = byteArrayOf(
  0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
)
private val PDF_START = ascii("%PDF-")

/** The ISO-BMFF brands that hold a still image rather than a movie. */
private val IMAGE_BRANDS = setOf("heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1", "avif", "avis", "crx ")

internal fun popopxLooksLikeImage(head: ByteArray): Boolean {
  if (matchesAt(head, 0, JPEG_START)) return true
  if (matchesAt(head, 0, PNG_START)) return true
  if (fourCC(head, 0) == "GIF8" && (matchesAt(head, 4, ascii("7a")) || matchesAt(head, 4, ascii("9a")))) return true
  if (matchesAt(head, 0, ascii("RIFF")) && fourCC(head, 8) == "WEBP") return true
  if (matchesAt(head, 0, ascii("BM"))) return true
  if (matchesAt(head, 0, ascii("II")) && head.size > 3 && head[2].toInt() == 0x2A) return true
  if (matchesAt(head, 0, ascii("MM")) && head.size > 3 && head[3].toInt() == 0x2A) return true
  val brand = fourCC(head, 8)
  return matchesAt(head, 4, ascii("ftyp")) && brand != null && IMAGE_BRANDS.contains(brand.lowercase())
}

/**
 * Whether a still-looking file must not be re-encoded. Undecidable cases answer `true`, which costs a
 * compression and never an animation.
 */
internal fun popopxLooksLikeAnimatedImage(head: ByteArray): Boolean {
  if (matchesAt(head, 0, PNG_START)) return pngIsAnimated(head)
  if (matchesAt(head, 0, ascii("RIFF")) && fourCC(head, 8) == "WEBP") return webpIsAnimated(head)
  if (fourCC(head, 0) == "GIF8") return gifFrameCount(head, atLeast = 2) != 1
  return false
}

/** PNG chunk walk: `acTL` before the image data is what makes a PNG animated. */
private fun pngIsAnimated(head: ByteArray): Boolean {
  var offset = PNG_START.size
  while (offset + 8 <= head.size) {
    val length = littleInt(head, offset) ?: return true
    val type = fourCC(head, offset + 4) ?: return true
    if (type == "acTL") return true
    // `IDAT` before `acTL` rules an animation out by definition, so the walk can stop with a real answer.
    if (type == "IDAT" || type == "IEND") return false
    if (length < 0) return true
    offset += 12 + length
  }
  return true
}

/** WebP chunk walk: the `VP8X` extended header carries the animation bit; `ANIM`/`ANMF` are the frames. */
private fun webpIsAnimated(head: ByteArray): Boolean {
  var offset = 12
  while (offset + 8 <= head.size) {
    val type = fourCC(head, offset) ?: return true
    val size = littleInt(head, offset + 4) ?: return true
    when (type) {
      "ANIM", "ANMF" -> return true
      "VP8X" -> {
        val flags = head.getOrNull(offset + 8)?.toInt()?.and(0xFF) ?: return true
        return flags and 0x02 != 0
      }
    }
    if (size < 0) return true
    offset += 8 + size + (size and 1)
  }
  return true
}

/**
 * Counts image descriptor blocks, stopping at [atLeast]. Returns null when the prefix ran out mid-walk and
 * `1` only when the trailer confirms the file holds exactly one frame.
 */
internal fun gifFrameCount(data: ByteArray, atLeast: Int): Int? {
  var offset = 13
  val flags = data.getOrNull(10)?.toInt()?.and(0xFF) ?: return null
  if (flags and 0x80 != 0) {
    val entries = 1 shl ((flags and 0x07) + 1)
    offset += entries * 3
  }
  var frames = 0
  while (offset < data.size) {
    when (val block = data[offset].toInt() and 0xFF) {
      0x3B -> return frames
      0x2C -> {
        frames += 1
        if (frames >= atLeast) return frames
        offset += 10
        val local = data.getOrNull(offset - 1)?.toInt()?.and(0xFF) ?: return null
        if (local and 0x80 != 0) {
          val entries = 1 shl ((local and 0x07) + 1)
          offset += entries * 3
        }
        offset += 1
        offset = skipSubBlocks(data, offset) ?: return null
      }
      0x21 -> {
        offset += 2
        offset = skipSubBlocks(data, offset) ?: return null
      }
      else -> return null
    }
  }
  return null
}

private fun skipSubBlocks(data: ByteArray, from: Int): Int? {
  var offset = from
  while (offset < data.size) {
    val length = data[offset].toInt() and 0xFF
    if (length == 0) return offset + 1
    offset += 1 + length
  }
  return null
}

// MARK: - Other kinds

internal fun popopxLooksLikePdf(head: ByteArray): Boolean = matchesAt(head, 0, PDF_START)

/**
 * The magic-side half of the video test. The platform probe (`MediaExtractor`) is the other half and is
 * consulted only when this says nothing, which is what keeps a clip renamed `.dat` a clip while never forcing
 * the desktop build to own a media framework.
 */
internal fun popopxLooksLikeVideoMagic(head: ByteArray): Boolean {
  if (matchesAt(head, 4, ascii("ftyp"))) {
    val brand = fourCC(head, 8)?.lowercase() ?: return false
    return !IMAGE_BRANDS.contains(brand)
  }
  if (matchesAt(head, 0, ascii("RIFF")) && fourCC(head, 8) == "AVI ") return true
  if (head.size > 4 && head[0] == 0x1A.toByte() && head[1] == 0x45.toByte() && head[2] == 0xDF.toByte() && head[3] == 0xA3.toByte()) return true
  return false
}
