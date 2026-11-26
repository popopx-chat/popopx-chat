package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxMeshAssemblerOutcome
import chat.popopx.common.mesh.PopopxMeshFragmentAssembler
import chat.popopx.common.mesh.PopopxMeshFragmentHeader
import chat.popopx.common.mesh.PopopxMeshFragmentKey
import chat.popopx.common.mesh.PopopxMeshFragmentRejection
import chat.popopx.common.mesh.PopopxMeshFragmenter
import chat.popopx.common.mesh.PopopxMeshMessageType
import chat.popopx.common.mesh.PopopxMeshPacket
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.mesh.meshHexToBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The 13-byte fragment header and the splitter that writes it, against the iOS fragment rows.
 *
 * Port of `Protocol/PopopxMeshFragments.swift`. The driver table is the only transcription in this
 * file - it mirrors `main.swift:207-213`, seven calls in the tool's own order - and everything
 * compared against it is read out of the rows: the encoded length, the first 35 bytes, and the header's
 * own fields as iOS printed them.
 */
internal class PopopxMeshFragmentVectorTest {
  @Test
  fun fragmentedStreamsMatchIOSByteForByte() {
    val rows = V.rows("fragment")
    var cursor = 0
    var streams = 0
    for ((payloadLength, budget, fragmentID) in DRIVERS) {
      assertTrue(cursor < rows.size, "the freeze holds fewer fragment groups than the driver ran")
      val (label, value) = rows[cursor]
      cursor++
      when (stem(label)) {
        "fragment.nil" -> {
          assertEquals("payload=$payloadLength budget=$budget", value, label)
          assertNull(PopopxMeshFragmenter.fragment(source(payloadLength), budget, fragmentID), "$label: $value")
        }
        "fragment.count" -> {
          val fragments =
            assertNotNull(PopopxMeshFragmenter.fragment(source(payloadLength), budget, fragmentID), "$label: $value")
          assertEquals(value.toInt(), fragments.size, "count for payload=$payloadLength budget=$budget")
          var held = 0
          for ((index, fragment) in fragments.withIndex()) {
            val encoded = assertNotNull(fragment.encoded(padded = false), "fragment $index encode")
            val (lenLabel, len) = next(rows, cursor, "fragment.$index.len")
            cursor++
            assertEquals(len.toInt(), encoded.size, lenLabel)
            val (headLabel, head) = next(rows, cursor, "fragment.$index.head13")
            cursor++
            assertEquals(HEAD_BYTES * 2, head.length, headLabel)
            assertEquals(head, encoded.copyOfRange(0, HEAD_BYTES).meshHex(), headLabel)
            val (parsedLabel, parsed) = next(rows, cursor, "fragment.$index.parsed")
            cursor++
            val header = assertNotNull(PopopxMeshFragmentHeader.of(fragment), parsedLabel)
            assertEquals(parsed, parsedRow(header), parsedLabel)
            // The same row, read as numbers instead of as one string.
            assertEquals(index, header.index, parsedLabel)
            assertEquals(fragments.size, header.total, parsedLabel)
            assertEquals(PopopxMeshMessageType.MESSAGE.wireValue, header.originalType, parsedLabel)
            assertEquals(fragmentID.meshHex(), head.substring(44, 44 + fragmentID.size * 2), "$headLabel: where the stream id sits")
            held += header.data.size
          }
          assertEquals(payloadLength, held, "$label: the split holds every byte of the payload once")
          streams++
        }
        else -> assertEquals("fragment.count", stem(label), label)
      }
    }
    assertEquals(rows.size, cursor, "every fragment row was consumed by the driver's seven calls")
    assertEquals(4, streams, "four streams split, three calls refused")
  }

