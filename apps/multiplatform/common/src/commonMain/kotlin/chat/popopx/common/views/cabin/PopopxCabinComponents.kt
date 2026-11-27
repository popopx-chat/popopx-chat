package chat.popopx.common.views.cabin

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Surface
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.mesh.PopopxBluetoothState
import chat.popopx.common.mesh.PopopxMeshConfig
import chat.popopx.common.mesh.PopopxMeshPeer
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.ui.theme.PopopxBrand
import chat.popopx.common.ui.theme.PopopxHairlineInner
import chat.popopx.common.ui.theme.PopopxMesh
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.ui.theme.PopopxOnBrand
import chat.popopx.common.ui.theme.PopopxOnMesh
import chat.popopx.common.ui.theme.isInDarkTheme
import chat.popopx.common.ui.theme.sectionCardColor
import chat.popopx.common.views.helpers.AutoMirroredIcon
import chat.popopx.common.views.helpers.DefaultBasicTextField
import chat.popopx.res.*
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max

// The atoms every Cabin screen shares, modelled on the iOS `PopopxSectionCard` + `PopopxCabinNode`
// reading of the same page. Kept in their own file because the root page, the hall and the settings
// centre (this program's C2–C4) all draw with them, and two copies of a card would be two places to
// disagree about one screen.

internal val cabinCardRadius = 16.dp
internal val cabinIconSide = 32.dp
internal val cabinSecondaryAlpha = 0.62f
internal val cabinLabelHintAlpha = 0.35f
private val cabinSeparatorAlpha = 0.08f

@Composable
internal fun CabinSectionCard(
  title: String? = null,
  footnote: String? = null,
  content: @Composable ColumnScope.() -> Unit,
) {
  Column(Modifier.fillMaxWidth()) {
    if (title != null) {
      Text(
        title,
        fontSize = 17.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(start = 4.dp, bottom = 8.dp)
      )
    }
    Surface(
      Modifier.fillMaxWidth(),
      shape = RoundedCornerShape(cabinCardRadius),
      color = sectionCardColor(),
      border = BorderStroke(0.5.dp, PopopxHairlineInner),
      elevation = if (isInDarkTheme()) 0.dp else 1.dp,
    ) {
      Column(Modifier.padding(16.dp), content = content)
    }
    if (footnote != null) {
      Text(
        footnote,
        fontSize = 13.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = cabinSecondaryAlpha),
        modifier = Modifier.padding(start = 4.dp, top = 8.dp)
      )
    }
  }
}

@Composable
internal fun CabinDivider() {
  Box(
    Modifier
      .fillMaxWidth()
      .padding(vertical = 8.dp)
      .height(1.dp)
      .background(MaterialTheme.colors.onSurface.copy(alpha = cabinSeparatorAlpha))
  )
}

@Composable
internal fun CabinIconBadge(icon: ImageResource, tint: Color) {
  Box(
    Modifier
      .size(cabinIconSide)
      .background(tint.copy(alpha = 0.12f), RoundedCornerShape(8.dp)),
    contentAlignment = Alignment.Center
  ) {
    Icon(painterResource(icon), null, Modifier.size(18.dp), tint = tint)
  }
}

@Composable
internal fun CabinPrimaryButton(
  text: String,
  icon: ImageResource? = null,
  enabled: Boolean = true,
  modifier: Modifier = Modifier,
  action: () -> Unit,
) {
  Surface(
    shape = RoundedCornerShape(12.dp),
    color = PopopxBrand.copy(alpha = if (enabled) 1f else 0.5f),
    modifier = modifier.heightIn(min = 44.dp).clickable(enabled = enabled, onClick = action)
  ) {
    CabinButtonInk(text, icon, PopopxOnBrand)
  }
}

@Composable
internal fun CabinSecondaryButton(
  text: String,
  icon: ImageResource? = null,
  enabled: Boolean = true,
  modifier: Modifier = Modifier,
  action: () -> Unit,
) {
  Surface(
    shape = RoundedCornerShape(12.dp),
    color = sectionCardColor(),
    border = BorderStroke(1.dp, MaterialTheme.colors.onSurface.copy(alpha = 0.18f)),
    modifier = modifier.heightIn(min = 44.dp).clickable(enabled = enabled, onClick = action)
  ) {
    CabinButtonInk(text, icon, PopopxBrand.copy(alpha = if (enabled) 1f else 0.5f))
  }
}

