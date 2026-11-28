package chat.popopx.common.views.agent

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Divider
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.agent.PopopxAgentReceipt
import chat.popopx.common.agent.PopopxAgentReceiptWire
import chat.popopx.common.agent.PopopxAgentTask
import chat.popopx.common.agent.PopopxAgentTaskWire
import chat.popopx.common.eco.PopopxEcoSecrets
import chat.popopx.common.model.Chat
import chat.popopx.common.signal.PopopxSilentSignalingRouter
import chat.popopx.common.ui.theme.PopopxBrand
import chat.popopx.common.ui.theme.PopopxCanvas
import chat.popopx.common.ui.theme.PopopxHairlineInner
import chat.popopx.common.ui.theme.PopopxLabelHint
import chat.popopx.common.ui.theme.PopopxMesh
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.ui.theme.PopopxOnBrand
import chat.popopx.common.ui.theme.PopopxRadiusCard
import chat.popopx.common.ui.theme.PopopxRadiusChip
import chat.popopx.common.ui.theme.PopopxRadiusControl
import chat.popopx.common.ui.theme.PopopxSeparator
import chat.popopx.common.ui.theme.PopopxSuccess
import chat.popopx.common.ui.theme.PopopxSuccessInk
import chat.popopx.common.ui.theme.PopopxSurface
import chat.popopx.common.ui.theme.PopopxWarningFill
import chat.popopx.common.ui.theme.PopopxWarningInk
import chat.popopx.common.ui.theme.isInDarkTheme
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.compose.painterResource
import kotlinx.coroutines.launch
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlin.random.Random

// The Android half of the `popopx.agent.task.v1` family, ported from
// apps/ios/Shared/Features/ServiceAccount/ServiceCardBubbleView.swift (`PopopxAgentTaskCard`).
//
// One frame for the four kinds on purpose: an agent moves a task from progress to approval to result under
// the same task id, and the user should recognise "the same card, one step on" rather than meet four
// unrelated widgets. Same three rules as the node update card:
// - the receipt bytes are minted here (`PopopxAgentReceiptSigner`) and handed to the router verbatim;
// - a decision is journalled only AFTER a successful send, and read back on every appearance;
// - the reply goes to the card's own conversation contact; with none the card renders read-only.

/** One `popopx.agent.task.v1` card, rendered in place of the text line that carried it. */
@Composable
fun PopopxAgentTaskCardView(task: PopopxAgentTask, incoming: Boolean, contactId: Long?) {
  val scope = rememberCoroutineScope()
  var recorded by remember(task.taskId) { mutableStateOf(PopopxAgentReceiptJournal.record(task.taskId)) }
  var sending by remember(task.taskId) { mutableStateOf(false) }
  var sendFailed by remember(task.taskId) { mutableStateOf(false) }

  // One place decides what the card may offer (`offersActions`), so the state line and the buttons
  // cannot disagree about whether this task is still answerable.
  val offersActions = incoming && contactId != null && contactId > 0 && task.isActive && recorded == null

  fun answer(decision: PopopxAgentReceiptWire.Decision, choiceId: String = "") {
    val target = contactId
    if (!offersActions || sending || target == null) return
    scope.launch {
      sendFailed = false
      sending = true
      val delivered = PopopxAgentReceiptResponder.send(task.taskId, decision, choiceId, target)
      sending = false
      if (delivered) {
        val line = PopopxAgentReceiptJournal.line(decision, choiceId)
        PopopxAgentReceiptJournal.put(line, task.taskId)
        recorded = line
      } else {
        sendFailed = true
      }
    }
  }

  val shape = RoundedCornerShape(PopopxRadiusCard)
  Surface(
    Modifier.fillMaxWidth(),
    shape = shape,
    color = PopopxSurface,
    border = BorderStroke(0.5.dp, PopopxHairlineInner),
    elevation = if (isInDarkTheme()) 0.dp else 1.dp,
  ) {
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
      header(task)
      if (task.retentionZero) {
        retentionLine()
      }
      task.detail?.takeIf { it.isNotEmpty() }?.let {
        Text(it, fontSize = 15.sp, color = MaterialTheme.colors.secondary)
      }
      if (task.kind == PopopxAgentTask.Kind.APPROVAL && task.permissions.isNotEmpty()) {
        permissionsBlock(task.permissions)
      }
      task.percent?.let { percentBlock(it) }
      if (task.steps.isNotEmpty()) {
        stepsBlock(task)
      }
      if (task.kind == PopopxAgentTask.Kind.CHOICE && task.choices.isNotEmpty()) {
        choicesBlock(task, offersActions, recorded, sending) { choice -> answer(PopopxAgentReceiptWire.Decision.CHOOSE, choice.id) }
      }
      task.result?.takeIf { it.isNotEmpty() }?.let { resultBlock(it) }
      statusLine(task, sending, sendFailed, recorded)
      if (task.kind == PopopxAgentTask.Kind.APPROVAL && offersActions) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
          AgentActionButton(
            generalGetString(MR.strings.agent_task_approve),
            filled = true,
            enabled = !sending,
            Modifier.weight(1f)
          ) { answer(PopopxAgentReceiptWire.Decision.APPROVE) }
          AgentActionButton(
            generalGetString(MR.strings.agent_task_deny),
            filled = false,
            enabled = !sending,
            Modifier.weight(1f)
          ) { answer(PopopxAgentReceiptWire.Decision.DENY) }
        }
      }
    }
  }
}

