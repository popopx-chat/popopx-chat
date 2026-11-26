package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxMeshControlFrame
import chat.popopx.common.mesh.PopopxMeshEnvelope
import chat.popopx.common.mesh.PopopxMeshPacket
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.mesh.meshHexToBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The envelope grammar and the control-frame prefixes.
 *
 * iOS writes this JSON with `JSONEncoder` and `.sortedKeys`, and reads it back with a decoder that is
 * stricter than a map lookup would be, so the byte order and the refusal list are both part of the
 * wire contract. The `envelopeDecode.*` block is the measured half of that: 46 documents, each with
 * its input recorded in hex and the decoder's own verdict.
 */
internal class PopopxMeshEnvelopeVectorTest {
  @Test
  fun encodedEnvelopesMatchIOSByteForByte() {
    val groups = V.rows("envelope").chunked(9)
    assertEquals(7, groups.size, "seven envelopes, nine rows each")
    for ((index, group) in groups.withIndex()) {
      val n = index + 1
      val suffix = if (n == 1) "" else "#$n"
      fun row(prefix: String): String = group.first { it.first == "$prefix$suffix" }.second
      val id = String(hex(row("envelope.in.idHex"), "id"))
      val body = String(hex(row("envelope.in.bodyHex"), "body"), Charsets.UTF_8)
      val kind = assertNotNull(PopopxMeshEnvelope.Kind.of(row("envelope.in.kind")), "kind row")
      val sentAt = row("envelope.in.sentAt").toULong().toLong()
      val envelope = PopopxMeshEnvelope(id = id, sentAt = sentAt, kind = kind, body = body)
      val encoded = PopopxMeshEnvelope.encode(envelope)

      assertEquals(row("envelope.utf8"), encoded.toString(Charsets.UTF_8), "envelope $n text")
      assertEquals(row("envelope.hex"), encoded.meshHex(), "envelope $n bytes")
      assertEquals(
        row("envelope.roundTrip"),
        if (PopopxMeshEnvelope.decode(encoded) == envelope) "equal" else "MISMATCH",
        "envelope $n round trip",
      )
      // The two throwaway rows in every group: the decoder's answer to a document that is not one.
      assertEquals(row("envelope.decodeGarbage"), (PopopxMeshEnvelope.decode("{}".toByteArray(Charsets.UTF_8)) == null).toString())
      assertEquals(row("envelope.decodeNotOurShape"), (PopopxMeshEnvelope.decode("[1,2]".toByteArray(Charsets.UTF_8)) == null).toString())
    }
  }

  /**
   * Every probe document, fed in as the bytes iOS was given, with the verdict compared as a whole
   * string: `nil` for a refusal, or the document our own encoder wrote back for an acceptance. That
   * second half is the point - accepting and then re-emitting different bytes would pass a weaker
   * comparison.
   */
  @Test
  fun inboundEnvelopeGrammar() {
    val rows = V.rows("envelopeDecode").toMap()
    val inputs = V.rows("envelopeDecode").filter { it.first.endsWith(".in") }
    assertEquals(46, inputs.size, "one input row per probe")
    for ((label, hexText) in inputs) {
      val verdict = rows.getValue(label.removeSuffix(".in"))
      val bytes = hex(hexText, label)
      val decoded = PopopxMeshEnvelope.decode(bytes)
      val actual =
        if (decoded == null) {
          "nil"
        } else {
          "ok->" + PopopxMeshEnvelope.encode(decoded).toString(Charsets.UTF_8)
        }
      assertEquals(verdict, actual, label)
    }
  }

  /**
   * Control frames, recognised and refused. An accepted row carries the frame's whole payload in hex,
   * so the input is read back out of it. A refused row only carries the first 24 characters and the
   * length, which is enough here because the only thing a refusal can depend on is the prefix, the
   * argument width and the length - all three of which the row states.
   */
  @Test
  fun controlFramePrefixes() {
    for ((label, row) in V.rows("control")) {
      val head = row.substringBefore(" len=")
      val length = row.substringAfter(" len=").substringBefore(" ").toInt()
      val expected = row.substringAfter("-> ")
      val text =
        if (expected == "nil") {
          head + (if (length > head.length) head.last().toString().repeat(length - head.length) else "")
        } else {
          String(hex(expected.substringAfter("bytes="), label), Charsets.UTF_8)
        }
      assertEquals(row, verdictOf(text), "$label (${if (expected == "nil") "refusal" else "accept"})")
    }
  }

  /**
   * Whether the announce payload's byte order is stable is a fact the port needs, and the answer is
   * that it belongs to Swift's dictionary rather than to the protocol: the count in
   * `announce.distinctOrderings` is measured per process, so it is read here as "at least one", while
   * every ordering that was seen is checked to hold the same three keys. The conclusion for the port
   * is that announce bytes may never be hashed or compared as identity - the envelope, which is
   * written with `.sortedKeys`, is the only mesh JSON with a stable byte form, and
   * `envelopeDecode.reverseKeyOrder` above is what our own reader makes of an unordered document.
   */
  @Test
  fun announceJsonOrderIsNotMeaningful() {
    val sorted = V.row("announceOrder", "announce.sortedKeysForm")
    val keys = listOf("\"nickname\":", "\"pubkey\":", "\"signpub\":")
    val positions = keys.map { sorted.indexOf(it) }
    assertEquals(3, positions.count { it >= 0 }, "the sorted form holds all three keys")
    assertEquals(positions.sorted(), positions, "and holds them in name order: $sorted")
    assertTrue(V.row("announceOrder", "announce.decodesFromSorted").toBoolean())
    val orderings = V.rowsStartingWith("announceOrder", "announce.ordering")
    assertTrue(V.int("announceOrder", "announce.distinctOrderings") >= 1)
    for ((label, row) in orderings) {
      val json = row.substringAfter("x ")
      assertEquals(sorted.length, json.length, label)
      val positions = keys.map { json.indexOf(it) }
      assertTrue(positions.all { it >= 0 }, "$label lost a key: $json")
      assertEquals(3, positions.distinct().size, "$label holds each key once: $json")
    }
  }

  /**
   * Which keys an announce may omit. The bytes are Swift's whole padded packet, so this is also the
   * only place the padding of a real announce payload is checked: our decoder has to take them and
   * hand back the identical bytes.
   */
  @Test
  fun announceKeyShapesRoundTrip() {
    for ((label, row) in V.rows("announceShape")) {
      if (!label.endsWith(".bytes")) continue
      val bytes = assertNotNull(row.meshHexToBytes(), label)
      val decoded = PopopxMeshPacket.decode(bytes)
      val accepted = (decoded != null).toString()
      assertEquals(V.rows("announceShape").toMap().getValue(label.removeSuffix(".bytes") + ".decodes"), accepted, label)
      val packet = assertNotNull(decoded, label)
      assertEquals(row, assertNotNull(packet.encoded(padded = true), label).meshHex(), "$label re-encoded")
    }
  }

  private fun verdictOf(text: String): String {
    val head = text.take(24)
    val frame = PopopxMeshControlFrame.of(text)
    return if (frame == null) {
      "$head len=${text.length} -> nil"
    } else {
      "$head len=${text.length} -> type=${frame.messageType.wireValue} bytes=${frame.payload.meshHex()}"
    }
  }

  private fun hex(value: String, forLabel: String): ByteArray =
    if (value.isEmpty()) ByteArray(0) else assertNotNull(value.meshHexToBytes(), "$forLabel is not hex: $value")

  private companion object {
    val V = PopopxMeshSwiftVectors
  }
}
