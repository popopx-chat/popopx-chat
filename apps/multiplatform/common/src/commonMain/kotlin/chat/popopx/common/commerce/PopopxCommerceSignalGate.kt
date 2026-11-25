package chat.popopx.common.commerce

import chat.popopx.common.discover.PopopxNodeCommand
import chat.popopx.common.discover.PopopxSubscriptionEngine
import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.base64UrlEncode
import chat.popopx.common.signal.PopopxRedemptionOutcome
import chat.popopx.common.signal.PopopxSignal
import chat.popopx.common.signal.PopopxSignalDisposition
import chat.popopx.common.signal.PopopxSignalInbound
import chat.popopx.common.signal.PopopxSignalKind
import chat.popopx.common.signal.PopopxSignalFailure
import chat.popopx.common.signal.PopopxSignalPayloadGate
import chat.popopx.common.signal.PopopxSysMarker
import kotlinx.serialization.json.Json

// The payload half of the inbound signalling pipeline: iOS interleaves it with frame routing inside
// `PopopxSilentSignalingRouter.handle` (PopopxSilentSignalingRouter.swift:196-379), and this port split the two
// at [PopopxSignalPayloadGate]. Everything below is the business side of that function — what a frame is worth,
// which vault row it flips, which ledger entry it credits, and what answer (if any) goes back.
//
// Two ordering facts carried over verbatim from iOS, because they are the ones that stop a stranger's frame from
// spending this device's money:
//
//  * A redemption ACK is matched against this device's OWN initiation BEFORE the vault is touched
//    (router:318-321, :353-356). The router does its own match afterwards, but by then a consume would already
//    have flipped the voucher, so the check is done here too and [awaitingVoucherId] is what makes it possible.
//  * A giver never signs for a voucher that is not its own or is already spent (router:261-265, :289-293): the
//    refusal answers nothing at all, which is also why the REQ row is still deleted (nothing leaks, and the row
//    is a machine line either way).

private val json = Json { ignoreUnknownKeys = false }

/**
 * `encoded(_:)` / `decodedGrant(_:)` / `encodedCreditGrant(_:)` / `decodedCreditGrant(_:)`
 * (router:723-757). The ceiling is checked BEFORE decoding on both sides, so an over-long frame never reaches
 * the JSON parser, and a decoded grant is signature-checked against the giver's key before anything is credited.
 * The two grant types have disjoint key sets, so feeding a badge ACK to the credit decoder answers null rather
 * than guessing a family from what failed.
 */
object PopopxCommerceGrants {
  fun encodeBadge(grant: PopopxBadgeGrant): String? {
    val text = json.encodeToString(PopopxBadgeGrant.serializer(), grant)
    val bytes = text.encodeToByteArray()
    if (bytes.size > PopopxCommerceLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS) return null
    return base64UrlEncode(bytes)
  }

  fun decodeBadge(payload: String): PopopxBadgeGrant? {
    if (payload.length > PopopxCommerceLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS) return null
    val bytes = base64UrlDecode(payload) ?: return null
    val grant = runCatching { json.decodeFromString(PopopxBadgeGrant.serializer(), bytes.decodeToString()) }.getOrNull()
      ?: return null
    return if (grant.isSignatureValid) grant else null
  }

  fun encodeCredit(grant: PopopxCreditsGrant): String? {
    val text = json.encodeToString(PopopxCreditsGrant.serializer(), grant)
    val bytes = text.encodeToByteArray()
    if (bytes.size > PopopxCommerceLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS) return null
    return base64UrlEncode(bytes)
  }

  fun decodeCredit(payload: String): PopopxCreditsGrant? {
    if (payload.length > PopopxCommerceLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS) return null
    val bytes = base64UrlDecode(payload) ?: return null
    val grant = runCatching { json.decodeFromString(PopopxCreditsGrant.serializer(), bytes.decodeToString()) }.getOrNull()
      ?: return null
    return if (grant.isSignatureValid) grant else null
  }
}