@Composable
private fun header(task: PopopxAgentTask) {
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
    val (fill, ink) = when (task.status) {
      PopopxAgentTask.Status.COMPLETED -> PopopxSuccess.copy(alpha = 0.12f) to PopopxSuccessInk
      PopopxAgentTask.Status.FAILED -> MaterialTheme.colors.error.copy(alpha = 0.12f) to MaterialTheme.colors.error
      PopopxAgentTask.Status.CANCELLED -> MaterialTheme.colors.secondary.copy(alpha = 0.12f) to MaterialTheme.colors.secondary
      else -> PopopxBrand.copy(alpha = 0.12f) to PopopxBrand
    }
    Box(
      Modifier.size(32.dp).clip(RoundedCornerShape(PopopxRadiusChip)).background(fill),
      contentAlignment = Alignment.Center
    ) {
      Icon(painterResource(symbol(task.kind)), null, Modifier.size(17.dp), tint = ink)
    }
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
      Text(
        task.agent ?: generalGetString(MR.strings.agent_task_spoken),
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary
      )
      Text(task.title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colors.onBackground)
    }
    task.percent?.let {
      Text("$it%", fontSize = 13.sp, color = MaterialTheme.colors.secondary)
    }
  }
}

private fun symbol(kind: PopopxAgentTask.Kind): ImageResource = when (kind) {
  PopopxAgentTask.Kind.PROGRESS -> MR.images.ic_bolt
  PopopxAgentTask.Kind.APPROVAL -> MR.images.ic_back_hand
  PopopxAgentTask.Kind.CHOICE -> MR.images.ic_checklist
  PopopxAgentTask.Kind.RESULT -> MR.images.ic_check_circle_filled
}

@Composable
private fun retentionLine() {
  Row(
    Modifier
      .clip(RoundedCornerShape(PopopxRadiusChip))
      .background(PopopxMesh.copy(alpha = 0.12f))
      .padding(horizontal = 8.dp, vertical = 4.dp),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(4.dp)
  ) {
    Icon(painterResource(MR.images.ic_lock_filled), null, Modifier.size(12.dp), tint = PopopxMeshInk)
    Text(
      generalGetString(MR.strings.agent_task_zero_retention_line),
      fontSize = 13.sp,
      color = PopopxMeshInk
    )
  }
}

