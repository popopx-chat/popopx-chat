package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxBLELink
import chat.popopx.common.mesh.PopopxBLELinkTable
import chat.popopx.common.mesh.PopopxBLELinkTable.SendDecision
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * The Kotlin port of `apps/ios/PopopxMeshKit/Tests/PopopxMeshKitTests/PopopxBLELinkTableTests.swift`,
 * one test per case, written against the port in `commonMain` rather than translated assertion by
 * assertion.
 *
 * The reason this exists twice is the same reason the table lives apart from the transport: every
 * decision in it — may I take a frame now, how large may it be, does another frame already own this
 * link's queue, may we dial one more neighbour — is arithmetic, not Bluetooth, and a mistake in it loses
 * a message on a device rather than failing a build on a laptop. iOS had these cases; the port had none.
 *
 * Where the two platforms genuinely cannot agree, the difference is in the file under test and stated in
 * its comment: the link id is iOS' `UUID` and Android's role-prefixed MAC address, and the table has no
 * clock (age order is a counter), so nothing here can pin a wall-clock behaviour either way.
 */
internal class PopopxBLELinkTableTest {
  private val central = "c:AA"
  private val listener = "p:BB"

  private fun table(
    maxQueuedFrames: Int = 64,
    maxCentralLinks: Int = 6,
    maxMTU: Int = 512,
  ) = PopopxBLELinkTable(maxQueuedFrames = maxQueuedFrames, maxCentralLinks = maxCentralLinks, maxMTU = maxMTU)

  private fun frame(marker: Int, bytes: Int = 4) = ByteArray(bytes) { if (it == 0) marker.toByte() else 0 }

  /** A link whose gate is open, which is the state a frame has to reach before the radio takes it. */
  private fun writableLink(
    table: PopopxBLELinkTable,
    linkID: String,
    isCentralRole: Boolean = true,
  ) {
    table.open(linkID, isCentralRole)
    table.setCanSend(true, linkID)
  }

  private fun SendDecision.isQueued(): Boolean = this is SendDecision.Queued

  private fun SendDecision.transmitted(): ByteArray? = (this as? SendDecision.Transmit)?.frame

  private fun SendDecision.rejected(): String? = (this as? SendDecision.Rejected)?.error?.message

  private fun List<ByteArray>.contentEqualsAll(other: List<ByteArray>) =
    size == other.size && zip(other).all { (a, b) -> a.contentEquals(b) }

  // MARK: - MTU and frame size

  @Test
  fun aFreshLinkCarriesTheATTDefaultOfTwentyThree() {
    val table = table()
    table.open(central, isCentralRole = true)
    val link = table.link(central)
    assertEquals(PopopxBLELink.DEFAULT_ATT_MTU, link?.negotiatedMTU)
    assertEquals(23, link?.negotiatedMTU)
    assertEquals(20, link?.usablePayloadBytes)
    assertEquals(false, link?.canSend)
    assertNull(link?.rssi)
  }

  @Test
  fun usablePayloadTracksTheNegotiatedMTU() {
    val table = table()
    table.open(central, isCentralRole = true)
    table.recordMTU(512, central)
    assertEquals(509, table.link(central)?.usablePayloadBytes)
    table.recordMTU(185, central)
    assertEquals(182, table.link(central)?.usablePayloadBytes)
    table.recordMTU(23, central)
    assertEquals(20, table.link(central)?.usablePayloadBytes)
  }

  @Test
  fun anAbsurdMTUIsClampedIntoTheRangeWeCanHonour() {
    val table = table(maxMTU = 512)
    table.open(central, isCentralRole = true)
    table.recordMTU(9_000, central)
    assertEquals(512, table.link(central)?.negotiatedMTU)
    table.recordMTU(4, central)
    assertEquals(PopopxBLELink.DEFAULT_ATT_MTU, table.link(central)?.negotiatedMTU)
  }

  @Test
  fun theWriteBudgetTheRadioReportsGainsTheATTHeaderBack() {
    val table = table()
    table.open(central, isCentralRole = true)
    assertEquals(23, table.recordWriteBudget(20, central))
    assertEquals(512, table.recordWriteBudget(509, central))
    assertEquals(509, table.link(central)?.usablePayloadBytes)
    // A zero budget means the radio told us nothing, not that the link shrank to nothing.
    assertNull(table.recordWriteBudget(0, central))
    assertEquals(512, table.link(central)?.negotiatedMTU)
    assertNull(table.recordWriteBudget(100, "c:unknown"))
  }

