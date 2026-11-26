package chat.popopx.common.copilot

/**
 * The compile-time switch for the bundled on-device engine, and the reason the shipped app does not
 * load 35 MB of weights.
 *
 * FALSE is the value this branch ships with. The gate is a `const` rather than a preference on
 * purpose: a preference could be flipped by a remote value or by a bug in settings, and the whole
 * point of the dormant engine is that nothing at runtime may decide to mmap weights that have not
 * been measured against a known-good reply. Making it a constant means the only way to turn the real
 * engine on is to edit this file and rebuild.
 *
 * Why it is off, stated honestly:
 * - Measured on this host, the published Needle 3 base weights route **1 of the 6** calendar intents
 *   in `PopopxEcoTool` correctly, and produce no usable Chinese output for the `zh-rCN`/`zh-rTW`
 *   input this product actually sees. The deterministic engine gets those intents right by
 *   construction.
 * - Fine-tuning Needle for this schema is a separate project, not a flag.
 * - The android artifact published alongside the header (`/tmp/cactus/android-arm64_cactus`) is the
 *   standalone CLI executable, not the `android-arm64/libcactus.a` its own manifest names; that
 *   archive is absent from this machine and this host is offline, so there is nothing to link the
 *   shim against yet.
 *
 * What IS here, and works the moment someone drops a `libcactus.so` into the apk's native library
 * directory: the shim resolves `cactus_load` / `cactus_init` / `cactus_complete` / `cactus_reset` /
 * `cactus_last_error` at runtime, the engine verifies its weights before touching them, and every
 * failure — absent library, failed load, empty reply, unparseable reply — returns
 * [PopopxEcoEnvelope.EMPTY] and lets [PopopxDeterministicEngine] answer.
 */
internal const val NEEDLE_CACTUS_ENABLED = false

/** The native library [PopopxCactusJni] is built into, by name and without the `lib`/`.so` affixes. */
internal const val CACTUS_JNI_LIBRARY = "cactus-jni"

/**
 * The JNI seam. Names are `Java_chat_popopx_common_copilot_PopopxCactusJni_*`, which is the package
 * this feature's Android code actually lives in (`common/src/androidMain`, the source set that owns
 * the `actual` declarations) rather than a `chat.popopx.android` package: the `expect` declarations
 * this file satisfies are in `:common`'s commonMain, and Kotlin matches `actual` to `expect` by
 * qualified name inside the same module, so an actual in the `:android` application module could not
 * compile.
 *
 * Loading is lazy and defensive. `System.loadLibrary` is attempted on first use inside a
 * [runCatching], so an apk without the shim — every apk built today — reports the engine as
 * unavailable instead of throwing in a class initializer.
 */
internal object PopopxCactusJni {
  /** Cached so a missing library is probed once per process rather than once per turn. */
  private var probed = false
  private var present = false

  /** True when the shim is in the apk; the cactus runtime is linked into it statically, so a loaded
   *  shim is a usable runtime, and `nativeAvailable` is the shim's own confirmation of that. */
  fun available(): Boolean {
    if (!probed) {
      probed = true
      present = runCatching {
        System.loadLibrary(CACTUS_JNI_LIBRARY)
        nativeAvailable()
      }.getOrDefault(false)
    }
    return present
  }

  fun load(model: ByteArray): Boolean = available() && runCatching { nativeLoad(model, model.size.toLong()) == 1 }.getOrDefault(false)

  fun init(systemPrompt: String, toolsJson: String): Boolean = available() && runCatching { nativeInit(systemPrompt, toolsJson) == 1 }.getOrDefault(false)

  fun complete(text: String, maxNewTokens: Int): String? =
    if (!available()) null else runCatching { nativeComplete(text, maxNewTokens) }.getOrNull()

  fun reset() {
    if (available()) runCatching { nativeReset() }
  }

  fun lastError(): String? = if (!available()) null else runCatching { nativeLastError() }.getOrNull()

  private external fun nativeAvailable(): Boolean
  private external fun nativeLoad(model: ByteArray, length: Long): Int
  private external fun nativeInit(systemPrompt: String, toolsJson: String): Int
  private external fun nativeComplete(text: String, maxNewTokens: Int): String?
  private external fun nativeReset()
  private external fun nativeLastError(): String?
}

