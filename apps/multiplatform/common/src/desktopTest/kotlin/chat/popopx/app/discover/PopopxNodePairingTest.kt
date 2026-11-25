package chat.popopx.app.discover

import chat.popopx.common.crypto.base64UrlEncode
import chat.popopx.common.crypto.ed25519PublicKey
import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.discover.PopopxDiscoverCopy
import chat.popopx.common.discover.PopopxDiscoverLimits
import chat.popopx.common.discover.PopopxMacNodeBinding
import chat.popopx.common.discover.PopopxNodePairing
import chat.popopx.common.discover.PopopxPairingAccept
import chat.popopx.common.discover.PopopxPairingRejection
import chat.popopx.common.discover.PopopxPairingVerdict
import chat.popopx.common.discover.popopxShortDigest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Pairing (DiscoverCatalogModels.swift:560-681, MacNodePairingSheet.swift:179-198).
//
// The CryptoKit-signed vectors are the load-bearing ones: they prove this Kotlin verifies the same
// preimage (the DECODED JSON bytes) against the same key (the body's own declaration) that iOS
// produces and accepts — and that the two classic wrong choices (verify the base64 TEXT; verify
// against any key) are refused.

class PopopxNodePairingTest {
  /** A wall-clock moment inside the pinned offer's 900 s window. */
  private val midWindowMs = DiscoverSwiftVectors.IAT_SECONDS * 1_000L + 450_000L

  @Test
  fun cryptoKitVectorVerifiesHereAndFieldsConvertSecondsToMillis() {
    val offer = assertNotNull(PopopxNodePairing.parse(DiscoverSwiftVectors.GOOD_OFFER))
    assertEquals(DiscoverSwiftVectors.GOOD_OFFER.trim(), offer.code)
    assertEquals("ppx-mac-7f3a9c21", offer.nodeId)
    assertEquals(DiscoverSwiftVectors.PUB_BASE64URL, offer.publicKeyBase64URL)
    assertEquals("popopx://invite?one-time=Kf3mQ8xR2v", offer.link)
    assertEquals(1, offer.schemaRevision) // "v"
    assertTrue(offer.singleUse) // "once"
    // SECONDS on the wire, MILLIS in the model (:586-589).
    assertEquals(DiscoverSwiftVectors.IAT_SECONDS * 1_000L, offer.issuedAtMs)
    assertEquals(DiscoverSwiftVectors.EXP_SECONDS * 1_000L, offer.expiresAtMs)
    assertEquals(900L, offer.lifetimeSeconds)
    assertEquals(900L, PopopxDiscoverLimits.PAIRING_OFFER_LIFETIME_SECONDS)
    // The pinned pub hex is what both platforms derive from the pinned seed.
    assertEquals(DiscoverSwiftVectors.ED25519_PUB_HEX, hexEncode(checkNotNull(ed25519PublicKey(discoverSeed))))
    assertEquals(DiscoverSwiftVectors.PUB_BASE64URL, base64UrlEncode(checkNotNull(ed25519PublicKey(discoverSeed))))
  }

  @Test
  fun liveWithinTheWindowAcceptedAndEdgesPinned() {
    // isLive semantics (:552-555): lower bound INCLUSIVE, upper EXCLUSIVE — the expiry instant
    // itself is stale. 899 s after issue still lives; 900 s does not.
    val t0 = 1_700_000_000_000L
    val code = liveOfferCode(t0, lifetimeSeconds = 900L)
    assertTrue(verdictAt(code, t0) is PopopxPairingVerdict.Accepted)
    assertTrue(verdictAt(code, t0 + 899_000L) is PopopxPairingVerdict.Accepted)
    assertEquals(PopopxPairingRejection.OFFER_STALE, rejectAt(code, t0 + 900_000L))
    assertEquals(PopopxPairingRejection.OFFER_STALE, rejectAt(code, t0 + 901_000L))

    // Future-issued: the Mac's clock ran ahead of ours; still not acceptable.
    val future = signedOfferCode(offerBody(iatSeconds = t0 / 1_000L + 10L, expSeconds = t0 / 1_000L + 910L))
    assertEquals(PopopxPairingRejection.OFFER_NOT_YET_VALID, rejectAt(future, t0))
    assertTrue(verdictAt(future, t0 + 10_000L) is PopopxPairingVerdict.Accepted)
  }

