package chat.popopx.common.eco

import chat.popopx.common.crypto.AEAD_NONCE_BYTES
import chat.popopx.common.crypto.AEAD_TAG_BYTES
import chat.popopx.common.crypto.ED25519_PRIVATE_BYTES
import chat.popopx.common.crypto.ED25519_PUBLIC_BYTES
import chat.popopx.common.crypto.ED25519_SIGNATURE_BYTES
import chat.popopx.common.crypto.base64Decode
import chat.popopx.common.crypto.base64Encode
import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.chacha20Poly1305Open
import chat.popopx.common.crypto.chacha20Poly1305Seal
import chat.popopx.common.crypto.ed25519PublicKey
import chat.popopx.common.crypto.ed25519Sign
import chat.popopx.common.crypto.ed25519Verify
import chat.popopx.common.crypto.randomBytes
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Ported from apps/ios/Shared/Features/ServiceAccount/ChannelKeyRotationManager.swift:40-433.

/**
 * The base64 rule of this envelope, which is not the rule the eco frames use: **write** standard
 * alphabet with padding, **read** standard first and only then the URL-safe alphabet, so that a
 * `+`/`/` from an encoder that did not read this file still decodes.
 */
object PopopxChannelBase64 {
  fun encode(data: ByteArray): String = base64Encode(data)

  fun decode(text: String): ByteArray? = base64Decode(text) ?: base64UrlDecode(text)
}

/**
 * `popopx.channel.enc.v1`: one channel message, sealed under one epoch key and signed by the channel's
 * Ed25519 identity key. Five JSON keys, and the ciphertext is `ct ‖ tag(16)`, never the combined
 * single-buffer form — the tag position is what the [decrypt] length test below depends on.
 */
