package chat.popopx.common.views.eco

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Button
import androidx.compose.material.ButtonDefaults
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.material.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.eco.PopopxEcoAction
import chat.popopx.common.eco.PopopxEcoActionRunner
import chat.popopx.common.eco.PopopxEcoActionResult
import chat.popopx.common.eco.PopopxEcoRuntime
import chat.popopx.common.eco.PopopxEcoSessionStore
import chat.popopx.common.eco.PopopxEcoStore
import chat.popopx.common.eco.PopopxServiceCard
import chat.popopx.common.views.helpers.AlertManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// The service account's dynamic card, ported from
// apps/ios/Shared/Features/ServiceAccount/ServiceCardBubbleView.swift. It replaces the plain text of the
// message that carried it, so the newest state of the card is what the user reads even after the peer sent an
// update: `PopopxEcoStore.rendered` answers that, and the message row stays the anchor
// (PopopxMessageBubble.swift:1026-1029, ServiceCardBubbleView.swift:76).
//
// One thing iOS has here is deliberately absent: the credit-store jump on a shortfall
// (ServiceCardBubbleView.swift:584-592). Android has no credit-store screen, so the card states the shortfall
// and offers no control that would do nothing.
//
// The gate that matters is iOS's `:404-406`: a `pay_credits` button is dead until this device holds a pairwise
// session with the issuer, because paying an unverified counterparty is the one thing a card cannot undo. The
// other kinds are not gated — a `callback` button moves no money.

/** One service card, rendered from the store's newest state of it. */
@Composable
fun PopopxEcoCardView(card: PopopxServiceCard, contactId: Long) {
  val store = PopopxEcoStore.shared
  val scope = rememberCoroutineScope()
  LaunchedEffect(Unit) { store.loadIfNeeded() }
  val shown = store.rendered(card)

  // Read off the composition path: the session secret lives in the keystore, and iOS keeps that read out of the
  // render body for the same reason (ServiceCardBubbleView.swift:112-116). null = not read yet.
  var issuerVerified by remember { mutableStateOf<Boolean?>(null) }
  LaunchedEffect(contactId) { issuerVerified = PopopxEcoSessionStore.hasSession(contactId) }

  var expiredNow by remember(shown.cardId) { mutableStateOf(false) }
  LaunchedEffect(shown.cardId, shown.expiresAtMs) {
    val expiresAtMs = shown.expiresAtMs ?: return@LaunchedEffect
    val remaining = expiresAtMs - System.currentTimeMillis()
    if (remaining > 0L) delay(remaining)
    expiredNow = true
  }

  // A card the peer changed invalidates whatever this device reported about the previous tap (iOS:156-159), which
  // is what keying this state on `updatedAtMs` does: a new key means a fresh slot.
  var feedback by remember(shown.updatedAtMs) { mutableStateOf<EcoActionFeedback?>(null) }

  val live = shown.isLive(System.currentTimeMillis()) && !expiredNow

  Column(
    Modifier
      .fillMaxWidth()
      .clip(RoundedCornerShape(12.dp))
      .background(MaterialTheme.colors.surface)
      .padding(12.dp),
    verticalArrangement = Arrangement.spacedBy(8.dp)
  ) {
    PopopxEcoCardHeader(shown)
    val body = shown.body
    if (!body.isNullOrEmpty()) {
      Text(body, style = MaterialTheme.typography.body1)
    }
    shown.fields.forEach { PopopxEcoCardField(it) }
    val progress = shown.progress
    if (progress != null) {
      PopopxEcoCardProgress(progress)
    }
    val report = feedback
    when {
      report != null -> PopopxEcoCardStatusLine(report)
      !live -> PopopxEcoCardNoteLine(stringResource(MR.strings.eco_card_expired), MaterialTheme.colors.secondary)
      issuerVerified == false -> PopopxEcoCardNoteLine(stringResource(MR.strings.eco_card_unverified_issuer), MaterialTheme.colors.error)
    }
    if (live) {
      shown.actions.filter { it.isLive }.forEach { action ->
        PopopxEcoCardButton(
          action = action,
          locked = store.isActionLocked(shown.cardId, action.id),
          unverifiedPayBlocked = action.kind == PopopxEcoAction.Kind.PAY_CREDITS && issuerVerified == false,
          onFire = {
            scope.launch {
              val result = PopopxEcoActionRunner.run(action, shown, contactId, PopopxEcoRuntime.router)
              // The runner says this device holds no pairwise identity for this issuer, so the card cannot be
              // tied to one. iOS flips the same local flag (iOS:515-517).
              if (result == PopopxEcoActionResult.NO_SESSION) issuerVerified = false
              feedback = EcoActionFeedback(result, action)
            }
          },
        )
      }
    }
  }
}

