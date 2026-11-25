package chat.popopx.app.duress

import chat.popopx.common.duress.PopopxDuressAccounts
import chat.popopx.common.duress.PopopxDuressAttempt
import chat.popopx.common.duress.PopopxDuressAuthManager
import chat.popopx.common.duress.PopopxDuressCrypto
import chat.popopx.common.duress.PopopxDuressOutcome
import chat.popopx.common.duress.PopopxDuressSetupError
import chat.popopx.common.duress.PopopxUpstreamMode
import chat.popopx.common.views.helpers.LAResult
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

// The engine's rules, asserted through its own seams.
//
// The claims that matter here are about *sequence* rather than about values — what is derived before what, which
// branch writes first, how many derivations a refusal costs — so the driver records an event list and the tests
// compare against that. A test that only checked the returned enum would stay green if `submit` were rewritten to
// derive before it consults the cooldown, which is the one change that turns a lockout into a timing oracle.

private val NORMAL = PopopxDuressAccounts.NORMAL
private val DURESS = PopopxDuressAccounts.DURESS
private val LOCKOUT = PopopxDuressAccounts.LOCKOUT

private fun kindOf(block: suspend () -> Unit): PopopxDuressSetupError.Kind =
  try {
    runBlocking { block() }
    error("expected a PopopxDuressSetupError, none thrown")
  } catch (e: PopopxDuressSetupError) {
    e.kind
  }

/** Wrong codes, walking past each cooldown so the next attempt is allowed to run. Returns the answers in order. */
private fun Duress.mistimes(times: Int, pin: String = "000000"): List<PopopxDuressAttempt> =
  (1..times).map {
    val answer = runBlocking { manager.submit(pin) }
    if (answer is PopopxDuressAttempt.LockedOut) advance(answer.remainingSeconds + 1)
    answer
  }

/**
 * Arrive at a cooldown and **stay** in it.
 *
 * [mistimes] walks past each cooldown on purpose — the escalating-ladder tests have to get to strike 8 and 9 — but the
 * fifth attempt is the one that earns the cooldown on itself (A:1907-1908, A:1875), so a test that wants to observe a
 * locked-out device has to stop there instead of advancing.
 */
private fun Duress.lockOurs(pin: String = "000000") {
  mistimes(4, pin)
  val earned = runBlocking { manager.submit(pin) }
  require(earned is PopopxDuressAttempt.LockedOut) { "the fifth attempt did not earn a cooldown: $earned" }
}

class PopopxDuressEngineTest {
  // MARK: verify — the constant-work claim

  @Test
  fun aDeviceWithNoNormalCodeAnswersWithoutDerivingAnything() {
    val d = Duress()
    assertEquals(PopopxDuressOutcome.NotConfigured, runBlocking { d.manager.verify("123456") })
    // Documented, not hidden: iOS's `guard normalConfigured` returns before any derivation, so "always two
    // derivations" holds among configured states only. An unconfigured device answers in about zero time.
    assertEquals(emptyList<String>(), d.events)
  }

  @Test
  fun twoCodesSetCostsTheSameTwoDerivationsAsOne() {
    val one = Duress()
    one.seedNormal("123456")
    val two = Duress()
    two.seedNormal("123456")
    two.seedDuress("654321")
    runBlocking { one.manager.verify("000000") }
    runBlocking { two.manager.verify("000000") }
    // The claim is the *equality*, not the number: a device with one code must not cost half of a device with two, or
    // the work answers "does this owner use a duress code" before any code is typed. The seeding itself derives
    // outside the engine (the fixture writes the record by hand), so the count is taken after a real attempt.
    assertEquals(2, one.derivations.size)
    assertEquals(one.derivations.size, two.derivations.size, "the cost must not reveal which codes exist")
    assertEquals(2, two.derivations.size)
  }

  @Test
  fun onlyTheNormalCodeSetStillCostsTwoDerivations() {
    val d = Duress()
    d.seedNormal("123456")
    runBlocking { d.manager.verify("000000") }
    // The second derivation is against a pad that cannot match. It looks like dead code and it is the point: a
    // device with one code configured must not cost half of a device with two, or the cost answers the question
    // "does this owner use a duress code" before any code is typed.
    assertEquals(listOf("derive", "derive"), d.events)
    assertEquals(1_000, d.derivations[0].third, "the real record's own iteration count")
    assertEquals(100_000, d.derivations[1].third, "the pad costs what a production record costs")
  }

