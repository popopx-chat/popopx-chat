package chat.popopx.common.duress

import chat.popopx.common.platform.cryptor
import com.russhwolf.settings.Settings
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The duress records, and the two different ways they are written.
 *
 * Mirrors `PopopxDuressVerifier` / `PopopxLockoutRecord` / the keychain layer of
 * `apps/ios/Shared/Features/AntiTheftDuress/PopopxDuressAuthManager.swift:269-298, 657-804`.
 *
 * iOS keeps these in the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and the lockout record
 * alone at `.afterFirstUnlockThisDeviceOnly` so a reboot does not hand the counter back. Android's keystore has
 * no such per-key attribute for a plain AES-GCM key, so the strength distinction collapses into the alias —
 * which is the deviation the plan already names (the keystore is a *substitute*, not a port). What is preserved is
 * the write strategy, because that one is not about strength:
 *
 * - Credentials: delete, then add. A stale ciphertext is worthless anyway, and a partial write must not be
 *   readable.
 * - Lockout: **update, and add only when the item is not found**. iOS's comment (A:777-778) is the reason:
 *   "clear-then-add would turn any failed write into deleting the old record too, and this record says how many
 *   times this person has already guessed wrong — wiping it hands those attempts back." So [PopopxDuressKv]
 *   exposes update and add as separate operations instead of one `put`, and a unified key-value helper would
 *   silently break the anti-rollback property this depends on.
 */

/** One stored entry: the salt it was derived with, and the hash that must match. */
@Serializable
data class PopopxDuressVerifier(
  /** Written and never read, exactly as iOS has it (A:276-280) — `iterations` is the only real compat lever. */
  val version: Int = VERSION,
  val iterations: Int,
  /** Lowercase hex, because the record travels as JSON text. */
  val salt: String,
  val hash: String,
) {
  companion object {
    const val VERSION: Int = 1

    /** All-zero hash: a record that can never match a real derivation, used to pad the cost of a missing one. */
    fun workloadPad(salt: ByteArray): PopopxDuressVerifier = PopopxDuressVerifier(
      iterations = PopopxDuressCrypto.ITERATIONS,
      salt = PopopxDuressCrypto.toHex(salt),
      hash = "0".repeat(PopopxDuressCrypto.HASH_BYTES * 2),
    )
  }
}

/**
 * The cooldown record.
 *
 * [lockoutEndTimestamp] is a wall-clock second, not a monotonic one — iOS's reasoning (A:659-666) is that the
 * only reason this record exists is "still there after killing the process and reopening it", and a monotonic
 * clock stops meaning anything across a process. The acknowledged hole: the owner can move the clock forward, but
 * `failedAttempts` survives that too, so clock-juggling walks him into the tenth gate instead of out of the lock.
 */
@Serializable
data class PopopxDuressLockoutRecord(
  val failedAttempts: Int,
  val lockoutEndTimestamp: Double? = null,
)

/**
 * The storage the records live in, split into the two write strategies rather than one setter.
 *
 * `exists` is separate from `read` because the two answers differ when a record is present but unreadable — a
 * keystore alias that was wiped behind surviving ciphertext, which is what a backup restore produces. For the
 * lockout counter, "absent" and "unreadable" must not be collapsed: treating an unreadable counter as absent
 * hands out four free attempts.
 */
interface PopopxDuressKv {
  fun read(key: String): String?
  fun exists(key: String): Boolean

  /** Writes only over an existing key. False when the key is absent or the write failed. */
  fun update(key: String, value: String): Boolean

  /** Writes only where nothing exists. False when the key is present or the write failed. */
  fun add(key: String, value: String): Boolean

  fun delete(key: String): Boolean
}

/**
 * The keystore-backed implementation: one sealed blob per key, base64 ciphertext plus base64 iv, in the shape
 * `PopopxEcoSecrets` and the configuration vault already use.
 *
 * Desktop is not special-cased here because `Cryptor.desktop.kt` is already a plaintext pass-through, and adding
 * a second actual that also does nothing would put the desktop build's behaviour somewhere other than where the
 * production one is decided.
 */
