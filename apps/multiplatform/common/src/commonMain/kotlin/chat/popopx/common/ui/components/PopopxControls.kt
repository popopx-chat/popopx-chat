package chat.popopx.common.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.CircularProgressIndicator
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Surface
import androidx.compose.material.Switch
import androidx.compose.material.SwitchDefaults
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.popopx.common.ui.theme.PopopxAlpha
import chat.popopx.common.ui.theme.PopopxBrand
import chat.popopx.common.ui.theme.PopopxDangerFill
import chat.popopx.common.ui.theme.PopopxHairlineStrong
import chat.popopx.common.ui.theme.PopopxLabelHint
import chat.popopx.common.ui.theme.PopopxOnBrand
import chat.popopx.common.ui.theme.PopopxOnDanger
import chat.popopx.common.ui.theme.PopopxPressScale
import chat.popopx.common.ui.theme.PopopxRadiusChip
import chat.popopx.common.ui.theme.PopopxRadiusControl
import chat.popopx.common.ui.theme.PopopxSize
import chat.popopx.common.ui.theme.PopopxSnappySpring
import chat.popopx.common.ui.theme.PopopxSpace
import chat.popopx.common.ui.theme.PopopxSurface
import chat.popopx.common.ui.theme.PopopxTypeScale
import chat.popopx.common.ui.theme.popopxFiniteSpec
import chat.popopx.common.ui.theme.popopxReducedMotion
import chat.popopx.common.views.helpers.AutoMirroredIcon
import chat.popopx.res.*
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.compose.painterResource

/**
 * The press contract of the Android design system: scale 0.97 on the snappy spring, ripple intact,
 * bounds unchanged. `haptic` is reserved for commits (primary action), not for navigation.
 */
@Composable
fun PopopxPressable(
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  enabled: Boolean = true,
  onClickLabel: String? = null,
  haptic: Boolean = false,
  content: @Composable BoxScope.() -> Unit,
) {
  val interactionSource = remember { MutableInteractionSource() }
  val pressed by interactionSource.collectIsPressedAsState()
  val haptics = LocalHapticFeedback.current
  val reduced = popopxReducedMotion()
  val scale by animateFloatAsState(
    targetValue = if (pressed) PopopxPressScale else 1f,
    animationSpec = popopxFiniteSpec(reduced, PopopxSnappySpring),
    label = "popopx-press"
  )
  Box(
    modifier
      .graphicsLayer {
        scaleX = scale
        scaleY = scale
      }
      .clickable(
        interactionSource = interactionSource,
        indication = LocalIndication.current,
        enabled = enabled,
        onClickLabel = onClickLabel,
        onClick = {
          if (haptic) haptics.performHapticFeedback(HapticFeedbackType.Confirm)
          onClick()
        }
      ),
    content = content
  )
}

@Composable
fun PopopxPrimaryButton(
  text: String,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  icon: ImageResource? = null,
  enabled: Boolean = true,
  loading: Boolean = false,
  mirrorIcon: Boolean = false,
) {
  PopopxPressable(
    onClick = onClick,
    enabled = enabled && !loading,
    modifier = modifier.fillMaxWidth(),
    haptic = true,
  ) {
    Surface(
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = PopopxSize.button),
      shape = RoundedCornerShape(PopopxRadiusControl),
      color = PopopxBrand.copy(alpha = if (enabled) 1f else PopopxAlpha.disabled),
    ) {
      Box(
        Modifier
          .fillMaxWidth()
          .padding(horizontal = PopopxSpace.m, vertical = PopopxSpace.s),
        contentAlignment = Alignment.Center
      ) {
        if (loading) {
          CircularProgressIndicator(Modifier.size(18.dp), color = PopopxOnBrand, strokeWidth = 2.dp)
        } else {
          Row(
            horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs),
            verticalAlignment = Alignment.CenterVertically
          ) {
            if (icon != null) {
              if (mirrorIcon) {
                AutoMirroredIcon(painterResource(icon), null, Modifier.size(PopopxSize.iconL), tint = PopopxOnBrand)
              } else {
                Icon(painterResource(icon), null, Modifier.size(PopopxSize.iconL), tint = PopopxOnBrand)
              }
            }
            Text(text, style = PopopxTypeScale.headline, color = PopopxOnBrand, maxLines = 1)
          }
        }
      }
    }
  }
}

