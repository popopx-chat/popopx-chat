package chat.popopx.common.views.commerce

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.AlertDialog
import androidx.compose.material.Button
import androidx.compose.material.ButtonDefaults
import androidx.compose.material.Divider
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.material.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.commerce.PopopxChannelAccessPayload
import chat.popopx.common.commerce.PopopxCreditGiftPayload
import chat.popopx.common.commerce.PopopxCreditsManager
import chat.popopx.common.commerce.PopopxGiftCardPayload
import chat.popopx.common.commerce.PopopxRedPacketPayload
import chat.popopx.common.commerce.PopopxCommerceLimits
import chat.popopx.common.commerce.PopopxBadgeCreditsError
import chat.popopx.common.signal.PopopxRedemptionOutcome
import chat.popopx.common.signal.PopopxSignalFailure
import chat.popopx.common.signal.PopopxSignalTarget
import chat.popopx.common.signal.PopopxSilentSignalingRouter
import chat.popopx.res.*
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.launch
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime

// Ported from apps/ios/Shared/Features/BadgeCredits/PopopxCommerceCards.swift (all 680 lines read).
//
// The four cards keep iOS's one structural rule, the one this file exists for: **the first branch is the
// gate**. A card whose signature does not verify never builds a button at all — not a disabled button, not a
// button that refuses when tapped. Anything less would leave "tappable" meaning something other than "the
// thing the issuer signed".
//
// Three measured deviations, all in the same direction (Android shows less than iOS rather than more):
//
//  * iOS's terminal line comes from the ACK payload (`redeemed(period:)` / `redeemedCredits(amount:)`).
//    [PopopxRedemptionOutcome.Completed] carries only a voucher id, because this port's signaling layer refuses
//    to know what a voucher is worth. The number printed here therefore comes from the card's OWN payload —
//    which is the same number, since the signed grant was minted from it, and the vault row is what the ledger
//    spent. A voucher id belongs to exactly one family, so a badge card can never be told a credit number.
//  * iOS's `.failed(error)` glosses `PopopxBadgeCreditsError.errorDescription`. [PopopxSignalFailure] has three
//    named cases and no message text, so KEYCHAIN_UNAVAILABLE falls to the generic sentence; inventing a
//    fourth sentence here would be a second, untranslatable copy of the ledger's own wording.
//  * The subscribe confirmation is a plain two-button dialog, not iOS's `PopopxChannelSubscriptionSheet`:
//    the sheet explains the boundary items (one-way broadcast, local admission gate) and those sentences were
//    not ported with it. What it DOES reproduce is that nothing is deducted until the user confirms, and that
//    the receipt goes back to the publisher.
//
// One deliberate absence: the badge a redemption lights is written by `PopopxBadgeManager.activate(grant:)` on
// iOS, which has no Android counterpart (the badge display tier was not part of this port). The grant IS filed
// in the vault and the voucher IS marked redeemed, so a second tap cannot spend it twice; what is missing is
// the profile mark. Recorded in the commit body, not papered over here.

/** The conversation the card sits in, handed over complete by the mount (router:35-58). */
class PopopxCommerceCardContext(
  /** Null makes the gift card, the credit card and the packet read-only: their reply goes back into this chat. */
  val target: PopopxSignalTarget?,
  val incoming: Boolean,
  /** The threshold card signs its local credential against the conversation's own id (iOS: `chat.chatId`). */
  val chatId: String = "",
  val chatTitle: String = "",
  val isChannel: Boolean = false,
)

/** Which card a text line renders as. Order is iOS's `detect` order: packet, gift, credit gift, channel. */
sealed class PopopxCommerceContent {
  data class Gift(val payload: PopopxGiftCardPayload) : PopopxCommerceContent()
  data class CreditGift(val payload: PopopxCreditGiftPayload) : PopopxCommerceContent()
  data class Packet(val payload: PopopxRedPacketPayload) : PopopxCommerceContent()
  data class Channel(val payload: PopopxChannelAccessPayload) : PopopxCommerceContent()

