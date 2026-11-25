package chat.popopx.common.views.localauth

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Surface
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.AppLock
import chat.popopx.common.duress.AndroidStorageWipeHost
import chat.popopx.common.duress.PopopxDuressAttempt
import chat.popopx.common.duress.PopopxDuressAuthManager
import chat.popopx.common.duress.PopopxLockoutSchedule
import chat.popopx.common.duress.PopopxStorageWipe
import chat.popopx.common.eco.PopopxChannelKeyRotation
import chat.popopx.common.model.ChatModel
import chat.popopx.common.platform.Log
import chat.popopx.common.platform.TAG
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.common.views.helpers.withLongRunningApi
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.delay

/**
 * The lock screen the duress module owns — the keypad, the cooldown, the biometric shortcut, the storage wipe and the
 * three-tap gate in one composable.
 *
 * Android-only: mounted from `AppLock.runAuthenticate` behind `appPlatform.isAndroid`, so desktop never composes a
 * line of it and none of the 376 baselines can move.
 *
 * The sentences are the iOS overlay's sentences (`PopopxLockCopy`, PopopxAppLockOverlayView.swift:116-127), and the
 * load-bearing one is that the wiping code and the ordinary code get **word-for-word the same** prompt and the same
 * "Unlocking…" while the answer is computed. Any other wording is the signal a bystander reads off the screen.
 */
