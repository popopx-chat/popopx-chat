package chat.popopx.common.views.cabin

import androidx.compose.foundation.layout.*
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import chat.popopx.common.mesh.PopopxMeshKillSwitch
import chat.popopx.common.mesh.PopopxMeshPeer
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.ui.components.PopopxDivider
import chat.popopx.common.ui.components.PopopxPickerRow
import chat.popopx.common.ui.components.PopopxSecondaryButton
import chat.popopx.common.ui.components.PopopxSection
import chat.popopx.common.ui.theme.PopopxAlpha
import chat.popopx.common.ui.theme.PopopxMesh
import chat.popopx.common.ui.theme.PopopxTypeScale
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.delay

// The "Local encrypted channels" screen and its pending-invitations sheet, ported from
// `PopopxCabinChannelsView` + `PopopxCabinPairingRequestsSheet`
// (`apps/ios/Shared/Features/Cabin/PopopxCabinView.swift:2211-2325`).
//
// What a channel is here: a peer this device actually holds a Noise session with, which is what the
// engine can prove (`channelMeshPublicKeyHexes`). iOS also counts binding-table rows and module 3's
// paired state; this build keeps neither, so the live session is the whole criterion and the footnote
// says so rather than quoting a table that does not exist.
//
// Deliberately absent, and said rather than faked: the sheet has no Accept/Decline buttons. The engine
// decrypts the sealed pairing invitation and it is listed here with the time it arrived, but there is no
// contact-binding layer on this platform for a decision to land on, so the sheet states that instead of
// offering two buttons that would write nowhere. The third channels row ("Offline group chat") stays on
// the root card as iOS draws it and reads "Not in this build", because GROUP_STATE/GROUP_MESSAGE frames
// are relayed but not read here.

fun showPopopxCabinChannels() {
  ModalManager.start.showModalCloseable(cardScreen = true) {
    PopopxCabinChannelsView()
  }
}

@Composable
private fun PopopxCabinChannelsView() {
  val store = PopopxCabinStore.shared
  val fuse = PopopxMeshKillSwitch.shared

  val enabled by fuse.isEnabled.collectAsState()
  val peers by store.peers.collectAsState()
  val channels by store.channels.collectAsState()
  val pending by store.pendingPairings.collectAsState()

  var nowMillis by remember { mutableStateOf(System.currentTimeMillis()) }
  LaunchedEffect(Unit) {
    while (true) {
      delay(2_000)
      nowMillis = System.currentTimeMillis()
    }
  }

  // The session table lives in the engine, and this screen may be the first reader after a mount.
  LaunchedEffect(Unit) { fuse.engine()?.let { store.seed(it) } }
  LaunchedEffect(enabled) {
    if (!enabled) store.clearChannels()
  }

  val shown = if (enabled) peers else emptyList()
  val channelPeers = shown.filter { peer -> peer.meshPublicKey?.meshHex()?.let { it in channels } == true }
  val strangerPeers = shown.filter { peer ->
    val key = peer.meshPublicKey?.meshHex()
    key != null && key !in channels
  }

  AppBarTitle(stringResource(MR.strings.cabin_channels_row))
  ColumnWithScrollBar(Modifier.fillMaxSize()) {
    Column(
      Modifier
        .padding(horizontal = 16.dp)
        .padding(top = 8.dp, bottom = 48.dp),
      verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
      PopopxSection(
        title = stringResource(MR.strings.cabin_channel_list_title, channelPeers.size),
        footnote = stringResource(
          if (enabled) MR.strings.cabin_channel_footnote else MR.strings.cabin_channel_footnote_off
        ),
      ) {
        if (channelPeers.isEmpty()) {
          Text(
            stringResource(
              if (enabled) MR.strings.cabin_channel_empty else MR.strings.cabin_channel_empty_off
            ),
            style = PopopxTypeScale.subheadline,
            color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
          )
        } else {
          ChannelRows(channelPeers, nowMillis)
        }
      }

      if (enabled && strangerPeers.isNotEmpty()) {
        PopopxSection(
          title = stringResource(MR.strings.cabin_stranger_title, strangerPeers.size),
          footnote = stringResource(MR.strings.cabin_stranger_footnote),
        ) {
          ChannelRows(strangerPeers, nowMillis)
        }
      }

      PopopxSection(
        title = stringResource(MR.strings.cabin_pending_title),
        footnote = stringResource(MR.strings.cabin_pending_footnote),
      ) {
        PopopxPickerRow(
          label = stringResource(MR.strings.cabin_pending_row),
          value = if (pending.isEmpty()) {
            stringResource(MR.strings.cabin_pending_none)
          } else {
            stringResource(MR.strings.cabin_pending_waiting, pending.size)
          },
          icon = MR.images.ic_mail_filled,
          onClick = { showPopopxCabinPendingPairings() },
          tint = PopopxMesh,
        )
      }
    }
  }
}

@Composable
private fun ChannelRows(peers: List<PopopxMeshPeer>, nowMillis: Long) {
  peers.forEachIndexed { index, peer ->
    PopopxCabinNodeRow(
      peer = peer,
      reachable = cabinIsReachable(peer, nowMillis),
      nowMillis = nowMillis,
      onOpenChat = { peer.meshPublicKey?.meshHex()?.let { showPopopxCabinPrivateChat(it) } },
    )
    if (index < peers.size - 1) PopopxDivider()
  }
}

private fun showPopopxCabinPendingPairings() {
  ModalManager.start.showModalCloseable(cardScreen = true) { close ->
    PopopxCabinPendingPairingsView(close)
  }
}

@Composable
private fun PopopxCabinPendingPairingsView(close: () -> Unit) {
  val store = PopopxCabinStore.shared
  val peers by store.peers.collectAsState()
  val pending by store.pendingPairings.collectAsState()

  var nowMillis by remember { mutableStateOf(System.currentTimeMillis()) }
  LaunchedEffect(Unit) {
    while (true) {
      delay(2_000)
      nowMillis = System.currentTimeMillis()
    }
  }

  AppBarTitle(stringResource(MR.strings.cabin_pending_sheet_title))
  ColumnWithScrollBar(Modifier.fillMaxSize()) {
    Column(
      Modifier
        .padding(horizontal = 16.dp)
        .padding(top = 8.dp, bottom = 48.dp),
      verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
      Text(
        stringResource(MR.strings.cabin_pending_sheet_subtitle),
        style = PopopxTypeScale.subheadline,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      )
      if (pending.isEmpty()) {
        Text(
          stringResource(MR.strings.cabin_pending_sheet_empty),
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        )
      } else {
        pending.forEach { request ->
          val known = peers.firstOrNull { it.meshPublicKey?.meshHex() == request.meshPublicKeyHex }
          PopopxSection(
            title = cabinPeerLabel(known?.nickname, request.meshPublicKeyHex, request.meshPublicKeyHex),
            footnote = stringResource(
              MR.strings.cabin_pending_since,
              cabinSince(request.receivedAtMillis, nowMillis),
            ),
          ) {
            Text(
              stringResource(MR.strings.cabin_pending_invite_hint),
              style = PopopxTypeScale.subheadline,
              color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
            )
          }
        }
      }
      PopopxSecondaryButton(
        text = stringResource(MR.strings.cabin_close),
        modifier = Modifier.fillMaxWidth(),
        onClick = close,
      )
    }
  }
}