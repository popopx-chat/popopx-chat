package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxMeshMessageType
import chat.popopx.common.mesh.PopopxMeshPacket
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.mesh.meshHexToBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * The packet codec: the 14-byte header, the padding buckets, the id that dedup keys on, and the
 * inbound parser's strictness list - row for row against the bytes iOS produced.
 */
internal class PopopxMeshPacketVectorTest {
  private val senderID = bytes(0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF)
  private val recipientID = bytes(0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10)
  private val broadcastID = ByteArray(8) { 0xFF.toByte() }
  private val timestamp = 1_795_614_944_000L
  private val smallPayload = "popopx mesh payload".toByteArray(Charsets.UTF_8)

  private val unsigned = packet(PopopxMeshMessageType.MESSAGE, 7, null, smallPayload)

  @Test
  fun encodedPacketsMatchIOSByteForByte() {
    val cases = listOf(
      "unsigned" to packet(PopopxMeshMessageType.MESSAGE, 7, null, smallPayload),
      "directed" to packet(PopopxMeshMessageType.MESSAGE, 5, recipientID, smallPayload),
      "broadcastOnes" to packet(PopopxMeshMessageType.MESSAGE, 5, broadcastID, smallPayload),
      "signed" to packet(
        PopopxMeshMessageType.NOISE_ENCRYPTED, 7, recipientID, smallPayload,
        signature = ByteArray(64) { it.toByte() },
      ),
      "announce" to packet(PopopxMeshMessageType.ANNOUNCE, 7, null, "{\"nickname\":\"ada\",\"pubkey\":\"".toByteArray(Charsets.UTF_8)),
      "emptyPayload" to packet(PopopxMeshMessageType.PING, 1, null, ByteArray(0), timestamp = 0L),
      "zeroTimestamp" to packet(PopopxMeshMessageType.PONG, 255, null, bytes(0x00), sender = ByteArray(8), timestamp = 0L),
      // A type iOS has no case for: the packet still encodes, and still decodes, with decodedType nil.
      "unknownType" to packet(typeValue = 0x77, ttl = 3, recipient = null, payload = smallPayload),
    )
    for ((name, packet) in cases) {
      val raw = assertNotNull(packet.encoded(padded = false), "$name encodes unpadded")
      val padded = assertNotNull(packet.encoded(padded = true), "$name encodes padded")
      assertEquals(V.row("packet", "packet.$name.packetID"), packet.packetID.meshHex(), "$name id")
      assertEquals(V.int("packet", "packet.$name.len"), raw.size, "$name len")
      assertEquals(V.row("packet", "packet.$name.unpadded"), raw.meshHex(), "$name bytes")
      assertEquals(V.row("packet", "packet.$name.padded"), padded.meshHex(), "$name padded bytes")
      assertEquals(V.row("packet", "packet.$name.isBroadcast"), packet.isBroadcast.toString(), "$name broadcast?")
      assertEquals(
        V.row("packet", "packet.$name.decodedType"),
        PopopxMeshVerdicts.swift(packet.decodedType),
        "$name decoded type",
      )
      assertEquals(V.row("packet", "packet.$name.decodeUnpadded"), (PopopxMeshPacket.decode(raw) == packet).toString(), "$name round trip")
      assertEquals(V.row("packet", "packet.$name.decodePadded"), (PopopxMeshPacket.decode(padded) == packet).toString(), "$name padded round trip")
      assertEquals(V.int("packet", "packet.$name.packetIDLen"), packet.packetID.size, "$name id width")
    }
  }

  /**
   * Packets that cannot be put on the wire. The rows arrived in the order Swift's dictionary happened
   * to iterate, so they are looked up by label rather than by position; every one of them must be a
   * refusal, and a silent acceptance is exactly the bug this list is here to catch.
   */
  @Test
  fun unrepresentablePacketsRefuseAtEncodeTime() {
    val refusals = mapOf(
      "packetBad.version2" to packet(typeValue = 2, ttl = 1, recipient = null, payload = smallPayload, version = 2),
      "packetBad.senderWidth" to packet(typeValue = 2, ttl = 1, recipient = null, payload = smallPayload, sender = ByteArray(7)),
      "packetBad.recipientWidth" to packet(typeValue = 2, ttl = 1, recipient = ByteArray(7), payload = smallPayload),
      "packetBad.signatureWidth" to packet(
        typeValue = 2, ttl = 1, recipient = null, payload = smallPayload, signature = ByteArray(63),
      ),
      "packetBad.oversized" to packet(typeValue = 2, ttl = 1, recipient = null, payload = ByteArray(65_536)),
    )
    assertEquals(V.rows("packetBad").map { it.first }.toSet(), refusals.keys)
    for ((label, packet) in refusals) {
      assertEquals(V.row("packetBad", label), if (packet.encoded(padded = false) == null) "nil" else "ENCODED (unexpected)", label)
    }
  }