  @Test
  fun wrongTextSignatureIsRefused() {
    // The base64-TEXT trap: a genuine CryptoKit signature over the wrong bytes. If this port ever
    // verifies `bodyPart` instead of `bodyBytes`, this vector starts PASSING — that is its purpose.
    assertNull(PopopxNodePairing.parse(DiscoverSwiftVectors.WRONG_PREIMAGE_OFFER))
    assertEquals(PopopxPairingRejection.SIGNATURE_INVALID, rejectAt(DiscoverSwiftVectors.WRONG_PREIMAGE_OFFER, midWindowMs))
  }

  @Test
  fun wrongKeySignatureIsRefusedAndOnlyTheGenericNoticeShows() {
    assertNull(PopopxNodePairing.parse(DiscoverSwiftVectors.WRONG_KEY_OFFER))
    assertEquals(PopopxPairingRejection.SIGNATURE_INVALID, rejectAt(DiscoverSwiftVectors.WRONG_KEY_OFFER, midWindowMs))
    // The anti-oracle contract: every failure collapses to the ONE sentence, and nothing is stored.
    val settings = discoverSettings()
    val clock = DiscoverClock(midWindowMs)
    val engine = discoverEngine(settings, clock)
    val accept = engine.acceptPastedCode(DiscoverSwiftVectors.WRONG_KEY_OFFER)
    assertEquals(PopopxPairingAccept.Rejected, accept)
    assertEquals(
      "That code is not a current Mac node credential",
      PopopxDiscoverCopy.GENERIC_PAIRING_NOTICE,
    )
    assertEquals(
      PopopxDiscoverCopy.GENERIC_PAIRING_NOTICE,
      (accept as PopopxPairingAccept.Rejected).userNotice,
    )
    assertNull(engine.binding)
  }

  @Test
  fun malformedInputsGetTheirOwnInternalReasons() {
    val t0 = 1_700_000_000_000L
    val live = liveOfferCode(t0)
    assertEquals(PopopxPairingRejection.NOT_OFFER_SYNTAX, rejectAt("hello", t0))
    assertEquals(PopopxPairingRejection.NOT_OFFER_SYNTAX, rejectAt("PPXNODE1-", t0))
    assertEquals(PopopxPairingRejection.NOT_OFFER_SYNTAX, rejectAt("PPXNODE1-noDotHere", t0))
    assertEquals(PopopxPairingRejection.NOT_OFFER_SYNTAX, rejectAt("PPXNODE1-." + live.substringAfter('.'), t0))
    assertEquals(PopopxPairingRejection.BODY_UNDECODABLE, rejectAt("PPXNODE1-!!!notbase64!!!.AAAA", t0))
    assertEquals(PopopxPairingRejection.BODY_UNDECODABLE, rejectAt("PPXNODE1-${base64UrlEncode("[1,2,3]".encodeToByteArray())}.AAAA", t0))
    assertEquals(PopopxPairingRejection.SIGNATURE_INVALID, rejectAt("PPXNODE1-${live.substringAfter("PPXNODE1-").substringBefore('.')}.!!!notbase64!!!", t0))

    // Field-level failures, each signed so the signature is NOT the reason.
    val noNode = signedOfferCode(offerBody(iatSeconds = t0 / 1_000L, expSeconds = t0 / 1_000L + 900L).replace("\"node\":\"ppx-mac-test-1\",", ""))
    assertEquals(PopopxPairingRejection.FIELD_INVALID, rejectAt(noNode, t0))
    val quotedIat = signedOfferCode(offerBody(iatSeconds = t0 / 1_000L, expSeconds = t0 / 1_000L + 900L).replace("\"iat\":${t0 / 1_000L}", "\"iat\":\"${t0 / 1_000L}\""))
    assertEquals(PopopxPairingRejection.FIELD_INVALID, rejectAt(quotedIat, t0)) // numbers must be unquoted (EcoWire.kt:26-34 rule)
    val shortKey = signedOfferCode(offerBody(iatSeconds = t0 / 1_000L, expSeconds = t0 / 1_000L + 900L, key = base64UrlEncode(ByteArray(16))))
    assertEquals(PopopxPairingRejection.PUBLIC_KEY_MALFORMED, rejectAt(shortKey, t0))
    val emptyNode = signedOfferCode(offerBody(node = "", iatSeconds = t0 / 1_000L, expSeconds = t0 / 1_000L + 900L))
    assertEquals(PopopxPairingRejection.OFFER_INCOMPLETE, rejectAt(emptyNode, t0)) // valid signature, hollow claim
    val absurdIat = signedOfferCode(offerBody(iatSeconds = 9_000_000_000_000_000_000L, expSeconds = 9_100_000_000_000_000_000L))
    assertEquals(PopopxPairingRejection.FIELD_INVALID, rejectAt(absurdIat, t0)) // overflow guard, KDoc on PopopxNodePairing
  }

