package chat.popopx.common.platform

import chat.popopx.common.simplexWindowState

actual fun allowedToShowNotification(): Boolean = !popopxWindowState.windowFocused.value
