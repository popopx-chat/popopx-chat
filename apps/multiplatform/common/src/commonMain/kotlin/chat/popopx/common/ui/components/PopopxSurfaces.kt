package chat.popopx.common.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Surface
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import chat.popopx.common.ui.theme.PopopxAlpha
import chat.popopx.common.ui.theme.PopopxElevation
import chat.popopx.common.ui.theme.PopopxHairlineStrong
import chat.popopx.common.ui.theme.PopopxHairlineInner
import chat.popopx.common.ui.theme.PopopxRadiusCard
import chat.popopx.common.ui.theme.PopopxRadiusChip
import chat.popopx.common.ui.theme.PopopxSeparator
import chat.popopx.common.ui.theme.PopopxSize
import chat.popopx.common.ui.theme.PopopxSpace
import chat.popopx.common.ui.theme.PopopxSurface
import chat.popopx.common.ui.theme.PopopxTypeScale
import chat.popopx.common.ui.theme.isInDarkTheme
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.compose.painterResource

/**
 * The single card surface of the Android design system: 16dp corners, a 0.5dp hairline, white on the
 * light canvas and #1C1C1E on OLED. Light cards keep the 1dp lift; dark cards separate by value.
 */
@Composable
fun PopopxCard(
  modifier: Modifier = Modifier,
  shape: Shape = RoundedCornerShape(PopopxRadiusCard),
  color: Color = PopopxSurface,
  border: BorderStroke? = BorderStroke(PopopxSize.hairline, PopopxHairlineStrong),
  elevation: Dp = if (isInDarkTheme()) 0.dp else PopopxElevation.card,
  contentPadding: PaddingValues = PaddingValues(PopopxSpace.m),
  content: @Composable ColumnScope.() -> Unit,
) {
  Surface(
    modifier = modifier.fillMaxWidth(),
    shape = shape,
    color = color,
    border = border,
    elevation = elevation,
  ) {
    Column(Modifier.padding(contentPadding), content = content)
  }
}

/**
 * `PopopxSectionCard`: optional eyebrow heading, the card, optional footnote. This is the one
 * definition behind Me, Cabin and Onboarding cards; those pages no longer carry their own copy.
 */
@Composable
fun PopopxSection(
  title: String? = null,
  footnote: String? = null,
  modifier: Modifier = Modifier,
  content: @Composable ColumnScope.() -> Unit,
) {
  Column(modifier.fillMaxWidth()) {
    if (title != null) {
      Text(
        title,
        style = PopopxTypeScale.headline,
        color = MaterialTheme.colors.onBackground,
        modifier = Modifier.padding(start = PopopxSpace.xxs, bottom = PopopxSpace.xs)
      )
    }
    PopopxCard {
      content()
    }
    if (footnote != null) {
      Text(
        footnote,
        style = PopopxTypeScale.subheadline,
        color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
        modifier = Modifier.padding(start = PopopxSpace.xxs, top = PopopxSpace.xs)
      )
    }
  }
}

/** The row separator inside a card, with the 8dp breathing room the iOS section atom carries. */
@Composable
fun PopopxDivider(modifier: Modifier = Modifier) {
  Box(
    modifier
      .fillMaxWidth()
      .padding(vertical = PopopxSpace.xs)
      .height(PopopxSize.hairline)
      .background(PopopxSeparator)
  )
}

/** A 32dp rounded icon badge: a 14% tint wash, an 18dp glyph. */
@Composable
fun PopopxIconBadge(
  icon: ImageResource,
  tint: Color,
  modifier: Modifier = Modifier,
  side: Dp = PopopxSize.iconBadge,
  iconSide: Dp = PopopxSize.iconL,
) {
  Box(
    modifier
      .size(side)
      .background(tint.copy(alpha = PopopxAlpha.wash), RoundedCornerShape(PopopxRadiusChip)),
    contentAlignment = Alignment.Center
  ) {
    Icon(painterResource(icon), null, Modifier.size(iconSide), tint = tint)
  }
}

/** The out-of-line card an empty shelf or empty tab draws, without inventing a second section shape. */
@Composable
fun PopopxEmptyCard(
  modifier: Modifier = Modifier,
  content: @Composable ColumnScope.() -> Unit,
) {
  Surface(
    modifier = modifier.fillMaxWidth(),
    shape = RoundedCornerShape(PopopxRadiusCard),
    color = PopopxSurface,
    border = BorderStroke(PopopxSize.hairline, PopopxHairlineInner),
    elevation = if (isInDarkTheme()) 0.dp else PopopxElevation.card,
  ) {
    Column(Modifier.padding(PopopxSpace.l), horizontalAlignment = Alignment.CenterHorizontally, content = content)
  }
}