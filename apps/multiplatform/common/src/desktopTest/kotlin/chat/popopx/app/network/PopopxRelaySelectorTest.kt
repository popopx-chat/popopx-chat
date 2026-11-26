package chat.popopx.app.network

import chat.popopx.common.network.PopopxRelayBadge
import chat.popopx.common.network.PopopxRelayProbe
import chat.popopx.common.network.PopopxRelaySelector
import chat.popopx.common.network.PopopxRelayTransport
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

// The Android/JVM half of the relay latency selector. Every case here has a Swift twin in
// PopopxRelaySelectorTests.swift, because the two clients must not be able to disagree about which
// relay is preferred or about what a badge is allowed to say.
//
// Nothing in this file opens a socket. The transport is injected, which is the only way to prove the
// rule that matters most: with a proxy configured, no direct connection is attempted at all.

class PopopxRelaySelectorTest {
  private val t0 = 1_000_000_000L
  private val ttl = PopopxRelaySelector.CACHE_TTL_MS

  private fun measured(host: String, ms: Long?, at: Long = t0) =
    PopopxRelayProbe(host = host, latencyMs = ms, completedAtMs = at, reason = if (ms == null) PopopxRelaySelector.PROBE_UNREACHABLE else null)

  // region constants

  @Test
  fun probeCeilingAndCacheWindowAreTheRuledValues() {
    assertEquals(3_000L, PopopxRelaySelector.PROBE_TIMEOUT_MS)
    assertEquals(10L * 60L * 1_000L, PopopxRelaySelector.CACHE_TTL_MS)
    assertEquals(443, PopopxRelaySelector.PROBE_PORT)
    assertEquals(150L, PopopxRelaySelector.FAST_BELOW_MS)
    assertEquals(400L, PopopxRelaySelector.SLOW_BELOW_MS)
  }

  // endregion
  // region ranking

  @Test
  fun rankingOrdersMeasuredHostsByLatency() {
    val probes = mapOf(
      "smp3.popopx.im" to measured("smp3.popopx.im", 90L),
      "smp1.popopx.im" to measured("smp1.popopx.im", 240L),
      "smp2.popopx.im" to measured("smp2.popopx.im", 30L),
    )
    val hosts = listOf("smp3.popopx.im", "smp1.popopx.im", "smp2.popopx.im")
    assertEquals(
      listOf("smp2.popopx.im", "smp3.popopx.im", "smp1.popopx.im"),
      PopopxRelaySelector.rank(hosts, probes, t0 + 1_000L)
    )
    assertEquals("smp2.popopx.im", PopopxRelaySelector.preferred(hosts, probes, t0 + 1_000L))
  }

  @Test
  fun unmeasuredHostsFollowMeasuredOnesAndKeepTheirOrder() {
    val probes = mapOf("smp2.popopx.im" to measured("smp2.popopx.im", 500L))
    val hosts = listOf("smp1.popopx.im", "smp2.popopx.im", "smp3.popopx.im", "smp4.popopx.im")
    // smp2 is the only measurement, however slow, so it leads; the rest stay in the incoming (already
    // shuffled by the core) order rather than clustering on the first host.
    assertEquals(
      listOf("smp2.popopx.im", "smp1.popopx.im", "smp3.popopx.im", "smp4.popopx.im"),
      PopopxRelaySelector.rank(hosts, probes, t0 + 1L)
    )
  }

  @Test
  fun withoutMeasurementsRankingIsTheInputOrder() {
    val hosts = listOf("smp7.popopx.im", "smp2.popopx.im", "smp9.popopx.im")
    assertEquals(hosts, PopopxRelaySelector.rank(hosts, emptyMap(), t0))
    assertEquals(hosts, PopopxRelaySelector.rank(hosts, emptyMap(), t0, probingAllowed = false))
    assertNull(PopopxRelaySelector.preferred(emptyList(), emptyMap(), t0))
  }

