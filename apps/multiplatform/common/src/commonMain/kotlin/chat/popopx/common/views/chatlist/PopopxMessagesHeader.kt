package chat.popopx.common.views.chatlist

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.Icon
import androidx.compose.material.IconButton
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.mesh.PopopxBluetoothState
import chat.popopx.common.mesh.PopopxMeshKillSwitch
import chat.popopx.common.model.UserNetworkInfo
import chat.popopx.common.model.UserNetworkType
import chat.popopx.common.platform.chatModel
import chat.popopx.common.platform.windowWidth
import chat.popopx.common.ui.theme.PopopxBrand
import chat.popopx.common.ui.theme.PopopxHairlineInner
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.views.helpers.AppBarHeight
import chat.popopx.common.views.helpers.fontSizeSqrtMultiplier
import chat.popopx.res.*
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.delay

// The Android port of iOS `PopopxTelemetryHeader` (apps/ios/Shared/Navigation/PopopxTelemetryHeader.swift):
// left identity entry, the network + Bluetooth status cluster in the middle, the badge/subscription entry and
// the page actions on the right. The chat title moved into that centre slot's place and is not drawn here —
// iOS hides its navigation bar entirely and lets this header be the first row, and the brief asks for the
// same three-part bar. The title's tap-to-scroll-to-bottom affordance is therefore desktop-only now.
//
// The header is mounted only from `ChatListToolbar` under `appPlatform.isAndroid`, and ChatListView selects
// the top layout on the same platform, so the desktop tree (and its snapshot baselines) is untouched.

/** The cluster steps up to labels only where iOS steps up too: iPhone portrait keeps both dots, wide screens don't. */
private val POPOPX_STATUS_LABEL_MIN_WIDTH = 600.dp

private val PopopxStatusDotSize = 8.dp
private val PopopxStatusIconSize = 16.dp
private val PopopxStatusPillSize = 32.dp
private val PopopxStatusPillHeight = 48.dp

@Composable
internal fun PopopxMessagesHeader(
  navigationButton: @Composable RowScope.() -> Unit,
  statusBadge: @Composable () -> Unit,
  buttons: List<@Composable RowScope.() -> Unit>,
  showNewChat: Boolean,
  onNewChat: () -> Unit,
) {
  Row(
    Modifier
      .fillMaxWidth()
      .background(MaterialTheme.colors.background)
      .statusBarsPadding()
      .padding(horizontal = 16.dp)
      .height(AppBarHeight * fontSizeSqrtMultiplier),
    verticalAlignment = Alignment.CenterVertically
  ) {
    navigationButton()
    Spacer(Modifier.weight(1f))
    PopopxMessagesStatusCluster()
    Spacer(Modifier.weight(1f))
    statusBadge()
    buttons.forEach { it() }
    if (showNewChat) {
      IconButton(onClick = onNewChat) {
        Box(
          contentAlignment = Alignment.Center,
          modifier = Modifier
            .background(MaterialTheme.colors.primary, shape = CircleShape)
            .size(33.dp * fontSizeSqrtMultiplier)
        ) {
          Icon(
            painterResource(MR.images.ic_add),
            stringResource(MR.strings.add_contact_or_create_group),
            Modifier.size(18.dp),
            tint = Color.White
          )
        }
      }
    }
  }
}

/**
 * `PopopxDualStatusCapsule` (:342-400): a network pill and a Bluetooth pill. Both are `PopopxStatusPill`
 * dots — 32×32 circles with an 8dp dot, a small glyph and a hairline ring — because the iOS measurement
 * that matters here is the iPhone-portrait one: out of 393pt only the 76pt double-dot tier fits, so the
 * labels are what wide screens buy. The wording is never truncated, only dropped to the dot tier.
 */
@Composable
private fun PopopxMessagesStatusCluster() {
  val status = rememberPopopxMessagesStatus()
  val labelled = windowWidth() >= POPOPX_STATUS_LABEL_MIN_WIDTH
  Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
    val network = popopxNetworkPill(status.network, labelled)
    PopopxStatusPill(
      icon = network.icon,
      tint = network.tint,
      text = if (labelled) network.text else null,
      spoken = stringResource(MR.strings.status_network_spoken, network.text),
      breathing = network.breathing
    )
    val radio = popopxRadioPill(status.radio)
    PopopxStatusPill(
      icon = radio.icon,
      tint = radio.tint,
      text = if (labelled) radio.text else null,
      spoken = stringResource(MR.strings.status_bluetooth_spoken, radio.text)
    )
  }
}

@Composable
private fun PopopxStatusPill(
  icon: ImageResource,
  tint: Color,
  text: String?,
  spoken: String,
  breathing: Boolean = false,
) {
  val dim by if (breathing) {
    val transition = rememberInfiniteTransition()
    transition.animateFloat(
      initialValue = 1f,
      targetValue = 0.45f,
      animationSpec = infiniteRepeatable(tween(1100), RepeatMode.Reverse)
    )
  } else {
    remember { mutableStateOf(1f) }
  }
  val shape = if (text == null) CircleShape else androidx.compose.foundation.shape.RoundedCornerShape(24.dp)
  Row(
    modifier = Modifier
      .height(PopopxStatusPillHeight)
      .then(if (text == null) Modifier.size(PopopxStatusPillSize) else Modifier)
      .clip(shape)
      .background(MaterialTheme.colors.surface, shape)
      .border(0.5.dp, PopopxHairlineInner, shape)
      .then(if (text == null) Modifier else Modifier.padding(horizontal = 16.dp))
      .clearAndSetSemantics { contentDescription = spoken },
    horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Box(
      Modifier
        .size(PopopxStatusDotSize)
        .graphicsLayer { alpha = dim; scaleX = 0.8f + 0.2f * dim; scaleY = 0.8f + 0.2f * dim }
        .background(tint, CircleShape)
    )
    Icon(painterResource(icon), null, Modifier.size(PopopxStatusIconSize), tint = tint)
    if (text != null) {
      Text(
        text,
        fontSize = 13.sp,
        fontWeight = FontWeight.Medium,
        color = tint,
        maxLines = 1
      )
    }
  }
}

