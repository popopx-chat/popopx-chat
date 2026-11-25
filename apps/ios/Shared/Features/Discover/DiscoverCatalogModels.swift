//
//  DiscoverCatalogModels.swift
//  POPOPX (iOS / Shared)
//
//  The "Discover" ecosystem plaza: the 10 official service accounts, the 30-day
//  compute-credit billing vocabulary, and the iOS half of the Mac Node wire contract
//  `::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}`.
//
//  Where the numbers and the names come from — every literal in this file is copied
//  from the finished host (`popopx-mac-node`), never invented here:
//  * `Sources/PopopxMacNode/Models/MacNodeModels.swift:40`/`:44`/`:55` — the marker, the segment
//    count, the pairing prefix `PPXNODE1`; `:58`/`:90`/`:93`/`:96` give the console port, the
//    console host, its token header and its query item; `:102` gives the 15-minute offer lifetime.
//  * `MacNodeModels.swift:1208-1218` — the ten `EngineKind` raw values. Those 10 strings
//    are the whole interoperability surface: `NodeWire.parseCommand` rejects a command
//    whose first segment is not one of them, so `PopopxNodeServiceId` below is a
//    character-for-character mirror and must never be renamed for taste.
//  * `Engines/TenBusinessEngines.swift:2199-2325` — the accepted `action` vocabulary per
//    engine. Every menu button in `PopopxNodeServiceId.menuActions` carries a token that
//    table actually accepts; sending a token outside it would be answered by the node's
//    `unsupported(...)` card, which is a protocol deviation, not a feature.
//  * `Core/MacNodePopopxBridge.swift:586-620` — the pairing code shape
//    `PPXNODE1-<base64url(signed body)>.<base64url(signature)>`, the body keys
//    `v/node/key/link/iat/exp/once`, and the fact that the signature is Ed25519
//    (`Curve25519.Signing`) over the *stored* body bytes. Verification therefore uses the
//    decoded bytes rather than a re-encoded dictionary, exactly as the host does.
//
//  Two measured facts about the host that shape this module, both stated here so nobody
//  re-derives them from the brief:
//  * The host has no `system` engine. A `NODE_CMD::system::pair_ack::…` signal is refused
//    by its own parser, so the pairing handshake below is a real command to a real engine
//    (`edge_compute_mesh::status`; host `TenBusinessEngines.swift:2253-2254` routes that arm to `meshStatusResult(commandID:)`, which takes no payload) instead.
//  * The host answers results as *unmarked* plain text (`CommandResult.cardText`,
//    `MacNodeModels.swift:1197-1201`: `✅ <English engine name> · <headline> · <ms>`).
//    Only the outbound direction carries a marker. `PopopxNodeResultCard` below therefore
//    recognises a result by its shape **and only for the contact bound to the node** —
//    it is a renderer, never a suppression rule, so no message can vanish.
//

import Foundation
import CryptoKit

// MARK: - Wire contract

/// Constants of the node protocol, named after the host's own `NodeWire`.
///
/// The values are duplicated rather than shared because the two products ship as separate
/// binaries; the host re-states them in `Docs/` and a drift here is a drift there, which is
/// why each one carries the line it was read from.
enum PopopxNodeWire {
    /// `MacNodeModels.swift:40`. Equal to `PopopxSysMarker.marker` + `NODE_CMD::`, and the
    /// router rebuilds the whole line from the kind, so only the tail is ever passed here.
    static let commandPrefix = "::popopx_sys::NODE_CMD::"

    /// `MacNodeModels.swift:44` — `serviceId`, `action`, `payload`.
    static let segmentCount = 3

    /// The host splits on the first `::` after the marker, twice, and leaves the rest alone.
    static let segmentSeparator = "::"

    /// `MacNodeModels.swift:55`. The host's own prefix, dash included once the body follows.
    static let pairingCodePrefix = "PPXNODE1"

    /// `MacNodeModels.swift:98-99`: `lockTriggers` = a padlock glyph, `LOCK_ALL`, `lock_all`. `lock_all` is the one
    /// this app sends: it survives the marker path, while a bare `🔒` only triggers the
    /// host's pre-parser when it is the *whole* message, which a marked signal never is.
    static let deterministicLockAction = "lock_all"

    /// `MacNodeModels.swift:58` (port 18920) and `:89-96` (host, token header, token query).
    static let consoleHost = "127.0.0.1"
    static let consolePort: UInt16 = 18920
    static let consoleTokenHeader = "X-PPX-Token"
    static let consoleTokenQueryItem = "t"

    /// `MacNodeModels.swift:101-102`. A one-time offer this old is refused by the host even
    /// before it looks at the signature.
    static let pairingOfferLifetime: TimeInterval = 15 * 60

    /// The host's minimum bridge secret (`allowLockdown` requires it); quoted in the guide
    /// so the exported credential matches what the daemon will accept.
    static let bridgeSecretMinimumCharacters = 16

    /// The signalling ceiling is inherited, not restated: `PopopxSysMarker.parse` refuses a
    /// payload over this size before a node command is ever attempted, and it counts
    /// `serviceId::action::payload`. The host charges two characters less for the same
    /// string (`MacNodeModels.swift:129-132`), so this side is the stricter one and
    /// anything this app emits is inside the host's budget.
    static var maximumSignalPayloadCharacters: Int { PopopxCommerceLimits.maximumSignalPayloadCharacters }

