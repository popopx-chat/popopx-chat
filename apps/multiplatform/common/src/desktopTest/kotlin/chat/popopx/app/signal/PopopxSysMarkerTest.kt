package chat.popopx.app.signal

import chat.popopx.common.signal.PopopxSignal
import chat.popopx.common.signal.PopopxSignalKind
import chat.popopx.common.signal.PopopxSignalLimits
import chat.popopx.common.signal.PopopxSignalParseResult
import chat.popopx.common.signal.PopopxSysMarker
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The frame codec, against PopopxBadgeCreditsModels.swift:1152-1205.
//
// The thirteen round trips pin the wire strings character for character; the hostile cases pin the
// promise that nothing throws AND nothing is guessed — every rejection names its own reason,
// because "the router must never throw on hostile input" is only testable if each hostile shape
// has an identity.

class PopopxSysMarkerTest {
  @Test
  fun everyKindRoundTripsThroughItsOwnWireString() {
    assertEquals(13, PopopxSignalKind.entries.size)
    for (kind in PopopxSignalKind.entries) {
      val payload = "payload-for-$kind"
      val signal = PopopxSignal(kind, payload)
      val text = PopopxSysMarker.wireString(signal)
      assertEquals(signalWire(kind, payload), text, "wire spelling of $kind")
      val parsed = PopopxSysMarker.parse(text)
      assertNotNull(parsed, "$kind must parse back")
      assertEquals(kind, parsed.kind)
      assertEquals(payload, parsed.payload)
    }
  }

  @Test
  fun theWireStringsAreTheSpecsCharacterForCharacter() {
    // Models:1092-1125 raw values, sampled where a typo would silently unpair the two platforms.
    assertEquals("EXT_REDEEM_REQ", PopopxSignalKind.EXTERNAL_REDEEM_REQ.raw)
    assertEquals("EXT_REDEEM_ACK", PopopxSignalKind.EXTERNAL_REDEEM_ACK.raw)
    assertEquals("CHAT_REDEEM_REQ", PopopxSignalKind.CHAT_REDEEM_REQ.raw)
    assertEquals("CHAT_REDEEM_ACK", PopopxSignalKind.CHAT_REDEEM_ACK.raw)
    assertEquals("REDPACKET_CLAIMED", PopopxSignalKind.REDPACKET_CLAIMED.raw)
    assertEquals("PROFILE_UNLOCKED", PopopxSignalKind.PROFILE_UNLOCKED.raw)
    assertEquals("CHANNEL_SUB_ACK", PopopxSignalKind.CHANNEL_SUB_ACK.raw)
    assertEquals("CHANNEL_PAY_RCPT", PopopxSignalKind.CHANNEL_PAY_RCPT.raw)
    assertEquals("CREDIT_EXT_REDEEM_REQ", PopopxSignalKind.CREDIT_EXT_REDEEM_REQ.raw)
    assertEquals("CREDIT_EXT_REDEEM_ACK", PopopxSignalKind.CREDIT_EXT_REDEEM_ACK.raw)
    assertEquals("CREDIT_CHAT_REDEEM_REQ", PopopxSignalKind.CREDIT_CHAT_REDEEM_REQ.raw)
    assertEquals("CREDIT_CHAT_REDEEM_ACK", PopopxSignalKind.CREDIT_CHAT_REDEEM_ACK.raw)
    assertEquals("NODE_CMD", PopopxSignalKind.NODE_CMD.raw)
    assertEquals(
      "::popopx_sys::REDPACKET_CLAIMED::packet-1",
      PopopxSysMarker.wireString(PopopxSignalKind.REDPACKET_CLAIMED, "packet-1"),
    )
  }

  @Test
  fun proseThatMerelyQuotesTheMarkerIsNotExecutable() {
    // The reason whole-string parsing exists (Models:1153-1156): a screenshot caption is not a frame.
    val quoted = "look at this screenshot of ${PopopxSysMarker.MARKER}EXT_REDEEM_REQ::x"
    assertIs<PopopxSignalParseResult.NotSignal.MissingPrefix>(PopopxSysMarker.parseOutcome(quoted))
    assertFalse(PopopxSysMarker.isSignalText(quoted))
  }

  @Test
  fun eachHostileShapeHasItsOwnNameAndNoneOfThemThrows() {
    val cases: List<Pair<String, PopopxSignalParseResult>> = listOf(
      "" to PopopxSignalParseResult.NotSignal.MissingPrefix,
      "hello" to PopopxSignalParseResult.NotSignal.MissingPrefix,
      PopopxSysMarker.MARKER to PopopxSignalParseResult.NotSignal.MissingBodySeparator,
      "${PopopxSysMarker.MARKER}REDPACKET_CLAIMED" to PopopxSignalParseResult.NotSignal.MissingBodySeparator,
      // A single colon is not a separator (Models:1168-1170): slicing a kind out of it would be the
      // easiest silent misalignment in the codec.
      "${PopopxSysMarker.MARKER}EXT_REDEEM_REQ:abc" to PopopxSignalParseResult.NotSignal.MissingBodySeparator,
      "${PopopxSysMarker.MARKER}NOT_A_KIND::x" to PopopxSignalParseResult.NotSignal.UnknownKind("NOT_A_KIND"),
      // Case is part of the protocol.
      "${PopopxSysMarker.MARKER}redpacket_claimed::x" to PopopxSignalParseResult.NotSignal.UnknownKind("redpacket_claimed"),
      "${PopopxSysMarker.MARKER}::x" to PopopxSignalParseResult.NotSignal.UnknownKind(""),
      "${PopopxSysMarker.MARKER}NODE_CMD::" to PopopxSignalParseResult.NotSignal.EmptyBody,
    )
    for ((text, expected) in cases) {
      val actual = PopopxSysMarker.parseOutcome(text)
      assertEquals(expected, actual, "outcome of [$text]")
      assertIs<PopopxSignalParseResult.NotSignal>(actual)
      assertNull(PopopxSysMarker.parse(text))
      assertFalse(PopopxSysMarker.isSignalText(text))
    }
  }