class PopopxDuressKvImpl(private val defaults: Settings) : PopopxDuressKv {
  private fun alias(key: String) = "${PopopxDuressAccounts.SERVICE}.$key"

  override fun read(key: String): String? = try {
    val cipherText = defaults.getStringOrNull("$key.ct") ?: return null
    val iv = defaults.getStringOrNull("$key.iv") ?: return null
    val bytes = decodeBase64(cipherText) ?: return null
    val ivBytes = decodeBase64(iv) ?: return null
    cryptor.decryptData(bytes, ivBytes, alias(key))
  } catch (e: Exception) {
    null
  }

  override fun exists(key: String): Boolean =
    defaults.getStringOrNull("$key.ct") != null && defaults.getStringOrNull("$key.iv") != null

  override fun update(key: String, value: String): Boolean = exists(key) && write(key, value)

  override fun add(key: String, value: String): Boolean = !exists(key) && write(key, value)

  override fun delete(key: String): Boolean {
    return try {
      cryptor.deleteKey(alias(key))
      defaults.remove("$key.ct")
      defaults.remove("$key.iv")
      true
    } catch (e: Exception) {
      false
    }
  }

  private fun write(key: String, value: String): Boolean {
    if (value.isEmpty()) return false
    return try {
      val (cipherText, iv) = cryptor.encryptText(value, alias(key))
      defaults.putString("$key.ct", encodeBase64(cipherText))
      defaults.putString("$key.iv", encodeBase64(iv))
      true
    } catch (e: Exception) {
      false
    }
  }

  private fun encodeBase64(bytes: ByteArray): String = java.util.Base64.getEncoder().encodeToString(bytes)

  private fun decodeBase64(text: String): ByteArray? = try {
    java.util.Base64.getDecoder().decode(text)
  } catch (e: IllegalArgumentException) {
    null
  }
}

/** The five iOS accounts, minus the two mnemonic ones this round does not mount (ruling 3). */
object PopopxDuressAccounts {
  const val SERVICE: String = "popopx.duress"
  const val NORMAL: String = "popopx.duress.normal"
  const val DURESS: String = "popopx.duress.duress"
  const val LOCKOUT: String = "popopx.duress.lockout"

  /**
   * What [PopopxDuressAuthManager.clearAllPins] removes.
   *
   * iOS deletes five accounts; two of them are the mnemonic and its phrase, which have no Android counterpart
   * this round, so the list is three long. The difference has to be stated where the deletion happens, not only
   * in the commit message: a reader comparing the two platforms will otherwise see a missing cleanup and conclude
   * the wipe is incomplete, when in fact there is no recovery phrase on this device to clean up.
   */
  val ALL: List<String> = listOf(NORMAL, DURESS, LOCKOUT)
}

internal object PopopxDuressCodec {
  /** One parser, strict, so a hand-edited record is "absent" rather than half-loaded. */
  private val json = Json { isLenient = false; ignoreUnknownKeys = false; encodeDefaults = true }

  fun encodeVerifier(record: PopopxDuressVerifier): String = json.encodeToString(PopopxDuressVerifier.serializer(), record)

  fun decodeVerifier(text: String?): PopopxDuressVerifier? = try {
    if (text == null) null else json.decodeFromString<PopopxDuressVerifier>(text)
  } catch (e: Exception) {
    null
  }

  fun encodeLockout(record: PopopxDuressLockoutRecord): String = json.encodeToString(PopopxDuressLockoutRecord.serializer(), record)

  fun decodeLockout(text: String?): PopopxDuressLockoutRecord? = try {
    if (text == null) null else json.decodeFromString<PopopxDuressLockoutRecord>(text)
  } catch (e: Exception) {
    null
  }
}
