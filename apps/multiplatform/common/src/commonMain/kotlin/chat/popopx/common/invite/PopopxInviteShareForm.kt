package chat.popopx.common.invite

import chat.popopx.common.model.CreatedConnLink
import chat.popopx.common.model.popopxChatLink

/**
 * What an invitation is shown, printed and shared as: the published `/i/v1/` code when the address can
 * be sealed, with the original server address reachable behind a fold. Port of `PopopxInviteShareForm`
 * in apps/ios/Shared/Views/NewChat/NewChatView.swift.
 *
 * The code exists to stop the share itself from naming which SMP server holds the queue - every form a
 * core hands out carries its SMP host in plaintext: the full link names it in the host or in `smp=`,
 * and the "short" form (`popopx:/...?h=<host>&p=<port>&c=<hash>`, or the `https://<host>/...` spelling)
 * names it in the query or authority. It is obfuscation, not confidentiality: the format key is
 * published, so nothing here may be described to the user as encrypted or private.
 */
data class PopopxInviteShareForm(
  /** The sealed link, or null when the codec refuses the address (scheme, size). */
  val opaque: String?,
  /** The plain form of what this share carries. Shown only when sealing failed, so an unsealable link
   * is shared rather than lost. */
  val fallback: String,
  /** The plain address, host included - the thing the fold reveals. */
  val original: String,
) {
  /** The one string a screen prints as text, encodes as a QR and hands to the share sheet. */
  val display: String get() = opaque ?: fallback

  /** Whether the share hides something, which is also the only condition under which the fold appears:
   * the displayed code is never the address it stands for. */
  val isSealed: Boolean get() = opaque != null

  companion object {
    fun make(link: CreatedConnLink, short: Boolean): PopopxInviteShareForm {
      // Sealing is decided by the address that is actually being shared, and it is not optional: a
      // short link is not host-free (its `?h=` names the server), so the user's choice selects which
      // address is sealed, never whether it is sealed. popopxChatUri rewrites the full link but not
      // the short one, so both forms go through popopxChatLink here: a shared value must be tappable
      // by whoever receives it.
      val full = popopxChatLink(link.popopxChatUri(short = false))
      val chosen = popopxChatLink(link.popopxChatUri(short = short))
      return PopopxInviteShareForm(
        opaque = PopopxInviteSealCache.linkFor(chosen),
        fallback = chosen,
        original = chosen,
      )
    }
  }
}

/** The one form to show, print and share for a stored connection address: the sealed `/i/v1/` code
 * when the address can be sealed, unchanged when it already is one of those codes (handing a share
 * back to a formatter must not mint a different link), and the plain address when the codec refuses
 * it. Not for migration file links or relay addresses, which are not connection addresses and are
 * consumed in their plain form by other parsers. */
fun popopxSharedLink(uri: String): String {
  val plain = popopxChatLink(uri)
  if (PopopxOpaqueInviteCodec.looksLikeOpaqueLink(plain)) return plain
  return PopopxInviteSealCache.linkFor(plain) ?: plain
}

/**
 * Memoised seals, keyed by the address they carry.
 *
 * Each code embeds a fresh nonce, so sealing on every render would hand the text, the QR and the share
 * sheet three different links for one invitation - and the QR would change underneath a user who is
 * midway through screenshotting it. A cache keyed on the URI is what makes "one invitation, one code"
 * true without storing anything on the view.
 *
 * Locked rather than confined to the main thread: the mint that needs a seal happens in the background
 * api callback (`createInvitation` posts to Main afterwards, but the same URI can be sealed from either
 * side), and a lock costs nothing here where a Compose state would tie the cache to a composition.
 */
object PopopxInviteSealCache {
  private const val MAX_CACHED_SEALS = 50

  private val lock = Any()
  private val seals = HashMap<String, String?>()

  /** The cached seal for [uri], minting it once. A null answer is cached too: an address the codec
   * refuses stays refused, and re-deriving it on every recomposition would not change that. */
  fun linkFor(uri: String): String? = synchronized(lock) {
    if (seals.containsKey(uri)) {
      seals[uri]
    } else {
      // Bounded on purpose: an app session mints few links, but the cache is keyed by URI and lives as
      // long as the process does.
      if (seals.size > MAX_CACHED_SEALS) seals.clear()
      PopopxOpaqueInviteCodec.linkFor(uri).also { seals[uri] = it }
    }
  }
}

/** Whether an incoming string has the shape of one of our shares. Shape only - it does not prove the
 * envelope authenticates, so it is a gate on trying the codec, never a reason to claim anything. */
fun looksLikePopopxInviteLink(value: String): Boolean =
  PopopxOpaqueInviteCodec.looksLikeOpaqueLink(value)

/** The connection URI a received string carries, or null when it is not a readable invitation of ours:
 * not the invite shape, or the shape with an envelope that does not verify, or one that opens to a byte
 * string which is not a connection address (a pairing offer is signed elsewhere).
 *
 * null means "not an invitation", which is also the answer for a damaged one: this app cannot tell a
 * truncated link from a link it was never issued, and saying so would promise it knows who minted it. */
fun popopxInviteLinkURI(value: String): String? {
  if (!PopopxOpaqueInviteCodec.looksLikeOpaqueLink(value)) return null
  val opened = PopopxOpaqueInviteCodec.uriIfOpaqueLink(value) ?: return null
  return opened.takeIf { isConnectableOpened(it) }
}

/** Whether an opened payload is something the connect path can act on: a connection address. A Mac Node
 * pairing offer is deliberately not one, although the codec opens it - the offer is consumed by
 * `PopopxNodeCommand`, which verifies its own Ed25519 signature, and handing it to `ConnectPlan` instead
 * would report a well-formed offer as a damaged invitation. The iOS twin is
 * `PopopxOpaqueInviteCodec.isConnectableOpened`, which `planAndConnect` consults for exactly this
 * reason (`NewChatView.swift:1458`); the list is read from the codec's published value here rather than
 * re-typed, so the two clients cannot drift into accepting different payloads. */
private fun isConnectableOpened(text: String): Boolean =
  PopopxOpaqueInviteCodec.OPENABLE_SCHEMES.any { text.startsWith(it) }

/** What the connection funnel hands to the classifier and to the core: the opened address for a
 * readable share, the string unchanged for everything else. */
fun popopxConnectURI(value: String): String = popopxInviteLinkURI(value) ?: value