    /// True when the host's parser would accept this command at all — the single question
    /// the send path asks before it touches SMP.
    static func isAccepted(_ command: PopopxNodeCmd) -> Bool {
        let used = command.serviceId.rawValue.count + command.action.count + command.payload.count
        return !command.action.isEmpty
            && !command.payload.isEmpty
            && used + (segmentCount - 1) * segmentSeparator.count <= maximumSignalPayloadCharacters
    }
}

// MARK: - Command

/// One decoded `NODE_CMD`: the three segments after the marker.
///
/// It lives inside `PopopxCommerceSignalKind.nodeCmd`'s payload field rather than beside it,
/// because the marker parser already owns the `::popopx_sys::{KIND}::` half and the render
/// suppression keys off that one parse. Splitting only the first two separators is the
/// host's rule and is kept here verbatim: a JSON payload containing `::` must survive.
struct PopopxNodeCmd: Hashable, Sendable {
    let serviceId: PopopxNodeServiceId
    let action: String
    let payload: String

    init(serviceId: PopopxNodeServiceId, action: String, payload: String = "{}") {
        self.serviceId = serviceId
        self.action = action
        self.payload = payload
    }

    /// What goes into `PopopxCommerceSignal.payload`.
    var signalPayload: String {
        [serviceId.rawValue, action, payload].joined(separator: PopopxNodeWire.segmentSeparator)
    }

    /// The complete line SMP carries, identical to the host's `NodeCommand.wireString`
    /// (`MacNodeModels.swift:1147-1149`).
    var wireString: String { PopopxNodeWire.commandPrefix + signalPayload }

    var isAcceptedByNode: Bool { PopopxNodeWire.isAccepted(self) }

    /// Decodes the payload half of a `NODE_CMD` signal.
    ///
    /// Mirrors the host's stricter `parseCommand` (`MacNodeModels.swift:115-138`): all three
    /// segments must be non-empty and the engine id must be known, so a command this app
    /// would refuse is never accepted from the wire either. An unknown `serviceId` returns
    /// nil, which leaves the line unparsed and suppressed by the marker rather than routed
    /// to a service that does not exist.
    init?(signalPayload: String) {
        var remaining = Substring(signalPayload)
        var segments: [String] = []
        while segments.count < PopopxNodeWire.segmentCount - 1,
              let separator = remaining.range(of: PopopxNodeWire.segmentSeparator) {
            segments.append(String(remaining[..<separator.lowerBound]))
            remaining = remaining[separator.upperBound...]
        }
        segments.append(String(remaining))
        guard segments.count == PopopxNodeWire.segmentCount,
              let serviceId = PopopxNodeServiceId(rawValue: segments[0].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let action = segments[1].trimmingCharacters(in: .whitespaces)
        guard !action.isEmpty, !segments[2].isEmpty else { return nil }
        self.serviceId = serviceId
        self.action = action
        self.payload = segments[2]
    }

    /// Convenience for a line that still carries the marker (a stored bubble, a pasted text).
    init?(wireString text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(PopopxNodeWire.commandPrefix) else { return nil }
        self.init(signalPayload: String(trimmed.dropFirst(PopopxNodeWire.commandPrefix.count)))
    }
}

// MARK: - Sections

/// The three plaza shelves of module two. Raw values are storage keys, so renaming one
/// re-reads an existing subscription as unsectioned.
enum PopopxDiscoverSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case productivity
    case compute
    case sanctuary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .productivity: NSLocalizedString("Work & Productivity", comment: "discover section")
        case .compute: NSLocalizedString("Compute & Mesh", comment: "discover section")
        case .sanctuary: NSLocalizedString("Life & Sanctuary", comment: "discover section")
        }
    }

    /// The filter chip is shorter than the shelf heading: five chips in a 320 pt row is
    /// where a long heading becomes an ellipsis.
    var filterTitle: String {
        switch self {
        case .productivity: NSLocalizedString("Productivity", comment: "discover filter chip")
        case .compute: NSLocalizedString("Edge compute", comment: "discover filter chip")
        case .sanctuary: NSLocalizedString("Home", comment: "discover filter chip")
        }
    }

    var symbol: String {
        switch self {
        case .productivity: "square.grid.2x2"
        case .compute: "point.3.connected.trianglepath.dotted"
        case .sanctuary: "house.and.flag"
        }
    }
}

// MARK: - Billing

/// What one 30-day cycle of a service costs.
///
/// Nine of the ten services are flat-rate packs; the mesh node is metered, and pretending
/// otherwise would print a price the settlement engine does not charge.
enum PopopxNodeCycleCost: Hashable, Sendable {
    case credits(Int)
    case usageBased

    /// The amount the renewal engine is allowed to debit. nil is the answer that stops it:
    /// a metered service has no cycle to renew and must never be given a nominal figure.
    var renewalCredits: Int? {
        switch self {
        case let .credits(amount): amount
        case .usageBased: nil
        }
    }

    var isRenewable: Bool { renewalCredits != nil }

    var priceLabel: String {
        switch self {
        case let .credits(amount): String(format: DiscoverCopy.cyclePriceFormat, amount)
        case .usageBased: DiscoverCopy.usageBasedPrice
        }
    }
}

// MARK: - Service accounts

