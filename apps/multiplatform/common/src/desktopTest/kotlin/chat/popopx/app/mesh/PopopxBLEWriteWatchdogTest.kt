package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxBLEWriteWatchdog
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The ledger behind the Android write-gate watchdog, on an injected clock.
 *
 * What is tested here is the part that decides whether a message survives: which frame is owed back, and
 * after how many unanswered offers the transport admits the peer is gone. The `Handler` that reads these
 * answers lives in androidMain, which `desktopTest` does not compile, so the arithmetic was moved out of
 * it precisely so it could be tested at all.
 */
internal class PopopxBLEWriteWatchdogTest {
  private fun frame(marker: Int) = byteArrayOf(marker.toByte(), 0, 0, 0)

  @Test
  fun aFrameBecomesOwedExactlyAtItsDeadlineAndNotBefore() {
    val ledger = PopopxBLEWriteWatchdog(timeoutMillis = 5_000)
    ledger.track("c:AA", frame(1), nowMillis = 0)
    assertEquals(1, ledger.trackedCount())
    assertEquals(5_000L, ledger.nextDueAt())
    assertTrue(ledger.expired(4_999).isEmpty(), "the callback still has a second to arrive")
    val stalled = ledger.expired(5_000)
    assertEquals(1, stalled.size)
    assertEquals("c:AA", stalled.single().linkID)
    assertTrue(stalled.single().frame.contentEquals(frame(1)), "the bytes the radio never answered")
    assertTrue(stalled.single().owed, "the radio holds the only copy, so the caller must requeue it")
    assertTrue(!stalled.single().gaveUp, "one unanswered offer is a slow peer, not a dead one")
    assertEquals(10_000L, ledger.nextDueAt(), "the frame is owed again after another full timeout")
  }

  @Test
  fun theWriteCallbackCancelsTheDebt() {
    val ledger = PopopxBLEWriteWatchdog(timeoutMillis = 5_000)
    ledger.track("c:AA", frame(1), nowMillis = 0)
    ledger.settle("c:AA")
    assertEquals(0, ledger.trackedCount())
    assertNull(ledger.nextDueAt())
    assertTrue(ledger.expired(60_000).isEmpty(), "an answered write must never be sent twice")
  }

  @Test
  fun aDifferentFrameTakesTheLinksDeadlineOver() {
    val ledger = PopopxBLEWriteWatchdog(timeoutMillis = 5_000)
    ledger.track("c:AA", frame(1), nowMillis = 0)
    ledger.track("c:AA", frame(2), nowMillis = 1_000)
    // One ATT write outstanding per link, so the first frame's fate was already settled by its caller;
    // keeping its ticket would requeue bytes the radio never had.
    assertEquals(1, ledger.trackedCount())
    assertEquals(6_000L, ledger.nextDueAt(), "the wait restarts with the bytes the radio actually took")
    assertTrue(ledger.expired(6_000).single().frame.contentEquals(frame(2)))
  }

  @Test
  fun reOfferingTheSameFrameKeepsCountingItsStalls() {
    val ledger = PopopxBLEWriteWatchdog(timeoutMillis = 5_000, maxStalls = 3)
    ledger.track("c:AA", frame(7), nowMillis = 0)
    // The transport's tick requeues the frame, the drain puts it back on the radio, and the radio goes
    // quiet again. Only the deadline moves; the stall count is what bounds this.
    assertTrue(!ledger.expired(5_000).single().gaveUp)
    ledger.track("c:AA", frame(7), nowMillis = 5_000)
    assertEquals(10_000L, ledger.nextDueAt())
    assertTrue(!ledger.expired(10_000).single().gaveUp)
    ledger.track("c:AA", frame(7), nowMillis = 10_000)
    assertTrue(ledger.expired(15_000).single().gaveUp, "the third unanswered offer is a gone peer")
    assertEquals(0, ledger.trackedCount(), "a given-up frame is not watched again")
    assertTrue(ledger.expired(60_000).isEmpty())
  }

