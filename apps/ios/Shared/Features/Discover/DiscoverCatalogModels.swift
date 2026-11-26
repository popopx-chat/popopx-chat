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
/// Only for `PopopxCactusBridge`, declared in `POPOPXChat/objc.h`. It is named even while the engine is
/// dormant, and every call is behind `popopxCactusEngineAllowed`, so the symbol is never reached — which is
/// also why `libcactus.a` need not be linked for the build to pass.
import POPOPXChat

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

// MARK: - Copilot

// The iOS twin of `apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/copilot/`.
//
// That package is Kotlin Multiplatform common code and this app does not compile it, so parity here is
// parity of *behaviour*: the same five tools, the same grammar in English and Chinese, the same
// Hinnant civil-date arithmetic, the same confirm-then-write gate and the same `.ics` writer. Reading
// the two side by side is meant to be a line-at-a-time exercise, which is why the type names are kept
// identical to the Kotlin ones rather than re-spelled for Swift taste.
//
// It lives in this file for three reasons, and they are all load-bearing:
//
// * `node.dispatch_task` is validated against `PopopxNodeServiceId.menuActions` and sized by
//   `PopopxNodeWire.isAccepted`, both of which are declared above. Anywhere else and the dispatcher
//   would have to reach across a file boundary to re-derive a wire rule this file already owns.
// * The bundled weights are verified with `CryptoKit`, which this file already imports.
// * The file is in the `POPOPX (iOS)` target, so it compiles today; a new file would not, because the
//   target's source list is explicit.
//
// Two deliberate departures from the Kotlin, both noted again at the code:
//
// * `NSRegularExpression` (ICU) instead of `kotlin.text.Regex` (java.util.regex). Every pattern string in
//   this file is one of the `Regex`es in `PopopxDeterministicEngine.kt` character for character, with the
//   exception of two iOS-only input-validation anchors in `popopxEcoNormalizeDateTime`; measured by
//   extracting both sets, not asserted. What the two engines do disagree about is `\b` beside a Han glyph:
//   java.util.regex counts CJK as non-word, ICU counts it as word. Nothing in either copy depends on that —
//   the Chinese verb alternatives sit outside `\b` on purpose (`PopopxDeterministicEngine.kt:205-213`), and
//   the three day-word patterns that do carry a boundary are ORed with a plain `contains` on both platforms
//   (`:248-250` there, `1550-1552` here), so the boundary is decoration on both sides.
// * The `.ics` folder counts UTF-8 octets, not characters. RFC 5545 folds at 75 *octets*, and an
//   assistant whose input language is Chinese puts non-ASCII in `SUMMARY` on every turn. Kotlin's
//   "ASCII in practice" note holds for its own tests and would emit an invalid line here.

// ---------------------------------------------------------------- Date arithmetic

/// Days from the start of its era to the first day of the March-based era year `yearOfEra`.
///
/// Both conversions below read this one function, so the pair cannot drift apart; the drift is what made
/// every 29 February come back as day 0 of March. Mirrors `PopopxDeterministicEngine.kt:37`.
private func popopxEcoEraYearStart(_ yearOfEra: Int64) -> Int64 { 365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100 }

/// Howard Hinnant's civil-days algorithm, and the reason this feature has no timezone, no `Calendar`
/// and no locale to disagree about. Copied digit-for-digit from `PopopxDeterministicEngine.kt:40-47`.
///
/// Swift's `/` and `%` on `Int64` truncate toward zero and take the sign of the dividend, which is
/// exactly Kotlin's `Long` behaviour, so the port needs no change of operators.
func popopxEcoDaysFromCivil(year y0: Int, month m: Int, day d: Int) -> Int64 {
    var y = Int64(y0)
    if m <= 2 { y -= 1 }
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = Int64((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1)
    return era * 146097 + popopxEcoEraYearStart(yearOfEra) + dayOfYear - 719468
}

/// The inverse of `popopxEcoDaysFromCivil`. `PopopxDeterministicEngine.kt:49-73`.
func popopxEcoCivilFromDays(_ z: Int64) -> (year: Int, month: Int, day: Int) {
    let z0 = z + 719468
    let era = (z0 >= 0 ? z0 : z0 - 146096) / 146097
    let dayOfEra = z0 - era * 146097
    // The era year is searched, not divided out. Hinnant's closed form `(doe - doe/1461 + doe/36524 -
    // doe/146096) / 365` returns 400 for every 29 February, because a March-based year that contains a
    // leap day runs to day 365 while the next era year already starts there; dayOfYear then goes negative
    // and the caller is handed day 0 of March. `dayOfEra / 365` is an upper bound, the clamp holds it
    // inside the era, and each loop moves at most one step.
    var yearOfEra = min(Int64(399), dayOfEra / 365)
    while popopxEcoEraYearStart(yearOfEra) > dayOfEra { yearOfEra -= 1 }
    while yearOfEra < 399 && popopxEcoEraYearStart(yearOfEra + 1) <= dayOfEra { yearOfEra += 1 }
    let y = yearOfEra + era * 400
    let dayOfYear = dayOfEra - popopxEcoEraYearStart(yearOfEra)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let d = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let m = shiftedMonth + (shiftedMonth < 10 ? 3 : -9)
    // The era year is counted from March, so January and February belong to the year that has not finished
    // yet. Without this, every date before March 1 returns the previous year, and a wrong year is a wrong
    // weekday for 「避开周末」.
    let year = y + (m <= 2 ? 1 : 0)
    return (Int(year), Int(m), Int(d))
}

/// Euclidean division — Kotlin's `floorDiv`. `Int64./` truncates, which differs below zero, and the
/// window math reaches below zero for any date before 1970.
func popopxEcoFloorDiv(_ value: Int64, _ modulus: Int64) -> Int64 {
    let q = value / modulus
    return value % modulus != 0 && (value < 0) != (modulus < 0) ? q - 1 : q
}

/// Euclidean remainder — Kotlin's `Int.mod`/`Long.mod`, always in `0..<|modulus|`.
func popopxEcoFloorMod(_ value: Int64, _ modulus: Int64) -> Int64 {
    let r = value % modulus
    return r != 0 && (r < 0) != (modulus < 0) ? r + modulus : r
}

/// The zero padding the ISO forms need. `PopopxDeterministicEngine.kt:411-413`.
func popopxEcoPad2(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
func popopxEcoPad4(_ value: Int) -> String { String(repeating: "0", count: max(0, 4 - String(value).count)) + "\(value)" }

/// Minutes in a day. `PopopxDeterministicEngine.kt:415`.
let popopxEcoMinutesPerDay: Int64 = 1_440

/// A proleptic Gregorian date kept as three integers — `EcoDate`.
struct PopopxEcoDate: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    var ordinal: Int64 { popopxEcoDaysFromCivil(year: year, month: month, day: day) }

    func plusDays(_ days: Int64) -> PopopxEcoDate {
        let parts = popopxEcoCivilFromDays(ordinal + days)
        return PopopxEcoDate(year: parts.year, month: parts.month, day: parts.day)
    }

    /// ISO 8601 day of the week, 1 is Monday. `PopopxDeterministicEngine.kt:16`, kept as written so all three platforms
    /// land on the same integer for the same epoch day.
    var dayOfWeek: Int { Int(popopxEcoFloorMod(ordinal + 3, 7)) + 1 }

    func iso() -> String { "\(popopxEcoPad4(year))-\(popopxEcoPad2(month))-\(popopxEcoPad2(day))" }

    static func fromEpochDays(_ days: Int64) -> PopopxEcoDate {
        let parts = popopxEcoCivilFromDays(days)
        return PopopxEcoDate(year: parts.year, month: parts.month, day: parts.day)
    }

    static func parse(_ text: String) -> PopopxEcoDate? {
        let groups = PopopxEcoPattern(#"^(\d{4})-(\d{2})-(\d{2})$"#)
            .firstGroups(in: text.trimmingCharacters(in: .whitespaces))
        guard let groups, let y = Int(groups[1]), let m = Int(groups[2]), let d = Int(groups[3]) else { return nil }
        let date = PopopxEcoDate(year: y, month: m, day: d)
        guard (1...12).contains(date.month), (1...Self.daysInMonth(year: date.year, month: date.month)).contains(date.day)
        else { return nil }
        return date
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        }
    }

    static func < (lhs: PopopxEcoDate, rhs: PopopxEcoDate) -> Bool { lhs.ordinal < rhs.ordinal }
}

/// A wall-clock instant with no offset — `EcoDateTime`. `PopopxDeterministicEngine.kt:84-107`.
struct PopopxEcoDateTime: Hashable, Sendable {
    let date: PopopxEcoDate
    let minuteOfDay: Int

    var epochMinutes: Int64 { date.ordinal * popopxEcoMinutesPerDay + Int64(minuteOfDay) }

    func isoLocal() -> String {
        "\(date.iso())T\(popopxEcoPad2(Int(popopxEcoFloorDiv(Int64(minuteOfDay), 60)))):\(popopxEcoPad2(Int(popopxEcoFloorMod(Int64(minuteOfDay), 60))))"
    }

    func plusMinutes(_ minutes: Int) -> PopopxEcoDateTime {
        let total = Int64(minuteOfDay + minutes)
        return PopopxEcoDateTime(
            date: date.plusDays(popopxEcoFloorDiv(total, popopxEcoMinutesPerDay)),
            minuteOfDay: Int(popopxEcoFloorMod(total, popopxEcoMinutesPerDay))
        )
    }

    static func fromEpochMinutes(_ minutes: Int64) -> PopopxEcoDateTime {
        PopopxEcoDateTime(
            date: PopopxEcoDate.fromEpochDays(popopxEcoFloorDiv(minutes, popopxEcoMinutesPerDay)),
            minuteOfDay: Int(popopxEcoFloorMod(minutes, popopxEcoMinutesPerDay))
        )
    }

    static func parse(_ text: String) -> PopopxEcoDateTime? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let groups = PopopxEcoPattern(#"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$"#).firstGroups(in: trimmed),
              let date = PopopxEcoDate.parse("\(groups[1])-\(groups[2])-\(groups[3])"),
              let hour = Int(groups[4]), let minute = Int(groups[5]),
              hour <= 23, minute <= 59
        else { return nil }
        return PopopxEcoDateTime(date: date, minuteOfDay: hour * 60 + minute)
    }
}

/// What the engine is told before it resolves a time — `PopopxEcoFacts`. The device clock is *read*
/// here and nowhere else: every subsequent step is integer arithmetic, so no `Calendar` participates
/// in deciding what "next Thursday at 4" means.
///
/// The local day comes from the epoch seconds plus `TimeZone`'s offset for this instant (DST-aware) and
/// then through Hinnant's `civilFromDays`, rather than from `Calendar.current`. Same answer, one fewer
/// component that can disagree with the Android build.
struct PopopxEcoFacts {
    var today: PopopxEcoDate
    var defaultEventMinutes: Int = 60
    var defaultWindowHours: Int = 24
    var clockMinutes: Int = 9 * 60

    var now: PopopxEcoDateTime { PopopxEcoDateTime(date: today, minuteOfDay: clockMinutes) }

    /// `PopopxDeterministicEngine.kt:123-124` — a clock past midnight rolls onto the next day.
    func at(_ minutesPastMidnight: Int, day: PopopxEcoDate? = nil) -> PopopxEcoDateTime {
        let base = day ?? today
        return minutesPastMidnight < 24 * 60
            ? PopopxEcoDateTime(date: base, minuteOfDay: minutesPastMidnight)
            : PopopxEcoDateTime(date: base.plusDays(1), minuteOfDay: minutesPastMidnight - 24 * 60)
    }

    /// Kotlin's `PopopxEcoFacts.now()` companion — read on every turn, never captured, so a long-lived
    /// assistant answers "tomorrow at 3" correctly the next morning.
    static func now() -> PopopxEcoFacts { PopopxEcoFacts(today: popopxEcoToday(), clockMinutes: popopxEcoNowMinutesPastMidnight()) }
}

/// `expect fun popopxToday(): EcoDate`, actualised for iOS.
func popopxEcoToday() -> PopopxEcoDate {
    PopopxEcoDate.fromEpochDays(popopxEcoFloorDiv(popopxEcoLocalEpochSeconds(), 86_400))
}

/// `expect fun popopxNowMinutesPastMidnight(): Int`, actualised for iOS.
func popopxEcoNowMinutesPastMidnight() -> Int {
    Int(popopxEcoFloorMod(popopxEcoLocalEpochSeconds(), 86_400) / 60)
}

private func popopxEcoLocalEpochSeconds() -> Int64 {
    let instant = Date()
    return Int64(instant.timeIntervalSince1970) + Int64(TimeZone.current.secondsFromGMT(for: instant))
}

// ---------------------------------------------------------------- Grammar

/// One compiled pattern, so the grammar reads as the grammar and not as `range(of:)` plumbing.
/// ICU counts UTF-8 here, which is why the Chinese alternatives below are worth writing out.
struct PopopxEcoPattern {
    private let expression: NSRegularExpression?

    init(_ pattern: String, ignoreCase: Bool = false) {
        expression = try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    func matches(in text: String) -> Bool {
        guard let expression else { return false }
        return expression.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Index 0 is the whole match, 1.. are the capture groups, `""` where a group did not participate.
    func firstGroups(in text: String) -> [String]? {
        guard let expression,
              let match = expression.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let bounds = Range(range, in: text) else { return "" }
            return String(text[bounds])
        }
    }

    func matches(in text: String, at position: Int) -> (value: String, range: NSRange)? {
        guard let expression else { return nil }
        guard let match = expression.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)).dropFirst(position).first,
              let bounds = Range(match.range, in: text)
        else { return nil }
        return (String(text[bounds]), match.range)
    }

    func replaceAll(_ template: String, in text: String) -> String {
        guard let expression else { return text }
        return expression.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Slash commands — `PopopxEcoCommand`. The unambiguous half of the summon path.
enum PopopxEcoCommand: String, CaseIterable, Sendable {
    case checkAvailability = "/查空闲"
    case bookTime = "/约时间"
    case moveTime = "/改时间"
    case cancelTime = "/取消日程"
    case summarizeFile = "/总结文件"

    var literal: String { rawValue }

    static func parse(_ text: String) -> PopopxEcoCommand? { allCases.first { text.contains($0.literal) } }

    /// `@助理` is the summon, not a command: it authorizes a turn without choosing the tool.
    static func isSummon(_ text: String) -> Bool {
        text.contains("@助理") || text.lowercased().contains("@assistant")
    }
}

// ---------------------------------------------------------------- Tool contract

/// The five things the on-device assistant is allowed to ask for — `PopopxEcoTool`. The raw values are
/// the wire contract with the bundled engine's `tools_json`, spelled exactly as the schema declares
/// them, so the shipped tools and the parser cannot drift apart. `PopopxEcoToolCall.kt:18-28`.
enum PopopxEcoTool: String, CaseIterable, Sendable {
    case getAvailability = "calendar.get_availability"
    case proposeCreate = "calendar.propose_create"
    case proposeReschedule = "calendar.propose_reschedule"
    case proposeCancel = "calendar.propose_cancel"
    case dispatchTask = "node.dispatch_task"

    static func fromWireName(_ name: String) -> PopopxEcoTool? { allCases.first { $0.rawValue == name } }

    /// Copied from `PopopxEcoToolCall.kt:190-197`. Not localized: it is the prompt the weights read.
    var schemaDescription: String {
        switch self {
        case .getAvailability: "Check when the user is free. Use for questions about availability or a proposed time. Never creates or changes an event."
        case .proposeCreate: "Book a NEW event that does not exist yet. Use only when the user asks to add, schedule or set up something new."
        case .proposeReschedule: "MOVE an event that already exists to a different time. Use when the user says move, push, shift or postpone. The event is not cancelled and not new."
        case .proposeCancel: "Delete an event that already exists. Use when the user says cancel, drop or call off."
        case .dispatchTask: "Hand a heavy job such as summarising a document to the user's paired Mac computer. Use only when a file or document is named."
        }
    }

    /// Property order is the order the emitted JSON shows, which is the order `tools.json` was written
    /// in by hand — kept so a diff against the bundled file is a real diff.
    var schema: PopopxEcoObjectSchema {
        switch self {
        case .getAvailability:
            PopopxEcoObjectSchema(
                properties: [
                    PopopxEcoParamSpec(name: "from", description: "window start, ISO 8601"),
                    PopopxEcoParamSpec(name: "to", description: "window end, ISO 8601"),
                ],
                required: ["from", "to"]
            )
        case .proposeCreate:
            PopopxEcoObjectSchema(
                properties: [
                    PopopxEcoParamSpec(name: "title", description: "short name for the event, in the user's words"),
                    PopopxEcoParamSpec(name: "start", description: "ISO 8601 local date-time"),
                    PopopxEcoParamSpec(name: "end", description: "ISO 8601 local date-time"),
                ],
                required: ["start", "end"]
            )
        case .proposeReschedule:
            PopopxEcoObjectSchema(
                properties: [
                    PopopxEcoParamSpec(name: "event_ref", description: "words identifying the existing event"),
                    PopopxEcoParamSpec(name: "new_start", description: "ISO 8601 local date-time"),
                ],
                required: ["event_ref", "new_start"]
            )
        case .proposeCancel:
            PopopxEcoObjectSchema(
                properties: [PopopxEcoParamSpec(name: "event_ref", description: "words identifying the existing event")],
                required: ["event_ref"]
            )
        case .dispatchTask:
            PopopxEcoObjectSchema(
                properties: [
                    PopopxEcoParamSpec(name: "task", description: "what to do, for example summarize"),
                    PopopxEcoParamSpec(name: "payload_ref", description: "the file or document named in the request"),
                ],
                required: ["task"]
            )
        }
    }
}

/// One parameter of a tool schema — the shape `stringProperty` produces in Kotlin.
struct PopopxEcoParamSpec {
    let name: String
    let description: String
}

/// A tool's `parameters` object.
struct PopopxEcoObjectSchema {
    let properties: [PopopxEcoParamSpec]
    let required: [String]
}

/// A JSON string literal, escaped the way the schema needs. Only `\`, `"`, control characters and
/// nothing else reach here — the schema text is ASCII, and a `U+2028` surprise in a prompt is not
/// worth a second escaper.
func popopxEcoJSONString(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
            else { out.unicodeScalars.append(scalar) }
        }
    }
    return out + "\""
}

