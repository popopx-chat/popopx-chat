package chat.popopx.common.media

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.crypto.randomBytes
import chat.popopx.common.platform.tmpDir
import java.io.File
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// Ported from apps/ios/Shared/Features/MediaCompression/PopopxMediaEngine.swift (911 lines).
//
// The shape is kept: a façade that owns only progress state over a stateless core that touches bytes. What
// differs is the platform layer underneath the core — ImageIO/AVFoundation/PDFKit become BitmapFactory,
// MediaCodec and a signature read — and one deliberate narrowing from ruling 1: the document container is
// unpacked but never emitted, because iOS writes LZFSE behind the same magic (see `documentResult`).
//
// Nothing here runs on desktop: the mount refuses non-Android callers, exactly as the eco mount does, so the
// desktop app's attachments and its snapshot baselines cannot move as a side effect of this port.

enum class PopopxAttachmentKind {
  IMAGE,
  ANIMATED_IMAGE,
  VIDEO,
  PDF,
  DOCUMENT,
  PASSTHROUGH;

  /** An animated image is passed through untouched: re-encoding it would destroy the animation. */
  val shouldCompress: Boolean get() = this != PASSTHROUGH && this != ANIMATED_IMAGE
}

enum class PopopxMediaEngineError {
  UNREADABLE,
  IMAGE_DECODE_FAILED,
  IMAGE_ENCODE_FAILED,
  VIDEO_EXPORT_FAILED,
  VIDEO_NO_VIDEO_TRACK,
  PDF_UNREADABLE,
  PDF_EXPORT_FAILED,
  CONTAINER_MAGIC_MISMATCH,
  CONTAINER_TRUNCATED,
  CONTAINER_UNSUPPORTED_CODEC,
  STREAM_FAILED,
  OUTPUT_DIRECTORY_UNAVAILABLE,
}

class PopopxMediaEngineException(
  val error: PopopxMediaEngineError,
  cause: Throwable? = null,
) : Exception(error.name, cause)

class PopopxCompressedAttachment(
  val file: File,
  val kind: PopopxAttachmentKind,
  val originalBytes: Long,
  val finalBytes: Long,
  val compressed: Boolean,
) {
  val savedBytes: Long get() = if (compressed) maxOf(0L, originalBytes - finalBytes) else 0L

  companion object {
    /** A file the fuse rejected, or one that is not compressible, keeps its original path. */
    fun unchanged(file: File, kind: PopopxAttachmentKind, bytes: Long): PopopxCompressedAttachment =
      PopopxCompressedAttachment(file, kind, bytes, bytes, false)
  }
}

sealed class PopopxUnpackResult {
  class Success(val file: File) : PopopxUnpackResult()
  class Failure(val error: PopopxMediaEngineError) : PopopxUnpackResult()

  val unpackedFile: File? get() = (this as? Success)?.file
}

/** The decoded geometry of a clip, as the platform reports it before any scaling decision. */
class PopopxVideoSourceInfo(val width: Int, val height: Int, val rotationDegrees: Int, val frameRate: Float)

/** The geometry an encoder is asked for. Produced only by [popopxVideoProfile], which is pure. */
class PopopxVideoProfile(
  val width: Int,
  val height: Int,
  val bitrateBps: Int,
  val keyframeInterval: Int,
  val rotationDegrees: Int,
)

// MARK: - Platform seam

/** Returns null on success, otherwise the reason the encode is abandoned. */
internal expect fun popopxEncodeImage(
  source: File,
  destination: File,
  maxDimensionInPixels: Int,
  qualityPercent: Int,
): PopopxMediaEngineError?

/** Returns null on success, otherwise the reason the transcode is abandoned. */
internal expect fun popopxTranscodeVideo(
  source: File,
  destination: File,
  profile: PopopxVideoProfile,
): PopopxMediaEngineError?

internal expect fun popopxHasVideoTrack(file: File): Boolean

internal expect fun popopxProbeVideoInfo(file: File): PopopxVideoSourceInfo?

// MARK: - Sizing, decided off-device

