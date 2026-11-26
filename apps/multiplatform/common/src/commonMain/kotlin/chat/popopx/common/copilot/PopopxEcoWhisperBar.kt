package chat.popopx.common.copilot

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.Divider
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.ui.theme.DEFAULT_PADDING
import chat.popopx.common.ui.theme.DEFAULT_PADDING_HALF
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.common.views.helpers.DefaultBasicTextField
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.launch

/**
 * The Private Whisper Bar.
 *
 * It sits above the user's own message input, and it is not a second way to talk to the contact. That
 * is a property of the signature, not of an internal rule: this composable takes a **local state key**
 * (`sessionKey`, which is a chat id or the string "discover"), the draft text as a value, and a
 * function that reads recent message text. There is no `Chat`, no `ChatRef`, no recipient, no
 * `apiSendMessages` and no `ChatModel` in scope, so there is nothing here that could be called to
 * send. The assistant's output goes into the bar's own composable state and nowhere else.
 *
 * Three things are separate and stay separate:
 * - the bar's own text, which is always processed (it is the user typing to the phone, and
 *   [PopopxEcoAssistantState.contextWindow] returns only it while the observer is `OFF`),
 * - the summon, which is `@助理` or a slash token in the **normal** input and buys exactly one turn
 *   with the last five messages,
 * - the per-session real-time assist, which is the only thing that keeps reading after a turn.
 *
 * On a platform that installed no glue, [PopopxEcoAssistantHost.session] is null and this renders
 * nothing at all — desktop, and an apk without calendar access, show no bar rather than a dead one.
 */
@Composable
fun PopopxEcoWhisperBar(
  sessionKey: String,
  draftText: String,
  history: () -> List<String> = { emptyList() },
) {
  val session = remember(sessionKey) { PopopxEcoAssistantHost.session(sessionKey) } ?: return
  val scope = rememberCoroutineScope()
  val text = rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
  // One summon per distinct draft. Without this, every keystroke after "@助理" would start a new turn
  // and re-read the window, which is a busy loop over a live calendar.
  val lastSummoned = remember { mutableStateOf<String?>(null) }

  // The permission state is read once per appearance rather than polled: `ask` refreshes it too, and a
  // grant from the system dialog arrives through the platform slot's callback.
  LaunchedEffect(session) { session.refreshPermissions() }

  LaunchedEffect(draftText) {
    val summoned = PopopxEcoCommand.isSummon(draftText) || PopopxEcoCommand.parse(draftText) != null
    if (summoned && lastSummoned.value != draftText) {
      lastSummoned.value = draftText
      session.summon()
      session.ask(draftText, history())
    }
  }

  Column(Modifier.fillMaxWidth()) {
    // 「绿色指示线」 — present only while the real-time assist is on for this session, so the line is
    // evidence of a mode the user chose rather than a decoration.
    if (session.liveIndicator) {
      Box(Modifier.fillMaxWidth().height(2.dp).background(WhisperGreen))
    }
    Divider()
    Row(
      Modifier.fillMaxWidth().padding(horizontal = DEFAULT_PADDING_HALF, vertical = 4.dp),
      verticalAlignment = Alignment.CenterVertically
    ) {
      DefaultBasicTextField(
        modifier = Modifier
          .weight(1f)
          .background(MaterialTheme.colors.background, shape = RoundedCornerShape(10.dp))
          .padding(horizontal = 10.dp, vertical = 6.dp),
        state = text,
        placeholder = {
          Text(
            stringResource(MR.strings.copilot_bar_placeholder),
            color = MaterialTheme.colors.secondary,
            fontSize = MaterialTheme.typography.body2.fontSize,
          )
        },
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = {
          val typed = text.value.text
          if (typed.isNotBlank()) scope.launch { session.ask(typed, history()) }
        }),
        onValueChange = { text.value = it },
      )
      Spacer(Modifier.width(8.dp))
      Text(
        stringResource(if (session.working) MR.strings.copilot_working else MR.strings.copilot_ask),
        fontSize = 13.sp,
        color = if (session.working) MaterialTheme.colors.secondary else MaterialTheme.colors.primary,
        modifier = Modifier
          .clip(RoundedCornerShape(8.dp))
          .clickable(enabled = !session.working) {
            val typed = text.value.text
            if (typed.isNotBlank()) {
              text.value = TextFieldValue("")
              scope.launch { session.ask(typed, history()) }
            }
          }
          .padding(horizontal = 8.dp, vertical = 6.dp)
      )
    }
    PopopxEcoObserverControls(session)
    session.reply?.text?.takeIf { it.isNotBlank() }?.let { answer ->
      Text(
        answer,
        style = MaterialTheme.typography.body2,
        color = MaterialTheme.colors.onBackground,
        modifier = Modifier.padding(horizontal = DEFAULT_PADDING_HALF, vertical = 2.dp)
      )
    }
    session.notice?.let { notice ->
      Text(
        notice,
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary,
        modifier = Modifier.padding(horizontal = DEFAULT_PADDING_HALF, vertical = 2.dp)
      )
    }
    session.cards.forEach { pending ->
      PopopxEcoConfirmCard(
        pending = pending,
        onConfirm = { scope.launch { session.confirm(pending.id) } },
        onCancel = { session.dismiss(pending.id) },
      )
    }
    session.PermissionAffordance()
  }
}

/**
 * The two explicit controls, and the only code path in this feature that changes the observer mode.
 *
 * The switch is labelled with what it actually is — 「本机助理实时协助中 · 数据不出设备」 — and a
 * second tap on it turns the assist off, because [PopopxEcoAssistantState.toggleRealtime] is written
 * as a toggle for its own session key. Nothing else in the app calls either function.
 */
