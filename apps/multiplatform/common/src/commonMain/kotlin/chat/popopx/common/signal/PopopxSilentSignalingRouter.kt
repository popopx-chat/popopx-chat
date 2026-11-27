package chat.popopx.common.signal

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.popopx.common.commerce.PopopxCommerceSignalGate
import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings

// Ported from apps/ios/Shared/Features/BadgeCredits/PopopxSilentSignalingRouter.swift.
//
// The single entry and exit for invisible signalling. Invisibility is achieved by three layers
// (router header:6-21), and this package owns two of them: the after-landing deletion (transport
// INTERNAL delete) and the machine-line bookkeeping. Render suppression lives in the UI layer,
// which must consult `PopopxSysMarker.isSignalText` at the three sites the header names — the
// conversation row, the chat-list preview, and the notification banner (the banner needs its own
// gate because it fires synchronously before the delete, header:13).
//
// The third honest leftover, ported rather than polished away (header:17-21): INTERNAL delete only
// removes THIS device's copy — the peer keeps the message — and a side running a different client
// does not recognise `::popopx_sys::` and shows it as ordinary text. Fixing that is a host-protocol
// change, out of scope here.
//
// What is NOT ported into this class, by deliberate seam rather than omission:
// * grant encode/decode and signature verification (router:727-757) — commerce, reached through
//   [PopopxSignalPayloadGate];
// * redeem-code decode/mint (`PPX1-`/`PPXC1-`, router:416-455, :488-522) — commerce; the entry
//   points here ([startExternalRedeem], [startExternalCreditRedeem]) take what the decoded envelope
//   already holds, because a code that fails its signature check must never reach the transport;
// * the card human-lines (`PopopxCommerceCardText`, router:786-818) — commerce, passed in as text.

/** What the router did with one inbound frame, named at every decision point of router:188-253. */
sealed class PopopxInboundVerdict {
  /** Router:190 — notes, contact requests, channels-as-such carry no signalling at all. */
  data object NotAConversation : PopopxInboundVerdict()

  /** Router:191 — hostile or non-signalling text; every parse rejection names its own reason. */
  data class NotASignal(val reason: PopopxSignalParseResult.NotSignal) : PopopxInboundVerdict()

  /** Router:192 — a legal frame of a kind that has no business in a group, dropped before dispatch. */
  data class RefusedInGroup(val kind: PopopxSignalKind) : PopopxInboundVerdict()

  /** Router:318-321, :353-356 — an ACK with no matching initiation: dropped, and NOT deleted. */
  data class AckWithoutInitiation(val kind: PopopxSignalKind, val voucherId: String) : PopopxInboundVerdict()

  /** Router:244-251 family: the gate said "drop the whole thing", row included or not by its own rule. */
  data class Dropped(val kind: PopopxSignalKind) : PopopxInboundVerdict()

  data class Handled(
    val kind: PopopxSignalKind,
    val disposition: PopopxSignalDisposition,
    /** Whether the INTERNAL delete of this device's row was accepted by the host. */
    val rowDeleted: Boolean,
    /** Only set by [PopopxSignalDisposition.AnswerRequest]: whether the grant ACK went out. */
    val ackDelivered: Boolean? = null,
    /** Only set by [PopopxSignalDisposition.SettleAck]: whether the one-time contact was removed. */
    val contactDeleted: Boolean = false,
  ) : PopopxInboundVerdict()
}

