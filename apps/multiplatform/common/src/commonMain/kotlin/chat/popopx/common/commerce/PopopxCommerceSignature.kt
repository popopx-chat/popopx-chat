package chat.popopx.common.commerce

import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.base64UrlEncode
import chat.popopx.common.crypto.ecdsaPublicKeyX963
import chat.popopx.common.crypto.ecdsaSignP256Sha256
import chat.popopx.common.crypto.ecdsaVerifyP256Sha256
import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.crypto.randomBytes
import chat.popopx.common.crypto.sha256
import chat.popopx.common.eco.PopopxEcoSecrets
import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings

/**
 * The canonical-byte and digest layer, plus this device's self-issued signing identity — the Kotlin form of
 * `PopopxCommerceSignature` (`apps/ios/Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift:1531-1608`).
 *
 * ### The trust model, stated once because every judgement below cites it
 * There is no server, no account and no certificate authority in this feature, so these signatures are **not an
 * identity chain**. They attest two things and promise no more: a tamper trail (change an amount, a period or a
 * code's content and verification fails) and origin, for the one external anchor the app does have. Badges are
 * self-issued: the public key in a grant is the giver's own, carried in the message, and nothing here is seeded
 * from a hardcoded root of trust. Do not add one.
 *
 * ### When this device holds no key
 * Every entry point degrades silently — [signatureBase64URL] returns null, [localPublicKeyBase64URL] returns the
 * empty string, and each caller already treats those as "no card, no grant, no code". That is iOS's behaviour
 * (`:1541-1551`): if the key cannot be stored the call must NOT hand back a throwaway key, because the codes
 * minted last time would all fail verification after the swap and the user would read that as "my code broke".
 */
class PopopxCommerceSignature(private val defaults: Settings = settings) {
  /**
   * This device's P-256 private scalar, minted on first use and never re-minted silently.
   *
   * iOS keeps a PEM in the keychain and re-parses it on every call so the material never sits in a static
   * (`:1540-1551`). Here the scalar goes through [PopopxEcoSecrets] — the app's own keystore wrapper, under the
   * commerce account name — which is the same "never a plaintext preferences entry" property, and the scalar is
   * re-read per call rather than cached.
   */
  fun signingScalar(): ByteArray? {
    val stored = PopopxEcoSecrets.read(ACCOUNT_SIGNING_KEY, defaults)
    if (stored != null && stored.size == PRIVATE_SCALAR_BYTES) return stored
    if (stored != null) {
      // A row of the wrong length is not a key this module minted; keeping it would mean every signature the
      // device makes from now on fails, so it is destroyed instead of being worked around.
      PopopxEcoSecrets.remove(ACCOUNT_SIGNING_KEY, defaults)
    }
    // A uniform 32-byte draw can land on 0 or on a value at or above the curve order, neither of which is a
    // private key. iOS cannot produce one (the secure enclave draws it) so the check is ours: a candidate is
    // written only once its public key exists.
    repeat(MINT_ATTEMPTS) {
      val candidate = randomBytes(PRIVATE_SCALAR_BYTES)
      if (ecdsaPublicKeyX963(candidate) == null) return@repeat
      if (!PopopxEcoSecrets.write(candidate, ACCOUNT_SIGNING_KEY, defaults)) return null
      return candidate
    }
    return null
  }

  /** This device's public key as unpadded base64url x9.63, or `""` when there is no usable key (`:1554`). */
  fun localPublicKeyBase64URL(): String {
    val scalar = signingScalar() ?: return ""
    return base64UrlEncode(ecdsaPublicKeyX963(scalar) ?: return "")
  }

  /** DER over the canonical bytes, unpadded base64url, or null when this device cannot sign (`:1558-1562`). */
  fun signatureBase64URL(canonical: ByteArray): String? {
    val scalar = signingScalar() ?: return null
    // `ecdsaSignP256Sha256` hashes internally, so the canonical bytes go in exactly as iOS hands them to
    // `key.signature(for:)` — pre-hashing here would sign a different message.
    val der = ecdsaSignP256Sha256(scalar, canonical) ?: return null
    return base64UrlEncode(der)
  }

  /**
   * Strict verification against a key the caller supplies. A key that will not decode, a signature that will not
   * decode and a failed check are all the same answer, with no reason attached — the same shape as `:1565-1574`.
   */
  fun verify(signatureBase64URL: String, canonical: ByteArray, publicKeyBase64URL: String): Boolean {
    if (signatureBase64URL.isEmpty() || publicKeyBase64URL.isEmpty()) return false
    val der = base64UrlDecode(signatureBase64URL) ?: return false
    val publicKey = base64UrlDecode(publicKeyBase64URL) ?: return false
    return ecdsaVerifyP256Sha256(publicKey, canonical, der)
  }

  /**
   * Self-signature check: meaningful only under the premise "this payload was minted on this device". It is named
   * apart from [verify] so no call site can read "self-signed passed" as "the other side confirmed it" (`:1577-1579`).
   */
  fun verifySelfIssued(signatureBase64URL: String, canonical: ByteArray): Boolean =
    verify(signatureBase64URL, canonical, localPublicKeyBase64URL())