@Composable
private fun CabinButtonInk(text: String, icon: ImageResource?, ink: Color) {
  Row(
    Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    if (icon != null) Icon(painterResource(icon), null, Modifier.size(18.dp), tint = ink)
    Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = ink)
  }
}

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
 * `PopopxPickerRow` of the iOS design system, in the shape the Cabin pages use: icon badge, label, the
 * value on the trailing side and a disclosure chevron that mirrors under RTL. A disabled row keeps its
 * value readable — it names an absent capability, it is not a control pretending to be one.
 */
@Composable
internal fun CabinPickerRow(
  label: String,
  value: String,
  icon: ImageResource,
  enabled: Boolean = true,
  onClick: () -> Unit,
) {
  Row(
    Modifier
      .fillMaxWidth()
      .heightIn(min = 44.dp)
      .clickable(enabled = enabled, onClick = onClick)
      .padding(vertical = 6.dp),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    CabinIconBadge(icon, if (enabled) PopopxMesh else MaterialTheme.colors.onSurface.copy(alpha = cabinLabelHintAlpha))
    Spacer(Modifier.width(12.dp))
    Text(
      label,
      fontSize = 16.sp,
      fontWeight = FontWeight.SemiBold,
      color = MaterialTheme.colors.onSurface.copy(alpha = if (enabled) 1f else cabinSecondaryAlpha),
      modifier = Modifier.weight(1f),
    )
    Spacer(Modifier.width(8.dp))
    Text(
      value,
      fontSize = 13.sp,
      color = MaterialTheme.colors.onSurface.copy(alpha = cabinSecondaryAlpha),
      maxLines = 1,
      overflow = TextOverflow.Ellipsis,
    )
    Spacer(Modifier.width(6.dp))
    AutoMirroredIcon(
      painterResource(MR.images.ic_chevron_right),
      null,
      Modifier.size(18.dp),
      tint = MaterialTheme.colors.onSurface.copy(alpha = cabinLabelHintAlpha),
    )
  }
}

/**
 * The hop capsule of a node row and of a hall bubble: the number is always there, and 0 hops is spelled
 * "0 hops · direct" rather than dropped (`Copy.hopsWords`).
 */
@Composable
internal fun CabinHopBadge(hops: Int) {
  Text(
    cabinHopWords(hops),
    fontSize = 11.sp,
    color = PopopxOnMesh,
    modifier = Modifier
      .background(PopopxMesh, RoundedCornerShape(8.dp))
      .padding(horizontal = 4.dp, vertical = 2.dp),
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
  Row(
    Modifier.fillMaxWidth(),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    DefaultBasicTextField(
      modifier = Modifier
        .weight(1f)
        .background(MaterialTheme.colors.surface, RoundedCornerShape(12.dp))
        .heightIn(min = 44.dp)
        .padding(horizontal = 12.dp, vertical = 10.dp)
        .semantics { contentDescription = fieldLabel },
      state = value,
      placeholder = { Text(placeholder, color = MaterialTheme.colors.onSurface.copy(alpha = cabinSecondaryAlpha), fontSize = 14.sp) },
      keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
      onValueChange = { value.value = it },
    )
    Surface(
      shape = RoundedCornerShape(12.dp),
      color = if (enabled) PopopxBrand else MaterialTheme.colors.onSurface.copy(alpha = 0.08f),
    ) {
      Text(
        action,
        fontSize = 15.sp,
        fontWeight = FontWeight.SemiBold,
        color = if (enabled) PopopxOnBrand else MaterialTheme.colors.onSurface.copy(alpha = cabinLabelHintAlpha),
        modifier = Modifier
          .heightIn(min = 44.dp)
          .clickable(enabled = enabled, onClick = onSubmit)
          .padding(horizontal = 16.dp, vertical = 13.dp),
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
      .heightIn(min = 44.dp)
      .background(
        if (on) PopopxMesh else sectionCardColor(),
        RoundedCornerShape(12.dp),
      )
      .clickable(onClick = onClick)
      .padding(horizontal = 12.dp)
      .semantics { contentDescription = hint },
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(4.dp),
  ) {
    Icon(
      painterResource(MR.images.ic_explore),
      null,
      Modifier.size(16.dp),
      tint = if (on) PopopxOnMesh else PopopxMeshInk,
    )
    Text(
      stringResource(MR.strings.cabin_discovery_mode) + " · " + state,
      fontSize = 13.sp,
      maxLines = 1,
      color = if (on) PopopxOnMesh else PopopxMeshInk,
    )
  }
}