package chat.popopx.common.eco

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.popopx.common.model.ChatInfo
import chat.popopx.common.model.ChatModel
import chat.popopx.common.model.ChatType
import chat.popopx.common.model.ConnectProgressManager
import kotlin.math.max

// Ported from apps/ios/Shared/Features/ServiceAccount/PopopxEcoRouterAndDeepLink.swift:313-820.
//
// MEASURED DEVIATION, stated rather than hidden. iOS sends every eco uplink through
// `PopopxComposerRouting.dispatch` + `PopopxMeshRuntime.shared.router.send`, so a callback to a service
// account that happens to be Cabin-bound can ride the mesh. Neither type exists anywhere in this
// Android/KMP tree — a recursive grep over `common/src/commonMain` for `ComposerRouting|MeshRuntime`
// returns zero files, because module 5 was never ported here. What is ported is the branch iOS takes when
// that decision table answers `.hostShouldSend`: one plain `apiSendMessages` text send. An eco uplink is
// plain text by construction, so the line on the wire is identical; what Android cannot yet do is reach a
// mesh-only peer, and `PopopxEcoSendFailure.NO_ROUTE` is kept as the value that would say so.

/** Why an uplink did not leave the device. Split because the card may retry one and must never retry another. */
enum class PopopxEcoSendFailure {
  /** `apiSendMessages` answered with nothing, which is how that call reports a refusal (it does not throw). */
  SEND_REFUSED,

  /** Nothing in this build can carry it: the route does not exist. */
  NO_ROUTE,

  /** A payload that would have looked like two commands, refused before anything was sent. */
  MALFORMED_PAYLOAD,
}

sealed class PopopxEcoSendOutcome {
  /** The text left this device. */
  data object Sent : PopopxEcoSendOutcome()

  data class Failed(val reason: PopopxEcoSendFailure) : PopopxEcoSendOutcome()

  val wasSent: Boolean get() = this is Sent

  companion object {
    fun failed(reason: PopopxEcoSendFailure): PopopxEcoSendOutcome = Failed(reason)
  }
}

/**
 * The one thing the host has to provide: a way to put a line into a direct conversation, and a way to
 * erase the row a control frame occupied. Everything else in this file is decision logic that needs neither.
 */
interface PopopxEcoSender {
  suspend fun sendUplink(contactId: Long, text: String): PopopxEcoSendOutcome

  /**
   * Delete this device's row of a control frame with the INTERNAL mode and nothing else: `.cidmBroadcast`
   * would tell the peer a message was deleted, which writes this module's existence back into their
   * timeline (Swift:449-474). Failure is logged, never surfaced — a row that stays is suppressed at render,
   * so the worst case is an invisible row, not a duplicated card.
   */
  suspend fun eraseControlRow(chatType: ChatType, chatId: Long, itemId: Long)
}

/** The commerce half of a card payment, asked through a seam: eco must not own the ledger. */
interface PopopxCreditSource {
  val balance: Int

  /** Debit and return the ledger entry id, or null when the debit was refused. */
  fun payForService(amount: Int, note: String): String?
}

sealed class PopopxCreditPayment {
  /**
   * The debit landed. `delivered` says whether the confirmation callback reached the peer, which the card
   * shows as "waiting for a reply" rather than as a failure — the credits are gone either way.
   */
  data class Paid(val transactionId: String, val delivered: Boolean) : PopopxCreditPayment()

  data class InsufficientBalance(val required: Int, val available: Int) : PopopxCreditPayment()

  data class Failed(val failure: PopopxEcoPaymentFailure) : PopopxCreditPayment()
}

enum class PopopxEcoPaymentFailure { MALFORMED_PAYLOAD, LEDGER }

/** Which credit store to open, and by how much the user is short. */
data class PopopxEcoCreditRequest(val required: Int, val available: Int) {
  val shortfall: Int get() = max(required - available, 0)
}

/** Which channel an `open_channel` action asked to see, and what the page should offer when not a member. */
data class PopopxEcoChannelPageRequest(
  /** Non-null opens that channel's detail; null opens the list, which is where the import field lives. */
  val channelId: String?,
  /** The tapped link — fragment and read key included — waiting in the import field. Nothing here sends it. */
  val importURI: String?,
) {
  val id: String get() = channelId ?: "import:${importURI ?: ""}"
}

