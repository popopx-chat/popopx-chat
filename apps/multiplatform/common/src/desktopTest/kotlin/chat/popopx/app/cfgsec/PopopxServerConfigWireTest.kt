package chat.popopx.app.cfgsec

import chat.popopx.common.cfgsec.PopopxServerConfigBodyParser
import chat.popopx.common.cfgsec.PopopxServerConfigDecode
import chat.popopx.common.cfgsec.PopopxServerConfigField
import chat.popopx.common.cfgsec.PopopxServerConfigFrame
import chat.popopx.common.cfgsec.PopopxServerConfigHost
import chat.popopx.common.cfgsec.PopopxServerConfigInflator
import chat.popopx.common.cfgsec.PopopxServerConfigLimits
import chat.popopx.common.cfgsec.PopopxServerConfigRefused
import chat.popopx.common.cfgsec.PopopxServerConfigRejection
import chat.popopx.common.cfgsec.PopopxServerEntry
import chat.popopx.common.cfgsec.PopopxServerConfigTrust
import chat.popopx.common.cfgsec.PopopxServerConfigWire
import java.util.zip.Deflater
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

// The wire contract: what a frame has to look like, in which order the checks run, and which single reason a
// refusal names. The three minted fixtures carry the positive cases; almost everything else here is a negative
// case, and the negatives are the point — a client that accepts a little more than the signer emits is a client
// an attacker can talk to.

private const val B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
private const val SMP_KEY = "QqYUUR-FYesxbsSt3w2zhmKHHbxSkmwLtuX0T3gATmI"

private fun accepted(text: String, at: Long = NOW, keys: List<ByteArray> = FIXTURE_KEYS): PopopxServerConfigFrame =
  (PopopxServerConfigWire.decodeConfigFrame(text, at, keys) as? PopopxServerConfigDecode.Accepted)?.frame
    ?: fail("fixture refused: ${(PopopxServerConfigWire.decodeConfigFrame(text, at, keys) as PopopxServerConfigDecode.Refused).reason.rawValue}")

private fun refusal(text: String, at: Long = NOW, keys: List<ByteArray> = FIXTURE_KEYS): PopopxServerConfigRejection =
  (PopopxServerConfigWire.decodeConfigFrame(text, at, keys) as? PopopxServerConfigDecode.Refused)?.reason
    ?: fail("frame was accepted")

private fun token(text: String): Pair<String, String> {
  val segment = text.drop(PopopxServerConfigWire.CONFIG_PREFIX.length)
  assertTrue(segment.startsWith(PopopxServerConfigLimits.TOKEN_PREFIX))
  val parts = segment.drop(PopopxServerConfigLimits.TOKEN_PREFIX.length).split(".")
  assertEquals(2, parts.size)
  return parts[0] to parts[1]
}

private fun frame(compressed: String, signature: String): String =
  PopopxServerConfigWire.CONFIG_PREFIX + PopopxServerConfigLimits.TOKEN_PREFIX + compressed + "." + signature

private fun bump(ch: Char): Char = B64URL[(B64URL.indexOf(ch) + 1) % B64URL.length]

/** The generator's container: RFC 1950, zlib header, big-endian Adler-32 trailer. */
private fun zlib(bytes: ByteArray): ByteArray {
  val deflater = Deflater(9, false)
  deflater.setInput(bytes)
  deflater.finish()
  val out = java.io.ByteArrayOutputStream()
  val buffer = ByteArray(8_192)
  while (!deflater.finished()) out.write(buffer, 0, deflater.deflate(buffer))
  deflater.end()
  return out.toByteArray()
}

/** A body that satisfies every rule, so each case below can break exactly one of them. */
private val BASE_BODY: List<Pair<String, String>> = listOf(
  "v" to "1",
  "enc" to "\"z9\"",
  "kid" to "\"$FIXTURE_KEY_ID\"",
  "seq" to "3",
  "iat" to "$ISSUED_AT",
  "exp" to "$EXPIRES_AT",
  "smp" to """[["$SMP_KEY","smp11.popopx.im"]]""",
  "xftp" to "[]",
  "ntf" to "[]",
  "relay" to "[]",
  "ice" to "[]",
  "pol" to """{"ack":"off","ms":1,"iw":3600,"ro":100,"ttl":604800}""",
)

private fun body(vararg overrides: Pair<String, String>): String =
  BASE_BODY.joinToString(",", "{", "}") { (field, value) ->
    "\"$field\":${overrides.firstOrNull { it.first == field }?.second ?: value}"
  }

/** An absent roster is an empty one and a roster spelled `null` is a refusal, so only this can tell them apart. */
private fun bodyWithout(vararg fields: String): String =
  BASE_BODY.filterNot { it.first in fields }.joinToString(",", "{", "}") { (field, value) -> "\"$field\":$value" }

private fun bodyRefusal(json: String, at: Long = NOW): PopopxServerConfigRejection = try {
  PopopxServerConfigBodyParser.parse(json.encodeToByteArray(), at, 0, FIXTURE_KEYS)
  fail("body was accepted: $json")
} catch (e: PopopxServerConfigRefused) {
  e.reason
}

private fun parseBody(json: String, at: Long = NOW) =
  PopopxServerConfigBodyParser.parse(json.encodeToByteArray(), at, 0, FIXTURE_KEYS)

private fun inflateRefusal(data: ByteArray): PopopxServerConfigRejection = try {
  PopopxServerConfigInflator.inflate(data)
  fail("inflated ${data.size} bytes")
} catch (e: PopopxServerConfigRefused) {
  e.reason
}

/** Rows of a roster, so a ceiling test says `11 entries` rather than carrying a hand-written 11-entry literal. */
private fun serverRows(count: Int, host: String): String =
  (1..count).joinToString(",", "[", "]") { """["$SMP_KEY","$host$it.popopx.im"]""" }

class PopopxServerConfigWireTest {
  // MARK: - The three frames the Swift generator minted

  @Test
  fun aFrameMintedByTheRepositorysOwnGeneratorDecodes() {
    val frame = accepted(MINIMAL_FRAME)
    val payload = frame.payload
    assertEquals(FIXTURE_KEY_ID, payload.keyId)
    assertEquals(1L, payload.seq)
    assertEquals(1_795_614_945L, payload.issuedAt)
    assertEquals(EXPIRES_AT, payload.expiresAt)
    assertEquals(0, frame.trustedKeyIndex)
    assertEquals(253, frame.body.size)
    // The generator's own report, quoted back. A hash that disagrees means the body this device reconstructed
    // is not the body that was signed, which is precisely the property a receipt depends on.
    assertEquals("09bf5d6ba8a7754e", frame.bodyHash)
    assertEquals(
      listOf(PopopxServerEntry(SMP_KEY, "smp11.popopx.im", null)),
      payload.smpServers,
    )
    assertTrue(payload.xftpServers.isEmpty())
    assertTrue(payload.notificationServers.isEmpty())
    assertTrue(payload.relays.isEmpty())
    assertTrue(payload.iceServers.isEmpty())
    assertFalse(payload.policy.ack)
    assertEquals(1L, payload.policy.minSeq)
    assertEquals(3_600L, payload.policy.installWindowSeconds)
    assertEquals(100L, payload.policy.rolloutPercent)
    assertEquals(604_800L, payload.policy.ttlSeconds)
  }