  @Test
  fun hittingTheNormalCodeDoesNotShortCircuitTheDuressDerivation() {
    val d = Duress()
    d.seedNormal("123456")
    d.seedDuress("654321")
    d.derivations.clear()
    d.events.clear()
    assertEquals(PopopxDuressOutcome.Unlocked, runBlocking { d.manager.verify("123456") })
    assertEquals(2, d.derivations.size, "a hit must still cost the full two derivations")
  }

  @Test
  fun theDuressCodeIsRecognisedOnTheSecondDerivationAndWins() {
    val d = Duress()
    d.seedNormal("123456")
    d.seedDuress("654321")
    d.derivations.clear()
    assertEquals(PopopxDuressOutcome.Duress, runBlocking { d.manager.verify("654321") })
    assertEquals("01020304", d.derivations[0].second, "normal record's salt first")
    assertEquals("0a0b0c0d", d.derivations[1].second, "duress record's salt second")
  }

  @Test
  fun aCorruptNormalRecordFailsClosedRatherThanReportingUnconfigured() {
    val d = Duress()
    d.seedNormal("123456")
    d.kv.unreadable = NORMAL
    // "Configured" is the *existence of the key*, so the keypad stays up and every code is refused. The alternative
    // — treating an unreadable record as "not configured" — would let the screen rebuild a code nobody set.
    assertEquals(PopopxDuressOutcome.Wrong, runBlocking { d.manager.verify("123456") })
    assertEquals(2, d.derivations.size, "both derivations still ran, against pads")
  }

  @Test
  fun aDuressRecordWhoseSwitchIsOffIsNotReadAtAll() {
    val d = Duress()
    d.seedNormal("123456")
    d.seedDuress("654321")
    d.manager.duressEnabled = false
    assertEquals(PopopxDuressOutcome.Wrong, runBlocking { d.manager.verify("654321") })
    assertFalse(d.kv.records.containsKey(DURESS), "turning the switch off deleted the record, not just the gate")
    assertEquals(2, d.derivations.size, "and the cost stayed the same")
  }

  // MARK: submit — the order that makes the rules real

  @Test
  fun aLockedOutAttemptDerivesNothingAndSleepsNothing() {
    val d = Duress()
    d.seedNormal("123456")
    d.mistimes(4)
    // The fifth attempt earns the cooldown *on itself* (A:1907-1908: the deadline is set in the same step that counts
    // the strike, and A:1875 returns `.lockedOut` for that same attempt), so a test that waited for a sixth refusal
    // first would have walked past the lockout it was trying to prove.
    val earned = runBlocking { d.manager.submit("000000") }
    assertTrue(earned is PopopxDuressAttempt.LockedOut, "the fifth attempt should have earned the cooldown, got $earned")
    assertEquals(60.0, (earned as PopopxDuressAttempt.LockedOut).remainingSeconds, 0.0001)
    d.events.clear()
    d.derivations.clear()
    val answer = runBlocking { d.manager.submit("000000") }
    assertTrue(answer is PopopxDuressAttempt.LockedOut, "expected a lockout, got $answer")
    // The gate is *before* the derivations and before the padding sleep. Deriving under a lockout would hand an
    // attacker the 0.7 s signature of a real attempt on an attempt that was never going to be evaluated.
    assertEquals(emptyList<String>(), d.events)
    assertEquals(5, d.manager.failedAttemptCount, "a locked-out attempt does not add a strike")
  }

  @Test
  fun theJitterIsDrawnBeforeAnythingIsDerived() {
    val d = Duress()
    d.seedNormal("123456")
    runBlocking { d.manager.submit("000000") }
    assertEquals(listOf("draw", "derive", "derive", "sleep"), d.events)
  }

  @Test
  fun anAttemptIsFlooredToTheMinimumFlowAndTheJitterAddsToIt() {
    val d = Duress()
    d.seedNormal("123456")
    runBlocking { d.manager.submit("000000") }
    assertEquals(1.2, d.sleeps.single(), 0.0001)
    val second = Duress()
    second.seedNormal("123456")
    second.jitter = 0.5
    runBlocking { second.manager.submit("000000") }
    assertEquals(1.2 + 0.5 * 1.2, second.sleeps.single(), 0.0001)
  }