/// The schema the engine is given at load — `popopxEcoToolsJson()`, `PopopxEcoToolCall.kt:178-188`.
func popopxEcoToolsJson() -> String {
    let tools = PopopxEcoTool.allCases.map { tool -> String in
        let properties = tool.schema.properties
            .map { "\(popopxEcoJSONString($0.name)): {\"type\": \"string\", \"description\": \(popopxEcoJSONString($0.description))}" }
            .joined(separator: ", ")
        let required = tool.schema.required.map { popopxEcoJSONString($0) }.joined(separator: ", ")
        return """
        {"name": \(popopxEcoJSONString(tool.rawValue)), "description": \(popopxEcoJSONString(tool.schemaDescription)), "parameters": {"type": "object", "properties": {\(properties)}, "required": [\(required)]}}
        """
    }
    return "[\(tools.joined(separator: ",\n"))]"
}

/// A tool call the engine or the deterministic extractor produced — the `PopopxEcoCall` sealed
/// interface. One case per Kotlin data class, with the same fields in the same order.
enum PopopxEcoCall: Hashable, Sendable {
    /// A window whose free time the user wants to know; both bounds are local, no timezone inferred.
    case getAvailability(from: String, to: String)
    /// A proposal, never a write. `start`/`end` are local date-times, `title` is the user's own words.
    case proposeCreate(title: String?, start: String, end: String?)
    case proposeReschedule(eventRef: String, newStart: String)
    case proposeCancel(eventRef: String)
    /// A heavy job for the paired Mac Node. `payloadRef` is a file *name*, never file contents.
    case dispatchTask(task: String, payloadRef: String?, priority: Int?)

    var tool: PopopxEcoTool {
        switch self {
        case .getAvailability: .getAvailability
        case .proposeCreate: .proposeCreate
        case .proposeReschedule: .proposeReschedule
        case .proposeCancel: .proposeCancel
        case .dispatchTask: .dispatchTask
        }
    }

