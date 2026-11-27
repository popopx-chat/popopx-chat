package chat.popopx.common.views.onboarding

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.ui.theme.*
import chat.popopx.common.views.helpers.AutoMirroredIcon
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.compose.painterResource

// The Android reading of the iOS onboarding atoms (apps/ios/Shared/Views/Onboarding/OnboardingView.swift,
// PopopxControls.swift): the same 4/8/12/16/24 metrics, 8/12/16 corner radii, 0.5/1/1.5 stroke set and
// PopopxPalette tokens. Shared by the four onboarding screens only, so desktop keeps its own layout.

val PopopxOnboardingGutter = 16.dp
val PopopxOnboardingSpace2XS = 4.dp
val PopopxOnboardingSpaceXS = 8.dp
val PopopxOnboardingSpaceS = 12.dp
val PopopxOnboardingSpaceM = 16.dp
val PopopxOnboardingSpaceL = 24.dp
val PopopxOnboardingRadiusChip = 8.dp
val PopopxOnboardingRadiusControl = 12.dp
val PopopxOnboardingRadiusCard = 16.dp
val PopopxOnboardingHairlineWidth = 0.5.dp
val PopopxOnboardingDividerWidth = 1.dp
val PopopxOnboardingMinHitTarget = 44.dp

private const val POPOPX_ONBOARDING_SECONDARY_ALPHA = 0.62f
private const val POPOPX_ONBOARDING_LABEL_HINT_ALPHA = 0.35f

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
fun popopxOnboardingSecondary() = MaterialTheme.colors.onBackground.copy(alpha = POPOPX_ONBOARDING_SECONDARY_ALPHA)

@Composable
fun popopxOnboardingLabelHint() = MaterialTheme.colors.onBackground.copy(alpha = POPOPX_ONBOARDING_LABEL_HINT_ALPHA)

@Composable
private fun popopxOnboardingChipBackground() =
  MaterialTheme.colors.onBackground.copy(alpha = if (isInDarkTheme()) 0.08f else 0.04f)

/** The `step / steps` capsule, stage label, title, note and the multi-segment progress track shared by screens 2, 3 and 4. */
@Composable
fun PopopxOnboardingHeader(step: Int, steps: Int, stage: String, title: String, note: String? = null) {
  Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceXS)) {
    Row(
      Modifier
        .background(popopxOnboardingChipBackground(), RoundedCornerShape(PopopxOnboardingRadiusChip))
        .border(PopopxOnboardingHairlineWidth, PopopxHairlineInner, RoundedCornerShape(PopopxOnboardingRadiusChip))
        .padding(horizontal = PopopxOnboardingSpaceXS, vertical = PopopxOnboardingSpace2XS),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceXS)
    ) {
      Text(
        "$step / $steps",
        fontSize = 11.sp,
        fontFamily = FontFamily.Monospace,
        color = PopopxBrand
      )
      Box(Modifier.width(PopopxOnboardingHairlineWidth).height(12.dp).background(PopopxSeparator))
      Text(
        stage,
        fontSize = 12.sp,
        color = popopxOnboardingSecondary(),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis
      )
    }
    Text(
      title,
      fontSize = 22.sp,
      fontWeight = FontWeight.SemiBold,
      color = popopxOnboardingLabel(),
      lineHeight = 28.sp
    )
    if (note != null) {
      Text(
        note,
        fontSize = 15.sp,
        color = popopxOnboardingSecondary(),
        lineHeight = 20.sp
      )
    }
    Row(Modifier.fillMaxWidth().padding(top = PopopxOnboardingSpaceXS), horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpace2XS)) {
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
      .height(PopopxOnboardingSpace2XS)
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
  Box(
    Modifier
      .fillMaxWidth()
      .padding(vertical = PopopxOnboardingSpaceXS)
      .height(PopopxOnboardingHairlineWidth)
      .background(PopopxSeparator)
  )
}