  /**
   * The receiver's three ceilings, all of which belong to the receiver and to nothing a peer declares:
   * the lifetime drops rather than resumes (`PopopxMeshFragments.swift:270`), `maxInFlight` refuses
   * rather than evicts (`:308`), and the byte limit is measured on bytes actually held (`:292`) - which
   * is why a re-delivered index may not tip a valid stream over it (`:324`).
   */
  @Test
  fun assemblerCeilingsFollowIOS() {
    val lifetimeMillis = (V.row("config", "config.fragmentLifetime").toDouble() * 1000).toLong()
    val defaults = PopopxMeshFragmentAssembler()
    assertEquals(V.row("config", "config.maxInFlightAssemblies").toInt(), defaults.maxInFlight)
    assertEquals(30_000L, lifetimeMillis, "the lifetime the defaults come from")
    assertEquals(2048, defaults.maxReassembledBytes, "the one ceiling iOS keeps out of its config")
    assertEquals(0, defaults.inFlightCount)

    val three = assertNotNull(PopopxMeshFragmenter.fragment(source(1000), FRAGMENT_SIZE, FID), "split 1000")
    val two = assertNotNull(PopopxMeshFragmenter.fragment(source(457), FRAGMENT_SIZE, FID), "split 457")
    assertEquals(3, three.size)
    assertEquals(2, two.size)
    val otherKey = assertNotNull(PopopxMeshFragmenter.fragment(source(10), FRAGMENT_SIZE, FID2), "split 10")
    val streamKey = assertNotNull(PopopxMeshFragmentHeader.of(three[2]), "three's own key").key

    // Out of order, one index re-delivered, then whole.
    val assembler = PopopxMeshFragmentAssembler()
    assertNull(assembler.append(message(), 0), "a packet that is not a fragment is not the assembler's business")
    assertEquals(streamKey, stored(assembler.append(three[2], 0)), "filed under the header's key")
    stored(assembler.append(three[0], 0))
    stored(assembler.append(three[0], 1), "a repeat of a held index stays held")
    assertEquals(1, assembler.inFlightCount, "and is not a second stream")
    val complete = assembler.append(three[1], 2) as PopopxMeshAssemblerOutcome.Complete
    assertEquals(PopopxMeshMessageType.MESSAGE.wireValue, complete.originalType)
    assertTrue(source(1000).payload.contentEquals(complete.data), "reassembled in index order, not in arrival order")
    assertEquals(0, assembler.inFlightCount, "a finished stream leaves the table")

    // Two fragments under one key that describe different streams: the stream goes, not the stranger.
    val contradicting = PopopxMeshFragmentAssembler()
    stored(contradicting.append(three[0], 0))
    assertEquals(PopopxMeshFragmentRejection.MalformedHeader, rejected(contradicting.append(two[0], 1)))
    assertEquals(0, contradicting.inFlightCount, "iOS drops the whole stream at :281")

    // The byte ceiling, and the duplicate that must not reach it.
    val tight = PopopxMeshFragmentAssembler(lifetime = 30.0, maxInFlight = 2, maxReassembledBytes = 500)
    stored(tight.append(three[0], 0))
    stored(tight.append(three[0], 1), "456 held, then 456 replaced - not 912")
    val oversized = rejected(tight.append(three[1], 2)) as PopopxMeshFragmentRejection.Oversized
    assertEquals(456 + 456, oversized.projectedBytes)
    assertEquals(500, oversized.limit)
    assertEquals(0, tight.inFlightCount, "an oversized stream is dropped as well as refused")

    // The lifetime: drop, do not resume, and let the same key start clean.
    val ageing = PopopxMeshFragmentAssembler(lifetime = 30.0, maxInFlight = 2, maxReassembledBytes = 2048)
    stored(ageing.append(three[0], 0))
    assertEquals(PopopxMeshFragmentRejection.Expired, rejected(ageing.append(three[1], lifetimeMillis + 1)))
    assertEquals(0, ageing.inFlightCount)
    stored(ageing.append(three[1], lifetimeMillis + 2), "the same key opens a clean stream")
    assertEquals(1, ageing.prune(lifetimeMillis * 3))
    assertEquals(0, ageing.inFlightCount)
    assertEquals(0, ageing.prune(lifetimeMillis * 3), "and prune reports nothing twice")

    // At the in-flight ceiling a new stream is refused and no held stream dies for it.
    val full = PopopxMeshFragmentAssembler(lifetime = 30.0, maxInFlight = 1, maxReassembledBytes = 2048)
    stored(full.append(three[0], 0))
    assertEquals(PopopxMeshFragmentRejection.TooManyInFlight, rejected(full.append(otherKey[0], 1)))
    assertEquals(1, full.inFlightCount, "the refusal costs the stranger, not the stream already held")

    // A header that does not parse is a rejection, not a null: the packet claimed to be a fragment.
    val malformed = PopopxMeshFragmentAssembler()
    assertEquals(PopopxMeshFragmentRejection.MalformedHeader, rejected(malformed.append(shortFragment(), 0)))
    assertEquals(0, malformed.inFlightCount)
  }

  /**
   * Every header iOS refuses. The widths and counts here are the ones a stranger can choose, so this
   * is the list that bounds a receiver's memory rather than a description of honest traffic.
   */
  @Test
  fun hostileFragmentHeadersRefuse() {
    assertNotNull(PopopxMeshFragmentHeader.of(fragmentOf(FID, 0, 1)), "control: one well-formed fragment parses")
    assertNull(PopopxMeshFragmentHeader.of(shortFragment()), "a payload shorter than the header")
    assertNotNull(PopopxMeshFragmentHeader.of(fragmentOf(FID, 0, 1, ByteArray(0))), "a header with no data behind it still parses")
    assertNull(PopopxMeshFragmentHeader.of(fragmentOf(FID, 0, 0)), "a stream of zero fragments")
    assertNull(PopopxMeshFragmentHeader.of(fragmentOf(FID, 0, 10_001)), "a total beyond MAX_TOTAL")
    assertNull(PopopxMeshFragmentHeader.of(fragmentOf(FID, 3, 3)), "an index the declared total cannot hold")
    assertNull(
      PopopxMeshFragmentHeader.of(fragmentOf(FID, 0, 1, senderID = ByteArray(7) { (it + 1).toByte() })),
      "a sender field too short to key on",
    )
    assertEquals(10_000, PopopxMeshFragmentHeader.MAX_TOTAL)
    assertEquals(13, PopopxMeshFragmentHeader.BYTE_COUNT)

    // The splitter's refusals are the same numbers from the sender's side.
    assertNull(PopopxMeshFragmenter.fragment(source(100), 13, FID), "a budget that cannot hold the header plus a byte")
    assertNull(PopopxMeshFragmenter.fragment(source(0), FRAGMENT_SIZE, FID), "an empty payload")
    assertNull(PopopxMeshFragmenter.fragment(source(100), FRAGMENT_SIZE, ByteArray(7)), "a stream id of the wrong width")
    assertNull(PopopxMeshFragmenter.fragment(fragmentOf(FID, 0, 1), FRAGMENT_SIZE, FID), "a packet that is already a fragment")
    assertNull(PopopxMeshFragmenter.fragment(source(10_001), 14, FID), "a split that would declare more fragments than MAX_TOTAL")
    assertEquals(1, PopopxMeshFragmenter.fragment(source(1), FRAGMENT_SIZE, FID)?.size, "a one-byte payload still goes as a wrapped fragment")
  }

