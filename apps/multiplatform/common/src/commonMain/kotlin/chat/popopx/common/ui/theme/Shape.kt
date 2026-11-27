package chat.popopx.common.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Shapes
import androidx.compose.ui.unit.dp

val Shapes = Shapes(
  small = RoundedCornerShape(4.dp),
  medium = RoundedCornerShape(4.dp),
  large = RoundedCornerShape(0.dp)
)

// The corner radii of PopopxMetrics (apps/ios/Shared/Theme/PopopxTheme.swift:171-178). Surfaces that the
// iOS golden draws as a card, a control or a message bubble read these instead of restating 16/12/4/8.
val PopopxRadiusCard = 16.dp
val PopopxRadiusControl = 12.dp
val PopopxRadiusChip = 8.dp
val PopopxRadiusBubbleTuck = 4.dp
val PopopxRadiusSheet = 20.dp
val PopopxRadiusAvatar = 8.dp
