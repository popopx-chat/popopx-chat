package chat.popopx.common.views.onboarding

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.ui.components.PopopxDivider
import chat.popopx.common.ui.components.PopopxGhostButton
import chat.popopx.common.ui.components.PopopxPrimaryButton
import chat.popopx.common.ui.components.PopopxSecondaryButton
import chat.popopx.common.ui.components.PopopxSection
import chat.popopx.common.ui.components.PopopxSwitch
import chat.popopx.common.ui.theme.*
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.compose.painterResource

// The Android reading of the iOS onboarding atoms (apps/ios/Shared/Views/Onboarding/OnboardingView.swift,
// PopopxControls.swift). Shared by the four onboarding screens only, so desktop keeps its own layout.

/** `PopopxIconTint`: the fill/ink pair a solid badge is painted with. */
enum class PopopxOnboardingTint {
  BRAND, MESH, DANGER, SUCCESS, NEUTRAL;

  @Composable
  fun fill(): Color = when (this) {
    BRAND -> PopopxBrand
    MESH -> PopopxMesh
    DANGER -> PopopxDangerFill
    SUCCESS -> PopopxSuccess
    NEUTRAL -> PopopxSeparator
  }

  @Composable
  fun ink(): Color = when (this) {
    BRAND -> PopopxOnBrand
    MESH -> PopopxOnMesh
    DANGER -> PopopxOnDanger
    SUCCESS -> PopopxOnSuccess
    NEUTRAL -> MaterialTheme.colors.onBackground
  }
}

@Composable
fun popopxOnboardingLabel() = MaterialTheme.colors.onBackground

@Composable
fun popopxOnboardingSecondary() = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary)

@Composable
fun popopxOnboardingLabelHint() = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.hint)

@Composable
private fun popopxOnboardingChipBackground() =
  MaterialTheme.colors.onBackground.copy(alpha = if (isInDarkTheme()) 0.08f else 0.04f)

/** The `step / steps` capsule, stage label, title, note and the multi-segment progress track shared by screens 2, 3 and 4. */
@Composable
fun PopopxOnboardingHeader(step: Int, steps: Int, stage: String, title: String, note: String? = null) {
  Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(PopopxSpace.xs)) {
    Row(
      Modifier
        .background(popopxOnboardingChipBackground(), RoundedCornerShape(PopopxRadiusChip))
        .border(PopopxSize.hairline, PopopxHairlineInner, RoundedCornerShape(PopopxRadiusChip))
        .padding(horizontal = PopopxSpace.xs, vertical = PopopxSpace.xxs),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs)
    ) {
      Text(
        "$step / $steps",
        style = PopopxTypeScale.codeSmall,
        color = PopopxBrand
      )
      Box(Modifier.width(PopopxSize.hairline).height(12.dp).background(PopopxSeparator))
      Text(
        stage,
        style = PopopxTypeScale.caption,
        color = popopxOnboardingSecondary(),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis
      )
    }
    Text(
      title,
      style = PopopxTypeScale.title2,
      color = popopxOnboardingLabel()
    )
    if (note != null) {
      Text(
        note,
        style = PopopxTypeScale.callout,
        color = popopxOnboardingSecondary()
      )
    }
    Row(Modifier.fillMaxWidth().padding(top = PopopxSpace.xs), horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xxs)) {
      repeat(steps) { index ->
        PopopxOnboardingTrackSegment(filled = index < step)
      }
    }
  }
}

/** One third of the progress track: a separator rail that the brand fill stretches into as the step advances. */
@Composable
private fun RowScope.PopopxOnboardingTrackSegment(filled: Boolean) {
  val fill by animateFloatAsState(
    targetValue = if (filled) 1f else 0f,
    animationSpec = PopopxFluidSpring,
    label = "onboarding-track-fill"
  )
  val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
  Box(
    Modifier
      .weight(1f)
      .height(PopopxSpace.xxs)
      .background(PopopxSeparator, CircleShape)
  ) {
    Box(
      Modifier
        .fillMaxSize()
        .graphicsLayer {
          scaleX = fill
          transformOrigin = TransformOrigin(if (rtl) 1f else 0f, 0.5f)
        }
        .background(PopopxBrand, CircleShape)
    )
  }
}

/** 0.5dp hairline with the 8dp vertical breathing room the iOS atom carries. */
@Composable
fun PopopxOnboardingHairline() {
  PopopxDivider()
}

/** The rounded coloured icon badge at the head of a row: a tint gradient, a 0.5dp rim and a soft halo. */
@Composable
fun PopopxOnboardingIconBadge(icon: ImageResource, tint: PopopxOnboardingTint) {
  val fill = tint.fill()
  val shape = RoundedCornerShape(PopopxRadiusChip)
  Box(
    Modifier
      .size(PopopxSize.iconBadge)
      .drawBehind {
        val radius = size.minDimension * 0.85f
        drawCircle(
          brush = Brush.radialGradient(
            colors = listOf(fill.copy(alpha = PopopxAlpha.wash), fill.copy(alpha = 0f)),
            center = center,
            radius = radius
          ),
          radius = radius
        )
      }
      .background(Brush.linearGradient(listOf(lerp(fill, Color.White, 0.16f), fill)), shape)
      .border(PopopxSize.hairline, PopopxHairlineInner, shape),
    contentAlignment = Alignment.Center
  ) {
    Icon(painterResource(icon), null, Modifier.size(PopopxSize.iconL), tint = tint.ink())
  }
}

