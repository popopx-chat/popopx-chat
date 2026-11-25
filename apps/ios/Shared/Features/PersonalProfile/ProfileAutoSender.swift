//
//  ProfileAutoSender.swift
//  POPOPX (iOS)
//
//  [Encrypted personal profile · module 4] the dual-mode intelligent sensing and automatic push engine.
//
//  This file does one thing only: turn a `PopopxProfileManifest` into a real message on the network, and make clear
//  which road it ended up taking and what it lost. It draws no interface, reads no photo library, and touches no on-disk layout (those three belong respectively to
//  `ProfileBuilderView`、`ProfileStorageManager`、`PersonalProfileModel`）。
//
//  ### Two trigger sources, one send chain
//  1. **Trigger source B (manual, inside chat)**: the `onSend` callback of `ProfileSendModeSheet` → `send(_:to:)`
//     (ProfileBuilderView.swift:818-836 hands over the manifest, and the ComposeView side is wired by the lead engineer).
//  2. **Trigger source A (automatic after scanning)**: the connection event bus → `handleContactConnected(contactId:)`
//     (the live location `Shared/Model/POPOPXAPI.swift:2651`-`:2665`, `case let .contactConnected(user, contact, _)`,
//     where the lead engineer adds one call line). With no armed scenario this function returns at its first `guard`,
//     leaving no log, creating no Task, reading no disk — something that should not happen for a single scan cannot be allowed to happen on every connection.
//
//  ### Why `scene=personal_profile` is not in the URI (a settled ruling, one-sentence version)
//  The string minted by `apiAddContact` belongs to the Rust core, and on the Swift side there is no precedent of appending query keys to an invite link
//  (`POPOPXAPI.swift:1050` hands back `CreatedConnLink`, `APITypes.swift:185` only replaces the prefix);
//  `popopxChatLink()` rewrites the `popopx:/` prefix into `https://popopx.chat/`;
//  while on the offline road `PopopxOfflineBridge.forbiddenLinkCharacters` (:101) explicitly forbids `$ \ " '`.
//  So this marker can only be **local arming metadata**, consumed by the `contactConnected` event that is already present —
//  putting the marker into the URI would mean changing the protocol, putting it into local state only means changing this one file.
//
//  ### The delivery method is not chosen by the user, it is decided by the link
//  `deliveryMode` is always `.fullMedia` in a draft (the ruling at ProfileBuilderView.swift:22-24). At the moment of sending, this file
//  asks the live decision maker (`PopopxComposerRouting`, `Shared/Features/ChatRoom/PopopxInputBar.swift:324`):
//  only when it says Bluetooth is the only path does it perform the `.meshTextOnly` downgrade and write `omittedMediaCount`. Counting signal strength ourselves,
//  judging `NWPathMonitor` ourselves, guessing at neighbours ourselves, would all add a second decision table outside module 5 — and once that table drifts,
//  "which channel the next one takes" in the interface and the channel actually taken talk past each other from then on.
//
//  The decision table's conclusion for "content carrying media" is always `.richContent` (PopopxInputBar.swift:359-:361), so this file
//  reports `hasAttachments` truthfully (a profile hung with original media files really cannot be carried), and when downgrading it **first projects through
//  `manifest.textOnly` and asks the decision table again**, and what the mesh branch sends out is the downgraded plain-text index payload itself.
//
//  `data=<base64url(JSON)>` is **obfuscation**, not encryption: this manifest segment carries no key of its own; what keeps it secret is the transport —
//  the public-network leg is SMP end-to-end, the Bluetooth leg is Cabin running over a Noise channel, and neither is something that can be added from here.
//
//  ### The original media files go through ordinary XFTP attachments
//  The index payload (that `popopx://profile?…` line) arrives first, then images/videos are sent one by one in the manifest's order. Each attachment's
//  file name carries an identifier that can be correlated back to the profile (see `attachmentFileName`): **the receiving side uses this file name to group the delivered
//  attachments under `profileId`**. ⚠️ Whether a sender-defined file name appears verbatim on the receiver's `CIFile.fileName`
//  has not been verified end to end by this file (the only basis is that `fileName` is an item on the wire and that `CIFile: Decodable`,
//  `POPOPXChat/ChatTypes.swift:5181`); see the delivery report for details.
//
//  ### The background window of about 30 seconds
//  The continuation window given by APNs silent pushes and `beginBGTask` (`POPOPXAPI.swift:71`-`:91`) is only about 30 seconds by system convention,
//  and `expirationHandler` may cut it short at any moment. So before every send the media queue asks once about
//  `UIApplication.shared.backgroundTimeRemaining`, stops when the window is too small, and records the already delivered mediaIds into
//  `pendingMedia` (an in-memory table, key = profileId + contactId), skipping them the next time the same profile goes to the same person.
//  This table **does not go to disk**: `ProfileStorageManager` is already this feature's only storage path, and opening a further
//  persistence channel for one unfinished queue would cost an index copy of "which media the user has sent" left in the backup. **Forgotten on restart**,
//  that is the real boundary of this implementation; it does not falsely claim resumable transfers.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import POPOPXChat
import PopopxMeshKit
import SwiftUI
import UIKit

// MARK: - Send result

