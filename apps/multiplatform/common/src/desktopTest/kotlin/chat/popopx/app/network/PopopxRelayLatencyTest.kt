package chat.popopx.app.network

import chat.popopx.common.network.PopopxRelayBadge
import chat.popopx.common.network.PopopxRelayLatency
import chat.popopx.common.network.PopopxRelaySelector
import chat.popopx.common.network.PopopxRelayTransport
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

// The store behind the Android latency badge. PopopxRelaySelectorTest.kt proves the decisions; this
// file proves the two things that only matter once the decisions are shared between screens: nobody
// probes when the proxy gate is closed, and nobody probes twice because two screens opened at once.
//
// As in the selector test, the transport is injected and no socket is opened here — which is the only
// way the first rule is an assertion instead of a comment.

class PopopxRelayLatencyTest {
  private val hosts = listOf("smp1.popopx.im", "smp2.popopx.im", "smp3.popopx.im")

  /** Records every handshake it is asked for, so "zero sockets" is a number. */
  private class Recorder(private val latencies: Map<String, Long?> = emptyMap()) : PopopxRelayTransport {
    val hosts = Collections.synchronizedList(mutableListOf<String>())
    val calls = AtomicInteger(0)

    override suspend fun handshakeMillis(host: String, port: Int, timeoutMs: Long): Long? {
      calls.incrementAndGet()
      hosts.add(host)
      return latencies[host]
    }
  }

  /**
   * A [Recorder] that parks inside the first handshake until a test lets it go, so another caller can
   * be proved to overlap the round rather than merely to follow it.
   */
  private class GatedRecorder(private val latencies: Map<String, Long?> = emptyMap()) : PopopxRelayTransport {
    val calls = AtomicInteger(0)
    val entered = CompletableDeferred<Unit>()
    private val release = CompletableDeferred<Unit>()

    override suspend fun handshakeMillis(host: String, port: Int, timeoutMs: Long): Long? {
      if (calls.incrementAndGet() == 1) entered.complete(Unit)
      release.await()
      return latencies[host]
    }

    fun letGo() {
      release.complete(Unit)
    }
  }

  // region the proxy gate

  @Test
  fun aRefreshWithTheGateClosedProbesNothingAndEveryBadgeSaysNotMeasurable() = runBlocking {
    val recorder = Recorder(mapOf("smp1.popopx.im" to 40L, "smp2.popopx.im" to 80L, "smp3.popopx.im" to 120L))
    val store = PopopxRelayLatency()

    val cached = store.refresh(hosts, probingAllowed = false, transport = recorder)

    assertEquals(0, recorder.calls.get(), "a direct probe behind a proxy leaks the address the proxy exists to hide")
    assertTrue(cached.isEmpty())
    for (host in hosts) {
      assertEquals(PopopxRelayBadge.UNAVAILABLE, store.badge(host, probingAllowed = false), host)
    }
    // Nothing is reordered either: without evidence the core's own shuffled order stands.
    assertEquals(hosts, store.ranked(hosts, probingAllowed = false))

    // Control: the same store and the same recorder with the gate open really do fan out, so the zero
    // above is the gate and not a dead recorder.
    val round = store.refresh(hosts, probingAllowed = true, transport = recorder)
    assertEquals(3, recorder.calls.get())
    assertEquals(3, round.size)
    assertEquals(PopopxRelayBadge.FAST, store.badge("smp1.popopx.im", probingAllowed = true))
    // Closing the gate again hides the live reading it just took, and does not probe on the way back.
    assertEquals(PopopxRelayBadge.UNAVAILABLE, store.badge("smp1.popopx.im", probingAllowed = false))
    assertEquals(3, recorder.calls.get(), "a closed gate must not probe to find out it is closed")
  }

  // endregion
  // region one round at a time

  @Test
  fun twoConcurrentRefreshesShareOneRound() = runBlocking {
    val gate = GatedRecorder(hosts.associateWith { 50L })
    val store = PopopxRelayLatency()

    val first = async { store.refresh(hosts, probingAllowed = true, transport = gate) }
    gate.entered.await()
    val second = async { store.refresh(hosts, probingAllowed = true, transport = gate) }
    gate.letGo()
    val results = listOf(first, second).awaitAll()

    assertEquals(3, gate.calls.get(), "two callers over three hosts are three handshakes, not six")
    assertEquals(results[0], results[1], "the joined caller reads the same cache as the caller that started the round")
    assertEquals(3, store.probes().size)
  }

  @Test
  fun aCallerThatJoinsARoundCoveringFewerHostsDoesNotStartASecondOne() = runBlocking {
    val gate = GatedRecorder(hosts.associateWith { 50L })
    val store = PopopxRelayLatency()

    // The open round covers two hosts; the newcomer asks for three, and cannot be satisfied from the
    // cache. It joins anyway: one fan-out at a time is the rule, and the host nobody probed simply
    // stays unmeasured until the next refresh.
    val partial = async { store.refresh(hosts.take(2), probingAllowed = true, transport = gate) }
    gate.entered.await()
    val full = async { store.refresh(hosts, probingAllowed = true, transport = gate) }
    // The round only closes when the gate opens, so the newcomer is proved to be mid-flight by running
    // it to the point where it has already looked at inFlight. Without this it queues behind the test
    // body and may arrive after letGo(), by which time the round has finished and joining is impossible.
    yield()
    gate.letGo()
    partial.await()
    full.await()

    assertEquals(2, gate.calls.get(), "the joined round probed the hosts it was started with")
    assertEquals(2, store.probes().size)
    assertEquals(PopopxRelayBadge.UNKNOWN, store.badge("smp3.popopx.im", probingAllowed = true))
  }

  // endregion
  // region the cache window