/** The result of one tap, kept with the action it came from because two actions of one card read differently. */
private class EcoActionFeedback(val result: PopopxEcoActionResult, val action: PopopxEcoAction)

@Composable
private fun PopopxEcoCardHeader(card: PopopxServiceCard) {
  val tint = when (card.style) {
    PopopxServiceCard.Style.STANDARD -> MaterialTheme.colors.primary
    PopopxServiceCard.Style.RECEIPT -> MaterialTheme.colors.secondary
    PopopxServiceCard.Style.SECURITY -> MaterialTheme.colors.error
  }
  val icon = when (card.style) {
    PopopxServiceCard.Style.STANDARD -> MR.images.ic_id_card
    PopopxServiceCard.Style.RECEIPT -> MR.images.ic_draft_filled
    PopopxServiceCard.Style.SECURITY -> MR.images.ic_shield
  }
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    Box(
      Modifier
        .size(24.dp)
        .clip(RoundedCornerShape(6.dp))
        .background(tint.copy(alpha = 0.12f)),
      contentAlignment = Alignment.Center
    ) {
      Icon(painterResource(icon), null, Modifier.size(14.dp), tint = tint)
    }
    Text(card.title, style = MaterialTheme.typography.body1, fontWeight = FontWeight.SemiBold)
  }
}

@Composable
private fun PopopxEcoCardField(field: PopopxServiceCard.Field) {
  Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    Text(field.label, fontSize = 13.sp, color = MaterialTheme.colors.secondary, modifier = Modifier.width(110.dp))
    Text(
      field.value,
      fontSize = 13.sp,
      fontFamily = if (field.mono == true) FontFamily.Monospace else FontFamily.Default,
      modifier = Modifier.weight(1f)
    )
  }
}

@Composable
private fun PopopxEcoCardProgress(progress: PopopxServiceCard.Progress) {
  val fraction = progress.percent.coerceIn(0, 100) / 100f
  Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
      Text(progress.label, fontSize = 12.sp, color = MaterialTheme.colors.secondary)
      Text("${progress.percent}%", fontSize = 12.sp, color = MaterialTheme.colors.secondary)
    }
    Box(
      Modifier
        .fillMaxWidth()
        .height(4.dp)
        .clip(RoundedCornerShape(2.dp))
        .background(MaterialTheme.colors.background)
    ) {
      Box(
        Modifier
          .fillMaxWidth(fraction)
          .height(4.dp)
          .clip(RoundedCornerShape(2.dp))
          .background(MaterialTheme.colors.primary)
      )
    }
    val detail = progress.detail
    if (!detail.isNullOrEmpty()) {
      Text(detail, fontSize = 12.sp, color = MaterialTheme.colors.secondary)
    }
  }
}

@Composable
private fun PopopxEcoCardButton(
  action: PopopxEcoAction,
  locked: Boolean,
  unverifiedPayBlocked: Boolean,
  onFire: () -> Unit,
) {
  val fill = when (action.visual) {
    PopopxEcoAction.Visual.PRIMARY -> MaterialTheme.colors.primary
    PopopxEcoAction.Visual.SECONDARY -> MaterialTheme.colors.background
    PopopxEcoAction.Visual.DESTRUCTIVE -> MaterialTheme.colors.error
  }
  val ink = when (action.visual) {
    PopopxEcoAction.Visual.PRIMARY -> MaterialTheme.colors.onPrimary
    PopopxEcoAction.Visual.SECONDARY -> MaterialTheme.colors.onSurface
    PopopxEcoAction.Visual.DESTRUCTIVE -> MaterialTheme.colors.onError
  }
  Button(
    onClick = {
      if (action.requiresConfirmation) confirmEcoCardAction(action, onFire) else onFire()
    },
    enabled = !locked && !unverifiedPayBlocked,
    colors = ButtonDefaults.buttonColors(
      backgroundColor = fill,
      contentColor = ink,
      disabledBackgroundColor = fill.copy(alpha = 0.35f),
      disabledContentColor = ink.copy(alpha = 0.6f),
    ),
    shape = RoundedCornerShape(10.dp),
    modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp)
  ) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
      if (locked) Icon(painterResource(MR.images.ic_lock), null, Modifier.size(14.dp))
      if (unverifiedPayBlocked) Icon(painterResource(MR.images.ic_shield), null, Modifier.size(14.dp))
      Text(action.title, fontSize = 14.sp, fontWeight = FontWeight.Medium)
      val amount = action.amount
      if (action.kind == PopopxEcoAction.Kind.PAY_CREDITS && amount != null) {
        Text(String.format(generalGetString(MR.strings.eco_card_paid_format), amount), fontSize = 12.sp)
      }
    }
  }
}