/// What a send finally became. The four branches are exclusive: full media sent, downgraded text sent, refused by the rules, the link itself failed.
enum PopopxProfileSendOutcome: Hashable, Sendable {
    /// The public-network SMP branch: the index payload was handed into the send chain, and the media queue up behind it.
    /// - `indexSent`: whether the index payload line was accepted by the server (false = not one line went out, so naturally no media either).
    /// - `mediaQueued`: how many original media items were actually queued this time. It **excludes** the items already delivered in the previous background window
    ///   (they are skipped by `pendingMedia`, the reason is in the file header's "30-second window" section).
    case sentFullMedia(indexSent: Bool, mediaQueued: Int)
    /// The Bluetooth Mesh branch: only the plain-text index payload was sent. `omittedMediaCount` is taken from the downgraded manifest.
    case sentMeshTextOnly(omittedMediaCount: Int)
    /// A rule-level refusal: the content is fine, but this send should not have happened at all (wrong conversation, profile not saved, bytes over budget…).
    case refused(PopopxProfileSendRefusal)
    /// A link-level failure: everything that should be sent was attempted, and the network or the core did not catch it. `reason` is a one-line Chinese string for the user.
    case failed(reason: String)
}

/// The reason for refusing. Every one can be read out by the interface directly, so it carries its own sentence; `nil` = this one should not be said from here.
enum PopopxProfileSendRefusal: Hashable, Sendable, CustomStringConvertible {
    /// There is no saved profile on this device (the only possible refusal on the scan-triggered automatic road).
    case noSavedProfile
    /// The conversation does not currently allow sending (`ChatInfo.sendMsgEnabled` is false, ChatTypes.swift:2260).
    case sendDisabled
    /// The target is not a 1:1 direct contact: groups, channels, this device's notes, and connections awaiting acceptance are all excluded.
    case notDirectContact
    /// Even the downgraded plain-text card exceeds the byte budget of a single Mesh message.
    case payloadTooLarge(bytes: Int)
    /// The public network is unreachable and Bluetooth cannot carry it either (`reason` is copied from the live decision maker, not guessed by this file).
    case meshUnavailable(reason: String)
    /// The host side is not ready yet (no usable identity on this device / the payload is abnormally empty).
    case hostNotReady(reason: String)

    /// A one-line Chinese string that can go straight into `PopopxToast`. `nil` means some other interface is responsible for saying it.
    var explanation: String? {
        switch self {
        case .noSavedProfile:
            return SenderCopy.refusalNoSavedProfile
        case .sendDisabled:
            // The host already has its own wording for this one (ComposeView.swift:1545-1546 pops exactly "conversation not ready"),
            // and stacking two hints onto the same tap only makes the user think two different things broke.
            return nil
        case .notDirectContact:
            return SenderCopy.refusalNotDirectContact
        case let .payloadTooLarge(bytes):
            return String(
                format: SenderCopy.refusalTooLargeFormat,
                bytes,
                PopopxProfileMeshBudget.maximumMessageBytes
            )
        case let .meshUnavailable(reason):
            return String(format: SenderCopy.refusalMeshUnavailableFormat, reason)
        case let .hostNotReady(reason):
            return String(format: SenderCopy.refusalHostNotReadyFormat, reason)
        }
    }

    /// A stable identifier for logging. It never enters the interface: the interface reads only `explanation` (this is also where the requirement
    /// "do not print user-visible errors" lands in this file — the lines the user can hear all travel through return values, and `logger` holds only this identifier column).
    var description: String {
        switch self {
        case .noSavedProfile: return "noSavedProfile"
        case .sendDisabled: return "sendDisabled"
        case .notDirectContact: return "notDirectContact"
        case let .payloadTooLarge(bytes): return "payloadTooLarge(bytes: \(bytes))"
        case let .meshUnavailable(reason): return "meshUnavailable(reason: \(reason))"
        case let .hostNotReady(reason): return "hostNotReady(reason: \(reason))"
        }
    }
}

// MARK: - Arming scenario

/// Which profile tier to push automatically after a scan establishes the connection. It is **local state**, not part of the network (reason in the file header).
struct PopopxArmedProfileScene: Hashable, Sendable {
    let mode: PopopxProfileSendMode
    /// Seconds. Always 0 when `mode == .standard` (the requirement on the protocol side, PersonalProfileModel.swift:399-406).
    let ttlSeconds: Int
    /// When this arming expires. Expired means cleared: no switch may be left that "could suddenly send out a card at any moment because of some wholly unrelated connection".
    let expiresAt: Date
}

// MARK: - The engine

/// The singleton's thread-safety approach matches this feature's other UI-side objects: `@MainActor final class`.
///
/// There is **no** blocking I/O on the main actor: reading originals all `await`s into `ProfileStorageManager` (that is an actor),
/// The one disk write that turns bytes into a pending attachment lives inside `Task.detached` (see `stage(_:profileId:)`),
/// and the network side is entirely async anyway.
@MainActor
final class ProfileAutoSender {
    static let shared = ProfileAutoSender()

    /// The validity period of the arming scenario. 15 minutes: scan → the other side confirms → SMP connection handshake → `contactConnected`,
    /// a slow link does not need that long for these four steps, but the other side sitting on the confirmation page for a few minutes is perfectly normal. If no connection exists after this time,
    /// then that scan is already void (the user left, the other side never pressed, the network dropped) — keeping it would only, on some wholly unrelated connection,
    /// suddenly send out a card, which is far more serious than "it was not sent".
    static let armingWindowSeconds: TimeInterval = 900

    /// When the background window drops below this many seconds, no new send is started: one XFTP upload + SMP ACK takes less than 5 seconds, but **starting**
    /// a send and then having the system cut it mid-way leaves the user looking at an attachment stuck at "transferring" forever.
    static let backgroundResumeFloorSeconds: TimeInterval = 5

