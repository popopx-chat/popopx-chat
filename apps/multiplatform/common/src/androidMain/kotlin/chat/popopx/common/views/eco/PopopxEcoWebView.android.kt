package chat.popopx.common.views.eco

import android.annotation.SuppressLint
import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import java.io.ByteArrayInputStream

@SuppressLint("SetJavaScriptEnabled")
@Composable
actual fun PopopxEcoWebView(url: String, modifier: Modifier) {
  AndroidView(
    modifier = modifier,
    factory = { context ->
      WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = false
        settings.databaseEnabled = false
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.allowFileAccessFromFileURLs = false
        settings.allowUniversalAccessFromFileURLs = false
        settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        settings.cacheMode = WebSettings.LOAD_NO_CACHE
        settings.mediaPlaybackRequiresUserGesture = true
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true
        // The signed URL is only ever meant for the service account that issued the session. A page that
        // redirects elsewhere would receive `popopx_uid` and `sig` as its referrer, so nothing leaves this
        // origin and no non-web scheme is followed: `javascript:` and `file:` in an anchor are the classic
        // way an in-app browser escapes the restrictions it was given.
        webViewClient = object : WebViewClient() {
          override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
            !isWebOrigin(request.url)

          // A non-web target is answered here rather than by returning null, which would let the stack fetch
          // it: a 403 with no body is the only way to stop the request, and the empty headers carry no referrer
          // of their own. This is the same claim iOS makes by refusing the load in `decidePolicyFor`.
          override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): android.webkit.WebResourceResponse? =
            if (isWebOrigin(request.url)) null else android.webkit.WebResourceResponse(
              "text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0))
            )
        }
        loadUrl(url)
      }
    },
    onRelease = { view ->
      // Clearing the page before destroy() matters: the WebView keeps its last document in the process, and a
      // signed URL is a credential while the session secret behind it is still live.
      view.stopLoading()
      view.loadUrl("about:blank")
      view.destroy()
    }
  )
}

private fun isWebOrigin(uri: Uri?): Boolean = uri?.scheme == "http" || uri?.scheme == "https"
