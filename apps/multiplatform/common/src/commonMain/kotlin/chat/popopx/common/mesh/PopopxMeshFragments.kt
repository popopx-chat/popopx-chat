package chat.popopx.common.mesh

import java.security.SecureRandom

/**
 * A frame too large for one MTU goes on the radio as a run of FRAGMENT packets and is put back
 * together on the far side. Port of
 * apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Protocol/PopopxMeshFragments.swift: the 13-byte
 * header and the receiver's ceilings are Bitchat's, kept both for interoperation and because an
 * inbound fragment is unauthenticated bytes from a stranger - every count it declares is a request,
 * never a fact, and the buffer below is exactly what a stranger is allowed to grow.
 */

/** Which stream a fragment belongs to: the sender's 8-byte wire id and the 8-byte id it stamped on
 * the stream. The sender half keeps two peers that happen to pick the same random id from
 * overwriting each other's reassembly. */
class PopopxMeshFragmentKey(val sender: Long, val id: Long) {
  /** The id half as 8 big-endian bytes, which is the order the wire writes a stream id in. */
  val idBytes: ByteArray get() = id.bigEndianBytes()

  override fun equals(other: Any?): Boolean =
    other is PopopxMeshFragmentKey && other.sender == sender && other.id == id

  override fun hashCode(): Int = 31 * sender.hashCode() + id.hashCode()

  override fun toString(): String =
    "FragmentKey(sender=${java.lang.Long.toUnsignedString(sender, 16)},id=${java.lang.Long.toUnsignedString(id, 16)})"
}

/** One parsed fragment header. Parsing is where every number a peer gets to choose is checked, so
 * nothing downstream has to remember which fields are hostile. */
class PopopxMeshFragmentHeader private constructor(
  val key: PopopxMeshFragmentKey,
  val index: Int,
  val total: Int,
  /** The `type` byte of the packet being reassembled, so the caller can dispatch the finished payload. */
  val originalType: Int,
  val data: ByteArray,
  val isBroadcast: Boolean,
) {
  companion object {
    /** `fragmentID(8) ++ index(u16 BE) ++ total(u16 BE) ++ originalType(1)`. */
    const val BYTE_COUNT: Int = 13
    const val ID_BYTE_COUNT: Int = 8

    /** Bitchat's ceiling on a declared fragment count. A stream longer than this is a lie about a
     * size we would never send, and answering it is how a receiver's memory dies. */
    const val MAX_TOTAL: Int = 10_000

    /**
     * null for anything that is not a well-formed fragment: a payload shorter than the header, a
     * sender field too short to key on, a total of zero or beyond [MAX_TOTAL], or an index the
     * declared total cannot hold.
     */
    fun of(packet: PopopxMeshPacket): PopopxMeshFragmentHeader? {
      val payload = packet.payload
      if (payload.size < BYTE_COUNT) return null
      // The key reads the sender field as exactly 8 bytes. A shorter one would still shift out a
      // plausible-looking number, and a wrong key merges two strangers' streams.
      if (packet.senderID.size != PopopxMeshPeerID.BYTE_COUNT) return null

      val rawIndex = ((payload[8].toInt() and 0xFF) shl 8) or (payload[9].toInt() and 0xFF)
      val rawTotal = ((payload[10].toInt() and 0xFF) shl 8) or (payload[11].toInt() and 0xFF)
      if (rawTotal <= 0 || rawTotal > MAX_TOTAL || rawIndex >= rawTotal) return null

      return PopopxMeshFragmentHeader(
        key = PopopxMeshFragmentKey(sender = packet.senderID.u64(), id = payload.u64At(0)),
        index = rawIndex,
        total = rawTotal,
        originalType = payload[12].toInt() and 0xFF,
        data = payload.copyOfRange(BYTE_COUNT, payload.size),
        isBroadcast = packet.isBroadcast,
      )
    }
  }
}

object PopopxMeshFragmenter {
  const val FRAGMENT_ID_BYTE_COUNT: Int = PopopxMeshFragmentHeader.ID_BYTE_COUNT

  private val random = SecureRandom()

  /**
   * A stream id nobody else can predict, because it is half of the key an inbound fragment is filed
   * under: a peer that could guess another peer's ids could pre-seed reassembly slots and race its
   * own streams against them, so this comes from the platform CSPRNG rather than a seedable source.
   */
  fun randomFragmentID(): ByteArray = ByteArray(FRAGMENT_ID_BYTE_COUNT).also { random.nextBytes(it) }