@Composable
fun PopopxSecondaryButton(
  text: String,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  icon: ImageResource? = null,
  enabled: Boolean = true,
  mirrorIcon: Boolean = false,
) {
  PopopxPressable(
    onClick = onClick,
    enabled = enabled,
    modifier = modifier.fillMaxWidth(),
    haptic = true,
  ) {
    Surface(
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = PopopxSize.button),
      shape = RoundedCornerShape(PopopxRadiusControl),
      color = PopopxSurface,
      border = BorderStroke(PopopxSize.hairline, PopopxHairlineStrong),
    ) {
      Box(
        Modifier
          .fillMaxWidth()
          .padding(horizontal = PopopxSpace.m, vertical = PopopxSpace.s),
        contentAlignment = Alignment.Center
      ) {
        Row(
          horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs),
          verticalAlignment = Alignment.CenterVertically
        ) {
          if (icon != null) {
            val tint = PopopxBrand.copy(alpha = if (enabled) 1f else PopopxAlpha.disabled)
            if (mirrorIcon) {
              AutoMirroredIcon(painterResource(icon), null, Modifier.size(PopopxSize.iconL), tint = tint)
            } else {
              Icon(painterResource(icon), null, Modifier.size(PopopxSize.iconL), tint = tint)
            }
          }
          Text(
            text,
            style = PopopxTypeScale.headline,
            color = PopopxBrand.copy(alpha = if (enabled) 1f else PopopxAlpha.disabled),
            maxLines = 1
          )
        }
      }
    }
  }
}

@Composable
fun PopopxGhostButton(
  text: String,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  icon: ImageResource? = null,
  mirrorIcon: Boolean = false,
) {
  PopopxPressable(onClick = onClick, modifier = modifier.fillMaxWidth()) {
    Row(
      Modifier
        .fillMaxWidth()
        .heightIn(min = PopopxSize.control)
        .padding(horizontal = PopopxSpace.m, vertical = PopopxSpace.s),
      horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs, Alignment.CenterHorizontally),
      verticalAlignment = Alignment.CenterVertically
    ) {
      if (icon != null) {
        if (mirrorIcon) {
          AutoMirroredIcon(painterResource(icon), null, Modifier.size(PopopxSize.iconL), tint = PopopxBrand)
        } else {
          Icon(painterResource(icon), null, Modifier.size(PopopxSize.iconL), tint = PopopxBrand)
        }
      }
      Text(text, style = PopopxTypeScale.headline, color = PopopxBrand, maxLines = 1)
    }
  }
}

/** The paired action of a QR pass card: one primary, one outlined, both 44dp. */
@Composable
fun PopopxActionButton(
  text: String,
  icon: ImageResource,
  primary: Boolean,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  enabled: Boolean = true,
) {
  PopopxActionButton(text, painterResource(icon), primary, onClick, modifier, enabled)
}

@Composable
fun PopopxActionButton(
  text: String,
  icon: androidx.compose.ui.graphics.painter.Painter,
  primary: Boolean,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  enabled: Boolean = true,
) {
  PopopxPressable(
    onClick = onClick,
    enabled = enabled,
    modifier = modifier,
    haptic = true,
  ) {
    Surface(
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = PopopxSize.control),
      shape = RoundedCornerShape(PopopxRadiusControl),
      color = if (primary) PopopxBrand.copy(alpha = if (enabled) 1f else PopopxAlpha.disabled) else PopopxSurface,
      border = if (primary) null else BorderStroke(PopopxSize.hairline, PopopxHairlineStrong),
    ) {
      Row(
        Modifier
          .fillMaxWidth()
          .heightIn(min = PopopxSize.control)
          .padding(horizontal = PopopxSpace.s, vertical = PopopxSpace.s),
        horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically
      ) {
        val ink = if (primary) PopopxOnBrand else PopopxBrand.copy(alpha = if (enabled) 1f else PopopxAlpha.disabled)
        Icon(icon, null, Modifier.size(PopopxSize.iconM), tint = ink)
        Text(text, style = PopopxTypeScale.calloutSmall.copy(fontWeight = FontWeight.SemiBold), color = ink, maxLines = 1)
      }
    }
  }
}