  @Test
  fun aTimedOutHostDoesNotSinkTheOthers() {
    val probes = mapOf(
      "smp1.popopx.im" to measured("smp1.popopx.im", null),
      "smp2.popopx.im" to measured("smp2.popopx.im", 120L),
    )
    val hosts = listOf("smp1.popopx.im", "smp2.popopx.im", "smp3.popopx.im")
    assertEquals(listOf("smp2.popopx.im", "smp1.popopx.im", "smp3.popopx.im"), PopopxRelaySelector.rank(hosts, probes, t0 + 1L))
  }

  @Test
  fun freshnessWindowIsExclusiveAtTheBoundary() {
    val probes = mapOf("smp1.popopx.im" to measured("smp1.popopx.im", 40L))
    assertEquals(1, PopopxRelaySelector.fresh(probes, t0 + ttl - 1L).size)
    assertEquals(0, PopopxRelaySelector.fresh(probes, t0 + ttl).size, "exactly ttl old is stale")
    assertEquals(0, PopopxRelaySelector.fresh(probes, t0 + ttl + 1L).size)
    // A stale reading is not evidence: it neither ranks nor badges.
    assertEquals(listOf("smp1.popopx.im", "smp2.popopx.im"), PopopxRelaySelector.rank(listOf("smp1.popopx.im", "smp2.popopx.im"), probes, t0 + ttl + 1L))
    assertEquals(PopopxRelayBadge.UNKNOWN, PopopxRelaySelector.badge("smp1.popopx.im", probes, t0 + ttl + 1L))
  }

  // endregion
  // region badges

  @Test
  fun badgeThresholds() {
    fun badgeFor(ms: Long) = PopopxRelaySelector.badge("smp1.popopx.im", mapOf("smp1.popopx.im" to measured("smp1.popopx.im", ms)), t0 + 1L)
    assertEquals(PopopxRelayBadge.FAST, badgeFor(0L))
    assertEquals(PopopxRelayBadge.FAST, badgeFor(149L))
    assertEquals(PopopxRelayBadge.ACCEPTABLE, badgeFor(150L))
    assertEquals(PopopxRelayBadge.ACCEPTABLE, badgeFor(399L))
    assertEquals(PopopxRelayBadge.SLOW, badgeFor(400L))
    assertEquals(PopopxRelayBadge.SLOW, badgeFor(2_999L))
  }

  @Test
  fun badgeDistinguishesUnreachableFromUnknownFromUnmeasured() {
    val probes = mapOf(
      "smp1.popopx.im" to measured("smp1.popopx.im", null),
      "smp2.popopx.im" to measured("smp2.popopx.im", 60L),
    )
    assertEquals(PopopxRelayBadge.UNREACHABLE, PopopxRelaySelector.badge("smp1.popopx.im", probes, t0 + 1L))
    assertEquals(PopopxRelayBadge.FAST, PopopxRelaySelector.badge("smp2.popopx.im", probes, t0 + 1L))
    assertEquals(PopopxRelayBadge.UNKNOWN, PopopxRelaySelector.badge("smp3.popopx.im", probes, t0 + 1L))
  }

  @Test
  fun aProxyTurnsEveryBadgeIntoNotMeasurableEvenWithAFreshReading() {
    val probes = mapOf(
      "smp1.popopx.im" to measured("smp1.popopx.im", 20L),
      "smp2.popopx.im" to measured("smp2.popopx.im", null),
    )
    for (host in listOf("smp1.popopx.im", "smp2.popopx.im", "smp3.popopx.im")) {
      assertEquals(
        PopopxRelayBadge.UNAVAILABLE,
        PopopxRelaySelector.badge(host, probes, t0 + 1L, probingAllowed = false),
        "$host must not show a number while a proxy is on"
      )
    }
  }

  // endregion
  // region the probe seam

  /** Records what the selector asked for, so "no socket" is an assertion and not a comment. */
  private class Recorder(private val latencies: Map<String, Long?> = emptyMap()) : PopopxRelayTransport {
    val hosts = Collections.synchronizedList(mutableListOf<String>())
    val calls = AtomicInteger(0)
    var port = -1
    var timeout = -1L

    override suspend fun handshakeMillis(host: String, port: Int, timeoutMs: Long): Long? {
      calls.incrementAndGet()
      hosts.add(host)
      this.port = port
      this.timeout = timeoutMs
      return latencies[host]
    }
  }

