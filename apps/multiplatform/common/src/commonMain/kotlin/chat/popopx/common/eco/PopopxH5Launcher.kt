package chat.popopx.common.eco

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.popopx.common.crypto.hmacSha256
import chat.popopx.common.crypto.hexEncode

// Ported from apps/ios/Shared/Features/ServiceAccount/PopopxH5Launcher.swift.
//
// The sheet half is not here: iOS presents `SFSafariViewController`, an out-of-process browser, while
// Android has no equivalent that the app does not have to build. What IS ported is the part that carries
// the security promise — the signed URL — because that is what the server verifies, and it is pure
// arithmetic a unit test can drive without a UI or a keystore.

/** Why an H5 open was refused, or what it produced. The copy for a refusal belongs to the caller. */
enum class PopopxH5OpenOutcome {
  /** A signed page was built and is now offered. */
  SIGNED,

  /** The service account has not sent its `session_handshake` here; opening unsigned would identify by IP alone. */
  NO_SESSION,

  /** The session is present but its secret is missing or unsane — the handshake was corrupted or wiped. */
  SESSION_UNUSABLE,

  /** The URL did not parse, or its scheme is not http/https. */
  INVALID_URL,

  /** A signed page is already on screen; a second tap would stack two sheets over one URL. */
  ALREADY_PRESENTING,
  ;

  val opened: Boolean get() = this == SIGNED
}

/** The one signed page this app currently offers, and the Unix seconds its HMAC covered. */
data class PopopxH5Request(val url: String, val timestampSeconds: Long) {
  companion object {
    fun signed(urlString: String, session: PopopxEcoSession, timestampSeconds: Long = nowSeconds()): PopopxH5Request? {
      val built = PopopxH5Signature.signedUrl(urlString, session, timestampSeconds) ?: return null
      return PopopxH5Request(built, timestampSeconds)
    }
  }
}

/** The arithmetic the server recomputes: pure functions, no state, no I/O. */
object PopopxH5Signature {
  /** The three parameter names the launcher owns. */
  const val UID_PARAMETER = "popopx_uid"
  const val TIMESTAMP_PARAMETER = "ts"
  const val SIGNATURE_PARAMETER = "sig"

  /** The exact bytes the HMAC covers. */
  fun preimage(pairwiseUid: String, timestampSeconds: Long): ByteArray =
    ("uid=" + pairwiseUid + "&ts=" + timestampSeconds).encodeToByteArray()

  /** Lower-case hex, because that is what the server expects. */
  fun signature(session: PopopxEcoSession, timestampSeconds: Long): String? {
    val key = session.secretBytes ?: return null
    return hmacSha256(key, preimage(session.pairwiseUid, timestampSeconds))?.let(::hexEncode)
  }

  /** RFC 3986 unreserved set, conservative on purpose: an `&` or `=` inside a pseudonym must not inject a fourth parameter. */
  fun escape(value: String): String? {
    val out = StringBuilder()
    for (ch in value) {
      if (ch.isLetterOrDigit() || ch == '-' || ch == '.' || ch == '_' || ch == '~') {
        out.append(ch)
      } else {
        for (byte in ch.toString().encodeToByteArray()) {
          out.append('%').append(HEX_DIGITS[(byte.toInt() shr 4) and 0x0f]).append(HEX_DIGITS[byte.toInt() and 0x0f])
        }
      }
    }
    return out.toString()
  }

  /**
   * Build the signed URL, dropping any pre-existing `popopx_uid`/`ts`/`sig` pair from the incoming query
   * so a spoofed card cannot ship a signature the server would read in place of ours. The signed values are
   * always the last three pairs, in that order.
   */
  fun signedUrl(urlString: String, session: PopopxEcoSession, timestampSeconds: Long): String? {
    if (!PopopxEcoAction.isHttpUrl(urlString)) return null
    val escapedUid = escape(session.pairwiseUid)?.takeIf { it.isNotEmpty() } ?: return null
    val sig = signature(session, timestampSeconds) ?: return null
    val owned = setOf(UID_PARAMETER, TIMESTAMP_PARAMETER, SIGNATURE_PARAMETER)
    // Fragment last, always, which is what writing `percentEncodedQuery` on iOS produces.
    val fragment = urlString.substringAfter('#', "").let { if (urlString.contains('#')) "#$it" else "" }
    val withoutFragment = if (fragment.isEmpty()) urlString else urlString.substringBefore('#')
    val base = withoutFragment.substringBefore('?')
    val kept = ArrayList<String>()
    if (withoutFragment.contains('?')) {
      for (pair in withoutFragment.substringAfter('?').split('&')) {
        if (pair.isEmpty()) continue
        val name = pair.substringBefore('=', pair)
        if (name in owned) continue
        kept.add(pair)
      }
    }
    kept.add(UID_PARAMETER + "=" + escapedUid)
    kept.add(TIMESTAMP_PARAMETER + "=" + timestampSeconds)
    kept.add(SIGNATURE_PARAMETER + "=" + sig)
    return base + "?" + kept.joinToString("&") + fragment
  }

  private const val HEX_DIGITS = "0123456789ABCDEF"
}

/**
 * The single owner of the signed page. Nothing else keeps a copy, so [close] is the only way the
 * signature is spent and dropped.
 *
 * [request] is Compose-observable so the sheet can be a reader rather than a caller: the card runner, the menu
 * bar and the deep-link handler all install a request and none of them owns a UI. iOS has the same shape with
 * `@Published` on the launcher and `.sheet(item:)` on the host (PopopxH5Launcher.swift).
 */
class PopopxH5Launcher {
  var request: PopopxH5Request? by mutableStateOf(null)
    private set

  /** The entry point the menu bar and the deep-link handler call: reads the session, signs, installs. */
  fun open(urlString: String, contactId: Long): PopopxH5OpenOutcome {
    if (request != null) return PopopxH5OpenOutcome.ALREADY_PRESENTING
    val session = PopopxEcoSessionStore.session(contactId) ?: return PopopxH5OpenOutcome.NO_SESSION
    return offer(urlString, session)
  }

  /** Idempotent: calling it when nothing is offered does nothing. */
  fun close() {
    request = null
  }

  /** The form the action runner uses, with the session already in hand. */
  fun present(url: String, session: PopopxEcoSession): Boolean = offer(url, session).opened

  private fun offer(urlString: String, session: PopopxEcoSession): PopopxH5OpenOutcome {
    if (request != null) return PopopxH5OpenOutcome.ALREADY_PRESENTING
    if (!session.isSane) return PopopxH5OpenOutcome.SESSION_UNUSABLE
    val built = PopopxH5Request.signed(urlString, session) ?: return PopopxH5OpenOutcome.INVALID_URL
    request = built
    return PopopxH5OpenOutcome.SIGNED
  }

  companion object {
    val shared: PopopxH5Launcher = PopopxH5Launcher()
  }
}

private fun nowSeconds(): Long = System.currentTimeMillis() / 1000
