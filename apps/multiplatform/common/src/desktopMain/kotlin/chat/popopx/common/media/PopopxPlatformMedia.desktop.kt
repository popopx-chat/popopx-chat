package chat.popopx.common.media

import java.io.File

// Desktop actuals for the media platform seam.
//
// There is no desktop behaviour to define here: the composer only asks the engine when `appPlatform.isAndroid`, so
// the desktop app keeps attaching exactly the bytes it attaches today and its snapshot baselines cannot move.
// These actuals exist so the shared code — the classifier, the container, the profile arithmetic, every unit test
// that drives them — compiles and runs on the JVM without Android's codec classes in reach.

internal actual fun popopxEncodeImage(
  source: File,
  destination: File,
  maxDimensionInPixels: Int,
  qualityPercent: Int,
): PopopxMediaEngineError? = PopopxMediaEngineError.IMAGE_DECODE_FAILED

internal actual fun popopxTranscodeVideo(
  source: File,
  destination: File,
  profile: PopopxVideoProfile,
): PopopxMediaEngineError? = PopopxMediaEngineError.VIDEO_EXPORT_FAILED

/** The classifier treats this as "the magic said nothing", which is the same answer a file with no video gives. */
internal actual fun popopxHasVideoTrack(file: File): Boolean = false

internal actual fun popopxProbeVideoInfo(file: File): PopopxVideoSourceInfo? = null
