package chat.popopx.common.media

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import java.nio.ByteBuffer

// Buffer plumbing for the transcode loop: one decoder frame into the encoder, one encoded frame into the muxer.
//
// The muxer cannot be started before the encoder reports its output format, because that is where the SPS/PPS live,
// and `MediaMuxer` refuses a track added after `start()`. So the copied audio track — if the clip has one — is
// registered in that same moment, which is the only reason this class knows about audio at all.
//
// A drain call that finds nothing queued returns "keep going" rather than "done": the encoder is free to hold a
// frame until the next one arrives, and only its end-of-stream flag closes the file.

internal class PopopxEncoderSink(
  private val encoder: MediaCodec,
  private val muxer: MediaMuxer,
  private val audioFormat: MediaFormat?,
) {
  var videoTrack = -1
    private set
  var audioTrack = -1
    private set

  private var started = false
  private var sawEndOfStream = false

  /** True once the encoder has emitted its end-of-stream buffer, which is when the file may be closed. */
  val finished: Boolean get() = sawEndOfStream

  /** False when the encoder could not take the frame, which the caller treats as a failed transcode. */
  fun accept(
    decoder: MediaCodec,
    decoderIndex: Int,
    decoderInfo: MediaCodec.BufferInfo,
    endOfStream: Boolean,
  ): Boolean {
    val inputIndex = dequeueInput() ?: return false
    val input = encoder.getInputBuffer(inputIndex) ?: return false
    input.clear()
    if (endOfStream) {
      encoder.queueInputBuffer(inputIndex, 0, 0, decoderInfo.presentationTimeUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
      return true
    }
    val output = decoder.getOutputBuffer(decoderIndex) ?: return false
    output.position(decoderInfo.offset)
    output.limit(decoderInfo.offset + decoderInfo.size)
    if (decoderInfo.size > input.remaining()) return false
    input.put(output)
    encoder.queueInputBuffer(inputIndex, 0, decoderInfo.size, decoderInfo.presentationTimeUs.coerceAtLeast(0L), 0)
    return true
  }

  /** Writes every encoded frame currently available. Null means "keep going", an error means abandon the clip. */
  fun drain(): PopopxMediaEngineError? {
    while (true) {
      val info = MediaCodec.BufferInfo()
      when (val index = encoder.dequeueOutputBuffer(info, POPOPX_CODEC_TIMEOUT_US)) {
        MediaCodec.INFO_TRY_AGAIN_LATER -> return null
        MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
          if (started) return PopopxMediaEngineError.VIDEO_EXPORT_FAILED
          videoTrack = muxer.addTrack(encoder.outputFormat)
          if (audioFormat != null) audioTrack = muxer.addTrack(audioFormat)
          muxer.start()
          started = true
        }
        MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
        else -> {
          if (index < 0) return PopopxMediaEngineError.VIDEO_EXPORT_FAILED
          val buffer = encoder.getOutputBuffer(index)
          // A partial frame is not a frame; muxing it produces a clip that stops short of its duration.
          if (buffer != null && started && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_PARTIAL_FRAME == 0) {
            muxer.writeSampleData(videoTrack, buffer, info)
          }
          encoder.releaseOutputBuffer(index, false)
          if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
            sawEndOfStream = true
            return null
          }
        }
      }
    }
  }

  /** Copies one demuxed audio sample straight into the new file. [started] is what makes this legal at all. */
  fun writeAudio(buffer: ByteBuffer, info: MediaCodec.BufferInfo): Boolean {
    if (!started || audioTrack < 0) return false
    muxer.writeSampleData(audioTrack, buffer, info)
    return true
  }

  private fun dequeueInput(): Int? {
    repeat(DEQUEUE_ATTEMPTS) {
      val index = encoder.dequeueInputBuffer(POPOPX_CODEC_TIMEOUT_US)
      if (index >= 0) return index
      drain()
    }
    return null
  }

  private companion object {
    /** The encoder input queue is small; emptying the output side is what frees it up again. */
    const val DEQUEUE_ATTEMPTS = 64
  }
}
