package chat.popopx.app.duress

import chat.popopx.common.duress.PopopxDuressAuthManager
import chat.popopx.common.duress.PopopxDuressBiometrics
import chat.popopx.common.duress.PopopxDuressKv
import chat.popopx.common.duress.PopopxDuressCrypto
import chat.popopx.common.duress.PopopxDuressAccounts
import chat.popopx.common.duress.PopopxUpstreamMode
import chat.popopx.common.duress.PopopxUpstreamPasscode
import chat.popopx.common.views.helpers.LAResult
import com.russhwolf.settings.PropertiesSettings
import com.russhwolf.settings.Settings
import java.security.MessageDigest
import java.util.Properties

// The doubles the duress engine is driven with, and the one helper that makes its timing claims observable.
//
// Every settings bag lives inside the test, never in the app-wide `settings`, for the same reason the cfgsec
// fixtures give: the shared instance writes real preference files, so a strike recorded by one test would decide
// the next one's cooldown.

internal fun duressSettings(): Settings = PropertiesSettings(Properties()) { }

/**
 * A stand-in derivation whose cost is a hash instead of 100,000 HMACs.
 *
 * It exists so that the suite can assert *how many* derivations ran, which is the only way to test "constant work:
 * always two derivations" — with the real function the same assertion costs 0.7 s per attempt and still does not
 * measure anything a counter measures better. The digest covers password, salt **and** iteration count, because a
 * fake that ignored any of the three would let a wrong call site pass: the same-code gate depends on re-deriving
 * with the *other* record's salt and iteration count, and a salt-blind fake would match on its own.
 */
internal fun duressFakeDerive(password: String, salt: ByteArray, iterations: Int): ByteArray {
  val digest = MessageDigest.getInstance("SHA-256")
    .digest("$password|${PopopxDuressCrypto.toHex(salt)}|$iterations".toByteArray(Charsets.UTF_8))
  return digest.copyOf(PopopxDuressCrypto.HASH_BYTES)
}

/**
 * The record store, with the two questions the real one can answer separately kept separate here too.
 *
 * [unreadable] models the case the split exists for: a key that is present but whose value cannot be decoded, which
 * is what a backup restore leaves behind when the keystore alias did not come with it. `exists` says yes, `read`
 * says no, and the engine must not collapse them.
 */
class PopopxDuressKvDouble : PopopxDuressKv {
  val records = LinkedHashMap<String, String>()
  var unreadable: String? = null
  var failWrites = false

  var updates = 0
  var adds = 0
  var deletes = 0

  override fun read(key: String): String? = if (key == unreadable) null else records[key]

  override fun exists(key: String): Boolean = records.containsKey(key)

  override fun update(key: String, value: String): Boolean {
    updates += 1
    if (failWrites || !records.containsKey(key)) return false
    records[key] = value
    return true
  }

  override fun add(key: String, value: String): Boolean {
    adds += 1
    if (failWrites || records.containsKey(key)) return false
    records[key] = value
    return true
  }

  override fun delete(key: String): Boolean {
    deletes += 1
    val removed = records.remove(key)
    if (unreadable == key) unreadable = null
    return removed != null
  }
}

/** The upstream passcode, recorded rather than performed, so a refusal branch can be shown to have written nothing. */
class PopopxUpstreamDouble(
  var app: ByteArray? = null,
  var selfDestruct: ByteArray? = null,
  var flag: Boolean = false,
  var currentMode: PopopxUpstreamMode = PopopxUpstreamMode.PASSCODE,
) : PopopxUpstreamPasscode {
  /** Each mutation, in the order it happened. */
  val writes = mutableListOf<String>()

  override fun appPasscode(): ByteArray? = app

  override fun selfDestructPasscode(): ByteArray? = selfDestruct

  override fun selfDestructFlag(): Boolean = flag

  override fun mode(): PopopxUpstreamMode = currentMode

  override fun removeAppPasscode() { app = null; writes.add("removeApp") }

  override fun removeSelfDestructPasscode() { selfDestruct = null; writes.add("removeSelfDestruct") }

  override fun removeSelfDestructFlag() { flag = false; writes.add("removeFlag") }

  override fun setMode(mode: PopopxUpstreamMode) { currentMode = mode; writes.add("setMode:$mode") }
}

