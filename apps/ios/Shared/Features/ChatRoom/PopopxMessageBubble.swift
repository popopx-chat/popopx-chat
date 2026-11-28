//
//  PopopxMessageBubble.swift
//  POPOPX (iOS)
//
//  [phase 5 · 1] modern chat-flow bubble + channel badge.
//
//  This file does three things:
//  1. Draws one **already-classified** chat item as a bubble: left (receiver) on a `card` surface, right (sender, online) on solid `brand`,
//     outer 16pt (`PopopxMetrics.radiusCard`), the corner adjacent to the consecutive message from the same sender tightened to 4pt
//     （`PopopxMetrics.radiusBubbleTucked`）——Docs/popopx-brand-spec.md §2.1、§4。
//  2. Makes clear "which channel delivered this one": indigo-violet = SMP public network, teal = Cabin offline BLE Mesh (**hop count mandatory**),
//     grey clock = still sitting in the Mesh relay queue. The semantic split is a hard rule (§1.1), not decoration.
//  3. The rendering half of "send location": `PopopxLocationCardBubble` at the end of this file — a map-snapshot card; list rows
//     hold only a **bitmap**, never a live `Map`/`MKMapView` (the performance red line at `location-prompt.md:72`).
//     The payload `PopopxLocationPayload` lives in `Shared/Features/ChatInfo/PopopxLocation.swift`: the sending side (ComposeView) needs it too,
//     and that file imports not a single MapKit/CoreLocation symbol. The consistency of the two halves over the same byte string is
//     the business of the `wireString` ↔ `parse(from:)` pair — changing either side means looking at the other at the same time.
//
//  Deliberately knows nothing about `ChatItem`: every value comes in through parameters (`PopopxBubbleItem`), the environment reads no globals. The channel truth is not taken at this layer either —
//  `PopopxBubbleTransportResolver` is the mounting seam: the host reads everything once (`allMappings` + `pendingMessages` +
//  `recordedFlushedAppChatItemIDs`, 3 actor hops in total; the rest are `@Published` snapshots it is already observing),
//  compresses them into a table indexed by message key, then feeds it row by row to the bubbles. **One await per row is not allowed**
//  (ui-prompt.md phase 5 "anti-parameter-loss mechanism": a component's interface must consume only values the caller already holds).
//
//  Color contract (self-checked item by item in this file):
//  - Sender bubbles are always solid `brand` + `onBrand` ink; receiver bubbles are always `card` surface + `label` ink.
//    Channel distinction is left to the bottom-right badge: SMP = indigo-violet lock, Mesh = teal ripples + hop chip, awaiting relay = grey clock.
//    outer 16pt (`PopopxMetrics.radiusCard`), the corner adjacent to the consecutive message from the same sender tightened to 4pt
//    （`PopopxMetrics.radiusBubbleTucked`）——Docs/popopx-brand-spec.md §2.1、§4。
//  - Inside a solid bubble the badge degrades to "the same ink" — never draw indigo on an indigo ground or teal on a teal ground
//    (§1.1 "within one message row, inside one bubble, violet and teal must not be mixed").
//  - `mesh` reaches only 2.98:1 on a card surface, so teal **text/graphics** on a card are always `meshInk` (6.03:1);
//    solid `mesh` is used only for the hop chip carrying the `onMesh` number (§1.2 table + the same drawing at PopopxCabinView.swift:1530-1542).
//  - `onBrand` flips to near-black in Dark (white text on `#7D7AFF` is only 3.44:1, PopopxTheme.swift:66-71), so this file
//    never assumes "white ink on a brand background".
//  - Red appears only on the SMP delivery-failure symbol, taken from the same predicate in the live app (`CIItemStatus.statusIcon` returns
//    `.red` for exactly these states, POPOPXChat/ChatTypes.swift:4622-4624); recalled / awaiting relay never go red.
//
//  ⚠️ Xcode project integration: this file must be dragged manually into the POPOPX (iOS) target. The red line forbids scripts from modifying project.pbxproj.
//

import SwiftUI
import UIKit
import CoreLocation
import MapKit
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - Channel values

/// Which channel delivered this message. One row, one conclusion; drawn out it becomes `PopopxBadge`.
enum PopopxBubbleChannel: Hashable {
    /// Carried over the SMP public network: indigo-violet lock.
    case smp
    /// Carried over the Cabin offline BLE Mesh. `hops` is the hop count measured for this message **at that moment**; 0 = a neighbour holds the link directly;
    /// the badge must print that number (§1.4 item 3); a teal chip with no number is a violating drawing.
    case mesh(hops: Int)
    /// Still sitting in the Mesh relay queue, not one message out: grey clock. `reason` is the reason, when there is one.
    case awaitingRelay(reason: PopopxBubbleQueueReason?)
    /// This row can promise no channel: system rows, local notes, the table not read out yet. No badge is drawn, and nothing is guessed.
    case none

    /// The merged timeline in the package has already classified this row; here it only gets a new colour-semantics shell.
    /// The entry point is the public `PopopxMeshTimelineChannel` (MergedTimelineModifier.swift:32),
    /// i.e. the same input as `PopopxMeshBadgeDescriptor.init(channel:)` (:357 in the same file); not
    /// `PopopxMeshChannelBadge.color(of:)`, because that one is internal (already recorded in brand-spec §0.1).
    init(_ channel: PopopxMeshTimelineChannel) {
        switch channel {
        case .smpPublicNetwork: self = .smp
        case let .offlineMesh(hopCount): self = .mesh(hops: hopCount)
        case .awaitingRelay: self = .awaitingRelay(reason: nil)
        @unknown default: self = .awaitingRelay(reason: nil)
        }
    }

    /// Is this channel teal. The sender uses it to decide the bubble fill, and also to decide whether the badge degrades to the same ink.
    var isMesh: Bool {
        if case .mesh = self { return true }
        return false
    }

    /// One VoiceOver sentence that spells out the channel; icons are always `accessibilityHidden`.
    var spoken: String {
        switch self {
        case .smp: PopopxBubbleCopy.channelSmp
        case let .mesh(hops): PopopxBubbleCopy.channelMesh(hops)
        case let .awaitingRelay(reason): reason.map { PopopxBubbleCopy.awaitingRelay($0) } ?? PopopxBubbleCopy.awaitingRelayPlain
        case .none: PopopxBubbleCopy.channelNone
        }
    }
}

/// The concrete reason for awaiting relay. The first 5 are those real values in the module 5 queue, moved over verbatim, word for word
/// (`PopopxQueueReason`, PopopxMessageRouter.swift:144-155); the last 2 are discovered by this component itself.
enum PopopxBubbleQueueReason: Hashable {
    case noNetwork
    case peerUnreachable
    case smpUnacknowledged
    case meshRefused
    case awaitingContactUpgrade
    /// The hop count exceeds `PopopxMeshConfig.fragmentRelayTtlCap`, or the neighbour this sender row is bound to has already been silent past the window:
    /// that number can no longer be promised by this mesh, so it falls back to a grey clock. Same predicate as ChatsListView.swift:464-466.
    case hopCountUnverifiable(hops: Int, cap: Int)
    /// A tier added later by module 5, or the host gave no reason.
    case unknown

    init(_ reason: PopopxQueueReason) {
        switch reason {
        case .noNetwork: self = .noNetwork
        case .peerUnreachable: self = .peerUnreachable
        case .smpUnacknowledged: self = .smpUnacknowledged
        case .meshRefused: self = .meshRefused
        case .awaitingContactUpgrade: self = .awaitingContactUpgrade
        @unknown default: self = .unknown
        }
    }

    var words: String {
        switch self {
        case .noNetwork: PopopxBubbleCopy.reasonNoNetwork
        case .peerUnreachable: PopopxBubbleCopy.reasonPeerUnreachable
        case .smpUnacknowledged: PopopxBubbleCopy.reasonSmpUnacknowledged
        case .meshRefused: PopopxBubbleCopy.reasonMeshRefused
        case .awaitingContactUpgrade: PopopxBubbleCopy.reasonAwaitingUpgrade
        case let .hopCountUnverifiable(hops, cap): PopopxBubbleCopy.reasonHopUnverifiable(hops, cap)
        case .unknown: PopopxBubbleCopy.awaitingRelayPlain
        }
    }
}

// MARK: - Layout values

/// The bubble's orientation. Receiver on the left, sender on the right — the predicate is the same one in the live app (`ChatView.swift:2257`'s
/// `ci.chatDir.sent && !terminal`), passed in by the host; this file does not read the chat model.
enum PopopxBubbleSide: Hashable {
    case received
    case sent

    var alignment: Alignment { self == .sent ? .trailing : .leading }
}

/// Which corner gets tightened. The brief's wording is "the corner adjacent to the previous message from the same sender", i.e. the **top** corner on the sender's side;
/// the live app's `ChatItemClipped` draws the tail on the **bottom** edge (ChatItemClipShape.swift:130-141).
/// Default follows the brief (`.top`); to return to the live app's visual memory, the mount point changes one line to `.bottom`.
enum PopopxBubbleTuckCorner: Hashable {
    case top
    case bottom
}

/// The bubble's corner-radius geometry. All four outer corners are `radiusCard`; only the `tucked` corner becomes `radiusBubbleTucked`.
struct PopopxBubbleTail: Hashable {
    var side: PopopxBubbleSide = .received
    /// The previous row is the same sender → tighten. The host's predicate is exactly the one it now uses to decide the tail
    /// (`tailVisible` at `ChatView.swift:2285`).
    var tucked: Bool = false
    var corner: PopopxBubbleTuckCorner = .top
    /// When `DEFAULT_CHAT_ITEM_TAIL` is off, or in terminal layout, corners are not merged: all four at 16pt.
    /// The same switch in the live app is at ChatItemClipShape.swift:49 (`tailEnabled && !terminal`).
    var enabled: Bool = true

    /// The concrete radius is clamped to h/2 by `UnevenRoundedRectangle` itself when the height is insufficient, so stretching Dynamic Type to
    /// 120% will not distort the bubble the way the live app does (ChatItemClipShape.swift:103-109 is the same thing clamped manually).
    var shape: UnevenRoundedRectangle {
        let outer = PopopxMetrics.radiusCard
        let near = tucked && enabled ? PopopxMetrics.radiusBubbleTucked : outer
        let leading = side == .received
        return UnevenRoundedRectangle(
            topLeadingRadius: leading && corner == .top ? near : outer,
            bottomLeadingRadius: leading && corner == .bottom ? near : outer,
            bottomTrailingRadius: !leading && corner == .bottom ? near : outer,
            topTrailingRadius: !leading && corner == .top ? near : outer,
            style: .continuous
        )
    }
}

