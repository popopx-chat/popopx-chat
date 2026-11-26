package chat.popopx.common.network

import java.net.InetSocketAddress
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Latency of the SMP relays this user has enabled, measured from the client.
 *
 * What this is: a TCP connect plus a TLS handshake to `host:443`, timed. Nothing is written to the
 * socket, so no queue id, no server address, no key and no account material ever leaves the device —
 * the only observable content of a probe is a connection to a host the client already talks to. That
 * is a deliberate, load-bearing property (the "零元数据测速" rule): a probe that carried a session
 * token would be a metadata leak dressed as a performance feature.
 *
 * What this is not: a way to choose the relay for a new queue. That choice is made in the Haskell
 * core (`chooseRandomServers`, over the enabled set, cached as `randomPresetServers`). The app layer
 * may order, label and toggle the enabled set; it cannot overwrite the core's pick, and this file
 * does not pretend to. Ruled 2026-11-26.
 *
 * The proxy gate is the other load-bearing rule: SMP traffic can be routed through the app's
 * SOCKS5/Tor proxy, which the core opens inside the pinned popopxmq dependency. App-layer sockets do
 * not traverse it, so a direct probe while a proxy is active would disclose the real public address
 * the proxy exists to hide. Therefore: proxied means no probe, and the badge says 不可测 rather than
 * showing a stale or a misleading number.
 */

/** One measurement. `latencyMs == null` means "did not get a handshake back", with [reason] naming
 * the failure coarsely (a class of failure, not a message: an exception string can carry the host,
 * a port, or a TLS alert, and none of that belongs in a UI label or a log line). */
data class PopopxRelayProbe(
  val host: String,
  val latencyMs: Long?,
  val completedAtMs: Long,
  val reason: String? = null,
) {
  val healthy: Boolean get() = latencyMs != null
}

/** The badge a settings row shows. `UNAVAILABLE` is distinct from `SLOW`: the first means "this build
 * is not allowed to look", the second means "it looks bad". Folding them would hide the proxy gate. */
enum class PopopxRelayBadge {
  UNKNOWN,
  FAST,
  ACCEPTABLE,
  SLOW,
  UNREACHABLE,
  UNAVAILABLE;

  /** true only for a fresh, completed handshake — the set the ranking orders. */
  val measured: Boolean get() = this == FAST || this == ACCEPTABLE || this == SLOW || this == UNREACHABLE
}

/** How to reach one host, injectable so the proxy gate and the ranking are testable without a
 * network. Returning null means "no handshake within the timeout". */
fun interface PopopxRelayTransport {
  suspend fun handshakeMillis(host: String, port: Int, timeoutMs: Long): Long?
}

object PopopxRelaySelector {
  /** A relay that has not answered this quickly is treated as down for selection purposes. */
  const val PROBE_TIMEOUT_MS: Long = 3_000L

  /** Re-probe cadence. Ten minutes is the compromise between a useful badge and a background
   * connection pattern a network observer could correlate. */
  const val CACHE_TTL_MS: Long = 10L * 60L * 1_000L

  /** SMP over TLS. The proxy-independent part of the address: no path, no query. */
  const val PROBE_PORT: Int = 443

  /** Green / amber thresholds, matching the design of the settings row. */
  const val FAST_BELOW_MS: Long = 150L
  const val SLOW_BELOW_MS: Long = 400L

  /** The default transport: connect, handshake, close, write nothing.
   *
   * `startHandshake()` is called explicitly because `createSocket(host, port)` on an SSLSocket does
   * the TCP connect only; without it the timing would measure DNS plus SYN/ACK and call that TLS. */
  val directTransport: PopopxRelayTransport = PopopxRelayTransport { host, port, timeoutMs ->
    try {
      val socket = SSLSocketFactory.getDefault().createSocket() as SSLSocket
      socket.soTimeout = timeoutMs.toInt()
      val elapsed = runCatching {
        val started = monotonicMillis()
        socket.connect(InetSocketAddress(host, port), timeoutMs.toInt())
        socket.startHandshake()
        monotonicMillis() - started
      }
      runCatching { socket.close() }
      elapsed.getOrNull()?.let { if (it in 0 until timeoutMs) it else null }
    } catch (e: Exception) {
      null
    }
  }

  /** A monotonic clock, so a wall-clock adjustment (NTP, travel, a manual change) cannot make a
   * measurement look negative or immortal. */
  fun monotonicMillis(): Long = System.nanoTime() / 1_000_000L

  //region pure decisions

  /** Probes that are still trustworthy at [nowMs]. A missing entry and an expired one are the same
   * thing to every caller: not evidence. */
  fun fresh(probes: Map<String, PopopxRelayProbe>, nowMs: Long, ttlMs: Long = CACHE_TTL_MS): Map<String, PopopxRelayProbe> =
    probes.filterValues { it.completedAtMs + ttlMs > nowMs }

