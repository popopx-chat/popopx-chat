package chat.popopx.app.media

import chat.popopx.common.media.PopopxDocumentContainer
import chat.popopx.common.media.PopopxIncomingFileUnpacker
import chat.popopx.common.media.PopopxJpegMetadata
import chat.popopx.common.media.PopopxMediaEngine
import chat.popopx.common.media.PopopxMediaEngineCore
import chat.popopx.common.media.PopopxMediaEngineError
import chat.popopx.common.media.PopopxMediaEngineException
import chat.popopx.common.media.PopopxMediaSettings
import chat.popopx.common.media.PopopxUnpackResult
import com.popopxchat.popopx.withTempDir
import com.russhwolf.settings.PropertiesSettings
import java.io.File
import java.util.Properties
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

// The `.ppxlz` container and the JPEG identity scrub — deliverable 1's two "prove it off-device" halves.
//
// Ruling 1 closed the emit path for this phase (iOS writes LZFSE behind the same magic), so these tests carry two
// separate burdens: the container must still round-trip its own framing, and a foreign frame must be *reported*
// rather than half-read. The 0.85 gate is checked at the boundary and with real compressible and incompressible
// payloads, because a ratio gate that only ever passes is indistinguishable from no gate at all.

private fun seg(marker: Int, payload: ByteArray): ByteArray =
  concat(raw(0xFF, marker and 0xFF), raw((payload.size + 2) shr 8 and 0xFF, (payload.size + 2) and 0xFF), payload)

private fun jpeg(segments: List<ByteArray>, entropy: Int = 32): ByteArray {
  val head = concat(raw(0xFF, 0xD8), *segments.toTypedArray())
  val scan = raw(0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00)
  return concat(head, scan, ByteArray(entropy) { (it % 251 + 4).toByte() }, raw(0xFF, 0xD9))
}

private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
  outer@ for (start in 0..haystack.size - needle.size) {
    for (offset in needle.indices) if (haystack[start + offset] != needle[offset]) continue@outer
    return start
  }
  return -1
}

class PopopxMediaContainerTest {
  @Test
  fun theRatioGateDiscardsAnArchiveThatOnlyTiesTheBoundary() {
    assertFalse(PopopxDocumentContainer.keepsPackedFile(850L, 1000L))
    assertTrue(PopopxDocumentContainer.keepsPackedFile(849L, 1000L))
    assertFalse(PopopxDocumentContainer.keepsPackedFile(1000L, 1000L))
    assertFalse(PopopxDocumentContainer.keepsPackedFile(0L, 0L))
    assertEquals(0.85, PopopxDocumentContainer.MINIMUM_REDUCTION_RATIO)
    assertEquals("PPXLZ1", PopopxDocumentContainer.MAGIC.decodeToString())
    assertEquals(1 shl 20, PopopxDocumentContainer.INPUT_CHUNK_BYTES)
    assertEquals(4 shl 20, PopopxDocumentContainer.OUTPUT_BUFFER_BYTES)
  }

  @Test
  fun theContainerRoundTripsItsOwnFraming() {
    withTempDir { path ->
      val dir = path.toFile()
      val payload = ascii("the quick brown fox jumps over the lazy dog\n".repeat(400))
      val source = File(dir, "notes.md").apply { writeBytes(payload) }
      val container = File(dir, "notes.md.ppxlz")
      val stream = PopopxDocumentContainer.pack(source, container)
      assertEquals(container.length() - PopopxDocumentContainer.MAGIC.size, stream)
      assertTrue(PopopxDocumentContainer.keepsPackedFile(stream, payload.size.toLong()))
      assertEquals("PPXLZ1", container.readBytes().copyOf(6).decodeToString())

      val out = File(dir, "restored.md")
      val written = PopopxDocumentContainer.unpack(container, out)
      assertEquals(payload.size.toLong(), written)
      assertContentEquals(payload, out.readBytes())
    }
  }

  @Test
  fun theZlibHeaderTestSeparatesOurFrameFromAnLZFSEOne() {
    assertTrue(PopopxDocumentContainer.isZlibFrame(raw(0x78, 0x9C)))
    assertTrue(PopopxDocumentContainer.isZlibFrame(raw(0x78, 0x01)))
    assertFalse(PopopxDocumentContainer.isZlibFrame(raw(0x62, 0x76, 0x6E, 0x36))) // the LZFSE "bv" marker
    assertFalse(PopopxDocumentContainer.isZlibFrame(raw(0x78, 0x00))) // header not a multiple of 31
    assertFalse(PopopxDocumentContainer.isZlibFrame(raw(0x78, 0x20))) // preset dictionary flag
    assertFalse(PopopxDocumentContainer.isZlibFrame(raw(0x88, 0x19))) // CINFO 8 is out of range
    assertFalse(PopopxDocumentContainer.isZlibFrame(raw(0x00, 0x00))) // method 0
    assertFalse(PopopxDocumentContainer.isZlibFrame(raw(0x78))) // too short to decide
  }