/// What a chat item row needs to draw. The first five tiers cover the five things that actually appear on this row in the live app; the sixth tier (`.location`)
/// comes from "send location": the mount point only maps `ChatItem.content` → this enum once, and the bubble never reads `ChatItem`.
enum PopopxBubbleBody: Hashable {
    /// Body text.
    case text(String)
    /// Image/video/voice/file: name + one line of description (size, duration). Thumbnails stay owned by the host —
    /// this component does not take over the playback controls of `CIFileView`/`CIVoiceView`.
    case media(name: String, detail: String?)
    /// The sentence left behind by a recall or a moderation removal (live app `MarkedDeletedItemView`, ChatItemView.swift:79-80).
    /// Neutral ink + italic: in this palette red belongs only to "dangerous actions" (§1.1), and an already-recalled history entry is not a dangerous action.
    case withdrawn(String)
    /// System/protocol row: whole-row text, no bubble fill.
    case event(String)
    /// Content that could not be read (`invalidJSON`, decryption failure).
    case unavailable(String)
    /// A location message. The payload itself carries latitude/longitude, place name and address; rendered as a map card (`PopopxLocationCardBubble` at the end of this file).
    case location(PopopxLocationPayload)
    /// A top-secret message. This tier **carries ciphertext only**: the payload's `sealed`/`key` are `Data`, and rendering uses only `ttlSeconds`
    /// to state the duration; the body details exist only inside the secret window and never appear in the bubble, `spokenText` or the list preview.
    case secure(PopopxSecurePayload)
    /// The **index payload** of an encrypted profile. Same family as `.location`/`.secure`: this tier carries a structured manifest rather than
    /// body text, rendered as a clickable business-card view (`ProfileCardBubbleView`). The image/text originals are ordinary attachment rows and do not enter this tier.
    case profile(PopopxProfilePayload)
    /// A message of the compute-points ecosystem: a badge gift card, a credit gift card, a red packet or a channel gate card. The mount point uses `PopopxCommerceContent.detect(in:)`
    /// to judge once from the same body text; if it detects nothing it stays `.text` — this tier carries no local state,
    /// the card reads from the keychain ledger itself, so `PopopxBubbleBody` remains `Hashable` and comparable.
    case commerce(PopopxCommerceContent)
    /// A service-account card (`::POPOPX_ECO::` with `mode == create`). Same family as `.commerce`: the tier carries the manifest, the
    /// card reads its own newest state from `PopopxEcoStore`, so `Hashable` survives and an in-place update repaints this row instead of
    /// appending a second bubble. Frames that *mutate* this device (handshake, menu, key rotation, and a card **update**) never reach
    /// this tier — `PopopxEcoMarker.isControlText` hides them through `PopopxSysMarker.isSignalText`.
    case serviceCard(PopopxServiceCard)
    /// The signed upgrade notice a bonded Mac publishes (`::POPOPX_UPD::v1`). Same family as
    /// `.serviceCard`: the tier carries the node's own manifest, and the card holds no local state, so
    /// `Hashable` survives. The two commands inside it are echoed byte-for-byte and never rebuilt —
    /// the receipt is minted node-side (`UpdateCenter.swift:219-228`), so this device can only return it.
    /// Direct chats only: a card posted in a group would put an outsider's string into the node channel.
    case nodeUpdate(PopopxNodeUpdateWire.Notice)
    /// An agent task card (`::POPOPX_AGENT::v1`): progress, an approval request, a choice or a result.
    /// Same family as `.nodeUpdate`: the tier carries the parsed manifest and the card holds only the
    /// decision journal, so `Hashable` survives an in-place update of the same task id. Direct chats
    /// only — the approval buttons mint a receipt addressed to the chat's contact.
    case agentTask(PopopxAgentTask)

    /// The body sentence VoiceOver should say. `.event` is routed by `PopopxMessageBubble.body` to `eventLine`,
    /// and gets no bubble fill — the predicate is written only in that one routing place.
    var spokenText: String {
        switch self {
        case let .text(text): text
        case let .media(name, detail): detail.map { "\(name)，\($0)" } ?? name
        case let .withdrawn(text): text
        case let .event(text): text
        case let .unavailable(text): text
        case let .location(payload): PopopxLocationCopy.spoken(payload)
        // The secret sentence says only "this is a top-secret message requiring biometrics, with what duration". It and the card's own
        // `accessibilityText` belong to the same wording family: if the two places each say something different, screen-reader users get two inconsistent facts.
        case let .secure(payload): String(format: NSLocalizedString("Top-secret burn-after-reading message, %@, tap it and pass biometrics to view", comment: ""), payload.summaryText)
        // The wording belongs to the same family as the card's own `accessibilityText` (the reason at :211 holds in both places): the profile's image/text body
        // is not in the bubble, so this only says "what kind of profile this is" — no block counts, nothing beyond the title.
        case let .profile(payload): String(format: NSLocalizedString("Encrypted profile card, %1$@, %2$@", comment: ""), payload.manifest.title, payload.isEphemeral ? String(format: NSLocalizedString("Burn after reading · %@", comment: ""), payload.ttlText) : NSLocalizedString("Permanent card, view it as often as you like", comment: ""))
        // The wording lives on the card side (`PopopxCommerceCards.swift`); this only forwards: for the same red packet, what the bubble says
        // and the numbers written on the card must come from the same place, otherwise one side gets changed and the other forgotten.
        case let .commerce(content): content.spokenText
        // The joiner follows `.media` above: a full-width comma is locale-neutral for VoiceOver and keeps the two bubble families
        // speaking with the same cadence. The wording on the card itself lives in `ServiceCardBubbleView` (agent-written); this only
        // says what the row *is* and what it's about, the same way `.profile` does.
        case let .serviceCard(card): "\(PopopxEcoCopy.cardSpokenPrefix)，\(card.title)"
        // Same rule as the two above: the sentence the row says out loud is built from wording that lives
        // on the card, and only the version is added here, because that is the one fact a user decides on.
        case let .nodeUpdate(notice): "\(PopopxNodeUpdateCopy.spokenPrefix)，\(notice.version)"
        // Wording lives on the card (`PopopxAgentCopy`), same rule as the two families above.
        case let .agentTask(task): PopopxAgentCopy.spoken(task: task, recorded: nil)
        }
    }
}

/// Delivery receipt. This enum only expresses meaning; it does not copy the live app's two asset checkmarks (`checkmark.wide` / `checkmark.2`,
/// `CIItemStatus.statusIcon`, POPOPXChat/ChatTypes.swift:4614-4627): at mount time choose one of two,
/// either map the `statusIcon` result onto the tiers here for the bubble to draw, or pass `receipt = nil` and let `CIMetaView` keep drawing.
enum PopopxBubbleReceipt: Hashable {
    /// Sent, no confirmation waited back yet (`sndNew`/`sndSent`).
    case inFlight
    /// Accepted by the server (the full progress of `sndSent`).
    case delivered
    /// Read by the peer (`sndRcvd(.ok)`).
    case read
    /// This receiver row has not been read by the local side yet (`rcvNew`).
    case received
    /// Delivery failed or warning (`sndError`/`sndErrorAuth`/`sndWarning`/`invalid`).
    case failed(String?)

    /// All use real SF Symbols: the live app's two checkmarks (`checkmark.wide`, `checkmark.2`) are asset images,
    /// owned by `CIMetaView`; this file copies no assets and does not pretend a same-named symbol exists in the system.
    var symbolName: String {
        switch self {
        case .inFlight: "circle.dashed"
        case .delivered: "checkmark"
        case .read: "checkmark.circle.fill"
        case .received: "circlebadge.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var words: String {
        switch self {
        case .inFlight: PopopxBubbleCopy.receiptInFlight
        case .delivered: PopopxBubbleCopy.receiptDelivered
        case .read: PopopxBubbleCopy.receiptRead
        case .received: PopopxBubbleCopy.receiptReceived
        case .failed: PopopxBubbleCopy.receiptFailed
        }
    }
}

/// All the input values one bubble needs. Every field has a default, so the mount point fills them by name.
struct PopopxBubbleItem: Hashable {
    /// The key used by the channel table: for app rows in the live app it is `String(ChatItem.id)` (`PopopxMeshApplicationStream.rows(from:)`
    /// feeds the timeline exactly that way at Shared/Model/POPOPXAPI.swift:3990); for mesh rows it is the envelope's `messageId`.
    var messageKey: String
    var content: PopopxBubbleBody = .text("")
    var tail: PopopxBubbleTail = PopopxBubbleTail()
    var channel: PopopxBubbleChannel = .none
    /// Who sent that message in a group/channel (live app `senderRole`, ChatView.swift:2252).
    var author: String?
    /// The time formatted by the host; `nil` means don't draw — the live app cuts it with `.environment(\.showTimestamp)`
    /// (ChatView.swift:2284); here it becomes a value instead, and the component reads no environment switch.
    var timeText: String?
    var receipt: PopopxBubbleReceipt?
    /// The chat object's id, used only so the decision table can match "this contact's neighbour" to this row; nil = broadcast/unknown.
    var contactId: Int64?
    /// The locator of this row's secret message (chat id + message id), handed verbatim to the manager to delete and acknowledge when the secret window opens.
    /// **Only `PopopxBubbleBody.secure` can use it**; every other body is `nil`. If it cannot be obtained, leave `nil`:
    /// the card degrades to "not clickable", which is still better than using a guessed id to delete somebody else's message.
    var secureTarget: PopopxSecureChatTarget?
    /// The locator of this row's encrypted profile (chat id + message id), handed verbatim to `ProfileReaderHost` to time, delete
    /// and acknowledge when the reader opens. **Only `PopopxBubbleBody.profile` can use it**; every other body is `nil`; if it cannot be obtained leave `nil`,
    /// the card degrades to "not clickable" — the two reasons above for `secureTarget` are one and the same reason, not repeated here.
    var profileTarget: PopopxProfileReadKey?
    /// The conversation landing point of this row's gift card/red packet. **Only `PopopxBubbleBody.commerce` can use it**; every other body is `nil`.
    /// If it cannot be obtained, leave `nil`: gift cards and red packets degrade to read-only — both opening and redeeming reply a silent message into this conversation,
    /// and replying with a guessed chatId means replying into somebody else's conversation.
    var commerceContext: PopopxCommerceCardContext?
    /// The message time of this row, serving only the encrypted-profile card's "nobody opened it within 24 hours after sending" fallback.
    /// Default `Date()` (= now) rather than 1970: when the time is unavailable, better **not to destroy early** a view-once business card
    /// than to draw "expired" out of thin air on a row of historical messages.
    var createdAt: Date = Date()
    /// Upper bound of the row width, the mount point's ready-made `maxWidth` (the argument at ChatView.swift:2256).
    var maxWidth: CGFloat = .infinity

