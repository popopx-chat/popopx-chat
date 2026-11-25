package chat.popopx.common.media

import chat.popopx.common.model.Chat
import chat.popopx.common.model.ChatInfo
import chat.popopx.common.model.CryptoFile
import chat.popopx.common.model.encryptCryptoFile
import chat.popopx.common.platform.appPlatform
import chat.popopx.common.platform.chatController
import chat.popopx.common.platform.getAppFilePath
import chat.popopx.common.platform.inputStream
import chat.popopx.common.views.helpers.AlertManager
import chat.popopx.common.views.helpers.FileTooLargeException
import chat.popopx.common.views.helpers.copyInputStreamToFile
import chat.popopx.common.views.helpers.generateNewFileName
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.common.views.helpers.getFileName
import chat.popopx.common.views.helpers.uniqueCombine
import chat.popopx.res.*
import java.io.File
import java.net.URI

// The Android-only seam between the picked attachment and the engine.
//
// iOS intercepts a file URL and hands a file URL back, because that is what its composer holds. The Android
// composer holds a content URI, and both helpers that turn one into an attachment (`saveImage`,
// `saveFileFromUri`) ask the provider for a display name, which a `file://` URI has none of. So the engine cannot
// be given a substituted URI: it has to produce the attachment itself, from a file, which is what
// [popopxSaveLocalFile] does — the same tail `saveFileFromUri` runs, with the destination name chosen the same way.
//
// Every decline returns control to the caller's original code path, so with the engine switched off, on desktop, or
// after any failure inside the platform layer, the bytes sent are exactly what this phase would have sent.

/**
 * The single mount used by the composer's media branches. [fallback] is today's save call, kept at the call site so
 * the reader can see what happens when the engine declines. Returning null means "do not send this attachment",
 * which happens only when the large-group ceiling refuses a file that is still over the ceiling.
 */
suspend fun popopxOutgoingFile(
  uri: URI,
  maxBytes: Long,
  groupMemberCount: Int,
  hiddenFileNamePrefix: String?,
  fallback: () -> CryptoFile?,
): CryptoFile? {
  if (!appPlatform.isAndroid || !PopopxMediaSettings.shared.isEngineEnabled) return fallback()
  val displayName = getFileName(uri) ?: return fallback()
  val source = popopxCopyToSandbox(uri, displayName, maxBytes) ?: return fallback()
  val attachment = try {
    PopopxOutgoingMediaInterceptor.shared.prepareOne(source, groupMemberCount)
  } catch (e: Exception) {
    source.delete()
    return fallback()
  }
  if (attachment.blocked) {
    source.delete()
    AlertManager.shared.showAlertMsg(
      title = generalGetString(MR.strings.large_file),
      text = PopopxOutgoingMediaInterceptor.shared.blockedMessage,
    )
    return null
  }
  // Not compressed is not a failure: it is the engine saying "this one I leave to you", and today's path knows
  // things this one does not, like the byte target the core resize aims an image at.
  if (!attachment.compressed) {
    source.delete()
    return fallback()
  }
  val saved = runCatching { popopxSaveLocalFile(attachment.file, displayName, hiddenFileNamePrefix, maxBytes) }.getOrNull()
  // The staged original and the recompressed copy have no reason to outlive the send: the payload now sits in the
  // app's own files directory, encrypted when that preference is on.
  source.delete()
  if (saved != null && attachment.file != source) attachment.file.delete()
  return saved ?: fallback()
}

/** Members of the conversation an attachment is about to be sent into, as the ceiling gate counts them. */
fun popopxGroupMemberCount(chat: Chat): Int = when (val info = chat.chatInfo) {
  is ChatInfo.Group -> {
    val summary = info.groupInfo.groupSummary
    val total = summary.currentMembers + (summary.publicMemberCount ?: 0L)
    if (total > Int.MAX_VALUE.toLong()) Int.MAX_VALUE else total.toInt()
  }
  else -> 0
}

/** Writes [source] into the app's files directory under the name the existing save path would have chosen. */
private fun popopxSaveLocalFile(
  source: File,
  displayName: String,
  hiddenFileNamePrefix: String?,
  maxBytes: Long,
): CryptoFile? {
  val directory = File(getAppFilePath(""))
  // The extension follows the bytes, not the picked name: a HEIC that decoded becomes a .jpg, and labelling the
  // JPEG stream `.heic` would leave the receiver with a file it cannot open.
  val extension = source.extension.lowercase().ifEmpty { displayName.substringAfterLast('.', "").lowercase() }
  val destFileName = if (hiddenFileNamePrefix != null) {
    generateNewFileName(hiddenFileNamePrefix, extension.ifEmpty { null }, directory)
  } else {
    val stem = if (displayName.contains(".")) displayName.substringBeforeLast(".") else displayName
    uniqueCombine(if (extension.isEmpty()) stem else "$stem.$extension", directory)
  }
  val destination = File(getAppFilePath(destFileName))
  return if (chatController.appPrefs.privacyEncryptLocalFiles.get()) {
    val args = encryptCryptoFile(source.absolutePath, destination.absolutePath)
    CryptoFile(destFileName, args)
  } else {
    copyInputStreamToFile(source.inputStream(), destination, maxBytes)
    CryptoFile.plain(destFileName)
  }
}

/** The picked file, streamed into the engine's sandbox under its provider name. Null if it cannot be staged. */
private fun popopxCopyToSandbox(uri: URI, displayName: String, maxBytes: Long): File? {
  val directory = runCatching { PopopxMediaEngineCore.workingDirectory() }.getOrNull() ?: return null
  val target = File(directory, uniqueCombine(PopopxDocumentContainer.sanitize(displayName), directory))
  val input = uri.inputStream() ?: return null
  return try {
    input.use { copyInputStreamToFile(it, target, maxBytes) }
    target
  } catch (e: FileTooLargeException) {
    // The caller's own path shows the "file too large" alert, with the same limit, so this stays quiet here.
    target.delete()
    null
  } catch (e: Exception) {
    target.delete()
    null
  }
}
