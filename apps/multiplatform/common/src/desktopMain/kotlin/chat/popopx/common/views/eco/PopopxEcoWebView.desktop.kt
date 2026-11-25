package chat.popopx.common.views.eco

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/**
 * Desktop draws nothing, because desktop never mounts an eco surface: every call site is gated on
 * `appPlatform.isAndroid` (PopopxEcoMount.kt), and the desktop app has never carried the service-account
 * ecosystem. The actual exists because `expect` requires one.
 *
 * A placeholder that said "open this link in your browser" was considered and rejected: it would be reachable
 * only if a mount ever lost its gate, and at that point the honest failure is a blank page, not an invitation
 * to send the signed URL to a different app.
 */
@Composable
actual fun PopopxEcoWebView(url: String, modifier: Modifier) = Unit