    var side: PopopxBubbleSide { tail.side }
}

// MARK: - The bubble itself

/// One chat item = one bubble + one badge.
///
/// Usage (the only entry point):
/// ```swift
/// PopopxMessageBubble(
///     PopopxBubbleItem(
///         messageKey: String(ci.id),
///         content: .text(ci.text),
///         tail: PopopxBubbleTail(side: ci.chatDir.sent ? .sent : .received,
///                               tucked: !itemSeparation.largeGap),
///         channel: table.channel(forKey: String(ci.id)),
///         author: senderRoleText,
///         timeText: itemSeparation.timestamp ? dateText(ci.meta.itemTs) : nil,
///         contactId: contactId
///     )
/// )
/// ```
/// `contextMenu`, swipe-to-reply, multi-select and the reaction bar — those row interactions **stay at the mount point** (ChatView.swift:2286-2326);
/// this component only provides the content view and the geometry, it does not grab the host's gestures.
@MainActor
struct PopopxMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let item: PopopxBubbleItem

    init(_ item: PopopxBubbleItem) {
        self.item = item
    }

    var body: some View {
        let row = Group {
            switch item.content {
            case let .event(text):
                eventLine(text)
            default:
                bubble
            }
        }
        .frame(maxWidth: item.maxWidth, alignment: item.side.alignment)
        switch item.content {
        case .location, .secure, .profile, .commerce, .serviceCard, .nodeUpdate, .agentTask:
            // Each of these cards contains at least one real button (open the map / tap to view / open the card / open and redeem / answer an update).
            // `.combine` would merge the subtree's tap action
            // into the whole row, and VoiceOver could never open them again, so this is changed to `.contain`: the container stays, and the children
            // each keep their own label and action (the location card's and the business card's sentence is spoken inside the card).
            row.accessibilityElement(children: .contain)
        default:
            row.accessibilityElement(children: .combine)
                .accessibilityLabel(spoken)
        }
    }

    // MARK: bubble

    private var bubble: some View {
        let ink = PopopxBubbleInk(channel: item.channel, side: item.side)
        return VStack(alignment: item.side.alignment.horizontal, spacing: PopopxMetrics.space2XS) {
            if let author = item.author {
                Text(author)
                    .font(PopopxType.caption)
                    .foregroundStyle(ink.meta)
                    .lineLimit(1)
            }
            contentText(ink)
            footer(ink)
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .padding(.vertical, PopopxMetrics.spaceXS)
        .fixedSize(horizontal: false, vertical: true)
        .background(ink.fill, in: item.tail.shape)
        // A card-surface bubble needs a bit of edge information on a pure-black ground (same predicate as §2.3); a solid bubble gets no stroke, lest yet another colour spring up.
        .overlay {
            if ink.onCard {
                item.tail.shape.strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            }
        }
        // Light layers on a shadow, Dark is automatically `.clear`: `popopxCardElevation` already picks by colorScheme,
        // and that little shadow under a solid bubble in Light is what a card should have anyway.
        .popopxCardElevation(colorScheme: colorScheme)
        // A channel migration is "something the user never touched changed by itself", so it goes through `fluid`; under Reduce Motion it lands directly
        // (§5, the same entry at PopopxTheme.swift:242-264).
        .popopxAnimation(PopopxSpring.fluid, value: item.channel, reduceMotion: reduceMotion)
    }

    /// Body text. `withdrawn` / `unavailable` share the body's font size and only swap the ink and the italic slant — a recall is not a dangerous action.
    @ViewBuilder private func contentText(_ ink: PopopxBubbleInk) -> some View {
        switch item.content {
        case let .text(text):
            Text(text)
                .font(PopopxType.body)
                .foregroundStyle(ink.text)
        case let .media(name, detail):
            VStack(alignment: item.side.alignment.horizontal, spacing: PopopxMetrics.space2XS) {
                Label {
                    Text(name)
                } icon: {
                    Image(systemName: "doc.viewfinder")
                }
                .font(PopopxType.meta)
                .foregroundStyle(ink.text)
                .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(PopopxType.caption)
                        .foregroundStyle(ink.meta)
                }
            }
        case let .withdrawn(text):
            Text(text)
                .font(PopopxType.body)
                .italic()
                .foregroundStyle(ink.meta)
        case let .event(text):
            // `.event` is routed to `eventLine` back in `body` and never reaches here; this branch exists only for switch completeness.
            Text(text)
                .font(PopopxType.caption)
                .foregroundStyle(ink.meta)
        case let .unavailable(text):
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "questionmark.folder")
                    .font(PopopxType.meta)
                    .foregroundStyle(ink.caution)
                    .accessibilityHidden(true)
                Text(text)
                    .font(PopopxType.caption)
                    .foregroundStyle(ink.meta)
            }
        case let .location(payload):
            // The bubble's inner padding is the breathing room between this map card and the bubble edge, so the thumbnail rounds itself and adds no separate stroke.
            // Time / receipt / channel badge come from the `footer` below; the card only contributes the map, the place name and the address.
            PopopxLocationCardBubble(payload: payload, ink: ink, channel: item.channel)
        case let .secure(payload):
            // This branch does not consume `ink`: the secret card carries its own fixed deep indigo-violet surface (see PopopxSecureSheetView.swift:413);
            // switching to the SMP solid violet would make "a clickable message" and "a vault door" indistinguishable.
            PopopxSecureBubbleMount(payload: payload,
                                    target: item.secureTarget,
                                    incoming: item.side == .received)
        case let .profile(payload):
            // Same reason as the secret branch: the business card carries its own fixed surface (deep indigo-violet / Cabin teal, chosen by delivery),
            // consuming `ink` would draw "a clickable message" and "a vault door" as the same thing.
            ProfileCardBubbleView(payload: payload,
                                  target: item.profileTarget,
                                  incoming: item.side == .received,
                                  channel: item.channel,
                                  createdAt: item.createdAt)
        case let .commerce(content):
            // Same family: these cards carry their own surfaces and do not consume `ink` (the opening section of `PopopxCommerceCards.swift` says why).
            switch content {
            case let .gift(payload):
                PopopxGiftCardBubble(payload: payload, context: commerceContext)
            case let .creditGift(payload):
                PopopxCreditGiftBubble(payload: payload, context: commerceContext)
            case let .packet(payload):
                PopopxRedPacketBubble(payload: payload, context: commerceContext)
            case let .channel(payload):
                PopopxChannelAccessBubble(payload: payload, context: commerceContext)
            }
        case let .serviceCard(card):
            // The service-account card reads its own newest state from `PopopxEcoStore` and routes action buttons through
            // `PopopxEcoActionRunner`, so the bubble here is a thin shell that only hands the manifest and the chat's id to the view.
            // `item.contactId` is the contact id for a direct chat and the group id for a group; the runner's `send` path
            // resolves the contact from that id, and in a group it returns `.sendFailed` (the group id is not a contact id), which
            // the view shows as a disabled button. That is the honest answer: a card in a group has no single contact to send to.
            ServiceCardBubbleView(card: card, contactId: item.contactId ?? 0)
        case let .nodeUpdate(notice):
            // No `contactId` is threaded in, unlike the service card above: `answerUpdate` sends on the
            // bonded node's own contact (`nodeContactId`), so a row cannot decide where a command goes.
            PopopxNodeUpdateCard(notice: notice)
        case let .agentTask(task):
            // Unlike the node card, the receipt here is addressed to the conversation's own contact,
            // so the row's `contactId` is exactly what the card needs; a group row leaves it 0 and the
            // card renders read-only rather than guessing a destination.
            PopopxAgentTaskCard(task: task, incoming: item.side == .received, contactId: item.contactId ?? 0)
        }
    }

    /// Fallback when the mount point gives no landing target: `target` and `chatId` both stay empty, so the four cards stop in the read-only slot.
    /// Better one clickable button fewer than using a guessed chatId to reply a signal into another conversation or sign a credential there.
    private var commerceContext: PopopxCommerceCardContext {
        item.commerceContext ?? PopopxCommerceCardContext(target: nil, incoming: item.side == .received)
    }

    /// Bottom line: time + receipt + badge. All three are secondary information, so they share one `meta` ink,
    /// and only the badge carries a channel colour of its own — one primary colour per row.
    @ViewBuilder private func footer(_ ink: PopopxBubbleInk) -> some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            if let timeText = item.timeText {
                Text(verbatim: timeText)
                    .font(PopopxType.caption)
                    .foregroundStyle(ink.meta)
                    .accessibilityHidden(true)
            }
            if let receipt = item.receipt {
                Image(systemName: receipt.symbolName)
                    .font(PopopxType.caption)
                    .imageScale(.medium)
                    .foregroundStyle(receiptIsDanger(receipt) ? ink.failure : ink.meta)
                    .accessibilityHidden(true)
            }
            PopopxBadge(channel: item.channel, monochromeInk: ink.monochromeBadgeInk)
        }
        .font(PopopxType.caption)
    }

    /// System row: centred, no ground, no badge — it never passed through any channel.
    private func eventLine(_ text: String) -> some View {
        Text(text)
            .font(PopopxType.caption)
            .foregroundStyle(PopopxPalette.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: item.maxWidth)
            .padding(.vertical, PopopxMetrics.space2XS)
            .accessibilityLabel(text)
    }

    /// A row says only "who sent what, over which channel". All icons are hidden; the semantics are carried by the text.
    private var spoken: String {
        var parts: [String] = []
        if let author = item.author { parts.append(author) }
        parts.append(item.content.spokenText)
        if let timeText = item.timeText { parts.append(timeText) }
        if let receipt = item.receipt { parts.append(receipt.words) }
        if item.channel != .none { parts.append(item.channel.spoken) }
        return parts.joined(separator: "，")
    }

    /// Red appears only in the failure state, and only on a card surface: `dangerInk` has no guaranteed contrast on a solid `brand`/`mesh`,
    /// in which case the same symbol uses the bubble's own ink. The predicate follows the states where the live app's `statusIcon` gives `.red`.
    private func receiptIsDanger(_ receipt: PopopxBubbleReceipt) -> Bool {
        if case .failed = receipt { return true }
        return false
    }
}

/// The bubble's whole set of inks. It binds "ground + body + secondary + badge drawing" into one value, so a 3rd combination cannot appear.
private struct PopopxBubbleInk {
    let fill: Color
    let text: Color
    let meta: Color
    /// Card surface → the badge may use the channel colour; solid → the badge degrades to the same ink, see `PopopxBadge`.
    let onCard: Bool
    /// Red only on a card surface; on a solid ground it falls back to the bubble's own ink.
    let failure: Color
    let caution: Color

    /// Whether the badge must degrade to "the same ink": solid = yes, card surface = no (use the channel colour).
    var monochromeBadgeInk: Color? { onCard ? nil : text }