  companion object {
    /**
     * At most one parse can succeed, because the four hosts are disjoint, so the order is not a correctness
     * claim (Swift:68-69) — it is kept identical anyway so that a future host that DOES overlap behaves the
     * same on both platforms.
     */
    fun detect(text: String?): PopopxCommerceContent? {
      if (text == null) return null
      PopopxRedPacketPayload.parse(text)?.let { return Packet(it) }
      PopopxGiftCardPayload.parse(text)?.let { return Gift(it) }
      PopopxCreditGiftPayload.parse(text)?.let { return CreditGift(it) }
      PopopxChannelAccessPayload.parse(text)?.let { return Channel(it) }
      return null
    }
  }
}

@Composable
fun PopopxCommerceCard(content: PopopxCommerceContent, context: PopopxCommerceCardContext) {
  when (content) {
    is PopopxCommerceContent.Gift -> PopopxGiftCardCard(content.payload, context)
    is PopopxCommerceContent.CreditGift -> PopopxCreditGiftCard(content.payload, context)
    is PopopxCommerceContent.Packet -> PopopxRedPacketCard(content.payload, context)
    is PopopxCommerceContent.Channel -> PopopxChannelAccessCard(content.payload, context)
  }
}

// MARK: - Gift card

@Composable
private fun PopopxGiftCardCard(payload: PopopxGiftCardPayload, context: PopopxCommerceCardContext) {
  val credits = PopopxCreditsManager.shared
  val router = PopopxSilentSignalingRouter.shared
  var opening by remember(payload.voucherId) { mutableStateOf(false) }
  // Only the "fails on the spot" kinds live here. Once the request is out, the terminal state comes from
  // `outcomesByVoucher`, and the two sources never cover each other up (Swift:179-181).
  var immediate by remember(payload.voucherId) { mutableStateOf<PopopxRedemptionOutcome?>(null) }
  LaunchedEffect(Unit) { credits.loadIfNeeded() }

  CommerceSurface {
    CommerceHeader(
      MR.images.ic_id_card,
      stringResource(MR.strings.commerce_badge_days_product, payload.period.days, stringResource(MR.strings.commerce_badge_product_name)),
      if (payload.note.isEmpty()) stringResource(MR.strings.commerce_gift_caption) else stringResource(MR.strings.commerce_note_format, payload.note),
      MaterialTheme.colors.primary,
    )
    Divider(Modifier.fillMaxWidth(), thickness = 1.dp, color = MaterialTheme.colors.onSurface.copy(alpha = 0.1f))
    val contactId = (context.target as? PopopxSignalTarget.Contact)?.chatId
    val outcome = immediate ?: router.outcomesByVoucher[payload.voucherId]
    when {
      !payload.isSignatureValid ->
        CommerceNote(MR.images.ic_error, stringResource(MR.strings.commerce_rejected), MaterialTheme.colors.error)
      credits.hasRedeemed(payload.voucherId) ->
        CommerceNote(MR.images.ic_check_circle_filled, stringResource(MR.strings.commerce_redeemed_here), MaterialTheme.colors.primary)
      !context.incoming ->
        CommerceNote(MR.images.ic_arrow_outward, stringResource(MR.strings.commerce_sent_by_you), MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
      context.target == null ->
        CommerceNote(MR.images.ic_visibility, stringResource(MR.strings.commerce_read_only), MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
      contactId == null ->
        // Gift-card ACKs are accounted by chatId, so a second person in the group would settle somebody
        // else's entry; the router refuses the leg at its own entry too (Swift:208-210).
        CommerceNote(MR.images.ic_group, stringResource(MR.strings.commerce_group_unsupported), MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
      outcome is PopopxRedemptionOutcome.Completed ->
        CommerceNote(
          MR.images.ic_check_circle_filled,
          stringResource(MR.strings.commerce_badge_redeemed_days, payload.period.days),
          MaterialTheme.colors.primary,
        )
      outcome is PopopxRedemptionOutcome.Failed ->
        CommerceNote(MR.images.ic_error, commerceGloss(outcome.reason, false), MaterialTheme.colors.error)
      else -> CommerceActionButton(
        label = if (opening) stringResource(MR.strings.commerce_sending) else stringResource(MR.strings.commerce_redeem),
        loading = opening,
      ) {
        opening = true
        immediate = null
        val result = router.redeemInChat(payload.voucherId, contactId)
        // `Initiated` is not a redemption: it only means the REQ went out, so the line stays a button.
        if (result !is PopopxRedemptionOutcome.Initiated) immediate = result
        opening = false
      }
    }
  }
}

// MARK: - Compute-credit gift card

@Composable
private fun PopopxCreditGiftCard(payload: PopopxCreditGiftPayload, context: PopopxCommerceCardContext) {
  val credits = PopopxCreditsManager.shared
  val router = PopopxSilentSignalingRouter.shared
  var opening by remember(payload.voucherId) { mutableStateOf(false) }
  var immediate by remember(payload.voucherId) { mutableStateOf<PopopxRedemptionOutcome?>(null) }
  LaunchedEffect(Unit) { credits.loadIfNeeded() }

  CommerceSurface {
    CommerceHeader(
      MR.images.ic_id_card,
      stringResource(MR.strings.commerce_credit_title),
      if (payload.note.isEmpty()) stringResource(MR.strings.commerce_credit_caption) else stringResource(MR.strings.commerce_note_format, payload.note),
      MaterialTheme.colors.primary,
    )
    CommerceAmount(payload.creditsAmount)
    Divider(Modifier.fillMaxWidth(), thickness = 1.dp, color = MaterialTheme.colors.onSurface.copy(alpha = 0.1f))
    val contactId = (context.target as? PopopxSignalTarget.Contact)?.chatId
    val outcome = immediate ?: router.outcomesByVoucher[payload.voucherId]
    when {
      !payload.isSignatureValid ->
        CommerceNote(MR.images.ic_error, stringResource(MR.strings.commerce_rejected), MaterialTheme.colors.error)
      credits.hasRedeemed(payload.voucherId) ->
        CommerceNote(MR.images.ic_check_circle_filled, stringResource(MR.strings.commerce_redeemed_here), MaterialTheme.colors.primary)
      !context.incoming ->
        CommerceNote(MR.images.ic_arrow_outward, stringResource(MR.strings.commerce_sent_by_you), MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
      context.target == null ->
        CommerceNote(MR.images.ic_visibility, stringResource(MR.strings.commerce_read_only), MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
      contactId == null ->
        CommerceNote(MR.images.ic_group, stringResource(MR.strings.commerce_credit_group_unsupported), MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
      outcome is PopopxRedemptionOutcome.Completed ->
        CommerceNote(
          MR.images.ic_check_circle_filled,
          stringResource(MR.strings.commerce_credit_redeemed_amount, payload.creditsAmount),
          MaterialTheme.colors.primary,
        )
      outcome is PopopxRedemptionOutcome.Failed ->
        CommerceNote(MR.images.ic_error, commerceGloss(outcome.reason, true), MaterialTheme.colors.error)
      else -> CommerceActionButton(
        label = if (opening) stringResource(MR.strings.commerce_sending) else stringResource(MR.strings.commerce_redeem),
        loading = opening,
      ) {
        opening = true
        immediate = null
        val result = router.redeemCreditInChat(payload.voucherId, contactId)
        if (result !is PopopxRedemptionOutcome.Initiated) immediate = result
        opening = false
      }
    }
  }
}

// MARK: - Red packet

@Composable
private fun PopopxRedPacketCard(payload: PopopxRedPacketPayload, context: PopopxCommerceCardContext) {
  val credits = PopopxCreditsManager.shared
  val router = PopopxSilentSignalingRouter.shared
  var opening by remember(payload.packetId) { mutableStateOf(false) }
  var opened by remember(payload.packetId) { mutableStateOf(false) }
  // Lives for the life of the process only, exactly as iOS says: "was the receipt delivered" has no locally
  // persistable criterion, so a restart stops prompting rather than pretending to know (Swift:23-26).
  var receiptStuck by remember(payload.packetId) { mutableStateOf(false) }
  LaunchedEffect(Unit) { credits.loadIfNeeded() }
  val scope = rememberCoroutineScope()

  CommerceSurface {
    CommerceHeader(
      MR.images.ic_redeem,
      stringResource(MR.strings.commerce_packet_title),
      if (payload.note.isEmpty()) stringResource(MR.strings.commerce_credit_caption) else stringResource(MR.strings.commerce_note_format, payload.note),
      MaterialTheme.colors.error,
    )
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
      Text(
        stringResource(MR.strings.commerce_credits_amount, payload.amount),
        fontSize = 20.sp,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colors.onSurface,
      )
      Text(
        if (payload.recipients > 1) stringResource(MR.strings.commerce_packet_split, payload.recipients)
        else stringResource(MR.strings.commerce_packet_single),
        fontSize = 12.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = 0.6f),
      )
    }
    Divider(Modifier.fillMaxWidth(), thickness = 1.dp, color = MaterialTheme.colors.onSurface.copy(alpha = 0.1f))
    val share = payload.amountPerRecipient
    val pending = credits.pendingPacket(payload.packetId)
    when {
      !payload.isSelfSignatureValid || !payload.isAmountAuthorized || share == null ->
        // An even split that is not even is a forgery, not a rounding case (Swift:412).
        CommerceNote(MR.images.ic_error, stringResource(MR.strings.commerce_rejected), MaterialTheme.colors.error)
      credits.hasClaimed(payload.packetId) || opened -> {
        CommerceNote(
          MR.images.ic_check_circle_filled,
          stringResource(MR.strings.commerce_packet_claimed, share),
          MaterialTheme.colors.primary,
        )
        if (receiptStuck) {
          TextButton(onClick = {
            scope.launch {
              val delivered = context.target?.let {
                router.sendRedPacketReceipt(payload.packetId, it)
              } == true
              receiptStuck = !delivered
            }
          }) {
            Text(stringResource(MR.strings.commerce_packet_resend_receipt), fontSize = 13.sp)
          }
        }
      }
      // The one you sent cannot be opened by you: sending already deducted the credits, so a tappable
      // "open" on this device's own timeline would charge once and pay a share to the same person.
      !context.incoming -> {
        val sent = pending
        if (sent != null) {
          CommerceNote(
            if (sent.isFullyClaimed) MR.images.ic_check_circle_filled else MR.images.ic_schedule,
            stringResource(MR.strings.commerce_packet_sent, sent.claimedCount, sent.recipientCount),
            MaterialTheme.colors.onSurface.copy(alpha = 0.6f),
          )
        } else {
          // Somebody else's packet id means nothing on this device: no share count is invented for it.
          CommerceNote(MR.images.ic_arrow_outward, stringResource(MR.strings.commerce_sent_by_you), MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
        }
      }
      context.target == null ->
        CommerceNote(MR.images.ic_visibility, stringResource(MR.strings.commerce_read_only), MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
      else -> CommerceActionButton(
        label = if (opening) stringResource(MR.strings.commerce_sending) else stringResource(MR.strings.commerce_packet_open),
        loading = opening,
      ) {
        opening = true
        // Credit first, then the receipt: the share belongs to the opener, and the receipt only decides how
        // much the sender is refunded — it must never decide whether this credit lands (Swift:467).
        val credited = try {
          credits.claimRedPacket(payload.packetId, share, payload.note)
        } catch (e: PopopxBadgeCreditsError) {
          false
        }
        if (credited) {
          opened = true
          val delivered = context.target?.let { router.sendRedPacketReceipt(payload.packetId, it) } == true
          receiptStuck = !delivered
        } else {
          // Blocked by the replay guard: show it as opened and do not send a second receipt.
          opened = true
        }
        opening = false
      }
    }
  }
}

// MARK: - Channel subscription threshold

@Composable
private fun PopopxChannelAccessCard(payload: PopopxChannelAccessPayload, context: PopopxCommerceCardContext) {
  val credits = PopopxCreditsManager.shared
  val router = PopopxSilentSignalingRouter.shared
  val scope = rememberCoroutineScope()
  var confirming by remember(context.chatId) { mutableStateOf(false) }
  var failed by remember(context.chatId) { mutableStateOf(false) }
  var refresh by remember(context.chatId) { mutableStateOf(0) }
  LaunchedEffect(Unit) { credits.loadIfNeeded() }

  CommerceSurface {
    CommerceHeader(
      if (context.incoming) MR.images.ic_lock_filled else MR.images.ic_lock_open_right,
      stringResource(MR.strings.commerce_channel_headline),
      stringResource(MR.strings.commerce_channel_caption, commerceDay(payload.publishedAtMs)),
      MaterialTheme.colors.primary,
    )
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
      Text(
        stringResource(MR.strings.commerce_credits_amount, payload.price),
        fontSize = 20.sp,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colors.onSurface,
      )
      Text(
        stringResource(MR.strings.commerce_channel_per_period, (PopopxCommerceLimits.CHANNEL_TICKET_SECONDS / 86_400).toInt()),
        fontSize = 12.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = 0.6f),
      )
    }
    Divider(Modifier.fillMaxWidth(), thickness = 1.dp, color = MaterialTheme.colors.onSurface.copy(alpha = 0.1f))
    // `refresh` is read so a settle that wrote a ticket repaints this row without any polling.
    val ticket = if (refresh >= 0) credits.validTicket(context.chatId) else null
    when {
      !payload.isPriceAuthorized ->
        CommerceNote(MR.images.ic_error, stringResource(MR.strings.commerce_channel_price_rejected), MaterialTheme.colors.error)
      !payload.isIssuerSignatureValid ->
        CommerceNote(MR.images.ic_error, stringResource(MR.strings.commerce_channel_rejected), MaterialTheme.colors.error)
      // The publisher's own copy: this branch neither deducts nor has a ticket to look at.
      !context.incoming ->
        CommerceNote(MR.images.ic_arrow_outward, stringResource(MR.strings.commerce_channel_published), MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
      // An empty conversation id would sign a credential keyed on "": one deduction would then read as
      // subscribed in every channel. Read-only is the honest answer (Swift:568-571).
      context.chatId.isEmpty() ->
        CommerceNote(MR.images.ic_visibility, stringResource(MR.strings.commerce_channel_read_only), MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
      // This guard MUST stay above the deduction: a forged `popopx://channel` pasted into a direct chat
      // would otherwise spend credits right there (Swift:572-575).
      !context.isChannel ->
        CommerceNote(MR.images.ic_error, stringResource(MR.strings.commerce_channel_not_a_channel), MaterialTheme.colors.error)
      credits.channelIssuerConflict(context.chatId, payload.issuerPublicKeyBase64URL) ->
        CommerceNote(MR.images.ic_error, stringResource(MR.strings.commerce_channel_issuer_mismatch), MaterialTheme.colors.error)
      failed ->
        CommerceNote(MR.images.ic_error, stringResource(MR.strings.commerce_gloss_generic), MaterialTheme.colors.error)
      ticket != null -> {
        CommerceNote(
          MR.images.ic_check_circle_filled,
          stringResource(MR.strings.commerce_channel_active_until, commerceDay(ticket.expiresAtMs)),
          MaterialTheme.colors.primary,
        )
        CommerceActionButton(stringResource(MR.strings.commerce_channel_renew), loading = false) { confirming = true }
      }
      else -> CommerceActionButton(stringResource(MR.strings.commerce_channel_subscribe), loading = false, primary = true) { confirming = true }
    }
  }

  if (confirming) {
    AlertDialog(
      onDismissRequest = { confirming = false },
      title = { Text(stringResource(MR.strings.commerce_channel_subscribe)) },
      text = {
        Text(
          stringResource(MR.strings.commerce_credits_amount, payload.price) +
            " " + stringResource(MR.strings.commerce_channel_per_period, (PopopxCommerceLimits.CHANNEL_TICKET_SECONDS / 86_400).toInt())
        )
      },
      confirmButton = {
        // Read in composition, used in the coroutine: `stringResource` is a composable call, and the ledger's
        // note is written once into the entry and never re-read, so capturing it here is what iOS's sheet does.
        val subscribeNote = stringResource(MR.strings.commerce_channel_headline)
        TextButton(onClick = {
          confirming = false
          scope.launch {
            val settled = try {
              val ticket = credits.subscribeToChannel(
                channelId = context.chatId,
                channelTitle = context.chatTitle,
                price = payload.price,
                issuerPublicKeyBase64URL = payload.issuerPublicKeyBase64URL,
                note = subscribeNote,
              )
              // The publisher gets the paid receipt; a missing target means nobody to tell, which is not a
              // reason to hold back the local ticket.
              val groupId = (context.target as? PopopxSignalTarget.Group)?.chatId
              if (groupId != null) {
                router.sendChannelPaymentReceipt(
                  channelId = groupId,
                  credits = payload.price,
                  txHash = ticket.transactionId,
                  target = context.target,
                )
              }
              true
            } catch (e: PopopxBadgeCreditsError) {
              false
            }
            failed = !settled
            refresh += 1
          }
        }) { Text(stringResource(MR.strings.confirm_verb)) }
      },
      dismissButton = {
        TextButton(onClick = { confirming = false }) { Text(stringResource(MR.strings.cancel_verb)) }
      },
    )
  }
}

// MARK: - Shared surface

/**
 * The cards bring their own surface and do not take the bubble's ink (Swift:102-120): "something you can tap"
 * has to read differently from the plain text around it, which is why it carries its own fill and a hairline
 * stroke instead of swapping text colour with the sent/received side.
 */
@Composable
private fun CommerceSurface(content: @Composable ColumnScope.() -> Unit) {
  val shape = RoundedCornerShape(10.dp)
  Column(
    Modifier
      .fillMaxWidth()
      .clip(shape)
      .background(MaterialTheme.colors.surface)
      .border(1.dp, MaterialTheme.colors.onSurface.copy(alpha = 0.12f), shape)
      .padding(12.dp),
    verticalArrangement = Arrangement.spacedBy(8.dp),
    content = content,
  )
}

@Composable
private fun CommerceHeader(icon: ImageResource, title: String, caption: String, ink: Color) {
  Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    Icon(painterResource(icon), null, Modifier.size(18.dp), tint = ink)
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
      Text(title, style = MaterialTheme.typography.body1, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colors.onSurface)
      Text(caption, fontSize = 12.sp, color = MaterialTheme.colors.onSurface.copy(alpha = 0.6f))
    }
  }
}

/** The refused/settled line: one icon and one sentence, never a red block — "expired" is an ordinary state. */
@Composable
private fun CommerceNote(icon: ImageResource, text: String, ink: Color) {
  Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
    Icon(painterResource(icon), null, Modifier.size(14.dp), tint = ink)
    Text(text, fontSize = 12.sp, color = ink, modifier = Modifier.weight(1f))
  }
}

@Composable
private fun CommerceAmount(amount: Int) {
  Text(
    stringResource(MR.strings.commerce_credits_amount, amount),
    fontSize = 20.sp,
    fontWeight = FontWeight.SemiBold,
    color = MaterialTheme.colors.onSurface,
  )
}

/**
 * The card's only action row. [onTap] is suspend because the router call it makes is: the host FFI hop must not
 * run on the composition thread, and the button must not report "sent" from a thread that never waited for it.
 * [loading] disables the button rather than hiding it, so the row cannot jump while the REQ is in flight.
 */
@Composable
private fun CommerceActionButton(label: String, loading: Boolean, primary: Boolean = false, onTap: suspend () -> Unit) {
  val scope = rememberCoroutineScope()
  Button(
    onClick = { if (!loading) scope.launch { onTap() } },
    enabled = !loading,
    colors = ButtonDefaults.buttonColors(
      backgroundColor = if (primary) MaterialTheme.colors.primary else MaterialTheme.colors.surface,
      contentColor = if (primary) MaterialTheme.colors.onPrimary else MaterialTheme.colors.onSurface,
    ),
    modifier = Modifier.fillMaxWidth(),
  ) {
    Text(label, fontSize = 14.sp, modifier = Modifier.padding(vertical = 4.dp))
  }
}

/** The ACK glosses, from iOS's `gloss(_:)` tables; credit cards get their own unavailable sentence. */
@Composable
private fun commerceGloss(reason: PopopxSignalFailure, credit: Boolean): String = when (reason) {
  PopopxSignalFailure.CONNECTION_UNAVAILABLE -> stringResource(MR.strings.commerce_gloss_unreachable)
  PopopxSignalFailure.SIGNAL_REJECTED -> stringResource(MR.strings.commerce_rejected)
  PopopxSignalFailure.KEYCHAIN_UNAVAILABLE ->
    if (credit) stringResource(MR.strings.commerce_credit_voucher_unavailable) else stringResource(MR.strings.commerce_gloss_generic)
}

/**
 * iOS prints these dates through `PopopxCommerceFormat.date`, a locale-aware formatter. The common source set
 * has no locale formatter that both targets compile, so the card prints an unambiguous ISO day instead — the
 * same string on every device, which is the property that matters for "when did this expire".
 */
private fun commerceDay(epochMs: Long): String {
  val local = Instant.fromEpochMilliseconds(epochMs).toLocalDateTime(TimeZone.currentSystemDefault()).date
  return "%04d-%02d-%02d".format(local.year, local.monthNumber, local.dayOfMonth)
}
