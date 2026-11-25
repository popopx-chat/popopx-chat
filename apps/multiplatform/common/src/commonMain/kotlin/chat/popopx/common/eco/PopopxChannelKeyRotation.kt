package chat.popopx.common.eco

import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.base64UrlEncode
import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

// Ported from apps/ios/Shared/Features/ServiceAccount/ChannelKeyRotationManager.swift:400-861.

/** Why a rotation did or did not land. Separate values, because the UI must say which the user can act on. */
enum class PopopxKeyRejection {
  /** No identity key for that channel on this device, so nothing to verify against and nothing to decrypt with. */
  UNKNOWN_CHANNEL,

  SIGNATURE_INVALID,
  DECRYPT_FAILED,

  /** `sealedUnderEpoch` does not match any usable key here. */
  UNKNOWN_SEALED_EPOCH,

  /** The new epoch is not newer than what is stored, so accepting it would be a replay. */
  EPOCH_NOT_NEWER,

  /** The envelope decrypted into bytes that are not a well-formed epoch secret. */
  MALFORMED_PAYLOAD,

  /** A handover to a different identity key while a paid credential is pinned to another one. */
  ISSUER_CONFLICT,

  /** The frame or the plaintext broke a limit. */
  OUT_OF_RANGE,
}

sealed class PopopxKeyRotationResult {
  data class Installed(val epoch: Int, val revoked: List<Int>) : PopopxKeyRotationResult()

  /** A frame for an epoch this device already holds — a re-send, not a rotation. */
  data class AlreadyCurrent(val epoch: Int) : PopopxKeyRotationResult()

  data class Rejected(val reason: PopopxKeyRejection) : PopopxKeyRotationResult()
}

/** One stored epoch of one channel. The key itself lives in the keystore; this row carries its metadata. */
data class PopopxChannelEpoch(
  val epoch: Int,
  val keyBase64URL: String,
  val createdAtMs: Long,
  val expiresAtMs: Long?,
  val revoked: Boolean,
) {
  val keyData: ByteArray? get() = base64UrlDecode(keyBase64URL)

  /** Whether this key may open a frame right now. */
  fun isUsable(nowMs: Long = nowMillis()): Boolean = !revoked && (expiresAtMs == null || expiresAtMs!! > nowMs)
}

/** Everything this device knows about one channel. */
data class PopopxChannelKeyState(
  val channelId: String,
  /** The Ed25519 trust root, base64url. Written from the URI's `pub`, replaced only by a signed handover. */
  val identityKeyBase64URL: String,
  val epochs: List<PopopxChannelEpoch>,
  /** What a member should try first, kept explicit rather than "highest number wins". */
  val currentEpoch: Int,
  val addedAtMs: Long,
  /** Display and connection only; never part of a key or a signature. */
  val relay: String?,
  /**
   * The account that last sent a key frame, as a LOCAL row id. Not an identity: a rotation request is
   * addressed to it, and a channel imported from a URI alone has none until an update frame lands.
   */
  val issuerContactId: Long? = null,
) {
  val identityKeyData: ByteArray? get() = base64UrlDecode(identityKeyBase64URL)

  val currentKey: PopopxChannelEpoch?
    get() = epochs.firstOrNull { it.epoch == currentEpoch && it.isUsable() }

  /** Newest usable epoch, which is what "the key a new frame should seal under" means on the issuer side. */
  val newestUsableKey: PopopxChannelEpoch?
    get() = epochs.filter { it.isUsable() }.maxByOrNull { it.epoch }
}

/**
 * The owner of the channel key store.
 *
 * The settings index holds metadata only: [save] blanks each epoch's `keyBase64URL` before the write, so a
 * copy of the preferences file — a cloud backup of the app's data directory, a forensic image — carries
 * channel names and epoch numbers but never the keys. That is the whole point of the keystore half of this
 * store, and it is why [restoreKeys] re-reads the secret instead of trusting the row: an epoch whose key is
 * gone from the keystore is dropped, so the wipe is what actually disables a channel rather than the flag.
 */