  @Test
  fun theFourthAttemptIsFreeAndTheFifthCostsAMinute() {
    val d = Duress()
    d.seedNormal("123456")
    val answers = d.mistimes(5)
    (0..3).forEach { index ->
      assertEquals(PopopxDuressAttempt.Wrong, answers[index], "attempt ${index + 1} must not lock")
    }
    // The off-by-one the table is easy to misread: the counter is the number of attempts *already made*, so it is
    // the fifth attempt — the first one past the four free tries — that costs a minute.
    assertEquals(PopopxDuressAttempt.LockedOut(60.0), answers[4])
    assertEquals(5, d.manager.failedAttemptCount)
  }

  @Test
  fun attemptsFiveSixSevenAndEightStepUpAndThenHoldAtTheCeiling() {
    val d = Duress()
    d.seedNormal("123456")
    val answers = d.mistimes(9)
    assertEquals(60.0, (answers[4] as PopopxDuressAttempt.LockedOut).remainingSeconds)
    assertEquals(300.0, (answers[5] as PopopxDuressAttempt.LockedOut).remainingSeconds)
    assertEquals(900.0, (answers[6] as PopopxDuressAttempt.LockedOut).remainingSeconds)
    (7..8).forEach { index ->
      assertEquals(3_600.0, (answers[index] as PopopxDuressAttempt.LockedOut).remainingSeconds, "attempt ${index + 1}")
    }
  }

  @Test
  fun everyStrikeIsPersistedAsACounterEvenWhileNoLockIsActive() {
    val d = Duress()
    d.seedNormal("123456")
    runBlocking { d.manager.submit("000000") }
    assertEquals(1, d.manager.failedAttemptCount)
    assertNotNull(d.storedLockout(), "the first strike must survive a restart, lock or no lock")
    assertTrue("1" in d.storedLockout()!!, d.storedLockout()!!)
  }

  @Test
  fun aCorrectCodeDeletesTheCounterInsteadOfZeroingIt() {
    val d = Duress()
    d.seedNormal("123456")
    d.mistimes(3)
    runBlocking { d.manager.submit("123456") }
    assertEquals(0, d.manager.failedAttemptCount)
    // Not `{"failedAttempts":0}`: that would be long-term storage of "this device had brute-force protection
    // enabled", which is itself a fact worth hiding.
    assertFalse(d.kv.records.containsKey(LOCKOUT), "the record must be gone, not zeroed")
    assertTrue(d.kv.deletes > 0)
  }

  @Test
  fun theTenthAttemptWipesOnlyWhenTheSwitchIsOn() {
    val off = Duress()
    off.seedNormal("123456")
    val offAnswers = off.mistimes(10)
    assertTrue(offAnswers[9] is PopopxDuressAttempt.LockedOut, "with the switch off the tenth attempt only locks")
    assertEquals(3_600.0, (offAnswers[9] as PopopxDuressAttempt.LockedOut).remainingSeconds)

    val on = Duress()
    on.manager.wipeOnTenthFailure = true
    on.seedNormal("123456")
    val onAnswers = on.mistimes(10)
    assertEquals(PopopxDuressAttempt.Duress, onAnswers[9])
    assertEquals(0, on.manager.failedAttemptCount, "the counter is cleared before the flow, not after")
  }

  @Test
  fun aDeviceThatNeverSawTheWipeSwitchDoesNotWipe() {
    // A manager nobody has written to, so the defaults are the ones the code reads from an empty bag. The
    // asymmetric default is the whole test: the two feature switches come on when their key is absent, but a
    // *destructive* one cannot. Reading the absent key as "on" would turn ten mistyped PINs into lost history.
    val fresh = PopopxDuressAuthManager(PopopxDuressKvDouble(), duressSettings())
    assertTrue(fresh.duressEnabled)
    assertTrue(fresh.biometricsEnabled)
    assertFalse(fresh.wipeOnTenthFailure)
  }

