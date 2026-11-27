package chat.popopx.common.ui.theme

import androidx.compose.animation.core.spring

// The two springs of PopopxSpring (apps/ios/Shared/Theme/PopopxTheme.swift:238-248), restated in
// Compose's mass-spring units: response r maps to stiffness (2π/r)² with mass 1, so snappy
// (0.3 s, damping 0.85) is 440 and fluid (0.4 s, damping 1.0) is 250. Press scale is the same 0.97
// the iOS button style applies.
val PopopxSnappySpring = spring<Float>(dampingRatio = 0.85f, stiffness = 440f)
val PopopxFluidSpring = spring<Float>(dampingRatio = 1f, stiffness = 250f)
const val PopopxPressScale = 0.97f