    init(channel: PopopxBubbleChannel, side: PopopxBubbleSide) {
        switch (side, channel) {
        case (.sent, .smp):
            fill = PopopxPalette.brand
            text = PopopxPalette.onBrand
            meta = PopopxPalette.onBrand
            onCard = false
            failure = PopopxPalette.onBrand
            caution = PopopxPalette.onBrand
        case (.sent, .mesh):
            // Ruling 3: sender bubbles uniformly use the modern deep indigo-violet primary (brand); offline Mesh is distinguished by the teal Bluetooth ripples + hop micro-badge at the bottom right.
            fill = PopopxPalette.brand
            text = PopopxPalette.onBrand
            meta = PopopxPalette.onBrand
            onCard = false
            failure = PopopxPalette.onBrand
            caution = PopopxPalette.onBrand
        case (.sent, .awaitingRelay), (.sent, .none):
            // Ruling 3: sender bubbles uniformly use the modern deep indigo-violet primary (brand); awaiting-relay / not-sent is distinguished by the grey clock badge at the bottom right.
            fill = PopopxPalette.brand
            text = PopopxPalette.onBrand
            meta = PopopxPalette.onBrand
            onCard = false
            failure = PopopxPalette.onBrand
            caution = PopopxPalette.onBrand
        case (.received, _):
            // The receiver is always a card surface: channel information belongs to the badge (§2.1 rows 2 and 3).
            fill = PopopxPalette.card
            text = PopopxPalette.label
            meta = PopopxPalette.labelSecondary
            onCard = true
            failure = PopopxPalette.dangerInk
            caution = PopopxPalette.labelSecondary
        }
    }
}

// MARK: - Badge

/// Channel badge. One per row; the icon is decoration, the number and the `accessibilityLabel` are the information.
///
/// Drawing table (Docs/popopx-brand-spec.md §2.2):
/// | channel | on a card surface | on a solid ground |
/// |---|---|---|
/// | SMP | `lock.shield.fill` · `brand` | same-ink symbol |
/// | Mesh | `antenna.radiowaves.left.and.right` · `meshInk` + a `mesh` chip reading "N hops" (`onMesh`) | same-ink symbol + same-ink number |
/// | awaiting relay | `clock` · `labelSecondary` + reason | same-ink symbol + reason |
/// | no channel | nothing is drawn | same |
@MainActor
struct PopopxBadge: View {
    let channel: PopopxBubbleChannel
    /// Non-nil = the bubble is solid, the badge degrades to this ink, and never draws indigo on indigo or teal on teal (§1.1).
    var monochromeInk: Color? = nil

    var body: some View {
        if let spoken {
            badge
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityIdentifier("popopx.bubble.channel")
        } else {
            EmptyView()
        }
    }

    @ViewBuilder private var badge: some View {
        switch channel {
        case .none:
            EmptyView()
        case .smp:
            glyph(PopopxBubbleCopy.smpSymbol, tint: accent(PopopxPalette.brand))
        case let .mesh(hops):
            meshBadge(hops)
        case let .awaitingRelay(reason):
            HStack(spacing: PopopxMetrics.space2XS) {
                glyph(PopopxBubbleCopy.relaySymbol, tint: accent(PopopxPalette.labelSecondary))
                Text(verbatim: reason?.words ?? PopopxBubbleCopy.awaitingRelayPlain)
                    .font(PopopxType.microTag)
                    .foregroundStyle(accent(PopopxPalette.labelSecondary))
            }
        }
    }

    /// `.none` does not occupy an accessibility element: if there is no channel to tell, do not conjure a focusable point out of nothing.
    private var spoken: String? {
        channel == .none ? nil : channel.spoken
    }

