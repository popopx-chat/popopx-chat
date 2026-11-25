//
//  PopopxInputBar.swift
//  POPOPX (iOS)
//
//  [Phase 5 · conversation input bar] A frosted-glass-backed pop-up input bar + the "smart routing" seam.
//
//  This is a **host-owned** layer, not a replacement for `ComposeView`. Today the conversation page hangs the composer
//  on it at `Shared/Views/Chat/ChatView.swift:237`-`:245`, with 7 arguments actually passed (`chat`, `im`,
//  `$composeState`、`$showCommandsMenu`、`$keyboardVisible`、`$keyboardHiddenDate`、`$selectedRange`），
//  while `ComposeView.swift` is 2732 lines and the `Shared/Views/Chat/ComposeMessage/` directory holds 13 files in total;
//  the real text field is `NativeTextEditor` (`SendMessageView.swift:67`, the struct at :16, built by
//  `ComposeView.swift:1160 sendMessageView(_:placeholder:sendToConnect:)`). In multi-selection mode the conversation page
//  also swaps it for `SelectedItemsBottomToolbar` (`ChatView.swift:247`). So this file:
//  ① neither imports nor rewrites `ComposeState`, it only takes the values the host folded in; ② changes no existing initializer;
//  ③ hands every side effect out through closures. **"Replace it or mount it alongside" is for a human to rule on; this bar can serve either.**
//
//  ── The five wires the host must connect ────────────────────────────────────────────────────────────
//  1. `text`: the host's own draft binding (`composeState.message` works too).
//  2. `context`: fold the nine preconditions of `ComposeState` into a `PopopxComposerContext` (see the field comments of that struct,
//     matching `ComposeView.swift:1324` mentions, the four `:1323` contextItem branches and the three `:1317-1322` preview branches).
//  3. `ttlSeconds` / `onTTLChange`: view-once. **The true value lives with the host**; this bar only reads and reports, it keeps no second copy.
//  4. `onSend`: receives a `PopopxComposerSend` whose `dispatch` has already picked the branch:
//     · `.routeViaMesh(message)` → the host runs `await PopopxMeshRuntime.shared.router.send(message)`
//       (`PopopxMeshKit/…/Router/PopopxMessageRouter.swift:630`); the returned `PopopxRoutedMessage`
//       (:244) is handed to module 7's timeline; this bar **sends nothing itself** and never touches `router.start()`/`stop()` — that is the fuse's
//       business (`Shared/Model/POPOPXAPI.swift:3818` registers the router into killSwitch).
//     · `.hostShouldSend(reason)` → the host takes the original chain (`ComposeView.swift:2193 sendMessage(ttl:sign:)` →
//       `:2202 sendMessageAsync` → `:2231 send(.text…)` → `:2259`/`:2419 send(_ msgs:)` →
//       `apiSendMessages`（`POPOPXAPI.swift:588`）→ `processSendMessageCmd`（:593）→ `chatApiSendCmd`）。
//  5. Keyboard avoidance, the safe area and `keyboardVisible` belong to the host: this bar only draws its own strip and reads no screen constants.
//
//  ── Why the `hostShouldSend` branch must exist (TTL / sign limits, red-line-grade facts)────────────
//  Module 5's public-network leg **is the app's own send**: `PopopxSMPSendRequest` (`PopopxMessageRouter.swift:39`) has only
//  the four fields `messageId / contactId / text / sentAt`, and the app-side implementation composes `.text(request.text)` into a
//  `ComposedMessage`, then calls `apiSendMessages(type: .direct, id: contactId, …)` and does its own `addChatItem`
//  (`POPOPXAPI.swift:3467`-`:3480`). So routing a plain-text direct chat message **does not fork a second network line**;
//  but that leg carries **neither `ttl` nor `sign`** (those two `apiSendMessages` parameters are at `POPOPXAPI.swift:588`),
//  and supports only the contactId of `.direct`. So "hand everything to the router" would silently drop view-once, signatures, group scope, quotes,
//  attachments, @mentions and live messages. That limit is therefore written into the decision table instead of being hidden in view code.
//
//  ── Decision table (`PopopxComposerRouting.dispatch`, pure function, unit-testable)───────────────────────
//  | input | verdict | why |
//  |---|---|---|
//  | draft all whitespace and no attachment carried | `.ignoreEmptyDraft` | neither sends nor hands back, so the host is never called twice; an empty text box that carries an attachment is still sent (`.richContent` → hand back to the host) |
//  | `ttlSeconds != nil` | `.hostShouldSend(.timedMessage)` | the routed leg carries no ttl, so view-once would be dropped |
//  | `requiresSignature` | `.hostShouldSend(.signedMessage)` | same as above, the leg has no sign |
//  | not a direct-chat contact (group / this device's notes / pending acceptance / invalid / not active) | `.hostShouldSend(.notDirectContact)` | of `PopopxRouteTarget` (:102) only `.contactId` can be written to by the public network; a group's scope/sendAsGroup has no place in the request body |
//  | quote / edit / forward / report | `.hostShouldSend(.quotedOrEditing)` | none of these live in the `.text` message |
//  | attachment / link preview / @mention / live | `.hostShouldSend(.richContent)` | same as above |
//  | Cabin master fuse off | `.hostShouldSend(.meshFuseOff)` | the whole mesh is switched off, so a message should not be handed to the mesh router |
//  | binding table not read to the end yet | `.hostShouldSend(.bindingUnknown)` | do not guess the channel on the user's behalf |
//  | no Cabin binding | `.hostShouldSend(.contactNotBoundToMesh)` | the router would only conclude `.notBound` and fall back to SMP, one hop wasted |
//  | radio unavailable | `.hostShouldSend(.radioUnavailable)` | same as above: with `.radioUnavailable` there is no mesh to send over |
//  | neighbour out of window | `.hostShouldSend(.peerOutOfRange)` | the only thing that can still carry it is the host's SMP line |
//  | none of the above holds: plain text + direct chat + bound + radio on + neighbour reachable | `.routeViaMesh(message)` | at this moment the mesh really can carry it, and only module 5 knows "retransmit concurrently when the public network does not ACK within 3 seconds", "reroute by the original id when delivery fails", "enter the offline fallback queue when both lines are down" |
//
//  ── Channel colours (`Docs/popopx-brand-spec.md` §1.1; inside one control indigo and teal are never both present as equals)──────
//  `PopopxComposerChannel` picks one of three: `.smp` = `brand` + `lock.shield.fill`; `.mesh` = `mesh` background +
//  `onMesh` text (hairline teal used as text has to be drawn with `meshInk`); `.undetermined` = `labelSecondary` grey and **no icon at all**.
//  The grey `clock` means only Cabin relay backlog (`Awaiting relay: N`, the number comes from `router.pendingMessageCount`,
//  `PopopxMessageRouter.swift:863`). Here view-once has words but no glyph: the chat-bubble side already owns
//  the `timer` symbol (`Shared/Views/Chat/ChatItem/CIMetaView.swift:135`), so this bar does not claim a second meaning for it.
//  Green never appears on this bar — it is a one-shot acknowledgement colour.
//  The only accent colour that appears in the "+" panel is indigo's "selected" state (reusing `PopopxCheckbox`'s own tint); no teal appears inside the panel.
//
//  ── When mesh facts are read (no per-keystroke, per-line await allowed)────────────────────────────────────────
//  `PopopxInputBarModel.refresh(contactId:)` reads four things in one batch: `IdentityMappingStore
//  .meshPublicKeyHexes(forContactId:)`（`Identity/IdentityMappingStore.swift:185`）、
//  `PopopxBluetoothHealthJudge`'s `radioState` and `isPeerReachable` (`PopopxMessageRouter.swift:391`,
//  the order of those checks is aligned line by line with module 5's own `predictBluetooth` (:1054-:1063), and the timeout is likewise taken from
//  `PopopxMeshConfig.default.peerReachabilityTimeout`), plus `NetworkStateMonitor.shared.currentPath()`
//  (`Router/NetworkStateMonitor.swift:365`, nil = not reported yet, **never guessed as "online"**). The result is cached as a
//  `PopopxMeshEligibility` value; refresh moments = opening the conversation + the master fuse flipping + one hop every 5 seconds (the hop count is read
//  from the already observed `PopopxMeshStateSource.state` synchronously, which produces no hop).
//
//  All design values come from Shared/Theme/PopopxTheme.swift and the controls from Shared/Components/; this file has no bare colour values,
//  no AppTheme styles, no home-grown button styles, and no bare `UIScreen` constants.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand (the iron rule forbids scripts from touching project.pbxproj).
//

