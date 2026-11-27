package chat.popopx.common.views.helpers

import androidx.compose.material.Icon
import androidx.compose.material.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection

/** Icons that point along the reading direction (back, forward, disclosure chevrons) point the other
 *  way in RTL, matching the automatic mirroring SwiftUI applies to the iOS set. */
@Composable
fun AutoMirroredIcon(
  painter: Painter,
  contentDescription: String?,
  modifier: Modifier = Modifier,
  tint: Color = LocalContentColor.current,
) {
  val mirrored = LocalLayoutDirection.current == LayoutDirection.Rtl
  Icon(painter, contentDescription, if (mirrored) modifier.scale(-1f, 1f) else modifier, tint)
}