package chat.popopx.common.media

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.PushbackInputStream
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

// Ported from `PopopxDocumentContainer` in apps/ios/Shared/Features/MediaCompression/PopopxMediaEngine.swift:729-895.
//
// The layout is unchanged — the six-byte `PPXLZ1` magic followed by a raw, chunk-streamed deflate — but the
// codec behind the magic is not: iOS produces an LZFSE stream (the user's ruling on that file's deviation 1)
// and no LZFSE implementation exists in either dependency cache, so this side emits and reads a zlib
// (RFC 1950) stream. That is why the bytes after the magic are *inspected* rather than trusted: a frame
// written by iOS arrives here, its two-byte header fails the zlib test, and the container reports
// CONTAINER_UNSUPPORTED_CODEC and leaves the file alone instead of producing garbage. Per ruling 1 this phase
// decompresses but never compresses outgoing documents, so the two framings never have to agree on the wire.

object PopopxDocumentContainer {
  const val PATH_EXTENSION = "ppxlz"

  /** Extensions worth streaming. Office formats are deliberately absent: they are already ZIP containers. */
  val ELIGIBLE_EXTENSIONS: Set<String> = setOf(
    "md", "txt", "csv", "tsv", "json", "jsonl", "log", "text",
    "yaml", "yml", "xml", "ini", "conf", "srt", "ics", "vcf", "sql",
  )

  /** Keep the packed file only when it is more than 15% smaller. */
  const val MINIMUM_REDUCTION_RATIO: Double = 0.85

  val MAGIC: ByteArray = "PPXLZ1".encodeToByteArray()
  const val INPUT_CHUNK_BYTES: Int = 1 shl 20
  const val OUTPUT_BUFFER_BYTES: Int = 4 shl 20

  fun isContainer(file: File): Boolean = extensionOf(file.name) == PATH_EXTENSION

  fun isContainerNamed(fileName: String): Boolean = fileName.lowercase().endsWith(".$PATH_EXTENSION")

  fun isEligible(file: File): Boolean {
    if (isContainer(file)) return false
    return ELIGIBLE_EXTENSIONS.contains(extensionOf(file.name))
  }

  /** `notes.md.ppxlz` -> `notes.md`, which is the name the bubble shows and the name the unpacker writes. */
  fun stem(file: File): String {
    var name = file.name
    if (name.lowercase().endsWith(".$PATH_EXTENSION")) name = name.dropLast(PATH_EXTENSION.count() + 1)
    return sanitize(name)
  }

  fun displayName(file: File): String = stem(file)

  fun sanitize(name: String): String {
    val cleaned = buildString(name.length) {
      for (ch in name) {
        if (ch != '/' && ch.code != 0 && !isLineBreak(ch)) append(ch)
      }
    }
    return cleaned.ifEmpty { "attachment" }
  }

  /**
   * The stream bytes written, excluding the magic — the same quantity iOS compares against
   * `originalBytes * minimumReductionRatio`, so the 15% gate decides identically on both platforms.
   */
  fun pack(source: File, destination: File): Long {
    if (!source.isFile) throw PopopxMediaEngineException(PopopxMediaEngineError.UNREADABLE)
    destination.parentFile?.mkdirs()
    val deflater = Deflater(Deflater.DEFAULT_COMPRESSION, false)
    try {
      FileInputStream(source).use { input ->
        BufferedOutputStream(FileOutputStream(destination)).use { raw ->
          raw.write(MAGIC)
          // Closing the deflate stream finishes it, which writes the big-endian Adler-32 trailer.
          DeflaterOutputStream(raw, deflater, OUTPUT_BUFFER_BYTES).use { deflate ->
            val buffer = ByteArray(INPUT_CHUNK_BYTES)
            while (true) {
              val read = input.read(buffer)
              if (read < 0) break
              if (read > 0) deflate.write(buffer, 0, read)
            }
          }
        }
      }
    } finally {
      deflater.end()
    }
    return destination.length() - MAGIC.size
  }