import Combine
import SwiftUI
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - Send preconditions folded in by the host

/// All preconditions of "what this line is about to send" other than the text.
///
/// Deliberately not a wrapper around `ComposeState`: that struct (`ComposeView.swift:47`) carries `parsedMessage`,
/// `preview`, `contextItem`, `voiceMessageRecordingState` and a whole set of things only the old composer understands,
/// while this bar only wants to know "can this be handed to module 5".
struct PopopxComposerContext: Hashable {
    /// The SMP address of the direct-chat contact. `nil` = this conversation has no contactId (group / this device's notes / a contact pending acceptance / invalid data).
    var contactId: Int64?
    /// `ChatInfo.direct(contact:)` with the contact `active` (`POPOPXChat/ChatTypes.swift:1995`) —
    /// only this kind of conversation has a queue on the server that can be written to.
    var isDirectContact = false
    /// The draft carries an attachment (image / file / voice / multimedia).
    var hasAttachments = false
    /// `composeState.preview != .noPreview` (`ComposeView.swift:1317-1322`): a link preview is part of the message body too.
    var hasLinkPreview = false
    /// `contextItem` is one of the four branches quoted / editing / forwarding / reported (`ComposeView.swift:1323`).
    var carriesContextItem = false
    /// `composeState.memberMentions` is not empty (`ComposeView.swift:1324`).
    var hasMentions = false
    /// Live message (live), `ComposeView.swift:1325`.
    var isLiveMessage = false
    /// A signature is required, `ComposeView.swift:1326` (the true value comes from `groupInfo?.useRelays`, the signing action itself is the `send(…sign:)` at `:2410`).
    var requiresSignature = false

    /// The most frequently used case: an active direct-chat contact, plain text, no TTL, no signature.
    static func directContact(_ contactId: Int64) -> PopopxComposerContext {
        var context = PopopxComposerContext()
        context.contactId = contactId
        context.isDirectContact = true
        return context
    }

    /// The conversation is not an active direct chat (group, this device's notes, a contact pending acceptance, data that cannot be read).
    static let outsideDirectContact = PopopxComposerContext()
}

// MARK: - A snapshot of the mesh facts

/// The mesh facts read in one batch. A value type: the decision table only reads it, and the view never awaits it on the render path.
struct PopopxMeshEligibility: Equatable {
    /// The Cabin master fuse (`PopopxMeshRuntime.isFuseOn`, `POPOPXAPI.swift:3740`).
    var fuseOn = false
    /// Whether the binding table has been read to the end. While it has not, any channel conclusion is premature.
    var bindingLoaded = false
    /// This contact's Cabin public key (with several bindings the first one is taken, the same choice module 5's `resolveBinding` makes).
    var meshPublicKeyHex: String?
    /// This device's radio, module 4's conclusion.
    var radioState: PopopxBluetoothState = .unknown
    /// The advance prediction — the conclusion of the same rule module 5's `predictBluetooth` uses.
    var prediction: PopopxBluetoothPrediction = .notBound
    /// The public network: `true` connected, `false` disconnected, `nil` = `NWPathMonitor` has not reported yet (module 5 does not guess "online" either).
    var networkConnected: Bool?
    /// The number of messages already in the offline fallback queue that have not received an ACK — the only data source of the grey `clock`.
    var queuedCount = 0

    /// Whether Bluetooth can carry a message away at this moment.
    var isMeshCapable: Bool {
        if case .reachable = prediction { return true }
        return false
    }

    /// The neighbour public key the prediction names (carried by both `.reachable` and `.peerOutOfRange`, `peerKey` at :211).
    var reachableMeshKey: String? { prediction.peerKey }

    static let notLoaded = PopopxMeshEligibility()
}

// MARK: - The verdict

/// The reasons for handing back to the host. Each one corresponds to a parameter genuinely missing on module 5's public-network leg, or to a real mesh fact.
enum PopopxHostSendReason: Hashable {
    /// View-once: the `ttl` of `apiSendMessages` (`POPOPXAPI.swift:588`) has no place in `PopopxSMPSendRequest`.
    case timedMessage(seconds: Int)
    /// Signed message: same as above, the leg carries no `sign`.
    case signedMessage
    /// Not an active direct-chat contact: only the one address `.contactId` can be written to by the public network.
    case notDirectContact
    /// Quote / edit / forward / report.
    case quotedOrEditing
    /// Attachment / link preview / @mention / live message.
    case richContent
    /// The Cabin master fuse is off.
    case meshFuseOff
    /// The binding table has not been read to the end yet.
    case bindingUnknown
    /// This contact has no Cabin binding.
    case contactNotBoundToMesh
    /// This device's radio is unavailable.
    case radioUnavailable(PopopxBluetoothState)
    /// Bound, but no neighbour has been heard inside the 15-second window.
    case peerOutOfRange