    /// The armed tier. `nil` = not armed, so `handleContactConnected` can return directly.
    private(set) var armedProfileScene: PopopxArmedProfileScene?

    private let store = ProfileStorageManager.shared

    /// Whether this arming's duration is "bound to that contact". See `armProfileScene(mode:ttlSeconds:ttlIsBoundToContact:)`.
    private var armedTTLIsBoundToContact = false

    /// The mediaIds **already delivered** from the previous round of the media queue (which the background window may have cut off).
    /// Key = profileId + contactId: sending the same profile to another person must resend the full set, skipping only happens for the same person.
    private var pendingMedia: [MediaKey: Set<String>] = [:]

    /// The primary key of a delivered record. A standalone type rather than a `"profileId:contactId"` concatenation: a concatenation must itself guarantee
    /// that the separator never appears inside a member, whereas here the two members' types have already locked them down.
    private struct MediaKey: Hashable {
        let profileId: String
        let contactId: Int64
    }

    private init() {}

    // MARK: Arming and cancelling

    /// Arm the "automatic push after a scan establishes the connection". The marker is stored on this device instead of being stuffed into the invite URI — reason in the file-header section
    /// (`apiAddContact` has no precedent for appending query keys, `popopxChatLink` rewrites the prefix, and the offline bridge forbids `$ \ " '`).
    ///
    /// - Parameter ttlIsBoundToContact: true = the duration chosen this time is the duration that person will get;
    ///   false = only the mode is carried, the duration keeps the saved profile's own field. `PopopxArmedProfileScene`'s three fields are
    ///   fixed by the contract (mode/ttlSeconds/expiresAt), so this field can only live in this class and does not go into that struct.
    func armProfileScene(mode: PopopxProfileSendMode, ttlSeconds: Int, ttlIsBoundToContact: Bool) {
        let effectiveTTL: Int
        switch mode {
        case .standard:
            effectiveTTL = 0
        case .ephemeral:
            // An out-of-range duration is pulled into the range the protocol allows right here, instead of handing out 0 or 3000 and
            // letting `PopopxProfilePayload.make` refuse it inside an automatic send the user never sees
            // (PersonalProfileModel.swift:389-411): at the moment of arming nobody is waiting for an error, so clamping the value is the only
            // meaningful handling. The three UI tiers already fall inside the range, so this clamp catches stray values passed in from elsewhere.
            effectiveTTL = min(
                max(ttlSeconds, PopopxProfilePayload.minimumTTLSeconds),
                PopopxProfilePayload.maximumTTLSeconds
            )
        }
        armedTTLIsBoundToContact = ttlIsBoundToContact
        armedProfileScene = PopopxArmedProfileScene(
            mode: mode,
            ttlSeconds: effectiveTTL,
            expiresAt: Date().addingTimeInterval(Self.armingWindowSeconds)
        )
        logger.notice("POPOPX profile: scan auto-push armed (\(mode.rawValue, privacy: .public), ttl=\(effectiveTTL, privacy: .public), boundToContact=\(ttlIsBoundToContact, privacy: .public))")
    }

    /// Cancel the arming. Idempotent: calling it while nothing is armed does nothing at all.
    func cancelArmedProfileScene() {
        guard armedProfileScene != nil else { return }
        armedProfileScene = nil
        armedTTLIsBoundToContact = false
        logger.notice("POPOPX profile: scan auto-push disarmed")
    }

    // MARK: Trigger source A: automatic push after a scan establishes the connection

    /// Called by the connection event bus (live location `POPOPXAPI.swift:2640`-`:2665`).
    ///
    /// Three hard requirements, all written in these few lines:
    /// 1. Not armed → return at the first `guard`: no disk read, no Task, no log. This function is called on **every single**
    ///    connection, so making it the origin of a side effect is giving every ordinary friend-adding action a chance to silently send a card.
    /// 2. Arming expired → clear it on the spot and return, never carrying a voided tier further down the road.
    /// 3. Send only when the conversation is found. When it is not found the arming is **kept** (letting the validity field close itself): inside `contactConnected`,
    ///    `ChatModel.updateContact` and this call are in the same batch of main-thread work, so missing it this time does not mean it misses next time.
    ///
    /// The result of the automatic branch only goes into the log, never into an interface: no user is waiting for an answer on this path, and a successful push should simply
    /// be one more card appearing in the chat stream; the place to add a receipt for it is on the event-bus side (where the lead engineer wires it).
    func handleContactConnected(contactId: Int64) async {
        guard let scene = armedProfileScene else { return }
        guard scene.expiresAt > Date() else {
            cancelArmedProfileScene()
            logger.notice("POPOPX profile: arming expired, auto-push cancelled")
            return
        }
        guard let chat = ChatModel.shared.getContactChat(contactId) else { return }
        guard let saved = await store.loadEditable() else {
            cancelArmedProfileScene()
            logger.notice("POPOPX profile: no saved profile on this device, auto-push cancelled (\(PopopxProfileSendRefusal.noSavedProfile.description, privacy: .public))")
            return
        }
        // One scan, one push: no arming is kept regardless of the outcome. A failure is not retried either — the retry moment (the next connection)
        // is simply not the semantics of this same scan.
        cancelArmedProfileScene()
        let outcome = await send(applyScene(scene, to: saved), to: chat)
        switch outcome {
        case let .sentFullMedia(indexSent, mediaQueued):
            logger.notice("POPOPX profile: scan auto-push went over the internet (index delivered=\(indexSent, privacy: .public), \(mediaQueued, privacy: .public) media items queued)")
        case let .sentMeshTextOnly(omitted):
            logger.notice("POPOPX profile: scan auto-push went as mesh text only (\(omitted, privacy: .public) media items omitted)")
        case let .refused(refusal):
            logger.error("POPOPX profile: scan auto-push refused (\(refusal.description, privacy: .public))")
        case let .failed(reason):
            logger.error("POPOPX profile: scan auto-push failed (\(reason, privacy: .public))")
        }
    }

