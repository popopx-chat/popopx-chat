package chat.popopx.common.mesh

import java.security.SecureRandom
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters

/**
 * The X25519 key pair a node announces itself with. Port of
 * apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Protocol/PopopxMeshIdentity.swift.
 *
 * `privateSeed` is the raw 32-byte scalar, kept as a ByteArray rather than a key object so the value
 * stays a plain data type across threads, the same reason iOS keeps Data rather than a Curve25519
 * key. The key objects are made on demand by [keyAgreementPrivateKey].
 */
class PopopxMeshIdentity private constructor(
  val privateSeed: ByteArray,
  val publicKey: ByteArray,
) {
  /** A hex mesh public key as it appears in `SYS_POPOPX_ACK:` and in the mapping table. */
  val meshPublicKeyHex: String get() = publicKey.meshHex()

  /** The short on-wire id: first 8 bytes of SHA256(pubkey). */
  val peerID: PopopxMeshPeerID get() = PopopxMeshPeerID.fromPublicKey(publicKey)

  fun keyAgreementPrivateKey(): X25519PrivateKeyParameters? =
    runCatching { X25519PrivateKeyParameters(privateSeed, 0) }.getOrNull()

  fun keyAgreementPublicKey(): X25519PublicKeyParameters? =
    runCatching { X25519PublicKeyParameters(publicKey, 0) }.getOrNull()

  override fun equals(other: Any?): Boolean =
    other is PopopxMeshIdentity &&
      other.privateSeed.contentEquals(privateSeed) &&
      other.publicKey.contentEquals(publicKey)

  override fun hashCode(): Int = 31 * privateSeed.contentHashCode() + publicKey.contentHashCode()

  override fun toString(): String = "PopopxMeshIdentity(publicKey=$meshPublicKeyHex)"

  companion object {
    const val KEY_BYTE_COUNT: Int = 32

    /**
     * null unless the seed is 32 bytes *and* derives a public key.
     *
     * iOS' failable initialiser is also `nil` for a seed CryptoKit refuses. The three measured cases
     * - 31 bytes, the identity vectors whose derived keys match BouncyCastle byte for byte, and an
     * all-zero seed, which iOS accepts - are all covered by the width check plus a derive that cannot
     * fail on BouncyCastle's side. If a future vector shows CryptoKit refusing a 32-byte value that
     * BouncyCastle accepts, that is a divergence to record, not to hide behind a try.
     */
    fun of(privateSeed: ByteArray): PopopxMeshIdentity? {
      if (privateSeed.size != KEY_BYTE_COUNT) return null
      val key = runCatching { X25519PrivateKeyParameters(privateSeed, 0) }.getOrNull() ?: return null
      return PopopxMeshIdentity(privateSeed.copyOf(), key.generatePublicKey().encoded)
    }

    /**
     * The pair a caller already holds, as iOS' second initialiser is: width is checked and the public
     * key is taken on trust, because restoring a stored identity must work even if the two halves
     * disagree.
     */
    fun of(privateSeed: ByteArray, publicKey: ByteArray): PopopxMeshIdentity? {
      if (privateSeed.size != KEY_BYTE_COUNT || publicKey.size != KEY_BYTE_COUNT) return null
      return PopopxMeshIdentity(privateSeed.copyOf(), publicKey.copyOf())
    }

    fun generate(): PopopxMeshIdentity {
      val key = X25519PrivateKeyParameters(SecureRandom())
      return PopopxMeshIdentity(key.encoded, key.generatePublicKey().encoded)
    }
  }
}
