package chat.popopx.app.discover

//
//  PopopxNodeUpdateWireTest.kt
//  desktopTest
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The `::POPOPX_UPD::v1` card reader, mirroring
//  apps/ios/PopopxMeshKit/Tests/PopopxMeshKitTests/PopopxNodeUpdateWireTests.swift case for case. Display
//  fields are optional because the producer drops them under its own size ceiling; the two commands are not
//  optional and are not re-encoded, because the phone's only job with a receipt it cannot mint is to hand it
//  back exactly as it arrived.
//
//  Nothing here is a self-consistency check: the marker line below is transcribed from the producer
//  (MacNodePopopxBridge.swift:2482-2486 with MacNodeModels.swift:1626-1631), including the lead-in that makes
//  a whole-string signal test miss it.
//

import chat.popopx.common.discover.PopopxNodeUpdateWire
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class PopopxNodeUpdateWireTest {

  // MARK: The happy path

  @Test
  fun parsesInLine() {
    val notice = assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(card))
    assertEquals("1.3.0", notice.version)
    assertEquals("1300", notice.build)
    assertEquals("2026-11-26", notice.releasedAt)
    assertEquals("a1b2c3d4e5f6", notice.shortSha)
    assertEquals("3", notice.summaryCount)
    assertEquals(listOf("Fixes a mesh relay timeout", "Adds a Discover feed", "Smaller IPA"), notice.summaryLines)
    assertTrue(notice.hasSummary)
    // The whole-string form of a signal check — what a marker-only test would do — cannot see this message
    // at all. Recorded because it is why suppression is a separate predicate.
    assertTrue(card.startsWith("✅"))
    assertFalse(card.startsWith(PopopxNodeUpdateWire.MARKER))
  }

  @Test
  fun commandsAreEchoedVerbatim() {
    val notice = assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(card))
    assertEquals(approve, notice.approveCommand)
    assertEquals(snooze, notice.snoozeCommand)
    assertTrue(notice.approveCommand.startsWith(PopopxNodeUpdateWire.APPROVE_COMMAND_PREFIX))
    assertTrue(notice.snoozeCommand.startsWith(PopopxNodeUpdateWire.SNOOZE_COMMAND_PREFIX))
    // Nothing was re-serialized: the braces and quotes of the receipt are still in the string.
    assertTrue(notice.approveCommand.contains(DQ + "rcp" + DQ + ":"))
  }

  // MARK: The shapes the producer chooses

  @Test
  fun droppedDisplayFieldsAreASupportedShape() {
    val trimmed = leadIn + PopopxNodeUpdateWire.MARKER + "v1|v=1.3.0|approve=" + approve + "|snooze=" + snooze
    val notice = assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(trimmed))
    assertEquals("1.3.0", notice.version)
    assertEquals(null, notice.build)
    assertEquals(null, notice.releasedAt)
    assertEquals(null, notice.shortSha)
    assertEquals(null, notice.summaryCount)
    assertTrue(notice.summaryLines.isEmpty())
    assertFalse(notice.hasSummary)
    assertEquals(approve, notice.approveCommand)
  }

  @Test
  fun emptyDisplayValueReadsAsAbsent() {
    val text = leadIn + PopopxNodeUpdateWire.MARKER + "v1|v=1.3.0|b=|d=|s=|n=|approve=" + approve + "|snooze=" + snooze
    val notice = assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(text))
    assertEquals(null, notice.build)
    assertEquals(null, notice.releasedAt)
    assertEquals(null, notice.shortSha)
    assertEquals(null, notice.summaryCount)
  }

  @Test
  fun aFutureFieldIsIgnoredNotFatal() {
    val text = leadIn + PopopxNodeUpdateWire.MARKER + "v1|z=whatever|v=1.3.0|q|x=|approve=" + approve + "|snooze=" + snooze
    val notice = assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(text))
    assertEquals("1.3.0", notice.version)
  }

  @Test
  fun aCommandMayContainTheFieldSeparator() {
    // Commands are never truncated, so a separator inside one is the producer's problem only in appearance.
    val wide = PopopxNodeUpdateWire.APPROVE_COMMAND_PREFIX + "{" + DQ + "v" + DQ + ":" + DQ + "1.3.0" + DQ +
      "," + DQ + "rcp" + DQ + ":" + DQ + "a|b" + DQ + "}"
    val text = leadIn + PopopxNodeUpdateWire.MARKER + "v1|v=1.3.0|approve=" + wide + "|snooze=" + snooze
    val notice = assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(text))
    assertEquals(wide, notice.approveCommand)
    assertTrue(notice.approveCommand.contains("|"))
    assertEquals(snooze, notice.snoozeCommand)
  }

  // MARK: Refusals

  @Test
  fun anythingUnanswerableReadsAsOrdinaryText() {
    val cases = listOf(
      "no marker at all" to "A message about 1.3.0 on your Mac",
      "marker with no version segment" to leadIn + PopopxNodeUpdateWire.MARKER + "|v=1.3.0|approve=" + approve + "|snooze=" + snooze,
      "a different version" to markerLine.replace("UPD::v1", "UPD::v2"),
      "a longer version prefix read as v1" to markerLine.replace("UPD::v1|", "UPD::v10|"),
      "missing approve" to markerLine.replace("|approve=" + approve, ""),
      "missing snooze" to markerLine.replace("|snooze=" + snooze, ""),
      "no version field" to markerLine.replace("|v=1.3.0", ""),
      "empty version" to markerLine.replace("|v=1.3.0", "|v="),
      "approve is not an update command" to markerLine.replace(approve, "::popopx_sys::NODE_CMD::mesh::reset::{}"),
      "snooze is not an update command" to markerLine.replace(snooze, "rm -rf /"),
      "commands in the other order" to markerLine.replace(
        "|approve=" + approve + "|snooze=" + snooze,
        "|snooze=" + snooze + "|approve=" + approve,
      ),
    )
    for ((name, text) in cases) {
      assertEquals(null, PopopxNodeUpdateWire.parseVisibleCard(text), name + " parsed")
      assertFalse(PopopxNodeUpdateWire.isUpdateCard(text), name + " reported as a card")
    }
  }

  @Test
  fun markerPositionIsNotTheGate() {
    // Deliberately tolerant: a producer that later wraps the line in markdown or brackets still renders
    // instead of silently losing the card. Nothing here believes the marker — the two command prefixes are
    // what is checked, and the receipt inside them is verified node-side.
    val wrapped = "```" + PopopxNodeUpdateWire.MARKER + "v1|v=1.3.0|approve=" + approve + "|snooze=" + snooze + "```"
    val notice = assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(wrapped))
    assertEquals("1.3.0", notice.version)
    assertEquals(approve, notice.approveCommand)
  }

  @Test
  fun oversizedMarkerLineIsNotTheProducersOutput() {
    val padded = leadIn + PopopxNodeUpdateWire.MARKER + "v1|v=" + "a".repeat(PopopxNodeUpdateWire.MAXIMUM_LINE_CHARACTERS) +
      "|approve=" + approve + "|snooze=" + snooze
    assertEquals(null, PopopxNodeUpdateWire.parseVisibleCard(padded))
    // Just under the ceiling still parses, so the refusal is the size and not the padding.
    assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(markerLine))
  }

  // MARK: The summary body

  @Test
  fun onlyTheBulletLinesBelowTheMarkerBecomeTheSummary() {
    val bullet = PopopxNodeUpdateWire.BULLET + " "
    val many = (1..12).joinToString(NL) { bullet + "line " + it }
    val notice = assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(markerLine + BLANK + many))
    assertEquals(PopopxNodeUpdateWire.MAXIMUM_SUMMARY_LINES, notice.summaryLines.size)
    assertEquals("line 1", notice.summaryLines.first())
    assertEquals("line 8", notice.summaryLines.last())

    // A bullet above the marker line belongs to the previous message, not to this card.
    val before = bullet + "earlier note" + NL + markerLine + NL + bullet + "after"
    assertEquals(listOf("after"), assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(before)).summaryLines)

    // The node writes "（无更新说明 / no summary）" when there is nothing to say: prose stays prose.
    val prose = markerLine + BLANK + "（无更新说明 / no summary）" + NL + "Updated just now."
    assertTrue(notNull(PopopxNodeUpdateWire.parseVisibleCard(prose)).summaryLines.isEmpty())

    // Trailing whitespace and an empty bullet are dropped rather than rendered as a blank row.
    val ragged = markerLine + BLANK + bullet + "  spaced  " + NL + bullet + NL
    assertEquals(listOf("spaced"), notNull(PopopxNodeUpdateWire.parseVisibleCard(ragged)).summaryLines)
  }

  @Test
  fun summaryLinesAnswersTheBodyAlone() {
    assertEquals(3, PopopxNodeUpdateWire.summaryLines(card).size)
    assertTrue(PopopxNodeUpdateWire.summaryLines("no marker here" + NL + PopopxNodeUpdateWire.BULLET + " but a bullet").isEmpty())
  }

  @Test
  fun repeatedReadsAgree() {
    // The mount asks this per message and per list row; anything state-dependent would flicker.
    val first = assertNotNull(PopopxNodeUpdateWire.parseVisibleCard(card))
    assertEquals(first, PopopxNodeUpdateWire.parseVisibleCard(card))
    assertTrue(PopopxNodeUpdateWire.isUpdateCard(card))
  }

  // MARK: Fixtures

  private fun notNull(notice: PopopxNodeUpdateWire.Notice?): PopopxNodeUpdateWire.Notice =
    assertNotNull(notice, "the card did not parse")

  private companion object {
    private const val DQ = "\""
    private val NL = 0x0A.toChar().toString()
    private val BLANK = NL + NL

    /** `MacNodePopopxBridge.swift:2482` sends the card text, and `MacNodeModels.swift:1626-1631` builds it
     * with a lead-in, so a receiver that compared whole strings never sees the marker. */
    private val leadIn = "✅ POPOPX 更新 / Update · "

    private val approve: String = PopopxNodeUpdateWire.APPROVE_COMMAND_PREFIX + receipt("1.3.0", "9f2c1a7b4e8d3c6a1b0f5e2d")
    private val snooze: String = PopopxNodeUpdateWire.SNOOZE_COMMAND_PREFIX + receipt("1.3.0", "4a1b0f5e2d9f2c1a7b4e8d3c")

    private fun receipt(version: String, rcp: String): String =
      "{" + DQ + "v" + DQ + ":" + DQ + version + DQ + "," + DQ + "rcp" + DQ + ":" + DQ + rcp + DQ + "}"

    private val markerLine: String = leadIn + PopopxNodeUpdateWire.MARKER + PopopxNodeUpdateWire.SCHEMA_VERSION +
      "|v=1.3.0|b=1300|d=2026-11-26|s=a1b2c3d4e5f6|n=3|approve=" + approve + "|snooze=" + snooze

    /** The line, then a blank line and the body — the exact shape the bridge delivers. */
    private val card: String = markerLine + BLANK + "1.3.0 is available on your Mac." + NL +
      "· Fixes a mesh relay timeout" + NL + "· Adds a Discover feed" + NL + "· Smaller IPA"
  }
}
