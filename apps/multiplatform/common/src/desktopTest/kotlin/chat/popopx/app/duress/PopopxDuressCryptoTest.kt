package chat.popopx.app.duress

import chat.popopx.common.duress.PopopxDuressCrypto
import chat.popopx.common.duress.PopopxDuressVerifier
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The derivation layer, asserted against vectors this repository did not invent.
//
// Each hex below was produced twice, independently, on 2026-11-25: once by iOS's own hand-rolled
// `PopopxDuressCrypto.pbkdf2SHA256` (CryptoKit `HMAC<SHA256>` in a loop) run as a Swift script, and once by
// CPython's `hashlib.pbkdf2_hmac`. The two agreed on all five, which is what makes them usable as the oracle for a
// *third* implementation. `SecretKeyFactory("PBKDF2WithHmacSHA256")` is the third, and these tests are the
// agreement proof — without them, the two platforms' records would silently refuse each other's codes, and the
// failure would surface as "wrong password" on a restore, not as a bug.

class PopopxDuressCryptoTest {
  private fun bytes(hex: String) = PopopxDuressCrypto.fromHex(hex)!!

  @Test
  fun passwordAndSaltAtOneIterationMatchesTheIosImplementationByteForByte() {
    // The inputs are RFC 6070's first vector ("password" / "salt" / c=1 / dkLen=32) with the PRF swapped from
    // HMAC-SHA-1 to HMAC-SHA-256, so the hex is not quoted from any document — it is what the two implementations
    // above produced for those inputs.
    val derived = PopopxDuressCrypto.pbkdf2Sha256(
      PopopxDuressCrypto.KnownAnswers.PASSWORD,
      bytes(PopopxDuressCrypto.KnownAnswers.SALT_HEX),
      1,
      32,
    )
    assertEquals(PopopxDuressCrypto.KnownAnswers.C1_DK32, PopopxDuressCrypto.toHex(derived))
  }

  @Test
  fun twoIterationsIsNotOneIteration() {
    // The counter that `iterations` is supposed to be, checked as a *difference*: if the implementation ignored it,
    // this test and the one above could both be green while every stored record meant something else.
    val derived = PopopxDuressCrypto.pbkdf2Sha256(
      PopopxDuressCrypto.KnownAnswers.PASSWORD,
      bytes(PopopxDuressCrypto.KnownAnswers.SALT_HEX),
      2,
      32,
    )
    assertEquals(PopopxDuressCrypto.KnownAnswers.C2_DK32, PopopxDuressCrypto.toHex(derived))
  }

  @Test
  fun multiBlockOutputKeepsTheSingleBlockPrefixAndExtendsIt() {
    val derived = PopopxDuressCrypto.pbkdf2Sha256(
      PopopxDuressCrypto.KnownAnswers.PASSWORD,
      bytes(PopopxDuressCrypto.KnownAnswers.SALT_HEX),
      1,
      48,
    )
    val hex = PopopxDuressCrypto.toHex(derived)
    assertEquals(48, derived.size)
    assertEquals(PopopxDuressCrypto.KnownAnswers.C1_DK48, hex)
    // The boundary itself is the assertion: `dkLen=48` is two blocks, and a wrong counter endianness or a broken
    // concatenation shows up as a mismatch in the second half only.
    assertTrue(hex.startsWith(PopopxDuressCrypto.KnownAnswers.C1_DK32), "block 1 must stand alone")
    assertEquals(64, PopopxDuressCrypto.KnownAnswers.C1_DK32.length)
  }

  @Test
  fun productionShapedVectorAtOneHundredThousandIterations() {
    val derived = PopopxDuressCrypto.pbkdf2Sha256(
      PopopxDuressCrypto.KnownAnswers.PRODUCTION_PASSWORD,
      bytes(PopopxDuressCrypto.KnownAnswers.PRODUCTION_SALT_HEX),
      PopopxDuressCrypto.ITERATIONS,
      PopopxDuressCrypto.HASH_BYTES,
    )
    assertEquals(PopopxDuressCrypto.KnownAnswers.PRODUCTION_C100_000, PopopxDuressCrypto.toHex(derived))
  }

  @Test
  fun secondProductionVectorUsesADifferentSaltAndPassword() {
    val derived = PopopxDuressCrypto.pbkdf2Sha256(
      PopopxDuressCrypto.KnownAnswers.SECOND_PASSWORD,
      bytes(PopopxDuressCrypto.KnownAnswers.SECOND_SALT_HEX),
      PopopxDuressCrypto.ITERATIONS,
      PopopxDuressCrypto.HASH_BYTES,
    )
    assertEquals(PopopxDuressCrypto.KnownAnswers.SECOND_C100_000, PopopxDuressCrypto.toHex(derived))
  }

