package chat.popopx.common.invite

import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.crypto.InvalidCipherTextException
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV

/**
 * The public share form of a connection URI: `https://popopx.chat/i/v1/<code>`.
 *
 * Port of apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Invite/PopopxOpaqueInviteCodec.swift, and
 * byte-compatible with popopx-service-suite/gateway/app/opaque_invite_codec.py and
 * popopx-bot-studio/studio/app/security/opaque_invite_codec.py. The published vectors in
 * PopopxOpaqueInviteVectors.kt are copied verbatim from those files, and the tests assert this
 * codec reproduces every byte of them on the JVM.
 *
 * What v1 is: HKDF-SHA256 over a fixed, published key-derivation input, then ChaCha20-Poly1305
 * with a fresh 12-byte nonce per link and a fixed AAD, encoded as unpadded base64url.
 *
 * What v1 is NOT: confidentiality. IKM_HEX is a *format* key — every client must hold it, so it is
 * in the source of an AGPL app by design, and the gateway's own docstring says the envelope "is not
 * confidentiality against someone who reads this file". The property this buys is that the relay
 * host stops appearing in link previews, screenshots, forwards and chat history. UI copy and
 * privacy disclosures must describe it that way and never as an encrypted or private link.
 *
 * Asymmetry, deliberate (ruled 2026-11-26): sealing is as strict as the two server repositories, so
 * nothing this app produces can be refused by them. Opening is wider, so a link from anywhere in the
 * ecosystem still resolves. `smp://` is a listed *rejected* vector upstream, not an accepted one, so
 * it may be opened but never minted.
 */

/** Every refusal the codec can raise. Mirrors the Swift enum's cases, including its coarseness:
 * opening failures deliberately share one case, because how close an envelope got to verifying is
 * not something a user can act on and not something worth leaking about a scanned QR. */
sealed class PopopxOpaqueInviteError(override val message: String) : Exception(message) {
  object EmptyURI : PopopxOpaqueInviteError("a non-empty connection URI is required")
  object UriSchemeInvalid : PopopxOpaqueInviteError("URI scheme is not one the servers seal")
  object UriNotPlain : PopopxOpaqueInviteError("URI carries whitespace or a control character")
  class UriTooLong(val bytes: Int, val limit: Int) :
    PopopxOpaqueInviteError("$bytes bytes exceeds the $limit limit")
  object LinkPrefixInvalid : PopopxOpaqueInviteError("not an /i/v1/ invite link")
  object CodeLengthInvalid : PopopxOpaqueInviteError("invite code is empty or oversized")
  object CodeNotBase64URL : PopopxOpaqueInviteError("invite code is not unpadded base64url")
  object Tampered : PopopxOpaqueInviteError("the authenticated envelope did not verify")
  object NonceUnavailable : PopopxOpaqueInviteError("the system RNG refused to fill a nonce")
}

object PopopxOpaqueInviteCodec {
  /** Versioned prefix. Changing it is a new format, not a configuration change. */
  const val LINK_PREFIX = "https://popopx.chat/i/v1/"

  internal const val IKM_HEX = "d1abbcb09b5bf244d9d8b6b1dcc38835b5a419d8a1d62b014c1bb49e765dbdeb"
  internal val SALT = "popopx.chat/invite-link/v1/salt".toByteArray(Charsets.UTF_8)
  internal val INFO = "popopx.chat/invite-link/v1/key".toByteArray(Charsets.UTF_8)
  internal val AAD = "popopx.chat/invite-link/v1/aad".toByteArray(Charsets.UTF_8)

  internal const val NONCE_BYTES = 12
  internal const val TAG_BYTES = 16
  internal const val KEY_BYTES = 32

  /** Seal ceiling, equal to the gateway's MAX_URI_BYTES. */
  const val MAX_SEAL_PLAINTEXT_BYTES = 2048

