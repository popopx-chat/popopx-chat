package chat.popopx.common.duress

import chat.popopx.common.model.AppPreferences
import chat.popopx.common.platform.settings
import chat.popopx.common.views.helpers.DatabaseUtils
import chat.popopx.common.views.helpers.LAResult
import chat.popopx.common.views.usersettings.LAMode
import com.russhwolf.settings.Settings
import kotlin.random.Random
import kotlinx.coroutines.delay

/** The answer to a code attempt that carries no extra data. */
enum class PopopxDuressOutcome {
  /** No normal record exists, so nothing was checked. */
  NotConfigured,

  Unlocked,

  /** The duress code: the caller runs the erasure. */
  Duress,
  Wrong,
}

/**
 * The answer to a lock-screen attempt.
 *
 * Split from [PopopxDuressOutcome] because the cooldown branch has to carry the remaining seconds, and an enum
 * cannot — the UI would otherwise have to ask the manager for the clock again and race with its own answer.
 */
sealed class PopopxDuressAttempt {
  data object NotConfigured : PopopxDuressAttempt()
  data object Unlocked : PopopxDuressAttempt()
  data object Duress : PopopxDuressAttempt()
  data object Wrong : PopopxDuressAttempt()
  data class LockedOut(val remainingSeconds: Double) : PopopxDuressAttempt()
}

/** Why a setup or reveal step refused. The UI maps these to localized copy; tests assert the kind. */
class PopopxDuressSetupError(val kind: Kind, cause: String? = null) : Exception("$kind${cause?.let { ": $it" } ?: ""}") {
  enum class Kind {
    MalformedPin,
    PinsMustDiffer,
    NormalPinRequiredFirst,
    EntryPinRequired,
    EntryPinIncorrect,
    NativePasscodeRequired,
    NativePasscodeIncorrect,
    NativeSelfDestructCodeRequired,
    NativeSelfDestructCodeIncorrect,

    /**
     * Also the case iOS throws when the duress switch is off (`setDuressPin` at A:1373 — `guard duressEnabled else {
     * throw .keychainWriteFailed }`). Reusing a write-failure case for a refusal is iOS's own sloppiness; it is
     * kept rather than improved because the UI must show *something*, and inventing a distinct case here would make
     * the two platforms' error surfaces incomparable.
     */
    KeychainWriteFailed,

    /** Raised by the biometric gate, which is a different thing from a wrong code. */
    BiometricDenied,
  }
}

/**
 * The duress authentication engine: two codes, one escalating cooldown, and a tenth attempt that may wipe.
 *
 * Mirrors `PopopxDuressAuthManager` (apps/ios/Shared/Features/AntiTheftDuress/PopopxDuressAuthManager.swift).
 * Everything that makes this more than "compare a string" is in the ordering of the steps below, so the ordering is
 * what the tests assert; a single reordered line turns either a duress code into an unlock or a brute-force attempt
 * into a free one.
 *
 * Not mounted on desktop, and the whole class is inert there: the lock screen that calls it is Android-only.
 */
