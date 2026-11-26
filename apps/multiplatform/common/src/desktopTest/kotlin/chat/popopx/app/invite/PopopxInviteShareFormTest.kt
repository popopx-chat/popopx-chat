package chat.popopx.app.invite

import chat.popopx.common.invite.PopopxInviteShareForm
import chat.popopx.common.invite.PopopxOpaqueInviteCodec
import chat.popopx.common.invite.looksLikePopopxInviteLink
import chat.popopx.common.invite.popopxConnectURI
import chat.popopx.common.invite.popopxInviteLinkURI
import chat.popopx.common.model.CreatedConnLink
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV

// The app-layer invite link: which share a screen shows, and what a received string turns into before
// the core sees it. Every expectation here is a spelled-out literal, because the rules being pinned are
// rules about particular strings - "a short link is never sealed" is only proved if the test names the
// short link, the published prefix and the original address it must not equal.

/** A full invitation address: it names the SMP host, which is the whole reason the code exists. */
private const val FULL =
  "https://popopx.chat/invitation#/?v=2&smp=smp%3A%2F%2F8yH7w55jipblnSA3Fk5l2T3BHFXTzZFvbX1CrsiDhBc%40smp7.popopx.im%2FAbCdEfGh0123456789IJKL&x3dh=MDEyMzQ1Njc4OQ%3D%3D"

/** The same invitation as the app publishes it on its own domain: no server host in it. */
private const val SHORT = "https://popopx.chat/i#A1b2C3d4E5f6G7h8I9j0"

/** The one published invite form this build mints. */
private const val OPAQUE_PREFIX = "https://popopx.chat/i/v1/"

private val invitation = CreatedConnLink(FULL, SHORT)

class PopopxInviteShareFormTest {

  /** Seals an arbitrary payload with the format key, so a test can hand the opener an envelope that
   * authenticates but is not a connection address. */
  private fun linkWrapping(payload: String): String {
    val nonce = ByteArray(PopopxOpaqueInviteCodec.NONCE_BYTES) { (it - 6).toByte() }
    val engine = ChaCha20Poly1305()
    engine.init(true, ParametersWithIV(KeyParameter(PopopxOpaqueInviteCodec.formatKey), nonce))
    engine.processAADBytes(PopopxOpaqueInviteCodec.AAD, 0, PopopxOpaqueInviteCodec.AAD.size)
    val input = payload.toByteArray(Charsets.UTF_8)
    val out = ByteArray(input.size + 16)
    val written = engine.processBytes(input, 0, input.size, out, 0)
    val total = written + engine.doFinal(out, written)
    return OPAQUE_PREFIX + PopopxOpaqueInviteCodec.base64Url(nonce + out.copyOfRange(0, total))
  }

  @Test
  fun shortLinkIsNeverSealed() {
    val form = PopopxInviteShareForm.make(invitation, short = true)
    assertNull(form.opaque, "a short link already names no server, so sealing it buys nothing")
    assertTrue(!form.isSealed, "the fold must not appear for a link that hides nothing")
    assertEquals("https://popopx.chat/i#A1b2C3d4E5f6G7h8I9j0", form.display)
    assertTrue(!form.display.startsWith(OPAQUE_PREFIX))
    assertEquals(SHORT, form.fallback)
    assertEquals(FULL, form.original)
  }

  @Test
  fun fullAddressIsSealedAndStillOpensToItself() {
    val form = PopopxInviteShareForm.make(invitation, short = false)
    assertTrue(form.isSealed)
    val display = checkNotNull(form.opaque)
    assertTrue(display.startsWith(OPAQUE_PREFIX), "displayed $display")
    assertNotEquals(FULL, display)
    assertEquals(FULL, PopopxOpaqueInviteCodec.uriFromLink(display))
    // The short choice does not leak into the full form: the fallback is the address, not the pointer.
    assertEquals(FULL, form.fallback)
  }

  @Test
  fun sealIsStableAcrossRenderBecauseTheCodecAloneIsNot() {
    val first = checkNotNull(PopopxInviteShareForm.make(invitation, short = false).opaque)
    val second = checkNotNull(PopopxInviteShareForm.make(CreatedConnLink(FULL, SHORT), short = false).opaque)
    assertEquals(first, second, "text, QR and share sheet would carry three links for one invitation")
    assertEquals(first, checkNotNull(PopopxInviteShareForm.make(invitation, short = false).opaque))
    // The memoisation is what makes that true; an unsealed mint draws a fresh nonce every call.
    assertNotEquals(
      checkNotNull(PopopxOpaqueInviteCodec.linkFor(FULL)),
      checkNotNull(PopopxOpaqueInviteCodec.linkFor(FULL)),
      "the codec, not the cache, is where the nonce comes from"
    )
  }

  @Test
  fun displayQrInputAndOriginalAreTheSameTriple() {
    val form = PopopxInviteShareForm.make(invitation, short = false)
    // The screen prints display, encodes display in the QR and shares display; the fold reveals original.
    assertEquals(form.opaque, form.display)
    assertEquals(FULL, form.original)
    assertNotEquals(form.original, form.display)
    assertEquals(form.original, popopxConnectURI(form.display))
    // A short link hides nothing, so there is nothing to unwrap and nothing for the fold to reveal.
    val shortForm = PopopxInviteShareForm.make(invitation, short = true)
    assertTrue(!shortForm.isSealed)
    assertEquals(SHORT, popopxConnectURI(shortForm.display))
  }