/**
 * The real engine, wrapped in the interface the app already talks to.
 *
 * Every exit that is not a clean, parseable model reply returns [PopopxEcoEnvelope.EMPTY], which makes
 * [PopopxEcoAssistant] fall through to the deterministic engine's answer for the same turn. The
 * wrapper never throws to the UI: an on-model inference failure is a privacy-preserving no-op, not an
 * error dialog.
 */
object NeedleCactusEngine : PopopxEdgeCopilotEngine {
  override val kind = PopopxEdgeCopilotEngine.Kind.Needle

  override var isLoaded: Boolean = false
    private set

  /** Serializes the native calls: the runtime keeps one global context, so two turns cannot share it. */
  private val lock = Any()

  override fun ensureLoaded(): Boolean {
    if (!NEEDLE_CACTUS_ENABLED) return false
    if (isLoaded) return true
    return synchronized(lock) {
      if (isLoaded) return true
      if (!PopopxCactusJni.available()) return false
      // loadVerifiedModel() is the only way onto the bytes, and it refuses anything that does not
      // match PopopxNeedleAssets.modelSha256; a corrupt or replaced asset throws here and the
      // deterministic engine is chosen instead.
      val model = runCatching { PopopxNeedleAssets.loadVerifiedModel() }.getOrNull() ?: return false
      if (model.engine.kind != kind) return false
      if (!PopopxCactusJni.load(model.bytes)) return false
      val facts = PopopxEcoFacts.now()
      val prompt = systemPrompt(facts)
      isLoaded = PopopxCactusJni.init(prompt, popopxEcoToolsJson())
      if (!isLoaded) PopopxCactusJni.reset()
      isLoaded
    }
  }

  override fun release() {
    synchronized(lock) {
      if (!isLoaded) return
      PopopxCactusJni.reset()
      isLoaded = false
    }
  }

  override fun parse(input: String, facts: PopopxEcoFacts): PopopxEcoEnvelope {
    if (!NEEDLE_CACTUS_ENABLED || !isLoaded) return PopopxEcoEnvelope.EMPTY
    val text = input.trim()
    if (text.isEmpty()) return PopopxEcoEnvelope.EMPTY
    val reply = synchronized(lock) {
      if (!isLoaded) return PopopxEcoEnvelope.EMPTY
      // The date is refreshed per turn: a long-lived session must resolve "tomorrow at 3" against
      // today, and the prompt was written when the model was loaded.
      if (!PopopxCactusJni.init(systemPrompt(facts), popopxEcoToolsJson())) return PopopxEcoEnvelope.EMPTY
      PopopxCactusJni.complete(text, MAX_NEW_TOKENS)
    } ?: return PopopxEcoEnvelope.EMPTY
    return envelopeOf(reply)
  }

  /**
   * Accepts a clean JSON reply, and a model that wrapped its JSON in prose or a code fence by taking
   * the outermost braces. Anything else is EMPTY, so a rambling reply cannot become a calendar write
   * by way of a lenient parser.
   */
  private fun envelopeOf(reply: String): PopopxEcoEnvelope {
    val trimmed = reply.trim().removePrefix("```json").removePrefix("```").removeSuffix("```").trim()
    val direct = PopopxEcoEnvelope.fromEngineJson(trimmed)
    if (direct.failure == null && !direct.isEmpty) return direct
    val from = trimmed.indexOf('{')
    val to = trimmed.lastIndexOf('}')
    if (from < 0 || to <= from) return PopopxEcoEnvelope.EMPTY
    val sliced = PopopxEcoEnvelope.fromEngineJson(trimmed.substring(from, to + 1))
    return if (sliced.isEmpty && sliced.failure != null) PopopxEcoEnvelope.EMPTY else sliced
  }

  /** Today, in the ISO form the schema asks the model to resolve against. No name, no location, no contact. */
  private fun systemPrompt(facts: PopopxEcoFacts): String =
    "You are a private assistant on the user's phone. Today is ${facts.today.iso()}. " +
      "Call exactly one of the given tools, or none. Never invent a time: if the message gives no clock time, return no call. " +
      "Answer only with a JSON object containing function_calls."

  private const val MAX_NEW_TOKENS = 256
}
