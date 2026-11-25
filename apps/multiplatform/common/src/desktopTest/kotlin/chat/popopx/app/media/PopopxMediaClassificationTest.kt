package chat.popopx.app.media

import chat.popopx.common.media.PopopxAttachmentKind
import chat.popopx.common.media.PopopxDocumentContainer
import chat.popopx.common.media.PopopxImageQualityPreset
import chat.popopx.common.media.PopopxIncomingFileUnpacker
import chat.popopx.common.media.PopopxMediaEngine
import chat.popopx.common.media.PopopxMediaEngineCore
import chat.popopx.common.media.PopopxMediaSettings
import chat.popopx.common.media.PopopxMediaSettingsKeys
import chat.popopx.common.media.PopopxOutgoingMediaInterceptor
import chat.popopx.common.media.PopopxVideoSourceInfo
import chat.popopx.common.media.popopxLooksLikeAnimatedImage
import chat.popopx.common.media.popopxLooksLikeImage
import chat.popopx.common.media.popopxLooksLikeText
import chat.popopx.common.media.popopxLooksLikeVideoMagic
import chat.popopx.common.media.popopxVideoProfile
import com.popopxchat.popopx.withTempDir
import com.russhwolf.settings.PropertiesSettings
import java.io.File
import java.util.Properties
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

// Block A of the Android media port: the classification walk, the profile arithmetic, the fuse, the
// large-group gate, and the scratch-cache purge.
//
// Everything here runs on the JVM against the desktop actuals, which is the point: the classifier and the
// arithmetic are the shared half of the engine, so the desktop test proves them without a device. The encode
// actuals deliberately always fail on desktop, which is what makes the fuse — never emit a broken file, never
// leave a scratch corpse behind — testable from here rather than only on a phone.

internal fun raw(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }

internal fun ascii(value: String): ByteArray = value.encodeToByteArray()

private fun u32le(value: Int): ByteArray =
  raw(value and 0xFF, value shr 8 and 0xFF, value shr 16 and 0xFF, value shr 24 and 0xFF)

internal fun concat(vararg parts: ByteArray): ByteArray {
  val out = ByteArray(parts.sumOf { it.size })
  var offset = 0
  for (part in parts) {
    part.copyInto(out, offset)
    offset += part.size
  }
  return out
}

