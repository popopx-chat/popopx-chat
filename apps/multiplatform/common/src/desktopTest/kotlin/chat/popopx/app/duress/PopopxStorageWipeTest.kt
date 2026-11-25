package chat.popopx.app.duress

import chat.popopx.common.duress.PopopxSecureDeleter
import chat.popopx.common.duress.PopopxStorageWipe
import chat.popopx.common.duress.PopopxStorageWipeHost
import chat.popopx.common.duress.PopopxStorageWipeStep
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

// The duress path's erasure, asserted as a *sequence*.
//
// The production host is upstream's own self-destruct flow with two additions, so what a test can add here is not
// "does the call work" but "does the order survive": the handle closing before the files are touched, every step
// still running after one failed, and the absence of anything that ends the process. The last one is checked
// against the interface's own method list, because a wipe that gained a `terminate()` would satisfy every runtime
// assertion below and still break ruling 2.

private class StorageWipeHost(
  var wasRunning: Boolean = true,
  var throwAt: Set<PopopxStorageWipeStep> = emptySet(),
  var files: List<File> = emptyList(),
  val trace: MutableList<String> = mutableListOf(),
) : PopopxStorageWipeHost {
  override suspend fun stopChat(): Boolean {
    trace.add("stopChat")
    if (PopopxStorageWipeStep.StopChat in throwAt) error("the chat would not stop")
    return wasRunning
  }

  override fun closeDatabaseStore() {
    trace.add("closeDatabaseStore")
    if (PopopxStorageWipeStep.CloseDatabase in throwAt) error("no controller")
  }

  override fun sensitiveFiles(): List<File> {
    trace.add("sensitiveFiles")
    if (PopopxStorageWipeStep.EraseFiles in throwAt) error("the paths are gone")
    return files
  }

  override fun clearSecrets() {
    trace.add("clearSecrets")
    if (PopopxStorageWipeStep.ClearSecrets in throwAt) error("the keystore is busy")
  }

  override fun cancelNotifications() {
    trace.add("cancelNotifications")
    if (PopopxStorageWipeStep.CancelNotifications in throwAt) error("no manager")
  }

  override suspend fun rebuild() {
    trace.add("rebuild")
    if (PopopxStorageWipeStep.Rebuild in throwAt) error("the controller would not come back")
  }
}

private fun tempDirectory(name: String): File =
  File(System.getProperty("java.io.tmpdir"), "popopx-wipe-$name-${System.nanoTime()}").apply { mkdirs() }

private fun File.writeSomeBytes(): File {
  parentFile?.mkdirs()
  writeBytes(ByteArray(512) { index -> (index % 251).toByte() })
  return this
}

class PopopxStorageWipeTest {
  @Test
  fun theSixStepsRunInThatOrderAndNothingElseIsTouched() {
    val host = StorageWipeHost()
    val report = kotlinx.coroutines.runBlocking { PopopxStorageWipe(host).execute() }
    assertEquals(
      listOf(
        PopopxStorageWipeStep.StopChat,
        PopopxStorageWipeStep.CloseDatabase,
        PopopxStorageWipeStep.EraseFiles,
        PopopxStorageWipeStep.ClearSecrets,
        PopopxStorageWipeStep.CancelNotifications,
        PopopxStorageWipeStep.Rebuild,
      ),
      report.entries.map { it.step },
    )
    assertEquals(
      listOf("stopChat", "closeDatabaseStore", "sensitiveFiles", "clearSecrets", "cancelNotifications", "rebuild"),
      host.trace,
    )
    assertTrue(report.isClean, report.summary())
    assertEquals(6, report.stepsCompleted)
  }

  @Test
  fun theDatabaseHandleClosesBeforeAnyFileIsOverwritten() {
    val host = StorageWipeHost()
    kotlinx.coroutines.runBlocking { PopopxStorageWipe(host).execute() }
    // Upstream's own comment is the authority: without `chatCloseStore` the OS can deny the database removal, and a
    // wipe that silently fails to remove the database reports success with every message still on the disk.
    assertTrue(host.trace.indexOf("closeDatabaseStore") < host.trace.indexOf("sensitiveFiles"), host.trace.joinToString())
  }

  @Test
  fun theDuressPathHasNoWayToExitTheProcess() {
    // Sorted, because `getDeclaredMethods` has no specified order and an order-dependent assertion here would be a
    // coin flip on a different JVM. The claim is only about which verbs the interface *has*.
    val names = PopopxStorageWipeHost::class.java.declaredMethods.map { it.name.lowercase() }.sorted()
    assertEquals(
      listOf("cancelnotifications", "clearsecrets", "closedatabasestore", "rebuild", "sensitivefiles", "stopchat"),
      names,
    )
    assertTrue(names.none { "exit" in it || "terminate" in it || "kill" in it }, names.joinToString())
  }