  @Test
  fun anOversizedFrameIsRefusedWholeRatherThanCutDown() {
    val table = table()
    writableLink(table, central)
    assertEquals(20, table.link(central)?.usablePayloadBytes)
    val oversized = frame(0xA5, bytes = 21)
    assertEquals("frameTooLarge(bytes=21, usable=20)", table.requestSend(oversized, central).rejected())
    assertEquals(0, table.queueDepth)
    assertEquals(0, table.framesInFlight)
    // The same bytes fit once the link's MTU does, which is the only way a peer that negotiated 512
    // ever gets a 300-byte fragment.
    table.recordMTU(512, central)
    assertTrue(table.requestSend(oversized, central).transmitted()?.contentEquals(oversized) == true)
  }

  // MARK: - Queueing

  @Test
  fun framesLeaveInTheOrderTheyArrived() {
    val table = table()
    table.open(central, isCentralRole = true)
    val frames = (0 until 4).map { frame(it) }
    for (one in frames) assertTrue(table.requestSend(one, central).isQueued())
    assertEquals(4, table.queueDepth(central))
    // Nothing may leave while the gate is shut, however long the queue is.
    assertNull(table.nextPendingFrame(central))
    table.setCanSend(true, central)
    val drained = (0 until 4).map { table.nextPendingFrame(central) }
    assertTrue(drained.map { it!! }.contentEqualsAll(frames))
    assertNull(table.nextPendingFrame(central))
    assertEquals(0, table.queueDepth)
  }

  @Test
  fun aFrameIsOnlyReleasedToTheRadioWhenTheLinkCanTakeIt() {
    val table = table()
    writableLink(table, central)
    val first = frame(1)
    val second = frame(2)
    // Empty queue and an open gate: straight through, counted as in flight.
    assertTrue(table.requestSend(first, central).transmitted()?.contentEquals(first) == true)
    assertEquals(1, table.framesInFlight)
    // The gate shuts: from here the table owns the bytes.
    table.setCanSend(false, central)
    assertTrue(table.requestSend(second, central).isQueued())
    assertNull(table.nextPendingFrame(central))
    // Opening it again hands out the frame that arrived first, not the newest one.
    assertEquals(true, table.setCanSend(true, central)?.canSend)
    assertEquals(0, table.framesInFlight, "the callback that reopens the gate is the notice that the buffer drained")
    assertTrue(table.nextPendingFrame(central)?.contentEquals(second) == true)
    assertEquals(1, table.framesInFlight)
  }

  @Test
  fun aFullQueueRefusesTheFrameThatDoesNotFit() {
    val table = table(maxQueuedFrames = 2)
    table.open(central, isCentralRole = true)
    assertTrue(table.requestSend(frame(0x0A), central).isQueued())
    assertTrue(table.requestSend(frame(0x0B), central).isQueued())
    assertEquals("writeQueueFull($central)", table.requestSend(frame(0x0C), central).rejected())
    assertEquals(2, table.queueDepth(central))
    // Draining one opens exactly one slot again — the cap is a bound, not a latch.
    table.setCanSend(true, central)
    assertTrue(table.nextPendingFrame(central) != null)
    assertTrue(table.requestSend(frame(0x0C), central).isQueued())
    assertEquals(2, table.queueDepth(central))
  }

  @Test
  fun aFrameTheRadioRefusedGoesBackToTheFrontOfItsQueue() {
    val table = table()
    writableLink(table, central)
    val first = frame(1)
    val second = frame(2)
    assertTrue(table.requestSend(first, central).transmitted()?.contentEquals(first) == true)
    // The write buffer filled up: from here on the table owns the bytes again.
    table.setCanSend(false, central)
    assertTrue(table.requestSend(second, central).isQueued())
    assertEquals(1, table.framesInFlight(central))
    // The radio said no to `first`; it must overtake nothing.
    assertTrue(table.returnFrame(first, central))
    assertEquals(0, table.framesInFlight)
    table.setCanSend(true, central)
    assertTrue(table.nextPendingFrame(central)?.contentEquals(first) == true)
    assertTrue(table.nextPendingFrame(central)?.contentEquals(second) == true)
  }

  @Test
  fun abandoningAFrameSettlesTheCountWithoutQueueingIt() {
    val table = table()
    writableLink(table, central)
    table.requestSend(frame(1), central)
    assertEquals(1, table.framesInFlight(central))
    table.abandonFrame(central)
    assertEquals(0, table.framesInFlight)
    assertEquals(0, table.queueDepth)
    // An unknown link has nothing to abandon, and must not invent one.
    table.abandonFrame("c:unknown")
    assertEquals(1, table.linkCount, "abandoning on a link nobody opened must not invent one")
    assertTrue(!table.returnFrame(frame(1), "c:unknown"))
  }

