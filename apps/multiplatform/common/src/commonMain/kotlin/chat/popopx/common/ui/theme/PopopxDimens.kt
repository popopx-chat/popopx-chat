package chat.popopx.common.ui.theme

import androidx.compose.ui.unit.dp

// The 4/8/12/16/24 lattice and the control sizes the Android reading of PopopxMetrics uses
// (apps/ios/Shared/Theme/PopopxTheme.swift:134-205). Only Android-only pages draw with these;
// the Material palettes, the global Typography and the desktop tree are not touched.

object PopopxSpace {
  val xxs = 4.dp
  val xs = 8.dp
  val s = 12.dp
  val m = 16.dp
  val l = 24.dp
  val xl = 32.dp
  val xxl = 48.dp
  val gutter = m
}

object PopopxSize {
  /** The iOS hairline. A 0.5dp stroke lands on one physical pixel at 2x and two at 3x. */
  val hairline = 0.5.dp
  val stroke = 1.0.dp
  val focusRing = 1.5.dp

  /** Visual heights: 44 is the smallest control, 48 is the interactive target. */
  val control = 44.dp
  val hitTarget = 48.dp
  val button = 48.dp
  val pill = 32.dp
  val row = 44.dp

  val iconXs = 12.dp
  val iconS = 14.dp
  val iconM = 16.dp
  val iconL = 18.dp
  val iconXl = 24.dp

  val iconBadge = 32.dp
  val statusDot = 8.dp
}

object PopopxElevation {
  /** Light cards float by one dp; OLED cards are separated by their surface value, not by shadow. */
  val card = 1.dp
  val bar = 12.dp
  val pressed = 0.dp
}

object PopopxAlpha {
  /** Tinted icon-badge wash. */
  const val wash = 0.12f
  const val washStrong = 0.14f
  const val press = 0.08f
  const val disabled = 0.45f
  const val track = 0.18f
  const val hint = 0.35f
  const val secondary = 0.62f
  const val separator = 0.12f
}