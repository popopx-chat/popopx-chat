package chat.popopx.app.invite

import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.invite.PopopxOpaqueInviteCodec
import chat.popopx.common.invite.PopopxOpaqueInviteError
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV

// Cross-language conformance for the /i/v1/ invite codec, JVM side.
//
// PopopxOpaqueInviteVectors.kt is generated from the gateway's and Bot Studio's published vector
// files, so these are the same expectations the Swift suite asserts on iOS. The byte-exact sealing
// cases are the reason this file exists: an app link the gateway refuses to open is a broken share
// path that no CI run in this repository can see from the client side.

private typealias Codec = PopopxOpaqueInviteCodec
private typealias Vector = PopopxOpaqueInviteVector

class PopopxOpaqueInviteCodecTest {

  private val published: List<Vector> =
    PopopxOpaqueInviteVectors.suite + PopopxOpaqueInviteVectors.studio + listOf(PopopxOpaqueInviteVectors.rejectedSMP)

  private val sealable: List<Vector> = PopopxOpaqueInviteVectors.suite + PopopxOpaqueInviteVectors.studio

  /** Seal an arbitrary payload with the format key, so a test can hand the opener something that
   * authenticates but must still be refused. */
  private fun rawEnvelope(payload: String, nonce: ByteArray): String {
    val engine = ChaCha20Poly1305()
    engine.init(true, ParametersWithIV(KeyParameter(Codec.formatKey), nonce))
    engine.processAADBytes(Codec.AAD, 0, Codec.AAD.size)
    val input = payload.toByteArray(Charsets.UTF_8)
    val out = ByteArray(input.size + 16)
    val written = engine.processBytes(input, 0, input.size, out, 0)
    val total = written + engine.doFinal(out, written)
    return Codec.base64Url(nonce + out.copyOfRange(0, total))
  }

  /** Flips one bit of the tag, not one base64 character: the last digit can carry discarded padding
   * bits, which would make a character swap a vacuous tamper test. */
  private fun flipTagBit(code: String): String {
    val raw = checkNotNull(Codec.base64UrlDecode(code)) { "vector code did not decode" }
    raw[raw.size - 1] = (raw[raw.size - 1].toInt() xor 1).toByte()
    return Codec.base64Url(raw)
  }

  private fun expect(reason: (Exception) -> Boolean, block: () -> Unit, label: String) {
    try {
      block()
      throw AssertionError("$label: expected a refusal, got a result")
    } catch (e: PopopxOpaqueInviteError) {
      assertTrue(reason(e), "$label: got ${e.message}")
    }
  }

  @Test
  fun publishedKeyDerivesFromPublishedInputs() {
    val derived = Codec.hkdfSha256(
      Codec.hexToBytes(PopopxOpaqueInviteVectors.ikmHex),
      PopopxOpaqueInviteVectors.salt.toByteArray(Charsets.UTF_8),
      PopopxOpaqueInviteVectors.info.toByteArray(Charsets.UTF_8),
      32
    )
    assertEquals(PopopxOpaqueInviteVectors.keyHex, hexEncode(derived))
    assertSameBytes(derived, Codec.formatKey)
    assertEquals(PopopxOpaqueInviteVectors.linkPrefix, Codec.LINK_PREFIX)
    assertEquals(25, PopopxOpaqueInviteVectors.linkPrefix.length)
  }

  @Test
  fun rfc5869Case1SurvivesThePort() {
    val v = PopopxOpaqueInviteVectors.hkdfCase1
    val out = Codec.hkdfSha256(
      Codec.hexToBytes(v.ikmHex), Codec.hexToBytes(v.saltHex), Codec.hexToBytes(v.infoHex), v.length
    )
    assertEquals(v.length, out.size)
    assertEquals(v.okmHex, hexEncode(out))
  }