  @Test
  fun dimensionsMatchTheIosRecordShape() {
    assertEquals(32, PopopxDuressCrypto.SALT_BYTES)
    assertEquals(32, PopopxDuressCrypto.HASH_BYTES)
    assertEquals(100_000, PopopxDuressCrypto.ITERATIONS)
    assertEquals(64, PopopxDuressCrypto.toHex(PopopxDuressCrypto.randomSalt()).length)
  }

  @Test
  fun anUndeniableZeroCostRequestYieldsNoBytesRatherThanThrowing() {
    // iOS returns empty Data for these two, and every caller treats empty as "do not write". A throw here would
    // surface as a crash in the screen whose job is to stay quiet.
    assertEquals(0, PopopxDuressCrypto.pbkdf2Sha256("x", ByteArray(4), 0, 32).size)
    assertEquals(0, PopopxDuressCrypto.pbkdf2Sha256("x", ByteArray(4), -1, 32).size)
    assertEquals(0, PopopxDuressCrypto.pbkdf2Sha256("x", ByteArray(4), 100, 0).size)
    assertEquals(0, PopopxDuressCrypto.randomBytes(0).size)
    assertEquals(0, PopopxDuressCrypto.randomBytes(-5).size)
  }

  @Test
  fun randomSaltsDiffer() {
    val a = PopopxDuressCrypto.randomSalt()
    val b = PopopxDuressCrypto.randomSalt()
    assertEquals(a.size, b.size)
    assertFalse(a.contentEquals(b), "two calls returned the same 32 bytes")
  }

  @Test
  fun constantTimeComparisonRejectsUnequalLengthEmptyAndMismatch() {
    val stored = bytes(PopopxDuressCrypto.KnownAnswers.C1_DK32)
    assertTrue(PopopxDuressCrypto.matchesInConstantTime(stored.copyOf(), stored))
    assertFalse(PopopxDuressCrypto.matchesInConstantTime(stored.copyOfRange(0, 31), stored))
    // The guard that matters for a port: an empty pair is a *refusal*, not a match. A comparison that read "no
    // stored hash" as equal would unlock on an absent record.
    assertFalse(PopopxDuressCrypto.matchesInConstantTime(ByteArray(0), ByteArray(0)))
    val flipped = stored.copyOf().also { it[31] = (it[31].toInt() xor 1).toByte() }
    assertFalse(PopopxDuressCrypto.matchesInConstantTime(flipped, stored))
  }

  @Test
  fun hexRoundTripsAndRefusesAnythingThatIsNotHex() {
    val bytes = ByteArray(32) { (it * 7).toByte() }
    assertContentEquals(bytes, PopopxDuressCrypto.fromHex(PopopxDuressCrypto.toHex(bytes)))
    assertNull(PopopxDuressCrypto.fromHex(""))
    assertNull(PopopxDuressCrypto.fromHex("abc"), "odd length")
    assertNull(PopopxDuressCrypto.fromHex("zz"), "not digits")
    assertNull(PopopxDuressCrypto.fromHex("ab c"), "a space is not a nibble")
    assertEquals("00ff7a", PopopxDuressCrypto.toHex(byteArrayOf(0, -1, 0x7A)))
  }

  @Test
  fun theWorkloadPadCanNeverMatchARealDerivation() {
    val pad = PopopxDuressVerifier.workloadPad(PopopxDuressCrypto.randomSalt())
    assertEquals(PopopxDuressCrypto.ITERATIONS, pad.iterations, "the pad must cost what a real record costs")
    val padBytes = assertNotNull(PopopxDuressCrypto.fromHex(pad.hash))
    assertEquals(PopopxDuressCrypto.HASH_BYTES, padBytes.size)
    assertTrue(padBytes.all { it == 0.toByte() })
    // Any password, hashed with the pad's own salt, differs — otherwise "the record was missing" would unlock.
    val candidate = PopopxDuressCrypto.pbkdf2Sha256("000000", PopopxDuressCrypto.fromHex(pad.salt)!!, PopopxDuressCrypto.ITERATIONS, PopopxDuressCrypto.HASH_BYTES)
    assertFalse(PopopxDuressCrypto.matchesInConstantTime(candidate, padBytes))
  }
}