private data class PopopxNetworkPill(val icon: ImageResource, val tint: Color, val text: String, val breathing: Boolean)

@Composable
private fun popopxNetworkPill(tier: PopopxNetworkTier, labelled: Boolean): PopopxNetworkPill = when (tier) {
  PopopxNetworkTier.Unknown -> PopopxNetworkPill(MR.images.ic_wifi, MaterialTheme.colors.onBackground.copy(alpha = 0.45f), stringResource(MR.strings.status_unknown), false)
  PopopxNetworkTier.Online -> PopopxNetworkPill(MR.images.ic_wifi, PopopxBrand, stringResource(MR.strings.status_online), false)
  is PopopxNetworkTier.Degraded -> PopopxNetworkPill(MR.images.ic_wifi, PopopxBrand, stringResource(MR.strings.status_online_degraded, tier.reason), false)
  is PopopxNetworkTier.MeshOnly -> PopopxNetworkPill(MR.images.ic_wifi_tethering, PopopxMeshInk, stringResource(MR.strings.status_mesh_nodes, tier.nodes), true)
  PopopxNetworkTier.Offline -> PopopxNetworkPill(MR.images.ic_wifi_off, MaterialTheme.colors.secondary, stringResource(MR.strings.status_offline), false)
}

private data class PopopxRadioPill(val icon: ImageResource, val tint: Color, val text: String)

@Composable
private fun popopxRadioPill(state: PopopxBluetoothState): PopopxRadioPill {
  val text = when (state) {
    PopopxBluetoothState.POWERED_ON -> stringResource(MR.strings.audio_device_bluetooth)
    PopopxBluetoothState.POWERED_OFF -> stringResource(MR.strings.status_bluetooth_off)
    PopopxBluetoothState.UNAUTHORIZED -> stringResource(MR.strings.status_bluetooth_not_allowed)
    PopopxBluetoothState.UNSUPPORTED -> stringResource(MR.strings.status_bluetooth_unsupported)
    PopopxBluetoothState.RESETTING -> stringResource(MR.strings.status_bluetooth_resetting)
    PopopxBluetoothState.UNKNOWN -> stringResource(MR.strings.status_bluetooth_unknown)
  }
  val tint = if (state.isUsable) PopopxMeshInk else MaterialTheme.colors.onBackground.copy(alpha = 0.45f)
  val icon = if (state.isUsable) MR.images.ic_wifi_tethering else MR.images.ic_bluetooth
  return PopopxRadioPill(icon, tint, text)
}

private sealed interface PopopxNetworkTier {
  data object Unknown : PopopxNetworkTier
  data object Online : PopopxNetworkTier
  data class Degraded(val reason: String) : PopopxNetworkTier
  data class MeshOnly(val nodes: Int) : PopopxNetworkTier
  data object Offline : PopopxNetworkTier
}

private data class PopopxMessagesStatus(val network: PopopxNetworkTier, val radio: PopopxBluetoothState)

/**
 * `PopopxHeaderSignal.resolve` (:89-109) over the sources this port has. iOS reads an `NWPath` and a
 * Bluetooth health actor; here `chatModel.networkInfo` is the SMP network reading, and direct neighbours
 * come from the mounted mesh engine. `proximityActive` has no Android counterpart this round (the
 * proximity page is a HOLD item), so that top-priority tier is simply never produced.
 */
@Composable
private fun rememberPopopxMessagesStatus(): PopopxMessagesStatus {
  val networkInfo = chatModel.networkInfo.value
  var radio by remember { mutableStateOf(PopopxBluetoothState.UNKNOWN) }
  var peers by remember { mutableStateOf(0) }

  LaunchedEffect(Unit) {
    while (true) {
      val engine = PopopxMeshKillSwitch.shared.engine()
      val state = engine?.bluetoothState ?: PopopxBluetoothState.UNKNOWN
      radio = state
      peers = if (state.isUsable) engine?.directNeighbourCount() ?: 0 else 0
      delay(2_000)
    }
  }

  return PopopxMessagesStatus(popopxResolveTier(networkInfo, peers), radio)
}

@Composable
private fun popopxResolveTier(info: UserNetworkInfo, peers: Int): PopopxNetworkTier = when {
  !info.online || info.networkType == UserNetworkType.NONE ->
    if (peers > 0) PopopxNetworkTier.MeshOnly(peers) else PopopxNetworkTier.Offline
  info.networkType == UserNetworkType.CELLULAR ->
    PopopxNetworkTier.Degraded(stringResource(MR.strings.network_type_cellular))
  else -> PopopxNetworkTier.Online
}