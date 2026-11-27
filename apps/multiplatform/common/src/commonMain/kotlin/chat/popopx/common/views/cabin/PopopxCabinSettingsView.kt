package chat.popopx.common.views.cabin

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Surface
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import chat.popopx.common.mesh.PopopxBluetoothState
import chat.popopx.common.mesh.PopopxMeshConfig
import chat.popopx.common.mesh.PopopxMeshEventHub
import chat.popopx.common.mesh.PopopxMeshFusePhase
import chat.popopx.common.mesh.PopopxMeshIdentity
import chat.popopx.common.mesh.PopopxMeshKillSwitch
import chat.popopx.common.mesh.PopopxMeshSecretStore
import chat.popopx.common.mesh.PopopxMeshWipe
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.platform.platform
import chat.popopx.common.platform.showToast
import chat.popopx.common.platform.tmpDir
import chat.popopx.common.ui.components.PopopxDivider
import chat.popopx.common.ui.components.PopopxIconBadge
import chat.popopx.common.ui.components.PopopxPickerRow
import chat.popopx.common.ui.components.PopopxSecondaryButton
import chat.popopx.common.ui.components.PopopxSection
import chat.popopx.common.ui.components.PopopxSwitch
import chat.popopx.common.ui.theme.PopopxAlpha
import chat.popopx.common.ui.theme.PopopxMesh
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.ui.theme.PopopxRadiusControl
import chat.popopx.common.ui.theme.PopopxSize
import chat.popopx.common.ui.theme.PopopxTypeScale
import chat.popopx.common.views.helpers.AlertManager
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// The Cabin's settings centre, ported from `PopopxCabinMeshSettingsSheet`
// (`apps/ios/Shared/Features/Cabin/PopopxCabinView.swift:2342-2673`): three cards in the same order —
// the switch and the pairing policy, the node identity with the real runtime state, and the wipe.
//
// Declared absences, said rather than faked: this build keeps no pairing layer and no binding table, so
// the pairing-policy radios and the records page are rows that name what is absent instead of offering
// controls that would write nowhere; "Bound offline contacts" and "Messages queued for a link" show
// "Not in this build" for the same reason. The verification block has no "Verify" button because the
// phase is read live from the running process; the extra sentence says so instead of shipping a no-op
// button. Wipe semantics follow `clearOfflineIdentity()`: pull the switch first, then erase — the other
// order lets a still-running component write its state back after the erase has reported success.

fun showPopopxCabinSettings() {
  ModalManager.start.showModalCloseable(cardScreen = true) { close ->
    PopopxCabinSettingsView(close)
  }
}

