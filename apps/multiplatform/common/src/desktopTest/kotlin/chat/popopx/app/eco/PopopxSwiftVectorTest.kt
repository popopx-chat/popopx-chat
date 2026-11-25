package chat.popopx.app.eco

import chat.popopx.common.crypto.base64Decode
import chat.popopx.common.crypto.base64Encode
import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.base64UrlEncode
import chat.popopx.common.crypto.derDecode
import chat.popopx.common.crypto.derEncode
import chat.popopx.common.crypto.ecdsaPublicKeyX963
import chat.popopx.common.crypto.ecdsaSignP256Sha256
import chat.popopx.common.crypto.ecdsaVerifyP256Sha256
import chat.popopx.common.crypto.ed25519PublicKey
import chat.popopx.common.crypto.ed25519Sign
import chat.popopx.common.crypto.ed25519Verify
import chat.popopx.common.crypto.hexDecode
import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.crypto.hmacSha256
import chat.popopx.common.crypto.sha256Hex
import chat.popopx.common.eco.PopopxChannelBase64
import chat.popopx.common.eco.PopopxChannelCrypto
import chat.popopx.common.eco.PopopxChannelEnvelope
import chat.popopx.common.eco.PopopxEcoSession
import chat.popopx.common.eco.PopopxH5Signature
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Every assertion here is against a value produced by Apple's CryptoKit, not by this port, so a passing
// run means the Kotlin agrees with the framework the iOS client uses: same AAD bytes, same signature
// preimage, same ciphertext layout, same hex casing, same DER.

class PopopxSwiftVectorTest {
  private val seed = hexDecode(SwiftVectors.ED25519_SEED_HEX, 32)!!
  private val identityPub = hexDecode(SwiftVectors.ED25519_PUB_HEX, 32)!!
  private val epochKey = hexDecode(SwiftVectors.EPOCH_KEY_HEX, 32)!!
  private val nonce = PopopxChannelBase64.decode(SwiftVectors.NONCE_B64)!!
  private val ctTag = PopopxChannelBase64.decode(SwiftVectors.CT_TAG_B64)!!
  private val swiftSignature = PopopxChannelBase64.decode(SwiftVectors.ED25519_SIG_B64)!!

  private val envelope = PopopxChannelEnvelope(
    epoch = 7,
    nonceBase64 = SwiftVectors.NONCE_B64,
    ciphertextBase64 = SwiftVectors.CT_TAG_B64,
    signatureBase64 = SwiftVectors.ED25519_SIG_B64,
  )

  @Test
  fun ed25519PublicKeyDerivationMatchesCryptoKit() {
    assertContentEquals(identityPub, ed25519PublicKey(seed))
  }

  /**
   * The direction the app needs at runtime: a rotation signed on an iPhone must verify here. It does, and
   * the `ct ‖ tag` layout is proven by the same assertion, because the preimage ends with the tag.
   */
  @Test
  fun iosEd25519SignatureVerifiesHere() {
    val preimage = hexDecode(SwiftVectors.CHANNEL_PREIMAGE_HEX, 4096)!!
    assertTrue(ed25519Verify(identityPub, preimage, swiftSignature))
    assertFalse(ed25519Verify(identityPub, preimage, swiftSignature.copyOf().also { it[0] = (it[0] + 1).toByte() }))
  }

  /**
   * The other direction cannot be a byte comparison and this is a measured fact, not an assumption: the
   * same Swift program over the same seed and the same preimage printed `gbhdjwpX…` on one run and
   * `jrh8N+RS…` on the next, so this SDK's Ed25519 signing is non-deterministic. What is pinned instead is
   * BouncyCastle's signature over that preimage — RFC 8032 makes it reproducible — and the reverse probe
   * recorded CryptoKit accepting it (`IOS_VERIFIES_KOTLIN_ED25519 = true`) and rejecting one flipped byte.
   */
  @Test
  fun kotlinEd25519SignatureIsTheOneCryptoKitAccepted() {
    val preimage = hexDecode(SwiftVectors.CHANNEL_PREIMAGE_HEX, 4096)!!
    val signature = ed25519Sign(seed, preimage)!!
    assertEquals(SwiftVectors.KOTLIN_ED25519_SIG_HEX, hexEncode(signature))
    assertTrue(ed25519Verify(identityPub, preimage, signature))
    assertFalse(ed25519Verify(identityPub, preimage, signature.copyOf().also { it[0] = (it[0] + 1).toByte() }))
  }