class PopopxSilentSignalingRouter(
  private val transport: PopopxSilentTransport = PopopxSilentTransportAdapter(),
  private val payloadGate: PopopxSignalPayloadGate = PopopxSignalUnboundGate(),
  private val defaults: Settings = settings,
  private val nowMs: () -> Long = { System.currentTimeMillis() },
  /**
   * The publish right of router:581-583, which on iOS reads `ChatModel`. This layer must not, so
   * the app layer answers "is this device's member record really an ACTIVE admin or above in that
   * channel" by computing [PopopxSilentSignalGate.mayPublishChannelThreshold] over its own model.
   * Unbound means "nobody may publish", the refusing direction.
   */
  private val channelAdminAt: (groupId: Long) -> Boolean = { false },
) {
  /** The most recent redemption result, for the redemption panel to subscribe to (router:117-119). */
  var lastOutcome: PopopxRedemptionOutcome? = null
    private set

  /**
   * voucherId → that gift card's result, for the bubbles to subscribe to. Relying on [lastOutcome]
   * alone would cross wires: with one voucher in each of two chats, the later terminal state would
   * light up both cards at once (router:121-124). Not persisted, exactly as iOS.
   */
  var outcomesByVoucher: Map<String, PopopxRedemptionOutcome> by mutableStateOf(emptyMap())
    private set

  /** connId → the REQ waiting to be sent, persisted so a killed process can still run the flow (router:139-142). */
  private val pendingRequests = LinkedHashMap<Long, PopopxPendingRedeem>()

  /** contactId → the entry whose REQ went out and is waiting for its ACK; in memory only (router:143-145). */
  private val awaitingAcks = LinkedHashMap<Long, PopopxInflightRedeem>()

  /**
   * The voucher this device is waiting an ACK for in that chat, if any. Read by
   * [chat.popopx.common.commerce.PopopxCommerceSignalGate] BEFORE it spends a vault row: iOS matches the
   * initiation at router:318-321 before it records the grant, and the split between router and gate here would
   * otherwise let a third party's ACK flip this device's voucher before the router got to say it was nobody's.
   */
  fun awaitingVoucherId(chatId: Long): String? = awaitingAcks[chatId]?.voucherId

  private val pendingStore = PopopxSignalPendingStore(defaults)
  private var loaded = false

  fun loadIfNeeded() {
    if (loaded) return
    loaded = true
    pendingRequests.clear()
    pendingRequests.putAll(pendingStore.load())
  }

  private fun savePendingRequests() = pendingStore.save(pendingRequests.toMap())

  /** Router:126-137. Both copies must be written in the same pass, or the panel and the card tell different stories. */
  private fun record(outcome: PopopxRedemptionOutcome, voucherId: String?) {
    lastOutcome = outcome
    if (voucherId == null) return
    // The ceiling exists only to stop unbounded growth. Anything still waiting for an ACK must
    // NEVER be cleared — those are the only entries that can still change. The filtered map is
    // then re-grown by the insert below, which is also how iOS behaves once the ceiling bites.
    if (outcomesByVoucher.size >= PopopxSignalLimits.MAXIMUM_OUTCOME_HISTORY) {
      val inflight = awaitingAcks.values.mapTo(HashSet()) { it.voucherId }
      outcomesByVoucher = outcomesByVoucher.filterKeys { it in inflight }
    }
    outcomesByVoucher = outcomesByVoucher + (voucherId to outcome)
  }

  // MARK: Mount point 1 · the recipient's connection is established (router:164-180)

  /**
   * Called from the app layer's `contactConnected` event for a connection this device may have a
   * pending REQ on. The event is precisely the signal that "the other side has already accepted":
   * before it, this side only has a PendingContactConnection that cannot carry a message
   * (router header:23-28), which is why the REQ hangs here and not at [startExternalRedeem].
   */
  suspend fun contactConnected(connectionId: Long, contactId: Long) {
    loadIfNeeded()
    val pending = pendingRequests.remove(connectionId) ?: return
    savePendingRequests()
    awaitingAcks[contactId] = PopopxInflightRedeem(pending.voucherId, deletesContactAfterAck = true)
    // The stored wire is replayed byte-for-byte and never re-assembled (router:762-767): these two
    // must be identical, and the voucher digest the giver checks is a digest of THIS string.
    val delivered = transport.send(
      contactId,
      isGroup = false,
      pending.signalWire,
      live = PopopxSignalLimits.SIGNAL_IS_NEVER_LIVE,
      ttlSeconds = PopopxSignalLimits.DEFAULT_TTL_SECONDS,
    )
    if (!delivered) {
      awaitingAcks.remove(contactId)
      val outcome = PopopxRedemptionOutcome.Failed(PopopxSignalFailure.CONNECTION_UNAVAILABLE)
      record(outcome, pending.voucherId)
    }
  }

  // MARK: Mount point 2 · a message arrived (router:182-253)

  /**
   * The inbound pipeline: gate, then dispatch, then delete. Never throws on any input — every
   * hostile shape ends as a named verdict, and the payload gate is a consumer of already-parsed
   * text, not another parser. `memberId` only exists on group messages (router:188-189).
   */
  suspend fun observeIncoming(
    chatKind: PopopxSignalChatKind,
    chatId: Long,
    itemId: Long,
    text: String,
    memberId: Long? = null,
  ): PopopxInboundVerdict {
    val signal = when (val decision = PopopxSilentSignalGate.allowReceive(chatKind, text)) {
      is PopopxReceiveDecision.Allowed -> decision.signal
      PopopxReceiveDecision.NotAConversation -> return PopopxInboundVerdict.NotAConversation
      is PopopxReceiveDecision.RefusedInGroup -> return PopopxInboundVerdict.RefusedInGroup(decision.kind)
      is PopopxReceiveDecision.NotASignal -> return PopopxInboundVerdict.NotASignal(decision.reason)
    }
    // The parse instant is taken here, once, before any consumer sees the frame — see
    // [PopopxSignalInbound.receivedAtMs] for why that is the receipt's only timestamp.
    val inbound = PopopxSignalInbound(signal, chatId, itemId, memberId, chatKind, nowMs())
    return when (val disposition = payloadGate.consume(inbound)) {
      is PopopxSignalDisposition.DeleteRow ->
        PopopxInboundVerdict.Handled(signal.kind, disposition, rowDeleted = deleteRow(chatId, itemId))

      is PopopxSignalDisposition.AnswerRequest -> {
        // A REQ that reached here from a group was already refused by the receive gate, so this
        // answer always goes back to the direct chat (router:272-274, :300-302). The REQ row is
        // deleted only when the ACK went out: if it did not, the request stays visible to nobody
        // but its sender, and the voucher's state is the payload owner's to unwind.
        val ackDelivered = sendSignal(disposition.ackSignal, PopopxSignalTarget.Contact(chatId))
        PopopxInboundVerdict.Handled(
          signal.kind, disposition,
          rowDeleted = ackDelivered && deleteRow(chatId, itemId),
          ackDelivered = ackDelivered,
        )
      }

      is PopopxSignalDisposition.SettleAck -> {
        val inflight = awaitingAcks[chatId]
        if (inflight == null || inflight.voucherId != disposition.voucherId) {
          // Router:318-321: the whole thing is dropped and not even deleted — we do not clean up
          // somebody else's timeline. The entry that DOES exist stays untouched for its real ACK.
          return PopopxInboundVerdict.AckWithoutInitiation(signal.kind, disposition.voucherId)
        }
        awaitingAcks.remove(chatId)
        record(disposition.outcome, disposition.voucherId)
        if (disposition.outcome is PopopxRedemptionOutcome.Failed) {
          // Router:323-326, :333-336, :370-373: a failed settle returns before any deletion.
          return PopopxInboundVerdict.Handled(signal.kind, disposition, rowDeleted = false)
        }
        // Order ported as measured (router:337-342, :375-378): delete the row, THEN drop the
        // one-time contact, and never notify — the peer already has the ACK, and "so-and-so
        // deleted you" would write this transaction back into both timelines.
        val rowDeleted = deleteRow(chatId, itemId)
        val contactDeleted = if (inflight.deletesContactAfterAck) {
          transport.deleteContact(chatId, notifyPeer = false)
        } else {
          false
        }
        PopopxInboundVerdict.Handled(
          signal.kind, disposition,
          rowDeleted = rowDeleted,
          contactDeleted = contactDeleted,
        )
      }

      is PopopxSignalDisposition.DropWithoutDeleting -> PopopxInboundVerdict.Dropped(signal.kind)
    }
  }

  // MARK: Outbound · the redemption legs (router:381-522)

  /**
   * A one-time redemption through a `PPX1-…` code, once the commerce package has decoded and
   * signature-checked the envelope (the two guards at router:389-390 belong to the caller; nothing
   * reaches this method that already failed them). The connection is made `incognito = true`
   * (router:392) and the REQ is stored under the new connection id, awaiting `contactConnected`.
   */
  suspend fun startExternalRedeem(voucherId: String, inviteLink: String): PopopxRedemptionOutcome =
    startExternalLeg(voucherId, inviteLink, PopopxSignalKind.EXTERNAL_REDEEM_REQ)

  /** The `CREDIT_EXT_REDEEM_REQ` mirror (router:459-474). The two code families never cross. */
  suspend fun startExternalCreditRedeem(voucherId: String, inviteLink: String): PopopxRedemptionOutcome =
    startExternalLeg(voucherId, inviteLink, PopopxSignalKind.CREDIT_EXT_REDEEM_REQ)

  private suspend fun startExternalLeg(
    voucherId: String,
    inviteLink: String,
    kind: PopopxSignalKind,
  ): PopopxRedemptionOutcome {
    loadIfNeeded()
    val connectionId = transport.connect(incognito = true, connFullLink = inviteLink)
      ?: return failed(PopopxSignalFailure.CONNECTION_UNAVAILABLE)
    pendingRequests[connectionId] = PopopxPendingRedeem(voucherId, PopopxSysMarker.wireString(kind, voucherId))
    savePendingRequests()
    record(PopopxRedemptionOutcome.Initiated, voucherId)
    return PopopxRedemptionOutcome.Initiated
  }

  /**
   * An in-conversation gift card (router:405-414): the contact already exists, the REQ goes
   * straight out, and after the ACK arrives the contact is NOT deleted — that is the friend itself.
   * Returning `Initiated` is not a successful redemption; the terminal state arrives with the ACK.
   */
  suspend fun redeemInChat(voucherId: String, contactId: Long): PopopxRedemptionOutcome =
    redeemInChatLeg(voucherId, contactId, PopopxSignalKind.CHAT_REDEEM_REQ)

  /** The `CREDIT_CHAT_REDEEM_REQ` mirror (router:477-486). */
  suspend fun redeemCreditInChat(voucherId: String, contactId: Long): PopopxRedemptionOutcome =
    redeemInChatLeg(voucherId, contactId, PopopxSignalKind.CREDIT_CHAT_REDEEM_REQ)

  private suspend fun redeemInChatLeg(voucherId: String, contactId: Long, kind: PopopxSignalKind): PopopxRedemptionOutcome {
    val target = PopopxSignalTarget.Contact(contactId)
    if (!sendSignal(PopopxSignal(kind, voucherId), target)) {
      return failed(PopopxSignalFailure.CONNECTION_UNAVAILABLE)
    }
    awaitingAcks[contactId] = PopopxInflightRedeem(voucherId, deletesContactAfterAck = false)
    record(PopopxRedemptionOutcome.Initiated, voucherId)
    return PopopxRedemptionOutcome.Initiated
  }

  /**
   * Opens the fresh one-time connection a code mint needs (router:419-426, :492-495). Every mint
   * calls this: a link can only be accepted once, and reusing one opens the double-spend window
   * the vault's serial check exists to close. The envelope, signature and code text built on the
   * returned link are the commerce package's.
   */
  suspend fun createEphemeralInvite(): PopopxSignalInvite? = transport.addContact(incognito = true)

  // MARK: Outbound · the receipt and node legs (router:544-652)

  /**
   * The receipt sent back after claiming a red packet (router:552-557). It follows the CARD, not
   * "the sender as a person", so it takes the same landing point as the packet itself — and this is
   * one of the three kinds a group may carry.
   */
  suspend fun sendRedPacketReceipt(packetId: String, target: PopopxSignalTarget): Boolean =
    sendSignal(PopopxSignal(PopopxSignalKind.REDPACKET_CLAIMED, packetId), target)

  /**
   * The profile unlock receipt (router:565-572). The payload carries ONLY the profile id: "who
   * opened it" comes from the connection itself and "how much was paid" only means something in
   * the paying device's ledger, so not one extra character is carried (router:559-561).
   * [contactId] must be a 1:1 chat contact — a group row number used as a contact id would send the
   * receipt to a completely unrelated person (router:563-564).
   */
  suspend fun sendProfileUnlockReceipt(profileId: String, contactId: Long): Boolean =
    sendSignal(
      PopopxSignal(PopopxSignalKind.PROFILE_UNLOCKED, profileId),
      PopopxSignalTarget.Contact(contactId),
    )

  /**
   * The member's subscription receipt (router:603-615). Payload `{chatInfoId}::{expiresAtMs}`,
   * joined here and split by the consumer on the LAST `::` pair (Models:1101-1103).
   * Best effort by ruling (router:599-602): the ticket is already written when this is called, and
   * a receipt that cannot be sent never rolls back that deduction and never errors at the user.
   */
  suspend fun sendChannelSubscriptionAck(chatInfoId: String, expiresAtMs: Long, target: PopopxSignalTarget): Boolean =
    sendSignal(PopopxSignal(PopopxSignalKind.CHANNEL_SUB_ACK, "$chatInfoId::$expiresAtMs"), target)

  /**
   * The payment receipt member → channel owner (router:619-632). Wire format
   * `{channelId}:{credits}:{txHash}` (Models:1365-1367), and note what is NOT here: the sender's
   * `paidAtMs` is dropped by the encoder (router:620 vs Models:1360, see
   * [PopopxSignalInbound.receivedAtMs]). The txHash is the owner's replay key — enforced in the
   * owner's ledger by the commerce package, not on this wire.
   */
  suspend fun sendChannelPaymentReceipt(channelId: Long, credits: Int, txHash: String, target: PopopxSignalTarget): Boolean =
    sendSignal(PopopxSignal(PopopxSignalKind.CHANNEL_PAY_RCPT, "$channelId:$credits:$txHash"), target)

  /**
   * Sends one Mac node command whose payload already carries the host's three-part shape
   * `{serviceId}::{action}::{payload}` (router:643-652). This is the ONLY way a `NODE_CMD` leaves:
   * routing around it puts a second outbound path in the app, which is the path by which a control
   * signal ends up visible in a bubble (router:636-639). The Bool means "accepted by SMP", never
   * "done on the Mac" (router:641-642).
   */
  suspend fun sendNodeCommand(commandPayload: String, contactId: Long): Boolean =
    sendSignal(
      PopopxSignal(PopopxSignalKind.NODE_CMD, commandPayload),
      PopopxSignalTarget.Contact(contactId),
    )

  /**
   * Verbatim delivery of a command string the NODE authored, for the one payload class this app may not
   * rebuild: the `::popopx_sys::NODE_CMD::updates::approve::{"rcp":…}` / `…snooze::…` receipts inside an
   * `::POPOPX_UPD::v1` card. `sendNodeCommand` above takes the three-part payload and writes the marker
   * itself; feeding it an already-complete wire string would produce a doubled marker, and the host's parser
   * would read serviceId `""` and drop it.
   *
   * The receipt is single-use and minted node-side (`UpdateCenter.swift:219-228`: an HMAC this device cannot
   * compute), so byte-for-byte echo is the whole requirement — hence this method takes a `String` and not a
   * model. Same non-live, no-TTL shape as every other control frame; the row is left visible-invisible by the
   * same `isSignalText` whole-string gate that hid it inbound, so no deletion is issued here.
   */
  suspend fun sendNodeText(text: String, contactId: Long): Boolean =
    transport.send(
      contactId,
      isGroup = false,
      text,
      live = PopopxSignalLimits.SIGNAL_IS_NEVER_LIVE,
    )

  /**
   * The bond-time pairing probe.
   *
   * DIVERGENCE, ported as measured rather than as documented (task item 6): the requirement names
   * `NODE_CMD::system::pair_ack`, but the host's own parser rejects any serviceId that is not one
   * of its ten engines (`NodeWire.parseCommand`, MacNodeModels.swift:127-128, recorded at
   * DiscoverCatalogModels.swift:30-33), so `system` could never be acknowledged. What iOS actually
   * emits is a real, engine-known, model-free command — `edge_compute_mesh::status`, routed to
   * `meshStatusResult(commandID:)`, which takes no payload
   * (DiscoverSubscriptionManager.swift:502-514, host TenBusinessEngines.swift:2253-2254).
   * The `{"probe":"pairing"}` body survives because it is the requirement's own fingerprint, not
   * because the engine reads it.
   */
  suspend fun sendPairingProbe(contactId: Long): Boolean =
    sendNodeCommand("edge_compute_mesh::status::{\"probe\":\"pairing\"}", contactId)

  /**
   * The channel owner's threshold card (router:589-595). Two rules, both ported:
   * 1. the landing point is ONLY the group/channel branch, and only when [channelAdminAt] says this
   *    device's member record really is an active admin — the interface and the exit share that
   *    one criterion (router:574-583);
   * 2. whatever goes out here is NEVER deleted or hidden: it is the members' only source of the
   *    price list, and hiding it means making members pay for a number they cannot see
   *    (router:585-588). [cardText] is the human line + machine line built by the commerce package.
   */
  suspend fun sendChannelThreshold(cardText: String, groupId: Long): Boolean {
    val target = PopopxSignalTarget.Group(groupId)
    if (!channelAdminAt(groupId)) return false
    return transport.send(
      target.chatId,
      isGroup = true,
      cardText,
      live = PopopxSignalLimits.SIGNAL_IS_NEVER_LIVE,
      ttlSeconds = PopopxSignalLimits.DEFAULT_TTL_SECONDS,
    )
  }

  // MARK: Send / delete primitives (router:654-721)

  /**
   * The one gate and the one exit for machine lines (router:660-688): group refusal first, then
   * `live = false` and the measured null TTL. "Chat not found" on iOS (router:666-669) is now the
   * transport's `false` — a bound adapter resolves the chat and says whether the host accepted.
   * Internal so the group refusal is testable for every kind, not only the ones a public builder
   * happens to take a target for.
   */
  internal suspend fun sendSignal(signal: PopopxSignal, target: PopopxSignalTarget): Boolean {
    if (PopopxSilentSignalGate.allowSend(signal.kind, target) is PopopxSendDecision.Refused) return false
    return transport.send(
      target.chatId,
      target.isGroup,
      PopopxSysMarker.wireString(signal),
      live = PopopxSignalLimits.SIGNAL_IS_NEVER_LIVE,
      ttlSeconds = PopopxSignalLimits.DEFAULT_TTL_SECONDS,
    )
  }

  /** INTERNAL and nothing else (router:694-721); a failed delete leaves the row suppressed but present. */
  private suspend fun deleteRow(chatId: Long, itemId: Long): Boolean =
    transport.delete(chatId, listOf(itemId), PopopxSilentDeleteMode.INTERNAL)

  private fun failed(reason: PopopxSignalFailure): PopopxRedemptionOutcome =
    PopopxRedemptionOutcome.Failed(reason)

  companion object {
    /**
     * The bound, application-wide router. It is ONE instance because the state below is wrong twice over if
     * there are two: [awaitingAcks] is what an ACK is matched against, so a second router would let a card's
     * own redemption be answered by an instance that never asked, and [outcomesByVoucher] is what the cards
     * read their terminal line from.
     *
     * `PopopxEcoRuntime.signaling` delegates here rather than constructing its own, so the inbound mount and
     * the card UI cannot end up on different routers.
     */
    val shared: PopopxSilentSignalingRouter by lazy {
      PopopxSilentSignalingRouter(
        transport = PopopxSilentHostTransport(),
        // The lambda resolves `shared` when an ACK arrives, not while this initializer runs.
        payloadGate = PopopxCommerceSignalGate(awaitingVoucherId = { chatId -> shared.awaitingVoucherId(chatId) }),
        channelAdminAt = { groupId -> PopopxSilentSignalHost.channelAdminAt(groupId) },
      )
    }
  }
}
