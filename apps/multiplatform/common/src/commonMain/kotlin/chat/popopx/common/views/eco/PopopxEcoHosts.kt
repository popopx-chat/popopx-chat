package chat.popopx.common.views.eco

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.Button
import androidx.compose.material.MaterialTheme
import androidx.compose.material.OutlinedTextField
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.eco.PopopxEcoChannelPageRequest
import chat.popopx.common.eco.PopopxEcoRuntime
import chat.popopx.common.eco.PopopxChannelKeyRotation
import chat.popopx.common.eco.PopopxChannelKeyState
import chat.popopx.common.eco.PopopxH5Launcher
import chat.popopx.common.eco.PopopxH5Request
import chat.popopx.common.platform.appPlatform
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import kotlinx.coroutines.launch

// The two hosts the eco module needs and iOS gets from a navigation stack.
//
// iOS presents the signed page as a sheet it owns (PopopxH5Launcher.swift:280) and pushes
// ChannelKeyManagementView for a channel. Android has one place where a value becomes a screen without a
// stack of its own: `ModalManager`. Both hosts therefore watch one observable value each and render it as a
// modal — and both values are Compose state precisely so a tap cannot report success while nothing opened.
//
// Mounted once, on the Android shell, not inside the chat: an H5 request can be raised from a chat and a
// channel request from a chat or from the Discover page, and the surface that draws them has to be one that
// stays composed while the page is up.

/** Mount once on the Android shell: the signed service page and the channel-key page. */
@Composable
fun PopopxEcoHosts() {
  if (!appPlatform.isAndroid) return
  PopopxEcoH5Host()
  PopopxEcoChannelPageHost()
}

/**
 * The signed page. The URL is snapshotted when the modal is built, as iOS's `PopopxH5Sheet` does, so a
 * dismissal that clears the launcher's request mid-animation cannot swap the page out from under the closing
 * sheet.
 *
 * The signature is spent in `onDispose`, not in a close button: the button, the system back gesture and
 * `ModalManager.closeModals()` all end this composition, and only the composition's death is a guarantee. A
 * signature this device still holds and nobody can see is a credential with a clock running on it.
 */
@Composable
private fun PopopxEcoH5Host() {
  val launcher = PopopxH5Launcher.shared
  LaunchedEffect(launcher) {
    snapshotFlow { launcher.request }.collect { request: PopopxH5Request? ->
      val url = request?.url ?: return@collect
      ModalManager.start.showModalCloseable(cardScreen = true) { close ->
        PopopxEcoH5Sheet(url)
      }
    }
  }
}

@Composable
private fun PopopxEcoH5Sheet(url: String) {
  DisposableEffect(Unit) {
    onDispose { PopopxH5Launcher.shared.close() }
  }
  Column(Modifier.fillMaxSize().background(MaterialTheme.colors.background)) {
    Text(
      generalGetString(MR.strings.eco_h5_heading),
      Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 4.dp),
      fontSize = 16.sp,
      color = MaterialTheme.colors.onBackground
    )
    PopopxEcoWebView(url, Modifier.fillMaxWidth().weight(1f))
  }
}

/**
 * The channel-key page, raised by `open_channel` on a card button or a menu item. The request is taken (not
 * merely read) as it is observed: it is a one-shot, and a value left behind would re-open the page on the
 * next recomposition.
 */
@Composable
private fun PopopxEcoChannelPageHost() {
  val router = PopopxEcoRuntime.router
  LaunchedEffect(router) {
    snapshotFlow { router.channelPageRequest }.collect { pending ->
      if (pending != null) {
        val request = router.takeChannelPageRequest()
        if (request != null) {
          ModalManager.start.showModalCloseable(cardScreen = true) { close ->
            PopopxEcoChannelKeysPage(request)
          }
        }
      }
    }
  }
}

/**
 * The page iOS builds as `ChannelKeyManagementView`, reduced to the two actions this port's core actually
 * answers: `importPublicURI`, and the `::CB::rotate:<channelId>` request
 * (`PopopxChannelKeyRotation.rotationRequestText`), which asks the issuing account for a new epoch because
 * this device holds no channel identity private key and cannot sign one itself.
 *
 * There is no revoke control. iOS's per-row revoke (its deviation note about `removeChannel` is the same
 * reasoning in reverse) has no counterpart in `PopopxChannelKeyRotation` — the Kotlin port exposes no revoke
 * API — and a button that reported success while the key stayed usable would be worse than no button. The
 * epoch list is read-only history, which is what it honestly is.
 */