  @Test
  fun everyStepStillRunsAfterAnEarlierOneThrows() {
    val host = StorageWipeHost(throwAt = setOf(PopopxStorageWipeStep.StopChat, PopopxStorageWipeStep.ClearSecrets))
    val logs = mutableListOf<String>()
    val report = kotlinx.coroutines.runBlocking { PopopxStorageWipe(host, log = { logs.add(it) }).execute() }
    // The caller is a person standing over a phone who needs it finished; and a wipe that stops at the first failure
    // leaves the *rest* of the data intact, which is the worst of both outcomes.
    assertEquals(6, report.entries.size)
    assertEquals(
      listOf("stopChat", "closeDatabaseStore", "sensitiveFiles", "clearSecrets", "cancelNotifications", "rebuild"),
      host.trace,
    )
    assertFalse(report.isClean)
    assertEquals(4, report.stepsCompleted)
    assertFalse(report.entries[0].ok)
    assertEquals("the chat would not stop", report.entries[0].detail)
    assertFalse(report.entries[3].ok)
    assertEquals("the keystore is busy", report.entries[3].detail)
    // A failed step carries its reason and a successful one carries its own detail; both are the journal's only
    // evidence of which half of the device still has data in it.
    assertEquals("closed", report.entries[1].detail)
    // Only the per-step lines: the closing summary repeats `failed` for every broken step, so a plain `"failed" in it`
    // would count three lines for two failures.
    assertEquals(2, logs.count { it.startsWith("storage wipe step ") && "failed" in it }, logs.joinToString())
    assertTrue("storage wipe incomplete" in report.summary(), report.summary())
  }

  @Test
  fun aRefusedOverwriteMakesTheWipeNotCleanButDoesNotStopTheOtherFiles() {
    val directory = tempDirectory("erase")
    val erased = File(directory, "chat.db").writeSomeBytes()
    val wal = File(directory, "chat.db-wal").writeSomeBytes()
    // A non-empty directory named as a file cannot be unlinked, so the overwrite step reports the refusal — the
    // cheapest way to make `eraseFile` throw without changing permissions out from under another test.
    val undeletable = File(directory, "agent.db").apply { mkdirs(); File(this, "inside").writeSomeBytes() }
    val missing = File(directory, "nothing.db")
    val host = StorageWipeHost(files = listOf(erased, wal, undeletable, missing))
    val report = kotlinx.coroutines.runBlocking { PopopxStorageWipe(host).execute() }
    assertFalse(erased.exists())
    assertFalse(wal.exists(), "companions go with their main file even when a later entry fails")
    assertTrue(undeletable.exists())
    assertEquals(1, report.eraseFailures.size, report.eraseFailures.joinToString { it.message ?: "no message" })
    val failure = report.eraseFailures.single()
    assertEquals(PopopxSecureDeleter.Failure.Kind.WriteFailed, failure.kind)
    assertEquals(undeletable.path, failure.path)
    assertFalse(report.isClean, "a wipe that only unlinked some of the files must not be able to read as clean")
    assertEquals("overwrites refused=1", report.entries[2].detail)
    assertTrue("erase failures=1" in report.summary(), report.summary())
  }

  @Test
  fun aFileThatWasNeverThereIsNotAFailure() {
    val host = StorageWipeHost(files = listOf(File(tempDirectory("absent"), "chat.db")))
    val report = kotlinx.coroutines.runBlocking { PopopxStorageWipe(host).execute() }
    // Nothing to overwrite is the honest state of a device that never ran the chat, so `isClean` stays reachable —
    // unlike the refusal above, where bytes survived.
    assertEquals(emptyList<PopopxSecureDeleter.Failure>(), report.eraseFailures)
    assertTrue(report.isClean, report.summary())
  }

  @Test
  fun theJournalSaysWhetherTheChatWasRunning() {
    val running = kotlinx.coroutines.runBlocking { PopopxStorageWipe(StorageWipeHost(wasRunning = true)).execute() }
    assertEquals("was running", running.entries[0].detail)
    val stopped = kotlinx.coroutines.runBlocking { PopopxStorageWipe(StorageWipeHost(wasRunning = false)).execute() }
    assertEquals("was not running", stopped.entries[0].detail)
    assertTrue(stopped.isClean, "a wipe of an app that was not running is still a clean wipe")
  }

  @Test
  fun theSummaryIsLoggedOnceAtTheEndAndNamesEveryStep() {
    val logs = mutableListOf<String>()
    val host = StorageWipeHost(throwAt = setOf(PopopxStorageWipeStep.Rebuild))
    val report = kotlinx.coroutines.runBlocking { PopopxStorageWipe(host, log = { logs.add(it) }).execute() }
    val summary = logs.last()
    assertEquals(report.summary(), summary, "the log and the returned report are the same record")
    PopopxStorageWipeStep.entries.forEach { step -> assertTrue(step.name in summary, summary) }
    assertEquals(1, logs.count { it == summary })
    assertEquals("the controller would not come back", report.entries.last().detail)
  }

  @Test
  fun theReportDistinguishesAStepThatFailedFromOneThatRefused() {
    val host = StorageWipeHost(files = listOf(File(tempDirectory("both"), "chat.db").writeSomeBytes()))
    val report = kotlinx.coroutines.runBlocking { PopopxStorageWipe(host).execute() }
    assertTrue(report.entries.all { it.ok })
    assertEquals(emptyList<PopopxSecureDeleter.Failure>(), report.eraseFailures)
    // Clean means both: every step returned, and no overwrite refused. The two are different failures of different
    // promises, and a report that folded them together could not say which file survived.
    val withRefusal = kotlinx.coroutines.runBlocking {
      PopopxStorageWipe(
        StorageWipeHost(files = listOf(File(tempDirectory("both2"), "x").apply { mkdirs(); File(this, "y").writeSomeBytes() }))
      ).execute()
    }
    assertTrue(withRefusal.entries.all { it.ok })
    assertFalse(withRefusal.isClean)
    assertEquals("overwrites refused=1", withRefusal.entries[2].detail)
  }
}