class PopopxDuressAuthManager(
  private val kv: PopopxDuressKv,
  /** The three switches, read with iOS's asymmetric defaults. */
  private val defaults: Settings = settings,
  /** Seconds since the epoch. Injectable so a cooldown can be crossed without waiting for one. */
  private val now: () -> Double = { System.currentTimeMillis() / 1000.0 },
  /**
   * The derivation seam. Production is [PopopxDuressCrypto.pbkdf2Sha256]; a test replaces it with a counter, which is
   * the only way to prove the claim that [verify] does constant work — the wall-clock difference between one and two
   * derivations is not measurable inside a test that must also stay fast.
   */
  private val derive: (password: String, salt: ByteArray, iterations: Int) -> ByteArray =
    { password, salt, iterations -> PopopxDuressCrypto.pbkdf2Sha256(password, salt, iterations, PopopxDuressCrypto.HASH_BYTES) },
  private val sleep: suspend (Double) -> Unit = { seconds -> delay((seconds * 1000).toLong()) },
  private val random: () -> Double = { Random.nextDouble() },
  /**
   * The device's biometric prompter, resolved per call.
   *
   * One seam rather than a boolean, because availability and prompting must be answered by the same object: a test
   * that injected only `available()` would leave [requestBiometricUnlock] reading the platform `expect`, whose desktop
   * actual answers `false` unconditionally — so the routing rule below would be testable while the thing it routes to
   * was not. iOS builds a fresh `LAContext()` inside each call (A:1521, A:2071) rather than keeping one, so resolving a
   * prompter per call is the same convention, and it also survives the activity changing under a rotation.
   */
  private val biometrics: () -> PopopxDuressBiometrics = { popopxDuressBiometrics() },
  private val log: (String) -> Unit = { },
) {
  companion object {
    /**
     * The floor a code attempt must take, whatever the answer was.
     *
     * iOS derives the reason for the floor at A:1074 and A:321-323: one 100,000-round derivation measured 355 ms on
     * the author's machine, so the fixed two derivations of [verify] take about 0.7 s, and 1.2 s is the budget that
     * leaves room for the slower path. The floor is what makes "wrong code" and "right code" indistinguishable by
     * timing; without it, an attacker learns which attempts hit from how long the screen thinks.
     */
    const val MINIMUM_FLOW_SECONDS: Double = 1.2

    /** Drawn before the verdict is known, so the random number cannot leak which branch was taken. */
    const val FLOW_JITTER_SECONDS: Double = 1.2

    /** Only ever downgraded — biometrics failing sends the user to the keypad, never to a weaker proof. */
    const val MAX_BIOMETRIC_FAILURES_BEFORE_KEYPAD: Int = 2

    /** Six digits, which is also what makes the duress code typeable one-handed. */
    const val PIN_LENGTH: Int = 6

    /**
     * The one shape a code may have.
     *
     * Public because the keypad gates its confirm key with exactly this predicate (A:279, A:1202): a second copy of
     * the rule in the UI is the drift class — a keypad that accepts five digits and an engine that rejects them is a
     * screen that can only ever answer "wrong".
     */
    fun isValidPin(pin: String): Boolean = pin.length == PIN_LENGTH && pin.all { it in '0'..'9' }

    const val KEY_DURESS_ENABLED: String = "antiTheftDuressEnabled"
    const val KEY_BIOMETRICS_ENABLED: String = "antiTheftBiometricsEnabled"
    const val KEY_TEN_STRIKE_WIPE: String = "antiTheftTenStrikeWipe"

    /**
     * iOS's `PopopxDuressAuthManager.shared` equivalent: the one instance the lock screen, the settings entry and the
     * wipe all talk to, so the cooldown and the biometric debt are not three separate copies of the same state.
     *
     * `by lazy`, because constructing it reads the Keystore-backed records: on desktop nothing ever touches this, and
     * a desktop process must not pay for a feature it does not mount.
     */
    val shared: PopopxDuressAuthManager by lazy { PopopxDuressAuthManager(PopopxDuressKvImpl(settings)) }
  }

  /**
   * Read as "absent means true", and that asymmetry is deliberate (A:1168-1176): the two feature switches default on,
   * while `wipeOnTenthFailure` is a plain `bool(forKey:)`, because "wiping data is the tier that turns ten misfires
   * into an irreversible action, so when the key does not exist it can only be false".
   */
  var duressEnabled: Boolean = absentThenTrue(KEY_DURESS_ENABLED)
    set(value) {
      if (field == value) return
      field = value
      defaults.putBoolean(KEY_DURESS_ENABLED, value)
      if (!value) {
        // "Switch turned off but the code still kept" is, in iOS's words, the most dangerous state of all: the record
        // stays armed for someone who no longer believes the feature exists. Deleting it here is also what makes
        // `duressConfigured` honest without a second flag.
        kv.delete(PopopxDuressAccounts.DURESS)
        duressConfigured = false
      }
    }

  var biometricsEnabled: Boolean = absentThenTrue(KEY_BIOMETRICS_ENABLED)
    set(value) {
      if (field == value) return
      field = value
      defaults.putBoolean(KEY_BIOMETRICS_ENABLED, value)
      if (value) {
        // Turning biometrics back on clears the debt accumulated while it was off, but not any lockout.
        biometricFailures = 0
        keypadRequired = false
      }
    }

  /** Absent means **false**. See [duressEnabled]. */
  var wipeOnTenthFailure: Boolean = defaults.getBoolean(KEY_TEN_STRIKE_WIPE, false)
    set(value) {
      if (field == value) return
      field = value
      defaults.putBoolean(KEY_TEN_STRIKE_WIPE, value)
    }

  var normalConfigured: Boolean = false
    private set
  var duressConfigured: Boolean = false
    private set
  var failedAttemptCount: Int = 0
    private set
  var lockoutEndsAt: Double? = null
    private set
  var biometricFailures: Int = 0
    private set
  var keypadRequired: Boolean = false
    private set

  /** True for the duration of a duress wipe, so a second attempt cannot pile on top of the first. */
  private var duressFlowInFlight = false

  init {
    refreshConfiguration()
  }

  /**
   * Re-reads what is configured.
   *
   * "Configured" is the **existence of the key**, not the existence of a record that parses (A:1187-1188), and
   * `duressConfigured` is ANDed with the switch. The consequence of the first part is worth stating, because it looks
   * like a hole and is not: a normal record that cannot be decoded leaves `normalConfigured` true, so [verify] runs
   * its two derivations against the pads and answers `.wrong` forever. That is fail-closed — a corrupt record cannot
   * be talked into unlocking — while "not configured" would have invited the keypad to silently rebuild a code
   * nobody set.
   *
   * A lockout read failure leaves the in-memory values alone rather than zeroing them (A:1191-1197): "reading it as
   * 'never failed' hands out 4 free attempts… So staying locked is preferred."
   */
  fun refreshConfiguration() {
    normalConfigured = kv.exists(PopopxDuressAccounts.NORMAL)
    duressConfigured = duressEnabled && kv.exists(PopopxDuressAccounts.DURESS)
    val record = PopopxDuressCodec.decodeLockout(kv.read(PopopxDuressAccounts.LOCKOUT)) ?: return
    failedAttemptCount = record.failedAttempts
    // Loaded raw, with no "past means none" clamp — `isLockedOut` compares against the clock, so a record whose
    // deadline passed still says how many strikes there were. Zeroing it here would be the free-attempts bug.
    lockoutEndsAt = record.lockoutEndTimestamp
  }

  val isLockedOut: Boolean get() = (lockoutEndsAt?.let { it > now() } ?: false)

  val remainingLockoutSeconds: Double get() = ((lockoutEndsAt ?: 0.0) - now()).coerceAtLeast(0.0)

  /**
   * The one check the lock screen uses to decide whether to open with biometrics or go straight to the keypad.
   *
   * Five terms, in iOS's order (A:1162-1164). `!isLockedOut` is the brief's hard requirement — Face ID must not
   * appear during a cooldown, because a biometric prompt that unlocks is how a cooldown gets bypassed — and there is
   * a second, independent check inside [requestBiometricUnlock], because a caller may assemble the conditions
   * itself.
   */
  val prefersBiometricUnlock: Boolean
    get() = biometricsEnabled && !keypadRequired && !isLockedOut && biometrics().available() && normalConfigured

  // MARK: - Verification

  /**
   * Pure verification, zero side effects — the settings page's "one-tap drill" may only use this, and it must never
   * be able to lead to a wipe.
   *
   * The timing claim, stated honestly: iOS comments this as "constant work: always two derivations" (A:1645-1650),
   * and the mechanism is [PopopxDuressVerifier.workloadPad] standing in for whichever record is missing, so "two
   * codes set", "only one code set", "hit the regular" and "hit the duress" all cost the same. That holds **among
   * configured states only**: the `guard normalConfigured` below returns before any derivation, so a device with no
   * code set answers in about 0 ms. That asymmetry is real in iOS and is reproduced rather than "fixed", because
   * fixing it would make an unconfigured device pay 0.7 s per unlock to hide a difference that a device with no
   * duress code has nothing to hide.
   */
  suspend fun verify(pin: String): PopopxDuressOutcome {
    refreshConfiguration()
    if (!normalConfigured) return PopopxDuressOutcome.NotConfigured
    val normal = readVerifier(PopopxDuressAccounts.NORMAL)
    val duress = if (duressConfigured) readVerifier(PopopxDuressAccounts.DURESS) else null
    val normalRecord = normal ?: PopopxDuressVerifier.workloadPad(PopopxDuressCrypto.randomSalt())
    val duressRecord = duress ?: PopopxDuressVerifier.workloadPad(PopopxDuressCrypto.randomSalt())
    // Normal first, duress second, and the pad is derived even though it cannot possibly match — the counter test is
    // what proves that, and the line reads like dead code without this comment.
    val normalHit = matches(pin, normalRecord) && normal != null
    val duressHit = matches(pin, duressRecord) && duress != null
    // The duress check is evaluated second but wins, so a code that somehow matches both erases instead of unlocking.
    if (duressHit) return PopopxDuressOutcome.Duress
    if (normalHit) return PopopxDuressOutcome.Unlocked
    return PopopxDuressOutcome.Wrong
  }

  private suspend fun matches(pin: String, record: PopopxDuressVerifier): Boolean {
    val salt = PopopxDuressCrypto.fromHex(record.salt) ?: return false
    val hash = PopopxDuressCrypto.fromHex(record.hash) ?: return false
    return PopopxDuressCrypto.matchesInConstantTime(derive(pin, salt, record.iterations), hash)
  }

  /**
   * The entry point the lock screen calls.
   *
   * Order, all of it load-bearing (A:1700-1725):
   * 1. re-read configuration,
   * 2. the cooldown gate **before any derivation** — otherwise a locked-out device still pays 0.7 s, which is the
   *    only signal an attacker is not supposed to get from a refusal,
   * 3. the target duration is drawn from the jitter **before** the verdict exists,
   * 4. verify,
   * 5. branch and settle,
   * 6. pad to the target last.
   */
  suspend fun submit(pin: String): PopopxDuressAttempt {
    refreshConfiguration()
    if (isLockedOut) return PopopxDuressAttempt.LockedOut(remainingLockoutSeconds)
    val started = now()
    val target = flowTargetSeconds()
    val outcome = verify(pin)
    val attempt = when (outcome) {
      PopopxDuressOutcome.Duress -> {
        clearFailures()
        PopopxDuressAttempt.Duress
      }
      PopopxDuressOutcome.Unlocked -> {
        // Only the cooldown table is paid here. The biometric debt is **not** cleared by a correct code, because iOS
        // does not clear it in `submit` either — the four sites that touch `keypadRequired` are the switch's didSet
        // (A:1149-1150), `clearAllPins` (A:1417-1418), a successful read (A:2088-2089) and `resetBiometricFailures`
        // (A:2103-2104) — and paying it is the overlay's job on the unlock edge
        // (PopopxAppLockOverlayView.swift:602-618). The Android keypad must make that call itself; doing it here would
        // make the two platforms' journals disagree about a finger that stopped working.
        clearFailures()
        PopopxDuressAttempt.Unlocked
      }
      PopopxDuressOutcome.NotConfigured -> PopopxDuressAttempt.NotConfigured
      PopopxDuressOutcome.Wrong -> settleWrongAttempt()
    }
    pad(from = started, to = target)
    return attempt
  }

  /**
   * A wrong code: one more strike, then either a longer lock or the wipe.
   *
   * iOS's non-reentrancy guard returns `.duress` rather than `.wrong` when a wipe is already in progress (A:1872-
   * 1876), and the reason is exposure, not correctness: an error popup raised on top of an in-progress wipe is a
   * dialog that says "something is happening on this phone" to whoever is holding it.
   */
  private suspend fun settleWrongAttempt(): PopopxDuressAttempt {
    // iOS counts first and only then looks at the threshold (A:1873-1876), so an attempt that lands during a running
    // wipe still costs a strike. Refusing before the count would leave the two platforms' cooldown tables disagreeing
    // about the same sequence of mistyped PINs.
    val strikes = registerFailure()
    if (strikes >= PopopxLockoutSchedule.WIPE_THRESHOLD && wipeOnTenthFailure) {
      if (duressFlowInFlight) return PopopxDuressAttempt.Duress
      duressFlowInFlight = true
      try {
        // Zeroed before the flow starts, so a wipe that is interrupted cannot leave a counter that re-triggers on
        // the next mistyped PIN.
        clearFailures()
        return PopopxDuressAttempt.Duress
      } finally {
        duressFlowInFlight = false
      }
    }
    return if (isLockedOut) PopopxDuressAttempt.LockedOut(remainingLockoutSeconds) else PopopxDuressAttempt.Wrong
  }

  /**
   * Memory first, disk second: a persistence failure costs the strike nothing that has already been earned.
   *
   * The deadline is computed **here**, in the same step as the count, so one strike is one write (A:1904-1917). A
   * separate write after the branch would put the record on disk twice per attempt and leave a window where the
   * counter says five and the deadline says nothing.
   */
  private fun registerFailure(): Int {
    failedAttemptCount += 1
    val seconds = PopopxLockoutSchedule.lockoutSeconds(failedAttemptCount)
    lockoutEndsAt = if (seconds > 0) now() + seconds else null
    if (!persistLockout()) log("duress lockout: persistence failed at strike $failedAttemptCount")
    return failedAttemptCount
  }

  /**
   * Zeroes the counter and **deletes** the record.
   *
   * iOS does not write a `failedAttempts = 0` record (A:1923-1927), because that would be long-term storage of "this
   * device had brute-force protection enabled", which is itself a fact worth hiding.
   */
  fun clearFailures() {
    failedAttemptCount = 0
    lockoutEndsAt = null
    kv.delete(PopopxDuressAccounts.LOCKOUT)
  }

  /**
   * Update, and add only when the record is genuinely not there — see the reason on [PopopxDuressKv.update].
   */
  private fun persistLockout(): Boolean {
    val value = PopopxDuressCodec.encodeLockout(PopopxDuressLockoutRecord(failedAttemptCount, lockoutEndsAt))
    if (kv.update(PopopxDuressAccounts.LOCKOUT, value)) return true
    if (kv.exists(PopopxDuressAccounts.LOCKOUT)) return false
    return kv.add(PopopxDuressAccounts.LOCKOUT, value)
  }

  private fun flowTargetSeconds(): Double = MINIMUM_FLOW_SECONDS + random() * FLOW_JITTER_SECONDS

  private suspend fun pad(from: Double, to: Double) {
    val elapsed = now() - from
    if (elapsed < to) sleep(to - elapsed)
  }

  // MARK: - Setting the codes

  /**
   * Records the ordinary code.
   *
   * The migration runs **before** the new code is written (A:1340-1341), and that order is the whole point: the
   * upstream passcode is about to stop being a front door, and turning the mode back to system while a code still
   * protects the app would lock the user out of their own app with a passcode they no longer have.
   */
  suspend fun setNormalPin(
    first: String,
    confirming: String,
    nativePasscode: String? = null,
    nativeSelfDestructCode: String? = null,
    upstream: PopopxUpstreamPasscode = PopopxUpstreamPasscodeImpl(),
  ) {
    if (!isValidPin(first) || first != confirming) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.MalformedPin)
    migrateNativeEntryPassword(nativePasscode, nativeSelfDestructCode, upstream)
    writeNewPin(PopopxDuressAccounts.NORMAL, first)
    normalConfigured = true
  }

  /**
   * Records the duress code.
   *
   * The same-code gate cannot be "compare the two strings" and it cannot be "compare the two hashes": the records
   * carry independent random salts, so a hash made with the *new* salt can never equal the normal record's hash — the
   * gate would look present and never once close. iOS spells that out at A:1382-1385. So the candidate is re-derived
   * **against the normal record's own salt and the normal record's own iteration count**, and only the derived values
   * are compared.
   */
  suspend fun setDuressPin(first: String, confirming: String) {
    if (!duressEnabled) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.KeychainWriteFailed)
    if (!normalConfigured) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.NormalPinRequiredFirst)
    if (!isValidPin(first) || first != confirming) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.MalformedPin)
    val normal = readVerifier(PopopxDuressAccounts.NORMAL)
      ?: throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.NormalPinRequiredFirst)
    val salt = PopopxDuressCrypto.randomSalt()
    if (salt.isEmpty()) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.KeychainWriteFailed)
    val normalSalt = PopopxDuressCrypto.fromHex(normal.salt)
      ?: throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.KeychainWriteFailed)
    val againstNormal = derive(first, normalSalt, normal.iterations)
    if (PopopxDuressCrypto.matchesInConstantTime(againstNormal, PopopxDuressCrypto.fromHex(normal.hash) ?: ByteArray(0))) {
      throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.PinsMustDiffer)
    }
    // Nothing above this line wrote anything, so a refusal leaves the duress record exactly as it was.
    writeNewRecord(PopopxDuressAccounts.DURESS, first, salt)
    duressConfigured = true
  }

  private suspend fun writeNewPin(key: String, pin: String) {
    val salt = PopopxDuressCrypto.randomSalt()
    if (salt.isEmpty()) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.KeychainWriteFailed)
    writeNewRecord(key, pin, salt)
  }

  private suspend fun writeNewRecord(key: String, pin: String, salt: ByteArray) {
    val hash = derive(pin, salt, PopopxDuressCrypto.ITERATIONS)
    if (hash.isEmpty()) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.KeychainWriteFailed)
    val record = PopopxDuressVerifier(
      iterations = PopopxDuressCrypto.ITERATIONS,
      salt = PopopxDuressCrypto.toHex(salt),
      hash = PopopxDuressCrypto.toHex(hash),
    )
    // Delete-then-add for credentials: unlike the lockout counter, an unreadable stale record is worth nothing.
    kv.delete(key)
    if (!kv.add(key, PopopxDuressCodec.encodeVerifier(record))) {
      throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.KeychainWriteFailed)
    }
  }

  /**
   * Removes every trace of this module's own records.
   *
   * Three accounts, not iOS's five — see [PopopxDuressAccounts.ALL] for why the two mnemonic ones are absent. No
   * preference key is removed here either, which is also a deliberate gap: iOS's `PopopxAntiTheftSwitches.eraseAllTraces()`
   * clears the switches, and that file is in the untouched tier of this pass, so the switches keep their values and a
   * device that is wiped keeps saying the features were on. Recorded as a deviation rather than half-implemented.
   */
  fun clearAllPins() {
    for (key in PopopxDuressAccounts.ALL) kv.delete(key)
    normalConfigured = false
    duressConfigured = false
    failedAttemptCount = 0
    lockoutEndsAt = null
    biometricFailures = 0
    keypadRequired = false
  }

  /** Deletes only the duress record; used by the "leave the normal code, drop duress" path. */
  fun clearDuressPin() {
    kv.delete(PopopxDuressAccounts.DURESS)
    duressConfigured = false
  }

  /**
   * The gate that says "this is the owner, not a thief who guessed the duress code": the ordinary code, verified with
   * the same 100,000 rounds, so looking costs what unlocking costs.
   *
   * It does not consume the cooldown table, on purpose (A:1512-1513): the escalating lock exists to slow a stranger
   * at the lock screen, and a person who knows the code is not being attacked by their own settings page.
   */
  suspend fun verifyEntryPin(pin: String) {
    if (!isValidPin(pin)) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.EntryPinRequired)
    val record = readVerifier(PopopxDuressAccounts.NORMAL)
      ?: throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.EntryPinRequired)
    if (!matches(pin, record)) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.EntryPinIncorrect)
  }

  /**
   * The drill the settings page offers: "type the duress code here and see what happens".
   *
   * Only ever [verify], which has no side effects, so the worst it can do is answer. A drill that went through
   * [submit] would be a wipe button wearing a help label.
   */
  suspend fun drillDuressPin(pin: String): PopopxDuressOutcome = verify(pin)

  // MARK: - Biometrics

  /**
   * The biometric gate (A:2070-2093).
   *
   * It re-checks the cooldown instead of trusting [prefersBiometricUnlock], because that property is only the
   * *routing* decision — "should the screen open with biometrics" — and a caller that assembles its own conditions
   * would otherwise get a prompt during a cooldown, which is precisely the bypass the brief names as forbidden.
   * iOS's own guard has all four terms (`biometricsEnabled, !keypadRequired, !isLockedOut, canEvaluate`), so this
   * function refuses on `keypadRequired` too: once two reads have failed, a finger is not allowed back in until the
   * code is typed.
   *
   * The debt moves **once per prompt** that did not succeed, which is what iOS's single `guard success else` does at
   * A:2080. Android is finer-grained — `onAuthenticationFailed` fires for every wrong finger inside one sheet, and
   * `onAuthenticationError` then ends it — so the per-attempt callback is given to the UI as a message and does not
   * count. Counting both would let one sheet with three wrong fingers cost three strikes and reach the keypad rule
   * on a single prompt, which is not what iOS promises. A dismissal counts, exactly as it does there: iOS sees
   * `success == false` and cannot tell a cancelled sheet from a rejected finger.
   */
  suspend fun requestBiometricUnlock(prompter: PopopxDuressBiometrics = biometrics()): PopopxDuressAttempt {
    if (!biometricsEnabled) return PopopxDuressAttempt.NotConfigured
    // The same answer as "no biometrics here", because the caller's action is the same: show the keypad.
    if (keypadRequired) return PopopxDuressAttempt.NotConfigured
    if (isLockedOut) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.BiometricDenied)
    if (!normalConfigured || !prompter.available()) return PopopxDuressAttempt.NotConfigured
    return when (prompter.authenticate(title = "POPOPX", subtitle = null, onFailedAttempt = { })) {
      LAResult.Success -> {
        // The cooldown table is zeroed here because a successful read is an unlock; the biometric debt is zeroed
        // because it is what the debt *means*. iOS does both (A:2088-2090) and then calls `unlock()` on its own
        // overlay state — that second action is left to the caller here, because dismissing the lock screen is the
        // keypad view's job and this module has no business reaching for it.
        clearFailures()
        resetBiometricFailures()
        PopopxDuressAttempt.Unlocked
      }
      // Not a success, so one strike on the biometric table — and no clear of the cooldown, which is a separate
      // table by iOS's own comment (A:2099-2101): "merging them would make one slipped Face ID look like one
      // guessed passcode".
      is LAResult.Error -> {
        registerBiometricFailure()
        PopopxDuressAttempt.Wrong
      }
      is LAResult.Failed -> {
        registerBiometricFailure()
        PopopxDuressAttempt.Wrong
      }
      // The guard at A:2073 fails before the prompt is ever shown, so nothing is counted: no capability is not a
      // failed read.
      is LAResult.Unavailable -> PopopxDuressAttempt.NotConfigured
    }
  }

  /**
   * A failed biometric, counted.
   *
   * Only ever downgrades: two failures and the keypad is required, which is a *stronger* demand, not a weaker one.
   * Nothing here falls back to a device credential — that is the whole reason [PopopxDuressBiometrics] exists next to
   * the upstream `authenticate`.
   */
  fun registerBiometricFailure() {
    biometricFailures += 1
    if (biometricFailures >= MAX_BIOMETRIC_FAILURES_BEFORE_KEYPAD) keypadRequired = true
  }

  /** iOS's `resetBiometricFailures` (A:2102-2105), which clears the biometric table and *only* that table. */
  fun resetBiometricFailures() {
    biometricFailures = 0
    keypadRequired = false
  }

  // MARK: - The upstream passcode

  /**
   * Hands the app's own passcode over to this module.
   *
   * Every check precedes every write (A:1272-1293), which is what makes the failure branches mean "nothing changed":
   * a refusal that has already deleted the upstream code would leave the app unlocked and the user believing it is
   * protected.
   *
   * Branch A is the common case — no upstream app passcode at all. Only the ghost flag is retired, then the mode goes
   * back to system.
   */
  fun migrateNativeEntryPassword(
    passcode: String?,
    selfDestructPasscode: String?,
    upstream: PopopxUpstreamPasscode = PopopxUpstreamPasscodeImpl(),
  ) {
    if (upstream.appPasscode() == null) {
      retireGhostSelfDestructCode(selfDestructPasscode, upstream)
      if (upstream.mode() == PopopxUpstreamMode.PASSCODE) upstream.setMode(PopopxUpstreamMode.SYSTEM)
      return
    }
    if (passcode.isNullOrEmpty()) throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.NativePasscodeRequired)
    val stored = upstream.appPasscode() ?: ByteArray(0)
    if (!PopopxDuressCrypto.matchesInConstantTime(passcode.toByteArray(), stored)) {
      throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.NativePasscodeIncorrect)
    }
    // All three removals happen here and nowhere above.
    upstream.removeAppPasscode()
    upstream.removeSelfDestructPasscode()
    upstream.removeSelfDestructFlag()
    upstream.setMode(PopopxUpstreamMode.SYSTEM)
  }

  /**
   * The ghost case, which is the one that needs a reason attached to it (A:1301-1303): the self-destruct item is gone
   * and only the display flag is set, so the flag is dropped **without asking for a code**. That boolean deletes no
   * data on its own — the self-destruct step requires the stored code to have a value equal to the input — so it is
   * purely display residue, and "please enter a password that no longer exists" is a demand that can neither be met
   * nor mean anything.
   *
   * When the item *is* still there, the code is demanded and checked, because then it is a real second front door.
   */
  fun retireGhostSelfDestructCode(selfDestructPasscode: String?, upstream: PopopxUpstreamPasscode = PopopxUpstreamPasscodeImpl()) {
    if (upstream.selfDestructPasscode() == null) {
      upstream.removeSelfDestructFlag()
      return
    }
    if (selfDestructPasscode.isNullOrEmpty()) {
      throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.NativeSelfDestructCodeRequired)
    }
    val stored = upstream.selfDestructPasscode() ?: ByteArray(0)
    if (!PopopxDuressCrypto.matchesInConstantTime(selfDestructPasscode.toByteArray(), stored)) {
      throw PopopxDuressSetupError(PopopxDuressSetupError.Kind.NativeSelfDestructCodeIncorrect)
    }
    upstream.removeSelfDestructPasscode()
    upstream.removeSelfDestructFlag()
  }

  /** Whether the app still has an upstream passcode in front of this module's keypad. */
  fun nativeEntryPasswordActive(upstream: PopopxUpstreamPasscode = PopopxUpstreamPasscodeImpl()): Boolean =
    upstream.appPasscode() != null

  /**
   * Strictly isomorphic to the retire condition above, which is the property that makes it safe to use as a banner:
   * it can only be true when running the migration would actually change something.
   */
  fun nativeSelfDestructGhostActive(upstream: PopopxUpstreamPasscode = PopopxUpstreamPasscodeImpl()): Boolean =
    upstream.appPasscode() == null && (upstream.selfDestructPasscode() != null || upstream.selfDestructFlag())

  private fun readVerifier(key: String): PopopxDuressVerifier? = PopopxDuressCodec.decodeVerifier(kv.read(key))

  /** iOS's `object(forKey:) == nil ? true : bool(forKey:)`, spelled with the null-returning getter the wrapper has. */
  private fun absentThenTrue(key: String): Boolean = defaults.getBooleanOrNull(key) ?: true
}

