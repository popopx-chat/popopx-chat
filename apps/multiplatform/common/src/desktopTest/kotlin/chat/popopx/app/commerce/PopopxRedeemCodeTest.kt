package chat.popopx.app.commerce

import chat.popopx.common.commerce.PopopxCreditRedeemEnvelope
import chat.popopx.common.commerce.PopopxNodeBadgePeriod
import chat.popopx.common.commerce.PopopxRedeemCode
import chat.popopx.common.commerce.PopopxRedeemEnvelope
import chat.popopx.common.crypto.base64UrlEncode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The redemption-code codec: `PPX1-…` for badges and `PPXC1-…` for compute credits
// (`PopopxBadgeCreditsModels.swift:533-617`).
//
// These tests protect the framing, not the JSON. A code is a hand-transcribed, one-shot withdrawal credential, so
// the questions are: does one wrong character get caught, can one family be spent as the other, and does
// normalising a pasted code ever eat a payload byte.

private const val LINK = "https://smp1.popopx.im/a#0123456789ABCDEF?c=popopx1%3A%40smp1.popopx.im"
private const val PUB = "BKz8Q0x1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"
private const val SIG = "MEUCIQDx0yT3nV1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5"
private const val P = PopopxRedeemCode.PREFIX

private val BADGE = PopopxRedeemEnvelope(
  inviteLink = LINK,
  voucherId = "voucher-1",
  period = PopopxNodeBadgePeriod.MONTHLY,
  mintedAtMs = 1_700_000_000_000L,
  nonce = "nonce123",
  giverPublicKey = PUB,
  signature = SIG,
)

private val CREDIT = PopopxCreditRedeemEnvelope(
  inviteLink = LINK,
  voucherId = "voucher-2",
  creditsAmount = 500,
  mintedAtMs = 1_700_000_000_000L,
  nonce = "nonce456",
  giverPublicKey = PUB,
  signature = SIG,
)

class PopopxRedeemCodeTest {
  private val badgeCode: String = PopopxRedeemCode.encode(BADGE)!!
  private val creditCode: String = PopopxRedeemCode.encodeCredit(CREDIT)!!

  @Test
  fun aBadgeCodeFramesAndUnframes() {
    assertEquals(BADGE, PopopxRedeemCode.decode(badgeCode))
  }

  @Test
  fun aCreditCodeFramesAndUnframes() {
    assertEquals(CREDIT, PopopxRedeemCode.decodeCredit(creditCode))
  }

  @Test
  fun theTwoFamiliesNeverDecodeAsEachOther() {
    // The prefixes differ at the THIRD character, which is what makes a `hasPrefix` test safe for either family.
    assertTrue(badgeCode.startsWith(P))
    assertTrue(creditCode.startsWith(PopopxRedeemCode.CREDIT_PREFIX))
    assertNull(PopopxRedeemCode.decodeCredit(badgeCode))
    assertNull(PopopxRedeemCode.decode(creditCode))
    assertEquals(P, PopopxRedeemCode.prefixOf(badgeCode))
    assertEquals(PopopxRedeemCode.CREDIT_PREFIX, PopopxRedeemCode.prefixOf(creditCode))
    assertNull(PopopxRedeemCode.prefixOf("PPX2-abc"))
  }

  @Test
  fun oneWrongCharacterIsCaughtByTheChecksumBeforeTheParse() {
    val body = badgeCode.substring(P.length)
    val middle = body.length / 2
    val swapped = if (body[middle] == 'A') 'B' else 'A'
    val tampered = P + body.substring(0, middle) + swapped + body.substring(middle + 1)
    assertNotEquals(badgeCode, tampered)
    assertNull(PopopxRedeemCode.decode(tampered))
  }

