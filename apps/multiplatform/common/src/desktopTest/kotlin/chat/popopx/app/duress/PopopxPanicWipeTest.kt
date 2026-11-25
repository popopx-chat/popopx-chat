package chat.popopx.app.duress

import chat.popopx.common.duress.PopopxPanicWipeArming
import chat.popopx.common.duress.PopopxPanicWipeFailure
import chat.popopx.common.duress.PopopxPanicWipeHost
import chat.popopx.common.duress.PopopxPanicWipeManager
import chat.popopx.common.duress.PopopxPanicWipeRecorder
import chat.popopx.common.duress.PopopxPanicWipeReport
import chat.popopx.common.duress.PopopxPanicWipeStep
import chat.popopx.common.duress.PopopxSecureDeleter
import java.io.File
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The three-tap gesture and the six steps it opens.
//
// Ruling 2 keeps the rank, the copy and the journal shape and changes only what is acted upon, so most of what is
// asserted here is the *shape*: the order the steps are recorded in, that a step is never skipped because another
// failed, that the log line lands before the exit is asked for, and that step 5 cannot be reached through an
// interface. Where the two platforms must disagree — step 1's radio and step 4's sandbox — the tests assert the
// Android action, not the iOS one, so a future "fix" that quietly restores the iOS wording has to break a test.

private fun tempDirectory(name: String): File =
  File(System.getProperty("java.io.tmpdir"), "popopx-panic-$name-${System.nanoTime()}").apply { mkdirs() }

private fun File.writeBytesOf(count: Int): File {
  parentFile?.mkdirs()
  writeBytes(ByteArray(count) { index -> (index % 251).toByte() })
  return this
}

private class WipeHost(
  var outboundReasons: List<String> = emptyList(),
  var burnReason: String? = null,
  var mirrorReasons: List<String> = emptyList(),
  var mappingReasons: List<String> = emptyList(),
  var sandboxes: List<File> = emptyList(),
  var databaseFile: File? = null,
  var provideTermination: Boolean = true,
  var throwAtStopOutbound: Boolean = false,
  var throwAtSandbox: Boolean = false,
  val trace: MutableList<String> = mutableListOf(),
) : PopopxPanicWipeHost {
  var terminated: Int? = null
  var isWipingDuringExit: Boolean? = null

  /** Set by the test that wants to read the flag while the run is still going. */
  var probe: (() -> Boolean)? = null

  override fun stopOutbound(): List<String> {
    if (throwAtStopOutbound) error("the queue would not stop")
    trace.add("stopOutbound")
    return outboundReasons
  }

  override fun burnKeys(): String? {
    trace.add("burnKeys")
    return burnReason
  }

  override fun clearInMemoryMirrors(): List<String> {
    trace.add("mirrors")
    return mirrorReasons
  }

  override fun eraseIdentityMapping(): List<String> {
    trace.add("mapping")
    return mappingReasons
  }

  override fun sandboxDirectories(): List<File> {
    if (throwAtSandbox) error("no storage paths")
    trace.add("sandbox")
    return sandboxes
  }

  override fun applicationDatabaseFile(): File? {
    trace.add("database")
    return databaseFile
  }

  override fun termination(): ((Int) -> Unit)? {
    if (!provideTermination) return null
    return { code ->
      trace.add("exit")
      terminated = code
      isWipingDuringExit = probe?.invoke()
    }
  }
}

private class EventRecorder : PopopxPanicWipeRecorder {
  val events = mutableListOf<String>()

  override fun didStart(step: PopopxPanicWipeStep) {
    events.add("start:${step.name}")
  }

  override fun didFinish(step: PopopxPanicWipeStep, erasedFileCount: Int) {
    events.add("finish:${step.name}:$erasedFileCount")
  }

  override fun didFail(failure: PopopxPanicWipeFailure, at: PopopxPanicWipeStep) {
    events.add("fail:${at.name}:${failure::class.simpleName}")
  }
}

class PopopxPanicWipeTest {
  // MARK: the promise, in data