/** Long edge of a transcoded clip, as on iOS: readable in a group while the bitrate ladder does the saving. */
internal const val POPOPX_VIDEO_MAX_DIMENSION = 1280

/**
 * The pixel budget is measured after the rotation (a portrait recording is a landscape grid once turned) but
 * the encode keeps the *natural* edge lengths and carries the rotation as metadata, which is iOS's split
 * between `displayedSize` and `videoInput.transform`.
 */
internal fun popopxVideoProfile(info: PopopxVideoSourceInfo): PopopxVideoProfile? {
  if (info.width <= 0 || info.height <= 0) return null
  val swapped = info.rotationDegrees % 180 != 0
  val displayedWidth = if (swapped) info.height else info.width
  val displayedHeight = if (swapped) info.width else info.height
  val scale = minOf(1.0, POPOPX_VIDEO_MAX_DIMENSION.toDouble() / maxOf(1, maxOf(displayedWidth, displayedHeight)))
  val width = even((info.width * scale).toInt())
  val height = even((info.height * scale).toInt())
  if (width < 16 || height < 16) return null
  return PopopxVideoProfile(
    width = width,
    height = height,
    bitrateBps = videoBitrate(width, height, info.frameRate),
    keyframeInterval = keyframeInterval(info.frameRate),
    rotationDegrees = ((info.rotationDegrees % 360) + 360) % 360,
  )
}

/** Encoders reject odd edges, and a clip that small has no reason to be sent at all. */
private fun even(value: Int): Int {
  val clamped = maxOf(16, value)
  return clamped - clamped % 2
}

private fun keyframeInterval(frameRate: Float): Int =
  maxOf(1, (clampFrameRate(frameRate) * 2).roundToInt())

private fun videoBitrate(width: Int, height: Int, frameRate: Float): Int {
  // About 0.06 bit per pixel per frame, clamped so a 720p clip lands near 1.5 Mbps and a 1280 px clip near 3.
  val pixels = maxOf(1L, width.toLong() * height.toLong()).toDouble()
  return minOf(maxOf(pixels * clampFrameRate(frameRate) * 0.06, 400_000.0), 4_000_000.0).toInt()
}

private fun clampFrameRate(frameRate: Float): Double =
  if (frameRate.isNaN()) 1.0 else minOf(maxOf(frameRate.toDouble(), 1.0), 60.0)

// MARK: - Core

internal object PopopxMediaEngineCore {
  /** Scratch space for recompressed attachments, cleared by the same hooks as the unpacked cache. */
  const val WORKING_DIRECTORY_NAME = "popopx_media"

  /** Plaintext cache for documents unpacked on the receiving side. */
  const val UNPACKED_DIRECTORY_NAME = "popopx_unpacked"

  /**
   * Ruling 1 (2026-11-25): iOS writes an LZFSE stream behind the `PPXLZ1` magic and the two framings cannot be
   * told apart from the magic alone, so nothing is emitted until the container carries a codec tag. The pack
   * path stays written — and round-trip tested — for the day it does.
   */
  const val EMITS_DOCUMENT_CONTAINER = false

  fun fileSizeOf(file: File): Long = if (file.isFile) file.length() else 0L

  fun identify(file: File): PopopxAttachmentKind {
    val head = readPrefix(file, POPOPX_MEDIA_FORMAT_PROBE_BYTES)
    // The platform probe is the fallback for a container the magic walk cannot name, so it is only paid for
    // when the magic says nothing.
    val platformVideo = !popopxLooksLikeImage(head) && !popopxLooksLikeVideoMagic(head) && popopxHasVideoTrack(file)
    return classify(head, platformVideo, file.name)
  }