/// The ten official service accounts, keyed by the host's `EngineKind` raw value.
enum PopopxNodeServiceId: String, Codable, CaseIterable, Identifiable, Sendable {
    case shadowCos = "shadow_cos"
    case zeroTrustWarroom = "zero_trust_warroom"
    case zerotraceStudio = "zerotrace_studio"
    case soloAutopilot = "solo_autopilot"
    case creatorPaywallHub = "creator_paywall_hub"
    case edgeComputeMesh = "edge_compute_mesh"
    case morningTv = "morning_tv"
    case phantomSentinel = "phantom_sentinel"
    case chronoArk = "chrono_ark"
    case healthSentinel = "health_sentinel"

    var id: String { rawValue }

    /// The name the host prints in its result card. **Never localized** — it is a wire
    /// literal, and `PopopxNodeResultCard.detect` matches on it.
    var nodeDisplayName: String {
        switch self {
        case .shadowCos: "Shadow Chief of Staff"
        case .zeroTrustWarroom: "Zero-Trust War Room"
        case .zerotraceStudio: "Zero-Trace Studio"
        case .soloAutopilot: "Solo Autopilot"
        case .creatorPaywallHub: "Creator Paywall Hub"
        case .edgeComputeMesh: "Edge Compute Mesh"
        case .morningTv: "Morning TV"
        case .phantomSentinel: "Phantom Sentinel"
        case .chronoArk: "Chrono Ark"
        case .healthSentinel: "Health Sentinel"
        }
    }

    /// The plaza name, from the 16 catalogues. The key is the host's English name, so a
    /// locale without an entry falls back to exactly what the node prints rather than to a
    /// half-translated third spelling.
    var title: String { NSLocalizedString(nodeDisplayName, comment: "discover service name") }

    var tagline: String {
        switch self {
        case .shadowCos: NSLocalizedString("Daily local briefing and live meeting prompts", comment: "discover service tagline")
        case .zeroTrustWarroom: NSLocalizedString("Physically isolated team room with blind watermark tracing", comment: "discover service tagline")
        case .zerotraceStudio: NSLocalizedString("On-device fingerprint removal and presenter synthesis", comment: "discover service tagline")
        case .soloAutopilot: NSLocalizedString("From topic to finished clip, unattended", comment: "discover service tagline")
        case .creatorPaywallHub: NSLocalizedString("Subscription threshold, fingerprinted delivery and credit red packets", comment: "discover service tagline")
        case .edgeComputeMesh: NSLocalizedString("Publish metered jobs, or lend idle cycles for credit", comment: "discover service tagline")
        case .morningTv: NSLocalizedString("A five-minute private morning bulletin, no tracking", comment: "discover service tagline")
        case .phantomSentinel: NSLocalizedString("Deterministic one-tap lockdown and daily security brief", comment: "discover service tagline")
        case .chronoArk: NSLocalizedString("Encrypted family vault with a time-locked capsule", comment: "discover service tagline")
        case .healthSentinel: NSLocalizedString("Offline report reading and sleep soundscapes", comment: "discover service tagline")
        }
    }

    /// Same symbol the host's own menu uses, so a user who sees both surfaces sees one icon.
    var symbol: String {
        switch self {
        case .shadowCos: "brain.head.profile"
        case .zeroTrustWarroom: "water.waves"
        case .zerotraceStudio: "eye.slash"
        case .soloAutopilot: "film.stack"
        case .creatorPaywallHub: "play.tv"
        case .edgeComputeMesh: "point.3.connected.trianglepath.dotted"
        case .morningTv: "sun.horizon"
        case .phantomSentinel: "lock.shield"
        case .chronoArk: "hourglass"
        case .healthSentinel: "heart.text.square"
        }
    }

    var section: PopopxDiscoverSection {
        switch self {
        case .shadowCos, .zeroTrustWarroom, .zerotraceStudio, .soloAutopilot, .creatorPaywallHub: .productivity
        case .edgeComputeMesh, .morningTv: .compute
        case .phantomSentinel, .chronoArk, .healthSentinel: .sanctuary
        }
    }

    /// The 30-day price of one cycle, per the requirement sheet. `edge_compute_mesh` is
    /// metered with a 10% protocol fee and has no cycle at all.
    var cycleCost: PopopxNodeCycleCost {
        switch self {
        case .shadowCos: .credits(200)
        case .zeroTrustWarroom: .credits(500)
        case .zerotraceStudio: .credits(300)
        case .soloAutopilot: .credits(500)
        case .creatorPaywallHub: .credits(300)
        case .edgeComputeMesh: .usageBased
        case .morningTv: .credits(100)
        case .phantomSentinel: .credits(100)
        case .chronoArk: .credits(200)
        case .healthSentinel: .credits(200)
        }
    }

