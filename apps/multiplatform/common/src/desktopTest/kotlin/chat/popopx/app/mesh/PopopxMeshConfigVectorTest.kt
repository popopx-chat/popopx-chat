package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxGCSFilter
import chat.popopx.common.mesh.PopopxMeshConfig
import chat.popopx.common.mesh.PopopxMeshPeerID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The tunables, one row per field, taken from `PopopxMeshConfig.default` inside the compiled iOS tree
 * rather than from its source text.
 *
 * Every value here is a cross-end obligation, not a preference: two nodes that disagree about
 * `fragmentSize` split streams differently, and two that disagree about `relayMinDelay` flood at
 * different rates. The `when` below is exhaustive on purpose - a row this file does not know about
 * fails instead of going unchecked, which is also what makes an added iOS field show up here.
 */
internal class PopopxMeshConfigVectorTest {
  @Test
  fun configLiteralsMatchIOS() {
    val config = PopopxMeshConfig.default
    val rows = V.rows("config")
    assertEquals(28, rows.size, "one row per field of PopopxMeshConfig.default")
    for ((label, value) in rows) {
      val ours =
        when (label) {
          "config.ttlDefault" -> config.ttlDefault
          "config.fragmentRelayTtlCap" -> config.fragmentRelayTtlCap
          "config.highDegreeThreshold" -> config.highDegreeThreshold
          "config.denseBroadcastTtlCap" -> config.denseBroadcastTtlCap
          "config.fragmentSize" -> config.fragmentSize
          "config.maxMTU" -> config.maxMTU
          "config.fragmentLifetime" -> config.fragmentLifetime
          "config.maxInFlightAssemblies" -> config.maxInFlightAssemblies
          "config.relayMinDelay" -> config.relayMinDelay
          "config.relayMaxDelay" -> config.relayMaxDelay
          "config.recentPacketWindow" -> config.recentPacketWindow
          "config.recentPacketMaxCount" -> config.recentPacketMaxCount
          "config.messageDedupMaxAge" -> config.messageDedupMaxAge
          "config.messageDedupMaxCount" -> config.messageDedupMaxCount
          "config.scanOnDuration" -> config.scanOnDuration
          "config.scanOffDuration" -> config.scanOffDuration
          "config.announceInterval" -> config.announceInterval
          "config.connectTimeout" -> config.connectTimeout
          "config.maxCentralLinks" -> config.maxCentralLinks
          "config.maintenanceInterval" -> config.maintenanceInterval
          "config.peerReachabilityTimeout" -> config.peerReachabilityTimeout
          "config.bleAckTimeout" -> config.bleAckTimeout
          "config.smpAckTimeout" -> config.smpAckTimeout
          "config.serviceUUID" -> config.serviceUUID
          "config.characteristicUUID" -> config.characteristicUUID
          "config.centralRestoreIdentifier" -> config.centralRestoreIdentifier
          "config.peripheralRestoreIdentifier" -> config.peripheralRestoreIdentifier
          "config.noiseTransportOverhead" -> config.noiseTransportOverhead
          else -> fail("config row $label is not covered by this test")
        }
      assertEquals(value, ours.toString(), label)
    }
    // This number is read from elsewhere in the port as well, so it is one fact and not two.
    assertEquals(config.noiseTransportOverhead, V.int("noise", "noise.frameOverhead"))
  }

  /**
   * The freeze these suites were written against. Row counts are what a truncated generation changes
   * first, and every test here walks a section by position, so a short file would otherwise be read as
   * agreement by the sections that survived.
   */
  @Test
  fun freezeIsTheOneTheseSuitesWereWrittenAgainst() {
    assertEquals(601, PopopxMeshSwiftVectors.ROW_COUNT)
    assertEquals(
      listOf(
        "noise",
        "identity",
        "xxEmpty",
        "xxPayload",
        "xxFail",
        "session",
        "window",
        "packet",
        "packetBad",
        "decode",
        "pad",
        "envelope",
        "announceOrder",
        "announceShape",
        "envelopeDecode",
        "control",
        "fragment",
        "gcs",
        "config",
      ),
      PopopxMeshSwiftVectors.SECTION_NAMES,
    )
    val counts =
      mapOf(
        "noise" to 12,
        "identity" to 12,
        "xxEmpty" to 36,
        "xxPayload" to 36,
        "xxFail" to 16,
        "session" to 46,
        "window" to 20,
        "packet" to 72,
        "packetBad" to 5,
        "decode" to 10,
        "pad" to 84,
        "envelope" to 63,
        "announceOrder" to 4,
        "announceShape" to 10,
        "envelopeDecode" to 92,
        "control" to 7,
        "fragment" to 28,
        "gcs" to 20,
        "config" to 28,
      )
    assertEquals(PopopxMeshSwiftVectors.SECTION_NAMES.toSet(), counts.keys, "one count per section")
    for ((section, count) in counts) {
      assertEquals(count, V.rows(section).size, "row count for $section")
      val prefixes = sectionPrefixes(section)
      assertTrue(
        V.rows(section).all { row -> prefixes.any { row.first.startsWith(it) } },
        "every $section label is namespaced with one of $prefixes",
      )
    }
    assertEquals(601, counts.values.sum(), "the sections add up to the total")
    assertEquals(46, V.rows("envelopeDecode").count { it.first.endsWith(".in") }, "46 decode probes")
    assertEquals(14, V.rows("pad").chunked(6).size, "thirteen buckets plus the unpad counterexamples")
    assertEquals(7, V.rows("envelope").chunked(9).size, "seven envelopes")
    assertEquals(3, V.rows("control").count { it.first.startsWith("control.accept") }, "three accepted control frames")
    assertEquals(4, V.rows("control").count { it.first.startsWith("control.reject") }, "four refusals")
    // Constants the port states next to the config, so a drift here would be a second source of truth.
    assertEquals(8, PopopxMeshPeerID.BYTE_COUNT, "the width every peer id is truncated to")
    assertEquals(4096, PopopxGCSFilter.MAX_ENCODED_BYTES)
  }

  /** The section names are label prefixes, except the two announce blocks the tool printed together. */
  /** The sections are blocks the tool printed, so four of them are not the one label prefix they hold. */
  private fun sectionPrefixes(section: String): List<String> =
    when (section) {
      "xxEmpty", "xxPayload" -> listOf("xx.")
      "xxFail" -> listOf("xxfail.")
      "announceOrder" -> listOf("announce.")
      "pad" -> listOf("pad.", "unpad.")
      else -> listOf("$section.")
    }

  private companion object {
    val V = PopopxMeshSwiftVectors
  }
}