    /// Overlay the armed tier onto the saved profile. Only the two fields of this send change, the draft stays untouched
    /// (the same rule as `ProfileSendModeSheet`, ProfileBuilderView.swift:813-816).
    private func applyScene(_ scene: PopopxArmedProfileScene, to saved: PopopxProfileManifest) -> PopopxProfileManifest {
        var target = saved
        target.sendMode = scene.mode
        switch scene.mode {
        case .standard:
            target.ttlSeconds = 0
        case .ephemeral:
            if armedTTLIsBoundToContact {
                target.ttlSeconds = scene.ttlSeconds
            } else {
                // When it is not bound to the contact, the draft's own field is kept; the draft's 0 (left over from the permanent tier) must not be carried into the privacy tier,
                // otherwise `make` refuses the whole send with `invalidTTL(0)`.
                target.ttlSeconds = saved.ttlSeconds >= PopopxProfilePayload.minimumTTLSeconds
                    ? min(saved.ttlSeconds, PopopxProfilePayload.maximumTTLSeconds)
                    : PopopxProfilePayload.ttlOptions.isEmpty
                        ? PopopxProfilePayload.minimumTTLSeconds
                        : PopopxProfilePayload.ttlOptions[PopopxProfilePayload.ttlOptions.count / 2]
            }
        }
        return target
    }

    // MARK: Trigger source B: manual send inside the chat

    /// Send a profile to this conversation. The manifest handed back by `ProfileSendModeSheet` is its input parameter
    /// （`onSend: (PopopxProfileManifest) -> Void`，ProfileBuilderView.swift:822）。
    func send(_ manifest: PopopxProfileManifest, to chat: Chat) async -> PopopxProfileSendOutcome {
        // Conversation shape: only a 1:1 direct contact has a queue that can be written on the server side, and there is no other address through which a message could be delivered.
        guard let contactId = chat.chatInfo.contact?.contactId else {
            return .refused(.notDirectContact)
        }
        guard chat.chatInfo.sendMsgEnabled else {
            return .refused(.sendDisabled)
        }
        guard ChatModel.shared.currentUser != nil else {
            return .refused(.hostNotReady(reason: SenderCopy.hostNoActiveUser))
        }

        // Both payloads are minted in one go: the public-network one carries all media, the Bluetooth one is the `textOnly` projection. Both pass through the `make` gate
        // (validate first, then normalise, PersonalProfileModel.swift:389-411), so by the time the `delivery=mesh` line
        // reaches the network, `omittedMediaCount` and the block table are certainly self-consistent.
        let fullPayload: PopopxProfilePayload
        let meshPayload: PopopxProfilePayload
        do {
            fullPayload = try PopopxProfilePayload.make(manifest)
            meshPayload = try PopopxProfilePayload.make(manifest.textOnly)
        } catch let failure as PopopxProfileError {
            // The payload layer's own wording is already Chinese and already carries the concrete numbers (PersonalProfileModel.swift:329-350),
            // so no second set of sentences is invented here.
            return .failed(reason: failure.reasonText)
        } catch let failure as PopopxProfileMediaError {
            return .failed(reason: failure.reasonText)
        } catch {
            return .failed(reason: String(format: SenderCopy.unexpectedFormat, error.localizedDescription))
        }

        switch await route(contactId: contactId, fullPayload: fullPayload, meshPayload: meshPayload) {
        case let .viaMesh(message, omittedMediaCount):
            return await sendViaMesh(message, omittedMediaCount: omittedMediaCount)
        case let .viaSMP(eligibility):
            return await sendViaSMP(fullPayload, to: chat, contactId: contactId, eligibility: eligibility)
        case let .refused(refusal):
            return .refused(refusal)
        }
    }

    // MARK: Routing decision

    /// This file's entire judgement about the link. Both branches really exist, and every decision is borrowed from the live decision table.
    private enum RouteChoice {
        /// Public-network SMP: index payload + original media. The snapshot is only used, on failure, to say which rule kept Bluetooth outside the door.
        case viaSMP(PopopxMeshEligibility)
        /// Bluetooth Mesh: the message handed to the router must have the **downgraded plain-text index payload** as its text
        /// (`meshPayload.messageContent`, `delivery=mesh`), not the original one.
        case viaMesh(PopopxOutboundMessage, omittedMediaCount: Int)
        /// Neither road works, or the budget is exceeded.
        case refused(PopopxProfileSendRefusal)
    }