  @Test
  fun theRanksComeFromDeclarationOrderSoTheCopyCannotDrift() {
    assertEquals(
      listOf(
        PopopxPanicWipeStep.StopRadio,
        PopopxPanicWipeStep.ClearVolatileState,
        PopopxPanicWipeStep.EraseIdentityMapping,
        PopopxPanicWipeStep.OverwriteSandbox,
        PopopxPanicWipeStep.OverwriteApplicationDatabase,
        PopopxPanicWipeStep.Terminate,
      ),
      PopopxPanicWipeStep.ordered(),
    )
    assertEquals(0, PopopxPanicWipeStep.StopRadio.rank)
    assertEquals(5, PopopxPanicWipeStep.Terminate.rank)
    assertEquals(
      listOf("stop Bluetooth", "clear session keys", "erase the identity map", "overwrite mesh files", "overwrite the chat database", "close the app"),
      PopopxPanicWipeStep.ordered().map { it.words },
    )
  }

  @Test
  fun theConfirmationSentenceNamesTheDatabaseOnlyWhenTheDatabaseIsNamed() {
    val without = PopopxPanicWipeManager.confirmationMessage(false)
    val with = PopopxPanicWipeManager.confirmationMessage(true)
    assertFalse("overwrite the chat database" in without, without)
    assertTrue("overwrite the chat database" in with, with)
    assertTrue(without.endsWith(". It cannot be undone."), without)
    assertTrue(PopopxPanicWipeStep.ordered().all { it.words in with }, with)
    assertTrue("close the app" in without, without)
    // The sentence has to promise everything the run will actually do: a consent sheet that leaves a step out is
    // the one place where a rank that exists in code and not in words becomes a lie. One clause per step, so the
    // counts are the check that nothing is named twice and nothing is missing.
    assertEquals(5, without.split(", ").size, without)
    assertEquals(6, with.split(", ").size, with)
  }

  @Test
  fun noInterfaceCanAskForTheDatabaseStep() {
    // Ruling 2, as an assertion rather than a comment: step 5's capability and tests exist, and the flag that opens
    // it stays false so that nothing mounted in the UI can reach it.
    assertFalse(PopopxPanicWipeManager.INTERFACE_OPT_IN_TO_DATABASE_ERASE)
    val host = WipeHost()
    val report = PopopxPanicWipeManager(host).execute()
    assertFalse(PopopxPanicWipeStep.OverwriteApplicationDatabase in report.steps, report.steps.joinToString())
    assertFalse("database" in host.trace, "the host was not even asked for the path: ${host.trace}")
    assertFalse(report.didTouchApplicationDatabase)
  }

  // MARK: a run

  @Test
  fun aCleanRunRecordsEveryStepOnceInOrderAndExitsWithZero() {
    val host = WipeHost()
    val logs = mutableListOf<String>()
    val manager = PopopxPanicWipeManager(host, log = { logs.add(it) })
    host.probe = { manager.isWiping }
    val report = manager.execute()
    assertEquals(
      listOf(
        PopopxPanicWipeStep.StopRadio,
        PopopxPanicWipeStep.ClearVolatileState,
        PopopxPanicWipeStep.EraseIdentityMapping,
        PopopxPanicWipeStep.OverwriteSandbox,
        PopopxPanicWipeStep.Terminate,
      ),
      report.steps,
    )
    assertTrue(report.isClean, report.failures.joinToString { it.reason })
    assertTrue(report.isInOrder)
    assertEquals(0, host.terminated)
    assertEquals(true, host.isWipingDuringExit, "the flag has to still be raised at the exit, or a re-entrant wipe is possible")
    assertFalse(manager.isWiping, "and released once the run is over")
    assertEquals(1, logs.size)
    // Four, not five: the database step is the one this interface does not opt into, and the log counts the steps that
    // actually ran. The report carries the fifth entry (`Terminate`), which the journal only receives inside
    // `terminateProcess`.
    assertTrue("4 step(s) before the exit" in logs.single(), logs.single())
    assertTrue("chat database touched=false" in logs.single(), logs.single())
  }

  @Test
  fun theLogLineIsWrittenBeforeTheExitIsAskedFor() {
    val host = WipeHost()
    PopopxPanicWipeManager(host, log = { host.trace.add("log") }).execute()
    // The exit hook appends to the same list, so this one comparison *is* the sequence claim: a line written after
    // `exitProcess(0)` has nothing guaranteeing it survives, and a panic wipe is exactly the event someone reads
    // the log for afterwards.
    assertEquals(listOf("log", "exit"), host.trace.takeLast(2), host.trace.joinToString())
  }