/**
 * A filter chip: a 32dp visual inside a 44dp hit target, brand-filled when selected. The visual is
 * the state; the semantics expose selected so TalkBack does not have to infer it from colour.
 */
@Composable
fun PopopxChip(
  text: String,
  selected: Boolean,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  icon: ImageResource? = null,
) {
  val interactionSource = remember { MutableInteractionSource() }
  val shape = RoundedCornerShape(PopopxRadiusChip)
  Box(
    modifier
      .heightIn(min = PopopxSize.control)
      .clip(RoundedCornerShape(PopopxRadiusControl))
      .selectable(
        selected = selected,
        interactionSource = interactionSource,
        indication = LocalIndication.current,
        role = Role.Button,
        onClick = onClick
      ),
    contentAlignment = Alignment.Center
  ) {
    Row(
      Modifier
        .height(PopopxSize.pill)
        .clip(shape)
        .background(if (selected) PopopxBrand else PopopxSurface, shape)
        .border(PopopxSize.hairline, if (selected) Color.Transparent else PopopxHairlineStrong, shape)
        .padding(horizontal = PopopxSpace.s, vertical = PopopxSpace.xxs),
      horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xxs),
      verticalAlignment = Alignment.CenterVertically
    ) {
      if (icon != null) {
        Icon(
          painterResource(icon),
          null,
          Modifier.size(PopopxSize.iconS),
          tint = if (selected) PopopxOnBrand else PopopxBrand
        )
      }
      Text(
        text,
        style = PopopxTypeScale.subheadline,
        color = if (selected) PopopxOnBrand else MaterialTheme.colors.onBackground,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis
      )
    }
  }
}

/**
 * The dot-tier status pill: a 32dp circle with an 8dp breathing dot, or a 48dp capsule once the
 * screen has room for the label. The whole pill is one accessibility node.
 */
@Composable
fun PopopxStatusPill(
  icon: ImageResource,
  tint: Color,
  text: String?,
  spoken: String,
  modifier: Modifier = Modifier,
  breathing: Boolean = false,
) {
  val reduced = popopxReducedMotion()
  val dim by if (breathing && !reduced) {
    val transition = rememberInfiniteTransition(label = "popopx-status-breath")
    transition.animateFloat(
      initialValue = 1f,
      targetValue = 0.45f,
      animationSpec = infiniteRepeatable(tween(1_100), RepeatMode.Reverse),
      label = "popopx-status-dim"
    )
  } else {
    remember { mutableStateOf(1f) }
  }
  val shape = if (text == null) CircleShape else RoundedCornerShape(PopopxSpace.l)
  Row(
    modifier = modifier
      .then(if (text == null) Modifier.size(PopopxSize.pill) else Modifier.height(PopopxSize.hitTarget))
      .clip(shape)
      .background(PopopxSurface, shape)
      .border(PopopxSize.hairline, PopopxHairlineStrong, shape)
      .then(if (text == null) Modifier else Modifier.padding(horizontal = PopopxSpace.m))
      .clearAndSetSemantics { contentDescription = spoken },
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xxs, Alignment.CenterHorizontally),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Box(
      Modifier
        .size(PopopxSize.statusDot)
        .graphicsLayer {
          alpha = dim
          scaleX = 0.8f + 0.2f * dim
          scaleY = 0.8f + 0.2f * dim
        }
        .background(tint, CircleShape)
    )
    Icon(painterResource(icon), null, Modifier.size(PopopxSize.iconM), tint = tint)
    if (text != null) {
      Text(text, style = PopopxTypeScale.subheadline, fontWeight = FontWeight.Medium, color = tint, maxLines = 1)
    }
  }
}

