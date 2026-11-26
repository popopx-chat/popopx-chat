package chat.popopx.common.mesh

/**
 * Three memories with three jobs — a port of
 * `apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Route/PopopxMeshDeduplicator.swift`.
 *
 * The short one holds packet ids for the seconds a flood is in the air, and is what stops a relay from
 * echoing its own re-transmission back down the mesh. The long one holds message ids for minutes, so a
 * message that arrived twice — over two links, or from the router after the radio already delivered it —
 * is shown to the user once.
 *
 * The packet window is joined by a third, shorter one: an id this node claimed but could not use. A
 * refused packet must not sit in the flood window for 30 seconds, because the retransmission that would
 * have completed it is the same bytes, and a mesh that eats its own retries cannot be asked to deliver
 * anything. It must not be forgotten either, or every hop of an undecryptable flood repeats the work of
 * failing it.
 *
 * All three are bounded twice over, by age and by count, because each bound fails on its own: a TTL alone
 * lets a peer spray new ids and grow the table without limit, and a count alone lets a peer keep one id
 * alive forever by re-sending it.
 *
 * iOS is an actor; [Synchronized] is the same serialisation, kept per call because nothing here blocks.
 * [now] is injectable so the ageing paths are testable without waiting for a clock.
 */
class PopopxMeshDeduplicator(
  config: PopopxMeshConfig = PopopxMeshConfig.default,
  private val now: () -> Long = { System.currentTimeMillis() },
) {
  private val recentWindowMillis: Long = millisOf(maxOf(0.0, config.recentPacketWindow))
  private val recentMaxCount: Int = maxOf(1, config.recentPacketMaxCount)
  private val refusalWindowMillis: Long = millisOf(maxOf(0.0, config.refusalPacketWindow))
  private val refusalMaxCount: Int = maxOf(1, config.refusalPacketMaxCount)
  private val messageWindowMillis: Long = millisOf(maxOf(0.0, config.messageDedupMaxAge))
  private val messageMaxCount: Int = maxOf(1, config.messageDedupMaxCount)

  private val packets = Window()
  private val refused = Window()
  private val messages = Window()
  private var hits = 0

  // MARK: Packet level

  /**
   * true the first time an id is seen — the caller may put it on the radio. false means it is a repeat and
   * the caller must drop it.
   */
  @Synchronized
  fun note(packetID: ByteArray): Boolean {
    if (packetID.isEmpty() || packetID.size > MAX_KEY_BYTES) {
      // Not an id this engine mints, so not worth a dictionary key: answer "not seen" and stay stateless
      // about it, which relays one copy instead of letting a stranger size our memory by his own bytes.
      // iOS logs this line; nothing here can be logged without a platform seam, so the branch is silent.
      return true
    }
    val timestamp = now()
    val key = packetID.meshHex()
    packets.removeExpired(timestamp - recentWindowMillis)
    if (packets.contains(key)) {
      hits += 1
      return false
    }
    insert(key, timestamp, target = packets, cap = recentMaxCount)
    return true
  }

  /** Insert plus the count bound, which every writer needs and each used to spell out. */
  private fun insert(id: String, at: Long, target: Window, cap: Int) {
    target.insert(id, at)
    while (target.count > cap) {
      if (!target.removeOldest()) break
    }
  }

  /**
   * Take the packet for this node alone, for as long as the short window: the caller is about to decide
   * whether it can use it, and two copies of one flood must not both make that decision. false means the
   * id is already held by either window.
   */
  @Synchronized
  fun claim(packetID: ByteArray): Boolean {
    if (packetID.isEmpty() || packetID.size > MAX_KEY_BYTES) return true
    val timestamp = now()
    val key = packetID.meshHex()
    packets.removeExpired(timestamp - recentWindowMillis)
    refused.removeExpired(timestamp - refusalWindowMillis)
    if (packets.contains(key) || refused.contains(key)) {
      hits += 1
      return false
    }
    insert(key, timestamp, target = refused, cap = refusalMaxCount)
    return true
  }

  /**
   * The packet was consumed or forwarded: move its id from the retryable hold into the flood window,
   * which is what stops the rest of that flood from being worked on again.
   */
  @Synchronized
  fun confirm(packetID: ByteArray) {
    if (packetID.isEmpty() || packetID.size > MAX_KEY_BYTES) return
    val timestamp = now()
    val key = packetID.meshHex()
    refused.remove(key)
    packets.removeExpired(timestamp - recentWindowMillis)
    if (packets.contains(key)) return
    insert(key, timestamp, target = packets, cap = recentMaxCount)
  }

  /**
   * Whether we would relay it, without saying that we looked. Also expires the front of the window, so a
   * caller that only asks still keeps the table honest.
   */
  @Synchronized
  fun contains(packetID: ByteArray): Boolean {
    packets.removeExpired(now() - recentWindowMillis)
    return packets.contains(packetID.meshHex())
  }

  // MARK: Message level

  /**
   * true when this envelope id has not been delivered yet, i.e. the caller should show or store it. Keyed by
   * `PopopxMeshEnvelope.id`, which the sender mints and reuses verbatim across Bluetooth and SMP retries.
   */
  @Synchronized
  fun noteMessage(id: String): Boolean {
    val bytes = id.toByteArray(Charsets.UTF_8)
    if (bytes.isEmpty() || bytes.size > PopopxMeshControlFrame.MAX_ARGUMENT_LENGTH) {
      // Same rule as the packet window, bounded by the length an id this app mints can have.
      return true
    }
    val timestamp = now()
    val key = bytes.meshHex()
    messages.removeExpired(timestamp - messageWindowMillis)
    if (messages.contains(key)) {
      hits += 1
      return false
    }
    messages.insert(key, timestamp)
    while (messages.count > messageMaxCount) {
      if (!messages.removeOldest()) break
    }
    return true
  }

  /** Message ids held, newest first — the order `PopopxGCSFilter.build` needs, so trimming to a byte budget drops the oldest. */
  @Synchronized
  fun seenMessageIDs(): List<ByteArray> = messages.idsNewestFirst.map { it.meshHexToBytes() ?: ByteArray(0) }

  /**
   * A sketch of what we already have, for a peer that resyncs after being out of range.
   *
   * Built on message ids, not packet ids, on purpose: a packet id names one radio frame, so the flood window
   * is a different set every second, is capped at 100 entries, and says nothing to a peer asking about hours
   * of history. The message id is the thing whose re-delivery a user would notice, and the message window is
   * the one that outlives a resync.
   *
   * Measured on iOS: this has no production caller there either, only tests. Ported as a primitive, not wired
   * into a frame — no mesh packet type carries a gossip filter (ruling 3).
   */
  @Synchronized
  fun gossipFilter(maxBytes: Int, targetFalsePositiveRate: Double): PopopxGCSFilter? =
    PopopxGCSFilter.build(
      ids = seenMessageIDs(),
      maxBytes = maxBytes,
      targetFalsePositiveRate = targetFalsePositiveRate,
    )

  // MARK: Housekeeping

  /**
   * Drops what has aged out of both windows. The mutating calls above do the same work for the front of each
   * queue, so this only has to be called on a timer, and [nowMillis] is a parameter so a test can move the
   * clock instead of waiting for it.
   */
  @Synchronized
  fun prune(nowMillis: Long) {
    packets.removeExpired(nowMillis - recentWindowMillis)
    refused.removeExpired(nowMillis - refusalWindowMillis)
    messages.removeExpired(nowMillis - messageWindowMillis)
  }

  val stats: PopopxMeshDedupStats
    @Synchronized get() = PopopxMeshDedupStats(
      recentCount = packets.count,
      messageCount = messages.count,
      hits = hits,
      refusalCount = refused.count,
    )

  // MARK: - Window

  /**
   * Insertion-ordered id set with O(1) access to the oldest entry. Insertion order is also age order, because
   * a repeat sighting neither moves its key nor refreshes its stamp: replaying a stale id must not let a peer
   * keep it alive past the window it was supposed to leave.
   *
   * Keys are the hex of the id bytes rather than the bytes, because Kotlin's `ByteArray` hashes by identity;
   * hex is injective, so the set means the same thing.
   */
  private class Window {
    private val stamps = HashMap<String, Long>()
    private val order = ArrayList<String>()
    private var head = 0

    val count: Int get() = stamps.size

    fun contains(id: String): Boolean = stamps.containsKey(id)

    /** For an id [contains] has already reported absent; inserting a known id twice would put two queue entries behind one key and skew the eviction order. */
    fun insert(id: String, at: Long) {
      stamps[id] = at
      order.add(id)
      compact()
    }

    fun oldest(): Pair<String, Long>? {
      while (head < order.size) {
        val candidate = order[head]
        val at = stamps[candidate]
        if (at != null) return candidate to at
        head += 1
      }
      return null
    }

    /**
     * The queue keeps the dead key and [oldest] walks past it, which is why removing a middle entry costs
     * nothing: compacting the array per confirm would make the flood path O(n) to hand one id from one
     * window to the other.
     */
    fun remove(id: String): Boolean = stamps.remove(id) != null

    fun removeOldest(): Boolean {
      val (id, _) = oldest() ?: return false
      stamps.remove(id)
      head += 1
      compact()
      return true
    }

    fun removeExpired(before: Long): Int {
      var removed = 0
      while (true) {
        val (id, at) = oldest() ?: break
        if (at >= before) break
        stamps.remove(id)
        head += 1
        removed += 1
      }
      if (removed > 0) compact()
      return removed
    }

    val idsNewestFirst: List<String> get() = order.subList(head, order.size).reversed()

    /**
     * Amortises the queue: the front is dropped in bulk once half of it is dead, so eviction stays O(1)
     * instead of shifting the whole array per insert.
     */
    private fun compact() {
      if (head <= 0 || head * 2 < order.size) return
      repeat(head) { order.removeAt(0) }
      head = 0
    }
  }

  companion object {
    /**
     * `PopopxMeshPacket.packetID` is 16 bytes and a mesh message id is capped by
     * `PopopxMeshControlFrame.MAX_ARGUMENT_LENGTH`. Anything longer is not an id this engine mints.
     */
    const val MAX_KEY_BYTES: Int = 64

    private fun millisOf(seconds: Double): Long = (seconds * 1000).toLong()
  }
}

/** What the two windows hold and how much flooding this node has suppressed. */
class PopopxMeshDedupStats(
  /** Ids in the flood window. */
  val recentCount: Int,
  /** Ids in the message window. */
  val messageCount: Int,
  /** Ids held only because this node could not use them — the retryable ones. */
  val refusalCount: Int = 0,
  /**
   * Times a `note` or `claim` call found the id already there, i.e. how much flooding this node has
   * suppressed. Counted on the deciding calls only: [contains] is a question.
   */
  val hits: Int,
) {
  override fun equals(other: Any?): Boolean =
    other is PopopxMeshDedupStats &&
      other.recentCount == recentCount &&
      other.messageCount == messageCount &&
      other.refusalCount == refusalCount &&
      other.hits == hits

  override fun hashCode(): Int = 31 * (31 * (31 * recentCount + messageCount) + refusalCount) + hits

  override fun toString(): String =
    "PopopxMeshDedupStats(recentCount=$recentCount, messageCount=$messageCount, refusalCount=$refusalCount, hits=$hits)"
}