  @Test
  fun everyStepRunsAfterAnEarlierOneFails() {
    val host = WipeHost(throwAtStopOutbound = true, burnReason = "no key to burn", mappingReasons = listOf("map is open"))
    val recorder = EventRecorder()
    val report = PopopxPanicWipeManager(host, recorder = recorder).execute()
    // A wipe that stopped halfway would report success for the part it did, so the run goes to the end and the
    // failures are collected instead.
    assertEquals(listOf("burnKeys", "mirrors", "mapping", "sandbox", "exit"), host.trace, host.trace.joinToString())
    assertFalse(report.isClean)
    assertEquals(3, report.failures.size, report.failures.joinToString { it.reason })
    assertEquals(
      listOf(
        PopopxPanicWipeStep.StopRadio,
        PopopxPanicWipeStep.ClearVolatileState,
        PopopxPanicWipeStep.EraseIdentityMapping,
        PopopxPanicWipeStep.OverwriteSandbox,
        PopopxPanicWipeStep.Terminate,
      ),
      report.steps,
    )
    assertTrue(report.isInOrder)
    assertTrue(recorder.events.contains("fail:StopRadio:RadioStep"), recorder.events.joinToString())
    assertTrue(recorder.events.contains("fail:ClearVolatileState:KeyStep"), recorder.events.joinToString())
    assertTrue(recorder.events.contains("fail:EraseIdentityMapping:MappingStep"), recorder.events.joinToString())
    assertEquals("the queue would not stop", report.failures[0].reason, "the thrown reason is carried, not invented")
  }

  @Test
  fun aHostThatSuppliesNoTerminationIsAFailureNotSilence() {
    val host = WipeHost(provideTermination = false)
    val report = PopopxPanicWipeManager(host).execute()
    assertNull(host.terminated)
    assertFalse(report.isClean, "the process is still running with wiped keys, which is the worst state to leave quietly")
    assertFalse(host.isWipingDuringExit == true)
    val failure = report.failures.single()
    assertTrue(failure is PopopxPanicWipeFailure.RadioStep)
    // iOS records it as `radioStep` even though it happened at the exit (B:665). The mismatch is a bug in the
    // source; reproducing it is what keeps the two platforms' journals comparable about the same event.
    assertEquals(PopopxPanicWipeStep.StopRadio, failure.step)
    assertEquals(5, report.steps.size, "the terminate step is begun even when nothing can complete it")
    assertEquals(PopopxPanicWipeStep.Terminate, report.steps.last())
  }

  @Test
  fun theTerminateStepIsStartedButNeverFinished() {
    val recorder = EventRecorder()
    PopopxPanicWipeManager(WipeHost(), recorder = recorder).execute()
    assertTrue(recorder.events.contains("start:Terminate"), recorder.events.joinToString())
    assertFalse(recorder.events.any { it.startsWith("finish:Terminate") }, recorder.events.joinToString())
    // A real exit does not return, so telling a recorder the step *completed* would report something the process
    // cannot know. The last thing a real wipe writes is its start.
    assertEquals("start:Terminate", recorder.events.last())
  }

  @Test
  fun aReportWithTheSameStepTwiceIsOutOfOrder() {
    val duplicated = PopopxPanicWipeReport(
      listOf(PopopxPanicWipeStep.Terminate, PopopxPanicWipeStep.StopRadio),
      emptyList(),
      listOf(PopopxPanicWipeFailure.KeyStep("x")),
      false,
    )
    assertFalse(duplicated.isInOrder)
    assertEquals("wiped 2 step(s), 1 failure(s)", duplicated.summary)
    val ascending = PopopxPanicWipeReport(PopopxPanicWipeStep.ordered(), listOf("a", "b"), emptyList(), false)
    assertTrue(ascending.isInOrder)
    assertEquals("wiped 6 step(s), 2 file(s) overwritten", ascending.summary)
  }

  // MARK: step 5, the three branches

  @Test
  fun theDatabaseStepWithAPathOverwritesTheFileAndNamesItInTheJournal() {
    val directory = tempDirectory("db")
    val database = File(directory, "chat.db").writeBytesOf(4096)
    val wal = File(directory, "chat.db-wal").writeBytesOf(128)
    val host = WipeHost(databaseFile = database)
    val report = PopopxPanicWipeManager(host).execute(true)
    assertTrue(report.didTouchApplicationDatabase)
    assertFalse(database.exists())
    // The SQLCipher companions go with the main file: a `-wal` holds pages that are not in the database yet, so
    // erasing only the main file leaves readable chat rows behind.
    assertFalse(wal.exists())
    assertTrue(report.erasedFiles.contains(database.path), report.erasedFiles.joinToString())
    assertEquals(6, report.steps.size, report.steps.joinToString())
    assertEquals(PopopxPanicWipeStep.OverwriteApplicationDatabase, report.steps[4])
    assertTrue(report.isClean, report.failures.joinToString { it.reason })
    assertTrue("database" in host.trace, "the host was asked for the path: ${host.trace}")
  }