@Composable
fun PopopxDuressLockView(
  onUnlocked: () -> Unit,
  onDismiss: () -> Unit,
) {
  val manager = PopopxDuressAuthManager.shared
  val pin = rememberSaveable { mutableStateOf("") }
  var busy by rememberSaveable { mutableStateOf(false) }
  var hint by remember { mutableStateOf<CharSequence?>(null) }
  var lockedOutFor by remember { mutableStateOf(0.0) }
  val panic = remember { PopopxPanicWipeUiState() }

  // What is on disk wins over what an earlier composition cached: a code set — or erased — on the settings screen
  // has to be visible here before the first key is pressed.
  LaunchedEffect(Unit) { manager.refreshConfiguration() }

  val lockedOut = lockedOutFor > 0.0
  // The cooldown is a wall clock, so it is re-read while it says locked. Keyed on the derived boolean rather than on
  // the seconds: the loop writes the seconds, so keying on them would restart the effect every tick.
  LaunchedEffect(lockedOut) {
    if (!lockedOut) return@LaunchedEffect
    while (manager.remainingLockoutSeconds > 0.0) {
      delay(1000)
      lockedOutFor = manager.remainingLockoutSeconds
    }
    lockedOutFor = 0.0
    hint = null
  }
  val keypadLive = !busy && !lockedOut

  fun completeUnlock() {
    // iOS's order (`PopopxAppLockOverlayView.swift:602-618`): clear the biometric debt *before* unlocking, then
    // unlock. The debt is deliberately not paid by `submit`, so if this line is missing, a user who failed two
    // sheets stays on the keypad until the code is typed — forever, because nothing else resets it.
    manager.resetBiometricFailures()
    AppLock.laFailed.value = false
    pin.value = ""
    hint = null
    lockedOutFor = 0.0
    busy = false
    onUnlocked()
  }

  fun submit() {
    if (!PopopxDuressAuthManager.isValidPin(pin.value) || busy) return
    busy = true
    hint = null
    withLongRunningApi {
      when (val attempt = manager.submit(pin.value)) {
        PopopxDuressAttempt.Unlocked -> completeUnlock()
        PopopxDuressAttempt.Duress -> {
          // The wiping code. Nothing on screen separates this from an ordinary unlock — same sentence, same minimum
          // flow — and there is no process exit on this path: the app has to end up looking freshly installed rather
          // than crashed (iOS rule 1, restated in `PopopxStorageWipe`). `execute` is a suspend call and this block is
          // already off the main thread, which is what keeps the overwriting from blocking the UI.
          val channels = PopopxChannelKeyRotation.shared.channels
          PopopxStorageWipe(
            AndroidStorageWipeHost(
              ChatModel,
              ecoIds = {
                channels.mapNotNull { it.issuerContactId }.distinct() to channels.map { it.channelId }.distinct()
              },
            ),
            log = { Log.d(TAG, "duress wipe: $it") },
          ).execute()
          completeUnlock()
        }
        PopopxDuressAttempt.Wrong -> {
          hint = generalGetString(MR.strings.duress_lock_wrong)
          pin.value = ""
          busy = false
        }
        is PopopxDuressAttempt.LockedOut -> {
          lockedOutFor = attempt.remainingSeconds
          busy = false
        }
        PopopxDuressAttempt.NotConfigured -> {
          // The record is gone from under this screen. Hand the door back to whatever flow the app owns instead of
          // showing a keypad that can never be right.
          busy = false
          onDismiss()
        }
      }
    }
  }

  fun askBiometrically() {
    if (busy) return
    busy = true
    withLongRunningApi {
      val attempt = try {
        manager.requestBiometricUnlock()
      } catch (e: Exception) {
        // The manager raises only for a prompt refused during a cooldown, which is the keypad's message to show.
        null
      }
      if (attempt == PopopxDuressAttempt.Unlocked) {
        completeUnlock()
      } else {
        // Every other answer, including "this device has no biometric", ends at the keypad. That is the downgrade the
        // routing rule is for, and it never goes the other way; the cooldown is re-read because the refused prompt
        // may itself have spent a strike.
        hint = generalGetString(MR.strings.duress_lock_wrong)
        lockedOutFor = manager.remainingLockoutSeconds
        busy = false
      }
    }
  }

  Box(Modifier.fillMaxSize().systemBarsPadding()) {
    Column(
      Modifier.fillMaxSize(),
      horizontalAlignment = Alignment.CenterHorizontally,
      verticalArrangement = Arrangement.SpaceBetween
    ) {
      Spacer(Modifier.height(28.dp))

      Column(horizontalAlignment = Alignment.CenterHorizontally) {
        // The three-tap gate lives on the headline: the one element that is always visible and is not a control, so
        // arming the wipe costs nothing that another tap needs. The reason the corner trigger iOS mounts is not
        // copied here is in the commit body.
        Text(
          if (lockedOut) generalGetString(MR.strings.duress_lock_disabled_title)
          else generalGetString(MR.strings.duress_lock_locked_title),
          style = MaterialTheme.typography.h2,
          modifier = Modifier
            .padding(12.dp)
            .pointerInput(Unit) { detectTapGestures(onTap = { panic.tap() }) }
        )
        Text(
          text = when {
            busy -> generalGetString(MR.strings.duress_lock_unlocking)
            hint != null -> hint.toString()
            else -> generalGetString(MR.strings.duress_lock_prompt)
          },
          style = MaterialTheme.typography.body1,
          textAlign = TextAlign.Center,
          color = if (hint != null) MaterialTheme.colors.error else MaterialTheme.colors.onSurface,
          modifier = Modifier.padding(horizontal = 32.dp),
          maxLines = 3
        )
        Spacer(Modifier.height(22.dp))
        PinDots(pin.value.length, busy)
        Spacer(Modifier.height(10.dp))
        // The count is spoken and shown; it never contains a digit of the code itself (iOS:850-858).
        Text(
          if (pin.value.length == PopopxDuressAuthManager.PIN_LENGTH)
            stringResource(MR.strings.duress_lock_digits_complete, PopopxDuressAuthManager.PIN_LENGTH)
          else
            stringResource(MR.strings.duress_lock_digits_progress, pin.value.length, PopopxDuressAuthManager.PIN_LENGTH),
          style = MaterialTheme.typography.caption,
          color = MaterialTheme.colors.onSurface.copy(alpha = 0.5f)
        )
      }

      if (lockedOut) {
        // The cooldown reads from the schedule's parts and from nowhere else: a second place that assembles numbers
        // is a second place that can disagree with the lock.
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
          Text(
            stringResource(MR.strings.duress_lock_disabled_format, lockoutPhrase(lockedOutFor)),
            style = MaterialTheme.typography.body1,
            color = MaterialTheme.colors.error,
            textAlign = TextAlign.Center
          )
          Spacer(Modifier.height(8.dp))
          Text(
            generalGetString(MR.strings.duress_lock_disabled_footnote),
            style = MaterialTheme.typography.caption,
            color = MaterialTheme.colors.onSurface.copy(alpha = 0.6f),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 32.dp)
          )
        }
      } else {
        Spacer(Modifier.height(8.dp))
      }

      Keypad(
        pin = pin,
        live = keypadLive,
        onSubmit = { submit() },
        onBiometric = { askBiometrically() },
        biometricAvailable = manager.prefersBiometricUnlock && !lockedOut,
      )
    }

    PopopxPanicWipeConfirm(panic)
  }
}

/** The cooldown duration in words, from the one reduction [PopopxLockoutSchedule] exposes. */
@Composable
private fun lockoutPhrase(seconds: Double): String {
  val remaining = PopopxLockoutSchedule.remaining(seconds)
  return when {
    remaining.hours > 0L && remaining.showsMinutesWithHours ->
      stringResource(MR.strings.duress_lockout_hours_minutes, remaining.hours, remaining.minutes)
    remaining.hours > 0L -> stringResource(MR.strings.duress_lockout_hours, remaining.hours)
    remaining.showsSecondsWithMinutes ->
      stringResource(MR.strings.duress_lockout_minutes_seconds, remaining.minutes, remaining.seconds)
    remaining.minutes > 0L -> stringResource(MR.strings.duress_lockout_minutes, remaining.minutes)
    else -> stringResource(MR.strings.duress_lockout_seconds, remaining.seconds)
  }
}

/**
 * The dot row. [busy] is the "breathing" stage: iOS keeps the dots static and moves only opacity and scale, because
 * a progress shape that changes while the answer is computed would tell the user which branch was taken.
 */