  @Test
  fun anInvitationNotYetMintedSharesNothingAndHidesNothing() {
    // CreatedConnLink("", null) is what these screens hold before the api answers.
    val form = PopopxInviteShareForm.make(CreatedConnLink("", null), short = true)
    assertNull(form.opaque)
    assertTrue(!form.isSealed)
    assertEquals("", form.display)
    assertEquals("", form.original)
  }

  @Test
  fun addressWithNoShortFormIsSealedByThePlaintextRule() {
    // A screen that passes the full address with no short link available (no user choice to respect):
    // the plaintext names the host, so it is sealed. Which screens are excluded is a call-site ruling,
    // not a property of this decision.
    val form = PopopxInviteShareForm.make(CreatedConnLink(FULL, null), short = true)
    assertTrue(form.isSealed)
    assertEquals(FULL, popopxConnectURI(checkNotNull(form.opaque)))
  }

  @Test
  fun receivedOpaqueLinkIsOpenedBeforeTheCoreSeesIt() {
    val display = checkNotNull(PopopxInviteShareForm.make(invitation, short = false).opaque)
    assertTrue(looksLikePopopxInviteLink(display))
    assertEquals(FULL, popopxInviteLinkURI(display))
    assertEquals(FULL, popopxConnectURI(display))
    // The scheme spellings a link between clients arrives as are read too.
    val code = display.removePrefix(OPAQUE_PREFIX)
    assertEquals(FULL, popopxConnectURI("popopx:/i/v1/" + code))
    assertEquals(FULL, popopxConnectURI("popopx://popopx.chat/i/v1/" + code))
  }

  @Test
  fun anythingThatIsNotOurLinkReachesTheCoreUnchanged() {
    assertEquals(SHORT, popopxConnectURI(SHORT))
    assertEquals(FULL, popopxConnectURI(FULL))
    assertEquals("popopx:/invitation#/?v=2", popopxConnectURI("popopx:/invitation#/?v=2"))
    assertEquals("https://smp7.popopx.im/i#A1b2", popopxConnectURI("https://smp7.popopx.im/i#A1b2"))
    assertEquals("", popopxConnectURI(""))
    assertTrue(!looksLikePopopxInviteLink("https://popopx.chat/i/v2/x"))
    assertTrue(!looksLikePopopxInviteLink(SHORT))
    assertNull(popopxInviteLinkURI("https://popopx.chat/i/v2/AAAAAAAAAAAAAAAAAAAAAAAA"))
    assertNull(popopxInviteLinkURI("https://example.test/i/v1/AAAAAAAAAAAAAAAAAAAAAAAA"))
  }

  @Test
  fun damagedShareIsAnsweredAsNotAnInvitationRatherThanAsABrokenOne() {
    val display = checkNotNull(PopopxInviteShareForm.make(invitation, short = false).opaque)
    // Corrupt the nonce, not a trailing character: the last base64 group carries discarded padding bits,
    // so a change there can still authenticate and the test would prove nothing.
    val damaged = OPAQUE_PREFIX + (if (display[OPAQUE_PREFIX.length] == 'B') 'A' else 'B') +
      display.substring(OPAQUE_PREFIX.length + 1)
    assertNotEquals(display, damaged)
    assertTrue(looksLikePopopxInviteLink(damaged), "shape test must still call this ours")
    assertNull(popopxInviteLinkURI(damaged))
    // Passed through, so the ordinary "this is not a link" path answers it and no copy claims a damage
    // this app cannot distinguish from a stranger's URL.
    assertEquals(damaged, popopxConnectURI(damaged))
  }

  @Test
  fun openedPayloadReachesTheConnectPathOnlyWhenItIsAnAddress() {
    val pairing = "PPXNODE1-" + "Q".repeat(96) + "." + "R".repeat(48)
    val wrapped = linkWrapping(pairing)
    assertTrue(looksLikePopopxInviteLink(wrapped))
    // Opening is wider than connecting, on both clients: the codec authenticates the offer and hands it
    // back, and the connect path declines it, because `PopopxNodeCommand` takes pairing offers and
    // verifies their Ed25519 signature itself. Treating one as an invitation would call a well-formed
    // offer damaged.
    assertEquals(pairing, PopopxOpaqueInviteCodec.uriIfOpaqueLink(wrapped))
    assertNull(popopxInviteLinkURI(wrapped))
    assertEquals(wrapped, popopxConnectURI(wrapped))

    // A payload that authenticates but is neither an address nor an offer never reaches the app: the
    // codec's own accept-list refuses it, so the answer comes back null before this file sees it.
    // `javascript:` under a trusted domain is the case that gate exists for.
    val hostile = linkWrapping("javascript:alert(1)")
    assertTrue(looksLikePopopxInviteLink(hostile))
    assertNull(PopopxOpaqueInviteCodec.uriIfOpaqueLink(hostile))
    assertNull(popopxInviteLinkURI(hostile))
    assertEquals(hostile, popopxConnectURI(hostile))

    // A legacy smp:// raw address is opened and handed on, exactly as iOS does: the servers refuse to
    // mint it, but a client that was handed one still gets the address it carries, and the core's own
    // classifier answers for it.
    val legacy = linkWrapping("smp://8yH7w55jipblnSA3Fk5l2T3BHFXTzZG@smp7.popopx.im/A1b2C3d4")
    assertEquals("smp://8yH7w55jipblnSA3Fk5l2T3BHFXTzZG@smp7.popopx.im/A1b2C3d4", popopxInviteLinkURI(legacy))
  }
}