  @Test
  fun documentResultKeepsOnlyWhatActuallyShrinks() {
    withTempDir { path ->
      val dir = path.toFile()
      val compressible = File(dir, "compressible.txt")
        .apply { writeBytes(ByteArray(200_000) { ('a'.code + it % 26).toByte() }) }
      val packedFile = PopopxMediaEngineCore.documentResult(compressible)
      assertNotEquals(compressible, packedFile)
      assertTrue(packedFile.name.endsWith(".ppxlz"))
      assertTrue(packedFile.length() < compressible.length())
      packedFile.delete()

      val noise = File(dir, "noise.txt").apply { writeBytes(Random(7).nextBytes(ByteArray(200_000))) }
      val refused = PopopxMediaEngineCore.documentResult(noise)
      assertEquals(noise, refused)
      val corpses = PopopxMediaEngineCore.workingDirectory().listFiles()?.filter { it.name.startsWith("noise-") }
      assertTrue(corpses == null || corpses.isEmpty(), "the ratio gate left $corpses behind")

      val archive = File(dir, "archive.zip").apply { writeBytes(compressible.readBytes()) }
      val thrown = runCatching { PopopxMediaEngineCore.documentResult(archive) }.exceptionOrNull()
      assertTrue(thrown is PopopxMediaEngineException)
      assertEquals(PopopxMediaEngineError.STREAM_FAILED, (thrown as PopopxMediaEngineException).error)
      assertFalse(PopopxDocumentContainer.isEligible(archive))
      assertFalse(PopopxDocumentContainer.isEligible(File(dir, "x.txt.ppxlz")))
      assertTrue(PopopxDocumentContainer.isEligible(File(dir, "y.sql")))
    }
  }

  @Test
  // `withTempDir` is not inline, so the coroutine has to open *inside* it rather than around it.
  fun everyForeignFrameIsReportedAndNothingIsHalfWritten() = withTempDir { path ->
    val engine = PopopxMediaEngine(PopopxMediaSettings(PropertiesSettings(Properties()) { }))
    runBlocking {
      val dir = path.toFile()
      val body = ascii("a document that survives the round trip")
      val source = File(dir, "good.md").apply { writeBytes(body) }
      val good = File(dir, "good.md.ppxlz")
      PopopxDocumentContainer.pack(source, good)
      val whole = good.readBytes()

      val foreign = File(dir, "foreign.md.ppxlz")
        .apply { writeBytes(concat(PopopxDocumentContainer.MAGIC, raw(0x62, 0x76, 0x6E, 0x36, 0x00, 0x01))) }
      val truncated = File(dir, "truncated.md.ppxlz").apply { writeBytes(whole.copyOf(whole.size - 6)) }
      val corrupt = File(dir, "corrupt.md.ppxlz").apply {
        val bytes = whole.copyOf()
        bytes[bytes.size - 6] = (bytes[bytes.size - 6].toInt() xor 0x5A).toByte()
        writeBytes(bytes)
      }
      val notOurs = File(dir, "plain.md.ppxlz").apply { writeBytes(raw(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00)) }
      val missing = File(dir, "absent.md.ppxlz")

      assertEquals(
        PopopxMediaEngineError.CONTAINER_UNSUPPORTED_CODEC,
        (engine.unpack(foreign) as PopopxUnpackResult.Failure).error,
      )
      assertEquals(
        PopopxMediaEngineError.CONTAINER_TRUNCATED,
        (engine.unpack(truncated) as PopopxUnpackResult.Failure).error,
      )
      assertEquals(
        PopopxMediaEngineError.CONTAINER_MAGIC_MISMATCH,
        (engine.unpack(notOurs) as PopopxUnpackResult.Failure).error,
      )
      assertEquals(PopopxMediaEngineError.UNREADABLE, (engine.unpack(missing) as PopopxUnpackResult.Failure).error)
      // A stream that decodes but fails its checksum must not be handed back as a restored document.
      assertTrue(engine.unpack(corrupt) is PopopxUnpackResult.Failure)
      assertEquals(0, engine.unpackedFileCount)

      val names = PopopxMediaEngineCore.unpackedDirectory().listFiles()?.map { it.name }.orEmpty()
      assertFalse(names.any { it.startsWith("corrupt") || it.startsWith("foreign") || it.startsWith("truncated") })

      val success = engine.unpack(good) as PopopxUnpackResult.Success
      assertEquals("good.md", success.file.name)
      assertEquals(body.decodeToString(), success.file.readBytes().decodeToString())
      assertEquals(1, engine.unpackedFileCount)
      // The second open is served from the plaintext cache rather than unpacked again.
      assertEquals(success.file, PopopxIncomingFileUnpacker.cachedFile(good))
      PopopxIncomingFileUnpacker.purgeTemporaryDirectories()
    }
  }