  @Test
  fun theCounterIsUpdatedFirstAndOnlyAddedWhenTheRecordIsGenuinelyAbsent() {
    val d = Duress()
    d.seedNormal("123456")
    // Seeding writes through the same double, so its own add is not the engine's; the counters are taken from here.
    d.kv.updates = 0
    d.kv.adds = 0
    runBlocking { d.manager.submit("000000") }
    assertEquals(1, d.kv.updates, "the update is attempted even when it must fail")
    assertEquals(1, d.kv.adds)
    runBlocking { d.manager.submit("000000") }
    // Clear-then-add would turn any failed write into deleting the old record too, and this record says how many
    // times this person has already guessed wrong.
    assertEquals(2, d.kv.updates)
    assertEquals(1, d.kv.adds, "the second strike must not re-add")
  }

  @Test
  fun aFailedPersistenceDoesNotCostTheStrike() {
    val d = Duress()
    d.seedNormal("123456")
    d.kv.failWrites = true
    runBlocking { d.manager.submit("000000") }
    assertEquals(1, d.manager.failedAttemptCount, "memory first, disk second")
    runBlocking { d.manager.submit("000000") }
    assertEquals(2, d.manager.failedAttemptCount)
    assertNull(d.storedLockout())
  }

  @Test
  fun anUnreadableLockoutRecordLeavesTheInMemoryCounterAlone() {
    val d = Duress()
    d.seedNormal("123456")
    d.mistimes(2)
    d.kv.unreadable = LOCKOUT
    d.manager.refreshConfiguration()
    // "Reading it as 'never failed' hands out 4 free attempts, while reading it as 'still cooling down' costs the
    // owner at most waiting once more through a time he already waited. So staying locked is preferred."
    assertEquals(2, d.manager.failedAttemptCount)
  }

  // MARK: setting the codes

  @Test
  fun aMismatchedConfirmationIsRefusedBeforeAnyDerivation() {
    val d = Duress()
    assertEquals(PopopxDuressSetupError.Kind.MalformedPin, kindOf { d.manager.setNormalPin("123456", "123457") })
    assertEquals(emptyList<String>(), d.events)
    assertTrue(d.kv.records.isEmpty())
  }

  @Test
  fun aDuressCodeNeedsSixDigitsAndCannotBeTheNormalCodeReusingItsOwnSalt() {
    val d = Duress()
    d.seedNormal("123456")
    assertEquals(PopopxDuressSetupError.Kind.MalformedPin, kindOf { d.manager.setDuressPin("12345", "12345") })
    assertEquals(PopopxDuressSetupError.Kind.MalformedPin, kindOf { d.manager.setDuressPin("12345a", "12345a") })
    assertEquals(PopopxDuressSetupError.Kind.MalformedPin, kindOf { d.manager.setDuressPin("123456", "654321") })
  }

  @Test
  fun theSameCodeGateReDerivesWithTheNormalRecordsSaltAndIterationCount() {
    val d = Duress()
    d.seedNormal("123456", iterations = 1_000, saltHex = "11223344")
    d.derivations.clear()
    assertEquals(PopopxDuressSetupError.Kind.PinsMustDiffer, kindOf { d.manager.setDuressPin("123456", "123456") })
    // A hash made with the *new* random salt can never equal the normal record's hash, so a gate that compared the
    // two hashes would look present and never once close. The derivation this refusal performed is the proof that
    // the gate used the normal record instead.
    assertEquals(1, d.derivations.size)
    assertEquals("11223344", d.derivations[0].second)
    assertEquals(1_000, d.derivations[0].third)
    assertEquals("123456", d.derivations[0].first)
  }

  @Test
  fun aRefusedDuressCodeLeavesThePreviousOneWorking() {
    val d = Duress()
    d.seedNormal("123456")
    val before = d.seedDuress("999999")
    kindOf { d.manager.setDuressPin("123456", "123456") }
    assertEquals(before, d.kv.records[DURESS], "nothing above the write ran a write")
    assertEquals(PopopxDuressOutcome.Duress, runBlocking { d.manager.verify("999999") })
  }

  @Test
  fun aDuressCodeCannotBeSetBeforeTheNormalOne() {
    val d = Duress()
    assertEquals(PopopxDuressSetupError.Kind.NormalPinRequiredFirst, kindOf { d.manager.setDuressPin("654321", "654321") })
  }

  @Test
  fun settingTheNormalCodeMigratesTheUpstreamPasscodeBeforeWritingIt() {
    val d = Duress()
    val upstream = PopopxUpstreamDouble(app = "1234".toByteArray())
    runBlocking { d.manager.setNormalPin("123456", "123456", nativePasscode = "1234", upstream = upstream) }
    assertEquals(
      listOf("removeApp", "removeSelfDestruct", "removeFlag", "setMode:SYSTEM"),
      upstream.writes,
      "the order is the point: the mode may only go back to system once nothing else is a front door",
    )
    assertTrue(d.kv.records.containsKey(NORMAL))
  }