  /** The decision, separated from the reading so every branch is reachable from a unit test. */
  fun classify(head: ByteArray, platformVideo: Boolean, fileName: String): PopopxAttachmentKind {
    if (PopopxDocumentContainer.isContainerNamed(fileName)) return PopopxAttachmentKind.PASSTHROUGH
    if (popopxLooksLikeImage(head)) {
      return if (popopxLooksLikeAnimatedImage(head)) PopopxAttachmentKind.ANIMATED_IMAGE else PopopxAttachmentKind.IMAGE
    }
    if (platformVideo || popopxLooksLikeVideoMagic(head)) return PopopxAttachmentKind.VIDEO
    if (popopxLooksLikePdf(head)) return PopopxAttachmentKind.PDF
    val extension = fileName.substringAfterLast('.', "").lowercase()
    if (PopopxDocumentContainer.ELIGIBLE_EXTENSIONS.contains(extension) &&
      popopxLooksLikeText(head.copyOf(minOf(head.size, POPOPX_MEDIA_TEXT_PROBE_BYTES)))
    ) {
      return PopopxAttachmentKind.DOCUMENT
    }
    return PopopxAttachmentKind.PASSTHROUGH
  }

  /** Never throws: a failure inside the platform layer degrades to the original attachment. */
  fun perform(source: File, bytes: Long, preset: PopopxImageQualityPreset): PopopxCompressedAttachment {
    val kind = try {
      identify(source)
    } catch (e: Exception) {
      return PopopxCompressedAttachment.unchanged(source, PopopxAttachmentKind.PASSTHROUGH, bytes)
    }
    if (!kind.shouldCompress) return PopopxCompressedAttachment.unchanged(source, kind, bytes)
    val candidate = try {
      when (kind) {
        PopopxAttachmentKind.IMAGE -> imageResult(source, preset)
        PopopxAttachmentKind.VIDEO -> videoResult(source)
        PopopxAttachmentKind.DOCUMENT -> if (EMITS_DOCUMENT_CONTAINER) documentResult(source) else null
        else -> null
      }
    } catch (e: Exception) {
      null
    }
    val output = candidate?.takeIf { it != source }
      ?: return PopopxCompressedAttachment.unchanged(source, kind, bytes)
    val finalBytes = fileSizeOf(output)
    if (finalBytes <= 0L || finalBytes >= bytes) {
      output.delete()
      return PopopxCompressedAttachment.unchanged(source, kind, bytes)
    }
    return PopopxCompressedAttachment(output, kind, bytes, finalBytes, true)
  }

  fun workingDirectory(): File = protectedDirectory(WORKING_DIRECTORY_NAME)

  fun unpackedDirectory(): File = protectedDirectory(UNPACKED_DIRECTORY_NAME)

  fun cacheDirectories(): List<File> = listOf(workingDirectory(), unpackedDirectory())

  fun scratchURL(source: File, newExtension: String): File {
    val name = "${PopopxDocumentContainer.stem(source)}-${hexEncode(randomBytes(4))}.$newExtension"
    return File(workingDirectory(), name)
  }

  private fun protectedDirectory(name: String): File {
    val target = File(File(tmpDir, "popopx"), name)
    if (target.isFile && !target.delete()) throw PopopxMediaEngineException(PopopxMediaEngineError.OUTPUT_DIRECTORY_UNAVAILABLE)
    if (!target.isDirectory && !target.mkdirs()) throw PopopxMediaEngineException(PopopxMediaEngineError.OUTPUT_DIRECTORY_UNAVAILABLE)
    return target
  }

  private fun imageResult(source: File, preset: PopopxImageQualityPreset): File {
    val output = scratchURL(source, "jpg")
    val failure = try {
      popopxEncodeImage(source, output, preset.maxDimensionInPixels, (preset.jpegQuality * 100).roundToInt())
    } catch (e: Exception) {
      output.delete()
      PopopxMediaEngineError.IMAGE_ENCODE_FAILED
    }
    if (failure != null) {
      output.delete()
      throw PopopxMediaEngineException(failure)
    }
    return output
  }

  private fun videoResult(source: File): File {
    val info = popopxProbeVideoInfo(source)
      ?: throw PopopxMediaEngineException(PopopxMediaEngineError.VIDEO_NO_VIDEO_TRACK)
    val profile = popopxVideoProfile(info)
      ?: throw PopopxMediaEngineException(PopopxMediaEngineError.VIDEO_EXPORT_FAILED)
    val output = scratchURL(source, "mp4")
    val failure = try {
      popopxTranscodeVideo(source, output, profile)
    } catch (e: Exception) {
      output.delete()
      PopopxMediaEngineError.VIDEO_EXPORT_FAILED
    }
    if (failure != null) {
      output.delete()
      throw PopopxMediaEngineException(failure)
    }
    return output
  }

