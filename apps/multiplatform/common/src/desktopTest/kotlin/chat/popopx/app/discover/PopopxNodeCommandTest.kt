package chat.popopx.app.discover

import chat.popopx.common.discover.PopopxDiscoverLimits
import chat.popopx.common.discover.PopopxNodeCommand
import chat.popopx.common.discover.PopopxNodeServiceId
import chat.popopx.common.discover.PopopxNodeWire
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The node-command wire (DiscoverCatalogModels.swift:50-186): frame, the twice-split payload rule,
// and the acceptance budget. The budget tests are the interesting ones — see the KDoc on
// PopopxNodeWire.isAccepted for why the brief's "1024 minus 20" is not the number in the Swift.

class PopopxNodeCommandTest {
  @Test
  fun encodesTheVerbatimFrame() {
    val command = PopopxNodeCommand(PopopxNodeServiceId.ShadowCos, "briefing")
    assertEquals("shadow_cos::briefing::{}", command.signalPayload)
    assertEquals("::popopx_sys::NODE_CMD::shadow_cos::briefing::{}", command.wireString)
    assertEquals(24, PopopxNodeWire.COMMAND_PREFIX.length)
    assertEquals(PopopxNodeWire.COMMAND_PREFIX.length, PopopxNodeWire.COMMAND_PREFIX_LENGTH)
    assertEquals("lock_all", PopopxNodeWire.DETERMINISTIC_LOCK_ACTION)
    assertEquals("PPXNODE1", PopopxNodeWire.PAIRING_CODE_PREFIX)
  }

  @Test
  fun parsesRoundTripAndDefaultPayload() {
    val parsed = PopopxNodeCommand.parse("shadow_cos::briefing::{}")
    assertEquals(PopopxNodeCommand(PopopxNodeServiceId.ShadowCos, "briefing"), parsed)
    val wire = PopopxNodeCommand.parseWireString("::popopx_sys::NODE_CMD::morning_tv::digest::{}")
    assertEquals(PopopxNodeServiceId.MorningTv, wire?.serviceId)
    assertEquals("digest", wire?.action)
    assertNull(PopopxNodeCommand.parseWireString("shadow_cos::briefing::{}")) // no prefix
    assertNull(PopopxNodeCommand.parseWireString(" ::popopx_sys::BADVERB::a::b::{}"))
    // A whole-line trim happens BEFORE the prefix test (:171-186 trims the paste).
    assertEquals(PopopxNodeServiceId.ChronoArk, PopopxNodeCommand.parseWireString("\n ::popopx_sys::NODE_CMD::chrono_ark::seal::{} \n")?.serviceId)
  }

  @Test
  fun payloadDoubleColonsSurviveTheTwiceSplit() {
    // THE rule: split on `::` exactly twice; everything after the second separator is the payload,
    // verbatim — `components(separatedBy:)`-style full splitting would mangle this (:137-148).
    val payload = "{\"a\":1}::spoiler::{\"b\":2}"
    val parsed = PopopxNodeCommand.parse("phantom_sentinel::lock_all::$payload")
    assertEquals(payload, parsed?.payload)
    assertEquals("phantom_sentinel::lock_all::$payload", parsed?.signalPayload)
    assertEquals(parsed, PopopxNodeCommand.parse(checkNotNull(parsed).signalPayload))
  }

  @Test
  fun trimsServiceAndActionButNeverThePayload() {
    val parsed = PopopxNodeCommand.parse("  shadow_cos  ::  briefing  ::  { } ")
    assertEquals(PopopxNodeServiceId.ShadowCos, parsed?.serviceId)
    assertEquals("briefing", parsed?.action)
    assertEquals("  { } ", parsed?.payload) // NOT trimmed (:143-146)
  }

  @Test
  fun refusesWhatTheHostWouldRefuse() {
    assertNull(PopopxNodeCommand.parse("not_a_service::briefing::{}"), "unknown engine id")
    assertNull(PopopxNodeCommand.parse("shadow_cos::::{}"), "empty action")
    assertNull(PopopxNodeCommand.parse("shadow_cos::   ::{}"), "whitespace action trims to empty")
    assertNull(PopopxNodeCommand.parse("shadow_cos::briefing::"), "empty payload")
    assertNull(PopopxNodeCommand.parse("shadow_cos"), "one segment")
    assertNull(PopopxNodeCommand.parse("shadow_cos::briefing"), "two segments")
  }

  @Test
  fun budgetCountsSegmentsNotThePrefix() {
    // used = raw + action + payload; accepted while used + 2*|::| <= 1024 (:92-97).
    // shadow_cos(10) + briefing(8): payload may reach 1006-4+... exactly: 1024-10-8-4 = 1002.
    val at = PopopxNodeCommand(PopopxNodeServiceId.ShadowCos, "briefing", "x".repeat(1_002))
    val over = PopopxNodeCommand(PopopxNodeServiceId.ShadowCos, "briefing", "x".repeat(1_003))
    assertTrue(at.isAcceptedByNode)
    assertNotNull(at.encode())
    assertEquals(PopopxDiscoverLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS, at.signalPayload.length) // 1024 exactly
    assertEquals(PopopxNodeWire.COMMAND_PREFIX.length + 1_024, at.wireString.length) // 1048 on the wire — prefix is free
    assertFalse(over.isAcceptedByNode)
    assertNull(over.encode())
    // The brief's "1024 minus 20" reading would reject `at`-shaped payloads above 984; the measured
    // rule does not, and a port with the invented limit would silently drop host-valid commands.
  }

  @Test
  fun emptyPayloadIsNeverAcceptedEvenThoughItParsesToNothing() {
    // A default-constructed command always carries "{}"; empty payload cannot be built through the
    // parser (rejected above) but CAN be built directly — isAccepted still refuses it (:93-95).
    assertFalse(PopopxNodeCommand(PopopxNodeServiceId.MorningTv, "digest", "").isAcceptedByNode)
    assertFalse(PopopxNodeCommand(PopopxNodeServiceId.MorningTv, "", "{}").isAcceptedByNode)
  }

}