  @Test
  fun rfc8439Section282SealsToThePublishedBytes() {
    val v = PopopxOpaqueInviteVectors.chachaCase
    val key = Codec.hexToBytes(v.keyHex)
    val nonce = Codec.hexToBytes(v.nonceHex)
    assertEquals(32, key.size)
    assertEquals(Codec.NONCE_BYTES, nonce.size)
    val engine = ChaCha20Poly1305()
    engine.init(true, ParametersWithIV(KeyParameter(key), nonce))
    engine.processAADBytes(Codec.hexToBytes(v.aadHex), 0, v.aadHex.length / 2)
    val input = v.plaintext.toByteArray(Charsets.UTF_8)
    val out = ByteArray(input.size + 16)
    val written = engine.processBytes(input, 0, input.size, out, 0)
    val total = written + engine.doFinal(out, written)
    val sealed = out.copyOfRange(0, total)
    assertEquals(v.ciphertextHex, hexEncode(sealed.copyOfRange(0, sealed.size - 16)))
    assertEquals(v.tagHex, hexEncode(sealed.copyOfRange(sealed.size - 16, sealed.size)))
  }

  @Test
  fun everyPublishedVectorSealsByteExactly() {
    for (vector in sealable) {
      val nonce = Codec.hexToBytes(vector.nonceHex)
      assertEquals(Codec.NONCE_BYTES, nonce.size, "${vector.name}: nonce did not decode")
      val sealed = checkNotNull(Codec.sealedBytes(vector.plaintext, nonce)) { "${vector.name}: seal refused" }
      assertEquals(vector.sealedB64URL, Codec.base64Url(sealed), vector.name)
      assertEquals(vector.link, Codec.linkFor(vector.plaintext, nonce), vector.name)
    }
  }

  @Test
  fun everyPublishedLinkOpensToItsPlaintext() {
    assertEquals(6, published.size)
    for (vector in published) {
      assertEquals(vector.plaintext, Codec.uriFromLink(vector.link), vector.name)
      assertEquals(vector.plaintext, Codec.uriIfOpaqueLink(vector.link), vector.name)
    }
  }

  @Test
  fun legacySchemeIsSealedByNobodyIncludingUs() {
    val legacy = PopopxOpaqueInviteVectors.rejectedSMP.plaintext
    assertTrue(legacy.startsWith("smp://"))
    assertNull(Codec.linkFor(legacy))
    expect({ e: Exception -> e === PopopxOpaqueInviteError.UriSchemeInvalid },
      { Codec.sealCode(legacy) }, "sealing an smp:// address")
  }

  @Test
  fun sealingRefusesWhatTheGatewayRefuses() {
    val refusals = listOf(
      Triple("", PopopxOpaqueInviteError.EmptyURI, "empty"),
      Triple("popopx.chat/i/v1/x", PopopxOpaqueInviteError.UriSchemeInvalid, "no scheme"),
      Triple("javascript:alert(1)", PopopxOpaqueInviteError.UriSchemeInvalid, "script scheme"),
      Triple("SMP://smp1.popopx.im/a", PopopxOpaqueInviteError.UriSchemeInvalid, "upper-case scheme"),
      Triple(" https://popopx.chat/i/v1/x", PopopxOpaqueInviteError.UriNotPlain, "leading space"),
      Triple("https://popopx.chat/i/v1/x ", PopopxOpaqueInviteError.UriNotPlain, "trailing space"),
      Triple("https://popopx.chat/a\tb", PopopxOpaqueInviteError.UriNotPlain, "interior tab"),
      Triple("https://popopx.chat/a\nb", PopopxOpaqueInviteError.UriNotPlain, "interior newline")
    )
    for ((uri, failure, label) in refusals) {
      expect({ e: Exception -> e === failure }, { Codec.sealCode(uri) }, label)
    }
    expect({ e: Exception -> e === PopopxOpaqueInviteError.CodeLengthInvalid },
      { Codec.sealCode("https://x.test/a", ByteArray(11)) }, "short nonce")
  }

  @Test
  fun sealCeilingMatchesTheGatewayAndIsInclusive() {
    val head = "https://popopx.chat/"
    val atLimit = head + "a".repeat(Codec.MAX_SEAL_PLAINTEXT_BYTES - head.length)
    assertEquals(Codec.MAX_SEAL_PLAINTEXT_BYTES, atLimit.toByteArray(Charsets.UTF_8).size)
    assertTrue(Codec.linkFor(atLimit) != null)
    expect({ e: Exception -> e is PopopxOpaqueInviteError.UriTooLong && e.bytes == 2049 && e.limit == 2048 },
      { Codec.sealCode(atLimit + "a") }, "one byte past the seal ceiling")
  }

