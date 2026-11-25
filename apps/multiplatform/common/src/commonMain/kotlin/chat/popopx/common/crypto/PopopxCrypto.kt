package chat.popopx.common.crypto

import org.bouncycastle.asn1.ASN1EncodableVector
import org.bouncycastle.asn1.ASN1Encoding
import org.bouncycastle.asn1.ASN1Integer
import org.bouncycastle.asn1.ASN1Sequence
import org.bouncycastle.asn1.DERSequence
import org.bouncycastle.crypto.DataLengthException
import org.bouncycastle.crypto.InvalidCipherTextException
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.ec.CustomNamedCurves
import org.bouncycastle.crypto.generators.ECKeyPairGenerator
import org.bouncycastle.crypto.generators.Ed25519KeyPairGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.ECDomainParameters
import org.bouncycastle.crypto.params.ECKeyGenerationParameters
import org.bouncycastle.crypto.params.ECPrivateKeyParameters
import org.bouncycastle.crypto.params.ECPublicKeyParameters
import org.bouncycastle.crypto.params.Ed25519KeyGenerationParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.signers.ECDSASigner
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.bouncycastle.crypto.signers.HMacDSAKCalculator
import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

private val secureRandom = SecureRandom()

const val SHA256_BYTES = 32
const val AEAD_TAG_BYTES = 16
const val AEAD_NONCE_BYTES = 12
const val ED25519_PRIVATE_BYTES = 32
const val ED25519_PUBLIC_BYTES = 32
const val ED25519_SIGNATURE_BYTES = 64
const val X963_PUBLIC_BYTES = 65

private val p256X9 = CustomNamedCurves.getByName("secp256r1")
val p256Domain = ECDomainParameters(p256X9.curve, p256X9.g, p256X9.n, p256X9.h)

// MARK: - Digests and MACs

fun sha256(data: ByteArray): ByteArray =
  MessageDigest.getInstance("SHA-256").digest(data)

fun sha256Hex(data: ByteArray): String = hexEncode(sha256(data))

fun hmacSha256(key: ByteArray, message: ByteArray): ByteArray? {
  if (key.isEmpty()) return null
  return try {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(key, "HmacSHA256"))
    mac.doFinal(message)
  } catch (e: Exception) {
    null
  }
}

fun hmacSha256Hex(key: ByteArray, message: ByteArray): String? =
  hmacSha256(key, message)?.let(::hexEncode)

fun randomBytes(count: Int): ByteArray = ByteArray(count).also { secureRandom.nextBytes(it) }

// MARK: - Hex
//
// Lower-case output, and a decoder that rejects instead of truncating: a hex field is key material, and
// silently taking the first 32 bytes of a longer string yields a key both sides believe they hold.

fun hexEncode(data: ByteArray): String {
  val digits = "0123456789abcdef"
  val out = StringBuilder(data.size * 2)
  for (byte in data) {
    val v = byte.toInt() and 0xff
    out.append(digits[v shr 4]).append(digits[v and 0x0f])
  }
  return out.toString()
}

fun hexDecode(text: String, maximumByteCount: Int): ByteArray? {
  if (maximumByteCount <= 0) return null
  val trimmed = text.trim { it.isWhitespace() }
  if (trimmed.isEmpty()) return null
  if (trimmed.length > maximumByteCount * 2) return null
  if (trimmed.length % 2 != 0) return null
  val out = ByteArray(trimmed.length / 2)
  var index = 0
  while (index < trimmed.length) {
    val high = Character.digit(trimmed[index], 16)
    val low = Character.digit(trimmed[index + 1], 16)
    if (high < 0 || low < 0) return null
    out[index / 2] = ((high shl 4) or low).toByte()
    index += 2
  }
  return out
}

// MARK: - Base64
//
// `popopxBase64URL` (apps/ios/Shared/Features/SecureEphemeral/PopopxSecurePayload.swift:404-430) is unpadded
// base64url when writing, and when reading it accepts padding but checks the alphabet first and rejects
// anything outside it. `ignoreUnknownCharacters` is deliberately never used, so a human sentence cannot
// decode into a run of bytes.

private const val BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
private const val BASE64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