  private fun parsedRow(header: PopopxMeshFragmentHeader): String =
    "key=" +
      java.lang.Long.toUnsignedString(header.key.sender) +
      "/" +
      java.lang.Long.toUnsignedString(header.key.id) +
      " index=${header.index} total=${header.total} type=${header.originalType} dataLen=${header.data.size}"

  private fun next(rows: List<Pair<String, String>>, at: Int, expected: String): Pair<String, String> {
    val row = rows[at]
    assertEquals(expected, stem(row.first), "${row.first} is out of place")
    return row
  }

  private fun stored(outcome: PopopxMeshAssemblerOutcome?, why: String = "held"): PopopxMeshFragmentKey =
    (assertNotNull(outcome, why) as PopopxMeshAssemblerOutcome.Stored).key

  private fun rejected(outcome: PopopxMeshAssemblerOutcome?): PopopxMeshFragmentRejection =
    (
      assertNotNull(outcome, "expected a rejection, not the null that means 'not a fragment'")
        as PopopxMeshAssemblerOutcome.Rejected
      )
      .reason

  private fun message(): PopopxMeshPacket = source(10)

  /** The packet every driver case was built from: MESSAGE, ttl 7, the fixed timestamp, no recipient. */
  private fun source(payloadLength: Int): PopopxMeshPacket =
    PopopxMeshPacket(
      version = 1,
      type = PopopxMeshMessageType.MESSAGE.wireValue,
      ttl = 7,
      timestamp = FIXED_TIMESTAMP,
      senderID = SENDER,
      recipientID = null,
      payload = ByteArray(payloadLength) { (it % 251).toByte() },
    )

  /** A FRAGMENT packet with a chosen header, for the cases no honest sender produces. */
  /** A FRAGMENT packet whose payload stops short of the 13-byte header it claims to carry. */
  private fun shortFragment(): PopopxMeshPacket =
    PopopxMeshPacket(
      version = 1,
      type = PopopxMeshMessageType.FRAGMENT.wireValue,
      ttl = 7,
      timestamp = FIXED_TIMESTAMP,
      senderID = SENDER,
      recipientID = null,
      payload = ByteArray(12),
    )

  private fun fragmentOf(
    fragmentID: ByteArray,
    index: Int,
    total: Int,
    data: ByteArray = ByteArray(4),
    senderID: ByteArray = SENDER,
  ): PopopxMeshPacket =
    PopopxMeshPacket(
      version = 1,
      type = PopopxMeshMessageType.FRAGMENT.wireValue,
      ttl = 7,
      timestamp = FIXED_TIMESTAMP,
      senderID = senderID,
      recipientID = null,
      payload = fragmentID + u16(index) + u16(total) + byteArrayOf(PopopxMeshMessageType.MESSAGE.wireValue.toByte()) + data,
    )

  private fun u16(value: Int): ByteArray = byteArrayOf((value shr 8).toByte(), value.toByte())

  private fun stem(label: String): String = label.substringBefore('#')

  private companion object {
    val V = PopopxMeshSwiftVectors
    const val FIXED_TIMESTAMP: Long = 1_795_614_944_000L
    const val HEAD_BYTES: Int = 22 + 13
    val SENDER: ByteArray = ByteArray(8) { (it + 1).toByte() }
    val FID: ByteArray = hex("0102030405060708")
    val FID2: ByteArray = hex("0a0b0c0d0e0f1011")
    val FRAGMENT_SIZE: Int = V.row("config", "config.fragmentSize").toInt()

    /** The driver's seven calls, in the order the tool ran them (`main.swift:207-213`). */
    val DRIVERS: List<Triple<Int, Int, ByteArray>> =
      listOf(
        Triple(1000, 469, FID),
        Triple(100, 469, FID2),
        Triple(456, 469, FID2),
        Triple(457, 469, FID2),
        Triple(0, 469, FID2),
        Triple(100, 13, FID2),
        Triple(100, 469, hex("0a0b0c0d0e0f10")),
      )

    fun hex(value: String): ByteArray = assertNotNull(value.meshHexToBytes(), "$value is not hex")
  }
}
