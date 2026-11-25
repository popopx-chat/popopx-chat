package chat.popopx.common.duress

import androidx.work.WorkManager
import chat.popopx.common.AppLock
import chat.popopx.common.eco.PopopxEcoKeys
import chat.popopx.common.eco.PopopxChannelKeyRotation
import chat.popopx.common.media.PopopxOutgoingMediaInterceptor
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
 * coroutine — the `runBlocking` in [stopOutbound] is therefore on a worker thread, never on the main one. That is
 * a real constraint, not a style preference: a chat stop that is merely *dispatched* would return while the
 * sending queue is still running, and step 1's contract is "each returned string is something that was still
 * running when the step finished".
 *
 * Nothing here reaches a hardware switch. An ordinary Android app cannot turn the radio off (deviation §6.6), so
 * step 1 stops what this app controls — its scheduled work and its chat session — and the journal says that, not
 * "radio off".
 */
class PopopxAppPanicWipeHostImpl(
  private val model: ChatModel = ChatModel,
  private val duress: PopopxDuressAuthManager = PopopxDuressAuthManager.shared,
) : PopopxPanicWipeHost {
  override fun stopOutbound(): List<String> {
    val reasons = mutableListOf<String>()
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
      null
    } catch (e: Throwable) {
      e.message ?: e.javaClass.simpleName
    }

  override fun clearInMemoryMirrors(): List<String> {
    // The unlock state first: a process that has burned its keys must not still believe it is authorized.
    AppLock.clearAuthState()
    ChatModel.showAuthScreen.value = true
    PopopxOutgoingMediaInterceptor.shared.reset()
    // A posted notification is a mirror this device cannot recall after the process exits, and it can carry the
    // message text, so it is cleared with the keys rather than with the database.
    runCatching { ntfManager.cancelAllNotifications() }.exceptionOrNull()?.let {
      return listOf("notifications: ${it.message ?: it.javaClass.simpleName}")
    }
    return emptyList()
  }

  override fun eraseIdentityMapping(): List<String> =
    // Step 3 on iOS erases the mesh identity mapping. `PopopxMeshKit` is phase 4 and is not mounted on Android, so
    // there is nothing here to erase — reporting an empty list would be a step that claims to have run. Ruling 2:
    // the rank and the copy stay, the journal says what actually happened.
    listOf("no identity mapping exists on this platform")

  override fun sandboxDirectories(): List<File> =
    // Directories only — the step feeds `eraseDirectory`. The chat and agent databases are *files* and belong to
    // step 5, which this interface can never request (ruling 2, and `INTERFACE_OPT_IN_TO_DATABASE_ERASE`); naming
    // them here would open the database for overwriting through step 4's back door.
    listOf(
      File(tmpDir, "popopx"),
      coreTmpDir,
    )

  override fun applicationDatabaseFile(): File? = null

  override fun termination(): ((Int) -> Unit)? = { code -> exitProcess(code) }
}

actual fun popopxAppPanicWipeHost(): PopopxPanicWipeHost = PopopxAppPanicWipeHostImpl()
