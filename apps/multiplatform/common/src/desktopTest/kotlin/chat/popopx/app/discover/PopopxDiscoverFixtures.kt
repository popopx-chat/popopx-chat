package chat.popopx.app.discover

import chat.popopx.common.crypto.base64UrlEncode
import chat.popopx.common.crypto.ed25519PublicKey
import chat.popopx.common.crypto.ed25519Sign
import chat.popopx.common.crypto.hexDecode
import chat.popopx.common.discover.PopopxDiscoverLedger
import chat.popopx.common.discover.PopopxNodeCommand
import chat.popopx.common.discover.PopopxShortfallNotice
import chat.popopx.common.discover.PopopxSubscriptionEngine
import com.russhwolf.settings.PropertiesSettings
import com.russhwolf.settings.Settings
import java.io.IOException
import java.util.Properties

// Shared fixtures for the Discover port tests.
//
// `PropertiesSettings(Properties()) { }` and NOT the app's own `settings`: the desktop actual of
// `chat.popopx.common.platform.settings` flushes to the developer's real preference store on every
// put, so a test that touched it would edit the user's machine. (Same rule the eco fixtures state,
// PopopxEcoFixtures.kt:10-15.)

internal fun discoverSettings(): Settings = PropertiesSettings(Properties()) { }

/** A clock the test turns by hand; every seam in the engine reads time through it. */
internal class DiscoverClock(var currentMs: Long) {
  operator fun invoke(): Long = currentMs

  fun advanceMillis(millis: Long) {
    currentMs += millis
  }

  fun advanceSeconds(seconds: Long) {
    currentMs += seconds * 1_000L
  }

  fun advanceDays(days: Long) = advanceSeconds(days * 86_400L)
}

/**
 * The wallet seam. `accept` mirrors a `payForService` that throws (the balance was checked again
 * and refused); balance is debited per successful charge, which is what makes the sweep's
 * per-row balance read (DiscoverSubscriptionManager.swift:342) observable.
 */
internal class FakeLedger(
  override var balance: Int = 0,
  var accept: Boolean = true,
) : PopopxDiscoverLedger {
  val notes = ArrayList<String>()
  val amounts = ArrayList<Int>()
  var balanceReads = 0
  var chargeAttempts = 0
  var charges = 0

  override fun payForService(amount: Int, note: String): Boolean {
    chargeAttempts++
    if (!accept) return false
    if (amount > balance) return false
    balance -= amount
    amounts.add(amount)
    notes.add(note)
    charges++
    return true
  }
}

/**
 * Settings that fails writes for one key, to exercise the charge-committed/state-lost branch
 * (PopopxEcoSecrets.write catches every Exception from the put and returns false, so the failure
 * surfaces as a keystore failure exactly like a locked Keychain would).
 */
internal class FailingPutSettings(
  private val delegate: Settings,
  private val failingKey: String,
) : Settings by delegate {
  override fun putString(name: String, value: String) {
    if (name == failingKey) throw IOException("simulated keystore failure")
    delegate.putString(name, value)
  }
}

/** The keystore slot names PopopxEcoSecrets actually puts through Settings — `PREFIX + account + ".ct"`. */
internal const val SUBSCRIPTIONS_CT_KEY = "popopx.eco.kc.popopx.discover.subscriptions.ct"

/**
 * Engine over in-memory settings and a hand-turned clock, with every seam recorded. No test may
 * construct the real `shared` — its defaults are the platform's own `settings`/`Log`.
 */
internal class EngineHarness(
  val engine: PopopxSubscriptionEngine,
  val clock: DiscoverClock,
  val ledger: FakeLedger,
  val settings: Settings,
  val logs: MutableList<String> = ArrayList(),
  val posted: MutableList<PopopxShortfallNotice> = ArrayList(),
  val sent: MutableList<Pair<PopopxNodeCommand, Long>> = ArrayList(),
  var authorised: Boolean = false,
  var posterAccepts: Boolean = true,
  var senderAccepts: Boolean = true,
) {
  fun lastSentCommand(): PopopxNodeCommand? = sent.lastOrNull()?.first
}

