package chat.popopx.common.mesh

import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

/**
 * The mesh half of the three-tap panic wipe: `PopopxMeshUI/PanicWipeManager.swift:586-624` and
 * `IdentityMappingStore.emergencyWipeAllMappings()` (`:316-346`).
 *
 * It lives here rather than inside the Android host because the host is untestable there — `desktopTest`
 * never compiles `androidMain` — and "step 2 left no readable static key" is a claim that has to be asserted
 * against an object a test can reach. The host calls these and reports what comes back.
 *
 * Nothing throws, and every function returns the reasons it failed. iOS runs all four steps even after one
 * of them fails, because a wipe that stopped halfway would report the state it never touched as erased.
 */
object PopopxMeshWipe {
  /**
   * Step 1: stop the radio, so a scan still winding down cannot receive a frame that re-creates a session
   * while the keys are being burned (`PanicWipeManager.swift:588-589`).
   *
   * Bounded where iOS is not, which is a deliberate deviation: the Android transport holds every callback
   * behind one monitor, and a wipe that blocks on a wedged radio callback never reaches the keys. A timeout
   * is recorded as a failure rather than assumed to have finished.
   */
  suspend fun stopRadio(engine: PopopxMeshEngine?): List<String> {
    val mounted = engine ?: return emptyList()
    val stopped = try {
      withTimeoutOrNull(STOP_TIMEOUT_MILLIS) {
        mounted.stop()
        !mounted.isRunning
      }
    } catch (e: Throwable) {
      null
    }
    return if (stopped == true) emptyList() else listOf("mesh radio: stop() did not complete within ${STOP_TIMEOUT_MILLIS}ms")
  }

  /**
   * Step 2: destroy the static key and every session built on it.
   *
   * The direct removal is not a duplicate of [PopopxMeshEngine.destroyIdentity]'s own: iOS reaches this
   * through `PopopxMeshEngine.shared`, which always exists, while the Android mount is null whenever the
   * mesh was never switched on — and a key minted by an earlier run is still sitting in the keystore.
   */
  suspend fun burnKeys(
    engine: PopopxMeshEngine?,
    secrets: PopopxMeshSecretStoring = PopopxMeshSecretStore(),
  ): List<String> {
    val reasons = mutableListOf<String>()
    if (engine != null && !runCatching { engine.destroyIdentity() }.getOrDefault(false)) {
      reasons.add("mesh identity: the static key was still readable after destroyIdentity")
    }
    if (!runCatching { secrets.remove(PopopxMeshSecretStore.IDENTITY_SERVICE, PopopxMeshSecretStore.IDENTITY_ACCOUNT) }.getOrDefault(false)) {
      reasons.add("mesh identity: the stored key survived removal")
    }
    return reasons
  }

  /**
   * Step 3: the durable mapping table and the two switches in `UserDefaults` — iOS erases both keychain
   * services and both preference keys here (`IdentityMappingStore.swift:325-336`). The cache files that
   * follow are step 4's job on Android, where the mesh sandbox is in the overwrite set.
   *
   * `hasKey` rather than a typed read: the enabled flag is written as a boolean by the host and a
   * `getStringOrNull` against a boolean-backed key is a `ClassCastException` on Android's
   * `SharedPreferences`, which would turn a verified erase into an exception.
   */
  fun eraseMappings(
    secrets: PopopxMeshSecretStoring = PopopxMeshSecretStore(),
    defaults: Settings = settings,
  ): List<String> {
    val reasons = mutableListOf<String>()
    if (!runCatching { secrets.removeAll(PopopxMeshSecretStore.IDENTITY_MAP_SERVICE) }.getOrDefault(false)) {
      reasons.add("identity map: the mapping service was not fully erased")
    }
    defaults.remove(PopopxMeshSecretStore.PAIRING_POLICY_KEY)
    defaults.remove(PopopxMeshSecretStore.MESH_ENABLED_KEY)
    if (defaults.hasKey(PopopxMeshSecretStore.PAIRING_POLICY_KEY) || defaults.hasKey(PopopxMeshSecretStore.MESH_ENABLED_KEY)) {
      reasons.add("mesh switches: the kill-switch keys survived removal")
    }
    return reasons
  }

  /**
   * Step 4's mesh entry: `PopopxMeshPaths.directoryName` inside the app's protected directory, the same
   * shape the media engine uses (`PopopxMediaEngine.kt:241-246`). Returned whether or not it exists —
   * the wipe's directory list is a claim about where the mesh may have written, not about what it did.
   */
  fun sandboxDirectory(root: File): File = File(File(root, "popopx"), PopopxMeshSecretStore.DIRECTORY_NAME)

  /** Seconds the radio is given to stop before the wipe reports that it did not. */
  private const val STOP_TIMEOUT_MILLIS = 5_000L
}