  @Test
  fun sendingToAnUnknownLinkIsReportedAsSuch() {
    val table = table()
    assertEquals("linkNotFound($central)", table.requestSend(frame(1), central).rejected())
    assertNull(table.nextPendingFrame(central))
    assertNull(table.setCanSend(true, central))
    assertNull(table.recordMTU(200, central))
    assertEquals(0, table.queueDepth(central))
  }

  // MARK: - Gates, handshakes, admission

  @Test
  fun onlyTheFlipIntoWritableIsWorthAnnouncing() {
    val table = table()
    table.open(central, isCentralRole = true)
    assertNull(table.setCanSend(false, central), "already shut, so nothing changed")
    assertEquals(true, table.setCanSend(true, central)?.canSend)
    assertNull(table.setCanSend(true, central), "a repeat open is background noise on a busy link")
    assertEquals(false, table.setCanSend(false, central)?.canSend)
    assertNull(table.setCanSend(false, central))
  }

  @Test
  fun aHandshakeStaysPendingUntilTheLinkIsUsable() {
    val table = table()
    table.open(central, isCentralRole = true)
    assertEquals(0, table.pendingHandshakeCount)
    table.markHandshakePending(central)
    assertEquals(listOf(central), table.pendingHandshakeIDs)
    assertEquals(1, table.pendingHandshakeCount)
    table.completeHandshake(central)
    assertEquals(0, table.pendingHandshakeCount)
    // Closing a link that was still handshaking says so, which is how the transport knows a
    // continuation on it has to be answered.
    table.markHandshakePending(central)
    assertEquals(true, table.close(central)?.handshakeWasPending)
  }

  @Test
  fun theCentralBudgetCountsTheLinksWeDialedAndIgnoresTheOnesDialedIntoUs() {
    val table = table(maxCentralLinks = 2)
    assertTrue(table.admitsCentralLink())
    table.open("c:00", isCentralRole = true)
    table.open(listener, isCentralRole = false)
    assertEquals(1, table.centralLinkCount)
    assertTrue(table.admitsCentralLink())
    table.open(central, isCentralRole = true)
    assertEquals(2, table.centralLinkCount)
    assertTrue(!table.admitsCentralLink())
    // Saturated outgoing budget, but a neighbour may still connect to us.
    assertEquals(3, table.linkCount)
    table.open("p:00", isCentralRole = false)
    assertEquals(4, table.linkCount)
    assertTrue(!table.admitsCentralLink())
  }

  @Test
  fun rssiIsRecordedAgainstTheLinkThatReportedIt() {
    val table = table()
    table.open(central, isCentralRole = true)
    assertNull(table.link(central)?.rssi)
    table.recordRssi((-72).toByte(), central)
    assertEquals((-72).toByte(), table.link(central)?.rssi)
    table.recordRssi((-40).toByte(), central)
    assertEquals((-40).toByte(), table.link(central)?.rssi)
    table.recordRssi(-1, "c:unknown")
    assertEquals(1, table.linkCount)
  }

  // MARK: - Closing

  @Test
  fun closingALinkHandsBackTheFramesItNeverReleased() {
    val table = table()
    writableLink(table, central)
    table.requestSend(frame(1), central)
    table.setCanSend(false, central)
    table.requestSend(frame(2), central)
    table.requestSend(frame(3), central)
    assertEquals(1, table.framesInFlight(central))
    assertEquals(2, table.queueDepth(central))

    val outcome = table.close(central) ?: error("the link was not there to close")
    assertEquals(1, outcome.droppedInFlightFrameCount)
    assertEquals(2, outcome.droppedQueuedFrames.size)
    assertTrue(outcome.droppedQueuedFrames.contentEqualsAll(listOf(frame(2), frame(3))))
    assertEquals(central, outcome.link.linkID)
    // Nothing survives the link that held it — the leak this whole type exists to prevent.
    assertEquals(0, table.framesInFlight)
    assertEquals(0, table.queueDepth)
    assertEquals(0, table.pendingHandshakeCount)
    assertNull(table.link(central))
    assertNull(table.close(central))
  }