  @Test
  fun aWrongNativePasscodeRefusesWithoutTouchingAnything() {
    val d = Duress()
    val upstream = PopopxUpstreamDouble(app = "1234".toByteArray(), selfDestruct = "5678".toByteArray())
    assertEquals(
      PopopxDuressSetupError.Kind.NativePasscodeIncorrect,
      kindOf { d.manager.setNormalPin("123456", "123456", nativePasscode = "9999", upstream = upstream) },
    )
    assertEquals(emptyList<String>(), upstream.writes, "a refusal that had already deleted the code would leave the app unlocked")
    assertTrue(d.kv.records.isEmpty())
  }

  @Test
  fun aMissingNativePasscodeIsDemandedRatherThanAssumedAbsent() {
    val d = Duress()
    val upstream = PopopxUpstreamDouble(app = "1234".toByteArray())
    assertEquals(
      PopopxDuressSetupError.Kind.NativePasscodeRequired,
      kindOf { d.manager.setNormalPin("123456", "123456", upstream = upstream) },
    )
    assertEquals(emptyList<String>(), upstream.writes)
  }

  @Test
  fun aGhostSelfDestructFlagIsCleanedWithoutDemandingACodeThatNoLongerExists() {
    val d = Duress()
    val upstream = PopopxUpstreamDouble(app = null, selfDestruct = null, flag = true)
    d.manager.migrateNativeEntryPassword(null, null, upstream)
    // That boolean deletes no data on its own, so "please enter a password that no longer exists" would be a demand
    // that can neither be met nor mean anything.
    assertEquals(listOf("removeFlag", "setMode:SYSTEM"), upstream.writes)
  }

  @Test
  fun aRealSelfDestructCodeIsDemandedAndCheckedWhenTheItemIsStillThere() {
    val withNoCode = Duress()
    val upstream = PopopxUpstreamDouble(app = null, selfDestruct = "5678".toByteArray(), flag = true)
    assertEquals(
      PopopxDuressSetupError.Kind.NativeSelfDestructCodeRequired,
      kindOf { withNoCode.manager.retireGhostSelfDestructCode(null, upstream) },
    )
    assertEquals(emptyList<String>(), upstream.writes)

    val wrongCode = Duress()
    val second = PopopxUpstreamDouble(app = null, selfDestruct = "5678".toByteArray(), flag = true)
    assertEquals(
      PopopxDuressSetupError.Kind.NativeSelfDestructCodeIncorrect,
      kindOf { wrongCode.manager.retireGhostSelfDestructCode("9999", second) },
    )
    assertEquals(emptyList<String>(), second.writes)

    val rightCode = Duress()
    val third = PopopxUpstreamDouble(app = null, selfDestruct = "5678".toByteArray(), flag = true)
    rightCode.manager.retireGhostSelfDestructCode("5678", third)
    assertEquals(listOf("removeSelfDestruct", "removeFlag"), third.writes)
  }

  @Test
  fun theGhostBannerIsTrueOnlyWhenRunningTheMigrationWouldChangeSomething() {
    val d = Duress()
    // Four combinations, and exactly one of them is the ghost.
    assertFalse(d.manager.nativeSelfDestructGhostActive(PopopxUpstreamDouble(app = "1".toByteArray(), selfDestruct = "2".toByteArray(), flag = true)))
    assertFalse(d.manager.nativeSelfDestructGhostActive(PopopxUpstreamDouble(app = null, selfDestruct = null, flag = false)))
    assertTrue(d.manager.nativeSelfDestructGhostActive(PopopxUpstreamDouble(app = null, selfDestruct = null, flag = true)))
    assertTrue(d.manager.nativeSelfDestructGhostActive(PopopxUpstreamDouble(app = null, selfDestruct = "2".toByteArray(), flag = false)))
    assertTrue(d.manager.nativeEntryPasswordActive(PopopxUpstreamDouble(app = "1".toByteArray())))
  }

