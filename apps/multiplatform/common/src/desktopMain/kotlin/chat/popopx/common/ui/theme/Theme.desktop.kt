package chat.popopx.common.ui.theme

import androidx.compose.runtime.Composable
import chat.popopx.common.platform.Log
import chat.popopx.common.platform.TAG
import chat.popopx.common.platform.desktopPlatform
import chat.popopx.common.platform.systemThemeDetector
import com.jthemedetecor.OsThemeDetector

private val detector: OsThemeDetector? = systemThemeDetector
  ?.apply {
    registerListener(::reactOnDarkThemeChanges)
    if (desktopPlatform.isLinux()) Runtime.getRuntime().addShutdownHook(Thread(::stopGsettingsMonitor))
  }

private fun stopGsettingsMonitor() =
  ProcessHandle.current().children()
    .filter { it.info().command().orElse("").contains("gsettings") }
    .forEach { it.destroy() }

// TODO: explore possibility to use
//@Composable
//actual fun isSystemInDarkTheme(): Boolean = androidx.compose.foundation.isSystemInDarkTheme()

@Composable
actual fun isSystemInDarkTheme(): Boolean = try {
  detector?.isDark ?: false
}
catch (e: Exception) {
  Log.e(TAG, e.stackTraceToString())
  /* On Mac this code can produce exception */
  false
}