/** The rounded coloured icon badge at the head of a row: a tint gradient, a 0.5dp light rim and a soft halo. */
@Composable
fun PopopxOnboardingIconBadge(icon: ImageResource, tint: PopopxOnboardingTint) {
  val fill = tint.fill()
  val shape = RoundedCornerShape(PopopxOnboardingRadiusChip)
  Box(
    Modifier
      .size(32.dp)
      .drawBehind {
        val radius = size.minDimension * 0.85f
        drawCircle(
          brush = Brush.radialGradient(
            colors = listOf(fill.copy(alpha = 0.28f), fill.copy(alpha = 0f)),
            center = center,
            radius = radius
          ),
          radius = radius
        )
      }
      .background(Brush.linearGradient(listOf(lerp(fill, Color.White, 0.16f), fill)), shape)
      .border(
        PopopxOnboardingHairlineWidth,
        Color.White.copy(alpha = if (isInDarkTheme()) 0.18f else 0.30f),
        shape
      ),
    contentAlignment = Alignment.Center
  ) {
    Icon(painterResource(icon), null, Modifier.size(18.dp), tint = tint.ink())
  }
}

/** The trailing status chip ("Selected" / "Automatic routing"): brand 14% background, brand text. */
@Composable
fun PopopxOnboardingChip(text: String) {
  Text(
    text,
    fontSize = 12.sp,
    color = PopopxBrand,
    modifier = Modifier
      .background(PopopxBrand.copy(alpha = 0.14f), RoundedCornerShape(PopopxOnboardingRadiusChip))
      .padding(horizontal = PopopxOnboardingSpace2XS, vertical = PopopxOnboardingSpace2XS)
  )
}

/** `PopopxSectionCard`: optional heading, 16dp card, optional footnote. */
@Composable
fun PopopxOnboardingSectionCard(
  title: String? = null,
  footnote: String? = null,
  content: @Composable ColumnScope.() -> Unit,
) {
  Column(Modifier.fillMaxWidth().padding(horizontal = PopopxOnboardingGutter)) {
    if (title != null) {
      Text(
        title,
        fontSize = 17.sp,
        fontWeight = FontWeight.SemiBold,
        color = popopxOnboardingLabel(),
        modifier = Modifier.padding(start = PopopxOnboardingSpace2XS, bottom = PopopxOnboardingSpaceXS)
      )
    }
    Surface(
      Modifier.fillMaxWidth(),
      shape = RoundedCornerShape(PopopxOnboardingRadiusCard),
      color = sectionCardColor(),
      border = BorderStroke(PopopxOnboardingHairlineWidth, PopopxHairlineInner),
      elevation = if (isInDarkTheme()) 0.dp else 1.dp,
    ) {
      Column(Modifier.padding(PopopxOnboardingSpaceM), content = content)
    }
    if (footnote != null) {
      Text(
        footnote,
        fontSize = 13.sp,
        color = popopxOnboardingSecondary(),
        lineHeight = 17.sp,
        modifier = Modifier.padding(start = PopopxOnboardingSpace2XS, top = PopopxOnboardingSpaceXS)
      )
    }
  }
}

@Composable
private fun popopxPressScale(interactionSource: MutableInteractionSource): Float {
  val pressed by interactionSource.collectIsPressedAsState()
  return animateFloatAsState(
    targetValue = if (pressed) PopopxPressScale else 1f,
    animationSpec = PopopxSnappySpring,
    label = "onboarding-press-scale"
  ).value
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
  val interactionSource = remember { MutableInteractionSource() }
  val pressScale = popopxPressScale(interactionSource)
  Surface(
    shape = RoundedCornerShape(PopopxOnboardingRadiusControl),
    color = PopopxBrand.copy(alpha = if (enabled) 1f else 0.45f),
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = PopopxOnboardingMinHitTarget)
      .graphicsLayer {
        scaleX = pressScale
        scaleY = pressScale
      }
      .clickable(
        interactionSource = interactionSource,
        indication = LocalIndication.current,
        enabled = enabled && !loading,
        onClick = action
      )
  ) {
    Box(
      Modifier.padding(horizontal = PopopxOnboardingSpaceM, vertical = PopopxOnboardingSpaceS),
      contentAlignment = Alignment.Center
    ) {
      if (loading) {
        CircularProgressIndicator(Modifier.size(18.dp), color = PopopxOnBrand, strokeWidth = 2.dp)
      } else {
        Row(horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceXS), verticalAlignment = Alignment.CenterVertically) {
          if (icon != null) {
            if (mirrorIcon) AutoMirroredIcon(painterResource(icon), null, Modifier.size(18.dp), tint = PopopxOnBrand)
            else Icon(painterResource(icon), null, Modifier.size(18.dp), tint = PopopxOnBrand)
          }
          Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = PopopxOnBrand)
        }
      }
    }
  }
}