/**
 * A follow-up that can only be delivered once a connection exists: `::REF::` and `::SSO_SCAN::` both need a
 * contact id, and a deep link opening a service account for the first time has none yet.
 *
 * Held in memory rather than persisted: an intent that survived a relaunch would be a silent message sent
 * without the user having touched anything since, and `::SSO_SCAN::` authorises a login on a third-party site.
 */
data class PopopxEcoIntent(
  val kind: Kind,
  /**
   * The invite address from the link's `uri=`. **Never logged and never shown whole** — it carries the
   * secret that authorises the connection. Nothing compares it against a local record, because no local
   * record keeps a peer address: that is why [knownContactIds] and [boundContactId] exist.
   */
  val serviceURI: String,
  /** The link's `ref`/`session` value, kept so a confirmation sheet can name what it is about to send. */
  val displayValue: String,
  /** Stamped by [PopopxEcoRouter.recordPendingIntent], never by the caller, so an intent cannot be made newborn. */
  val recordedAtMs: Long,
  /** Every direct contact id the app had at that moment: a contact NOT in this set is one this link created. */
  val knownContactIds: Set<Long>,
  /** Set once the connection flow reports the contact it already knew for this exact address. */
  val boundContactId: Long? = null,
) {
  sealed class Kind {
    /** Send `::REF::<articleId>` into the service account the link opened. */
    data class Reference(val articleId: String) : Kind()

    /** Send `::SSO_SCAN::<sessionId>`: a third-party site's QR, already scanned by this device. */
    data class SsoScan(val sessionId: String) : Kind()
  }

  /** A link scanned and left is dead rather than queued: delivering it later is the mis-delivery this type exists to avoid. */
  fun isStale(nowMs: Long): Boolean =
    (nowMs - recordedAtMs) / 1000 > PopopxEcoLimits.PENDING_INTENT_LIFETIME_SECONDS

  /**
   * Whether the handshake from [contactId] may consume this intent.
   *
   * Bound: only that contact, which is exact. Unbound: only a contact that did NOT exist when the link was
   * scanned, because the connection a scan makes is a new contact. Refusing the known ones is the point —
   * it stops an `::SSO_SCAN::` meant for the account in the link from landing in whichever service account
   * handshakes next.
   *
   * The two directions this cannot close, and how each fails: a NEW contact created by something other than
   * this link, inside the window, can still collect the intent; and a contact the link did name whose
   * `filterKnownContact` never fired is refused — the intent is consumed and dropped rather than delivered
   * on a guess. That false negative is the safe half of the trade: the user re-scans, whereas a false
   * positive authorises a login on the wrong account.
   */
  fun accepts(contactId: Long): Boolean = boundContactId?.let { it == contactId } ?: !knownContactIds.contains(contactId)
}

/**
 * The inbound half, the outbound half and the pending intents in one type: they are three ends of one
 * protocol, and the ordering between them is the part that is easy to get wrong.
 */