    /// Three buttons per service, and every `action` token is in that engine's accepted set
    /// (`TenBusinessEngines.swift:2199-2325`). Payload is always `{}`: the host's handlers
    /// read their parameters from the node's own settings document, and an empty object is
    /// the only argument every handler treats as "use what is configured".
    var menuActions: [PopopxNodeMenuAction] {
        switch self {
        case .shadowCos:
            [
                PopopxNodeMenuAction(title: NSLocalizedString("Today's action brief", comment: "discover menu action"), action: "briefing", serviceId: .shadowCos),
                PopopxNodeMenuAction(title: NSLocalizedString("Live meeting prompts", comment: "discover menu action"), action: "negotiation_prompt", serviceId: .shadowCos),
                PopopxNodeMenuAction(title: NSLocalizedString("Ask the local knowledge base", comment: "discover menu action"), action: "generate", serviceId: .shadowCos)
            ]
        case .zeroTrustWarroom:
            [
                PopopxNodeMenuAction(title: NSLocalizedString("Create isolated room", comment: "discover menu action"), action: "assign", serviceId: .zeroTrustWarroom),
                PopopxNodeMenuAction(title: NSLocalizedString("Trace a leaked copy", comment: "discover menu action"), action: "trace", serviceId: .zeroTrustWarroom),
                PopopxNodeMenuAction(title: NSLocalizedString("Audit member access", comment: "discover menu action"), action: "registry", serviceId: .zeroTrustWarroom)
            ]
        case .zerotraceStudio:
            [
                PopopxNodeMenuAction(title: NSLocalizedString("Sanitise source media", comment: "discover menu action"), action: "strip", serviceId: .zerotraceStudio),
                PopopxNodeMenuAction(title: NSLocalizedString("Switch virtual presenter", comment: "discover menu action"), action: "anchor", serviceId: .zerotraceStudio),
                PopopxNodeMenuAction(title: NSLocalizedString("Distribute to channels", comment: "discover menu action"), action: "broadcast", serviceId: .zerotraceStudio)
            ]
        case .soloAutopilot:
            [
                PopopxNodeMenuAction(title: NSLocalizedString("Today's finished clips", comment: "discover menu action"), action: "run", serviceId: .soloAutopilot),
                PopopxNodeMenuAction(title: NSLocalizedString("Set trending keywords", comment: "discover menu action"), action: "script", serviceId: .soloAutopilot),
                PopopxNodeMenuAction(title: NSLocalizedString("Generate support QR", comment: "discover menu action"), action: "generate", serviceId: .soloAutopilot)
            ]
        case .creatorPaywallHub:
            [
                PopopxNodeMenuAction(title: NSLocalizedString("New paid channel", comment: "discover menu action"), action: "grant", serviceId: .creatorPaywallHub),
                PopopxNodeMenuAction(title: NSLocalizedString("Send credit red packet", comment: "discover menu action"), action: "red_packet", serviceId: .creatorPaywallHub),
                PopopxNodeMenuAction(title: NSLocalizedString("Channel earnings", comment: "discover menu action"), action: "ledger", serviceId: .creatorPaywallHub)
            ]
        case .edgeComputeMesh:
            [
                PopopxNodeMenuAction(title: NSLocalizedString("Publish a compute job", comment: "discover menu action"), action: "offer", serviceId: .edgeComputeMesh),
                PopopxNodeMenuAction(title: NSLocalizedString("Bond node, accept jobs", comment: "discover menu action"), action: "enable", serviceId: .edgeComputeMesh),
                PopopxNodeMenuAction(title: NSLocalizedString("Earnings statement", comment: "discover menu action"), action: "settle", serviceId: .edgeComputeMesh)
            ]
        case .morningTv:
            [
                PopopxNodeMenuAction(title: NSLocalizedString("Play today's bulletin", comment: "discover menu action"), action: "broadcast", serviceId: .morningTv),
                PopopxNodeMenuAction(title: NSLocalizedString("Choose feeds", comment: "discover menu action"), action: "digest", serviceId: .morningTv),
                PopopxNodeMenuAction(title: NSLocalizedString("Change broadcast window", comment: "discover menu action"), action: "schedule", serviceId: .morningTv)
            ]
        case .phantomSentinel:
            [
                PopopxNodeMenuAction(title: NSLocalizedString("Lock down the house", comment: "discover menu action"), action: PopopxNodeWire.deterministicLockAction, serviceId: .phantomSentinel),
                PopopxNodeMenuAction(title: NSLocalizedString("Capture a snapshot", comment: "discover menu action"), action: "probe", serviceId: .phantomSentinel),
                PopopxNodeMenuAction(title: NSLocalizedString("Build the security brief", comment: "discover menu action"), action: "status", serviceId: .phantomSentinel)
            ]
        case .chronoArk:
            [
                PopopxNodeMenuAction(title: NSLocalizedString("Confirm safety heartbeat", comment: "discover menu action"), action: "heartbeat", serviceId: .chronoArk),
                PopopxNodeMenuAction(title: NSLocalizedString("Seal a time capsule", comment: "discover menu action"), action: "seal", serviceId: .chronoArk),
                PopopxNodeMenuAction(title: NSLocalizedString("Manage trusted contacts", comment: "discover menu action"), action: "check", serviceId: .chronoArk)
            ]
        case .healthSentinel:
            [
                PopopxNodeMenuAction(title: NSLocalizedString("Read a health report", comment: "discover menu action"), action: "read", serviceId: .healthSentinel),
                PopopxNodeMenuAction(title: NSLocalizedString("Compose a sleep soundscape", comment: "discover menu action"), action: "binaural", serviceId: .healthSentinel),
                PopopxNodeMenuAction(title: NSLocalizedString("Household trend", comment: "discover menu action"), action: "report", serviceId: .healthSentinel)
            ]
        }
    }