@Composable
private fun PopopxEcoChannelKeysPage(request: PopopxEcoChannelPageRequest) {
  val scope = rememberCoroutineScope()
  val rotation = PopopxChannelKeyRotation.shared
  // `channels` is a plain list, so the page re-reads it by key after a write instead of pretending it is
  // observable. A rotation lands later, on an inbound key frame, and is seen the next time the page opens.
  var refresh by remember { mutableStateOf(0) }
  var uriText by remember { mutableStateOf(request.importURI ?: "") }
  var receipt by remember { mutableStateOf<String?>(null) }
  val channels = remember(refresh) { rotation.channels }
  val selectedId = request.channelId

  Column(
    Modifier.fillMaxSize().background(MaterialTheme.colors.background).verticalScroll(rememberScrollState()).padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(12.dp)
  ) {
    Text(generalGetString(MR.strings.eco_keys_title), fontSize = 16.sp, color = MaterialTheme.colors.onBackground)
    if (channels.isEmpty()) {
      Text(generalGetString(MR.strings.eco_keys_none), fontSize = 14.sp, color = MaterialTheme.colors.secondary)
    } else {
      channels.forEach { state ->
        PopopxEcoChannelKeyRow(state, selected = selectedId == null || selectedId == state.channelId) {
          val issuer = state.issuerContactId
          if (issuer != null) {
            scope.launch {
              val outcome = PopopxEcoRuntime.router.sendCallback(rotation.rotationRequestText(state.channelId), issuer)
              receipt = generalGetString(if (outcome.wasSent) MR.strings.eco_card_sent else MR.strings.eco_card_failed)
            }
          }
        }
      }
    }

    OutlinedTextField(
      value = uriText,
      onValueChange = { uriText = it },
      label = { Text(generalGetString(MR.strings.eco_keys_import)) },
      placeholder = { Text(generalGetString(MR.strings.eco_keys_import_hint), fontSize = 13.sp) },
      modifier = Modifier.fillMaxWidth()
    )
    Button(onClick = {
      val stored = uriText.isNotBlank() && rotation.importPublicURI(uriText.trim())
      receipt = generalGetString(if (stored) MR.strings.eco_keys_stored else MR.strings.eco_keys_bad_uri)
      if (stored) {
        uriText = ""
        refresh += 1
      }
    }) {
      Text(generalGetString(MR.strings.eco_keys_add), fontSize = 15.sp)
    }
    val shown = receipt
    if (shown != null) Text(shown, fontSize = 13.sp, color = MaterialTheme.colors.secondary)
  }
}

@Composable
private fun PopopxEcoChannelKeyRow(state: PopopxChannelKeyState, selected: Boolean, onRotate: () -> Unit) {
  val shape = RoundedCornerShape(12.dp)
  val canRotate = state.issuerContactId != null
  Column(
    Modifier.fillMaxWidth().clip(shape).background(MaterialTheme.colors.surface)
      .border(1.dp, MaterialTheme.colors.onSurface.copy(alpha = if (selected) 0.35f else 0.12f), shape)
      .padding(12.dp),
    verticalArrangement = Arrangement.spacedBy(6.dp)
  ) {
    Text(state.channelId, fontSize = 14.sp, color = MaterialTheme.colors.onSurface)
    Text(
      String.format(generalGetString(MR.strings.eco_keys_active_epoch_format), state.currentEpoch),
      fontSize = 13.sp,
      color = MaterialTheme.colors.secondary
    )
    state.epochs.forEach { epoch ->
      Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text("#${epoch.epoch}", fontSize = 13.sp, color = MaterialTheme.colors.onSurface.copy(alpha = 0.7f), modifier = Modifier.weight(1f))
        if (epoch.revoked) Text(generalGetString(MR.strings.eco_keys_revoked), fontSize = 12.sp, color = MaterialTheme.colors.error)
      }
    }
    Text(
      generalGetString(MR.strings.eco_keys_rotate),
      fontSize = 15.sp,
      color = if (canRotate) MaterialTheme.colors.primary else MaterialTheme.colors.onSurface.copy(alpha = 0.35f),
      modifier = Modifier.clickable(enabled = canRotate, onClick = onRotate)
    )
  }
}
