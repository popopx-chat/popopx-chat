package chat.popopx.app.discover

import chat.popopx.common.discover.PopopxNodeCommand
import chat.popopx.common.discover.PopopxNodeResultCard
import chat.popopx.common.discover.PopopxNodeResultStatus
import chat.popopx.common.discover.PopopxNodeServiceId
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The result card (DiscoverCatalogModels.swift:476-528) — including the two documented Swift
// quirks the port keeps, because the host's output and the stored cards are what they are.

class PopopxNodeResultCardTest {
  private val now = 1_760_000_500_000L

  @Test
  fun parsesTheDocumentedShape() {
    // The exact comment example from :469: flag, name, headline, duration.
    val card = PopopxNodeResultCard.detect("\u2705 Shadow Chief of Staff \u00b7 Daily brief ready \u00b7 1432 ms", fromPairedNode = true, nowMs = now)
    assertEquals(PopopxNodeServiceId.ShadowCos, card?.serviceId)
    assertEquals(PopopxNodeResultStatus.SUCCEEDED, card?.status)
    assertEquals("Daily brief ready", card?.headline)
    assertEquals(1_432, card?.durationMilliseconds)
    assertEquals("", card?.detail)
    assertEquals(now, card?.receivedAtMs)
    // id = "<raw>.<nowMs>.<headline+detail hash>" (:506): the shape, not the unstable hash digits.
    assertTrue(card!!.id.startsWith("shadow_cos.$now."))
  }

  @Test
  fun warningFlagIsDegradedAndExtraLinesBecomeDetail() {
    val card = PopopxNodeResultCard.detect("\u26a0\ufe0f Health Sentinel \u00b7 Report stale\nWatermark queue paused\n", true, now)
    assertEquals(PopopxNodeServiceId.HealthSentinel, card?.serviceId)
    assertEquals(PopopxNodeResultStatus.DEGRADED, card?.status)
    assertEquals("Report stale", card?.headline)
    assertEquals("Watermark queue paused", card?.detail)
    assertNull(card?.durationMilliseconds)
    // Bare warning sign, no variation selector, is the same status (:483) — and both scalars go.
    val bare = PopopxNodeResultCard.detect("\u26a0 Morning TV \u00b7 Feeds unreachable", true, now)
    assertEquals(PopopxNodeResultStatus.DEGRADED, bare?.status)
    assertEquals("Feeds unreachable", bare?.headline)
  }

  @Test
  fun longestEngineNameWins() {
    // :487-490: "Health Sentinel" / "Phantom Sentinel" share their tail; the FULL name plus " \u00b7"
    // must prefix-match, so a card can never be filed under the shorter lookalike.
    val phantom = PopopxNodeResultCard.detect("\u2705 Phantom Sentinel \u00b7 House secured", true, now)
    assertEquals(PopopxNodeServiceId.PhantomSentinel, phantom?.serviceId)
    assertEquals("House secured", phantom?.headline)
    val health = PopopxNodeResultCard.detect("\u2705 Health Sentinel \u00b7 Report ready", true, now)
    assertEquals(PopopxNodeServiceId.HealthSentinel, health?.serviceId)
    // "...Sentinel \u00b7" alone matches NEITHER — the host always prints the full name.
    assertNull(PopopxNodeResultCard.detect("\u2705 Sentinel \u00b7 House secured", true, now))
  }

  @Test
  fun onlyTheTwoFlagsOpenACard() {
    assertNull(PopopxNodeResultCard.detect("Shadow Chief of Staff \u00b7 Daily brief", true, now))
    assertNull(PopopxNodeResultCard.detect("\u274c Shadow Chief of Staff \u00b7 failed", true, now))
    assertNull(PopopxNodeResultCard.detect("   ", true, now))
    assertNull(PopopxNodeResultCard.detect("\u2705 Chrono Ark \u00b7", true, now)) // name, no remainder -> empty headline
    // A newline right after the flag survives the whitespace-only trim (:486) and kills the match.
    assertNull(PopopxNodeResultCard.detect("\u2705\nChrono Ark \u00b7 Capsule sealed", true, now))
  }

  @Test
  fun unpairedSourceIsNotACardAndNotADrop() {
    // THE renderer-not-suppressor rule (:441-447): identical text, wrong source -> nil, and the
    // bubble renders as it arrived. detect must not guess provenance itself.
    val text = "\u2705 Shadow Chief of Staff \u00b7 Daily brief ready \u00b7 1432 ms"
    assertNull(PopopxNodeResultCard.detect(text, fromPairedNode = false, nowMs = now))
    assertEquals(PopopxNodeServiceId.ShadowCos, PopopxNodeResultCard.detect(text, true, now)?.serviceId)
  }

