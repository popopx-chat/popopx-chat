package chat.popopx.common.duress

import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import chat.popopx.common.platform.mainActivity
import chat.popopx.common.views.helpers.LAResult
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

private const val STRONG_ONLY = BiometricManager.Authenticators.BIOMETRIC_STRONG

/**
 * The `BIOMETRIC_STRONG`-only prompt, kept separate from `LocalAuthentication.android.kt` for the reason stated on
 * the interface: adding `or DEVICE_CREDENTIAL` would let the lock-screen PIN answer in place of the keypad, and the
 * keypad is where a duress code is typed.
 *
 * Anything the device cannot do with a strong biometric is `Unavailable`, which the caller reads as "use the
 * keypad" — never as "fall back to something weaker".
 */
private class AndroidDuressBiometrics : PopopxDuressBiometrics {
  override fun available(): Boolean {
    val activity = mainActivity.get() ?: return false
    // `canAuthenticate(Int)` with an authenticator bitmask is API 28+; below that there is no strong-only mode to
    // ask for at all, so the keypad is the only honest answer.
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
    return BiometricManager.from(activity).canAuthenticate(STRONG_ONLY) == BiometricManager.BIOMETRIC_SUCCESS
  }

  override suspend fun authenticate(
    title: String,
    subtitle: String?,
    onFailedAttempt: () -> Unit,
  ): LAResult {
    val activity = mainActivity.get() ?: return LAResult.Error("")
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return LAResult.Unavailable()
    if (BiometricManager.from(activity).canAuthenticate(STRONG_ONLY) != BiometricManager.BIOMETRIC_SUCCESS) {
      return LAResult.Unavailable()
    }
    return suspendCancellableCoroutine { cont ->
      val prompt = BiometricPrompt(
        activity,
        ContextCompat.getMainExecutor(activity),
        object : BiometricPrompt.AuthenticationCallback() {
          override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
            // A user dismissal is an error code here, not `onAuthenticationFailed`, and the two must not be
            // collapsed: only a genuine failed read counts toward the keypad downgrade.
            if (errorCode == BiometricPrompt.ERROR_USER_CANCELED || errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON) {
              cont.resume(LAResult.Error(errString))
            } else {
              cont.resume(LAResult.Unavailable(errString))
            }
          }

          override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
            cont.resume(LAResult.Success)
          }

          override fun onAuthenticationFailed() {
            // Non-terminal: the dialog stays open and the user may try again, so this reports the attempt without
            // ending the call.
            onFailedAttempt()
          }
        }
      )
      val info = BiometricPrompt.PromptInfo.Builder()
        .setTitle(title)
        .setSubtitle(subtitle.orEmpty())
        .setAllowedAuthenticators(STRONG_ONLY)
        .setConfirmationRequired(false)
        // Required by the API when device credentials are not allowed: without a way out `authenticate()` throws
        // instead of showing a prompt. A dismissal reports `Error`, not a failed read, so it never counts toward the
        // keypad downgrade.
        .setNegativeButtonText(generalGetString(MR.strings.cancel_verb))
        .build()
      prompt.authenticate(info)
    }
  }
}

actual fun popopxDuressBiometrics(): PopopxDuressBiometrics = AndroidDuressBiometrics()
