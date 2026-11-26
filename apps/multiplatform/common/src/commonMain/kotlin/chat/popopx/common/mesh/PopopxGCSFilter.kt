package chat.popopx.common.mesh

/**
 * A Golomb-coded set: the packed, one-way membership list the sync protocol uses to ask "which of
 * these do you already have?" without either side sending its list in the clear. It is a set
 * difference sketch, not a Bloom filter - GCS is what the deployed peers speak, and it costs about
 * log2(1/fpr) bits per element where a Bloom filter needs 1.44 times that.
 *
 * Port of apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Protocol/PopopxGCSFilter.swift.
 *
 * Encoding, byte for byte:
 *   serialized = version(1) ++ p(1) ++ M(4, big endian) ++ Golomb-Rice bitstream
 *   bitstream  = for each element, in ascending mapped order, the delta from the previous one
 *                (>= 1) written as q = (delta-1) >> p ones then a zero, followed by the p-bit
 *                remainder. MSB first inside each byte.
 *
 * Mapping an id: h64 = first 8 bytes of SHA256(id), big endian, cut to 63 bits, taken mod M, with 0
 * remapped to 1 so every delta is positive. Determinism is the contract - two peers must land an id
 * on the same bucket or the sketch answers a different question than it was asked.
 *
 * iOS keeps M in a UInt32 field, and this port keeps that width rather than the wider one the brief
 * implies: a six-byte header is what a peer parses. Because M never exceeds 2^32-1, every bucket and
 * every accumulator is a positive Long and the comparisons below are plain signed ones - that is the
 * only reason no unsigned compare is needed anywhere in this file.
 */
