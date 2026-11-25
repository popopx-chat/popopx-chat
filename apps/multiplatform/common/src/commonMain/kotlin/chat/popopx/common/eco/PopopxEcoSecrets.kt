package chat.popopx.common.eco

import chat.popopx.common.crypto.base64Decode
import chat.popopx.common.crypto.base64Encode
import chat.popopx.common.crypto.hexDecode
import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.platform.cryptor
import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings

// The Keychain half of the eco module (PopopxEcoModels.swift:858-930, and the account names at :866-872).
//
// iOS keeps every secret in the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The
// equivalent here is the app's own `cryptor`, whose Android actual is an AndroidKeyStore AES-GCM key
// created per alias and whose desktop actual is the plaintext pass-through it has always been. The
// ciphertext and the IV are stored as base64 in `settings`, exactly like `DatabaseUtils.KeyStoreItem`
// does for the database passphrase, so this module adds no second keystore and no new platform call.
//
// The plaintext handed to `cryptor` is the secret's LOWER-CASE HEX, not its bytes: `encryptText` takes a
// String and turns it back into bytes with UTF-8 on the way out, which is lossy for arbitrary key
// material. Hex is the smallest encoding that survives a round trip through a text-only cipher API.

/** The Keychain item names of this module, spelled as on iOS so a migrated device could be read by either. */
object PopopxEcoKeychain {
  const val SERVICE = "popopx.eco"

  fun sessionAccount(contactId: Long): String = "session.$contactId"

  /** The channel's Ed25519 trust root, keyed by channel id. */
  fun channelAccount(channelId: String): String = "channel.$channelId.pub"

  /** One epoch key, with the epoch in the name so an old epoch can be revoked without touching the current one. */
  fun epochAccount(channelId: String, epoch: Int): String = "channel.$channelId.epoch.$epoch"

  /** Which epoch this channel is on, kept apart from the keys so a launch finds the active key without enumerating. */
  fun currentEpochAccount(channelId: String): String = "channel.$channelId.epoch.current"
}

internal object PopopxEcoSecrets {
  private const val PREFIX = "popopx.eco.kc."
  private const val MAX_SECRET_BYTES = 4096

  // `defaults` is a parameter, not the global, so a unit test can drive this whole layer over an
  // in-memory store; the desktop global writes to the user's own preferences file on every put.
  fun write(data: ByteArray, account: String, defaults: Settings = settings): Boolean {
    if (data.isEmpty() || data.size > MAX_SECRET_BYTES) return false
    return try {
      val (cipherText, iv) = cryptor.encryptText(hexEncode(data), account)
      defaults.putString(PREFIX + account + ".ct", base64Encode(cipherText))
      defaults.putString(PREFIX + account + ".iv", base64Encode(iv))
      true
    } catch (e: Exception) {
      false
    }
  }

  fun read(account: String, defaults: Settings = settings): ByteArray? = try {
    val cipherText = defaults.getStringOrNull(PREFIX + account + ".ct") ?: return null
    val iv = defaults.getStringOrNull(PREFIX + account + ".iv") ?: return null
    val hex = cryptor.decryptData(base64Decode(cipherText) ?: return null, base64Decode(iv) ?: return null, account) ?: return null
    hexDecode(hex, MAX_SECRET_BYTES)
  } catch (e: Exception) {
    null
  }

  fun contains(account: String, defaults: Settings = settings): Boolean = read(account, defaults) != null

  fun remove(account: String, defaults: Settings = settings) {
    try {
      cryptor.deleteKey(account)
    } catch (e: Exception) {
      // The alias may not exist on this device; the slots below are the part that must go.
    }
    defaults.remove(PREFIX + account + ".ct")
    defaults.remove(PREFIX + account + ".iv")
  }

  /** The `epoch` value is written as decimal text, the same item iOS stores as `Data("\(epoch)".utf8)`. */
  fun writeEpochNumber(epoch: Int, account: String, defaults: Settings = settings): Boolean =
    write(epoch.toString().encodeToByteArray(), account, defaults)

  fun readEpochNumber(account: String, defaults: Settings = settings): Int? = read(account, defaults)?.decodeToString()?.trim()?.toIntOrNull()
}
