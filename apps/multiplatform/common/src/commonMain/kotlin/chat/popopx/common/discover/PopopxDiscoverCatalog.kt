package chat.popopx.common.discover

// Ported from apps/ios/Shared/Features/Discover/DiscoverCatalogModels.swift — the ten official
// edge services, the billing vocabulary of the 30-day cycle, and the display-only console text.
//
// Every string that leaves or re-enters this device as data — service ids, action tokens, the
// node's result-card names, ledger remarks, the pairing notice — is a WIRE LITERAL here, kept as
// a plain Kotlin constant rather than a resource lookup: iOS states the same rule for
// `nodeDisplayName` (DiscoverCatalogModels.swift:249-250, "**Never localized** — it is a wire
// literal, and `PopopxNodeResultCard.detect` matches on it") and for the ledger remarks
// (DiscoverSubscriptionManager.swift:619-621, "the sentence is frozen at the moment of the
// charge"). Marketing strings that iOS feeds to `NSLocalizedString` with the English text as the
// key are ported as that key verbatim: with no resource layer in this module, iOS's own fallback
// for a missing locale entry (`title = NSLocalizedString(nodeDisplayName)`,
// DiscoverCatalogModels.swift:268) is exactly "the English key is the value".
//
// Character counts are UTF-16 code units. On every field this module measures (ASCII ids, tokens,
// JSON payloads) that equals Swift's grapheme count; they diverge only off-ASCII, where the Kotlin
// count is larger, so the guards reject more, never less — the same convention the eco port took
// (PopopxEcoModels.kt:15-19).

/** Every numeric ceiling of the Discover module, in one place, each measured from the Swift. */
object PopopxDiscoverLimits {
  /** The signalling payload ceiling this module inherits from the commerce codec (`PopopxCommerceLimits.maximumSignalPayloadCharacters`, PopopxBadgeCreditsModels.swift:47). */
  const val MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS = 1_024

  /** `PopopxNodeWire.segmentCount`, DiscoverCatalogModels.swift:56 — `serviceId`, `action`, `payload`. */
  const val SEGMENT_COUNT = 3

  /** `PopopxNodeWire.pairingOfferLifetime`, DiscoverCatalogModels.swift:77: 15 minutes, in seconds. */
  const val PAIRING_OFFER_LIFETIME_SECONDS = 15L * 60L

  /** An `iat`/`exp` beyond this cannot be multiplied to milliseconds without overflowing a Long. */
  const val MAXIMUM_OFFER_EPOCH_SECONDS = 4_000_000_000L

  /** `PopopxNodeWire.bridgeSecretMinimumCharacters`, DiscoverCatalogModels.swift:81. */
  const val BRIDGE_SECRET_MINIMUM_CHARACTERS = 16

  /** `DiscoverCopy.cycleDays`, DiscoverCatalogModels.swift:698. */
  const val CYCLE_DAYS = 30

  /** `PopopxDiscoverClock.cycleSeconds`, DiscoverSubscriptionManager.swift:96: 30 days. */
  const val CYCLE_SECONDS = 30L * 86_400L

  /** `PopopxDiscoverClock.cycleMilliseconds`, DiscoverSubscriptionManager.swift:100. */
  const val CYCLE_MILLIS = CYCLE_SECONDS * 1_000L

  /** `PopopxDiscoverClock.renewalWindowSeconds`, DiscoverSubscriptionManager.swift:97: 24 h. */
  const val RENEWAL_WINDOW_SECONDS = 24L * 3_600L

  /** `PopopxDiscoverClock.renewalWindowSeconds * 1_000`, the unit `millisecondsRemaining` is in. */
  const val RENEWAL_WINDOW_MILLIS = RENEWAL_WINDOW_SECONDS * 1_000L

  /** `PopopxDiscoverClock.secondsPerDay`, DiscoverSubscriptionManager.swift:98. */
  const val SECONDS_PER_DAY = 86_400L

  /** `PopopxDiscoverClock.maximumInboxRows`, DiscoverSubscriptionManager.swift:581. */
  const val MAXIMUM_INBOX_ROWS = 40

