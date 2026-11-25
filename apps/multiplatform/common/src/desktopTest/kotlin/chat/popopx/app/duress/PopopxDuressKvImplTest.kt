package chat.popopx.app.duress

import chat.popopx.common.duress.PopopxDuressAccounts
import chat.popopx.common.duress.PopopxDuressCodec
import chat.popopx.common.duress.PopopxDuressKvImpl
import chat.popopx.common.duress.PopopxDuressLockoutRecord
import chat.popopx.common.duress.PopopxDuressVerifier
import com.russhwolf.settings.PropertiesSettings
import com.russhwolf.settings.Settings
import java.util.Properties
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The keystore-shaped key-value tier, exercised against the real `cryptor`.
//
// On desktop that real `cryptor` is upstream's plaintext pass-through (`Cryptor.desktop.kt:3-17`, red-lined and
// deliberately untouched), so what these tests can prove is the *contract the store depends on*: that `update` and
// `add` are mutually exclusive, that `exists` answers presence while `read` answers readability, and that a refused
// write leaves nothing behind. What they cannot prove is anything about AndroidKeyStore — an alias surviving a
// failed write, StrongBox availability, `WhenUnlocked` semantics — and that gap is stated here rather than left to a
// reader who assumes a green suite covers it.

private const val KEY = PopopxDuressAccounts.DURESS

/** The bag plus the raw `Properties` under it, so a test can name the slots actually written. */
private class Bag {
  val properties = Properties()
  val settings: Settings = PropertiesSettingsOf(properties)
  val kv = PopopxDuressKvImpl(settings)
  fun slotNames(): Set<String> = properties.stringPropertyNames().toList().sorted().map { it.removePrefix(KEY) }.toSet()
}

private fun PropertiesSettingsOf(properties: Properties): Settings = PropertiesSettings(properties) { }

/** Valid base64 of the given text, because `exists` and `read` disagree only for bytes that *decode*. */
private fun b64(text: String): String = java.util.Base64.getEncoder().encodeToString(text.toByteArray())

private fun hexBytes(count: Int): String = (0 until count).joinToString("") { (it % 256).toString(16).padStart(2, '0') }

class PopopxDuressKvImplTest {
  @Test
  fun aRecordSurvivesASecondReaderOverTheSameBag() {
    val bag = Bag()
    val record = """{"version":1,"iterations":100000,"salt":"aa","hash":"bb"}"""
    assertTrue(bag.kv.add(KEY, record))
    // A second instance over the same preferences is the same device after a restart, which is the only reason this
    // tier exists instead of an in-memory map.
    assertEquals(record, PopopxDuressKvImpl(bag.settings).read(KEY))
    assertTrue(PopopxDuressKvImpl(bag.settings).exists(KEY))
  }

  @Test
  fun theCipherTextAndTheIvAreStoredAsTwoSeparateSlots() {
    val bag = Bag()
    assertTrue(bag.kv.add(KEY, "value"))
    assertNotNull(bag.settings.getStringOrNull("$KEY.ct"))
    assertNotNull(bag.settings.getStringOrNull("$KEY.iv"))
    // The shape `PopopxEcoSecrets` and the configuration vault already use, so one keystore layout serves all three
    // tiers and an operator can read a device's dump against the iOS names.
    assertEquals(b64("value"), bag.settings.getStringOrNull("$KEY.ct"))
    assertNull(bag.settings.getStringOrNull("$KEY.plain"), "nothing is stored under a plaintext-looking name")
  }

  @Test
  fun addRefusesWhereSomethingAlreadyExists() {
    val bag = Bag()
    assertTrue(bag.kv.add(KEY, "first"))
    assertFalse(bag.kv.add(KEY, "second"), "clear-then-add is exactly the shape that loses a lockout counter")
    assertEquals("first", bag.kv.read(KEY))
  }

  @Test
  fun updateRefusesWhereNothingExists() {
    val bag = Bag()
    assertFalse(bag.kv.update(KEY, "only"))
    assertFalse(bag.kv.exists(KEY))
    assertNull(bag.kv.read(KEY))
    assertTrue(bag.kv.add(KEY, "only"))
    assertTrue(bag.kv.update(KEY, "second"))
    assertEquals("second", bag.kv.read(KEY))
  }

  @Test
  fun anEmptyValueIsRefusedRatherThanStoredAsAnEmptyRecord() {
    val bag = Bag()
    assertFalse(bag.kv.add(KEY, ""))
    assertFalse(bag.kv.exists(KEY), "a refused write must not leave the key present but unreadable")
    assertNull(bag.kv.read(KEY))
    assertEquals(emptySet<String>(), bag.slotNames())
  }

