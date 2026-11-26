package chat.popopx.common.mesh

/**
 * Per-link send bookkeeping — a line-for-line port of
 * `apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/BLE/PopopxBLELinkTable.swift`.
 *
 * It lives apart from the transport for the same reason iOS keeps it apart: every decision here — may I
 * take a frame now, how large may it be, does another frame already own this link's queue, may we dial
 * one more neighbour — is arithmetic, not Bluetooth. Kept here it runs in `desktopTest` on a machine
 * with no radio, which is where those mistakes are cheapest to find.
 *
 * iOS serialises the table with a private serial queue and states the rule that makes it safe: every
 * method is a single `gate.sync` leaf that never calls another public method from inside its critical
 * section. [Synchronized] is that lock, and the same rule is kept — the private [append] and [applyMTU]
 * leaves are called only with the monitor held.
 *
 * iOS' `PopopxBLELink` is a struct, so every value that leaves this table is a snapshot: a caller holding
 * a link from before a write does not see it go stale afterwards. [PopopxBLELink] is immutable here and
 * rebuilt by [snapshot] on each read, because a shared mutable link would quietly change that rule and the
 * engine's delivery decisions depend on it.
 */
class PopopxBLELinkTable(
  /** Frames one link may hold while its radio gate is shut. Bounded: a queue in front of a dead peer is a leak. */
  maxQueuedFrames: Int = QUEUED_FRAMES_PER_LINK,
  maxCentralLinks: Int = PopopxMeshConfig.default.maxCentralLinks,
  /** Ceiling for a reported MTU — `bleMaxMTU`. A peer that claims more than this is not our problem. */
  maxMTU: Int = PopopxMeshConfig.default.maxMTU,
) {
  /**
   * What a close took with it. The transport reads this to fail the frames that never made it and to
   * answer anyone waiting on the link. Queued frames come back by value — the radio never had them —
   * while in-flight ones are only counted.
   */
  class CloseOutcome(
    val link: PopopxBLELink,
    val droppedQueuedFrames: List<ByteArray>,
    val droppedInFlightFrameCount: Int,
    val handshakeWasPending: Boolean,
  )

  /** The answer to "may I put this frame on this link right now". */
  sealed class SendDecision {
    /** Hand these bytes to the radio immediately. Counted as in flight from this moment. */
    class Transmit(val frame: ByteArray) : SendDecision()

    /** The link took ownership of the frame and will hand it back through [nextPendingFrame]. */
    object Queued : SendDecision()

    /** The frame is still the caller's problem; the error says why. */
    class Rejected(val error: PopopxBLETransportError) : SendDecision()
  }

  private class Entry(
    val linkID: String,
    val isCentralRole: Boolean,
    var canSend: Boolean,
    var negotiatedMTU: Int,
    var rssi: Byte?,
    val openedAt: Long,
  ) {
    val queued: ArrayDeque<ByteArray> = ArrayDeque()
    var framesInFlight: Int = 0
    var handshakePending: Boolean = false
  }

  private val maxQueuedFrames: Int = maxOf(1, maxQueuedFrames)
  private val maxCentralLinks: Int = maxOf(1, maxCentralLinks)
  private val maxMTU: Int = maxOf(PopopxBLELink.DEFAULT_ATT_MTU, maxMTU)

  private val entries = HashMap<String, Entry>()

  /**
   * Age order for [links] and [closeAll]. iOS sorts by the `Date` the entry opened; a counter says the
   * same thing and stays total when two links open inside one clock tick.
   */
  private var openedSequence = 0L

  /** Leaf: reads the entry's current fields, so it is called only with the monitor held. */
  private fun snapshot(entry: Entry): PopopxBLELink =
    PopopxBLELink(
      linkID = entry.linkID,
      isCentralRole = entry.isCentralRole,
      canSend = entry.canSend,
      negotiatedMTU = entry.negotiatedMTU,
      rssi = entry.rssi,
    )

  // MARK: - Link lifecycle

  /**
   * Registers a link and returns it, so the caller can announce it. Re-opening a known [linkID]
   * replaces the entry and drops its queued frames: the id is the peer's address, so the same id means
   * a re-discovered bearer, and replaying bytes captured against the old one into a new session would
   * corrupt the engine's reassembly rather than recover anything.
   */
  @Synchronized
  fun open(
    linkID: String,
    isCentralRole: Boolean,
    canSend: Boolean = false,
    rssi: Byte? = null,
  ): PopopxBLELink {
    val entry = Entry(
      linkID = linkID,
      isCentralRole = isCentralRole,
      canSend = canSend,
      negotiatedMTU = PopopxBLELink.DEFAULT_ATT_MTU,
      rssi = rssi,
      openedAt = openedSequence++,
    )
    entries[linkID] = entry
    return snapshot(entry)
  }

  @Synchronized
  fun close(linkID: String): CloseOutcome? = outcomeFor(entries.remove(linkID))

  /** Drops every link and returns what each was holding, oldest first. */
  @Synchronized
  fun closeAll(): List<CloseOutcome> {
    val ordered = entries.values.sortedBy { it.openedAt }
    entries.clear()
    return ordered.mapNotNull { outcomeFor(it) }
  }

  /** Leaf: reads an already-removed entry, so it is called only with the monitor held. */
  private fun outcomeFor(entry: Entry?): CloseOutcome? {
    if (entry == null) return null
    return CloseOutcome(
      link = snapshot(entry),
      droppedQueuedFrames = entry.queued.toList(),
      droppedInFlightFrameCount = entry.framesInFlight,
      handshakeWasPending = entry.handshakePending,
    )
  }

  @Synchronized
  fun link(linkID: String): PopopxBLELink? = entries[linkID]?.let { snapshot(it) }

  val links: List<PopopxBLELink>
    @Synchronized get() = entries.values.sortedBy { it.openedAt }.map { snapshot(it) }

  val linkIDs: List<String>
    @Synchronized get() = entries.keys.toList()

  val isEmpty: Boolean
    @Synchronized get() = entries.isEmpty()

  val linkCount: Int
    @Synchronized get() = entries.size

  // MARK: - Central admission

  val centralLinkCount: Int
    @Synchronized get() = entries.values.count { it.isCentralRole }

  /**
   * Whether dialing one more neighbour is within `bleMaxCentralLinks`. Checked before the connect, not
   * after, so an over-budget discovery event never costs a link teardown. Our own peripheral-role links
   * are not counted — the platform caps those, and this budget exists to stop this device from
   * exhausting the shared radio with too many outgoing connections.
   */
  @Synchronized
  fun admitsCentralLink(): Boolean = entries.values.count { it.isCentralRole } < maxCentralLinks

  // MARK: - Facts the radio reports

  /**
   * Sets writability. Returns the link only when it flipped closed → open, which is the single moment
   * worth telling the engine about; a repeat `true` is background noise on a busy link. Flipping to
   * writable also clears the in-flight count, because the callback that makes a link writable again is
   * the platform's notice that the buffer those frames sat in has drained.
   */
  @Synchronized
  fun setCanSend(canSend: Boolean, linkID: String): PopopxBLELink? {
    val entry = entries[linkID] ?: return null
    if (entry.canSend == canSend) return null
    entry.canSend = canSend
    if (canSend) entry.framesInFlight = 0
    return snapshot(entry)
  }

  @Synchronized
  fun recordRssi(rssi: Byte, linkID: String) {
    entries[linkID]?.rssi = rssi
  }

  /** Stores a negotiated ATT MTU clamped into `23...maxMTU`, and returns the resulting link. */
  @Synchronized
  fun recordMTU(mtu: Int, linkID: String): PopopxBLELink? = entries[linkID]?.let { applyMTU(mtu, it) }

  /**
   * The radio-facing form: both stacks report what a link fits as a byte budget — the MTU with the
   * 3-byte ATT header taken out — rather than an ATT MTU. Returns the stored MTU, or null for an unknown
   * link or a budget that is not a fact yet.
   */
  @Synchronized
  fun recordWriteBudget(usableBytes: Int, linkID: String): Int? {
    if (usableBytes <= 0) return null
    return entries[linkID]?.let { applyMTU(usableBytes + PopopxBLELink.ATT_HEADER_BYTES, it)?.negotiatedMTU }
  }

  /** Leaf: touches an entry the caller took out of [entries], so it is called only with the monitor held. */
  private fun applyMTU(mtu: Int, entry: Entry): PopopxBLELink {
    entry.negotiatedMTU = minOf(maxOf(mtu, PopopxBLELink.DEFAULT_ATT_MTU), maxMTU)
    return snapshot(entry)
  }

  // MARK: - Handshakes

  /**
   * Marks a link as still waiting for its ATT setup to finish. The transport mirrors its pending waiters
   * here so "a close left a waiter parked forever" is a countable fact rather than a hunch.
   */
  @Synchronized
  fun markHandshakePending(linkID: String) {
    entries[linkID]?.handshakePending = true
  }

  @Synchronized
  fun completeHandshake(linkID: String): PopopxBLELink? {
    val entry = entries[linkID] ?: return null
    if (!entry.handshakePending) return snapshot(entry)
    entry.handshakePending = false
    return snapshot(entry)
  }

  val pendingHandshakeCount: Int
    @Synchronized get() = entries.values.count { it.handshakePending }

  val pendingHandshakeIDs: List<String>
    @Synchronized get() = entries.values.filter { it.handshakePending }.map { it.linkID }

  // MARK: - Queues

  /**
   * The one way a frame enters a link. Size is checked against the link's own MTU rather than truncated:
   * splitting an oversized message into ATT-sized pieces is the engine's job — it knows about fragment
   * lifetimes and relay TTLs — and a transport that quietly cut a frame in half would hand the peer a
   * corrupt packet instead of an error it can act on.
   */
  @Synchronized
  fun requestSend(frame: ByteArray, linkID: String): SendDecision {
    val entry = entries[linkID] ?: return SendDecision.Rejected(PopopxBLETransportError.LinkNotFound(linkID))
    val usable = maxOf(PopopxBLELink.MIN_USABLE_PAYLOAD_BYTES, entry.negotiatedMTU - PopopxBLELink.ATT_HEADER_BYTES)
    if (frame.size > usable) {
      return SendDecision.Rejected(PopopxBLETransportError.FrameTooLarge(frame.size, usable))
    }
    // A frame that arrives behind others already waiting takes its place at the end of the queue even
    // when the gate is open, or FIFO would be a suggestion.
    if (!entry.canSend || entry.queued.isNotEmpty()) return append(frame, entry, linkID)
    entry.framesInFlight += 1
    return SendDecision.Transmit(frame)
  }

  /** Leaf: called only with the monitor held, on an entry that came out of [entries]. */
  private fun append(frame: ByteArray, entry: Entry, linkID: String): SendDecision {
    if (entry.queued.size >= maxQueuedFrames) {
      return SendDecision.Rejected(PopopxBLETransportError.WriteQueueFull(linkID))
    }
    entry.queued.addLast(frame)
    return SendDecision.Queued
  }

  /**
   * The next frame this link may send, in arrival order, or null while the link is not writable. Callers
   * loop on it; the loop ends by itself when the queue empties or the radio closes the gate.
   */
  @Synchronized
  fun nextPendingFrame(linkID: String): ByteArray? {
    val entry = entries[linkID] ?: return null
    if (!entry.canSend || entry.queued.isEmpty()) return null
    val frame = entry.queued.removeFirst()
    entry.framesInFlight += 1
    return frame
  }

  /**
   * Puts a frame the radio refused back at the head, so a refused write keeps its place instead of
   * overtaking what was already waiting. False means the room it had is gone.
   */
  @Synchronized
  fun returnFrame(frame: ByteArray, linkID: String): Boolean {
    val entry = entries[linkID] ?: return false
    if (entry.queued.size >= maxQueuedFrames) return false
    entry.queued.addFirst(frame)
    entry.framesInFlight = maxOf(0, entry.framesInFlight - 1)
    return true
  }

  /**
   * Takes a released frame out of the count without queueing it again, for the paths where the caller has
   * already reported the frame as failed. Without it a link that could not be written to would carry an
   * in-flight frame nothing can ever settle.
   */
  @Synchronized
  fun abandonFrame(linkID: String) {
    val entry = entries[linkID] ?: return
    entry.framesInFlight = maxOf(0, entry.framesInFlight - 1)
  }

  // MARK: - Read-only totals

  @Synchronized
  fun queueDepth(linkID: String): Int = entries[linkID]?.queued?.size ?: 0

  /** Frames waiting for a writable link, across every link. */
  val queueDepth: Int
    @Synchronized get() = entries.values.sumOf { it.queued.size }

  /**
   * Frames this table handed to the radio that it has not reported as flushed. It moves when a frame
   * leaves a queue and back to zero when the link's `canSend` flips true again or the link closes, which
   * is what makes "no frame survived its link" a checkable claim.
   *
   * Measured on iOS: the table has no ageing and no LRU, and [recordMTU] has no caller there. Both are
   * kept as facts rather than improved on.
   */
  val framesInFlight: Int
    @Synchronized get() = entries.values.sumOf { it.framesInFlight }

  @Synchronized
  fun framesInFlight(linkID: String): Int = entries[linkID]?.framesInFlight ?: 0

  companion object {
    /**
     * Room for a couple of flooded broadcasts per neighbour and nothing more, past which the mesh should
     * reroute rather than buffer.
     */
    const val QUEUED_FRAMES_PER_LINK: Int = 64
  }
}