    /// The three selling points of the detail sheet, kept short enough for one line each.
    var highlights: [String] {
        switch self {
        case .shadowCos:
            [DiscoverCopy.highlightRunsOnYourMachine, DiscoverCopy.highlightNeverUploadsNotes, DiscoverCopy.highlightWorksOffline]
        case .zeroTrustWarroom:
            [DiscoverCopy.highlightRunsOnYourMachine, DiscoverCopy.highlightBlindWatermark, DiscoverCopy.highlightWorksOffline]
        case .zerotraceStudio:
            [DiscoverCopy.highlightStripsMetadata, DiscoverCopy.highlightRunsOnYourMachine, DiscoverCopy.highlightWorksOffline]
        case .soloAutopilot:
            [DiscoverCopy.highlightUnattendedQueue, DiscoverCopy.highlightRunsOnYourMachine, DiscoverCopy.highlightWorksOffline]
        case .creatorPaywallHub:
            [DiscoverCopy.highlightYouSetTheThreshold, DiscoverCopy.highlightBlindWatermark, DiscoverCopy.highlightRunsOnYourMachine]
        case .edgeComputeMesh:
            [DiscoverCopy.highlightMeteredSettlement, DiscoverCopy.highlightYouKeepYourCycles, DiscoverCopy.highlightRunsOnYourMachine]
        case .morningTv:
            [DiscoverCopy.highlightNoTracking, DiscoverCopy.highlightScheduledLocally, DiscoverCopy.highlightWorksOffline]
        case .phantomSentinel:
            [DiscoverCopy.highlightDeterministic, DiscoverCopy.highlightNoModelInPath, DiscoverCopy.highlightRunsOnYourMachine]
        case .chronoArk:
            [DiscoverCopy.highlightEncryptedAtRest, DiscoverCopy.highlightTimeLocked, DiscoverCopy.highlightRunsOnYourMachine]
        case .healthSentinel:
            [DiscoverCopy.highlightReportsStayLocal, DiscoverCopy.highlightWorksOffline, DiscoverCopy.highlightRunsOnYourMachine]
        }
    }

    static func grouped(_ section: PopopxDiscoverSection) -> [PopopxNodeServiceId] {
        allCases.filter { $0.section == section }
    }
}

/// One button of a service's bottom menu: the label the user reads, the token the node accepts.
struct PopopxNodeMenuAction: Hashable, Identifiable, Sendable {
    let title: String
    let action: String
    let serviceId: PopopxNodeServiceId

    var id: String { "\(serviceId.rawValue).\(action)" }

    var command: PopopxNodeCmd { PopopxNodeCmd(serviceId: serviceId, action: action) }
}

// MARK: - Node result card

/// A result the node sent back, as recognised on this device.
///
/// Deliberately a *renderer*, not a suppression rule. The host emits these lines unmarked
/// (`CommandResult.cardText`), so the only thing that identifies them is their shape, and a
/// shape test can match something a person typed. That is why `detect` is a pure function
/// the caller must gate on `fromPairedNode`, and why a card that fails to decode still
/// renders as the ordinary bubble it arrived as. A marked `NODE_CMD` line, by contrast, is
/// silently swallowed by the existing marker gates in all three places — that is the half
/// of the requirement this app can enforce on its own.
struct PopopxNodeResultCard: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case succeeded
        case degraded

        var symbol: String {
            switch self {
            case .succeeded: "checkmark.seal.fill"
            case .degraded: "exclamationmark.triangle.fill"
            }
        }
    }

    let id: String
    let serviceId: PopopxNodeServiceId
    let status: Status
    let headline: String
    let detail: String
    let durationMilliseconds: Int?
    let receivedAtMs: Int64

    /// `✅ Shadow Chief of Staff · Daily brief ready · 1432 ms` — the flag picks the status,
    /// the first known engine name picks the service, the remainder is the headline, and a
    /// trailing `· <n> ms` is lifted into `durationMilliseconds` so it stops being prose.
    ///
    /// Longest engine name wins: `Health Sentinel` and `Phantom Sentinel` share a suffix, and
    /// the host prints the full name, so a shortest-first scan could mis-file one as the
    /// other's tail.
    static func detect(text: String, fromPairedNode: Bool, now: Date = Date()) -> PopopxNodeResultCard? {
        guard fromPairedNode else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let status: Status
        switch trimmed.first {
        case "✅": status = .succeeded
        case "⚠️", "⚠": status = .degraded
        default: return nil
        }
        let afterFlag = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let serviceId = PopopxNodeServiceId.allCases
            .filter({ afterFlag.hasPrefix("\($0.nodeDisplayName) ·") })
            .max(by: { $0.nodeDisplayName.count < $1.nodeDisplayName.count })
        else { return nil }
        let remainder = afterFlag.dropFirst(serviceId.nodeDisplayName.count + 3)
            .trimmingCharacters(in: .whitespaces)
        let lines = remainder.components(separatedBy: .newlines)
        var headline = (lines.first ?? "").trimmingCharacters(in: .whitespaces)
        var duration: Int?
        if let separator = headline.range(of: " · ", options: .backwards) {
            let tail = String(headline[separator.upperBound...])
            if tail.hasSuffix(" ms") {
                duration = Int(tail.dropLast(3))
                headline = String(headline[..<separator.lowerBound])
            }
        }
        guard !headline.isEmpty else { return nil }
        let detail = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return PopopxNodeResultCard(
            id: "\(serviceId.rawValue).\(Int(now.timeIntervalSince1970 * 1_000)).\(headline.hashValue &+ detail.hashValue)",
            serviceId: serviceId,
            status: status,
            headline: headline,
            detail: detail,
            durationMilliseconds: duration,
            receivedAtMs: Int64(now.timeIntervalSince1970 * 1_000)
        )
    }

    /// A marked `NODE_CMD` that came *back* rather than from here — a future host, or a
    /// re-synced history row. The engine and action are real; the payload holds the text.
    static func decode(command: PopopxNodeCmd, now: Date = Date()) -> PopopxNodeResultCard {
        PopopxNodeResultCard(
            id: "\(command.serviceId.rawValue).\(Int(now.timeIntervalSince1970 * 1_000)).\(command.action.hashValue)",
            serviceId: command.serviceId,
            status: .succeeded,
            headline: command.action,
            detail: command.payload,
            durationMilliseconds: nil,
            receivedAtMs: Int64(now.timeIntervalSince1970 * 1_000)
        )
    }
}