  @Test
  fun envelopeByteLayoutsMatchCryptoKit() {
    assertContentEquals(hexDecode(SwiftVectors.CHANNEL_AAD_HEX, 4096), envelope.authenticationData("chan.7", identityPub))
    assertContentEquals(hexDecode(SwiftVectors.CHANNEL_PREIMAGE_HEX, 4096), envelope.signingPreimage("chan.7", nonce, ctTag))
  }

  /** The headline gate: a box sealed by CryptoKit opens here, and its plaintext is the epoch secret. */
  @Test
  fun channelEnvelopeSealedByIosDecryptsOnAndroid() {
    assertTrue(envelope.isSane)
    assertContentEquals(
      SwiftVectors.ENVELOPE_PLAINTEXT.encodeToByteArray(),
      envelope.decrypt("chan.7", epochKey, identityPub),
    )
  }

  /**
   * The tag binds the AAD, not just the key. Re-signing a copy for another channel id satisfies the
   * signature check and must still refuse to open, which is what keeps one stolen epoch key from
   * decrypting another channel's traffic.
   */
  @Test
  fun additionalAuthenticatedDataBindsTheChannelAndRejectsAForgedChannelId() {
    val otherChannel = "chan.8"
    val signature = ed25519Sign(seed, envelope.signingPreimage(otherChannel, nonce, ctTag))!!
    assertTrue(PopopxChannelCrypto.verify(signature, envelope.signingPreimage(otherChannel, nonce, ctTag), identityPub))
    val rebadged = envelope.copy(signatureBase64 = PopopxChannelBase64.encode(signature))
    assertNull(rebadged.decrypt(otherChannel, epochKey, identityPub))
  }