data class PopopxChannelEnvelope(
  val epoch: Int,
  val nonceBase64: String,
  val ciphertextBase64: String,
  val signatureBase64: String,
) {
  val nonceBytes: ByteArray? get() = PopopxChannelBase64.decode(nonceBase64)
  val ciphertextBytes: ByteArray? get() = PopopxChannelBase64.decode(ciphertextBase64)
  val signatureBytes: ByteArray? get() = PopopxChannelBase64.decode(signatureBase64)

  val isSane: Boolean
    get() =
      (nonceBytes?.size == AEAD_NONCE_BYTES) &&
        (ciphertextBytes?.size ?: 0) in (AEAD_TAG_BYTES + 1)..PopopxEcoLimits.MAXIMUM_CIPHERTEXT_BYTES &&
        (signatureBytes?.size == ED25519_SIGNATURE_BYTES) &&
        epoch in 1..PopopxEcoLimits.MAXIMUM_EPOCH

  /**
   * Fed to ChaCha20-Poly1305 as additional authenticated data. The channel id and the epoch are bound
   * here so ciphertext copied from another channel, or from another epoch of this one, fails the tag
   * instead of decrypting into somebody else's plaintext.
   */
  fun authenticationData(channelId: String, identityPublicKey: ByteArray): ByteArray {
    val bytes = ArrayList<Byte>()
    bytes.addAll(PROTOCOL_NAME.encodeToByteArray().toList())
    bytes.add(SEPARATOR)
    bytes.addAll(channelId.encodeToByteArray().toList())
    bytes.add(SEPARATOR)
    bytes.addAll(epoch.toString().encodeToByteArray().toList())
    bytes.add(SEPARATOR)
    bytes.addAll(identityPublicKey.toList())
    return bytes.toByteArray()
  }

  /**
   * Fed to Ed25519. Deliberately **not** the same bytes as the AAD: the nonce and the ciphertext are
   * covered here so a re-ordered or truncated payload is caught by the signature, and this is the
   * reason epoch `1` + a nonce beginning with `1` cannot be read as epoch `11`.
   */
  fun signingPreimage(channelId: String, nonce: ByteArray, ciphertext: ByteArray): ByteArray {
    val bytes = ArrayList<Byte>()
    bytes.addAll(PROTOCOL_NAME.encodeToByteArray().toList())
    bytes.add(SEPARATOR)
    bytes.addAll(channelId.encodeToByteArray().toList())
    bytes.add(SEPARATOR)
    bytes.addAll(epoch.toString().encodeToByteArray().toList())
    bytes.add(SEPARATOR)
    bytes.addAll(nonce.toList())
    bytes.add(SEPARATOR)
    bytes.addAll(ciphertext.toList())
    return bytes.toByteArray()
  }

  /**
   * Seal a plaintext. The signature is made with the identity **private** key, which no member device
   * holds: iOS's own `seal` therefore cannot produce an envelope at all (K:99), and this is the
   * issuer-side operation, used here by the round-trip tests and by nothing in the app.
   */
  fun seal(epochKey: ByteArray, identityPrivateKey: ByteArray, channelId: String, plaintext: ByteArray): PopopxChannelEnvelope? {
    if (plaintext.size > PopopxEcoLimits.MAXIMUM_PLAINTEXT_BYTES) return null
    if (epochKey.size != EPOCH_KEY_BYTES || identityPrivateKey.size != ED25519_PRIVATE_BYTES) return null
    val nonce = randomBytes(AEAD_NONCE_BYTES)
    val identityPublicKey = ed25519PublicKey(identityPrivateKey) ?: return null
    val aad = authenticationData(channelId, identityPublicKey)
    val sealed = chacha20Poly1305Seal(epochKey, nonce, plaintext, aad) ?: return null
    val signature = ed25519Sign(identityPrivateKey, signingPreimage(channelId, nonce, sealed)) ?: return null
    return PopopxChannelEnvelope(
      epoch = epoch,
      nonceBase64 = PopopxChannelBase64.encode(nonce),
      ciphertextBase64 = PopopxChannelBase64.encode(sealed),
      signatureBase64 = PopopxChannelBase64.encode(signature),
    )
  }

  /**
   * Verify, then decrypt. The order is the security order: a frame that does not carry this channel's
   * identity signature is never offered to the cipher, so the decryption is not an oracle.
   */
  fun decrypt(channelId: String, epochKey: ByteArray, identityPublicKey: ByteArray): ByteArray? {
    if (ciphertextBase64.ecoLength() > PopopxEcoLimits.MAXIMUM_CIPHERTEXT_BYTES) return null
    val nonce = nonceBytes?.takeIf { it.size == AEAD_NONCE_BYTES } ?: return null
    val sealed = ciphertextBytes?.takeIf { it.size > AEAD_TAG_BYTES } ?: return null
    val signature = signatureBytes?.takeIf { it.size == ED25519_SIGNATURE_BYTES } ?: return null
    if (epochKey.size != EPOCH_KEY_BYTES || identityPublicKey.size != ED25519_PUBLIC_BYTES) return null
    if (!PopopxChannelCrypto.verify(signature, signingPreimage(channelId, nonce, sealed), identityPublicKey)) return null
    return chacha20Poly1305Open(epochKey, nonce, sealed, authenticationData(channelId, identityPublicKey))
  }

  companion object {
    const val PROTOCOL_NAME = "popopx.channel.enc.v1"
    const val NONCE_BYTES = AEAD_NONCE_BYTES
    const val TAG_BYTES = AEAD_TAG_BYTES
    const val SIGNATURE_BYTES = ED25519_SIGNATURE_BYTES
    const val IDENTITY_KEY_BYTES = ED25519_PUBLIC_BYTES
    const val EPOCH_KEY_BYTES = 32

    private const val SEPARATOR: Byte = '|'.code.toByte()

    private const val KEY_PROTOCOL = "protocol"
    private const val KEY_EPOCH = "epoch"
    private const val KEY_NONCE = "nonce"
    private const val KEY_CIPHERTEXT = "ciphertext"
    private const val KEY_SIGNATURE = "signature"

    /** Throws [EcoReject] so the caller drops the whole frame. */
    fun of(obj: JsonObject): PopopxChannelEnvelope {
      val protocol = obj.string(KEY_PROTOCOL) ?: throw EcoReject()
      if (protocol != PROTOCOL_NAME) throw EcoReject()
      // iOS reads this as Int64 and lets `isSane` bound it; the Int reader rejects anything past
      // Int32 here instead, which is a smaller set of accepted frames and still fails the same test.
      val epoch = obj.int(KEY_EPOCH) ?: throw EcoReject()
      return PopopxChannelEnvelope(
        epoch = epoch,
        nonceBase64 = obj.stringOrThrow(KEY_NONCE),
        ciphertextBase64 = obj.stringOrThrow(KEY_CIPHERTEXT),
        signatureBase64 = obj.stringOrThrow(KEY_SIGNATURE),
      )
    }

    fun encode(envelope: PopopxChannelEnvelope): JsonObject = ecoJsonObject(
      KEY_PROTOCOL to JsonPrimitive(PROTOCOL_NAME),
      KEY_EPOCH to JsonPrimitive(envelope.epoch),
      KEY_NONCE to JsonPrimitive(envelope.nonceBase64),
      KEY_CIPHERTEXT to JsonPrimitive(envelope.ciphertextBase64),
      KEY_SIGNATURE to JsonPrimitive(envelope.signatureBase64),
    )
  }
}

/** Only the signature is checked here, and a malformed key or signature is a `false`, never a throw. */
object PopopxChannelCrypto {
  fun verify(signature: ByteArray, preimage: ByteArray, publicKey: ByteArray): Boolean {
    if (signature.size != PopopxChannelEnvelope.SIGNATURE_BYTES || publicKey.size != PopopxChannelEnvelope.IDENTITY_KEY_BYTES) {
      return false
    }
    return ed25519Verify(publicKey, preimage, signature)
  }
}