  @Test
  fun aBranchAWithNoUpstreamCodeAtAllStillRetiresTheGhostBeforeReturning() {
    val d = Duress()
    val upstream = PopopxUpstreamDouble(app = null, selfDestruct = null, flag = false, currentMode = PopopxUpstreamMode.SYSTEM)
    d.manager.migrateNativeEntryPassword(null, null, upstream)
    // `removeFlag` is called even when the flag was never set — iOS's branch A does that, and the assertion exists
    // so the port cannot quietly "optimize" it away and change what the preference file looks like afterwards.
    assertEquals(listOf("removeFlag"), upstream.writes, "no mode write needed: already system")
  }

  // MARK: clearing

  @Test
  fun clearAllPinsLeavesNoRecordAndNoInMemoryState() {
    val d = Duress()
    d.seedNormal("123456")
    d.seedDuress("654321")
    d.mistimes(2)
    d.manager.registerBiometricFailure()
    d.manager.clearAllPins()
    // Three records, not iOS's five: the mnemonic and its phrase have no Android counterpart this round, so there is
    // no recovery data on this device to clean up. Ruling 3, asserted rather than promised.
    assertTrue(d.kv.records.isEmpty(), d.kv.records.keys.joinToString())
    assertFalse(d.manager.normalConfigured)
    assertFalse(d.manager.duressConfigured)
    assertEquals(0, d.manager.failedAttemptCount)
    assertEquals(0, d.manager.biometricFailures)
    assertFalse(d.manager.keypadRequired)
  }

  @Test
  fun clearAllPinsLeavesTheSwitchesAloneBecauseTheSettingsScreenOwnsThem() {
    val d = Duress()
    d.manager.wipeOnTenthFailure = true
    d.seedNormal("123456")
    d.manager.clearAllPins()
    assertTrue(d.defaults.getBoolean(PopopxDuressAuthManager.KEY_TEN_STRIKE_WIPE, false))
    // iOS clears them in `PopopxAntiTheftSwitches.eraseAllTraces()`, which is in the untouched tier of this pass.
    // Recorded as a deviation, not quietly implemented twice.
  }

  @Test
  fun aRecordWrittenBehindTheManagerBlindsTheCachedReadersButNotTheAuthentication() {
    val d = Duress()
    // A raw store write rather than the fixture's `seed`, because `seed` re-reads on purpose.
    val salt = PopopxDuressCrypto.fromHex("01020304")!!
    val hash = PopopxDuressCrypto.toHex(duressFakeDerive("123456", salt, 1_000))
    assertTrue(d.kv.add(NORMAL, """{"version":1,"iterations":1000,"salt":"01020304","hash":"$hash"}"""))
    // The two consumers that answer from the cache (A:1162, A:2067). A record the manager did not write is invisible
    // to them until something calls `refreshConfiguration`, which is why the keypad mount calls it on appear — a
    // stale cache does not leak a code, it picks the wrong door.
    assertFalse(d.manager.normalConfigured, "the cached copy still says no")
    assertFalse(d.manager.prefersBiometricUnlock)
    assertEquals(PopopxDuressAttempt.NotConfigured, runBlocking { d.manager.requestBiometricUnlock() })
    assertEquals(0, d.biometrics.prompts, "the guard fired before any sheet was built")
    d.manager.refreshConfiguration()
    assertTrue(d.manager.normalConfigured)
    assertTrue(d.manager.prefersBiometricUnlock)

    // The asymmetry, asserted instead of only commented: `verify` and `submit` re-read at entry, in iOS's order, so
    // the authentication itself cannot be lied to by a cache. A second device, because the block above has already
    // refreshed this one.
    val fresh = Duress()
    assertTrue(fresh.kv.add(NORMAL, """{"version":1,"iterations":1000,"salt":"01020304","hash":"$hash"}"""))
    assertFalse(fresh.manager.normalConfigured)
    assertEquals(PopopxDuressOutcome.Unlocked, runBlocking { fresh.manager.verify("123456") })
    assertEquals(2, fresh.derivations.size, "the constant two derivations ran off the re-read record")
  }

  // MARK: the owner gate