class PopopxEcoRouter(
  private val store: PopopxEcoStore = PopopxEcoStore.shared,
  private val sender: PopopxEcoSender,
  private val keyRotation: PopopxChannelKeyRotation = PopopxChannelKeyRotation.shared,
  private val h5: PopopxH5Launcher = PopopxH5Launcher.shared,
  /**
   * Looked up per payment rather than captured, because the ledger is a different module's singleton and the
   * router is built before that module has one. A payment with no ledger fails as `LEDGER`, which is what the
   * user should see if the wallet is genuinely absent.
   */
  private val creditsSource: () -> PopopxCreditSource? = { null },
  private val nowMs: () -> Long = { System.currentTimeMillis() },
  /** The ledger note is amount plus the title the user was actually shown; iOS formats it from its copy table. */
  private val paidNoteFormat: (Int) -> String = { "Paid $it POPOPX Compute Credits" },
  private val directContactIds: () -> Set<Long> = {
    ChatModel.chats.value.mapNotNull { (it.chatInfo as? ChatInfo.Direct)?.contact?.contactId }.toSet()
  },
  private val connectionInProgress: () -> Boolean = { ConnectProgressManager.isInProgress },
) {
  var pendingIntent: PopopxEcoIntent? = null
    private set

  /**
   * Raised by `open_channel` and drained by the host, exactly as iOS's `@Published` pair is
   * (PopopxEcoRouterAndDeepLink.swift:707). Compose state rather than a plain `var` because the host learns
   * about the request by observing it — a `var` the UI only reads on a timer is how a tap ends up reporting
   * "Done" while nothing opened.
   */
  var channelPageRequest: PopopxEcoChannelPageRequest? by mutableStateOf(null)

  var creditTopUpRequest: PopopxEcoCreditRequest? by mutableStateOf(null)
    private set

  // MARK: Mount point · a message arrived

  /**
   * Called beside the silent-signalling observer for every inbound message, from the one site that reads the
   * text, so there is never a second subscription ordering the same message differently.
   *
   * In a group only `service_card` is accepted. The other three frames are per-person or per-channel secrets
   * and a group has neither: a menu would attach one member's private menu to a conversation shared with
   * everybody, a handshake would store one member's pairwise identity under the group's id, and a key update
   * would push an epoch key to people who are not members of that channel (Swift:400-420).
   */
  suspend fun observeIncoming(chatType: ChatType, chatId: Long, itemId: Long, text: String): PopopxEcoInboundVerdict {
    if (chatType != ChatType.Direct && chatType != ChatType.Group) return PopopxEcoInboundVerdict.NOT_ECO
    val frame = PopopxEcoMarker.parseControlText(text) ?: return PopopxEcoInboundVerdict.NOT_ECO
    if (chatType == ChatType.Group && frame !is PopopxEcoFrame.ServiceCard) return PopopxEcoInboundVerdict.REFUSED_IN_GROUP
    return handle(chatType, chatId, itemId, frame)
  }

  private suspend fun handle(chatType: ChatType, chatId: Long, itemId: Long, frame: PopopxEcoFrame): PopopxEcoInboundVerdict {
    // `chatId` is `chatInfo.apiId`, which is what the send path and the session index both use.
    val outcome = store.apply(frame, chatId)
    when (outcome) {
      PopopxEcoApplyOutcome.REJECTED, PopopxEcoApplyOutcome.KEYCHAIN_FAILED -> Unit
      PopopxEcoApplyOutcome.IGNORED_STALE -> Unit
      // The row stays: it is the bubble the user reads.
      PopopxEcoApplyOutcome.RENDERED_CARD -> Unit
      PopopxEcoApplyOutcome.UPDATED_CARD,
      PopopxEcoApplyOutcome.STORED_SESSION,
      PopopxEcoApplyOutcome.STORED_MENU,
      PopopxEcoApplyOutcome.ROTATED_KEY,
      -> sender.eraseControlRow(chatType, chatId, itemId)
    }
    // A handshake is also the moment a pending deep-link intent can finally be delivered: this device just
    // met a service account, and this is the only point in the app that knows it happened.
    if (frame is PopopxEcoFrame.SessionHandshake && chatType == ChatType.Direct) deliverPendingIntent(chatId)
    return PopopxEcoInboundVerdict.applied(outcome)
  }

  // MARK: Uplink

  /**
   * Send one eco uplink line (`::CB::…`, `::REF::…`, `::SSO_SCAN::…`) into a direct conversation. The host
   * fallback is the same text sent the ordinary way: an eco uplink is plain text by construction, which is
   * exactly why it needs no second code path.
   */
  suspend fun send(text: String, contactId: Long): PopopxEcoSendOutcome = sender.sendUplink(contactId, text)

  /**
   * The callback a card button fires. Every uplink line is built by [PopopxEcoUplink.wireString], never by
   * spelling the prefix here: that is the same function the render-suppression gate consults, so a line that
   * can be sent is a line that can be hidden, and neither end can be updated alone.
   */
  suspend fun sendCallback(payload: String, contactId: Long): PopopxEcoSendOutcome =
    sendUplink(PopopxEcoUplink.CALLBACK_PREFIX, payload, contactId)

  suspend fun sendReference(articleId: String, contactId: Long): PopopxEcoSendOutcome =
    sendUplink(PopopxEcoUplink.REFERENCE_PREFIX, articleId, contactId)

  suspend fun sendSSOScan(sessionId: String, contactId: Long): PopopxEcoSendOutcome =
    sendUplink(PopopxEcoUplink.SSO_SCAN_PREFIX, sessionId, contactId)

  private suspend fun sendUplink(prefix: String, payload: String, contactId: Long): PopopxEcoSendOutcome {
    val wire = PopopxEcoUplink.wireString(prefix, payload) ?: return PopopxEcoSendOutcome.failed(PopopxEcoSendFailure.MALFORMED_PAYLOAD)
    return send(wire, contactId)
  }

  // MARK: Pending intents

  /**
   * Take custody of an intent for one handshake window. The three target-facts are stamped here rather than
   * by the caller: a caller that could choose `recordedAt` could keep the intent alive indefinitely, and the
   * contact snapshot has to be taken at the same instant for the before/after comparison in
   * [PopopxEcoIntent.accepts] to mean anything.
   */
  fun recordPendingIntent(kind: PopopxEcoIntent.Kind, serviceURI: String, displayValue: String) {
    pendingIntent = PopopxEcoIntent(kind, serviceURI, displayValue, nowMs(), directContactIds())
  }

  /**
   * Pin a held intent to a contact id, from the one place that maps an invite address to a contact:
   * `planAndConnect`'s `filterKnownContact`, handed the contact it recognised for THAT address. After this,
   * [PopopxEcoIntent.accepts] is exact.
   */
  fun bindPendingIntent(contactId: Long) {
    val intent = pendingIntent ?: return
    pendingIntent = intent.copy(boundContactId = contactId)
  }

  /**
   * Drop the intent when the connection it was waiting for was abandoned.
   *
   * `cleanup` fires on cancel, on a refused link AND after a chat opened, so "cleanup ran" proves nothing on
   * its own. The two tests that separate abandoned from succeeded: nothing is in progress any more, and no
   * contact exists that the snapshot did not already have. An intent already bound to a contact is left
   * alone, because that contact is connected and the handshake — not this cleanup — owns its delivery.
   */
  fun discardPendingIntentIfConnectionAborted() {
    val intent = pendingIntent ?: return
    if (intent.boundContactId != null) return
    if (connectionInProgress()) return
    if ((directContactIds() - intent.knownContactIds).isNotEmpty()) return
    pendingIntent = null
  }

  /**
   * Deliver the held intent to the contact that just completed an eco handshake, if it is that contact.
   *
   * Two refusals, then one shot. A refused or expired intent is STILL consumed, because leaving it in the
   * slot would hand it to the next handshake instead — the exact mis-delivery these tests exist to prevent.
   */
  private suspend fun deliverPendingIntent(contactId: Long) {
    val intent = pendingIntent ?: return
    pendingIntent = null
    if (intent.isStale(nowMs())) return
    if (!intent.accepts(contactId)) return
    when (val kind = intent.kind) {
      is PopopxEcoIntent.Kind.Reference -> sendReference(kind.articleId, contactId)
      is PopopxEcoIntent.Kind.SsoScan -> sendSSOScan(kind.sessionId, contactId)
    }
  }

  fun clearPendingIntent() {
    pendingIntent = null
  }

  // MARK: Channel page

  /**
   * `open_channel` on a card button or a menu item: show this device's page for that channel, or offer the
   * link for import. "Joined" is the narrow, provable thing — this device holds key material for that
   * `channelId`, which is the only local index keyed by the id the URI carries. A channel paid for through
   * the credits flow whose keys never arrived has no such row, and opening a detail page of empty rows for
   * it is worse than the guidance below, which is also what an unjoined channel needs because keys arrive
   * FROM the link. Surfaced as a request rather than a navigation push: the page carries its own stack.
   */
  fun openChannel(uri: PopopxChannelPublicURI, sourceText: String): Boolean {
    val joined = keyRotation.channel(uri.channelId) != null
    channelPageRequest = if (joined) PopopxEcoChannelPageRequest(uri.channelId, null) else PopopxEcoChannelPageRequest(null, sourceText)
    return true
  }

  /** The menu form: a payload that is not a channel URI is not this action's business, and saying so lets the caller report it. */
  fun openChannel(text: String): Boolean {
    val uri = PopopxChannelPublicURI.parse(text) ?: return false
    return openChannel(uri, text)
  }

  fun takeChannelPageRequest(): PopopxEcoChannelPageRequest? {
    val request = channelPageRequest
    channelPageRequest = null
    return request
  }

  // MARK: Credits

  /**
   * A card button that spends compute credits. The order matters twice over: the balance is checked BEFORE
   * anything is written to the ledger, and the callback is sent only AFTER the debit succeeded — a
   * `::CB::<payload>:paid_<txHash>` naming a transaction that does not exist would be a payment confirmation
   * the server can neither refuse nor honour. When the debit succeeds but the callback does not land, the
   * entry is kept and the hash returned anyway: the user paid, the ledger is the record, and a second tap on
   * a locked button must not charge them twice (Swift:659-700).
   */
  suspend fun payForCard(card: PopopxServiceCard, action: PopopxEcoAction, contactId: Long): PopopxCreditPayment {
    val amount = action.amount
    if (amount == null || amount < PopopxEcoLimits.MINIMUM_AMOUNT || amount > PopopxEcoLimits.MAXIMUM_CREDIT_AMOUNT) {
      return PopopxCreditPayment.Failed(PopopxEcoPaymentFailure.MALFORMED_PAYLOAD)
    }
    val source = creditsSource() ?: return PopopxCreditPayment.Failed(PopopxEcoPaymentFailure.LEDGER)
    if (source.balance < amount) return PopopxCreditPayment.InsufficientBalance(amount, source.balance)
    // Proved before the debit, not after: the payload half of the callback line is server-supplied, and a
    // payload `wireString` would refuse is a payment that takes the credits and then cannot deliver the
    // confirmation naming them.
    val callbackPayload = action.payload ?: card.cardId
    if (!PopopxEcoUplink.isSendablePayload(callbackPayload)) return PopopxCreditPayment.Failed(PopopxEcoPaymentFailure.MALFORMED_PAYLOAD)
    // `action.target` is deliberately NOT used in the note: it is a server-supplied string that never
    // appeared on screen, and a ledger row nobody can account for is worse than a terse one. `card.title` is
    // bounded by `PopopxServiceCard.isSane`, so the note cannot be padded out by a peer.
    val entryId = source.payForService(amount, "${paidNoteFormat(amount)} · ${card.title}")
      ?: return PopopxCreditPayment.Failed(PopopxEcoPaymentFailure.LEDGER)
    val outcome = sendUplink(PopopxEcoUplink.CALLBACK_PREFIX, "$callbackPayload:paid_$entryId", contactId)
    return PopopxCreditPayment.Paid(entryId, outcome.wasSent)
  }

  fun requestCreditTopUp(required: Int, available: Int) {
    creditTopUpRequest = PopopxEcoCreditRequest(required, available)
  }

  fun takeCreditTopUpRequest(): PopopxEcoCreditRequest? {
    val request = creditTopUpRequest
    creditTopUpRequest = null
    return request
  }
}