class PopopxCommerceSignalGate(
  private val vault: PopopxP2PVoucherVault = PopopxP2PVoucherVault.shared,
  private val credits: PopopxCreditsManager = PopopxCreditsManager.shared,
  private val engine: PopopxSubscriptionEngine = PopopxSubscriptionEngine.shared,
  /** This device's in-flight voucher for that chat, or null when it never asked. Supplied by the router. */
  private val awaitingVoucherId: (chatId: Long) -> String? = { null },
) : PopopxSignalPayloadGate {

  override fun consume(inbound: PopopxSignalInbound): PopopxSignalDisposition {
    val payload = inbound.signal.payload
    return when (inbound.signal.kind) {
      PopopxSignalKind.EXTERNAL_REDEEM_REQ, PopopxSignalKind.CHAT_REDEEM_REQ -> answerBadgeRequest(inbound)
      PopopxSignalKind.CREDIT_EXT_REDEEM_REQ, PopopxSignalKind.CREDIT_CHAT_REDEEM_REQ -> answerCreditRequest(inbound)
      PopopxSignalKind.EXTERNAL_REDEEM_ACK, PopopxSignalKind.CHAT_REDEEM_ACK -> applyBadgeAck(inbound)
      PopopxSignalKind.CREDIT_EXT_REDEEM_ACK, PopopxSignalKind.CREDIT_CHAT_REDEEM_ACK -> applyCreditAck(inbound)
      PopopxSignalKind.REDPACKET_CLAIMED -> {
        // `memberId` exists only on group messages and is the share's attribution key; in a direct chat the
        // claimer's own ledger already refuses the same packetId twice, so null is the honest input here.
        credits.recordClaim(payload, inbound.memberId?.toString())
        PopopxSignalDisposition.DeleteRow
      }

      PopopxSignalKind.PROFILE_UNLOCKED -> {
        // Exactly one thing: the row must not become a bubble. No book is kept and no prompt is shown, because
        // "who opened your profile, when" stops being silent the moment it is a record to look back at.
        PopopxSignalDisposition.DeleteRow
      }

      PopopxSignalKind.CHANNEL_SUB_ACK -> {
        // No book is possible, not merely inadvisable: `chatInfoId` in the payload is the SENDING device's local
        // row number, and a channel message carries no member object, so "who redeemed it" cannot be resolved
        // at this layer at all (router:218-225).
        PopopxSignalDisposition.DeleteRow
      }

      PopopxSignalKind.CHANNEL_PAY_RCPT -> {
        // The txHash is the replay key; a malformed receipt is still deleted, and `receivedAtMs` is the only
        // allowed paidAtMs because the wire never carries one.
        val receipt = PopopxChannelPaymentReceipt.parse(payload, inbound.receivedAtMs)
        if (receipt != null) credits.receiveChannelPayment(receipt)
        PopopxSignalDisposition.DeleteRow
      }

      PopopxSignalKind.NODE_CMD -> {
        // The engine owns the reading (which service's transcript, whether it came from a bonded node); this
        // layer only guarantees the row never reaches a bubble, which is why the malformed case still deletes.
        val command = PopopxNodeCommand.parse(payload)
        if (command != null) engine.recordInboundCommand(command, inbound.receivedAtMs)
        PopopxSignalDisposition.DeleteRow
      }
    }
  }

  private fun answerBadgeRequest(inbound: PopopxSignalInbound): PopopxSignalDisposition {
    val grant = vault.authorizeRedemption(inbound.signal.payload, wireOf(inbound))
      ?: return PopopxSignalDisposition.DeleteRow
    val encoded = PopopxCommerceGrants.encodeBadge(grant)
      // The voucher is already flipped to redeemed by the call above. Encoding failure is a local-bug-level
      // state, and answering "success" would hand the other side an unsigned number, so this refuses and
      // leaves the REQ row alone: the giver can void the voucher from its own list.
      ?: return PopopxSignalDisposition.DropWithoutDeleting
    return PopopxSignalDisposition.AnswerRequest(PopopxSignal(PopopxSignalKind.EXTERNAL_REDEEM_ACK, encoded))
  }

  private fun answerCreditRequest(inbound: PopopxSignalInbound): PopopxSignalDisposition {
    val grant = vault.authorizeCreditRedemption(inbound.signal.payload, wireOf(inbound))
      ?: return PopopxSignalDisposition.DeleteRow
    val encoded = PopopxCommerceGrants.encodeCredit(grant)
      ?: return PopopxSignalDisposition.DropWithoutDeleting
    return PopopxSignalDisposition.AnswerRequest(PopopxSignal(PopopxSignalKind.CREDIT_EXT_REDEEM_ACK, encoded))
  }

  private fun applyBadgeAck(inbound: PopopxSignalInbound): PopopxSignalDisposition {
    val grant = PopopxCommerceGrants.decodeBadge(inbound.signal.payload)
      ?: return PopopxSignalDisposition.DropWithoutDeleting
    if (awaitingVoucherId(inbound.chatId) != grant.voucherId) return PopopxSignalDisposition.DropWithoutDeleting
    if (!vault.record(grant)) {
      return PopopxSignalDisposition.SettleAck(grant.voucherId, PopopxRedemptionOutcome.Failed(failedStore()))
    }
    // "This device has redeemed this voucher" is written BEFORE the terminal state, so a process killed in
    // between restarts showing a spent card rather than a button that can be tapped once more.
    credits.markRedeemed(grant.voucherId)
    return PopopxSignalDisposition.SettleAck(grant.voucherId, PopopxRedemptionOutcome.Completed(grant.voucherId))
  }

  private fun applyCreditAck(inbound: PopopxSignalInbound): PopopxSignalDisposition {
    val grant = PopopxCommerceGrants.decodeCredit(inbound.signal.payload)
      ?: return PopopxSignalDisposition.DropWithoutDeleting
    if (awaitingVoucherId(inbound.chatId) != grant.voucherId) return PopopxSignalDisposition.DropWithoutDeleting
    if (!vault.recordCredit(grant)) {
      return PopopxSignalDisposition.SettleAck(grant.voucherId, PopopxRedemptionOutcome.Failed(failedStore()))
    }
    val settled = try {
      // `false` is the replay guard doing its job, not a failure: the same signed voucher id was already
      // credited once, and the number cannot differ because a second signature would not verify.
      credits.creditGiftCard(grant)
      PopopxRedemptionOutcome.Completed(grant.voucherId)
    } catch (e: PopopxBadgeCreditsError) {
      PopopxRedemptionOutcome.Failed(failedOf(e))
    }
    return PopopxSignalDisposition.SettleAck(grant.voucherId, settled)
  }

  /**
   * `codeDigestSource` is the whole signalling line on iOS (`wire: text`). [PopopxSignalInbound] carries the
   * parsed frame rather than the raw text, so the line is rebuilt from the same marker and the same kind the
   * parser matched: [PopopxSysMarker] emits and accepts one spelling, so the rebuilt string is byte-equal to
   * what arrived, and the digest the giver records is the one its own code text hashes to.
   */
  private fun wireOf(inbound: PopopxSignalInbound): String =
    PopopxSysMarker.wireString(inbound.signal.kind, inbound.signal.payload)

  private fun failedOf(error: PopopxBadgeCreditsError): PopopxSignalFailure =
    if (error is PopopxBadgeCreditsError.KeychainUnavailable) PopopxSignalFailure.KEYCHAIN_UNAVAILABLE
    else PopopxSignalFailure.SIGNAL_REJECTED

  private fun failedStore(): PopopxSignalFailure = PopopxSignalFailure.KEYCHAIN_UNAVAILABLE
}