    /// Only the two the user can make sense of come with an explanation; the rest are internal conclusions and do not disturb them.
    ///
    /// `NSLocalizedString` is used here deliberately instead of `Text("…")`: `explanation` returns `String?`,
    /// the host (`ProfileAutoSender.meshBlockText`) takes it away as a plain string, and it lands on the `Text(verbatim:)` side.
    /// The keys are still the English source sentences, the same table as the app-wide `Text("Send")` convention.
    var explanation: String? {
        switch self {
        case let .timedMessage(seconds):
            return String(
                format: NSLocalizedString("Burn after reading · %@", comment: "composer channel strip"),
                PopopxComposerRouting.durationText(seconds)
            )
        case .richContent: return NSLocalizedString("Attachments and previews do not go over Bluetooth Mesh", comment: "composer channel strip")
        case .quotedOrEditing: return NSLocalizedString("Quotes and edits do not go over Bluetooth Mesh", comment: "composer channel strip")
        case .signedMessage: return NSLocalizedString("Signed messages do not go over Bluetooth Mesh", comment: "composer channel strip")
        case .meshFuseOff, .bindingUnknown, .contactNotBoundToMesh, .radioUnavailable, .peerOutOfRange, .notDirectContact:
            return nil
        }
    }
}

/// Who a send ultimately belongs to. This enum is the "seam" itself: verdicts are kept apart from side effects, and the verdict is unit-testable.
enum PopopxComposerDispatch: Hashable {
    /// Handed to module 5: the host runs `await router.send(message)` (`PopopxMessageRouter.swift:630`).
    case routeViaMesh(PopopxOutboundMessage)
    /// Handed back to the host unchanged, with the reason why it cannot be routed.
    case hostShouldSend(reason: PopopxHostSendReason)
    /// Empty draft: nothing happens.
    case ignoreEmptyDraft

    var isRouted: Bool {
        if case .routeViaMesh = self { return true }
        return false
    }

    /// The reason for handing back to the host; nil for the other two cases.
    var hostReason: PopopxHostSendReason? {
        if case let .hostShouldSend(reason) = self { return reason }
        return nil
    }
}

/// Which channel will carry the next message away — the only source of the send key's accent colour.
enum PopopxComposerChannel: Hashable {
    /// Public-network SMP (indigo).
    case smp
    /// Cabin Bluetooth (teal). `hops` is the hop count the mesh measured, nil = the hop count is not known yet.
    case mesh(hops: Int?)
    /// The public-network state has not been reported and Bluetooth is already a candidate — no guessing on the user's behalf.
    case undetermined
}

/// The payload of `onSend`: the verdict plus the preconditions at the moment of the verdict, so the host can reproduce this conclusion exactly.
struct PopopxComposerSend: Hashable {
    let text: String
    let context: PopopxComposerContext
    let ttlSeconds: Int?
    /// The top-secret tier's on-screen dwell time in seconds; nil = this is not a top-secret message.
    ///
    /// and `ttlSeconds` **are two independent values that must not be merged**: that field is "how long until the message disappears from the server" on the SMP side,
    /// this one is "how long plaintext is allowed to stay on the recipient's screen". They are enforced by different modules and can be on at the same time
    /// (a message that is both view-once over the public network and view-once on screen is a legitimate combination).
    /// In the payload file, `PopopxSecureCopy.ttlOptions` refusing to reuse `durationOptions` is the same reason seen from the other side.
    let secureTTLSeconds: Int?
    let dispatch: PopopxComposerDispatch
    let channel: PopopxComposerChannel

    init(
        text: String,
        context: PopopxComposerContext,
        ttlSeconds: Int?,
        secureTTLSeconds: Int? = nil,
        dispatch: PopopxComposerDispatch,
        channel: PopopxComposerChannel
    ) {
        self.text = text
        self.context = context
        self.ttlSeconds = ttlSeconds
        self.secureTTLSeconds = secureTTLSeconds
        self.dispatch = dispatch
        self.channel = channel
    }
}

/// Duration tiers must be drawable by the same row of chips: view-once and top-secret use the same control, only the data and the landing point differ.
/// The two types each stay in their own file (`PopopxComposerDurationOption` in this file,
/// `PopopxSecureTTLOption` in the top-secret payload file); this protocol is their only intersection.
protocol PopopxDurationOption {
    var seconds: Int { get }
    var title: String { get }
}

extension PopopxComposerDurationOption: PopopxDurationOption {}
extension PopopxSecureTTLOption: PopopxDurationOption {}