  /**
   * What the inbound parser must refuse and what it must tolerate. Every case here is a mutation of
   * the same real packet the encoder produced, taken from the `unpadded` row itself, so the counter-
   * examples are aimed at iOS' own bytes rather than at a reconstruction.
   */
  @Test
  fun inboundParserCounterexamples() {
    val base = assertNotNull(V.row("packet", "packet.unsigned.unpadded").meshHexToBytes())
    fun nilFor(label: String, bytes: ByteArray) =
      assertEquals(V.row("decode", label), if (PopopxMeshPacket.decode(bytes) == null) "nil" else "decoded (unexpected)", label)

    nilFor("decode.wrongVersion", mutate(base) { it[0] = 2 })
    nilFor("decode.shorterThan22", base.copyOfRange(0, 21))
    nilFor("decode.recipientFlagWithoutBytes", mutate(base) { it[11] = (it[11].toInt() or 0x01).toByte() })
    nilFor("decode.signatureFlagWithoutBytes", mutate(base) { it[11] = (it[11].toInt() or 0x02).toByte() })
    nilFor("decode.payloadOverrun", mutate(base) { it[12] = 0xFF.toByte(); it[13] = 0xFF.toByte() })
    nilFor("decode.empty", ByteArray(0))
    nilFor("decode.garbage", ByteArray(64) { it.toByte() })

    val trailing = base + bytes(0xAA, 0xBB, 0xCC)
    assertEquals(
      V.row("decode", "decode.trailingBytesIgnored"),
      (PopopxMeshPacket.decode(trailing) == unsigned).toString(),
    )
    assertEquals(
      V.row("decode", "decode.ttlZeroAccepted"),
      (PopopxMeshPacket.decode(mutate(base) { it[2] = 0 })?.ttl == 0).toString(),
    )
    // The version field is read and never written back, so whatever arrived is reported as version 1.
    assertEquals(V.row("decode", "decode.versionNotStored"), (PopopxMeshPacket.decode(base)?.version == 1).toString())
    assertEquals("true", V.row("decode", "decode.versionNotStored"))
  }

  /**
   * The four buckets and their boundaries on both sides, the >255 branch where iOS pads nothing, and
   * the shape of a frame that is already larger than the last bucket.
   *
   * The freeze repeats a label once per bucket, suffixed `#2`, `#3`..., and all six labels of one
   * bucket repeat the same number of times, so the row of the bucket at index `n` is addressed by
   * that index rather than looked up - a lookup would silently re-test bucket 0 thirteen times.
   */
  @Test
  fun paddingBuckets() {
    val groups = V.rows("pad").chunked(6)
    assertEquals(14, groups.size, "thirteen buckets plus one group of unpad counterexamples")
    for (n in 1..13) {
      val suffix = if (n == 1) "" else "#$n"
      fun row(prefix: String): String = V.row("pad", "$prefix$suffix")
      fun int(prefix: String): Int = row(prefix).toInt()
      val size = int("pad.in")
      val bucket = int("pad.bucket")
      assertEquals(bucket, PopopxMeshPacket.optimalBlockSize(size), "bucket for $size")
      val padded = PopopxMeshPacket.pad(ByteArray(size), bucket)
      assertEquals(int("pad.out"), padded.size, "padded length for $size")
      assertEquals(row("pad.tail"), padded.takeLast(6).toByteArray().meshHex(), "pad tail for $size")
      val unpadded = PopopxMeshPacket.unpad(padded)
      assertEquals(int("pad.unpadLength"), unpadded.size, "unpadded length for $size")
      assertEquals(row("pad.unpadStable"), (unpadded.size == size).toString(), "unpad is exact for $size")
    }
    // The bucket list is the wire contract the loop above only exercises through its boundaries.
    assertEquals(listOf(256, 512, 1024, 2048), PopopxMeshPacket.blockSizes)
  }

  /**
   * `unpad` on bytes that were never padded must return the input unchanged. Each row already holds
   * both halves - `input -> output` in hex - so the check is a byte compare, not an interpretation.
   */
  @Test
  fun unpadLeavesForeignBytesAlone() {
    for ((label, row) in V.rows("pad").filter { it.first.startsWith("unpad.") }) {
      val (inputHex, outputHex) = row.split(" -> ")
      val input = inputHex.meshHexToBytes() ?: ByteArray(0)
      assertEquals(outputHex, PopopxMeshPacket.unpad(input).meshHex(), label)
    }
  }

  private fun packet(
    type: PopopxMeshMessageType? = null,
    ttl: Int,
    recipient: ByteArray?,
    payload: ByteArray,
    typeValue: Int = 0,
    sender: ByteArray = senderID,
    timestamp: Long = this.timestamp,
    signature: ByteArray? = null,
    version: Int = 1,
  ): PopopxMeshPacket =
    PopopxMeshPacket(
      version = version,
      type = type?.wireValue ?: typeValue,
      ttl = ttl,
      timestamp = timestamp,
      senderID = sender,
      recipientID = recipient,
      payload = payload,
      signature = signature,
    )

  private fun bytes(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }

  private fun mutate(source: ByteArray, block: (ByteArray) -> Unit): ByteArray =
    source.copyOf().also(block)

  private companion object {
    val V = PopopxMeshSwiftVectors
  }
}
