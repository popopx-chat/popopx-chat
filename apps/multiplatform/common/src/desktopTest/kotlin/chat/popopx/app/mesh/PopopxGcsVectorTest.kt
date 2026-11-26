package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxGCSFilter
import chat.popopx.common.mesh.meshHex
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The Golomb-coded set, at the width the local dedup pre-filter asks for.
 *
 * Port of `Protocol/PopopxGCSFilter.swift`. Ruling 3 chose `targetFalsePositiveRate = 1/4096` because
 * it lands exactly on `p = 12`, and the `gcs.deriveP(...)` rows are the measurement behind that choice:
 * the rate is taken out of each label rather than retyped, so the table cannot drift from the tool.
 *
 * Nothing here is a sync protocol. iOS has no packet type that carries a GCS, so this filter is a
 * local pre-screen and is tested as one (deviation 5 in the commit body).
 */
internal class PopopxGcsVectorTest {
  @Test
  fun derivedWidthsMatchIOS() {
    val rows = V.rows("gcs").filter { it.first.startsWith("gcs.deriveP(") }
    assertEquals(6, rows.size, "the driver probed six rates")
    for ((label, value) in rows) {
      val rate = label.substringAfter("(").substringBeforeLast(")").toDouble()
      assertEquals(value.toInt(), PopopxGCSFilter.deriveP(rate), label)
    }
    // The rate this app asks for, and the p that came out of iOS' own filter.
    assertEquals(V.int("gcs", "gcs.p"), PopopxGCSFilter.deriveP(1.0 / 4096.0))
    assertEquals(2, PopopxGCSFilter.deriveP(Double.POSITIVE_INFINITY), "PopopxGCSFilter.swift:192")
  }

  @Test
  fun serializedFilterMatchesIOSByteForByte() {
    val filter = assertNotNull(PopopxGCSFilter.build(IDS, MAX_BYTES, 1.0 / 4096.0), "build")
    assertEquals(V.int("gcs", "gcs.p"), filter.p)
    assertEquals(V.long("gcs", "gcs.m"), filter.m)
    assertEquals(V.int("gcs", "gcs.included"), filter.includedCount)
    assertEquals(64, IDS.size, "every id the driver hashed")
    assertEquals(V.int("gcs", "gcs.included"), IDS.size, "the budget held all of them")

    val serialized = filter.serialized
    assertEquals(V.row("gcs", "gcs.serialized"), serialized.meshHex())
    assertEquals(V.int("gcs", "gcs.serializedLen"), serialized.size)
    assertEquals(HEADER, serialized.copyOfRange(0, HEADER).size, "the header a peer parses")
    assertEquals(1, serialized[0].toInt())
    assertEquals(filter.p, serialized[1].toInt())
    assertEquals(filter.m, serialized.copyOfRange(2, 6).u64Of(), "M is a UInt32 field")

    assertTrue(V.flag("gcs", "gcs.containsKnown"), "an element is never answered 'no'")
    assertEquals(0, IDS.count { !filter.contains(it) }, "all 64 included ids answer present")
    assertEquals(V.long("gcs", "gcs.bucketFirst"), filter.bucketFor(IDS.first()))
    assertEquals(V.long("gcs", "gcs.bucketLast"), filter.bucketFor(IDS.last()))
    for (id in IDS) {
      val bucket = filter.bucketFor(id)
      assertTrue(bucket in 1 until filter.m, "$id mapped outside 1..M-1: $bucket")
    }

    val roundTrip = assertNotNull(PopopxGCSFilter.of(serialized), "decoding our own filter")
    assertEquals(V.flag("gcs", "gcs.roundTrip"), roundTrip == filter)
    assertEquals(V.row("gcs", "gcs.roundTripSerialized"), roundTrip.serialized.meshHex())
    assertEquals(filter.elementCount, roundTrip.elementCount, "the bitstream decodes to the set it encoded")

    // The measured false-positive rate: 20,000 probes that are not in the set, exactly as the tool ran
    // them, so the row is a count rather than a claim.
    var falsePositives = 0
    for (index in 0 until PROBES) {
      val probe = "probe-$index".encodeToByteArray()
      if (IDS.none { it.contentEquals(probe) } && filter.contains(probe)) falsePositives += 1
    }
    assertEquals(V.row("gcs", "gcs.falsePositiveRate").toDouble() * PROBES, falsePositives.toDouble(), 0.5)
    assertTrue(falsePositives in 1..40, "p = 12 should screen at about one in 4096, got $falsePositives of $PROBES")
  }

