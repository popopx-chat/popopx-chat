package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxMeshEngine
import chat.popopx.common.mesh.PopopxMeshEventHub
import chat.popopx.common.mesh.PopopxMeshIdentity
import chat.popopx.common.mesh.PopopxMeshFusePhase
import chat.popopx.common.mesh.PopopxMeshKillSwitch
import chat.popopx.common.mesh.PopopxMeshSecretStore
import chat.popopx.common.mesh.PopopxMeshWipe
import com.russhwolf.settings.PropertiesSettings
import com.russhwolf.settings.Settings
import java.io.File
import java.util.Properties
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/** `chat.popopx.mesh.enabled`, read from the same place the settings row writes it. */
private fun meshEnabledKey(): String = PopopxMeshKillSwitch.MESH_ENABLED_KEY

private fun newSettings(): Settings = PropertiesSettings(Properties())

/** A store whose `remove` changes nothing, which is the failure step 2 and step 3 report. */
private class StubbornSettings(private val delegate: Settings = newSettings()) : Settings by delegate {
  override fun remove(key: String) = Unit
  override fun clear() = Unit
}

/**
 * The wipe's four mesh steps, and the fuse that decides whether the mesh may exist at all. The Android host's
 * own method bodies are `androidMain` and never compile here, so this asserts the behaviour those bodies
 * report — the seam, not the wiring.
 */