/** The trailing status chip ("Selected" / "Automatic routing"): brand 14% background, brand text. */
@Composable
fun PopopxOnboardingChip(text: String) {
  Text(
    text,
    style = PopopxTypeScale.caption,
    color = PopopxBrand,
    modifier = Modifier
      .background(PopopxBrand.copy(alpha = PopopxAlpha.washStrong), RoundedCornerShape(PopopxRadiusChip))
      .padding(horizontal = PopopxSpace.xxs, vertical = PopopxSpace.xxs)
  )
}

/** `PopopxSectionCard`: optional heading, 16dp card, optional footnote. */
@Composable
fun PopopxOnboardingSectionCard(
  title: String? = null,
  footnote: String? = null,
  content: @Composable ColumnScope.() -> Unit,
) {
  PopopxSection(
    title = title,
    footnote = footnote,
    modifier = Modifier.padding(horizontal = PopopxSpace.m),
    content = content
  )
}

@Composable
fun PopopxOnboardingPrimaryButton(
  text: String,
  icon: ImageResource? = null,
  enabled: Boolean = true,
  loading: Boolean = false,
  mirrorIcon: Boolean = false,
  action: () -> Unit,
) {
  PopopxPrimaryButton(
    text = text,
    onClick = action,
    icon = icon,
    enabled = enabled,
    loading = loading,
    mirrorIcon = mirrorIcon
  )
}

@Composable
fun PopopxOnboardingGhostButton(
  text: String,
  icon: ImageResource? = null,
  mirrorIcon: Boolean = false,
  action: () -> Unit,
) {
  PopopxGhostButton(
    text = text,
    onClick = action,
    icon = icon,
    mirrorIcon = mirrorIcon
  )
}

/** The opaque bottom action bar: content scrolls underneath, a single hairline marks the top edge. */
@Composable
fun PopopxOnboardingBottomBar(content: @Composable ColumnScope.() -> Unit) {
  Column(
    Modifier
      .fillMaxWidth()
      .background(PopopxCanvas)
      .padding(horizontal = PopopxSpace.m)
      .padding(top = PopopxSpace.xs, bottom = PopopxSpace.xs),
    verticalArrangement = Arrangement.spacedBy(PopopxSpace.s),
    content = content
  )
}

/** `featureRow`: solid badge, semibold title, footnote note — one hairline separates two of them. */
@Composable
fun PopopxOnboardingFeatureRow(icon: ImageResource, tint: PopopxOnboardingTint, title: String, note: String) {
  Row(
    Modifier.fillMaxWidth().padding(vertical = PopopxSpace.xxs),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.s),
    verticalAlignment = Alignment.Top
  ) {
    PopopxOnboardingIconBadge(icon, tint)
    Column(verticalArrangement = Arrangement.spacedBy(PopopxSpace.xxs)) {
      Text(title, style = PopopxTypeScale.headline, color = popopxOnboardingLabel())
      Text(note, style = PopopxTypeScale.subheadline, color = popopxOnboardingSecondary())
    }
  }
}

/** The two-mode pill of the manifesto page: soft tinted icon square + label inside a chip-material capsule. */
@Composable
fun PopopxOnboardingModePill(icon: ImageResource, tint: PopopxOnboardingTint, label: String) {
  Row(
    Modifier
      .fillMaxWidth()
      .background(popopxOnboardingChipBackground(), RoundedCornerShape(PopopxRadiusControl))
      .border(PopopxSize.hairline, PopopxHairlineInner, RoundedCornerShape(PopopxRadiusControl))
      .padding(PopopxSpace.xxs),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xxs),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Box(
      Modifier
        .size(PopopxSize.iconBadge)
        .background(tint.fill().copy(alpha = PopopxAlpha.washStrong), RoundedCornerShape(PopopxRadiusChip)),
      contentAlignment = Alignment.Center
    ) {
      Icon(painterResource(icon), null, Modifier.size(PopopxSize.iconL), tint = tint.fill())
    }
    Text(label, style = PopopxTypeScale.caption, color = popopxOnboardingLabel(), modifier = Modifier.weight(1f))
  }
}