@Composable
private fun PopopxCabinSettingsView(close: () -> Unit) {
  val store = PopopxCabinStore.shared
  val fuse = PopopxMeshKillSwitch.shared
  val uiScope = rememberCoroutineScope()

  val enabled by fuse.isEnabled.collectAsState()
  val phase by fuse.phase.collectAsState()
  val radio by store.radioState.collectAsState()
  val peers by store.peers.collectAsState()

  var nowMillis by remember { mutableStateOf(System.currentTimeMillis()) }
  LaunchedEffect(Unit) {
    while (true) {
      delay(2_000)
      nowMillis = System.currentTimeMillis()
    }
  }

  // The engine's key when one is mounted (a wipe mints a fresh in-memory key), otherwise the persisted
  // one; empty means "this device has never run Cabin" — the iOS empty-string reading, not "key lost".
  var localKeyHex by remember { mutableStateOf("") }
  LaunchedEffect(enabled) {
    localKeyHex = withContext(Dispatchers.Default) {
      fuse.engine()?.localMeshPublicKeyHex ?: persistedMeshKeyHex()
    }
  }

  val nodes = if (enabled) peers else emptyList()
  val inReach = nodes.filter { cabinIsReachable(it, nowMillis) }
  val relayedCount = inReach.count { !it.isDirect }
  val farthestHop = inReach.maxOfOrNull { it.hopCount } ?: 0
  val relayHopCap = PopopxMeshConfig.default.fragmentRelayTtlCap

  val busy = phase == PopopxMeshFusePhase.STARTING || phase == PopopxMeshFusePhase.STOPPING

  AppBarTitle(stringResource(MR.strings.cabin_settings_entry))
  ColumnWithScrollBar(Modifier.fillMaxSize()) {
    Column(
      Modifier
        .padding(horizontal = 16.dp)
        .padding(top = 8.dp, bottom = 48.dp),
      verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
      Text(
        stringResource(MR.strings.cabin_settings_subtitle),
        style = PopopxTypeScale.subheadline,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      )

      PopopxSection(
        title = stringResource(MR.strings.cabin_settings_card_switch),
        footnote = stringResource(MR.strings.cabin_settings_switch_footnote),
      ) {
        Row(
          Modifier.fillMaxWidth().heightIn(min = PopopxSize.control).padding(vertical = 8.dp),
          verticalAlignment = Alignment.CenterVertically,
        ) {
          Column(Modifier.weight(1f)) {
            Text(stringResource(MR.strings.cabin_switch), style = PopopxTypeScale.headline)
            Spacer(Modifier.height(2.dp))
            Text(
              stringResource(if (enabled) MR.strings.cabin_fuse_note_on else MR.strings.cabin_fuse_note_off),
              style = PopopxTypeScale.subheadline,
              color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
            )
          }
          Spacer(Modifier.width(12.dp))
          PopopxSwitch(
            checked = enabled,
            onCheckedChange = { next -> uiScope.launch { fuse.setEnabled(next) } },
            enabled = !busy,
          )
        }
        PopopxDivider()
        Row(
          Modifier.fillMaxWidth().heightIn(min = PopopxSize.control).padding(vertical = 8.dp),
          verticalAlignment = Alignment.CenterVertically,
        ) {
          Text(
            stringResource(MR.strings.cabin_settings_pairing),
            style = PopopxTypeScale.body.copy(fontWeight = FontWeight.SemiBold),
            modifier = Modifier.weight(1f),
          )
          Spacer(Modifier.width(8.dp))
          Text(
            stringResource(MR.strings.cabin_settings_fact_absent),
            style = PopopxTypeScale.subheadline,
            color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
          )
        }
        Text(
          stringResource(MR.strings.cabin_settings_pairing_absent),
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        )
        PopopxDivider()
        PopopxPickerRow(
          label = stringResource(MR.strings.cabin_settings_privacy_row),
          value = stringResource(MR.strings.cabin_settings_fact_absent),
          icon = MR.images.ic_shield,
          enabled = false,
          onClick = {},
          tint = PopopxMesh,
        )
      }

      PopopxSection(
        title = stringResource(MR.strings.cabin_settings_card_identity),
        footnote = stringResource(MR.strings.cabin_settings_key_footnote),
      ) {
        Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
          Text(stringResource(MR.strings.cabin_settings_key_row), style = PopopxTypeScale.body)
          Spacer(Modifier.height(4.dp))
          SelectionContainer {
            Text(
              if (localKeyHex.isEmpty()) stringResource(MR.strings.cabin_settings_key_absent) else localKeyHex,
              style = PopopxTypeScale.metric,
              color = if (localKeyHex.isEmpty()) {
                MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.hint)
              } else {
                MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary)
              },
            )
          }
        }
        PopopxDivider()
        CabinFactRow(stringResource(MR.strings.cabin_settings_binding_row), stringResource(MR.strings.cabin_settings_fact_absent))
        CabinFactRow(stringResource(MR.strings.cabin_settings_queue_row), stringResource(MR.strings.cabin_settings_fact_absent))
        CabinFactRow(stringResource(MR.strings.cabin_settings_in_reach_row), "${inReach.size} / ${nodes.size}")
        CabinFactRow(stringResource(MR.strings.cabin_settings_relay_row), "$relayedCount")
        CabinFactRow(stringResource(MR.strings.cabin_settings_farthest_row), "$farthestHop / $relayHopCap")
        PopopxDivider()
        CabinRadioDiagnosisRow(radio)
        PopopxDivider()
        CabinVerificationBlock(phase, fuse)
      }

      PopopxSection(
        title = stringResource(MR.strings.cabin_settings_card_danger),
        footnote = stringResource(MR.strings.cabin_settings_wipe_detail),
      ) {
        CabinDangerButton(stringResource(MR.strings.cabin_settings_wipe)) {
          AlertManager.shared.showAlertDialog(
            title = generalGetString(MR.strings.cabin_settings_wipe_question),
            text = generalGetString(MR.strings.cabin_settings_wipe_detail),
            confirmText = generalGetString(MR.strings.cabin_settings_wipe),
            destructive = true,
            onConfirm = {
              uiScope.launch {
                val reasons = runOfflineWipe(fuse, store)
                if (reasons.isEmpty()) {
                  showToast(generalGetString(MR.strings.cabin_settings_wipe_clean_toast))
                } else {
                  showToast(String.format(generalGetString(MR.strings.cabin_settings_wipe_failed_toast), reasons.size))
                }
              }
            },
          )
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

/** The 64-hex mesh key as it sits in the keystore; empty when this device never created one. */
private fun persistedMeshKeyHex(): String =
  PopopxMeshSecretStore()
    .data(PopopxMeshSecretStore.IDENTITY_SERVICE, PopopxMeshSecretStore.IDENTITY_ACCOUNT)
    ?.let { PopopxMeshIdentity.of(it)?.meshPublicKeyHex }
    .orEmpty()

/**
 * iOS' `clearOfflineIdentity()` order, reduced to what this build persists: switch first, so nothing
 * still running can write the queue back after the erase; the static key is deliberately kept.
 */
private suspend fun runOfflineWipe(fuse: PopopxMeshKillSwitch, store: PopopxCabinStore): List<String> =
  withContext(Dispatchers.IO) {
    val reasons = mutableListOf<String>()
    runCatching { fuse.setEnabled(false) }.onFailure {
      reasons.add("mesh switch: ${it.message ?: it.javaClass.simpleName}")
    }
    runCatching { fuse.clearNickname() }.onFailure {
      reasons.add("nickname: ${it.message ?: it.javaClass.simpleName}")
    }
    reasons += PopopxMeshWipe.eraseMappings()
    val cache = PopopxMeshWipe.sandboxDirectory(tmpDir)
    if (cache.exists() && !cache.deleteRecursively()) {
      reasons.add("mesh cache: ${cache.name} was not fully removed")
    }
    // The mirror keeps in-memory frames (invitations, threads) that name what was just erased; a fresh
    // pump is the cheapest way to start from nothing without touching the root page's own subscription.
    store.stop()
    store.start()
    reasons
  }

@Composable
private fun CabinFactRow(title: String, value: String) {
  Row(
    Modifier.fillMaxWidth().padding(vertical = 4.dp),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    Text(title, style = PopopxTypeScale.callout, modifier = Modifier.weight(1f))
    Spacer(Modifier.width(8.dp))
    Text(
      value,
      style = PopopxTypeScale.metric,
      color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
    )
  }
}

/**
 * `radioDiagnosisRow`: the reading has one source (the mesh's own monitor). The Open Settings button is
 * real only for the two tiers that have something to change there; every other tier stays a cell.
 */
@Composable
private fun CabinRadioDiagnosisRow(radio: PopopxBluetoothState) {
  val needsSettings = radio == PopopxBluetoothState.UNAUTHORIZED || radio == PopopxBluetoothState.POWERED_OFF
  Row(
    Modifier.fillMaxWidth().padding(vertical = 8.dp),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    PopopxIconBadge(
      if (needsSettings) MR.images.ic_wifi_off else MR.images.ic_wifi_tethering,
      if (needsSettings) MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary) else PopopxMesh,
    )
    Spacer(Modifier.width(12.dp))
    Column(Modifier.weight(1f)) {
      Text(
        stringResource(MR.strings.cabin_settings_radio_row),
        style = PopopxTypeScale.body.copy(fontWeight = FontWeight.SemiBold),
      )
      Spacer(Modifier.height(2.dp))
      Text(
        stringResource(
          when (radio) {
            PopopxBluetoothState.UNKNOWN -> MR.strings.cabin_settings_radio_pending
            PopopxBluetoothState.UNAUTHORIZED -> MR.strings.cabin_settings_radio_unauthorized
            PopopxBluetoothState.POWERED_OFF -> MR.strings.cabin_settings_radio_off
            PopopxBluetoothState.POWERED_ON -> MR.strings.cabin_settings_radio_healthy
            PopopxBluetoothState.RESETTING, PopopxBluetoothState.UNSUPPORTED -> MR.strings.cabin_settings_radio_quiet
          }
        ),
        style = PopopxTypeScale.subheadline,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      )
    }
    Spacer(Modifier.width(8.dp))
    if (needsSettings) {
      OpenSettingsButton()
    } else {
      Text(
        cabinRadioWords(radio),
        style = PopopxTypeScale.subheadline,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        modifier = Modifier.widthIn(max = 120.dp),
      )
    }
  }
}

@Composable
private fun OpenSettingsButton() {
  Surface(
    shape = RoundedCornerShape(10.dp),
    color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.press),
    modifier = Modifier.heightIn(min = PopopxSize.control).clickable { platform.androidOpenAppSettings() },
  ) {
    Text(
      stringResource(MR.strings.cabin_settings_open_settings),
      style = PopopxTypeScale.subheadline.copy(fontWeight = FontWeight.SemiBold),
      color = PopopxMeshInk,
      modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
    )
  }
}