/**
 * iOS's `confirmationDialog` (ServiceCardBubbleView.swift:132-151): the action title, and for a payment the
 * amount that is about to leave the wallet. The text is server-supplied, so it is rendered literally — an alert
 * that parsed markup from a card would let the card author rewrite its own confirmation.
 */
private fun confirmEcoCardAction(action: PopopxEcoAction, onConfirm: () -> Unit) {
  val amount = action.amount
  val text = if (action.kind == PopopxEcoAction.Kind.PAY_CREDITS && amount != null) {
    action.title + "\n" + String.format(generalGetString(MR.strings.eco_card_paid_format), amount)
  } else {
    action.title
  }
  AlertManager.shared.showAlertDialogButtonsColumn(
    title = generalGetString(MR.strings.eco_card_confirm_title),
    text = text,
    parseHtml = false,
    buttons = {
      TextButton(onClick = { AlertManager.shared.hideAlert(); onConfirm() }) {
        Text(generalGetString(MR.strings.confirm_verb), color = MaterialTheme.colors.primary)
      }
      TextButton(onClick = { AlertManager.shared.hideAlert() }) {
        Text(generalGetString(MR.strings.cancel_verb), color = MaterialTheme.colors.secondary)
      }
    }
  )
}

@Composable
private fun PopopxEcoCardStatusLine(feedback: EcoActionFeedback) {
  val icon = feedback.result.icon
  val ink = feedback.result.ink(feedback.action)
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
    Icon(painterResource(icon), null, Modifier.size(14.dp), tint = ink)
    Text(feedback.result.statusCopy(feedback.action), fontSize = 12.sp, color = ink)
  }
}

@Composable
private fun PopopxEcoCardNoteLine(text: String, ink: Color) {
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
    Icon(painterResource(MR.images.ic_error), null, Modifier.size(14.dp), tint = ink)
    Text(text, fontSize = 12.sp, color = ink)
  }
}

private val PopopxEcoActionResult.icon: dev.icerock.moko.resources.ImageResource
  get() = when (this) {
    PopopxEcoActionResult.SENT_CALLBACK -> MR.images.ic_arrow_upward
    PopopxEcoActionResult.PAID_AWAITING_REPLY, PopopxEcoActionResult.LOCKED -> MR.images.ic_lock
    is PopopxEcoActionResult.NeedsCredits -> MR.images.ic_error
    PopopxEcoActionResult.OPENED_H5 -> MR.images.ic_open_in_new
    PopopxEcoActionResult.OPENED_CHANNEL -> MR.images.ic_link
    PopopxEcoActionResult.EXPIRED, PopopxEcoActionResult.IGNORED, PopopxEcoActionResult.SEND_FAILED -> MR.images.ic_error
    PopopxEcoActionResult.NO_SESSION -> MR.images.ic_shield
  }

@Composable
private fun PopopxEcoActionResult.ink(action: PopopxEcoAction): Color = when (this) {
  is PopopxEcoActionResult.NeedsCredits, PopopxEcoActionResult.SEND_FAILED, PopopxEcoActionResult.NO_SESSION -> MaterialTheme.colors.error
  PopopxEcoActionResult.IGNORED -> MaterialTheme.colors.secondary
  else -> if (this == PopopxEcoActionResult.SENT_CALLBACK && action.kind == PopopxEcoAction.Kind.PAY_CREDITS) MaterialTheme.colors.primary else MaterialTheme.colors.secondary
}

/**
 * The copy one tap leaves behind. Every `PopopxEcoActionResult` case is named, as iOS's `ServiceCardOutcome` is
 * (ServiceCardBubbleView.swift:545-657), so a new case cannot fall through to silence.
 */
@Composable
private fun PopopxEcoActionResult.statusCopy(action: PopopxEcoAction): String = when (this) {
  PopopxEcoActionResult.SENT_CALLBACK ->
    if (action.kind == PopopxEcoAction.Kind.PAY_CREDITS && action.amount != null) {
      String.format(stringResource(MR.strings.eco_card_paid_format), action.amount!!)
    } else {
      stringResource(MR.strings.eco_card_sent)
    }

  PopopxEcoActionResult.PAID_AWAITING_REPLY,
  PopopxEcoActionResult.LOCKED,
  -> stringResource(MR.strings.eco_card_waiting)

  is PopopxEcoActionResult.NeedsCredits -> stringResource(MR.strings.eco_card_balance_short)
  PopopxEcoActionResult.OPENED_H5, PopopxEcoActionResult.OPENED_CHANNEL -> stringResource(MR.strings.ok)
  PopopxEcoActionResult.EXPIRED -> stringResource(MR.strings.eco_card_expired)
  PopopxEcoActionResult.IGNORED, PopopxEcoActionResult.SEND_FAILED -> stringResource(MR.strings.eco_card_failed)
  PopopxEcoActionResult.NO_SESSION -> stringResource(MR.strings.eco_card_unverified_issuer)
}