/**
 * The `ku` frame: an envelope plus the two facts about it that are not inside the envelope — which
 * channel it is for, and which epoch it was sealed under.
 */
data class PopopxChannelKeyUpdate(
  val channelId: String,
  val sealedUnderEpoch: Int,
  val revokePrevious: Boolean,
  val envelope: PopopxChannelEnvelope,
) {
  /** An update that seals and delivers the same epoch proves nothing, so it is not a rotation. */
  val isSane: Boolean
    get() =
      channelId.isNotEmpty() &&
        channelId.ecoLength() <= PopopxEcoLimits.MAXIMUM_VALUE_CHARACTERS &&
        sealedUnderEpoch in 1..PopopxEcoLimits.MAXIMUM_EPOCH &&
        envelope.epoch != sealedUnderEpoch &&
        envelope.isSane

  fun encode(): JsonObject {
    val obj = LinkedHashMap<String, JsonElement>()
    obj[KEY_CHANNEL_ID] = JsonPrimitive(channelId)
    obj[KEY_SEALED_UNDER_EPOCH] = JsonPrimitive(sealedUnderEpoch)
    if (revokePrevious) obj[KEY_REVOKE_PREVIOUS] = JsonPrimitive(true)
    obj[KEY_ENVELOPE] = PopopxChannelEnvelope.encode(envelope)
    return JsonObject(obj)
  }

  companion object {
    const val KEY_CHANNEL_ID = "ch"
    const val KEY_SEALED_UNDER_EPOCH = "se"
    const val KEY_REVOKE_PREVIOUS = "rp"
    const val KEY_ENVELOPE = "env"

    /** Throws [EcoReject]; `rp` is optional and its absence is false, its wrong type is a rejection. */
    fun of(obj: JsonObject): PopopxChannelKeyUpdate {
      val channelId = obj.string(KEY_CHANNEL_ID) ?: throw EcoReject()
      val sealedUnderEpoch = obj.int(KEY_SEALED_UNDER_EPOCH) ?: throw EcoReject()
      val revoke = obj.boolean(KEY_REVOKE_PREVIOUS) ?: false
      val envelope = PopopxChannelEnvelope.of(obj.child(KEY_ENVELOPE) ?: throw EcoReject())
      return PopopxChannelKeyUpdate(channelId, sealedUnderEpoch, revoke, envelope)
    }
  }
}

/**
 * The plaintext of a rotation: the new epoch key, base64url, exactly as
 * `PopopxSecurePayload.PopopxKeyRotationPayload` spells it. It carries no material the recipient did
 * not already have, which is why one signature can never be replayed against another channel.
 */
data class PopopxChannelEpochSecret(
  val epoch: Int,
  val keyBase64URL: String,
  val publicKeyBase64URL: String? = null,
  val expiresAtMs: Long? = null,
) {
  val isSane: Boolean
    get() =
      epoch in 1..PopopxEcoLimits.MAXIMUM_EPOCH &&
        base64UrlDecode(keyBase64URL)?.size == EPOCH_KEY_BYTES &&
        (publicKeyBase64URL == null || base64UrlDecode(publicKeyBase64URL)?.size == PopopxChannelEnvelope.IDENTITY_KEY_BYTES) &&
        (expiresAtMs == null || expiresAtMs > 0)

  fun encode(): JsonObject {
    val obj = LinkedHashMap<String, JsonElement>()
    obj[KEY_EPOCH] = JsonPrimitive(epoch)
    obj[KEY_KEY] = JsonPrimitive(keyBase64URL)
    publicKeyBase64URL?.let { obj[KEY_PUBLIC_KEY] = JsonPrimitive(it) }
    expiresAtMs?.let { obj[KEY_EXPIRES_AT] = JsonPrimitive(it) }
    return JsonObject(obj)
  }

  companion object {
    const val EPOCH_KEY_BYTES = PopopxChannelEnvelope.EPOCH_KEY_BYTES

    private const val KEY_EPOCH = "epoch"
    private const val KEY_KEY = "keyBase64URL"
    private const val KEY_PUBLIC_KEY = "publicKeyBase64URL"
    private const val KEY_EXPIRES_AT = "expiresAtMs"

    fun of(obj: JsonObject): PopopxChannelEpochSecret {
      val epoch = obj.int(KEY_EPOCH) ?: throw EcoReject()
      val key = obj.string(KEY_KEY) ?: throw EcoReject()
      val pub = obj.string(KEY_PUBLIC_KEY)
      val expires = obj.long(KEY_EXPIRES_AT)
      return PopopxChannelEpochSecret(epoch, key, pub, expires)
    }
  }
}