  /** Open ceiling, equal to Bot Studio's MAX_ADDRESS_BYTES and wider on purpose. */
  const val MAX_OPEN_PLAINTEXT_BYTES = 4096

  /** Schemes the servers will seal, in the order and spelling of URI_SCHEMES. */
  val SEALABLE_SCHEMES = listOf("popopx:/", "popopx://", "https://")

  /** Schemes accepted *when opening*, plus the Mac Node pairing prefix. A PPXNODE1 offer carries
   * its own Ed25519 signature, verified by PopopxNodePairing — this codec only unwraps it. */
  internal val OPENABLE_SCHEMES = SEALABLE_SCHEMES + "smp://"
  internal val OPENABLE_PREFIXES = listOf("PPXNODE1-")

  /** The widest token a plaintext at the open ceiling can encode to. */
  internal val MAX_OPEN_TOKEN_CHARS = ((NONCE_BYTES + MAX_OPEN_PLAINTEXT_BYTES + TAG_BYTES + 2) / 3) * 4

  private const val CODE_ALPHABET =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

  /** Derived once: HKDF is two HMAC calls, and doing it per link would put it on the share path. */
  internal val formatKey: ByteArray = hkdfSha256(hexToBytes(IKM_HEX), SALT, INFO, KEY_BYTES)

  //region Sealing

  /** The public form of a connection URI, or null when the URI is not sealable. Null instead of a
   * throw so a caller can fall back to the raw link without a try/catch on the UI path; [sealCode]
   * carries the reason when one is needed. */
  fun linkFor(uri: String, nonce: ByteArray? = null): String? {
    val code = try { sealCode(uri, nonce) } catch (e: PopopxOpaqueInviteError) { return null }
    return LINK_PREFIX + code
  }

  /** [linkFor] with the reason exposed. */
  fun sealCode(uri: String, nonce: ByteArray? = null): String {
    val text = validatedSealableURI(uri)
    val nonceBytes: ByteArray
    if (nonce != null) {
      if (nonce.size != NONCE_BYTES) throw PopopxOpaqueInviteError.CodeLengthInvalid
      nonceBytes = nonce
    } else {
      // A fresh nonce per link is what stops two shares of the same contact address being
      // comparable, so a failed CSPRNG must not silently fall back to a fixed one.
      nonceBytes = ByteArray(NONCE_BYTES)
      try {
        SecureRandom().nextBytes(nonceBytes)
      } catch (e: Exception) {
        throw PopopxOpaqueInviteError.NonceUnavailable
      }
    }
    return base64Url(nonceBytes + seal(text, nonceBytes))
  }

  /** The raw envelope — nonce || ciphertext || tag — with a caller-supplied nonce. Exposed for the
   * vector tests, which must pin the nonce to reproduce published bytes. */
  internal fun sealedBytes(uri: String, nonce: ByteArray): ByteArray? {
    val text = try { validatedSealableURI(uri) } catch (e: PopopxOpaqueInviteError) { return null }
    if (nonce.size != NONCE_BYTES) return null
    return try { nonce + seal(text, nonce) } catch (e: PopopxOpaqueInviteError) { null }
  }

  //endregion

  //region Opening

  /** Recovers the connection URI an opaque link carries.
   * @throws PopopxOpaqueInviteError.Tampered for anything that does not authenticate. */
  fun uriFromLink(link: String): String = openCode(substringOfLink(link))

  /** [uriFromLink] as a nullable, for paste and QR paths where "not an invite" is the normal
   * answer. */
  fun uriIfOpaqueLink(value: String): String? = try { uriFromLink(value) } catch (e: PopopxOpaqueInviteError) { null }

  /** The prefixes this codec will read. Only the first is ever minted: `popopx:/…` and
   * `https://popopx.chat/…` are two spellings of one address, and an invitation carried between
   * clients arrives rewritten either way. Reading only the minted form would make the same link
   * work when pasted and fail when tapped. */
  internal val OPEN_LINK_PREFIXES =
    listOf(LINK_PREFIX, "popopx:/i/v1/", "popopx://popopx.chat/i/v1/")

