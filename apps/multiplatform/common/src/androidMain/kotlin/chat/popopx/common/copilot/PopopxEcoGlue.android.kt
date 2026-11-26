package chat.popopx.common.copilot

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource

/**
 * Android's half of the copilot: installs the calendar behind the seam the shared whisper bar reads,
 * and draws the one piece of UI that cannot exist in commonMain — a runtime permission request.
 *
 * Called from `PopopxApp.onCreate`, which is where this app already keeps process-wide platform
 * wiring ([chat.popopx.common.platform.AppContextProvider] is initialized in the same place). Nothing
 * here loads a model, queries a calendar, or registers a receiver beyond the lifecycle hop the app
 * already owns.
 */
fun installPopopxEcoCopilot(context: Context) {
  val appContext = context.applicationContext
  PopopxEcoAssistantHost.install(
    PopopxEcoGlue(
      calendar = PopopxAndroidCalendar(appContext),
      permissionUi = { session -> PopopxEcoCalendarPermissionRow(session) },
      // One read of the OS state, so the shared code never has to name a permission.
      permissionsGranted = { popopxEcoCalendarPermissionsGranted(appContext) },
    )
  )
}

/** Both calendar permissions, or the assistant can plan but cannot write, which is the same as neither. */
fun popopxEcoCalendarPermissionsGranted(context: Context): Boolean =
  PopopxAndroidCalendar.POPOPX_CALENDAR_PERMISSIONS.all {
    ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
  }

/**
 * The prompt, drawn only while a session is missing the permission.
 *
 * [rememberLauncherForActivityResult] with `RequestMultiplePermissions` is the app's existing idiom
 * for a runtime permission (see `ComposeView.android.kt` for the single-permission form and
 * `GetImageView.android.kt` for the helper): the request is made from composition, the result comes
 * back into the session, and the row disappears when the session observes the grant. No settings
 * screen is opened on the user's behalf, and no rationale dialog is invented — the line says what the
 * permission is for and the system dialog says the rest.
 */
@Composable
private fun PopopxEcoCalendarPermissionRow(session: PopopxEcoSession) {
  val launcher = rememberLauncherForActivityResult(contract = ActivityResultContracts.RequestMultiplePermissions()) { results ->
    // A partial grant is a denial for this feature: READ without WRITE means a card that cannot be
    // confirmed, and telling the user the assistant is ready would be the wrong answer.
    session.onPermissionResult(results.values.all { it })
  }
  Row(
    Modifier
      .fillMaxWidth()
      .padding(horizontal = 8.dp, vertical = 4.dp),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Column(Modifier.weight(1f)) {
      Text(
        stringResource(MR.strings.copilot_permission_title),
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary
      )
      Text(
        stringResource(MR.strings.copilot_permission_body),
        fontSize = 11.sp,
        color = MaterialTheme.colors.secondary,
        modifier = Modifier.padding(top = 2.dp)
      )
    }
    Spacer(Modifier.width(8.dp))
    Text(
      stringResource(MR.strings.copilot_permission_action),
      fontSize = 13.sp,
      color = MaterialTheme.colors.primary,
      modifier = Modifier
        .clip(RoundedCornerShape(8.dp))
        .clickable { launcher.launch(PopopxAndroidCalendar.POPOPX_CALENDAR_PERMISSIONS) }
        .padding(horizontal = 8.dp, vertical = 6.dp)
    )
  }
  // After a denial the system stops showing the dialog, so the only route left is the app's own
  // settings page; offered as a second line rather than opened automatically.
  if (session.notice == PopopxEcoSession.PERMISSION_DENIED_NOTICE) {
    Text(
      stringResource(MR.strings.copilot_permission_settings),
      fontSize = 12.sp,
      color = MaterialTheme.colors.primary,
      modifier = Modifier
        .padding(horizontal = 8.dp, vertical = 4.dp)
        .clickable { openCopilotAppSettings() }
    )
  }
}

/** The app's entry in system settings, which is where a permanently denied permission is recovered. */
private fun openCopilotAppSettings() {
  val context = chat.popopx.common.platform.AppContextProvider.getApplicationContext() ?: return
  val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
    data = Uri.fromParts("package", context.packageName, null)
    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
  }
  runCatching { context.startActivity(intent) }
}

/**
 * The background hook.
 *
 * `PopopxApp` already observes [androidx.lifecycle.ProcessLifecycleOwner] and gets `ON_STOP`; this is
 * the call it makes there. It releases the weights for every surface and drops every outstanding
 * confirm card, so returning to the app never leaves a proposal that could be written against a
 * calendar the user changed while away.
 */
fun popopxEcoEnteredBackground() {
  PopopxEcoAssistantHost.enteredBackground()
}
