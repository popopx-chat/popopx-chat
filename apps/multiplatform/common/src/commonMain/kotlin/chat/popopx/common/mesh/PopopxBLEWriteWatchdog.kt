package chat.popopx.common.mesh

/**
 * Which frames the radio took and never answered, and when waiting for one stops being worth the link.
 *
 * The Android write gate shuts when a frame is handed to `BluetoothGatt.writeCharacteristic` and opens
 * again on `onCharacteristicWrite` (`androidMain/.../PopopxBLETransport.android.kt`). That callback is not
 * guaranteed: a peer that disappears without a disconnect leaves some vendor stacks with a write pending
 * forever, and a link that never reopens silently keeps every frame queued behind it. iOS does not need
 * this ledger because CoreBluetooth answers an accepted write through
 * `peripheralIsReadyToSendWriteWithoutResponse`.
 *
 * The arithmetic lives here rather than in androidMain because androidMain is not compiled by
 * `desktopTest`: the `Handler` that fires the deadline cannot run on a machine with no radio, but the
 * decision of which frame is owed back, and for how long, can be — and that decision is the part that
 * either loses a message or spends the radio forever.
 *
 * A frame that has been offered [maxStalls] times without ever being answered is given up on rather than
 * retried again: the caller reports it as failed, which is the seam the engine's own message-layer
 * retry (`PopopxMeshEngine.retransmit`) takes over from.
 */
class PopopxBLEWriteWatchdog(
  /** How long one frame may sit unacknowledged before it is put back. `<= 0` switches the ledger off. */
  private val timeoutMillis: Long,
  private val maxStalls: Int = DEFAULT_MAX_STALLS,
) {
  /**
   * A frame whose wait is over. [owed] means the radio holds the only copy, so the caller must put it back;
   * without it the frame is already at the head of its link's queue and only the gate is stuck. [gaveUp]
   * means this is the last notice, and the link's gate still has to be reopened or whatever is queued
   * behind it would never move.
   */
  class Stalled(val linkID: String, val frame: ByteArray, val owed: Boolean, val gaveUp: Boolean)

  private class Ticket(
    val frame: ByteArray,
    val owed: Boolean,
    var dueAt: Long,
    var stalls: Int,
  )

  private val tickets = HashMap<String, Ticket>()

  /**
   * The radio took this frame for this link and has not answered. Re-tracking the same bytes — which is
   * what happens when a requeued frame goes out again — extends the deadline and keeps the stall count,
   * because that count is the only thing bounding the retries.
   *
   * [owedByRadio] is false on the path where the caller already put the frame back itself and only the
   * gate is waiting for a callback, which is a stall worth reopening but not one worth re-queueing.
   */
  @Synchronized
  fun track(
    linkID: String,
    frame: ByteArray,
    nowMillis: Long,
    owedByRadio: Boolean = true,
  ) {
    if (timeoutMillis <= 0L) return
    val held = tickets[linkID]
    if (held != null && held.frame.contentEquals(frame)) {
      held.dueAt = nowMillis + timeoutMillis
      return
    }
    tickets[linkID] = Ticket(frame, owedByRadio, nowMillis + timeoutMillis, stalls = 0)
  }

  /** `onCharacteristicWrite` arrived: whatever this link owed, it owes nothing now. */
  @Synchronized
  fun settle(linkID: String) {
    tickets.remove(linkID)
  }

  /** The link is gone. Its frames are failed by the close itself, not by a timer nobody will cancel. */
  @Synchronized
  fun forget(linkID: String) {
    tickets.remove(linkID)
  }

  @Synchronized
  fun clear() {
    tickets.clear()
  }

  /**
   * Every frame whose deadline has passed, soonest first, each with a fresh deadline unless it is the one
   * that gives up. Sorted because a link that stalled first should be the first back on the radio.
   */
  @Synchronized
  fun expired(nowMillis: Long): List<Stalled> {
    if (tickets.isEmpty()) return emptyList()
    val due = tickets.entries.filter { it.value.dueAt <= nowMillis }.sortedBy { it.value.dueAt }
    val stalled = ArrayList<Stalled>(due.size)
    for ((linkID, ticket) in due) {
      ticket.stalls += 1
      val gaveUp = ticket.stalls >= maxStalls
      if (gaveUp) tickets.remove(linkID) else ticket.dueAt = nowMillis + timeoutMillis
      stalled += Stalled(linkID, ticket.frame, ticket.owed, gaveUp)
    }
    return stalled
  }

  /** The soonest deadline, so the caller arms one timer for every owed frame instead of one per frame. */
  @Synchronized
  fun nextDueAt(): Long? = tickets.values.minOfOrNull { it.dueAt }

  @Synchronized
  fun trackedCount(): Int = tickets.size

  companion object {
    /**
     * Three unanswered offers of one frame, i.e. fifteen seconds against the default
     * `bleAckTimeout`, after which the peer is treated as gone rather than slow.
     */
    const val DEFAULT_MAX_STALLS: Int = 3
  }
}