    private func route(
        contactId: Int64,
        fullPayload: PopopxProfilePayload,
        meshPayload: PopopxProfilePayload
    ) async -> RouteChoice {
        let eligibility = await PopopxInputBarModel.resolveFromRuntime(contactId: contactId)
        var context = PopopxComposerContext.directContact(contactId)
        // Report "this profile carries original media files" truthfully to the decision table: content carrying media should not be given to Bluetooth
        // (the `.richContent` rule at PopopxInputBar.swift:359-:361), so the answer of the first dispatch
        // only reflects "can this complete card go over Bluetooth", and for the one carrying media the answer is always "no".
        context.hasAttachments = fullPayload.manifest.mediaCount > 0

        switch PopopxComposerRouting.dispatch(
            text: fullPayload.messageContent,
            context: context,
            eligibility: eligibility,
            ttlSeconds: nil
        ) {
        case let .routeViaMesh(message):
            // For a profile with only text, the decision table releases Bluetooth directly. What is sent must still be the downgraded projection: its only change is
            // the `delivery=mesh` field, and the reader needs that field to draw Cabin's teal banner. The message the decision table minted
            // carries the original text, so here the text is swapped while the id and the address stay — retry idempotence rests on exactly that id.
            return meshChoice(eligibility: eligibility, from: message, payload: meshPayload)

        case .hostShouldSend:
            // Only "the public network really is down" (`false`; `nil` = NWPathMonitor has not reported yet, so it is guessed neither online nor down)
            // is worth asking once more with the downgrade. Having network, or an unknown state, both go back to the host's normal link (SMP + XFTP original media).
            guard eligibility.networkConnected == false else {
                return .viaSMP(eligibility)
            }
            var degradedContext = PopopxComposerContext.directContact(contactId)
            degradedContext.hasAttachments = false
            switch PopopxComposerRouting.dispatch(
                text: meshPayload.messageContent,
                context: degradedContext,
                eligibility: eligibility,
                ttlSeconds: nil
            ) {
            case let .routeViaMesh(message):
                return meshChoice(eligibility: eligibility, from: message, payload: meshPayload)
            case let .hostShouldSend(meshRefusal):
                // If the decision table still returns the message to the host after the downgrade, Bluetooth cannot carry it either. Then do **not** pretend SMP can still send:
                // offline, `apiSendMessages` only ends in one timeout failure, and stating the reason clearly is more useful than trying once.
                return .refused(.meshUnavailable(reason: Self.meshBlockText(meshRefusal)))
            case .ignoreEmptyDraft:
                return .refused(.hostNotReady(reason: SenderCopy.hostEmptyPayload))
            }

        case .ignoreEmptyDraft:
            // `messageContent` is never empty (degradeLine carries at least "👤 [Encrypted personal profile]",
            // PersonalProfileModel.swift:441-:443). Reaching here can only mean the payload contract was broken,
            // so it is reported as "the host is not ready" rather than kept silent.
            return .refused(.hostNotReady(reason: SenderCopy.hostEmptyPayload))
        }
    }

    /// Fold one decision-table-released downgraded payload into the mesh branch: measure the bytes first, and if it is over budget refuse it here,
    /// rather than handing out a card that is certain to flood the relay.
    ///
    /// What goes to the router is the **same id / same address** of the message the decision table minted, with only the text replaced by the downgraded payload —
    /// the id is the router's sole basis for deduplication and retry idempotence (`PopopxMessageRouter.swift:630-:643`), and swapping the id
    /// means letting the other side receive two exactly identical cards.
    private func meshChoice(
        eligibility: PopopxMeshEligibility,
        from message: PopopxOutboundMessage,
        payload: PopopxProfilePayload
    ) -> RouteChoice {
        guard eligibility.fuseOn else {
            // Never take mesh while the circuit breaker is off. The decision table already returns the message to the host when `fuseOn == false`, so this line
            // is normally unreachable; it stays because "no Bluetooth while the fuse is off" is a hard requirement that deserves a visible gate in the code,
            // rather than one only in a comment.
            return .refused(.meshUnavailable(reason: SenderCopy.meshFuseOff))
        }
        let text = payload.messageContent
        let bytes = text.utf8.count
        guard bytes <= PopopxProfileMeshBudget.maximumMessageBytes else {
            return .refused(.payloadTooLarge(bytes: bytes))
        }
        return .viaMesh(
            PopopxOutboundMessage(messageId: message.messageId, target: message.target, text: text, sentAt: message.sentAt),
            omittedMediaCount: payload.manifest.omittedMediaCount
        )
    }

    /// When the message still returns to the host after downgrading, how that one reason is worded for the user.
    ///
    /// The decision table's `explanation` (PopopxInputBar.swift:183-:192) deliberately adds a human sentence only to the rules "the content itself should not go over Bluetooth"
    /// and returns nil for the mesh-fact rules. The nil ones are filled in here because **offline + Bluetooth cannot carry it**
    /// is a scenario unique to this file: during an ordinary host send the user does not care whether the master switch is on, but here the user must know which field
    /// blocked this push, otherwise all they see is a card with nothing happening.
    private static func meshBlockText(_ reason: PopopxHostSendReason) -> String {
        switch reason {
        case .meshFuseOff: return SenderCopy.meshFuseOff
        case .bindingUnknown: return SenderCopy.meshBindingUnknown
        case .contactNotBoundToMesh: return SenderCopy.meshNotBound
        case .radioUnavailable: return SenderCopy.meshRadioOff
        case .peerOutOfRange: return SenderCopy.meshPeerOutOfRange
        case .notDirectContact: return SenderCopy.meshNotDirectContact
        default: return reason.explanation ?? SenderCopy.meshReasonUnknown
        }
    }

    // MARK: Branch B: Bluetooth Mesh (Cabin)