  @Test
  fun theOwnerGateCostsTheSameAsUnlockingAndConsumesNoStrikes() {
    val d = Duress()
    d.seedNormal("123456", iterations = 1_000)
    runBlocking { d.manager.verifyEntryPin("123456") }
    assertEquals(1, d.derivations.size, "one derivation: this gate checks the normal code only")
    assertEquals(0, d.manager.failedAttemptCount)
    assertNull(d.storedLockout())

    val wrong = assertFailsWith<PopopxDuressSetupError> { runBlocking { d.manager.verifyEntryPin("000000") } }
    assertEquals(PopopxDuressSetupError.Kind.EntryPinIncorrect, wrong.kind)
    assertEquals(0, d.manager.failedAttemptCount, "the escalating lock is for a stranger at the lock screen")
    assertNull(d.storedLockout())
  }

  @Test
  fun theOwnerGateOnADeviceWithNoCodeSaysSoRatherThanUnlocking() {
    val d = Duress()
    assertEquals(PopopxDuressSetupError.Kind.EntryPinRequired, kindOf { d.manager.verifyEntryPin("123456") })
    assertEquals(emptyList<String>(), d.events)
  }

  // MARK: biometrics

  @Test
  fun biometricsAreOfferedOnlyWhenAllFiveTermsHold() {
    val d = Duress()
    d.seedNormal("123456")
    assertTrue(d.manager.prefersBiometricUnlock, "the control case must be reachable, or the four refusals below prove nothing")

    d.manager.biometricsEnabled = false
    assertFalse(d.manager.prefersBiometricUnlock)
    d.manager.biometricsEnabled = true

    d.biometrics.canUse = false
    assertFalse(d.manager.prefersBiometricUnlock, "no enrolled fingerprint is a different refusal from a wrong one")
    d.biometrics.canUse = true

    d.manager.registerBiometricFailure()
    d.manager.registerBiometricFailure()
    assertTrue(d.manager.keypadRequired)
    assertFalse(d.manager.prefersBiometricUnlock)
    d.manager.resetBiometricFailures()
    assertTrue(d.manager.prefersBiometricUnlock, "and the term comes back when the debt is paid")

    d.lockOurs()
    assertTrue(d.manager.isLockedOut)
    assertFalse(d.manager.prefersBiometricUnlock, "a biometric prompt during a cooldown is how a cooldown gets bypassed")

    val unlockedDevice = Duress()
    assertFalse(unlockedDevice.manager.prefersBiometricUnlock, "with no normal code there is nothing to unlock")
  }

  @Test
  fun askingForBiometricsWhileLockedOutThrowsInsteadOfPrompting() {
    val d = Duress()
    d.seedNormal("123456")
    d.lockOurs()
    val biometrics = PopopxDuressBiometricsDouble()
    assertFailsWith<PopopxDuressSetupError> { runBlocking { d.manager.requestBiometricUnlock(biometrics) } }
    assertEquals(0, biometrics.prompts, "nothing was asked of the system")
  }

  @Test
  fun aPromptThatDidNotSucceedCostsOneStrikeOnTheBiometricTable() {
    // iOS has one `guard success else` for the whole prompt (A:2080), so a cancelled sheet and a rejected finger cost
    // the same: the platform cannot tell them apart there, and a port that could would count differently.
    val dismissal = Duress()
    dismissal.seedNormal("123456")
    val answer = runBlocking {
      dismissal.manager.requestBiometricUnlock(PopopxDuressBiometricsDouble(outcome = LAResult.Error("cancelled")))
    }
    assertEquals(PopopxDuressAttempt.Wrong, answer)
    assertEquals(1, dismissal.manager.biometricFailures)
    assertEquals(0, dismissal.manager.failedAttemptCount, "the biometric table and the cooldown table are separate")

    val rejected = Duress()
    rejected.seedNormal("123456")
    runBlocking {
      rejected.manager.requestBiometricUnlock(PopopxDuressBiometricsDouble(outcome = LAResult.Failed("no match"), failedAttempts = 3))
    }
    // Android's prompt is finer-grained — `onAuthenticationFailed` fires per finger inside one sheet — so the
    // per-attempt callback is UI messaging and does not move the debt. Counting both would let one sheet with three
    // wrong fingers reach the keypad rule on a single prompt, which is not what iOS promises.
    assertEquals(1, rejected.manager.biometricFailures, "three wrong fingers inside one sheet is still one prompt")
    assertFalse(rejected.manager.keypadRequired)
  }