  internal fun openLinkPrefix(link: String): String? =
    OPEN_LINK_PREFIXES.firstOrNull { link.startsWith(it) }

  /** Shape test only: it does not prove the envelope authenticates. Used to decide whether to try
   * the codec at all before falling back to the plain-link path. */
  fun looksLikeOpaqueLink(value: String): Boolean {
    val prefix = openLinkPrefix(value) ?: return false
    val code = value.substring(prefix.length)
    return code.isNotEmpty() && code.length <= MAX_OPEN_TOKEN_CHARS && base64UrlDecode(code) != null
  }

  //endregion

  //region Steps, split out so a test can tell prefix from envelope from payload

  internal fun substringOfLink(link: String): String {
    val prefix = openLinkPrefix(link) ?: throw PopopxOpaqueInviteError.LinkPrefixInvalid
    val code = link.substring(prefix.length)
    if (code.isEmpty() || code.length > MAX_OPEN_TOKEN_CHARS) throw PopopxOpaqueInviteError.CodeLengthInvalid
    return code
  }

  internal fun openCode(code: String): String {
    val raw = base64UrlDecode(code) ?: throw PopopxOpaqueInviteError.CodeNotBase64URL
    if (raw.size < NONCE_BYTES + TAG_BYTES + 1 || raw.size > NONCE_BYTES + MAX_OPEN_PLAINTEXT_BYTES + TAG_BYTES) {
      throw PopopxOpaqueInviteError.CodeLengthInvalid
    }
    val plaintext = open(raw.copyOfRange(0, NONCE_BYTES), raw.copyOfRange(NONCE_BYTES, raw.size))
      ?: throw PopopxOpaqueInviteError.Tampered
    val text = utf8OrNull(plaintext) ?: throw PopopxOpaqueInviteError.Tampered
    if (!opensAcceptable(text)) throw PopopxOpaqueInviteError.Tampered
    return text
  }

  /** What this codec will hand back after a successful open. Wider than the seal side by ruling,
   * narrower than "any string": an unauthenticated byte sequence cannot reach here (the tag already
   * failed), and a wrapper that would return `javascript:alert(1)` under a trusted domain is a
   * phishing primitive. */
  internal fun opensAcceptable(text: String): Boolean {
    if (text.isEmpty() || text != text.trim()) return false
    if (text.any { it.code < 0x20 || it.code == 0x7F || it.isWhitespace() }) return false
    if (OPENABLE_PREFIXES.any { text.startsWith(it) }) return true
    return OPENABLE_SCHEMES.any { text.startsWith(it) }
  }

  internal fun validatedSealableURI(uri: String): String {
    if (uri.isEmpty()) throw PopopxOpaqueInviteError.EmptyURI
    if (uri != uri.trim()) throw PopopxOpaqueInviteError.UriNotPlain
    if (SEALABLE_SCHEMES.none { uri.startsWith(it) }) throw PopopxOpaqueInviteError.UriSchemeInvalid
    val bytes = uri.toByteArray(Charsets.UTF_8).size
    if (bytes > MAX_SEAL_PLAINTEXT_BYTES) throw PopopxOpaqueInviteError.UriTooLong(bytes, MAX_SEAL_PLAINTEXT_BYTES)
    if (uri.any { it.code < 0x20 || it.code == 0x7F || it.isWhitespace() }) throw PopopxOpaqueInviteError.UriNotPlain
    return uri
  }

  //endregion

  //region Primitives

  private fun seal(plaintext: String, nonce: ByteArray): ByteArray {
    val engine = ChaCha20Poly1305()
    engine.init(true, ParametersWithIV(KeyParameter(formatKey), nonce))
    engine.processAADBytes(AAD, 0, AAD.size)
    val input = plaintext.toByteArray(Charsets.UTF_8)
    val out = ByteArray(input.size + TAG_BYTES)
    val written = engine.processBytes(input, 0, input.size, out, 0)
    val total = written + engine.doFinal(out, written)
    return out.copyOfRange(0, total)
  }