  /** `PopopxDiscoverNotice.categoryIdentifier`, DiscoverSubscriptionManager.swift:585 — a wire literal: the notification channel this module posts into and nothing else. */
  const val SHORTFALL_CHANNEL_ID = "popopx.discover.shortfall"
}

/**
 * The three plaza shelves (DiscoverCatalogModels.swift:168-200). The raw values are STORAGE keys:
 * a subscription is filed under its section's raw value on iOS, so renaming one re-reads an
 * existing subscription as unsectioned (:166-167). Titles are the iOS localization keys, verbatim.
 */
enum class PopopxDiscoverSection(val rawValue: String) {
  PRODUCTIVITY("productivity"),
  COMPUTE("compute"),
  SANCTUARY("sanctuary"),
  ;

  val id: String get() = rawValue

  /** The shelf heading (`title`, DiscoverCatalogModels.swift:175-181). */
  val title: String
    get() = when (this) {
      PRODUCTIVITY -> "Work & Productivity"
      COMPUTE -> "Compute & Mesh"
      SANCTUARY -> "Life & Sanctuary"
    }

  /** The filter chip, deliberately shorter than the heading (:183-191). */
  val filterTitle: String
    get() = when (this) {
      PRODUCTIVITY -> "Productivity"
      COMPUTE -> "Edge compute"
      SANCTUARY -> "Home"
    }

  val symbol: String
    get() = when (this) {
      PRODUCTIVITY -> "square.grid.2x2"
      COMPUTE -> "point.3.connected.trianglepath.dotted"
      SANCTUARY -> "house.and.flag"
    }

  companion object {
    fun from(rawValue: String): PopopxDiscoverSection? = entries.firstOrNull { it.rawValue == rawValue }
  }
}

/** The plaza filter (PopopxDiscoverView.swift:498-523). `ALL` is a case, not null, as on iOS. */
enum class PopopxDiscoverFilter(val rawValue: String) {
  ALL("all"),
  PRODUCTIVITY("productivity"),
  COMPUTE("compute"),
  SANCTUARY("sanctuary"),
  ;

  val id: String get() = rawValue

  val title: String
    get() = when (this) {
      ALL -> "All"
      PRODUCTIVITY -> PopopxDiscoverSection.PRODUCTIVITY.filterTitle
      COMPUTE -> PopopxDiscoverSection.COMPUTE.filterTitle
      SANCTUARY -> PopopxDiscoverSection.SANCTUARY.filterTitle
    }

  fun matches(section: PopopxDiscoverSection): Boolean =
    this == ALL || rawValue == section.rawValue
}

/**
 * What one 30-day cycle of a service costs (DiscoverCatalogModels.swift:208-229). MEASURED: there
 * is no tiered price — each service carries exactly one `cycleCost`, nine flat packs and one
 * metered node. `renewalCredits == null` is the answer that stops the renewal engine: a metered
 * service has no cycle to renew and must never be given a nominal figure (:213-215).
 */
sealed class PopopxNodeCycleCost {
  data class Credits(val amount: Int) : PopopxNodeCycleCost()

  data object UsageBased : PopopxNodeCycleCost()

  val renewalCredits: Int?
    get() = when (this) {
      is Credits -> amount
      UsageBased -> null
    }

  val isRenewable: Boolean get() = renewalCredits != null

  /** The price chip, formatted the way the iOS key does (`cyclePriceFormat`, :696; `usageBasedPrice`, :697). */
  val priceLabel: String
    get() = when (this) {
      is Credits -> "$amount Compute Credits / ${PopopxDiscoverLimits.CYCLE_DAYS} days"
      UsageBased -> "Metered, settled per job"
    }
}

/** One button of a service's bottom menu (DiscoverCatalogModels.swift:427-435). */
data class PopopxNodeMenuAction(val title: String, val action: String, val serviceId: PopopxNodeServiceId) {
  val id: String get() = "${serviceId.rawValue}.$action"

  val command: PopopxNodeCommand get() = PopopxNodeCommand(serviceId, action)
}

/**
 * The ten official service accounts, keyed by the host's `EngineKind` raw values
 * (DiscoverCatalogModels.swift:234-424). Those 10 strings are the whole interoperability surface
 * (:14-17): `NodeWire.parseCommand` on the host rejects a command whose first segment is not one
 * of them, so this list is a character-for-character mirror and must never be renamed for taste.
 */