    private func sendViaMesh(
        _ message: PopopxOutboundMessage,
        omittedMediaCount: Int
    ) async -> PopopxProfileSendOutcome {
        let bytes = message.text.utf8.count
        logger.notice("POPOPX profile: handed to the Bluetooth mesh (\(bytes, privacy: .public) bytes ≈ \(PopopxProfileMeshBudget.fragmentCount(forBytes: bytes), privacy: .public) fragments, \(omittedMediaCount, privacy: .public) media items omitted)")
        // Does not throw and does not return nil: `PopopxMessageRouter.send(_:)` hands back a `PopopxRoutedMessage` carrying a conclusion
        // (PopopxMessageRouter.swift:629-:689), and every possibility is inside that one return value.
        let routed = await PopopxMeshRuntime.shared.router.send(message)
        switch routed.outcome {
        case let .smpAcknowledged(contactId):
            // The router chose the public network itself (with network available its policy is SMP first, `PopopxMessageRouter.swift:653`-:660).
            // The message handed out is the plain-text projection and not one original media file was queued — report it as "only text was sent", not as
            // "full media sent". ⚠️ The result enum (the four branches fixed by the contract) has no branch for "text over the public network", so the channel is
            // recorded in the log while the branch the user can read says only "the text went out"; details in the delivery report.
            logger.notice("POPOPX profile: Bluetooth allowed by the verdict, the router still delivers SMP-first (contact :\(contactId, privacy: .public); no media queued)")
            return .sentMeshTextOnly(omittedMediaCount: omittedMediaCount)
        case let .smpUnacknowledgedMeshParallel(contactId, peerMeshPublicKeyHex):
            logger.notice("POPOPX profile: the internet did not ACK within the limit, Bluetooth sent it concurrently (contact :\(contactId, privacy: .public) / neighbor \(peerMeshPublicKeyHex.prefix(8), privacy: .public))")
            return .sentMeshTextOnly(omittedMediaCount: omittedMediaCount)
        case let .smpUnacknowledgedNoMesh(contactId):
            // Unconfirmed on the public network and with no second leg. This attempt is still in flight inside the router and may later enter the fallback queue.
            logger.error("POPOPX profile: no ACK from the internet and no Bluetooth backup available (contact :\(contactId, privacy: .public))")
            return .failed(reason: SenderCopy.smpUnacknowledged)
        case let .meshSent(peerMeshPublicKeyHex):
            logger.notice("POPOPX profile: delivered over the mesh (neighbor \(peerMeshPublicKeyHex.prefix(8), privacy: .public))")
            return .sentMeshTextOnly(omittedMediaCount: omittedMediaCount)
        case let .queuedOffline(reason):
            // It entered the offline fallback queue, and when a neighbour reappears the router resends the same id. Reported as "plain text delivered",
            // but the queue side is the truth — already marked honestly as a weak point of this reading in the delivery notes.
            logger.notice("POPOPX profile: neither path worked, the card went into the mesh fallback queue (\(reason.rawValue, privacy: .public))")
            return .sentMeshTextOnly(omittedMediaCount: omittedMediaCount)
        case .refusedUnboundStranger:
            return .refused(.meshUnavailable(reason: SenderCopy.meshUnboundStranger))
        case let .duplicate(messageId):
            return .failed(reason: String(format: SenderCopy.failedDuplicateFormat, messageId))
        case let .nothingToReroute(messageId):
            return .failed(reason: String(format: SenderCopy.failedNothingToRerouteFormat, messageId))
        }
    }

    // MARK: Branch A: public-network SMP

    private func sendViaSMP(
        _ payload: PopopxProfilePayload,
        to chat: Chat,
        contactId: Int64,
        eligibility: PopopxMeshEligibility
    ) async -> PopopxProfileSendOutcome {
        // The index payload: shaped after `popopxSendPlainViaSMP` (ComposeView.swift:1678-1693) —
        // `apiSendMessages` + handing the returned ChatItem back to the timeline. `apiSendMessages` itself throws no error and
        // shows its own network error sheet (POPOPXAPI.swift:577-:613), so no second layer of prompting is stacked here.
        //
        // `ttl` is always passed nil: the profile's "view-once" tier is a destruction timer **on the recipient's screen**, not the lifetime of the
        // message on the SMP server. Stuffing 300 into `ttl` would make the index message disappear from the server, while "whether the recipient read it"
        // is governed by the clock at `ProfileStorageManager.readState`; mixing the two into one parameter is two semantics overwriting each other.
        let indexItems = await apiSendMessages(
            type: chat.chatInfo.chatType,
            id: chat.chatInfo.apiId,
            scope: chat.chatInfo.groupChatScope(),
            sendAsGroup: chat.chatInfo.sendAsGroup,
            live: false,
            ttl: nil,
            sign: false,
            composedMessages: [ComposedMessage(msgContent: .text(payload.messageContent))]
        )
        guard let indexItems, !indexItems.isEmpty else {
            logger.error("POPOPX profile: the index payload did not reach the internet (contact :\(contactId, privacy: .public), mesh prediction=\(String(describing: eligibility.prediction), privacy: .public))")
            return .failed(reason: SenderCopy.smpIndexFailed)
        }
        for item in indexItems {
            ChatModel.shared.addChatItem(chat.chatInfo, item)
        }
        let queued = await pushMedia(payload.manifest, to: chat, contactId: contactId)
        return .sentFullMedia(indexSent: true, mediaQueued: queued)
    }

