package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxBluetoothState
import chat.popopx.common.mesh.PopopxMeshConfig
import chat.popopx.common.mesh.PopopxMeshEngine
import chat.popopx.common.mesh.PopopxMeshBody
import chat.popopx.common.mesh.PopopxMeshEvent
import chat.popopx.common.mesh.PopopxMeshEventHub
import chat.popopx.common.mesh.PopopxMeshIdentity
import chat.popopx.common.mesh.PopopxMeshMessageType
import chat.popopx.common.mesh.PopopxMeshPacket
import chat.popopx.common.mesh.PopopxMeshSendFailure
import chat.popopx.common.mesh.meshHex
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The flood rules, tested against an in-memory radio. Every case here is a claim about
 * `PopopxMeshEngine.swift` that the port must keep: a packet is forwarded once with one hop less, never
 * back out of the link it came in on, and never twice.
 */
class PopopxMeshEngineFloodTest {
  private fun engineWith(
    transport: FakeMeshTransport,
    hub: PopopxMeshEventHub = PopopxMeshEventHub(),
    config: PopopxMeshConfig = PopopxMeshConfig.default,
    now: () -> Long = { 1_700_000_000_000L },
  ): Pair<PopopxMeshEngine, EventLog> {
    val engine = PopopxMeshEngine(
      config = config,
      transport = transport,
      hub = hub,
      secrets = FakeMeshSecrets(),
      nowMillis = now,
      // Pinned, so the relay's jitter (0.008...0.025s of delay on the engine thread) cannot make a case flaky.
      relayDelay = { 0.0 },
    )
    return engine to EventLog(hub.subscribe())
  }

  private fun foreignIdentity(): PopopxMeshIdentity = PopopxMeshIdentity.generate()

  private fun incoming(
    peer: PopopxMeshIdentity,
    type: PopopxMeshMessageType,
    ttl: Int,
    payload: ByteArray,
    recipient: ByteArray? = null,
  ): ByteArray = PopopxMeshPacket(
    version = 1,
    type = type.wireValue,
    ttl = ttl,
    timestamp = 1_700_000_000_000L,
    senderID = peer.peerID.bytes,
    recipientID = recipient,
    payload = payload,
  ).encoded(padded = false)!!