enum class PopopxNodeServiceId(
  val rawValue: String,
  /**
   * The name the host prints in its result card — a WIRE MATCHING STRING used by
   * [PopopxNodeResultCard.detect], never localized (DiscoverCatalogModels.swift:248-263).
   */
  val nodeDisplayName: String,
  val tagline: String,
  val symbol: String,
  val section: PopopxDiscoverSection,
  val cycleCost: PopopxNodeCycleCost,
  val highlights: List<String>,
) {
  ShadowCos(
    rawValue = "shadow_cos",
    nodeDisplayName = "Shadow Chief of Staff",
    tagline = "Daily local briefing and live meeting prompts",
    symbol = "brain.head.profile",
    section = PopopxDiscoverSection.PRODUCTIVITY,
    cycleCost = PopopxNodeCycleCost.Credits(200),
    highlights = listOf(PopopxDiscoverHighlight.RUNS_ON_YOUR_MACHINE, PopopxDiscoverHighlight.READS_ONLY_AUTHORISED_FOLDERS, PopopxDiscoverHighlight.WORKS_WITH_NO_ACCOUNT),
  ),
  ZeroTrustWarroom(
    rawValue = "zero_trust_warroom",
    nodeDisplayName = "Zero-Trust War Room",
    tagline = "Physically isolated team room with blind watermark tracing",
    symbol = "water.waves",
    section = PopopxDiscoverSection.PRODUCTIVITY,
    cycleCost = PopopxNodeCycleCost.Credits(500),
    highlights = listOf(PopopxDiscoverHighlight.RUNS_ON_YOUR_MACHINE, PopopxDiscoverHighlight.BLIND_WATERMARK_PER_COPY, PopopxDiscoverHighlight.WORKS_WITH_NO_ACCOUNT),
  ),
  ZerotraceStudio(
    rawValue = "zerotrace_studio",
    nodeDisplayName = "Zero-Trace Studio",
    tagline = "On-device fingerprint removal and presenter synthesis",
    symbol = "eye.slash",
    section = PopopxDiscoverSection.PRODUCTIVITY,
    cycleCost = PopopxNodeCycleCost.Credits(300),
    highlights = listOf(PopopxDiscoverHighlight.REMOVES_CAMERA_FINGERPRINTS, PopopxDiscoverHighlight.RUNS_ON_YOUR_MACHINE, PopopxDiscoverHighlight.WORKS_WITH_NO_ACCOUNT),
  ),
  SoloAutopilot(
    rawValue = "solo_autopilot",
    nodeDisplayName = "Solo Autopilot",
    tagline = "From topic to finished clip, unattended",
    symbol = "film.stack",
    section = PopopxDiscoverSection.PRODUCTIVITY,
    cycleCost = PopopxNodeCycleCost.Credits(500),
    highlights = listOf(PopopxDiscoverHighlight.QUEUES_OVERNIGHT, PopopxDiscoverHighlight.RUNS_ON_YOUR_MACHINE, PopopxDiscoverHighlight.WORKS_WITH_NO_ACCOUNT),
  ),
  CreatorPaywallHub(
    rawValue = "creator_paywall_hub",
    nodeDisplayName = "Creator Paywall Hub",
    tagline = "Subscription threshold, fingerprinted delivery and credit red packets",
    symbol = "play.tv",
    section = PopopxDiscoverSection.PRODUCTIVITY,
    cycleCost = PopopxNodeCycleCost.Credits(300),
    highlights = listOf(PopopxDiscoverHighlight.YOU_SET_THE_PRICE, PopopxDiscoverHighlight.BLIND_WATERMARK_PER_COPY, PopopxDiscoverHighlight.RUNS_ON_YOUR_MACHINE),
  ),
  EdgeComputeMesh(
    rawValue = "edge_compute_mesh",
    nodeDisplayName = "Edge Compute Mesh",
    tagline = "Publish metered jobs, or lend idle cycles for credit",
    symbol = "point.3.connected.trianglepath.dotted",
    section = PopopxDiscoverSection.COMPUTE,
    cycleCost = PopopxNodeCycleCost.UsageBased,
    highlights = listOf(PopopxDiscoverHighlight.SETTLED_PER_JOB, PopopxDiscoverHighlight.YOU_DECIDE_WHAT_TO_LEND, PopopxDiscoverHighlight.RUNS_ON_YOUR_MACHINE),
  ),
  MorningTv(
    rawValue = "morning_tv",
    nodeDisplayName = "Morning TV",
    tagline = "A five-minute private morning bulletin, no tracking",
    symbol = "sun.horizon",
    section = PopopxDiscoverSection.COMPUTE,
    cycleCost = PopopxNodeCycleCost.Credits(100),
    highlights = listOf(PopopxDiscoverHighlight.NO_RECOMMENDATION_FEED, PopopxDiscoverHighlight.FIRES_ON_YOUR_CLOCK, PopopxDiscoverHighlight.WORKS_WITH_NO_ACCOUNT),
  ),
  PhantomSentinel(
    rawValue = "phantom_sentinel",
    nodeDisplayName = "Phantom Sentinel",
    tagline = "Deterministic one-tap lockdown and daily security brief",
    symbol = "lock.shield",
    section = PopopxDiscoverSection.SANCTUARY,
    cycleCost = PopopxNodeCycleCost.Credits(100),
    highlights = listOf(PopopxDiscoverHighlight.NO_MODEL_IN_THE_PATH, PopopxDiscoverHighlight.ONE_TAP_STATE_MACHINE, PopopxDiscoverHighlight.RUNS_ON_YOUR_MACHINE),
  ),
  ChronoArk(
    rawValue = "chrono_ark",
    nodeDisplayName = "Chrono Ark",
    tagline = "Encrypted family vault with a time-locked capsule",
    symbol = "hourglass",
    section = PopopxDiscoverSection.SANCTUARY,
    cycleCost = PopopxNodeCycleCost.Credits(200),
    highlights = listOf(PopopxDiscoverHighlight.ENCRYPTED_AT_REST, PopopxDiscoverHighlight.OPENS_AFTER_YOUR_DATE, PopopxDiscoverHighlight.RUNS_ON_YOUR_MACHINE),
  ),
  HealthSentinel(
    rawValue = "health_sentinel",
    nodeDisplayName = "Health Sentinel",
    tagline = "Offline report reading and sleep soundscapes",
    symbol = "heart.text.square",
    section = PopopxDiscoverSection.SANCTUARY,
    cycleCost = PopopxNodeCycleCost.Credits(200),
    highlights = listOf(PopopxDiscoverHighlight.REPORTS_PARSED_OFFLINE, PopopxDiscoverHighlight.WORKS_WITH_NO_ACCOUNT, PopopxDiscoverHighlight.RUNS_ON_YOUR_MACHINE),
  ),
  ;

  val id: String get() = rawValue

  /**
   * The plaza name. iOS runs this through `NSLocalizedString` keyed by [nodeDisplayName]
   * (:265-268), and a locale without an entry falls back to exactly that key — which is the only
   * behaviour this module has, and the reason it stays identity here rather than a TODO.
   */
  val title: String get() = nodeDisplayName

  /**
   * Three buttons per service, and every token is in that engine's accepted set on the host
   * (`TenBusinessEngines.swift:2199-2325`, transcribed at DiscoverCatalogModels.swift:330-393).
   * A token outside that table is answered by the node's `unsupported(...)` card, which is a
   * protocol deviation, not a feature. Computed, not a constructor argument, because a menu
   * action names the entry it belongs to.
   */
  val menuActions: List<PopopxNodeMenuAction>
    get() = when (this) {
      ShadowCos ->
        listOf(
          PopopxNodeMenuAction("Today's action brief", "briefing", this),
          PopopxNodeMenuAction("Live meeting prompts", "negotiation_prompt", this),
          PopopxNodeMenuAction("Ask the local knowledge base", "generate", this),
        )
      ZeroTrustWarroom ->
        listOf(
          PopopxNodeMenuAction("Create isolated room", "assign", this),
          PopopxNodeMenuAction("Trace a leaked copy", "trace", this),
          PopopxNodeMenuAction("Audit member access", "registry", this),
        )
      ZerotraceStudio ->
        listOf(
          PopopxNodeMenuAction("Sanitise source media", "strip", this),
          PopopxNodeMenuAction("Switch virtual presenter", "anchor", this),
          PopopxNodeMenuAction("Distribute to channels", "broadcast", this),
        )
      SoloAutopilot ->
        listOf(
          PopopxNodeMenuAction("Today's finished clips", "run", this),
          PopopxNodeMenuAction("Set trending keywords", "script", this),
          PopopxNodeMenuAction("Generate support QR", "generate", this),
        )
      CreatorPaywallHub ->
        listOf(
          PopopxNodeMenuAction("New paid channel", "grant", this),
          PopopxNodeMenuAction("Send credit red packet", "red_packet", this),
          PopopxNodeMenuAction("Channel earnings", "ledger", this),
        )
      EdgeComputeMesh ->
        listOf(
          PopopxNodeMenuAction("Publish a compute job", "offer", this),
          PopopxNodeMenuAction("Bond node, accept jobs", "enable", this),
          PopopxNodeMenuAction("Earnings statement", "settle", this),
        )
      MorningTv ->
        listOf(
          PopopxNodeMenuAction("Play today's bulletin", "broadcast", this),
          PopopxNodeMenuAction("Choose feeds", "digest", this),
          PopopxNodeMenuAction("Change broadcast window", "schedule", this),
        )
      PhantomSentinel ->
        listOf(
          PopopxNodeMenuAction("Lock down the house", PopopxNodeWire.DETERMINISTIC_LOCK_ACTION, this),
          PopopxNodeMenuAction("Capture a snapshot", "probe", this),
          PopopxNodeMenuAction("Build the security brief", "status", this),
        )
      ChronoArk ->
        listOf(
          PopopxNodeMenuAction("Confirm safety heartbeat", "heartbeat", this),
          PopopxNodeMenuAction("Seal a time capsule", "seal", this),
          PopopxNodeMenuAction("Manage trusted contacts", "check", this),
        )
      HealthSentinel ->
        listOf(
          PopopxNodeMenuAction("Read a health report", "read", this),
          PopopxNodeMenuAction("Compose a sleep soundscape", "binaural", this),
          PopopxNodeMenuAction("Household trend", "report", this),
        )
    }

  companion object {
    /** The host's `EngineKind` lookup: an unknown id is not a service, as on the wire. */
    fun from(rawValue: String): PopopxNodeServiceId? = entries.firstOrNull { it.rawValue == rawValue }
  }
}

