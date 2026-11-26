package chat.popopx.common.views.usersettings.networkAndServers

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.CircularProgressIndicator
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import SectionItemViewSpaceBetween
import chat.popopx.common.network.PopopxRelayBadge
import chat.popopx.common.network.PopopxRelayLatency
import chat.popopx.common.network.PopopxRelayProbe
import chat.popopx.common.network.PopopxRelaySelector
import chat.popopx.common.ui.theme.*
import chat.popopx.common.model.NetCfg
import chat.popopx.common.model.OnionHosts
import chat.popopx.common.model.ServerAddress.Companion.parseServerAddress
import chat.popopx.common.model.UserServer
import chat.popopx.common.platform.chatModel
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.StringResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.launch

/**
 * The presentation half of SMP relay latency on Android.
 *
 * The decisions live in `PopopxRelaySelector` / `PopopxRelayLatency`, which are the twin of the Swift
 * `PopopxMeshKit` types; nothing here re-derives a threshold or ranks a host on its own. What this
 * file owns is the two rules the user sees:
 *
 * - a row says 不可测 rather than a number whenever a direct probe is not allowed, because a stale
 *   reading next to a server the user cannot currently test reads as a live one;
 * - the probe is a TCP connect and a TLS handshake to a host the client already talks to, and it
 *   carries no queue id, server address, key or account material. The row says that in words, so the
 *   connection is disclosed rather than surprising.
 *
 * The ranking labels and orders the enabled set for display only. Choosing the server for a new queue
 * stays in the core (`chooseRandomServers`), and nothing here writes a preference into it.
 */

/**
 * Whether a direct latency probe may be sent at all, from the same live preference state the network
 * screens read.
 *
 * Two conditions, matching `relayProbingAllowed()` on iOS (`networkUseOnionHosts == no && socksProxy ==
 * nil`):
 * - the SOCKS5/Tor proxy is on. The proxy is opened inside the agent, so an app-layer socket does not
 *   traverse it: probing would disclose the public address the proxy exists to hide;
 * - onion host addressing is enabled, i.e. the user asked for `.onion` rather than public addresses.
 *   Reaching those goes via the proxy, so the same reasoning applies even if the proxy string is not
 *   currently set.
 *
 * The three preferences are read as state, so flipping the proxy on while this screen is open stops
 * the next round before it starts instead of at the next recomposition of the parent modal.
 */
@Composable
fun relayLatencyProbingAllowed(): Boolean {
  val controller = chatModel.controller
  val useSocksProxy by controller.appPrefs.networkUseSocksProxy.state
  val hostMode by controller.appPrefs.networkHostMode.state
  val requiredHostMode by controller.appPrefs.networkRequiredHostMode.state
  // NetCfg.onionHosts is derived from hostMode + requiredHostMode, so those two states and nothing
  // else of the (large) config can change the answer.
  return remember(useSocksProxy, hostMode, requiredHostMode) {
    relayLatencyProbingAllowed(controller.getNetCfg())
  }
}

/** The same decision outside composition, for the moment a probe is actually about to be sent. */
fun relayLatencyProbingAllowed(cfg: NetCfg): Boolean =
  !cfg.useSocksProxy && cfg.onionHosts == OnionHosts.NEVER

/**
 * The hosts to measure: enabled, non-deleted SMP servers, in the order the agent gave them, deduped.
 * Duplicates are dropped so a host listed twice is not probed twice in one round.
 */
fun relayLatencyHosts(smpServers: List<UserServer>): List<String> =
  smpServers
    .filter { it.enabled && !it.deleted }
    .mapNotNull { parseServerAddress(it.server)?.hostnames?.firstOrNull() }
    .distinct()

/**
 * What one SMP row shows for [server], or null when the row has nothing to say.
 *
 * `ms` is only filled when the gate is open and the reading is fresh, which is what keeps a green pill
 * and a millisecond figure from coming from two different rounds.
 */
@Composable
fun relayLatency(
  server: String,
  probes: Map<String, PopopxRelayProbe>,
  enabled: Boolean,
  probingAllowed: Boolean,
): RelayLatency? {
  if (!enabled) return null
  val host = serverHostname(server)
  val now = PopopxRelaySelector.monotonicMillis()
  val current = PopopxRelaySelector.fresh(probes, now)[host]
  return RelayLatency(
    badge = PopopxRelaySelector.badge(host, probes, now, probingAllowed),
    ms = if (probingAllowed) current?.latencyMs else null,
  )
}

data class RelayLatency(val badge: PopopxRelayBadge, val ms: Long?)

