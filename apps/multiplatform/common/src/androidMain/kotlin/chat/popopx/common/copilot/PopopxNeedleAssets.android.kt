package chat.popopx.common.copilot

import chat.popopx.common.platform.AppContextProvider
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.security.MessageDigest

/**
 * The Android half of the bundled-weights contract.
 *
 * Two things about this file are load-bearing and both come from the rule in
 * [PopopxNeedleAssets]:
 *
 * 1. The digest is computed **while the asset is being read**, from the same pass that fills the
 *    buffer, and the buffer is only handed to an engine after it has been checked. There is no code
 *    path here that returns bytes without having compared their digest, because a `.cact` file is
 *    tensor data the engine goes on to execute, and "it parsed" is not evidence of anything.
 * 2. Everything is fail-closed. No context, no asset, a short read, a size mismatch, a digest
 *    mismatch — each of them throws or returns false, and the caller in
 *    [PopopxEcoAssistantState.ensureEngineLoaded] falls through to the deterministic engine. The
 *    user sees an assistant that answers, not an error.
 *
 * The digest and the byte count below are measured, not copied from a release note:
 * `shasum -a 256 common/src/commonMain/resources/assets/needle3.cact` and `wc -c` on the same file,
 * run on this checkout. They are the same values the desktop actual carries, which is the point —
 * one asset, two platforms, one expected digest.
 */
actual object PopopxNeedleAssets {
  /** Measured with `shasum -a 256` over the `needle3.cact` that the bundle carries. */
  actual val modelSha256: String = "c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38"

  /** The path the desktop actual and the brief use. The AssetManager key drops the `assets/` root. */
  actual val modelPath: String = "assets/needle3.cact"

  actual val modelBytes: Long = 35_335_380L

  /**
   * True when the asset opens and is the length it claims to be.
   *
   * The length is checked without reading 35 MB, because this is the predicate a settings row may
   * call: [android.content.res.AssetManager.openFd] gives the length of an uncompressed asset
   * directly, and [InputStream.available] is the fallback for a compressed one (an
   * [android.content.res.AssetManager] stream reports the whole remaining length for both cases,
   * which is the length of the file when nothing has been read from it yet).
   */
  actual fun bundledModelPresent(): Boolean {
    val length = assetLength() ?: return false
    return length == modelBytes
  }

  /**
   * Read, hash, compare, then — and only then — hand the bytes to an engine.
   *
   * @throws IllegalStateException when the asset is absent, short, oversized or does not match
   *   [modelSha256]. The message carries the byte count and never the observed digest: printing the
   *   digest of an untrusted file would let a replaced asset be identified from logcat, which is the
   *   one thing this check exists to prevent.
   */
  actual fun loadVerifiedModel(): PopopxVerifiedModel {
    val stream = openModel() ?: throw IllegalStateException("the bundled copilot model is not present in this build")
    val digest = runCatching { popopxNewSha256() }.getOrNull()
      ?: throw IllegalStateException("this device reports no SHA-256 implementation")
    val bytes = runCatching { readAndHash(stream, digest) }.getOrElse {
      runCatching { stream.close() }
      throw IllegalStateException("the bundled copilot model could not be read", it)
    }
    runCatching { stream.close() }
    if (bytes.size.toLong() != modelBytes) {
      throw IllegalStateException("the bundled copilot model is ${bytes.size} bytes, expected $modelBytes")
    }
    if (!popopxConstantTimeEquals(popopxSha256Hex(digest), modelSha256)) {
      throw IllegalStateException("the bundled copilot model failed verification")
    }
    // Verification finished before this line runs, so the engine below only ever sees checked bytes.
    return PopopxVerifiedModel(bytes, engineForVerifiedModel())
  }

  /**
   * The engine the verified bytes are handed to.
   *
   * [NeedleCactusEngine] only, and only while it is enabled: it is the only consumer of the buffer on
   * this platform. When the native shim is off — which is how this branch ships — the honest answer
   * is the deterministic engine, exactly as on desktop: returning a `Kind.Needle` engine that cannot
   * load would make [PopopxEcoReply.usedFallback] lie.
   */
  private fun engineForVerifiedModel(): PopopxEdgeCopilotEngine =
    if (NEEDLE_CACTUS_ENABLED) NeedleCactusEngine else PopopxDeterministicEngine()

  /** Opens the asset under either spelling of [modelPath]. */
  private fun openModel(): InputStream? {
    val assets = AppContextProvider.getApplicationContext()?.assets ?: return null
    for (key in assetKeys()) {
      val stream = runCatching { assets.open(key) }.getOrNull()
      if (stream != null) return stream
    }
    return null
  }

  private fun assetLength(): Long? {
    val context = AppContextProvider.getApplicationContext() ?: return null
    for (key in assetKeys()) {
      runCatching { context.assets.openFd(key).use { it.length } }.getOrNull()?.let { return it }
      runCatching { context.assets.open(key).use { it.available().toLong() } }.getOrNull()?.let { return it }
    }
    return null
  }

  /**
   * The app module roots its asset directory at `common/src/commonMain/resources/assets`
   * (`android/build.gradle.kts`, `sourceSets["main"].assets.setSrcDirs`), so the manager's key for
   * this file is `needle3.cact`. `assets/needle3.cact` is tried first so the value of [modelPath]
   * remains the one the shared contract documents.
   */
  private fun assetKeys(): List<String> = listOf(modelPath, modelPath.removePrefix("assets/"))

  /** One pass: fill the buffer, feed the digest. Returns the bytes the digest was taken over. */
  private fun readAndHash(stream: InputStream, digest: MessageDigest): ByteArray {
    val out = ByteArrayOutputStream(CHUNK_SIZE * 4)
    val buffer = ByteArray(CHUNK_SIZE)
    // A 2x oversized asset is refused by the length check in the caller, but reading is capped here so
    // a hostile asset cannot make this loop allocate without bound first.
    val limit = modelBytes + modelBytes / 8
    var total = 0L
    while (total < limit) {
      val read = stream.read(buffer)
      if (read <= 0) break
      popopxSha256Update(digest, buffer, read)
      out.write(buffer, 0, read)
      total += read
    }
    return out.toByteArray()
  }

  private const val CHUNK_SIZE = 128 * 1024
}

/**
 * Length-checked digest comparison. Not a secret comparison — [modelSha256] is public in the apk — but
 * it is the same shape, and it avoids the `==` short circuit that would let timing say how much of a
 * forged file matched.
 */
private fun popopxConstantTimeEquals(actual: String, expected: String): Boolean {
  if (actual.length != expected.length) return false
  var diff = 0
  for (index in actual.indices) diff = diff or (actual[index].code xor expected[index].code)
  return diff == 0
}
