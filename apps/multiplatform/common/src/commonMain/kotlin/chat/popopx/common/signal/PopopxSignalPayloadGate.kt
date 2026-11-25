package chat.popopx.common.signal

// Ported from apps/ios/Shared/Features/BadgeCredits/PopopxSilentSignalingRouter.swift:196-379.
//
// The Swift router `handle` interleaves two jobs: frame routing (this package) and payload
// business — signature verification, voucher state, badge activation, the credits ledger (the
// commerce package). They are split here: the router decodes, gates and book-keeps, then asks
// [PopopxSignalPayloadGate] what the payload is worth, and executes whatever deletion the answer
// names. The commerce package satisfies this interface; until then the default refuses everything
// but still records it, so a bound build can be diffed against "nothing was ever wired".

/**
 * One inbound frame plus everything the per-kind handler needs to charge or attribute correctly:
 * `memberId` exists only on group messages and is how a group red-packet receipt is attributed to a
 * person (router:185-186, 208-210, citing `CIDirection.groupMemberId`); direct passes null.
 */
data class PopopxSignalInbound(
  val signal: PopopxSignal,
  val chatId: Long,
  val itemId: Long,
  val memberId: Long?,
  val chatKind: PopopxSignalChatKind,
  /**
   * THE PARSE INSTANT, and this is security-relevant, not an implementation detail.
   *
   * `CHANNEL_PAY_RCPT`'s `paidAtMs` is never carried on the wire: the Swift sender stamps
   * `Date()` onto its receipt object (router:620) and the wire encoder then DROPS the field —
   * `wireString` emits only `{channelId}:{credits}:{txHash}` (Models:1365-1367) — and the receiving
   * side's `parse` re-stamps `paidAtMs = now()` from its own clock (Models:1360). The "time paid"
   * a channel owner can show is therefore the time THIS device parsed the frame: no sender-side
   * claim about when it charged anything ever crosses the wire or gets recorded. Ported exactly as
   * measured: the stamped clock value is produced here, once, from the router's injectable clock,
   * and it is the only timestamp a payload handler may use for this kind.
   */
  val receivedAtMs: Long,
)

/** What the payload owner wants done with the row, spelled out so the deletion policy stays in the router. */
sealed class PopopxSignalDisposition {
  /**
   * Delete this device's row with INTERNAL after consuming. Covers the pure receipts
   * (router:211, :217, :225, :238), the refused REQ (router:263, :291), and the malformed
   * `NODE_CMD` (router:246-251: a malformed control signal is still deleted, because leaving it
   * on screen would be a bubble after all).
   */
  data object DeleteRow : PopopxSignalDisposition()

  /**
   * The giver answered the REQ with a grant. The router sends [ackSignal] through the transport and
   * deletes the REQ row ONLY if the ACK went out (router:272-280, :300-308). If the ACK could not
   * be sent the row stays: the voucher is already flipped, and silence beats a fake authorisation.
   */
  data class AnswerRequest(val ackSignal: PopopxSignal) : PopopxSignalDisposition()

  /**
   * The recipient applied a verified grant. `voucherId` must match this device's own initiation —
   * the router does that matching ([PopopxRedemptionOutcome.Failed] below can never settle somebody
   * else's entry), and only on a match does the outcome get recorded. When [outcome] is not a
   * failure the router then deletes the row and, for a one-time connection, drops the contact
   * (router:322-342, :357-378, in that order: file → credit → record → delete row → delete contact).
   */
  data class SettleAck(val voucherId: String, val outcome: PopopxRedemptionOutcome) : PopopxSignalDisposition()

  /**
   * Drop everything, delete nothing. This is the router's answer to an ACK that matches no
   * initiation (router header:35-37, :318-321, :353-356): "we do not clean up somebody else's
   * timeline" — deleting an unrelated person's row is itself a signal to the peer.
   */
  data object DropWithoutDeleting : PopopxSignalDisposition()
}

/** The seam the commerce package satisfies. One method, one answer per inbound frame. */
fun interface PopopxSignalPayloadGate {
  fun consume(inbound: PopopxSignalInbound): PopopxSignalDisposition
}

/**
 * The default gate while no payload consumer is bound: accept nothing, but record every frame it
 * refused so the wiring gap is visible in state, not only in a log nobody reads. The deletions it
 * still orders are deliberate — they are the ones iOS performs without consulting any signature
 * (the receipts are pure housekeeping), and they are what keeps an unbound build's control frames
 * out of bubbles.
 */
class PopopxSignalUnboundGate : PopopxSignalPayloadGate {
  private val history = ArrayDeque<PopopxSignalInbound>()

  /** Oldest dropped past [PopopxSignalLimits.MAXIMUM_UNBOUND_RECORDS], FIFO, same idiom as the eco stores. */
  val recorded: List<PopopxSignalInbound> get() = history.toList()

  override fun consume(inbound: PopopxSignalInbound): PopopxSignalDisposition {
    if (history.size >= PopopxSignalLimits.MAXIMUM_UNBOUND_RECORDS) history.removeFirst()
    history.addLast(inbound)
    return when {
      // An ACK cannot be verified here — the grant decode is commerce (router:314-316, :349-351:
      // undecodable answer, record the failure, touch no row). Without a verifier every ACK is
      // indistinguishable from somebody else's, which is the drop-without-deleting case.
      inbound.signal.kind.isAcknowledgement -> PopopxSignalDisposition.DropWithoutDeleting

      // Every other kind's row is deleted by iOS regardless of what the payload says it means.
      else -> PopopxSignalDisposition.DeleteRow
    }
  }
}
