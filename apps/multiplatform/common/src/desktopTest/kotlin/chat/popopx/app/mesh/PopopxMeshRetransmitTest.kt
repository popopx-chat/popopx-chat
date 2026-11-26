package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxBLETransportError
import chat.popopx.common.mesh.PopopxMeshConfig
import chat.popopx.common.mesh.PopopxMeshDeduplicator
import chat.popopx.common.mesh.PopopxMeshEngine
import chat.popopx.common.mesh.PopopxMeshEvent
import chat.popopx.common.mesh.PopopxMeshEventHub
import chat.popopx.common.mesh.PopopxMeshIdentity
import chat.popopx.common.mesh.PopopxMeshMessageType
import chat.popopx.common.mesh.PopopxMeshPacket
import chat.popopx.common.mesh.PopopxMeshSendFailure
import chat.popopx.common.mesh.PopopxMeshSecretStoring
import chat.popopx.common.mesh.meshHex
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking

/**
 * The three things this port changed about frame loss: a packet that could not be used is not eaten for
 * the whole flood window, a frame the radio refused is offered again, and a stream too large to
 * reassemble is refused out loud instead of vanishing.
 *
 * The clock is injected in every case, because all three are statements about *windows* and a test that
 * waited for a wall clock would prove nothing about their bounds.
 */
class PopopxMeshRetransmitTest {
  // MARK: - The three windows

  @Test
  fun aPacketThisNodeCouldNotUseIsClaimableAgainAfterTheShortWindow() {
    var now = 1_700_000_000_000L
    val dedup = PopopxMeshDeduplicator(PopopxMeshConfig.default, { now })
    val packet = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
    assertTrue(dedup.claim(packet), "the first copy is this node's to work on")
    assertFalse(dedup.claim(packet), "two copies of one flood must not both be worked on")
    assertEquals(1, dedup.stats.hits)
    // The retransmission that would have finished the job carries the same bytes. Under the old rule it
    // was eaten for `recentPacketWindow` (30s); here it is only held for `refusalPacketWindow` (2s).
    now += (PopopxMeshConfig.default.refusalPacketWindow * 1000).toLong() + 1
    assertTrue(dedup.claim(packet), "the retry is the same packet, not a duplicate of a delivered one")
    assertEquals(0, dedup.stats.recentCount, "a refusal never entered the flood window")
  }

  @Test
  fun confirmingAPacketPromotesItIntoTheFloodWindow() {
    var now = 1_700_000_000_000L
    val config = PopopxMeshConfig.default
    val dedup = PopopxMeshDeduplicator(config, { now })
    val packet = byteArrayOf(9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6)
    assertTrue(dedup.claim(packet))
    dedup.confirm(packet)
    assertEquals(1, dedup.stats.recentCount)
    assertEquals(0, dedup.stats.refusalCount)
    // Past the short window and well inside the flood window: the rest of that flood must not be worked
    // on again, which is the whole reason a relay does not echo its own re-transmission.
    now += (config.refusalPacketWindow * 1000).toLong() + 1
    assertFalse(dedup.claim(packet))
    assertFalse(dedup.note(packet))
  }

  @Test
  fun theRefusalHoldIsBoundedByCountAsWellAsByAge() {
    val now = 1_700_000_000_000L
    val config = PopopxMeshConfig(refusalPacketMaxCount = 2)
    val dedup = PopopxMeshDeduplicator(config, { now })
    for (marker in 1..3) dedup.claim(byteArrayOf(marker.toByte(), 2, 3, 4))
    assertEquals(2, dedup.stats.refusalCount, "a peer cannot grow this node's memory by spraying ids")
    // The evicted one is claimable again at the same instant: the count bound replaces the age bound, it
    // does not extend it.
    assertTrue(dedup.claim(byteArrayOf(1, 2, 3, 4)))
    assertEquals(2, dedup.stats.refusalCount)
  }