  @Test
  fun deleteTakesBothSlotsAndReportsSuccessEvenForAnAbsentKey() {
    val bag = Bag()
    bag.kv.add(KEY, "value")
    assertTrue(bag.kv.delete(KEY))
    assertFalse(bag.kv.exists(KEY))
    assertNull(bag.kv.read(KEY))
    assertEquals(emptySet<String>(), bag.slotNames())
    // Idempotence is what lets `clearAllPins` delete all three accounts without checking which were configured.
    assertTrue(bag.kv.delete(KEY))
  }

  @Test
  fun presenceAndReadabilityAreDifferentAnswers() {
    val bag = Bag()
    // A slot whose bytes decode but whose contents are not a record. On desktop the decrypt pass-through hands the
    // text straight back, so the tier *reads* and the codec refuses; on a device the keystore itself refuses. Both
    // roads end at "absent to the caller", and the store's rule is written against that, not against the mechanism.
    bag.settings.putString("$KEY.ct", b64("not a record"))
    bag.settings.putString("$KEY.iv", b64("not a record"))
    assertTrue(bag.kv.exists(KEY))
    assertNotNull(bag.kv.read(KEY))
    assertNull(PopopxDuressCodec.decodeVerifier(bag.kv.read(KEY)))
    assertNull(PopopxDuressCodec.decodeLockout(bag.kv.read(KEY)))
  }

  @Test
  fun aHalfWrittenRecordIsAbsentAndCanBeReplacedByAdd() {
    val bag = Bag()
    bag.settings.putString("$KEY.ct", b64("part"))
    assertFalse(bag.kv.exists(KEY), "both slots are required for presence, so a half pair is neither")
    assertNull(bag.kv.read(KEY))
    // And because `exists` is false, `add` can overwrite the half-written pair instead of refusing forever.
    assertTrue(bag.kv.add(KEY, "whole"))
    assertEquals("whole", bag.kv.read(KEY))
  }

  @Test
  fun undecodableBase64IsReadAsAbsentWhileStillReportingPresence() {
    val bag = Bag()
    bag.settings.putString("$KEY.ct", "!!!not base64!!!")
    bag.settings.putString("$KEY.iv", "!!!not base64!!!")
    // `exists` says the bytes are here; `read` cannot open them. Collapsing the two would hand out four free
    // attempts on a device whose counter is present but corrupt.
    assertTrue(bag.kv.exists(KEY))
    assertNull(bag.kv.read(KEY))
    // The corrupt pair is still *present*, so the counter's own write path takes the `update` branch and is not
    // permanently wedged by a truncated write.
    assertTrue(bag.kv.update(KEY, """{"failedAttempts":5}"""))
    assertEquals(5, PopopxDuressCodec.decodeLockout(bag.kv.read(KEY))?.failedAttempts)
  }

  @Test
  fun aRecordWrittenByTheCodecRoundTripsThroughTheKvTier() {
    val bag = Bag()
    val verifier = PopopxDuressVerifier(iterations = 100_000, salt = hexBytes(32), hash = hexBytes(32))
    assertTrue(bag.kv.add(KEY, PopopxDuressCodec.encodeVerifier(verifier)))
    assertEquals(verifier, PopopxDuressCodec.decodeVerifier(bag.kv.read(KEY)))
    val lockout = PopopxDuressLockoutRecord(failedAttempts = 3, lockoutEndTimestamp = 1_766_000_000.5)
    assertTrue(bag.kv.update(KEY, PopopxDuressCodec.encodeLockout(lockout)))
    assertEquals(lockout, PopopxDuressCodec.decodeLockout(bag.kv.read(KEY)))
  }

  @Test
  fun theTwoSlotsAreTheWholeFootprintOfARecord() {
    val bag = Bag()
    bag.kv.add(KEY, "value")
    // No third key, no marker: `clearAllPins` can enumerate the accounts by name alone, and an operator comparing
    // two devices sees exactly the pairs the iOS dump shows.
    assertEquals(setOf(".ct", ".iv"), bag.slotNames())
    assertEquals("popopx.duress", PopopxDuressAccounts.SERVICE)
    assertEquals(
      listOf("popopx.duress.normal", "popopx.duress.duress", "popopx.duress.lockout"),
      PopopxDuressAccounts.ALL,
      "three accounts, not iOS's five: the mnemonic tier is not mounted this round",
    )
  }
}