// MARK: - Pairing credential

/// The decoded, verified `PPXNODE1-…` offer.
///
/// `body` keeps the exact bytes the host signed. Re-encoding the JSON to check the fields
/// would break the signature on any formatting drift, which is the host's own rule
/// (`MacNodePopopxBridge.swift:604-607`) and is honoured here.
struct PopopxNodePairingOffer: Hashable, Sendable {
    let code: String
    let nodeId: String
    let publicKeyBase64URL: String
    let link: String
    let issuedAtMs: Int64
    let expiresAtMs: Int64
    let singleUse: Bool
    let schemaRevision: Int

    var isValid: Bool {
        !nodeId.isEmpty && !publicKeyBase64URL.isEmpty && !link.isEmpty
    }

    func isLive(at date: Date = Date()) -> Bool {
        let nowMs = Int64(date.timeIntervalSince1970 * 1_000)
        return nowMs >= issuedAtMs && nowMs < expiresAtMs
    }

    /// Parses and verifies. Every failure returns nil and says nothing: an expired or
    /// foreign QR must look the same to the caller as a QR that was never a node code, so
    /// that no scan result can be used to probe whether a machine here is paired.
    static func decode(_ candidate: String) -> PopopxNodePairingOffer? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = "\(PopopxNodeWire.pairingCodePrefix)-"
        guard trimmed.hasPrefix(marker) else { return nil }
        let tail = String(trimmed.dropFirst(marker.count))
        guard let dot = tail.firstIndex(of: ".") else { return nil }
        let bodyPart = String(tail[tail.startIndex..<dot])
        let signaturePart = String(tail[tail.index(after: dot)...])
        guard !signaturePart.isEmpty,
              let body = Data(popopxBase64URL: bodyPart), !body.isEmpty,
              let signature = Data(popopxBase64URL: signaturePart)
        else { return nil }
        guard let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let nodeId = fields["node"] as? String,
              let publicKey = fields["key"] as? String,
              let link = fields["link"] as? String,
              let issuedAt = fields["iat"] as? Int,
              let expiresAt = fields["exp"] as? Int
        else { return nil }
        guard verifySignature(signature: signature, body: body, publicKeyBase64URL: publicKey) else { return nil }
        let offer = PopopxNodePairingOffer(
            code: trimmed,
            nodeId: nodeId,
            publicKeyBase64URL: publicKey,
            link: link,
            issuedAtMs: Int64(issuedAt) * 1_000,
            expiresAtMs: Int64(expiresAt) * 1_000,
            singleUse: (fields["once"] as? Bool) ?? true,
            schemaRevision: (fields["v"] as? Int) ?? 0
        )
        return offer.isValid ? offer : nil
    }

    /// Ed25519 over the stored bytes — the host signs with `Curve25519.Signing`
    /// (`MacNodePopopxBridge.swift:573-580`), so this is the same primitive, not a mirror of
    /// this app's P256 commerce signatures.
    private static func verifySignature(signature: Data, body: Data, publicKeyBase64URL: String) -> Bool {
        guard let raw = Data(popopxBase64URL: publicKeyBase64URL), raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return false }
        return key.isValidSignature(signature, for: body)
    }

    /// The `popopx:/` one-time invitation the host minted with `/_connect 1`. Connecting it
    /// is what makes this device the contact the host is willing to listen to.
    var invitationLink: String { link }
}

// MARK: - Binding

/// This device's record of a bonded Mac node. Lives in the Keychain, not in a file:
/// the public key and the contact id together are enough to address a machine a user
/// keeps their briefings on.
struct PopopxMacNodeBinding: Codable, Hashable, Identifiable, Sendable {
    var nodeId: String
    var publicKeyBase64URL: String
    var deviceLabel: String
    /// The one-time invitation this device consumed, kept only so that a re-scan of the
    /// same QR can be recognised as the same node instead of a second one.
    var offerFingerprint: String
    var pairedAtMs: Int64
    var offerExpiresAtMs: Int64
    /// The chat this node answers on. nil until the user picks it, because nothing on this
    /// device can safely infer "which conversation did I just create" — guessing would put
    /// node commands into a stranger's chat, and a silently mis-delivered control signal is
    /// the one failure this module is not allowed to have.
    var contactId: Int64?
    var contactDisplayName: String?
    /// True once a command has gone out over `contactId`, so the plaza can say
    /// "connected" rather than "paired but never used".
    var handshakeConfirmed: Bool

    var id: String { nodeId }

    init(
        nodeId: String,
        publicKeyBase64URL: String,
        deviceLabel: String,
        offerFingerprint: String,
        pairedAtMs: Int64,
        offerExpiresAtMs: Int64,
        contactId: Int64? = nil,
        contactDisplayName: String? = nil,
        handshakeConfirmed: Bool = false
    ) {
        self.nodeId = nodeId
        self.publicKeyBase64URL = publicKeyBase64URL
        self.deviceLabel = deviceLabel
        self.offerFingerprint = offerFingerprint
        self.pairedAtMs = pairedAtMs
        self.offerExpiresAtMs = offerExpiresAtMs
        self.contactId = contactId
        self.contactDisplayName = contactDisplayName
        self.handshakeConfirmed = handshakeConfirmed
    }