  /**
   * Splits `packet.payload` into runs of at most `maxPayloadBytes - 13` bytes and wraps each one as a
   * FRAGMENT packet, keeping the original senderID, recipientID, timestamp, ttl, signature and
   * version so a receiver still ties the run to the same sender and a relay still dedups it the same
   * way.
   *
   * A payload that already fits comes back as a one-element list holding a *wrapped* fragment rather
   * than the packet itself: one shape on the wire means one path through an inbound parser, and a
   * sender that had to branch on "did it fit" would branch wrongly under pressure.
   *
   * null when no valid split exists - a budget that cannot hold the header plus one byte, an empty
   * payload, a wrong-width id, or a packet that is already a fragment.
   */
  fun fragment(
    packet: PopopxMeshPacket,
    maxPayloadBytes: Int,
    fragmentID: ByteArray = randomFragmentID(),
  ): List<PopopxMeshPacket>? {
    if (fragmentID.size != FRAGMENT_ID_BYTE_COUNT) return null
    if (packet.type == PopopxMeshMessageType.FRAGMENT.wireValue) return null
    if (maxPayloadBytes <= PopopxMeshFragmentHeader.BYTE_COUNT) return null
    if (packet.payload.isEmpty()) return null

    val chunkSize = maxPayloadBytes - PopopxMeshFragmentHeader.BYTE_COUNT
    val count = (packet.payload.size + chunkSize - 1) / chunkSize
    if (count > PopopxMeshFragmentHeader.MAX_TOTAL) return null

    val fragments = ArrayList<PopopxMeshPacket>(count)
    var offset = 0
    for (index in 0 until count) {
      val end = minOf(offset + chunkSize, packet.payload.size)
      fragments.add(
        makeFragment(
          source = packet,
          fragmentID = fragmentID,
          index = index,
          total = count,
          chunk = packet.payload.copyOfRange(offset, end),
        )
      )
      offset = end
    }
    return fragments
  }

  private fun makeFragment(
    source: PopopxMeshPacket,
    fragmentID: ByteArray,
    index: Int,
    total: Int,
    chunk: ByteArray,
  ): PopopxMeshPacket {
    val payload = java.io.ByteArrayOutputStream(PopopxMeshFragmentHeader.BYTE_COUNT + chunk.size)
    payload.write(fragmentID)
    payload.write(index.bigEndianBytes(2))
    payload.write(total.bigEndianBytes(2))
    payload.write(source.type)
    payload.write(chunk)

    return PopopxMeshPacket(
      version = source.version,
      type = PopopxMeshMessageType.FRAGMENT.wireValue,
      ttl = source.ttl,
      timestamp = source.timestamp,
      senderID = source.senderID,
      recipientID = source.recipientID,
      payload = payload.toByteArray(),
      signature = source.signature,
    )
  }
}

/** Why a fragment was not taken. Each case is a different answer for the caller's log and retry. */
sealed class PopopxMeshFragmentRejection {
  /** The header does not parse, or two fragments under one key disagree about the stream. */
  object MalformedHeader : PopopxMeshFragmentRejection()

  /** `maxInFlight` streams are already open and none of them has aged out yet. */
  object TooManyInFlight : PopopxMeshFragmentRejection()

  /** Accepting this fragment would take the reassembly past `maxReassembledBytes`. */
  class Oversized(val projectedBytes: Int, val limit: Int) : PopopxMeshFragmentRejection()

  /** The stream this fragment belongs to is older than the lifetime and was dropped instead of
   * resumed; a later fragment under the same key starts a clean one. */
  object Expired : PopopxMeshFragmentRejection()
}

sealed class PopopxMeshAssemblerOutcome {
  /** Held; the stream is still missing fragments. Also the answer for a repeat of an index we
   * already hold, which is counted once. */
  class Stored(val key: PopopxMeshFragmentKey) : PopopxMeshAssemblerOutcome()

  /** Every index of the stream is in. The buffer is gone from the table. */
  class Complete(val key: PopopxMeshFragmentKey, val originalType: Int, val data: ByteArray) :
    PopopxMeshAssemblerOutcome()

  class Rejected(val reason: PopopxMeshFragmentRejection) : PopopxMeshAssemblerOutcome()
}

/**
 * Files inbound fragments under their key until the stream is whole, then hands back the original
 * payload. Everything it owns is bounded by three numbers fixed at construction and by nothing a
 * peer declares.
 *
 * iOS makes this an actor, which serialises every call. [append] and [prune] are `@Synchronized`
 * for the same reason: the BLE callback thread and the engine's coroutine would otherwise race on
 * the table. Unlike iOS there is no await, because nothing here suspends.
 */