@Composable
private fun permissionsBlock(permissions: List<String>) {
  Column(
    Modifier
      .fillMaxWidth()
      .clip(RoundedCornerShape(PopopxRadiusControl))
      .background(PopopxCanvas)
      .padding(12.dp),
    verticalArrangement = Arrangement.spacedBy(8.dp)
  ) {
    Text(
      generalGetString(MR.strings.agent_task_permissions_requested),
      fontSize = 12.sp,
      color = MaterialTheme.colors.secondary
    )
    permissions.forEach { permission ->
      Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(painterResource(MR.images.ic_shield), null, Modifier.size(14.dp), tint = PopopxBrand)
        Text(permission, fontSize = 15.sp, color = MaterialTheme.colors.onBackground)
      }
    }
  }
}

@Composable
private fun percentBlock(percent: Int) {
  Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
    Box(
      Modifier.fillMaxWidth().height(6.dp).clip(CircleShape).background(PopopxSeparator)
    ) {
      Box(
        Modifier
          .fillMaxWidth(percent.coerceIn(0, 100) / 100f)
          .height(6.dp)
          .clip(CircleShape)
          .background(PopopxBrand)
      )
    }
    Text(
      // The percent sign lives here, not in the resource: the moko build's placeholder scanner rejects a
      // literal "%" in any <string> value, so the value stops at the number.
      String.format(generalGetString(MR.strings.agent_task_progress_format), percent) + "%",
      fontSize = 12.sp,
      color = MaterialTheme.colors.secondary
    )
  }
}

@Composable
private fun stepsBlock(task: PopopxAgentTask) {
  val done = task.steps.count { it.state == PopopxAgentTask.Step.State.DONE }
  Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
    task.steps.forEach { step ->
      val (icon, ink) = when (step.state) {
        PopopxAgentTask.Step.State.PENDING -> MR.images.ic_circle to PopopxLabelHint
        PopopxAgentTask.Step.State.ACTIVE -> MR.images.ic_circle_filled to PopopxBrand
        PopopxAgentTask.Step.State.DONE -> MR.images.ic_check_circle_filled to PopopxSuccessInk
        PopopxAgentTask.Step.State.FAILED -> MR.images.ic_error_filled to MaterialTheme.colors.error
      }
      Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(painterResource(icon), null, Modifier.size(14.dp), tint = ink)
        Text(
          step.label,
          fontSize = 15.sp,
          color = if (step.state == PopopxAgentTask.Step.State.PENDING) MaterialTheme.colors.secondary else MaterialTheme.colors.onBackground
        )
      }
    }
    Text(
      String.format(generalGetString(MR.strings.agent_task_steps_format), done, task.steps.size),
      fontSize = 12.sp,
      color = MaterialTheme.colors.secondary
    )
  }
}

@Composable
private fun choicesBlock(
  task: PopopxAgentTask,
  offersActions: Boolean,
  recorded: String?,
  sending: Boolean,
  choose: (PopopxAgentTask.Choice) -> Unit
) {
  val spent = recorded != null || !task.isActive || !offersActions
  Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
    Text(
      generalGetString(MR.strings.agent_task_choose_one),
      fontSize = 12.sp,
      color = MaterialTheme.colors.secondary
    )
    task.choices.forEach { choice ->
      val shape = RoundedCornerShape(PopopxRadiusControl)
      Surface(
        shape = shape,
        color = PopopxSurface,
        border = BorderStroke(1.dp, PopopxBrand.copy(alpha = if (spent) 0.3f else 0.8f)),
        modifier = Modifier
          .fillMaxWidth()
          .heightIn(min = 44.dp)
          .clickable(enabled = !spent && !sending) { choose(choice) }
      ) {
        Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
          Text(
            choice.label,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            color = PopopxBrand.copy(alpha = if (spent) 0.55f else 1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
          )
        }
      }
    }
  }
}