/// A row of duration chips. Moved out of `disappearingBlock` verbatim (every modifier unchanged),
/// so that the top-secret tier does not have to be copied a second time — two rows of chips looking different is the harder bug to track down.
private struct PopopxDurationChips<Option>: View where Option: PopopxDurationOption & Identifiable {
    let options: [Option]
    let selectedSeconds: Int
    /// `LocalizedStringKey` rather than `String`: this field is a VoiceOver label, and a bare `String` does not enter the localisation tables.
    let label: LocalizedStringKey
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            ForEach(options) { option in
                let isSelected = selectedSeconds == option.seconds
                Button {
                    PopopxHaptics.selection()
                    onSelect(option.seconds)
                } label: {
                    // `title`'s protocol signature is `String` (the top-secret tier in the payload file uses it too),
                    // so it is looked up explicitly as a key here; a miss just shows it verbatim, the same behaviour as before the change.
                    Text(LocalizedStringKey(option.title))
                        .font(PopopxType.meta)
                        .foregroundStyle(isSelected ? PopopxPalette.onBrand : PopopxPalette.labelSecondary)
                        .lineLimit(1)
                        .frame(minWidth: PopopxMetrics.space2XL, minHeight: PopopxMetrics.minHitTarget)
                        .background(
                            isSelected ? PopopxPalette.brand : Color.clear,
                            in: .rect(cornerRadius: PopopxMetrics.radiusChip)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: PopopxMetrics.radiusChip)
                                .strokeBorder(
                                    isSelected ? Color.clear : PopopxPalette.labelHint,
                                    lineWidth: PopopxMetrics.hairline
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(PopopxPressButtonStyle(feedback: nil))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: PopopxMetrics.spaceXS)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}

/// One view-once tier. Made a struct rather than a labelled tuple: the key path of `ForEach(…, id: \.seconds)` cannot reach tuple members.
struct PopopxComposerDurationOption: Hashable, Identifiable {
    let seconds: Int
    let title: String

    var id: Int { seconds }
}

// MARK: - The decision table (pure function)

/// No state, no side effects: the entire decision table lives here, and the view only draws it.
enum PopopxComposerRouting {
    /// The view-once tiers, identical to the three tiers in the old composer's send-key menu (`SendMessageView.swift:199`-`:201`).
    static let durationOptions: [PopopxComposerDurationOption] = [
        .init(seconds: 30, title: "30 seconds"),
        .init(seconds: 60, title: "1 minute"),
        .init(seconds: 300, title: "5 minutes")
    ]

    /// The default tier when the host has never chosen one, taken straight from the persisted value the app already has (`SettingsView.swift:230`).
    static var fallbackDurationSeconds: Int {
        customDisappearingMessageTimeDefault.get()
    }

    /// The duration phrase. It returns `String` (taken away by `explanation` and by the host), so the table is queried with `NSLocalizedString`
    /// + `String(format:)` here, not the implicit key of `Text("…")`. The order of `%@`/`%lld` matches the whole table.
    static func durationText(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return String(format: NSLocalizedString("%lld days", comment: "composer duration"), seconds / 86_400) }
        if seconds % 3_600 == 0 { return String(format: NSLocalizedString("%lld hours", comment: "composer duration"), seconds / 3_600) }
        if seconds % 60 == 0 { return String(format: NSLocalizedString("%lld minutes", comment: "composer duration"), seconds / 60) }
        return String(format: NSLocalizedString("%lld seconds", comment: "composer duration"), seconds)
    }

    /// The core of the decision table: whether this draft can be handed to module 5 at this moment. `nil` = it can.
    ///
    /// Its separation from `dispatch` has a reason: the channel strip asks this on every redraw, while minting a `messageId` should only happen
    /// When a message is really being handed off.
    static func hostReason(
        context: PopopxComposerContext,
        eligibility: PopopxMeshEligibility,
        ttlSeconds: Int?
    ) -> PopopxHostSendReason? {
        if let ttlSeconds {
            return .timedMessage(seconds: ttlSeconds)
        }
        if context.requiresSignature {
            return .signedMessage
        }
        guard context.isDirectContact, context.contactId != nil else {
            return .notDirectContact
        }
        if context.carriesContextItem {
            return .quotedOrEditing
        }
        if context.hasAttachments || context.hasLinkPreview || context.hasMentions || context.isLiveMessage {
            return .richContent
        }
        guard eligibility.fuseOn else {
            return .meshFuseOff
        }
        guard eligibility.bindingLoaded else {
            return .bindingUnknown
        }
        switch eligibility.prediction {
        case .notBound: return .contactNotBoundToMesh
        case let .radioUnavailable(state): return .radioUnavailable(state)
        case .peerOutOfRange: return .peerOutOfRange
        case .reachable: return nil
        }
    }

    /// the verdict. **The order is meaningful**: first rule out the cases where "the router silently drops things" (TTL, signing, non-direct chat, rich content),
    /// then look at the mesh facts themselves. Reversing the order would let a view-once message enter the mesh queue first.
    static func dispatch(
        text: String,
        context: PopopxComposerContext,
        eligibility: PopopxMeshEligibility,
        ttlSeconds: Int?,
        messageId: String = PopopxOutboundMessage.newMessageId()
    ) -> PopopxComposerDispatch {
        let blankDraft = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // An empty draft is not the same as "nothing to send": a draft carrying an attachment (image / file / voice) has an empty text box by nature,
        // while the old path's `ComposeState.sendEnabled` returns true for every one of these. Ignoring them across the board would mean
        // that this seam can never send an attachment without text.
        if blankDraft && !context.hasAttachments {
            return .ignoreEmptyDraft
        }
        if let reason = hostReason(context: context, eligibility: eligibility, ttlSeconds: ttlSeconds) {
            return .hostShouldSend(reason: reason)
        }
        // `hostReason` has already confirmed contactId is non-empty; this only unwraps the optional value, it is not a new branch.
        guard let contactId = context.contactId else {
            return .hostShouldSend(reason: .notDirectContact)
        }
        return .routeViaMesh(
            PopopxOutboundMessage(
                messageId: messageId,
                target: .contactId(contactId),
                text: text
            )
        )
    }

    /// The channel verdict. Note that it is wider than `dispatch`: with an empty draft it still has to answer "which route would a send right now take",
    /// because that information is a state, not a verdict about one particular message.
    static func channel(eligibility: PopopxMeshEligibility, ttlSeconds: Int?, hops: Int?) -> PopopxComposerChannel {
        guard ttlSeconds == nil, eligibility.fuseOn, eligibility.isMeshCapable else { return .smp }
        switch eligibility.networkConnected {
        case true: return .smp
        case false: return .mesh(hops: hops)
        case nil: return .undetermined
        }
    }
}

// MARK: - Batch reading the mesh facts

/// The input bar's state layer: it does only two things - read the mesh facts once in a batch and cache them, and hand the conclusion to the decision table.
///
/// Testability lives here: replacing `resolver` with a closure lets you feed any snapshot, with no radio, no session and no router needed.
@MainActor
final class PopopxInputBarModel: ObservableObject {
    /// The one cached copy of the mesh facts.
    @Published private(set) var eligibility = PopopxMeshEligibility.notLoaded
    /// Whether the table is being read (used only to draw "channel pending"; it takes no part in the verdict - the verdict looks at `bindingLoaded`).
    @Published private(set) var isResolving = false

    /// Injection point. `nil` = use the real runtime (`resolveFromRuntime`).
    var resolver: (@MainActor (Int64?) async -> PopopxMeshEligibility)?

    /// One tick every 5 s, only so that "a neighbour has gone quiet past the window" fades away on its own; the same cadence as the message list page
    /// （`Shared/Features/Chats/ChatsListView.swift:187`、`:502`）。
    static let pollIntervalSeconds: Double = 5

    func refresh(contactId: Int64?) async {
        isResolving = true
        let next: PopopxMeshEligibility
        if let resolver {
            next = await resolver(contactId)
        } else {
            next = await Self.resolveFromRuntime(contactId: contactId)
        }
        eligibility = next
        isResolving = false
    }