fun base64Encode(data: ByteArray): String = java.util.Base64.getEncoder().encodeToString(data)

fun base64Decode(text: String): ByteArray? = try {
  java.util.Base64.getDecoder().decode(text)
} catch (e: IllegalArgumentException) {
  null
}

fun base64UrlEncode(data: ByteArray): String =
  java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(data)

fun base64UrlDecode(text: String): ByteArray? {
  if (text.isEmpty()) return null
  if (text.any { it !in BASE64URL_ALPHABET && it != '=' && it != '+' && it != '/' }) return null
  val canonical = text.replace('-', '+').replace('_', '/')
  val padded = when (canonical.length % 4) {
    0 -> canonical
    2 -> "$canonical=="
    3 -> "$canonical="
    else -> return null
  }
  return base64Decode(padded)
}

// MARK: - ChaCha20-Poly1305
//
// The sealed layout is ciphertext followed by the 16-byte tag, which is what CryptoKit's
// `ChaChaPoly.Box` holds as `ciphertext + tag` when it is not using `combined`.

fun chacha20Poly1305Seal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: ByteArray): ByteArray? {
  if (nonce.size != AEAD_NONCE_BYTES) return null
  return try {
    val cipher = ChaCha20Poly1305()
    cipher.init(true, AEADParameters(KeyParameter(key), AEAD_TAG_BYTES * 8, nonce, aad))
    val out = ByteArray(cipher.getOutputSize(plaintext.size))
    val written = cipher.processBytes(plaintext, 0, plaintext.size, out, 0)
    val total = written + cipher.doFinal(out, written)
    if (total == out.size) out else out.copyOf(total)
  } catch (e: DataLengthException) {
    null
  } catch (e: IllegalStateException) {
    null
  }
}

fun chacha20Poly1305Open(key: ByteArray, nonce: ByteArray, sealed: ByteArray, aad: ByteArray): ByteArray? {
  if (nonce.size != AEAD_NONCE_BYTES) return null
  if (sealed.size < AEAD_TAG_BYTES) return null
  return try {
    val cipher = ChaCha20Poly1305()
    cipher.init(false, AEADParameters(KeyParameter(key), AEAD_TAG_BYTES * 8, nonce, aad))
    val out = ByteArray(cipher.getOutputSize(sealed.size))
    val written = cipher.processBytes(sealed, 0, sealed.size, out, 0)
    val total = written + cipher.doFinal(out, written)
    out.copyOf(total)
  } catch (e: InvalidCipherTextException) {
    null
  } catch (e: DataLengthException) {
    null
  } catch (e: IllegalStateException) {
    null
  }
}

// MARK: - Ed25519
//
// Raw 32-byte keys and raw 64-byte signatures, which is CryptoKit's `rawRepresentation` /
// `SerializedSignature` form rather than any DER or PEM wrapper.

fun ed25519KeyPair(): Pair<ByteArray, ByteArray> {
  val generator = Ed25519KeyPairGenerator()
  generator.init(Ed25519KeyGenerationParameters(secureRandom))
  val pair = generator.generateKeyPair()
  val private = pair.private as Ed25519PrivateKeyParameters
  val public = pair.public as Ed25519PublicKeyParameters
  return private.encoded to public.encoded
}

fun ed25519PublicKey(privateKey: ByteArray): ByteArray? {
  if (privateKey.size != ED25519_PRIVATE_BYTES) return null
  return try {
    Ed25519PrivateKeyParameters(privateKey, 0).generatePublicKey().encoded
  } catch (e: Exception) {
    null
  }
}

fun ed25519Sign(privateKey: ByteArray, message: ByteArray): ByteArray? {
  if (privateKey.size != ED25519_PRIVATE_BYTES) return null
  return try {
    val signer = Ed25519Signer()
    signer.init(true, Ed25519PrivateKeyParameters(privateKey, 0))
    signer.update(message, 0, message.size)
    signer.generateSignature()
  } catch (e: Exception) {
    null
  }
}

