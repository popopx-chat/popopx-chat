package chat.popopx.common.views.eco

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Surface
import androidx.compose.material.Text
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.discover.PopopxNodeUpdateDecision
import chat.popopx.common.discover.PopopxNodeUpdateWire
import chat.popopx.common.discover.PopopxSubscriptionEngine
import chat.popopx.common.discover.popopxNodeReceiptKey
import chat.popopx.common.signal.PopopxSilentSignalingRouter
import chat.popopx.common.ui.theme.PopopxBrand
import chat.popopx.common.ui.theme.PopopxLabelHint
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.ui.theme.PopopxOnBrand
import chat.popopx.common.ui.theme.PopopxPressScale
import chat.popopx.common.ui.theme.PopopxRadiusCard
import chat.popopx.common.ui.theme.PopopxRadiusChip
import chat.popopx.common.ui.theme.PopopxRadiusControl
import chat.popopx.common.ui.theme.PopopxSnappySpring
import chat.popopx.common.ui.theme.PopopxSuccessInk
import chat.popopx.common.ui.theme.isInDarkTheme
import chat.popopx.common.ui.theme.sectionCardColor
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.compose.painterResource
import kotlinx.coroutines.launch

// The phone's half of the Mac Node's upgrade notice, ported from
// apps/ios/Shared/Features/ServiceAccount/ServiceCardBubbleView.swift (`PopopxNodeUpdateCard`, :699-860).
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
//
// The look follows the same iOS struct: the mesh-teal hairline is the app's "comes from your own hardware"
// colour and the only thing separating this card from a stranger's text; the icon chip, eyebrow and title reuse
// the eco card's header idiom so a node notice and a service card read as the same kind of thing.

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

  // One place decides what the card may offer (`PopopxNodeUpdateCard.status()`, :786-810), so the status line
  // and the buttons cannot disagree about whether this notice is still answerable. A retry clears the failure
  // the same way iOS's `answer()` does; the decision order is sending → failed → answered, exactly as there.
  val sendingNow = sending
  val status = when {
    !bonded -> NodeUpdateStatus(
      generalGetString(MR.strings.node_update_unbonded), MR.images.ic_shield, MaterialTheme.colors.error, false
    )
    sendingNow != null -> NodeUpdateStatus(
      generalGetString(
        if (sendingNow == PopopxNodeUpdateDecision.APPROVED) MR.strings.node_update_sending_install
        else MR.strings.node_update_sending_snooze
      ),
      MR.images.ic_arrow_upward, MaterialTheme.colors.secondary, false
    )
    failed -> NodeUpdateStatus(
      generalGetString(MR.strings.node_update_failed), MR.images.ic_warning, MaterialTheme.colors.error, true
    )
    answered == PopopxNodeUpdateDecision.APPROVED -> NodeUpdateStatus(
      generalGetString(MR.strings.node_update_approved), MR.images.ic_check_circle_filled, PopopxSuccessInk, false
    )
    answered == PopopxNodeUpdateDecision.SNOOZED -> NodeUpdateStatus(
      generalGetString(MR.strings.node_update_snoozed), MR.images.ic_schedule, MaterialTheme.colors.secondary, false
    )
    else -> null
  }

  fun answer(decision: PopopxNodeUpdateDecision) {
    if (!bonded || sending != null) return
    scope.launch {
      failed = false
      sending = decision
      val delivered = contactId != null && PopopxSilentSignalingRouter.shared.sendNodeText(
        if (decision == PopopxNodeUpdateDecision.APPROVED) notice.approveCommand else notice.snoozeCommand,
        contactId
      )
      sending = null
      if (delivered) {
        engine.recordNodeUpdateDecision(receiptKey, decision)
        answered = decision
      } else {
        failed = true
      }
    }
  }

  val meta = buildList {
    notice.build?.let { add(String.format(generalGetString(MR.strings.node_update_build_format), it)) }
    notice.releasedAt?.let { add(String.format(generalGetString(MR.strings.node_update_released_format), it)) }
    notice.shortSha?.let { add(String.format(generalGetString(MR.strings.node_update_digest_format), it)) }
  }.joinToString(" · ")

  Surface(
    Modifier.fillMaxWidth(),
    shape = RoundedCornerShape(PopopxRadiusCard),
    color = sectionCardColor(),
    border = BorderStroke(1.dp, PopopxMeshInk.copy(alpha = 0.35f)),
    elevation = if (isInDarkTheme()) 0.dp else 1.dp,
  ) {
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
      Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
          Box(
            Modifier
              .size(32.dp)
              .clip(RoundedCornerShape(PopopxRadiusChip))
              .background(PopopxMeshInk.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center
          ) {
            Icon(painterResource(MR.images.ic_desktop), null, Modifier.size(17.dp), tint = PopopxMeshInk)
          }
          Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(generalGetString(MR.strings.discover_node_heading), fontSize = 12.sp, color = PopopxMeshInk)
            Text(
              String.format(generalGetString(MR.strings.node_update_ready_format), notice.version),
              fontSize = 17.sp,
              fontWeight = FontWeight.SemiBold,
              color = MaterialTheme.colors.onBackground
            )
          }
        }
        if (meta.isNotEmpty()) {
          Text(meta, fontSize = 13.sp, color = MaterialTheme.colors.secondary)
        }
        if (notice.hasSummary) {
          Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            notice.summaryLines.forEach { line ->
              Text("· $line", fontSize = 16.sp, color = MaterialTheme.colors.onBackground)
            }
          }
        }
      }
      if (status != null) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
          status.icon?.let { Icon(painterResource(it), null, Modifier.size(13.dp), tint = status.ink) }
          Text(status.text, fontSize = 13.sp, color = status.ink)
        }
      }
      if (status?.offersActions ?: true) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
          NodeUpdateButton(
            generalGetString(MR.strings.node_update_now),
            filled = true,
            Modifier.weight(1f)
          ) { answer(PopopxNodeUpdateDecision.APPROVED) }
          NodeUpdateButton(
            generalGetString(MR.strings.app_check_for_updates_button_remind_later),
            filled = false,
            Modifier.weight(1f)
          ) { answer(PopopxNodeUpdateDecision.SNOOZED) }
        }
      }
    }
  }
}

