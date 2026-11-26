package chat.popopx.common.mesh

import chat.popopx.common.platform.CryptorInterface
import chat.popopx.common.platform.cryptor
import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings
import java.util.Base64

/**
 * The secret items the mesh keeps, behind the same four-method shape iOS gives its Keychain
 * (`Core/PopopxMeshStorage.swift:119-126`).
 *
 * On iOS these are generic-password items, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Here they are
 * AES-GCM blobs in the app's key-value store, keyed by the same `service`/`account` pair and encrypted
 * under an AndroidKeyStore alias derived from it — a replacement, not a port (§6.10), and the reason the
 * literals are kept verbatim: the two platforms' namespaces can then be compared line for line.
 */
interface PopopxMeshSecretStoring {
  /** null for an absent item and for one whose key no longer exists, which is iOS' `try?` at the call site. */
  fun data(service: String, account: String): ByteArray?

  /** true only when the bytes came back out equal, which is what iOS' `verifyStored` insists on. */
  fun set(data: ByteArray, service: String, account: String): Boolean

  /** true when nothing is left to read; an absent item counts as already erased. */
  fun remove(service: String, account: String): Boolean

  /** Panic wipe: one call empties the whole service, not one account at a time. */
  fun removeAll(service: String): Boolean
}

/**
 * A `Settings` + [CryptorInterface] implementation of [PopopxMeshSecretStoring].
 *
 * Two things this backend has to do that the Keychain does not:
 *
 * - It cannot enumerate the accounts under a service, so each service keeps a plain index of the account
 *   names written through it. The index holds no secret — an account name is a literal in the source — and
 *   it is what lets [removeAll] report a real result rather than guess at one account.
 * - A stored blob whose key is gone reads as absent, and a caller that sees absent mints a new identity.
 *   iOS behaves the same way, but here it is reachable — an app restore keeps the blobs and loses the
 *   keystore — so the gate sits deliberately before decryption: `CryptorInterface.decryptData` raises a
 *   user-visible alert when its alias is missing, and a cold start is not the place to show one. Probing
 *   with `keyStorage` first, which returns null without alerting, keeps the fallback silent.
 */
class PopopxMeshSecretStore(
  private val defaults: Settings = settings,
  private val secretCryptor: CryptorInterface = cryptor,
) : PopopxMeshSecretStoring {

  override fun data(service: String, account: String): ByteArray? =
    try {
      val cipherText = defaults.getStringOrNull(cipherKey(service, account))
      val initializationVector = defaults.getStringOrNull(ivKey(service, account))
      // `keyStorage` answers without alerting, which is the only reason it is asked before decrypting.
      if (cipherText == null || initializationVector == null || secretCryptor.keyStorage(alias(service, account)) == null) {
        null
      } else {
        val bytes = Base64.getDecoder().decode(cipherText)
        val iv = Base64.getDecoder().decode(initializationVector)
        secretCryptor.decryptData(bytes, iv, alias(service, account))?.meshHexToBytes()
      }
    } catch (e: Throwable) {
      null
    }

  /**
   * The write is reported as stored only once it has been read back, so a keystore that accepted the call
   * and kept nothing is a false rather than an identity that silently changes at the next launch.
   */
  override fun set(data: ByteArray, service: String, account: String): Boolean {
    val stored = try {
      val (cipherText, iv) = secretCryptor.encryptText(data.meshHex(), alias(service, account))
      defaults.putString(cipherKey(service, account), Base64.getEncoder().encodeToString(cipherText))
      defaults.putString(ivKey(service, account), Base64.getEncoder().encodeToString(iv))
      true
    } catch (e: Throwable) {
      false
    }
    if (!stored) return false
    if (data(service, account)?.contentEquals(data) != true) {
      remove(service, account)
      return false
    }
    addToIndex(service, account)
    return true
  }

  override fun remove(service: String, account: String): Boolean {
    val key = cipherKey(service, account)
    return try {
      if (defaults.getStringOrNull(key) != null) secretCryptor.deleteKey(alias(service, account))
      defaults.remove(key)
      defaults.remove(ivKey(service, account))
      // The alias is what a surviving copy of the key would be, so the erase is not believed until the
      // blob, the vector and the alias are all gone.
      if (defaults.getStringOrNull(key) != null || secretCryptor.keyStorage(alias(service, account)) != null) {
        return false
      }
      removeFromIndex(service, account)
      true
    } catch (e: Throwable) {
      false
    }
  }

  override fun removeAll(service: String): Boolean {
    var clean = true
    for (account in accounts(service)) {
      // Every account is attempted even after one fails: a wipe that stopped early would report what is
      // left as erased.
      if (!remove(service, account)) clean = false
    }
    defaults.remove(indexKey(service))
    return clean && accounts(service).isEmpty() && defaults.getStringOrNull(indexKey(service)) == null
  }

  private fun accounts(service: String): List<String> {
    val stored = runCatching { defaults.getStringOrNull(indexKey(service)) }.getOrNull()
      ?: return emptyList()
    if (stored.isEmpty()) return emptyList()
    return stored.split(SEPARATOR).filter { it.isNotEmpty() }
  }

  private fun addToIndex(service: String, account: String) {
    val known = accounts(service)
    if (known.contains(account)) return
    defaults.putString(indexKey(service), (known + account).joinToString(SEPARATOR))
  }

  private fun removeFromIndex(service: String, account: String) {
    val rest = accounts(service).filter { it != account }
    if (rest.isEmpty()) defaults.remove(indexKey(service))
    else defaults.putString(indexKey(service), rest.joinToString(SEPARATOR))
  }

  companion object {
    /** `PopopxMeshEngine.swift:77` — the namespace holding the Noise static key. */
    const val IDENTITY_SERVICE: String = "chat.popopx.mesh.identity"

    /** `PopopxMeshEngine.swift:78`. */
    const val IDENTITY_ACCOUNT: String = "noise-static-key"

    /** `IdentityMappingStore.swift:108,111` — the mapping table snapshot, which the pairing layer owns. */
    const val IDENTITY_MAP_SERVICE: String = "chat.popopx.mesh.identity-map"

    const val IDENTITY_MAP_ACCOUNT: String = "identity-map.v1"

    /** `PopopxMeshPaths.directoryName` — the mesh sandbox inside the app's Documents. */
    const val DIRECTORY_NAME: String = "popopx_mesh"

    /** `IdentityMappingStore.swift:113` / `PopopxMeshKillSwitch.swift:194` — the global switch. */
    const val MESH_ENABLED_KEY: String = "chat.popopx.mesh.enabled"

    /** `IdentityMappingStore.swift:112`, erased with the mapping table and owned by the pairing layer. */
    const val PAIRING_POLICY_KEY: String = "chat.popopx.mesh.pairingPolicy"

    private const val SEPARATOR = ","

    /** Unkeyed: the four call sites below are the only readers, and the shape must stay comparable to iOS. */
    private fun cipherKey(service: String, account: String): String = "$service/$account.ct"

    private fun ivKey(service: String, account: String): String = "$service/$account.iv"

    private fun indexKey(service: String): String = "$service/.accounts"

    private fun alias(service: String, account: String): String = "$service.$account"
  }
}
