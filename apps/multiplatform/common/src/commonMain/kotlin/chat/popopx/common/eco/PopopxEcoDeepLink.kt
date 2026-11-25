package chat.popopx.common.eco

import chat.popopx.common.model.ChatModel

// Ported from apps/ios/Shared/Features/ServiceAccount/PopopxEcoRouterAndDeepLink.swift:822-1094.

/**
 * `popopx://service?uri=<service address>&ref=<article id>` and
 * `popopx://sso?uri=<service address>&session=<sso session id>`.
 *
 * ### Why this is not a URI-component parse, unlike [PopopxChannelPublicURI]
 * The `uri=` parameter holds a connection address, and a connection address carries `#`, `&` and `=` of its
 * own (`smp://host/connId#key=…&auth=…`). Percent-encoded by the producer that is an ordinary query
 * parameter. Left raw — which is what a QR generator that concatenates strings produces — it turns the
 * address's own `&auth=` into a parameter *after* a fragment, and a whole-query split on `&` cuts the
 * address in half and loses it. So this parser locates the two parameters it knows by name at parameter
 * boundaries and treats EVERYTHING BETWEEN THEM as the address, in either order.
 *
 * The cost of that choice, stated rather than hidden: unlike [PopopxChannelPublicURI.parse] this cannot
 * reject unrecognised keys, because an unescaped address is indistinguishable from a pile of unrecognised
 * keys. What makes the value safe instead is the two checks at the end — the address must be one
 * printable-ASCII token free of quoting metacharacters, and the id must be the single token
 * [PopopxEcoUplink] requires — plus the fact that the address is never interpreted here: it goes to the
 * connection flow, which asks the core, exactly as pasting a link does.
 */
data class PopopxEcoLink(
  /** The service account's own address, percent-decoded, as it is handed to the connection flow. */
  val serviceURI: String,
  val kind: Kind,
  /** The article id or the SSO session id — whichever parameter the kind names. This is the uplink payload. */
  val payload: String,
) {
  enum class Kind(val prefix: String, val parameter: String) {
    /** A channel article's "handle the business in this service account" link; sends `::REF::`. */
    SERVICE("popopx://service?", "ref"),

    /** A third-party site's login QR, already scanned by this camera; sends `::SSO_SCAN::`. */
    SSO("popopx://sso?", "session"),
    ;

    companion object {
      /** The literal that claims the link, `?` included, so a bare `popopx://service` is not an eco link. */
      fun of(text: String): Kind? = entries.firstOrNull { text.startsWith(it.prefix) }
    }
  }

  companion object {
    private const val ADDRESS_PARAMETER = "uri"

    /** The cap the mesh bridge applied before it put a link on a command line (`PopopxOfflineBridge.swift:100`). */
    private const val MAXIMUM_ADDRESS_CHARACTERS = 2048

    /**
     * Quoting and expansion metacharacters: they would break the JSON envelope the command travels in even
     * where the byte itself is printable (`PopopxOfflineBridge.swift:104`).
     */
    private const val FORBIDDEN_ADDRESS_CHARACTERS = "\"'`\\" + "$"

    fun parse(text: String): PopopxEcoLink? {
      val trimmed = text.trim()
      if (trimmed.ecoLength() > PopopxEcoLimits.MAXIMUM_URL_CHARACTERS) return null
      val kind = Kind.of(trimmed) ?: return null
      val queryStart = kind.prefix.length
      if (trimmed.length < queryStart) return null
      val query = trimmed.substring(queryStart)

      // One walk over `&`-delimited segments. A parameter counts only at the start of the query or straight
      // after a `&`, which is what stops an `xref=` inside an address value from being read as the article id.
      var uriNameAt = -1
      var uriValueAt = -1
      var anchorNameAt = -1
      var anchorValue: String? = null
      var index = 0
      while (index < query.length) {
        val equals = query.indexOf('=', index)
        if (equals < 0) break
        val name = query.substring(index, equals)
        val valueAt = equals + 1
        val foundAmpersand = query.indexOf('&', valueAt)
        val valueEnd = if (foundAmpersand < 0) query.length else foundAmpersand
        when (name) {
          ADDRESS_PARAMETER -> {
            if (uriNameAt >= 0) return null
            uriNameAt = index
            uriValueAt = valueAt
          }

          kind.parameter -> {
            if (anchorNameAt >= 0) return null
            anchorNameAt = index
            anchorValue = query.substring(valueAt, valueEnd)
          }
        }
        if (valueEnd >= query.length) break
        index = valueEnd + 1
      }
      if (uriNameAt < 0 || uriValueAt < 0) return null
      val anchor = anchorValue ?: return null

      // The address is the whole span between the two anchors, separators included, so an unescaped
      // `#key=…&auth=…` survives.
      val addressRaw: String = if (uriNameAt < anchorNameAt) {
        val separator = anchorNameAt - 1
        if (anchorNameAt <= uriValueAt || query[separator] != '&') return null
        query.substring(uriValueAt, separator)
      } else {
        query.substring(uriValueAt)
      }

      val address = percentDecoded(addressRaw) ?: return null
      if (!isAddressToken(address)) return null
      val payload = percentDecoded(anchor) ?: return null
      if (!PopopxEcoUplink.isSendablePayload(payload)) return null
      return PopopxEcoLink(address, kind, payload)
    }

    /**
     * Percent-decodes only what was percent-encoded. A `%` has no other meaning in either value, so a
     * malformed escape is a broken link rather than a literal percent. Hand-written because the JVM's
     * decoder also converts `+` into a space, which Swift's `removingPercentEncoding` does not — and a
     * connection address is full of `+` in its base64 key.
     */
    private fun percentDecoded(text: String): String? {
      if (text.isEmpty()) return null
      if (!text.contains('%')) return text
      val out = StringBuilder(text.length)
      var i = 0
      while (i < text.length) {
        val c = text[i]
        if (c != '%') {
          out.append(c)
          i += 1
          continue
        }
        if (i + 2 >= text.length) return null
        val high = Character.digit(text[i + 1], 16)
        val low = Character.digit(text[i + 2], 16)
        if (high < 0 || low < 0) return null
        out.append(((high shl 4) + low).toChar())
        i += 3
      }
      return out.toString()
    }

    /** 0x21…0x7E only, and none of the quoting metacharacters. A space would split the argument; a newline does that AND ends the command. */
    private fun isAddressToken(address: String): Boolean {
      if (address.isEmpty() || address.length > MAXIMUM_ADDRESS_CHARACTERS) return false
      if (address.any { it in FORBIDDEN_ADDRESS_CHARACTERS }) return false
      return address.all { it.code in 0x21..0x7E }
    }
  }
}

