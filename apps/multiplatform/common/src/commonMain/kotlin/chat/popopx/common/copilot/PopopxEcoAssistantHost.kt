package chat.popopx.common.copilot

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * What a platform must hand over for the whisper bar to exist, and the seam that keeps the bar in
 * commonMain without dragging `CalendarContract` into shared code.
 *
 * This is deliberately an installed value rather than an `expect fun`: the `expect`/`actual` pair
 * this feature already uses ([popopxPlatformEngines]) covers the engines, and a calendar needs
 * context, permissions and a coroutine-friendly surface that would have to be duplicated as a
 * desktop stub for no other reason than to compile. A platform that installs nothing gets nothing —
 * which is the correct desktop behaviour, and the correct behaviour for an apk built without the
 * calendar permissions too.
 */
class PopopxEcoGlue(
  val calendar: PopopxEcoCalendarAccess,
  /**
   * Draws — and drives — the calendar-permission prompt for a session that lacks the permission.
   *
   * Composable because the only supported way to request a runtime permission on Android is through
   * an activity-result launcher, which has to be created in composition. Null means the platform has
   * nothing to ask with, and then the bar says so instead of offering a control that does nothing.
   */
  val permissionUi: (@Composable (PopopxEcoSession) -> Unit)? = null,
  /** Whether the OS has the calendar permissions right now; a plain read, safe off the main thread. */
  val permissionsGranted: () -> Boolean = { calendar.permissionsGranted() },
)

/**
 * One assistant per surface, and the only place the assistant's state is held.
 *
 * The map is keyed by a caller-chosen string that names a *local* surface — a chat id, or the
 * discover tab — and nothing else. That key is not an address, a contact, or a session on the wire,
 * and it is the only identity the bar is given. This is the structural half of 「数据不出设备」: a
 * component that cannot name a recipient cannot message one, so the whisper bar has no way to reach
 * the peer even by passing the wrong argument.
 */
@Stable
class PopopxEcoSession internal constructor(
  val key: String,
  private val glue: PopopxEcoGlue,
) {
  /** The observer mode, the loaded engine and the release-on-background rule. */
  val state = PopopxEcoAssistantState()

  /** The turn machine: calendar read, sanitizer, planner, confirm gate. */
  private val assistant = PopopxEcoAssistant(state, glue.calendar)

  var reply by mutableStateOf<PopopxEcoReply?>(null)
    private set

  /** Proposals waiting for the tap. Re-read from the gate so a confirm removes its own card. */
  var cards by mutableStateOf<List<PopopxEcoConfirmGate.Pending>>(emptyList())
    private set

  /** A sentence about the last turn that produced nothing the user could act on. */
  var notice by mutableStateOf<String?>(null)
    private set

  var working by mutableStateOf(false)
    private set

  /** True while the green indicator line must be shown: the per-session assist is on. */
  val liveIndicator: Boolean get() = state.showsLiveIndicator

  /** The permission state as the UI last observed it, so a grant retires the prompt on its own. */
  var permissionsGranted by mutableStateOf(false)
    private set

  /** The bar's own text, always processed, with no authorisation needed for it. */
  suspend fun ask(text: String, history: List<String> = emptyList()) {
    if (text.isBlank() || working) return
    working = true
    notice = null
    refreshPermissions()
    val outcome = runCatching { assistant.onMessage(text, history.filter { it.isNotBlank() }) }
    working = false
    outcome.fold(
      onSuccess = { reply = it; notice = null; refreshCards() },
      onFailure = { reply = null; notice = FALLBACK_NOTICE },
    )
  }

  /** The only tap that can reach a calendar write, and it reaches it through the gate. */
  suspend fun confirm(id: Int): Boolean {
    val applied = runCatching { assistant.confirm(id) }.getOrDefault(false)
    refreshCards()
    notice = if (applied) null else CONFIRM_FAILED_NOTICE
    return applied
  }

  fun dismiss(id: Int) {
    assistant.dismiss(id)
    refreshCards()
  }

  /**
   * 「本机助理实时协助中」 — the per-session switch. Off when it was already on for this key, so one
   * tap is enough to leave, which is what the brief asks for.
   */
  fun toggleRealtime() {
    assistant.observe(key, PopopxEcoObserverMode.REALTIME_SESSION)
    refreshCards()
  }

  /** One tap back to zero listening: mode off, engine released, cards dropped. */
  fun turnOff() {
    assistant.observe(key, PopopxEcoObserverMode.OFF)
    assistant.enteredBackground()
    reply = null
    notice = null
    refreshCards()
  }

  /** The summon from the normal input: authorises five preceding messages, for this turn only. */
  fun summon() {
    assistant.observe(key, PopopxEcoObserverMode.SUMMON_LAST_MESSAGES)
  }

  fun enteredBackground() {
    assistant.enteredBackground()
    reply = null
    notice = null
    refreshCards()
  }

  /** Re-reads the OS and publishes the answer, so a grant retires the prompt without a poll. */
  fun refreshPermissions(): Boolean {
    val granted = glue.permissionsGranted()
    permissionsGranted = granted
    return granted
  }

  /** Called by the platform slot with the outcome of the system dialog. */
  fun onPermissionResult(granted: Boolean) {
    permissionsGranted = granted
    if (!granted) notice = PERMISSION_DENIED_NOTICE
  }

  /**
   * The permission affordance for this session, drawn by the platform that owns the launcher.
   *
   * A slot rather than a call because requesting a runtime permission on Android has to be built in
   * composition (`rememberLauncherForActivityResult`), and because a platform with nothing to ask —
   * permissions already granted, or no calendar at all — draws nothing. This keeps `CalendarContract`
   * and the permission API out of shared code without turning the prompt into a silent no-op.
   */
  @Composable
  fun PermissionAffordance() {
    val slot = glue.permissionUi
    if (!permissionsGranted && slot != null) slot(this)
  }

  private fun refreshCards() {
    cards = assistant.pendingProposals
  }

  companion object {
    /** Shown when a turn could not be completed; no detail, because the detail would be calendar content. */
    const val FALLBACK_NOTICE = "the assistant could not read this turn"
    const val CONFIRM_FAILED_NOTICE = "the calendar was not written"
    const val PERMISSION_DENIED_NOTICE = "calendar access was not granted"
  }
}

/**
 * The registry: installs the platform glue once, and hands out one session per local surface.
 *
 * Sessions are kept rather than rebuilt because [PopopxEcoAssistantState] is the thing the user
 * toggled — dropping it on recomposition would silently turn the assist off while the indicator
 * still claims it is on, which is the exact failure this feature cannot have.
 */
object PopopxEcoAssistantHost {
  private var glue: PopopxEcoGlue? = null
  private val sessions = LinkedHashMap<String, PopopxEcoSession>()

  /** Installed by the platform layer. An app built without calendar access never calls this. */
  fun install(glue: PopopxEcoGlue) {
    this.glue = glue
    sessions.clear()
  }

  val available: Boolean get() = glue != null

  /** The session for a local surface, or null when this platform has no assistant at all. */
  fun session(key: String): PopopxEcoSession? {
    val installed = glue ?: return null
    return sessions.getOrPut(key) { PopopxEcoSession(key, installed) }
  }

  /**
   * Called when the process leaves the foreground. Releases the weights and expires the outstanding
   * cards for every surface, because a card that survived backgrounding could be confirmed against a
   * calendar the user changed elsewhere.
   */
  fun enteredBackground() {
    sessions.values.toList().forEach { it.enteredBackground() }
  }
}