  @Test
  fun withAProxyActiveNotOneDirectHandshakeIsAttempted() = runBlocking {
    val recorder = Recorder(mapOf("smp1.popopx.im" to 40L, "smp2.popopx.im" to 80L))
    val hosts = listOf("smp1.popopx.im", "smp2.popopx.im")

    val refused = PopopxRelaySelector.probe(hosts, allowed = false, transport = recorder)
    assertEquals(0, recorder.calls.get(), "a direct probe while a proxy is on leaks the public address")
    assertTrue(refused.isEmpty())

    // Control: the same call with the gate open really does fan out, so the zero above is the gate
    // and not a broken recorder.
    val round = PopopxRelaySelector.probe(hosts, allowed = true, transport = recorder)
    assertEquals(2, recorder.calls.get())
    assertEquals(2, round.size)
    assertEquals(443, recorder.port)
    assertEquals(3_000L, recorder.timeout)
    assertEquals(40L, round.getValue("smp1.popopx.im").latencyMs)
    assertTrue(round.getValue("smp1.popopx.im").healthy)
  }

  @Test
  fun anEmptyHostSetProbesNothingEvenWhenAllowed() = runBlocking {
    val recorder = Recorder()
    assertTrue(PopopxRelaySelector.probe(emptyList(), allowed = true, transport = recorder).isEmpty())
    assertEquals(0, recorder.calls.get())
  }

  @Test
  fun aHostThatNeverAnswersIsRecordedAsUnhealthyNotSilentlyDropped() = runBlocking {
    val recorder = Recorder(mapOf("smp1.popopx.im" to 50L, "smp2.popopx.im" to null))
    val round = PopopxRelaySelector.probe(listOf("smp1.popopx.im", "smp2.popopx.im"), allowed = true, transport = recorder)
    assertEquals(2, round.size, "a failure is still an answer about that host")
    val failed = round.getValue("smp2.popopx.im")
    assertNull(failed.latencyMs)
    assertEquals(PopopxRelaySelector.PROBE_UNREACHABLE, failed.reason)
    assertEquals(false, failed.healthy)
  }

  // endregion
  // region cache merging

  @Test
  fun aRefusedRoundKeepsTheOldReadingsButADeletedHostStillLeaves() {
    val previous = mapOf(
      "smp1.popopx.im" to measured("smp1.popopx.im", 30L),
      "smp2.popopx.im" to measured("smp2.popopx.im", 60L),
    )
    val merged = PopopxRelaySelector.merged(previous, emptyMap(), listOf("smp1.popopx.im"))
    assertEquals(setOf("smp1.popopx.im"), merged.keys)
    assertEquals(30L, merged.getValue("smp1.popopx.im").latencyMs)
    // A refused round is not evidence that a relay got worse, so the badge survives; the badge, not
    // the cache, is what the proxy gate hides.
    assertEquals(PopopxRelayBadge.UNAVAILABLE, PopopxRelaySelector.badge("smp1.popopx.im", merged, t0 + 1L, probingAllowed = false))
  }

  @Test
  fun aRealRoundReplacesTheHostsItCoveredAndLeavesTheOthersAlone() {
    val previous = mapOf(
      "smp1.popopx.im" to measured("smp1.popopx.im", 30L),
      "smp2.popopx.im" to measured("smp2.popopx.im", 60L),
    )
    // This round covered smp1 only; the other group's servers, or xftp, are a different host set.
    val round = mapOf("smp1.popopx.im" to measured("smp1.popopx.im", null, at = t0 + 5_000L))
    val merged = PopopxRelaySelector.merged(previous, round, listOf("smp1.popopx.im"))
    assertEquals(2, merged.size)
    assertNull(merged.getValue("smp1.popopx.im").latencyMs)
    assertEquals(60L, merged.getValue("smp2.popopx.im").latencyMs, "hosts outside this round keep their reading")
    assertEquals(PopopxRelayBadge.UNREACHABLE, PopopxRelaySelector.badge("smp1.popopx.im", merged, t0 + 5_001L))
    assertEquals(PopopxRelayBadge.FAST, PopopxRelaySelector.badge("smp2.popopx.im", merged, t0 + 5_001L))
  }

  // endregion
}
