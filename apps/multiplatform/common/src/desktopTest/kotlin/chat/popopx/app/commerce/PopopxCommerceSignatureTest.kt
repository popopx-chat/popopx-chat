package chat.popopx.app.commerce

import chat.popopx.common.commerce.PopopxCommerceSignature
import chat.popopx.common.commerce.PopopxNodeBadgePeriod
import chat.popopx.common.eco.PopopxEcoSecrets
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

// The commerce signature layer: canonical bytes plus ECDSA P-256 (secp256r1) over them
// (`PopopxBadgeCreditsModels.swift:1531-1608`).
//
// The point of the canonical form is that a signature is bound to ONE payload shape: change an amount, a period or
// a code's content and verification fails, and a signature minted for one payload type can never be replayed
// against another. These tests are that claim, byte by byte. The P-256 primitives themselves are pinned against
// Swift/CryptoKit ground truth in `PopopxSwiftVectorTest`.

private val GIFT = PopopxCommerceSignature.canonicalGift("voucher.1", PopopxNodeBadgePeriod.MONTHLY, 1_700_000_000_000L, "enjoy")

class PopopxCommerceSignatureTest {
  private val giver = CommerceFixture().signature
  private val other = CommerceFixture().signature

  @Test
  fun theCanonicalFormIsTheJoinedBytes() {
    assertEquals(
      "popopx|grant|voucher.1|m|1700000000000|1700000086400",
      String(PopopxCommerceSignature.canonicalGrant("voucher.1", PopopxNodeBadgePeriod.MONTHLY, 1_700_000_000_000L, 1_700_000_086_400L))
    )
    assertEquals(
      "popopx|credit_grant|voucher.1|500|1700000000000",
      String(PopopxCommerceSignature.canonicalCreditGrant("voucher.1", 500, 1_700_000_000_000L))
    )
    assertEquals(
      "popopx|chan|100|1700000000000|pubkey",
      String(PopopxCommerceSignature.canonicalChannel(100, 1_700_000_000_000L, "pubkey"))
    )
    assertEquals(
      "popopx|rp|packet.1|100|5happy new year",
      String(PopopxCommerceSignature.canonicalRedPacket("packet.1", 100, 5, "happy new year"))
    )
  }

  @Test
  fun freeTextIsAppendedAfterTheLastPartSoItCannotShiftAField() {
    // MEASURED against Swift `:642`: the note's raw bytes are appended to the joined parts with NO separator, so a
    // note that begins with `|` sits directly after the timestamp. `gift` is the only field that can absorb a pipe,
    // and it is the last one, so no earlier field can be re-aligned out of position.
    assertEquals(
      "popopx|gift|voucher.1|m|1700000000000|evil|500",
      String(PopopxCommerceSignature.canonicalGift("voucher.1", PopopxNodeBadgePeriod.MONTHLY, 1_700_000_000_000L, "|evil|500"))
    )
    assertNotEquals(
      String(GIFT),
      String(PopopxCommerceSignature.canonicalCreditGift("voucher.1", 500, 1_700_000_000_000L, "enjoy"))
    )
  }

  @Test
  fun theTimestampAndTheNoteShareTheirBoundaryExactlyAsIosSignsThem() {
    // The consequence of appending with no separator: (ts=1700, note="|x") and (ts=170, note="0|x") canonicalise to
    // the same bytes. Inherited from the Swift, kept because changing it would break every code minted on the other
    // platform, and bounded: only the two tail fields can trade bytes, never the voucher id or the period.
    val a = PopopxCommerceSignature.canonicalGift("v", PopopxNodeBadgePeriod.MONTHLY, 1_700L, "|x")
    val b = PopopxCommerceSignature.canonicalGift("v", PopopxNodeBadgePeriod.MONTHLY, 170L, "0|x")
    assertTrue(a.contentEquals(b))
  }

  @Test
  fun aSignatureVerifiesOverTheBytesItWasMadeFor() {
    val signature = giver.signatureBase64URL(GIFT)
    assertNotNull(signature)
    assertTrue(giver.verify(signature, GIFT, giver.localPublicKeyBase64URL()))
    assertTrue(giver.verifySelfIssued(signature, GIFT))
  }

  @Test
  fun tamperingWithOneSignedFieldFailsVerification() {
    val signature = giver.signatureBase64URL(GIFT)!!
    val tampered = PopopxCommerceSignature.canonicalGift("voucher.1", PopopxNodeBadgePeriod.ANNUAL, 1_700_000_000_000L, "enjoy")
    assertFalse(giver.verify(signature, tampered, giver.localPublicKeyBase64URL()))
    assertFalse(giver.verify(signature, GIFT.copyOf(GIFT.size - 1), giver.localPublicKeyBase64URL()))
  }