  @Test
  fun anIdTooLongToBeOursKeepsNoState() {
    val dedup = PopopxMeshDeduplicator(PopopxMeshConfig.default, { 0 })
    assertTrue(dedup.claim(ByteArray(0)))
    assertTrue(dedup.claim(ByteArray(0)))
    val tooLong = ByteArray(PopopxMeshDeduplicator.MAX_KEY_BYTES + 1) { 7 }
    assertTrue(dedup.claim(tooLong))
    assertTrue(dedup.claim(tooLong))
    assertTrue(dedup.note(tooLong))
    dedup.confirm(tooLong)
    val stats = dedup.stats
    assertEquals(0, stats.recentCount)
    assertEquals(0, stats.refusalCount)
    assertEquals(0, stats.messageCount)
    assertEquals(0, stats.hits, "answering not-seen for bytes we never mint must not look like a hit")
  }

  @Test
  fun noteStillMeansWhatItMeantBeforeTheRetryableHoldExisted() {
    val dedup = PopopxMeshDeduplicator(PopopxMeshConfig.default, { 0 })
    val packet = byteArrayOf(4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4)
    assertTrue(dedup.note(packet))
    assertFalse(dedup.note(packet))
    assertEquals(1, dedup.stats.recentCount)
    assertEquals(0, dedup.stats.refusalCount, "the outbound path never takes a claim")
    assertTrue(dedup.contains(packet))
  }

  // MARK: - The engine on a radio that refuses

  private fun engineWith(
    transport: FakeMeshTransport,
    config: PopopxMeshConfig,
    hub: PopopxMeshEventHub = PopopxMeshEventHub(),
  ): Pair<PopopxMeshEngine, EventLog> {
    val engine = PopopxMeshEngine(
      config = config,
      transport = transport,
      hub = hub,
      secrets = FakeMeshSecrets(),
      nowMillis = { 1_700_000_000_000L },
      relayDelay = { 0.0 },
    )
    return engine to EventLog(hub.subscribe())
  }

  private suspend fun awaitSent(transport: FakeMeshTransport, atLeast: Int, withinMillis: Long = 3_000): Boolean {
    var waited = 0L
    while (transport.sent.size < atLeast && waited < withinMillis) {
      delay(20)
      waited += 20
    }
    return transport.sent.size >= atLeast
  }

  /**
   * `didFailToSend` publishes from the engine's own thread, so a [EventLog.drain] taken in the same
   * instant as the call reads an empty channel and reports that as the result.
   */
  private suspend fun awaitSendFailures(events: EventLog, withinMillis: Long = 3_000): List<PopopxMeshEvent.SendFailed> {
    val seen = mutableListOf<PopopxMeshEvent>()
    var waited = 0L
    while (true) {
      seen += events.drain()
      val failures = seen.filterIsInstance<PopopxMeshEvent.SendFailed>()
      if (failures.isNotEmpty() || waited >= withinMillis) return failures
      delay(20)
      waited += 20
    }
  }

  /** The engine hands the transport one encoded packet per frame, so the retry is the same bytes. */
  private fun sameBytes(left: ByteArray, right: ByteArray) = left.toList() == right.toList()

