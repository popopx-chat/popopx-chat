package chat.popopx.common.views.eco

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.material.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.eco.PopopxEcoAction
import chat.popopx.common.eco.PopopxEcoActionRunner
import chat.popopx.common.eco.PopopxEcoActionResult
import chat.popopx.common.eco.PopopxEcoRuntime
import chat.popopx.common.eco.PopopxEcoSessionStore
import chat.popopx.common.eco.PopopxEcoStore
import chat.popopx.common.eco.PopopxServiceCard
import chat.popopx.common.ui.theme.PopopxLabelHint
import chat.popopx.common.ui.theme.PopopxMesh
import chat.popopx.common.ui.theme.PopopxOnMesh
import chat.popopx.common.ui.theme.PopopxSeparator
import chat.popopx.common.views.helpers.AlertManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.ImageResource
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
// Three styles, three treatments (iOS :185-257): `standard` wears a brand badge and a 35%-brand hairline,
// `receipt` a neutral badge and a separator hairline plus a rule between its key/value rows, `security` a
// shield badge whose hue is derived from the card itself — red once it is expired or carries a destructive
// action, mesh teal while it is still a decision. The surface is `card`, 16dp round, 0.5dp edge, 16dp in.
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
  val shape = RoundedCornerShape(16.dp)
  val stroke = when (shown.style) {
    PopopxServiceCard.Style.STANDARD -> MaterialTheme.colors.primary.copy(alpha = 0.35f)
    PopopxServiceCard.Style.RECEIPT, PopopxServiceCard.Style.SECURITY -> PopopxSeparator
  }

  Column(
    Modifier
      .fillMaxWidth()
      .clip(shape)
      .background(MaterialTheme.colors.surface)
      .border(0.5.dp, stroke, shape)
      .padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(8.dp)
  ) {
    // The content block speaks as one piece and the actions follow it (iOS :82-98); the separation is structural
    // so a four-action card cannot push the status line away from the fields it explains.
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
      PopopxEcoCardHeader(shown, live, issuerVerified)
      val body = shown.body
      if (!body.isNullOrEmpty()) {
        Text(body, style = MaterialTheme.typography.body1)
      }
      if (shown.fields.isNotEmpty()) {
        PopopxEcoCardFields(shown.fields, shown.style)
      }
      val progress = shown.progress
      if (progress != null) {
        PopopxEcoCardProgress(progress)
      }
      PopopxEcoCardStatus(shown, feedback, live, issuerVerified)
    }
    if (live) {
      val liveActions = shown.actions.filter { it.isLive }
      if (liveActions.isNotEmpty()) {
        val onFire: (PopopxEcoAction) -> Unit = { action ->
          scope.launch {
            val result = PopopxEcoActionRunner.run(action, shown, contactId, PopopxEcoRuntime.router)
            // The runner says this device holds no pairwise identity for this issuer, so the card cannot be
            // tied to one. iOS flips the same local flag (iOS:515-517).
            if (result == PopopxEcoActionResult.NO_SESSION) issuerVerified = false
            feedback = EcoActionFeedback(result, action)
          }
        }
        // One action is a full-width bar; two sit side by side; three or four stack (iOS :378-400), because at
        // XXL type a three-column label would be crushed.
        if (liveActions.size == 2) {
          Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            liveActions.forEach { action ->
              PopopxEcoCardActionButton(
                action = action,
                locked = store.isActionLocked(shown.cardId, action.id),
                unverifiedPayBlocked = action.kind == PopopxEcoAction.Kind.PAY_CREDITS && issuerVerified == false,
                modifier = Modifier.weight(1f),
                onFire = { onFire(action) },
              )
            }
          }
        } else {
          Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            liveActions.forEach { action ->
              PopopxEcoCardActionButton(
                action = action,
                locked = store.isActionLocked(shown.cardId, action.id),
                unverifiedPayBlocked = action.kind == PopopxEcoAction.Kind.PAY_CREDITS && issuerVerified == false,
                modifier = Modifier.fillMaxWidth(),
                onFire = { onFire(action) },
              )
            }
          }
        }
      }
    }
  }
}

/** The result of one tap, kept with the action it came from because two actions of one card read differently. */
private class EcoActionFeedback(val result: PopopxEcoActionResult, val action: PopopxEcoAction)