    /// Push the original media files one by one in the manifest's order. Returns how many items were actually queued this time.
    private func pushMedia(_ manifest: PopopxProfileManifest, to chat: Chat, contactId: Int64) async -> Int {
        let media = manifest.blocks.compactMap { $0.media }
        guard !media.isEmpty else { return 0 }
        let key = MediaKey(profileId: manifest.profileId, contactId: contactId)
        var delivered = pendingMedia[key] ?? []
        var queued = 0
        // Background keep-alive: the whole queue is wrapped in `beginBGTask` (POPOPXAPI.swift:71-:91), and `defer` guarantees
        // that whichever branch is taken, this background task is handed back — missing one endTask means holding the app's background allowance open for good.
        let endTask = beginBGTask(nil)
        defer { endTask() }

        for item in media {
            guard !delivered.contains(item.mediaId) else { continue }
            if UIApplication.shared.backgroundTimeRemaining < Self.backgroundResumeFloorSeconds {
                pendingMedia[key] = delivered
                logger.error("POPOPX profile: the background window ran out, the media queue stops after \(delivered.count, privacy: .public) delivered items (profile \(manifest.profileId.prefix(8), privacy: .public)); this table is not persisted, so a restart does not recognize these items")
                return queued
            }
            guard let staged = await stage(item, profileId: manifest.profileId) else { continue }
            let items = await apiSendMessages(
                type: chat.chatInfo.chatType,
                id: chat.chatInfo.apiId,
                scope: chat.chatInfo.groupChatScope(),
                sendAsGroup: chat.chatInfo.sendAsGroup,
                live: false,
                ttl: nil,
                sign: false,
                composedMessages: [ComposedMessage(
                    fileSource: staged.file,
                    msgContent: .file(attachmentLine(profileId: manifest.profileId, media: item))
                )]
            )
            guard let items, !items.isEmpty else {
                // `apiSendMessages` has already shown the failure of this one to the user; this item does not enter delivered,
                // so the next send of the same profile will try it once more.
                logger.error("POPOPX profile: the media original was not sent (media \(item.mediaId.prefix(8), privacy: .public))")
                continue
            }
            for chatItem in items {
                ChatModel.shared.addChatItem(chat.chatInfo, chatItem)
            }
            delivered.insert(item.mediaId)
            queued += 1
        }
        // Once all the media of this profile is in the other side's hands, this record is wiped: keeping it would turn "send it again" into "nothing was sent at all".
        if delivered.isSuperset(of: Set(media.map { $0.mediaId })) {
            pendingMedia[key] = nil
        } else {
            pendingMedia[key] = delivered
        }
        return queued
    }

    // MARK: Media → pending attachment

    /// One medium's original file on this device, and what it looks like as a pending attachment.
    private struct StagedMedia {
        let file: CryptoFile
    }

    /// Turn a profile original in the sandbox into a pending attachment. **This segment is the only heavy I/O in the whole chain**: reading up to 15 MB of bytes
    /// and writing them into XFTP's staging directory, so the whole block sits in `Task.detached` while the main actor only `await`s.
    ///
    /// Staging uses the app's existing `saveFile(_:fileName:encrypted:)` (`POPOPXChat/FileUtils.swift:271`) —
    /// that is precisely the same function underneath `saveImage`/`saveFileFromURL` (ImageUtils.swift:97-:104, :218-:241),
    /// so the profile adds no second storage path (red line: this feature's original-file storage is only the one place at `ProfileStorageManager`,
    /// what is written here is the sender-side temporary attachment area, exactly the same road as a user sending an image in a chat).
    private func stage(_ media: PopopxProfileMedia, profileId: String) async -> StagedMedia? {
        let load = await store.loadMedia(media, profileId: profileId)
        let url: URL
        switch load {
        case let .loaded(loaded):
            url = loaded
        case let .missing(mediaId):
            logger.error("POPOPX profile: this device has no original for this media item (media \(mediaId.prefix(8), privacy: .public)); skipped")
            return nil
        case let .unreadable(mediaId, reason):
            logger.error("POPOPX profile: the original on this device cannot be read (media \(mediaId.prefix(8), privacy: .public): \(reason, privacy: .public)); skipped")
            return nil
        }
        let wireName = Self.attachmentFileName(profileId: profileId, media: media, url: url)
        let encrypted = privacyEncryptLocalFilesGroupDefault.get()
        let staged: CryptoFile? = await Task.detached(priority: .utility) { () -> CryptoFile? in
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return saveFile(data, wireName, encrypted: encrypted)
        }.value
        guard let staged else {
            logger.error("POPOPX profile: the original could not be staged as an outgoing attachment (media \(media.mediaId.prefix(8), privacy: .public))")
            return nil
        }
        return StagedMedia(file: staged)
    }

    /// Attachment file name: `popopx-profile-<profileId>-<mediaId>.<ext>`.
    ///
    /// **The receiving side uses this file name to group the delivered attachments under `profileId`** — the `data=` manifest segment holds only the arrangement skeleton and
    /// byte counts, the media originals are ordinary XFTP attachments, and the two have no other connection point on the network. The extension is taken from the local path
    /// (`ProfileStorageManager.mediaURL` can only yield `jpg`/`mp4`, ProfileStorageManager.swift:167-:172, :373-:376),
    /// so this neither has to copy that extension table nor can it assemble a suffix the peer has never seen.
    ///
    /// `profileId`/`mediaId` are both `UUID().uuidString.lowercased()` (PersonalProfileModel.swift:116-:118, :177),
    /// the character set is `[a-z0-9-]`, so putting them straight into a file name is safe. ⚠️ Unlike the `saveFileFromURL` road, this does not pass through
    /// `uniqueCombine`: a name clash overwrites the same-named attachment in place, and a UUID-level mediaId decides that it cannot clash;
    /// and if it really did clash (the same profile resent), the bytes overwritten are the same bytes anyway.
    static func attachmentFileName(profileId: String, media: PopopxProfileMedia, url: URL) -> String {
        "popopx-profile-\(profileId)-\(media.mediaId).\(url.pathExtension)"
    }