/** The biometric prompt, with the two answers that must not be confused kept separately triggerable. */
class PopopxDuressBiometricsDouble(
  var canUse: Boolean = true,
  var outcome: LAResult = LAResult.Success,

  /** How many per-attempt failures to report before the terminal [outcome]. */
  var failedAttempts: Int = 0,
) : PopopxDuressBiometrics {
  var prompts = 0

  override fun available(): Boolean = canUse

  override suspend fun authenticate(title: String, subtitle: String?, onFailedAttempt: () -> Unit): LAResult {
    prompts += 1
    repeat(failedAttempts) { onFailedAttempt() }
    return outcome
  }
}

/**
 * One engine, its clock, its sleeps and its derivation count under test control.
 *
 * The clock is a plain number because the cooldown is a *wall-clock* record by design, and a test that has to sleep
 * through a 60-second lock to prove it is a test that gets deleted. [advance] moves it, and nothing else in the
 * suite can.
 */
class Duress(
  val kv: PopopxDuressKvDouble = PopopxDuressKvDouble(),
  val defaults: Settings = duressSettings(),
) {
  var clock: Double = 1_766_000_000.0
    private set

  /** (password, salt hex, iterations), in call order. */
  val derivations = mutableListOf<Triple<String, String, Int>>()

  /**
   * The order the engine did its observable work in: `draw`, `derive`, `sleep`, `read`.
   *
   * A list rather than three counters, because the claims under test are about *sequence* — the cooldown gate before
   * any derivation, the jitter drawn before the verdict exists — and three counters cannot show which came first.
   */
  val events = mutableListOf<String>()

  /** The sleeps the engine asked for, in seconds. */
  val sleeps = mutableListOf<Double>()

  /** What `random()` returns, so the jitter can be pinned instead of tolerated. */
  var jitter: Double = 0.0

  /**
   * The device's biometric capability, as the engine sees it.
   *
   * Injected rather than read from `popopxDuressBiometrics()`, because the desktop actual answers `false` always and
   * would make the routing rule `prefersBiometricUnlock` untestable here — the one term of five that decides whether
   * a finger or the keypad opens the app.
   */
  val biometrics = PopopxDuressBiometricsDouble()

  val manager = PopopxDuressAuthManager(
    kv = kv,
    defaults = defaults,
    now = { clock },
    derive = { password, salt, iterations ->
      events.add("derive")
      derivations.add(Triple(password, PopopxDuressCrypto.toHex(salt), iterations))
      duressFakeDerive(password, salt, iterations)
    },
    sleep = { seconds -> events.add("sleep"); sleeps.add(seconds) },
    random = { events.add("draw"); jitter },
    biometrics = { biometrics },
  )

  init {
    // The three switches, set the way a first-run device has them.
    manager.duressEnabled = true
    manager.biometricsEnabled = true
    manager.wipeOnTenthFailure = false
  }

  fun advance(seconds: Double) { clock += seconds }

  /** Writes a record by hand, so the iteration count and the salt are the test's choice. */
  fun seed(key: String, pin: String, iterations: Int = 1_000, saltHex: String = "01020304"): String {
    val salt = PopopxDuressCrypto.fromHex(saltHex)!!
    val hash = PopopxDuressCrypto.toHex(duressFakeDerive(pin, salt, iterations))
    val json = """{"version":1,"iterations":$iterations,"salt":"$saltHex","hash":"$hash"}"""
    require(kv.add(key, json)) { "seed refused: $key already present" }
    // A record written behind the manager's back is invisible to its cached `normalConfigured`/`duressConfigured`
    // until it re-reads, which is exactly what iOS does when the settings screen appears. Without this, a seeded
    // fixture is a device that has a code in storage and says it has none, and the refusal a test then measures is
    // the fixture's, not the engine's.
    manager.refreshConfiguration()
    return json
  }

  fun seedNormal(pin: String, iterations: Int = 1_000, saltHex: String = "01020304") =
    seed(PopopxDuressAccounts.NORMAL, pin, iterations, saltHex)

  fun seedDuress(pin: String, saltHex: String = "0a0b0c0d") =
    seed(PopopxDuressAccounts.DURESS, pin, 1_000, saltHex)

  /** The lockout counter as the engine wrote it, so a test can read the record instead of the field. */
  fun storedLockout(): String? = kv.records[PopopxDuressAccounts.LOCKOUT]
}
