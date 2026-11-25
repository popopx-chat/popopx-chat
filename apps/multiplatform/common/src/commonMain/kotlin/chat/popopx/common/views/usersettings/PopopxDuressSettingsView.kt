package chat.popopx.common.views.usersettings

import SectionDividerSpaced
import SectionItemView
import SectionView
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import chat.popopx.common.duress.PopopxDuressAuthManager
import chat.popopx.common.duress.PopopxDuressSetupError
import chat.popopx.common.duress.PopopxUpstreamPasscodeImpl
import chat.popopx.common.platform.Log
import chat.popopx.common.platform.TAG
import chat.popopx.common.ui.theme.DEFAULT_PADDING
import chat.popopx.common.ui.theme.DEFAULT_PADDING_HALF
import chat.popopx.common.views.helpers.*
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource

/**
 * The settings half of the duress module — deliberately small.
 *
 * iOS's equivalent is a 2,257-line page (`PopopxAntiTheftSettingsView.swift`), and that page is in the untouched tier
 * of this pass, so what lives here is the part the Android keypad cannot function without: set or change the two
 * codes, the three switches, and one removal. Ruling 3 is the reason there is no mnemonic cell at all — this phase
 * does not implement BIP-39 recovery, so the page must not advertise a reset path that does not exist.
 *
 * Mounted only inside `if (appPlatform.isAndroid)`, so desktop's privacy screen and its baselines do not change.
 */
@Composable
fun PopopxDuressSettingsSection() {
  val manager = PopopxDuressAuthManager.shared
  // The switches are `var`s that persist on assignment, but Compose needs a state object to notice them, so each one
  // mirrors the manager's value and writes it straight back. A local copy that is never re-read is how a settings
  // screen ends up showing a switch the engine has already changed (see `duressEnabled`'s setter, which also deletes
  // the duress record).
  var duressOn by remember { mutableStateOf(manager.duressEnabled) }
  var biometricsOn by remember { mutableStateOf(manager.biometricsEnabled) }
  var tenStrikeOn by remember { mutableStateOf(manager.wipeOnTenthFailure) }
  val configured = remember { mutableStateOf(manager.normalConfigured to manager.duressConfigured) }

  fun sync() {
    manager.refreshConfiguration()
    configured.value = manager.normalConfigured to manager.duressConfigured
    duressOn = manager.duressEnabled
    biometricsOn = manager.biometricsEnabled
    tenStrikeOn = manager.wipeOnTenthFailure
  }

  SectionDividerSpaced()
  SectionView(stringResource(MR.strings.duress_settings_title)) {
    SectionItemView(null) {
      Text(
        stringResource(
          when {
            !configured.value.first -> MR.strings.duress_settings_status_none
            !configured.value.second -> MR.strings.duress_settings_status_entry_only
            else -> MR.strings.duress_settings_status_both
          }
        ),
        color = MaterialTheme.colors.onSurface.copy(alpha = 0.75f)
      )
    }
    SectionItemView({ showDuressCodeSheet(DuressCodeKind.ENTRY) { sync() } }) {
      Text(
        stringResource(
          if (configured.value.first) MR.strings.duress_settings_change_entry
          else MR.strings.duress_settings_set_entry
        ),
        color = MaterialTheme.colors.primary
      )
    }
    if (configured.value.first) {
      SectionItemView({ showDuressCodeSheet(DuressCodeKind.DURESS) { sync() } }) {
        Text(
          stringResource(
            if (configured.value.second) MR.strings.duress_settings_change_duress
            else MR.strings.duress_settings_set_duress
          ),
          color = MaterialTheme.colors.primary
        )
      }
      SectionItemView {
        Row(verticalAlignment = Alignment.CenterVertically) {
          Text(
            stringResource(MR.strings.duress_settings_duress_switch),
            Modifier.padding(end = 24.dp).fillMaxWidth().weight(1f)
          )
          DefaultSwitch(
            checked = duressOn,
            onCheckedChange = {
              // Turning the switch off deletes the duress record, inside the manager's own setter. The re-sync after
              // the write is what keeps this row honest.
              manager.duressEnabled = it
              duressOn = it
              sync()
            },
          )
        }
      }
      SectionItemView {
        Row(verticalAlignment = Alignment.CenterVertically) {
          Text(
            stringResource(MR.strings.duress_settings_biometrics),
            Modifier.padding(end = 24.dp).fillMaxWidth().weight(1f)
          )
          DefaultSwitch(
            checked = biometricsOn,
            onCheckedChange = {
              manager.biometricsEnabled = it
              biometricsOn = it
            },
          )
        }
      }
      SectionItemView {
        Row(verticalAlignment = Alignment.CenterVertically) {
          Text(
            stringResource(MR.strings.duress_settings_ten_strike),
            Modifier.padding(end = 24.dp).fillMaxWidth().weight(1f)
          )
          DefaultSwitch(
            checked = tenStrikeOn,
            onCheckedChange = {
              manager.wipeOnTenthFailure = it
              tenStrikeOn = it
            },
          )
        }
      }
      Text(
        stringResource(MR.strings.duress_settings_ten_strike_note),
        style = MaterialTheme.typography.caption,
        color = MaterialTheme.colors.onSurface.copy(alpha = 0.6f),
        modifier = Modifier.padding(horizontal = DEFAULT_PADDING, vertical = DEFAULT_PADDING_HALF)
      )
      if (configured.value.first) {
        SectionItemView({ confirmRemoveDuressCodes(::sync) }) {
          Text(
            stringResource(MR.strings.duress_settings_remove),
            color = MaterialTheme.colors.error
          )
        }
      }
    }
  }
}

