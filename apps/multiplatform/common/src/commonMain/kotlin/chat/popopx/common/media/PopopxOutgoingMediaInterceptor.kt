package chat.popopx.common.media

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.CircularProgressIndicator
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import java.io.File

// Ported from `PopopxOutgoingMediaInterceptor` in apps/ios/Shared/Features/MediaCompression/PopopxOutgoingMediaInterceptor.swift.
//
// Same contract: the host hands over the file it is about to attach plus the size of the target conversation and
// gets back the file to attach instead. A failure inside the engine never blocks a send — the original file comes
// back — and only the large-group ceiling refuses an attachment outright.
//
// Two iOS details are not portable and are left out rather than faked: haptics (the multiplatform app has no
// haptic bus, so the success and warning notifications have no Android counterpart) and the `blockedMessage`
// presentation, which iOS delegates to the caller's alert surface and this port raises through the caller's own
// `AlertManager` in the handoff file.

/** The English sentence is the iOS catalog key; the moko slot carries the same wording. */
object PopopxMediaCopy {
  fun processingStatus(): String = generalGetString(MR.strings.media_processing_status)
  fun oversizedBlocked(): String = generalGetString(MR.strings.media_oversized_blocked)
  fun unpackFailed(): String = generalGetString(MR.strings.media_unpack_failed)
}

class PopopxOutgoingAttachment(
  val file: File,
  val displayName: String,
  val kind: PopopxAttachmentKind,
  val originalBytes: Long,
  val finalBytes: Long,
  val compressed: Boolean,
  val blocked: Boolean,
) {
  val savedBytes: Long get() = if (compressed) maxOf(0L, originalBytes - finalBytes) else 0L

  companion object {
    /** A blocked attachment keeps its file so the caller can still report on it, but must not be attached. */
    fun passthrough(file: File, kind: PopopxAttachmentKind, bytes: Long, blocked: Boolean): PopopxOutgoingAttachment =
      PopopxOutgoingAttachment(
        file = file,
        displayName = file.name,
        kind = kind,
        originalBytes = bytes,
        finalBytes = bytes,
        compressed = false,
        blocked = blocked,
      )
  }
}

class PopopxOutgoingBatch(val attachments: List<PopopxOutgoingAttachment> = emptyList()) {
  val allowed: List<PopopxOutgoingAttachment> get() = attachments.filter { !it.blocked }
  val blocked: List<PopopxOutgoingAttachment> get() = attachments.filter { it.blocked }
  val savedBytes: Long get() = attachments.fold(0L) { total, it -> total + it.savedBytes }
  val isEmpty: Boolean get() = attachments.isEmpty()
}

class PopopxOutgoingMediaInterceptor(
  private val settings: PopopxMediaSettings = PopopxMediaSettings.shared,
  private val engine: PopopxMediaEngine = PopopxMediaEngine.shared,
) {
  /** Counted rather than flagged, because two attachments can be prepared before either finishes. */
  var activeTaskCount by mutableIntStateOf(0)
    private set

  var processedCount by mutableIntStateOf(0)
    private set

  var lastSavedBytes by mutableLongStateOf(0L)
    private set

  val isProcessing: Boolean get() = activeTaskCount > 0

  /** Text shown by the capsule while attachments are being prepared. */
  val statusText: String get() = PopopxMediaCopy.processingStatus()

  /** Message shown when the large-group ceiling refuses a file. */
  val blockedMessage: String get() = PopopxMediaCopy.oversizedBlocked()

  suspend fun prepare(files: List<File>, groupMemberCount: Int = 0): PopopxOutgoingBatch {
    val prepared = files.map { prepareOne(it, groupMemberCount) }
    return PopopxOutgoingBatch(prepared)
  }

  /** The single interception point: engine first, then the large-group ceiling. */
  suspend fun prepareOne(file: File, groupMemberCount: Int = 0): PopopxOutgoingAttachment {
    activeTaskCount += 1
    try {
      val bytes = PopopxMediaEngineCore.fileSizeOf(file)
      if (!settings.isEngineEnabled) {
        return PopopxOutgoingAttachment.passthrough(file, PopopxAttachmentKind.PASSTHROUGH, bytes, blocked = false)
      }
      val result = engine.process(file, settings.imageQualityPreset)
      val blocked = settings.appliesToGroup(groupMemberCount) && result.finalBytes > settings.sizeCeiling
      processedCount += 1
      lastSavedBytes = result.savedBytes
      return PopopxOutgoingAttachment(
        file = result.file,
        displayName = result.file.name,
        kind = result.kind,
        originalBytes = result.originalBytes,
        finalBytes = result.finalBytes,
        compressed = result.compressed,
        blocked = blocked,
      )
    } finally {
      activeTaskCount -= 1
    }
  }

  fun reset() {
    activeTaskCount = 0
    processedCount = 0
    lastSavedBytes = 0L
  }

  companion object {
    val shared: PopopxOutgoingMediaInterceptor = PopopxOutgoingMediaInterceptor()
  }
}

/** The lightweight processing pill placed above the input bar. Android-only mount. */
@Composable
fun PopopxMediaProcessingCapsule(text: String, modifier: Modifier = Modifier) {
  val shape = RoundedCornerShape(50)
  Row(
    modifier = modifier
      .padding(horizontal = 12.dp, vertical = 4.dp)
      .clip(shape)
      .background(MaterialTheme.colors.surface)
      .border(1.dp, MaterialTheme.colors.primary.copy(alpha = 0.28f), shape)
      .padding(horizontal = 10.dp, vertical = 5.dp),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(6.dp),
  ) {
    CircularProgressIndicator(modifier = Modifier.size(13.dp), strokeWidth = 1.5.dp, color = MaterialTheme.colors.primary)
    Text(
      text = text,
      style = MaterialTheme.typography.body2,
      color = MaterialTheme.colors.onSurface,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis,
    )
  }
}