  /**
   * Whether this device holds a usable signing key at all, without minting one. The sheets use it to decide
   * between "unavailable" and a form the user cannot complete.
   */
  fun hasSigningKey(): Boolean = PopopxEcoSecrets.contains(ACCOUNT_SIGNING_KEY, defaults)

  companion object {
    /**
     * The keystore account. iOS stores this identity in the service `popopx.commerce` under the name
     * `popopx.commerce.signing-key` (`:1421`, `:1464`); the same string is kept here as the account so a migrated
     * device can be read by either side. This wrapper has no service concept — [PopopxEcoSecrets] namespaces every
     * account with its own prefix — so the service name appears only inside the account, exactly as it does on iOS.
     */
    const val ACCOUNT_SIGNING_KEY = "popopx.commerce.signing-key"

    private const val PRIVATE_SCALAR_BYTES = 32

    /** Bound on [signingScalar]'s draw loop; four failures in a row means the RNG is broken, not unlucky. */
    private const val MINT_ATTEMPTS = 4

    val shared: PopopxCommerceSignature = PopopxCommerceSignature()

    /**
     * The canonical bytes (`:1594-1596`): `popopx|<kind>|<parts…>`, joined with `|`, first segment the payload
     * type name. Only one input shape is allowed on purpose — two shapes would grow into two canonicalisations of
     * the same payload, which is exactly where the tamper-trail promise breaks.
     *
     * Free text (a message) never enters `parts`: it may contain `|`, and as long as it is appended AFTER the last
     * part it cannot shift any earlier field out of position. Two of the eight kinds do append it — see
     * [canonicalGift] and [canonicalCreditGift].
     */
    fun canonical(kind: String, parts: List<String>): ByteArray =
      (listOf("popopx", kind) + parts).joinToString(separator = "|").encodeToByteArray()

    /** `canonicalBytes` of `PopopxGiftCardPayload` (`:642`): three parts, then the raw note bytes after the final `|`. */
    fun canonicalGift(voucherId: String, period: PopopxNodeBadgePeriod, mintedAtMs: Long, note: String): ByteArray =
      canonical("gift", listOf(voucherId, period.wireValue, mintedAtMs.toString())) + note.encodeToByteArray()

    /** `canonicalBytes` of `PopopxCreditGiftPayload` (`:756`), the same raw-note tail. */
    fun canonicalCreditGift(voucherId: String, creditsAmount: Int, mintedAtMs: Long, note: String): ByteArray =
      canonical("creditgift", listOf(voucherId, creditsAmount.toString(), mintedAtMs.toString())) + note.encodeToByteArray()

    /** `canonicalBytes` of `PopopxRedPacketPayload` (`:872`), the same raw-note tail. */
    fun canonicalRedPacket(packetId: String, amount: Int, recipients: Int, note: String): ByteArray =
      canonical("rp", listOf(packetId, amount.toString(), recipients.toString())) + note.encodeToByteArray()

    /** `canonicalBytes` of `PopopxChannelAccessPayload` (`:990`): no note, so nothing is appended. */
    fun canonicalChannel(price: Int, publishedAtMs: Long, issuerPublicKeyBase64URL: String): ByteArray =
      canonical("chan", listOf(price.toString(), publishedAtMs.toString(), issuerPublicKeyBase64URL))

    /** `canonicalBytes` of `PopopxBadgeGrant` (`:473`). */
    fun canonicalGrant(voucherId: String, period: PopopxNodeBadgePeriod, grantedAtMs: Long, expiresAtMs: Long): ByteArray =
      canonical("grant", listOf(voucherId, period.wireValue, grantedAtMs.toString(), expiresAtMs.toString()))

    /** `canonicalBytes` of `PopopxCreditsGrant` (`:453`); a signature over one form never verifies as the other. */
    fun canonicalCreditGrant(voucherId: String, creditsAmount: Int, grantedAtMs: Long): ByteArray =
      canonical("credit_grant", listOf(voucherId, creditsAmount.toString(), grantedAtMs.toString()))

    /** `canonicalBytes` of `PopopxRedeemEnvelope` (`:498`). */
    fun canonicalCode(voucherId: String, period: PopopxNodeBadgePeriod, mintedAtMs: Long, nonce: String, inviteLink: String): ByteArray =
      canonical("code", listOf(voucherId, period.wireValue, mintedAtMs.toString(), nonce, inviteLink))

    /** `canonicalBytes` of `PopopxCreditRedeemEnvelope` (`:526`). */
    fun canonicalCreditCode(voucherId: String, creditsAmount: Int, mintedAtMs: Long, nonce: String, inviteLink: String): ByteArray =
      canonical("credit_code", listOf(voucherId, creditsAmount.toString(), mintedAtMs.toString(), nonce, inviteLink))

    /** SHA-256, the digest every `…Digest` field in this module is (`:1598-1600`). */
    fun digest(data: ByteArray): ByteArray = sha256(data)

    fun digest(text: String): ByteArray = sha256(text.encodeToByteArray())

    /**
     * The first 8 digest bytes printed as hex — 16 characters, which is what a ledger row, a voucher's
     * `jwsDigest` and a trial guard all carry (`:1603-1607`).
     */
    fun shortDigest(data: ByteArray): String = hexEncode(digest(data)).substring(0, 16)

    fun shortDigest(text: String): String = shortDigest(text.encodeToByteArray())
  }
}