  @Test
  fun theFullFrameCarriesEveryRosterKind() {
    val frame = accepted(FULL_FRAME)
    val payload = frame.payload
    assertEquals(7L, payload.seq)
    assertEquals(639, frame.body.size)
    assertEquals("06a413cfe750c6e2", frame.bodyHash)
    assertEquals(2, payload.smpServers.size)
    assertEquals(listOf("smp11.popopx.im", "smp12.popopx.im"), payload.smpServers.map { it.host })
    assertEquals("xftp4.popopx.im", payload.xftpServers.single().host)
    assertEquals("ntf2.popopx.im", payload.notificationServers.single().host)
    assertTrue(payload.policy.ack)
    assertEquals(5L, payload.policy.minSeq)
    assertEquals(7_200L, payload.policy.installWindowSeconds)
    assertEquals(60L, payload.policy.rolloutPercent)

    // The relay row is `[host, key]`, the reverse of a server entry, and the client assembles the address from
    // the parts. An implementation that reused the server reader would swap them and never say so.
    val relay = payload.relays.single()
    assertEquals("relay7.popopx.im", relay.host)
    assertEquals("b0NNz2FODWtHjYGo4LU9p4aMCChepv5wyCbKmiKUQeY", relay.key)

    val ice = payload.iceServers.single()
    assertEquals("turns", ice.scheme)
    assertEquals("turn.popopx.im", ice.host)
    assertEquals(443, ice.port)
    assertEquals("tcp", ice.transport)
    assertEquals("1798206943:cfg-7d", ice.username)
    // The credential stays in its published, padded form: 20 raw bytes of HMAC-SHA1 under standard base64.
    assertEquals("L+Q1QONMKBLJva5uf4ErxrGm7Xc=", ice.credential)
    assertEquals(1_798_206_943L, ice.expiresAt)
  }

  @Test
  fun theRotatedFrameIsANewerGenerationFromTheSameKey() {
    val frame = accepted(ROTATED_FRAME)
    assertEquals(12L, frame.payload.seq)
    assertEquals(FIXTURE_KEY_ID, frame.payload.keyId)
    assertEquals("f1f04e8630821940", frame.bodyHash)
    assertEquals(319, frame.body.size)
    assertEquals("smp13.popopx.im", frame.payload.smpServers.single().host)
    // The rotation the anti-downgrade floor exists for: same `kid`, higher `seq`, one host that was not there
    // in generation 7.
    assertTrue(frame.payload.seq > accepted(FULL_FRAME).payload.seq)
  }

  @Test
  fun bothKeyIdDerivationsStillAgreeWithThePublishedValues() {
    // Two derivations, one property. The fixture key proves the function against a frame the generator signed;
    // the pinned root proves it against the id this repository publishes, which no test key can reproduce.
    assertEquals(FIXTURE_KEY_ID, PopopxServerConfigTrust.keyId(FIXTURE_KEYS.first()))
    assertEquals(
      "k-ad1dc5463a",
      PopopxServerConfigTrust.keyIdFromHex(PopopxServerConfigTrust.signingPublicKeyHexes.first()),
    )
    assertEquals(1, PopopxServerConfigTrust.signingPublicKeys.size)
    assertEquals(32, PopopxServerConfigTrust.signingPublicKeys.first().size)
  }

  // MARK: - The order of the checks

  @Test
  fun theSignatureIsCheckedOverTheReceivedCompressedBytesBeforeAnythingIsInflated() {
    val (compressed, signature) = token(FULL_FRAME)
    val index = compressed.length / 2
    val broken = compressed.take(index) + bump(compressed[index]) + compressed.substring(index + 1)
    // That one character is inside the deflate stream, so the same byte would corrupt the compressed block and
    // its Adler-32 trailer as well. The only reason a correct implementation can therefore name here is the
    // signature: verification runs against the received text and nothing has reached a decompressor yet.
    assertEquals(PopopxServerConfigRejection.SIGNATURE_NOT_VERIFYING, refusal(frame(broken, signature)))
  }

  @Test
  fun aSignatureOfTheRightLengthThatMeansNothingIsRefusedByTheVerifier() {
    val (compressed, _) = token(MINIMAL_FRAME)
    // Eighty-six base64url characters are exactly 64 bytes, so this gets past both length gates and has to be
    // stopped by the math.
    assertEquals(
      PopopxServerConfigRejection.SIGNATURE_NOT_VERIFYING,
      refusal(frame(compressed, "A".repeat(PopopxServerConfigLimits.SIGNATURE_SEGMENT_CHARACTERS))),
    )
  }

  @Test
  fun aFrameSignedByAKeyOutsideTheTrustListDoesNotVerify() {
    val stranger = PopopxServerConfigTrust.decodeKeyHex("0".repeat(63) + "1")
    assertNotNull(stranger)
    // Against the pinned production root, the fixture's own frame is unsigned. This is the direction a real
    // attack comes from: a valid signature from a key nobody endorsed.
    assertEquals(PopopxServerConfigRejection.SIGNATURE_NOT_VERIFYING, refusal(MINIMAL_FRAME, keys = PopopxServerConfigTrust.signingPublicKeys))
    // And a stranger added to the list does not become trusted by being *first* in it.
    assertEquals(PopopxServerConfigRejection.SIGNATURE_NOT_VERIFYING, refusal(MINIMAL_FRAME, keys = listOf(stranger!!)))
    val withBoth = accepted(MINIMAL_FRAME, keys = listOf(stranger!!, FIXTURE_KEYS.first()))
    assertEquals(1, withBoth.trustedKeyIndex)
    // The `kid` check then runs against the key that verified, not against the one that was tried first.
    assertEquals(FIXTURE_KEY_ID, withBoth.payload.keyId)
  }

  @Test
  fun thePrefixIsRequiredAndTheKindIsPartOfIt() {
    assertEquals(PopopxServerConfigRejection.FRAME_PREFIX_MISSING, refusal(MINIMAL_FRAME.replaceFirst("::popopx_sys::", ":popopx_sys::")))
    assertEquals(PopopxServerConfigRejection.FRAME_PREFIX_MISSING, refusal(MINIMAL_FRAME.replace("SERVER_CFG_V1", "SERVER_CFG_V2")))
    assertEquals(PopopxServerConfigRejection.FRAME_PREFIX_MISSING, refusal(MINIMAL_FRAME.lowercase()))
    // Trimming belongs to the suppression test only. The acceptance path refuses a line with anything in front
    // of the prefix, so a padded frame hides rather than installs.
    assertEquals(PopopxServerConfigRejection.FRAME_PREFIX_MISSING, refusal(" $MINIMAL_FRAME"))
    assertTrue(PopopxServerConfigWire.isControlText(" $MINIMAL_FRAME "))
  }