@Composable
fun PopopxOnboardingGhostButton(
  text: String,
  icon: ImageResource? = null,
  mirrorIcon: Boolean = false,
  action: () -> Unit,
) {
  val interactionSource = remember { MutableInteractionSource() }
  val pressScale = popopxPressScale(interactionSource)
  Row(
    Modifier
      .fillMaxWidth()
      .heightIn(min = PopopxOnboardingMinHitTarget)
      .graphicsLayer {
        scaleX = pressScale
        scaleY = pressScale
      }
      .clickable(
        interactionSource = interactionSource,
        indication = LocalIndication.current,
        onClick = action
      )
      .padding(horizontal = PopopxOnboardingSpaceM, vertical = PopopxOnboardingSpaceS),
    horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceXS, Alignment.CenterHorizontally),
    verticalAlignment = Alignment.CenterVertically
  ) {
    if (icon != null) {
      if (mirrorIcon) AutoMirroredIcon(painterResource(icon), null, Modifier.size(18.dp), tint = PopopxBrand)
      else Icon(painterResource(icon), null, Modifier.size(18.dp), tint = PopopxBrand)
    }
    Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = PopopxBrand)
  }
}

/** The opaque bottom action bar: content scrolls underneath, a single hairline marks the top edge. */
@Composable
fun PopopxOnboardingBottomBar(content: @Composable ColumnScope.() -> Unit) {
  Column(
    Modifier
      .fillMaxWidth()
      .background(MaterialTheme.colors.background)
      .padding(horizontal = PopopxOnboardingGutter)
      .padding(top = PopopxOnboardingSpaceXS, bottom = PopopxOnboardingSpaceXS),
    verticalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceS),
    content = content
  )
}

/** `featureRow`: solid badge, semibold title, footnote note — one hairline separates two of them. */
@Composable
fun PopopxOnboardingFeatureRow(icon: ImageResource, tint: PopopxOnboardingTint, title: String, note: String) {
  Row(
    Modifier.fillMaxWidth().padding(vertical = PopopxOnboardingSpace2XS),
    horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceS),
    verticalAlignment = Alignment.Top
  ) {
    PopopxOnboardingIconBadge(icon, tint)
    Column(verticalArrangement = Arrangement.spacedBy(PopopxOnboardingSpace2XS)) {
      Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = popopxOnboardingLabel())
      Text(note, fontSize = 13.sp, color = popopxOnboardingSecondary(), lineHeight = 17.sp)
    }
  }
}