private enum class DuressCodeKind { ENTRY, DURESS }

/**
 * The code sheet: two entries, and — only when the app still has an upstream passcode in front of this module — the
 * fields that hand it over.
 *
 * The native fields appear precisely when [PopopxDuressAuthManager.migrateNativeEntryPassword] would demand them,
 * because the migration runs **before** the new code is written and a refusal after the keypad has already collected
 * two entries would otherwise be an unexplained "nothing happened".
 */
private fun showDuressCodeSheet(kind: DuressCodeKind, onSaved: () -> Unit) {
  ModalManager.fullscreen.showCustomModal { close ->
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colors.background.copy(1f), contentColor = LocalContentColor.current) {
      PopopxDuressCodeSheet(kind, close = { close(); onSaved() })
    }
  }
}

@Composable
private fun PopopxDuressCodeSheet(kind: DuressCodeKind, close: () -> Unit) {
  val manager = PopopxDuressAuthManager.shared
  var pin by rememberSaveable { mutableStateOf("") }
  var confirm by rememberSaveable { mutableStateOf("") }
  var current by rememberSaveable { mutableStateOf("") }
  var native by rememberSaveable { mutableStateOf("") }
  var nativeSelfDestruct by rememberSaveable { mutableStateOf("") }
  var error by remember { mutableStateOf<CharSequence?>(null) }
  var busy by rememberSaveable { mutableStateOf(false) }

  // Read once: whether the upstream code exists does not change while this sheet is open, and asking the keystore on
  // every recomposition would be a keystroke-costing call in a text field's rewrite path.
  val migrating = remember { kind == DuressCodeKind.ENTRY && manager.nativeEntryPasswordActive() }
  // Changing the entry code proves ownership of the old one first. Setting one for the first time cannot: there is
  // nothing to prove against.
  val ownerGate = remember { kind == DuressCodeKind.ENTRY && manager.normalConfigured }
  val hasSelfDestruct = remember {
    migrating && PopopxUpstreamPasscodeImpl().selfDestructPasscode() != null
  }

  Column(
    Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = DEFAULT_PADDING),
    verticalArrangement = Arrangement.spacedBy(14.dp)
  ) {
    AppBarTitle(
      stringResource(
        when (kind) {
          DuressCodeKind.ENTRY -> if (manager.normalConfigured) MR.strings.duress_settings_change_entry else MR.strings.duress_settings_set_entry
          DuressCodeKind.DURESS -> if (manager.duressConfigured) MR.strings.duress_settings_change_duress else MR.strings.duress_settings_set_duress
        }
      )
    )
    Text(
      stringResource(
        when (kind) {
          DuressCodeKind.ENTRY -> MR.strings.duress_settings_entry_note
          DuressCodeKind.DURESS -> MR.strings.duress_settings_duress_note
        }
      ),
      style = MaterialTheme.typography.body2,
      color = MaterialTheme.colors.onSurface.copy(alpha = 0.75f)
    )
    if (migrating) {
      Text(
        stringResource(MR.strings.duress_settings_migration_note),
        style = MaterialTheme.typography.body2,
        color = MaterialTheme.colors.error
      )
    }
    CodeField(
      stringResource(MR.strings.duress_setup_pin_field),
      pin,
      enabled = !busy,
      onValueChange = { pin = digitsOnly(it) }
    )
    CodeField(
      stringResource(MR.strings.duress_setup_confirm_field),
      confirm,
      enabled = !busy,
      onValueChange = { confirm = digitsOnly(it) }
    )
    if (ownerGate) {
      CodeField(
        stringResource(MR.strings.duress_setup_current_field),
        current,
        enabled = !busy,
        onValueChange = { current = digitsOnly(it) }
      )
    }
    if (migrating) {
      CodeField(
        stringResource(MR.strings.duress_setup_native_field),
        native,
        enabled = !busy,
        numeric = false,
        onValueChange = { native = it }
      )
    }
    if (hasSelfDestruct) {
      CodeField(
        stringResource(MR.strings.duress_setup_self_destruct_field),
        nativeSelfDestruct,
        enabled = !busy,
        numeric = false,
        onValueChange = { nativeSelfDestruct = it }
      )
    }
    if (error != null) {
      Text(error.toString(), style = MaterialTheme.typography.body2, color = MaterialTheme.colors.error)
    }
    // The same predicate the keypad gates its confirm key with, so a sheet can never offer a save the engine will
    // refuse for shape reasons. Computed once: this rule appearing twice is how the colour and the tap drift apart.
    val ready = PopopxDuressAuthManager.isValidPin(pin)
      && pin == confirm
      && (!ownerGate || PopopxDuressAuthManager.isValidPin(current))
    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
      Text(
        stringResource(MR.strings.cancel_verb),
        color = MaterialTheme.colors.onSurface,
        modifier = Modifier.clickable(enabled = !busy) { close() }.padding(vertical = 10.dp)
      )
      Text(
        if (busy) stringResource(MR.strings.duress_settings_saving) else stringResource(MR.strings.duress_setup_save),
        color = if (!busy && ready) MaterialTheme.colors.primary else MaterialTheme.colors.onSurface.copy(alpha = 0.3f),
        modifier = Modifier
          .clickable(enabled = !busy && ready) {
            busy = true
            error = null
            withLongRunningApi {
              try {
                when (kind) {
                  DuressCodeKind.ENTRY -> {
                    if (ownerGate) manager.verifyEntryPin(current)
                    manager.setNormalPin(
                      pin,
                      confirm,
                      nativePasscode = native.ifEmpty { null },
                      nativeSelfDestructCode = nativeSelfDestruct.ifEmpty { null },
                    )
                  }
                  DuressCodeKind.DURESS -> manager.setDuressPin(pin, confirm)
                }
                Log.d(TAG, "duress setup: ${kind} recorded")
                close()
              } catch (e: PopopxDuressSetupError) {
                error = setupErrorMessage(e.kind)
                busy = false
              } catch (e: Exception) {
                error = setupErrorMessage(PopopxDuressSetupError.Kind.KeychainWriteFailed)
                busy = false
              }
            }
          }
          .padding(vertical = 10.dp)
      )
    }
    Spacer(Modifier.height(12.dp))
  }
}