@Composable
fun PopopxBadge(text: String, modifier: Modifier = Modifier) {
  Text(
    text,
    style = PopopxTypeScale.metricSmall,
    color = PopopxOnDanger,
    maxLines = 1,
    modifier = modifier
      .background(PopopxDangerFill, CircleShape)
      .padding(horizontal = PopopxSpace.xxs, vertical = 1.dp)
  )
}

@Composable
fun PopopxSwitch(
  checked: Boolean,
  onCheckedChange: ((Boolean) -> Unit)?,
  modifier: Modifier = Modifier,
  enabled: Boolean = true,
) {
  val haptics = LocalHapticFeedback.current
  Switch(
    checked = checked,
    onCheckedChange = if (onCheckedChange == null) null else { next ->
      haptics.performHapticFeedback(if (next) HapticFeedbackType.ToggleOn else HapticFeedbackType.ToggleOff)
      onCheckedChange(next)
    },
    modifier = modifier,
    enabled = enabled,
    colors = SwitchDefaults.colors(
      checkedThumbColor = PopopxOnBrand,
      checkedTrackColor = PopopxBrand,
      uncheckedThumbColor = Color.White,
      uncheckedTrackColor = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.track),
    )
  )
}

/** Icon badge, label, trailing value and a chevron that mirrors under RTL. */
@Composable
fun PopopxPickerRow(
  label: String,
  value: String?,
  icon: ImageResource,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  enabled: Boolean = true,
  tint: Color = PopopxBrand,
) {
  Row(
    modifier
      .fillMaxWidth()
      .heightIn(min = PopopxSize.control)
      .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
      .padding(vertical = 6.dp),
    verticalAlignment = Alignment.CenterVertically
  ) {
    PopopxIconBadge(icon, if (enabled) tint else PopopxLabelHint)
    Spacer(Modifier.width(PopopxSpace.s))
    Text(
      label,
      style = PopopxTypeScale.body,
      fontWeight = FontWeight.SemiBold,
      color = MaterialTheme.colors.onSurface.copy(alpha = if (enabled) 1f else PopopxAlpha.secondary),
      modifier = Modifier.weight(1f)
    )
    Spacer(Modifier.width(PopopxSpace.xs))
    if (value != null) {
      Text(
        value,
        style = PopopxTypeScale.subheadline,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis
      )
      Spacer(Modifier.width(6.dp))
    }
    AutoMirroredIcon(
      painterResource(MR.images.ic_chevron_right),
      null,
      Modifier.size(PopopxSize.iconL),
      tint = PopopxLabelHint
    )
  }
}

/** A labelled switch row. The row is the 44dp control; the switch itself is drawn, not a second target. */
@Composable
fun PopopxToggleRow(
  title: String,
  checked: Boolean,
  onCheckedChange: (Boolean) -> Unit,
  modifier: Modifier = Modifier,
  note: String? = null,
  icon: ImageResource? = null,
  tint: Color = PopopxBrand,
  enabled: Boolean = true,
) {
  val haptics = LocalHapticFeedback.current
  Row(
    modifier
      .fillMaxWidth()
      .heightIn(min = PopopxSize.control)
      .toggleable(
        value = checked,
        enabled = enabled,
        role = Role.Switch,
        onValueChange = {
          haptics.performHapticFeedback(if (it) HapticFeedbackType.ToggleOn else HapticFeedbackType.ToggleOff)
          onCheckedChange(it)
        }
      )
      .padding(vertical = 6.dp),
    verticalAlignment = Alignment.CenterVertically
  ) {
    if (icon != null) {
      PopopxIconBadge(icon, if (enabled) tint else PopopxLabelHint)
      Spacer(Modifier.width(PopopxSpace.s))
    }
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
      Text(
        title,
        style = PopopxTypeScale.body,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colors.onSurface.copy(alpha = if (enabled) 1f else PopopxAlpha.secondary)
      )
      if (note != null) {
        Text(
          note,
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary)
        )
      }
    }
    Spacer(Modifier.width(PopopxSpace.xs))
    PopopxSwitch(checked = checked, onCheckedChange = null, enabled = enabled)
  }
}