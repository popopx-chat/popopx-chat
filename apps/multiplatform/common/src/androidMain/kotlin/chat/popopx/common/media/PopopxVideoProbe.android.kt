package chat.popopx.common.media

import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File

// Video probing for the Android media layer.
//
// The frame rate is the one number iOS reads straight off the asset (`nominalFrameRate`) that Android does not
// report for a file: `MediaFormat.KEY_FRAME_RATE` is written by the *encoder*, so a recorded clip usually carries
// no such key on the read side, and `MediaExtractor` publishes no sample count at all. It is therefore measured —
// a declared key when present, otherwise the first samples' timestamps, otherwise 30 — and the derivation only ever
// moves the bitrate and the keyframe spacing inside the clamps that `popopxVideoProfile` already applies.

/** The fallback for a clip whose frame count or duration cannot be read: what a phone camera writes. */
internal const val POPOPX_FALLBACK_FRAME_RATE = 30f

internal inline fun <R> withExtractor(file: File, block: (MediaExtractor) -> R): R? = try {
  val extractor = MediaExtractor()
  try {
    extractor.setDataSource(file.absolutePath)
    block(extractor)
  } finally {
    runCatching { extractor.release() }
  }
} catch (e: Exception) {
  null
}

internal fun videoTrackIndex(extractor: MediaExtractor): Int? =
  (0 until extractor.trackCount).firstOrNull { mimeOf(extractor, it)?.startsWith("video/") == true }

internal fun audioTrackIndex(extractor: MediaExtractor): Int? =
  (0 until extractor.trackCount).firstOrNull { mimeOf(extractor, it)?.startsWith("audio/") == true }

internal fun mimeOf(extractor: MediaExtractor, trackIndex: Int): String? =
  runCatching { extractor.getTrackFormat(trackIndex).getString(MediaFormat.KEY_MIME) }.getOrNull()

internal fun MediaExtractor.formatOf(trackIndex: Int): MediaFormat? =
  runCatching { getTrackFormat(trackIndex) }.getOrNull()

internal fun MediaFormat.intValue(key: String): Int? =
  if (containsKey(key)) runCatching { getInteger(key) }.getOrNull() else null

/** AAC inside an ISO base media file, which is what a phone writes and what `MediaMuxer` accepts on the way out. */
internal fun MediaFormat.isCopyableAudio(): Boolean =
  runCatching { getString(MediaFormat.KEY_MIME) }.getOrNull() == MediaFormat.MIMETYPE_AUDIO_AAC

internal actual fun popopxHasVideoTrack(file: File): Boolean =
  withExtractor(file) { videoTrackIndex(it) != null } == true

internal actual fun popopxProbeVideoInfo(file: File): PopopxVideoSourceInfo? = withExtractor(file) { extractor ->
  val index = videoTrackIndex(extractor) ?: return@withExtractor null
  val format = extractor.formatOf(index) ?: return@withExtractor null
  val width = format.intValue(MediaFormat.KEY_WIDTH) ?: return@withExtractor null
  val height = format.intValue(MediaFormat.KEY_HEIGHT) ?: return@withExtractor null
  PopopxVideoSourceInfo(
    width = width,
    height = height,
    rotationDegrees = format.intValue(MediaFormat.KEY_ROTATION) ?: 0,
    frameRate = popopxAverageFrameRate(extractor, index, format),
  )
}

/** Samples inspected before the estimate is abandoned: more than enough to span a second at any rate. */
private const val POPOPX_FRAME_SAMPLE_LIMIT = 120

/**
 * Frames per second, best effort: a declared key, else the timestamps of the first samples of the selected track,
 * else the camera-typical 30. The walk is bounded so a probe costs at most [POPOPX_FRAME_SAMPLE_LIMIT] `advance()`
 * calls, and a failed measurement degrades to the fallback rather than to a refusal — the profile it feeds is
 * clamped either way.
 */
internal fun popopxAverageFrameRate(extractor: MediaExtractor, trackIndex: Int, format: MediaFormat): Float {
  format.intValue(MediaFormat.KEY_FRAME_RATE)?.takeIf { it > 0 }?.let { return it.toFloat() }
  val measured = runCatching {
    extractor.selectTrack(trackIndex)
    var first = -1L
    var last = -1L
    var samples = 0
    while (samples < POPOPX_FRAME_SAMPLE_LIMIT) {
      val time = extractor.sampleTime
      if (time < 0L) break
      if (first < 0L) first = time
      last = time
      samples += 1
      if (!extractor.advance()) break
    }
    val spanUs = last - first
    if (samples >= 2 && spanUs > 0L) (samples - 1).toFloat() / (spanUs / 1_000_000f) else 0f
  }.getOrDefault(0f)
  return if (measured > 0f) measured else POPOPX_FALLBACK_FRAME_RATE
}