  /** Bytes written to [destination]. Throws on a foreign frame, a bad header or a truncated stream. */
  fun unpack(container: File, destination: File): Long {
    if (!container.isFile) throw PopopxMediaEngineException(PopopxMediaEngineError.UNREADABLE)
    destination.parentFile?.mkdirs()
    val inflater = Inflater(false)
    try {
      FileInputStream(container).use { raw ->
        val magic = ByteArray(MAGIC.size)
        if (!readFully(raw, magic) || !magic.contentEquals(MAGIC)) {
          throw PopopxMediaEngineException(PopopxMediaEngineError.CONTAINER_MAGIC_MISMATCH)
        }
        val pushback = PushbackInputStream(raw, 2)
        val frame = ByteArray(2)
        if (!readFully(pushback, frame)) throw PopopxMediaEngineException(PopopxMediaEngineError.CONTAINER_TRUNCATED)
        pushback.unread(frame)
        // The dispatch point: the magic says container, the two header bytes say which codec.
        if (!isZlibFrame(frame)) throw PopopxMediaEngineException(PopopxMediaEngineError.CONTAINER_UNSUPPORTED_CODEC)
        var written = 0L
        InflaterInputStream(pushback, inflater, OUTPUT_BUFFER_BYTES).use { input ->
          FileOutputStream(destination).use { output ->
            val buffer = ByteArray(OUTPUT_BUFFER_BYTES)
            while (true) {
              val read = input.read(buffer)
              if (read < 0) break
              if (read > 0) {
                output.write(buffer, 0, read)
                written += read
              }
            }
          }
        }
        // `read()` returning -1 is not proof the stream ended: a truncated deflate stops there too.
        if (!inflater.finished()) throw PopopxMediaEngineException(PopopxMediaEngineError.CONTAINER_TRUNCATED)
        return written
      }
    } catch (e: java.io.IOException) {
      // A cut stream reaches this line as a `ZipException` rather than as a clean end-of-file, and the wire
      // inflator's own rule applies: the stream that never saw its end marker was truncated, whatever the
      // decoder chose to complain about first. Only a stream that finished and still failed is corrupt.
      if (!inflater.finished()) throw PopopxMediaEngineException(PopopxMediaEngineError.CONTAINER_TRUNCATED, e)
      throw PopopxMediaEngineException(PopopxMediaEngineError.STREAM_FAILED, e)
    } finally {
      inflater.end()
    }
  }

  /**
   * The 15% gate, kept apart from the pack so its boundary is testable: an archive that lands exactly on
   * `original * 0.85` is discarded, which is iOS's `>=` comparison on the same two quantities.
   */
  fun keepsPackedFile(packedBytes: Long, originalBytes: Long): Boolean =
    packedBytes.toDouble() < originalBytes.toDouble() * MINIMUM_REDUCTION_RATIO

  /**
   * A zlib stream: method 8, window smaller than the 32 KiB CINFO ceiling, no preset dictionary, and the
   * header divisible by 31. Checked exactly as `PopopxServerConfigWire` checks the frame it is handed.
   */
  internal fun isZlibFrame(header: ByteArray): Boolean {
    if (header.size < 2) return false
    val cmf = header[0].toInt() and 0xFF
    val flg = header[1].toInt() and 0xFF
    val method = cmf and 0x0F
    val window = cmf shr 4
    return method == 8 && window < 8 && (flg and 0x20) == 0 && ((cmf shl 8) or flg) % 31 == 0
  }

  /** `CharacterSet.newlines`, whose members below 0x1000 are exactly these. */
  private fun isLineBreak(ch: Char): Boolean =
    ch == '\n' || ch == '\r' || ch.code == 0x85 || ch.code == 0x2028 || ch.code == 0x2029

  private fun extensionOf(fileName: String): String = fileName.substringAfterLast('.', "").lowercase()

  private fun readFully(stream: InputStream, into: ByteArray): Boolean {
    var offset = 0
    while (offset < into.size) {
      val read = stream.read(into, offset, into.size - offset)
      if (read < 0) return false
      offset += read
    }
    return true
  }
}