  @Test
  fun optionalFieldsFallBackNotReject() {
    // "v" and "once" absent take their defaults (:584-585); Swift's lenient accessors, ported.
    val t0 = 1_700_000_000_000L
    val body = offerBody(iatSeconds = t0 / 1_000L, expSeconds = t0 / 1_000L + 900L, v = null, once = null)
    val offer = assertNotNull(PopopxNodePairing.parse(signedOfferCode(body)))
    assertEquals(0, offer.schemaRevision)
    assertTrue(offer.singleUse, "once defaults to true")
  }

  @Test
  fun bindingKeepsFingerprintAndExpiryRules() {
    val offer = assertNotNull(PopopxNodePairing.parse(DiscoverSwiftVectors.GOOD_OFFER))
    val pairedAt = DiscoverSwiftVectors.IAT_SECONDS * 1_000L + 5_000L
    val binding = PopopxMacNodeBinding.of(offer, pairedAt)
    // shortDigest of the CODE (DiscoverCatalogModels.swift:657-659, PopopxBadgeCreditsModels.swift:1602-1607), pinned to Apple's ground truth.
    assertEquals(DiscoverSwiftVectors.GOOD_FINGERPRINT, binding.offerFingerprint)
    assertEquals(DiscoverSwiftVectors.GOOD_FINGERPRINT, popopxShortDigest(DiscoverSwiftVectors.GOOD_OFFER))
    assertEquals(16, binding.offerFingerprint.length)
    assertEquals("", binding.deviceLabel) // :644
    assertEquals(pairedAt, binding.pairedAtMs)
    assertEquals(DiscoverSwiftVectors.EXP_SECONDS * 1_000L, binding.offerExpiresAtMs)
    assertEquals(offer.nodeId, binding.id)
    // canAttemptHandshake (:670-674): strictly before the offer's expiry.
    assertTrue(binding.canAttemptHandshake(DiscoverSwiftVectors.EXP_SECONDS * 1_000L - 1L))
    assertTrue(!binding.canAttemptHandshake(DiscoverSwiftVectors.EXP_SECONDS * 1_000L))
    assertNull(binding.contactId)
    assertTrue(!binding.isBondedToChat)
  }

  @Test
  fun bindingSurvivesTheKeystoreRoundTrip() {
    val settings = discoverSettings()
    val clock = DiscoverClock(1_700_000_000_000L)
    val engine = discoverEngine(settings, clock)
    val offer = assertNotNull(PopopxNodePairing.parse(liveOfferCode(clock())))
    assertTrue(engine.bond(offer))
    engine.attach(4242L, "Studio Mac")
    engine.renameBinding("mac mini")
    engine.confirmHandshake()

    val reopened = discoverEngine(settings, clock)
    val stored = assertNotNull(reopened.binding)
    assertEquals(offer.nodeId, stored.nodeId)
    assertEquals(offer.publicKeyBase64URL, stored.publicKeyBase64URL)
    assertEquals(popopxShortDigest(offer.code), stored.offerFingerprint)
    assertEquals(4242L, stored.contactId)
    assertEquals("Studio Mac", stored.contactDisplayName)
    assertEquals("mac mini", stored.deviceLabel)
    assertTrue(stored.handshakeConfirmed)
    assertTrue(stored.isBondedToChat)

    reopened.unbind()
    assertNull(discoverEngine(settings, clock).binding)
  }

  @Test
  fun pasteOrderEcoLinkFirstThenPairing() {
    val settings = discoverSettings()
    val clock = DiscoverClock(1_700_000_000_000L)
    val code = liveOfferCode(clock())
    // Empty paste: ignored without even a notice (:180-183).
    assertEquals(PopopxPairingAccept.Ignored, discoverEngine(settings, clock).acceptPastedCode("   "))
    // The eco protocol gets first refusal (MacNodePairingSheet.swift:184-188) — even for a VALID node code.
    val ecoClaims = discoverEngine(settings, clock, ecoLinkConsumed = { true })
    assertEquals(PopopxPairingAccept.HandledByAnotherProtocol, ecoClaims.acceptPastedCode(code))
    // Otherwise the live code arrives as PENDING; bonding is the user's explicit act, never automatic.
    val accept = discoverEngine(settings, clock).acceptPastedCode(code)
    assertTrue(accept is PopopxPairingAccept.Pending)
  }

  private fun verdictAt(code: String, nowMs: Long): PopopxPairingVerdict = PopopxNodePairing.evaluate(code, nowMs)

  private fun rejectAt(code: String, nowMs: Long): PopopxPairingRejection =
    (verdictAt(code, nowMs) as PopopxPairingVerdict.Rejected).reason
}