    init(offer: PopopxNodePairingOffer, now: Date = Date()) {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        self.init(
            nodeId: offer.nodeId,
            publicKeyBase64URL: offer.publicKeyBase64URL,
            deviceLabel: "",
            offerFingerprint: PopopxMacNodeBinding.fingerprint(of: offer.code),
            pairedAtMs: nowMs,
            offerExpiresAtMs: offer.expiresAtMs
        )
    }

    var isBoundToChat: Bool { contactId != nil }

    /// A node is only worth addressing while its one-time offer is still the live one.
    /// Past it, the host has already retired the invitation and would ignore every command.
    var canAttemptHandshake: Bool {
        Int64(Date().timeIntervalSince1970 * 1_000) < offerExpiresAtMs
    }

    /// Short, stable, non-reversible: enough to notice a re-scan of the same QR, not enough
    /// to replay it. Same construction the commerce vault uses for card digests.
    static func fingerprint(of code: String) -> String {
        PopopxCommerceSignature.shortDigest(code)
    }
}

// MARK: - Copy

/// Every phrase this module draws. One place, because the English source text is itself the
/// catalogue key and a second spelling of one sentence is how a locale ends up with two rows.
enum DiscoverCopy {
    static let plazaTitle = NSLocalizedString("Discover", comment: "tab and plaza title")
    static let plazaSubtitle = NSLocalizedString("Local services that run on your own Mac", comment: "discover subtitle")

    static let searchPrompt = NSLocalizedString("Search services", comment: "discover search field")
    static let allFilter = NSLocalizedString("All", comment: "discover filter chip")
    static let noResultsTitle = NSLocalizedString("No service matches that search", comment: "discover empty search")
    static let noResultsHint = NSLocalizedString("Try a shorter word.", comment: "discover empty search hint")

    static let cyclePriceFormat = NSLocalizedString("%lld Compute Credits / 30 days", comment: "discover price chip")
    static let usageBasedPrice = NSLocalizedString("Metered, settled per job", comment: "discover price chip for the mesh node")
    static let cycleDays = 30

    static var cyclePriceSentence: String {
        NSLocalizedString("One cycle is 30 days. The price is charged in Compute Credits you already own.", comment: "discover billing note")
    }

    static let statusRunning = NSLocalizedString("Running", comment: "discover subscription badge")
    static let statusRunningAutoRenew = NSLocalizedString("Running · auto-renew", comment: "discover subscription badge")
    static let statusPaused = NSLocalizedString("Paused", comment: "discover subscription badge")
    static let statusExpiringSoon = NSLocalizedString("Expires today", comment: "discover subscription badge")
    static let statusNotSubscribed = NSLocalizedString("Not activated", comment: "discover subscription badge")
    static let statusNeedsBalance = NSLocalizedString("Waiting for credits", comment: "discover subscription badge")
    static let edgeBadge = NSLocalizedString("On-device", comment: "discover accelerator micro-badge")

    static func expiry(_ date: Date) -> String {
        String(format: NSLocalizedString("Valid until %@ at 00:00", comment: "discover expiry line"), Self.dateFormatter.string(from: date))
    }

    static func daysRemaining(_ days: Int) -> String {
        String(format: NSLocalizedString("%lld days left", comment: "discover countdown"), days)
    }

    static func renewIn(_ days: Int) -> String {
        String(format: NSLocalizedString("Renews in %lld days from your credit balance", comment: "discover renewal line"), days)
    }

    static let autoRenewTitle = NSLocalizedString("Renew automatically with Compute Credits", comment: "discover renewal switch")
    static let autoRenewExplanation = NSLocalizedString(
        "When a cycle has less than a day left, this device pays the next 30 days from the credits you already hold and extends the expiry. It never starts an App Store purchase on its own — a renewal that could not be paid simply stops, and your settings are kept.",
        comment: "discover renewal switch footnote"
    )
    static let insufficientBalanceNotice = NSLocalizedString(
        "Not enough Compute Credits for the next cycle. Top up to keep the service running.",
        comment: "discover renewal warning"
    )

    static func activate(_ credits: Int) -> String {
        String(format: NSLocalizedString("Activate now for %lld Compute Credits", comment: "discover primary action"), credits)
    }

    static let activateMetered = NSLocalizedString("Bond a Mac node to start", comment: "discover primary action, mesh node")
    static let goToTopUp = NSLocalizedString("Add Compute Credits", comment: "discover balance shortcut")
    static let activatedFormat = NSLocalizedString("%@ is active for 30 days", comment: "discover activation toast")
    static let deactivatedNotice = NSLocalizedString("Service stopped. Your history stays on this device.", comment: "discover stop toast")
    static let stopService = NSLocalizedString("Stop after this cycle", comment: "discover destructive action")
    static let confirmStop = NSLocalizedString("Stop renewing this service?", comment: "discover confirmation title")

    static let roomTitle = NSLocalizedString("Service room", comment: "discover service room")
    static let roomEmptyTitle = NSLocalizedString("Nothing has run yet", comment: "discover empty service room")
    static let roomEmptyHint = NSLocalizedString("Use a button below. Your Mac answers in this list.", comment: "discover empty service room hint")
    static let menuHeader = NSLocalizedString("Menu", comment: "discover service room menu header")
    static let sendFailed = NSLocalizedString("This Mac is not reachable right now", comment: "discover send failure")
    static let noNodeTitle = NSLocalizedString("No Mac node bonded", comment: "discover pairing banner, unbound")
    static let noNodeAction = NSLocalizedString("Bond a Mac", comment: "discover pairing banner button")
    static func nodeConnected(_ label: String) -> String {
        String(format: NSLocalizedString("%@ · local compute online", comment: "discover pairing banner"), label)
    }
    static let nodeIdle = NSLocalizedString("Bonded, not responding", comment: "discover pairing banner")