  @Test
  fun oversizedPayloadsAreRefusedNotDecoded() {
    // Models:47 ceiling, Models:1177 guard. Ten times over, per the hostile-input brief.
    val atTheCeiling = "x".repeat(PopopxSignalLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS)
    assertIs<PopopxSignalParseResult.Parsed>(PopopxSysMarker.parseOutcome(signalWire(PopopxSignalKind.CHAT_REDEEM_REQ, atTheCeiling)))

    val over = "x".repeat(PopopxSignalLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS + 1)
    assertIs<PopopxSignalParseResult.NotSignal.OversizeBody>(
      PopopxSysMarker.parseOutcome(signalWire(PopopxSignalKind.CHAT_REDEEM_REQ, over))
    )

    val tenTimes = "x".repeat(PopopxSignalLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS * 10)
    val huge = PopopxSysMarker.parseOutcome(signalWire(PopopxSignalKind.EXTERNAL_REDEEM_ACK, tenTimes))
    assertIs<PopopxSignalParseResult.NotSignal.OversizeBody>(huge)
    assertEquals(PopopxSignalLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS * 10, huge.characters)
  }

  @Test
  fun theFirstSeparatorIsTheOnlySeparator() {
    // Models:1168-1173 + :1117-1119: the host's three-part NODE_CMD shape keeps its inner `::`.
    val wire = "::popopx_sys::NODE_CMD::shadow_cos::briefing::{\"k\":\"v::w\"}"
    val parsed = PopopxSysMarker.parse(wire)
    assertNotNull(parsed)
    assertEquals(PopopxSignalKind.NODE_CMD, parsed.kind)
    assertEquals("shadow_cos::briefing::{\"k\":\"v::w\"}", parsed.payload)
    assertEquals(wire, PopopxSysMarker.wireString(parsed))
  }

  @Test
  fun surroundingWhitespaceIsTrimmedBeforeThePrefixJudge() {
    // Models:1165 — Swift trims `.whitespacesAndNewlines`; `trim { it.isWhitespace() }` is the same set.
    val padded = " \t\n" + signalWire(PopopxSignalKind.PROFILE_UNLOCKED, "profile-7") + "\r\n"
    val parsed = PopopxSysMarker.parse(padded)
    assertNotNull(parsed)
    assertEquals(PopopxSignalKind.PROFILE_UNLOCKED, parsed.kind)
    assertEquals("profile-7", parsed.payload)
    assertTrue(PopopxSysMarker.isSignalText(padded))
  }

  @Test
  fun isSignalTextAndParseShareOneCriterion() {
    // The three UI suppression gates read this one function (router header:10-12); the router reads
    // the other. They must never disagree, so they must be the same computation.
    for (kind in PopopxSignalKind.entries) {
      val wire = signalWire(kind, "body")
      assertEquals(PopopxSysMarker.parse(wire) != null, PopopxSysMarker.isSignalText(wire))
      assertTrue(PopopxSysMarker.isSignalText(wire))
    }
    assertFalse(PopopxSysMarker.isSignalText("::popopx_sys::NODE_CMD::"))
  }

  @Test
  fun requestAndGroupFlagsAreTheMeasuredTables() {
    // Models:1131-1133 and :1142-1149, listed rather than inferred.
    val inGroup = PopopxSignalKind.entries.filter { it.acceptedInGroup }.map { it.raw }.sorted()
    assertEquals(listOf("CHANNEL_PAY_RCPT", "CHANNEL_SUB_ACK", "REDPACKET_CLAIMED"), inGroup)
    val requests = PopopxSignalKind.entries.filter { it.isRequest }.map { it.raw }.sorted()
    assertEquals(
      listOf("CHAT_REDEEM_REQ", "CREDIT_CHAT_REDEEM_REQ", "CREDIT_EXT_REDEEM_REQ", "EXT_REDEEM_REQ"),
      requests,
    )
    val acks = PopopxSignalKind.entries.filter { it.isAcknowledgement }.map { it.raw }.sorted()
    assertEquals(
      listOf("CHAT_REDEEM_ACK", "CREDIT_CHAT_REDEEM_ACK", "CREDIT_EXT_REDEEM_ACK", "EXT_REDEEM_ACK"),
      acks,
    )
  }
}
