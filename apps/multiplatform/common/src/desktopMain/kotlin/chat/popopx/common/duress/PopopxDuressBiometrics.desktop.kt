package chat.popopx.common.duress

import chat.popopx.common.views.helpers.LAResult

/**
 * Inert. Desktop has no equivalent of a strong-only biometric, and nothing in this phase mounts the duress keypad
 * there.
 *
 * `Unavailable` rather than `Success`: a platform that cannot answer the question must not be the reason a lock
 * screen opened.
 */
private object DesktopDuressBiometrics : PopopxDuressBiometrics {
  override fun available(): Boolean = false

  override suspend fun authenticate(title: String, subtitle: String?, onFailedAttempt: () -> Unit): LAResult =
    LAResult.Unavailable()
}

actual fun popopxDuressBiometrics(): PopopxDuressBiometrics = DesktopDuressBiometrics