  @Test
  fun theSegmentCeilingIsExactAndCountedInScalars() {
    val segment = FULL_FRAME.drop(PopopxServerConfigWire.CONFIG_PREFIX.length)
    val (compressed, signature) = token(FULL_FRAME)
    // Filled to exactly the ceiling: the frame survives the cap and dies at the verifier, which is the proof
    // that the cap did not fire.
    val atCeiling = frame(compressed + "A".repeat(PopopxServerConfigLimits.MAXIMUM_SEGMENT_CHARACTERS - segment.length), signature)
    assertEquals(PopopxServerConfigLimits.MAXIMUM_SEGMENT_CHARACTERS, PopopxServerConfigHost.scalarCount(atCeiling.drop(PopopxServerConfigWire.CONFIG_PREFIX.length)))
    assertEquals(PopopxServerConfigRejection.SIGNATURE_NOT_VERIFYING, refusal(atCeiling))
    // One scalar more, and the cap names itself instead.
    assertEquals(PopopxServerConfigRejection.SEGMENT_TOO_LONG, refusal(atCeiling + "A"))
    // The reason the ceiling is stated in scalars: an off-BMP character is one to Swift and two `Char`s to
    // Kotlin, so a length measured in UTF-16 units would refuse an honest frame that sits near the cap.
    assertEquals(2, "😀".length)
    assertEquals(1, PopopxServerConfigHost.scalarCount("😀"))
  }

  @Test
  fun theTokenGrammarIsAnchoredAndHasExactlyOneDot() {
    val (compressed, signature) = token(MINIMAL_FRAME)
    val prefix = PopopxServerConfigWire.CONFIG_PREFIX
    val tag = PopopxServerConfigLimits.TOKEN_PREFIX
    assertEquals(PopopxServerConfigRejection.TOKEN_MALFORMED, refusal("$prefix$compressed.$signature"))
    assertEquals(PopopxServerConfigRejection.TOKEN_MALFORMED, refusal("$prefix POPXCFG1-$compressed.$signature"))
    assertEquals(PopopxServerConfigRejection.TOKEN_MALFORMED, refusal(prefix + tag + compressed))
    assertEquals(PopopxServerConfigRejection.TOKEN_MALFORMED, refusal(prefix + tag + "$compressed.$signature.$signature"))
    assertEquals(PopopxServerConfigRejection.TOKEN_MALFORMED, refusal(prefix + tag + ".$signature"))
    assertEquals(PopopxServerConfigRejection.TOKEN_MALFORMED, refusal(prefix + tag + "$compressed."))
    // Padding is outside the alphabet, so a padded token is refused here rather than tolerated by a decoder
    // that accepts it.
    assertEquals(PopopxServerConfigRejection.TOKEN_MALFORMED, refusal(prefix + tag + "$compressed.$signature="))
    assertEquals(PopopxServerConfigRejection.TOKEN_MALFORMED, refusal(prefix + tag + "*${compressed.drop(1)}.$signature"))
    // Folding case is legal, which is worth stating: base64url has both alphabet halves and a
    // verifier that lowercased before decoding would accept a frame nobody signed.
    assertEquals(PopopxServerConfigRejection.SIGNATURE_NOT_VERIFYING, refusal(prefix + tag + "${compressed.lowercase()}.$signature"))
  }

  @Test
  fun theSignatureSegmentIsMeasuredBeforeItIsDecoded() {
    val (compressed, signature) = token(MINIMAL_FRAME)
    assertEquals(86, signature.length)
    assertEquals(PopopxServerConfigRejection.SIGNATURE_SEGMENT_MALFORMED, refusal(frame(compressed, signature.dropLast(2))))
    assertEquals(PopopxServerConfigRejection.SIGNATURE_SEGMENT_MALFORMED, refusal(frame(compressed, signature + "A")))
    // A non-alphabet character at the same length reaches the same gate, because the test is on the segment.
    assertEquals(PopopxServerConfigRejection.TOKEN_MALFORMED, refusal(frame(compressed, signature.dropLast(1) + "=")))
    // One level down, a signature of the wrong byte count never reaches an implementation.
    assertNull(PopopxServerConfigTrust.verify(ByteArray(63), PopopxServerConfigTrust.signatureDomain, FIXTURE_KEYS))
    assertNull(PopopxServerConfigTrust.verify(ByteArray(64), PopopxServerConfigTrust.signatureDomain, FIXTURE_KEYS))
  }

  @Test
  fun expiryIsDeadAtTheSecondItSays() {
    assertEquals(PopopxServerConfigRejection.EXPIRED, refusal(FULL_FRAME, at = EXPIRES_AT))
    assertEquals(PopopxServerConfigRejection.EXPIRED, refusal(FULL_FRAME, at = EXPIRES_AT + 1))
    assertEquals(7L, accepted(FULL_FRAME, at = EXPIRES_AT - 1).payload.seq)
  }

  // MARK: - The container

  @Test
  fun theHeaderGateIsRFC1950sOwnRules() {
    val stream = zlib("hello".encodeToByteArray())
    assertTrue(PopopxServerConfigInflator.hasZlibHeader(stream))
    // Method not 8.
    assertFalse(PopopxServerConfigInflator.hasZlibHeader(byteArrayOf(0x01, 0x01, 0, 0, 0, 0)))
    // Window larger than 32 KiB: the high nibble of the first byte is the window code.
    assertFalse(PopopxServerConfigInflator.hasZlibHeader(byteArrayOf(0x88.toByte(), 0x1D, 0, 0, 0, 0)))
    // A preset dictionary, which this format never uses and which would silently change what the bytes mean.
    assertFalse(PopopxServerConfigInflator.hasZlibHeader(byteArrayOf(0x78, 0x20, 0, 0, 0, 0)))
    // Header checksum not divisible by 31.
    assertFalse(PopopxServerConfigInflator.hasZlibHeader(byteArrayOf(0x78, 0x02, 0, 0, 0, 0)))
    assertEquals(PopopxServerConfigRejection.DEFLATE_HEADER_INVALID, inflateRefusal(byteArrayOf(0x01, 0x01, 0, 0, 0, 0)))
    // Two header bytes and a trailer is the smallest real stream, so five bytes cannot be one at all.
    assertEquals(PopopxServerConfigRejection.DEFLATE_HEADER_INVALID, inflateRefusal(ByteArray(5)))
    // Level 0 emits a different header byte (`78 01`) and stored blocks instead of compressed ones. Demanding
    // the `78 9C` that a level-9 stream carries would refuse an honest frame built by any other encoder, which
    // is exactly what the FLEVEL comment warns about.
    val stored = Deflater(0, false).let {
      it.setInput("level zero".encodeToByteArray())
      it.finish()
      val out = java.io.ByteArrayOutputStream()
      val buffer = ByteArray(64)
      while (!it.finished()) out.write(buffer, 0, it.deflate(buffer))
      it.end()
      out.toByteArray()
    }
    assertEquals(0x78, stored[0].toInt() and 0xFF)
    assertEquals(0x01, stored[1].toInt() and 0xFF)
    assertContentEquals("level zero".encodeToByteArray(), PopopxServerConfigInflator.inflate(stored))
  }