private val JPEG_HEAD = concat(raw(0xFF, 0xD8, 0xFF, 0xE0), ascii("JFIF"), ByteArray(20))
private val PNG_SIG = raw(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

private fun mp4(brand: String): ByteArray = concat(ByteArray(4), ascii("ftyp"), ascii(brand), ByteArray(8))

/** A GIF with [frames] image descriptors, each a minimal 12-byte block, closed by the trailer. */
private fun gif(frames: Int): ByteArray {
  val header = concat(ascii("GIF89a"), ByteArray(7)) // signature + 7-byte screen descriptor, no global table
  val block = concat(raw(0x2C), ByteArray(8), raw(0x00, 0x08, 0x00)) // descriptor, min code size, empty sub-block
  var out = header
  repeat(frames) { out = concat(out, block) }
  return concat(out, raw(0x3B))
}

/** One PNG chunk, CRC included, so a walk can be sent past it instead of off the end of the fixture. */
private fun pngChunk(type: String, payload: ByteArray): ByteArray =
  concat(u32le(payload.size), ascii(type), payload, ByteArray(4))

private fun png(chunkType: String, payload: ByteArray = ByteArray(0)): ByteArray =
  concat(PNG_SIG, u32le(payload.size), ascii(chunkType), payload)

private fun pngOf(vararg chunks: ByteArray): ByteArray = concat(PNG_SIG, *chunks)

private fun webp(flags: Int): ByteArray =
  concat(ascii("RIFF"), ByteArray(4), ascii("WEBP"), ascii("VP8X"), u32le(10), raw(flags), ByteArray(9))

/** Never the app's own `settings`: its desktop actual writes real preference files on every put. */
private fun memorySettings(properties: Properties = Properties()) = PropertiesSettings(properties) { }

class PopopxMediaClassificationTest {
  @Test
  fun containerNamesPassThroughBeforeAnyMagicIsRead() {
    assertEquals(
      PopopxAttachmentKind.PASSTHROUGH,
      PopopxMediaEngineCore.classify(JPEG_HEAD, platformVideo = false, fileName = "photo.jpg.ppxlz"),
    )
    assertTrue(PopopxIncomingFileUnpacker.isContainerNamed("a.b.ppxlz"))
    assertFalse(PopopxIncomingFileUnpacker.isContainerNamed("a.ppxlz.bak"))
  }

  @Test
  fun contentBeatsTheExtensionForStillsAndClips() {
    assertEquals(PopopxAttachmentKind.IMAGE, PopopxMediaEngineCore.classify(JPEG_HEAD, false, "unnamed.dat"))
    assertEquals(PopopxAttachmentKind.VIDEO, PopopxMediaEngineCore.classify(mp4("mp42"), false, "clip.dat"))
    assertEquals(PopopxAttachmentKind.IMAGE, PopopxMediaEngineCore.classify(mp4("heic"), false, "IMG_1.raw"))
    assertTrue(popopxLooksLikeImage(JPEG_HEAD))
    assertFalse(popopxLooksLikeImage(mp4("mp42")))
    assertTrue(popopxLooksLikeVideoMagic(mp4("mp42")))
    assertTrue(popopxLooksLikeVideoMagic(concat(raw(0x1A, 0x45, 0xDF, 0xA3), ByteArray(8))))
    assertTrue(popopxLooksLikeVideoMagic(concat(ascii("RIFF"), ByteArray(4), ascii("AVI "), ByteArray(4))))
    assertFalse(popopxLooksLikeVideoMagic(mp4("heic")))
  }

  @Test
  fun animatedContainersAreNeverReEncoded() {
    assertEquals(PopopxAttachmentKind.ANIMATED_IMAGE, PopopxMediaEngineCore.classify(gif(2), false, "a.gif"))
    assertEquals(PopopxAttachmentKind.IMAGE, PopopxMediaEngineCore.classify(gif(1), false, "a.gif"))
    // An unreadable frame walk answers "animated", which costs a compression and never an animation.
    assertEquals(PopopxAttachmentKind.ANIMATED_IMAGE, PopopxMediaEngineCore.classify(gif(2).copyOf(20), false, "a.gif"))
    val ihdr = pngChunk("IHDR", ByteArray(13))
    val idat = pngChunk("IDAT", ByteArray(4))
    val actl = pngChunk("acTL", ByteArray(8))
    assertFalse(popopxLooksLikeAnimatedImage(pngOf(ihdr, idat, pngChunk("IEND", ByteArray(0)))))
    // `acTL` after the image data is not an animation by definition, and the walk stops there with a real
    // answer rather than running to the end of the prefix.
    assertFalse(popopxLooksLikeAnimatedImage(pngOf(ihdr, idat, actl)))
    assertTrue(popopxLooksLikeAnimatedImage(pngOf(ihdr, actl, idat)))
    // A prefix that ends inside a chunk cannot decide the question, so it answers "animated".
    assertTrue(popopxLooksLikeAnimatedImage(png("IHDR", ByteArray(13))))
    assertTrue(popopxLooksLikeAnimatedImage(webp(0x02)))
    assertFalse(popopxLooksLikeAnimatedImage(webp(0x00)))
    assertFalse(popopxLooksLikeAnimatedImage(JPEG_HEAD))
  }

  @Test
  fun pdfDocumentsAndEverythingElse() {
    assertEquals(PopopxAttachmentKind.PDF, PopopxMediaEngineCore.classify(ascii("%PDF-1.7"), false, "a.bin"))
    assertEquals(PopopxAttachmentKind.DOCUMENT, PopopxMediaEngineCore.classify(ascii("hello"), false, "notes.md"))
    // A zip renamed `.txt` stays out of the container: the text test is what protects it.
    assertEquals(
      PopopxAttachmentKind.PASSTHROUGH,
      PopopxMediaEngineCore.classify(raw(0x50, 0x4B, 0x03, 0x04), false, "doc.txt"),
    )
    assertEquals(PopopxAttachmentKind.PASSTHROUGH, PopopxMediaEngineCore.classify(ascii("hello"), false, "blob.bin"))
    assertEquals(PopopxAttachmentKind.VIDEO, PopopxMediaEngineCore.classify(ByteArray(0), true, "x.dat"))
    assertEquals(PopopxAttachmentKind.PASSTHROUGH, PopopxMediaEngineCore.classify(ByteArray(0), false, "empty.txt"))
  }

  @Test
  fun looksLikeTextIsByteForByteTheIosRule() {
    assertFalse(popopxLooksLikeText(ByteArray(0)))
    assertTrue(popopxLooksLikeText(concat(raw(0xEF, 0xBB, 0xBF), raw(0x00, 0x07)))) // the BOM short-circuits
    assertTrue(popopxLooksLikeText(raw(0x09, 0x0A, 0x0D, 0x1B, 0x7F, 0x20)))
    assertFalse(popopxLooksLikeText(raw(0x41, 0x00)))
    assertFalse(popopxLooksLikeText(raw(0x41, 0x07)))
    assertFalse(popopxLooksLikeText(raw(0x41, 0x0E)))
    assertFalse(popopxLooksLikeText(raw(0x41, 0x1F)))
  }

  @Test
  fun identifyReadsTheFileAndNotTheExtension() {
    withTempDir { dir ->
      val jpeg = dir.resolve("shot.dat").toFile().apply { writeBytes(concat(JPEG_HEAD, ByteArray(64))) }
      val clip = dir.resolve("clip.dat").toFile().apply { writeBytes(concat(mp4("mp42"), ByteArray(64))) }
      val doc = dir.resolve("notes.txt").toFile().apply { writeBytes(ascii("a document body")) }
      assertEquals(PopopxAttachmentKind.IMAGE, PopopxMediaEngineCore.identify(jpeg))
      assertEquals(PopopxAttachmentKind.VIDEO, PopopxMediaEngineCore.identify(clip))
      assertEquals(PopopxAttachmentKind.DOCUMENT, PopopxMediaEngineCore.identify(doc))
      assertEquals(PopopxAttachmentKind.PASSTHROUGH, PopopxMediaEngineCore.identify(dir.resolve("absent.txt").toFile()))
    }
  }

  @Test
  fun theFuseKeepsTheOriginalWheneverTheEncodeCannotProveASmallerFile() {
    withTempDir { dir ->
      val jpeg = dir.resolve("fuse.jpg").toFile()
        .apply { writeBytes(concat(JPEG_HEAD, ByteArray(4096))) }
      // The desktop image actual always refuses, which is exactly the failure the fuse exists for.
      val result = PopopxMediaEngineCore.perform(jpeg, jpeg.length(), PopopxImageQualityPreset.DATA_SAVER)
      assertSame(jpeg, result.file)
      assertFalse(result.compressed)
      assertEquals(0L, result.savedBytes)
      assertEquals(jpeg.length(), result.finalBytes)
      assertEquals(PopopxAttachmentKind.IMAGE, result.kind)
      // A failed encode deletes its scratch file instead of leaving a header-sized corpse in the cache.
      val leftovers = PopopxMediaEngineCore.workingDirectory().listFiles()?.filter { it.name.startsWith("fuse-") }
      assertTrue(leftovers == null || leftovers.isEmpty(), "scratch left behind: $leftovers")
    }
  }

  @Test
  fun videoProfileGeometryBitrateAndRotation() {
    val landscape = popopxVideoProfile(PopopxVideoSourceInfo(1920, 1080, 0, 30f))!!
    assertEquals(1280, landscape.width)
    assertEquals(720, landscape.height)
    assertEquals(1_658_880, landscape.bitrateBps)
    assertEquals(60, landscape.keyframeInterval)
    assertEquals(0, landscape.rotationDegrees)

    val portrait = popopxVideoProfile(PopopxVideoSourceInfo(1080, 1920, 90, 30f))!!
    assertEquals(720, portrait.width)
    assertEquals(1280, portrait.height)
    assertEquals(90, portrait.rotationDegrees)

    val odd = popopxVideoProfile(PopopxVideoSourceInfo(1001, 601, 0, 24f))!!
    assertEquals(1000, odd.width)
    assertEquals(600, odd.height)

    assertEquals(400_000, popopxVideoProfile(PopopxVideoSourceInfo(64, 48, 0, 1f))!!.bitrateBps)
    val fast = popopxVideoProfile(PopopxVideoSourceInfo(1280, 720, 0, 240f))!!
    assertTrue(fast.bitrateBps <= 4_000_000, "bitrate ladder escaped its ceiling: $fast.bitrateBps")
    assertEquals(120, popopxVideoProfile(PopopxVideoSourceInfo(1280, 720, 0, 120f))!!.keyframeInterval)
    // A nonsense rate degrades to 1 fps rather than to a division by zero.
    val nan = popopxVideoProfile(PopopxVideoSourceInfo(640, 480, 0, Float.NaN))!!
    assertEquals(2, nan.keyframeInterval)
    assertEquals(400_000, nan.bitrateBps)
    assertEquals(270, popopxVideoProfile(PopopxVideoSourceInfo(640, 480, -90, 30f))!!.rotationDegrees)
    assertEquals(90, popopxVideoProfile(PopopxVideoSourceInfo(640, 480, 450, 30f))!!.rotationDegrees)
    assertNull(popopxVideoProfile(PopopxVideoSourceInfo(0, 480, 0, 30f)))
    assertNull(popopxVideoProfile(PopopxVideoSourceInfo(-4, 480, 0, 30f)))
  }

  @Test
  fun theLargeGroupGateNeedsBothSwitchesAndTheMemberThreshold() {
    val settings = PopopxMediaSettings(memorySettings())
    assertTrue(settings.appliesToGroup(50))
    assertFalse(settings.appliesToGroup(49))
    settings.isStrictGroupCompressionEnabled = false
    assertFalse(settings.appliesToGroup(500))
    settings.isStrictGroupCompressionEnabled = true
    settings.isEngineEnabled = false
    assertFalse(settings.appliesToGroup(500))
    assertEquals(5_000_000L, settings.sizeCeiling)
    settings.imageQualityPreset = PopopxImageQualityPreset.DATA_SAVER
    assertEquals("dataSaver", settings.imageQualityPreset.rawValue)
    assertEquals(1080, settings.imageQualityPreset.maxDimensionInPixels)
    settings.imageQualityPreset = PopopxImageQualityPreset.STANDARD_HD
    assertEquals(1600, settings.imageQualityPreset.maxDimensionInPixels)
    // An unknown stored value falls back instead of throwing, as iOS's `?? .standardHD` does.
    val garbage = PopopxMediaSettings(
      memorySettings(Properties().apply { setProperty(PopopxMediaSettingsKeys.IMAGE_QUALITY_PRESET, "ultra") }),
    )
    assertEquals(PopopxImageQualityPreset.STANDARD_HD, garbage.imageQualityPreset)
  }

  @Test
  // `withTempDir` is not inline, so the coroutine has to open *inside* it rather than around it.
  fun theCeilingBlocksOnlyInsideALargeGroup() = withTempDir { dir ->
    val settings = PopopxMediaSettings(memorySettings())
    val engine = PopopxMediaEngine(settings)
    val interceptor = PopopxOutgoingMediaInterceptor(settings, engine)
    runBlocking {
      val big = dir.resolve("big.txt").toFile()
        .apply { writeBytes(ByteArray(6 * 1024 * 1024) { ('a'.code + it % 26).toByte() }) }
      val smallGroup = interceptor.prepareOne(big, groupMemberCount = 49)
      assertFalse(smallGroup.blocked)
      val largeGroup = interceptor.prepareOne(big, groupMemberCount = 50)
      assertTrue(largeGroup.blocked)
      assertEquals(PopopxAttachmentKind.DOCUMENT, largeGroup.kind)
      assertFalse(largeGroup.compressed)
      assertEquals(2, interceptor.processedCount)
      assertEquals(0, interceptor.activeTaskCount)
      assertFalse(interceptor.isProcessing)
      val batch = interceptor.prepare(listOf(big), groupMemberCount = 50)
      assertEquals(1, batch.blocked.size)
      assertTrue(batch.allowed.isEmpty())
      assertEquals(0L, batch.savedBytes)

      val off = PopopxMediaSettings(memorySettings())
      off.isEngineEnabled = false
      val quiet = PopopxOutgoingMediaInterceptor(off, PopopxMediaEngine(off)).prepareOne(big, groupMemberCount = 500)
      assertFalse(quiet.blocked)
      assertEquals(PopopxAttachmentKind.PASSTHROUGH, quiet.kind)

      // Two single preparations and one batch of one, on the engine the interceptor was built with.
      assertEquals(3, engine.handledAttachmentCount)
      assertEquals(0L, engine.savedBytesTotal)
      engine.reset()
      assertEquals(0, engine.handledAttachmentCount)
      assertEquals(0L, engine.savedBytesTotal)
      assertEquals(0, engine.unpackedFileCount)
      assertFalse(engine.isProcessing)
      interceptor.reset()
      assertEquals(0, interceptor.processedCount)
      assertEquals(0L, interceptor.lastSavedBytes)
    }
  }

  @Test
  fun thePurgeClearsOurScratchAndLeavesThePlatformDotFiles() {
    val working = PopopxMediaEngineCore.workingDirectory()
    val unpacked = PopopxMediaEngineCore.unpackedDirectory()
    val mine = File(working, "purge-me.jpg").apply { writeBytes(ascii("x")) }
    val nested = File(working, "purge-sub").apply { mkdirs() }
    File(nested, "deep.bin").writeBytes(ascii("y"))
    val hidden = File(working, ".purge-keep").apply { writeBytes(ascii("keep")) }
    val received = File(unpacked, "purged-note.txt").apply { writeBytes(ascii("z")) }
    assertEquals(2, PopopxMediaEngineCore.cacheDirectories().size)
    PopopxIncomingFileUnpacker.purgeTemporaryDirectories()
    assertFalse(mine.exists())
    assertFalse(nested.exists())
    assertFalse(received.exists())
    assertTrue(hidden.exists())
    hidden.delete()
    assertNull(PopopxIncomingFileUnpacker.cachedFile(File(unpacked, "purged-note.txt.ppxlz")))
  }

  @Test
  fun displayNamesDropOnlyTheContainerExtension() {
    assertEquals("notes.md", PopopxIncomingFileUnpacker.displayNameFor("notes.md.ppxlz"))
    assertEquals("notes", PopopxIncomingFileUnpacker.displayNameFor("notes.ppxlz"))
    assertEquals("a.txt", PopopxIncomingFileUnpacker.displayNameFor("a.txt.PPXLZ"))
    assertEquals(".ppxlz", PopopxIncomingFileUnpacker.displayNameFor(".ppxlz"))
    assertEquals("plain.txt", PopopxIncomingFileUnpacker.displayNameFor("plain.txt"))
    assertEquals("a.txt", PopopxDocumentContainer.displayName(File("x/y/a.txt.ppxlz")))
    assertEquals("abcde", PopopxDocumentContainer.sanitize("a/b\nc\u0000d\u2028e"))
    assertEquals("attachment", PopopxDocumentContainer.sanitize("/\n\r\u0000"))
    assertEquals("plain", PopopxDocumentContainer.sanitize("plain"))
  }
}