    static let pairingTitle = NSLocalizedString("Bond a Mac node", comment: "pairing sheet title")
    static let pairingIntro = NSLocalizedString(
        "Open the POPOPX Mac node, go to wizard step 2 and scan its QR code. The code is a one-time credential that expires in 15 minutes.",
        comment: "pairing sheet intro"
    )
    static let scanAction = NSLocalizedString("Scan the QR code", comment: "pairing scan button")
    static let pasteAction = NSLocalizedString("Paste the code", comment: "pairing paste button")
    static let bridgeSegment = NSLocalizedString("Linger / OpenClaw", comment: "pairing mode segment")
    static let officialSegment = NSLocalizedString("Mac node QR", comment: "pairing mode segment")
    static let pairingFailed = NSLocalizedString("That code is not a current Mac node credential", comment: "pairing rejection")
    static let pairingSucceededFormat = NSLocalizedString("Bonded to %@", comment: "pairing success toast")
    static let chooseChatTitle = NSLocalizedString("Which conversation is this Mac?", comment: "pairing chat picker")
    static let chooseChatHint = NSLocalizedString(
        "Pick the chat you just opened with the node. Control signals are sent only there.",
        comment: "pairing chat picker footnote"
    )
    static let skipPicker = NSLocalizedString("Do it later", comment: "pairing picker skip")
    static let unbond = NSLocalizedString("Remove this Mac", comment: "pairing remove action")
    static let confirmUnbond = NSLocalizedString("Forget this Mac node on this device?", comment: "pairing removal title")
    static let unbondNotice = NSLocalizedString("The node keeps its own history; only this device forgets it.", comment: "pairing removal footnote")
    static let cameraDenied = NSLocalizedString("Camera access is off, so the code cannot be scanned. Paste it instead.", comment: "pairing camera denial")

    static let bridgeTitle = NSLocalizedString("Local console bridge", comment: "bridge guide title")
    static let bridgeIntro = NSLocalizedString(
        "For a keyboard-driven host such as Linger or OpenClaw: talk to the node's own console over loopback instead of over the chat.",
        comment: "bridge guide intro"
    )
    static let bridgeAddressLabel = NSLocalizedString("Address", comment: "bridge field label")
    static let bridgeTokenLabel = NSLocalizedString("Token header", comment: "bridge field label")
    static let bridgeTokenHint = NSLocalizedString(
        "The console prints a fresh token on every start and accepts it either as the X-PPX-Token header or as the t query item. A token is never written into this app.",
        comment: "bridge guide explanation"
    )
    static let bridgeSecretHint = NSLocalizedString(
        "Bridge plugins that also relay messages need PPX_BRIDGE_SECRET of at least 16 characters, and a relay that is allowed to lock devices keeps that secret on the Mac.",
        comment: "bridge guide explanation"
    )
    static let copyAddress = NSLocalizedString("Copy address", comment: "bridge copy button")
    static let copiedNotice = NSLocalizedString("Copied", comment: "copy toast")

    static let highlightRunsOnYourMachine = NSLocalizedString("Runs on your own Mac", comment: "discover feature highlight")
    static let highlightNeverUploadsNotes = NSLocalizedString("Reads only the folders you authorise", comment: "discover feature highlight")
    static let highlightWorksOffline = NSLocalizedString("Works with no account", comment: "discover feature highlight")
    static let highlightBlindWatermark = NSLocalizedString("Blind watermark per copy", comment: "discover feature highlight")
    static let highlightStripsMetadata = NSLocalizedString("Removes camera fingerprints", comment: "discover feature highlight")
    static let highlightUnattendedQueue = NSLocalizedString("Queues overnight, reports in the morning", comment: "discover feature highlight")
    static let highlightYouSetTheThreshold = NSLocalizedString("You set the price per member", comment: "discover feature highlight")
    static let highlightMeteredSettlement = NSLocalizedString("Settled per job, 10% protocol fee", comment: "discover feature highlight")
    static let highlightYouKeepYourCycles = NSLocalizedString("Your machine decides what to lend", comment: "discover feature highlight")
    static let highlightNoTracking = NSLocalizedString("No recommendation feed", comment: "discover feature highlight")
    static let highlightScheduledLocally = NSLocalizedString("Fires on your own clock", comment: "discover feature highlight")
    static let highlightDeterministic = NSLocalizedString("No model in the path", comment: "discover feature highlight")
    static let highlightNoModelInPath = NSLocalizedString("One tap, one state machine", comment: "discover feature highlight")
    static let highlightEncryptedAtRest = NSLocalizedString("Encrypted at rest on your Mac", comment: "discover feature highlight")
    static let highlightTimeLocked = NSLocalizedString("Opens only after the date you set", comment: "discover feature highlight")
    static let highlightReportsStayLocal = NSLocalizedString("Reports are parsed offline", comment: "discover feature highlight")

    static let serviceSectionFooter = NSLocalizedString(
        "Activation moves nothing off this device. The service runs on the Mac you bond, and Compute Credits are the only thing that leaves the ledger.",
        comment: "discover section footer"
    )

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