@Composable
private fun PopopxEcoCardHeader(card: PopopxServiceCard, live: Boolean, issuerVerified: Boolean?) {
  val danger = MaterialTheme.colors.error
  val destructive = card.actions.any { it.visual == PopopxEcoAction.Visual.DESTRUCTIVE }
  // iOS's `badgeTint` (ServiceCardBubbleView.swift:214-229): a security card reads red once it is spent or points
  // at a destructive action, and mesh teal while it is a decision waiting to be made.
  val securityAlarm = !live || destructive
  val fill = when (card.style) {
    PopopxServiceCard.Style.STANDARD -> MaterialTheme.colors.primary
    PopopxServiceCard.Style.RECEIPT -> PopopxSeparator
    PopopxServiceCard.Style.SECURITY -> if (securityAlarm) danger else PopopxMesh
  }
  val ink = when (card.style) {
    PopopxServiceCard.Style.STANDARD -> MaterialTheme.colors.onPrimary
    PopopxServiceCard.Style.RECEIPT -> MaterialTheme.colors.onSurface
    PopopxServiceCard.Style.SECURITY -> if (securityAlarm) MaterialTheme.colors.onError else PopopxOnMesh
  }
  val icon = when (card.style) {
    PopopxServiceCard.Style.STANDARD -> MR.images.ic_notifications
    PopopxServiceCard.Style.RECEIPT -> MR.images.ic_article
    PopopxServiceCard.Style.SECURITY -> MR.images.ic_shield
  }
  Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
    Box(
      Modifier
        .size(24.dp)
        .clip(RoundedCornerShape(8.dp))
        .background(fill),
      contentAlignment = Alignment.Center
    ) {
      Icon(painterResource(icon), null, Modifier.size(14.dp), tint = ink)
    }
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
      Text(card.title, style = MaterialTheme.typography.body1, fontWeight = FontWeight.SemiBold)
      if (!live) {
        Text(stringResource(MR.strings.eco_card_expired), fontSize = 13.sp, color = MaterialTheme.colors.secondary)
      } else if (issuerVerified == false) {
        Text(stringResource(MR.strings.eco_card_unverified_issuer), fontSize = 13.sp, color = danger)
      }
    }
  }
}

/**
 * The key/value grid. Labels lead, values trail (iOS's `Grid` alignment, :262-287); a `receipt` card rules
 * between rows so a long bill reads as a table rather than a paragraph.
 */
@Composable
private fun PopopxEcoCardFields(fields: List<PopopxServiceCard.Field>, style: PopopxServiceCard.Style) {
  Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
    fields.forEachIndexed { index, field ->
      Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(field.label, Modifier.weight(0.45f), fontSize = 13.sp, color = MaterialTheme.colors.secondary)
        Text(
          field.value,
          Modifier.weight(0.55f),
          fontSize = if (field.mono == true) 13.sp else 15.sp,
          fontFamily = if (field.mono == true) FontFamily.Monospace else FontFamily.Default,
          textAlign = TextAlign.End
        )
      }
      if (style == PopopxServiceCard.Style.RECEIPT && index < fields.lastIndex) {
        Spacer(Modifier.fillMaxWidth().height(0.5.dp).background(PopopxSeparator))
      }
    }
  }
}

@Composable
private fun PopopxEcoCardProgress(progress: PopopxServiceCard.Progress) {
  val fraction = progress.percent.coerceIn(0, 100) / 100f
  Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
      Text("${progress.label} ${progress.percent}%", fontSize = 13.sp)
      val detail = progress.detail
      if (!detail.isNullOrEmpty()) {
        Spacer(Modifier.width(8.dp))
        Text(detail, fontSize = 13.sp, color = MaterialTheme.colors.secondary)
      }
      Spacer(Modifier.weight(1f))
    }
    Box(
      Modifier
        .fillMaxWidth()
        .height(4.dp)
        .clip(RoundedCornerShape(2.dp))
        .background(PopopxSeparator)
    ) {
      Box(
        Modifier
          .fillMaxWidth(fraction)
          .fillMaxHeight()
          .clip(RoundedCornerShape(2.dp))
          .background(MaterialTheme.colors.primary)
      )
    }
  }
}

