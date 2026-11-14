package chat.popopx.common.views.badges

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import chat.popopx.common.BuildConfigCommon
import chat.popopx.common.platform.*
import chat.popopx.common.ui.theme.*
import chat.popopx.common.views.helpers.*
import chat.popopx.common.views.newchat.darkStops
import chat.popopx.common.views.newchat.gradientPoints
import chat.popopx.common.views.newchat.lightStops
import chat.popopx.res.*

@Composable
fun SupportPOPOPXBanner(
  title: String = generalGetString(MR.strings.badges_banner_title),
  subtitle: String = generalGetString(MR.strings.badges_banner_subtitle),
  warning: Boolean = false,
  showDismiss: Boolean = true,
  onTap: () -> Unit,
  onDismiss: () -> Unit
) {
  // the card's own height, for centring the fallback hero; hero stays fixed so its above-card
  // overhang shrinks at very large fonts
  val cardHeight = (72.dp * fontSizeMultiplier).coerceAtLeast(72.dp)
  val cardTrailingPadding = 8.dp
  val heroWidth = 110.dp
  // shorter than the natural drawn height so ContentScale.Crop slices the phone body at card bottom
  val heroVisibleHeight = 108.dp
  // hero right edge sits at the dismiss X's icon left edge (X: outer 4pt + inner-pad 8 + half of 16pt icon)
  val heroTrailingPadding = 28.dp
  val textToHeroGap = 6.dp

  // Layout sizes to the card; hero is placed at y = cardHeight - heroHeight (negative → hero
  // overhangs above card at normal fonts, 0/positive → hero fits inside card at large fonts).
  Layout(content = {
    Box(Modifier.fillMaxWidth()) {
      Row(
        Modifier
          .bannerCard(onTap)
          .padding(
            start = 16.dp,
            end = cardTrailingPadding + heroWidth + heroTrailingPadding + textToHeroGap,
            top = 12.dp,
            bottom = 12.dp
          ),
        verticalAlignment = Alignment.CenterVertically
      ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
          Text(
            title,
            style = MaterialTheme.typography.body1,
            fontWeight = FontWeight.SemiBold,
            color = if (warning) Color.Red else MaterialTheme.colors.primary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
          )
          Text(
            subtitle,
            style = MaterialTheme.typography.body2,
            color = MaterialTheme.colors.onBackground,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
          )
        }
      }

      if (showDismiss) {
        BannerDismissButton(Modifier.align(Alignment.TopEnd), onDismiss)
      }
    }

    HeroThumbnail(
      heroWidth = heroWidth,
      heroVisibleHeight = heroVisibleHeight,
      cardHeight = cardHeight,
      trailingPadding = heroTrailingPadding
    )
  }) { measurables, constraints ->
    val cardPlaceable = measurables[0].measure(constraints)
    val heroPlaceable = measurables[1].measure(constraints.copy(minWidth = 0, minHeight = 0))
    layout(cardPlaceable.width, cardPlaceable.height) {
      cardPlaceable.place(0, 0)
      heroPlaceable.place(cardPlaceable.width - heroPlaceable.width, cardPlaceable.height - heroPlaceable.height)
    }
  }
}

@Composable
private fun HeroThumbnail(heroWidth: Dp, heroVisibleHeight: Dp, cardHeight: Dp, trailingPadding: Dp) {
  if (BuildConfigCommon.POPOPX_ASSETS) {
    // draws at natural aspect, top-aligned in a shorter slot; ContentScale.Crop cuts the overflow at card bottom
    Image(
      painterResource(if (isInDarkTheme()) MR.images.phone_supporter_light else MR.images.phone_supporter),
      contentDescription = null,
      contentScale = ContentScale.Crop,
      alignment = Alignment.TopCenter,
      modifier = Modifier.padding(end = trailingPadding).size(width = heroWidth, height = heroVisibleHeight)
    )
  } else {
    val badgeSize = 48.dp
    Image(
      painterResource(MR.images.badge_supporter),
      contentDescription = null,
      contentScale = ContentScale.Fit,
      modifier = Modifier
        .padding(end = trailingPadding + 12.dp, top = (cardHeight - badgeSize) / 2, bottom = (cardHeight - badgeSize) / 2)
        .size(badgeSize)
    )
  }
}

// Banner chrome for the chat-list banner (`SupportPOPOPXBanner`); one declaration so the cards
// cannot drift apart in appearance.
@Composable
fun Modifier.bannerCard(onTap: () -> Unit): Modifier {
  // grows linearly with system font but never shrinks below the default, and the card grows further
  // when 2-line text wraps at very large fonts
  val cardHeight = (72.dp * fontSizeMultiplier).coerceAtLeast(72.dp)
  val isDark = isInDarkTheme()
  var cardSize by remember { mutableStateOf(IntSize.Zero) }
  val brush = remember(isDark, cardSize) { gradientBrush(isDark, cardSize) }
  return this
    .fillMaxWidth()
    .heightIn(min = cardHeight)
    .clip(RoundedCornerShape(16.dp))
    .background(brush)
    .clickable(onClick = onTap)
    .onSizeChanged { cardSize = it }
}

// Same X pattern as OneHandUICard: circle-clipped clickable region with inner padding for hit area.
@Composable
fun BannerDismissButton(modifier: Modifier, onDismiss: () -> Unit) {
  Icon(
    painterResource(MR.images.ic_close),
    contentDescription = stringResource(MR.strings.icon_descr_close_button),
    tint = if (isInDarkTheme()) MaterialTheme.colors.onBackground else MaterialTheme.colors.secondary,
    modifier = modifier
      .padding(end = 4.dp, top = 4.dp)
      .clip(CircleShape)
      .clickable(onClick = onDismiss)
      .padding(8.dp)
      .size(16.dp)
  )
}

// Geometry-aware gradient with asymmetric scale: start (dark) pushed further below the card than
// end (warm) is above, so card-middle lands at the bright/mid-transition stop, not the dark region.
private fun gradientBrush(isDark: Boolean, size: IntSize): Brush {
  val stops = if (isDark) darkStops else lightStops
  if (size.width == 0 || size.height == 0) return Brush.linearGradient(colorStops = stops)
  val w = size.width.toFloat()
  val h = size.height.toFloat()
  val startScale = if (isDark) 3.0f else 2.5f
  val endScale = if (isDark) 2.1f else 1.7f
  val gp = gradientPoints(h / w, 1.0f)
  val sx = 0.5f + (gp.startX - 0.5f) * startScale
  val sy = 0.5f + (gp.startY - 0.5f) * startScale
  val ex = 0.5f + (gp.endX - 0.5f) * endScale
  val ey = 0.5f + (gp.endY - 0.5f) * endScale
  return Brush.linearGradient(
    colorStops = stops,
    start = Offset(sx * w, sy * h),
    end = Offset(ex * w, ey * h)
  )
}
