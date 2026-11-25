package chat.popopx.common.media

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.SystemClock
import java.io.File
import java.nio.ByteBuffer

// The video half of the Android media layer: decode, re-encode at the profile the pure function decided, mux.
//
// Why a re-encode rather than a metadata edit of the existing file: the GPS, the maker note and the shoot time of a
// clip live in the container's metadata box, which `MediaMuxer` does not carry over at all — so a remux would strip
// them too. What it would not do is shrink the file, and the engine's fuse rejects an output that is not smaller
// than its input, so a remux is thrown away and the original goes out with its metadata intact. Re-encoding is the
// only path here that satisfies both halves of the iOS rule.
//
// Audio is copied rather than re-encoded to mono AAC: a copy keeps the clip's sound, needs no second codec loop,
// and writes no metadata. A source whose audio is not AAC in an ISO base media file is refused rather than muxed
// into something a receiver may not play. The buffer loop itself is in `PopopxVideoCodecLoop.android.kt`.
//
// This path is compile-verified only: no emulator run was part of this phase, and every failure path deletes its
// output so the core sends the original clip instead of a truncated one.

internal const val POPOPX_CODEC_TIMEOUT_US = 10_000L

internal actual fun popopxTranscodeVideo(
  source: File,
  destination: File,
  profile: PopopxVideoProfile,
): PopopxMediaEngineError? {
  val extractor = MediaExtractor()
  var decoder: MediaCodec? = null
  var encoder: MediaCodec? = null
  var muxer: MediaMuxer? = null
  val failure = try {
    extractor.setDataSource(source.absolutePath)
    val videoIndex = videoTrackIndex(extractor) ?: return PopopxMediaEngineError.VIDEO_NO_VIDEO_TRACK
    val videoFormat = extractor.formatOf(videoIndex) ?: return PopopxMediaEngineError.VIDEO_NO_VIDEO_TRACK
    val decoderMime = videoFormat.getString(MediaFormat.KEY_MIME) ?: return PopopxMediaEngineError.VIDEO_EXPORT_FAILED
    val audioIndex = audioTrackIndex(extractor)
    if (audioIndex != null && extractor.formatOf(audioIndex)?.isCopyableAudio() != true) {
      return PopopxMediaEngineError.VIDEO_EXPORT_FAILED
    }
    val encoderFormat = MediaFormat.createVideoFormat(
      MediaFormat.MIMETYPE_VIDEO_AVC,
      profile.width,
      profile.height,
    ).apply {
      setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
      setInteger(MediaFormat.KEY_BIT_RATE, profile.bitrateBps)
      setInteger(
        MediaFormat.KEY_FRAME_RATE,
        popopxAverageFrameRate(extractor, videoIndex, videoFormat).toInt().coerceAtLeast(1),
      )
      setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, profile.keyframeInterval)
    }
    decoder = MediaCodec.createDecoderByType(decoderMime)
    encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    muxer = MediaMuxer(destination.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    popopxRunTranscode(extractor, decoder, encoder, muxer, videoFormat, encoderFormat, videoIndex, audioIndex, profile)
  } catch (e: Exception) {
    PopopxMediaEngineError.VIDEO_EXPORT_FAILED
  } finally {
    runCatching { decoder?.stop() }
    runCatching { decoder?.release() }
    runCatching { encoder?.stop() }
    runCatching { encoder?.release() }
    runCatching { muxer?.stop() }
    runCatching { muxer?.release() }
    runCatching { extractor.release() }
  }
  if (failure != null) destination.delete()
  return failure
}

/** How long the encoder is given to flush the frames it still holds after the last input. */
private const val POPOPX_TRANSCODE_TAIL_MS = 5_000L

/** Scratch buffer size for a copied audio sample; an AAC frame is a few kilobytes, so this is never the limit. */
private const val POPOPX_AUDIO_SAMPLE_BYTES = 256 * 1024

/**
 * The synchronous buffer loop: pull a decoded frame, push it at the encoder, drain whatever the encoder has
 * produced, and stop at the first sign of trouble. Null means the muxer was started and reached end of stream;
 * anything else deletes the partial file upstream so the original clip is sent instead.
 */