  @Test
  fun theDatabaseStepWithoutAPathRefusesAndCountsAsNeitherSuccessNorSilence() {
    val host = WipeHost(databaseFile = null)
    val report = PopopxPanicWipeManager(host).execute(true)
    // Ruling 2's third branch: asked for, no path. `didTouchApplicationDatabase` must stay false, because a step
    // that reports the refusal and then reads as having touched the file is the one mistake this branch can make.
    assertFalse(report.didTouchApplicationDatabase)
    assertFalse(report.isClean)
    val failure = report.failures.single()
    assertTrue(failure is PopopxPanicWipeFailure.DatabaseStepRefused, failure::class.simpleName!!)
    assertEquals(PopopxPanicWipeStep.OverwriteApplicationDatabase, failure.step)
    assertNull(failure.path, "a refusal has no file to name")
    assertTrue(PopopxPanicWipeStep.Terminate in report.steps, "the refusal returns from the step, it does not abort the run")
  }
  @Test
  fun theDatabaseStepOnAFileThatIsNotThereReportsTheAbsenceRatherThanACleanErase() {
    val host = WipeHost(databaseFile = File(tempDirectory("missing"), "nope.db"))
    val report = PopopxPanicWipeManager(host).execute(true)
    assertEquals(1, report.failures.size)
    val failure = report.failures.single()
    assertTrue(failure is PopopxPanicWipeFailure.DatabaseStep)
    assertEquals("the database was not there to erase", failure.reason)
    assertTrue(report.didTouchApplicationDatabase, "it was asked to touch it, and the truth is that the file was gone")
    assertEquals(emptyList<String>(), report.erasedFiles)
  }

  // MARK: step 4, the sandbox that actually exists

  @Test
  fun theSandboxStepOverwritesEveryFileItFindsAndCountsThem() {
    val media = tempDirectory("media")
    File(media, "photo.jpg").writeBytesOf(1024)
    File(media, "nested/deep.bin").writeBytesOf(2048)
    val unpacked = tempDirectory("unpacked")
    File(unpacked, "a.txt").writeBytesOf(16)
    val host = WipeHost(sandboxes = listOf(media, unpacked))
    val recorder = EventRecorder()
    val report = PopopxPanicWipeManager(host, recorder = recorder).execute()
    assertEquals(3, report.erasedFiles.size, report.erasedFiles.joinToString())
    assertTrue(recorder.events.contains("finish:OverwriteSandbox:3"), recorder.events.joinToString())
    assertFalse(File(media, "photo.jpg").exists())
    assertFalse(File(media, "nested/deep.bin").exists())
    assertFalse(File(media, "nested").exists(), "a directory is removed only after its contents, so this proves the order")
    assertFalse(media.exists(), "the tree is promised gone, not only emptied")
    assertTrue(report.isClean, report.failures.joinToString { it.reason })
  }

  @Test
  fun aSandboxThatWasNeverCreatedIsAnAbsentStepRatherThanAFailure() {
    val host = WipeHost(sandboxes = listOf(File(tempDirectory("gone"), "never-created")))
    val report = PopopxPanicWipeManager(host).execute()
    // A missing directory is the honest answer for a device that never used the feature, so it is *not* a failure.
    assertTrue(report.isClean, report.failures.joinToString { it.reason })
    assertEquals(emptyList<String>(), report.erasedFiles)
  }

  @Test
  fun aSandboxLocationThatThrowsIsRecordedAndTheRunContinues() {
    val host = WipeHost(throwAtSandbox = true)
    val report = PopopxPanicWipeManager(host).execute()
    val failure = report.failures.single()
    assertTrue(failure is PopopxPanicWipeFailure.SandboxStep)
    assertTrue("sandbox locations unavailable" in failure.reason, failure.reason)
    assertEquals("", failure.path, "there is no path to name when the paths themselves could not be read")
    assertTrue(PopopxPanicWipeStep.Terminate in report.steps)
  }

  // MARK: the deleter

