package chat.popopx.common.copilot

/**
 * The engine the app talks to, and the one rule that decides which implementation answers:
 * the bundled weights may only be read after their SHA-256 has been checked against
 * [PopopxNeedleAssets.modelSha256], which is this file's only job.
 *
 * The digest check is not a performance concern dressed up as security. A `.cact` file is mmapped
 * tensor data that the engine then executes, so a tampered asset is the one input in this feature
 * for which "it parsed" is not evidence of anything.
 */
expect object PopopxNeedleAssets {
  /** The SHA-256 of the `needle3.cact` committed into the bundle, lowercase hex. */
  val modelSha256: String

  /** Where the bundle keeps it: an Android asset path or an iOS bundle relative path. */
  val modelPath: String

  /** Bytes the file must be, checked before it is hashed; a truncated copy hashes to something new. */
  val modelBytes: Long

  /** True when the platform can find and read the bundled weights at all. */
  fun bundledModelPresent(): Boolean

  /** The one entry point: read the asset, verify it, and hand the bytes to the engine. */
  fun loadVerifiedModel(): PopopxVerifiedModel
}

/** Weights that passed verification, kept separate so an unverified buffer cannot reach the engine. */
class PopopxVerifiedModel internal constructor(val bytes: ByteArray, val engine: PopopxEdgeCopilotEngine)

/** The engine the platform layer actually provides. */
expect fun popopxPlatformEngines(facts: PopopxEcoFacts): List<PopopxEdgeCopilotEngine>

/** The digest of a byte array, lowercase hex; only used on the bundled weights. */
expect fun popopxSha256Hex(bytes: ByteArray): String

/**
 * How the assistant is allowed to look at a conversation.
 *
 * The default is [OFF] and there is no state in which the app reads history without the user having
 * entered it in this session: the brief's 「默认零监听」 is implemented as `OFF` being the initial
 * value of a `var` that no code path writes to except the two toggles the user can see.
 */
enum class PopopxEcoObserverMode {
  /** Nothing is read, not even the current message. The initial value. */
  OFF,

  /** Only the message the user typed with the summon token, plus the 5 that precede it. */
  SUMMON_LAST_MESSAGES,

  /** Every message of the one session the user opened the real-time assist in, until they leave it. */
  REALTIME_SESSION,
}

/**
 * The live state of the assistant for one session.
 *
 * Model state and observation state are kept apart on purpose: releasing the weights because the app
 * went to the background says nothing about whether the user had authorised listening, and returning
 * to the foreground must not re-enable an observer the user turned off.
 */
class PopopxEcoAssistantState(initialObserver: PopopxEcoObserverMode = PopopxEcoObserverMode.OFF) {
  var observer: PopopxEcoObserverMode = initialObserver
    private set

  /** The session the real-time assist was opened in, or null. Only one session at a time. */
  var realtimeSession: String? = null
    private set

  var engine: PopopxEdgeCopilotEngine = PopopxDeterministicEngine()
    private set

  /** True while the green 「本机助理实时协助中 · 数据不出设备」 indicator must be shown. */
  val showsLiveIndicator: Boolean get() = observer == PopopxEcoObserverMode.REALTIME_SESSION && realtimeSession != null

  fun summon(sessionId: String): PopopxEcoObserverMode {
    observer = PopopxEcoObserverMode.SUMMON_LAST_MESSAGES
    realtimeSession = null
    return observer
  }

  /** The toggle the user reaches for; a second call with the same session turns the assist off. */
  fun toggleRealtime(sessionId: String): PopopxEcoObserverMode {
    if (observer == PopopxEcoObserverMode.REALTIME_SESSION && realtimeSession == sessionId) {
      stopRealtime()
    } else {
      observer = PopopxEcoObserverMode.REALTIME_SESSION
      realtimeSession = sessionId
    }
    return observer
  }

  fun stopRealtime() {
    observer = PopopxEcoObserverMode.OFF
    realtimeSession = null
  }

  fun turnOff() {
    stopRealtime()
    engine.release()
  }

  /**
   * Called by the platform when the app leaves the foreground. The weights are dropped, and a
   * real-time assist does not survive the backgrounding: 「离开会话或退到后台即释放模型」 would be
   * pointless if returning to the foreground kept a loaded model the user never re-asked for.
   */
  fun enteredBackground() {
    engine.release()
    if (observer == PopopxEcoObserverMode.REALTIME_SESSION) stopRealtime()
  }

  /** The engine is loaded lazily, on the first turn the user actually asked for. */
  fun ensureEngineLoaded(): Boolean {
    if (engine.isLoaded) return true
    val candidates = popopxPlatformEngines(PopopxEcoFacts.now()) + engine
    val loaded = candidates.firstOrNull { it.ensureLoaded() } ?: return false
    engine = loaded
    return true
  }

  /** The messages the assistant may read for this turn: the typed message plus the preceding window. */
  fun contextWindow(all: List<String>, typed: String): List<String> = when (observer) {
    PopopxEcoObserverMode.OFF -> listOf(typed)
    PopopxEcoObserverMode.SUMMON_LAST_MESSAGES -> (all.takeLast(CONTEXT_WINDOW) + typed)
    PopopxEcoObserverMode.REALTIME_SESSION -> all.takeLast(CONTEXT_WINDOW) + typed
  }

  companion object {
    /** 「最近 5 条上下文」 — the summon feeds five messages, never the whole thread. */
    const val CONTEXT_WINDOW = 5
  }
}