/** What the inbound gate decided, kept as a value so the mount point and the tests can both assert it. */
sealed class PopopxEcoInboundVerdict {
  /** Not an eco frame at all, or a chat type that never carries one. */
  data object NOT_ECO : PopopxEcoInboundVerdict()

  /** A frame that must not be applied to a shared conversation. */
  data object REFUSED_IN_GROUP : PopopxEcoInboundVerdict()

  data class Applied(val outcome: PopopxEcoApplyOutcome) : PopopxEcoInboundVerdict()

  companion object {
    fun applied(outcome: PopopxEcoApplyOutcome) = Applied(outcome)
  }
}

/**
 * What a card button does, decided in one place so the bubble, the menu bar and the deep link cannot each
 * invent a half of it (Swift:758-806).
 */
object PopopxEcoActionRunner {
  /**
   * The lockout is keyed on `cardId + actionId`, which means the CARD decides when the lock is released: any
   * change to it clears its own locks ([PopopxEcoStore.apply]). A timer-based lock would release while the
   * peer was still silent.
   */
  suspend fun run(
    action: PopopxEcoAction,
    card: PopopxServiceCard,
    contactId: Long,
    router: PopopxEcoRouter,
    store: PopopxEcoStore = PopopxEcoStore.shared,
    h5: PopopxH5Launcher = PopopxH5Launcher.shared,
    nowMs: () -> Long = { System.currentTimeMillis() },
  ): PopopxEcoActionResult {
    if (store.isActionLocked(card.cardId, action.id)) return PopopxEcoActionResult.LOCKED
    if (!card.isLive(nowMs())) return PopopxEcoActionResult.EXPIRED
    if (!action.isLive) return PopopxEcoActionResult.IGNORED
    store.lock(card.cardId, action.id)
    return when (action.kind) {
      PopopxEcoAction.Kind.CALLBACK -> {
        val payload = action.payload ?: return PopopxEcoActionResult.IGNORED
        if (router.sendCallback(payload, contactId).wasSent) PopopxEcoActionResult.SENT_CALLBACK else PopopxEcoActionResult.SEND_FAILED
      }

      PopopxEcoAction.Kind.PAY_CREDITS ->
        when (val payment = router.payForCard(card, action, contactId)) {
          is PopopxCreditPayment.Paid ->
            if (payment.delivered) PopopxEcoActionResult.SENT_CALLBACK else PopopxEcoActionResult.PAID_AWAITING_REPLY

          is PopopxCreditPayment.InsufficientBalance -> {
            router.requestCreditTopUp(payment.required, payment.available)
            PopopxEcoActionResult.NeedsCredits(payment.required, payment.available)
          }

          is PopopxCreditPayment.Failed -> PopopxEcoActionResult.SEND_FAILED
        }

      PopopxEcoAction.Kind.OPEN_URL -> {
        val url = action.url ?: return PopopxEcoActionResult.IGNORED
        if (!PopopxEcoAction.isHttpUrl(url)) return PopopxEcoActionResult.IGNORED
        val session = store.session(contactId) ?: return PopopxEcoActionResult.NO_SESSION
        if (h5.present(url, session)) PopopxEcoActionResult.OPENED_H5 else PopopxEcoActionResult.SEND_FAILED
      }

      // Parsed once here for the SHAPE (a malformed payload is IGNORED, not a failure the user is told
      // about) and the text is passed along, because the unjoined branch needs the fragment the parsed value
      // deliberately drops.
      PopopxEcoAction.Kind.OPEN_CHANNEL -> {
        val source = action.payload ?: return PopopxEcoActionResult.IGNORED
        val uri = PopopxChannelPublicURI.parse(source) ?: return PopopxEcoActionResult.IGNORED
        if (router.openChannel(uri, source)) PopopxEcoActionResult.OPENED_CHANNEL else PopopxEcoActionResult.SEND_FAILED
      }

      // A card carries commands only through a menu button; a card action of this kind is a server that
      // meant the menu layer.
      PopopxEcoAction.Kind.SEND_COMMAND, PopopxEcoAction.Kind.NONE -> PopopxEcoActionResult.IGNORED
    }
  }
}

/** The outcome a bubble turns into a line of copy and a haptic. Nothing here is a sentence: the view owns the wording. */
sealed class PopopxEcoActionResult {
  data object SENT_CALLBACK : PopopxEcoActionResult()

  /** The credits are gone; only the confirmation has not been seen by the peer. */
  data object PAID_AWAITING_REPLY : PopopxEcoActionResult()

  data class NeedsCredits(val required: Int, val available: Int) : PopopxEcoActionResult()

  data object OPENED_H5 : PopopxEcoActionResult()
  data object OPENED_CHANNEL : PopopxEcoActionResult()
  data object LOCKED : PopopxEcoActionResult()
  data object EXPIRED : PopopxEcoActionResult()
  data object IGNORED : PopopxEcoActionResult()

  /** A card button that wants a pairwise identity this device does not have: the service never introduced itself. */
  data object NO_SESSION : PopopxEcoActionResult()

  data object SEND_FAILED : PopopxEcoActionResult()
}