@Composable
private fun PinDots(filled: Int, busy: Boolean) {
  Row(horizontalArrangement = Arrangement.spacedBy(11.dp)) {
    for (i in 0 until PopopxDuressAuthManager.PIN_LENGTH) {
      Box(
        Modifier
          .size(12.dp)
          .clip(CircleShape)
          .background(
            when {
              busy -> MaterialTheme.colors.primary.copy(alpha = 0.45f)
              i < filled -> MaterialTheme.colors.primary
              else -> MaterialTheme.colors.onSurface.copy(alpha = 0.22f)
            }
          )
      )
    }
  }
}

private const val KEY_SIZE = 76

@Composable
private fun Keypad(
  pin: MutableState<String>,
  live: Boolean,
  onSubmit: () -> Unit,
  onBiometric: () -> Unit,
  biometricAvailable: Boolean,
) {
  // Sizes are fixed, not derived from the box: this column is unbounded in one axis on a phone, so
  // `minOf(maxWidth, maxHeight)` can be infinite. iOS's floor is the real constraint — `minHitTarget` (44) plus one
  // spacing step (PopopxLockLayout.keySide) — and the action keys are the same size as the digits or delete is the
  // one key a thumb misses.
  Column(
    Modifier
      .fillMaxWidth()
      .padding(bottom = 26.dp)
      .semantics { contentDescription = generalGetString(MR.strings.duress_lock_keypad) },
    horizontalAlignment = Alignment.CenterHorizontally
  ) {
    DigitRow(1, 2, 3, pin, live)
    Spacer(Modifier.height(14.dp))
    DigitRow(4, 5, 6, pin, live)
    Spacer(Modifier.height(14.dp))
    DigitRow(7, 8, 9, pin, live)
    Spacer(Modifier.height(14.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
      ActionKey(generalGetString(MR.strings.duress_lock_delete), live && pin.value.isNotEmpty()) {
        pin.value = pin.value.dropLast(1)
      }
      Spacer(Modifier.width(KEY_SIZE.dp))
      ActionKey(
        generalGetString(MR.strings.duress_lock_send),
        live && PopopxDuressAuthManager.isValidPin(pin.value),
        emphasise = true,
        action = onSubmit
      )
    }
    Spacer(Modifier.height(16.dp))
    // The one biometric shortcut, and it is rendered only while the routing rule still allows it. Refusing to render
    // it during a cooldown is not decoration: a prompt that can unlock is how a cooldown would be bypassed.
    if (biometricAvailable) {
      val label = generalGetString(MR.strings.duress_lock_biometric)
      Text(
        label,
        color = MaterialTheme.colors.primary,
        modifier = Modifier
          .clickable(enabled = live, onClickLabel = label, role = Role.Button) { onBiometric() }
          .padding(12.dp)
      )
    } else {
      Spacer(Modifier.height(20.dp))
    }
  }
}

@Composable
private fun DigitRow(a: Int, b: Int, c: Int, pin: MutableState<String>, live: Boolean) {
  Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
    DigitKey(a, pin, live)
    DigitKey(b, pin, live)
    DigitKey(c, pin, live)
  }
}

@Composable
private fun DigitKey(digit: Int, pin: MutableState<String>, live: Boolean) {
  Key(live, digit.toString(), action = {
    // The cap is the engine's own length rather than a UI preference: there is no auto-submit, so a seventh digit
    // would silently change what the confirm key then sends.
    if (pin.value.length < PopopxDuressAuthManager.PIN_LENGTH) pin.value += digit.toString()
  }, label = {
    Text(digit.toString(), fontSize = 28.sp, fontWeight = FontWeight.Normal, color = MaterialTheme.colors.onSurface)
  })
}

@Composable
private fun ActionKey(label: String, enabled: Boolean, emphasise: Boolean = false, action: () -> Unit) {
  Key(enabled, label, emphasise, action) {
    Text(
      label,
      fontSize = 15.sp,
      color = if (enabled) MaterialTheme.colors.primary else MaterialTheme.colors.onSurface.copy(alpha = 0.3f)
    )
  }
}

@Composable
private fun Key(
  enabled: Boolean,
  onClickLabel: String,
  emphasise: Boolean = false,
  action: () -> Unit,
  label: @Composable () -> Unit,
) {
  Box(
    Modifier
      .size(KEY_SIZE.dp)
      .clip(RoundedCornerShape(50))
      .background(if (emphasise && enabled) MaterialTheme.colors.primary.copy(alpha = 0.14f) else Color.Transparent)
      .clickable(enabled = enabled, onClickLabel = onClickLabel, role = Role.Button) { action() },
    contentAlignment = Alignment.Center
  ) {
    label()
  }
}

/** Mounts the keypad over whatever the app was about to show, on the host the shipped passcode modal uses. */
fun showDuressLockScreen(onUnlocked: () -> Unit, onDismiss: () -> Unit) {
  ModalManager.fullscreen.showPasscodeCustomModal(oneTime = false) { close ->
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colors.background.copy(1f)) {
      PopopxDuressLockView(
        onUnlocked = { close(); onUnlocked() },
        onDismiss = { close(); onDismiss() },
      )
    }
  }
}