/** The mode the upstream local-auth setting is in. */
enum class PopopxUpstreamMode { SYSTEM, PASSCODE }

/**
 * The upstream passcode's storage, injected rather than reached for.
 *
 * The production names are `DatabaseUtils.ksAppPassword` / `ksSelfDestructPassword` (both `KeyStoreItem`, so both
 * already go through `cryptor` — Keystore AES-GCM on Android, plaintext pass-through on desktop, which is why the
 * comparison below is byte-comparable to the input's UTF-8) and `AppPreferences.laMode` / `selfDestruct`.
 *
 * Taking them as an interface is what lets a test assert that a refusal branch wrote **nothing**, which is the claim
 * the ordering of [PopopxDuressAuthManager.migrateNativeEntryPassword] exists to earn. Reaching through the single
 * objects directly would make that assertion unobservable, and would additionally initialize
 * `ChatController.appPrefs` — and therefore the whole preference layer — inside a unit test.
 */
interface PopopxUpstreamPasscode {
  fun appPasscode(): ByteArray?
  fun selfDestructPasscode(): ByteArray?
  fun selfDestructFlag(): Boolean
  fun mode(): PopopxUpstreamMode
  fun removeAppPasscode()
  fun removeSelfDestructPasscode()
  fun removeSelfDestructFlag()
  fun setMode(mode: PopopxUpstreamMode)
}