  @Test
  fun theNoSpaceAfterMiddleDotQuirkIsKept() {
    // dropFirst(name.count + 3) (:491) skips " \u00b7 " ASSUMING a space follows the dot; without it,
    // the headline loses its first character. Pinned as a quirk, not fixed (KDoc explains).
    val card = PopopxNodeResultCard.detect("\u2705 Health Sentinel \u00b7Report ready", true, now)
    assertEquals("eport ready", card?.headline)
  }

  @Test
  fun theMsSuffixTruncatesTheHeadlineEvenWhenTheNumberWillNotParse() {
    // :496-502: any tail ending " ms" cuts the headline at the LAST " \u00b7 ", Int-parse or not.
    val card = PopopxNodeResultCard.detect("\u2705 Morning TV \u00b7 Bulletin \u00b7 cost 12 ms", true, now)
    assertEquals("Bulletin", card?.headline) // "cost 12 ms" is gone entirely
    assertNull(card?.durationMilliseconds) // and "cost 12" is not an Int
    // A negative number parses (Swift Int accepts the sign), and is stored as such.
    assertEquals(-5, PopopxNodeResultCard.detect("\u2705 Zero-Trace Studio \u00b7 Clip \u00b7 -5 ms", true, now)?.durationMilliseconds)
  }

  @Test
  fun newlinesInsideTheRemainderSplitTheWayFoundationSplitsThem() {
    // CharacterSet.newlines (:493) includes VT, CR and NEL — escapes keep them visible in source.
    val card = PopopxNodeResultCard.detect("\u2705 Chrono Ark \u00b7 Capsule sealed\u000bnext\r\nqueued\u0085done", true, now)
    assertEquals("Capsule sealed", card?.headline)
    // Measured against real Foundation: CharacterSet.newlines holds BOTH \r and \n, so the CRLF pair splits into
    // an empty component (`components` keeps empties, unlike `split`), and the rejoin at :504 renders it as a blank
    // line. Verified with swift on this machine: 5 components, detail = "next\n\nqueued\ndone".
    assertEquals("next\n\nqueued\ndone", card?.detail)
  }

  @Test
  fun markedCommandsDecodeWithoutAnyShapeTest() {
    // :518-528: a NODE_CMD that came BACK — provenance is the mark, so no flag/name parsing and no
    // fromPairedNode gate. Action becomes the headline, payload the detail.
    val command = PopopxNodeCommand(PopopxNodeServiceId.ZeroTrustWarroom, "registry", "{\"rooms\":2}")
    val card = PopopxNodeResultCard.decodeCommand(command, now)
    assertEquals(PopopxNodeServiceId.ZeroTrustWarroom, card.serviceId)
    assertEquals(PopopxNodeResultStatus.SUCCEEDED, card.status)
    assertEquals("registry", card.headline)
    assertEquals("{\"rooms\":2}", card.detail)
    assertNull(card.durationMilliseconds)
    assertTrue(card.id.startsWith("zero_trust_warroom.$now."))
  }

  @Test
  fun statusWireValuesAndSymbols() {
    assertEquals("succeeded", PopopxNodeResultStatus.SUCCEEDED.rawValue)
    assertEquals("degraded", PopopxNodeResultStatus.DEGRADED.rawValue)
    assertEquals("checkmark.seal.fill", PopopxNodeResultStatus.SUCCEEDED.symbol)
    assertEquals("exclamationmark.triangle.fill", PopopxNodeResultStatus.DEGRADED.symbol)
  }

  @Test
  fun storedCardsRoundTripAndRejectForeignRows() {
    val card = checkNotNull(PopopxNodeResultCard.detect("\u2705 Solo Autopilot \u00b7 3 clips ready \u00b7 812 ms\nTopics: Q3", true, now))
    val json = PopopxNodeResultCard.toJson(card)
    assertEquals(card, PopopxNodeResultCard.fromJson(json))
    // An unknown service or status drops the row (unknown Codable case throws on iOS).
    val foreignService = JsonObject(json.toMutableMap().also { it["serviceId"] = JsonPrimitive("badge_credits") })
    assertNull(PopopxNodeResultCard.fromJson(foreignService))
    val foreignStatus = JsonObject(json.toMutableMap().also { it["status"] = JsonPrimitive("failed") })
    assertNull(PopopxNodeResultCard.fromJson(foreignStatus))
    // A missing required field drops it too.
    val missingHeadline = JsonObject(json.toMutableMap().also { it.remove("headline") })
    assertNull(PopopxNodeResultCard.fromJson(missingHeadline))
  }
}
