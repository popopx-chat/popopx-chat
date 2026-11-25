package chat.popopx.common.duress

import java.io.File

/**
 * The six-step panic wipe, and the three-tap gesture that arms it.
 *
 * Mirrors `PopopxPanicWipeManager` / `PopopxPanicWipeArming` / `PopopxMeshSecureDeleter`
 * (apps/ios/PopopxMeshKit/Sources/PopopxMeshUI/PanicWipeManager.swift). Two of the six steps cannot do on Android
 * what they do on iOS, and the ruling for this round was to keep the rank, the copy and the journal shape and
 * change only what is acted upon — see [PopopxPanicWipeStep.StopRadio] and [PopopxPanicWipeStep.OverwriteSandbox].
 * A step that silently disappeared would make the two platforms' journals incomparable, which is the one thing a
 * wipe record has to survive being.
 */

/** One step of the promised order. Declaration order *is* the order, so the rank cannot drift from the promise. */
enum class PopopxPanicWipeStep(val words: String) {
  /**
   * iOS waits for each radio component to confirm it turned off. An ordinary Android app is not allowed to switch
   * Bluetooth or the cellular radio off at all — that is a privileged operation — so this step stops what this app
   * *does* control: its outbound work. Deviation, stated rather than hidden.
   */
  StopRadio("stop Bluetooth"),

  ClearVolatileState("clear session keys"),
  EraseIdentityMapping("erase the identity map"),

  /** iOS overwrites the mesh sandbox, which Android does not have yet (phase 4); this phase's scratch does exist. */
  OverwriteSandbox("overwrite mesh files"),
  OverwriteApplicationDatabase("overwrite the chat database"),
  Terminate("close the app"),
  ;

  val rank: Int get() = entries.indexOf(this)

  companion object {
    fun ordered(): List<PopopxPanicWipeStep> = entries.toList()
  }
}

/**
 * What went wrong, and where.
 *
 * [KeyStep] is present because iOS declares and maps it although nothing in the iOS file ever constructs it
 * (B:120-140). Keeping it is the difference between a journal vocabulary that matches iOS's and one that is a
 * subset of it; a recorder that sees an unknown case later has nowhere to put the observation.
 */
sealed class PopopxPanicWipeFailure(open val path: String?, open val reason: String) {
  abstract val step: PopopxPanicWipeStep

  /** iOS's `keyStep` — declared, mapped, never emitted. See the class comment. */
  class KeyStep(reason: String) : PopopxPanicWipeFailure(null, reason) {
    override val step: PopopxPanicWipeStep get() = PopopxPanicWipeStep.ClearVolatileState
  }

  class RadioStep(reason: String) : PopopxPanicWipeFailure(null, reason) {
    override val step: PopopxPanicWipeStep get() = PopopxPanicWipeStep.StopRadio
  }

  class MappingStep(reason: String) : PopopxPanicWipeFailure(null, reason) {
    override val step: PopopxPanicWipeStep get() = PopopxPanicWipeStep.EraseIdentityMapping
  }

  class SandboxStep(path: String, reason: String) : PopopxPanicWipeFailure(path, reason) {
    override val step: PopopxPanicWipeStep get() = PopopxPanicWipeStep.OverwriteSandbox
  }

  class DatabaseStep(path: String, reason: String) : PopopxPanicWipeFailure(path, reason) {
    override val step: PopopxPanicWipeStep get() = PopopxPanicWipeStep.OverwriteApplicationDatabase
  }

  /**
   * The host asked for the database step but named no file. This is a distinct case from [DatabaseStep] because
   * it is a refusal, not an IO failure, and it must never be folded into success: iOS's rule is that the step
   * reports the refusal and leaves `didTouchApplicationDatabase` false.
   */
  class DatabaseStepRefused(reason: String) : PopopxPanicWipeFailure(null, reason) {
    override val step: PopopxPanicWipeStep get() = PopopxPanicWipeStep.OverwriteApplicationDatabase
  }
}

/** Everything the wipe says it did, in the order it said it. */
class PopopxPanicWipeJournal {
  val steps = mutableListOf<PopopxPanicWipeStep>()
  val erasedFiles = mutableListOf<String>()
  val failures = mutableListOf<PopopxPanicWipeFailure>()
  var didTouchApplicationDatabase: Boolean = false
}