private fun popopxRunTranscode(
  extractor: MediaExtractor,
  decoder: MediaCodec,
  encoder: MediaCodec,
  muxer: MediaMuxer,
  videoFormat: MediaFormat,
  encoderFormat: MediaFormat,
  videoIndex: Int,
  audioIndex: Int?,
  profile: PopopxVideoProfile,
): PopopxMediaEngineError? {
  val audioFormat = if (audioIndex == null) null else extractor.formatOf(audioIndex)
    ?: return PopopxMediaEngineError.VIDEO_EXPORT_FAILED
  // `MediaMuxer` carries the rotation as a hint on the track, and it only accepts quarter turns; an
  // odd angle has no container representation, so it is left out rather than guessed at.
  if (profile.rotationDegrees % 90 == 0) muxer.setOrientationHint(profile.rotationDegrees)
  decoder.configure(videoFormat, null, null, 0)
  encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
  extractor.selectTrack(videoIndex)
  decoder.start()
  encoder.start()

  val sink = PopopxEncoderSink(encoder, muxer, audioFormat)
  val info = MediaCodec.BufferInfo()
  var inputDone = false
  var outputDone = false

  while (!outputDone) {
    if (!inputDone) {
      val inputIndex = decoder.dequeueInputBuffer(POPOPX_CODEC_TIMEOUT_US)
      if (inputIndex >= 0) {
        val input = decoder.getInputBuffer(inputIndex)
        val size = if (input == null) -1 else extractor.readSampleData(input, 0)
        if (size < 0) {
          decoder.queueInputBuffer(inputIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
          inputDone = true
        } else {
          decoder.queueInputBuffer(inputIndex, 0, size, extractor.sampleTime, 0)
          extractor.advance()
        }
      }
    }
    val index = decoder.dequeueOutputBuffer(info, POPOPX_CODEC_TIMEOUT_US)
    when {
      index == MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
      index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED || index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
      index < 0 -> return PopopxMediaEngineError.VIDEO_EXPORT_FAILED
      else -> {
        val endOfStream = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
        val accepted = sink.accept(decoder, index, info, endOfStream)
        decoder.releaseOutputBuffer(index, false)
        if (!accepted) return PopopxMediaEngineError.VIDEO_EXPORT_FAILED
        if (endOfStream) outputDone = true
      }
    }
    sink.drain()?.let { return it }
  }
  // A hardware encoder holds the last few frames until it is emptied, so the tail is bounded by time, not by
  // iteration count: it stops as soon as the end-of-stream buffer arrives.
  val deadline = SystemClock.elapsedRealtime() + POPOPX_TRANSCODE_TAIL_MS
  while (!sink.finished) {
    sink.drain()?.let { return it }
    if (!sink.finished && SystemClock.elapsedRealtime() >= deadline) {
      return PopopxMediaEngineError.VIDEO_EXPORT_FAILED
    }
  }
  if (audioIndex != null) popopxCopyAudioTrack(extractor, sink, audioIndex, videoIndex)?.let { return it }
  return null
}

/**
 * Re-demuxes the audio track and writes its compressed samples straight into the new file: no decode, no second
 * re-encode, and nothing in the copied samples names a device or a place.
 */
private fun popopxCopyAudioTrack(
  extractor: MediaExtractor,
  sink: PopopxEncoderSink,
  trackIndex: Int,
  videoIndex: Int,
): PopopxMediaEngineError? = try {
  popopxWalkAudioSamples(extractor, sink, trackIndex, videoIndex)
} catch (e: Exception) {
  PopopxMediaEngineError.VIDEO_EXPORT_FAILED
}

/** The loop, kept apart from its handler so that an early exit can be a plain return. */
private fun popopxWalkAudioSamples(
  extractor: MediaExtractor,
  sink: PopopxEncoderSink,
  trackIndex: Int,
  videoIndex: Int,
): PopopxMediaEngineError? {
  val buffer = ByteBuffer.allocate(POPOPX_AUDIO_SAMPLE_BYTES)
  val info = MediaCodec.BufferInfo()
  // Only a selected track yields samples, and the video track has to be dropped first: a mixed read returns both
  // tracks interleaved, which would write video frames into the audio track.
  extractor.unselectTrack(videoIndex)
  extractor.selectTrack(trackIndex)
  extractor.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
  while (true) {
    buffer.clear()
    val size = extractor.readSampleData(buffer, 0)
    if (size < 0) break
    if (size > buffer.capacity()) return PopopxMediaEngineError.VIDEO_EXPORT_FAILED
    if (extractor.sampleTrackIndex == trackIndex) {
      info.set(0, size, extractor.sampleTime.coerceAtLeast(0L), extractor.sampleFlags)
      if (!sink.writeAudio(buffer, info)) return PopopxMediaEngineError.VIDEO_EXPORT_FAILED
      if (extractor.sampleFlags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
    }
    extractor.advance()
  }
  return null
}