  /** Returns null for a tag mismatch: BC signals it by throwing, and every caller of this codec
   * treats "did not authenticate" as one answer. BC holds the trailing tag back internally while
   * decrypting, so `doFinal` contributes no bytes here and `written` is already the plaintext
   * length — subtracting a tag would clip the last 16 bytes of every address. */
  private fun open(nonce: ByteArray, sealed: ByteArray): ByteArray? {
    val engine = ChaCha20Poly1305()
    return try {
      engine.init(false, ParametersWithIV(KeyParameter(formatKey), nonce))
      engine.processAADBytes(AAD, 0, AAD.size)
      val out = ByteArray(sealed.size)
      val written = engine.processBytes(sealed, 0, sealed.size, out, 0)
      val total = written + engine.doFinal(out, written)
      out.copyOfRange(0, total)
    } catch (e: InvalidCipherTextException) {
      null
    }
  }

  /** RFC 5869 HKDF-SHA256, written out rather than taken from HKDFBytesGenerator for the same reason
   * PopopxNoiseXX.kt's hkdf() is: this file must be readable against the Python and Swift references
   * without a second dependency to consult. The invite key is one HashLen block; the expand loop is
   * here so the RFC 5869 vector, which asks for 42 bytes, can be run through the same function. */
  internal fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
    require(length in 1..255 * 32) { "HKDF output must be between 1 and 8160 bytes" }
    val prk = hmacSha256(salt, ikm)
    val out = ByteArray(length)
    var previous = ByteArray(0)
    var written = 0
    var block = 1
    while (written < length) {
      previous = hmacSha256(prk, previous + info + byteArrayOf(block.toByte()))
      val take = minOf(previous.size, length - written)
      previous.copyInto(out, written, 0, take)
      written += take
      block += 1
    }
    return out
  }

  private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(key, "HmacSHA256"))
    return mac.doFinal(data)
  }

  internal fun base64Url(data: ByteArray): String =
    java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(data)

  /** Strict `_CODE_RE`: `+/=` are rejected rather than tolerated, because a code that decodes two
   * ways is a code two implementations can disagree about. chat.popopx.common.crypto's
   * base64UrlDecode() is deliberately looser for the payloads it serves, so it is not reused here. */
  internal fun base64UrlDecode(text: String): ByteArray? {
    if (text.isEmpty() || text.length % 4 == 1) return null
    if (text.any { it !in CODE_ALPHABET }) return null
    val canonical = text.replace('-', '+').replace('_', '/')
    val padded = canonical + "=".repeat((4 - canonical.length % 4) % 4)
    return try {
      java.util.Base64.getDecoder().decode(padded)
    } catch (e: IllegalArgumentException) {
      null
    }
  }

  /** Kotlin's String type cannot hold invalid UTF-8, so unlike Swift this cannot be a happy path;
   * it stays explicit because the AEAD output is bytes first. */
  internal fun utf8OrNull(bytes: ByteArray): String? = try {
    val decoder = Charsets.UTF_8.newDecoder()
      .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
      .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
    decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
  } catch (e: java.nio.charset.CharacterCodingException) {
    null
  }

  /** An odd or non-hex string yields empty, which the key derivation then makes a key that cannot
   * open any published vector — the vector tests fail loudly rather than silently shipping a
   * non-interop build. */
  internal fun hexToBytes(hex: String): ByteArray {
    if (hex.length % 2 != 0) return ByteArray(0)
    val out = ByteArray(hex.length / 2)
    for (index in out.indices) {
      val high = Character.digit(hex[index * 2], 16)
      val low = Character.digit(hex[index * 2 + 1], 16)
      if (high < 0 || low < 0) return ByteArray(0)
      out[index] = ((high shl 4) or low).toByte()
    }
    return out
  }

  //endregion
}