class PopopxChannelKeyRotation(
  private val defaults: Settings = settings,
  private val verifier: (signature: ByteArray, preimage: ByteArray, publicKey: ByteArray) -> Boolean = PopopxChannelCrypto::verify,
) {
  private val json = Json { ignoreUnknownKeys = true }

  private val channelList = mutableListOf<PopopxChannelKeyState>()
  private var loaded = false

  var expiryWarningDays: Int = PopopxEcoLimits.DEFAULT_EXPIRY_WARNING_DAYS
    private set

  /** The channels this device holds keys for, in the order they were added so the list does not reshuffle. */
  val channels: List<PopopxChannelKeyState>
    get() {
      loadIfNeeded()
      return channelList.toList()
    }

  /**
   * A handover to a new identity key is refused when this device already paid under a different one.
   *
   * iOS calls `PopopxCreditsManager` directly from here; the two hooks below are the same question asked
   * through a seam, because the commerce ledger is a different module and this file must not own it.
   * Both default to "no conflict", which is what a device with no purchases answers anyway.
   */
  var channelIssuerConflict: (channelId: String, issuerPublicKeyBase64URL: String) -> Boolean = { _, _ -> false }
  var channelTicketExists: (channelId: String) -> Boolean = { false }

  fun loadIfNeeded() {
    if (loaded) return
    loaded = true
    val stored = defaults.getInt(PopopxEcoKeys.EXPIRY_WARNING_DAYS, 0)
    // An unset key reads as 0, which is below the floor and not a user choice.
    expiryWarningDays = if (stored < PopopxEcoLimits.MINIMUM_EXPIRY_WARNING_DAYS) {
      PopopxEcoLimits.DEFAULT_EXPIRY_WARNING_DAYS
    } else {
      minOf(stored, PopopxEcoLimits.MAXIMUM_EXPIRY_WARNING_DAYS)
    }
    val text = defaults.getStringOrNull(PopopxEcoKeys.CHANNEL_INDEX) ?: return
    val elements = try {
      json.parseToJsonElement(text).jsonArray
    } catch (e: Exception) {
      return
    }
    channelList.clear()
    for (element in elements) {
      val state = try {
        stateFromJson(element.jsonObject)
      } catch (e: Exception) {
        null
      } ?: continue
      val restored = restoreKeys(state) ?: continue
      channelList.add(restored)
    }
  }

  private fun restoreKeys(state: PopopxChannelKeyState): PopopxChannelKeyState? {
    if (state.channelId.isEmpty() || state.identityKeyData == null) return null
    if (state.epochs.size > PopopxEcoLimits.MAXIMUM_STORED_EPOCHS) return null
    if (state.epochs.any { it.epoch < 1 || it.epoch > PopopxEcoLimits.MAXIMUM_EPOCH }) return null
    // The epoch keys live in the keystore; a row whose secret is gone cannot decrypt anything and must
    // not be offered as "active".
    val epochs = state.epochs.mapNotNull { epoch ->
      val key = PopopxEcoSecrets.read(PopopxEcoKeychain.epochAccount(state.channelId, epoch.epoch), defaults)
      if (key != null && key.size == PopopxChannelEnvelope.EPOCH_KEY_BYTES) epoch.copy(keyBase64URL = base64UrlEncode(key)) else null
    }
    if (epochs.isEmpty()) return null
    val currentPresent = epochs.any { it.epoch == state.currentEpoch }
    return state.copy(
      epochs = epochs,
      currentEpoch = if (currentPresent) state.currentEpoch else epochs.maxOf { it.epoch },
    )
  }

  fun channel(channelId: String): PopopxChannelKeyState? {
    loadIfNeeded()
    return channelList.firstOrNull { it.channelId == channelId }
  }

  /**
   * Store the key material of a public channel URI. Re-importing the same channel id with the SAME key is
   * a no-op that still returns true (a link tapped twice is not an error); with a different identity key
   * it is refused unless this device holds no paid credential for that channel, otherwise a second channel
   * owner could take over a subscription paid to the first.
   */
  fun importPublicURI(text: String): Boolean {
    loadIfNeeded()
    val uri = PopopxChannelPublicURI.parse(text) ?: return false
    val key = base64UrlDecode(uri.masterKeyBase64Url) ?: return false
    val pub = base64UrlDecode(uri.issuerPublicKeyBase64Url) ?: return false
    val existing = channel(uri.channelId)
    if (existing != null) {
      if (existing.identityKeyBase64URL == uri.issuerPublicKeyBase64Url) return true
      return !channelIssuerConflict(uri.channelId, uri.issuerPublicKeyBase64Url) && !channelTicketExists(uri.channelId)
    }
    if (!PopopxEcoSecrets.write(key, PopopxEcoKeychain.epochAccount(uri.channelId, 1), defaults)) return false
    if (!PopopxEcoSecrets.write(pub, PopopxEcoKeychain.channelAccount(uri.channelId), defaults)) return false
    if (!PopopxEcoSecrets.writeEpochNumber(1, PopopxEcoKeychain.currentEpochAccount(uri.channelId), defaults)) return false
    val nowMs = nowMillis()
    channelList.add(
      PopopxChannelKeyState(
        channelId = uri.channelId,
        identityKeyBase64URL = uri.issuerPublicKeyBase64Url,
        epochs = listOf(PopopxChannelEpoch(1, uri.masterKeyBase64Url, nowMs, null, false)),
        currentEpoch = 1,
        addedAtMs = nowMs,
        relay = uri.relay,
      )
    )
    save()
    return true
  }

  /**
   * Apply a `channel_key_update` frame. The order is the security order and it is not negotiable: find the
   * channel, verify the signature against the stored identity key, THEN decrypt, THEN check the plaintext's
   * epoch is newer. Verifying first is what stops an attacker who cannot break the cipher from learning
   * anything by probing, and the "newer" test last is what turns a re-sent frame into a no-op rather than
   * a rollback.
   */
  fun apply(update: PopopxChannelKeyUpdate, issuerContactId: Long? = null): PopopxKeyRotationResult {
    loadIfNeeded()
    if (!update.isSane) return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.OUT_OF_RANGE)
    val index = channelList.indexOfFirst { it.channelId == update.channelId }
    if (index < 0) return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.UNKNOWN_CHANNEL)
    val state = channelList[index]
    val identityKey = state.identityKeyData ?: return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.UNKNOWN_CHANNEL)
    val nonce = update.envelope.nonceBytes
    val ciphertext = update.envelope.ciphertextBytes
    val signature = update.envelope.signatureBytes
    if (nonce == null || ciphertext == null || signature == null) {
      return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.OUT_OF_RANGE)
    }
    if (!verifier(signature, update.envelope.signingPreimage(update.channelId, nonce, ciphertext), identityKey)) {
      return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.SIGNATURE_INVALID)
    }
    val sealed = state.epochs.firstOrNull { it.epoch == update.sealedUnderEpoch }
      ?: return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.UNKNOWN_SEALED_EPOCH)
    val sealedKey = if (sealed.isUsable()) sealed.keyData else null
    if (sealedKey == null || sealedKey.size != PopopxChannelEnvelope.EPOCH_KEY_BYTES) {
      return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.UNKNOWN_SEALED_EPOCH)
    }
    val plaintext = update.envelope.decrypt(update.channelId, sealedKey, identityKey)
      ?: return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.DECRYPT_FAILED)
    val secret = epochSecretFromBytes(plaintext) ?: return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.MALFORMED_PAYLOAD)
    if (!secret.isSane) return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.MALFORMED_PAYLOAD)
    if (secret.epoch <= state.currentEpoch || secret.epoch <= sealed.epoch) {
      if (secret.epoch == state.currentEpoch) {
        // A re-send still tells this device who the issuer is, which is the one fact worth keeping from it.
        if (issuerContactId != null && state.issuerContactId != issuerContactId) {
          channelList[index] = state.copy(issuerContactId = issuerContactId)
          save()
        }
        return PopopxKeyRotationResult.AlreadyCurrent(secret.epoch)
      }
      return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.EPOCH_NOT_NEWER)
    }
    if (secret.epoch > PopopxEcoLimits.MAXIMUM_EPOCH) return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.OUT_OF_RANGE)

    // Identity-key handover: the envelope is signed by the OLD key, a legitimate handover, but this device
    // may have paid a credential pinned to it. Refusing keeps the paid credential meaningful.
    val newPub = secret.publicKeyBase64URL
    if (newPub != null && newPub != state.identityKeyBase64URL && channelIssuerConflict(state.channelId, newPub)) {
      return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.ISSUER_CONFLICT)
    }
    val newKey = base64UrlDecode(secret.keyBase64URL) ?: return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.MALFORMED_PAYLOAD)

    var next = state
    val revoked = ArrayList<Int>()
    if (update.revokePrevious) {
      val marked = ArrayList<PopopxChannelEpoch>(next.epochs.size)
      for (epoch in next.epochs) {
        if (epoch.epoch != secret.epoch && !epoch.revoked) {
          revoked.add(epoch.epoch)
          marked.add(epoch.copy(revoked = true))
        } else {
          marked.add(epoch)
        }
      }
      next = next.copy(epochs = marked)
    }
    next = next.copy(
      epochs = next.epochs.filter { it.epoch != secret.epoch } + PopopxChannelEpoch(secret.epoch, secret.keyBase64URL, nowMillis(), secret.expiresAtMs, false),
      currentEpoch = secret.epoch,
      issuerContactId = issuerContactId ?: state.issuerContactId,
      identityKeyBase64URL = newPub ?: state.identityKeyBase64URL,
    )
    // Bounded history, oldest SURVIVING epoch number dropped first: the cap is on the stored set, and a
    // revoked epoch is the least useful one to keep.
    if (next.epochs.size > PopopxEcoLimits.MAXIMUM_STORED_EPOCHS) {
      val sorted = next.epochs.sortedBy { it.epoch }
      next = next.copy(epochs = sorted.subList(sorted.size - PopopxEcoLimits.MAXIMUM_STORED_EPOCHS, sorted.size))
    }

    if (!PopopxEcoSecrets.write(newKey, PopopxEcoKeychain.epochAccount(next.channelId, secret.epoch), defaults)) {
      return PopopxKeyRotationResult.Rejected(PopopxKeyRejection.DECRYPT_FAILED)
    }
    PopopxEcoSecrets.writeEpochNumber(secret.epoch, PopopxEcoKeychain.currentEpochAccount(next.channelId), defaults)
    if (newPub != null) {
      base64UrlDecode(newPub)?.let { PopopxEcoSecrets.write(it, PopopxEcoKeychain.channelAccount(next.channelId), defaults) }
    }
    for (epoch in revoked) PopopxEcoSecrets.remove(PopopxEcoKeychain.epochAccount(next.channelId, epoch), defaults)
    channelList[index] = next
    save()
    return PopopxKeyRotationResult.Installed(secret.epoch, revoked)
  }

  /** How long before an epoch expires the key page starts saying so. Clamped, then written once. */
  fun setExpiryWarningDays(days: Int) {
    val clamped = days.coerceIn(PopopxEcoLimits.MINIMUM_EXPIRY_WARNING_DAYS, PopopxEcoLimits.MAXIMUM_EXPIRY_WARNING_DAYS)
    expiryWarningDays = clamped
    defaults.putInt(PopopxEcoKeys.EXPIRY_WARNING_DAYS, clamped)
  }

  /**
   * The member-side rotation request. This device cannot mint an epoch key, so the only honest "rotate"
   * is a request addressed to the account that issued the previous one.
   */
  fun rotationRequestText(channelId: String): String = "rotate:$channelId"

  private fun save() {
    val redacted = channelList.map { state -> state.copy(epochs = state.epochs.map { it.copy(keyBase64URL = "") }) }
    defaults.putString(PopopxEcoKeys.CHANNEL_INDEX, JsonArray(redacted.map { stateToJson(it) }).toString())
  }

  companion object {
    val shared: PopopxChannelKeyRotation = PopopxChannelKeyRotation()
  }
}

