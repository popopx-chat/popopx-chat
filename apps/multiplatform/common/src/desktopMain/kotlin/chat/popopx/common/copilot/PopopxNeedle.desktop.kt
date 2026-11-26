package chat.popopx.common.copilot

import java.io.File
import java.security.MessageDigest
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * The desktop half of the asset contract, and the reason the verify step lives in the platform layer:
 * a JVM process has a classpath and a working directory, and only one of the two is stable across
 * `gradle :desktop:run`, `:common:desktopTest` and an IDE launch.
 *
 * Resolution order is classpath resource first, then the repo-relative file. The filesystem path is
 * re-rooted onto every ancestor of the working directory, because Gradle runs the tests from the
 * module directory while the app runs from the repository root, and a check that only worked from one
 * of the two would quietly report `bundledModelPresent() == false` in the other — which fails closed,
 * but for the wrong reason.
 */
private const val BUNDLED_MODEL_RESOURCE = "/assets/needle3.cact"

/** Where the weights live in the shipped bundle: an asset path, not a filesystem path. */
private const val BUNDLED_MODEL_ASSET_PATH = "assets/needle3.cact"

/** The same file, seen from the repository, for a desktop build that runs against the source tree. */
private val BUNDLED_MODEL_REPO_PATHS = listOf(
  "src/commonMain/resources/$BUNDLED_MODEL_ASSET_PATH",
  "common/src/commonMain/resources/$BUNDLED_MODEL_ASSET_PATH",
  "apps/multiplatform/common/src/commonMain/resources/$BUNDLED_MODEL_ASSET_PATH",
)

actual object PopopxNeedleAssets {
  /** Measured with `shasum -a 256` over the `needle3.cact` that the bundle carries. */
  actual val modelSha256: String = "c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38"

  actual val modelPath: String = BUNDLED_MODEL_ASSET_PATH

  actual val modelBytes: Long = 35_335_380L

  actual fun bundledModelPresent(): Boolean = readBundledModelBytes() != null

  /**
   * The only way onto this platform's model handle.
   *
   * There is no Needle engine on desktop, so the engine carried by the returned value is the
   * deterministic one the app actually answers with — [kind] stays `Deterministic`, and nothing here
   * pretends a `.cact` file was mmapped. The bytes are returned verified or not at all: an unverified
   * buffer cannot be constructed into [PopopxVerifiedModel] from outside this module.
   */
  actual fun loadVerifiedModel(): PopopxVerifiedModel {
    val bytes = readBundledModelBytes() ?: throw IllegalStateException("the bundled copilot model is not present in this build")
    if (!popopxBundledModelAccepts(bytes)) {
      // Deliberately silent about both digests: printing the digest of an untrusted file would let a
      // replaced asset be identified from the log, which is the one thing the check is for.
      throw IllegalStateException("the bundled copilot model failed verification (${bytes.size} bytes read, expected $modelBytes)")
    }
    return PopopxVerifiedModel(bytes, PopopxDeterministicEngine())
  }

  /** Reads the classpath resource, then the repo file, then gives up. Read-only in every branch. */
  private fun readBundledModelBytes(): ByteArray? {
    runCatching {
      PopopxNeedleAssets::class.java.getResourceAsStream(BUNDLED_MODEL_RESOURCE)?.use { it.readBytes() }
    }.getOrNull()?.let { return it }
    val file = bundledModelFile() ?: return null
    if (!file.isFile) return null
    return runCatching { file.readBytes() }.getOrNull()
  }
}

/**
 * The size-and-digest gate, split out from [PopopxNeedleAssets.loadVerifiedModel] so the fail-closed
 * path can be exercised with bytes that are not the shipped bundle — a test must not have to corrupt a
 * 35 MB asset to prove that corruption is refused.
 */
internal fun popopxBundledModelAccepts(bytes: ByteArray): Boolean =
  bytes.size.toLong() == PopopxNeedleAssets.modelBytes &&
    PopopxNeedleAssets.modelSha256.isNotEmpty() &&
    popopxConstantTimeEquals(popopxSha256Hex(bytes), PopopxNeedleAssets.modelSha256)

/** Length-checked byte comparison. Not a crypto equal, but not `==` on a short-circuiting basis either. */
private fun popopxConstantTimeEquals(actual: String, expected: String): Boolean {
  if (actual.length != expected.length) return false
  var diff = 0
  for (index in actual.indices) diff = diff or (actual[index].code xor expected[index].code)
  return diff == 0
}

/** The repo-relative file, found by walking up from the working directory rather than assuming it. */
private fun bundledModelFile(): File? {
  var directory: File? = runCatching { File("").absoluteFile }.getOrNull()
  var depth = 0
  while (directory != null && depth < MAX_REPO_SEARCH_DEPTH) {
    for (relative in BUNDLED_MODEL_REPO_PATHS) {
      val candidate = File(directory, relative)
      if (candidate.isFile) return candidate
    }
    directory = directory.parentFile
    depth++
  }
  return null
}

private const val MAX_REPO_SEARCH_DEPTH = 8

/**
 * The engines this platform can offer.
 *
 * Only the deterministic one: the Cactus/Needle runtime is linked into the Android build and nothing
 * on desktop, so a desktop entry in this list would be a `Kind.Needle` engine whose `ensureLoaded()`
 * cannot load. That absence is a decision, not an oversight, and [PopopxNeedleAssets.loadVerifiedModel]
 * keeps the verification path honest anyway.
 */
actual fun popopxPlatformEngines(facts: PopopxEcoFacts): List<PopopxEdgeCopilotEngine> =
  listOf(PopopxDeterministicEngine())

/** SHA-256, lowercase hex, spelled with a char loop so the same body can be copied to an API 21 target. */
actual fun popopxSha256Hex(bytes: ByteArray): String {
  val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
  val hex = CharArray(digest.size * 2)
  var position = 0
  for (byte in digest) {
    val value = byte.toInt() and 0xFF
    hex[position++] = DIGITS[value ushr 4]
    hex[position++] = DIGITS[value and 0x0F]
  }
  return String(hex)
}

private const val DIGITS = "0123456789abcdef"

/** The device's local calendar day, with no timezone carried past this line. */
actual fun popopxToday(): EcoDate {
  val today = LocalDate.now(ZoneId.systemDefault())
  return EcoDate(today.year, today.monthValue, today.dayOfMonth)
}

actual fun popopxNowMinutesPastMidnight(): Int {
  val now = LocalDateTime.now(ZoneId.systemDefault())
  return now.hour * 60 + now.minute
}
