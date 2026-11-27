package chat.popopx.app.discover

//
//  PopopxNodeFeedWireTest.kt
//  desktopTest
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The receiver side of the `popopx.discover.feed.v1` contract, checked against the same pinned envelopes
//  iOS checks (NodeFeedVectors, generated from PopopxNodeFeedVectors.swift). Mirrors
//  apps/ios/PopopxMeshKit/Tests/PopopxMeshKitTests/PopopxNodeFeedWireTests.swift case for case; where the
//  two cannot match, the reason is said out loud in the test that cannot.
//
//  The load-bearing case is canonicalBodiesMatchTheMint: it compares the bytes this serializer rebuilds
//  against digests minted from Foundation's own JSONSerialization output. A signature check alone passes for
//  any self-consistent pair of encoder and verifier; this one fails the moment an implementation escapes a
//  slash, normalizes an accent, or sorts a key differently — which is exactly how a Kotlin port drifts.
//

import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.crypto.sha256Hex
import chat.popopx.common.discover.PopopxNodeFeed
import chat.popopx.common.discover.PopopxNodeFeedApply
import chat.popopx.common.discover.PopopxNodeFeedItem
import chat.popopx.common.discover.PopopxNodeFeedRefusal
import chat.popopx.common.discover.PopopxNodeFeedSnapshot
import chat.popopx.common.discover.PopopxNodeFeedVerdict
import chat.popopx.common.discover.PopopxNodeFeedWire
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PopopxNodeFeedWireTest {

  // MARK: The carriers themselves

  @Test
  fun carriersKeepTheirEscapesLiteral() {
    // The must-be-true control for sharing text between two lexers: a Kotlin raw string must hand the JSON
    // parser the escape SEQUENCE, not a character it decoded first. Were it the latter, every digest below
    // would still be self-consistent and this file would prove nothing about iOS.
    assertTrue(NodeFeedVectors.escaping.contains("Ctl" + BACKSLASH + "u0001"))
    assertTrue(NodeFeedVectors.plain.contains(BACKSLASH + "/popopx.example"))
    assertTrue(NodeFeedVectors.unicode.contains(BACKSLASH + "u4E2D"))
    assertFalse(NodeFeedVectors.unicode.contains("中"), "the raw string decoded its escapes")
    // And trimIndent must leave the producer's own formatting intact, byte for byte.
    for ((name, expected) in NodeFeedVectors.byteSizes) {
      assertEquals(expected, carrier(name).toByteArray().size, "carrier bytes: " + name)
    }
  }

  // MARK: Acceptance

  @Test
  fun honestVectorsAreAccepted() {
    for (name in listOf("plain", "escaping", "unicode", "empty")) {
      val verdict = PopopxNodeFeedWire.verify(carrierBytes(name), NodeFeedVectors.SIGNING_PUBLIC_KEY, null)
      assertTrue(verdict is PopopxNodeFeedVerdict.Accepted, name + " refused: " + (verdict as? PopopxNodeFeedVerdict.Refused)?.reason)
    }
  }

  @Test
  fun emptyFeedIsValidFeed() {
    assertEquals(0, feed("empty").items.size)
    assertTrue(PopopxNodeFeedWire.verify(carrierBytes("empty"), NodeFeedVectors.SIGNING_PUBLIC_KEY, null) is PopopxNodeFeedVerdict.Accepted)
  }

  @Test
  fun decodedValuesAreUnescaped() {
    val plain = feed("plain")
    assertEquals("https://popopx.example/blog/1-2-0?x=a/b", plain.items[0].link)
    assertEquals("~/Documents", plain.items[1].sourceLabel)
    assertEquals("", plain.items[1].link)

    val unicode = feed("unicode")
    val title = unicode.items[0].title
    assertTrue(title.any { it.code == 0x2028 }, "U+2028 did not survive")
    assertTrue(title.any { it.code == 0x7F }, "U+007F did not survive")
    assertTrue(title.toByteArray().contains(0xF0.toByte()), "the astral emoji is not UTF-8")
    // Deliberately decomposed at mint time, and it must stay that way: normalizing here would change the
    // bytes under the signature. Compared by code unit and by UTF-8 hex, never with contains on a precomposed
    // letter — Swift reports an accented e and e + U+0301 as the same text, and this platform would too if a
    // decoder ever normalized.
    val summary = unicode.items[0].summary
    assertTrue(summary.any { it.code == 0x301 })
    assertFalse(summary.any { it.code == 0xE9 })
    assertTrue(hexEncode(summary.toByteArray()).contains("65cc81"))
    assertFalse(hexEncode(summary.toByteArray()).contains("c3a9"))
  }

  // MARK: The byte gate

  @Test
  fun canonicalBodiesMatchTheMint() {
    assertEquals(NodeFeedVectors.Digest.PLAIN_ITEM_BODY, sha256Hex(PopopxNodeFeedWire.canonicalItemBody(feed("plain").items[0])))
    assertEquals(NodeFeedVectors.Digest.PLAIN_ENVELOPE_BODY, sha256Hex(PopopxNodeFeedWire.canonicalEnvelopeBody(feed("plain"))))
    assertEquals(NodeFeedVectors.Digest.ESCAPING_ITEM_BODY, sha256Hex(PopopxNodeFeedWire.canonicalItemBody(feed("escaping").items[0])))
    assertEquals(NodeFeedVectors.Digest.ESCAPING_ENVELOPE_BODY, sha256Hex(PopopxNodeFeedWire.canonicalEnvelopeBody(feed("escaping"))))
    assertEquals(NodeFeedVectors.Digest.UNICODE_ITEM_BODY, sha256Hex(PopopxNodeFeedWire.canonicalItemBody(feed("unicode").items[0])))
    assertEquals(NodeFeedVectors.Digest.UNICODE_ENVELOPE_BODY, sha256Hex(PopopxNodeFeedWire.canonicalEnvelopeBody(feed("unicode"))))
    assertEquals(NodeFeedVectors.Digest.EMPTY_ENVELOPE_BODY, sha256Hex(PopopxNodeFeedWire.canonicalEnvelopeBody(feed("empty"))))
  }

  @Test
  fun fileBytesDifferFromSigningBody() {
    // For the two ASCII vectors the carrier is byte-identical to what the node wrote to disk, so this
    // compares the receiver's real input against the real signature body, not a paraphrase of it.
    assertEquals(NodeFeedVectors.Digest.PLAIN_FILE_BYTES, sha256Hex(carrierBytes("plain")))
    assertTrue(sha256Hex(carrierBytes("plain")) != NodeFeedVectors.Digest.PLAIN_ENVELOPE_BODY)
    assertEquals(NodeFeedVectors.Digest.ESCAPING_FILE_BYTES, sha256Hex(carrierBytes("escaping")))
    // The unicode carrier is the one place the pinned text and the disk bytes part company.
    assertEquals(NodeFeedVectors.Digest.UNICODE_CARRIER_BYTES, sha256Hex(carrierBytes("unicode")))
    assertTrue(sha256Hex(carrierBytes("unicode")) != NodeFeedVectors.Digest.UNICODE_FILE_BYTES)
  }

  @Test
  fun keyOrderMatchesFoundation() {
    // The order the iOS suite reads out of JSONSerialization's own output is hardcoded here, because that
    // order is a wire value: a receiver that sorted the seven item keys differently would rebuild a body no
    // node ever signed. Asserted on the constant, and on the escaping vectors' digest, which cannot match
    // under any other order.
    assertEquals(
      listOf("id", "link", "sha256", "signature", "source", "sourceLabel", "summary", "timestamp", "title"),
      PopopxNodeFeedWire.ITEM_KEYS,
    )
    assertEquals(listOf("id", "link", "source", "sourceLabel", "summary", "timestamp", "title"), PopopxNodeFeedWire.ITEM_BODY_KEYS)
    assertEquals(listOf("generatedAt", "items", "nodeId", "publicKey", "schema"), PopopxNodeFeedWire.ENVELOPE_BODY_KEYS)
  }

  @Test
  fun escapingTable() {
    val item = PopopxNodeFeedItem(
      id = "x",
      title = "q" + DQ + "t b" + BACKSLASH + "k s/l",
      summary = controlRun(),
      source = "rss",
      sourceLabel = "del" + DEL + " ls" + LS + " ps" + PS,
      link = "https://a/b",
      timestamp = NodeFeedVectors.ITEM_TIMESTAMP,
      sha256 = "",
      signature = "",
    )
    val body = String(PopopxNodeFeedWire.canonicalItemBody(item), Charsets.UTF_8)
    assertTrue(body.contains(DQ + "title" + DQ + ":" + DQ + "q" + BACKSLASH + DQ + "t b" + BACKSLASH + BACKSLASH + "k s/l" + DQ), body)
    assertTrue(body.contains(DQ + "link" + DQ + ":" + DQ + "https://a/b" + DQ))
    assertTrue(body.contains(BACKSLASH + "b" + BACKSLASH + "f" + BACKSLASH + "t" + BACKSLASH + "n" + BACKSLASH + "r"))
    assertTrue(body.contains(BACKSLASH + "u0001" + BACKSLASH + "u001f"), "four digits, lowercase hex")
    assertTrue(body.contains("del" + DEL))
    assertTrue(body.contains("ls" + LS + " ps" + PS))
    assertFalse(body.contains(BACKSLASH + "/"))
    // The seven signing keys, in order — and the two that are ABOUT the signature are absent, which is what
    // lets a digest be checked before any key is believed.
    assertTrue(
      body.startsWith(
        "{" + DQ + "id" + DQ + ":" + DQ + "x" + DQ + "," + DQ + "link" + DQ + ":" + DQ + "https://a/b" + DQ + "," +
          DQ + "source" + DQ + ":" + DQ + "rss" + DQ + "," + DQ + "sourceLabel" + DQ + ":" + DQ
      ), body
    )
    assertFalse(body.contains("sha256"))
    assertFalse(body.contains("signature"))
    assertTrue(body.endsWith("}"))
  }

  // MARK: Refusals, one per decision

  @Test
  fun editedItemFailsItsDigest() {
    refused("digestDrift", PopopxNodeFeedRefusal.ITEM_DIGEST)
  }

  @Test
  fun recomputedDigestCannotRescueAnOldItemSignature() {
    refused("itemSignature", PopopxNodeFeedRefusal.ITEM_SIGNATURE)
  }

  @Test
  fun changedEnvelopeFieldIsCaughtByTheEnvelopeSignature() {
    refused("envelopeSignature", PopopxNodeFeedRefusal.ENVELOPE_SIGNATURE)
  }

  @Test
  fun itemsSignedByASecondKeyAreRefusedUnderTheDeclaredKey() {
    refused("foreignKey", PopopxNodeFeedRefusal.ITEM_SIGNATURE)
  }

  @Test
  fun reorderedItemsBreakOnlyTheEnvelope() {
    val data = mutated(NodeFeedVectors.plain) { envelope ->
      val items = envelope["items"] as JsonArray
      envelope["items"] = JsonArray(listOf(items[1], items[0]))
    }
    assertEquals(
      PopopxNodeFeedRefusal.ENVELOPE_SIGNATURE,
      (PopopxNodeFeedWire.verify(data, NodeFeedVectors.SIGNING_PUBLIC_KEY, null) as? PopopxNodeFeedVerdict.Refused)?.reason,
    )
  }

  @Test
  fun rotatedKeyIsRefusedNeverRePinned() {
    assertEquals(
      PopopxNodeFeedRefusal.KEY_MISMATCH,
      (PopopxNodeFeedWire.verify(carrierBytes("plain"), NodeFeedVectors.OTHER_PUBLIC_KEY, null) as? PopopxNodeFeedVerdict.Refused)?.reason,
    )
    // With nothing pinned yet the same feed is acceptable — pinning is the caller's first run.
    assertTrue(PopopxNodeFeedWire.verify(carrierBytes("plain"), null, null) is PopopxNodeFeedVerdict.Accepted)
  }

  @Test
  fun generatedAtMustBeStrictlyNewer() {
    val at = assertNotNull(feed("plain").generatedAtMs)
    assertTrue(PopopxNodeFeedWire.verify(carrierBytes("plain"), NodeFeedVectors.SIGNING_PUBLIC_KEY, at) is PopopxNodeFeedVerdict.Refused)
    assertEquals(
      PopopxNodeFeedRefusal.STALE,
      (PopopxNodeFeedWire.verify(carrierBytes("plain"), NodeFeedVectors.SIGNING_PUBLIC_KEY, at) as? PopopxNodeFeedVerdict.Refused)?.reason,
    )
    assertEquals(
      PopopxNodeFeedRefusal.STALE,
      (PopopxNodeFeedWire.verify(carrierBytes("plain"), NodeFeedVectors.SIGNING_PUBLIC_KEY, at + 60_000L) as? PopopxNodeFeedVerdict.Refused)?.reason,
    )
    assertTrue(PopopxNodeFeedWire.verify(carrierBytes("plain"), NodeFeedVectors.SIGNING_PUBLIC_KEY, at - 60_000L) is PopopxNodeFeedVerdict.Accepted)
  }

  @Test
  fun structuralRefusalsFireBeforeAnythingIsSigned() {
    assertEquals(PopopxNodeFeedRefusal.SCHEMA, reason(DQ_SCHEMA_V2))
    assertEquals(PopopxNodeFeedRefusal.MALFORMED_JSON, reason("[]".toByteArray()))
    assertEquals(PopopxNodeFeedRefusal.MALFORMED_JSON, reason("not json".toByteArray()))
    assertEquals(PopopxNodeFeedRefusal.MALFORMED_JSON, reason((DQ + "a string" + DQ).toByteArray()))
    assertEquals(
      PopopxNodeFeedRefusal.MALFORMED_JSON,
      reason(ByteArray(PopopxNodeFeedWire.MAXIMUM_FEED_BYTES.toInt() + 1) { 0x20.toByte() }),
    )
    assertEquals(PopopxNodeFeedRefusal.EMPTY_KEY, reason(mutated(NodeFeedVectors.plain) { it["publicKey"] = JsonPrimitive("") }))
    // A padded or standard-alphabet key is refused rather than repaired.
    assertEquals(PopopxNodeFeedRefusal.EMPTY_KEY, reason(mutated(NodeFeedVectors.plain) { it["publicKey"] = JsonPrimitive("AA==") }))
    assertEquals(PopopxNodeFeedRefusal.EMPTY_KEY, reason(mutated(NodeFeedVectors.plain) { it["publicKey"] = JsonPrimitive("AA/+AA") }))
    assertEquals(PopopxNodeFeedRefusal.EMPTY_SIG, reason(mutated(NodeFeedVectors.plain) { it["signature"] = JsonPrimitive("") }))
    assertEquals(PopopxNodeFeedRefusal.ITEM_SHAPE, reason(mutated(NodeFeedVectors.plain) { it["items"] = JsonArray(listOf(JsonPrimitive("not an object"))) }))
    assertEquals(PopopxNodeFeedRefusal.ITEM_SHAPE, reason(editFirstItem(NodeFeedVectors.plain) { it["id"] = JsonPrimitive("") }))
    assertEquals(PopopxNodeFeedRefusal.ITEM_SHAPE, reason(editFirstItem(NodeFeedVectors.plain) { it.remove("title") }))
    assertEquals(PopopxNodeFeedRefusal.ITEM_SHAPE, reason(editFirstItem(NodeFeedVectors.plain) { it["sha256"] = JsonPrimitive("too short") }))
    // A number is not the string the producer writes, and describing it is not this decoder's job.
    assertEquals(PopopxNodeFeedRefusal.ITEM_SHAPE, reason(editFirstItem(NodeFeedVectors.plain) { it["timestamp"] = JsonPrimitive(1_764_000_000L) }))
  }

  @Test
  fun itemCeilingIsStructural() {
    assertTrue(PopopxNodeFeedWire.parse(envelopeWithCount(60)).feedOrNull()?.items?.size == 60)
    assertEquals(PopopxNodeFeedRefusal.ITEM_SHAPE, reason(envelopeWithCount(61)))
  }

  @Test
  fun loneSurrogateIsRefusedNotSignedOver() {
    // WHICH refusal is Foundation's and the JSON library's, not a wire fact: iOS cannot even parse the
    // escape, while this parser may keep an unpaired surrogate and lose the digest instead. Both are a drop,
    // so that is the only claim made.
    assertTrue(PopopxNodeFeedWire.verify(carrierBytes("loneSurrogate"), NodeFeedVectors.SIGNING_PUBLIC_KEY, null) is PopopxNodeFeedVerdict.Refused)
  }

  // MARK: Storing

  @Test
  fun ingestChain() {
    val at = assertNotNull(feed("plain").generatedAtMs)
    val stored = (PopopxNodeFeedWire.ingest(carrierBytes("plain"), null, at) as? PopopxNodeFeedApply.Stored)?.snapshot
    assertNotNull(stored)
    assertEquals(NodeFeedVectors.SIGNING_PUBLIC_KEY, stored.publicKey)
    assertEquals(2, stored.items.size)
    assertEquals(NodeFeedVectors.GENERATED_AT, stored.generatedAt)
    assertNull(stored.keyChangedAtMs)

    // The same envelope twice is not newer, so the snapshot does not move. This is the dedupe: a re-synced
    // chat row must not rewrite the panel or re-run the crypto for show.
    val again = PopopxNodeFeedWire.ingest(carrierBytes("plain"), stored, at) as? PopopxNodeFeedApply.Refused
    assertNotNull(again)
    assertEquals(PopopxNodeFeedRefusal.STALE, again.reason)
    assertEquals(stored, again.state)

    // A feed under a different key is refused rather than re-pinned, and the refusal carries the reason
    // forward so the panel can say why nothing changed.
    val other = PopopxNodeFeedSnapshot(
      items = emptyList(),
      generatedAt = "2026-11-27T08:00:00Z",
      nodeId = "node-7f2a",
      publicKey = NodeFeedVectors.OTHER_PUBLIC_KEY,
    )
    val rotated = PopopxNodeFeedWire.ingest(carrierBytes("plain"), other, at) as? PopopxNodeFeedApply.Refused
    assertNotNull(rotated)
    assertEquals(PopopxNodeFeedRefusal.KEY_MISMATCH, rotated.reason)
    assertEquals(at, rotated.state?.keyChangedAtMs)
    assertEquals(NodeFeedVectors.OTHER_PUBLIC_KEY, rotated.state?.publicKey, "the pinned key was overwritten")
    assertTrue(rotated.state?.items?.isEmpty() == true, "a refused feed replaced the items")

    // A tampered feed leaves the stored state byte-for-byte where it was, warning included.
    val tampered = PopopxNodeFeedWire.ingest(carrierBytes("digestDrift"), stored, at) as? PopopxNodeFeedApply.Refused
    assertNotNull(tampered)
    assertEquals(PopopxNodeFeedRefusal.ITEM_DIGEST, tampered.reason)
    assertEquals(stored, tampered.state)

    // And once a key change is on record, a later success does not quietly undo it.
    val warned = other.copy(publicKey = NodeFeedVectors.SIGNING_PUBLIC_KEY, keyChangedAtMs = 1L)
    val kept = PopopxNodeFeedWire.ingest(carrierBytes("plain"), warned, at) as? PopopxNodeFeedApply.Stored
    assertNotNull(kept, "the warned snapshot was refused instead of stored")
    assertEquals(1L, kept.snapshot.keyChangedAtMs)
    assertEquals(2, kept.snapshot.items.size)

    // Round-tripping the stored form keeps every field, because the panel reads it back after a restart.
    assertEquals(stored, PopopxNodeFeedSnapshot.fromJson(PopopxNodeFeedSnapshot.toJson(stored)))
    assertNull(PopopxNodeFeedSnapshot.fromJson(Json.parseToJsonElement("[]")))
  }

  // MARK: Primitives

  @Test
  fun keyDecodingIsStrict() {
    assertEquals(32, PopopxNodeFeedWire.keyBytes(NodeFeedVectors.SIGNING_PUBLIC_KEY)?.size)
    assertNull(PopopxNodeFeedWire.keyBytes(""))
    assertNull(PopopxNodeFeedWire.keyBytes("A".repeat(43) + "="))
    assertNull(PopopxNodeFeedWire.keyBytes("AA/+AA"))
    assertNull(PopopxNodeFeedWire.keyBytes("A"))
    assertNull(PopopxNodeFeedWire.keyBytes("A".repeat(42)), "31.5 bytes is not a key")
  }

  @Test
  fun instantParsing() {
    assertNotNull(PopopxNodeFeedWire.instantMillis("2026-11-27T09:05:00Z"))
    assertNotNull(PopopxNodeFeedWire.instantMillis("2026-11-27T09:05:00.123Z"))
    assertNull(PopopxNodeFeedWire.instantMillis("2026-11-27 09:05:00"))
    assertNull(PopopxNodeFeedWire.instantMillis(""))
  }

  @Test
  fun autoReceiveGate() {
    val name = PopopxNodeFeedWire.ARTIFACT_FILE_NAME
    assertTrue(PopopxNodeFeedWire.shouldAutoReceive(name, 4_096L, false, true))
    assertTrue(PopopxNodeFeedWire.shouldAutoReceive(name, PopopxNodeFeedWire.MAXIMUM_FEED_BYTES, false, true))
    // The negative half is the point: each of these is a download the app must not start.
    assertFalse(PopopxNodeFeedWire.shouldAutoReceive(name, 1L, false, false))
    assertFalse(PopopxNodeFeedWire.shouldAutoReceive(name, PopopxNodeFeedWire.MAXIMUM_FEED_BYTES + 1L, false, true))
    assertFalse(PopopxNodeFeedWire.shouldAutoReceive(name, 0L, false, true))
    assertFalse(PopopxNodeFeedWire.shouldAutoReceive(name, -1L, false, true))
    assertFalse(PopopxNodeFeedWire.shouldAutoReceive("other.json", 1L, false, true))
    assertFalse(PopopxNodeFeedWire.shouldAutoReceive(name, 1L, true, true))
    assertFalse(
      PopopxNodeFeedWire.shouldAutoReceive("FEED.JSON", 1L, false, true),
      "the basename is compared, not matched case-insensitively — the node writes one spelling",
    )
    // The same question asked AFTER the download has to reach the same verdict: the mount measures the real
    // bytes before reading them, and it must not invent a second rule.
    assertTrue(PopopxNodeFeedWire.isArtifact(name, PopopxNodeFeedWire.MAXIMUM_FEED_BYTES))
    assertFalse(PopopxNodeFeedWire.isArtifact(name, PopopxNodeFeedWire.MAXIMUM_FEED_BYTES + 1L))
    assertFalse(PopopxNodeFeedWire.isArtifact(name, 0L))
    assertFalse(PopopxNodeFeedWire.isArtifact("Feed.json", 1L))
  }

  // MARK: Helpers

  private fun carrier(name: String): String = when (name) {
    "plain" -> NodeFeedVectors.plain
    "escaping" -> NodeFeedVectors.escaping
    "unicode" -> NodeFeedVectors.unicode
    "empty" -> NodeFeedVectors.empty
    "digestDrift" -> NodeFeedVectors.digestDrift
    "itemSignature" -> NodeFeedVectors.itemSignature
    "envelopeSignature" -> NodeFeedVectors.envelopeSignature
    "foreignKey" -> NodeFeedVectors.foreignKey
    "loneSurrogate" -> NodeFeedVectors.loneSurrogate
    else -> error("no carrier named " + name)
  }

  private fun carrierBytes(name: String): ByteArray = carrier(name).toByteArray()

  private fun feed(name: String): PopopxNodeFeed {
    val verdict = PopopxNodeFeedWire.parse(carrierBytes(name))
    assertTrue(verdict is PopopxNodeFeedVerdict.Accepted, "vector did not parse: " + name + " " + (verdict as? PopopxNodeFeedVerdict.Refused)?.reason)
    return verdict.feed
  }

  private fun reason(bytes: ByteArray): PopopxNodeFeedRefusal? =
    (PopopxNodeFeedWire.parse(bytes) as? PopopxNodeFeedVerdict.Refused)?.reason

  private fun refused(name: String, expected: PopopxNodeFeedRefusal) {
    val verdict = PopopxNodeFeedWire.verify(carrierBytes(name), NodeFeedVectors.SIGNING_PUBLIC_KEY, null)
    assertTrue(verdict is PopopxNodeFeedVerdict.Refused, name + " was accepted instead of refused as " + expected)
    assertEquals(expected, verdict.reason, name)
  }

  private fun PopopxNodeFeedVerdict.feedOrNull(): PopopxNodeFeed? = (this as? PopopxNodeFeedVerdict.Accepted)?.feed

  /** Edit a pinned vector the way an attacker would: decode, change one value, re-encode. The signatures
   * stay exactly as the node made them. */
  private fun mutated(text: String, change: (MutableMap<String, JsonElement>) -> Unit): ByteArray {
    val object0 = Json.parseToJsonElement(text) as JsonObject
    val envelope = LinkedHashMap(object0)
    change(envelope)
    return JsonObject(envelope).toString().toByteArray()
  }

  private fun editFirstItem(text: String, change: (MutableMap<String, JsonElement>) -> Unit): ByteArray =
    mutated(text) { envelope ->
      val items = envelope["items"] as JsonArray
      val edited = LinkedHashMap(items[0] as JsonObject)
      change(edited)
      envelope["items"] = JsonArray(listOf(JsonObject(edited)) + items.drop(1))
    }

  private fun envelopeWithCount(count: Int): ByteArray {
    val item = JsonObject(
      linkedMapOf(
        "id" to JsonPrimitive("i"),
        "title" to JsonPrimitive("t"),
        "summary" to JsonPrimitive("s"),
        "source" to JsonPrimitive("rss"),
        "sourceLabel" to JsonPrimitive("L"),
        "link" to JsonPrimitive(""),
        "timestamp" to JsonPrimitive(NodeFeedVectors.ITEM_TIMESTAMP),
        "sha256" to JsonPrimitive("0".repeat(64)),
        "signature" to JsonPrimitive("AAA"),
      ),
    )
    return JsonObject(
      linkedMapOf(
        "schema" to JsonPrimitive(PopopxNodeFeedWire.SCHEMA_IDENTIFIER),
        "generatedAt" to JsonPrimitive(NodeFeedVectors.GENERATED_AT),
        "nodeId" to JsonPrimitive("node-7f2a"),
        "publicKey" to JsonPrimitive(NodeFeedVectors.SIGNING_PUBLIC_KEY),
        "items" to JsonArray(List(count) { item }),
        "signature" to JsonPrimitive("AAA"),
      ),
    ).toString().toByteArray()
  }

  /** BS, FF, TAB, LF, CR, SOH, US — the control scalars the escaping table has to name or number. */
  private fun controlRun(): String =
    charArrayOf(0x08.toChar(), 0x0C.toChar(), 0x09.toChar(), 0x0A.toChar(), 0x0D.toChar(), 0x01.toChar(), 0x1F.toChar()).concatToString()

  private companion object {
    private const val DQ = "\""
    private val BACKSLASH = 0x5C.toChar().toString()
    private val DEL = 0x7F.toChar().toString()
    private val LS = 0x2028.toChar().toString()
    private val PS = 0x2029.toChar().toString()
    private val DQ_SCHEMA_V2 = (DQ + "schema" + DQ + ":" + DQ + "popopx.discover.feed.v2" + DQ).let { "{" + it + "}" }.toByteArray()
  }
}
