package chat.popopx.app.commerce

import chat.popopx.common.commerce.PopopxCommerceSignature
import chat.popopx.common.commerce.PopopxCommerceStore
import chat.popopx.common.commerce.PopopxCreditsManager
import chat.popopx.common.commerce.PopopxP2PVoucherVault
import com.russhwolf.settings.PropertiesSettings
import com.russhwolf.settings.Settings
import java.util.Properties

// Shared fixtures for the commerce tests.
//
// `PropertiesSettings(Properties()) { }` for the same reason the eco fixtures use it: the desktop actual of
// `chat.popopx.common.platform.settings` flushes to `~/Library/Preferences/…` on every put, and this module writes a
// wallet, a ledger, a replay guard AND a P-256 signing key. A test that used the global would mint a real key into
// the developer's own preferences — silent, permanent, and it still reports PASS.
//
// Every object here is constructed, never taken from a `shared` singleton, for the same reason: `shared` is bound to
// the global settings at class-initialisation time, so touching it from a test cannot be isolated afterwards.
//
// `ids` is a queue rather than a counter because one call mints several ids (a debit and its reversal), and a test
// that asserts on an id has to know which leg it is looking at.

internal class CommerceFixture(ids: List<String> = (1..40).map { "id.$it" }) {
  val defaults: Settings = PropertiesSettings(Properties()) { }
  val signature = PopopxCommerceSignature(defaults)
  private var clock = START_MS
  private val idQueue = ArrayDeque(ids)
  val store = PopopxCommerceStore(defaults)
  val vault = PopopxP2PVoucherVault(defaults, store, signature, { clock })
  val manager = manager()

  private var seedCount = 0

  fun newIds(count: Int) {
    repeat(count) { idQueue.addLast("id.${idQueue.size + 1}") }
  }

  /** The clock is a fixture field, not a parameter, because the grace-period tests move it and everything else reads it. */
  fun advanceMs(millis: Long) {
    clock += millis
  }

  fun nowMs(): Long = clock

  fun manager(): PopopxCreditsManager =
    PopopxCreditsManager(
      defaults = defaults,
      store = PopopxCommerceStore(defaults),
      vault = PopopxP2PVoucherVault(defaults, store, signature, { clock }),
      nowMs = { clock },
      newId = { if (idQueue.isEmpty()) "id.extra" else idQueue.removeFirst() },
    )

  /** A fresh instance over the same store, which is what a relaunch is. */
  fun reopened(): PopopxCreditsManager = manager()

  /**
   * Income without a scenario. `claimRedPacket` is the only public credit leg that takes an arbitrary amount and a
   * caller-chosen key, so a balance is seeded with it; every test below then exercises the leg it is about.
   */
  fun seed(amount: Int): PopopxCreditsManager {
    seedCount += 1
    check(manager.claimRedPacket("seed.$seedCount", amount, "seed"))
    return manager
  }

  companion object {
    const val START_MS = 1_700_000_000_000L
    const val DAY_MS = 86_400_000L
  }
}