/** The 15 selling-point sentences, one constant each (DiscoverCatalogModels.swift:797-812). */
object PopopxDiscoverHighlight {
  const val RUNS_ON_YOUR_MACHINE = "Runs on your own Mac"
  const val READS_ONLY_AUTHORISED_FOLDERS = "Reads only the folders you authorise"
  const val WORKS_WITH_NO_ACCOUNT = "Works with no account"
  const val BLIND_WATERMARK_PER_COPY = "Blind watermark per copy"
  const val REMOVES_CAMERA_FINGERPRINTS = "Removes camera fingerprints"
  const val QUEUES_OVERNIGHT = "Queues overnight, reports in the morning"
  const val YOU_SET_THE_PRICE = "You set the price per member"
  const val SETTLED_PER_JOB = "Settled per job, 10% protocol fee"
  const val YOU_DECIDE_WHAT_TO_LEND = "Your machine decides what to lend"
  const val NO_RECOMMENDATION_FEED = "No recommendation feed"
  const val FIRES_ON_YOUR_CLOCK = "Fires on your own clock"
  const val NO_MODEL_IN_THE_PATH = "No model in the path"
  const val ONE_TAP_STATE_MACHINE = "One tap, one state machine"
  const val ENCRYPTED_AT_REST = "Encrypted at rest on your Mac"
  const val OPENS_AFTER_YOUR_DATE = "Opens only after the date you set"
  const val REPORTS_PARSED_OFFLINE = "Reports are parsed offline"
}