/** The two-mode pill of the manifesto page: soft tinted icon square + label inside a chip-material capsule. */
@Composable
fun PopopxOnboardingModePill(icon: ImageResource, tint: PopopxOnboardingTint, label: String) {
  Row(
    Modifier
      .fillMaxWidth()
      .background(popopxOnboardingChipBackground(), RoundedCornerShape(PopopxOnboardingRadiusControl))
      .border(PopopxOnboardingHairlineWidth, PopopxHairlineInner, RoundedCornerShape(PopopxOnboardingRadiusControl))
      .padding(PopopxOnboardingSpace2XS),
    horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpace2XS),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Box(
      Modifier.size(32.dp).background(tint.fill().copy(alpha = 0.14f), RoundedCornerShape(PopopxOnboardingRadiusChip)),
      contentAlignment = Alignment.Center
    ) {
      Icon(painterResource(icon), null, Modifier.size(18.dp), tint = tint.fill())
    }
    Text(label, fontSize = 12.sp, color = popopxOnboardingLabel(), lineHeight = 15.sp, modifier = Modifier.weight(1f))
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
      .heightIn(min = PopopxOnboardingMinHitTarget)
      .background(sectionCardColor(), RoundedCornerShape(PopopxOnboardingRadiusControl))
      .border(
        if (focused) 1.5.dp else 1.dp,
        if (focused) PopopxBrand else popopxOnboardingLabelHint(),
        RoundedCornerShape(PopopxOnboardingRadiusControl)
      )
      .padding(horizontal = PopopxOnboardingSpaceS),
    horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceXS),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Icon(
      painterResource(icon),
      null,
      Modifier.size(24.dp),
      tint = if (focused) PopopxBrand else popopxOnboardingSecondary()
    )
    Box(Modifier.weight(1f)) {
      if (value.value.isEmpty()) {
        Text(prompt, fontSize = 16.sp, color = popopxOnboardingSecondary(), maxLines = 1, overflow = TextOverflow.Ellipsis)
      }
      BasicTextField(
        value = value.value,
        onValueChange = { value.value = it },
        textStyle = TextStyle(fontSize = 16.sp, color = popopxOnboardingLabel()),
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

/** `PopopxButton(role: .secondary)`: card fill, label ink, a 1dp label-hint border. */
@Composable
fun PopopxOnboardingSecondaryButton(
  text: String,
  icon: ImageResource? = null,
  action: () -> Unit,
) {
  val interactionSource = remember { MutableInteractionSource() }
  val pressScale = popopxPressScale(interactionSource)
  Surface(
    shape = RoundedCornerShape(PopopxOnboardingRadiusControl),
    color = sectionCardColor(),
    border = BorderStroke(1.dp, popopxOnboardingLabelHint()),
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = PopopxOnboardingMinHitTarget)
      .graphicsLayer {
        scaleX = pressScale
        scaleY = pressScale
      }
      .clickable(
        interactionSource = interactionSource,
        indication = LocalIndication.current,
        onClick = action
      )
  ) {
    Row(
      Modifier.padding(horizontal = PopopxOnboardingSpaceM, vertical = PopopxOnboardingSpaceS),
      horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceXS, Alignment.CenterHorizontally),
      verticalAlignment = Alignment.CenterVertically
    ) {
      if (icon != null) Icon(painterResource(icon), null, Modifier.size(18.dp), tint = popopxOnboardingLabel())
      Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = popopxOnboardingLabel())
    }
  }
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
      .heightIn(min = PopopxOnboardingMinHitTarget)
      .clickable(enabled = enabled) { onCheckedChange(!checked) }
      .padding(vertical = PopopxOnboardingSpaceXS),
    horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceS),
    verticalAlignment = Alignment.CenterVertically
  ) {
    PopopxOnboardingIconBadge(icon, tint)
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(PopopxOnboardingSpace2XS)) {
      Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = popopxOnboardingLabel())
      Text(note, fontSize = 13.sp, color = popopxOnboardingSecondary(), lineHeight = 17.sp)
    }
    Spacer(Modifier.width(PopopxOnboardingSpaceXS))
    Switch(
      checked = checked,
      onCheckedChange = { if (enabled) onCheckedChange(it) },
      enabled = enabled,
      colors = SwitchDefaults.colors(
        checkedThumbColor = Color.White,
        checkedTrackColor = PopopxBrand,
        uncheckedThumbColor = Color.White,
        uncheckedTrackColor = MaterialTheme.colors.onBackground.copy(alpha = 0.18f),
      )
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
        RoundedCornerShape(PopopxOnboardingRadiusControl)
      )
      .border(
        if (selected) 1.5.dp else PopopxOnboardingHairlineWidth,
        if (selected) PopopxBrand else PopopxHairlineInner,
        RoundedCornerShape(PopopxOnboardingRadiusControl)
      )
      .clickable(onClick = onClick)
      .padding(
        horizontal = PopopxOnboardingSpaceXS,
        vertical = if (compact) PopopxOnboardingSpace2XS else PopopxOnboardingSpaceS
      ),
    horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceS),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(PopopxOnboardingSpace2XS)) {
      Text(
        title,
        fontSize = 17.sp,
        fontWeight = FontWeight.SemiBold,
        color = if (selected) PopopxBrand else popopxOnboardingLabel()
      )
      Text(note, fontSize = 13.sp, color = popopxOnboardingSecondary(), lineHeight = 17.sp)
    }
    Spacer(Modifier.width(PopopxOnboardingSpaceXS))
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
      .background(if (checked) PopopxBrand else Color.Transparent, RoundedCornerShape(PopopxOnboardingRadiusChip))
      .border(
        1.5.dp,
        if (checked) Color.Transparent else popopxOnboardingLabelHint(),
        RoundedCornerShape(PopopxOnboardingRadiusChip)
      ),
    contentAlignment = Alignment.Center
  ) {
    if (checked) {
      Text("✓", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = PopopxOnBrand, textAlign = TextAlign.Center)
    }
  }
}