  @Test
  fun closeAllEmptiesEveryQueueAtOnce() {
    val table = table(maxQueuedFrames = 8, maxCentralLinks = 8)
    val ids = (0 until 4).map { "c:$it" }
    for ((offset, id) in ids.withIndex()) {
      table.open(id, isCentralRole = offset % 2 == 0)
      table.markHandshakePending(id)
      table.requestSend(frame(offset), id)
    }
    assertEquals(4, table.queueDepth)
    val outcomes = table.closeAll()
    assertEquals(4, outcomes.size)
    assertEquals(ids.toSet(), outcomes.map { it.link.linkID }.toSet())
    assertEquals(4, outcomes.sumOf { it.droppedQueuedFrames.size })
    assertEquals(4, outcomes.count { it.handshakeWasPending })
    assertTrue(table.isEmpty)
    assertTrue(table.linkIDs.isEmpty())
    assertEquals(0, table.queueDepth)
    assertEquals(0, table.framesInFlight)
    assertEquals(0, table.pendingHandshakeCount)
    assertTrue(table.admitsCentralLink())
  }

  @Test
  fun reopeningALinkDoesNotInheritTheOldQueue() {
    val table = table()
    writableLink(table, central)
    table.requestSend(frame(1), central)
    table.setCanSend(false, central)
    table.requestSend(frame(2), central)
    assertEquals(1, table.queueDepth(central))
    assertEquals(1, table.framesInFlight)
    // The id is the peer's address, so the same id means a re-discovered bearer: bytes captured against
    // the old ATT session would corrupt reassembly rather than recover anything.
    table.open(central, isCentralRole = true)
    assertEquals(0, table.queueDepth)
    assertEquals(0, table.framesInFlight)
    assertEquals(0, table.pendingHandshakeCount)
    assertEquals(false, table.link(central)?.canSend)
  }

  // MARK: - Concurrent bookkeeping

  /**
   * The table is shared between the radio thread and everything else, so the same calls are run at each
   * other from many coroutines and the totals still have to add up.
   */
  @Test
  fun concurrentEnqueuesNeitherCrashNorLoseCount() {
    val linkCount = 4
    val perTask = 60
    val taskCount = 24
    val table = table(maxQueuedFrames = 512, maxCentralLinks = linkCount)
    val ids = (0 until linkCount).map { "c:$it" }
    for (id in ids) table.open(id, isCentralRole = true)

    var total = 0
    runBlocking {
      val accepted =
        (0 until taskCount).map { step ->
            async {
              var taken = 0
              for (index in 0 until perTask) {
                val decision = table.requestSend(frame(step % 7), ids[index % ids.size])
                when {
                  decision.isQueued() || decision.transmitted() != null -> taken += 1
                  decision.rejected() == "writeQueueFull(${ids[index % ids.size]})" -> Unit
                  else -> error("unexpected rejection ${ids[index % ids.size]}: ${decision.rejected()}")
                }
                // Interleave the readers with the writers: a snapshot taken mid-storm must still be a
                // coherent number, not a torn read of the map.
                if (index % 11 == 0) table.queueDepth + table.framesInFlight
                if (index % 17 == 0) table.links.size
              }
              taken
            }
          }
          .awaitAll()
          .sum()
      total = accepted
    }
    // Nothing was drained, so every request was either queued or handed to the radio, and the two
    // together are exactly what was handed in.
    assertEquals(taskCount * perTask, total)
    assertEquals(total, table.queueDepth + table.framesInFlight)
    assertTrue(table.queueDepth <= linkCount * 512)

    for (id in ids) table.close(id)
    assertEquals(0, table.queueDepth)
    assertEquals(0, table.framesInFlight)
  }

  @Test
  fun concurrentDrainAndEnqueueConserveTheFrames() {
    val table = table(maxQueuedFrames = 128)
    val linkID = central
    writableLink(table, linkID)
    val rounds = 40

    runBlocking {
      listOf(
          launch { repeat(rounds) { table.requestSend(frame(1), linkID) } },
          launch {
            repeat(rounds) {
              table.nextPendingFrame(linkID)
              table.abandonFrame(linkID)
            }
          },
          launch {
            repeat(rounds) {
              table.setCanSend(false, linkID)
              table.setCanSend(true, linkID)
            }
          },
        )
        .joinAll()
    }
    // Frames drained are frames gone; whatever is left is queued plus what the radio holds.
    assertTrue(table.queueDepth + table.framesInFlight <= rounds, "${table.queueDepth}+${table.framesInFlight} vs $rounds")
    assertEquals(1, table.linkCount)
    table.close(linkID)
    assertEquals(0, table.queueDepth)
    assertEquals(0, table.framesInFlight)
  }
}