/** The plaza catalogue: the ten services, their shelves, and the search the plaza runs over them. */
object PopopxDiscoverCatalog {
  /** Declaration order is `CaseIterable` order on iOS, which is the shelf order. */
  val services: List<PopopxNodeServiceId> = PopopxNodeServiceId.entries.toList()

  /** `PopopxNodeServiceId.grouped(_:)`, DiscoverCatalogModels.swift:421-423. */
  fun grouped(section: PopopxDiscoverSection): List<PopopxNodeServiceId> = services.filter { it.section == section }

  /**
   * The search the plaza runs (PopopxDiscoverView.swift:539-551): lower-cased substring match over
   * the plaza name, the name the Mac itself prints, the tagline, the service id with its
   * underscores turned into spaces, and the menu-button titles. Matching [PopopxNodeServiceId.nodeDisplayName]
   * is what lets a user who has read a result card find the tile that produced it.
   */
  fun matchesSearch(service: PopopxNodeServiceId, query: String): Boolean {
    val needle = query.lowercase()
    return service.title.lowercase().contains(needle) ||
      service.nodeDisplayName.lowercase().contains(needle) ||
      service.tagline.lowercase().contains(needle) ||
      service.rawValue.lowercase().replace('_', ' ').contains(needle) ||
      service.menuActions.any { it.title.lowercase().contains(needle) }
  }