class PopopxGCSFilter private constructor(
  /** Golomb-Rice remainder width. */
  val p: Int,
  /** Hash-space size: every id maps into 1..M-1. The empty set is M == 1, which iOS measured as
   * `010c00000001`, not as M == 0. */
  val m: Long,
  /** The Golomb-Rice bitstream, without our header. */
  internal val bitstream: ByteArray,
  /** Decoded, ascending, unique. Cached because contains() runs per inbound id per peer. */
  private val values: LongArray,
  /** How many leading entries of build()'s `ids` the filter actually encodes. Trimming to fit the
   * byte budget only ever drops from the tail, so a caller that passes ids newest-first can treat
   * this as an exact cursor. */
  val includedCount: Int,
) {
  val elementCount: Int get() = values.size

  /** True when the id may be in the set. False is exact: a set element is never answered "no". */
  fun contains(id: ByteArray): Boolean {
    if (m <= 1 || values.isEmpty()) return false
    return containsCandidate(bucketFor(id))
  }

  /**
   * The bucket `id` occupies in 1..M-1. Public because a peer comparing two filters must map ids the
   * same way both sides did, and because it is the one function here worth pinning in a test.
   */
  fun bucketFor(id: ByteArray): Long {
    if (m <= 1) return 0L
    return mapHash(h64(id), m)
  }

  /** Header plus bitstream: what goes on the wire, and what [of] takes back. */
  val serialized: ByteArray
    get() {
      val out = java.io.ByteArrayOutputStream(HEADER_BYTES + bitstream.size)
      out.write(VERSION)
      out.write(p)
      out.write(m.bigEndianBytes().copyOfRange(4, 8))
      out.write(bitstream)
      return out.toByteArray()
    }

  private fun containsCandidate(candidate: Long): Boolean {
    var low = 0
    var high = values.size - 1
    while (low <= high) {
      val middle = (low + high) ushr 1
      val value = values[middle]
      if (value == candidate) return true
      if (value < candidate) low = middle + 1 else high = middle - 1
    }
    return false
  }

  /** Two filters are the same when they say the same thing on the wire. `values` is derived from
   * these three, so comparing it too would only make equality O(n) - and a peer's truncated stream
   * that happens to decode to the same set is not the same message we would have sent. */
  override fun equals(other: Any?): Boolean =
    other is PopopxGCSFilter && other.p == p && other.m == m && other.bitstream.contentEquals(bitstream)

  override fun hashCode(): Int {
    var result = p
    result = 31 * result + m.hashCode()
    result = 31 * result + bitstream.contentHashCode()
    return result
  }

  companion object {
    /** The only serialization this version reads. */
    const val VERSION: Int = 1

    /** version ++ p ++ M. */
    internal const val HEADER_BYTES: Int = 6

    /** p is the remainder width in bits, so fpr ~= 1/2^p. Above 32 the remainder is wider than any
     * filter that could plausibly fit a packet and the shifts below start losing bits. */
    const val MAX_P: Int = 32

    /** Ceiling on the bitstream, in both directions: [build] never offers more, and [of] refuses more
     * rather than decoding a peer's request for our memory. */
    const val MAX_ENCODED_BYTES: Int = 4096

    /** Ceiling on elements, so a bitstream crafted to keep yielding small deltas cannot make us
     * append forever. */
    const val MAX_ELEMENTS: Int = 10_000

    /** Longer than this and it is not an id this engine minted; hashing it would just be work. */
    const val MAX_ID_BYTES: Int = 128

    private const val MAX_M = 0xFFFF_FFFFL

    /**
     * null for anything this builder would not have produced: too short, too long, a version, a p or
     * an M out of range, or a bitstream that decodes to more elements than exist. Never a throw -
     * every byte below is chosen by the peer.
     */
    fun of(data: ByteArray): PopopxGCSFilter? {
      if (data.size < HEADER_BYTES || data.size > MAX_ENCODED_BYTES + HEADER_BYTES) return null
      if ((data[0].toInt() and 0xFF) != VERSION) return null
      val width = data[1].toInt() and 0xFF
      if (width < 1 || width > MAX_P) return null
      var modulus = 0L
      for (offset in 0 until 4) modulus = (modulus shl 8) or (data[2 + offset].toLong() and 0xFF)
      val bitstream = data.copyOfRange(HEADER_BYTES, data.size)
      // M == 1 is how an empty set is written and M == 0 is not a modulus at all; bits behind either
      // would be a set that cannot exist.
      if (modulus == 1L) {
        if (bitstream.isNotEmpty()) return null
      } else if (modulus < 1L) {
        return null
      }
      val values = decodeBitstream(width, modulus, bitstream) ?: return null
      return PopopxGCSFilter(width, modulus, bitstream, values, values.size)
    }

    /**
     * Encodes `ids` as small as `maxBytes` and no smaller. Returns null when `maxBytes` cannot even
     * hold the header.
     *
     * Both inputs are treated as unbounded: `ids` is cut to [MAX_ELEMENTS] from the front (so a
     * caller passing newest-first keeps the ones it cares about) and ids longer than [MAX_ID_BYTES]
     * are skipped, so neither a huge list nor a huge element turns into a huge hash loop. Elements
     * that do not fit the byte budget are trimmed from the tail, a tenth at a time, until the
     * encoding stops overflowing it.
     */
    fun build(
      ids: List<ByteArray>,
      maxBytes: Int,
      targetFalsePositiveRate: Double,
    ): PopopxGCSFilter? {
      if (maxBytes < HEADER_BYTES) return null
      val budget = minOf(maxBytes - HEADER_BYTES, MAX_ENCODED_BYTES)
      val width = deriveP(targetFalsePositiveRate)

      val candidates = ids.take(MAX_ELEMENTS).filter { it.isNotEmpty() && it.size <= MAX_ID_BYTES }
      val estimated = estimateMaxElements(budget, width)
      val initialCount = minOf(candidates.size, estimated)
      if (initialCount <= 0) return empty(width)

      // M is pinned to the first candidate count and stays put while the tail is trimmed, so a
      // trimmed filter still means the same thing per element as an untrimmed one.
      val modulo = hashRange(initialCount, width)

      var count = initialCount
      var attempt = encodeFirst(candidates, count, modulo, width)
      while (attempt.second.size > budget && count > 1) {
        count = maxOf(1, count * 9 / 10)
        attempt = encodeFirst(candidates, count, modulo, width)
      }
      // One element that still does not fit is not a filter, it is a caller who set maxBytes below what
      // their own p costs. Say so by returning the empty set rather than a lie.
      if (attempt.second.size > budget) return empty(width)

      return PopopxGCSFilter(
        p = width,
        m = modulo,
        bitstream = attempt.second,
        values = attempt.first,
        includedCount = count,
      )
    }

    private fun encodeFirst(
      candidates: List<ByteArray>,
      count: Int,
      modulo: Long,
      width: Int,
    ): Pair<LongArray, ByteArray> {
      val mapped = ArrayList<Long>(count)
      for (index in 0 until count) mapped.add(mapHash(h64(candidates[index]), modulo))
      mapped.sort()
      // Kept strictly increasing, which is what lets the deltas stay positive: equal buckets are the
      // same element, and a bucket at M is one past the end of the space.
      val normalised = normalize(mapped, modulo)
      val encoded = if (normalised.isEmpty()) ByteArray(0) else encodeBits(normalised, width)
      return Pair(normalised, encoded)
    }

    /** The set with nothing in it: everything answers "no", which makes a peer send it again. */
    private fun empty(width: Int): PopopxGCSFilter =
      PopopxGCSFilter(width, 1L, ByteArray(0), LongArray(0), 0)

    /**
     * fpr ~= 1/2^p, so p = ceil(log2(1/fpr)). Clamped at both ends: below 0.25 buys nothing an honest
     * caller wants, and asking for better than 1e-6 costs a tenth of a bit per element and cannot be
     * met by a set this small anyway. A request of 0 therefore means "as precise as this format goes",
     * which is what a caller who writes 0 means. 1/4096 lands exactly on p = 12, which is the value
     * this app asks the local dedup pre-filter for.
     */
    fun deriveP(targetFalsePositiveRate: Double): Int {
      // NaN or infinity is not a rate at all: take the coarsest one a filter can be built at rather
      // than pretending to buy precision the bitstream cannot hold.
      if (!targetFalsePositiveRate.isFinite()) return 2
      val rate = minOf(0.25, maxOf(0.000_001, targetFalsePositiveRate))
      return minOf(MAX_P, maxOf(1, kotlin.math.ceil(kotlin.math.ln(1.0 / rate) / LN2).toInt()))
    }

    /** A Golomb-Rice element costs about p + 2 bits: p for the remainder, and a unary quotient
     * averaging one or two bits at the densities this filter is built at. */
    internal fun estimateMaxElements(sizeBytes: Int, width: Int): Int {
      val bits = maxOf(8, sizeBytes * 8)
      val per = maxOf(3, width + 2)
      return maxOf(1, bits / per)
    }

    /** M = n * 2^p, saturating at UInt32. The classic Golomb-Coded-Set modulus: it puts about one
     * collision per 2^p elements, which is where the ~1/2^p false-positive rate comes from. */
    private fun hashRange(count: Int, width: Int): Long {
      if (count <= 0) return 1L
      // At p >= 32 any n >= 1 already exceeds the field, so the saturation is the whole answer.
      if (width >= 32) return MAX_M
      val product = count.toLong() * (1L shl width)
      if (product <= 0L) return MAX_M
      return if (product > MAX_M) MAX_M else product
    }
  }
}