/** The pill in a server row. Colour is the verdict, the number is what the user compares. */
@Composable
fun RelayLatencyBadge(latency: RelayLatency) {
  val color = when (latency.badge) {
    PopopxRelayBadge.FAST -> PopopxGreen
    PopopxRelayBadge.ACCEPTABLE -> WarningYellow
    PopopxRelayBadge.SLOW, PopopxRelayBadge.UNREACHABLE -> MaterialTheme.colors.error
    PopopxRelayBadge.UNKNOWN, PopopxRelayBadge.UNAVAILABLE -> MaterialTheme.colors.secondary
  }
  // A measured badge shows the figure; an unmeasured or refused one shows why there is no figure.
  val text = when (latency.badge) {
    PopopxRelayBadge.FAST, PopopxRelayBadge.ACCEPTABLE, PopopxRelayBadge.SLOW ->
      latency.ms?.let { stringResource(MR.strings.relay_latency_ms, it.toInt()) } ?: stringResource(latency.badge.label())
    else -> stringResource(latency.badge.label())
  }
  Box(
    Modifier
      .background(color.copy(alpha = 0.16f), RoundedCornerShape(percent = 50))
      .padding(horizontal = 6.dp, vertical = 2.dp)
  ) {
    Text(
      text,
      style = MaterialTheme.typography.caption,
      color = color,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis,
    )
  }
}

private fun PopopxRelayBadge.label(): StringResource = when (this) {
  PopopxRelayBadge.FAST -> MR.strings.relay_latency_fast
  PopopxRelayBadge.ACCEPTABLE -> MR.strings.relay_latency_acceptable
  PopopxRelayBadge.SLOW -> MR.strings.relay_latency_slow
  PopopxRelayBadge.UNREACHABLE -> MR.strings.relay_latency_unreachable
  PopopxRelayBadge.UNKNOWN -> MR.strings.relay_latency_unknown
  PopopxRelayBadge.UNAVAILABLE -> MR.strings.relay_latency_unavailable
}

/**
 * 「立即重新测速」. Disabled exactly when pressing it could do nothing: no gate, no round in flight,
 * nothing enabled to measure.
 *
 * Opening the screen also measures, unforced, from [LaunchedEffect]; this row is the manual override
 * of the ten-minute cache.
 */
@Composable
fun RelayLatencyRow(
  smpServers: List<UserServer>,
  probes: MutableState<Map<String, PopopxRelayProbe>>,
  probing: MutableState<Boolean>,
) {
  val scope = rememberCoroutineScope()
  val probingAllowed = relayLatencyProbingAllowed()
  val hosts = remember(smpServers) { relayLatencyHosts(smpServers) }
  val disabled = !probingAllowed || probing.value || hosts.isEmpty()

  suspend fun refresh(force: Boolean) {
    probing.value = true
    try {
      // The gate is evaluated again at the moment of the call, not captured from the composition: a
      // proxy switched on since this row was composed must stop this round, not the next one.
      val allowed = relayLatencyProbingAllowed(chatModel.controller.getNetCfg())
      probes.value = PopopxRelayLatency.shared.refresh(hosts, probingAllowed = allowed, force = force)
    } finally {
      probing.value = false
    }
  }

  LaunchedEffect(hosts, probingAllowed) {
    if (probingAllowed && hosts.isNotEmpty()) {
      refresh(force = false)
    } else if (!probingAllowed) {
      // The badge hides the readings while the gate is closed; dropping them here means a number
      // taken before the proxy came on cannot survive the next recomposition either.
      PopopxRelayLatency.shared.invalidate()
      probes.value = emptyMap()
    }
  }

  SectionItemViewSpaceBetween(
    { scope.launch { refresh(force = true) } },
    disabled = disabled,
  ) {
    Column(Modifier.weight(1f)) {
      Text(
        stringResource(MR.strings.relay_latency_test_now),
        color = if (disabled) MaterialTheme.colors.secondary else MaterialTheme.colors.onBackground,
      )
      Text(
        relayLatencyFooter(probingAllowed, hosts.isEmpty()),
        style = MaterialTheme.typography.caption,
        color = MaterialTheme.colors.secondary,
      )
    }
    if (probing.value) {
      CircularProgressIndicator(
        Modifier
          .padding(horizontal = 4.dp)
          .size(18.dp),
        color = MaterialTheme.colors.secondary,
        strokeWidth = 2.dp,
      )
    }
  }
}

/** Disclosure, not decoration: the probe opens a connection, so the sentence says what it carries and
 * what makes it unsafe to run. */
@Composable
private fun relayLatencyFooter(probingAllowed: Boolean, noHosts: Boolean): String = when {
  !probingAllowed -> generalGetString(MR.strings.relay_latency_paused_by_proxy)
  noHosts -> generalGetString(MR.strings.relay_latency_no_servers)
  else -> generalGetString(MR.strings.relay_latency_probe_explained)
}
