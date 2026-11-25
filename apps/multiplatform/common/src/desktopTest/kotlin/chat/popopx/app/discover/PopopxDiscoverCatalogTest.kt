package chat.popopx.app.discover

import chat.popopx.common.discover.PopopxDiscoverCatalog
import chat.popopx.common.discover.PopopxDiscoverFilter
import chat.popopx.common.discover.PopopxDiscoverLimits
import chat.popopx.common.discover.PopopxDiscoverSection
import chat.popopx.common.discover.PopopxNodeConsole
import chat.popopx.common.discover.PopopxNodeCommand
import chat.popopx.common.discover.PopopxNodeCycleCost
import chat.popopx.common.discover.PopopxNodeServiceId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The catalogue (DiscoverCatalogModels.swift:234-424) is the interoperability surface: the ten raw
// values must match the host's EngineKind character-for-character, and the display names must match
// what the host PRINTS, because the result-card renderer matches on them. Hence pinning them as
// literals here rather than deriving anything.

class PopopxDiscoverCatalogTest {
  @Test
  fun theTenWireIdsAreVerbatimAndInCaseIterableOrder() {
    assertEquals(
      listOf(
        "shadow_cos", "zero_trust_warroom", "zerotrace_studio", "solo_autopilot", "creator_paywall_hub",
        "edge_compute_mesh", "morning_tv", "phantom_sentinel", "chrono_ark", "health_sentinel",
      ),
      PopopxDiscoverCatalog.services.map { it.rawValue },
    )
    assertEquals(10, PopopxNodeServiceId.entries.size)
    for (service in PopopxNodeServiceId.entries) {
      assertEquals(service, PopopxNodeServiceId.from(service.rawValue))
    }
    assertNull(PopopxNodeServiceId.from("badge_credits"))
  }

  @Test
  fun nodeDisplayNamesAreTheWireStringsTheCardsMatch() {
    assertEquals(
      listOf(
        "Shadow Chief of Staff", "Zero-Trust War Room", "Zero-Trace Studio", "Solo Autopilot",
        "Creator Paywall Hub", "Edge Compute Mesh", "Morning TV", "Phantom Sentinel", "Chrono Ark",
        "Health Sentinel",
      ),
      PopopxDiscoverCatalog.services.map { it.nodeDisplayName },
    )
    assertEquals(10, PopopxNodeServiceId.entries.map { it.nodeDisplayName }.toSet().size)
    // iOS titles are NSLocalizedString(nodeDisplayName) with the key as the only available value
    // (:265-268) — identity here is the ported fallback, not an unfinished TODO.
    assertEquals(PopopxNodeServiceId.ChronoArk.nodeDisplayName, PopopxNodeServiceId.ChronoArk.title)
  }

  @Test
  fun oneCycleCostPerServiceMeasuredNoTiers() {
    // THE MEASURED DEVIATION from the brief's "three-tier spec": every service carries ONE
    // `cycleCost` (DiscoverCatalogModels.swift:311-324) — nine flat credit packs and one metered.
    val expected = mapOf(
      PopopxNodeServiceId.ShadowCos to 200,
      PopopxNodeServiceId.ZeroTrustWarroom to 500,
      PopopxNodeServiceId.ZerotraceStudio to 300,
      PopopxNodeServiceId.SoloAutopilot to 500,
      PopopxNodeServiceId.CreatorPaywallHub to 300,
      PopopxNodeServiceId.MorningTv to 100,
      PopopxNodeServiceId.PhantomSentinel to 100,
      PopopxNodeServiceId.ChronoArk to 200,
      PopopxNodeServiceId.HealthSentinel to 200,
    )
    for ((service, credits) in expected) {
      assertEquals(PopopxNodeCycleCost.Credits(credits), service.cycleCost, service.rawValue)
      assertEquals(credits, service.cycleCost.renewalCredits)
      assertTrue(service.cycleCost.isRenewable)
    }
    val mesh = PopopxNodeServiceId.EdgeComputeMesh
    assertEquals(PopopxNodeCycleCost.UsageBased, mesh.cycleCost)
    assertNull(mesh.cycleCost.renewalCredits)
    assertFalse(mesh.cycleCost.isRenewable)
  }