internal fun discoverHarness(
  settings: Settings = discoverSettings(),
  nowMs: Long = 1_700_000_000_000L,
  balance: Int = 0,
  ecoClaims: (String) -> Boolean = { false },
): EngineHarness {
  val clock = DiscoverClock(nowMs)
  val ledger = FakeLedger(balance)
  var harness: EngineHarness? = null
  val engine =
    PopopxSubscriptionEngine(
      defaults = settings,
      ledger = ledger,
      notificationsAuthorised = { harness?.authorised ?: false },
      shortfallPoster = { harness!!.posted.add(it); harness!!.posterAccepts },
      nodeCommandSender = { command, contactId -> harness!!.sent.add(command to contactId); harness!!.senderAccepts },
      ecoLinkConsumed = ecoClaims,
      nowMs = { clock() },
      logger = { harness?.logs?.add(it) },
    )
  return EngineHarness(engine, clock, ledger, settings).also { harness = it }
}

/** The short form for tests that only need an engine over given settings/clock. */
internal fun discoverEngine(
  settings: Settings,
  clock: DiscoverClock,
  ledger: PopopxDiscoverLedger = PopopxDiscoverLedger.UNPAID,
  ecoLinkConsumed: (String) -> Boolean = { false },
): PopopxSubscriptionEngine =
  PopopxSubscriptionEngine(
    defaults = settings,
    ledger = ledger,
    ecoLinkConsumed = ecoLinkConsumed,
    nowMs = { clock() },
  )

// Offers for the engine paths are signed HERE with the same Ed25519 the port verifies with; the
// CryptoKit-produced ones live in PopopxDiscoverSwiftVectors.kt. Kotlin's signing is deterministic,
// CryptoKit's is randomised, so in-process minting is the only practical way to stamp arbitrary
// iat/exp windows, and cross-platform acceptance is pinned by the vectors instead.

/** The seed the eco vectors also use (PopopxSwiftVectors.kt:25) — same key, two modules, consistent by construction. */
internal val discoverSeed: ByteArray =
  hexDecode("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", 64)!!

internal val discoverPublicKeyBase64Url: String = base64UrlEncode(ed25519PublicKey(discoverSeed)!!)

internal fun offerBody(
  node: String = "ppx-mac-test-1",
  iatSeconds: Long,
  expSeconds: Long,
  key: String = discoverPublicKeyBase64Url,
  link: String = "popopx://invite?one-time=Kf3mQ8xR2v",
  v: Int? = 1,
  once: Boolean? = true,
): String =
  buildString {
    append('{')
    if (v != null) append("\"v\":").append(v).append(',')
    append("\"node\":\"").append(node).append('"')
    append(",\"key\":\"").append(key).append('"')
    append(",\"link\":\"").append(link).append('"')
    append(",\"iat\":").append(iatSeconds)
    append(",\"exp\":").append(expSeconds)
    if (once != null) append(",\"once\":").append(once)
    append('}')
  }

internal fun signedOfferCode(bodyJson: String, seed: ByteArray = discoverSeed): String {
  val bodyBytes = bodyJson.encodeToByteArray()
  val signature = ed25519Sign(seed, bodyBytes)!!
  return "PPXNODE1-${base64UrlEncode(bodyBytes)}.${base64UrlEncode(signature)}"
}

/** A well-formed live offer whose iat/exp bracket `nowSeconds`, as the Mac stamps it: 900 s. */
internal fun liveOfferCode(nowMs: Long, lifetimeSeconds: Long = 900L, node: String = "ppx-mac-test-1"): String {
  val nowSeconds = nowMs / 1_000L
  return signedOfferCode(offerBody(node = node, iatSeconds = nowSeconds, expSeconds = nowSeconds + lifetimeSeconds))
}
