package chat.popopx.common.views.eco

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Button
import androidx.compose.material.ButtonDefaults
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.material.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.discover.PopopxNodeUpdateDecision
import chat.popopx.common.discover.PopopxNodeUpdateWire
import chat.popopx.common.discover.PopopxSubscriptionEngine
import chat.popopx.common.discover.popopxNodeReceiptKey
import chat.popopx.common.signal.PopopxSilentSignalingRouter
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import kotlinx.coroutines.launch

// The phone's half of the Mac Node's upgrade notice, ported from
// apps/ios/Shared/Features/ServiceAccount/ServiceCardBubbleView.swift (`NodeUpdateCardView`).
//
// What the card may NOT do is the interesting part. The two buttons carry the command strings the node put in
// the notice — `::popopx_sys::NODE_CMD::updates::approve::{"v":…,"rcp":…}` — and the `rcp` is an HMAC the node
// minted over its own pending release (`UpdateCenter.swift:219-228`). This device cannot compute one, cannot
// repair one, and cannot re-order the JSON inside one without invalidating it, so the strings go out verbatim
// through [PopopxSilentSignalingRouter.sendNodeText] rather than through `sendNodeCommand`, which rebuilds the
// marker around an already-complete wire string and doubles it.
//
// A tap is therefore a question, not an instruction: the node re-checks the receipt, and a spent or foreign one
// is refused there. The local record of the answer exists only so the card stops offering a second tap.

/** One upgrade notice, rendered as the card that replaces the text of the message that carried it. */
@Composable
fun PopopxNodeUpdateCardView(notice: PopopxNodeUpdateWire.Notice, contactId: Long?) {
  val engine = PopopxSubscriptionEngine.shared
  val scope = rememberCoroutineScope()
  val receiptKey = remember(notice.approveCommand) { popopxNodeReceiptKey(notice.approveCommand) }

  // The bond decides whether the buttons exist at all. Anyone who can send this device a message can send the
  // card text, and the parser deliberately accepts a card from an unbonded sender so it still renders; the one
  // thing that must not be possible is echoing a receipt into a stranger's command channel.
  val bonded = contactId != null && engine.nodeContactId == contactId

  var answered by remember(receiptKey) { mutableStateOf(PopopxNodeUpdateDecision.from(engine.nodeUpdateDecision(receiptKey))) }
  var sending by remember(receiptKey) { mutableStateOf<PopopxNodeUpdateDecision?>(null) }
  var failed by remember(receiptKey) { mutableStateOf(false) }

  val meta = buildList {
    notice.build?.let { add(String.format(generalGetString(MR.strings.node_update_build_format), it)) }
    notice.releasedAt?.let { add(String.format(generalGetString(MR.strings.node_update_released_format), it)) }
    notice.shortSha?.let { add(String.format(generalGetString(MR.strings.node_update_digest_format), it)) }
  }

  Column(
    Modifier
      .fillMaxWidth()
      .clip(RoundedCornerShape(12.dp))
      .background(MaterialTheme.colors.surface)
      .padding(12.dp),
    verticalArrangement = Arrangement.spacedBy(8.dp)
  ) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
      Box(
        Modifier
          .size(24.dp)
          .clip(RoundedCornerShape(6.dp))
          .background(MaterialTheme.colors.primary.copy(alpha = 0.12f)),
        contentAlignment = Alignment.Center
      ) {
        Icon(painterResource(MR.images.ic_desktop), null, Modifier.size(14.dp), tint = MaterialTheme.colors.primary)
      }
      Text(
        generalGetString(MR.strings.discover_node_heading),
        fontSize = 12.sp,
        fontWeight = FontWeight.Medium,
        color = MaterialTheme.colors.secondary,
      )
    }
    Text(
      String.format(generalGetString(MR.strings.app_check_for_updates_update_available), notice.version),
      style = MaterialTheme.typography.body1,
      fontWeight = FontWeight.SemiBold
    )
    if (meta.isNotEmpty()) {
      Text(meta.joinToString(" · "), fontSize = 12.sp, color = MaterialTheme.colors.secondary)
    }
    if (notice.hasSummary) {
      Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        notice.summaryLines.forEach { line ->
          Text("· $line", fontSize = 13.sp, style = MaterialTheme.typography.body2)
        }
      }
      if (meta.isEmpty()) {
        Text(
          String.format(generalGetString(MR.strings.node_update_features_format), notice.summaryLines.size),
          fontSize = 12.sp,
          color = MaterialTheme.colors.secondary
        )
      }
    }
    val pending = sending
    when {
      answered != null -> Text(
        generalGetString(
          if (answered == PopopxNodeUpdateDecision.APPROVED) MR.strings.node_update_approved else MR.strings.node_update_snoozed
        ),
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary
      )
      pending != null -> Text(
        generalGetString(
          if (pending == PopopxNodeUpdateDecision.APPROVED) MR.strings.node_update_sending_install else MR.strings.node_update_sending_snooze
        ),
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary
      )
      failed -> Text(generalGetString(MR.strings.node_update_failed), fontSize = 12.sp, color = MaterialTheme.colors.error)
      !bonded -> Text(generalGetString(MR.strings.node_update_unbonded), fontSize = 12.sp, color = MaterialTheme.colors.error)
    }
    if (answered == null) {
      Button(
        onClick = {
          if (!bonded || pending != null) return@Button
          scope.launch {
            sending = PopopxNodeUpdateDecision.APPROVED
            val delivered = contactId != null &&
              PopopxSilentSignalingRouter.shared.sendNodeText(notice.approveCommand, contactId)
            sending = null
            if (delivered) {
              engine.recordNodeUpdateDecision(receiptKey, PopopxNodeUpdateDecision.APPROVED)
              answered = PopopxNodeUpdateDecision.APPROVED
            } else {
              failed = true
            }
          }
        },
        enabled = bonded,
        colors = ButtonDefaults.buttonColors(
          backgroundColor = MaterialTheme.colors.primary,
          contentColor = MaterialTheme.colors.onPrimary,
          disabledBackgroundColor = MaterialTheme.colors.primary.copy(alpha = 0.35f),
          disabledContentColor = MaterialTheme.colors.onPrimary.copy(alpha = 0.6f),
        ),
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp)
      ) {
        Text(generalGetString(MR.strings.node_update_now), fontSize = 14.sp, fontWeight = FontWeight.Medium)
      }
      TextButton(
        onClick = {
          if (!bonded || pending != null) return@TextButton
          scope.launch {
            sending = PopopxNodeUpdateDecision.SNOOZED
            val delivered = contactId != null &&
              PopopxSilentSignalingRouter.shared.sendNodeText(notice.snoozeCommand, contactId)
            sending = null
            if (delivered) {
              engine.recordNodeUpdateDecision(receiptKey, PopopxNodeUpdateDecision.SNOOZED)
              answered = PopopxNodeUpdateDecision.SNOOZED
            } else {
              failed = true
            }
          }
        },
        enabled = bonded,
        modifier = Modifier.fillMaxWidth()
      ) {
        Text(
          generalGetString(MR.strings.app_check_for_updates_button_remind_later),
          fontSize = 14.sp,
          color = MaterialTheme.colors.primary
        )
      }
    }
  }
}