  /** The container iOS streams through `compression_stream`, with the same negative-optimization fuse. */
  internal fun documentResult(source: File): File {
    if (!PopopxDocumentContainer.isEligible(source)) throw PopopxMediaEngineException(PopopxMediaEngineError.STREAM_FAILED)
    val originalBytes = fileSizeOf(source)
    if (originalBytes <= 0L) throw PopopxMediaEngineException(PopopxMediaEngineError.UNREADABLE)
    val output = scratchURL(source, PopopxDocumentContainer.PATH_EXTENSION)
    val packed = try {
      PopopxDocumentContainer.pack(source, output)
    } catch (e: Exception) {
      output.delete()
      throw e
    }
    if (!PopopxDocumentContainer.keepsPackedFile(packed, originalBytes)) {
      output.delete()
      return source
    }
    return output
  }

  fun unpack(container: File): PopopxUnpackResult {
    val destination = try {
      File(unpackedDirectory(), PopopxDocumentContainer.displayName(container))
    } catch (e: Exception) {
      return PopopxUnpackResult.Failure(PopopxMediaEngineError.OUTPUT_DIRECTORY_UNAVAILABLE)
    }
    return try {
      PopopxDocumentContainer.unpack(container, destination)
      PopopxUnpackResult.Success(destination)
    } catch (e: PopopxMediaEngineException) {
      destination.delete()
      PopopxUnpackResult.Failure(e.error)
    } catch (e: Exception) {
      destination.delete()
      PopopxUnpackResult.Failure(PopopxMediaEngineError.STREAM_FAILED)
    }
  }

  private fun readPrefix(file: File, byteCount: Int): ByteArray = try {
    if (!file.isFile) ByteArray(0)
    else file.inputStream().use { input ->
      val buffer = ByteArray(minOf(byteCount.toLong(), file.length()).toInt())
      var offset = 0
      while (offset < buffer.size) {
        val read = input.read(buffer, offset, buffer.size - offset)
        if (read < 0) break
        offset += read
      }
      if (offset == buffer.size) buffer else buffer.copyOf(offset)
    }
  } catch (e: Exception) {
    ByteArray(0)
  }
}

/** The observable half, mirroring `PopopxMediaEngine`. Snapshot state so the processing capsule re-renders. */
class PopopxMediaEngine(private val settings: PopopxMediaSettings = PopopxMediaSettings.shared) {
  var handledAttachmentCount by mutableStateOf(0)
    private set

  var unpackedFileCount by mutableStateOf(0)
    private set

  var savedBytesTotal by mutableLongStateOf(0L)
    private set

  var isProcessing by mutableStateOf(false)
    private set

  /** Single entry point for the outgoing pipeline. Never throws. */
  suspend fun process(file: File, preset: PopopxImageQualityPreset? = null): PopopxCompressedAttachment {
    val chosen = preset ?: settings.imageQualityPreset
    val bytes = PopopxMediaEngineCore.fileSizeOf(file)
    isProcessing = true
    val output = try {
      withContext(Dispatchers.IO) { PopopxMediaEngineCore.perform(file, bytes, chosen) }
    } finally {
      isProcessing = false
    }
    handledAttachmentCount += 1
    savedBytesTotal += output.savedBytes
    return output
  }

  /** Receiving side: unpacks a container into the protected cache. */
  suspend fun unpack(file: File): PopopxUnpackResult {
    val result = withContext(Dispatchers.IO) { PopopxMediaEngineCore.unpack(file) }
    if (result.unpackedFile != null) unpackedFileCount += 1
    return result
  }

  fun reset() {
    handledAttachmentCount = 0
    savedBytesTotal = 0L
    unpackedFileCount = 0
    isProcessing = false
  }

  companion object {
    val shared: PopopxMediaEngine = PopopxMediaEngine()
  }
}