    /// The teal badge: the symbol uses `meshInk` (on a card surface `mesh` is only 2.98:1, text must be ink),
    /// the number uses a `mesh` chip + `onMesh` — the same drawing as `PopopxCabinHopBadge` (PopopxCabinView.swift:1530-1542),
    /// and the number is written out even at 0 hops ("0 hops · direct").
    @ViewBuilder private func meshBadge(_ hops: Int) -> some View {
        let words = PopopxBubbleCopy.hopsWords(hops)
        HStack(spacing: PopopxMetrics.space2XS) {
            glyph(PopopxBubbleCopy.meshSymbol, tint: accent(PopopxPalette.meshInk))
            if let monochromeInk {
                Text(verbatim: words)
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(monochromeInk)
                    .accessibilityHidden(true)
            } else {
                Text(verbatim: words)
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(PopopxPalette.onMesh)
                    .padding(.horizontal, PopopxMetrics.space2XS)
                    .padding(.vertical, PopopxMetrics.space2XS / 2)
                    .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func glyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    /// On a solid ground no channel colour ever appears as a second ink: everything falls back to the bubble's own ink.
    private func accent(_ token: Color) -> Color { monochromeInk ?? token }
}

// MARK: - Batch channel decision (mounting seam)

/// What one neighbour can promise. Only the four fields that actually exist on `PopopxMeshPeer` are taken
/// （hopCount / lastSeenAt / rssi / isDirect，PopopxMeshEvents.swift:37-41）。
struct PopopxBubblePeerFact: Hashable {
    var hops: Int
    var lastSeenAt: Date
    var isDirect: Bool
    var rssi: Int8?

    init(_ peer: PopopxMeshPeer) {
        hops = peer.hopCount
        lastSeenAt = peer.lastSeenAt
        isDirect = peer.isDirect
        rssi = peer.rssi
    }

    func isFresh(now: Date, window: TimeInterval) -> Bool {
        now.timeIntervalSince(lastSeenAt) <= window
    }
}

/// One row of the decision table's input. The host can assemble it from the chat item alone, no await needed anywhere.
struct PopopxBubbleRowAddress: Hashable {
    /// The same key as `PopopxBubbleItem.messageKey`.
    var messageKey: String
    /// The contact id of this conversation; broadcast rows and unknown objects are nil.
    var contactId: Int64?
    /// Whether this message was "sent out". Only the sender needs the neighbour hop count re-verified.
    var sent: Bool
    /// Whether it is a real message. System rows, local notes, unreadable content = false, and get no channel at all
    /// (the same predicate as ChatsListView.swift:451-453 giving `.none` to `.local/.contactRequest/.invalidJSON`).
    var isMessage: Bool = true
}

/// All the decision table's truth values, a snapshot after one complete read. Every field can be passed by value; none is an environment or a singleton.
struct PopopxBubbleTransportSources: Hashable {
    /// The global fuse (`PopopxMeshRuntime.isFuseOn`, Shared/Model/POPOPXAPI.swift:3740).
    var fuseOn = false
    /// The radio tier (`PopopxMeshStreamState.radioState`, PopopxMeshStateSource.swift:27 + `isUsable`, PopopxMeshEvents.swift:25).
    var radioUsable = false
    /// Hop cap: `PopopxMeshConfig.default.fragmentRelayTtlCap` (Core/PopopxMeshConfig.swift:24, 7).
    var hopCap = 1
    /// The silence window: `peerReachabilityTimeout` (:68 in the same file, 15 seconds).
    var reachabilityWindow: TimeInterval = 15
    /// contactId → meshPublicKeyHex, the whole table read in one pass (IdentityMappingStore.swift:204 `allMappings()`).
    var bindings: [Int64: String] = [:]
    /// meshPublicKeyHex → neighbour facts.
    var peers: [String: PopopxBubblePeerFact] = [:]
    /// message key → the channel already classified by the merged timeline / radio state.
    var channels: [String: PopopxBubbleChannel] = [:]
    /// mesh message id → queue reason (`PopopxMessageRouter.pendingMessages()`, Router/PopopxMessageRouter.swift:866).
    var queueReasons: [String: PopopxQueueReason] = [:]
    /// app row id → mesh message id, from ruling 1's dual-id table
    /// (`recordedFlushedAppChatItemIDs()`, :878 in the same file; the app row key form is documented at POPOPXAPI.swift:3990).
    var meshKeyByRowKey: [String: String] = [:]
    /// The moment these values were read out. Freshness always uses it, never `Date.now`: redraw does not mean re-decision.
    var readAt = Date.now
    /// `false` = the table has not been read out yet. In that case no channel is guessed.
    var isLoaded = false
}

/// The result of one pass. Row rendering is only a dictionary lookup.
struct PopopxBubbleChannelTable: Hashable {
    private var channels: [String: PopopxBubbleChannel]
    var sourceReadAt: Date = Date.now

    init(channels: [String: PopopxBubbleChannel], sourceReadAt: Date = .now) {
        self.channels = channels
        self.sourceReadAt = sourceReadAt
    }

    /// Not found → give `.none`: no badge drawn, and no channel invented.
    func channel(for address: PopopxBubbleRowAddress) -> PopopxBubbleChannel {
        channels[address.messageKey] ?? .none
    }

    func channel(forKey messageKey: String) -> PopopxBubbleChannel {
        channels[messageKey] ?? .none
    }

    var count: Int { channels.count }
    var isEmpty: Bool { channels.isEmpty }
}

/// The mounting seam: read once, build the table once.
///
/// The host's usage (finished inside one `.task(id:)`, zero awaits in row rendering):
/// ```swift
/// let sources = await PopopxBubbleTransportResolver.loadSources(
///     fuseOn: runtime.isFuseOn,
///     state: runtime.stateSource.state,
///     timelineRows: runtime.timelineModel.result.rows,
///     mappingStore: runtime.mappingStore,
///     router: runtime.router
/// )
/// let table = PopopxBubbleTransportResolver.table(sources, rows: addresses)
/// ```
@MainActor
enum PopopxBubbleTransportResolver {
    /// Three actor hops read out all sources; everything else is a snapshot value the host is already observing. Beyond that there is no await at all.
    static func loadSources(
        fuseOn: Bool,
        state: PopopxMeshStreamState,
        timelineRows: [PopopxMeshTimelineRow],
        mappingStore: IdentityMappingStore,
        router: PopopxMessageRouter,
        config: PopopxMeshConfig = .default,
        now: Date = .now
    ) async -> PopopxBubbleTransportSources {
        var sources = PopopxBubbleTransportSources()
        sources.fuseOn = fuseOn
        sources.readAt = now
        sources.isLoaded = true
        sources.hopCap = Int(config.fragmentRelayTtlCap)
        sources.reachabilityWindow = config.peerReachabilityTimeout
        sources.radioUsable = state.radioState.isUsable

        // Neighbour table: one pass, indexed by hex (`peerID.hex`, Protocol/PopopxMeshProtocol.swift:71).
        var peers: [String: PopopxBubblePeerFact] = [:]
        peers.reserveCapacity(state.peers.count)
        for peer in state.peers { peers[peer.peerID.hex] = PopopxBubblePeerFact(peer) }
        sources.peers = peers

        // The classification of timeline rows (`channel` at MergedTimelineModifier.swift:188), then the radio's own reported
        // `awaitingRelayMessageIDs` (PopopxMeshStateSource.swift:40) fills in the ids the timeline did not cover.
        var channels: [String: PopopxBubbleChannel] = [:]
        channels.reserveCapacity(timelineRows.count + state.awaitingRelayMessageIDs.count)
        for row in timelineRows { channels[row.messageID] = PopopxBubbleChannel(row.channel) }
        for id in state.awaitingRelayMessageIDs where channels[id] == nil {
            channels[id] = .awaitingRelay(reason: nil)
        }
        sources.channels = channels

        // When the fuse is off, not one key in the binding table counts (the live app uses the same predicate: ChatsListView.swift:458-459),
        // so those three hops are not initiated at all.
        guard fuseOn else { return sources }

        var bindings: [Int64: String] = [:]
        var newestUpdate: [Int64: Date] = [:]
        let mappings = await mappingStore.allMappings()          // hop 1
        for mapping in mappings {
            // Only bindings that already point at a real contact are accepted (the meaning of `contactId`, IdentityMappingStore.swift:38-45).
            guard let contactId = mapping.contactId else { continue }
            if let seen = newestUpdate[contactId], seen >= mapping.updatedAt { continue }
            newestUpdate[contactId] = mapping.updatedAt
            bindings[contactId] = mapping.meshPublicKeyHex
        }
        sources.bindings = bindings

        var reasons: [String: PopopxQueueReason] = [:]
        let pending = await router.pendingMessages()             // hop 2
        for entry in pending { reasons[entry.messageId] = entry.reason }
        sources.queueReasons = reasons

        var meshByRow: [String: String] = [:]
        let flushed = await router.recordedFlushedAppChatItemIDs()  // hop 3
        for (meshMessageId, appItemId) in flushed {
            meshByRow[String(appItemId)] = meshMessageId
        }
        sources.meshKeyByRowKey = meshByRow
        return sources
    }

    /// Pure function: one pass finishes all rows — no task started, no environment read, no actor touched.
    static func table(
        _ sources: PopopxBubbleTransportSources,
        rows: [PopopxBubbleRowAddress]
    ) -> PopopxBubbleChannelTable {
        var resolved: [String: PopopxBubbleChannel] = [:]
        resolved.reserveCapacity(rows.count)
        for row in rows { resolved[row.messageKey] = channel(for: row, sources: sources) }
        return PopopxBubbleChannelTable(channels: resolved, sourceReadAt: sources.readAt)
    }

    /// The decision for a single row. The order is the priority; once an earlier rule hits, nothing below runs:
    /// 1. not a message → `.none`; 2. fuse off → the public network is the only truth → `.smp`;
    /// 3. it is in the queue → grey clock (with module 5's reason); 4. the timeline classified it → follow the classification,
    /// and for the teal one re-verify whether the hop count can still be promised; 5. an app row nobody claimed → `.smp`
    /// (the live app's same rule: rows in the app's own stream are by definition SMP, MergedTimelineModifier.swift:121).
    static func channel(
        for address: PopopxBubbleRowAddress,
        sources: PopopxBubbleTransportSources
    ) -> PopopxBubbleChannel {
        guard address.isMessage else { return .none }
        guard sources.fuseOn else { return .smp }
        guard sources.isLoaded else { return .none }

        let meshKey = sources.meshKeyByRowKey[address.messageKey]
        if let reason = sources.queueReasons[address.messageKey] ?? meshKey.flatMap({ sources.queueReasons[$0] }) {
            return .awaitingRelay(reason: PopopxBubbleQueueReason(reason))
        }

        guard let found = sources.channels[address.messageKey] else { return .smp }
        switch found {
        case .smp, .none:
            return .smp
        case let .awaitingRelay(reason):
            return .awaitingRelay(reason: reason)
        case let .mesh(hops):
            guard hops >= 0, hops <= sources.hopCap else {
                return .awaitingRelay(reason: .hopCountUnverifiable(hops: hops, cap: sources.hopCap))
            }
            // The sender's row says "I just sent this out through a neighbour", so the neighbour must still be inside module 4's reachability window
            // and the radio must still be on; the receiver's row is a historical fact and is not re-verified.
            if address.sent, !sources.radioUsable {
                return .awaitingRelay(reason: .peerUnreachable)
            }
            if address.sent,
               let contactId = address.contactId,
               let hex = sources.bindings[contactId],
               let peer = sources.peers[hex],
               !peer.isFresh(now: sources.readAt, window: sources.reachabilityWindow) {
                return .awaitingRelay(reason: .peerUnreachable)
            }
            return .mesh(hops: hops)
        }
    }
}

// MARK: - Mount point of the top approval banner

/// Manual-connection approval banner: it only **references** the one real banner in the package (`ManualPairingBannerView(model:)`,
/// PopopxMeshKit/Sources/PopopxMeshUI/ManualPairingBannerView.swift:368); it does not copy its wording or its decisions,
/// and it does not change that file either.
///
/// The live app already mounts it in one place: `.popopxMeshBanner(...)` at `ChatView.swift:119/127` (the package's
/// `popopxMeshBanner(_:)`, ManualPairingBannerView.swift:469), and that one sits on the safe area.
/// **Only one of the two may exist**: with both on, the user sees two identical approval banners and two approve buttons.
/// When the conversation flow is replaced wholesale, use the one below to put the banner at the top of the flow and remove those two modifier lines.
@MainActor
struct PopopxBubbleConsentBanner: View {
    let model: PopopxMeshBannerModel

    var body: some View {
        ManualPairingBannerView(model: model)
    }
}

// MARK: - Wording

/// The user-visible text of this file. As with the new views of the other phases: the literals are gathered here, the symbol table is gathered here too,
/// so that a rule like "only one badge symbol per line" can be checked (§6 icon glossary).
enum PopopxBubbleCopy {
    static let smpSymbol = "lock.shield.fill"
    static let meshSymbol = "antenna.radiowaves.left.and.right"
    static let relaySymbol = "clock"

    static let channelSmp = NSLocalizedString("SMP online encryption", comment: "")
    static let channelNone = NSLocalizedString("No channel used", comment: "")
    static let awaitingRelayPlain = NSLocalizedString("Awaiting relay", comment: "")

    static let reasonNoNetwork = NSLocalizedString("Awaiting relay · no internet", comment: "")
    static let reasonPeerUnreachable = NSLocalizedString("Awaiting relay · the neighbour is out of reach", comment: "")
    static let reasonSmpUnacknowledged = NSLocalizedString("Awaiting relay · not acknowledged over the internet", comment: "")
    static let reasonMeshRefused = NSLocalizedString("Awaiting relay · the mesh refused it", comment: "")
    static let reasonAwaitingUpgrade = NSLocalizedString("Awaiting relay · waiting for the card to upgrade", comment: "")
    static let receiptInFlight = NSLocalizedString("Sending", comment: "")
    static let receiptDelivered = NSLocalizedString("Delivered", comment: "")
    static let receiptRead = NSLocalizedString("Read", comment: "")
    static let receiptReceived = NSLocalizedString("Unread", comment: "")
    static let receiptFailed = NSLocalizedString("Delivery failed", comment: "")

    static func channelMesh(_ hops: Int) -> String {
        hops == 0 ? NSLocalizedString("Cabin offline, direct (0 hops)", comment: "") : String(format: NSLocalizedString("Cabin offline, %lld hops", comment: ""), hops)
    }

    /// The hop-count badge always carries a number (§1.4 item 3); at 0 hops "direct" is spelled out too, same as PopopxCabinView.swift:2625.
    static func hopsWords(_ hops: Int) -> String { hops == 0 ? NSLocalizedString("0 hops · direct", comment: "") : String(format: NSLocalizedString("%lld hops", comment: ""), hops) }

    static func awaitingRelay(_ reason: PopopxBubbleQueueReason) -> String { reason.words }

    static func reasonHopUnverifiable(_ hops: Int, _ cap: Int) -> String {
        String(format: NSLocalizedString("Awaiting relay · %1$lld hops is over the limit of %2$lld", comment: ""), hops, cap)
    }
}

// MARK: - B5 mount adapter (ChatItem -> PopopxBubbleItem)

/// The single mapping entry point from the live app's `ChatItem` to the bubble's input parameters.
///
/// `CIContent` (POPOPXChat/ChatTypes.swift:4862, **33 cases**) is **enumerated exhaustively** here: the `switch` has no
/// `default`, so if the Haskell side adds a case later the build fails, and the mapping table cannot quietly fall behind the protocol.
///
/// But "covered" is not the same as "handed to the bubble to draw". `PopopxBubbleBody` has only 5 tiers (this file :172), and thumbnails, players,
/// file download controls, link preview cards, quoted reply bars, call callbacks, join-group accept/reject are all beyond it - this file :174-176
/// spells that boundary out. Those rows all return `nil`, and on that basis the mount point keeps handing the **whole row** to the live app's `ChatItemView`,
/// instead of squashing it into `.media(name:detail:)` and quietly drawing the controls away (ruling A: tiered mounting, zero regression outranks full coverage).
@MainActor
enum PopopxBubbleMount {
    /// `nil` = the live app's `ChatItemView` stays responsible for this row.
    ///
    /// This round takes over **direct chats**: group/channel content rows get their avatar and member name drawn by the live app (`CIMemberNameView`),
    /// and the bubble has only one `author: String?`, so taking over would draw the avatar away. System rows (`.event`) never had an avatar,
    /// so extending to groups/channels only takes removing this one guard - left for a separate later round, because it means re-checking the sender
    /// that `eventItemViewText` splices in.
    ///
    /// The exceptions are the three rows of `groupBody` below (the location card, the gift card, the red packet); that boundary is written at that place.
    static func body(of ci: ChatItem, chat: Chat) -> PopopxBubbleBody? {
        guard !ci.isLiveDummy, !ci.localNote else { return nil }
        guard chat.chatInfo.chatType == .direct else { return groupBody(ci, chat: chat) }
        let isChannel = chat.chatInfo.isChannel
        switch ci.content {
        case let .sndMsgContent(mc), let .rcvMsgContent(mc):
            return msgBody(mc, ci: ci)
        case .sndDeleted, .rcvDeleted, .sndModerated, .rcvModerated, .rcvBlocked:
            return .withdrawn(ci.text(isChannel: isChannel))
        case .rcvIntegrityError, .rcvDecryptionError, .rcvMsgError, .invalidJSON:
            return .unavailable(ci.text(isChannel: isChannel))
        case .rcvDirectEvent, .rcvGroupEvent, .sndGroupEvent, .rcvConnEvent, .sndConnEvent,
             .rcvChatFeature, .sndChatFeature, .rcvChatPreference, .sndChatPreference,
             .rcvGroupFeature, .sndGroupFeature, .rcvChatFeatureRejected, .rcvGroupFeatureRejected,
             .sndDirectE2EEInfo, .rcvDirectE2EEInfo, .sndGroupE2EEInfo, .rcvGroupE2EEInfo:
            let text = ci.text(isChannel: isChannel)
            return text.isEmpty ? nil : .event(text)
        case .sndCall, .rcvCall:
            return nil
        case .rcvGroupInvitation, .sndGroupInvitation:
            return nil
        case .chatBanner:
            return nil
        }
    }

    /// The only takeover on the group-chat side: the location card, plus the gift card and red packet bodies; everything else still goes back to the live app's `ChatItemView`.
    ///
    /// Why the takeover is needed: the red packet body is `popopx://redpacket?id=...&n=...&sig=...`, and handing that to the live app means reading a
    /// signature verbatim to the user, while the person sending the packet already @-mentioned everyone in the group to open it. The same is true of
    /// `popopx://loc`: in a group it would degrade into one line of plain text with a link, exactly the failure mode described in `msgBody`.
    /// Why only these three: taking over the whole row would draw the avatar and the member name away with it (the ruling above);
    /// the member name branch is restored in `item` by `author: ci.memberDisplayName` from the same live-app source, the avatar cannot be restored.
    /// The location card is the only tier here that also covers channels (`isChannel`): a channel in the underlying chat app is also a group, and opening a
    /// voucher or a red packet would send a receipt back into this chat, which becomes a broadcast to all subscribers - per the prompt a red packet only does
    /// targeted-single or split-across-group, there is no channel tier. **Opening a location card sends nothing at all**: its two actions are
    /// `MKMapItem.openInMaps` and one write to the pasteboard (`PopopxLocationCardBubble`), so it never touches the receiving chat.
    private static func groupBody(_ ci: ChatItem, chat: Chat) -> PopopxBubbleBody? {
        let mc: MsgContent
        switch ci.content {
        case let .sndMsgContent(m), let .rcvMsgContent(m): mc = m
        default: return nil
        }
        guard case .text = mc else { return nil }
        if let location = PopopxLocationPayload.parse(from: mc.text) {
            return .location(location)
        }
        // Service-account cards in a group/channel are content (the brief's DevOps-alert case is a channel broadcast), so the same
        // family as `.commerce` applies here. `parseVisibleCard` only returns `mode == create` frames; an update is a control frame
        // and `PopopxSysMarker.isSignalText` already hides it before this function runs.
        if let card = PopopxEcoMarker.parseVisibleCard(in: mc.text) {
            return .serviceCard(card)
        }
        guard chat.chatInfo.chatType == .group, !chat.chatInfo.isChannel else { return nil }
        return PopopxCommerceContent.detect(in: mc.text).map(PopopxBubbleBody.commerce)
    }

    /// Content rows. The 7 `MsgContent` tiers other than text all have dedicated live-app controls; not one is taken over.
    private static func msgBody(_ mc: MsgContent, ci: ChatItem) -> PopopxBubbleBody? {
        switch mc {
        case .text:
            // Location cards are listed first, and they must outrank the three guards below: the payload carries `popopx://loc`,
            // which the live app's `formattedText`/`markdownBlocks` would read as a link, so this row would never reach
            // the card branch - on a real device it shows as "a location message silently degrading into one line of plain text", harder to catch than a crash.
            if let location = PopopxLocationPayload.parse(from: mc.text) {
                return .location(location)
            }
            // The secure payload has the same reason, and a harder one: what `PopopxSecurePayload.parse` recognises is `popopx://sec?...`,
            // and the invite-link prefix is `popopx:/` as well. If this branch sat after the three guards below, the live app would render a
            // secure message as "an add-contact invite from the peer" - that is a mistaken contact add, not merely an ugly line.
            if let secure = PopopxSecurePayload.parse(from: mc.text) {
                return .secure(secure)
            }
            // The encrypted profile must also outrank the three guards below, for the same reason as the two branches above: `popopx://profile?...`
            // would be read as a link by the live app's `formattedText`/`markdownBlocks`, and that line would stay plain text forever.
            // The order of the three branches does not matter - the three hosts (`loc`/`sec`/`profile`) never overlap, and each `parse` only recognises its own.
            if let profile = PopopxProfilePayload.parse(from: mc.text) {
                return .profile(profile)
            }
            // Gift cards and red packets are one family of tests and must also outrank the three guards below: `popopx://voucher`/`popopx://redpacket`
            // would be read as links by the live app, and that line would forever be nothing but a signed string of plain text.
            if let commerce = PopopxCommerceContent.detect(in: mc.text) {
                return .commerce(commerce)
            }
            // Service-account cards are the fifth family, and they must also outrank the three guards below for the same reason:
            // the `::POPOPX_ECO::` line is a JSON blob whose `u` field may carry a URL that the live app's `formattedText` would
            // turn into a link, and the whole line would then render as a plain-text URL instead of a card. `parseVisibleCard` only
            // returns `mode == create` frames, so an update never reaches this tier (the store mutates the existing row in place).
            if let card = PopopxEcoMarker.parseVisibleCard(in: mc.text) {
                return .serviceCard(card)
            }
            // The sixth family: a bonded Mac's signed upgrade notice. It must outrank the three guards below
            // for the same reason as the five above, and it mounts **here and not in `groupBody`** because the
            // card's buttons echo a `NODE_CMD` into the node channel — a group member could otherwise type
            // one and have this device deliver it to the user's own Mac. `body(of:)` only reaches `msgBody`
            // for a direct chat (:980), which is the whole of that guarantee, so it is stated rather than
            // re-checked. `PopopxNodeUpdateWire` still refuses a line whose commands are not update commands.
            if let notice = PopopxNodeUpdateWire.parseVisibleCard(in: mc.text) {
                return .nodeUpdate(notice)
            }
            // The seventh family: an agent task card. Same reason to outrank the three guards below —
            // its JSON line may carry a URL in `detail` that the live app would linkify. Mounted only
            // here, which `body(of:)` restricts to direct chats: the approval buttons mint a receipt
            // and send it to the chat's contact, and a group row has no single contact to answer.
            if let task = PopopxAgentTaskWire.parseVisibleCard(in: mc.text) {
                return .agentTask(task)
            }
            // Rows with rich text/mentions/markdown go to the live app: the bubble only draws plain `Text`, so links and @ would no longer be tappable.
            guard ci.formattedText == nil, ci.mentions == nil, ci.markdownBlocks == nil else { return nil }
            // Quoted reply bars and attachments are both outside the 6 tiers of `PopopxBubbleBody`.
            guard ci.quotedItem == nil, ci.file == nil else { return nil }
            // The markers below are drawn by the live app inside `CIMetaView`; the bubble's lower edge has no place for them (this file :199 "choose one of the two when mounting").
            guard ci.meta.itemDeleted == nil, !ci.meta.itemEdited, ci.meta.itemTimed == nil,
                  ci.meta.itemForwarded == nil, ci.meta.sentViaProxy != true,
                  ci.meta.msgVerified == nil, !ci.meta.isLive
            else { return nil }
            return mc.text.isEmpty ? nil : .text(mc.text)
        case let .unknown(_, text):
            return .unavailable(text)
        case .link, .image, .video, .voice, .file, .report, .chat:
            return nil
        }
    }

    /// Assembles the bubble's input parameters; only called after `body(of:)` has already produced content.
    static func item(
        _ ci: ChatItem,
        content: PopopxBubbleBody,
        chat: Chat,
        maxWidth: CGFloat,
        timestamp: Bool,
        tailVisible: Bool,
        table: PopopxBubbleChannelTable
    ) -> PopopxBubbleItem {
        // For retracted/unreadable/system rows the live app draws no tail (ChatItemClipShape.swift:55-60), so the bubble tightens no corner either.
        let tucked: Bool
        switch content {
        case .withdrawn, .unavailable, .event: tucked = false
        case .text, .media, .location, .secure, .profile, .commerce, .serviceCard, .nodeUpdate, .agentTask: tucked = tailVisible
        }
        // The secure slot has to be able to answer "which row to delete after it closes". Both ids are read off live-app objects verbatim only, never built, never guessed:
        // `chat.chatInfo.id` = `ChatInfo.id` (generated per case at ChatTypes.swift:2104-2112), `ci.id` = the message id.
        // Building our own key (something like `"@" + contactId`) means creating a second source of truth - once it drifts from `ChatInfo.id`,
        // what gets deleted is somebody else's message, and SMP will not raise an error. So here values are only carried, never manufactured; non-`.secure` stays nil.
        let secureTarget: PopopxSecureChatTarget?
        if case .secure = content {
            secureTarget = PopopxSecureChatTarget(chatId: chat.chatInfo.id, itemId: ci.id)
        } else {
            secureTarget = nil
        }
        // The encrypted-profile slot keys **differently** from the secure slot: secure uses the `ChatInfo.id` string (`getChat(_:)` looks it up),
        // while `PopopxProfileReadKey.chatId` is an `Int64` taken from `ChatInfo.apiId` (ProfileReaderView.swift:745-752
        // the delete path there finds the chat back by apiId). Timing is still counted **per row**: if the same person receives two profiles with the same name,
        // each has its own burn clock, so the key must carry `ci.id` and not profileId alone. Both ids are read off live-app objects verbatim only.
        let profileTarget: PopopxProfileReadKey?
        if case .profile = content {
            profileTarget = PopopxProfileReadKey(chatId: chat.chatInfo.apiId, itemId: ci.id)
        } else {
            profileTarget = nil
        }
        // Which chat the gift card/red packet slot signals back into. `apiId` is the very same number the routed `apiSendMessages` call used
        // (`getContactChat`/`getGroupChat` look it up too, ChatModel.swift:551-568), so these two places cannot each tell their own story;
        // for the `.invalidJSON` tier `apiId` is a made-up 0, so only direct/group are accepted and the rest stay nil, leaving the card read-only.
        let commerceContext: PopopxCommerceCardContext?
        if case .commerce = content {
            commerceContext = PopopxCommerceCardContext(
                target: PopopxCommerceTarget.commerceTarget(chatType: chat.chatInfo.chatType,
                                                             chatId: chat.chatInfo.apiId),
                incoming: !ci.chatDir.sent,
                // The chat key and name the gate card signs the local credential with: `ChatInfo.id` carried verbatim (same statement as `secureTarget`),
                // so the credential lives and dies with "this channel on this device" and was never portable across devices (explained in the keychain slot).
                chatId: chat.chatInfo.id,
                chatTitle: chat.chatInfo.displayName,
                // The gate card only recognises channels. Its test uses the same value as the channel info page slot (`GroupInfo.isChannel`),
                // and a chat whose groupInfo cannot be reached is always false, so the card stays at "this one is not in a channel".
                isChannel: chat.chatInfo.groupInfo?.isChannel == true
            )
        } else {
            commerceContext = nil
        }
        return PopopxBubbleItem(
            messageKey: String(ci.id),
            content: content,
            tail: PopopxBubbleTail(side: ci.chatDir.sent ? .sent : .received, tucked: tucked),
            channel: table.channel(forKey: String(ci.id)),
            author: ci.memberDisplayName,
            timeText: timestamp ? formatTimestampMeta(ci.meta.itemTs) : nil,
            receipt: receipt(of: ci),
            contactId: contactId(of: chat),
            secureTarget: secureTarget,
            profileTarget: profileTarget,
            commerceContext: commerceContext,
            createdAt: ci.meta.itemTs,
            maxWidth: maxWidth
        )
    }

    /// Delivery receipt. The test is the same place as the live app's `CIStatus.statusIcon` (ChatTypes.swift:4614-4627),
    /// only those two asset checkmarks are swapped for the tiers of `PopopxBubbleReceipt`.
    static func receipt(of ci: ChatItem) -> PopopxBubbleReceipt? {
        switch ci.meta.itemStatus {
        case .sndNew: .inFlight
        case let .sndSent(progress): progress == .partial ? .inFlight : .delivered
        case let .sndRcvd(status, progress):
            status == .ok ? (progress == .partial ? .delivered : .read) : .failed(nil)
        case .sndErrorAuth, .sndError, .sndWarning, .invalid: .failed(nil)
        case .rcvNew: .received
        case .rcvRead: nil
        }
    }

    static func contactId(of chat: Chat) -> Int64? {
        if case let .direct(contact) = chat.chatInfo { return contact.contactId }
        return nil
    }

    /// All row addresses needed to build the channel table. **Called exactly once, at the ChatView layer** - awaiting row by row is a pattern forbidden in this component
    /// (this file :17).
    static func addresses(for items: [ChatItem], chat: Chat) -> [PopopxBubbleRowAddress] {
        let contact = contactId(of: chat)
        var rows: [PopopxBubbleRowAddress] = []
        rows.reserveCapacity(items.count)
        for ci in items where body(of: ci, chat: chat) != nil {
            rows.append(
                PopopxBubbleRowAddress(
                    messageKey: String(ci.id),
                    contactId: contact,
                    sent: ci.chatDir.sent,
                    isMessage: ci.content.msgContent != nil
                )
            )
        }
        return rows
    }
}

// MARK: - Location card

/// All the wording of the location card. It shares its file with the payload and the rendering; see item 7 of the file header for the reason.
enum PopopxLocationCopy {
    /// The one-sentence body VoiceOver says for this bubble. **Without the channel** - the channel is
    /// spliced in front by `PopopxMessageBubble.spoken`, repeating it here would be read out twice.
    static func spoken(_ payload: PopopxLocationPayload) -> String {
        var parts = [NSLocalizedString("Location", comment: "")]
        if let name = payload.name { parts.append(name) }
        if let address = payload.address { parts.append(address) }
        parts.append(payload.coordinateString)
        return parts.joined(separator: "，")
    }

    /// The card's own action hint. SwiftUI appends "button" by itself, so this only says what happens on tap.
    static let hint = NSLocalizedString("Open the location menu", comment: "")
    static let openNavigation = NSLocalizedString("Open navigation in Apple Maps", comment: "")
    static let copyCoordinates = NSLocalizedString("Copy the coordinates", comment: "")
    static let copied = NSLocalizedString("Coordinates copied", comment: "")
    static let cancel = NSLocalizedString("Cancel", comment: "")
}

/// Rendering of one location message.
///
/// Red line (`location-prompt.md:72`): **a bubble in a list never embeds an interactive `MKMapView`** - that is a whole
/// GL rendering pipeline, and seven or eight rows on a screen means seven or eight of them. Here there is only a static bitmap rendered by `MKMapSnapshotter`, with
/// an in-process LRU (`PopopxLocationSnapshotCache`). If the image has not arrived, rendering failed, or this coordinate is being rendered by someone else,
/// it always falls back to the brand-coloured placeholder block: place name, address and coordinates are always there, only the image is missing.
///
/// The whole card is one borderless button that opens a `confirmationDialog` (navigate / copy coordinates). The channel badge is not drawn
/// here - `PopopxMessageBubble.footer` already owns the line with the time, the receipt and the badge.
private struct PopopxLocationCardBubble: View {
    let payload: PopopxLocationPayload
    let ink: PopopxBubbleInk
    /// The pin's colour has to tell the same channel as the badge in the bottom-right corner, and `PopopxBubbleInk` keeps the colour but not the conclusion,
    /// so the channel is passed in by itself.
    let channel: PopopxBubbleChannel

    @Environment(\.colorScheme) private var colorScheme
    @State private var snapshot: UIImage?
    @State private var showMenu = false
    /// The chat-list layer has no screen-level toast host: the `.popopxToast` contract is "mounted once per screen, pinned on top"
    /// (PopopxToast.swift:131), and I am not going to change ChatView for one receipt line. So it hangs above the card's own head -
    /// closest to the action, and not overstepping.
    @State private var toast = PopopxToastModel()

    var body: some View {
        Button(action: presentMenu) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                thumbnail
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(payload.displayName)
                        .font(PopopxType.meta)
                        .foregroundStyle(ink.text)
                        .lineLimit(2)
                    if let address = payload.address {
                        Text(address)
                            .font(PopopxType.caption)
                            .foregroundStyle(ink.meta)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: PopopxLocationSnapshotCache.size.width, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PopopxLocationCopy.spoken(payload))
        .accessibilityHint(PopopxLocationCopy.hint)
        // The title uses coordinates instead of the place name: a chat may have sent "home" twice, and the menu has to say which one it is.
        .confirmationDialog(
            payload.coordinateString,
            isPresented: $showMenu,
            titleVisibility: .visible
        ) {
            Button(PopopxLocationCopy.openNavigation) { openInMaps() }
            Button(PopopxLocationCopy.copyCoordinates) { copyCoordinates() }
            Button(PopopxLocationCopy.cancel, role: .cancel) {}
        }
        .popopxToast(toast)
        .task(id: cacheKey) {
            let image = await PopopxLocationSnapshotCache.shared.image(
                forKey: cacheKey,
                coordinate: coordinate,
                tint: markerTintColor,
                style: interfaceStyle
            )
            // If it cannot be fetched (no network, rate limited, this coordinate is being rendered by someone) keep things as they are: a map already drawn should not
            // be wiped back to the placeholder by one failed fetch. A changed key runs it again, and the cache-hit path is a plain table lookup.
            if let image { snapshot = image }
        }
    }

    // MARK: Image

    /// The payload itself does not know CoreLocation (PopopxLocation.swift file header item 1); coordinates are assembled at this layer.
    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: payload.latitude, longitude: payload.longitude)
    }

    /// Turning SwiftUI's `ColorScheme` into the UIKit trait: the base-map style, the pin colour resolution and the cache key, three places, all
    /// need it, and it is turned exactly once, here.
    private var interfaceStyle: UIUserInterfaceStyle { colorScheme == .dark ? .dark : .light }

    /// The cache key carries three things: coordinates, the pin's channel colour, light/dark. The channel colour is in the key because it really does get drawn into the bitmap -
    /// at the same coordinate SMP's is an indigo pin and Mesh's is a teal pin, dropping that part would cross-contaminate colours. Light/dark changes the base-map
    /// style (Apple ships a separate tile set for the dark base map).
    private var cacheKey: String {
        "\(payload.coordinateKey)|\(channel.isMesh ? "mesh" : "smp")|\(interfaceStyle == .dark ? "d" : "l")"
    }

    /// The pin colour tells the same channel as the badge in the bottom-right corner: indigo-violet = SMP, teal-green = Mesh (§1.1 item 2:
    /// hue is not borrowed across channels, so messages on the teal path keep teal on the map as well).
    private var markerColor: Color { channel.isMesh ? PopopxPalette.mesh : PopopxPalette.brand }

    /// Placeholder ink: the card surface (receiver) may use the channel colour, solid fill (sender) must fall back to the local ink - the test is the badge one,
    /// exactly (`PopopxBubbleInk.onCard` / `monochromeBadgeInk`).
    private var placeholderInk: Color { ink.onCard ? markerColor : ink.text }

    /// `UIColor(_:) + resolvedColor(with:)` is the only defensible way for a SwiftUI `Color` to land on the UIKit side
    /// (PopopxQRCardSheet.swift:145-149 is the same precedent).
    private var markerTintColor: UIColor {
        UIColor(markerColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: interfaceStyle))
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
            } else {
                // Placeholder: a very faint background layer + one pin. It is not the red "load failed" warning - with the image missing
                // this message is still readable, and an error should not sit in the message history long-term.
                //
                // Neither the background nor the pin **may use the channel colour itself**: the sender bubble is solid `brand`, drawing an indigo pin on indigo is the same as not drawing it
                // (§1.1, the same prohibition; what `PopopxBubbleInk.monochromeBadgeInk` does on the badge is exactly this).
                // The pin inside the snapshot is not bound by that restriction - it has the whole base map to give it contrast.
                placeholderInk.opacity(colorScheme == .dark ? 0.16 : 0.08)
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(placeholderInk)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PopopxLocationSnapshotCache.size.height)
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        }
        // The image is not announced separately: coordinates, place name and address are all in the two lines below and in the card's overall label.
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func presentMenu() {
        PopopxHaptics.selection()
        showMenu = true
    }

    /// Handed to Apple Maps straight into walking-navigation state - the reason people send a location is almost always "I am coming to you".
    private func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = payload.displayName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    private func copyCoordinates() {
        UIPasteboard.general.string = payload.coordinateString
        PopopxHaptics.notice(.success)
        toast.show(PopopxLocationCopy.copied)
    }
}