  @Test
  fun aSignatureOverOneKindNeverVerifiesAsAnother() {
    // The eight kinds share one joining function, so the only thing separating a voucher's `code` signature from a
    // credit card's `credit_code` signature is the second segment. If a canonicaliser ever dropped it, a badge code
    // would become spendable as a credit code at the same voucher id.
    val code = PopopxCommerceSignature.canonicalCode("voucher.1", PopopxNodeBadgePeriod.MONTHLY, 1_700_000_000_000L, "nonce", "https://smp1.popopx.im/a")
    val creditCode = PopopxCommerceSignature.canonicalCreditCode("voucher.1", 500, 1_700_000_000_000L, "nonce", "https://smp1.popopx.im/a")
    val signature = giver.signatureBase64URL(code)!!
    assertTrue(giver.verify(signature, code, giver.localPublicKeyBase64URL()))
    assertFalse(giver.verify(signature, creditCode, giver.localPublicKeyBase64URL()))
  }

  @Test
  fun aGrantSignedElsewhereDoesNotVerifyHere() {
    // The trust model has no authority: a grant is only as good as the key inside it, and this device's key is not
    // anybody else's. `verifySelfIssued` must therefore never be a shortcut for "somebody signed this".
    val signature = giver.signatureBase64URL(GIFT)!!
    assertTrue(giver.verifySelfIssued(signature, GIFT))
    assertFalse(other.verifySelfIssued(signature, GIFT))
    assertFalse(giver.verify(signature, GIFT, other.localPublicKeyBase64URL()))
  }

  @Test
  fun missingOrUndecodableInputsAreNotVerifiableAndSayNothingMore() {
    val signature = giver.signatureBase64URL(GIFT)!!
    val publicKey = giver.localPublicKeyBase64URL()
    assertFalse(giver.verify("", GIFT, publicKey))
    assertFalse(giver.verify(signature, GIFT, ""))
    assertFalse(giver.verify("not*base64", GIFT, publicKey))
    assertFalse(giver.verify(signature, GIFT, "not*base64"))
    assertFalse(giver.verify(signature, GIFT, "AAAA"))
  }

  @Test
  fun aDeviceHoldsNoKeyUntilTheFirstSignatureIsAskedFor() {
    val fixture = CommerceFixture()
    assertFalse(fixture.signature.hasSigningKey())
    assertFalse(fixture.manager.canSign())
    // `hasSigningKey` and `canSign` must not mint: the sheets ask them to decide between "unavailable" and a form
    // the user cannot finish, and minting while asking would leave a key behind on a device that never signed.
    assertFalse(fixture.signature.hasSigningKey())
    val signature = fixture.signature.signatureBase64URL(GIFT)
    assertNotNull(signature)
    assertTrue(fixture.signature.hasSigningKey())
    assertTrue(PopopxCommerceSignature(fixture.defaults).hasSigningKey())
  }

  @Test
  fun theKeyIsStableAcrossInstancesAndARestart() {
    val fixture = CommerceFixture()
    val first = fixture.signature.localPublicKeyBase64URL()
    assertTrue(first.isNotEmpty())
    assertEquals(first, PopopxCommerceSignature(fixture.defaults).localPublicKeyBase64URL())
    assertEquals(first, fixture.signature.localPublicKeyBase64URL())
  }

  @Test
  fun aRowOfTheWrongLengthIsDestroyedRatherThanUsed() {
    val fixture = CommerceFixture()
    assertTrue(PopopxEcoSecrets.write(ByteArray(16) { 7 }, PopopxCommerceSignature.ACCOUNT_SIGNING_KEY, fixture.defaults))
    val scalar = fixture.signature.signingScalar()
    assertNotNull(scalar)
    assertEquals(32, scalar.size)
    assertTrue(fixture.signature.localPublicKeyBase64URL().isNotEmpty())
  }

  @Test
  fun theShortDigestIsTheFirstEightSha256BytesAsHex() {
    // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad. A known answer, so neither
    // a changed hex encoding nor a different slice length can pass, and the ledger's dedupe keys depend on it.
    assertEquals("ba7816bf8f01cfea", PopopxCommerceSignature.shortDigest("abc"))
    assertEquals("ba7816bf8f01cfea", PopopxCommerceSignature.shortDigest("abc".encodeToByteArray()))
    assertEquals(32, PopopxCommerceSignature.digest("abc").size)
  }
}