private data class NodeUpdateStatus(
  val text: String,
  val icon: ImageResource?,
  val ink: Color,
  val offersActions: Boolean,
)

/**
 * The card's two answers (`PopopxNodeUpdateCard.button`, :831-855): equal width, 44dp floor, `radiusControl`,
 * brand fill versus a card face outlined in `labelHint`, emphasis type. The press feedback is the same
 * spring scale as the onboarding primary button — no ripple growth, because a receipt tap must not read as
 * a destructive control.
 */
@Composable
private fun NodeUpdateButton(title: String, filled: Boolean, modifier: Modifier = Modifier, click: () -> Unit) {
  val interactionSource = remember { MutableInteractionSource() }
  val pressed by interactionSource.collectIsPressedAsState()
  val scale by animateFloatAsState(
    targetValue = if (pressed) PopopxPressScale else 1f,
    animationSpec = PopopxSnappySpring,
    label = "node-update-press"
  )
  val shape = RoundedCornerShape(PopopxRadiusControl)
  Surface(
    shape = shape,
    color = if (filled) PopopxBrand else sectionCardColor(),
    border = if (filled) null else BorderStroke(1.dp, PopopxLabelHint),
    modifier = modifier
      .heightIn(min = 44.dp)
      .graphicsLayer {
        scaleX = scale
        scaleY = scale
      }
      .clickable(
        interactionSource = interactionSource,
        indication = LocalIndication.current,
        onClick = click
      )
  ) {
    Box(
      Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
      contentAlignment = Alignment.Center
    ) {
      Text(
        title,
        fontSize = 17.sp,
        fontWeight = FontWeight.SemiBold,
        color = if (filled) PopopxOnBrand else MaterialTheme.colors.onBackground,
        maxLines = 1
      )
    }
  }
}