  @Test
  fun identitySegmentsAreDroppedAndTheCodingStreamIsUntouched() {
    val exif = seg(0xE1, concat(ascii("Exif"), ByteArray(2), ByteArray(48)))
    val xmp = seg(0xE1, concat(ascii("http://ns.adobe.com/xap/1.0/"), raw(0x00), ascii("<x:xmpmeta>iPhone</x:xmpmeta>")))
    val mpf = seg(0xE1, concat(ascii("MPF"), raw(0x00), ByteArray(16)))
    val jfif = seg(0xE0, concat(ascii("JFIF"), raw(0x00, 0x01, 0x02, 0x00), ByteArray(12)))
    val icc = seg(0xE2, concat(ascii("ICC_PROFILE"), raw(0x00, 0x01, 0x01), ByteArray(40)))
    val colour = seg(0xE2, concat(ascii("dcctags"), ByteArray(20)))
    val jfxx = seg(0xE0, concat(ascii("JFXX"), raw(0x0D), ByteArray(20)))
    val comment = seg(0xFE, ascii("written by a camera"))
    val photoshop = seg(0xED, concat(ascii("Photoshop 3.0"), raw(0x00), ascii("8BIM"), ByteArray(24)))
    val ducky = seg(0xEC, ByteArray(16))
    val original = jpeg(listOf(jfif, exif, xmp, mpf, icc, colour, jfxx, comment, photoshop, ducky))

    assertTrue(PopopxJpegMetadata.isJpeg(original))
    assertTrue(PopopxJpegMetadata.hasIdentityMetadata(original))
    val stripped = PopopxJpegMetadata.strip(original)
    assertTrue(stripped != null && stripped.size < original.size)
    assertFalse(PopopxJpegMetadata.hasIdentityMetadata(stripped!!))
    assertNull(PopopxJpegMetadata.strip(stripped))
    assertTrue(indexOf(stripped, ascii("JFIF")) > 0)
    assertTrue(indexOf(stripped, ascii("ICC_PROFILE")) > 0)
    assertEquals(-1, indexOf(stripped, ascii("dcctags")))
    assertEquals(-1, indexOf(stripped, ascii("Exif")))
    assertEquals(-1, indexOf(stripped, ascii("xap")))
    assertEquals(-1, indexOf(stripped, ascii("JFXX")))
    assertEquals(-1, indexOf(stripped, ascii("8BIM")))
    assertEquals(-1, indexOf(stripped, ascii("written by")))
    // Everything from the scan header onward is copied verbatim, including the trailing bytes.
    val tail = 46
    assertContentEquals(original.copyOfRange(original.size - tail, original.size), stripped.copyOfRange(stripped.size - tail, stripped.size))
    assertContentEquals(raw(0xFF, 0xD8), stripped.copyOf(2))
  }

  @Test
  fun aCleanImageIsNotRewrittenAndAnUnparsableOneIsLeftAlone() {
    val clean = jpeg(listOf(seg(0xE0, concat(ascii("JFIF"), raw(0x00, 0x01, 0x01, 0x00), ByteArray(8)))))
    assertFalse(PopopxJpegMetadata.hasIdentityMetadata(clean))
    assertNull(PopopxJpegMetadata.strip(clean))
    // Not a JPEG, a truncated marker, and a segment length that overruns the buffer all mean "do nothing".
    assertNull(PopopxJpegMetadata.strip(ascii("PNM\u0000")))
    assertNull(PopopxJpegMetadata.strip(raw(0xFF, 0xD8)))
    assertNull(PopopxJpegMetadata.strip(raw(0xFF, 0xD8, 0xFF, 0xE1, 0x40, 0x00)))
    assertNull(PopopxJpegMetadata.strip(raw(0xFF, 0xD8, 0x00, 0x05, 0x00)))
  }

  @Test
  fun stripFromFileReportsTheBytesItRemoved() {
    withTempDir { path ->
      val dirty = path.resolve("photo.jpg").toFile()
        .apply { writeBytes(jpeg(listOf(seg(0xE1, concat(ascii("Exif"), ByteArray(2), ByteArray(400)))))) }
      val before = dirty.length()
      val clean = jpeg(listOf(seg(0xE0, concat(ascii("JFIF"), raw(0x00, 0x01, 0x01, 0x00), ByteArray(8)))))
      val untouched = path.resolve("clean.jpg").toFile().apply { writeBytes(clean) }
      // The dropped segment is the 2 marker bytes plus its 408-byte length-prefixed payload.
      assertEquals(410, PopopxJpegMetadata.stripFromFile(dirty))
      assertEquals(before - 410L, dirty.length())
      assertFalse(PopopxJpegMetadata.hasIdentityMetadata(dirty.readBytes()))
      assertEquals(0, PopopxJpegMetadata.stripFromFile(untouched))
      assertContentEquals(clean, untouched.readBytes())
      assertEquals(0, PopopxJpegMetadata.stripFromFile(path.resolve("absent.jpg").toFile()))
    }
  }
}