  @Test
  fun sectionsShelveTheServicesAsIOSCountsThem() {
    assertEquals(listOf(PopopxNodeServiceId.EdgeComputeMesh, PopopxNodeServiceId.MorningTv), PopopxDiscoverCatalog.grouped(PopopxDiscoverSection.COMPUTE))
    assertEquals(5, PopopxDiscoverCatalog.grouped(PopopxDiscoverSection.PRODUCTIVITY).size)
    assertEquals(3, PopopxDiscoverCatalog.grouped(PopopxDiscoverSection.SANCTUARY).size)
    assertEquals(10, PopopxDiscoverSection.entries.flatMap { PopopxDiscoverCatalog.grouped(it) }.size)
    assertEquals(listOf("productivity", "compute", "sanctuary"), PopopxDiscoverSection.entries.map { it.rawValue })
  }

  @Test
  fun everyServiceHasExactlyThreeButtonsAndThreeHighlights() {
    for (service in PopopxNodeServiceId.entries) {
      assertEquals(3, service.menuActions.size, service.rawValue)
      assertEquals(3, service.highlights.size, service.rawValue)
      assertEquals(3, service.menuActions.map { it.action }.toSet().size, service.rawValue)
      assertEquals(3, service.highlights.toSet().size, service.rawValue)
      for (action in service.menuActions) {
        assertTrue(action.title.isNotEmpty())
        assertTrue(action.action.isNotEmpty())
        assertEquals("${service.rawValue}.${action.action}", action.id)
        assertEquals(service, action.serviceId)
        assertEquals(PopopxNodeCommand(service, action.action), action.command)
      }
    }
    // The full menu-id set is unique plaza-wide, which is what a LazyVGrid `id:` needs.
    val ids = PopopxNodeServiceId.entries.flatMap { it.menuActions }.map { it.id }
    assertEquals(ids.size, ids.toSet().size)
    assertEquals(
      "phantom_sentinel::lock_all::{}",
      PopopxNodeServiceId.PhantomSentinel.menuActions.first().command.wireString.removePrefix("::popopx_sys::NODE_CMD::"),
    )
  }

  @Test
  fun priceLabelsFollowTheIosFormats() {
    assertEquals("200 Compute Credits / 30 days", PopopxNodeServiceId.ShadowCos.cycleCost.priceLabel)
    assertEquals("Metered, settled per job", PopopxNodeServiceId.EdgeComputeMesh.cycleCost.priceLabel)
  }

  @Test
  fun searchMatchesWhatThePlazaMatches() {
    // PopopxDiscoverView.swift:539-551: name, the Mac's own printed name, tagline, raw value with
    // underscores as spaces, and menu titles.
    val yes = listOf(
      PopopxNodeServiceId.PhantomSentinel to "phantom",
      PopopxNodeServiceId.PhantomSentinel to "sentinel", // both sentinels share the tail; both must match it
      PopopxNodeServiceId.HealthSentinel to "sentinel",
      PopopxNodeServiceId.ZeroTrustWarroom to "zero trust warroom", // rawValue underscores -> spaces
      PopopxNodeServiceId.EdgeComputeMesh to "lend idle cycles", // tagline
      PopopxNodeServiceId.ShadowCos to "knowledge base", // menu title
      PopopxNodeServiceId.ChronoArk to "time capsule",
      PopopxNodeServiceId.MorningTv to "MORNING", // case-insensitive
    )
    for ((service, query) in yes) assertTrue(PopopxDiscoverCatalog.matchesSearch(service, query), "$service / $query")
    val no = listOf(
      PopopxNodeServiceId.MorningTv to "warroom",
      PopopxNodeServiceId.ShadowCos to "binaural",
      PopopxNodeServiceId.ChronoArk to "zzz",
    )
    for ((service, query) in no) assertFalse(PopopxDiscoverCatalog.matchesSearch(service, query), "$service / $query")
    // The plaza never calls the matcher with an empty query (it shows everything in that case,
    // PopopxDiscoverView.swift:97-100); "" trivially "matches" here, which is harmless — pinned so.
    assertTrue(PopopxDiscoverCatalog.matchesSearch(PopopxNodeServiceId.ChronoArk, ""))
  }