  @Test
  fun aSettledFrameStartsFreshInsteadOfFinishingTheOldCount() {
    val ledger = PopopxBLEWriteWatchdog(timeoutMillis = 5_000, maxStalls = 2)
    ledger.track("c:AA", frame(7), nowMillis = 0)
    assertTrue(!ledger.expired(5_000).single().gaveUp)
    ledger.settle("c:AA")
    ledger.track("c:AA", frame(7), nowMillis = 6_000)
    assertTrue(!ledger.expired(11_000).single().gaveUp, "a frame that got a callback was not stalled")
  }

  @Test
  fun eachLinkIsWatchedAloneAndTheStalestGoesFirst() {
    val ledger = PopopxBLEWriteWatchdog(timeoutMillis = 5_000)
    ledger.track("c:AA", frame(1), nowMillis = 6_000)
    ledger.track("c:BB", frame(2), nowMillis = 0)
    ledger.track("p:CC", frame(3), nowMillis = 1_000)
    assertEquals(5_000L, ledger.nextDueAt())
    val stalled = ledger.expired(6_000)
    // The link owed since 5000 is handed back before the one owed since 6000, and the link not due yet
    // is left alone. Two deadlines inside the same tick would be an unordered pair, so none is made here.
    assertEquals(listOf("c:BB", "p:CC"), stalled.map { it.linkID })
    // A stall is not an ending: the two re-armed tickets stay watched next to the one that was not due,
    // all three now due at the same instant, and the third link keeps the deadline it already had.
    assertEquals(3, ledger.trackedCount(), "a stalled frame stays watched, only its deadline moved")
    assertEquals(11_000L, ledger.nextDueAt())
    assertTrue(ledger.expired(6_000).isEmpty(), "a frame is handed back once per deadline")
  }

  @Test
  fun aGateOnlyStallIsReopenedWithoutPuttingBytesBack() {
    val ledger = PopopxBLEWriteWatchdog(timeoutMillis = 5_000)
    // The notify path returns the frame to its queue itself, so requeueing it from the tick would put
    // the same bytes on the radio twice.
    ledger.track("p:CC", frame(4), nowMillis = 0, owedByRadio = false)
    val stalled = ledger.expired(5_000)
    assertTrue(!stalled.single().owed)
    assertTrue(!stalled.single().gaveUp)
  }

  @Test
  fun aGateOnlyStallEndsByStoppingToWatch() {
    val ledger = PopopxBLEWriteWatchdog(timeoutMillis = 5_000, maxStalls = 2)
    ledger.track("p:CC", frame(4), nowMillis = 0, owedByRadio = false)
    ledger.expired(5_000)
    assertTrue(ledger.expired(10_000).single().gaveUp)
    assertEquals(0, ledger.trackedCount(), "the caller must not fail bytes the link still holds")
  }

  @Test
  fun closingALinkOrTheRadioEndsTheWatch() {
    val ledger = PopopxBLEWriteWatchdog(timeoutMillis = 5_000)
    ledger.track("c:AA", frame(1), nowMillis = 0)
    ledger.track("c:BB", frame(2), nowMillis = 0)
    ledger.forget("c:AA")
    assertEquals(listOf("c:BB"), ledger.expired(5_000).map { it.linkID })
    ledger.track("c:CC", frame(3), nowMillis = 0)
    ledger.clear()
    assertEquals(0, ledger.trackedCount())
    assertNull(ledger.nextDueAt())
  }

  @Test
  fun aLedgerWithNoTimeoutWatchesNothing() {
    val ledger = PopopxBLEWriteWatchdog(timeoutMillis = 0)
    ledger.track("c:AA", frame(1), nowMillis = 0)
    assertEquals(0, ledger.trackedCount())
    assertNull(ledger.nextDueAt())
    assertTrue(ledger.expired(Long.MAX_VALUE).isEmpty(), "no timer is armed for a ledger that is empty")
  }
}