    /// Refreshes repeatedly until this `Task` is cancelled (session switched, master kill switch flipped, input bar left the screen).
    func poll(contactId: Int64?) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
            guard !Task.isCancelled else { break }
            await refresh(contactId: contactId)
        }
    }

    /// One batched read, four hops at most, happening only when the session opens and on the 5 s tick - never on the keypress path.
    ///
    /// The ordering of the verdicts copies module 5's `predictBluetooth` (`PopopxMessageRouter.swift:1054`-`:1063`) exactly:
    /// no binding → `.notBound`; radio unavailable → `.radioUnavailable`; ask reachability one by one and stop at the first one that is really reachable;
    /// all unreachable → `.peerOutOfRange(first)`. It also uses **the same judge and the same timeout**,
    /// so this seam's conclusion cannot tell a different story from the router's own conclusion.
    static func resolveFromRuntime(contactId: Int64?) async -> PopopxMeshEligibility {
        let runtime = PopopxMeshRuntime.shared
        var snapshot = PopopxMeshEligibility()
        snapshot.fuseOn = runtime.isFuseOn
        guard runtime.isFuseOn, let contactId else {
            // Master switch off, or this session has no contact: the binding table is not read and `bindingLoaded` stays false.
            return snapshot
        }
        let judge = PopopxBluetoothHealthJudge(monitor: runtime.healthMonitor)
        let hexes = await runtime.mappingStore.meshPublicKeyHexes(forContactId: contactId)
        snapshot.bindingLoaded = true
        snapshot.meshPublicKeyHex = hexes.first
        let radio = await judge.radioState
        snapshot.radioState = radio
        if hexes.isEmpty {
            snapshot.prediction = .notBound
        } else if !radio.isUsable {
            snapshot.prediction = .radioUnavailable(radio)
        } else {
            var answer = PopopxBluetoothPrediction.peerOutOfRange(peerMeshPublicKeyHex: hexes[0])
            let timeout = PopopxMeshConfig.default.peerReachabilityTimeout
            for hex in hexes where await judge.isPeerReachable(publicKey: hex, timeout: timeout) {
                answer = .reachable(peerMeshPublicKeyHex: hex)
                break
            }
            snapshot.prediction = answer
        }
        // nil is left exactly as it is: that means "not reported yet", not "disconnected".
        snapshot.networkConnected = await NetworkStateMonitor.shared.currentPath()?.isConnected
        snapshot.queuedCount = await runtime.router.pendingMessageCount
        return snapshot
    }
}

// MARK: - Actions of the "+" panel

/// A cell in the WeChat-style function panel. This bar is only responsible for "which one was pressed"; the implementation is entirely in the host.
enum PopopxPlusAction: String, CaseIterable, Identifiable {
    case photo
    case camera
    case file
    case location
    /// The top-secret cell is an **arm switch**, not a picker: it marks this draft as top-secret, and the duration is tuned on the row of chips in that same panel.
    /// So it differs from the other four cells - pressing it does not close the panel (see the one `action != .secure` inside `plusPanel`).
    case secure
    /// The encrypted profile cell is a **send entry**, in the same family as `.location`: pressing it closes the panel and the host presents this send's
    /// mode confirmation sheet (`ProfileSendModeSheet`); the panel itself carries no duration - the profile's duration is a property of "this send",
    /// not of this draft, so it cannot be built as a standing arm switch the way `.secure` is.
    case personalProfile
    /// Compute-point red packet: pressing it closes the panel and the host presents `PopopxSendRedPacketSheet`. It holds in both direct chats and groups,
    /// because the destination is supplied by the session itself (`PopopxPacketDestination` computes it from `ChatInfo`), and the cap on the share count follows the member count.
    case redPacket
    /// Badge gift card: pressing it closes the panel and the host presents `PopopxGiftBadgeCardSheet(contactId:)`.
    /// **Only direct chats should show this cell** - the gift card's redemption receipt travels over the direct-chat connection, and groups and channels have no matching destination,
    /// so the host filters it out with `plusActions` instead of putting up a button that can only report an error (see that parameter in init).
    case giftCard
    /// Compute-credit gift card: pressing it closes the panel and the host presents `PopopxCreditsStoreView(contactId:)` on its gift segment,
    /// where the user picks one of the cards this device holds and the card face grows a "send in this conversation" button.
    /// **Direct chats only**, for the same reason as `.giftCard`: the credit redemption receipt travels over the direct-chat connection,
    /// and a group has no destination for it.
    ///
    /// It opens the credits page instead of a dedicated picker on purpose: the unused-card list, the mint and the code face all already
    /// live there, and a second picker would be a second place that has to keep agreeing with `PopopxP2PVoucherVault` about which cards exist.
    case creditsGiftCard

    var id: String { rawValue }

    /// The caption of a "+" panel cell. Its type is `LocalizedStringKey` rather than `String`: a bare `String` going into `Text`
    /// does not consult the table, so an English locale would leak Chinese straight through. The English source sentence is the key; the existing translations are looked up in the 16 tables.
    var title: LocalizedStringKey {
        switch self {
        case .photo: return "Album"
        case .camera: return "Camera"
        case .file: return "Files"
        case .location: return "Location"
        case .secure: return "Top secret"
        case .personalProfile: return "Profile page"
        case .redPacket: return "Red packet"
        case .giftCard: return "Gift card"
        case .creditsGiftCard: return "Credits gift card"
        }
    }

    var symbolName: String {
        switch self {
        case .photo: return "photo.on.rectangle.angled"
        case .camera: return "camera.fill"
        case .file: return "folder.fill"
        case .location: return "location.fill"
        case .secure: return "lock.shield.fill"
        case .personalProfile: return "person.text.rectangle.fill"
        case .redPacket: return "gift"
        case .giftCard: return "giftcard.fill"
        // The outline twin of the badge card's filled glyph: two gift cards, one family filled and one outlined, so the panel
        // reads as "the same kind of thing, two kinds of value" without inventing a third metaphor.
        case .creditsGiftCard: return "giftcard"
        }
    }
}

// MARK: - Input bar

