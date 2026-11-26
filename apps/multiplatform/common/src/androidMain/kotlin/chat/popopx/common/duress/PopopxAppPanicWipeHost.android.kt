package chat.popopx.common.duress

import androidx.work.WorkManager
import chat.popopx.common.AppLock
import chat.popopx.common.eco.PopopxEcoKeys
import chat.popopx.common.eco.PopopxChannelKeyRotation
import chat.popopx.common.media.PopopxOutgoingMediaInterceptor
import chat.popopx.common.mesh.PopopxMeshEngine
import chat.popopx.common.mesh.PopopxMeshEventHub
import chat.popopx.common.mesh.PopopxMeshWipe
import chat.popopx.common.model.ChatModel
import chat.popopx.common.platform.AppContextProvider
import chat.popopx.common.platform.coreTmpDir
import chat.popopx.common.platform.ntfManager
import chat.popopx.common.platform.tmpDir
import chat.popopx.common.views.database.stopChatAsync
import chat.popopx.common.views.helpers.DatabaseUtils
import java.io.File
import kotlin.system.exitProcess

/**
 * What the six steps do on a real device.
 *
 * [PopopxStorageWipe]'s host (the duress path) is a different object and stays suspend: that path rebuilds the app
 * and returns. This one ends the process, so its methods are synchronous and it is called from a background
 * coroutine — the `runBlocking` calls in [stopOutbound] and [burnKeys] are therefore on a worker thread, never on
 * the main one. That is
 * a real constraint, not a style preference: a chat stop that is merely *dispatched* would return while the
 * sending queue is still running, and step 1's contract is "each returned string is something that was still
 * running when the step finished".
 *
 * Nothing here reaches a hardware switch. An ordinary Android app cannot turn the radio off (deviation §6.6), so
 * step 1 stops what this app controls — the mesh's scan and advertisement, its scheduled work, and its chat
 * session — and the journal says that, not "radio off".
 */
class PopopxAppPanicWipeHostImpl(
  private val model: ChatModel = ChatModel,
  private val duress: PopopxDuressAuthManager = PopopxDuressAuthManager.shared,
) : PopopxPanicWipeHost {
  override fun stopOutbound(): List<String> {
    val reasons = mutableListOf<String>()
    // The mesh radio first, ahead of everything else this step stops: iOS puts the radio at the head of the
    // wipe for the reason stated there — a scan still winding down can receive a frame that re-creates a
    // session while the keys are being burned (`PanicWipeManager.swift:588-589`).
    reasons += kotlinx.coroutines.runBlocking { PopopxMeshWipe.stopRadio(PopopxMeshEngine.current) }
    val context = AppContextProvider.getApplicationContext()
    if (context == null) {
      reasons.add("no application context: scheduled work was not cancelled")
    } else {
      try {
        WorkManager.getInstance(context).cancelAllWork()
      } catch (e: Throwable) {
        reasons.add("scheduled work: ${e.message ?: e.javaClass.simpleName}")
      }
    }
    try {
      if (model.chatRunning.value == true) kotlinx.coroutines.runBlocking { stopChatAsync(model) }
    } catch (e: Throwable) {
      reasons.add("chat session: ${e.message ?: e.javaClass.simpleName}")
    }
    return reasons
  }

  override fun burnKeys(): String? =
    try {
      duress.clearAllPins()
      DatabaseUtils.ksAppPassword.remove()
      DatabaseUtils.ksSelfDestructPassword.remove()
      // The service-account keys are the other secrets this device holds, and until now `PopopxEcoKeys.wipe` had
      // no caller. The ids come from the running model, because the step that deletes the database runs after this
      // one and after it the channel list is unreachable.
      val channels = PopopxChannelKeyRotation.shared.channels
      PopopxEcoKeys.wipe(
        channels.mapNotNull { it.issuerContactId }.distinct(),
        channels.map { it.channelId }.distinct(),
      )
      // The mesh static key is a key this device holds, and iOS burns it in this step (`Engine:157-164`).
      val mesh = kotlinx.coroutines.runBlocking { PopopxMeshWipe.burnKeys(PopopxMeshEngine.current) }
      if (mesh.isNotEmpty()) mesh.joinToString("; ") else null
    } catch (e: Throwable) {
      e.message ?: e.javaClass.simpleName
    }

  override fun clearInMemoryMirrors(): List<String> {
    // The unlock state first: a process that has burned its keys must not still believe it is authorized.
    AppLock.clearAuthState()
    ChatModel.showAuthScreen.value = true
    PopopxOutgoingMediaInterceptor.shared.reset()
    // The mesh's published events are mirrors too — a banner that still names a peer after the keys are
    // burned is a leak the user can see, which is why iOS clears `PopopxMeshStateSource` here rather than in
    // the radio step (`PanicWipeManager.swift:599-601`).
    PopopxMeshEventHub.shared.unsubscribeAll()
    // A posted notification is a mirror this device cannot recall after the process exits, and it can carry the
    // message text, so it is cleared with the keys rather than with the database.
    runCatching { ntfManager.cancelAllNotifications() }.exceptionOrNull()?.let {
      return listOf("notifications: ${it.message ?: it.javaClass.simpleName}")
    }
    return emptyList()
  }

  override fun eraseIdentityMapping(): List<String> =
    // Step 3 now has something to erase: the mapping snapshot and the two mesh switches live behind
    // [PopopxMeshWipe], and it returns a reason only when a value survived its removal. The cache files iOS
    // deletes here are the contents of the mesh sandbox, which is step 4's directory on Android.
    PopopxMeshWipe.eraseMappings()

  override fun sandboxDirectories(): List<File> =
    // Directories only — the step feeds `eraseDirectory`. The chat and agent databases are *files* and belong to
    // step 5, which this interface can never request (ruling 2, and `INTERFACE_OPT_IN_TO_DATABASE_ERASE`); naming
    // them here would open the database for overwriting through step 4's back door.
    listOf(
      File(tmpDir, "popopx"),
      // Named explicitly even though `eraseDirectory` walks the parent recursively: the mesh sandbox is a
      // promised overwrite target, and listing it keeps that promise if the parent set ever narrows. When
      // nothing was written there it is absent and the sweep reports nothing, which is the truth, not a skip.
      PopopxMeshWipe.sandboxDirectory(tmpDir),
      coreTmpDir,
    )

  override fun applicationDatabaseFile(): File? = null

  override fun termination(): ((Int) -> Unit)? = { code -> exitProcess(code) }
}

actual fun popopxAppPanicWipeHost(): PopopxPanicWipeHost = PopopxAppPanicWipeHostImpl()
