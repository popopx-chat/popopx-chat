package chat.popopx.common.views.chatlist

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import chat.popopx.common.cfgsec.PopopxServerConfigStore
import chat.popopx.common.cfgsec.PopopxServerConfigVerdict
import chat.popopx.common.ui.theme.DEFAULT_PADDING
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/**
 * The signed server-cluster status, as one read-only line inside the servers summary.
 *
 * Android-only by its call site. iOS is silent end to end on this path — zero alerts, zero banners — and that is the
 * property being preserved here: the whole point of a signed roster is that an operator can move a device without
 * the device advertising that it was moved. This row is something the user opens deliberately, on the screen that
 * already lists servers; it is not a notice.
 *
 * It shows only what the store actually keeps. The plan also asked for "source" and "probe", and neither has a
 * durable field: which conversation a frame arrived in is recorded on the staged frame and the receipt, both of
 * which are consumed when the update is promoted, and the probe's outcome *is* the verdict — verified means a host
 * answered, rolled back means none did, pending means the window is still open. Printing two more numbers would
 * mean inventing where they came from, so the verdict carries the probe and the introduced-URI count carries the
 * source. Recorded in the commit body.
 */
@Composable
fun PopopxServerConfigStatusRow() {
  val store = PopopxServerConfigStore.shared
  // Re-read rather than observe: the store writes to `settings` from the signal handler's coroutine, and nothing in
  // that path is a Compose state. A slow poll is the honest way to show it without making the handler know the UI
  // exists — a handler that had to notify a view would be a handler with a reason to fail because of the view.
  var generation by remember { mutableStateOf(store.floors.lastOrNull()) }
  var verdict by remember { mutableStateOf(store.verdict) }
  var introduced by remember { mutableStateOf(store.introducedURIs.size) }
  LaunchedEffect(Unit) {
    while (isActive) {
      generation = store.floors.lastOrNull()
      verdict = store.verdict
      introduced = store.introducedURIs.size
      delay(5_000)
    }
  }
  // Copied into a local: `generation` is a delegated property, so the null check below cannot smart-cast it, and
  // re-reading the state between the check and the use would be a race with the poll.
  val current = generation
  Text(
    if (current == null) stringResource(MR.strings.server_config_status_none)
    else stringResource(
      MR.strings.server_config_status,
      verdictWords(verdict),
      current.kid,
      current.seq,
      introduced,
    ),
    style = MaterialTheme.typography.caption,
    color = MaterialTheme.colors.secondary,
    textAlign = TextAlign.Start,
    modifier = Modifier.fillMaxWidth().padding(horizontal = DEFAULT_PADDING, vertical = DEFAULT_PADDING / 2)
  )
}

/** The one place the verdict becomes a sentence, so the row cannot disagree with itself. */
@Composable
private fun verdictWords(verdict: PopopxServerConfigVerdict?): String = stringResource(
  when (verdict) {
    PopopxServerConfigVerdict.PENDING -> MR.strings.server_config_status_pending
    PopopxServerConfigVerdict.VERIFIED -> MR.strings.server_config_status_verified
    PopopxServerConfigVerdict.ROLLED_BACK -> MR.strings.server_config_status_rolled_back
    null -> MR.strings.server_config_status_never
  }
)