    /// `PopopxEcoCall.argumentString` — the trimmed, non-empty argument, or nil. Reading it off the
    /// case's own fields keeps a second copy of the payload out of existence.
    func argumentString(_ key: String) -> String? {
        let raw: String?
        switch self {
        case let .getAvailability(from, to): raw = key == "from" ? from : key == "to" ? to : nil
        case let .proposeCreate(title, start, end): raw = key == "title" ? title : key == "start" ? start : key == "end" ? end : nil
        case let .proposeReschedule(eventRef, newStart): raw = key == "event_ref" ? eventRef : key == "new_start" ? newStart : nil
        case let .proposeCancel(eventRef): raw = key == "event_ref" ? eventRef : nil
        case let .dispatchTask(task, payloadRef, priority):
            raw = key == "task" ? task : key == "payload_ref" ? payloadRef : key == "priority" ? priority.map { "\($0)" } : nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func argumentInt(_ key: String) -> Int? { argumentString(key).flatMap { Int($0) } }

    /// The booked length, from the pair of times if the engine gave both — `EcoProposeCreate.durationMinutes`.
    func durationMinutes(fallback: Int = popopxEcoDefaultEventMinutes) -> Int {
        guard case let .proposeCreate(_, start, end) = self,
              let from = PopopxEcoDateTime.parse(start),
              let to = end.flatMap({ PopopxEcoDateTime.parse($0) })
        else { return fallback }
        return Int(max(1, to.epochMinutes - from.epochMinutes))
    }

    /// `EcoProposeCreate.normalized` — the only place the gap between "the engine said 16:00" and
    /// "the card needs a date-time" is closed.
    func normalizedCreate(facts: PopopxEcoFacts, fallbackDurationMinutes: Int = popopxEcoDefaultEventMinutes) -> PopopxEcoCall {
        guard case let .proposeCreate(title, start, end) = self else { return self }
        let resolvedStart = popopxEcoWithDateOf(start, date: facts.today) ?? popopxEcoNormalizeDateTime(start) ?? start
        let resolvedEnd = end.flatMap { popopxEcoWithDateOf($0, date: facts.today) } ?? popopxEcoDefaultEnd(resolvedStart, minutes: fallbackDurationMinutes)
        return .proposeCreate(title: title, start: resolvedStart, end: resolvedEnd)
    }

    /// `EcoProposeReschedule.normalized` — nil when the value is not a time at all, so the planner
    /// refuses rather than guessing a day.
    func normalizedReschedule(facts: PopopxEcoFacts) -> PopopxEcoCall? {
        guard case let .proposeReschedule(eventRef, newStart) = self,
              let start = popopxEcoWithDateOf(newStart, date: facts.today) ?? popopxEcoNormalizeDateTime(newStart)
        else { return nil }
        return .proposeReschedule(eventRef: eventRef, newStart: start)
    }

    /// `EcoDispatchTask.service` — the token is parsed against the paired service's accepted actions
    /// rather than forwarded as free text.
    var dispatchService: PopopxNodeServiceId? {
        guard case let .dispatchTask(task, _, _) = self else { return nil }
        let head = String(task.split(separator: ".", omittingEmptySubsequences: false).dropLast().joined(separator: "."))
        guard !head.isEmpty else { return nil }
        return PopopxNodeServiceId(rawValue: head)
    }

    /// `EcoDispatchTask.action` — and only when the token actually carries one.
    var dispatchAction: String? {
        guard case let .dispatchTask(task, _, _) = self, task.contains(".") else { return nil }
        let tail = String(task.split(separator: ".", omittingEmptySubsequences: false).dropFirst().joined(separator: "."))
        return tail.isEmpty ? nil : tail
    }
}

/// A proposal with no end time is booked for this long — `DEFAULT_EVENT_MINUTES`.
let popopxEcoDefaultEventMinutes = 60

/// Accepts what the engine actually emits for a time and returns a local date-time, or nil when the
/// value is not a time at all. `PopopxEcoToolCall.kt:253-258`. The engine writes
/// `2026-11-27T15:00:00`, sometimes `16:00`, and occasionally a date with no time; only the first two
/// are resolved here, because inventing a time is how a wrong event gets booked.
func popopxEcoNormalizeDateTime(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if PopopxEcoPattern(#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$"#).matches(in: trimmed) {
        return String(trimmed.prefix(16))
    }
    if PopopxEcoPattern(#"^\d{1,2}:\d{2}$"#).matches(in: trimmed) {
        return String(repeating: "0", count: max(0, 5 - trimmed.count)) + trimmed
    }
    return nil
}

/// The end of a proposal whose engine reply gave no end time — `PopopxEcoToolCall.kt:264-269`. A bare
/// `16:00` stays bare, because the day is not known here either; a full date-time gets the default
/// duration added with real civil-date rollover.
func popopxEcoDefaultEnd(_ text: String, minutes: Int) -> String? {
    guard let normalized = popopxEcoNormalizeDateTime(text), normalized.count != 5,
          let instant = PopopxEcoDateTime.parse(normalized)
    else { return nil }
    return instant.plusMinutes(minutes).isoLocal()
}

/// Widens `HH:mm` into a full local date-time when the date was resolved — `PopopxEcoToolCall.kt:275-278`.
func popopxEcoWithDateOf(_ text: String, date: PopopxEcoDate) -> String? {
    guard let normalized = popopxEcoNormalizeDateTime(text) else { return nil }
    return normalized.count == 5 ? "\(date.iso())T\(normalized)" : normalized
}

/// What the engine said about one turn — `PopopxEcoEnvelope`. `suppressed` is not an error: the engine
/// withholds a call it is not confident about and puts it here, which is the same shape as the
/// confirm-first rule this feature runs on.
struct PopopxEcoEnvelope {
    var calls: [PopopxEcoCall]
    var suppressed: [PopopxEcoCall]
    var confidence: Double?
    var reasoning: String?
    var failure: String? = nil

    var isEmpty: Bool { calls.isEmpty && suppressed.isEmpty }

    /// The calls worth showing a card for: emitted first, then withheld, deduplicated by tool name.
    func suggestions() -> [PopopxEcoCall] {
        var seen = Set<PopopxEcoTool>()
        return (calls + suppressed).filter { seen.insert($0.tool).inserted }
    }

    static let empty = PopopxEcoEnvelope(calls: [], suppressed: [], confidence: nil, reasoning: nil)

    /// Parses the engine's own JSON — `PopopxEcoEnvelope.fromEngineJson`. Unknown tool names and
    /// unreadable arguments are dropped rather than guessed at, so a malformed model reply can never
    /// widen the set of things the app will do.
    static func fromEngineJson(_ json: String) -> PopopxEcoEnvelope {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return PopopxEcoEnvelope(calls: [], suppressed: [], confidence: nil, reasoning: nil, failure: "unparseable engine reply")
        }
        return PopopxEcoEnvelope(
            calls: parseCalls(root["function_calls"]),
            suppressed: parseCalls(root["suppressed_calls"]),
            confidence: (root["confidence"] as? NSNumber)?.doubleValue,
            reasoning: root["reasoning"] as? String,
            failure: root["error"] as? String
        )
    }

    private static func parseCalls(_ element: Any?) -> [PopopxEcoCall] {
        guard let entries = element as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String, let tool = PopopxEcoTool.fromWireName(name),
                  let args = entry["arguments"] as? [String: Any]
            else { return nil }
            switch tool {
            case .getAvailability:
                guard let from = popopxEcoArgString(args["from"]), let to = popopxEcoArgString(args["to"]) else { return nil }
                return .getAvailability(from: from, to: to)
            case .proposeCreate:
                guard let start = popopxEcoArgString(args["start"]) else { return nil }
                return .proposeCreate(title: popopxEcoArgString(args["title"]), start: start, end: popopxEcoArgString(args["end"]))
            case .proposeReschedule:
                guard let ref = popopxEcoArgString(args["event_ref"]), let start = popopxEcoArgString(args["new_start"]) else { return nil }
                return .proposeReschedule(eventRef: ref, newStart: start)
            case .proposeCancel:
                guard let ref = popopxEcoArgString(args["event_ref"]) else { return nil }
                return .proposeCancel(eventRef: ref)
            case .dispatchTask:
                guard let task = popopxEcoArgString(args["task"]) else { return nil }
                return .dispatchTask(task: task, payloadRef: popopxEcoArgString(args["payload_ref"]), priority: popopxEcoArgInt(args["priority"]))
            }
        }
    }
}

