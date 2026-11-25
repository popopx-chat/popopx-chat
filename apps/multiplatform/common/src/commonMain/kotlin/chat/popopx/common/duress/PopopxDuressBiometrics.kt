package chat.popopx.common.duress

import chat.popopx.common.views.helpers.LAResult

/**
 * The unlock prompt the duress screen asks for, and nothing else.
 *
 * This is deliberately a second entry point rather than another `LAMode` on the existing
 * `chat.popopx.common.views.helpers.authenticate`: `LocalAuthentication.android.kt:27` asks for
 * `BIOMETRIC_STRONG or DEVICE_CREDENTIAL`, and on Android that combination lets the system answer a biometric
 * failure with the lock-screen PIN. iOS states the reason for refusing that in `requestBiometricUnlock`: the
 * device-credential fallback bypasses this module's own keypad, and a bypass that skips the keypad also skips the
 * duress code, so the two-code scheme stops meaning anything. Only `BIOMETRIC_STRONG` is offered, and when it is
 * unavailable the caller goes to the keypad rather than to a weaker proof.
 *
 * The upstream file is untouched because desktop and the pre-existing app-lock flows depend on its behaviour;
 * narrowing it would move a shipped flow for a phase-3 requirement that only this screen has.
 */
interface PopopxDuressBiometrics {
  /** Whether a strong biometric can actually be prompted for right now. */
  fun available(): Boolean

  /**
   * Asks for one.
   *
   * Resumes only on a terminal answer, which is a correction of an upstream habit rather than a change to it: the
   * existing callers receive `LAResult.Failed` once per rejected finger and ignore it
   * (`AppLock.kt:95` — "Can be called multiple times on every failure"), so a suspend function that resumed on the
   * first one would end the flow while the system dialog is still open. Failed attempts therefore go to
   * [onFailedAttempt], which is also the only place the keypad downgrade can be counted from.
   */
  suspend fun authenticate(
    title: String,
    subtitle: String?,
    onFailedAttempt: () -> Unit = {},
  ): LAResult
}

expect fun popopxDuressBiometrics(): PopopxDuressBiometrics