  @Test
  fun visibleSectionsFilterThenSearchThenDropEmptyShelves() {
    val all = PopopxDiscoverCatalog.visibleSections(PopopxDiscoverFilter.ALL, "")
    assertEquals(listOf(PopopxDiscoverSection.PRODUCTIVITY, PopopxDiscoverSection.COMPUTE, PopopxDiscoverSection.SANCTUARY), all.map { it.section })
    assertEquals(10, all.sumOf { it.services.size })

    val compute = PopopxDiscoverCatalog.visibleSections(PopopxDiscoverFilter.COMPUTE, "")
    assertEquals(listOf(PopopxDiscoverSection.COMPUTE), compute.map { it.section })
    assertEquals(2, compute.first().services.size)

    val sentinel = PopopxDiscoverCatalog.visibleSections(PopopxDiscoverFilter.SANCTUARY, "sentinel")
    assertEquals(listOf(PopopxNodeServiceId.PhantomSentinel, PopopxNodeServiceId.HealthSentinel), sentinel.single().services)

    // A query that hits one shelf must NOT resurface the other shelves' services (:95-104).
    val capsule = PopopxDiscoverCatalog.visibleSections(PopopxDiscoverFilter.ALL, "time capsule")
    assertEquals(listOf(PopopxDiscoverSection.SANCTUARY), capsule.map { it.section })
    assertEquals(1, capsule.sumOf { it.services.size })

    val nothing = PopopxDiscoverCatalog.visibleSections(PopopxDiscoverFilter.PRODUCTIVITY, "sentinel")
    assertTrue(nothing.isEmpty())
  }

  @Test
  fun filtersCoverSectionsTheWayTheChipBarDoes() {
    assertTrue(PopopxDiscoverFilter.ALL.matches(PopopxDiscoverSection.COMPUTE))
    assertFalse(PopopxDiscoverFilter.COMPUTE.matches(PopopxDiscoverSection.SANCTUARY))
    assertEquals(PopopxDiscoverFilter.entries.size - 1, PopopxDiscoverFilter.entries.count { it != PopopxDiscoverFilter.ALL })
    assertEquals("all", PopopxDiscoverFilter.ALL.rawValue)
  }

  @Test
  fun theConsoleBridgeIsDisplayTextAndNeverAConnection() {
    // MEASURED FACT, pinned as text: Discover does not open 127.0.0.1:18920 (MacNodePairingSheet.swift
    // :616-619). These strings are what a user reads or copies; the transport is the SMP invisible
    // text in PopopxNodeCommand. This module has no socket API — if a future edit reaches for one,
    // this test's subject matter is the thing being violated.
    assertEquals("http://127.0.0.1:18920/", PopopxNodeConsole.consoleDisplayUrl())
    assertEquals(PopopxNodeConsole.consoleDisplayUrl(), PopopxNodeConsole.copyText())
    assertEquals("X-PPX-Token: \$PPX_BRIDGE_SECRET · ?t=\$PPX_BRIDGE_SECRET", PopopxNodeConsole.tokenContractText())
    assertEquals(18_920, PopopxNodeConsole.CONSOLE_PORT)
    assertEquals("127.0.0.1", PopopxNodeConsole.CONSOLE_HOST)
    assertEquals("X-PPX-Token", PopopxNodeConsole.CONSOLE_TOKEN_HEADER)
    assertEquals("t", PopopxNodeConsole.CONSOLE_TOKEN_QUERY_ITEM)
    assertEquals(900L, PopopxDiscoverLimits.PAIRING_OFFER_LIFETIME_SECONDS)
    assertEquals(40, PopopxDiscoverLimits.MAXIMUM_INBOX_ROWS)
    assertEquals(30L * 86_400L * 1_000L, PopopxDiscoverLimits.CYCLE_MILLIS)
  }

}