@Composable
private fun PopopxEcoObserverControls(session: PopopxEcoSession) {
  Column(Modifier.padding(horizontal = DEFAULT_PADDING_HALF, vertical = 2.dp)) {
    Row(
      Modifier
        .clip(RoundedCornerShape(8.dp))
        .clickable { session.toggleRealtime() }
        .padding(vertical = 4.dp),
      verticalAlignment = Alignment.CenterVertically
    ) {
      Box(
        Modifier
          .width(14.dp)
          .height(14.dp)
          .clip(RoundedCornerShape(7.dp))
          .background(if (session.liveIndicator) WhisperGreen else MaterialTheme.colors.background)
      ) {}
      Spacer(Modifier.width(8.dp))
      Text(
        stringResource(if (session.liveIndicator) MR.strings.copilot_live_on else MR.strings.copilot_live_off),
        fontSize = 12.sp,
        color = if (session.liveIndicator) WhisperGreen else MaterialTheme.colors.primary,
      )
    }
    Text(
      stringResource(if (session.liveIndicator) MR.strings.copilot_live_tap_stop else MR.strings.copilot_summon_hint),
      fontSize = 11.sp,
      color = MaterialTheme.colors.secondary,
      modifier = Modifier.padding(top = 2.dp)
    )
    if (session.liveIndicator) {
      Text(
        stringResource(MR.strings.copilot_turn_off_now),
        fontSize = 12.sp,
        color = MaterialTheme.colors.error,
        modifier = Modifier
          .clip(RoundedCornerShape(6.dp))
          .clickable { session.turnOff() }
          .padding(vertical = 4.dp)
      )
    }
  }
}

/**
 * The card, and the only way to a calendar write.
 *
 * [PopopxEcoProposal.description] and `whenText` are all the card is given, which is what keeps the
 * privacy promise visible: a reschedule or cancel proposal describes itself as "Move event 41" with
 * the store id, because the sanitizer dropped the title before the proposal existed. The confirm tap
 * calls [PopopxEcoAssistant.confirm] and nothing else; there is no path from this file to a calendar
 * insert that does not go through the gate's return value.
 */
@Composable
fun PopopxEcoConfirmCard(
  pending: PopopxEcoConfirmGate.Pending,
  onConfirm: () -> Unit,
  onCancel: () -> Unit,
) {
  Column(
    Modifier
      .fillMaxWidth()
      .padding(horizontal = DEFAULT_PADDING_HALF, vertical = 4.dp)
      .clip(RoundedCornerShape(10.dp))
      .background(MaterialTheme.colors.background)
      .padding(10.dp)
  ) {
    Text(
      generalGetString(MR.strings.copilot_confirm_title),
      fontSize = 11.sp,
      color = MaterialTheme.colors.secondary,
    )
    Text(
      pending.proposal.description,
      style = MaterialTheme.typography.body1,
      color = MaterialTheme.colors.onBackground,
      modifier = Modifier.padding(top = 2.dp)
    )
    if (pending.proposal.whenText.isNotBlank()) {
      Text(
        pending.proposal.whenText,
        fontSize = 12.sp,
        color = MaterialTheme.colors.primary,
        modifier = Modifier.padding(top = 2.dp)
      )
    }
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
      CardAction(
        text = generalGetString(MR.strings.copilot_confirm_write),
        color = MaterialTheme.colors.primary,
        modifier = Modifier.weight(1f),
        onClick = onConfirm,
      )
      Spacer(Modifier.width(8.dp))
      CardAction(
        text = generalGetString(MR.strings.copilot_cancel),
        color = MaterialTheme.colors.secondary,
        modifier = Modifier.weight(1f),
        onClick = onCancel,
      )
    }
  }
}

@Composable
private fun CardAction(text: String, color: Color, modifier: Modifier = Modifier, onClick: () -> Unit) {
  Box(
    modifier
      .clip(RoundedCornerShape(8.dp))
      .background(MaterialTheme.colors.background)
      .clickable(onClick = onClick)
      .padding(vertical = 8.dp),
    contentAlignment = Alignment.Center
  ) {
    Text(text, fontSize = 13.sp, color = color)
  }
}

/**
 * The Discover surface: 「发现 → 我的私人助理」.
 *
 * Same session machinery, no chat. `history` is the default reader, which returns nothing, so ambient
 * messages are not even reachable from here — the sheet only ever processes what is typed into it.
 */
@Composable
fun PopopxEcoAssistantSheet(close: () -> Unit) {
  ColumnWithScrollBar {
    AppBarTitle(generalGetString(MR.strings.copilot_sheet_title))
    Column(Modifier.padding(horizontal = DEFAULT_PADDING)) {
      Text(
        generalGetString(MR.strings.copilot_sheet_note),
        style = MaterialTheme.typography.body2,
        color = MaterialTheme.colors.secondary
      )
      PopopxEcoWhisperBar(sessionKey = DISCOVER_SESSION_KEY, draftText = "")
      Spacer(Modifier.height(DEFAULT_PADDING))
      Text(
        generalGetString(MR.strings.copilot_sheet_done),
        fontSize = 14.sp,
        color = MaterialTheme.colors.primary,
        modifier = Modifier.clickable { close() }.padding(vertical = 8.dp)
      )
    }
  }
}

/** Opens the assistant surface the same way the Discover service tiles open their sheet. */
fun showPopopxEcoAssistantSheet() {
  ModalManager.start.showModalCloseable(cardScreen = true) { close ->
    PopopxEcoAssistantSheet(close)
  }
}

/** The key for the discover-tab session: a local state name, not a chat and not a recipient. */
const val DISCOVER_SESSION_KEY = "discover.private-assistant"

/** The line above the input and the dot on the switch: shown only while a mode the user chose is on. */
private val WhisperGreen = Color(0xFF2E9E5B)