  @Test
  fun startingHandsTheDelegateToTheRadioAndPublishesItsState() = runBlocking {
    val transport = FakeMeshTransport()
    val (engine, events) = engineWith(transport)
    try {
      engine.start()
      assertEquals(1, transport.startCount)
      assertTrue(engine.isRunning)
      assertNotNull(transport.sink)
      assertTrue(
        events.drain().any {
          it is PopopxMeshEvent.BluetoothState && it.state == PopopxBluetoothState.POWERED_ON
        }
      )
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun broadcastLeavesOnEveryWritableLinkWithTheDefaultTTL() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("a"), meshLink("b")))
    val (engine, events) = engineWith(transport)
    try {
      engine.start()
      events.drain()
      val id = engine.sendBroadcast("hello mesh")
      assertEquals(2, transport.sent.size)
      val packet = transport.packets().first()
      assertEquals(PopopxMeshMessageType.MESSAGE.wireValue, packet.type)
      assertEquals(PopopxMeshConfig.default.ttlDefault, packet.ttl)
      assertEquals("hello mesh", String(packet.payload, Charsets.UTF_8))
      assertEquals(id, packet.packetID.meshHex())
      assertEquals(emptyList(), events.drain().filterIsInstance<PopopxMeshEvent.SendFailed>())
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun broadcastWithNoWritableLinkReportsTheFailureItselfRatherThanSilence() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("a", writable = false)))
    val (engine, events) = engineWith(transport)
    try {
      engine.start()
      events.drain()
      engine.sendBroadcast("nobody to hear it")
      val failures = events.drain().filterIsInstance<PopopxMeshEvent.SendFailed>()
      assertEquals(1, failures.size)
      assertTrue(failures.first().reason is PopopxMeshSendFailure.NoLinkToPeer)
      assertEquals(0, transport.sent.size)
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun aForeignBroadcastIsRelayedOnceOneHopLessAndNotBackOutItsOwnLink() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("in"), meshLink("out"), meshLink("other")))
    val (engine, events) = engineWith(transport)
    val peer = foreignIdentity()
    try {
      engine.start()
      events.drain()
      val data = incoming(peer, PopopxMeshMessageType.MESSAGE, ttl = 5, payload = "flood me".toByteArray())
      // receive() rather than the transport's delegate hop: the latter is a launch and would not be done
      // by the time the next line asserts.
      engine.receive(data, "in")
      val linkIDs = transport.sent.map { it.second }
      assertEquals(listOf("other", "out"), linkIDs.sorted())
      assertFalse(linkIDs.contains("in"))
      val relayed = transport.packets().first()
      assertEquals(4, relayed.ttl)
      assertEquals(peer.peerID.bytes.toList(), relayed.senderID.toList())
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun theSamePacketSeenTwiceIsNotFloodedTwice() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("in"), meshLink("out")))
    val (engine, events) = engineWith(transport)
    val peer = foreignIdentity()
    try {
      engine.start()
      events.drain()
      val data = incoming(peer, PopopxMeshMessageType.MESSAGE, ttl = 5, payload = "one flood".toByteArray())
      engine.receive(data, "in")
      val afterFirst = transport.sent.size
      engine.receive(data, "in")
      assertEquals(afterFirst, transport.sent.size)
      assertEquals(1, afterFirst)
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun aPacketThatDiesAtOurDoorIsNotRelayed() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("in"), meshLink("out")))
    val (engine, events) = engineWith(transport)
    val peer = foreignIdentity()
    try {
      engine.start()
      events.drain()
      val data = incoming(peer, PopopxMeshMessageType.MESSAGE, ttl = 1, payload = "last hop".toByteArray())
      engine.receive(data, "in")
      assertEquals(0, transport.sent.size)
      // It is still delivered, and the hop count says where it has been: ttl 1 means it reached us after
      // ttlDefault - 1 hops, which is exactly what stops it travelling further.
      val inbound = events.drain().filterIsInstance<PopopxMeshEvent.Inbound>()
      assertEquals(1, inbound.size)
      assertEquals(PopopxMeshConfig.default.ttlDefault - 1, inbound.first().inbound.hopCount)
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun hopCountIsTheHopsItTookNotTheTTLWeHandedOut() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("in"), meshLink("out")))
    val (engine, events) = engineWith(transport)
    val peer = foreignIdentity()
    try {
      engine.start()
      events.drain()
      engine.receive(
        incoming(peer, PopopxMeshMessageType.MESSAGE, ttl = 4, payload = "two hops".toByteArray()),
        "in",
      )
      val inbound = events.drain().filterIsInstance<PopopxMeshEvent.Inbound>().single()
      assertEquals(
        PopopxMeshConfig.default.ttlDefault - 4,
        inbound.inbound.hopCount,
      )
      assertTrue(inbound.inbound.isBroadcast)
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun aDenseNeighbourhoodClampsBroadcastsButNotDirectedTraffic() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("in")))
    val (engine, events) = engineWith(transport)
    val peers = List(PopopxMeshConfig.default.highDegreeThreshold + 1) { foreignIdentity() }
    try {
      engine.start()
      events.drain()
      peers.forEach { peer ->
        val payload = "{\"${PopopxMeshEngine.ANNOUNCE_PUBLIC_KEY_FIELD}\":\"${peer.meshPublicKeyHex}\"}"
        engine.receive(
          incoming(peer, PopopxMeshMessageType.ANNOUNCE, ttl = 1, payload = payload.toByteArray()),
          "in",
        )
      }
      assertEquals(peers.size, engine.directNeighbourCount())
      transport.linkList = mutableListOf(meshLink("out"))
      transport.sent.clear()
      engine.sendBroadcast("dense room")
      assertEquals(PopopxMeshConfig.default.denseBroadcastTtlCap, transport.packets().first().ttl)
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  /**
   * The one case that does go through the radio's delegate: `didReceive` hands the frame to a coroutine
   * rather than processing it inline, so the only honest wait is for the event the receive publishes.
   */
  @Test
  fun aFrameFromTheRadioReachesTheEngineThroughTheDelegateSeam() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("in"), meshLink("out")))
    val (engine, events) = engineWith(transport)
    val peer = foreignIdentity()
    try {
      engine.start()
      events.drain()
      transport.sink!!.didReceive(
        incoming(peer, PopopxMeshMessageType.MESSAGE, ttl = 1, payload = "through the seam".toByteArray()),
        "in",
      )
      val inbound = events.awaitInbound().inbound
      assertEquals("through the seam", (inbound.body as? PopopxMeshBody.Text)?.text)
      assertEquals(PopopxMeshConfig.default.ttlDefault - 1, inbound.hopCount)
      assertEquals(0, transport.sent.size)
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun stoppingClearsTheCurrentEngineAndLeavesNoDelegateBehind() = runBlocking {
    val transport = FakeMeshTransport()
    val (engine, _) = engineWith(transport)
    engine.start()
    assertEquals(engine, PopopxMeshEngine.current)
    engine.stop()
    assertFalse(engine.isRunning)
    assertEquals(1, transport.stopCount)
    assertEquals(null, transport.sink)
    assertEquals(null, PopopxMeshEngine.current)
    engine.shutdown()
  }
}
