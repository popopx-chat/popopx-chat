package chat.popopx.common.duress

import chat.popopx.common.eco.PopopxEcoKeys
import chat.popopx.common.model.ChatModel
import chat.popopx.common.platform.agentDatabaseFileName
import chat.popopx.common.platform.chatCloseStore
import chat.popopx.common.platform.chatDatabaseFileName
import chat.popopx.common.platform.dataDir
import chat.popopx.common.platform.ntfManager
import chat.popopx.common.platform.tmpDir
import chat.popopx.common.views.database.deleteChatDatabaseFilesAndState
import chat.popopx.common.views.database.stopChatAsync
import chat.popopx.common.views.helpers.DatabaseUtils
import chat.popopx.common.views.localauth.reinitChatController
import java.io.File

/**
 * The effects a storage wipe needs, all of them reached through here so the ordering can be tested.
 *
 * The production implementation is [AndroidStorageWipeHost], and its bodies are the same calls upstream's own
 * self-destruct flow makes (`LocalAuthView.kt:51-101`) — not a new design. Every method is allowed to throw; the
 * wipe catches per-step and keeps going, because a wipe that stops at the first failure leaves the *rest* of the data
 * intact, which is the worst of both outcomes.
 */
interface PopopxStorageWipeHost {
  /** Whether the chat was running, reported back so the journal says what actually happened. */
  suspend fun stopChat(): Boolean

  /** Closes the agent's database handles. Must precede any file deletion. */
  fun closeDatabaseStore()

  /** The files whose contents must be overwritten rather than merely unlinked. */
  fun sensitiveFiles(): List<File>

  /**
   * Erases the secrets this module and its neighbours keep: the duress records, the upstream app/self-destruct
   * passcodes, and the service-account keys.
   */
  fun clearSecrets()

  fun cancelNotifications()

  /** Rebuilds the control layer and a fresh active user, so the app is left usable rather than bricked. */
  suspend fun rebuild()
}

/** One step's result. */
data class PopopxStorageWipeEntry(
  val step: PopopxStorageWipeStep,
  val ok: Boolean,
  val detail: String? = null,
)

enum class PopopxStorageWipeStep {
  StopChat,
  CloseDatabase,
  EraseFiles,
  ClearSecrets,
  CancelNotifications,
  Rebuild,
}

/**
 * What a wipe did.
 *
 * [isClean] is the only claim the UI may make. A wipe that cleared the secrets but failed to overwrite the database
 * files is *not* clean, and the duress flow still has to leave the app looking empty — which it does, because none of
 * these steps are conditional on each other.
 */
class PopopxStorageWipeReport(val entries: List<PopopxStorageWipeEntry>, val eraseFailures: List<PopopxSecureDeleter.Failure>) {
  val isClean: Boolean get() = entries.all { it.ok } && eraseFailures.isEmpty()

  val stepsCompleted: Int get() = entries.count { it.ok }

  fun summary(): String = buildString {
    append("storage wipe ")
    if (isClean) append("clean") else append("incomplete")
    append(": ")
    append(entries.joinToString("; ") { "${it.step}${if (it.ok) "=ok" else "=failed(${it.detail ?: "no detail"})"}" })
    if (eraseFailures.isNotEmpty()) append("; erase failures=${eraseFailures.size}")
  }
}

/**
 * The duress path's erasure: destroy the local database, every secret this module and its neighbours hold, then
 * rebuild an empty app.
 *
 * Mirrors iOS `PopopxStorageWipe` (A:831-952) in *intent* and upstream `LocalAuthView.deleteStorageAndRestart`
 * (LocalAuthView.kt:51-101) in *mechanism*. Two properties are the reason this is a class rather than four lines in
 * the keypad's callback:
 *
 * 1. **No process termination.** iOS forbids `exit(0)`/`abort()` on this path (App Store 4.2.x, and here the simpler
 *    reason that a duress wipe must leave the user inside an apparently-fresh app, not inside a crash dialog that
 *    announces the wipe happened). Only the three-tap path terminates, via its own host hook — ruling 2.
 * 2. **The database handle closes before any file is touched.** Upstream's comment is the authority here: without
 *    `chatCloseStore`, the OS can deny the database removal, and a wipe that silently fails to remove the database is
 *    a wipe that reports success while leaving every message on the disk.
 */