@Composable
private fun resultBlock(result: String) {
  Column(
    Modifier
      .fillMaxWidth()
      .clip(RoundedCornerShape(PopopxRadiusControl))
      .background(PopopxCanvas)
      .padding(12.dp),
    verticalArrangement = Arrangement.spacedBy(4.dp)
  ) {
    Text(
      generalGetString(MR.strings.agent_task_result),
      fontSize = 12.sp,
      color = MaterialTheme.colors.secondary
    )
    Text(result, fontSize = 15.sp, color = MaterialTheme.colors.onBackground)
  }
}

@Composable
private fun statusLine(task: PopopxAgentTask, sending: Boolean, sendFailed: Boolean, recorded: String?) {
  val text: String
  val icon: ImageResource
  val ink: Color
  when {
    sending -> {
      text = generalGetString(MR.strings.agent_task_sending_answer)
      icon = MR.images.ic_arrow_upward
      ink = MaterialTheme.colors.secondary
    }
    sendFailed -> {
      text = generalGetString(MR.strings.agent_task_send_failed)
      icon = MR.images.ic_warning
      ink = MaterialTheme.colors.error
    }
    recorded != null -> {
      text = PopopxAgentCopy.recordLine(recorded)
      icon = MR.images.ic_check_circle_filled
      ink = PopopxSuccessInk
    }
    task.status == PopopxAgentTask.Status.COMPLETED -> {
      text = PopopxAgentCopy.status(task.status)
      icon = MR.images.ic_check_circle_filled
      ink = PopopxSuccessInk
    }
    task.status == PopopxAgentTask.Status.FAILED -> {
      text = PopopxAgentCopy.status(task.status)
      icon = MR.images.ic_error_filled
      ink = MaterialTheme.colors.error
    }
    task.status == PopopxAgentTask.Status.CANCELLED -> {
      text = PopopxAgentCopy.status(task.status)
      icon = MR.images.ic_info
      ink = MaterialTheme.colors.secondary
    }
    else -> return
  }
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
    Icon(painterResource(icon), null, Modifier.size(13.dp), tint = ink)
    Text(text, fontSize = 13.sp, color = ink)
  }
}

/**
 * The card's answers, with the node update card's press idiom: equal width, 44dp floor,
 * `radiusControl`, brand fill versus a card face outlined in `labelHint`.
 */