/** What a caller is handed afterwards. */
class PopopxPanicWipeReport(
  val steps: List<PopopxPanicWipeStep>,
  val erasedFiles: List<String>,
  val failures: List<PopopxPanicWipeFailure>,
  val didTouchApplicationDatabase: Boolean,
) {
  val isClean: Boolean get() = failures.isEmpty()

  /** Strictly increasing, so the same step recorded twice is out of order — the only way a duplicated step shows. */
  val isInOrder: Boolean
    get() = steps.zipWithNext().all { (left, right) -> left.rank < right.rank }

  val summary: String
    get() = if (failures.isEmpty()) {
      "wiped ${steps.size} step(s), ${erasedFiles.size} file(s) overwritten"
    } else {
      "wiped ${steps.size} step(s), ${failures.size} failure(s)"
    }
}

/**
 * The effects a wipe is allowed to have, all of them the host's.
 *
 * Every method returns what it could not do rather than throwing, because the run must reach the end: iOS's
 * comment at B:525-526 is the reason — "a wipe that stopped halfway would report success for the part it did".
 */
interface PopopxPanicWipeHost {
  /** Step 1. Each returned string is something that was still running when the step finished. */
  fun stopOutbound(): List<String>

  /** Step 2. Null when the keys were burned; a reason when they were not. */
  fun burnKeys(): String?

  /** Step 2, second half: the in-memory mirrors, cleared with the keys rather than with the radio. */
  fun clearInMemoryMirrors(): List<String>

  /** Step 3. */
  fun eraseIdentityMapping(): List<String>

  /** Step 4: the directories whose contents are overwritten. */
  fun sandboxDirectories(): List<File>

  /** Step 5: the file, or null when the host asked for the step without naming one. */
  fun applicationDatabaseFile(): File?

  /**
   * Step 6. Absent means the process is still running with wiped keys, which iOS records as a failure rather
   * than as silence (`missingTerminationIsAFailure`).
   */
  fun termination(): ((Int) -> Unit)?
}

/** Where the journal goes. iOS has an empty default implementation and a silent recorder; both are kept. */
interface PopopxPanicWipeRecorder {
  fun didStart(step: PopopxPanicWipeStep) {}
  fun didFinish(step: PopopxPanicWipeStep, erasedFileCount: Int) {}
  fun didFail(failure: PopopxPanicWipeFailure, at: PopopxPanicWipeStep) {}
}

object PopopxPanicWipeSilentRecorder : PopopxPanicWipeRecorder