/** `PopopxTextField`: bordered tap target with a leading glyph; the visible text is the prompt until something is typed. */
@Composable
fun PopopxOnboardingTextField(
  prompt: String,
  value: MutableState<String>,
  icon: ImageResource,
  modifier: Modifier = Modifier,
) {
  var focused by remember { mutableStateOf(false) }
  val interactionSource = remember { MutableInteractionSource() }
  Row(
    modifier
      .fillMaxWidth()
      .heightIn(min = PopopxSize.control)
      .background(sectionCardColor(), RoundedCornerShape(PopopxRadiusControl))
      .border(
        if (focused) PopopxSize.focusRing else PopopxSize.stroke,
        if (focused) PopopxBrand else popopxOnboardingLabelHint(),
        RoundedCornerShape(PopopxRadiusControl)
      )
      .padding(horizontal = PopopxSpace.s),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Icon(
      painterResource(icon),
      null,
      Modifier.size(PopopxSize.iconXl),
      tint = if (focused) PopopxBrand else popopxOnboardingSecondary()
    )
    Box(Modifier.weight(1f)) {
      if (value.value.isEmpty()) {
        Text(
          prompt,
          style = PopopxTypeScale.body,
          color = popopxOnboardingSecondary(),
          maxLines = 1,
          overflow = TextOverflow.Ellipsis
        )
      }
      BasicTextField(
        value = value.value,
        onValueChange = { value.value = it },
        textStyle = PopopxTypeScale.body.copy(color = popopxOnboardingLabel()),
        singleLine = true,
        cursorBrush = SolidColor(PopopxBrand),
        keyboardOptions = KeyboardOptions.Default,
        interactionSource = interactionSource,
        modifier = Modifier
          .fillMaxWidth()
          .onFocusChanged { focused = it.isFocused }
      )
    }
  }
}

/** `PopopxButton(role: .secondary)`: the shared secondary button, one press contract for every page. */
@Composable
fun PopopxOnboardingSecondaryButton(
  text: String,
  icon: ImageResource? = null,
  action: () -> Unit,
) {
  PopopxSecondaryButton(
    text = text,
    onClick = action,
    icon = icon
  )
}

/** `PopopxToggleRow`: whole-row switch, 32dp badge, semibold title + caption note. */
@Composable
fun PopopxOnboardingToggleRow(
  title: String,
  note: String,
  icon: ImageResource,
  tint: PopopxOnboardingTint = PopopxOnboardingTint.BRAND,
  checked: Boolean,
  enabled: Boolean = true,
  onCheckedChange: (Boolean) -> Unit,
) {
  Row(
    Modifier
      .fillMaxWidth()
      .heightIn(min = PopopxSize.control)
      .clickable(enabled = enabled) { onCheckedChange(!checked) }
      .padding(vertical = PopopxSpace.xs),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.s),
    verticalAlignment = Alignment.CenterVertically
  ) {
    PopopxOnboardingIconBadge(icon, tint)
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(PopopxSpace.xxs)) {
      Text(title, style = PopopxTypeScale.headline, color = popopxOnboardingLabel())
      Text(note, style = PopopxTypeScale.subheadline, color = popopxOnboardingSecondary())
    }
    Spacer(Modifier.width(PopopxSpace.xs))
    PopopxSwitch(
      checked = checked,
      onCheckedChange = { if (enabled) onCheckedChange(it) },
      enabled = enabled
    )
  }
}

/** One of the three routing tiers: whole row is the control, four selected signals (wash, stroke, chip, solid dot). */
@Composable
fun PopopxOnboardingModeRow(
  title: String,
  note: String,
  selected: Boolean,
  chipText: String,
  compact: Boolean,
  onClick: () -> Unit,
) {
  Row(
    Modifier
      .fillMaxWidth()
      .background(
        if (selected) PopopxBrand.copy(alpha = 0.08f) else Color.Transparent,
        RoundedCornerShape(PopopxRadiusControl)
      )
      .border(
        if (selected) 1.5.dp else PopopxSize.hairline,
        if (selected) PopopxBrand else PopopxHairlineInner,
        RoundedCornerShape(PopopxRadiusControl)
      )
      .clickable(onClick = onClick)
      .padding(
        horizontal = PopopxSpace.xs,
        vertical = if (compact) PopopxSpace.xxs else PopopxSpace.s
      ),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.s),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(PopopxSpace.xxs)) {
      Text(
        title,
        style = PopopxTypeScale.headline,
        color = if (selected) PopopxBrand else popopxOnboardingLabel()
      )
      Text(note, style = PopopxTypeScale.subheadline, color = popopxOnboardingSecondary())
    }
    Spacer(Modifier.width(PopopxSpace.xs))
    if (selected) PopopxOnboardingChip(chipText)
    Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
      Box(
        Modifier
          .size(16.dp)
          .border(1.5.dp, if (selected) PopopxBrand else popopxOnboardingLabelHint(), CircleShape)
      )
      if (selected) {
        Box(Modifier.size(8.dp).background(PopopxBrand, CircleShape))
      }
    }
  }
}

/** The 16dp square check shared by the commitment rows and the agreement row. */
@Composable
fun PopopxOnboardingCheckSquare(checked: Boolean) {
  Box(
    Modifier
      .size(16.dp)
      .background(if (checked) PopopxBrand else Color.Transparent, RoundedCornerShape(PopopxRadiusChip))
      .border(
        1.5.dp,
        if (checked) Color.Transparent else popopxOnboardingLabelHint(),
        RoundedCornerShape(PopopxRadiusChip)
      ),
    contentAlignment = Alignment.Center
  ) {
    if (checked) {
      Text("✓", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = PopopxOnBrand, textAlign = TextAlign.Center)
    }
  }
}