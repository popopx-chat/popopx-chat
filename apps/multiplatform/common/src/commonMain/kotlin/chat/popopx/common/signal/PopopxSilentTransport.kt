package chat.popopx.common.signal

import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings

// Ported from apps/ios/Shared/Features/BadgeCredits/PopopxSilentSignalingRouter.swift:654-721,
// 168-180, 341, 377, 387-402, 426, 464, 495.
//
// The host half of silent signalling, asked through a seam: this package must not import
// `PopopxAPI.kt` or `ChatModel.kt`. The app layer binds [PopopxSilentTransport] to the four FFI
// calls the Swift uses and to nothing else. Every method returns "did the host accept it", the same
// claim the Swift makes at each site — nothing here promises the peer saw anything.

/** The delete tiers, named after `CIDeleteMode` (ChatModel.kt:4374-4379) so the binding is a lookup. */
enum class PopopxSilentDeleteMode(val wireName: String) {
  /**
   * The only correct tier for signalling (router:690-693). `broadcast` would show the other side
   * "message deleted", which writes the signalling's existence back into their timeline; `history`
   * rewrites history as well and its cross-platform semantics are noisier.
   */
  INTERNAL("internal"),

  /** Listed so a `when` cannot silently accept a new tier; signalling never uses these two. */
  INTERNAL_MARK("internalMark"),
  BROADCAST("broadcast"),
  HISTORY("history"),
  ;

  companion object {
    fun from(wireName: String): PopopxSilentDeleteMode? = entries.firstOrNull { it.wireName == wireName }
  }
}

/** The one-time connection [PopopxSilentTransport.addContact] hands back: link + the id the ACK hangs on. */
data class PopopxSignalInvite(val connFullLink: String, val connId: Long)

/**
 * The four host operations silent signalling needs, and nothing else.
 *
 * `send` is the ONLY outbound path for a control frame (router:636-639: routing around it is how a
 * `NODE_CMD` ends up visible in a bubble). `live = false` is not a default the caller may flip: a
 * live message pins the SMP connection open, which is precisely the opposite of "invisible"
 * (router:675, and the same reading at ServerConfigSignalHandler.swift:743,
 * EcoRouterAndDeepLink.swift:539). `ttlSeconds` is null exactly as iOS passes it (router:676) —
 * the row's disappearance is done by [delete], not by the server's expiry.
 *
 * Failure is a Bool, not a throw: `apiSendMessages` does not throw itself, it pops a prompt at the
 * app layer and returns nil, and "nil or an empty array" is the failure (router:656-659, :680-683).
 * Treating anything else as success gives the deadlock of "the UI thinks it sent and the peer never
 * received".
 */
interface PopopxSilentTransport {
  /**
   * Bound to `apiSendMessages(rh, type, id, scope, sendAsGroup, live, ttl, sign, composedMessages)`.
   * [live] is passed by every caller as `false` (router:675) and the binding must hand it to the host
   * verbatim; [ttlSeconds] is null exactly as iOS passes it (router:676).
   */
  suspend fun send(chatId: Long, isGroup: Boolean, text: String, live: Boolean = false, ttlSeconds: Int? = null): Boolean

  /** Bound to `apiDeleteChatItems(rh, type, id, scope, itemIds, mode)`, always with [PopopxSilentDeleteMode.INTERNAL]. */
  suspend fun delete(chatId: Long, itemIds: List<Long>, mode: PopopxSilentDeleteMode): Boolean

  /**
   * Bound to `apiAddContact(rh, incognito)`. Signalling always asks for it `incognito = true`
   * (router:426, :495): a redemption link must not reveal the giver's profile, and every mint
   * opens a FRESH connection because a link can only be accepted once (router:419-421).
   */
  suspend fun addContact(incognito: Boolean): PopopxSignalInvite?

  /**
   * Bound to `apiConnect(rh, incognito, connLink)`, again `incognito = true` (router:392, :464).
   * Returns the new connection's id, which is the key the pending REQ is stored under: the REQ can
   * only be sent once `contactConnected` reports the peer accepted (router header:23-28 — one step
   * earlier simply cannot go out, that connection cannot carry a message yet).
   */
  suspend fun connect(incognito: Boolean, connFullLink: String): Long?

  /**
   * Bound to `apiDeleteContact(rh, id, chatDeleteMode = ChatDeleteMode.Full(notify = false))`.
   * Used once, after a one-time redemption lands (router:338-342, :376-378): the whole temporary
   * contact is removed, and with `notify = false` — the peer already has the ACK, and one more
   * "so-and-so deleted you" would write this transaction back into both timelines.
   */
  suspend fun deleteContact(contactId: Long, notifyPeer: Boolean): Boolean
}

/**
 * The no-op adapter: every call is refused, no host dependency. It exists so the router can be
 * constructed, injected and tested before the app layer binds the real calls; a bound build must
 * replace it, and silence here is a bug, not a fallback.
 */
class PopopxSilentTransportAdapter : PopopxSilentTransport {
  override suspend fun send(chatId: Long, isGroup: Boolean, text: String, live: Boolean, ttlSeconds: Int?): Boolean = false

  override suspend fun delete(chatId: Long, itemIds: List<Long>, mode: PopopxSilentDeleteMode): Boolean = false

  override suspend fun addContact(incognito: Boolean): PopopxSignalInvite? = null

  override suspend fun connect(incognito: Boolean, connFullLink: String): Long? = null

  override suspend fun deleteContact(contactId: Long, notifyPeer: Boolean): Boolean = false
}

/**
 * The pending-REQ table as durable state, exactly the router's `pendingRequestsByConnection`
 * (router:142, :157-162, stored under [PopopxSignalKeys.PENDING_REDEEMS]). iOS put it in the
 * Keychain's `ephemeralConnections` slot; the value here is a voucher id and a wire string that are
 * public by construction (the user handed the code to somebody), so it is kept in plain settings —
 * no second keystore, and the desktop actual does not reach the Keychain at all. If the org ruling
 * is "anything the Keychain holds on iOS holds here", this is the one call site to move, via
 * `chat.popopx.common.eco.PopopxEcoSecrets`.
 */
class PopopxSignalPendingStore(private val defaults: Settings = settings) {
  fun load(): Map<Long, PopopxPendingRedeem> =
    PopopxPendingRedeemWire.decode(defaults.getStringOrNull(PopopxSignalKeys.PENDING_REDEEMS))

  fun save(entries: Map<Long, PopopxPendingRedeem>) {
    defaults.putString(PopopxSignalKeys.PENDING_REDEEMS, PopopxPendingRedeemWire.encode(entries))
  }

  fun clear() = defaults.remove(PopopxSignalKeys.PENDING_REDEEMS)
}