/// In-process map-snapshot cache: `coordinates + light/dark` -> bitmap, LRU.
///
/// The cap is sized against memory: one `size` (244x140 pt) bitmap at @2x is about 0.5 MB, 24 of them worst case is about 13 MB,
/// and what it buys is not re-rendering when you scroll back to the top half; beyond that you are trading the whole app's memory for a few rows already scrolled past.
///
/// This class **never imports Metal/GL and never holds an `MKMapView`**: it only stores
/// the one-shot output of `MKMapSnapshotter` (the other half of the red line at `location-prompt.md:72`).
@MainActor
final class PopopxLocationSnapshotCache {
    static let shared = PopopxLocationSnapshotCache()

    /// Thumbnail size (pt). The card's layout width and the snapshot's render size are the same number, so changing one changes both.
    static let size = CGSize(width: 244, height: 140)

    /// The **full width** of the snapshot viewport (metres): 800 m means 400 m east and west of the centre, enough to make out an intersection
    /// without blurring down to mere block colouring. It is far wider than the picker's working-surface viewport (`PopopxLocationPickerSheet.swift:443`) - the card is a thumbnail, the picker has to recognise a single house number.
    static let spanMeters: Double = 800

    private static let capacity = 24
    private static let renderScale: CGFloat = 2

    private var images: [String: UIImage] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []

    /// Take one snapshot: a hit returns it, a miss renders it now.
    ///
    /// If someone is already rendering the same key, return nil straight away - this branch falls back to the placeholder first and waits for the card's next
    /// `.task(id:)` re-run (scrolling back to the top half or switching light/dark both re-run it). No waiting queue: a chat holds
    /// a single-digit number of location messages, so queueing them is not worth this complexity.
    func image(
        forKey key: String,
        coordinate: CLLocationCoordinate2D,
        tint: UIColor,
        style: UIUserInterfaceStyle
    ) async -> UIImage? {
        if let hit = touch(key) { return hit }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        guard let image = await Self.render(coordinate: coordinate, tint: tint, style: style) else { return nil }
        store(image, forKey: key)
        return image
    }

    private func touch(_ key: String) -> UIImage? {
        guard let image = images[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return image
    }

    private func store(_ image: UIImage, forKey key: String) {
        while images.count >= Self.capacity, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
        images[key] = image
        order.removeAll { $0 == key }
        order.append(key)
    }

    private static func render(
        coordinate: CLLocationCoordinate2D,
        tint: UIColor,
        style: UIUserInterfaceStyle
    ) async -> UIImage? {
        // This type's ObjC name is `MKMapSnapshotOptions`, but the Swift side only accepts the nested spelling (measured with a probe:
        // writing the ObjC name directly errors with "has been renamed to 'MKMapSnapshotter.Options'").
        let options = MKMapSnapshotter.Options()
        options.size = size
        // Scale and light/dark are written into the same trait at once: the `scale` property is already marked
        // deprecated in this SDK ("Use traitCollection.displayScale"), and touching it breaks the 0-warning gate.
        options.traitCollection = UITraitCollection { traits in
            traits.displayScale = renderScale
            traits.userInterfaceStyle = style
        }
        // The viewport uses `region` rather than `cameraBoundary`: the latter does not exist on this SDK's Options (measured with a probe).
        options.region = MKCoordinateRegion(center: coordinate, span: span(around: coordinate))
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let base = snapshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = true
        return UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
            base.draw(at: .zero)
            // The pin is drawn dead centre: `region` was asked for around the target point anyway, so the step "picture centre = coordinate"
            // needs no `point(for:)`, and there is no need to manufacture an `MKAnnotation` for a static bitmap.
            if let pin = pin(tint: tint) {
                pin.draw(at: CGPoint(
                    x: (base.size.width - pin.size.width) / 2,
                    y: base.size.height / 2 - pin.size.height
                ))
            }
        }
    }