  @Test
  fun emptyFilterAndDecodeGuards() {
    val empty = assertNotNull(PopopxGCSFilter.build(emptyList(), MAX_BYTES, 1.0 / 4096.0), "the empty set is a filter")
    assertEquals(V.row("gcs", "gcs.empty.serialized"), empty.serialized.meshHex())
    assertEquals(1L, empty.m, "M == 1 is how an empty set is written")
    assertEquals(V.flag("gcs", "gcs.empty.containsAny"), empty.contains("anything".encodeToByteArray()))
    assertEquals(V.int("gcs", "gcs.empty.decoded"), assertNotNull(PopopxGCSFilter.of(empty.serialized)).includedCount)

    // Every byte of a peer's filter is chosen by the peer. PopopxGCSFilter.swift:77,81,83,89.
    assertNull(PopopxGCSFilter.of(ByteArray(5)), "shorter than the header")
    assertNull(PopopxGCSFilter.of(byteArrayOf(2, 12, 0, 4, 0, 0)), "a version this builder never wrote")
    assertNull(PopopxGCSFilter.of(byteArrayOf(1, 0, 0, 4, 0, 0)), "p = 0 has no remainder width")
    assertNull(PopopxGCSFilter.of(byteArrayOf(1, 33, 0, 4, 0, 0)), "p beyond MAX_P")
    assertNull(PopopxGCSFilter.of(byteArrayOf(1, 12, 0, 0, 0, 0)), "M = 0 is not a modulus")
    assertNull(PopopxGCSFilter.of(byteArrayOf(1, 12, 0, 0, 0, 1, 0)), "bits behind an empty set")
    assertNull(PopopxGCSFilter.of(ByteArray(HEADER + PopopxGCSFilter.MAX_ENCODED_BYTES + 1)), "beyond the byte ceiling")
    assertNull(PopopxGCSFilter.build(IDS, HEADER - 1, 1.0 / 4096.0), "a budget that cannot hold the header")
    assertEquals(32, PopopxGCSFilter.MAX_P)
    assertEquals(4096, PopopxGCSFilter.MAX_ENCODED_BYTES)
    assertEquals(128, PopopxGCSFilter.MAX_ID_BYTES)
  }

  /**
   * The two inputs are treated as unbounded, so both are cut before any hashing: the list from the
   * front, because a caller that passes newest-first keeps the ids it cares about, and an oversized id
   * by skipping it. Neither rule is visible in the freeze - iOS measures the same trimming here, so
   * these are the port's own bounds, stated as numbers.
   */
  @Test
  fun unboundedInputsAreCutNotHashed() {
    val oversized = listOf("id-0".encodeToByteArray(), ByteArray(PopopxGCSFilter.MAX_ID_BYTES + 1))
    val filter = assertNotNull(PopopxGCSFilter.build(oversized, MAX_BYTES, 1.0 / 4096.0), "build")
    assertEquals(1, filter.includedCount, "the oversized id was skipped, not hashed")
    assertTrue(filter.contains("id-0".encodeToByteArray()))
    assertEquals(10_000, PopopxGCSFilter.MAX_ELEMENTS)
    val emptyIds = assertNotNull(PopopxGCSFilter.build(listOf(ByteArray(0)), MAX_BYTES, 1.0 / 4096.0), "build")
    assertEquals(0, emptyIds.includedCount, "a zero-length id is not an element")
    assertEquals(1L, emptyIds.m, "so what comes back is the empty set")
  }

  private fun ByteArray.u64Of(): Long {
    var value = 0L
    for (byte in this) value = (value shl 8) or (byte.toLong() and 0xFF)
    return value
  }

  private companion object {
    val V = PopopxMeshSwiftVectors
    const val MAX_BYTES: Int = 4096
    const val PROBES: Int = 20_000

    /** version(1) ++ p(1) ++ M(4): the six bytes of `PopopxGCSFilter.swift:77`, kept literal here so
     * nothing in this file depends on the port's own visibility. */
    const val HEADER: Int = 6
    val IDS: List<ByteArray> = (0 until 64).map { "id-$it".encodeToByteArray() }
  }
}