private const val LN2 = 0.693_147_180_559_945_3

/**
 * First 8 bytes of SHA256, big endian, top bit cleared so every subsequent shift and addition stays
 * inside 63 bits and cannot wrap into a negative-looking value.
 */
private fun h64(id: ByteArray): Long {
  val digest = sha256(id)
  var value = 0L
  for (index in 0 until 8) value = (value shl 8) or (digest[index].toLong() and 0xFF)
  return value and 0x7FFF_FFFF_FFFF_FFFFL
}

private fun mapHash(hash: Long, modulo: Long): Long {
  if (modulo <= 1L) return 0L
  val value = hash % modulo
  return if (value == 0L) 1L else value
}

/** Keeps the sequence strictly increasing, which is what lets the deltas stay positive. */
private fun normalize(values: List<Long>, modulo: Long): LongArray {
  if (modulo <= 1L || values.isEmpty()) return LongArray(0)
  val out = ArrayList<Long>(values.size)
  var last = 0L
  val cap = modulo - 1
  for (value in values) {
    val capped = minOf(value, cap)
    if (capped > last) {
      out.add(capped)
      last = capped
    }
  }
  return out.toLongArray()
}

private fun encodeBits(values: LongArray, width: Int): ByteArray {
  val writer = MeshBitWriter()
  var previous = 0L
  val mask = (1L shl width) - 1
  for (value in values) {
    val delta = value - previous
    previous = value
    val quotient = (delta - 1) ushr width
    val remainder = (delta - 1) and mask
    writer.writeOnes(quotient.toInt())
    writer.writeBit(0)
    writer.writeBits(remainder, width)
  }
  return writer.toByteArray()
}

