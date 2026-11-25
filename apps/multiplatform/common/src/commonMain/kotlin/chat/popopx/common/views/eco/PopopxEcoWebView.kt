package chat.popopx.common.views.eco

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/**
 * The in-app browser the signed service page opens in.
 *
 * iOS uses `SFSafariViewController` (PopopxH5Launcher.swift:232-249), which is a browser the app does not
 * implement and cannot read. Android has no such view: the only in-app option is `android.webkit.WebView`,
 * which this app must configure itself. The hand-back-to-external-browser alternative is not equivalent — an
 * external browser is another app, and the signed URL carries the pairwise uid and the HMAC that identify this
 * user to the service account, so leaking it to a third-party process would leak the credential.
 *
 * The Android actual therefore keeps the page in-process and narrows what that process may reach: http/https
 * only, no file or content URIs, no DOM storage, no cache, and no navigation to another scheme.
 */
@Composable
expect fun PopopxEcoWebView(url: String, modifier: Modifier = Modifier)