/**
 * Production binding to the upstream storage.
 *
 * Nothing resets `laLockDelay` here, which is a deliberate difference from iOS: iOS's `localAuthenticationTimeout`
 * and `localAuthenticationLockAppOnForeground` are keys whose absence is ambiguous ("`getOrCreate` writes them on
 * first read"), whereas Android's `laLockDelay` is an `mkIntPreference` with a declared default of 30, so leaving it
 * alone has a defined meaning — the user's own lock delay survives the migration, which is what they would expect.
 */
class PopopxUpstreamPasscodeImpl(
  private val appPrefs: AppPreferences = AppPreferences(),
) : PopopxUpstreamPasscode {
  override fun appPasscode(): ByteArray? = DatabaseUtils.ksAppPassword.get()?.toByteArray()

  override fun selfDestructPasscode(): ByteArray? = DatabaseUtils.ksSelfDestructPassword.get()?.toByteArray()

  override fun selfDestructFlag(): Boolean = appPrefs.selfDestruct.get()

  override fun mode(): PopopxUpstreamMode =
    if (appPrefs.laMode.get() == LAMode.PASSCODE) PopopxUpstreamMode.PASSCODE else PopopxUpstreamMode.SYSTEM

  override fun removeAppPasscode() { DatabaseUtils.ksAppPassword.remove() }

  override fun removeSelfDestructPasscode() { DatabaseUtils.ksSelfDestructPassword.remove() }

  override fun removeSelfDestructFlag() { appPrefs.selfDestruct.set(false) }

  override fun setMode(mode: PopopxUpstreamMode) {
    appPrefs.laMode.set(if (mode == PopopxUpstreamMode.PASSCODE) LAMode.PASSCODE else LAMode.SYSTEM)
  }
}