class PopopxMeshWipeTest {
  private fun runningEngine(
    secrets: FakeMeshSecrets = FakeMeshSecrets(),
  ): Pair<PopopxMeshEngine, FakeMeshTransport> {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("a")))
    val engine = PopopxMeshEngine(
      transport = transport,
      hub = PopopxMeshEventHub(),
      secrets = secrets,
      relayDelay = { 0.0 },
    )
    runBlocking { engine.start() }
    return engine to transport
  }

  @Test
  fun stoppingTheRadioIsANoOpWhenNoMeshWasEverMounted() = runBlocking {
    assertEquals(emptyList(), PopopxMeshWipe.stopRadio(null))
  }

  @Test
  fun stepOneStopsTheRadioAndReportsNothing() = runBlocking {
    val (engine, transport) = runningEngine()
    try {
      assertEquals(emptyList(), PopopxMeshWipe.stopRadio(engine))
      assertEquals(1, transport.stopCount)
      assertFalse(engine.isRunning)
      assertEquals(null, PopopxMeshEngine.current)
    } finally {
      engine.shutdown()
    }
  }

  @Test
  fun stepTwoBurnsTheStaticKeyAndMintsAFreshIdentity() = runBlocking {
    val secrets = FakeMeshSecrets()
    val (engine, _) = runningEngine(secrets)
    val before = engine.localMeshPublicKeyHex
    assertTrue(secrets.items.containsKey("${PopopxMeshSecretStore.IDENTITY_SERVICE}/${PopopxMeshSecretStore.IDENTITY_ACCOUNT}"))
    try {
      assertEquals(emptyList(), PopopxMeshWipe.burnKeys(engine, secrets))
      assertNotEquals(before, engine.localMeshPublicKeyHex)
      assertEquals(emptyList(), secrets.items.keys.filter { it.startsWith(PopopxMeshSecretStore.IDENTITY_SERVICE) })
      // A node keeps working after its identity burns: the fresh key is minted, not nulled.
      assertTrue(engine.localMeshPublicKeyHex.length == PopopxMeshIdentity.KEY_BYTE_COUNT * 2)
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun aKeyThatSurvivesRemovalIsReportedTwiceRatherThanSilently() = runBlocking {
    val secrets = FakeMeshSecrets(refuseRemove = true)
    val (engine, _) = runningEngine(secrets)
    try {
      val reasons = PopopxMeshWipe.burnKeys(engine, secrets)
      assertEquals(
        listOf(
          "mesh identity: the static key was still readable after destroyIdentity",
          "mesh identity: the stored key survived removal",
        ),
        reasons,
      )
      assertTrue(secrets.items.isNotEmpty())
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun stepThreeErasesTheMappingServiceAndBothSwitches() = runBlocking {
    val secrets = FakeMeshSecrets().apply {
      set("peer-a".toByteArray(), PopopxMeshSecretStore.IDENTITY_MAP_SERVICE, PopopxMeshSecretStore.IDENTITY_MAP_ACCOUNT)
    }
    val defaults = newSettings().apply {
      putBoolean(meshEnabledKey(), true)
      putString(PopopxMeshSecretStore.PAIRING_POLICY_KEY, "manual")
    }
    assertEquals(emptyList(), PopopxMeshWipe.eraseMappings(secrets, defaults))
    assertEquals(1, secrets.removeAllCalls)
    assertEquals(emptyList(), secrets.items.keys.filter { it.startsWith(PopopxMeshSecretStore.IDENTITY_MAP_SERVICE) })
    assertFalse(defaults.hasKey(meshEnabledKey()))
    assertFalse(defaults.hasKey(PopopxMeshSecretStore.PAIRING_POLICY_KEY))
  }

  @Test
  fun aMappingServiceThatRefusesToEmptyIsNamedAsAFailure() = runBlocking {
    val secrets = FakeMeshSecrets(refuseRemove = true)
    val reasons = PopopxMeshWipe.eraseMappings(secrets, newSettings())
    assertEquals(listOf("identity map: the mapping service was not fully erased"), reasons)
  }

  @Test
  fun aKillSwitchKeyThatSurvivesRemovalIsNamedAsAFailure() {
    val defaults: Settings = StubbornSettings().apply {
      putBoolean(meshEnabledKey(), true)
      putString(PopopxMeshSecretStore.PAIRING_POLICY_KEY, "manual")
    }
    val reasons = PopopxMeshWipe.eraseMappings(FakeMeshSecrets(), defaults)
    assertEquals(listOf("mesh switches: the kill-switch keys survived removal"), reasons)
    // The reason is only worth anything if the key really is still there afterwards.
    assertTrue(defaults.hasKey(meshEnabledKey()))
  }

  @Test
  fun stepFourNamesTheMeshSandboxInsideTheAppDirectory() {
    val dir = PopopxMeshWipe.sandboxDirectory(File("/data/user/0/com.popopxchat.popopx/files"))
    assertEquals(
      File("/data/user/0/com.popopxchat.popopx/files/popopx/popopx_mesh").path,
      dir.path,
    )
    // The directory is reported whether or not the mesh ever wrote to it.
    assertFalse(dir.exists())
  }
}

/**
 * The fuse, tested with a factory so the case can see exactly how many engines were built: a switch that
 * mounts a second engine on a double tap would leave the first one holding the radio forever.
 */
class PopopxMeshKillSwitchTest {
  private class Harness(makeTransport: () -> FakeMeshTransport = { FakeMeshTransport() }) {
    val transports = mutableListOf<FakeMeshTransport>()
    var built = 0
    val defaults: Settings = newSettings()
    val fuse: PopopxMeshKillSwitch

    init {
      fuse = PopopxMeshKillSwitch(defaults = defaults, makeEngine = {
        built += 1
        val transport = makeTransport()
        transports += transport
        PopopxMeshEngine(
          transport = transport,
          hub = PopopxMeshEventHub(),
          secrets = FakeMeshSecrets(),
          relayDelay = { 0.0 },
        )
      })
    }
  }

  @Test
  fun anUnsetKeyRestoresToOffAndBuildsNothing() = runBlocking {
    val harness = Harness()
    try {
      harness.fuse.restore()
      assertEquals(0, harness.built)
      assertEquals(PopopxMeshFusePhase.OFF, harness.fuse.phase.value)
      assertEquals(null, harness.fuse.engine())
      assertFalse(harness.fuse.persistedIsEnabled())
    } finally {
      harness.fuse.engine()?.shutdown()
    }
  }

  @Test
  fun switchingOnMountsExactlyOneRunningEngine() = runBlocking {
    val harness = Harness()
    try {
      harness.fuse.setEnabled(true)
      assertEquals(PopopxMeshFusePhase.ON, harness.fuse.phase.value)
      assertEquals(1, harness.built)
      assertEquals(1, harness.transports.single().startCount)
      assertTrue(harness.fuse.persistedIsEnabled())
      harness.fuse.setEnabled(true)
      assertEquals(1, harness.built)
      assertEquals(1, harness.transports.single().startCount)
    } finally {
      harness.fuse.engine()?.shutdown()
    }
  }

  @Test
  fun switchingOffStopsTheRadioAndLeavesNoEngineMounted() = runBlocking {
    val harness = Harness()
    harness.fuse.setEnabled(true)
    val engine = harness.fuse.engine()!!
    try {
      harness.fuse.setEnabled(false)
      assertEquals(PopopxMeshFusePhase.OFF, harness.fuse.phase.value)
      assertEquals(null, harness.fuse.engine())
      assertEquals(1, harness.transports.single().stopCount)
      assertFalse(engine.isRunning)
      assertFalse(harness.fuse.persistedIsEnabled())
      assertEquals(null, PopopxMeshEngine.current)
    } finally {
      engine.shutdown()
    }
  }

  @Test
  fun aKeyLeftOnByACrashRestoresTheMeshWithoutAnyoneTappingTheSwitch() = runBlocking {
    val harness = Harness()
    harness.defaults.putBoolean(meshEnabledKey(), true)
    try {
      harness.fuse.restore()
      assertEquals(PopopxMeshFusePhase.ON, harness.fuse.phase.value)
      assertEquals(1, harness.built)
    } finally {
      val engine = harness.fuse.engine()
      harness.fuse.setEnabled(false)
      engine?.shutdown()
    }
  }

  @Test
  fun restoringWithTheKeyOffTearsDownAMeshThisProcessStarted() = runBlocking {
    val harness = Harness()
    harness.fuse.setEnabled(true)
    val engine = harness.fuse.engine()!!
    try {
      harness.defaults.remove(meshEnabledKey())
      harness.fuse.restore()
      assertEquals(PopopxMeshFusePhase.OFF, harness.fuse.phase.value)
      assertEquals(1, harness.transports.single().stopCount)
      assertFalse(engine.isRunning)
    } finally {
      engine.shutdown()
    }
  }
}