/// The conversation input bar on a frosted-glass base: voice key · self-growing text box · emoji · the "+" function panel (which contains view-once) · send key.
struct PopopxInputBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @Binding private var text: String
    @FocusState private var isFocused: Bool

    @StateObject private var model: PopopxInputBarModel
    @ObservedObject private var runtime: PopopxMeshRuntime
    @ObservedObject private var meshState: PopopxMeshStateSource

    private let context: PopopxComposerContext
    private let ttlSeconds: Int?
    private let secureTTLSeconds: Int?
    private let isSendEnabled: Bool
    private let placeholder: String
    private let onSend: (PopopxComposerSend) -> Void
    private let onVoiceTap: (Bool) -> Void
    private let onHoldToTalk: () -> Void
    private let onPlusTap: (PopopxPlusAction) -> Void
    private let onTTLChange: (Int?) -> Void
    private let onSecureTTLChange: (Int?) -> Void
    /// Which cells are actually drawn in the "+" panel. The default is all of them; the host filters out, per session, the ones that **cannot be sent at all in this session**
    /// (the gift card only holds in direct chats). Deliberately not built as "draw it, then show a hint when it is pressed": one cell fewer is just one entry point fewer,
    /// whereas a cell whose tap buys nothing but a "not possible here" is tricking the user into pressing it.
    private let plusActions: [PopopxPlusAction]

    @State private var showsPlusPanel = false
    @State private var showsEmojiTray = false
    @State private var isVoiceMode = false

    /// How many lines the text box grows to at most; beyond that it scrolls on its own.
    private static let maxComposerLines = 5

    /// `@MainActor` is there so that init can obtain those two `@MainActor` singletons (`PopopxMeshRuntime.shared`
    /// `POPOPXAPI.swift:3732`、`PopopxMeshStateSource.shared` `PopopxMeshStateSource.swift:161`）——
    /// and the same spelling used by the phase four pages (`Shared/Features/Chats/ChatsListView.swift:189`).
    @MainActor
    init(
        text: Binding<String>,
        context: PopopxComposerContext = .outsideDirectContact,
        ttlSeconds: Int? = nil,
        secureTTLSeconds: Int? = nil,
        isSendEnabled: Bool = true,
        placeholder: String = "Message…",
        onSend: @escaping (PopopxComposerSend) -> Void,
        onVoiceTap: @escaping (Bool) -> Void = { _ in },
        onHoldToTalk: @escaping () -> Void = {},
        onPlusTap: @escaping (PopopxPlusAction) -> Void = { _ in },
        onTTLChange: @escaping (Int?) -> Void = { _ in },
        onSecureTTLChange: @escaping (Int?) -> Void = { _ in },
        plusActions: [PopopxPlusAction] = PopopxPlusAction.allCases
    ) {
        _text = text
        _model = StateObject(wrappedValue: PopopxInputBarModel())
        _runtime = ObservedObject(wrappedValue: PopopxMeshRuntime.shared)
        _meshState = ObservedObject(wrappedValue: PopopxMeshStateSource.shared)
        self.context = context
        self.ttlSeconds = ttlSeconds
        self.secureTTLSeconds = secureTTLSeconds
        self.isSendEnabled = isSendEnabled
        self.placeholder = placeholder
        self.onSend = onSend
        self.onVoiceTap = onVoiceTap
        self.onHoldToTalk = onHoldToTalk
        self.onPlusTap = onPlusTap
        self.onTTLChange = onTTLChange
        self.onSecureTTLChange = onSecureTTLChange
        self.plusActions = plusActions
    }

    var body: some View {
        VStack(spacing: PopopxMetrics.space2XS) {
            channelStrip
            inputRow
            if showsEmojiTray { emojiTray }
            if showsPlusPanel { plusPanel }
        }
        .padding(.top, PopopxMetrics.spaceXS)
        .padding(.bottom, PopopxMetrics.space2XS)
        .padding(.horizontal, PopopxMetrics.spaceS)
        .background(PopopxMaterial.bar, in: .rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .popopxCardElevation(colorScheme: colorScheme)
        .popopxAnimation(PopopxSpring.snappy, value: showsPlusPanel, reduceMotion: reduceMotion)
        .popopxAnimation(PopopxSpring.snappy, value: showsEmojiTray, reduceMotion: reduceMotion)
        .popopxAnimation(PopopxSpring.fluid, value: channel, reduceMotion: reduceMotion)
        // Read once when the session opens; when the master switch flips this pair of tasks is restarted (`refresh` itself first clears the old verdict to unread).
        .task(id: context.contactId) { await model.refresh(contactId: context.contactId) }
        .task(id: runtime.isFuseOn) { await model.poll(contactId: context.contactId) }
    }

    // MARK: Channel strip

    private var channel: PopopxComposerChannel {
        PopopxComposerRouting.channel(
            eligibility: model.eligibility,
            ttlSeconds: ttlSeconds,
            hops: currentHops
        )
    }

    /// The hop count is read synchronously from the already observed mesh snapshot, so it produces no actor hop (`peer(withHex:)` is at PopopxMeshStateSource.swift:56).
    private var currentHops: Int? {
        guard let hex = model.eligibility.reachableMeshKey else { return nil }
        return meshState.state.peer(withHex: hex)?.hopCount
    }

    /// The half of the verdict that the channel strip asks on every redraw (no messageId is minted - there is no "this message" yet).
    private var hostSendReason: PopopxHostSendReason? {
        PopopxComposerRouting.hostReason(
            context: context,
            eligibility: model.eligibility,
            ttlSeconds: ttlSeconds
        )
    }

    /// The send key's graphic follows only the **channel**, not "who gets to send it": in this product teal has always meant "Bluetooth took this one away",
    /// not "module 5 got hold of it" (the verdict is in the `dispatch` of `onSend`, for the host to read itself).
    private var sendSymbolName: String {
        if case .mesh = channel { return "antenna.radiowaves.left.and.right" }
        return "arrow.up"
    }

    @ViewBuilder private var channelStrip: some View {
        let note = stripNote
        if note != nil || model.eligibility.queuedCount > 0 {
            HStack(spacing: PopopxMetrics.spaceXS) {
                channelBadge
                if model.eligibility.queuedCount > 0 {
                    // A grey clock says exactly one thing: Cabin relay backlog.
                    Label("Awaiting relay: \(model.eligibility.queuedCount)", systemImage: "clock")
                        .font(PopopxType.metricSmall)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .accessibilityLabel(Text("Mesh relay backlog: \(model.eligibility.queuedCount) messages"))
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .padding(.leading, PopopxMetrics.space2XS)
        }
    }

    @ViewBuilder private var channelBadge: some View {
        switch channel {
        case .smp:
            Label("Online encryption · SMP", systemImage: "lock.shield.fill")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.brand)
        case let .mesh(hops):
            // The closure returns `LocalizedStringKey` explicitly: the type of the whole expression decides which `Label` overload is taken,
            // and landing on `String` is the same as not localizing.
            Label(
                hops.map { (n: Int) -> LocalizedStringKey in "Mesh offline · \(n) hops" } ?? "Mesh offline",
                systemImage: "antenna.radiowaves.left.and.right"
            )
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.meshInk)
        case .undetermined:
            // We do not guess the channel on the user's behalf, so this deliberately gets no icon and no accent color.
            Text(model.isResolving ? "Reading mesh bindings…" : "Channel undetermined")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
    }

    /// The one line of explanation beyond the accent color (grey, never competing with the accent color for the second color inside the same control).
    /// The same reason as `PopopxHostSendReason.explanation`: it returns `String?`, so the table lookup goes through `NSLocalizedString`.
    private var stripNote: String? {
        if let reason = hostSendReason { return reason.explanation }
        switch channel {
        case .smp:
            // When the public network is up and Bluetooth can also reach directly, say clearly that mesh is only a resend / fallback (module 5's 3 second rule).
            return model.eligibility.isMeshCapable && model.eligibility.networkConnected == true
                ? NSLocalizedString("If the internet does not acknowledge within 3 seconds it is also sent over Bluetooth", comment: "composer channel strip")
                : nil
        case .mesh:
            return NSLocalizedString("No internet connection; this message will be relayed over Bluetooth", comment: "composer channel strip")
        case .undetermined:
            return nil
        }
    }

    // MARK: Main row

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: PopopxMetrics.spaceXS) {
            PopopxBarKey(
                symbol: isVoiceMode ? "keyboard" : "mic",
                label: isVoiceMode ? "Switch back to keyboard" : "Switch to voice input",
                active: isVoiceMode
            ) {
                isVoiceMode.toggle()
                closeTrays()
                PopopxHaptics.selection()
                onVoiceTap(isVoiceMode)
            }

            if isVoiceMode {
                holdToTalkBar
            } else {
                composerField
            }

            PopopxBarKey(
                symbol: "face.smiling",
                label: "Emoji",
                active: showsEmojiTray
            ) {
                showsPlusPanel = false
                showsEmojiTray.toggle()
                if showsEmojiTray { isFocused = false }
                PopopxHaptics.selection()
            }

            PopopxBarKey(
                symbol: showsPlusPanel ? "xmark" : "plus",
                label: showsPlusPanel ? "Hide functions" : "More functions",
                active: showsPlusPanel
            ) {
                showsEmojiTray = false
                showsPlusPanel.toggle()
                if showsPlusPanel { isFocused = false }
                PopopxHaptics.selection()
            }
            .accessibilityIdentifier("popopx.inputBar.plusButton")

            sendKey
        }
    }

    private var composerField: some View {
        // `placeholder` is a `String` handed in by the host, so here it is explicitly looked up once as a key;
        // the bare `String` overload of `TextField(_:text:axis:)` does not consult the table.
        TextField(LocalizedStringKey(placeholder), text: $text, axis: .vertical)
            .font(PopopxType.body)
            .foregroundStyle(PopopxPalette.label)
            .lineLimit(1...Self.maxComposerLines)
            .focused($isFocused)
            .submitLabel(.send)
            .onSubmit(send)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .padding(.vertical, PopopxMetrics.space2XS)
            .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(
                        isFocused ? PopopxPalette.hairlineInner : Color.clear,
                        lineWidth: PopopxMetrics.hairline
                    )
            )
            .accessibilityLabel(Text(LocalizedStringKey(placeholder)))
            .accessibilityIdentifier("popopx.inputBar.textField")
    }

    /// Recording is not owned by this bar: here it only switches the "hold to talk" surface in and hands the press itself out.
    private var holdToTalkBar: some View {
        Button(action: onHoldToTalk) {
            Text("Hold to talk")
                .font(PopopxType.emphasis)
                .foregroundStyle(PopopxPalette.label)
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget)
                .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                .contentShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: .medium))
        .accessibilityHint(Text("Handed to the host's recording pipeline; this input bar does not own the recorder"))
    }

    private var sendKey: some View {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canFire = isSendEnabled && (!blank || context.hasAttachments)
        return Button(action: send) {
            Image(systemName: sendSymbolName)
                .font(PopopxType.emphasis)
                .foregroundStyle(sendAccent.ink)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .background(sendAccent.fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .disabled(!canFire)
        .opacity(canFire ? 1 : 0.45)
        .accessibilityLabel(Text("Send"))
        .accessibilityValue(sendAccessoryLabel)
        .accessibilityIdentifier("popopx.inputBar.sendButton")
    }

    /// Only one accent color is possible inside a single control: indigo (SMP) or teal (mesh), or a neutral gray that is neither.
    private var sendAccent: (fill: Color, ink: Color) {
        switch channel {
        case .smp: (PopopxPalette.brand, PopopxPalette.onBrand)
        case .mesh: (PopopxPalette.mesh, PopopxPalette.onMesh)
        case .undetermined: (PopopxPalette.separator, PopopxPalette.labelSecondary)
        }
    }

    /// The VoiceOver value: the send key itself carries no text, so the channel can only be told through this sentence.
    private var sendAccessoryLabel: LocalizedStringKey {
        switch channel {
        case .smp: return "Will be sent over online encryption · SMP"
        case .mesh: return "Will be sent over the mesh Bluetooth channel"
        case .undetermined: return "Send channel undetermined"
        }
    }

    // MARK: Emoji tray

    private var emojiTray: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: PopopxMetrics.space2XL), spacing: PopopxMetrics.spaceXS)],
            spacing: PopopxMetrics.space2XS
        ) {
            ForEach(Self.quickEmoji, id: \.self) { glyph in
                Button {
                    text += glyph
                    PopopxHaptics.impact(.soft)
                } label: {
                    Text(glyph)
                        .font(PopopxType.title)
                        .frame(minWidth: PopopxMetrics.minHitTarget, minHeight: PopopxMetrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PopopxPressButtonStyle(feedback: nil))
                .accessibilityLabel(Text("Insert emoji \(glyph)"))
            }
            Button {
                if !text.isEmpty { text.removeLast() }
                PopopxHaptics.impact(.light)
            } label: {
                Image(systemName: "delete.left")
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(minWidth: PopopxMetrics.minHitTarget, minHeight: PopopxMetrics.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle(feedback: nil))
            .accessibilityLabel(Text("Delete the previous character"))
        }
        .padding(.top, PopopxMetrics.space2XS)
    }

    /// The 24 most frequently used ones. A fuller emoji set belongs to the system emoji keyboard (switch back to the keyboard); this bar does not build a second picker -
    /// the old composer's `ElegantEmojiPicker` was only ever hooked in when choosing a tag icon on the list page (`TagListView.swift:250`).
    private static let quickEmoji: [String] = [
        "😀", "😄", "😂", "🥰", "😍", "😉",
        "😊", "😎", "🤔", "😴", "😭", "😱",
        "👍", "👎", "👏", "🙏", "💪", "🤝",
        "❤️", "🔥", "🎉", "✨", "🌙", "⚡️"
    ]

    // MARK: "+" function panel

    private var plusPanel: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            Rectangle()
                .fill(PopopxPalette.separator)
                .frame(height: PopopxMetrics.divider)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: PopopxMetrics.space2XL), spacing: PopopxMetrics.spaceS)],
                spacing: PopopxMetrics.spaceXS
            ) {
                ForEach(plusActions) { action in
                    // So far the only cell with an "armed" state is top secret: drawn as an ordinary one-shot action,
                    // the user cannot tell whether this draft is in fact a top-secret message - and that is the only visible clue before sending.
                    // The declaration must go before `Button` rather than inside `label:`: the `.accessibilityAddTraits` below
                    // hangs off Button's return value, so it cannot see the scope inside the label closure.
                    let armed = action == .secure && secureTTLSeconds != nil
                    Button {
                        // The top-secret cell **does not close the panel** when pressed: it is an arm switch, and once closed the user would only see
                        // the panel vanish with nothing happening; staying inside the panel is what lets the row of duration chips light up immediately.
                        // The other four cells are one-shot actions (open a picker / system panel) and must close it.
                        if action != .secure { closeTrays() }
                        onPlusTap(action)
                    } label: {
                        VStack(spacing: PopopxMetrics.space2XS) {
                            Image(systemName: action.symbolName)
                                .font(PopopxType.sectionHeader)
                                .foregroundStyle(armed ? PopopxPalette.onBrand : PopopxPalette.label)
                                .frame(
                                    minWidth: PopopxMetrics.minHitTarget,
                                    minHeight: PopopxMetrics.minHitTarget
                                )
                                .background(
                                    armed ? PopopxPalette.brand : PopopxPalette.card,
                                    in: .rect(cornerRadius: PopopxMetrics.radiusControl)
                                )
                            Text(action.title)
                                .font(PopopxType.microTag)
                                .foregroundStyle(armed ? PopopxPalette.brand : PopopxPalette.labelSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PopopxPressButtonStyle(feedback: .light))
                    .accessibilityLabel(action.title)
                    .accessibilityAddTraits(armed ? .isSelected : [])
                }
            }

            disappearingBlock

            secureBlock

            Text("Burn after reading, attachments and quotes are not relayed over Bluetooth - they are still sent over the internet, unchanged.")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, PopopxMetrics.space2XS)
    }

    @ViewBuilder private var disappearingBlock: some View {
        // `PopopxCheckbox` takes a `String` (`Shared/Components/PopopxControls.swift:412`),
        // and the `Text(title)` inside it does not consult the table, so the key has to be resolved before it is handed in.
        PopopxCheckbox(
            NSLocalizedString("Burn after reading", comment: "composer option"),
            note: NSLocalizedString("When this is on the message goes only over online encryption, never relayed by Bluetooth", comment: "composer option"),
            isOn: disappearingSwitch
        )
        if let ttlSeconds {
            // The three tiers are exactly the three tiers of the old send-key menu (`SendMessageView.swift:199`-`:201`); no separate duration is set up here.
            PopopxDurationChips(
                options: PopopxComposerRouting.durationOptions,
                selectedSeconds: ttlSeconds,
                label: "Burn-after-reading duration",
                onSelect: onTTLChange
            )
        }
    }

    /// The top-secret tier. It sits adjacent to the tier above in the layout, so the two pieces of copy must state the **difference**:
    /// one governs how long the server keeps it, the other how long the screen keeps it, and this one may travel over Bluetooth (what goes out is ciphertext).
    @ViewBuilder private var secureBlock: some View {
        PopopxCheckbox(
            NSLocalizedString("Top-secret burn after reading", comment: "composer option"),
            note: NSLocalizedString("The text is sent as ciphertext; the recipient must pass biometrics to view it. Can be relayed over Bluetooth (relays store ciphertext only)", comment: "composer option"),
            isOn: secureSwitch
        )
        if let secureTTLSeconds {
            PopopxDurationChips(
                options: PopopxSecureCopy.ttlOptions,
                selectedSeconds: secureTTLSeconds,
                label: "How long the top-secret message stays on the recipient's screen",
                onSelect: onSecureTTLChange
            )
        }
    }

    /// There is only one source of truth: `ttlSeconds` read in, `onTTLChange` written out. This bar does not store "the duration chosen last time".
    private var disappearingSwitch: Binding<Bool> {
        Binding(
            get: { ttlSeconds != nil },
            set: { turnedOn in
                PopopxHaptics.impact(.light)
                guard turnedOn else {
                    onTTLChange(nil)
                    return
                }
                onTTLChange(ttlSeconds ?? PopopxComposerRouting.fallbackDurationSeconds)
            }
        )
    }

    /// The same rule for the top-secret tier: read `secureTTLSeconds`, write `onSecureTTLChange`, keep no local copy.
    /// The default tier comes from the payload layer (`PopopxSecureCopy.defaultTTLSeconds`); see there for the reason.
    private var secureSwitch: Binding<Bool> {
        Binding(
            get: { secureTTLSeconds != nil },
            set: { turnedOn in
                PopopxHaptics.impact(.light)
                onSecureTTLChange(turnedOn
                    ? secureTTLSeconds ?? PopopxSecureCopy.defaultTTLSeconds
                    : nil)
            }
        )
    }

    // MARK: Actions

    private func closeTrays() {
        showsPlusPanel = false
        showsEmojiTray = false
    }

    private func send() {
        let dispatch = PopopxComposerRouting.dispatch(
            text: text,
            context: context,
            eligibility: model.eligibility,
            ttlSeconds: ttlSeconds
        )
        // Empty draft: do not send, and do not call the host either.
        if case .ignoreEmptyDraft = dispatch { return }
        PopopxHaptics.impact(dispatch.isRouted ? .medium : .light)
        onSend(
            PopopxComposerSend(
                text: text,
                context: context,
                ttlSeconds: ttlSeconds,
                secureTTLSeconds: secureTTLSeconds,
                dispatch: dispatch,
                channel: channel
            )
        )
        // Only the router branch is this bar's job to clear the draft: module 5's SMP leg inserts the row into the timeline itself
        // (`POPOPXAPI.swift:3467`-`:3480`), and apart from here nobody else clears `text`.
        // The branch handed back to the host keeps the host's own clearing timing (`SendMessageView.swift:152`); this bar does not touch it,
        // otherwise the host's failure refill and draft rewriting would be wiped out.
        if dispatch.isRouted { text = "" }
        closeTrays()
    }
}

// MARK: - Keys (starting at 44pt, all through atomic controls)

/// An icon key on the input bar. The selected state uses ink color + a card backing, **neither indigo nor teal**:
/// those two colors carry the semantics of the transport channel in this product and cannot be borrowed for something like "the panel is open".
private struct PopopxBarKey: View {
    let symbol: String
    /// `LocalizedStringKey`: this cell has only an icon, the caption is for VoiceOver, and a bare `String` does not enter the localization table.
    let label: LocalizedStringKey
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(active ? PopopxPalette.label : PopopxPalette.labelSecondary)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .background(
                    active ? PopopxPalette.card : Color.clear,
                    in: .rect(cornerRadius: PopopxMetrics.radiusControl)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: .light))
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