  @Test
  fun anOversizedBroadcastIsRefusedBeforeItReachesTheRadio() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("a")))
    val config = PopopxMeshConfig(maxReassembledBytes = 16)
    val (engine, events) = engineWith(transport, config)
    try {
      engine.start()
      events.drain()
      engine.sendBroadcast("this payload is longer than sixteen bytes on purpose")
      val failures = events.drain().filterIsInstance<PopopxMeshEvent.SendFailed>()
      assertEquals(1, failures.size)
      val reason = failures.first().reason
      assertTrue(reason is PopopxMeshSendFailure.Oversized, "reported as $reason")
      assertEquals(16, (reason as PopopxMeshSendFailure.Oversized).limitBytes)
      assertEquals(0, transport.sent.size, "nothing was put on the radio for a stream that would be deleted")
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun aRefusedWriteIsOfferedAgainRatherThanLost() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("a")))
    val (engine, events) = engineWith(transport, PopopxMeshConfig.default)
    try {
      engine.start()
      events.drain()
      engine.sendBroadcast("one retry")
      val frame = transport.sent.single().first
      events.drain()
      transport.sink!!.didFailToSend(frame, "a", PopopxBLETransportError.WriteQueueFull("a"))
      assertTrue(
        awaitSent(transport, 2),
        "the refusal of a frame that never left is the one case a retry cannot duplicate a delivery",
      )
      assertEquals(1, events.drain().filterIsInstance<PopopxMeshEvent.SendFailed>().size)
      val first = transport.sent[0].first
      val second = transport.sent[1].first
      assertTrue(sameBytes(first, second), "the same packet id, so the peer's dedup keeps it one message")
      assertEquals("a", transport.sent[1].second, "retried out of the link that refused it")
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun theRetryBudgetIsPerPacketAndThenStops() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("a")))
    val config = PopopxMeshConfig(meshDeliveryRetries = 2)
    val (engine, events) = engineWith(transport, config)
    try {
      engine.start()
      events.drain()
      engine.sendBroadcast("bounded")
      val frame = transport.sent.single().first
      transport.sink!!.didFailToSend(frame, "a", PopopxBLETransportError.WriteQueueFull("a"))
      assertTrue(awaitSent(transport, 2))
      transport.sink!!.didFailToSend(transport.sent.last().first, "a", PopopxBLETransportError.WriteQueueFull("a"))
      assertTrue(awaitSent(transport, 3))
      // Third refusal, same id: the budget is spent, and a node that keeps re-flooding a frame the peer
      // never takes is the failure mode this whole path was added to avoid.
      transport.sink!!.didFailToSend(transport.sent.last().first, "a", PopopxBLETransportError.WriteQueueFull("a"))
      delay(300)
      assertEquals(3, transport.sent.size, "meshDeliveryRetries = 2 means two more attempts, not a hundred")
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun aNodeWithNoRetriesReportsTheRefusalAndSendsNothingMore() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("a")))
    val config = PopopxMeshConfig(meshDeliveryRetries = 0)
    val (engine, events) = engineWith(transport, config)
    try {
      engine.start()
      events.drain()
      engine.sendBroadcast("no budget")
      val frame = transport.sent.single().first
      transport.sink!!.didFailToSend(frame, "a", PopopxBLETransportError.WriteQueueFull("a"))
      assertTrue(awaitSendFailures(events).isNotEmpty(), "the user still hears about it")
      delay(300)
      assertEquals(1, transport.sent.size, "a retry budget of zero is honoured, not defaulted")
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun restartingTheEngineSpendsTheBudgetAgain() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("a")))
    val (engine, events) = engineWith(transport, PopopxMeshConfig.default)
    try {
      engine.start()
      events.drain()
      engine.sendBroadcast("spent then reset")
      val frame = transport.sent.single().first
      repeat(2) {
        transport.sink!!.didFailToSend(transport.sent.last().first, "a", PopopxBLETransportError.WriteQueueFull("a"))
      }
      assertTrue(awaitSent(transport, 3))
      engine.stop()
      events.drain()
      engine.start()
      events.drain()
      engine.sendBroadcast("spent then reset")
      assertEquals(4, transport.sent.size)
      transport.sink!!.didFailToSend(transport.sent.last().first, "a", PopopxBLETransportError.WriteQueueFull("a"))
      assertTrue(
        awaitSent(transport, 5),
        "the counts belong to a session, and a new one has not tried anything yet",
      )
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }

  @Test
  fun aRefusedBroadcastIsReportedEvenThoughItHasNoRecipient() = runBlocking {
    val transport = FakeMeshTransport(linkList = mutableListOf(meshLink("a")))
    val (engine, events) = engineWith(transport, PopopxMeshConfig(meshDeliveryRetries = 0))
    try {
      engine.start()
      events.drain()
      engine.sendBroadcast("to nobody in particular")
      val frame = transport.sent.single().first
      transport.sink!!.didFailToSend(frame, "a", PopopxBLETransportError.WriteQueueFull("a"))
      val failure = awaitSendFailures(events).single()
      val packet = PopopxMeshPacket.decode(frame)!!
      assertEquals(packet.packetID.meshHex(), failure.messageId)
      assertEquals(null, failure.peer, "the guard that returned on a nil recipient is what silenced this")
    } finally {
      engine.stop()
      engine.shutdown()
    }
  }
}