    /// The visible text of the attachment's message. Always one line (the conversation list and the notification banner take exactly this line), and the correlation identifier
    /// is written into the text **as well**: should the sender-defined file name be rewritten on the peer, this line can still recognise the attachment back into its profile.
    private func attachmentLine(profileId: String, media: PopopxProfileMedia) -> String {
        let head = "👤 " + NSLocalizedString("[Encrypted profile · attachment]", comment: "POPOPX profile share") + " profile=\(profileId) media=\(media.mediaId)"
        guard let caption = media.caption else { return head }
        let oneLine = caption.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return oneLine.isEmpty ? head : "\(head) · \(oneLine)"
    }
}

// MARK: - Mesh byte budget

/// The byte ceiling of the Bluetooth road, all taken from real constants in the live app; this file invents no number whatsoever.
///
/// - `PopopxProximityFrame.maxWireBytes = 8_192` (`PopopxProximityEngine.swift:113`) is PopopxMeshKit's
///   only public ceiling for "how big a payload may be before it enters the core". ⚠️ It is written on the definition of the **near-field exchange frame**, and the BLE relay
///   road has no published equivalent constant (`PopopxMeshEngine` fragments automatically according to the link's `usablePayloadBytes`,
///   PopopxMeshEngine.swift:504-:458). This is **borrowing**, not "BLE really has this hard ceiling". The reason for borrowing:
///   a 6 KB manifest JSON would be cut into more than a dozen 469-byte fragments, which in a TTL 7 flood amounts to manufacturing
///   a broadcast storm for yourself, and a card's amount of text never needs that magnitude anyway — over the limit, the user should delete text rather than the relay carrying it for them.
/// - `fragmentSize = 469` / `maxMTU = 512` (`PopopxMeshConfig.swift:30`, `:32`) are only used to compute "how many fragments this card
///   would be cut into" for the log, and take no part in the refusal decision.
enum PopopxProfileMeshBudget {
    /// The maximum UTF-8 bytes allowed for a single mesh card message (including the line shown to a person).
    static let maximumMessageBytes = PopopxProximityFrame.maxWireBytes

    /// Estimates the fragment count from the real fragment size. Used only for logging, not for deciding: the decision looks only at `maximumMessageBytes`.
    static func fragmentCount(forBytes bytes: Int) -> Int {
        let fragment = PopopxMeshConfig.default.fragmentSize
        guard fragment > 0 else { return 1 }
        return (bytes + fragment - 1) / fragment
    }
}

// MARK: - Copy

/// All the Chinese in this file that a user can hear appears exactly once, here (ProfileBuilderView.swift:1283's
/// `private enum Copy` rule; because here it must cross a type boundary and be read by `PopopxProfileSendRefusal.explanation`,
/// it is a file-visible `enum` rather than a private member of some type).
private enum SenderCopy {
    static let refusalNoSavedProfile = NSLocalizedString("No profile has been saved on this device yet. Build one under Me → Encrypted profile and save it, then scan or send.", comment: "")
    static let refusalNotDirectContact = NSLocalizedString("An encrypted profile can only be sent to a 1-to-1 contact.", comment: "")
    static let refusalTooLargeFormat = NSLocalizedString("The plain-text card is %1$lld bytes, over the %2$lld byte limit for a single Bluetooth Mesh message; trim the text and try again.", comment: "")
    static let refusalMeshUnavailableFormat = NSLocalizedString("There is no internet right now and the Bluetooth mesh cannot carry this card either: %@", comment: "")
    static let refusalHostNotReadyFormat = NSLocalizedString("This profile cannot be sent for now: %@", comment: "")
    static let hostNoActiveUser = NSLocalizedString("No usable identity on this device yet", comment: "")
    static let hostEmptyPayload = NSLocalizedString("This profile has no content", comment: "")
    static let smpIndexFailed = NSLocalizedString("The card did not reach the internet; check your connection and try again.", comment: "")
    static let smpUnacknowledged = NSLocalizedString("The card was handed to the send queue, but the internet did not confirm it within the time limit; the mesh will resend it once the connection is back.", comment: "")
    static let meshFuseOff = NSLocalizedString("The mesh master switch is closed", comment: "")
    static let meshBindingUnknown = NSLocalizedString("The mesh binding table has not finished loading", comment: "")
    static let meshNotBound = NSLocalizedString("This contact has no mesh binding yet", comment: "")
    static let meshRadioOff = NSLocalizedString("Bluetooth is not available on this device right now", comment: "")
    static let meshPeerOutOfRange = NSLocalizedString("Their device has not appeared in the mesh for a long time", comment: "")
    static let meshNotDirectContact = NSLocalizedString("This chat is not a 1-to-1 direct chat", comment: "")
    static let meshUnboundStranger = NSLocalizedString("Their device has not exchanged mesh cards with yours; move closer once, or send over the internet", comment: "")
    static let meshReasonUnknown = NSLocalizedString("Bluetooth is not available right now", comment: "")
    static let failedDuplicateFormat = NSLocalizedString("This card (%@) is already in the relay queue, so it was not submitted twice.", comment: "")
    static let failedNothingToRerouteFormat = NSLocalizedString("The router no longer has a delivery record for this card (%@); please send it again.", comment: "")
    static let unexpectedFormat = NSLocalizedString("This profile cannot be sent: %@", comment: "")
}
