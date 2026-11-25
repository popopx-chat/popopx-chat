package chat.popopx.common.views.localauth

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import chat.popopx.common.duress.PopopxPanicWipeArming
import chat.popopx.common.duress.PopopxPanicWipeManager
import chat.popopx.common.duress.popopxAppPanicWipeHost
import chat.popopx.common.platform.Log
import chat.popopx.common.platform.TAG
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.common.views.helpers.withLongRunningApi
import chat.popopx.res.*

/**
 * The UI half of the three-tap emergency wipe: the counter, the confirmation, and the run.
 *
 * The state machine and the six steps are iOS's (`PopopxPanicWipeArming` / `PopopxPanicWipeManager`); this class is
 * only what a Compose surface needs to observe. It owns nothing that [arming] also owns: [isConfirming] is re-read
 * *from* the machine after every tap instead of being set alongside it, because a separately tracked flag is how a
 * sheet outlives the sequence that raised it — and the fourth tap, which the machine makes mean "never mind", would
 * otherwise leave an armed sheet with no arming behind it.
 */
class PopopxPanicWipeUiState {
  val arming = PopopxPanicWipeArming()
  val isConfirming = mutableStateOf(false)
  private var wiping = false

  fun tap() {
    if (wiping) return
    arming.tap()
    isConfirming.value = arming.isAwaitingConfirmation
  }

  fun cancel() {
    arming.resolveConfirmation()
    isConfirming.value = false
  }

  /**
   * The destructive button. Consent is a deadline, not a countdown: nothing ticks, so validity is asked for at the
   * moment of the press and an expired sheet behaves exactly like cancel.
   */
  fun confirm() {
    if (!arming.confirmationIsStillValid()) {
      cancel()
      return
    }
    cancel()
    wiping = true
    withLongRunningApi {
      // `includeApplicationDatabase` is not passed: the interface cannot ask for the chat database (ruling 2, and
      // `PopopxPanicWipeManager.INTERFACE_OPT_IN_TO_DATABASE_ERASE`). This is the path that does terminate.
      PopopxPanicWipeManager(popopxAppPanicWipeHost(), log = { Log.d(TAG, "panic wipe: $it") }).execute()
    }
  }
}

/**
 * The sheet the third tap raises, drawn inline over the surface that armed it.
 *
 * iOS uses a system alert (`PopopxPanicWipeGate`, PanicWipeManager.swift:714-738); the Android equivalent would be a
 * manager-stacked dialog, which is how a confirmation ends up outliving the screen that asked for it. The sentence is
 * this build's truth rather than iOS's [PopopxPanicWipeManager.confirmationMessage]: two of those six clauses name
 * Bluetooth and the mesh files, and a consent line for an irreversible action may not promise a step this device does
 * not perform. The ranks, the journal and `confirmationMessage` keep iOS's copy, so the two platforms' wipe records
 * still line up; the wording difference is recorded in the commit body.
 */
@Composable
fun PopopxPanicWipeConfirm(state: PopopxPanicWipeUiState) {
  if (!state.isConfirming.value) return
  Box(
    Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.72f)),
    contentAlignment = Alignment.Center
  ) {
    Column(
      Modifier
        .widthIn(max = 360.dp)
        .padding(horizontal = 24.dp)
        .clip(RoundedCornerShape(16.dp))
        .background(MaterialTheme.colors.background)
        .padding(20.dp),
      horizontalAlignment = Alignment.CenterHorizontally
    ) {
      Text(generalGetString(MR.strings.panic_wipe_title), style = MaterialTheme.typography.h3, textAlign = TextAlign.Center)
      Spacer(Modifier.height(12.dp))
      Text(generalGetString(MR.strings.panic_wipe_body), style = MaterialTheme.typography.body2, textAlign = TextAlign.Center)
      Spacer(Modifier.height(22.dp))
      Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
        PanicWipeButton(generalGetString(MR.strings.cancel_verb), MaterialTheme.colors.primary) { state.cancel() }
        PanicWipeButton(generalGetString(MR.strings.panic_wipe_erase), MaterialTheme.colors.error) { state.confirm() }
      }
    }
  }
}

@Composable
private fun PanicWipeButton(label: String, color: Color, action: () -> Unit) {
  Text(
    label,
    color = color,
    modifier = Modifier
      .clickable(onClickLabel = label, role = Role.Button) { action() }
      .padding(8.dp)
  )
}