  @Test
  fun twoFailedPromptsMakeTheKeypadMandatoryAndTheGateThenRefusesToPrompt() {
    val d = Duress()
    d.seedNormal("123456")
    val biometrics = PopopxDuressBiometricsDouble(outcome = LAResult.Error(""))
    runBlocking { d.manager.requestBiometricUnlock(biometrics) }
    assertFalse(d.manager.keypadRequired, "one failure only raises the counter")
    runBlocking { d.manager.requestBiometricUnlock(biometrics) }
    assertEquals(2, d.manager.biometricFailures)
    assertTrue(d.manager.keypadRequired)
    // The guard is iOS's (A:2073), and the consequence is the point: once the keypad is mandatory a finger is not
    // asked again until a code is typed, so the prompt count has to stop climbing.
    val answer = runBlocking { d.manager.requestBiometricUnlock(biometrics) }
    assertEquals(PopopxDuressAttempt.NotConfigured, answer)
    assertEquals(2, biometrics.prompts, "the third prompt never happened")
    assertEquals(2, d.manager.biometricFailures, "and refusing does not add to the debt")
  }

  @Test
  fun theEngineKeepsTheBiometricDebtAndTheViewIsWhatPaysIt() {
    val d = Duress()
    d.seedNormal("123456")
    val biometrics = PopopxDuressBiometricsDouble(outcome = LAResult.Error(""))
    repeat(2) { runBlocking { d.manager.requestBiometricUnlock(biometrics) } }
    assertTrue(d.manager.keypadRequired)
    assertEquals(PopopxDuressAttempt.Unlocked, runBlocking { d.manager.submit("123456") })
    // A correct code does not clear the debt inside the engine, because iOS's `submit` does not either. The clearing
    // is the overlay's, in `completeUnlock`, and the order there is declared load-bearing
    // (PopopxAppLockOverlayView.swift:602-611): count first, then unlock, then tell the sensors. The Android keypad
    // calls `resetBiometricFailures()` on the same edge, and this assertion is what keeps that call from being
    // "optimized" into the engine, where it would be invisible to the other platform.
    assertTrue(d.manager.keypadRequired, "the engine boundary, not the view's behaviour")
    assertEquals(0, d.manager.failedAttemptCount, "while the cooldown table *is* zeroed by the code")
    d.manager.resetBiometricFailures()
    assertFalse(d.manager.keypadRequired)
    assertTrue(d.manager.prefersBiometricUnlock)
  }

  @Test
  fun aBiometricUnlockClearsTheCooldownAndItsRecord() {
    val d = Duress()
    d.seedNormal("123456")
    d.mistimes(1)
    val unlocked = runBlocking { d.manager.requestBiometricUnlock(PopopxDuressBiometricsDouble()) }
    assertEquals(PopopxDuressAttempt.Unlocked, unlocked)
    assertEquals(0, d.manager.failedAttemptCount)
    assertNull(d.storedLockout())
  }

  @Test
  fun turningBiometricsBackOnClearsTheDebtButNotTheLockout() {
    val d = Duress()
    d.seedNormal("123456")
    d.manager.registerBiometricFailure()
    d.lockOurs()
    d.manager.biometricsEnabled = false
    d.manager.biometricsEnabled = true
    assertEquals(0, d.manager.biometricFailures)
    assertFalse(d.manager.keypadRequired)
    assertTrue(d.manager.isLockedOut, "the cooldown is not a biometric debt and a switch does not pay it")
  }

  @Test
  fun anUnavailableBiometricIsReferredToTheKeypadNotTreatedAsAFailure() {
    val d = Duress()
    d.seedNormal("123456")
    val answer = runBlocking { d.manager.requestBiometricUnlock(PopopxDuressBiometricsDouble(canUse = false)) }
    assertEquals(PopopxDuressAttempt.NotConfigured, answer)
    assertEquals(0, d.manager.biometricFailures)
  }

  @Test
  fun theDrillUsesTheSideEffectFreePathAndCannotWipe() {
    val d = Duress()
    d.manager.wipeOnTenthFailure = true
    d.seedNormal("123456")
    d.seedDuress("654321")
    // A drill that went through `submit` would be a wipe button wearing a help label.
    d.mistimes(2)
    val strikes = d.manager.failedAttemptCount
    repeat(12) { assertEquals(PopopxDuressOutcome.Duress, runBlocking { d.manager.drillDuressPin("654321") }) }
    assertEquals(strikes, d.manager.failedAttemptCount)
  }
}
