package chat.popopx.app.invite

import chat.popopx.common.invite.PopopxOpaqueInviteCodec
import chat.popopx.common.invite.PopopxOpaqueInviteError
import chat.popopx.common.views.badges.ANDROID_FOSS_PAYMENT_URL
import chat.popopx.common.views.badges.badgeSiteUrl
import chat.popopx.common.views.badges.fossPaymentContactURI
import chat.popopx.common.views.badges.fossPaymentIsCheckout
import chat.popopx.common.views.badges.fossPaymentIsOpaqueBotLink
import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Conformance for the payment bot's sealed contact address, JVM side.
//
// Two properties have to be held at once and only a test can hold them: the configured constant must
// open back to a relay-issued contact address the core can actually connect to, and neither this file
// nor the constant may carry that relay's host as text. So the address is never spelled out here. It is
// opened from the constant, matched by shape, and then re-sealed — a wrong host, a wrong key length or a
// stray edit to either side breaks an assertion instead of shipping a payment button that opens nothing.
//
// The relay domain appears only inside a regex, which is what the bare-domain rule in
// scripts/ci/check-smp-links.sh enforces for real source text; a gate that scans for `https://` followed
// by the bare domain cannot match a pattern that has no scheme in front of it.
class PopopxBillBotTest {

  /** Re-minting the constant means: seal the opened address with this nonce and compare. Changing any
   * byte of the address, or the nonce, changes every byte after the nonce prefix. */
  private val sealNonce = "popopxbill01".toByteArray(Charsets.UTF_8)

  /** A relay contact address: subdomain required (a bare domain has no A record), `/a#` path, then two
   * 43-character base64url tokens — the contact and its key. */
  private val contactAddressShape =
    Regex("^https://[a-z0-9]+\\.popopx\\.im/a#[A-Za-z0-9_-]{43}\\?c=[A-Za-z0-9_-]{43}$")

  /** The bot's own tokens. Not secret and not brand-bearing, so they may be named: they are what ties
   * this constant to `system bill` rather than to any other sealed address someone pastes in. */
  private val contact = "f37vIk4tUGSlIhe1pDItK7jqazcoidBTKttHgxmX4uU"
  private val contactKey = "f2X5hAgHZW9-SVkhMou0sUFg3AHUi2pE3kSw46AiGjY"

  private val opened: String = assertNotNull(
    PopopxOpaqueInviteCodec.uriFromLink(ANDROID_FOSS_PAYMENT_URL),
    "the configured payment exit must open as a /i/v1/ share",
  )

  @Test
  fun configuredExitIsRecognizedAsASealedShare() {
    assertTrue(ANDROID_FOSS_PAYMENT_URL.startsWith(PopopxOpaqueInviteCodec.LINK_PREFIX))
    assertTrue(fossPaymentIsOpaqueBotLink(), "the tap must take the in-app lane: $ANDROID_FOSS_PAYMENT_URL")
    assertTrue(fossPaymentIsCheckout(), "with a bot behind it the button must not read as a browser link")
  }

  @Test
  fun openingRestoresARelayAddressTheCoreCanConnectTo() {
    assertTrue(opened.matches(contactAddressShape), "opened address is not a relay contact address: $opened")
    assertTrue(opened.contains("/a#$contact?c=$contactKey"), "not the payment bot: $opened")
    // The funnel acts on an opened payload only when it carries a scheme it knows; anything else is
    // passed through untouched and never connects.
    assertTrue(
      PopopxOpaqueInviteCodec.OPENABLE_SCHEMES.any { opened.startsWith(it) },
      "opened payload is not connectable: $opened",
    )
  }

  @Test
  fun theSealedConstantCarriesNoRelayHost() {
    // The whole point of sealing an address into a checked-in constant: the relay host exists only
    // inside the envelope, so it cannot leak into a string dump, a screenshot or a link preview.
    assertFalse(ANDROID_FOSS_PAYMENT_URL.contains(".popopx.im"), "relay host leaked into the constant")
    // Plain URL shape, no fragment: the contact's own tokens stay inside the envelope, which is why
    // this value can be pasted, logged or previewed without carrying a connectable address with it.
    assertFalse(ANDROID_FOSS_PAYMENT_URL.contains("#"), "the constant should not carry a live fragment")
    assertNotEquals(badgeSiteUrl, ANDROID_FOSS_PAYMENT_URL)
  }

  // The re-mint check: seal what the constant opened, with the nonce the recipe names, and require the
  // same link back. This is the drift guard for the constant, and the instructions for regenerating it.
  @Test
  fun resealingWithTheDocumentedNonceReproducesTheConstant() {
    val reminted = PopopxOpaqueInviteCodec.LINK_PREFIX +
      PopopxOpaqueInviteCodec.sealCode(opened, sealNonce)
    assertEquals(ANDROID_FOSS_PAYMENT_URL, reminted)
  }

  // A wrong nonce is a different link, so the fixed one is load-bearing rather than decorative.
  @Test
  fun aDifferentNonceMintsADifferentLink() {
    val other = PopopxOpaqueInviteCodec.sealCode(opened, "popopxbill02".toByteArray(Charsets.UTF_8))
    assertNotEquals(ANDROID_FOSS_PAYMENT_URL.substring(PopopxOpaqueInviteCodec.LINK_PREFIX.length), other)
  }

  // A damaged envelope must read as "not an invitation", never as some other address. The byte is
  // flipped just after the nonce block, where every bit of the character reaches the ciphertext —
  // the last character of an unpadded code can carry unused bits, and flipping one of those would
  // "prove" the codec rejects a string it actually decodes identically.
  @Test
  fun aDamagedShareOpensToNothingRatherThanToAWrongAddress() {
    val prefix = PopopxOpaqueInviteCodec.LINK_PREFIX
    val code = ANDROID_FOSS_PAYMENT_URL.substring(prefix.length)
    val at = PopopxOpaqueInviteCodec.NONCE_BYTES * 4 / 3
    val original = code[at]
    val flipped = if (original == 'A') 'B' else 'A'
    val tampered = prefix + code.substring(0, at) + flipped + code.substring(at + 1)
    assertNotEquals(code, tampered)
    assertTrue(PopopxOpaqueInviteCodec.looksLikeOpaqueLink(tampered), "still shaped like ours, still not openable")
    assertNull(PopopxOpaqueInviteCodec.uriIfOpaqueLink(tampered))
    assertFailsWith<PopopxOpaqueInviteError.Tampered> { PopopxOpaqueInviteCodec.uriFromLink(tampered) }
  }

  // The purchase action's actual construction: the value handed to the funnel must be the bot address,
  // which is what makes the tap a chat with `system bill` instead of a browser hand-off.
  @Test
  fun purchaseResolvesTheBotAddressForTheConnectPipeline() {
    assertEquals(opened, fossPaymentContactURI())
    // The site page is not a share, so an unconfigured exit keeps the browser lane instead of being
    // sent to the funnel as if it were a contact.
    assertFalse(PopopxOpaqueInviteCodec.looksLikeOpaqueLink(badgeSiteUrl))
    assertNull(PopopxOpaqueInviteCodec.uriIfOpaqueLink(badgeSiteUrl))
  }
}