class PopopxPanicWipeManager(
  private val host: PopopxPanicWipeHost,
  private val deleter: PopopxSecureDeleter = PopopxSecureDeleter(),
  private val recorder: PopopxPanicWipeRecorder = PopopxPanicWipeSilentRecorder,
  private val log: (String) -> Unit = { },
) {
  private val journal = PopopxPanicWipeJournal()

  /** True for the whole run, so anything that could pile a second wipe on top of this one can refuse. */
  var isWiping: Boolean = false
    private set

  companion object {
    /**
     * A promise, in code: no interface in this package can ever ask for step 5.
     *
     * iOS states it at B:444-447 and asserts it in its own suite (`PopopxPanicWipeTests.swift:301-306`,
     * `interfaceCannotOptIn`): the only way the chat database is opened for overwriting is a host that calls
     * [execute] with `includeApplicationDatabase = true` itself, knowing the path. The Android UI never does, so
     * the value is false here and the test asserts that it is — the flag is the gate, not the UI.
     */
    const val INTERFACE_OPT_IN_TO_DATABASE_ERASE: Boolean = false

    /** The sentence the confirmation sheet shows, built from the same list the steps run in. */
    fun confirmationMessage(includeApplicationDatabase: Boolean): String {
      val parts = mutableListOf<String>()
      for (step in PopopxPanicWipeStep.ordered()) {
        if (step == PopopxPanicWipeStep.OverwriteApplicationDatabase && !includeApplicationDatabase) continue
        parts.add(step.words)
      }
      return "This will " + parts.joinToString(", ") + ". It cannot be undone."
    }
  }

  /**
   * Runs the six steps.
   *
   * There is deliberately no early return between them, and no `guard` that skips a step because an earlier one
   * failed: every step is attempted, and the failures are collected. The journal is written **before** the exit
   * is asked for — iOS's comment at B:545-552 is the reason, and it applies verbatim to `Log` on Android too: a
   * line written after `exitProcess(0)` has nothing guaranteeing it survives, and a panic wipe is exactly the
   * event someone reads the log for afterwards.
   */
  fun execute(includeApplicationDatabase: Boolean = INTERFACE_OPT_IN_TO_DATABASE_ERASE): PopopxPanicWipeReport {
    isWiping = true
    try {
      stopOutbound()
      clearVolatileState()
      eraseIdentityMapping()
      overwriteSandbox()
      if (includeApplicationDatabase) overwriteApplicationDatabase()
      val failures = journal.failures.toList()
      val steps = journal.steps.toList()
      val erased = journal.erasedFiles.toList()
      val touched = journal.didTouchApplicationDatabase
      // Before the termination, for the reason above.
      log(
        "panic wipe: ${steps.size} step(s) before the exit, ${erased.size} file(s) overwritten, " +
          "${failures.size} failure(s), chat database touched=$touched"
      )
      terminateProcess()
      // Re-read after the exit was asked for, not before: the terminate step and the failure that a missing
      // termination records both land in the journal *inside* `terminateProcess`, and a snapshot taken above would
      // report a clean five-step wipe for a process that is still running with its keys burned. When the host does
      // terminate, nothing past `termination(0)` runs, so this only ever executes on the test path.
      return PopopxPanicWipeReport(journal.steps.toList(), journal.erasedFiles.toList(), journal.failures.toList(), journal.didTouchApplicationDatabase)
    } finally {
      // Only reachable when the host supplied no termination, which is itself recorded as a failure.
      isWiping = false
    }
  }

  private fun begin(step: PopopxPanicWipeStep) {
    journal.steps.add(step)
    recorder.didStart(step)
  }

  private fun finish(step: PopopxPanicWipeStep, erasedFileCount: Int) {
    recorder.didFinish(step, erasedFileCount)
  }

  private fun record(failure: PopopxPanicWipeFailure, at: PopopxPanicWipeStep) {
    journal.failures.add(failure)
    recorder.didFail(failure, at)
  }

  private fun stopOutbound() {
    begin(PopopxPanicWipeStep.StopRadio)
    val reasons = runCatching { host.stopOutbound() }.getOrElse { listOf(it.message ?: "outbound stop failed") }
    for (reason in reasons) {
      record(PopopxPanicWipeFailure.RadioStep(reason), PopopxPanicWipeStep.StopRadio)
    }
    finish(PopopxPanicWipeStep.StopRadio, 0)
  }

  private fun clearVolatileState() {
    begin(PopopxPanicWipeStep.ClearVolatileState)
    val reason = runCatching { host.burnKeys() }.getOrElse { it.message ?: "keys could not be burned" }
    if (reason != null) record(PopopxPanicWipeFailure.KeyStep(reason), PopopxPanicWipeStep.ClearVolatileState)
    // A banner that still shows a peer after a wipe is a leak the user can see, which is why the mirrors are
    // cleared here with the keys and not with the radio.
    for (mirror in runCatching { host.clearInMemoryMirrors() }.getOrDefault(emptyList())) {
      record(PopopxPanicWipeFailure.KeyStep(mirror), PopopxPanicWipeStep.ClearVolatileState)
    }
    finish(PopopxPanicWipeStep.ClearVolatileState, 0)
  }

  private fun eraseIdentityMapping() {
    begin(PopopxPanicWipeStep.EraseIdentityMapping)
    for (reason in runCatching { host.eraseIdentityMapping() }.getOrElse { listOf(it.message ?: "mapping erase failed") }) {
      record(PopopxPanicWipeFailure.MappingStep(reason), PopopxPanicWipeStep.EraseIdentityMapping)
    }
    finish(PopopxPanicWipeStep.EraseIdentityMapping, 0)
  }

  private fun overwriteSandbox() {
    begin(PopopxPanicWipeStep.OverwriteSandbox)
    val directories = runCatching { host.sandboxDirectories() }.getOrElse {
      record(
        PopopxPanicWipeFailure.SandboxStep("", "sandbox locations unavailable: ${it.message ?: "unknown"}"),
        PopopxPanicWipeStep.OverwriteSandbox
      )
      emptyList()
    }
    var count = 0
    for (directory in directories) {
      val paths = runCatching { deleter.eraseDirectory(directory) }.getOrElse { error ->
        record(
          PopopxPanicWipeFailure.SandboxStep(
            directory.path,
            if (error is PopopxSecureDeleter.Failure) error.underlying else error.message ?: "erase failed"
          ),
          PopopxPanicWipeStep.OverwriteSandbox
        )
        null
      } ?: continue
      journal.erasedFiles.addAll(paths)
      count += paths.size
    }
    finish(PopopxPanicWipeStep.OverwriteSandbox, count)
  }

  private fun overwriteApplicationDatabase() {
    begin(PopopxPanicWipeStep.OverwriteApplicationDatabase)
    val file = runCatching { host.applicationDatabaseFile() }.getOrNull()
    if (file == null) {
      // Refusing is not succeeding, so this branch must not fall through to `finish` with a clean journal.
      record(
        PopopxPanicWipeFailure.DatabaseStepRefused(
          "the host asked for the chat database to be erased but gave no path; refusing rather than guessing"
        ),
        PopopxPanicWipeStep.OverwriteApplicationDatabase
      )
      return
    }
    journal.didTouchApplicationDatabase = true
    val erased = runCatching { deleter.eraseFile(file) }.getOrElse { error ->
      record(
        PopopxPanicWipeFailure.DatabaseStep(
          file.path,
          if (error is PopopxSecureDeleter.Failure) error.underlying else error.message ?: "erase failed"
        ),
        PopopxPanicWipeStep.OverwriteApplicationDatabase
      )
      return
    }
    if (erased) {
      journal.erasedFiles.add(file.path)
      finish(PopopxPanicWipeStep.OverwriteApplicationDatabase, 1)
    } else {
      record(
        PopopxPanicWipeFailure.DatabaseStep(file.path, "the database was not there to erase"),
        PopopxPanicWipeStep.OverwriteApplicationDatabase
      )
    }
  }

  private fun terminateProcess() {
    begin(PopopxPanicWipeStep.Terminate)
    val termination = runCatching { host.termination() }.getOrNull()
    if (termination == null) {
      // Kept exactly as iOS has it (B:665): a terminate failure recorded as `radioStep`, so
      // `failure.step` reads `.stopRadio` for something that happened at the exit. The mismatch is a bug in the
      // source, and a port that "fixed" it would leave the two platforms' journals disagreeing about the same
      // event — which is worse than reproducing it. Named in the commit message.
      record(
        PopopxPanicWipeFailure.RadioStep("host supplied no termination: the process is still running with wiped keys"),
        PopopxPanicWipeStep.Terminate
      )
      return
    }
    // No `finish` for this step, on purpose (B:650-660): a real exit does not return, so reporting that the
    // terminate step *completed* would tell a recorder something the process cannot do. The start entry above is
    // the last thing a real wipe ever writes.
    termination(0)
  }
}