  @Test
  fun aFreshCacheIsNotReProbedButAForcedOneIs() = runBlocking {
    val store = PopopxRelayLatency()
    val first = Recorder(hosts.associateWith { 60L })
    store.refresh(hosts, probingAllowed = true, transport = first)
    assertEquals(3, first.calls.get())

    val second = Recorder(hosts.associateWith { 60L })
    store.refresh(hosts, probingAllowed = true, transport = second)
    assertEquals(0, second.calls.get(), "inside the ten-minute window the cached badge is already evidence")

    val forced = Recorder(hosts.associateWith { 900L })
    val round = store.refresh(hosts, probingAllowed = true, force = true, transport = forced)
    assertEquals(3, forced.calls.get(), "the re-test row means measure now")
    assertEquals(900L, round.getValue("smp1.popopx.im").latencyMs)
    // The forced round replaced the reading, so the badge moved with it.
    assertEquals(PopopxRelayBadge.SLOW, store.badge("smp1.popopx.im", probingAllowed = true))
  }

  @Test
  fun aHostWithNoReadingTriggersARoundOverTheWholeSet() = runBlocking {
    val store = PopopxRelayLatency()
    val first = Recorder(mapOf("smp1.popopx.im" to 60L))
    store.refresh(listOf("smp1.popopx.im"), probingAllowed = true, transport = first)

    val second = Recorder(mapOf("smp1.popopx.im" to 500L, "smp2.popopx.im" to 70L))
    store.refresh(hosts.take(2), probingAllowed = true, transport = second)
    assertEquals(2, second.calls.get(), "a round is taken per set, the way the selector fans out — it does not patch one host")
    assertEquals(2, store.probes().size)
    assertEquals(PopopxRelayBadge.SLOW, store.badge("smp1.popopx.im", probingAllowed = true), "the re-measured host keeps the newer number")
    assertEquals(listOf("smp2.popopx.im", "smp1.popopx.im"), store.ranked(hosts.take(2), probingAllowed = true))
  }

  @Test
  fun invalidateEmptiesTheCacheAndTheBadgesGoBackToNotMeasured() = runBlocking {
    val store = PopopxRelayLatency()
    store.refresh(hosts, probingAllowed = true, transport = Recorder(hosts.associateWith { 30L }))
    assertEquals(3, store.probes().size)
    assertEquals(PopopxRelayBadge.FAST, store.badge("smp2.popopx.im", probingAllowed = true))

    store.invalidate()

    assertTrue(store.probes().isEmpty(), "a reading for a server that left the enabled set is worse than no reading")
    for (host in hosts) {
      assertEquals(PopopxRelayBadge.UNKNOWN, store.badge(host, probingAllowed = true), host)
    }
    // No enabled servers: nothing to measure, so nothing is probed and an empty round cannot wipe the
    // cache of a later one.
    val after = Recorder(hosts.associateWith { 30L })
    store.refresh(emptyList(), probingAllowed = true, force = true, transport = after)
    assertEquals(0, after.calls.get())
    assertTrue(store.probes().isEmpty())
  }

  @Test
  fun invalidatingMidRoundStopsItRepublishingIntoAnEmptyCache() = runBlocking {
    val gate = GatedRecorder(hosts.associateWith { 30L })
    val store = PopopxRelayLatency()

    val round = async { store.refresh(hosts, probingAllowed = true, transport = gate) }
    gate.entered.await()
    store.invalidate()
    gate.letGo()
    runCatching { round.await() }

    assertTrue(store.probes().isEmpty(), "the cancelled round must not write back what it finished measuring")
  }

  // endregion
  // region the view the screen reads

  @Test
  fun rankedAndBadgeReflectTheLastRound() = runBlocking {
    val store = PopopxRelayLatency()
    store.refresh(
      hosts,
      probingAllowed = true,
      transport = Recorder(mapOf("smp1.popopx.im" to 300L, "smp2.popopx.im" to 20L, "smp3.popopx.im" to null)),
    )

    // smp2 measured fastest; smp1 is slow but still measured, so it leads the unmeasured tail; smp3
    // answered nothing, so it keeps the place it arrived in.
    assertEquals(listOf("smp2.popopx.im", "smp1.popopx.im", "smp3.popopx.im"), store.ranked(hosts, probingAllowed = true))
    assertEquals(PopopxRelayBadge.ACCEPTABLE, store.badge("smp1.popopx.im", probingAllowed = true))
    assertEquals(PopopxRelayBadge.FAST, store.badge("smp2.popopx.im", probingAllowed = true))
    assertEquals(PopopxRelayBadge.UNREACHABLE, store.badge("smp3.popopx.im", probingAllowed = true))
    assertEquals(PopopxRelayBadge.UNKNOWN, store.badge("smp9.popopx.im", probingAllowed = true))
    assertEquals(3, store.probes().size)
    assertEquals(3, PopopxRelaySelector.fresh(store.probes(), PopopxRelaySelector.monotonicMillis()).size)
  }

  @Test
  fun theSharedStoreBehavesLikeAnOwnedOne() = runBlocking {
    // The settings screens read `shared`; a test that only ever used a private instance would not
    // notice two of them double-probing each other.
    val shared = PopopxRelayLatency.shared
    shared.invalidate()
    val recorder = Recorder(hosts.associateWith { 40L })
    for (host in hosts) shared.refresh(listOf(host), probingAllowed = true, transport = recorder)
    assertEquals(3, recorder.calls.get())
    assertEquals(3, shared.probes().size)
    // Asking again over the whole set now hits the cache instead of the network.
    shared.refresh(hosts, probingAllowed = true, transport = recorder)
    assertEquals(3, recorder.calls.get())
    shared.invalidate()
    assertTrue(shared.probes().isEmpty())
  }

  // endregion
}