private fun epochSecretFromBytes(bytes: ByteArray): PopopxChannelEpochSecret? = try {
  PopopxChannelEpochSecret.of(Json.parseToJsonElement(bytes.decodeToString()).jsonObjectOrThrow())
} catch (e: Exception) {
  null
}

/** The plaintext a channel post is sealed from, encoded the way the envelope's own plaintext expects it. */
internal fun epochSecretBytes(secret: PopopxChannelEpochSecret): ByteArray = secret.encode().toString().encodeToByteArray()

private fun stateFromJson(obj: JsonObject): PopopxChannelKeyState {
  val channelId = obj.string("channelId") ?: throw EcoReject()
  val identity = obj.string("identityKeyBase64URL") ?: throw EcoReject()
  val epochs = obj.array("epochs")?.map { epochFromJson(it.jsonObjectOrThrow()) } ?: throw EcoReject()
  val currentEpoch = obj.int("currentEpoch") ?: throw EcoReject()
  val addedAtMs = obj.long("addedAtMs") ?: throw EcoReject()
  return PopopxChannelKeyState(channelId, identity, epochs, currentEpoch, addedAtMs, obj.string("relay"), obj.long("issuerContactId"))
}

private fun stateToJson(state: PopopxChannelKeyState): JsonObject {
  val obj = LinkedHashMap<String, JsonElement>()
  obj["channelId"] = JsonPrimitive(state.channelId)
  obj["identityKeyBase64URL"] = JsonPrimitive(state.identityKeyBase64URL)
  obj["epochs"] = JsonArray(state.epochs.map { epochToJson(it) })
  obj["currentEpoch"] = JsonPrimitive(state.currentEpoch)
  obj["addedAtMs"] = JsonPrimitive(state.addedAtMs)
  state.relay?.let { obj["relay"] = JsonPrimitive(it) }
  state.issuerContactId?.let { obj["issuerContactId"] = JsonPrimitive(it) }
  return JsonObject(obj)
}

private fun epochFromJson(obj: JsonObject): PopopxChannelEpoch {
  val epoch = obj.int("epoch") ?: throw EcoReject()
  val key = obj.string("keyBase64URL") ?: throw EcoReject()
  val createdAtMs = obj.long("createdAtMs") ?: throw EcoReject()
  val expiresAtMs = obj.long("expiresAtMs")
  val revoked = obj.boolean("revoked") ?: false
  return PopopxChannelEpoch(epoch, key, createdAtMs, expiresAtMs, revoked)
}

private fun epochToJson(epoch: PopopxChannelEpoch): JsonObject {
  val obj = LinkedHashMap<String, JsonElement>()
  obj["epoch"] = JsonPrimitive(epoch.epoch)
  obj["keyBase64URL"] = JsonPrimitive(epoch.keyBase64URL)
  obj["createdAtMs"] = JsonPrimitive(epoch.createdAtMs)
  epoch.expiresAtMs?.let { obj["expiresAtMs"] = JsonPrimitive(it) }
  obj["revoked"] = JsonPrimitive(epoch.revoked)
  return JsonObject(obj)
}

/** Wall clock in milliseconds, the unit every `…AtMs` field in this module is written in. */
internal fun nowMillis(): Long = System.currentTimeMillis()
