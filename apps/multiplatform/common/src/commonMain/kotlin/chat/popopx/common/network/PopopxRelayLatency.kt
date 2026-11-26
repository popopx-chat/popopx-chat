package chat.popopx.common.network

import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The last measured latency round of the SMP relays this profile has enabled, and the decision of
 * what a settings row is allowed to say about it.
 *
 * The decisions themselves are not here — they are in [PopopxRelaySelector], which is a byte-for-byte
 * twin of `PopopxRelaySelector.swift` on iOS. This class is only the cache plus the two rules that
 * make the cache safe to share:
 *
 * 1. at most one round runs at a time. Two screens opening 你的服务器 simultaneously must not fan out
 *    twice against the same relays — that is the concurrency hole the relay-latency audit found, and
 *    it is why the iOS side put this behind an `actor`;
 * 2. a proxy gate that is closed means no socket at all, so the badge falls back to 不可测 instead of
 *    re-showing a number the user cannot currently verify.
 *
 * On iOS rule 1 is free (an `actor` isolates the state). There is no `actor` in commonMain, so here it
 * is a [Mutex] around the critical section plus a stored in-flight [Deferred] that a late caller joins
 * instead of starting its own round. Reads of the cache are lock-free and get a consistent map because
 * every write publishes a new immutable instance through a `@Volatile` field.
 *
 * Not a server preference: this ranking labels and orders the enabled set for the app's own display.
 * The core still picks the server for a new queue (`chooseRandomServers`) and nothing here writes to
 * it. Ruled 2026-11-26.
 */
class PopopxRelayLatency(ioContext: CoroutineContext = Dispatchers.IO) {
  companion object {
    /** One store per process, so every screen that shows a latency badge is looking at the same
     * round. Same role as `PopopxRelayLatency.shared` on iOS. */
    val shared = PopopxRelayLatency()
  }

  /**
   * The round runs detached from whoever asked for it: a settings sheet that closes halfway through
   * must not take the measurement down with it (the iOS `Task { }` behaves the same way). `SupervisorJob`
   * so a failed round cannot cancel anything else in the scope, and [Dispatchers.IO] because the
   * default transport opens real sockets — never run this on the main dispatcher.
   */
  private val scope = CoroutineScope(SupervisorJob() + ioContext)

  /**
   * Guards the read-decide-install section of [refresh] and the merge at the end of a round. Held
   * only around cheap, non-blocking work: the handshake itself happens outside it.
   */
  private val mutex = Mutex()

  private val inFlight = AtomicReference<Deferred<Map<String, PopopxRelayProbe>>?>(null)

  /**
   * Bumped whenever the cache is thrown away or replaced, so a round that was still merging when
   * [invalidate] ran cannot write its readings back into an emptied cache.
   */
  private val generation = AtomicInteger(0)

  @Volatile
  private var cached: Map<String, PopopxRelayProbe> = emptyMap()

  /** The last round, as an immutable snapshot. Callers cannot mutate a reading. */
  fun probes(): Map<String, PopopxRelayProbe> = cached

  /** Enabled hosts, best first, from whatever is cached. A closed gate returns the input order, which
   * is the core's own randomisation. */
  fun ranked(hosts: List<String>, probingAllowed: Boolean): List<String> =
    PopopxRelaySelector.rank(hosts, cached, PopopxRelaySelector.monotonicMillis(), probingAllowed)

  fun badge(host: String, probingAllowed: Boolean): PopopxRelayBadge =
    PopopxRelaySelector.badge(host, cached, PopopxRelaySelector.monotonicMillis(), probingAllowed)

  /**
   * Probe [hosts] unless the cache already covers all of them, or a round is already running.
   *
   * Returns the cache to use afterwards. A refused refresh (closed gate, empty host set) returns the
   * cache untouched — refusing is not evidence about anything — and [badge] hides those readings while
   * the gate stays closed rather than showing a stale figure as a live one.
   */
  suspend fun refresh(
    hosts: List<String>,
    probingAllowed: Boolean,
    force: Boolean = false,
    transport: PopopxRelayTransport = PopopxRelaySelector.directTransport,
  ): Map<String, PopopxRelayProbe> {
    if (!probingAllowed) return cached
    if (hosts.isEmpty()) return cached
    if (!force) {
      val now = PopopxRelaySelector.monotonicMillis()
      if (hosts.all { cached[it].stillFresh(now) }) return cached
    }
    val round: Deferred<Map<String, PopopxRelayProbe>> = mutex.withLock {
      val running = inFlight.get()
      // Joining is the whole point: a caller that arrives while a round is open gets its answer, it
      // does not queue a second fan-out behind it.
      if (running != null && running.isActive) running else startRoundLocked(hosts, transport)
    }
    return try {
      round.await()
    } catch (e: CancellationException) {
      throw e
    } catch (e: Exception) {
      cached
    }
  }

  /**
   * Forget every reading and stop the round in progress.
   *
   * Called when the enabled set or the proxy gate changes underneath us: a badge that belongs to a
   * server the user just removed, or a measurement taken before Tor was switched on, is worse than no
   * badge. Deliberately not `suspend` — a settings screen wants to drop the cache from a click
   * handler, and there is nothing here that can block.
   */
  fun invalidate() {
    generation.incrementAndGet()
    cached = emptyMap()
    inFlight.getAndSet(null)?.cancel()
  }

  /** Must already hold [mutex]. */
  private fun startRoundLocked(
    hosts: List<String>,
    transport: PopopxRelayTransport,
  ): Deferred<Map<String, PopopxRelayProbe>> {
    val roundId = generation.incrementAndGet()
    val round = scope.async { runRound(hosts, transport, roundId) }
    inFlight.set(round)
    return round
  }

  /**
   * One fan-out, then merge it into the cache, then hand the merged cache back to everyone waiting.
   *
   * The merge is inside the deferred rather than in each caller on purpose: an awaiter must never see
   * a round that has finished probing but not yet published, or two screens would render two different
   * answers for one measurement.
   */
  private suspend fun runRound(
    hosts: List<String>,
    transport: PopopxRelayTransport,
    roundId: Int,
  ): Map<String, PopopxRelayProbe> {
    val round = try {
      // allowed = true: the gate was checked by the caller that started this round, and [probe] would
      // refuse anyway. Keeping it explicit means a future refactor cannot silently drop the check.
      PopopxRelaySelector.probe(hosts, allowed = true, transport = transport)
    } catch (e: CancellationException) {
      throw e
    } catch (e: Exception) {
      // A round that fell over says nothing, and [merged] treats "says nothing" as "not evidence",
      // so the previous readings survive instead of every badge going grey.
      emptyMap()
    }
    return mutex.withLock {
      // A round superseded by invalidate() must not republish into an emptied cache.
      if (roundId == generation.get()) {
        cached = PopopxRelaySelector.merged(cached, round, hosts)
      }
      cached
    }
  }

  private fun PopopxRelayProbe?.stillFresh(nowMs: Long): Boolean =
    this != null && completedAtMs + PopopxRelaySelector.CACHE_TTL_MS > nowMs
}