/**
 * The runtime truth behind the switch: phase, the hub's live subscription count, and the mismatch when
 * the persisted switch and the phase disagree after a transition has settled.
 */
@Composable
private fun CabinVerificationBlock(phase: PopopxMeshFusePhase, fuse: PopopxMeshKillSwitch) {
  val phaseWord = stringResource(
    when (phase) {
      PopopxMeshFusePhase.OFF -> MR.strings.cabin_settings_verify_phase_off
      PopopxMeshFusePhase.STARTING -> MR.strings.cabin_settings_verify_phase_starting
      PopopxMeshFusePhase.ON -> MR.strings.cabin_settings_verify_phase_on
      PopopxMeshFusePhase.STOPPING -> MR.strings.cabin_settings_verify_phase_stopping
    }
  )
  val settled = phase == PopopxMeshFusePhase.OFF || phase == PopopxMeshFusePhase.ON
  val mismatch = settled && fuse.persistedIsEnabled() != (phase == PopopxMeshFusePhase.ON)
  val subscribers = PopopxMeshEventHub.shared.subscriberCount
  Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
    Text(
      stringResource(MR.strings.cabin_settings_verify_headline),
      style = PopopxTypeScale.body.copy(fontWeight = FontWeight.SemiBold),
    )
    Spacer(Modifier.height(2.dp))
    Text(
      phaseWord +
        stringResource(MR.strings.cabin_settings_verify_subscribers, subscribers) +
        if (mismatch) stringResource(MR.strings.cabin_settings_verify_mismatch) else "",
      style = PopopxTypeScale.subheadline,
      color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
    )
    Spacer(Modifier.height(2.dp))
    Text(
      stringResource(MR.strings.cabin_settings_verify_live),
      style = PopopxTypeScale.subheadline,
      color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.hint),
    )
  }
}

@Composable
private fun CabinDangerButton(text: String, action: () -> Unit) {
  val danger = MaterialTheme.colors.error
  Surface(
    shape = RoundedCornerShape(PopopxRadiusControl),
    color = danger.copy(alpha = 0.10f),
    border = BorderStroke(PopopxSize.stroke, danger.copy(alpha = 0.35f)),
    modifier = Modifier.fillMaxWidth().heightIn(min = PopopxSize.control).clickable(onClick = action),
  ) {
    Row(
      Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
      Icon(painterResource(MR.images.ic_delete_forever_filled), null, Modifier.size(PopopxSize.iconL), tint = danger)
      Text(
        text,
        style = PopopxTypeScale.headline,
        color = danger,
      )
    }
  }
}