class PopopxMeshFragmentAssembler(
  private val lifetime: Double = PopopxMeshConfig.default.fragmentLifetime,
  maxInFlight: Int = PopopxMeshConfig.default.maxInFlightAssemblies,
  /**
   * Ceiling on one reassembled payload, not on the table: `maxInFlight` already bounds the total.
   * Sized for a mesh frame, since nothing legitimate arrives as fragments otherwise. iOS keeps this
   * out of the config, so the engine's frame ceiling stays its own decision.
   */
  maxReassembledBytes: Int = 2048,
  private val log: (String) -> Unit = { },
) {
  private class Assembly(
    val total: Int,
    val originalType: Int,
    val startedAtMillis: Long,
    var heldBytes: Int,
    val chunks: HashMap<Int, ByteArray>,
  )

  private val assemblies = HashMap<PopopxMeshFragmentKey, Assembly>()
  private val lifetimeMillis = (lifetime * 1000).toLong()

  /** The three ceilings are fixed here and read-only afterwards, so a caller that merely wants to
   * know them does not have to take the lock. */
  val maxInFlight: Int = maxOf(1, maxInFlight)
  val maxReassembledBytes: Int = maxOf(1, maxReassembledBytes)

  val inFlightCount: Int get() = synchronized(assemblies) { assemblies.size }

  /**
   * null when `packet` is not a fragment at all: that is the caller's type dispatch, not a stream we
   * should be counting, logging or holding a slot for.
   *
   * `nowMillis` is injectable so the expiry path is testable without sleeping.
   */
  fun append(packet: PopopxMeshPacket, nowMillis: Long = System.currentTimeMillis()): PopopxMeshAssemblerOutcome? {
    if (packet.type != PopopxMeshMessageType.FRAGMENT.wireValue) return null
    val header = PopopxMeshFragmentHeader.of(packet)
    if (header == null) {
      log("mesh fragment dropped: header does not parse")
      return PopopxMeshAssemblerOutcome.Rejected(PopopxMeshFragmentRejection.MalformedHeader)
    }

    return synchronized(assemblies) {
      // One lookup for the whole function: the checks below either return or leave the stream as it
      // was, so what is read here is still what is held further down.
      val held = assemblies[header.key]
      if (held != null) {
        if (nowMillis - held.startedAtMillis > lifetimeMillis) {
          // Drop rather than resume. Past the lifetime we can no longer tell this fragment from a new
          // stream that reused the id, and resuming on a stranger's say-so is how a peer pins a
          // buffer forever by dripping one fragment per window.
          assemblies.remove(header.key)
          log("mesh fragment dropped: stream expired")
          return@synchronized PopopxMeshAssemblerOutcome.Rejected(PopopxMeshFragmentRejection.Expired)
        }
        if (held.total != header.total || held.originalType != header.originalType) {
          // Two fragments under one key describe different streams. Nothing identifies the honest one,
          // so the whole stream goes; a real sender re-floods inside a round trip.
          assemblies.remove(header.key)
          log("mesh fragment dropped: stream contradicts itself")
          return@synchronized PopopxMeshAssemblerOutcome.Rejected(PopopxMeshFragmentRejection.MalformedHeader)
        }
      }

      // The projection is what we would hold afterwards, from bytes actually received. A declared
      // total never enters it: pre-allocating on a peer's number is the bug this type exists to avoid.
      val heldBytes = held?.heldBytes ?: 0
      val replacedBytes = held?.chunks?.get(header.index)?.size ?: 0
      val projectedBytes = heldBytes - replacedBytes + header.data.size
      if (projectedBytes > maxReassembledBytes) {
        assemblies.remove(header.key)
        log("mesh fragment dropped: oversized $projectedBytes of $maxReassembledBytes bytes")
        return@synchronized PopopxMeshAssemblerOutcome.Rejected(
          PopopxMeshFragmentRejection.Oversized(projectedBytes = projectedBytes, limit = maxReassembledBytes)
        )
      }

      val assembly = held ?: run {
        // Refuse instead of evicting the oldest: forcing a slot fails two assemblies where dropping
        // this one fails one, and the peer spraying fragments is the one choosing which half-finished
        // stream of ours dies.
        if (assemblies.size >= maxInFlight) {
          log("mesh fragment dropped: at max in flight")
          return@synchronized PopopxMeshAssemblerOutcome.Rejected(PopopxMeshFragmentRejection.TooManyInFlight)
        }
        Assembly(
          total = header.total,
          originalType = header.originalType,
          startedAtMillis = nowMillis,
          heldBytes = 0,
          chunks = HashMap(),
        )
      }

      // A re-delivered index replaces what it held instead of adding to it: fragments bypass packet
      // dedup upstream and a sync can re-serve an index we already have, so a duplicate near the
      // ceiling must not tip a valid stream over it.
      val previous = assembly.chunks.put(header.index, header.data)
      if (previous != null) assembly.heldBytes += header.data.size - previous.size
      else assembly.heldBytes += header.data.size

      if (assembly.chunks.size != header.total) {
        assemblies[header.key] = assembly
        return@synchronized PopopxMeshAssemblerOutcome.Stored(header.key)
      }

      val reassembled = java.io.ByteArrayOutputStream(assembly.heldBytes)
      for (index in 0 until header.total) assembly.chunks[index]?.let { reassembled.write(it) }
      assemblies.remove(header.key)
      PopopxMeshAssemblerOutcome.Complete(
        key = header.key,
        originalType = header.originalType,
        data = reassembled.toByteArray(),
      )
    }
  }

  /** Drops every stream older than the lifetime. Returns how many went. */
  fun prune(nowMillis: Long = System.currentTimeMillis()): Int =
    synchronized(assemblies) {
      val expired = ArrayList<PopopxMeshFragmentKey>()
      for ((key, assembly) in assemblies) if (nowMillis - assembly.startedAtMillis > lifetimeMillis) expired.add(key)
      for (key in expired) assemblies.remove(key)
      expired.size
    }
}