  @Test
  fun theTwoPassesAreZerosThenNoiseAtSixtyFourKibibytes() {
    val deleter = PopopxSecureDeleter(Random(7))
    assertEquals(64 * 1024, PopopxSecureDeleter.PATTERN_BYTE_COUNT)
    assertTrue(deleter.passBuffer(4096, false).all { it == 0.toByte() })
    assertFalse(deleter.passBuffer(4096, true).all { it == 0.toByte() }, "one pass leaves a pattern whose boundary is the file's old length")
    assertEquals(0, deleter.passBuffer(0, true).size)
    assertEquals(100, deleter.passBuffer(100, false).size)
  }

  @Test
  fun theCompanionSuffixesAreTheOnesSqlCipherWrites() {
    assertEquals(listOf("-wal", "-shm", "-journal"), PopopxSecureDeleter.COMPANION_SUFFIXES)
    assertEquals(
      listOf("/tmp/chat.db-wal", "/tmp/chat.db-shm", "/tmp/chat.db-journal"),
      PopopxSecureDeleter().companionFiles(File("/tmp/chat.db")).map { it.path },
    )
  }

  @Test
  fun erasingAFileTakesItsCompanionsWithItAndLeavesTheRestOfTheDirectory() {
    val directory = tempDirectory("companions")
    val main = File(directory, "chat.db").writeBytesOf(70_000)
    val wal = File(directory, "chat.db-wal").writeBytesOf(8)
    val shm = File(directory, "chat.db-shm").writeBytesOf(8)
    val journal = File(directory, "chat.db-journal").writeBytesOf(8)
    val others = File(directory, "prefs.txt").writeBytesOf(8)
    assertTrue(PopopxSecureDeleter().eraseFile(main))
    listOf(main, wal, shm, journal).forEach { assertFalse(it.exists(), it.name) }
    assertTrue(others.exists(), "erasing one file must not sweep the directory")
    assertFalse(PopopxSecureDeleter().eraseFile(main), "a second pass over a gone file answers 'nothing was erased'")
  }

  @Test
  fun aDirectorySweepSkipsCompanionSuffixedPathsAndReachesThemOnlyThroughTheirMainFile() {
    val root = tempDirectory("tree")
    val database = File(root, "db/chat.db").writeBytesOf(64)
    val wal = File(root, "db/chat.db-wal").writeBytesOf(64)
    val deep = File(root, "db/nested/deep/x.bin").writeBytesOf(64)
    val erased = PopopxSecureDeleter().eraseDirectory(root)
    // Compared sorted: the walk is deepest-first, but the order of two *siblings* is whatever the filesystem
    // returns, and asserting it would be asserting a JDK detail.
    assertEquals(listOf(deep.path, database.path).sorted(), erased.sorted(), erased.joinToString())
    assertFalse(wal.exists(), "erased together with chat.db, not by the sweep")
    assertFalse(File(root, "db/nested").exists())
    assertFalse(root.exists(), "the root is removed once it is empty")
  }

  @Test
  fun anOrphanCompanionSurvivesTheSweepAndMakesTheDirectoryReportItselfAsUnusable() {
    val root = tempDirectory("orphan")
    val wal = File(root, "db/chat.db-wal").writeBytesOf(64)
    val failure = assertFailsWith<PopopxSecureDeleter.Failure> { PopopxSecureDeleter().eraseDirectory(root) }
    // The orphan `-wal` surviving is the deviation carried over on purpose (B:310) — but the consequence is stated
    // rather than hidden: a directory that survives its own removal *is* reported, so the wipe's journal cannot read
    // as clean while a file with chat rows in it is still on the device.
    assertTrue(wal.exists())
    assertEquals(PopopxSecureDeleter.Failure.Kind.DirectoryUnusable, failure.kind)
    assertEquals(root.path, failure.path)
    val report = PopopxPanicWipeManager(WipeHost(sandboxes = listOf(root))).execute()
    assertEquals(1, report.failures.size)
    val sandboxFailure = report.failures.single()
    assertTrue(sandboxFailure is PopopxPanicWipeFailure.SandboxStep)
    assertEquals(root.path, sandboxFailure.path)
  }

  // MARK: the gesture

  @Test
  fun threeTapsInsideTheWindowArmTheSheet() {
    val arming = PopopxPanicWipeArming()
    assertFalse(arming.tap(100.0))
    assertFalse(arming.tap(100.3))
    assertTrue(arming.tap(100.6))
    assertTrue(arming.isAwaitingConfirmation)
    assertEquals(100.6, arming.confirmationRequestedAt!!, 0.0001)
    assertEquals(0, arming.tapCount, "arming resets the counters before it raises the flag")
    assertNull(arming.firstTapAt)
  }