/**
 * null when the stream decodes to more elements than MAX_ELEMENTS: a crafted sequence of small deltas
 * is a request for memory, not a set. iOS breaks the loop the same way it does here when an
 * accumulator reaches M, because a bucket at or past the modulus is not in the space.
 */
private fun decodeBitstream(width: Int, modulus: Long, bitstream: ByteArray): LongArray? {
  if (modulus <= 1L) return LongArray(0)
  val reader = MeshBitReader(bitstream)
  val values = ArrayList<Long>()
  var accumulator = 0L
  while (true) {
    val quotient = reader.readUnary() ?: break
    val remainder = reader.readBits(width) ?: break
    accumulator += (quotient.toLong() shl width) + remainder + 1L
    if (accumulator >= modulus) break
    values.add(accumulator)
    if (values.size > PopopxGCSFilter.MAX_ELEMENTS) return null
  }
  return values.toLongArray()
}

/** MSB-first, as the format is specified. */
private class MeshBitWriter {
  private val bytes = ArrayList<Int>()
  private var current = 0
  private var filled = 0

  fun writeBit(bit: Int) {
    current = (current shl 1) or (bit and 1)
    filled += 1
    if (filled == 8) {
      bytes.add(current and 0xFF)
      current = 0
      filled = 0
    }
  }

  fun writeOnes(count: Int) {
    repeat(maxOf(0, count)) { writeBit(1) }
  }

  fun writeBits(value: Long, count: Int) {
    if (count <= 0) return
    var shift = count - 1
    while (shift >= 0) {
      writeBit(((value ushr shift) and 1L).toInt())
      shift -= 1
    }
  }

  fun toByteArray(): ByteArray {
    val out = java.io.ByteArrayOutputStream(bytes.size + 1)
    for (byte in bytes) out.write(byte)
    // The final partial byte is left-justified, which is what the reader's MSB-first walk expects.
    if (filled > 0) out.write((current shl (8 - filled)) and 0xFF)
    return out.toByteArray()
  }
}

private class MeshBitReader(private val bytes: ByteArray) {
  private var index = 0
  private var current = 0
  private var left = 0

  init {
    if (bytes.isNotEmpty()) {
      current = bytes[0].toInt() and 0xFF
      left = 8
    }
  }

  fun readBit(): Int? {
    if (index >= bytes.size) return null
    val bit = (current ushr 7) and 1
    current = (current shl 1) and 0xFF
    left -= 1
    if (left == 0) {
      index += 1
      if (index < bytes.size) {
        current = bytes[index].toInt() and 0xFF
        left = 8
      }
    }
    return bit
  }

  /** Unary quotient: the number of ones before the terminating zero, or null at end of stream. */
  fun readUnary(): Int? {
    var count = 0
    while (true) {
      val bit = readBit() ?: return null
      if (bit == 1) count += 1 else return count
    }
  }

  fun readBits(count: Int): Long? {
    var value = 0L
    repeat(count) {
      val bit = readBit() ?: return null
      value = (value shl 1) or bit.toLong()
    }
    return value
  }
}