  /** The badge for one host. [probingAllowed] is the proxy gate: false forces UNAVAILABLE even when
   * a stale measurement exists, because showing an old number next to a server the user cannot test
   * reads as a live reading. */
  fun badge(
    host: String,
    probes: Map<String, PopopxRelayProbe>,
    nowMs: Long,
    probingAllowed: Boolean = true,
    ttlMs: Long = CACHE_TTL_MS,
  ): PopopxRelayBadge {
    if (!probingAllowed) return PopopxRelayBadge.UNAVAILABLE
    val probe = fresh(probes, nowMs, ttlMs)[host] ?: return PopopxRelayBadge.UNKNOWN
    val latency = probe.latencyMs ?: return PopopxRelayBadge.UNREACHABLE
    return when {
      latency < FAST_BELOW_MS -> PopopxRelayBadge.FAST
      latency < SLOW_BELOW_MS -> PopopxRelayBadge.ACCEPTABLE
      else -> PopopxRelayBadge.SLOW
    }
  }

  /**
   * Enabled hosts, best first.
   *
   * Only fresh, healthy measurements are promoted, and they keep ascending latency order. Everything
   * else — unmeasured, stale, timed out — keeps the relative order it arrived in and goes after the
   * measured set. That matters: the incoming order is the core's shuffled enabled list, so an
   * unmeasured tail stays randomised instead of clustering on smp1 and turning a latency feature into
   * a load imbalance.
   */
  fun rank(
    hosts: List<String>,
    probes: Map<String, PopopxRelayProbe>,
    nowMs: Long,
    probingAllowed: Boolean = true,
    ttlMs: Long = CACHE_TTL_MS,
  ): List<String> {
    if (!probingAllowed) return hosts
    val usable = fresh(probes, nowMs, ttlMs)
    val (measured, rest) = hosts.partition { usable[it]?.healthy == true }
    return measured.sortedBy { usable.getValue(it).latencyMs } + rest
  }

  /** The head of [rank], or null when there is nothing to prefer. Callers treat null as "keep doing
   * what the core already does". */
  fun preferred(
    hosts: List<String>,
    probes: Map<String, PopopxRelayProbe>,
    nowMs: Long,
    probingAllowed: Boolean = true,
  ): String? = rank(hosts, probes, nowMs, probingAllowed).firstOrNull()

  //endregion

  //region probing

  /**
   * Probe every host concurrently.
   *
   * [allowed] is the proxy gate and is checked here rather than at every call site: this is the only
   * function that touches a socket, so a caller that forgets the flag still cannot leak. When it is
   * false the transport is never invoked and the result is empty — the caller keeps its previous
   * cache but [badge] will not show it.
   */
  suspend fun probe(
    hosts: List<String>,
    allowed: Boolean,
    transport: PopopxRelayTransport = directTransport,
    timeoutMs: Long = PROBE_TIMEOUT_MS,
    port: Int = PROBE_PORT,
  ): Map<String, PopopxRelayProbe> {
    if (!allowed || hosts.isEmpty()) return emptyMap()
    return coroutineScope {
      hosts.map { host -> async { probeOne(host, transport, timeoutMs, port) } }
        .map { it.await() }
        .associateBy { it.host }
    }
  }

  /** One host, with the timeout enforced twice: the socket has its own, and a transport that ignores
   * it still cannot stall the fan-out beyond it. */
  private suspend fun probeOne(
    host: String,
    transport: PopopxRelayTransport,
    timeoutMs: Long,
    port: Int,
  ): PopopxRelayProbe {
    val latency = withTimeoutOrNull(timeoutMs + PROBE_GRACE_MS) { transport.handshakeMillis(host, port, timeoutMs) }
    return PopopxRelayProbe(
      host = host,
      latencyMs = latency,
      completedAtMs = monotonicMillis(),
      reason = if (latency == null) PROBE_UNREACHABLE else null,
    )
  }

  /** Slack added to the socket timeout so a handshake that lands at 2.99 s is not recorded as a
   * failure by the surrounding guard. */
  private const val PROBE_GRACE_MS: Long = 250L

  const val PROBE_UNREACHABLE: String = "unreachable"

  /**
   * Merge a fresh round into a cache, keeping the older reading when the new round was refused
   * (proxy active, hosts removed from the enabled set) instead of wiping the badge to UNKNOWN.
   * A refused round is not evidence that a relay got worse.
   */
  fun merged(
    previous: Map<String, PopopxRelayProbe>,
    round: Map<String, PopopxRelayProbe>,
    hosts: List<String>,
  ): Map<String, PopopxRelayProbe> {
    if (round.isEmpty()) return previous.filterKeys { it in hosts.toSet() }
    val kept = previous.filterKeys { it !in hosts.toSet() }
    return kept + round.filterKeys { it in hosts.toSet() }
  }

  /** Sleep helper kept here so the caller's "re-test now" button and the periodic refresh share one
   * notion of a pause that a cancelled scope interrupts. */
  suspend fun pause(millis: Long) = delay(millis)

  //endregion
}