  @Test
  fun aFourthTapCancelsInsteadOfStartingASecondSequence() {
    val arming = PopopxPanicWipeArming()
    arming.tap(0.0)
    arming.tap(0.1)
    assertTrue(arming.tap(0.2))
    // The interesting behaviour falls out of the order of two branches: the arming path resets before it sets the
    // flag, so the fourth tap hits "awaiting" and abandons the sequence rather than counting toward a new one.
    assertFalse(arming.tap(0.3))
    assertFalse(arming.isAwaitingConfirmation)
    assertNull(arming.confirmationRequestedAt)
    assertEquals(0, arming.tapCount)
  }

  @Test
  fun tappingWhileTheSheetIsUpIsTheNeverMindGesture() {
    val arming = PopopxPanicWipeArming()
    arming.tap(0.0)
    arming.tap(0.1)
    arming.tap(0.2)
    assertTrue(arming.isAwaitingConfirmation)
    assertFalse(arming.tap(5.0))
    assertFalse(arming.isAwaitingConfirmation)
    // The sheet is the only thing that can start a wipe, so an abandoned sequence cannot be resumed.
    assertFalse(arming.confirmationIsStillValid(5.0))
  }

  @Test
  fun aSlowSequenceIsNotThreeTaps() {
    val arming = PopopxPanicWipeArming()
    assertFalse(arming.tap(0.0))
    assertFalse(arming.tap(1.5), "beyond the window the first tap is forgotten")
    assertEquals(1, arming.tapCount, "the stale burst was discarded and this tap started a new one")
    assertEquals(1.5, arming.firstTapAt!!, 0.0001)
    assertFalse(arming.tap(2.0))
    assertTrue(arming.tap(2.1))
    assertEquals(1.0, PopopxPanicWipeArming.TAP_WINDOW_SECONDS, 0.0001)
    assertEquals(3, PopopxPanicWipeArming.REQUIRED_TAPS)
  }

  @Test
  fun tapsSpreadOverTheWindowArmOnTheSecondBurst() {
    // The window is measured from the first tap of the *current* burst, so a late tap resets mid-sequence and the
    // next two complete it. Asserted because an off-by-one here is the difference between the gesture being
    // forgiving and it being unreachable.
    val arming = PopopxPanicWipeArming()
    assertFalse(arming.tap(0.0))
    assertFalse(arming.tap(3.0))
    assertFalse(arming.tap(3.2))
    assertTrue(arming.tap(3.4))
    assertTrue(arming.isAwaitingConfirmation)
  }

  @Test
  fun theConfirmationHasADeadlineNotACountdown() {
    val arming = PopopxPanicWipeArming()
    arming.tap(0.0)
    arming.tap(0.1)
    arming.tap(0.2)
    assertTrue(arming.confirmationIsStillValid(0.2))
    assertTrue(arming.confirmationIsStillValid(15.19))
    assertFalse(arming.confirmationIsStillValid(15.3), "an alert that wipes when finally tapped is not a confirmation")
    assertFalse(arming.isAwaitingConfirmation, "and the expiry disarms, so a late tap on the sheet has nothing to authorise")
    assertFalse(arming.confirmationIsStillValid(1.0), "a disarmed sequence cannot be revived by asking again")
    assertEquals(15.0, PopopxPanicWipeArming.CONFIRM_LIFETIME_SECONDS, 0.0001)
  }

  @Test
  fun answeringTheSheetResetsEverythingRegardlessOfTheAnswer() {
    val arming = PopopxPanicWipeArming()
    arming.tap(0.0)
    arming.tap(0.05)
    arming.tap(0.1)
    arming.resolveConfirmation()
    assertFalse(arming.isAwaitingConfirmation)
    assertNull(arming.confirmationRequestedAt)
    assertEquals(0, arming.tapCount)
    // Nothing may stay armed once the user answered, either way.
    assertFalse(arming.confirmationIsStillValid(0.1))
  }

  @Test
  fun aTapWithNoHistoryStartsFromTheCurrentTime() {
    val arming = PopopxPanicWipeArming()
    assertFalse(arming.tap(50.0))
    assertEquals(50.0, arming.firstTapAt!!, 0.0001)
    arming.reset()
    assertNull(arming.firstTapAt)
    assertFalse(arming.tap(1_000.0))
    assertEquals(1_000.0, arming.firstTapAt!!, 0.0001)
  }
}