  /** One shelf that still holds something after filter and search (PopopxDiscoverView.swift:95-104). */
  data class Shelf(val section: PopopxDiscoverSection, val services: List<PopopxNodeServiceId>) {
    val id: String get() = section.rawValue
  }

  /** The plaza's visible shelves: filter first, then search, empty shelves dropped whole. */
  fun visibleSections(filter: PopopxDiscoverFilter, query: String): List<Shelf> {
    val trimmed = query.trim { it.isWhitespace() }
    return PopopxDiscoverSection.entries.mapNotNull { section ->
      if (!filter.matches(section)) return@mapNotNull null
      val services = grouped(section).filter { trimmed.isEmpty() || matchesSearch(it, trimmed) }
      if (services.isEmpty()) null else Shelf(section, services)
    }
  }
}

/**
 * The local console bridge, as `popopx-mac-node` publishes it.
 *
 * MEASURED AND BINDING: this app never opens a connection to [CONSOLE_HOST]:[CONSOLE_PORT]
 * (MacNodePairingSheet.swift:616-619 — "the app does not open a socket to 127.0.0.1:18920; on a
 * phone that address is the phone"). On iOS the address is shown so a tool running on the same
 * Mac can be configured, and the transport that actually carries a node command is the SMP
 * invisible text in [PopopxNodeCommand]. Everything in this object is therefore display and copy
 * text, and nothing here may become a network call.
 */
object PopopxNodeConsole {
  /** `PopopxNodeWire.consoleHost`, DiscoverCatalogModels.swift:70. */
  const val CONSOLE_HOST = "127.0.0.1"

  /** `PopopxNodeWire.consolePort`, DiscoverCatalogModels.swift:71. */
  const val CONSOLE_PORT = 18_920

  /** `PopopxNodeWire.consoleTokenHeader`, DiscoverCatalogModels.swift:72. */
  const val CONSOLE_TOKEN_HEADER = "X-PPX-Token"

  /** `PopopxNodeWire.consoleTokenQueryItem`, DiscoverCatalogModels.swift:73. */
  const val CONSOLE_TOKEN_QUERY_ITEM = "t"

  /** The string the bridge pane shows and the copy button writes to the clipboard (MacNodePairingSheet.swift:647-649, :638-640). */
  fun consoleDisplayUrl(): String = "http://$CONSOLE_HOST:$CONSOLE_PORT/"

  /** Same text as [consoleDisplayUrl] — named apart so no caller mistakes "copy" for "connect". */
  fun copyText(): String = consoleDisplayUrl()

  /** The token contract line, shown verbatim, never sent by this app (MacNodePairingSheet.swift:651-653). */
  fun tokenContractText(): String = "$CONSOLE_TOKEN_HEADER: \$PPX_BRIDGE_SECRET · ?$CONSOLE_TOKEN_QUERY_ITEM=\$PPX_BRIDGE_SECRET"

  /** The pasteboard carries only the address; this is that action's one honest description. */
  const val LOCAL_ONLY_NOTE =
    "This address is on the Mac itself. The app shows it so a tool running there can be configured; it does not connect to it."
}
