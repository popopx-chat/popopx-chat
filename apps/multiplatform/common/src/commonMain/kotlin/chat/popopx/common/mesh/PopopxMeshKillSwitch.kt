package chat.popopx.common.mesh

import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** The fuse's own four states, in iOS' order (`PopopxMeshFusePhase`). */
enum class PopopxMeshFusePhase {
  OFF,
  STARTING,
  ON,
  STOPPING,
  ;

  val isIdle: Boolean get() = this == OFF
}

/**
 * The global mesh switch — `PopopxMeshUI/PopopxMeshKillSwitch.swift`, reduced to the components this port has.
 *
 * iOS declares four components (engine, health monitor, optional pairing, interface mirror); Groups, Proximity,
 * Health and the state source are all HOLD this round, so the only component here is the engine and the mirror is
 * the event hub the engine stops with itself. What is kept is the switch's *discipline*, which is the part that
 * matters for a security feature:
 *
 * - the persisted key is written before anything starts or stops (`:317`), so a process that dies mid-transition
 *   cannot leave a running radio behind an off switch;
 * - an absent key is false (`UserDefaults.bool`), so the fuse is off until somebody decides;
 * - a transition superseded mid-flight does not overwrite the newer answer (`generation`, `:361-374`);
 * - off means off: every component is stopped even when turning off from a state that was never started
 *   (`restoreOnLaunch`, `:305-306`).
 */
class PopopxMeshKillSwitch(
  private val defaults: Settings = settings,
  private val makeEngine: () -> PopopxMeshEngine = { PopopxMeshEngine() },
) {
  /** iOS serialises this on `@MainActor`; one mutex is the same guarantee without forcing the caller onto a thread. */
  private val transition = Mutex()
  private var mounted: PopopxMeshEngine? = null
  private var generation = 0

  val isEnabled: MutableStateFlow<Boolean> = MutableStateFlow(persistedIsEnabled())
  val phase: MutableStateFlow<PopopxMeshFusePhase> = MutableStateFlow(PopopxMeshFusePhase.OFF)

  /** Straight from disk, without waiting on a transition: the settings row and this cannot disagree. */
  fun persistedIsEnabled(): Boolean =
    runCatching { defaults.getBoolean(MESH_ENABLED_KEY, false) }.getOrDefault(false)

  /**
   * The seam the app has no other place for: iOS calls `restoreOnLaunch()` from its launch path, and here the
   * Cabin page is the first screen that can. Re-entering a page that is already on leaves the radio alone, so
   * this cannot tear down a running mesh; a fuse that is off stops everything rather than doing nothing, which
   * is what makes "off" mean off after a crash that left the radio on.
   */
  suspend fun restore() = transition.withLock {
    val enabled = persistedIsEnabled()
    isEnabled.value = enabled
    if (!enabled) {
      stopEverything()
      return@withLock
    }
    if (phase.value == PopopxMeshFusePhase.ON) return@withLock
    startEverything()
  }

  suspend fun setEnabled(enabled: Boolean) = transition.withLock {
    defaults.putBoolean(MESH_ENABLED_KEY, enabled)
    isEnabled.value = enabled
    if (enabled) {
      if (phase.value == PopopxMeshFusePhase.ON) return@withLock
      startEverything()
    } else {
      stopEverything()
    }
  }

  /** The engine the fuse mounted, or null while the mesh is off. The UI reads peers through this. */
  fun engine(): PopopxMeshEngine? = mounted

  private suspend fun startEverything() {
    val engine = mounted ?: makeEngine().also { mounted = it }
    val mine = ++generation
    phase.value = PopopxMeshFusePhase.STARTING
    engine.start()
    // A newer transition owns the answer now; reporting `on` for a start it has abandoned would be a lie
    // the UI cannot tell apart from the truth.
    if (mine != generation) return
    phase.value = PopopxMeshFusePhase.ON
  }

  private suspend fun stopEverything() {
    val engine = mounted
    mounted = null
    if (engine == null && phase.value == PopopxMeshFusePhase.OFF) return
    val mine = ++generation
    phase.value = PopopxMeshFusePhase.STOPPING
    engine?.stop()
    if (mine != generation) return
    phase.value = PopopxMeshFusePhase.OFF
  }

  companion object {
    /** `PopopxMeshKillSwitch.enabledDefaultsKey` — the one persisted key of the whole feature. */
    const val MESH_ENABLED_KEY: String = PopopxMeshSecretStore.MESH_ENABLED_KEY

    val shared: PopopxMeshKillSwitch = PopopxMeshKillSwitch()
  }
}
