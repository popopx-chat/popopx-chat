package chat.popopx.common.ui.theme

import androidx.compose.runtime.Composable

/**
 * True when the platform asks for reduced motion (Android animator duration scale 0). Compose 1.8.2
 * carries [androidx.compose.ui.MotionDurationScale] only in the animation coroutine context, not as a
 * CompositionLocal, so the two infinite decorations (radar pulse, status breathing) read this gate
 * and stay still instead of animating forever.
 */
@Composable
expect fun popopxReducedMotion(): Boolean