@Composable
private fun AgentActionButton(title: String, filled: Boolean, enabled: Boolean, modifier: Modifier = Modifier, click: () -> Unit) {
  val shape = RoundedCornerShape(PopopxRadiusControl)
  Surface(
    shape = shape,
    color = if (filled) PopopxBrand else PopopxSurface,
    border = if (filled) null else BorderStroke(1.dp, PopopxLabelHint),
    modifier = modifier
      .heightIn(min = 44.dp)
      .clickable(enabled = enabled, onClick = click)
  ) {
    Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
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

// MARK: - Wording

/** The card, pill and bar sentences, one table so the three surfaces cannot disagree. */
object PopopxAgentCopy {
  fun spokenPrefix(): String = generalGetString(MR.strings.agent_task_spoken)
  fun zeroRetention(): String = generalGetString(MR.strings.agent_task_zero_retention)
  fun awaitingCount(count: Int): String = String.format(generalGetString(MR.strings.agent_task_awaiting_count_format), count)
  fun workingPercent(percent: Int): String =
    String.format(generalGetString(MR.strings.agent_task_working_percent_format), percent) + "%"
  fun working(): String = generalGetString(MR.strings.agent_task_working)

  fun status(status: PopopxAgentTask.Status): String = when (status) {
    PopopxAgentTask.Status.RUNNING -> generalGetString(MR.strings.agent_task_status_running)
    PopopxAgentTask.Status.AWAITING_APPROVAL -> generalGetString(MR.strings.agent_task_status_awaiting)
    PopopxAgentTask.Status.COMPLETED -> generalGetString(MR.strings.agent_task_status_completed)
    PopopxAgentTask.Status.FAILED -> generalGetString(MR.strings.agent_task_status_failed)
    PopopxAgentTask.Status.CANCELLED -> generalGetString(MR.strings.agent_task_status_cancelled)
  }

  fun recordLine(record: String): String = when (record) {
    "approve" -> generalGetString(MR.strings.agent_task_approval_sent)
    "deny" -> generalGetString(MR.strings.agent_task_denial_sent)
    else -> generalGetString(MR.strings.agent_task_choice_sent)
  }
}

// MARK: - Status capsule

/**
 * The status capsule the messages home shows for a chat with an agent task: amber `Awaiting approval`, a
 * brand capsule with a breathing dot for `Running…`, green `Completed` — plus the `Zero retention` micro
 * badge beside it when the task claims it. One component for the chat row, the preview and the active bar.
 */
@Composable
fun PopopxAgentStatusPill(task: PopopxAgentTask, showsRetention: Boolean = false) {
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
    Row(
      Modifier
        .clip(CircleShape)
        .background(pillFill(task))
        .padding(horizontal = 8.dp, vertical = 2.dp),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
      if (task.status == PopopxAgentTask.Status.RUNNING) {
        val transition = rememberInfiniteTransition(label = "popopx-agent-breathing")
        val alpha by transition.animateFloat(
          initialValue = 1f,
          targetValue = 0.35f,
          animationSpec = infiniteRepeatable(tween(1100, easing = FastOutSlowInEasing), RepeatMode.Reverse),
          label = "popopx-agent-breathing-alpha"
        )
        Box(Modifier.size(6.dp).clip(CircleShape).background(PopopxBrand.copy(alpha = alpha)))
      }
      Text(PopopxAgentCopy.status(task.status), fontSize = 12.sp, color = pillInk(task), maxLines = 1)
    }
    if (showsRetention && task.retentionZero) {
      Row(
        Modifier
          .clip(CircleShape)
          .background(PopopxSeparator)
          .padding(horizontal = 8.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp)
      ) {
        Icon(painterResource(MR.images.ic_lock_filled), null, Modifier.size(9.dp), tint = MaterialTheme.colors.secondary)
        Text(PopopxAgentCopy.zeroRetention(), fontSize = 12.sp, color = MaterialTheme.colors.secondary, maxLines = 1)
      }
    }
  }
}

@Composable
private fun pillFill(task: PopopxAgentTask): Color = when (task.status) {
  PopopxAgentTask.Status.AWAITING_APPROVAL -> PopopxWarningFill
  PopopxAgentTask.Status.RUNNING -> PopopxBrand.copy(alpha = 0.12f)
  PopopxAgentTask.Status.COMPLETED -> PopopxSuccess.copy(alpha = 0.14f)
  PopopxAgentTask.Status.FAILED -> MaterialTheme.colors.error.copy(alpha = 0.12f)
  PopopxAgentTask.Status.CANCELLED -> PopopxSeparator
}

@Composable
private fun pillInk(task: PopopxAgentTask): Color = when (task.status) {
  PopopxAgentTask.Status.AWAITING_APPROVAL -> PopopxWarningInk
  PopopxAgentTask.Status.RUNNING -> PopopxBrand
  PopopxAgentTask.Status.COMPLETED -> PopopxSuccessInk
  PopopxAgentTask.Status.FAILED -> MaterialTheme.colors.error
  PopopxAgentTask.Status.CANCELLED -> MaterialTheme.colors.secondary
}

// MARK: - Derivation

/** One chat with a live agent task, as the messages home needs it. */
data class PopopxAgentChatTask(val chat: Chat, val task: PopopxAgentTask)

/**
 * Derives task state from the chats the model already holds — read-only, no extra state. Both the
 * active-tasks bar and the row pill read through here, so the two places that answer "is this chat
 * busy" cannot disagree about which message counts.
 */
object PopopxAgentTaskScan {
  /** The newest task card in a chat; the first hit scanning backwards supersedes an earlier card. */
  fun latestTask(chat: Chat): PopopxAgentTask? {
    val items = chat.chatItems
    for (index in items.indices.reversed()) {
      val text = items[index].content.msgContent?.text ?: continue
      if (!text.contains(PopopxAgentTaskWire.MARKER)) continue
      PopopxAgentTaskWire.parseVisibleCard(text)?.let { return it }
    }
    return null
  }

  /** What the chat row's capsule shows; a failed or cancelled task is not "alive", so it gets none. */
  fun pillTask(chat: Chat): PopopxAgentTask? {
    val task = latestTask(chat) ?: return null
    return when (task.status) {
      PopopxAgentTask.Status.RUNNING,
      PopopxAgentTask.Status.AWAITING_APPROVAL,
      PopopxAgentTask.Status.COMPLETED -> task
      else -> null
    }
  }

  /** Chats with work in flight, in list order, for the bar above the conversations. */
  fun activeTasks(chats: List<Chat>): List<PopopxAgentChatTask> = chats.mapNotNull { chat ->
    val task = latestTask(chat) ?: return@mapNotNull null
    if (!task.isActive) null else PopopxAgentChatTask(chat, task)
  }
}

// MARK: - Receipt signer and journal

/**
 * Mints one `popopx.agent.receipt.v1` envelope for a tap on an agent card. The seed lives in the eco
 * secret store beside the other device-only secrets, so the emergency wipe removes it with the journal.
 * A seed that cannot be persisted yields no receipt at all: a key that changes every launch would turn
 * "approved" into "unknown signer" with no visible symptom here.
 */
internal object PopopxAgentReceiptSigner {
  private const val ACCOUNT = "agent.receipt.key"
  private const val SEED_BYTES = 32

  fun make(
    taskId: String,
    decision: PopopxAgentReceiptWire.Decision,
    choiceId: String = ""
  ): PopopxAgentReceipt? {
    val seed = seed() ?: return null
    // ISO 8601 UTC at second precision (`2026-11-28T10:00:00Z`) — the shape the wire documents, and the
    // shape `Instant.toString()` prints when the fraction is zero.
    val at = Instant.fromEpochSeconds(Clock.System.now().epochSeconds).toString()
    return PopopxAgentReceiptWire.make(taskId, decision, choiceId, at, seed)
  }

  private fun seed(): ByteArray? {
    PopopxEcoSecrets.read(ACCOUNT)?.takeIf { it.size == SEED_BYTES }?.let { return it }
    val fresh = Random.nextBytes(SEED_BYTES)
    return if (PopopxEcoSecrets.write(fresh, ACCOUNT)) fresh else null
  }
}

/**
 * The one answer per task id, persisted so a card re-read from history shows the same spent state.
 * Values are `approve`, `deny`, or `choose:<id>`; bounded to 200 entries, oldest evicted first (which
 * only makes an ancient card answerable again in the UI — the agent side refuses a second receipt for
 * the same task anyway).
 */
internal object PopopxAgentReceiptJournal {
  private const val ACCOUNT = "agent.receipt.journal"
  private const val LIMIT = 200

  fun record(taskId: String): String? = map()[taskId]

  fun put(line: String, taskId: String) {
    val all = LinkedHashMap(map())
    all.remove(taskId)
    all[taskId] = line
    while (all.size > LIMIT) {
      all.remove(all.keys.first())
    }
    val text = all.entries.joinToString("\n") { "${it.key}\t${it.value}" }
    PopopxEcoSecrets.write(text.encodeToByteArray(), ACCOUNT)
  }

  fun line(decision: PopopxAgentReceiptWire.Decision, choiceId: String): String = when (decision) {
    PopopxAgentReceiptWire.Decision.APPROVE -> "approve"
    PopopxAgentReceiptWire.Decision.DENY -> "deny"
    PopopxAgentReceiptWire.Decision.CHOOSE -> "choose:$choiceId"
  }

  private fun map(): Map<String, String> {
    val text = PopopxEcoSecrets.read(ACCOUNT)?.decodeToString() ?: return emptyMap()
    val result = LinkedHashMap<String, String>()
    for (line in text.lineSequence()) {
      val tab = line.indexOf('\t')
      if (tab <= 0 || tab == line.length - 1) continue
      result[line.substring(0, tab)] = line.substring(tab + 1)
    }
    return result
  }
}

/** Signs and sends one answer through the single outbound gate. */
object PopopxAgentReceiptResponder {
  suspend fun send(
    taskId: String,
    decision: PopopxAgentReceiptWire.Decision,
    choiceId: String,
    contactId: Long
  ): Boolean {
    val receipt = PopopxAgentReceiptSigner.make(taskId, decision, choiceId) ?: return false
    return PopopxSilentSignalingRouter.shared.sendAgentReceipt(PopopxAgentReceiptWire.wireText(receipt), contactId)
  }
}

// MARK: - Active agent bar

/**
 * The collapsible bar above the conversation list. Collapsed it states the most urgent fact — how many
 * tasks wait on the user, or how far the running one has got; expanded it lists every chat with work in
 * flight and each row opens that conversation, where the full card offers its buttons. Hidden entirely
 * when nothing is active: the list only inserts it when the derived task list is non-empty.
 */
@Composable
fun PopopxActiveAgentBar(tasks: List<PopopxAgentChatTask>, onOpen: (Chat) -> Unit) {
  var expanded by remember { mutableStateOf(false) }
  val shape = RoundedCornerShape(PopopxRadiusCard)
  Column(
    Modifier
      .fillMaxWidth()
      .clip(shape)
      .background(PopopxSurface)
      .border(0.5.dp, PopopxHairlineInner, shape)
  ) {
    Row(
      Modifier
        .fillMaxWidth()
        .heightIn(min = 44.dp)
        .clickable { expanded = !expanded }
        .padding(horizontal = 16.dp),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
      Icon(painterResource(MR.images.ic_bolt_filled), null, Modifier.size(14.dp), tint = PopopxBrand)
      Text(
        summary(tasks),
        fontSize = 13.sp,
        color = MaterialTheme.colors.onBackground,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.weight(1f)
      )
      Icon(
        painterResource(if (expanded) MR.images.ic_arrow_drop_up else MR.images.ic_arrow_drop_down),
        null,
        Modifier.size(18.dp),
        tint = MaterialTheme.colors.secondary
      )
    }
    if (expanded) {
      tasks.forEach { entry ->
        Divider(color = PopopxSeparator, thickness = 0.5.dp)
        Row(
          Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clickable { onOpen(entry.chat) }
            .padding(horizontal = 16.dp, vertical = 8.dp),
          verticalAlignment = Alignment.CenterVertically,
          horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
          Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
              entry.chat.chatInfo.displayName,
              fontSize = 13.sp,
              color = MaterialTheme.colors.onBackground,
              maxLines = 1,
              overflow = TextOverflow.Ellipsis
            )
            Text(
              entry.task.title,
              fontSize = 12.sp,
              color = MaterialTheme.colors.secondary,
              maxLines = 1,
              overflow = TextOverflow.Ellipsis
            )
          }
          PopopxAgentStatusPill(entry.task)
          Icon(
            painterResource(MR.images.ic_arrow_forward_ios),
            null,
            Modifier.size(12.dp),
            tint = MaterialTheme.colors.secondary
          )
        }
      }
    }
  }
}

/** One line, most urgent fact first: approvals outrank a percentage, because a task waiting on the user
 * is the only one that cannot finish without them. */
private fun summary(tasks: List<PopopxAgentChatTask>): String {
  val awaiting = tasks.count { it.task.status == PopopxAgentTask.Status.AWAITING_APPROVAL }
  if (awaiting > 0) return PopopxAgentCopy.awaitingCount(awaiting)
  tasks.firstNotNullOfOrNull { it.task.percent }?.let { return PopopxAgentCopy.workingPercent(it) }
  return PopopxAgentCopy.working()
}