  @Test
  fun openCeilingIsWiderThanTheSealCeilingByRuling() {
    val head = "https://popopx.chat/"
    val zeroNonce = ByteArray(Codec.NONCE_BYTES)
    assertTrue(Codec.MAX_OPEN_PLAINTEXT_BYTES > Codec.MAX_SEAL_PLAINTEXT_BYTES)

    val wide = head + "a".repeat(Codec.MAX_OPEN_PLAINTEXT_BYTES - head.length)
    assertNull(Codec.linkFor(wide))
    assertEquals(wide, Codec.uriFromLink(Codec.LINK_PREFIX + rawEnvelope(wide, zeroNonce)))

    val beyond = head + "a".repeat(Codec.MAX_OPEN_PLAINTEXT_BYTES + 1 - head.length)
    expect({ e: Exception -> e === PopopxOpaqueInviteError.CodeLengthInvalid },
      { Codec.uriFromLink(Codec.LINK_PREFIX + rawEnvelope(beyond, zeroNonce)) }, "past the open ceiling")
  }

  @Test
  fun tolerantOpeningReadsLegacyAndNodePayloadsButNotAddresses() {
    val zeroNonce = ByteArray(Codec.NONCE_BYTES)
    val legacy = PopopxOpaqueInviteVectors.rejectedSMP.plaintext
    assertEquals(legacy, Codec.uriFromLink(Codec.LINK_PREFIX + rawEnvelope(legacy, zeroNonce)))

    val pairing = "PPXNODE1-" + "Q".repeat(96) + "." + "R".repeat(48)
    assertEquals(pairing, Codec.uriFromLink(Codec.LINK_PREFIX + rawEnvelope(pairing, zeroNonce)))
    assertTrue(Codec.SEALABLE_SCHEMES.none { pairing.startsWith(it) })

    for (trap in listOf("javascript:alert(1)", "data:text/html,<script>", "<img src=x onerror=1>", " https://popopx.chat/a")) {
      expect({ e: Exception -> e === PopopxOpaqueInviteError.Tampered },
        { Codec.uriFromLink(Codec.LINK_PREFIX + rawEnvelope(trap, zeroNonce)) }, "payload $trap")
    }
    expect({ e: Exception -> e === PopopxOpaqueInviteError.CodeLengthInvalid },
      { Codec.uriFromLink(Codec.LINK_PREFIX + rawEnvelope("", zeroNonce)) }, "empty payload")
  }

  @Test
  fun damagedEnvelopesNeverYieldAnAddress() {
    val vector = published.first()
    assertEquals(vector.plaintext, Codec.uriFromLink(vector.link))

    val flipped = flipTagBit(vector.sealedB64URL)
    assertNotEquals(vector.sealedB64URL, flipped)
    expect({ e: Exception -> e === PopopxOpaqueInviteError.Tampered },
      { Codec.uriFromLink(Codec.LINK_PREFIX + flipped) }, "flipped tag bit")

    expect({ e: Exception -> e === PopopxOpaqueInviteError.Tampered },
      { Codec.uriFromLink(vector.link + "A") }, "one extra character")
    expect({ e: Exception -> e === PopopxOpaqueInviteError.CodeLengthInvalid },
      { Codec.uriFromLink(vector.link.dropLast(90)) }, "truncated code")
    expect({ e: Exception -> e === PopopxOpaqueInviteError.CodeLengthInvalid },
      { Codec.uriFromLink(Codec.LINK_PREFIX) }, "empty code")
    expect({ e: Exception -> e === PopopxOpaqueInviteError.CodeNotBase64URL },
      { Codec.uriFromLink(Codec.LINK_PREFIX + "****") }, "non-alphabet characters")
    expect({ e: Exception -> e === PopopxOpaqueInviteError.CodeNotBase64URL },
      { Codec.uriFromLink(Codec.LINK_PREFIX + "ab=c") }, "padding inside the code")
    expect({ e: Exception -> e === PopopxOpaqueInviteError.CodeNotBase64URL },
      { Codec.uriFromLink(Codec.LINK_PREFIX + vector.sealedB64URL.replace('-', '+')) }, "standard alphabet")
    expect({ e: Exception -> e === PopopxOpaqueInviteError.LinkPrefixInvalid },
      { Codec.uriFromLink("https://popopx.chat." + vector.sealedB64URL) }, "the dot form")
    expect({ e: Exception -> e === PopopxOpaqueInviteError.LinkPrefixInvalid },
      { Codec.uriFromLink("https://example.test/i/v1/" + vector.sealedB64URL) }, "foreign host")
  }