  @Test
  fun aValidStreamRoundTripsAndItsTrailerIsTheBigEndianAdlerValue() {
    val payload = """{"v":1,"enc":"z9","kid":"$FIXTURE_KEY_ID"}""".encodeToByteArray()
    val stream = zlib(payload)
    assertTrue(PopopxServerConfigInflator.inflate(stream).contentEquals(payload))
    assertEquals(
      PopopxServerConfigInflator.adler32(payload, payload.size),
      PopopxServerConfigInflator.bigEndianUInt32(stream, stream.size - 4),
    )
    // The trailer is big-endian, so the same four bytes read little-endian are a different number, and a
    // decoder that trusted the platform's byte order would report a checksum mismatch on every honest frame.
    val trailer = stream.copyOfRange(stream.size - 4, stream.size)
    assertTrue(PopopxServerConfigInflator.bigEndianUInt32(trailer, 0) != littleEndian(trailer))
    assertEquals(-1L, PopopxServerConfigInflator.bigEndianUInt32(trailer, 1))
  }

  private fun littleEndian(bytes: ByteArray): Long {
    var value = 0L
    for ((shift, byte) in bytes.withIndex()) value = value or ((byte.toLong() and 0xFF) shl (8 * shift))
    return value
  }

  @Test
  fun truncatedAndTrailingStreamsAreDifferentRefusals() {
    val text = "the ceiling, the cut line, and a second stream are three different defects"
    val stream = zlib(text.encodeToByteArray())
    assertEquals(PopopxServerConfigRejection.DEFLATE_TRUNCATED, inflateRefusal(stream.copyOf(stream.size / 2)))
    // A stream glued onto the end of a signed one: the first block inflates perfectly, and the leftovers are
    // what makes it a refusal rather than a success.
    assertEquals(PopopxServerConfigRejection.DEFLATE_TRAILING_BYTES, inflateRefusal(stream + byteArrayOf(0x78, 0x9C.toByte(), 0x03, 0x00, 0x00, 0x00, 0x00, 0x01)))
    assertEquals(PopopxServerConfigRejection.DEFLATE_TRAILING_BYTES, inflateRefusal(stream + byteArrayOf(0x00)))
  }

  @Test
  fun aBodyOverTheCeilingIsRefusedAndNoPathReturnsPartialBytes() {
    val bomb = zlib(ByteArray(PopopxServerConfigLimits.MAXIMUM_INFLATED_BYTES * 4))
    assertEquals(PopopxServerConfigRejection.DEFLATE_OVER_CAP, inflateRefusal(bomb))
    // Exactly at the ceiling succeeds: the limit is the number, not something smaller than it.
    val atLimit = zlib(ByteArray(PopopxServerConfigLimits.MAXIMUM_INFLATED_BYTES) { 65 })
    assertEquals(PopopxServerConfigLimits.MAXIMUM_INFLATED_BYTES, PopopxServerConfigInflator.inflate(atLimit).size)
    assertEquals(PopopxServerConfigRejection.DEFLATE_OVER_CAP, inflateRefusal(zlib(ByteArray(PopopxServerConfigLimits.MAXIMUM_INFLATED_BYTES + 1))))
  }