    /// One channel-coloured pin. `MKMarkerAnnotationView` is not used here: this SDK's `MKMapSnapshotOptions`
    /// no longer has an `annotationViews` property, and the marker defaults would also drag in a white title box -
    /// the red line "no third shade of blue beyond the two badge patches" holds on the map just the same.
    private static func pin(tint: UIColor) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        return UIImage(systemName: "mappin.circle.fill", withConfiguration: configuration)
            .map { $0.withTintColor(tint, renderingMode: .alwaysTemplate) }
    }

    /// Converting "metres" into latitude/longitude deltas: latitude 1 deg is about 111.32 km, and longitude has to be divided by cos(latitude), otherwise
    /// mid-to-high latitude viewports get squashed flat. The two deltas are apportioned by the card's aspect ratio so that `region`'s aspect matches the bitmap
    /// (when they disagree Apple makes it up itself, at the cost of an actual viewport a stretch wider or narrower than the nominal one).
    /// Near the poles cos -> 0, and there it falls back to the latitude tier: a narrower viewport is better than handing MapKit an inf.
    private static func span(around coordinate: CLLocationCoordinate2D) -> MKCoordinateSpan {
        let degreesPerMeter = 1.0 / 111_320.0
        let width = spanMeters * degreesPerMeter
        let height = spanMeters * Double(size.height / size.width) * degreesPerMeter
        let cosine = cos(coordinate.latitude * .pi / 180)
        return MKCoordinateSpan(
            latitudeDelta: height,
            longitudeDelta: cosine > 0.01 ? width / cosine : width
        )
    }
}

// MARK: - Secure card

/// The secure card plus "the one jump that opens it".
///
/// The card itself lives in `PopopxSecureSheetView.swift` (`PopopxSecureCardBubble`); this layer does only two things:
/// hand `PopopxSecureChatTarget` to the window manager, and record "this one can never be opened again" in its own state.
/// Why this layer exists instead of calling directly from `contentText`: `present` is asynchronous (a biometric wait sits in the middle),
/// while body is synchronous - after a failure the card changes colour, and that fact has to live in a View's `@State` for the redraw to reach it.
@MainActor
private struct PopopxSecureBubbleMount: View {
    let payload: PopopxSecurePayload
    /// Where this local record came from. `nil` is not "unknown, so take a gamble": the card drops straight into the cannot-be-opened tier.
    /// A wrong gamble costs somebody else's deleted message while this message is still in front of the user - neither debt can be paid back.
    let target: PopopxSecureChatTarget?
    let incoming: Bool

    @State private var damaged = false

    var body: some View {
        PopopxSecureCardBubble(
            ttlText: payload.summaryText,
            state: state,
            incoming: incoming,
            onOpen: open
        )
    }

    private var state: PopopxSecureCardBubble.State {
        if damaged { return .damaged }
        if target == nil { return .unlocated }
        return .locked
    }

    private func open() {
        guard let target else { return }
        // This Task is not stored: a biometric wait sits in the middle, and neither list recycling nor going to background should cancel
        // a "view" the user already pressed. The thing that has to clean up is the window itself (the lifecycle clause of anti-theft module five).
        Task { @MainActor in
            // Presence check gate (anti-theft module two): the secure card holds "look once and it is destroyed" content, exactly the slot
            // a bystander hammering the fingerprint sensor is trying to get. The window opens only once it passes; when blocked this place **pops nothing** - module two has already
            // put the user behind the full-screen cover, and layering "operation cancelled" on top would only add a spurious signal.
            guard await PopopxBehaviorGuard.shared.authorized(reason: NSLocalizedString("Confirm this is you before opening the top-secret message", comment: "")) else { return }
            if let failure = await PopopxSecureWindowManager.shared.present(payload: payload, target: target) {
                if failure.marksCardDamaged { damaged = true }
                // Goes through `Text(verbatim:)`: `showAlertMsg` takes a `LocalizedStringKey`
                // (ContentView.swift:559), a runtime string does not convert to it, and it should not be looked up in the format table either.
                AlertManager.shared.showAlert(
                    Alert(title: Text(verbatim: NSLocalizedString("This top-secret message will not open", comment: "")),
                          message: Text(verbatim: failure.userText))
                )
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private struct PopopxBubbleGallery: View {
    /// The secure payload used for previews: `make` runs AES-GCM once on this device and never touches the network, so it is self-contained mock data.
    /// The `try!` here holds because the input is a hard-written literal - `make` only throws for "empty body" and "over 32 KiB".
    private static let previewPayload = try! PopopxSecurePayload.make(
        plaintext: "Top-secret preview text. It never shows in the list.",
        ttlSeconds: 30
    )

    private static let rows: [PopopxBubbleItem] = [
        PopopxBubbleItem(
            messageKey: "1",
            content: .text("Saturday at ten, same place as always. I will bring the drawings."),
            tail: PopopxBubbleTail(side: .received),
            channel: .smp,
            timeText: "09:12",
            receipt: nil
        ),
        PopopxBubbleItem(
            messageKey: "2",
            content: .text("Sure, I will message you when I get there."),
            tail: PopopxBubbleTail(side: .sent, tucked: true),
            channel: .mesh(hops: 3),
            timeText: "09:13",
            receipt: .delivered
        ),
        PopopxBubbleItem(
            messageKey: "3",
            content: .text("The drawings are in the attachment."),
            tail: PopopxBubbleTail(side: .sent, tucked: false),
            channel: .awaitingRelay(reason: .peerUnreachable),
            timeText: "09:14"
        ),
        PopopxBubbleItem(
            messageKey: "4",
            content: .media(name: "IMG_0421.HEIC", detail: "1.4 MB"),
            tail: PopopxBubbleTail(side: .received, tucked: true),
            channel: .mesh(hops: 0),
            timeText: "09:15",
            receipt: .read
        ),
        PopopxBubbleItem(
            messageKey: "5",
            content: .event("The other side switched on burn after reading"),
            channel: .none
        ),
        PopopxBubbleItem(
            messageKey: "6",
            content: .withdrawn("This message was retracted"),
            tail: PopopxBubbleTail(side: .sent),
            channel: .none,
            timeText: "09:16"
        ),
        PopopxBubbleItem(
            messageKey: "7",
            content: .location(
                PopopxLocationPayload(
                    latitude: 22.543096,
                    longitude: 114.057865,
                    name: "Shenzhen North Station",
                    address: "Liuxian Avenue, Minzhi Subdistrict, Longhua District, Shenzhen"
                )
            ),
            tail: PopopxBubbleTail(side: .sent),
            channel: .smp,
            timeText: "09:18",
            receipt: .delivered
        ),
        PopopxBubbleItem(
            // Coordinates only, no place name: the card's first line degrades to `coordinateString`, and this degradation path has to be
            // visible at a glance inside the canvas.
            messageKey: "8",
            content: .location(PopopxLocationPayload(latitude: 31.230416, longitude: 121.473701)),
            tail: PopopxBubbleTail(side: .received, tucked: true),
            channel: .mesh(hops: 2),
            timeText: "09:20"
        ),
        PopopxBubbleItem(
            // The secure slot. The payload goes through real encapsulation (`make` = one local AES-GCM, no network), and what the body says does not matter:
            // it is never shown in the list - all that can show is that lock-shield card and the duration.
            //
            // The `chatId: "preview"` here is **lazy**, not the forbidden "guess an id": inside the preview process
            // nobody calls `install(host:)`, so `present` returns `.hostNotInstalled` at the very first step and cannot delete any row.
            // On a real device these two values are carried verbatim from `chat.chatInfo.id` / `ci.id` only (see `item(...)` above).
            messageKey: "9",
            content: .secure(PopopxBubbleGallery.previewPayload),
            tail: PopopxBubbleTail(side: .received),
            channel: .smp,
            timeText: "09:22",
            secureTarget: PopopxSecureChatTarget(chatId: "preview", itemId: 9)
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            ForEach(PopopxBubbleGallery.rows, id: \.messageKey) { row in
                PopopxMessageBubble(row)
            }
        }
        .padding(PopopxMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(PopopxPalette.base)
    }
}

struct PopopxBubbleGallery_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBubbleGallery()
    }
}
#endif
