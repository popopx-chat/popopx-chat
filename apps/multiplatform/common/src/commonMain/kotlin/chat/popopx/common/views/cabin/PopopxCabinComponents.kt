package chat.popopx.common.views.cabin

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import chat.popopx.common.mesh.PopopxBluetoothState
import chat.popopx.common.mesh.PopopxMeshConfig
import chat.popopx.common.mesh.PopopxMeshPeer
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.ui.theme.PopopxAlpha
import chat.popopx.common.ui.theme.PopopxBrand
import chat.popopx.common.ui.theme.PopopxFieldSurface
import chat.popopx.common.ui.theme.PopopxMesh
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.ui.theme.PopopxOnBrand
import chat.popopx.common.ui.theme.PopopxOnMesh
import chat.popopx.common.ui.theme.PopopxRadiusChip
import chat.popopx.common.ui.theme.PopopxRadiusControl
import chat.popopx.common.ui.theme.PopopxSize
import chat.popopx.common.ui.theme.PopopxSpace
import chat.popopx.common.ui.theme.PopopxSurface
import chat.popopx.common.ui.theme.PopopxTypeScale
import chat.popopx.common.views.helpers.DefaultBasicTextField
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max

// The feature-specific atoms every Cabin screen shares, modelled on the iOS `Copy` / `PopopxCabinClock`
// / `PopopxCabinAuthor` readings of the same page. The generic card, divider, badge, button and picker
// row are the design-system atoms (`PopopxSection`, `PopopxDivider`, `PopopxIconBadge`,
// `PopopxPrimaryButton`, `PopopxSecondaryButton`, `PopopxPickerRow`) and are not restated here.

/** The six radio states, exhausting [PopopxBluetoothState] in iOS' `Copy.radioWords` wording. */
@Composable
internal fun cabinRadioWords(state: PopopxBluetoothState): String = when (state) {
  PopopxBluetoothState.UNKNOWN -> stringResource(MR.strings.cabin_radio_unknown)
  PopopxBluetoothState.RESETTING -> stringResource(MR.strings.cabin_radio_resetting)
  PopopxBluetoothState.UNSUPPORTED -> stringResource(MR.strings.cabin_radio_unsupported)
  PopopxBluetoothState.UNAUTHORIZED -> stringResource(MR.strings.cabin_radio_unauthorized)
  PopopxBluetoothState.POWERED_OFF -> stringResource(MR.strings.cabin_radio_off)
  PopopxBluetoothState.POWERED_ON -> stringResource(MR.strings.cabin_radio_on)
}

/**
 * iOS' `PopopxCabinNode.isReachable`: the mirror computes it from module 4's `peerReachabilityTimeout`,
 * and this port has the same constant and the same "heard within the window" definition, nothing else.
 */
internal fun cabinIsReachable(peer: PopopxMeshPeer, nowMillis: Long): Boolean =
  nowMillis - peer.lastSeenAtMillis <= (PopopxMeshConfig.default.peerReachabilityTimeout * 1000).toLong()

/**
 * `PopopxCabinClock.since(_:)`, tier for tier. Past a day iOS switches to a dated stamp; the template is
 * the locale-neutral `MMM d HH:mm` it uses, not a hard-coded pattern of day and month order.
 */
@Composable
internal fun cabinSince(atMillis: Long, nowMillis: Long): String {
  val seconds = max(0L, (nowMillis - atMillis) / 1000).toInt()
  return when {
    seconds < 5 -> stringResource(MR.strings.cabin_just_now)
    seconds < 60 -> stringResource(MR.strings.cabin_seconds_ago, seconds)
    seconds < 3_600 -> stringResource(MR.strings.cabin_minutes_ago, seconds / 60)
    seconds < 86_400 -> stringResource(MR.strings.cabin_hours_ago, seconds / 3_600)
    else -> SimpleDateFormat("MMM d HH:mm", Locale.getDefault()).format(Date(atMillis))
  }
}

/** `Copy.hopsWords(_:)`: 0 hops means this radio holds the link, so "direct" is written out too. */
@Composable
internal fun cabinHopWords(hops: Int): String =
  if (hops == 0) stringResource(MR.strings.cabin_hop_direct) else stringResource(MR.strings.cabin_hop_badge, hops)

/** `PopopxCabinClock.metres(_:)`: the kilometre boundary is the same one the reach estimate uses. */
@Composable
internal fun cabinReachRadius(hops: Int): String {
  val metres = max(0, hops) * PopopxCabinReach.METRES_PER_HOP
  return if (metres >= 1_000) {
    stringResource(MR.strings.cabin_kilometres, String.format(Locale.getDefault(), "%.1f", metres / 1_000.0))
  } else {
    stringResource(MR.strings.cabin_metres, metres)
  }
}