  @Test
  fun shapeCheckRefusesNearMisses() {
    for (vector in sealable) assertTrue(Codec.looksLikeOpaqueLink(vector.link), vector.name)
    val code = Codec.substringOfLink(PopopxOpaqueInviteVectors.suite.first().link)
    assertTrue(!Codec.looksLikeOpaqueLink(code), "a bare code is not a link")
    assertTrue(!Codec.looksLikeOpaqueLink("https://popopx.chat." + code), "the dot form is not a link")
    assertTrue(!Codec.looksLikeOpaqueLink("https://popopx.chat/i/v2/" + code), "v1 does not claim v2")
    assertTrue(!Codec.looksLikeOpaqueLink(Codec.LINK_PREFIX), "an empty code is not an invite")
  }

  @Test
  fun linkPrefixSpellings() {
    // Spelled out here rather than read from `Codec.OPEN_LINK_PREFIXES`: a loop over the production
    // list passes when that list shrinks to one entry, which is the exact regression this catches.
    val expected = listOf("https://popopx.chat/i/v1/", "popopx:/i/v1/", "popopx://popopx.chat/i/v1/")
    assertEquals(expected, Codec.OPEN_LINK_PREFIXES)
    val vector = PopopxOpaqueInviteVectors.suite.first()
    val code = Codec.substringOfLink(vector.link)
    for (prefix in expected) {
      val link = prefix + code
      assertTrue(Codec.looksLikeOpaqueLink(link), "prefix $prefix not read")
      assertEquals(vector.plaintext, Codec.uriFromLink(link))
    }
    // Reading three spellings must not mean writing three: the servers publish one.
    assertEquals(Codec.LINK_PREFIX, Codec.OPEN_LINK_PREFIXES.first())
    assertTrue(checkNotNull(Codec.linkFor(vector.plaintext)).startsWith(Codec.LINK_PREFIX))
    assertTrue(!Codec.looksLikeOpaqueLink("popopx:/i/v2/" + code))
    assertTrue(!Codec.looksLikeOpaqueLink("popopx://popopx.chat." + code))
    expect({ e: Exception -> e === PopopxOpaqueInviteError.LinkPrefixInvalid },
      { Codec.uriFromLink("popopx:/invitation/" + code) }, "a scheme-carried code under another path")
  }

  @Test
  fun freshNoncesMakeDifferentLinks() {
    val uri = PopopxOpaqueInviteVectors.suite.first().plaintext
    val a = checkNotNull(Codec.linkFor(uri))
    val b = checkNotNull(Codec.linkFor(uri))
    assertNotEquals(a, b, "a fixed nonce would make every share of an address comparable")
    assertEquals(uri, Codec.uriFromLink(a))
    assertEquals(uri, Codec.uriFromLink(b))
  }

  @Test
  fun strictBase64UrlReaderAcceptsOnlyTheWireAlphabet() {
    assertSameBytes(byteArrayOf(0), Codec.base64UrlDecode("AA"))
    assertTrue(Codec.base64UrlDecode("A-_8") != null)
    assertNull(Codec.base64UrlDecode("AAAAA"))
    assertNull(Codec.base64UrlDecode(""))
    assertNull(Codec.base64UrlDecode("A"))
    assertNull(Codec.base64UrlDecode("AA=="))
    assertNull(Codec.base64UrlDecode("AA/+"))
    assertNull(Codec.base64UrlDecode("AAé"))
  }

  @Test
  fun malformedHexReadsEmptyInsteadOfHalfAKey() {
    assertEquals(32, Codec.hexToBytes(PopopxOpaqueInviteVectors.ikmHex).size)
    assertTrue(Codec.hexToBytes("").isEmpty())
    assertTrue(Codec.hexToBytes("abc").isEmpty(), "an odd length is a typo, not a truncated byte")
    assertTrue(Codec.hexToBytes("zz").isEmpty())
    assertTrue(Codec.hexToBytes("d1 abb").isEmpty())
  }
}

private fun assertSameBytes(expected: ByteArray?, actual: ByteArray?) {
  assertTrue(expected.contentEquals(actual ?: ByteArray(0)), "byte arrays differ")
}