/**
 * The three-tap gesture.
 *
 * Mirrors `PopopxPanicWipeArming` (B:360-431) branch for branch, because the interesting behaviour is what the
 * *fourth* tap does, and on iOS that falls out of the order of two branches rather than from a rule of its own.
 */
class PopopxPanicWipeArming {
  companion object {
    /** Seconds the whole sequence has to finish in, measured from the first tap. */
    const val TAP_WINDOW_SECONDS: Double = 1.0

    const val REQUIRED_TAPS: Int = 3

    /**
     * How long the confirmation stays answerable. Past that the user has stopped looking at the phone, and an
     * alert that wipes when finally tapped is not a confirmation (B:369-371). A **deadline**, not a countdown:
     * nothing ticks, the timestamp is simply compared when someone answers.
     */
    const val CONFIRM_LIFETIME_SECONDS: Double = 15.0

    /**
     * Wall clock, not a monotonic reading — the same choice iOS makes for its lockout record: these values are
     * compared across a process restart, where a monotonic clock stops meaning anything.
     */
    fun wallClockSeconds(): Double = System.currentTimeMillis() / 1000.0
  }

  var tapCount: Int = 0
    private set
  var firstTapAt: Double? = null
    private set
  var confirmationRequestedAt: Double? = null
    private set
  var isAwaitingConfirmation: Boolean = false
    private set

  /** One tap. Returns true only when the sequence reached exactly three inside the window. */
  fun tap(now: Double = PopopxPanicWipeArming.wallClockSeconds()): Boolean {
    // Tapping while the sheet is up is the "never mind" gesture: the sequence is abandoned, and the sheet itself
    // is the only thing that can start a wipe. This branch is also what a fourth tap hits, because the arming
    // path resets the counters before it sets the flag.
    if (isAwaitingConfirmation) {
      reset()
      return false
    }
    val first = firstTapAt
    if (first != null && now - first > TAP_WINDOW_SECONDS) {
      tapCount = 0
      firstTapAt = null
    }
    if (firstTapAt == null) firstTapAt = now
    tapCount += 1
    if (tapCount < REQUIRED_TAPS) return false
    val armed = tapCount == REQUIRED_TAPS
    reset()
    if (!armed) return false
    isAwaitingConfirmation = true
    confirmationRequestedAt = now
    return true
  }

  /** The user answered, either way, so nothing may stay armed. */
  fun resolveConfirmation() = reset()

  /** Consent has a shelf life: an expired sheet no longer means "yes" when it is finally tapped. */
  fun confirmationIsStillValid(now: Double = PopopxPanicWipeArming.wallClockSeconds()): Boolean {
    val requested = confirmationRequestedAt ?: return false
    if (!isAwaitingConfirmation) return false
    if (now - requested > CONFIRM_LIFETIME_SECONDS) {
      reset()
      return false
    }
    return true
  }

  fun reset() {
    tapCount = 0
    firstTapAt = null
    confirmationRequestedAt = null
    isAwaitingConfirmation = false
  }
}