/**
 * `PopopxCabinAuthor.label`: announce nickname, then the public-key abbreviation, then the 8-byte wire id.
 * One spelling for the row and the timeline bubble, because two spellings of one peer is how two places
 * start disagreeing about who is who.
 */
internal fun cabinPeerLabel(nickname: String?, meshPublicKeyHex: String?, peerIDHex: String): String {
  val name = nickname?.trim()
  if (!name.isNullOrEmpty()) return name
  if (meshPublicKeyHex != null) return cabinAbbreviate(meshPublicKeyHex)
  return peerIDHex.take(8)
}

/** `PopopxCabinLabel.abbreviate`: past 16 characters, 16 and an ellipsis. */
internal fun cabinAbbreviate(hex: String): String =
  if (hex.length > 16) hex.substring(0, 16) + "…" else hex

internal fun cabinPeerKey(peer: PopopxMeshPeer): String? = peer.meshPublicKey?.meshHex()

/** `PopopxCabinClock.clock(_:)`: the `HH:mm` of a locale-neutral template, nothing else. */
internal fun cabinClock(atMillis: Long): String =
  SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(atMillis))

/**
 * The hop capsule of a node row and of a hall bubble: the number is always there, and 0 hops is spelled
 * "0 hops · direct" rather than dropped (`Copy.hopsWords`).
 */
@Composable
internal fun CabinHopBadge(hops: Int) {
  Text(
    cabinHopWords(hops),
    style = PopopxTypeScale.metricSmall,
    color = PopopxOnMesh,
    modifier = Modifier
      .background(PopopxMesh, RoundedCornerShape(PopopxRadiusChip))
      .padding(horizontal = PopopxSpace.xxs, vertical = 2.dp),
  )
}

/**
 * The one-row send bar the hall and the private chat both use: a text field and one button, with no title
 * and no permanent character count (`PopopxCabinHallView.composer`'s stated shape).
 */
@Composable
internal fun CabinSendRow(
  value: MutableState<TextFieldValue>,
  fieldLabel: String,
  placeholder: String,
  action: String,
  enabled: Boolean,
  onSubmit: () -> Unit,
) {
  val haptics = LocalHapticFeedback.current
  Row(
    Modifier.fillMaxWidth(),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs),
  ) {
    DefaultBasicTextField(
      modifier = Modifier
        .weight(1f)
        .background(PopopxFieldSurface, RoundedCornerShape(PopopxRadiusControl))
        .heightIn(min = PopopxSize.control)
        .padding(horizontal = PopopxSpace.s, vertical = 10.dp)
        .semantics { contentDescription = fieldLabel },
      state = value,
      placeholder = {
        Text(
          placeholder,
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        )
      },
      keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
      onValueChange = { value.value = it },
    )
    Box(
      Modifier
        .heightIn(min = PopopxSize.control)
        .clip(RoundedCornerShape(PopopxRadiusControl))
        .background(if (enabled) PopopxBrand else MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.press))
        .clickable(
          enabled = enabled,
          onClick = {
            haptics.performHapticFeedback(HapticFeedbackType.VirtualKey)
            onSubmit()
          },
        )
        .padding(horizontal = PopopxSpace.m, vertical = 13.dp),
      contentAlignment = Alignment.Center,
    ) {
      Text(
        action,
        style = PopopxTypeScale.callout.copy(fontWeight = FontWeight.SemiBold),
        color = if (enabled) PopopxOnBrand else MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.hint),
      )
    }
  }
}

/** The hall's discovery-mode switch (`PopopxCabinHallView.discoveryEntry`): the chip *is* the state — filled
 * teal when on (a mesh fact), card-coloured with a teal ink when collapsed.
 */
@Composable
internal fun CabinDiscoveryChip(on: Boolean, onClick: () -> Unit) {
  val hint = stringResource(MR.strings.cabin_discovery_hint)
  val state = stringResource(if (on) MR.strings.cabin_turned_on else MR.strings.cabin_turned_off)
  Row(
    Modifier
      .heightIn(min = PopopxSize.control)
      .background(
        if (on) PopopxMesh else PopopxSurface,
        RoundedCornerShape(PopopxRadiusControl),
      )
      .clickable(onClick = onClick)
      .padding(horizontal = PopopxSpace.s)
      .semantics { contentDescription = hint },
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xxs),
  ) {
    Icon(
      painterResource(MR.images.ic_explore),
      null,
      Modifier.size(PopopxSize.iconM),
      tint = if (on) PopopxOnMesh else PopopxMeshInk,
    )
    Text(
      stringResource(MR.strings.cabin_discovery_mode) + " · " + state,
      style = PopopxTypeScale.subheadline,
      maxLines = 1,
      color = if (on) PopopxOnMesh else PopopxMeshInk,
    )
  }
}