  @Test
  fun wrongEpochKeyAndTamperedTagBothRefuseToDecrypt() {
    val otherKey = ByteArray(32) { (it + 1).toByte() }
    assertNull(envelope.decrypt("chan.7", otherKey, identityPub))
    val flipped = ctTag.copyOf().also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() }
    assertNull(envelope.copy(ciphertextBase64 = PopopxChannelBase64.encode(flipped)).decrypt("chan.7", epochKey, identityPub))
    // A frame that is only a tag is not a ciphertext; the length test runs before the cipher does.
    assertNull(envelope.copy(ciphertextBase64 = PopopxChannelBase64.encode(ctTag.copyOf(PopopxChannelEnvelope.TAG_BYTES))).decrypt("chan.7", epochKey, identityPub))
  }

  /** iOS writes standard base64 and reads either alphabet; `+`/`/` must therefore survive unchanged. */
  @Test
  fun base64WritesStandardAndReadsBothAlphabets() {
    val bytes = byteArrayOf(0xFB.toByte(), 0xFF.toByte(), 0x00, 0x7F)
    val standard = base64Encode(bytes)
    assertTrue(standard.contains('+') || standard.contains('/'))
    assertEquals(standard, PopopxChannelBase64.encode(bytes))
    assertContentEquals(bytes, PopopxChannelBase64.decode(standard))
    assertContentEquals(bytes, PopopxChannelBase64.decode(base64UrlEncode(bytes)))
  }

  /**
   * The separator is load-bearing: `chan.1` at epoch 0 and a channel actually named `chan.10` are one
   * `0x7C` apart. Pinned as two CryptoKit byte strings so the claim is about the wire, not about this test.
   */
  @Test
  fun signingPreimageIsNotAmbiguousAcrossEpochs() {
    val withSeparator = hexDecode(SwiftVectors.AMBIG_WITH_SEPARATOR_HEX, 4096)!!
    val withoutSeparator = hexDecode(SwiftVectors.AMBIG_WITHOUT_SEPARATOR_HEX, 4096)!!
    assertFalse(withSeparator.contentEquals(withoutSeparator))
    assertContentEquals(withSeparator, PopopxChannelEnvelope(epoch = 0, nonceBase64 = SwiftVectors.NONCE_B64, ciphertextBase64 = SwiftVectors.CT_TAG_B64, signatureBase64 = SwiftVectors.ED25519_SIG_B64).signingPreimage("chan.1", nonce, ctTag))
    // What a separator-free construction would have produced for the same frame, i.e. the collision: the
    // channel literally named `chan.10` and the pair (`chan.1`, epoch 0) become one byte string.
    val naive = ArrayList<Byte>().apply {
      addAll((PopopxChannelEnvelope.PROTOCOL_NAME + "|" + "chan.1" + "0").encodeToByteArray().toList())
      add(0x7C)
      addAll(nonce.toList())
      add(0x7C)
      addAll(ctTag.toList())
    }.toByteArray()
    assertContentEquals(withoutSeparator, naive)
  }

  @Test
  fun hmacSha256OfTheH5PreimageMatchesCryptoKitInLowerCaseHex() {
    val key = hexDecode(SwiftVectors.HMAC_KEY_HEX, 32)!!
    val message = SwiftVectors.HMAC_PREIMAGE.encodeToByteArray()
    assertContentEquals(message, PopopxH5Signature.preimage("popopx1abcdefghijklmnopqrstuvwxyz", 1_700_000_000L))
    val session = PopopxEcoSession("popopx1abcdefghijklmnopqrstuvwxyz", SwiftVectors.HMAC_KEY_HEX, null)
    assertEquals(SwiftVectors.HMAC_HEX, hexEncode(hmacSha256(key, message)!!))
    assertEquals(SwiftVectors.HMAC_HEX, PopopxH5Signature.signature(session, 1_700_000_000L))
  }

  /** The three signed parameters go last, in order, and a card that shipped its own is overwritten. */
  @Test
  fun signedUrlDropsSpoofedParametersAndAppendsItsOwnInOrder() {
    val session = PopopxEcoSession("popopx1abcdefghijklmnopqrstuvwxyz", SwiftVectors.HMAC_KEY_HEX, null)
    val url = PopopxH5Signature.signedUrl("https://eco.test/h5?order=9&sig=deadbeef&ts=1&popopx_uid=spoofed#fragment", session, 1_700_000_000L)!!
    assertEquals(
      "https://eco.test/h5?order=9&popopx_uid=popopx1abcdefghijklmnopqrstuvwxyz&ts=1700000000&sig=${SwiftVectors.HMAC_HEX}#fragment",
      url,
    )
    val escaped = PopopxH5Signature.signature(PopopxEcoSession("a b&c=d", SwiftVectors.HMAC_KEY_HEX, null), 1_700_000_000L)
    assertEquals(
      "https://eco.test/h5?popopx_uid=a%20b%26c%3Dd&ts=1700000000&sig=$escaped",
      PopopxH5Signature.signedUrl("https://eco.test/h5", PopopxEcoSession("a b&c=d", SwiftVectors.HMAC_KEY_HEX, null), 1_700_000_000L),
    )
  }

  @Test
  fun ecdsaP256CredentialSignedByIosVerifiesHere() {
    val x963 = base64UrlDecode(SwiftVectors.P256_X963_BASE64URL)!!
    assertEquals(65, x963.size)
    assertEquals(0x04.toByte(), x963[0])
    val canonical = SwiftVectors.P256_CANONICAL.encodeToByteArray()
    val der = base64Decode(SwiftVectors.P256_DER_BASE64)!!
    assertTrue(ecdsaVerifyP256Sha256(x963, canonical, der))
    assertFalse(ecdsaVerifyP256Sha256(x963, "popopx|badge|PPX-BADGE-0002|3|POPOPX Founding Member|1780000000".encodeToByteArray(), der))
    assertFalse(ecdsaVerifyP256Sha256(x963, canonical, der.copyOf().also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() }))
    // The same scalar must put the same point on the wire, which is what makes a self-issued credential
    // re-verifiable after a reinstall of the app on the same device.
    assertContentEquals(x963, ecdsaPublicKeyX963(hexDecode(SwiftVectors.P256_PRIV_HEX, 32)!!))
    assertEquals(SwiftVectors.P256_CANONICAL_SHA256_HEX, sha256Hex(canonical))
    val rs = derDecode(der)!!
    assertContentEquals(der, derEncode(rs.first, rs.second))
  }

  /**
   * The signing half of the badge code, pinned the same way as Ed25519 above: RFC 6979 makes
   * BouncyCastle's `k` deterministic, so this DER is reproducible here, and the reverse probe recorded
   * CryptoKit accepting it over the canonical bytes (`IOS_VERIFIES_KOTLIN_ECDSA = true`) and rejecting it
   * for a different message. A credential minted on Android therefore verifies on iOS and back.
   */
  @Test
  fun kotlinEcdsaSignatureIsTheOneCryptoKitAccepted() {
    val scalar = hexDecode(SwiftVectors.P256_PRIV_HEX, 32)!!
    val canonical = SwiftVectors.P256_CANONICAL.encodeToByteArray()
    val der = base64UrlDecode(SwiftVectors.KOTLIN_ECDSA_DER_BASE64URL)!!
    assertContentEquals(der, ecdsaSignP256Sha256(scalar, canonical))
    assertTrue(ecdsaVerifyP256Sha256(ecdsaPublicKeyX963(scalar)!!, canonical, der))
    assertContentEquals(
      base64UrlDecode(SwiftVectors.P256_X963_BASE64URL)!!,
      base64UrlDecode(SwiftVectors.KOTLIN_ECDSA_X963_BASE64URL)!!,
    )
  }
}