@Composable
private fun PopopxEcoCardStatus(
  card: PopopxServiceCard,
  feedback: EcoActionFeedback?,
  live: Boolean,
  issuerVerified: Boolean?,
) {
  when {
    feedback != null -> PopopxEcoCardStatusLine(feedback)
    !live -> PopopxEcoCardNoteLine(MR.images.ic_error, stringResource(MR.strings.eco_card_expired), MaterialTheme.colors.secondary)
    issuerVerified == false ->
      PopopxEcoCardNoteLine(MR.images.ic_shield, stringResource(MR.strings.eco_card_unverified_issuer), MaterialTheme.colors.error)
  }
}

@Composable
private fun PopopxEcoCardActionButton(
  action: PopopxEcoAction,
  locked: Boolean,
  unverifiedPayBlocked: Boolean,
  modifier: Modifier = Modifier,
  onFire: () -> Unit,
) {
  val enabled = !locked && !unverifiedPayBlocked
  val shape = RoundedCornerShape(12.dp)
  val fill = when (action.visual) {
    PopopxEcoAction.Visual.PRIMARY -> MaterialTheme.colors.primary
    PopopxEcoAction.Visual.SECONDARY -> MaterialTheme.colors.surface
    PopopxEcoAction.Visual.DESTRUCTIVE -> MaterialTheme.colors.error
  }
  val ink = when (action.visual) {
    PopopxEcoAction.Visual.PRIMARY -> MaterialTheme.colors.onPrimary
    PopopxEcoAction.Visual.SECONDARY -> MaterialTheme.colors.onSurface
    PopopxEcoAction.Visual.DESTRUCTIVE -> MaterialTheme.colors.onError
  }
  // iOS's `actionLabel` (ServiceCardBubbleView.swift:427-460): 12dp round, 44dp tall, brand / outlined card /
  // danger fill; a secondary button is outlined with the label-hint hairline rather than a second fill.
  Row(
    modifier
      .heightIn(min = 44.dp)
      .clip(shape)
      .background(fill)
      .then(
        if (action.visual == PopopxEcoAction.Visual.SECONDARY) Modifier.border(1.dp, PopopxLabelHint, shape)
        else Modifier
      )
      .then(
        if (enabled) Modifier.clickable {
          if (action.requiresConfirmation) confirmEcoCardAction(action, onFire) else onFire()
        } else Modifier
      )
      .alpha(if (enabled) 1f else 0.45f)
      .padding(horizontal = 16.dp, vertical = 12.dp),
    horizontalArrangement = Arrangement.Center,
    verticalAlignment = Alignment.CenterVertically
  ) {
    if (locked) {
      Icon(painterResource(MR.images.ic_lock), null, Modifier.size(16.dp), tint = ink)
      Spacer(Modifier.width(8.dp))
    }
    if (unverifiedPayBlocked) {
      Icon(painterResource(MR.images.ic_shield), null, Modifier.size(16.dp), tint = ink)
      Spacer(Modifier.width(8.dp))
    }
    Text(action.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = ink)
    val amount = action.amount
    if (action.kind == PopopxEcoAction.Kind.PAY_CREDITS && amount != null) {
      Spacer(Modifier.width(8.dp))
      // iOS labels the price with its own formatter (`creditsAmountFormat`) rather than the past-tense receipt
      // sentence, so the button reads "Pay 100 Compute Credits", not "Paid 100 …" (iOS:442-446).
      Text(
        String.format(generalGetString(MR.strings.commerce_credits_amount), amount),
        fontSize = 13.sp,
        color = ink.copy(alpha = 0.85f)
      )
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
    action.title + "\n" + String.format(generalGetString(MR.strings.commerce_credits_amount), amount)
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
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    Icon(painterResource(icon), null, Modifier.size(14.dp), tint = ink)
    Text(feedback.result.statusCopy(feedback.action), fontSize = 13.sp, color = ink)
  }
}

@Composable
private fun PopopxEcoCardNoteLine(icon: ImageResource, text: String, ink: Color) {
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    Icon(painterResource(icon), null, Modifier.size(14.dp), tint = ink)
    Text(text, fontSize = 13.sp, color = ink)
  }
}

private val PopopxEcoActionResult.icon: ImageResource
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