/**
 * Turns an eco deep link into either an opened service-account conversation carrying the uplink, or a
 * connection request plus the one-shot intent that the peer's handshake collects.
 *
 * ### What is deliberately not here
 * No second send path: [PopopxEcoRouter] owns the only one, and its uplinks are suppressed at render by
 * [PopopxEcoUplink] rather than by a gate of this module's. No address-to-contact lookup of the app's own:
 * a contact stores no address and a connection stores no link, so the branch that cannot recognise the
 * address records an intent instead of guessing a destination. The one address-to-id fact the core DOES
 * report — the callback naming the contact it matched for this address — is captured as
 * [PopopxEcoRouter.bindPendingIntent].
 *
 * No confirmation before scanning. `::SSO_SCAN::` goes out silently, which is what the QR promises: the
 * user's action IS the authorisation, and a dialog on top of it would be the pattern every phishing QR
 * trains users to tap through. What was ruled out is a SECOND prompt, not the guard: the send is bound to
 * the address that was scanned, expires, and is refused by any handshake that does not match it.
 */
class PopopxEcoDeepLinkHandler(
  private val router: PopopxEcoRouter,
  /**
   * The host's own funnel: on Android this is `planAndConnect`, whose `cleanup` fires on cancel, on a
   * refused link AND after a chat opened, and whose `filterKnownContact` is the only place an invite address
   * and a contact id are ever seen together. Only scalars may leave that callback.
   */
  private val connect: (serviceURI: String, onCleanup: () -> Unit, onKnownContact: suspend (Long) -> Unit) -> Unit,
  /** Suspending because opening a conversation on this host is a model operation, not a navigation call. */
  private val openKnownChat: suspend (contactId: Long) -> Unit,
  private val hasSession: (contactId: Long) -> Boolean = { PopopxEcoSessionStore.hasSession(it) },
  /**
   * Whether the host actually has a conversation row for this contact. Injected rather than read inline
   * because the answer comes from the live chat list, and a router test that never built one would otherwise
   * be unable to reach the bind branch at all — the branch that decides whether a held intent is spent now
   * or dropped.
   */
  private val hasContactChat: (contactId: Long) -> Boolean = { ChatModel.getContactChat(it) != null },
) {
  /**
   * The scanner entry: a string that is not an eco link is reported as unhandled and the caller continues.
   * Not suspending on purpose — the intent is recorded before the connection starts, and the caller has to
   * know synchronously whether the link became this module's.
   */
  fun handle(text: String): Boolean {
    val link = PopopxEcoLink.parse(text) ?: return false
    dispatch(link)
    return true
  }

  private fun dispatch(link: PopopxEcoLink) {
    val kind = if (link.kind == PopopxEcoLink.Kind.SERVICE) {
      PopopxEcoIntent.Kind.Reference(link.payload)
    } else {
      PopopxEcoIntent.Kind.SsoScan(link.payload)
    }
    router.recordPendingIntent(kind, link.serviceURI, link.payload)
    connect(
      link.serviceURI,
      { router.discardPendingIntentIfConnectionAborted() },
      { contactId -> reachedExistingContact(contactId, link) },
    )
  }

  /**
   * The branch the core reports as "this address is somebody you already know": switch to that conversation,
   * and send now if the peer has already identified itself as a service account.
   */
  private suspend fun reachedExistingContact(contactId: Long, link: PopopxEcoLink) {
    // A contact with no chat row is nowhere to send and nothing to open. Dropping the intent is the honest
    // answer: keeping it would leave a silent authorisation line waiting for the NEXT handshake, from an
    // unrelated service account.
    if (!hasContactChat(contactId)) {
      router.clearPendingIntent()
      return
    }
    openKnownChat(contactId)
    if (!hasSession(contactId)) {
      // Connected, not yet identified: the app's own definition of a service account is a completed eco
      // handshake, so the intent stays and the handshake delivers it — and now stays BOUND, because this
      // callback is the only place in the app that ever saw the address and the contact id together.
      router.bindPendingIntent(contactId)
      return
    }
    router.clearPendingIntent()
    when (link.kind) {
      PopopxEcoLink.Kind.SERVICE -> router.sendReference(link.payload, contactId)
      PopopxEcoLink.Kind.SSO -> router.sendSSOScan(link.payload, contactId)
    }
  }

  /** A contact with no chat row is nowhere to send and nothing to open. */
  private fun hostHasContactChat(contactId: Long): Boolean = ChatModel.getContactChat(contactId) != null
}