class PopopxStorageWipe(
  private val host: PopopxStorageWipeHost,
  private val deleter: PopopxSecureDeleter = PopopxSecureDeleter(),
  private val log: (String) -> Unit = { },
) {
  suspend fun execute(): PopopxStorageWipeReport {
    val entries = mutableListOf<PopopxStorageWipeEntry>()
    val eraseFailures = mutableListOf<PopopxSecureDeleter.Failure>()

    entries += attempt(PopopxStorageWipeStep.StopChat) { if (host.stopChat()) "was running" else "was not running" }
    entries += attempt(PopopxStorageWipeStep.CloseDatabase) { host.closeDatabaseStore(); "closed" }

    // Overwrite-then-delete happens before `deleteChatDatabaseFilesAndState()`, because that function unlinks with
    // plain `File.delete()` and an unlinked-but-unoverwritten SQLite file is exactly what this step exists to prevent.
    entries += attempt(PopopxStorageWipeStep.EraseFiles) {
      host.sensitiveFiles().forEach { file ->
        // A refused overwrite is collected, not propagated: the files after it still have to be erased.
        try {
          deleter.eraseFile(file)
        } catch (f: PopopxSecureDeleter.Failure) {
          eraseFailures += f
        }
      }
      // Recorded as a failure if any overwrite refused, so `isClean` cannot be reached by a wipe that only unlinked.
      if (eraseFailures.isNotEmpty()) "overwrites refused=${eraseFailures.size}" else null
    }

    entries += attempt(PopopxStorageWipeStep.ClearSecrets) { host.clearSecrets(); null }
    entries += attempt(PopopxStorageWipeStep.CancelNotifications) { host.cancelNotifications(); null }
    entries += attempt(PopopxStorageWipeStep.Rebuild) { host.rebuild(); null }

    val report = PopopxStorageWipeReport(entries, eraseFailures.toList())
    // Logged last but never after a process exit, because this path does not exit — the journal is the only record
    // that survives, and a wipe that cannot say what it did is indistinguishable from one that did nothing.
    log(report.summary())
    return report
  }

  /**
   * Runs one step and turns any throwable into a journal entry.
   *
   * The swallowed exception is not sloppiness: the caller of a duress wipe is a person standing over a phone who
   * needs it finished, and every step after a failure is still worth doing. It is why each step is a separate
   * `attempt` rather than one `try`.
   */
  private suspend fun attempt(step: PopopxStorageWipeStep, detailStep: suspend () -> String?): PopopxStorageWipeEntry =
    try {
      PopopxStorageWipeEntry(step, ok = true, detail = detailStep())
    } catch (e: Throwable) {
      log("storage wipe step $step failed: ${e.message}")
      PopopxStorageWipeEntry(step, ok = false, detail = e.message ?: e.javaClass.simpleName)
    }
}

/**
 * The production host.
 *
 * Nothing here is invented: each line reproduces a call the shipped self-destruct flow already makes, in the order it
 * already makes them, with the duress module's own records and the service-account keys added — the two things
 * upstream's flow has no reason to know about and which therefore survive an upstream wipe today.
 */
class AndroidStorageWipeHost(
  private val model: ChatModel,
  /** The service-account contacts and channels whose keys are erased along with everything else. */
  private val ecoIds: () -> Pair<List<Long>, List<String>> = { emptyList<Long>() to emptyList<String>() },
  private val duress: PopopxDuressAuthManager = PopopxDuressAuthManager.shared,
) : PopopxStorageWipeHost {
  override suspend fun stopChat(): Boolean {
    val wasRunning = model.chatRunning.value == true
    if (wasRunning) stopChatAsync(model)
    return wasRunning
  }

  override fun closeDatabaseStore() {
    val ctrl = model.controller.getChatCtrl()
    // `-1L` is upstream's "no controller" sentinel (LocalAuthView.kt:36, :62), so it must not be handed to the JNI.
    if (ctrl != null && ctrl != -1L) chatCloseStore(ctrl)
  }

  override fun sensitiveFiles(): List<File> =
    listOf(
      File(dataDir, chatDatabaseFileName),
      File(dataDir, "$chatDatabaseFileName.bak"),
      File(dataDir, "$chatDatabaseFileName.exported"),
      File(dataDir, agentDatabaseFileName),
      File(dataDir, "$agentDatabaseFileName.bak"),
      File(dataDir, "$agentDatabaseFileName.exported"),
      // The plaintext copies this phase created. iOS overwrites its mesh sandbox for the same reason: they are the
      // files a forensic copy of the database would otherwise not be needed to read.
      File(tmpDir, "popopx"),
    )

  override fun clearSecrets() {
    duress.clearAllPins()
    DatabaseUtils.ksAppPassword.remove()
    DatabaseUtils.ksSelfDestructPassword.remove()
    val (contacts, channels) = ecoIds()
    PopopxEcoKeys.wipe(contacts, channels)
  }

  override fun cancelNotifications() {
    ntfManager.cancelAllNotifications()
  }

  /**
   * Rebuilds through upstream's own path: `deleteChatDatabaseFilesAndState()` for the files, preferences and in-memory
   * caches, then `reinitChatController()` for the control layer and a fresh active user.
   *
   * `apiCreateActiveUser` and `startChat` are deliberately *not* re-implemented here — `reinitChatController` is the
   * function the shipped flow uses, and a second implementation of controller startup is how a wipe ends with a
   * controller that half exists.
   */
  override suspend fun rebuild() {
    deleteChatDatabaseFilesAndState()
    reinitChatController()
  }
}