  @Test
  fun normalisingRemovesWhitespaceAndRepairsThePrefixCaseOnly() {
    val pasted = buildString {
      append("  pp")
      append(badgeCode.substring(2, 12))
      append('\n')
      append(badgeCode.substring(12))
      append('\t')
    }
    assertEquals(badgeCode, PopopxRedeemCode.normalized(pasted))
    assertEquals(BADGE, PopopxRedeemCode.decode(PopopxRedeemCode.normalized(pasted)))
    assertEquals(badgeCode, PopopxRedeemCode.normalized("ppx1-" + badgeCode.substring(P.length)))
  }

  @Test
  fun normalisingNeverStripsHyphensBecauseTheAlphabetContainsThem() {
    // The measured trap: `-` is a base64url character, so a normaliser that "removes the grouping hyphens" silently
    // corrupts the payload. A trailing `-AAAA` therefore survives normalisation and then fails its checksum.
    val withTail = "$badgeCode-AAAA"
    assertEquals(withTail, PopopxRedeemCode.normalized(withTail))
    assertNull(PopopxRedeemCode.decode(withTail))
  }

  @Test
  fun anUpperCasedBodyIsNotReCasedAndAnswersWithTheHonestFailure() {
    // Only the prefix's case is repaired. A body that some clipboard upper-cased still normalises, still decodes as
    // base64url (into different bytes) and then fails the checksum, which reports "this code is not right" instead
    // of handing over a different voucher.
    val upper = badgeCode.uppercase()
    val normalised = PopopxRedeemCode.normalized(upper)
    assertEquals(upper, normalised)
    assertNotEquals(badgeCode, normalised)
    assertNull(PopopxRedeemCode.decode(normalised))
  }

  @Test
  fun groupingIsEightCharactersAcrossTheWholeBody() {
    assertEquals("${P}abcdefgh", PopopxRedeemCode.grouped("${P}abcdefgh"))
    assertEquals("${P}abcdefgh ij", PopopxRedeemCode.grouped("${P}abcdefghij"))
    assertEquals("abcdefgh", PopopxRedeemCode.grouped("abcdefgh"))
    assertEquals("abcdefgh ij", PopopxRedeemCode.grouped("abcdefghij"))
  }

  @Test
  fun aBodyThatAlreadyHoldsASpaceRendersTwoOfThemSideBySide() {
    // iOS groups over the body as it stands, spaces included: `abcdefgh ij` splits as "abcdefgh" then " ij", and the
    // joining separator puts a second space in front of the one already there. Reproduced, not "fixed".
    assertEquals("${P}abcdefgh  ij", PopopxRedeemCode.grouped("${P}abcdefgh ij"))
  }

  @Test
  fun anEmptyBodyIsReturnedUnchangedRatherThanAsAPrefixAndASpace() {
    assertEquals(P, PopopxRedeemCode.grouped(P))
    assertEquals("noprefix", PopopxRedeemCode.grouped("noprefix"))
  }

  @Test
  fun copyingHandsOverTheTextItIsGivenBecauseGroupingIsDisplayOnly() {
    // `clipboardValue` is the identity by design (`:615-616`): the grouped rendering carries the spaces a human
    // reads and a paste must not carry them, so the caller hands over the ungrouped text and nothing here silently
    // re-joins or strips. The round trip back is [normalized]'s job, and it is pinned here because a pasted group
    // is the ordinary way a code comes back.
    assertEquals(badgeCode, PopopxRedeemCode.clipboardValue(badgeCode))
    val grouped = PopopxRedeemCode.grouped(badgeCode)
    assertTrue(grouped.contains(' '))
    assertEquals(grouped, PopopxRedeemCode.clipboardValue(grouped))
    assertEquals(BADGE, PopopxRedeemCode.decode(PopopxRedeemCode.normalized(grouped)))
  }

  @Test
  fun aBodyOverTheCapIsRefusedBeforeAnyByteIsCommitted() {
    assertNull(PopopxRedeemCode.encode(BADGE.copy(inviteLink = "x".repeat(5_000))))
    assertNotNull(PopopxRedeemCode.encode(BADGE.copy(inviteLink = "x".repeat(200))))
  }
}