@Composable
private fun CodeField(
  label: String,
  value: String,
  enabled: Boolean,
  numeric: Boolean = true,
  onValueChange: (String) -> Unit,
) {
  OutlinedTextField(
    value = value,
    onValueChange = onValueChange,
    label = { Text(label) },
    enabled = enabled,
    singleLine = true,
    visualTransformation = if (numeric) PasswordVisualTransformation() else VisualTransformation.None,
    keyboardOptions = KeyboardOptions(
      keyboardType = if (numeric) KeyboardType.NumberPassword else KeyboardType.Password
    ),
    modifier = Modifier.fillMaxWidth()
  )
}

private fun digitsOnly(value: String): String =
  value.filter { it in '0'..'9' }.take(PopopxDuressAuthManager.PIN_LENGTH)

private fun setupErrorMessage(kind: PopopxDuressSetupError.Kind): String = generalGetString(
  when (kind) {
    PopopxDuressSetupError.Kind.MalformedPin -> MR.strings.duress_error_malformed_pin
    PopopxDuressSetupError.Kind.PinsMustDiffer -> MR.strings.duress_error_pins_must_differ
    PopopxDuressSetupError.Kind.NormalPinRequiredFirst -> MR.strings.duress_error_normal_required
    PopopxDuressSetupError.Kind.EntryPinRequired -> MR.strings.duress_error_entry_required
    PopopxDuressSetupError.Kind.EntryPinIncorrect -> MR.strings.duress_error_entry_incorrect
    PopopxDuressSetupError.Kind.NativePasscodeRequired -> MR.strings.duress_error_native_passcode_required
    PopopxDuressSetupError.Kind.NativePasscodeIncorrect -> MR.strings.duress_error_native_passcode_incorrect
    PopopxDuressSetupError.Kind.NativeSelfDestructCodeRequired -> MR.strings.duress_error_self_destruct_required
    PopopxDuressSetupError.Kind.NativeSelfDestructCodeIncorrect -> MR.strings.duress_error_self_destruct_incorrect
    PopopxDuressSetupError.Kind.KeychainWriteFailed -> MR.strings.duress_error_write_failed
    PopopxDuressSetupError.Kind.BiometricDenied -> MR.strings.duress_error_biometric_denied
  }
)

/** The removal has to be confirmed: dropping the codes also drops the only thing that makes a duress entry mean anything. */
private fun confirmRemoveDuressCodes(onRemoved: () -> Unit) {
  AlertManager.shared.showAlertDialog(
    title = generalGetString(MR.strings.duress_settings_remove),
    text = generalGetString(MR.strings.duress_settings_remove_confirm),
    confirmText = generalGetString(MR.strings.duress_settings_remove),
    destructive = true,
    onConfirm = {
      PopopxDuressAuthManager.shared.clearAllPins()
      Log.d(TAG, "duress setup: records removed")
      onRemoved()
    },
    onDismiss = { },
  )
}