fun ed25519Verify(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean {
  if (publicKey.size != ED25519_PUBLIC_BYTES) return false
  if (signature.size != ED25519_SIGNATURE_BYTES) return false
  return try {
    val signer = Ed25519Signer()
    signer.init(false, Ed25519PublicKeyParameters(publicKey, 0))
    signer.update(message, 0, message.size)
    signer.verifySignature(signature)
  } catch (e: Exception) {
    false
  }
}

// MARK: - ECDSA P-256
//
// The public key travels as an x9.63 uncompressed point (65 bytes, leading 0x04) and the signature as DER,
// both then base64url — matching `secp256r1.Signing.PublicKey.x963Representation` and
// `ECDSASignature.derRepresentation` on the iOS side.

fun ecdsaP256KeyPair(): Pair<ByteArray, String> {
  val generator = ECKeyPairGenerator()
  generator.init(ECKeyGenerationParameters(p256Domain, secureRandom))
  val pair = generator.generateKeyPair()
  val private = pair.private as ECPrivateKeyParameters
  val public = pair.public as ECPublicKeyParameters
  return private.d.toByteArrayPadded(ED25519_PRIVATE_BYTES) to base64UrlEncode(public.q.getEncoded(false))
}

fun ecdsaSignP256Sha256(privateKeyScalar: ByteArray, message: ByteArray): ByteArray? {
  if (privateKeyScalar.isEmpty() || privateKeyScalar.size > ED25519_PRIVATE_BYTES) return null
  return try {
    val signer = ECDSASigner(HMacDSAKCalculator(SHA256Digest()))
    signer.init(true, ECPrivateKeyParameters(BigInteger(1, privateKeyScalar), p256Domain))
    val digest = sha256(message)
    val parts = signer.generateSignature(digest)
    derEncode(parts[0], parts[1])
  } catch (e: Exception) {
    null
  }
}

fun ecdsaVerifyP256Sha256(publicKeyX963: ByteArray, message: ByteArray, derSignature: ByteArray): Boolean {
  if (publicKeyX963.size != X963_PUBLIC_BYTES || publicKeyX963[0] != 0x04.toByte()) return false
  val parts = derDecode(derSignature) ?: return false
  val (r, s) = parts
  val n = p256Domain.n
  if (r.signum() <= 0 || s.signum() <= 0 || r >= n || s >= n) return false
  return try {
    val point = p256Domain.curve.decodePoint(publicKeyX963) ?: return false
    val signer = ECDSASigner()
    signer.init(false, ECPublicKeyParameters(point, p256Domain))
    signer.verifySignature(sha256(message), r, s)
  } catch (e: Exception) {
    false
  }
}

fun ecdsaPublicKeyX963(privateKeyScalar: ByteArray): ByteArray? {
  if (privateKeyScalar.isEmpty() || privateKeyScalar.size > ED25519_PRIVATE_BYTES) return null
  return try {
    val scalar = BigInteger(1, privateKeyScalar)
    if (scalar.signum() <= 0 || scalar >= p256Domain.n) return null
    p256Domain.g.multiply(scalar).normalize().getEncoded(false)
  } catch (e: Exception) {
    null
  }
}

// MARK: - DER

fun derEncode(r: BigInteger, s: BigInteger): ByteArray {
  val vector = ASN1EncodableVector()
  vector.add(ASN1Integer(r))
  vector.add(ASN1Integer(s))
  return DERSequence(vector).getEncoded(ASN1Encoding.DER)
}

fun derDecode(der: ByteArray): Pair<BigInteger, BigInteger>? = try {
  val sequence = ASN1Sequence.getInstance(der)
  if (sequence.size() != 2) null
  else {
    val r = ASN1Integer.getInstance(sequence.getObjectAt(0)).value
    val s = ASN1Integer.getInstance(sequence.getObjectAt(1)).value
    r to s
  }
} catch (e: Exception) {
  null
}

// MARK: - Misc

fun BigInteger.toByteArrayPadded(size: Int): ByteArray {
  val raw = toByteArray()
  return when {
    raw.size == size -> raw
    raw.size == size + 1 && raw[0] == 0.toByte() -> raw.copyOfRange(1, raw.size)
    raw.size < size -> ByteArray(size - raw.size) + raw
    else -> raw.copyOfRange(raw.size - size, raw.size)
  }
}