  @Test
  fun aForgedAdlerTrailerIsNamedRatherThanReportedAsACorruptStream() {
    val stream = zlib("checksum".encodeToByteArray())
    val tampered = stream.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 0x01).toByte() }
    assertEquals(PopopxServerConfigRejection.CHECKSUM_MISMATCH, inflateRefusal(tampered))
    // The trailer is the last four bytes only: corrupting the compressed block is a different defect, and the
    // two names are what let an operator tell a cut line from a forgery.
    val bodyCorrupted = stream.copyOf().also { it[3] = (it[3].toInt() xor 0x40).toByte() }
    assertTrue(
      setOf(
        PopopxServerConfigRejection.DEFLATE_FAILED,
        PopopxServerConfigRejection.DEFLATE_TRUNCATED,
        PopopxServerConfigRejection.CHECKSUM_MISMATCH,
      ).contains(inflateRefusal(bodyCorrupted)),
    )
  }

  // MARK: - Body grammar

  @Test
  fun anHonestBodyParses() {
    val frame = parseBody(body())
    assertEquals(3L, frame.payload.seq)
    assertEquals(FIXTURE_KEY_ID, frame.payload.keyId)
    assertEquals(SMP_KEY, frame.payload.smpServers.single().key)
    assertEquals(PopopxServerConfigWire.bodyHash(frame.body), frame.bodyHash)
    assertEquals(body().encodeToByteArray().size, frame.body.size)
  }

  @Test
  fun theVersionAndEncodingComeBeforeEverythingElse() {
    assertEquals(PopopxServerConfigRejection.FORMAT_VERSION_UNSUPPORTED, bodyRefusal(body("v" to "2")))
    assertEquals(PopopxServerConfigRejection.FORMAT_VERSION_UNSUPPORTED, bodyRefusal(body("v" to "\"1\"")))
    assertEquals(PopopxServerConfigRejection.FORMAT_VERSION_UNSUPPORTED, bodyRefusal(body("v" to "1.0")))
    assertEquals(PopopxServerConfigRejection.FORMAT_VERSION_UNSUPPORTED, bodyRefusal(body("v" to "null")))
    assertEquals(PopopxServerConfigRejection.ENCODING_UNKNOWN, bodyRefusal(body("enc" to "\"z8\"")))
    assertEquals(PopopxServerConfigRejection.ENCODING_UNKNOWN, bodyRefusal(body("enc" to "\"Z9\"")))
    assertEquals(PopopxServerConfigRejection.ENCODING_UNKNOWN, bodyRefusal(body("enc" to "null")))
    // A version failure masks the encoding failure behind it, which is what "the first reason propagates" means.
    assertEquals(PopopxServerConfigRejection.FORMAT_VERSION_UNSUPPORTED, bodyRefusal(body("v" to "2", "enc" to "\"z8\"")))
  }

  @Test
  fun theKeyMustBeTheOneThatVerified() {
    assertEquals(PopopxServerConfigRejection.KEY_ID_MALFORMED, bodyRefusal(body("kid" to "\"k-c88d4fd35\"")))
    assertEquals(PopopxServerConfigRejection.KEY_ID_MALFORMED, bodyRefusal(body("kid" to "\"k-C88D4FD35D\"")))
    assertEquals(PopopxServerConfigRejection.KEY_ID_MALFORMED, bodyRefusal(body("kid" to "\"c88d4fd35d\"")))
    assertEquals(PopopxServerConfigRejection.KEY_ID_MALFORMED, bodyRefusal(body("kid" to "\"k-\"")))
    assertEquals(PopopxServerConfigRejection.KEY_ID_MALFORMED, bodyRefusal(body("kid" to "null")))
    assertEquals(PopopxServerConfigRejection.KEY_ID_MISMATCH, bodyRefusal(body("kid" to "\"k-0000000000\"")))
    // An index outside the list cannot name an id, which is the bug an injected key list could otherwise
    // introduce: a frame verified by nothing would still carry a plausible `kid`.
    assertEquals(
      PopopxServerConfigRejection.KEY_ID_MISMATCH,
      try {
        PopopxServerConfigBodyParser.parse(body().encodeToByteArray(), NOW, 1, FIXTURE_KEYS); fail("parsed")
      } catch (e: PopopxServerConfigRefused) {
        e.reason
      },
    )
  }

  @Test
  fun theThreeCountersHaveOneRuleEach() {
    assertEquals(PopopxServerConfigRejection.SEQUENCE_MISSING, bodyRefusal(body("seq" to "0")))
    assertEquals(PopopxServerConfigRejection.SEQUENCE_MISSING, bodyRefusal(body("seq" to "-1")))
    assertEquals(PopopxServerConfigRejection.SEQUENCE_MISSING, bodyRefusal(body("seq" to "${PopopxServerConfigLimits.MAXIMUM_COUNTER_VALUE + 1}")))
    // A double is a different claim about the field, not the same number spelled another way: 3.5 is not a
    // generation, and `true` must never read as generation one.
    assertEquals(PopopxServerConfigRejection.SEQUENCE_MISSING, bodyRefusal(body("seq" to "3.5")))
    assertEquals(PopopxServerConfigRejection.SEQUENCE_MISSING, bodyRefusal(body("seq" to "true")))
    assertEquals(PopopxServerConfigRejection.SEQUENCE_MISSING, bodyRefusal(body("seq" to "\"3\"")))
    assertEquals(PopopxServerConfigRejection.ISSUED_AT_MISSING, bodyRefusal(body("iat" to "0")))
    assertEquals(PopopxServerConfigRejection.EXPIRY_MISSING, bodyRefusal(body("exp" to "0")))
    assertEquals(PopopxServerConfigRejection.EXPIRY_NOT_AFTER_ISSUE, bodyRefusal(body("iat" to "$EXPIRES_AT")))
    assertEquals(PopopxServerConfigRejection.EXPIRY_NOT_AFTER_ISSUE, bodyRefusal(body("iat" to "${EXPIRES_AT + 10}")))
    assertEquals(
      PopopxServerConfigRejection.VALIDITY_SPAN_TOO_LONG,
      bodyRefusal(body("iat" to "${EXPIRES_AT - PopopxServerConfigLimits.MAXIMUM_VALIDITY_SECONDS - 1}")),
    )
    // Thirty days exactly is the longest honest validity, so the ceiling is the number and not its neighbour.
    assertEquals(
      PopopxServerConfigLimits.MAXIMUM_VALIDITY_SECONDS,
      parseBody(body("iat" to "${EXPIRES_AT - PopopxServerConfigLimits.MAXIMUM_VALIDITY_SECONDS}")).payload.expiresAt -
        parseBody(body("iat" to "${EXPIRES_AT - PopopxServerConfigLimits.MAXIMUM_VALIDITY_SECONDS}")).payload.issuedAt,
    )
    assertEquals(PopopxServerConfigRejection.EXPIRED, bodyRefusal(body(), at = EXPIRES_AT))
  }

  @Test
  fun anSmpRosterCannotBeEmptyBecauseThatWouldMeanRemovingEveryServer() {
    assertEquals(PopopxServerConfigRejection.SMP_ROSTER_INVALID, bodyRefusal(body("smp" to "[]")))
    assertEquals(PopopxServerConfigRejection.SMP_ROSTER_INVALID, bodyRefusal(body("smp" to "{}")))
    assertEquals(PopopxServerConfigRejection.SMP_ROSTER_INVALID, bodyRefusal(body("smp" to "\"\"")))
    // `null` is a value and absence is not: a roster the operator left out is empty, and one spelled null is a
    // generator bug this device refuses to guess about.
    assertEquals(PopopxServerConfigRejection.SMP_ROSTER_INVALID, bodyRefusal(body("smp" to "null")))
    assertEquals(PopopxServerConfigRejection.SMP_ROSTER_INVALID, bodyRefusal(bodyWithout("smp")))
    assertEquals(PopopxServerConfigRejection.ENTRY_SHAPE_INVALID, bodyRefusal(body("smp" to "[$SMP_KEY]")))
    assertEquals(
      PopopxServerConfigRejection.SMP_ROSTER_TOO_LARGE,
      bodyRefusal(body("smp" to serverRows(PopopxServerConfigLimits.MAXIMUM_SMP_SERVER_ENTRIES + 1, "smp"))),
    )
    // At the ceiling it is accepted, so the cap is the published number rather than an accident of counting.
    assertEquals(
      PopopxServerConfigLimits.MAXIMUM_SMP_SERVER_ENTRIES,
      parseBody(body("smp" to serverRows(PopopxServerConfigLimits.MAXIMUM_SMP_SERVER_ENTRIES, "smp"))).payload.smpServers.size,
    )
  }

  @Test
  fun theSecondaryRostersHaveTheirOwnCeilingsAndTheirOwnNames() {
    assertEquals(
      PopopxServerConfigRejection.XFTP_ROSTER_TOO_LARGE,
      bodyRefusal(body("xftp" to serverRows(PopopxServerConfigLimits.MAXIMUM_XFTP_SERVER_ENTRIES + 1, "xftp"))),
    )
    assertEquals(
      PopopxServerConfigRejection.NTF_ROSTER_TOO_LARGE,
      bodyRefusal(body("ntf" to serverRows(PopopxServerConfigLimits.MAXIMUM_NOTIFICATION_SERVER_ENTRIES + 1, "ntf"))),
    )
    assertEquals(PopopxServerConfigRejection.XFTP_ROSTER_INVALID, bodyRefusal(body("xftp" to """{"a":1}""")))
    assertEquals(PopopxServerConfigRejection.NTF_ROSTER_INVALID, bodyRefusal(body("ntf" to "\"smp11.popopx.im\"")))
    assertEquals(PopopxServerConfigRejection.RELAY_ROSTER_INVALID, bodyRefusal(body("relay" to """{"a":1}""")))
    assertEquals(PopopxServerConfigRejection.RELAY_ROSTER_INVALID, bodyRefusal(body("relay" to "null")))
    assertEquals(PopopxServerConfigRejection.ICE_ROSTER_INVALID, bodyRefusal(body("ice" to "42")))
    // Absent rosters are empty rather than refused, which is how a cluster ships no TURN servers at all.
    val absent = parseBody(bodyWithout("relay", "ice", "xftp", "ntf"))
    assertTrue(absent.payload.relays.isEmpty() && absent.payload.iceServers.isEmpty())
    assertTrue(absent.payload.xftpServers.isEmpty() && absent.payload.notificationServers.isEmpty())
    assertEquals(1, absent.payload.smpServers.size)
  }

  @Test
  fun anEntryIsTwoOrThreeStringsAndNothingElse() {
    assertEquals(PopopxServerConfigRejection.ENTRY_SHAPE_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY"]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_SHAPE_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","smp11.popopx.im","a","b"]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_SHAPE_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY",44]]""")))
    assertEquals(PopopxServerConfigRejection.SMP_ROSTER_INVALID, bodyRefusal(body("smp" to """{"$SMP_KEY":"smp11.popopx.im"}""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_SHAPE_INVALID, bodyRefusal(body("smp" to """[[]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_KEY_INVALID, bodyRefusal(body("smp" to """[["short","smp11.popopx.im"]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_KEY_INVALID, bodyRefusal(body("smp" to """[["","smp11.popopx.im"]]""")))
    // Sixty-four characters of a padded key is the *other* fingerprint length, and the published rosters carry
    // unpadded ones: `fingerprint` normalizes exactly one `=` away and refuses anything else.
    assertEquals(SMP_KEY, PopopxServerConfigHost.fingerprint("$SMP_KEY="))
    assertNull(PopopxServerConfigHost.fingerprint("$SMP_KEY=="))
    assertNull(PopopxServerConfigHost.fingerprint(SMP_KEY.dropLast(1)))
    // The `+` belongs to standard base64, which is what a copied key arrives as, and it is the one
    // substitution that must not survive into a roster.
    assertNull(PopopxServerConfigHost.fingerprint(SMP_KEY.replace("-", "+")))
    assertEquals(SMP_KEY, PopopxServerConfigHost.fingerprint(SMP_KEY))
    assertEquals(PopopxServerConfigRejection.ENTRY_HOST_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","SMP11.popopx.im"]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_HOST_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","smp11..popopx.im"]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_HOST_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","-smp11.popopx.im"]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_HOST_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","smp11.popopx.im."]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_HOST_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","noplural"]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_HOST_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","smp11_popopx.im"]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_HOST_UNADMITTED, bodyRefusal(body("smp" to """[["$SMP_KEY","smp11.example.com"]]""")))
    // The host a 254-character name reaches: the ceiling is on the whole name, not on a label.
    val long = "a".repeat(247) + ".popopx.im"
    assertEquals(257, long.length)
    assertEquals(PopopxServerConfigRejection.ENTRY_HOST_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","$long"]]""")))
    assertNull(PopopxServerConfigHost.rejection("a".repeat(243) + ".popopx.im"))
  }

  @Test
  fun anOnionAlternateIsAV3AddressOrNothing() {
    val onion = "ad55fgrdvnddijzhfy3f2duhps4ux5bqz3d6b23qj2z3z5blddz63zqd.onion"
    assertEquals(56, onion.dropLast(".onion".length).length)
    assertTrue(PopopxServerConfigHost.isOnion(onion))
    assertNull(PopopxServerConfigHost.rejection(onion))
    assertEquals(
      listOf("smp11.popopx.im", onion),
      parseBody(body("smp" to """[["$SMP_KEY","smp11.popopx.im","$onion"]]""")).payload.smpServers.single().hostnames,
    )
    assertEquals(PopopxServerConfigRejection.ENTRY_ONION_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","smp11.popopx.im","${onion.dropLast(1)}"]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_ONION_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","smp11.popopx.im","abcdefghijklmnop.onion"]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_ONION_INVALID, bodyRefusal(body("smp" to """[["$SMP_KEY","smp11.popopx.im","${onion.uppercase()}"]]""")))
    // The onion is an alternate, never the only name: an onion-only roster would mean the device can only dial
    // over Tor, which the admission rule allows but the grammar test does not forbid. It is admitted, and the
    // probe window decides whether it works.
    assertTrue(PopopxServerConfigHost.isAdmitted(onion))
    assertTrue(PopopxServerConfigHost.isAdmitted("anything.onion"))
  }

  @Test
  fun theRelayRosterChecksItsHostBeforeItsKey() {
    val relay = "b0NNz2FODWtHjYGo4LU9p4aMCChepv5wyCbKmiKUQeY"
    assertEquals(PopopxServerConfigRejection.RELAY_ENTRY_SHAPE_INVALID, bodyRefusal(body("relay" to """[["relay7.popopx.im"]]""")))
    assertEquals(PopopxServerConfigRejection.RELAY_ENTRY_SHAPE_INVALID, bodyRefusal(body("relay" to """[["relay7.popopx.im","$relay","x"]]""")))
    assertEquals(PopopxServerConfigRejection.RELAY_KEY_INVALID, bodyRefusal(body("relay" to """[["relay7.popopx.im","short"]]""")))
    // A relay key is never carried padded, unlike a server fingerprint, so one `=` is a refusal here.
    assertEquals(PopopxServerConfigRejection.RELAY_KEY_INVALID, bodyRefusal(body("relay" to """[["relay7.popopx.im","$relay="]]""")))
    assertEquals(PopopxServerConfigRejection.ENTRY_HOST_UNADMITTED, bodyRefusal(body("relay" to """[["relay7.example.net","$relay"]]""")))
    assertEquals(
      PopopxServerConfigRejection.RELAY_ROSTER_TOO_LARGE,
      bodyRefusal(body("relay" to (1..PopopxServerConfigLimits.MAXIMUM_RELAY_ENTRIES + 1).joinToString(",", "[", "]") { """["relay$it.popopx.im","$relay"]""" })),
    )
  }

  @Test
  fun iceEntriesAreObjectsWithTheirOwnCredentialRules() {
    val credential = "L+Q1QONMKBLJva5uf4ErxrGm7Xc="
    val turn = """{"t":"turns","h":"turn.popopx.im","p":443,"tr":"tcp","u":"1798206943:cfg-7","c":"$credential","x":1798206943}"""
    val parsed = parseBody(body("ice" to "[$turn]")).payload.iceServers.single()
    assertEquals(443, parsed.port)
    assertEquals(credential, parsed.credential)
    assertEquals("tcp", parsed.transport)

    assertEquals(PopopxServerConfigRejection.ICE_ENTRY_SHAPE_INVALID, bodyRefusal(body("ice" to """["turn.popopx.im"]""")))
    assertEquals(PopopxServerConfigRejection.ICE_ENTRY_SHAPE_INVALID, bodyRefusal(body("ice" to """[{"t":"stun","p":3478}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_SCHEME_UNKNOWN, bodyRefusal(body("ice" to """[{"t":"TURN","h":"s.popopx.im","p":3478}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_SCHEME_UNKNOWN, bodyRefusal(body("ice" to """[{"t":"http","h":"s.popopx.im","p":443}]""")))
    // Shape, then scheme, then host, then port: a missing host on a nonsense scheme reports the scheme.
    assertEquals(PopopxServerConfigRejection.ICE_SCHEME_UNKNOWN, bodyRefusal(body("ice" to """[{"t":"x"}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_PORT_INVALID, bodyRefusal(body("ice" to """[{"t":"stun","h":"s.popopx.im","p":0}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_PORT_INVALID, bodyRefusal(body("ice" to """[{"t":"stun","h":"s.popopx.im","p":65536}]""")))
    // The port is mandatory rather than defaulted: a guessed port is the shape that lets a call path fall back.
    assertEquals(PopopxServerConfigRejection.ICE_PORT_INVALID, bodyRefusal(body("ice" to """[{"t":"stun","h":"s.popopx.im"}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_TRANSPORT_UNKNOWN, bodyRefusal(body("ice" to """[{"t":"stun","h":"s.popopx.im","p":3478,"tr":"sctp"}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_CREDENTIALS_NOT_ALLOWED, bodyRefusal(body("ice" to """[{"t":"stun","h":"s.popopx.im","p":3478,"c":"$credential"}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_CREDENTIALS_MISSING, bodyRefusal(body("ice" to """[{"t":"turn","h":"s.popopx.im","p":3478}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_USERNAME_MALFORMED, bodyRefusal(body("ice" to """[{"t":"turn","h":"s.popopx.im","p":3478,"u":"cfg-7","c":"$credential","x":1798206943}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_USERNAME_MALFORMED, bodyRefusal(body("ice" to """[{"t":"turn","h":"s.popopx.im","p":3478,"u":"1798206943:cfg-7:extra","c":"$credential","x":1798206943}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_CREDENTIAL_MALFORMED, bodyRefusal(body("ice" to """[{"t":"turn","h":"s.popopx.im","p":3478,"u":"1798206943:cfg-7","c":"short","x":1798206943}]""")))
    // Twenty raw bytes spelled with the *url-safe* alphabet is the wrong agreement: coturn emits `+/` and the
    // padding, and the credential is recomputed by a third party.
    assertEquals(PopopxServerConfigRejection.ICE_CREDENTIAL_MALFORMED, bodyRefusal(body("ice" to """[{"t":"turn","h":"s.popopx.im","p":3478,"u":"1798206943:cfg-7","c":"________________________","x":1798206943}]""")))
    // Sixteen characters of base64 is 12 raw bytes, which is not HMAC-SHA1.
    assertEquals(PopopxServerConfigRejection.ICE_CREDENTIAL_MALFORMED, bodyRefusal(body("ice" to """[{"t":"turn","h":"s.popopx.im","p":3478,"u":"1798206943:cfg-7","c":"AAAAAAAAAAAAAAAA","x":1798206943}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_EXPIRY_INVALID, bodyRefusal(body("ice" to """[{"t":"turn","h":"s.popopx.im","p":3478,"u":"1798206943:cfg-7","c":"$credential","x":0}]""")))
    assertEquals(PopopxServerConfigRejection.ICE_EXPIRY_INVALID, bodyRefusal(body("ice" to """[{"t":"turn","h":"s.popopx.im","p":3478,"u":"1798206943:cfg-7","c":"$credential","x":true}]""")))
    // An expiry is a claim about a clock, so it is read for `stun` too, and a zero one is refused there as well.
    assertEquals(PopopxServerConfigRejection.ICE_EXPIRY_INVALID, bodyRefusal(body("ice" to """[{"t":"stun","h":"s.popopx.im","p":3478,"x":0}]""")))
    assertEquals(
      PopopxServerConfigRejection.ICE_ROSTER_TOO_LARGE,
      bodyRefusal(body("ice" to (1..PopopxServerConfigLimits.MAXIMUM_ICE_ENTRIES + 1).joinToString(",", "[", "]") { """{"t":"stun","h":"s$it.popopx.im","p":3478}""" })),
    )
  }

  @Test
  fun thePolicyBlockHasNoDefaults() {
    assertEquals(PopopxServerConfigRejection.POLICY_MISSING, bodyRefusal(body("pol" to "null")))
    assertEquals(PopopxServerConfigRejection.POLICY_MISSING, bodyRefusal(body("pol" to "[]")))
    assertEquals(PopopxServerConfigRejection.POLICY_MISSING, bodyRefusal(body("pol" to "\"off\"")))
    assertEquals(PopopxServerConfigRejection.POLICY_ACK_INVALID, bodyRefusal(body("pol" to """{"ms":1,"iw":1,"ro":100,"ttl":1}""")))
    assertEquals(PopopxServerConfigRejection.POLICY_ACK_INVALID, bodyRefusal(body("pol" to """{"ack":"maybe","ms":1,"iw":1,"ro":100,"ttl":1}""")))
    // A truthy number is a different agreement about the field, not another spelling of it.
    assertEquals(PopopxServerConfigRejection.POLICY_ACK_INVALID, bodyRefusal(body("pol" to """{"ack":1,"ms":1,"iw":1,"ro":100,"ttl":1}""")))
    assertEquals(PopopxServerConfigRejection.POLICY_ACK_INVALID, bodyRefusal(body("pol" to """{"ack":"1","ms":1,"iw":1,"ro":100,"ttl":1}""")))
    assertEquals(PopopxServerConfigRejection.POLICY_MIN_SEQ_INVALID, bodyRefusal(body("pol" to """{"ack":"off","ms":0,"iw":1,"ro":100,"ttl":1}""")))
    assertEquals(PopopxServerConfigRejection.POLICY_MIN_SEQ_INVALID, bodyRefusal(body("pol" to """{"ack":"off","iw":1,"ro":100,"ttl":1}""")))
    assertEquals(PopopxServerConfigRejection.POLICY_INSTALL_WINDOW_INVALID, bodyRefusal(body("pol" to """{"ack":"off","ms":1,"ro":100,"ttl":1}""")))
    assertEquals(PopopxServerConfigRejection.POLICY_ROLLOUT_INVALID, bodyRefusal(body("pol" to """{"ack":"off","ms":1,"iw":1,"ttl":1}""")))
    assertEquals(PopopxServerConfigRejection.POLICY_ROLLOUT_INVALID, bodyRefusal(body("pol" to """{"ack":"off","ms":1,"iw":1,"ro":101,"ttl":1}""")))
    // Zero is refused on both platforms: iOS reads `ro` through the same counter that requires one, so a
    // "roll out to nobody" frame is not expressible in this format. That is the generator's rule, quoted.
    assertEquals(PopopxServerConfigRejection.POLICY_TTL_INVALID, bodyRefusal(body("pol" to """{"ack":"off","ms":1,"iw":1,"ro":100,"ttl":0}""")))
    assertEquals(PopopxServerConfigRejection.POLICY_TTL_INVALID, bodyRefusal(body("pol" to """{"ack":"off","ms":1,"iw":1,"ro":100}""")))
    // Both real spellings of `ack`, and the long form of the install window the generator also emits.
    assertTrue(parseBody(body("pol" to """{"ack":true,"ms":1,"iw":1,"ro":100,"ttl":1}""")).payload.policy.ack)
    assertFalse(parseBody(body("pol" to """{"ack":false,"ms":1,"iw":1,"ro":100,"ttl":1}""")).payload.policy.ack)
    assertEquals(
      4_321L,
      parseBody(body("pol" to """{"ack":"on","ms":1,"install_window":4321,"ro":100,"ttl":1}""")).payload.policy.installWindowSeconds,
    )
    assertEquals(
      PopopxServerConfigRejection.POLICY_ROLLOUT_INVALID,
      bodyRefusal(body("pol" to """{"ack":"off","ms":1,"iw":1,"ro":0,"ttl":1}""")),
    )
  }

  @Test
  fun unknownFieldsAreIgnoredAndAMissingOneIsNot() {
    val withExtra = body().removeSuffix("}") + ""","future":{"also":"ignored"},"another":42}"""
    assertEquals(3L, parseBody(withExtra).payload.seq)
    // `ignoreUnknownKeys` is set on the parser and the reader takes its own names, so a renamed field is a
    // missing field rather than a guess.
    assertEquals(PopopxServerConfigRejection.POLICY_MISSING, bodyRefusal(body().replace("\"pol\":", "\"policy\":")))
    assertEquals(PopopxServerConfigRejection.SMP_ROSTER_INVALID, bodyRefusal(body().replace("\"smp\":", "\"smpServers\":")))
  }

  @Test
  fun aBodyThatIsNotAnObjectDiesAtTheFirstStep() {
    assertEquals(PopopxServerConfigRejection.BODY_NOT_JSON, bodyRefusal("not json at all"))
    assertEquals(PopopxServerConfigRejection.BODY_NOT_JSON, bodyRefusal(""))
    assertEquals(PopopxServerConfigRejection.BODY_NOT_JSON, bodyRefusal("{"))
    assertEquals(PopopxServerConfigRejection.BODY_NOT_JSON, bodyRefusal("""{"v":1,}"""))
    assertEquals(PopopxServerConfigRejection.BODY_NOT_OBJECT, bodyRefusal("[1,2,3]"))
    assertEquals(PopopxServerConfigRejection.BODY_NOT_OBJECT, bodyRefusal("\"a string\""))
    assertEquals(PopopxServerConfigRejection.BODY_NOT_OBJECT, bodyRefusal("null"))
    assertEquals(PopopxServerConfigRejection.BODY_NOT_OBJECT, bodyRefusal("42"))
  }

  @Test
  fun theStrictParserRefusesWhatALenientOneWouldTolerate() {
    // `isLenient = false` is what keeps a bare token, a comment and single quotes out of the grammar. A frame
    // whose body parsed leniently would be a body nobody signed.
    assertEquals(PopopxServerConfigRejection.BODY_NOT_JSON, bodyRefusal("{'v':1}"))
    assertEquals(PopopxServerConfigRejection.BODY_NOT_JSON, bodyRefusal("{v:1}"))
    // A float that equals one is still a different literal, and the reader takes the exact integer text.
    assertEquals(PopopxServerConfigRejection.FORMAT_VERSION_UNSUPPORTED, bodyRefusal(body("v" to "1e0")))
    assertFalse(PopopxServerConfigField.isBase64UrlChar('='))
    assertTrue(PopopxServerConfigField.isStandardBase64Char('='))
  }

  // MARK: - Suppression and receipts

  @Test
  fun theSuppressionTestIsShapeOnlyAndNeverConsultsAKey() {
    assertTrue(PopopxServerConfigWire.isControlText(MINIMAL_FRAME))
    assertTrue(PopopxServerConfigWire.isControlText(PopopxServerConfigWire.ACK_PREFIX + "7::06a413cfe750c6e2"))
    assertTrue(PopopxServerConfigWire.isControlText(PopopxServerConfigWire.ACK_PREFIX + "7"))
    // The whole reason this test exists: a line that fails every other check in this file is still hidden.
    assertTrue(PopopxServerConfigWire.isControlText(PopopxServerConfigWire.CONFIG_PREFIX + "garbage"))
    assertTrue(PopopxServerConfigWire.isControlText(PopopxServerConfigWire.CONFIG_PREFIX + "x".repeat(4_000)))
    assertTrue(PopopxServerConfigWire.isControlText(PopopxServerConfigWire.CONFIG_PREFIX + "::::"))
    assertFalse(PopopxServerConfigWire.isControlText("$MINIMAL_FRAME $MINIMAL_FRAME"))
    assertFalse(PopopxServerConfigWire.isControlText("hello"))
    assertFalse(PopopxServerConfigWire.isControlText("::popopx_sys::SERVER_CFG_V9::x"))
    assertFalse(PopopxServerConfigWire.isControlText("::popopx_sys::SERVER_CFG_ACK::7 8"))
    assertFalse(PopopxServerConfigWire.isControlText(PopopxServerConfigWire.MARKER))
    assertFalse(PopopxServerConfigWire.isControlText(""))
    // The two kinds share a marker but never a prefix, so a receipt cannot be mistaken for an instruction.
    assertFalse(PopopxServerConfigWire.isControlText(PopopxServerConfigWire.ACK_KIND))
    assertEquals(PopopxServerConfigRejection.FRAME_PREFIX_MISSING, refusal(PopopxServerConfigWire.ACK_PREFIX + "7"))
  }

  @Test
  fun theReceiptGrammarCarriesOnlyFacts() {
    assertEquals("::popopx_sys::SERVER_CFG_ACK::7", PopopxServerConfigWire.ackFrame(7, null))
    assertEquals("::popopx_sys::SERVER_CFG_ACK::7::06a413cfe750c6e2", PopopxServerConfigWire.ackFrame(7, "06a413cfe750c6e2"))
    assertNull(PopopxServerConfigWire.ackFrame(0, null))
    assertNull(PopopxServerConfigWire.ackFrame(-1, null))
    assertNull(PopopxServerConfigWire.ackFrame(PopopxServerConfigLimits.MAXIMUM_COUNTER_VALUE + 1, null))
    assertNull(PopopxServerConfigWire.ackFrame(7, "06a413cfe750c6e"))
    assertNull(PopopxServerConfigWire.ackFrame(7, "06a413cfe750c6e22"))
    assertNull(PopopxServerConfigWire.ackFrame(7, "06a413cfe750c6eZ"))
    assertTrue(PopopxServerConfigWire.isControlText(PopopxServerConfigWire.ackFrame(7, "06a413cfe750c6e2")!!))
  }

  @Test
  fun theBodyHashIsTheGeneratorsRecipeAndNotAFunctionOfThisParser() {
    assertEquals(16, PopopxServerConfigWire.bodyHash("".encodeToByteArray()).length)
    // A value anyone can check without this repository: SHA-256 of the empty string begins e3b0c44298fc1c14.
    assertEquals("e3b0c44298fc1c14", PopopxServerConfigWire.bodyHash(ByteArray(0)))
    assertTrue(PopopxServerConfigWire.bodyHash("x".encodeToByteArray()).all { PopopxServerConfigField.isHex(it.toString()) })
    // And the same function reproduces the hash the generator reported for the full fixture body, which is the
    // half that says the two implementations hash the *same* bytes.
    assertEquals("06a413cfe750c6e2", PopopxServerConfigWire.bodyHash(accepted(FULL_FRAME).body))
  }
}