/// A JSON argument read the way `JsonObject.stringOrNull` reads one: trimmed, non-empty, and a literal
/// `null` is absence rather than the four-letter word.
private func popopxEcoArgString(_ value: Any?) -> String? {
    guard let text = value as? String else {
        if let number = value as? NSNumber { return number.stringValue.isEmpty ? nil : number.stringValue }
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == "null" ? nil : trimmed
}

private func popopxEcoArgInt(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    return (value as? String).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

// ---------------------------------------------------------------- The engine

/// Everything one platform can do with the messages it is allowed to read — `PopopxEdgeCopilotEngine`.
/// The on-device engine and the deterministic one implement the same shape so the UI never has to know
/// which answered.
/// Which of the two engines answered. `PopopxEdgeCopilotEngine.Kind` would be the natural spelling, but
/// Swift does not allow a nested type in a protocol, so it lives beside it.
enum PopopxEcoEngineKind { case needle, deterministic }

protocol PopopxEdgeCopilotEngine: AnyObject {
    var kind: PopopxEcoEngineKind { get }

    /// Loads weights or warms tables. Called only on an explicit summon, and `release` must undo it.
    func ensureLoaded() -> Bool
    func release()

    var isLoaded: Bool { get }

    func parse(input: String, facts: PopopxEcoFacts) -> PopopxEcoEnvelope
}

/// The engine that ships in this branch: a deterministic extractor over a bounded grammar —
/// `PopopxDeterministicEngine`.
///
/// It is deliberately narrow. A turn that does not clearly ask for one of the five tools returns an
/// empty envelope, because a wrong calendar proposal costs the user more than a missed one. English is
/// matched on word boundaries; Chinese on the particles 点/号/周 and the verb pairs below. Other locales
/// fall through to an empty envelope rather than being guessed at from Latin keywords.
///
/// **This is the live engine.** The Cactus-backed `needle` engine below it is dormant by construction,
/// and the reason is a measurement, not a preference:
///
/// > The published base weights route **1 of 6** calendar intents correctly on this host and produce no
/// > usable Chinese output. Three of the five tools are never selected at all, and the free-text
/// > replies are English regardless of the input language. Fine-tuning is a separate project; until it
/// > exists, shipping the model as the answering engine would replace a grammar that works with one
/// > that does not.
final class PopopxDeterministicEngine: PopopxEdgeCopilotEngine {
    let kind: PopopxEcoEngineKind = .deterministic
    private(set) var isLoaded = true

    func ensureLoaded() -> Bool { true }
    func release() { isLoaded = true }

    func parse(input: String, facts: PopopxEcoFacts) -> PopopxEcoEnvelope {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        let lowered = text.lowercased()

        if let command = PopopxEcoCommand.parse(text) {
            let resolved = Self.resolveTime(text, facts)
            switch command {
            case .checkAvailability:
                guard let resolved else { return emptyWithReason("no window") }
                return call(.getAvailability(from: resolved.start.isoLocal(), to: resolved.end.isoLocal()), facts: facts)
            case .bookTime:
                guard let resolved else { return emptyWithReason("no time") }
                return call(
                    PopopxEcoCall.proposeCreate(title: Self.titleOf(text), start: resolved.start.isoLocal(), end: resolved.end.isoLocal())
                        .normalizedCreate(facts: facts, fallbackDurationMinutes: facts.defaultEventMinutes),
                    facts: facts
                )
            case .moveTime:
                guard let resolved else { return emptyWithReason("no time") }
                return call(.proposeReschedule(eventRef: Self.refOf(text), newStart: resolved.start.isoLocal()), facts: facts)
            case .cancelTime:
                let reference = Self.refOf(text)
                guard !reference.isEmpty else { return emptyWithReason("no event") }
                return call(.proposeCancel(eventRef: reference), facts: facts)
            case .summarizeFile:
                guard let file = Self.fileRefOf(text) else { return emptyWithReason("no file") }
                return call(.dispatchTask(task: "summarize", payloadRef: file, priority: nil), facts: facts)
            }
        }

        let when = Self.resolveTime(text, facts)
        if Self.cancel.matches(in: lowered), !Self.refOf(text).isEmpty {
            return call(.proposeCancel(eventRef: Self.refOf(text)), facts: facts)
        }
        if Self.reschedule.matches(in: lowered), let when {
            return call(.proposeReschedule(eventRef: Self.refOf(text), newStart: when.start.isoLocal()), facts: facts)
        }
        if Self.dispatch.matches(in: lowered), let file = Self.fileRefOf(text) {
            return call(.dispatchTask(task: "summarize", payloadRef: file, priority: nil), facts: facts)
        }
        if Self.availability.matches(in: lowered), let when {
            return call(.getAvailability(from: when.start.isoLocal(), to: when.end.isoLocal()), facts: facts)
        }
        if Self.create.matches(in: lowered), let when {
            return call(
                PopopxEcoCall.proposeCreate(title: Self.titleOf(text), start: when.start.isoLocal(), end: when.end.isoLocal())
                    .normalizedCreate(facts: facts, fallbackDurationMinutes: facts.defaultEventMinutes),
                facts: facts
            )
        }
        return .empty
    }

    private func call(_ call: PopopxEcoCall, facts: PopopxEcoFacts) -> PopopxEcoEnvelope {
        PopopxEcoEnvelope(calls: [call], suppressed: [], confidence: 1.0, reasoning: "deterministic match against \(facts.today.iso())")
    }

    private func emptyWithReason(_ reason: String) -> PopopxEcoEnvelope {
        PopopxEcoEnvelope(calls: [], suppressed: [], confidence: 0.0, reasoning: reason)
    }

    // MARK: Time resolution

    /// `PopopxDeterministicEngine.resolveTime`. Returns nil when no clock time is present: a whole-day
    /// proposal guessed from "sometime next week" is not a booking.
    static func resolveTime(_ text: String, _ facts: PopopxEcoFacts) -> (start: PopopxEcoDateTime, end: PopopxEcoDateTime)? {
        guard let day = resolveDay(text, facts.today), let clock = resolveClock(text) else { return nil }
        let start = facts.at(clock, day: day)
        let end = clockRange(text).map { facts.at($0, day: day) } ?? start.plusMinutes(facts.defaultEventMinutes)
        return end.minuteOfDay <= start.minuteOfDay && end.date == start.date
            ? (start, start.plusMinutes(facts.defaultEventMinutes))
            : (start, end)
    }

    static func resolveDay(_ text: String, _ today: PopopxEcoDate) -> PopopxEcoDate? {
        let lowered = text.lowercased()
        if PopopxEcoPattern(#"\btoday|今天|今日\b"#).matches(in: lowered) || lowered.contains("今天") || lowered.contains("今日") { return today }
        if PopopxEcoPattern(#"\btomorrow|明天\b"#).matches(in: lowered) || lowered.contains("明天") { return today.plusDays(1) }
        if PopopxEcoPattern(#"\bday after tomorrow|后天\b"#).matches(in: lowered) || lowered.contains("后天") { return today.plusDays(2) }
        if lowered.contains("下周") || lowered.contains("next week") { return nextWeekday(today, weekdayOf(lowered) ?? 1) }
        if let target = weekdayOf(lowered) {
            let explicitNext = lowered.contains("next ") || lowered.contains("下周")
            let candidate = firstWeekdayOnOrAfter(today, target)
            return explicitNext && candidate.dayOfWeek == target && candidate == today ? candidate.plusDays(7) : candidate
        }
        if let groups = PopopxEcoPattern(#"(\d{1,2})\s*(?:日|号)"#).firstGroups(in: text), let day = Int(groups[1]) {
            guard (1...31).contains(day) else { return nil }
            return PopopxEcoDate(year: today.year, month: day < today.day && today.month < 12 ? today.month + 1 : today.month, day: day)
        }
        return nil
    }

    static func firstWeekdayOnOrAfter(_ today: PopopxEcoDate, _ isoWeekday: Int) -> PopopxEcoDate {
        var offset: Int64 = 0
        while offset < 7 {
            let candidate = today.plusDays(offset)
            if candidate.dayOfWeek == isoWeekday { return candidate }
            offset += 1
        }
        return today.plusDays(7)
    }

    static func nextWeekday(_ today: PopopxEcoDate, _ isoWeekday: Int) -> PopopxEcoDate {
        firstWeekdayOnOrAfter(today.plusDays(1), isoWeekday)
    }

    /// Table order is the Kotlin order: the first entry the text contains wins, which is how
    /// "monday" is found by `"monday"` and not by the shorter `"mon"` beneath it.
    static func weekdayOf(_ lowered: String) -> Int? {
        let table: [(String, Int)] = [
            ("monday", 1), ("mon", 1), ("周一", 1), ("星期一", 1), ("礼拜一", 1),
            ("tuesday", 2), ("tue", 2), ("周二", 2), ("星期二", 2), ("礼拜二", 2),
            ("wednesday", 3), ("wed", 3), ("周三", 3), ("星期三", 3), ("礼拜三", 3),
            ("thursday", 4), ("thu", 4), ("thur", 4), ("周四", 4), ("星期四", 4), ("礼拜四", 4),
            ("friday", 5), ("fri", 5), ("周五", 5), ("星期五", 5), ("礼拜五", 5),
            ("saturday", 6), ("sat", 6), ("周六", 6), ("星期六", 6), ("礼拜六", 6),
            ("sunday", 7), ("sun", 7), ("周日", 7), ("星期天", 7), ("星期日", 7), ("礼拜天", 7),
        ]
        return table.first { lowered.contains($0.0) }?.1
    }

    /// Minutes past midnight, or nil — `resolveClock`. Understands `15:00`, `3pm`, `3:30 pm`, 三点半,
    /// 十五点 and 上午/下午 hints.
    static func resolveClock(_ text: String) -> Int? {
        if let groups = PopopxEcoPattern(#"(\d{1,2}):(\d{2})\s*(am|pm)?"#).firstGroups(in: text.lowercased()),
           let hour = Int(groups[1]), let minute = Int(groups[2]) {
            return normalizeHour(hour, minute, groups[3], text)
        }
        if let groups = PopopxEcoPattern(#"(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)"#).firstGroups(in: text.lowercased()),
           let hour = Int(groups[1]) {
            return normalizeHour(hour, 0, groups[2], text)
        }
        if let groups = PopopxEcoPattern(#"(\d{1,2})\s*点(?:半|\d{1,2}分?)?"#).firstGroups(in: text),
           let spoken = Int(groups[1]) {
            let minutes = groups[0].contains("半") ? 30 : 0
            let marker = text.contains("下午") || text.contains("晚上") ? "pm"
                : text.contains("上午") || text.contains("早上") || text.contains("中午") ? "am" : ""
            return normalizeHour(spoken, minutes, marker, text)
        }
        if let numeral = chineseNumeral.matches(in: text, at: 0), let hour = chineseNumber(numeral.value) {
            let trailing = popopxEcoAfterMatch(text, numeral.range)
            let minutes = trailing.hasPrefix("半") ? 30 : 0
            return normalizeHour(hour, minutes, text.contains("下午") || text.contains("晚上") ? "pm" : "", text)
        }
        return nil
    }

    static func normalizeHour(_ hour: Int, _ minute: Int, _ marker: String, _ text: String) -> Int? {
        guard (1...24).contains(hour), (0...59).contains(minute) else { return nil }
        let pm = marker.lowercased().hasPrefix("p") || text.contains("下午") || text.contains("晚上")
        let adjusted: Int
        if pm && hour < 12 { adjusted = hour + 12 }
        else if !pm && hour == 12 { adjusted = 0 }
        else { adjusted = hour % 24 }
        return adjusted * 60 + minute
    }

    /// The second clock token, when the sentence holds two — Kotlin's `findAll(...).toList()` guarded
    /// by `size < 2`, which is the same question as "does the match at index 1 exist".
    static func clockRange(_ text: String) -> Int? {
        guard let second = clockToken.matches(in: text.lowercased(), at: 1) else { return nil }
        return resolveClock(second.value)
    }

    static let chineseNumeral = PopopxEcoPattern(#"[一二两三四五六七八九十]{1,3}(?=点)"#)
    static let clockToken = PopopxEcoPattern(#"(?:\d{1,2}:\d{2}|\d{1,2}\s*(?:点|am|pm))"#)

    static func chineseNumber(_ text: String) -> Int? {
        switch text {
        case "一": 1
        case "二", "两": 2
        case "三": 3
        case "四": 4
        case "五": 5
        case "六": 6
        case "七": 7
        case "八": 8
        case "九": 9
        case "十": 10
        case "十一": 11
        case "十二": 12
        case "十三": 13
        case "十四": 14
        case "十五": 15
        case "十六": 16
        case "十七": 17
        case "十八": 18
        case "十九": 19
        case "二十": 20
        default: nil
        }
    }

    // MARK: Phrase extraction

    /// The words the user called the thing, with the trigger and the clock stripped — `titleOf`.
    /// Never invents a title. The five passes are the Kotlin's chained `replace` calls, in order; they are
    /// written as steps because a five-deep nest of them is impossible to audit against the source.
    static func titleOf(_ text: String) -> String? {
        var cleaned = summonAndSlash.replaceAll(" ", in: text)
        cleaned = clockDigits.replaceAll(" ", in: cleaned)
        cleaned = spokenClock.replaceAll(" ", in: cleaned)
        cleaned = dayWords.replaceAll(" ", in: cleaned)
        cleaned = whitespace.replaceAll(" ", in: cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return nil }
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ",，.。;；"))
        guard let first = parts.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return (2...60).contains(first.count) ? first : nil
    }

    /// The words that point at an existing event — `refOf`. Same reasoning: the Kotlin strips eleven
    /// different shapes, and the order is the order it strips them in.
    static func refOf(_ text: String) -> String {
        var stripped = summonAndSlash.replaceAll(" ", in: text)
        stripped = cancel.replaceAll(" ", in: stripped)
        stripped = reschedule.replaceAll(" ", in: stripped)
        stripped = englishVerbs.replaceAll(" ", in: stripped)
        stripped = chineseVerbs.replaceAll(" ", in: stripped)
        stripped = latinClock.replaceAll(" ", in: stripped)
        stripped = spokenClockB.replaceAll(" ", in: stripped)
        stripped = dayWordsEnglish.replaceAll(" ", in: stripped)
        stripped = whitespace.replaceAll(" ", in: stripped)
        stripped = stripped.trimmingCharacters(in: CharacterSet(charactersIn: " ?？!.。"))
        return stripped.isEmpty ? "" : String(stripped.prefix(60))
    }

    // The stripping passes, named once and shared by `titleOf` and `refOf`.
    static let summonAndSlash = PopopxEcoPattern(#"@助理|/[^\s]+"#)
    static let clockDigits = PopopxEcoPattern(#"\d{1,2}(:\d{2})?\s*(am|pm|点|半)"#)
    /// `refOf` strips a narrower clock than `titleOf` does — the Kotlin has `(am|pm)` here and
    /// `(am|pm|点|半)` there, and the difference is preserved rather than unified.
    static let latinClock = PopopxEcoPattern(#"\d{1,2}(:\d{2})?\s*(am|pm)"#)
    static let spokenClock = PopopxEcoPattern(#"[一二两三四五六七八九十]{1,3}点(半|\d{1,2}分?)?"#)
    static let spokenClockB = PopopxEcoPattern(#"[一二两三四五六七八九十]{1,3}点(半)?"#)
    static let dayWords = PopopxEcoPattern(#"今天|明天|后天|下周|上午|下午|晚上|早上"#)
    static let whitespace = PopopxEcoPattern(#"\s+"#)
    /// The five intents. Each pattern string is byte-identical to the Kotlin `Regex` it mirrors
    /// (`PopopxDeterministicEngine.kt:214-218`) and no Chinese alternative sits inside a `\b`, for the
    /// reason given in the Copilot header. The `ignoreCase` flags are the one difference from Kotlin, and
    /// they cost nothing: Kotlin matches text it has already lowercased (`:169`) and so does this call
    /// site, so there is no case left for the flag to change.
    static let cancel = PopopxEcoPattern(#"\b(cancel|call off|drop)\b|删除|取消|把.+(取消|删掉)"#, ignoreCase: true)
    static let reschedule = PopopxEcoPattern(#"\b(move|push|shift|reschedule|postpone)\b|改到|改期|挪到|推到"#, ignoreCase: true)
    static let dispatch = PopopxEcoPattern(#"\b(summari[sz]e|digest|read|translate|compress)\b|总结|摘要|翻译"#, ignoreCase: true)
    static let availability = PopopxEcoPattern(#"\b(free|available|busy|open|when can)\b|有空|有没空|查空闲|几点有空"#, ignoreCase: true)
    static let create = PopopxEcoPattern(#"\b(meet|meeting|book|schedule|set up|reserve|add|grab)\b|约|安排|订|加个"#, ignoreCase: true)

    static let englishVerbs = PopopxEcoPattern(#"\b(cancel|move|reschedule|postpone|shift|push|delete|drop|call off)\b"#, ignoreCase: true)
    static let chineseVerbs = PopopxEcoPattern(#"取消|删除|改到|改期|挪到|推到|把"#)
    static let dayWordsEnglish = PopopxEcoPattern(#"today|tomorrow|明天|今天|后天|周[一二三四五六日天]|星期[一二三四五六日天]"#, ignoreCase: true)

    /// Only a real file reference counts: the assistant never queues work over a word that happens to
    /// be "pdf" — `fileRefOf`. Group 1 is the whole `name.ext` in the first and third patterns, exactly
    /// as `groupValues[1]` reads it in Kotlin.
    static func fileRefOf(_ text: String) -> String? {
        if let groups = fileExtension.firstGroups(in: text), groups.count > 1 {
            let name = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if let groups = chineseFileWord.firstGroups(in: text), groups.count > 1 {
            let candidate = popopxEcoStripPrefixes(
                groups[1].trimmingCharacters(in: .whitespacesAndNewlines),
                ["帮我", "请"]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if (2...80).contains(candidate.count) { return candidate }
        }
        if let groups = englishFileWord.firstGroups(in: text), groups.count > 1 {
            let name = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }

    static let fileExtension = PopopxEcoPattern(#"([\w \-]+\.(pdf|docx?|txt|md|csv|pptx|xlsx|epub|png|jpe?g))"#, ignoreCase: true)
    static let chineseFileWord = PopopxEcoPattern(#"(.+?(?:文件|文档|pdf|合同|报告|说明书))"#)
    static let englishFileWord = PopopxEcoPattern(#"\b(?:the|my|this)\s+([\w \-]{2,60}?(?:document|file|report|contract|pdf|doc))"#, ignoreCase: true)

    // MARK: Intent grammar
}

/// The text following an ICU match, taken by byte offset so a surrogate pair cannot shift it.
private func popopxEcoAfterMatch(_ text: String, _ range: NSRange) -> String {
    guard let bounds = Range(NSRange(location: range.location + range.length, length: 0), in: text) else { return "" }
    return String(text[bounds.lowerBound...])
}

/// Kotlin's chained `removePrefix` — only the leading one is removed, and only if present.
private func popopxEcoStripPrefixes(_ text: String, _ prefixes: [String]) -> String {
    var rest = text
    for prefix in prefixes where rest.hasPrefix(prefix) { rest = String(rest.dropFirst(prefix.count)) }
    return rest
}

// ---------------------------------------------------------------- Calendar privacy

/// An event exactly as the system calendar store hands it over — `PopopxRawCalendarEvent`. This is the
/// only type in the app that carries a title, a location, an attendee or a note.
///
/// The assistant's privacy rule is that nothing but the two times ever leaves `PopopxCalendarPrivacy`,
/// and what it returns holds no `String` at all. That makes 「计算完 Free/Busy 空闲时段后立即丢弃事件
/// 标题、地点、参会人与备注」 a shape the compiler enforces rather than a promise in a comment: to leak,
/// the sanitizer would have to convert a string into a number.
struct PopopxRawCalendarEvent: Hashable, Sendable {
    let startEpochMinutes: Int64
    let endEpochMinutes: Int64
    var title: String = ""
    var location: String = ""
    var attendees: [String] = []
    var notes: String = ""
}

/// A busy or free interval, minutes since the epoch — `PopopxEcoBusySlot`. Numbers only.
struct PopopxEcoBusySlot: Hashable, Sendable {
    let startEpochMinutes: Int64
    let endEpochMinutes: Int64

    var durationMinutes: Int { Int(max(0, endEpochMinutes - startEpochMinutes)) }

    func contains(_ instant: PopopxEcoDateTime) -> Bool {
        instant.epochMinutes >= startEpochMinutes && instant.epochMinutes < endEpochMinutes
    }

    var toLocalRange: (start: PopopxEcoDateTime, end: PopopxEcoDateTime) {
        (PopopxEcoDateTime.fromEpochMinutes(startEpochMinutes), PopopxEcoDateTime.fromEpochMinutes(endEpochMinutes))
    }

    static func between(_ start: PopopxEcoDateTime, minutes: Int) -> PopopxEcoBusySlot {
        PopopxEcoBusySlot(startEpochMinutes: start.epochMinutes, endEpochMinutes: start.epochMinutes + Int64(minutes))
    }
}

/// What the user has said about when they are willing to be booked — `PopopxTimePreferences`.
struct PopopxTimePreferences: Sendable {
    struct MinuteRange: Hashable, Sendable {
        let startMinute: Int
        let endMinute: Int

        var isValid: Bool { endMinute > startMinute }

        /// A range that wraps midnight (a night shift) holds the hours at either end of the day.
        func covers(_ minutesPastMidnight: Int) -> Bool {
            if endMinute >= startMinute { return minutesPastMidnight >= startMinute && minutesPastMidnight < endMinute }
            return minutesPastMidnight >= startMinute || minutesPastMidnight < endMinute
        }
    }

    /// Local minute-of-day ranges; empty means "any hour", which is the onboarding default.
    var workingMinutes: [MinuteRange] = []
    var lunch: MinuteRange?
    var avoidWeekends = false
    /// Kept free on either side of a new event. Applied by widening the busy set rather than by
    /// shrinking candidates, so a buffer also protects the time around events already in the calendar.
    var bufferMinutes = 0
    var minimumSlotMinutes = 15

    static let dayMinutes: Int64 = 24 * 60

    /// The defaults 「本地时间偏好」 starts with before the user has said anything.
    static let defaults = PopopxTimePreferences(
        workingMinutes: [MinuteRange(startMinute: 9 * 60, endMinute: 18 * 60)],
        lunch: MinuteRange(startMinute: 12 * 60, endMinute: 13 * 60),
        avoidWeekends: false,
        bufferMinutes: 0,
        minimumSlotMinutes: 15
    )

    /// The permitted intervals of `[windowStart, windowEnd)`: working hours minus lunch, day by day,
    /// clipped and sorted — `PopopxTimePreferences.allowedRanges`.
    func allowedRanges(windowStart: Int64, windowEnd: Int64) -> [PopopxEcoBusySlot] {
        var out: [PopopxEcoBusySlot] = []
        let ranges = workingMinutes.isEmpty ? [MinuteRange(startMinute: 0, endMinute: 24 * 60)] : workingMinutes
        var day = popopxEcoFloorDiv(windowStart, Self.dayMinutes)
        while day * Self.dayMinutes < windowEnd {
            let dayStart = day * Self.dayMinutes
            if !avoidWeekends || PopopxEcoDate.fromEpochDays(day).dayOfWeek <= 5 {
                for range in ranges.filter(\.isValid) {
                    let segments: [(Int64, Int64)]
                    if range.endMinute >= range.startMinute {
                        segments = [(dayStart + Int64(range.startMinute), dayStart + Int64(range.endMinute))]
                    } else {
                        segments = [
                            (dayStart + Int64(range.startMinute), dayStart + Self.dayMinutes),
                            (dayStart, dayStart + Int64(range.endMinute)),
                        ]
                    }
                    for segment in segments {
                        let from = max(segment.0, windowStart)
                        let to = min(segment.1, windowEnd)
                        if to > from { out.append(contentsOf: subtractLunch(from: from, to: to, dayStart: dayStart)) }
                    }
                }
            }
            day += 1
        }
        return out.sorted { ($0.startEpochMinutes, $0.endEpochMinutes) < ($1.startEpochMinutes, $1.endEpochMinutes) }
    }

    private func subtractLunch(from: Int64, to: Int64, dayStart: Int64) -> [PopopxEcoBusySlot] {
        guard let lunch, lunch.isValid else { return [PopopxEcoBusySlot(startEpochMinutes: from, endEpochMinutes: to)] }
        let cutStart = max(from, dayStart + Int64(lunch.startMinute))
        let cutEnd = min(to, dayStart + Int64(lunch.endMinute))
        if cutEnd <= cutStart { return [PopopxEcoBusySlot(startEpochMinutes: from, endEpochMinutes: to)] }
        var out: [PopopxEcoBusySlot] = []
        if from < cutStart { out.append(PopopxEcoBusySlot(startEpochMinutes: from, endEpochMinutes: cutStart)) }
        if cutEnd < to { out.append(PopopxEcoBusySlot(startEpochMinutes: cutEnd, endEpochMinutes: to)) }
        return out
    }

    /// True when the slot fits entirely inside one permitted interval and is long enough to offer.
    func allows(_ slot: PopopxEcoBusySlot, windowStart: Int64, windowEnd: Int64) -> Bool {
        guard slot.durationMinutes >= minimumSlotMinutes else { return false }
        return allowedRanges(windowStart: windowStart, windowEnd: windowEnd).contains {
            $0.startEpochMinutes <= slot.startEpochMinutes && slot.endEpochMinutes <= $0.endEpochMinutes
        }
    }
}

/// Free/busy computation, and the only place raw calendar events are read — `PopopxCalendarPrivacy`.
///
/// Every function here takes events and returns numbers. Nothing in the returned types can hold a word,
/// so the desensitisation is structural: the caller drops the event list after one call, and the
/// assistant's later turns never see a title, a location, an attendee or a note.
enum PopopxCalendarPrivacy {
    static let dayMinutes = PopopxTimePreferences.dayMinutes

    /// Busy intervals clipped to the window and merged, so a day block beside a meeting is one answer.
    static func busySlots(events: [PopopxRawCalendarEvent], windowStart: Int64, windowEnd: Int64) -> [PopopxEcoBusySlot] {
        merge(events
            .map { PopopxEcoBusySlot(startEpochMinutes: max($0.startEpochMinutes, windowStart), endEpochMinutes: min($0.endEpochMinutes, windowEnd)) }
            .filter { $0.startEpochMinutes < $0.endEpochMinutes })
    }

    /// The same busy set widened by the user's buffer, which is how a buffer protects existing events too.
    static func busySlotsWithBuffer(events: [PopopxRawCalendarEvent], windowStart: Int64, windowEnd: Int64, bufferMinutes: Int) -> [PopopxEcoBusySlot] {
        guard bufferMinutes > 0 else { return busySlots(events: events, windowStart: windowStart, windowEnd: windowEnd) }
        let buffer = Int64(bufferMinutes)
        return merge(busySlots(events: events, windowStart: windowStart - buffer, windowEnd: windowEnd + buffer)
            .map { PopopxEcoBusySlot(startEpochMinutes: max($0.startEpochMinutes - buffer, windowStart), endEpochMinutes: min($0.endEpochMinutes + buffer, windowEnd)) }
            .filter { $0.startEpochMinutes < $0.endEpochMinutes })
    }

    private static func merge(_ slots: [PopopxEcoBusySlot]) -> [PopopxEcoBusySlot] {
        var out: [PopopxEcoBusySlot] = []
        for slot in slots.sorted(by: { $0.startEpochMinutes < $1.startEpochMinutes }) {
            if let last = out.last, slot.startEpochMinutes <= last.endEpochMinutes {
                out[out.count - 1] = PopopxEcoBusySlot(startEpochMinutes: last.startEpochMinutes, endEpochMinutes: max(last.endEpochMinutes, slot.endEpochMinutes))
            } else {
                out.append(slot)
            }
        }
        return out
    }

    /// The free intervals of the window, earliest first, each at least `eventMinutes` long.
    ///
    /// `eventMinutes` is the length of the meeting being proposed: the subtraction happens against the
    /// whole length, so a ten-minute gap in front of a blocked hour is never offered for an hour.
    static func freeSlots(
        events: [PopopxRawCalendarEvent],
        windowStart: Int64,
        windowEnd: Int64,
        preferences: PopopxTimePreferences = .defaults,
        eventMinutes: Int = popopxEcoDefaultEventMinutes
    ) -> [PopopxEcoBusySlot] {
        guard windowEnd > windowStart, eventMinutes > 0 else { return [] }
        let busy = busySlotsWithBuffer(events: events, windowStart: windowStart, windowEnd: windowEnd, bufferMinutes: preferences.bufferMinutes)
        var out: [PopopxEcoBusySlot] = []
        for allowed in preferences.allowedRanges(windowStart: windowStart, windowEnd: windowEnd) {
            var cursor = allowed.startEpochMinutes
            for block in busy.filter({ $0.endEpochMinutes > cursor && $0.startEpochMinutes < allowed.endEpochMinutes }) {
                addAtLeast(&out, from: cursor, to: min(block.startEpochMinutes, allowed.endEpochMinutes), eventMinutes: eventMinutes, minimumMinutes: preferences.minimumSlotMinutes)
                cursor = max(cursor, block.endEpochMinutes)
            }
            addAtLeast(&out, from: cursor, to: allowed.endEpochMinutes, eventMinutes: eventMinutes, minimumMinutes: preferences.minimumSlotMinutes)
        }
        return out
    }

    private static func addAtLeast(_ out: inout [PopopxEcoBusySlot], from: Int64, to: Int64, eventMinutes: Int, minimumMinutes: Int) {
        if to - from >= Int64(max(eventMinutes, minimumMinutes)) { out.append(PopopxEcoBusySlot(startEpochMinutes: from, endEpochMinutes: to)) }
    }

    /// Whether a proposal at `start` for `minutes` collides with anything already in the calendar.
    static func conflicts(events: [PopopxRawCalendarEvent], start: PopopxEcoDateTime, minutes: Int, bufferMinutes: Int = 0) -> PopopxEcoBusySlot? {
        let slot = PopopxEcoBusySlot.between(start, minutes: minutes)
        return busySlotsWithBuffer(events: events, windowStart: slot.startEpochMinutes, windowEnd: slot.endEpochMinutes, bufferMinutes: bufferMinutes)
            .first { $0.contains(start) || (slot.startEpochMinutes < $0.endEpochMinutes && $0.startEpochMinutes < slot.endEpochMinutes) }
    }

    /// The window 「查空闲」 reads: `hours` of real time from `from`, no rounding to invent.
    static func window(from: PopopxEcoDateTime, hours: Int) -> (start: Int64, end: Int64) {
        (from.epochMinutes, from.epochMinutes + Int64(hours) * 60)
    }
}

// ---------------------------------------------------------------- The confirm gate

/// A confirmed calendar change, in the only form the platform layer accepts — `PopopxCalendarWrite`.
///
/// Note what is absent: there is no field for a note, a location, an attendee or a reminder, so the
/// assistant cannot reach any of them even by accident. `insert` carries a title because it is the title
/// of the event being created, taken from the user's own message.
enum PopopxCalendarWrite: Hashable, Sendable {
    case insert(title: String, startEpochMinutes: Int64, endEpochMinutes: Int64)
    case update(eventId: String, newStartEpochMinutes: Int64, durationMinutes: Int)
    case delete(eventId: String)
}

/// What the assistant is offering to do, and the only thing it can do to the calendar —
/// `PopopxEcoProposal`.
///
/// Each proposal knows how to describe itself to the person and, once confirmed, how to be executed.
/// `description` is deliberately the user's own words for a new event and a *reference* for an existing
/// one: an existing event's title is not carried here, because the sanitizer dropped it and a card that
/// showed it would leak the calendar back into the assistant's output.
enum PopopxEcoProposal: Hashable, Sendable {
    /// Book a new event. The title is what the user said, not something the model invented.
    case create(title: String, start: PopopxEcoDateTime, end: PopopxEcoDateTime)
    /// Move an existing event. `eventRef` is the store id the platform read for it, and the only way
    /// this proposal names the event.
    case reschedule(eventRef: String, newStart: PopopxEcoDateTime, durationMinutes: Int)
    /// Delete an existing event.
    case cancel(eventRef: String)

    /// The sentence on the card.
    var description: String {
        switch self {
        case let .create(title, _, _): title
        case let .reschedule(eventRef, _, _): "Move event \(eventRef)"
        case let .cancel(eventRef): "Cancel event \(eventRef)"
        }
    }

    /// The times shown in the user's own calendar app, for the card's second line.
    var whenText: String {
        switch self {
        case let .create(_, start, end): "\(start.isoLocal()) – \(end.isoLocal())"
        case let .reschedule(_, newStart, _): newStart.isoLocal()
        case .cancel: ""
        }
    }

    /// The change, for the platform layer to apply. Only reachable through the gate.
    func write() -> PopopxCalendarWrite {
        switch self {
        case let .create(title, start, end):
            .insert(title: title, startEpochMinutes: start.epochMinutes, endEpochMinutes: end.epochMinutes)
        case let .reschedule(eventRef, newStart, durationMinutes):
            .update(eventId: eventRef, newStartEpochMinutes: newStart.epochMinutes, durationMinutes: durationMinutes)
        case let .cancel(eventRef):
            .delete(eventId: eventRef)
        }
    }

    /// The busy interval this proposal would land inside, or nil.
    ///
    /// One predicate, called by `PopopxEcoPlanner.plan` to make the `.conflict` case and again by the
    /// confirm card to say it out loud, so the two can never disagree about what "it collides" means. A
    /// cancellation is never a collision: deleting a booked hour is the free thing to do.
    func collision(in busy: [PopopxEcoBusySlot]) -> PopopxEcoBusySlot? {
        switch self {
        case let .create(_, start, end):
            return busy.first { $0.startEpochMinutes < end.epochMinutes && start.epochMinutes < $0.endEpochMinutes }
        case let .reschedule(_, newStart, durationMinutes):
            let from = newStart.epochMinutes
            let until = newStart.plusMinutes(durationMinutes).epochMinutes
            return busy.first { $0.startEpochMinutes < until && from < $0.endEpochMinutes }
        case .cancel:
            return nil
        }
    }

    /// Resolves a words-reference into a store id before the card is shown, so 「日历里没有这条日程」 is
    /// answered with no card rather than with a card that points at nothing — the Kotlin's
    /// `PopopxEcoAssistant.withResolvedRef`. A create has no existing event to resolve.
    func withResolvedRef(calendar: PopopxEcoCalendarAccess, windowStart: Int64, windowEnd: Int64) async -> PopopxEcoProposal? {
        switch self {
        case .create:
            return self
        case let .reschedule(eventRef, newStart, durationMinutes):
            guard let id = await calendar.resolveEventId(words: eventRef, windowStartEpochMinutes: windowStart, windowEndEpochMinutes: windowEnd)
            else { return nil }
            return .reschedule(eventRef: id, newStart: newStart, durationMinutes: durationMinutes)
        case let .cancel(eventRef):
            guard let id = await calendar.resolveEventId(words: eventRef, windowStartEpochMinutes: windowStart, windowEndEpochMinutes: windowEnd)
            else { return nil }
            return .cancel(eventRef: id)
        }
    }
}

/// The gate between an assistant turn and the system calendar — `PopopxEcoConfirmGate`.
///
/// 「先生成待确认卡片 → 用户点击确认后才写入系统日历」 is a rule about ordering, and an ordering rule
/// in a feature like this is only worth what its enforcement is worth, so the write is not a callback the
/// UI may choose to call: it is the return value of `confirm`, and a proposal that was never confirmed
/// produces nothing. The second reason is the model — the bundled engine's `validation.ungrounded` flag
/// exists because it sometimes proposes something the user did not say, so proposals are the only
/// representation the engine has and the person is the only thing that can turn one into an entry.
final class PopopxEcoConfirmGate {
    /// A proposal waiting for the tap, with the moment it was made: a card left on screen while the user
    /// went elsewhere must not confirm against a calendar that has since changed.
    struct Pending: Identifiable {
        let id: Int
        let proposal: PopopxEcoProposal
        let proposedAtEpochMinutes: Int64
    }

    /// How long a card may wait: long enough to read, short enough that it describes today.
    static let defaultConfirmWindowMinutes = 30

    private var sequence = 0
    private var pending: [Pending] = []

    var proposals: [Pending] { pending }

    func propose(_ proposal: PopopxEcoProposal, nowEpochMinutes: Int64) -> Pending {
        sequence += 1
        let item = Pending(id: sequence, proposal: proposal, proposedAtEpochMinutes: nowEpochMinutes)
        pending.append(item)
        return item
    }

    /// The tap. The proposal leaves the pending set with it, so a double tap cannot double-write.
    func confirm(id: Int, nowEpochMinutes: Int64, expiresAfterMinutes: Int = PopopxEcoConfirmGate.defaultConfirmWindowMinutes) -> PopopxCalendarWrite? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        let item = pending.remove(at: index)
        guard nowEpochMinutes - item.proposedAtEpochMinutes <= Int64(expiresAfterMinutes) else { return nil }
        return item.proposal.write()
    }

    func dismiss(id: Int) {
        pending.removeAll { $0.id == id }
    }

    /// Backgrounding the app drops every outstanding card; returning to it is not a confirmation.
    func expireAll() { pending.removeAll() }
}

/// A card the UI can render, or the reason there is no card — `PopopxEcoPlan`.
///
/// The rejection is a value rather than a silent no-op because the user has to be told why the assistant
/// did nothing: 「日程标题缺失」 and 「日历里没有这条日程」 are different sentences, and only the second
/// one suggests trying again with the calendar app open.
enum PopopxEcoPlan: Sendable {
    case card(proposal: PopopxEcoProposal, reason: String?)
    /// The proposal collides with a busy interval, which the card then says out loud.
    case conflict(proposal: PopopxEcoProposal, with: PopopxEcoBusySlot)
    case reject(reason: String)
    /// Nothing to do: the turn asked a question rather than proposing a change.
    case answer(text: String)
}

/// Turns a parsed call into a proposal — `PopopxEcoPlanner`.
///
/// `busy` is what the sanitizer already returned, so the planner can warn about a collision without ever
/// reading an event itself.
enum PopopxEcoPlanner {
    static func plan(_ call: PopopxEcoCall, facts: PopopxEcoFacts, busy: [PopopxEcoBusySlot] = []) -> PopopxEcoPlan {
        switch call {
        case .getAvailability:
            return .answer(text: freeText(facts: facts, busy: busy))

        case .proposeCreate:
            let normalized = call.normalizedCreate(facts: facts, fallbackDurationMinutes: facts.defaultEventMinutes)
            guard case let .proposeCreate(title, start, end) = normalized,
                  let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .reject(reason: "the proposal has no event title") }
            guard let from = PopopxEcoDateTime.parse(start) else { return .reject(reason: "the proposal has no start time") }
            let until = end.flatMap { PopopxEcoDateTime.parse($0) } ?? from.plusMinutes(facts.defaultEventMinutes)
            guard until.epochMinutes > from.epochMinutes else { return .reject(reason: "the proposal ends before it starts") }
            let proposal = PopopxEcoProposal.create(title: title, start: from, end: until)
            return proposal.collision(in: busy).map { .conflict(proposal: proposal, with: $0) } ?? .card(proposal: proposal, reason: nil)

        case .proposeReschedule:
            guard let normalized = call.normalizedReschedule(facts: facts),
                  case let .proposeReschedule(eventRef, newStart) = normalized
            else { return .reject(reason: "the new time is not a time") }
            guard let start = PopopxEcoDateTime.parse(newStart) else { return .reject(reason: "the new time is not a time") }
            guard !eventRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .reject(reason: "the proposal names no event") }
            return .card(proposal: .reschedule(eventRef: eventRef, newStart: start, durationMinutes: facts.defaultEventMinutes), reason: nil)

        case .proposeCancel:
            guard let reference = call.argumentString("event_ref") else { return .reject(reason: "the proposal names no event") }
            return .card(proposal: .cancel(eventRef: reference), reason: nil)

        case .dispatchTask:
            return .reject(reason: "a compute task is not a calendar change")
        }
    }

    private static func freeText(facts: PopopxEcoFacts, busy: [PopopxEcoBusySlot]) -> String {
        if busy.isEmpty { return "nothing is booked in the next \(facts.defaultWindowHours) hours" }
        var free: [String] = []
        var cursor = facts.now.epochMinutes
        let horizon = cursor + Int64(facts.defaultWindowHours) * 60
        for slot in busy {
            if slot.startEpochMinutes > cursor { free.append(span(cursor, min(slot.startEpochMinutes, horizon))) }
            cursor = max(cursor, slot.endEpochMinutes)
        }
        if cursor < horizon { free.append(span(cursor, horizon)) }
        return free.isEmpty ? "no free time in the next \(facts.defaultWindowHours) hours" : free.joined(separator: ", ")
    }

    private static func span(_ from: Int64, _ to: Int64) -> String {
        "\(PopopxEcoDateTime.fromEpochMinutes(from).isoLocal()) – \(PopopxEcoDateTime.fromEpochMinutes(to).isoLocal())"
    }
}

// ---------------------------------------------------------------- RFC 5545

/// `.ics` for a confirmed proposal, so the user can save or share what the assistant booked instead of
/// only seeing it inside the app — `PopopxEcoICS`.
///
/// The output is written with the CRLF the spec requires, not the platform's own line ending, because
/// `.ics` files are read by other vendors' software and a folded `\n` is not valid there. Long values are
/// folded at 75 **octets** with a leading space on the continuation, and text is escaped the way the
/// spec's `TEXT` rule asks — backslash first, then semicolon and comma, then newline, in that order.
enum PopopxEcoICS {
    static let crlf = "\r\n"
    static let lineLimit = 75

    static func calendar(_ proposal: PopopxEcoProposal, stampEpochMinutes: Int64, productId: String = "-//POPOPX//Copilot//EN") -> String {
        var out = ""
        emit("BEGIN:VCALENDAR", into: &out)
        emit("VERSION:2.0", into: &out)
        emit("PRODID:\(productId)", into: &out)
        emit("CALSCALE:GREGORIAN", into: &out)
        emit("METHOD:PUBLISH", into: &out)
        emit("BEGIN:VEVENT", into: &out)
        emit("UID:\(uid(for: proposal))@popopx.im", into: &out)
        emit("DTSTAMP:\(generalized(PopopxEcoDateTime.fromEpochMinutes(stampEpochMinutes), utc: true))", into: &out)
        switch proposal {
        case let .create(_, start, end):
            emit("DTSTART:\(generalized(start, utc: false))", into: &out)
            emit("DTEND:\(generalized(end, utc: false))", into: &out)
        case let .reschedule(_, newStart, durationMinutes):
            emit("DTSTART:\(generalized(newStart, utc: false))", into: &out)
            emit("DTEND:\(generalized(newStart.plusMinutes(durationMinutes), utc: false))", into: &out)
            emit("SEQUENCE:1", into: &out)
        case .cancel:
            break
        }
        emit("SUMMARY:\(escape(proposal.description))", into: &out)
        if case .cancel = proposal { emit("STATUS:CANCELLED", into: &out) }
        emit("END:VEVENT", into: &out)
        emit("END:VCALENDAR", into: &out)
        return out
    }

    /// RFC 5545 `UID` for this proposal.
    ///
    /// A deliberate departure from the Kotlin, which uses `proposal.toString().hashCode()`. Java's
    /// `String.hashCode` is specified and therefore stable across runs; Swift's `hashValue` is seeded per
    /// process, so copying it would mint a fresh UID every time the card is drawn and a shared event
    /// would never be recognisable as the same event. SHA-256 over the proposal's own text is stable and
    /// cheap, and the file never leaves the device unsigned anyway.
    private static func uid(for proposal: PopopxEcoProposal) -> String {
        let canonical: String
        switch proposal {
        case let .create(title, start, end): canonical = "create|\(title)|\(start.epochMinutes)|\(end.epochMinutes)"
        case let .reschedule(ref, start, minutes): canonical = "reschedule|\(ref)|\(start.epochMinutes)|\(minutes)"
        case let .cancel(ref): canonical = "cancel|\(ref)"
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "popopx-copilot-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A content line, folded at 75 octets. The first chunk is 75 and every later chunk is 74, because a
    /// continuation line begins with one space. Folding walks UTF-8 bytes and never splits a scalar, so a
    /// Chinese `SUMMARY` is valid and inside the limit; the Kotlin twin folds by UTF-16 unit, which stays
    /// scalar-safe for CJK but can run a line past 75 octets and can cut an emoji in half.
    private static func emit(_ value: String, into out: inout String) {
        let bytes = Array(value.utf8)
        var index = 0
        var first = true
        while index < bytes.count {
            let width = first ? lineLimit : lineLimit - 1
            var end = min(index + width, bytes.count)
            while end > index, end < bytes.count, (bytes[end] & 0xC0) == 0x80 { end -= 1 }
            if !first { out += " " }
            out += String(decoding: bytes[index..<end], as: UTF8.self) + crlf
            index = end
            first = false
        }
        if value.isEmpty { out += crlf }
    }

    /// `20261127T150000` — the times are the user's local ones, so no `Z` and no timezone is claimed.
    ///
    /// `EcoDateTime.isoLocal()` carries no seconds, and RFC 5545's `GeneralizedTime` requires them, so
    /// the seconds are written as `00` here rather than dropped the way a plain
    /// `isoLocal().replacing("-"/":")` would drop them.
    private static func generalized(_ instant: PopopxEcoDateTime, utc: Bool) -> String {
        let hour = Int(popopxEcoFloorDiv(Int64(instant.minuteOfDay), 60))
        let minute = Int(popopxEcoFloorMod(Int64(instant.minuteOfDay), 60))
        let date = instant.date
        return popopxEcoPad4(date.year) + popopxEcoPad2(date.month) + popopxEcoPad2(date.day)
            + "T" + popopxEcoPad2(hour) + popopxEcoPad2(minute) + "00" + (utc ? "Z" : "")
    }

    /// Backslash first, then semicolon and comma, then newline — that order, or the later escapes eat the
    /// backslash the earlier one inserted.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// ---------------------------------------------------------------- Observer state

/// How the assistant is allowed to look at a conversation — `PopopxEcoObserverMode`.
///
/// The default is `off` and there is no state in which the app reads history without the user having
/// entered it in this session: 「默认零监听」 is implemented as `off` being the initial value of a `var`
/// that no code path writes to except the two toggles the user can see.
enum PopopxEcoObserverMode: Int, Sendable {
    /// Nothing is read, not even the current message. The initial value.
    case off
    /// Only the message the user typed with the summon token, plus the 5 that precede it.
    case summonLastMessages
    /// Every message of the one session the user opened the real-time assist in, until they leave it.
    case realtimeSession
}

/// The live state of the assistant for one session — `PopopxEcoAssistantState`.
///
/// Model state and observation state are kept apart on purpose: releasing the weights because the app
/// went to the background says nothing about whether the user had authorised listening, and returning to
/// the foreground must not re-enable an observer the user turned off. There is accordingly no
/// `willEnterForeground` handler anywhere in this feature.
final class PopopxEcoAssistantState {
    /// 「最近 5 条上下文」 — the summon feeds five messages, never the whole thread.
    static let contextWindow = 5

    private(set) var observer: PopopxEcoObserverMode
    private(set) var realtimeSession: String?
    private(set) var engine: PopopxEdgeCopilotEngine

    init(initialObserver: PopopxEcoObserverMode = .off) {
        observer = initialObserver
        engine = PopopxDeterministicEngine()
    }

    /// True while the green 「本机助理实时协助中 · 数据不出设备」 indicator must be shown.
    var showsLiveIndicator: Bool { observer == .realtimeSession && realtimeSession != nil }

    @discardableResult
    func summon(sessionId: String) -> PopopxEcoObserverMode {
        observer = .summonLastMessages
        realtimeSession = nil
        return observer
    }

    /// The toggle the user reaches for; a second call with the same session turns the assist off.
    @discardableResult
    func toggleRealtime(sessionId: String) -> PopopxEcoObserverMode {
        if observer == .realtimeSession && realtimeSession == sessionId {
            stopRealtime()
        } else {
            observer = .realtimeSession
            realtimeSession = sessionId
        }
        return observer
    }

    func stopRealtime() {
        observer = .off
        realtimeSession = nil
    }

    func turnOff() {
        stopRealtime()
        engine.release()
    }

    /// Called by the platform when the app leaves the foreground. The weights are dropped, and a
    /// real-time assist does not survive the backgrounding.
    func enteredBackground() {
        engine.release()
        if observer == .realtimeSession { stopRealtime() }
    }

    /// The engine is loaded lazily, on the first turn the user actually asked for.
    func ensureEngineLoaded() -> Bool {
        if engine.isLoaded { return true }
        let candidates = popopxPlatformEngines(PopopxEcoFacts.now()) + [engine]
        guard let loaded = candidates.first(where: { $0.ensureLoaded() }) else { return false }
        engine = loaded
        return true
    }

    /// The messages the assistant may read for this turn: the typed message plus the preceding window.
    func contextWindow(all: [String], typed: String) -> [String] {
        switch observer {
        case .off: [typed]
        case .summonLastMessages: Array(all.suffix(Self.contextWindow)) + [typed]
        case .realtimeSession: Array(all.suffix(Self.contextWindow)) + [typed]
        }
    }
}

// ---------------------------------------------------------------- Bundled weights

/// Weights that passed verification, kept separate so an unverified buffer cannot reach the engine —
/// `PopopxVerifiedModel`.
final class PopopxVerifiedModel {
    let bytes: Data
    let engine: PopopxEdgeCopilotEngine

    init(bytes: Data, engine: PopopxEdgeCopilotEngine) {
        self.bytes = bytes
        self.engine = engine
    }
}

/// The digest check is not a performance concern dressed up as security. A `.cact` file is mmapped
/// tensor data that the engine then executes, so a tampered asset is the one input in this feature for
/// which "it parsed" is not evidence of anything. `PopopxNeedleAssets`.
enum PopopxNeedleAssets {
    /// SHA-256 of the `needle3.cact` that ships in this checkout, lowercase hex, **as measured on the
    /// file itself** (`shasum -a 256` over
    /// `apps/multiplatform/common/src/commonMain/resources/assets/needle3.cact`).
    /// An earlier revision of this port carried a different literal here, transcribed into the work
    /// instructions rather than measured; it matches no file in this checkout. The constant below is the
    /// value measured off the shipped bytes. A verifier that contradicted its own input would either block
    /// the model it ships or, relaxed to match, verify nothing.
    static let modelSha256 = "c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38"

    /// Where the bundle keeps it. `sounds` is a folder reference in the target, so a file dropped there
    /// is bundled verbatim with no project-file edit, which is the only reason the path works today.
    static let modelPath = "sounds/needle3.cact"

    /// Bytes the file must be, checked before it is hashed; a truncated copy hashes to something new.
    static let modelBytes = 35_335_380

    /// The two names the asset can be found under: inside the `sounds` folder reference, or flattened
    /// into the bundle root if the owner adds a discrete resource entry instead.
    static let resourceName = "needle3"
    static let resourceExtension = "cact"

    /// True when the platform can find the bundled weights and they are the expected length.
    static func bundledModelPresent() -> Bool {
        guard let url = bundledModelURL() else { return false }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return (values?.fileSize).map { $0 == Int(modelBytes) } ?? false
    }

    /// The bundle location of the weights, or nil. Checks the size before reading, so a truncated copy
    /// costs one stat instead of thirty-four megabytes.
    static func bundledModelURL() -> URL? {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) { return url }
        return Bundle.main.url(forResource: resourceName, withExtension: resourceExtension, subdirectory: "sounds")
    }

    /// The one entry point: read the asset, verify it, and hand the bytes to the engine. Returns nil —
    /// and the caller stays on the deterministic engine — when the file is absent, the wrong length, or
    /// does not digest to `modelSha256`.
    static func loadVerifiedModel() -> PopopxVerifiedModel? {
        guard let url = bundledModelURL(),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == Int64(modelBytes),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        var buffer = Data()
        // Streamed in megabyte slices: the whole point of the check is that this file is read on the way
        // to being executed, and a 34 MB `Data` copy on a phone in a chat thread is not free.
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            digest.update(data: chunk)
            buffer.append(chunk)
            if buffer.count > Int(modelBytes) { return nil }
        }
        let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == modelSha256, buffer.count == Int(modelBytes) else { return nil }
        return PopopxVerifiedModel(bytes: buffer, engine: PopopxNeedleEngine())
    }

    /// The hex digest of a buffer — `popopxSha256Hex`.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// ---------------------------------------------------------------- Cactus (DORMANT)
///
/// The path to `libcactus.a`. **It does nothing in this build.** Two independent things keep it off, and
/// both are deliberate:
///
/// 1. `popopxCactusEngineAllowed` below is `false`, so no engine ever asks the bridge to load weights.
/// 2. The C calls in `POPOPXChat/objc.m` are inside `#if POPPX_CACTUS_ENABLED`, which is not defined, so
///    `libcactus.a` is never linked and a missing static library cannot break the build.
///
/// The measured reason it is dormant, repeated here because this is where a future reader will look
/// before flipping it: the published base weights route **1 of 6** calendar intents correctly on this
/// host and produce no usable Chinese output, with three of the five tools never selected. Fine-tuning is
/// a separate project. Until that exists, the deterministic grammar above is the shipping engine, and it
/// is not a placeholder — it answers every intent the UI can ask about.
let popopxCactusEngineAllowed = false

/// `libcactus.a` behind the verification gate. `ensureLoaded` is the only place the weights are read, and
/// it reads them *through* `PopopxNeedleAssets`, so an unverified buffer has no route to the engine.
final class PopopxNeedleEngine: PopopxEdgeCopilotEngine {
    let kind: PopopxEcoEngineKind = .needle
    private(set) var isLoaded = false

    private var contextReady = false

    func ensureLoaded() -> Bool {
        guard popopxCactusEngineAllowed else { return false }
        guard PopopxCactusBridge.isCompiledIn() else { return false }
        if isLoaded { return contextReady }
        guard let model = PopopxNeedleAssets.loadVerifiedModel() else { return false }
        // The buffer reaches the C API only through `loadVerifiedModel`, which has already compared the
        // digest, so there is no route from an unverified asset to `cactus_load`.
        guard PopopxCactusBridge.loadModelData(model.bytes) else { return false }
        isLoaded = true
        contextReady = PopopxCactusBridge.begin(
            withSystemPrompt: popopxCactusSystemPrompt,
            toolsJson: popopxEcoToolsJson(),
            toolIndexPath: nil
        )
        return contextReady
    }

    func release() {
        guard isLoaded else { return }
        PopopxCactusBridge.reset()
        isLoaded = false
        contextReady = false
    }

    func parse(input: String, facts: PopopxEcoFacts) -> PopopxEcoEnvelope {
        guard isLoaded, contextReady else {
            return PopopxEcoEnvelope(calls: [], suppressed: [], confidence: nil, reasoning: nil, failure: "cactus engine unavailable")
        }
        guard let reply = PopopxCactusBridge.complete(input, maxNewTokens: 512) else {
            // The engine's own error string, so a silent turn is at least diagnosable from a screenshot.
            // `lastError` is an unannotated ObjC method, hence optional here; the bridge's own default is "" and
            // it is replaced by this literal so a nil tail cannot read as "the engine said nothing".
            return PopopxEcoEnvelope(
                calls: [], suppressed: [], confidence: nil, reasoning: nil,
                failure: "cactus produced no reply: \(PopopxCactusBridge.lastError() ?? "no error recorded")"
            )
        }
        return PopopxEcoEnvelope.fromEngineJson(reply)
    }
}

/// `system.txt` as shipped in the model drop, with the date line refreshed per turn by `facts`.
private let popopxCactusSystemPrompt = "date: today, locale en, device: phone"

/// `expect fun popopxPlatformEngines(facts): List<PopopxEdgeCopilotEngine>`, actualised for iOS.
///
/// The needle engine is first because `ensureEngineLoaded` takes the first candidate that loads, and the
/// deterministic engine is the fallback the state already holds. With `popopxCactusEngineAllowed` false the
/// needle never claims to load, so the deterministic engine always answers.
func popopxPlatformEngines(_ facts: PopopxEcoFacts) -> [PopopxEdgeCopilotEngine] { [PopopxNeedleEngine()] }

// ---------------------------------------------------------------- The turn

/// The calendar the assistant is allowed to see, as an interface the platform implements —
/// `PopopxEcoCalendarAccess`.
///
/// It is deliberately `PopopxRawCalendarEvent`-shaped rather than "give me free slots", because the
/// privacy rule needs a single place where titles, locations, attendees and notes exist: the events come
/// out of here, go through `PopopxCalendarPrivacy.busySlots`, and the result is the only thing the
/// assistant keeps. A platform that returned busy slots directly would be a nicer API and a worse
/// guarantee.
///
/// `@MainActor` because the iOS implementation talks to one `EKEventStore` instance, which is not
/// documented as safe to share across threads; serialising the reads costs nothing, since a turn is one
/// query over a day.
@MainActor
protocol PopopxEcoCalendarAccess: AnyObject {
    /// The raw rows of the window, from EventKit.
    func rawEvents(windowStartEpochMinutes: Int64, windowEndEpochMinutes: Int64) async -> [PopopxRawCalendarEvent]

    /// The store id of the event the user's words point at, or nil. Ids are the only handle a write may
    /// use, so an unresolved reference means no card rather than a wrong write.
    func resolveEventId(words: String, windowStartEpochMinutes: Int64, windowEndEpochMinutes: Int64) async -> String?

    /// Apply a confirmed change. The platform must refuse when `write` did not come from the gate.
    func apply(_ write: PopopxCalendarWrite) async -> Bool

    /// Whether the OS has granted the calendar permissions right now; false means the user is asked.
    func permissionsGranted() -> Bool

    /// Asks the OS for calendar access and reports whether it was granted. Kotlin declares no such
    /// method because the Android side requests at bind time; iOS has to be able to ask from the card,
    /// and the request is the only place a system prompt can appear in this feature.
    func requestPermissions() async -> Bool
}

/// What one assistant turn produced — `PopopxEcoReply`.
struct PopopxEcoReply {
    /// The sentence shown in the private bar; nil when the turn produced only a card.
    var text: String?
    /// Proposals waiting for the tap, empty for a turn that asked for nothing.
    var proposals: [PopopxEcoProposal] = []
    /// True when the bundled engine could not be loaded and the deterministic engine answered.
    var usedFallback = false
    /// The `node.dispatch_task` calls of this turn.
    ///
    /// Not in the Kotlin, which keeps `PopopxEcoMacNodeDispatcher` as a type the caller is expected to
    /// reach for and never actually reaches. Without it the dispatcher would be unreachable here too,
    /// because `onMessage` swallows the call into `PopopxCalendarPrivacy`'s reject path. Surfacing them
    /// costs one array and changes no decision: these still go only to a paired service offering the
    /// action, and they still cannot become a chat message.
    var computeTasks: [PopopxEcoCall] = []
}

/// The turn: read the calendar, drop it, plan, and hand back a card — `PopopxEcoAssistant`.
///
/// `@MainActor` is this platform's mutex. A turn queries a live calendar store, and two overlapping turns
/// — a summon while a real-time message arrives — would otherwise plan against two different snapshots,
/// so the user would see a card whose free slot had already been filled by the other turn's confirmation.
/// A turn is milliseconds of in-memory work plus one query, so serializing them costs nothing the user
/// can feel.
@MainActor
final class PopopxEcoAssistant {
    static let shared = PopopxEcoAssistant()

    let state = PopopxEcoAssistantState()
    private let gate = PopopxEcoConfirmGate()

    var pendingProposals: [PopopxEcoConfirmGate.Pending] { gate.proposals }

    /// The confirm tap; the write is what the platform applies, and nil means there was nothing to apply.
    func confirm(id: Int, calendar: PopopxEcoCalendarAccess) async -> Bool {
        let facts = PopopxEcoFacts.now()
        guard let write = gate.confirm(id: id, nowEpochMinutes: facts.now.epochMinutes) else { return false }
        return await calendar.apply(write)
    }

    func dismiss(id: Int) { gate.dismiss(id: id) }

    /// One turn of the assistant.
    ///
    /// `PopopxCalendarPrivacy.busySlots` is called once, immediately, and its input is an expression that
    /// is never named — after that line nothing in this class can reach a title, a location, an attendee
    /// or a note again, because the only value kept is the list of numbers.
    func onMessage(
        _ text: String,
        history: [String],
        calendar: PopopxEcoCalendarAccess,
        preferences: PopopxTimePreferences = .defaults
    ) async -> PopopxEcoReply {
        let facts = PopopxEcoFacts.now()
        let windowStart = facts.now.epochMinutes
        let windowEnd = windowStart + Int64(facts.defaultWindowHours) * PopopxTimePreferences.dayMinutes
        let loaded = state.ensureEngineLoaded()
        let envelope = state.engine.parse(input: state.contextWindow(all: history, typed: text).joined(separator: "\n"), facts: facts)

        let busy = PopopxCalendarPrivacy.busySlots(
            events: await calendar.rawEvents(windowStartEpochMinutes: windowStart, windowEndEpochMinutes: windowEnd),
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        var answer: String?
        var proposals: [PopopxEcoProposal] = []
        var computeTasks: [PopopxEcoCall] = []
        for call in envelope.suggestions() {
            // A compute task is not a calendar change, so it is diverted before the planner rather than
            // rejected by it; the planner's 「a compute task is not a calendar change」 path stays exactly
            // as the Kotlin wrote it for any caller that hands it one anyway.
            if case .dispatchTask = call {
                computeTasks.append(call)
                continue
            }
            switch PopopxEcoPlanner.plan(call, facts: facts, busy: busy) {
            case .answer(let text): answer = text
            case .reject: break
            case .card(let proposal, _), .conflict(let proposal, _):
                if let resolved = await proposal.withResolvedRef(calendar: calendar, windowStart: windowStart, windowEnd: windowEnd) {
                    proposals.append(resolved)
                }
            }
        }
        proposals.forEach { _ = gate.propose($0, nowEpochMinutes: facts.now.epochMinutes) }

        return PopopxEcoReply(
            text: answer ?? (proposals.isEmpty && computeTasks.isEmpty && !envelope.isEmpty ? envelope.reasoning : nil),
            proposals: proposals,
            usedFallback: !loaded || state.engine.kind == .deterministic,
            computeTasks: computeTasks
        )
    }

    /// Called by the platform when the app leaves the foreground.
    func enteredBackground() {
        state.enteredBackground()
        gate.expireAll()
    }

    /// The two opt-ins the user can see; nothing else in the app may call this.
    func observe(sessionId: String, mode: PopopxEcoObserverMode) {
        switch mode {
        case .off: state.stopRealtime()
        case .summonLastMessages: state.summon(sessionId: sessionId)
        case .realtimeSession: state.toggleRealtime(sessionId: sessionId)
        }
    }

    var liveIndicatorVisible: Bool { state.showsLiveIndicator }

    func permissionsNeeded(_ calendar: PopopxEcoCalendarAccess) -> Bool { !calendar.permissionsGranted() }

    /// Requests the OS permission. Returns whether the calendar may be read now.
    func requestPermissions(_ calendar: PopopxEcoCalendarAccess) async -> Bool {
        await calendar.requestPermissions()
    }
}

// ---------------------------------------------------------------- Mac node dispatch

/// `node.dispatch_task` against the transport the app already has — `PopopxEcoMacNodeDispatcher`.
///
/// A node command travels as an invisible text to a paired service account (`PopopxNodeCmd`), so the
/// assistant may not invent either end of it: the service must be one the user has paired, and the action
/// must be one that service's own menu offers (`PopopxNodeServiceId.menuActions`), which is the set the
/// host accepts. Anything else is refused here, before a sender is consulted, so "the model named a
/// service" can never become "the app sent a message to an account".
///
/// This is also why the payload is fixed at `{}`: the engine's `payload_ref` is a *local* file reference,
/// and the host documents that it cannot know offline which token is meaningful, so a reference is never
/// turned into content and never leaves the device.
@MainActor
final class PopopxEcoMacNodeDispatcher {
    /// What the user sees: the refusal is a sentence, and a nil is not.
    enum Result {
        /// The command was accepted by the transport, which is the pair's encrypted queue.
        case queued(PopopxNodeCmd)
        case rejected(reason: String)
    }

    private let pairedServices: () -> [PopopxNodeServiceId]
    private let send: (PopopxNodeCmd) async -> Bool

    /// Both defaults refuse, which is Kotlin's `send: (PopopxNodeCommand) -> Boolean = { false }` and the
    /// reason an unpaired device cannot dispatch even if a caller forgets to wire the transport. The app
    /// injects the real closures in `PopopxCopilotModel`, so this type needs no dependency on
    /// `DiscoverSubscriptionManager` and the two files stay independent.
    init(
        pairedServices: @escaping () -> [PopopxNodeServiceId] = { [] },
        send: ((PopopxNodeCmd) async -> Bool)? = nil
    ) {
        self.pairedServices = pairedServices
        self.send = send ?? { _ in false }
    }

    func dispatch(_ task: PopopxEcoCall) async -> Result {
        guard case .dispatchTask = task else { return .rejected(reason: "not a dispatch call") }
        guard let service = task.dispatchService else { return .rejected(reason: "no Mac Node service was named") }
        guard let action = task.dispatchAction else { return .rejected(reason: "no Mac Node action was named") }
        let paired = pairedServices()
        guard paired.contains(service) else { return .rejected(reason: "\(service.rawValue) is not paired on this device") }
        guard service.menuActions.contains(where: { $0.action == action }) else {
            return .rejected(reason: "\(action) is not an action \(service.rawValue) offers")
        }
        let command = PopopxNodeCmd(serviceId: service, action: action, payload: "{}")
        guard PopopxNodeWire.isAccepted(command) else { return .rejected(reason: "the command is longer than the node accepts") }
        return await send(command) ? .queued(command) : .rejected(reason: "the node is not reachable right now")
    }
}
