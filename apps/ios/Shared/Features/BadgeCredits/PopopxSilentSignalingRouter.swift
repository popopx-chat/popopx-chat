//  PopopxSilentSignalingRouter.swift
//
//  The single entry and exit for invisible signalling: sending and receiving `::popopx_sys::`, creating and deleting one-time SMP connections,
//  and one complete round trip of what "redemption" means in an end-to-end shape.
//
//  ### Signalling is ordinary SMP text (the landing shape ruled this round)
//  The prompt demands "the encrypted signalling channel is completely invisible to the UI". This app's `MsgContent` only has a visible tier,
//  the control tiers of `CIContent` are all produced by the Haskell core, and the Swift side has no interface for "send a message that never enters the timeline".
//  So signalling is a **plain text message**, invisibility is achieved by three layers, and it stops at those three layers:
//  1. Render suppression: three gates share `PopopxSysMarker.isSignalText` (that is the only copy of the criterion, see
//     the marker section of `PopopxBadgeCreditsModels.swift`) — the row inside a conversation `ChatView.swift:2323-2330`,
//     the conversation-list preview `ChatPreviewView.swift:301-307`, the notification banner `NtfManager.swift:254-262`.
//     The notification has to be gated separately: the banner is emitted synchronously before the `Task` that deletes the row, so "delete once used" cannot catch it;
//  2. deletion after it lands in the store: once the ACK completes, `apiDeleteChatItems(mode: .cidmInternal)`, no row kept locally
//     (the model update after deletion copies `Shared/Features/PersonalProfile/ProfileReaderView.swift:756-773`);
//  3. the temporary connection is deleted whole: the contact used for a one-time redemption calls `apiDeleteContact(.full(notify: false))` once the ACK is done.
//  The two leftovers are stated honestly rather than claimed clean: `.cidmInternal` only deletes this device's copy (no delete is broadcast to the other side,
//  the message itself long ago arrived there and stays in their store), and **a side running a different client (the desktop app) does not recognise
//  `::popopx_sys::`**, so it displays it as ordinary text and notifies as usual — these three gates only protect devices running this app.
//  Eliminating those two for real needs a dedicated message type or a new `CIDeleteMode` on the core side,
//  which is a Haskell-layer change and out of this round's scope.
//
//  ### Timing (why REQ is not sent at the step that establishes the connection)
//  After the recipient calls `apiConnect`, its own side is only a `PendingContactConnection`;
//  only after the giver accepts do **both** sides have a direct contact, and the recipient's `contactConnected` event
//  is precisely the signal that "the other side has already accepted". So REQ hangs on the recipient's `.contactConnected` (mount point
//  next to that case at `Shared/Model/POPOPXAPI.swift:2651`, the same shape as `ProfileAutoSender`).
//  Sending one step earlier simply cannot go out: that connection cannot carry a message yet.
//
//  ### Why a redemption can only ever return to the device that minted the voucher
//  The one-time link points at the giver's connection, and only the voucher holder can accept. The double-spend state machine lives in
//  `PopopxP2PVoucherVault.authorizeRedemption` (an actor serialising, flipping `redeemed` before signing),
//  and this layer is only responsible for "handing that criterion's result back to the other side as-is".
//
//  ### An ACK must match an initiation
//  Verifying a signature only proves "someone signed", not "this badge is for you". So every ACK has to match the one initiation this
//  device is waiting for (`awaitingAcks`); if it does not match, the whole thing is dropped and not even deleted (we do not clean up somebody else's timeline).
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts modifying project.pbxproj.

import Foundation
import os
import POPOPXChat

// MARK: - Landing point

/// The publication right for a channel threshold card, with only one copy of the criterion: this device's member record really is admin or above in that group.
/// The `memberCurrent` half cannot be dropped — an admin who has been demoted still holds the old conversation, and that branch should be blocked too.
/// The shape follows `GroupInfo.canAddMembers` (ChatTypes.swift:3083-3085).
/// Both the channel info page's cell (`PopopxGroupChatInfoView`) and `sendChannelAccess`'s guard go through it.
extension GroupInfo {
    var popopxCanPublishChannelThreshold: Bool {
        isChannel && membership.memberRole >= .admin && membership.memberCurrent
    }
}

/// Which conversation a commercial message is to be sent to. Carries only ids: neither `Contact` nor `GroupInfo` is Sendable,
/// and everywhere this type appears only needs "where to find this conversation", not the conversation's content.
///
/// `.group` serves the red packet and channel branches (cards, receipts); redemption signalling is always `.contact` — `awaitingAcks` keeps its books per chatId,
/// and a second person in the group would settle somebody else's entry (entry criterion: `PopopxCommerceSignalKind.acceptedInGroup`).
enum PopopxCommerceTarget: Hashable, Sendable {
    case contact(Int64)
    case group(Int64)

    var chatId: Int64 {
        switch self {
        case let .contact(id): id
        case let .group(id): id
        }
    }

    /// Takes the landing point from the conversation info. Conversations that are neither direct nor group (notes, contact requests, channels) return nil:
    /// in those conversations there is no "person on the other side" who could receive money.
    static func commerceTarget(chatType: ChatType, chatId: Int64) -> PopopxCommerceTarget? {
        switch chatType {
        case .direct: .contact(chatId)
        case .group: .group(chatId)
        default: nil
        }
    }
}

// MARK: - Result

/// The outcome of one redemption as spoken to the user. A failure carries the already-worded error rather than a sentence invented here.
enum PopopxRedemptionOutcome: Hashable, Sendable {
    /// Initiated, waiting for the other side to confirm. This is what the recipient gets before the ACK arrives, and the UI shows "waiting for the other side to confirm".
    /// Once the terminal state is reached it is written into `PopopxSilentSignalingRouter.lastOutcome`.
    case initiated
    /// Already lit up (the ACK's signature verified, matching this device's initiation, and the badge written successfully).
    case redeemed(period: PopopxNodeBadgePeriod, expiresAtMs: Int64)
    /// A compute-credit gift card landed. Separate case rather than a `redeemed` with a nil period, for the same reason the two envelopes are separate types:
    /// the badge answer is a deadline (`expiresAtMs`) while the credit answer is a number that never expires, and one case carrying both would let a screen
    /// print an expiry for credits or a period for a badge purely by forgetting a branch.
    case redeemedCredits(amount: Int, grantedAtMs: Int64)
    /// A definite failure.
    case failed(PopopxBadgeCreditsError)

    var announcementText: String {
        switch self {
        case .initiated: PopopxSignalingCopy.waitingForPeer
        case let .redeemed(period, _): PopopxSignalingCopy.redeemed(period.days)
        case let .redeemedCredits(amount, _): PopopxSignalingCopy.redeemedCredits(amount)
        case let .failed(error): error.errorDescription ?? PopopxSignalingCopy.genericFailure
        }
    }
}

// MARK: - Router

@MainActor
@Observable
final class PopopxSilentSignalingRouter {
    static let shared = PopopxSilentSignalingRouter()

    /// The most recent redemption result, for the redemption panel to subscribe to. A one-time link's ACK arrives asynchronously,
    /// so when the panel taps "Redeem" the terminal state cannot be returned in the same call, and therefore it is written here rather than in the return value.
    private(set) var lastOutcome: PopopxRedemptionOutcome?

    /// voucherId → the result of that one gift card, for the bubbles in the conversation stream to subscribe to.
    /// Relying on `lastOutcome` alone would cross wires: with one voucher in each of two chats, the later terminal state would light up both cards at once.
    /// Not persisted: it is only "the result this stretch of UI has to see"; what really stays behind is `PopopxBadgeManager`'s badge record.
    private(set) var outcomesByVoucher: [String: PopopxRedemptionOutcome] = [:]

    /// Writes the terminal state. Both copies must be written in the same pass, otherwise the panel and the card each tell a different story.
    /// `voucherId` may be nil: an ACK that cannot be decoded only knows "it failed", not which voucher it belonged to.
    private func record(_ outcome: PopopxRedemptionOutcome, voucherId: String?) {
        lastOutcome = outcome
        guard let voucherId else { return }
        // The 64-entry ceiling exists only to stop unbounded growth. Anything still waiting for an ACK must never be cleared — those are the only entries that can still change.
        if outcomesByVoucher.count >= 64 {
            let inflight = Set(awaitingAcks.values.map(\.voucherId))
            outcomesByVoucher = outcomesByVoucher.filter { inflight.contains($0.key) }
        }
        outcomesByVoucher[voucherId] = outcome
    }

    /// connId → the REQ waiting to be sent. It lands in the Keychain (the `ephemeralConnections` slot) so that after the process is killed
    /// the user can still run the flow once more; without persisting, one background termination would leave that code stuck forever at "connected, not requested".
    /// The key is `PendingContactConnection.pccConnId` (`POPOPXChat/ChatTypes.swift:2912`, Int64).
    private var pendingRequestsByConnection: [Int64: PopopxPendingRedeem] = [:]
    /// contactId → the entry whose REQ has been sent and is waiting for the ACK. `deletesContactAfterAck` separates two kinds of redemption:
    /// the one-time link one has to delete the contact along with it (no trace left), while the in-conversation gift card one must never delete it — that is the friend itself.
    private var awaitingAcks: [Int64: PopopxInflightRedeem] = [:]

    private var loaded = false
    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "signaling")

    private init() {}

    // MARK: Loading

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        pendingRequestsByConnection = PopopxCommerceKeychain.decode([Int64: PopopxPendingRedeem].self, .ephemeralConnections) ?? [:]
    }

    private func savePendingRequests() {
        _ = PopopxCommerceKeychain.encode(pendingRequestsByConnection, .ephemeralConnections)
    }

    // MARK: Mount point 1 · the recipient's connection is established

    /// Called from `POPOPXAPI`'s `.contactConnected` branch. Only scalars are passed: `Contact` is not Sendable,
    /// and bringing it into this isolated domain runs straight into strict-concurrency warnings; `ProfileAutoSender` handles it the same way.
    func contactConnected(connectionId: Int64, contactId: Int64) {
        loadIfNeeded()
        guard let pending = pendingRequestsByConnection[connectionId] else { return }
        pendingRequestsByConnection.removeValue(forKey: connectionId)
        savePendingRequests()
        awaitingAcks[contactId] = PopopxInflightRedeem(voucherId: pending.voucherId, deletesContactAfterAck: true)
        Task {
            if await send(text: pending.signalWire, to: .contact(contactId)) == false {
                awaitingAcks.removeValue(forKey: contactId)
                record(.failed(.connectionUnavailable), voucherId: pending.voucherId)
            }
        }
    }

    // MARK: Mount point 2 · a message arrived

    /// Redemption signalling is only accepted over direct: one in a group would broadcast "who redeemed this voucher" to every member.
    /// The only thing allowed in a group conversation is the red packet receipt — that is the share-count source for a group red packet, and `memberId` can attribute it to a person
    /// （`CIDirection.groupMemberId`，`POPOPXChat/ChatTypes.swift:4440`）。
    /// Putting the criterion first is so that another signalling kind misdelivered into a group is not even parsed.
    func observeIncoming(chatType: ChatType, chatId: Int64, itemId: Int64,
                         memberId: Int64? = nil, text: String) {
        guard chatType == .direct || chatType == .group,
              let signal = PopopxSysMarker.parse(wholeText: text) else { return }
        if chatType == .group, !signal.kind.acceptedInGroup { return }
        Task { await handle(signal, chatId: chatId, itemId: itemId, memberId: memberId, wire: text) }
    }

    private func handle(_ signal: PopopxCommerceSignal, chatId: Int64,
                        itemId: Int64, memberId: Int64?, wire: String) async {
        switch signal.kind {
        case .externalRedeemRequest, .chatRedeemRequest:
            await answerRedeemRequest(signal, chatId: chatId, itemId: itemId, wire: wire)
        case .externalRedeemAcknowledge, .chatRedeemAcknowledge:
            await applyRedeemAcknowledgement(signal, chatId: chatId, itemId: itemId)
        case .creditExternalRedeemRequest, .creditChatRedeemRequest:
            await answerCreditRedeemRequest(signal, chatId: chatId, itemId: itemId, wire: wire)
        case .creditExternalRedeemAcknowledge, .creditChatRedeemAcknowledge:
            await applyCreditRedeemAcknowledgement(signal, chatId: chatId, itemId: itemId)
        case .redPacketClaimed:
            // `memberId` exists only on group messages. direct passes nil: the replay prevention on that side already lives in the claimer's ledger
            // (the same packetId is credited only once); here on the sender's side it only records the share count.
            PopopxCreditsManager.shared.recordClaim(packetId: signal.payload, memberKey: memberId.map { "\($0)" })
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
        case .profileUnlocked:
            // The card owner's side does exactly one thing: delete that row. It keeps no book, shows no prompt, and leaves no trace on the bubble —
            // "who viewed your profile page, and when" stops being silent the moment it becomes a record you can look back at.
            // A line in the log is kept so that when the user asks, there is an answer (it really did pass through this device).
            log.info("signaling: profile unlock receipt from chat \(chatId, privacy: .public)")
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
        case .channelSubscriptionAcknowledge:
            // Handled exactly like the profile unlock receipt: delete this device's row, keep no book, touch no UI.
            // Why no book can be kept: the `chatInfoId` in the payload is the row number on **the sending device** (`ChatInfo.id` =
            // `"#"` + the local groupId, ChatTypes.swift:3059), and the receiving side has no correspondence to it at all;
            // and a channel message's `chatDir` is `.channelRcv`, which carries no member object (:4421-4422, :4440-4442),
            // so "who redeemed it" cannot be determined at the Swift layer at all. This one log line is the only empirical trace.
            log.info("signaling: channel subscription receipt in chat \(chatId, privacy: .public)")
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
        case .channelPaymentReceipt:
            // Channel owner receives payment receipt: parse, verify txHash uniqueness, credit wallet.
            guard let receipt = PopopxChannelPaymentReceipt.parse(from: signal.payload) else {
                log.error("signaling: malformed channel payment receipt")
                _ = await deleteSignal(chatId: chatId, itemId: itemId)
                return
            }
            if PopopxCreditsManager.shared.receiveChannelPayment(receipt) {
                log.info("signaling: channel payment credited \(receipt.credits, privacy: .public) credits")
            } else {
                log.info("signaling: channel payment duplicate or failed")
            }
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
        case .nodeCmd:
            // The Mac node's status line or result card. `DiscoverSubscriptionManager` owns the reading:
            // it decides which service's transcript the receipt belongs to and whether it came from the
            // contact the user bonded. This layer does one thing only — the row never becomes a bubble,
            // because a control signal rendered as chat text is what the requirement forbids.
            if let command = PopopxNodeCmd(signalPayload: signal.payload) {
                DiscoverSubscriptionManager.shared.recordInbound(command: command)
            } else {
                // Not the host's three-part shape. It is still signalling from this marker, so it is still
                // deleted: leaving a malformed `NODE_CMD` on screen would be a bubble after all.
                log.error("signaling: NODE_CMD payload without the host's {serviceId}::{action}::{payload} shape")
            }
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
        }
    }

    // MARK: Giver · answering a redemption request

    private func answerRedeemRequest(_ signal: PopopxCommerceSignal, chatId: Int64, itemId: Int64, wire: String) async {
        guard signal.isRequest else { return }
        // Not this device's voucher, or already redeemed → never sign at all. That sentence is itself the answer: it leaks no information
        // beyond "does this voucher exist", because the voucher number is one the user handed over themselves.
        guard let grant = await PopopxP2PVoucherVault.shared.authorizeRedemption(voucherId: signal.payload, codeDigestSource: wire) else {
            log.info("signaling: redeem request rejected — unknown or already redeemed voucher")
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
            return
        }
        guard let encoded = PopopxSilentSignalingRouter.encoded(grant) else {
            // The authorisation landed on disk but encoding failed: a local-bug-level state, and it must never answer with "success".
            // The voucher staying at redeemed is better than letting the other side get a fake authorisation, and the user can void it from the voucher list.
            log.error("signaling: grant could not be encoded")
            return
        }
        let acknowledged = await send(
            text: PopopxSysMarker.wireString(for: PopopxCommerceSignal(kind: .externalRedeemAcknowledge, payload: encoded)),
            to: .contact(chatId)
        )
        guard acknowledged else {
            log.error("signaling: ACK could not be sent; voucher stays redeemed")
            return
        }
        _ = await deleteSignal(chatId: chatId, itemId: itemId)
    }

    /// The giver's side of a compute-credit gift card. Deliberately a second function rather than a flag on `answerRedeemRequest`:
    /// the two families sign different grants (`PopopxBadgeGrant` vs `PopopxCreditsGrant`) over different canonical `kind` strings,
    /// and one function doing both would have to re-derive "which vault table did I just flip" from a Bool instead of from the types.
    private func answerCreditRedeemRequest(_ signal: PopopxCommerceSignal, chatId: Int64, itemId: Int64, wire: String) async {
        guard signal.isRequest else { return }
        // Same refusal as the badge leg: a voucher that is not this device's, or is already spent, gets no signature at all.
        guard let grant = await PopopxP2PVoucherVault.shared.authorizeCreditRedemption(voucherId: signal.payload, codeDigestSource: wire) else {
            log.info("signaling: credit redeem request rejected — unknown or already redeemed gift card")
            _ = await deleteSignal(chatId: chatId, itemId: itemId)
            return
        }
        guard let encoded = PopopxSilentSignalingRouter.encodedCreditGrant(grant) else {
            // The card is already flipped to redeemed by the call above and the grant will not encode: a local-bug-level state,
            // and answering "success" here would be worse than silence — the other side would credit an unsigned number.
            log.error("signaling: credit grant could not be encoded")
            return
        }
        let acknowledged = await send(
            text: PopopxSysMarker.wireString(for: PopopxCommerceSignal(kind: .creditExternalRedeemAcknowledge, payload: encoded)),
            to: .contact(chatId)
        )
        guard acknowledged else {
            log.error("signaling: credit ACK could not be sent; gift card stays redeemed")
            return
        }
        _ = await deleteSignal(chatId: chatId, itemId: itemId)
    }

    // MARK: Recipient · applying the authorisation

    private func applyRedeemAcknowledgement(_ signal: PopopxCommerceSignal, chatId: Int64, itemId: Int64) async {
        guard let grant = PopopxSilentSignalingRouter.decodedGrant(signal.payload) else {
            record(.failed(.codeMalformed), voucherId: nil)
            return
        }
        guard let inflight = awaitingAcks[chatId], inflight.voucherId == grant.voucherId else {
            log.info("signaling: acknowledgement for a redemption this device never requested")
            return
        }
        awaitingAcks.removeValue(forKey: chatId)
        guard await PopopxP2PVoucherVault.shared.record(grant) else {
            record(.failed(.signalRejected), voucherId: grant.voucherId)
            return
        }
        do {
            let badge = try PopopxBadgeManager.shared.activate(grant: grant)
            // Record "this device has redeemed this voucher" first, then write the terminal state: if the process is killed in between, after restart the bubble still sees it as redeemed,
            // rather than a button that can be tapped one more time.
            PopopxCreditsManager.shared.markRedeemed(voucherId: grant.voucherId)
            record(.redeemed(period: badge.period, expiresAtMs: badge.expiresAtMs), voucherId: grant.voucherId)
        } catch {
            record(.failed(.keychainUnavailable), voucherId: grant.voucherId)
            return
        }
        _ = await deleteSignal(chatId: chatId, itemId: itemId)
        if inflight.deletesContactAfterAck {
            // A one-time redemption connection: delete the whole thing, and send no notification either — the other side already has the ACK,
            // and one more "so-and-so deleted you" would just write this transaction back into both timelines.
            _ = try? await apiDeleteContact(id: chatId, chatDeleteMode: .full(notify: false))
        }
    }

    /// The recipient's side of a compute-credit gift card. The ordering is the badge leg's ordering and for the same reasons:
    /// file the grant → credit the wallet (which flips the local replay record) → write the terminal state → delete the machine line →
    /// only then drop the temporary connection.
    private func applyCreditRedeemAcknowledgement(_ signal: PopopxCommerceSignal, chatId: Int64, itemId: Int64) async {
        guard let grant = PopopxSilentSignalingRouter.decodedCreditGrant(signal.payload) else {
            record(.failed(.codeMalformed), voucherId: nil)
            return
        }
        guard let inflight = awaitingAcks[chatId], inflight.voucherId == grant.voucherId else {
            log.info("signaling: credit acknowledgement for a redemption this device never requested")
            return
        }
        awaitingAcks.removeValue(forKey: chatId)
        guard await PopopxP2PVoucherVault.shared.recordCredit(grant) else {
            record(.failed(.keychainUnavailable), voucherId: grant.voucherId)
            return
        }
        do {
            // `false` means this device already credited this exact voucher id once. That is the replay guard doing its job, not a failure:
            // the number the giver signed cannot differ (a second signature over a different amount would not verify against the pinned key),
            // so the honest answer to a repeated ACK is the same terminal state the first one produced.
            if try PopopxCreditsManager.shared.creditGiftCard(grant: grant) {
                log.info("signaling: credit gift card redeemed for \(grant.creditsAmount, privacy: .public) credits")
            }
            record(.redeemedCredits(amount: grant.creditsAmount, grantedAtMs: grant.grantedAtMs), voucherId: grant.voucherId)
        } catch {
            // Keep the wording the wallet already chose (the balance ceiling has its own sentence) instead of inventing one here.
            record(.failed((error as? PopopxBadgeCreditsError) ?? .keychainUnavailable), voucherId: grant.voucherId)
            return
        }
        _ = await deleteSignal(chatId: chatId, itemId: itemId)
        if inflight.deletesContactAfterAck {
            _ = try? await apiDeleteContact(id: chatId, chatDeleteMode: .full(notify: false))
        }
    }

    // MARK: Outbound · called by the UI

    /// The recipient starts a one-time redemption with a `PPX1-…` code.
    ///
    /// Returning `.initiated` is not the same as a successful redemption: it only means "the connection is built, and the REQ will be sent on `contactConnected`".
    /// The terminal state is given by `lastOutcome`, and the panel subscribes to it.
    func startExternalRedeem(code: String) async -> PopopxRedemptionOutcome {
        loadIfNeeded()
        guard let envelope = PopopxRedeemCode.decode(code) else { return .failed(.codeMalformed) }
        guard envelope.isSignatureValid else { return .failed(.signalRejected) }
        let connLink = CreatedConnLink(connFullLink: envelope.inviteLink, connShortLink: nil)
        guard let (_, connection) = await apiConnect(incognito: true, connLink: connLink) else {
            return .failed(.connectionUnavailable)
        }
        let wire = PopopxSysMarker.wireString(
            for: PopopxCommerceSignal(kind: .externalRedeemRequest, payload: envelope.voucherId)
        )
        pendingRequestsByConnection[connection.pccConnId] = PopopxPendingRedeem(voucherId: envelope.voucherId, signalWire: wire)
        savePendingRequests()
        record(.initiated, voucherId: envelope.voucherId)
        return .initiated
    }

    /// An in-conversation gift card: there is already a contact, the REQ is sent directly, and after the ACK arrives the contact is **not deleted**.
    func redeemInChat(_ payload: PopopxGiftCardPayload, contactId: Int64) async -> PopopxRedemptionOutcome {
        guard payload.isSignatureValid else { return .failed(.signalRejected) }
        let wire = PopopxSysMarker.wireString(
            for: PopopxCommerceSignal(kind: .chatRedeemRequest, payload: payload.voucherId)
        )
        guard await send(text: wire, to: .contact(contactId)) else { return .failed(.connectionUnavailable) }
        awaitingAcks[contactId] = PopopxInflightRedeem(voucherId: payload.voucherId, deletesContactAfterAck: false)
        record(.initiated, voucherId: payload.voucherId)
        return .initiated
    }

    /// Mints a redeemable code for one voucher: `PPX1-…` (a one-time SMP invite link + the voucher number + the giver's signature + checksum).
    ///
    /// The only precondition: the voucher is already in the local voucher wallet (both the Apple gift tier and the compute-credit redemption mint the voucher first).
    /// Every call creates a new one-time connection — that is a **necessary** cost, not decoration:
    /// a link can only be accepted once, and reusing the same one opens a double-spend window of "the second person scans while the first has not redeemed".
    /// So pressing "Regenerate" on the same voucher yields a new nonce and a new link, and the old code becomes void (`codeDigest` keeps only the newest copy).
    func mintCode(for voucher: PopopxNodeVoucher) async -> String? {
        // A badge code signs a `period`, so a row without one has no business here: a compute-credit card is minted by
        // `mintCreditCode(for:)`, and the two code families (`PPX1-` / `PPXC1-`) never cross.
        guard voucher.state == .unused, let period = voucher.period else { return nil }
        guard let (link, _) = await apiAddContact(incognito: true) else { return nil }
        let publicKey = PopopxCommerceSignature.localPublicKeyBase64URL()
        guard !publicKey.isEmpty else { return nil }
        let seed = PopopxRedeemEnvelope(
            inviteLink: link.connFullLink,
            voucherId: voucher.voucherId,
            period: period,
            mintedAtMs: voucher.mintedAtMs,
            nonce: Self.nonce(),
            giverPublicKey: publicKey,
            signature: ""
        )
        guard let signature = PopopxCommerceSignature.signatureBase64URL(for: seed.canonicalBytes) else { return nil }
        let envelope = PopopxRedeemEnvelope(
            inviteLink: seed.inviteLink,
            voucherId: seed.voucherId,
            period: seed.period,
            mintedAtMs: seed.mintedAtMs,
            nonce: seed.nonce,
            giverPublicKey: seed.giverPublicKey,
            signature: signature
        )
        // Self-check once before handing it out: the correspondence between the signed string and the source is computed by the same `canonicalBytes`,
        // but the private key in the Keychain may have been swapped by the clearing flow in this beat, and verifying once before issuing the code is cheaper than the other side scanning and getting "signalling rejected".
        guard envelope.isSignatureValid, let code = PopopxRedeemCode.encode(envelope) else { return nil }
        await PopopxP2PVoucherVault.shared.recordCodeDigest(
            PopopxCommerceSignature.shortDigest(code), forVoucherId: voucher.voucherId
        )
        return code
    }

    /// The recipient starts a one-time redemption with a `PPXC1-…` code. Mirror of `startExternalRedeem`, one step different on purpose:
    /// the decode call names the family, so a badge code handed to this function fails as "malformed code" rather than being redeemed as a badge.
    func startExternalCreditRedeem(code: String) async -> PopopxRedemptionOutcome {
        loadIfNeeded()
        guard let envelope = PopopxRedeemCode.decodeCredit(code) else { return .failed(.codeMalformed) }
        guard envelope.isSignatureValid else { return .failed(.signalRejected) }
        let connLink = CreatedConnLink(connFullLink: envelope.inviteLink, connShortLink: nil)
        guard let (_, connection) = await apiConnect(incognito: true, connLink: connLink) else {
            return .failed(.connectionUnavailable)
        }
        let wire = PopopxSysMarker.wireString(
            for: PopopxCommerceSignal(kind: .creditExternalRedeemRequest, payload: envelope.voucherId)
        )
        pendingRequestsByConnection[connection.pccConnId] = PopopxPendingRedeem(voucherId: envelope.voucherId, signalWire: wire)
        savePendingRequests()
        record(.initiated, voucherId: envelope.voucherId)
        return .initiated
    }

    /// An in-conversation compute-credit gift card: the contact already exists, so the REQ goes straight out and the contact is **not** deleted.
    func redeemCreditInChat(_ payload: PopopxCreditGiftPayload, contactId: Int64) async -> PopopxRedemptionOutcome {
        guard payload.isSignatureValid else { return .failed(.signalRejected) }
        let wire = PopopxSysMarker.wireString(
            for: PopopxCommerceSignal(kind: .creditChatRedeemRequest, payload: payload.voucherId)
        )
        guard await send(text: wire, to: .contact(contactId)) else { return .failed(.connectionUnavailable) }
        awaitingAcks[contactId] = PopopxInflightRedeem(voucherId: payload.voucherId, deletesContactAfterAck: false)
        record(.initiated, voucherId: payload.voucherId)
        return .initiated
    }

    /// Mints a redeemable `PPXC1-…` code for one compute-credit gift card.
    ///
    /// Same cost structure as `mintCode`: every call opens a fresh one-time connection, because a link that two people can both present
    /// would reopen the double-spend window the vault's serial check exists to close.
    func mintCreditCode(for voucher: PopopxNodeVoucher) async -> String? {
        // The credit envelope signs a `creditsAmount`, so a badge row (no amount) has no business here: `mintCode(for:)` is its path.
        guard voucher.state == .unused, let creditsAmount = voucher.creditsAmount else { return nil }
        guard let (link, _) = await apiAddContact(incognito: true) else { return nil }
        let publicKey = PopopxCommerceSignature.localPublicKeyBase64URL()
        guard !publicKey.isEmpty else { return nil }
        let seed = PopopxCreditRedeemEnvelope(
            inviteLink: link.connFullLink,
            voucherId: voucher.voucherId,
            creditsAmount: creditsAmount,
            mintedAtMs: voucher.mintedAtMs,
            nonce: Self.nonce(),
            giverPublicKey: publicKey,
            signature: ""
        )
        guard let signature = PopopxCommerceSignature.signatureBase64URL(for: seed.canonicalBytes) else { return nil }
        let envelope = PopopxCreditRedeemEnvelope(
            inviteLink: seed.inviteLink,
            voucherId: seed.voucherId,
            creditsAmount: seed.creditsAmount,
            mintedAtMs: seed.mintedAtMs,
            nonce: seed.nonce,
            giverPublicKey: seed.giverPublicKey,
            signature: signature
        )
        guard envelope.isSignatureValid, let code = PopopxRedeemCode.encode(envelope) else { return nil }
        await PopopxP2PVoucherVault.shared.recordCodeDigest(
            PopopxCommerceSignature.shortDigest(code), forVoucherId: voucher.voucherId
        )
        return code
    }

    /// Sends a credit gift card into an existing conversation (a human line + a machine line).
    /// The message comes from the payload and from nowhere else: `note` is part of the signed bytes, so a second copy supplied by the
    /// caller is a sentence that can disagree with the signature — the red packet send above already reads it off the payload, same shape.
    func sendCreditGiftCard(_ payload: PopopxCreditGiftPayload, contactId: Int64) async -> Bool {
        await send(text: PopopxCommerceCardText.messageText(creditGift: payload), to: .contact(contactId))
    }

    /// 16 random bytes. Swift's `SystemRandomNumberGenerator` on Apple platforms is seeded by
    /// `getrandom(2)`, which is good enough here; it goes into a public code text, not into key material.
    private static func nonce() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).popopxBase64URL
    }

    /// Sends a gift card (a human line + a machine line). This is the origin of the card rendered inside the bubble.
    /// Same rule as the credit twin above: the line the recipient reads is built from the message that was signed, never from a
    /// second copy handed in alongside it.
    func sendGiftCard(_ payload: PopopxGiftCardPayload, contactId: Int64) async -> Bool {
        await send(text: PopopxCommerceCardText.messageText(gift: payload), to: .contact(contactId))
    }

    /// Sends a red packet. `PopopxCreditsManager.sendRedPacket` has already deducted the credits, so this only gets it out the door.
    /// The only difference between 1:1 and group is "where to find this conversation", and every send parameter comes from `chatInfo`, so it is a single path.
    func sendRedPacket(_ payload: PopopxRedPacketPayload, to target: PopopxCommerceTarget) async -> Bool {
        await send(text: PopopxCommerceCardText.messageText(packet: payload), to: target)
    }

    /// The receipt sent back to the sender after claiming a red packet. In a group it goes back to the group, in a 1:1 chat back to the chat — it follows that card,
    /// not "the sender as a person", so its parameters take the same landing point as `sendRedPacket`.
    func sendRedPacketReceipt(packetId: String, to target: PopopxCommerceTarget) async -> Bool {
        await send(
            text: PopopxSysMarker.wireString(for: PopopxCommerceSignal(kind: .redPacketClaimed, payload: packetId)),
            to: target
        )
    }

    /// The profile unlock receipt. The payload carries only `profileId`: the one thing this signalling has to answer is "which card was opened",
    /// while "who opened it" is given by the SMP connection itself, and "how much was paid" only means something in the ledger of the paying device —
    /// nothing on the owner's side changes because of it, so not one extra character is carried here.
    ///
    /// `contactId` must be the **1:1 chat** contact: `PopopxProfileReadKey.chatId` holds a group number inside a group,
    /// and using it as a contactId would send the receipt to a completely unrelated person, so the caller must first confirm this row came from a 1:1 chat.
    func sendProfileUnlockReceipt(profileId: String, contactId: Int64) async -> Bool {
        await send(
            text: PopopxSysMarker.wireString(
                for: PopopxCommerceSignal(kind: .profileUnlocked, payload: profileId)
            ),
            to: .contact(contactId)
        )
    }

    /// Who may publish (the publishing half of the product ruling): this device's member record really is admin or above in that group
    /// (`memberRole >= .admin` and `memberCurrent`, shape following `GroupInfo.canAddMembers`,
    /// ChatTypes.swift:3083-3085). A threshold card is "the price the channel owner sets", so ordinary members have no right to issue it.
    ///
    /// This criterion exists in one copy only: the publish page's button (`PopopxChannelThresholdView.canPublish`) and
    /// `sendChannelAccess`'s guard both go through it, so the interface and the exit cannot tell two different stories.
    /// What it blocks is "this device's own interface"; the forged-by-others half is on the render side, see `PopopxChannelAccessBubble`.
    static func canPublishChannelThreshold(groupId: Int64) -> Bool {
        ChatModel.shared.getGroupChat(groupId)?.chatInfo.groupInfo?.popopxCanPublishChannelThreshold == true
    }

    /// The channel owner publishes the subscription threshold. Same shape as gift cards and red packets: one line for people, one line for machines,
    /// but **this one is never deleted or hidden** — it is the members' side's only source of the price list (see
    /// the "why it must travel as a message" section at the top of `PopopxChannelAccessPayload`), and hiding it means making members pay for a number they cannot see.
    /// The landing point is only the group/channel branch: a channel is, in the model, a group conversation with `useRelays`.
    func sendChannelAccess(_ payload: PopopxChannelAccessPayload, to target: PopopxCommerceTarget) async -> Bool {
        guard case .group(let groupId) = target, Self.canPublishChannelThreshold(groupId: groupId) else {
            log.info("signaling: channel threshold publication refused — this device is not an active admin here")
            return false
        }
        return await send(text: PopopxCommerceCardText.messageText(channel: payload), to: target)
    }

    /// The redemption receipt a member sends back to the channel after deducting credits and signing a ticket.
    ///
    /// It is **best effort**: the ticket is already written into the keychain, and a receipt that cannot be sent never rolls back that deduction and never errors at the user —
    /// an error would make an already-established subscription look like a failure. Whether "a subscriber may speak" in a channel is decided by the core's group settings,
    /// and the Swift layer has no such criterion (`ChatInfo.sendAsGroup` is only true for `memberRole >= .owner`, :2405-2415),
    /// so the subscriber's one will most likely be blocked already at the core; if blocked, only this log line remains.
    func sendChannelSubscriptionAck(chatInfoId: String, expiresAtMs: Int64, to target: PopopxCommerceTarget) async -> Bool {
        let delivered = await send(
            text: PopopxSysMarker.wireString(for: PopopxCommerceSignal(
                kind: .channelSubscriptionAcknowledge,
                payload: "\(chatInfoId)::\(expiresAtMs)"
            )),
            to: target
        )
        if !delivered {
            log.info("signaling: channel subscription receipt not delivered — ticket stands")
        }
        return delivered
    }

    /// Send channel payment receipt to channel owner: member pays → owner credits.
    /// The txHash provides replay protection on the owner's side.
    func sendChannelPaymentReceipt(channelId: Int64, credits: Int, txHash: String, to target: PopopxCommerceTarget) async -> Bool {
        let receipt = PopopxChannelPaymentReceipt(channelId: channelId, credits: credits, txHash: txHash, paidAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        let delivered = await send(
            text: PopopxSysMarker.wireString(for: PopopxCommerceSignal(
                kind: .channelPaymentReceipt,
                payload: receipt.wireString
            )),
            to: target
        )
        if !delivered {
            log.info("signaling: channel payment receipt not delivered — credits already deducted on payer side")
        }
        return delivered
    }

    /// Sends one Mac node command and reports whether SMP accepted it.
    ///
    /// Public because Discover is its only caller and the command must leave through the same
    /// gate every other control signal uses: `send(text:to:)` is the one place that builds an
    /// `apiSendMessages` call, and routing around it would put a second outbound path in the app
    /// — the path by which a `NODE_CMD` ends up visible in a bubble.
    /// The receipt is the node's answer arriving later through `observeIncoming`, not this Bool:
    /// "accepted by SMP" and "done on the Mac" are two claims, and callers here show the user only
    /// the first one.
    func sendNodeCommand(_ command: PopopxNodeCmd, toContactId contactId: Int64) async -> Bool {
        let delivered = await send(
            text: PopopxSysMarker.wireString(for: PopopxCommerceSignal(kind: .nodeCmd, payload: command.signalPayload)),
            to: .contact(contactId)
        )
        if !delivered {
            log.info("signaling: node command \(command.serviceId.rawValue, privacy: .public) not delivered")
        }
        return delivered
    }

    /// Sends one **verbatim** node signal — a receipt the node minted itself and handed to us in a
    /// card (`approve=` / `snooze=`).
    ///
    /// Deliberately not `sendNodeCommand`: that path rebuilds `::popopx_sys::NODE_CMD::<service>::
    /// <action>::<json>` out of structured fields, and this payload's exact bytes are the value the
    /// node HMACed. Re-encoding it here would let a key order or an escaping difference turn a valid
    /// receipt into a rejection the user cannot explain. What this adds over a bare `send` is only
    /// what every other control signal already gets: the same SMP path, the same suppression, and a
    /// Bool that means "SMP took it" and nothing more.
    func sendNodeText(_ text: String, toContactId contactId: Int64) async -> Bool {
        let delivered = await send(text: text, to: .contact(contactId))
        if !delivered { log.info("signaling: verbatim node signal not delivered") }
        return delivered
    }

    // MARK: Send / receive primitives

    /// One SMP text message. The call shape follows `ProfileAutoSender.sendViaSMP`
    /// （`Shared/Features/PersonalProfile/ProfileAutoSender.swift:511-527`）：
    /// `apiSendMessages` does not throw itself and the failure pops a prompt at the app layer, so "nil or an empty array returned" is treated as a failure here —
    /// signalling has no other receipt, and the caller must know it did not go out, otherwise you get the deadlock of "the UI thinks it sent and the peer never received".
    private func send(text: String, to target: PopopxCommerceTarget) async -> Bool {
        let chat: Chat?
        switch target {
        case let .contact(id): chat = ChatModel.shared.getContactChat(id)
        case let .group(id): chat = ChatModel.shared.getGroupChat(id)
        }
        guard let chat else {
            log.error("signaling: chat :\(target.chatId, privacy: .public) not found")
            return false
        }
        let items = await apiSendMessages(
            type: chat.chatInfo.chatType,
            id: chat.chatInfo.apiId,
            scope: chat.chatInfo.groupChatScope(),
            sendAsGroup: chat.chatInfo.sendAsGroup,
            live: false,
            ttl: nil,
            sign: false,
            composedMessages: [ComposedMessage(msgContent: .text(text))]
        )
        guard let items, !items.isEmpty else {
            log.error("signaling: send returned no chat item")
            return false
        }
        for item in items {
            ChatModel.shared.addChatItem(chat.chatInfo, item)
        }
        return true
    }

    /// Deletes this device's row of signalling. `.cidmInternal` is the only correct tier:
    /// `.cidmBroadcast` would show the other side "message deleted", which writes the signalling's existence back into their timeline;
    /// `.cidmHistory` rewrites history as well and its cross-platform semantics are noisier. After a successful delete the model must be changed too,
    /// otherwise the row still lives in the in-memory timeline (the criterion only blocks re-rendering, not the one already loaded).
    private func deleteSignal(chatId: Int64, itemId: Int64) async -> Bool {
        let model = ChatModel.shared
        guard let chat = model.chats.first(where: { $0.chatInfo.apiId == chatId }) else {
            log.error("signaling: no chat for apiId :\(chatId, privacy: .public); the row stays in memory")
            return false
        }
        do {
            let deletions = try await apiDeleteChatItems(
                type: chat.chatInfo.chatType,
                id: chat.chatInfo.apiId,
                scope: chat.chatInfo.groupChatScope(),
                itemIds: [itemId],
                mode: .cidmInternal
            )
            for deletion in deletions {
                if let toItem = deletion.toChatItem {
                    _ = model.upsertChatItem(chat.chatInfo, toItem.chatItem)
                } else {
                    model.removeChatItem(chat.chatInfo, deletion.deletedChatItem.chatItem)
                }
                model.updateChatInfo(deletion.deletedChatItem.chatInfo)
            }
            return true
        } catch {
            log.error("signaling: internal delete failed; the row stays suppressed but present")
            return false
        }
    }

    // MARK: Encoding and decoding the authorisation text

    /// The length ceiling shares one tier with `PopopxSilentSignalingRouter.decodedGrant`:
    /// a signalling message should not be longer than what one screen can read, so over the ceiling it is refused outright and never enters decoding.
    static func encoded(_ grant: PopopxBadgeGrant) -> String? {
        guard let data = try? JSONEncoder().encode(grant),
              data.count <= PopopxCommerceLimits.maximumSignalPayloadCharacters else { return nil }
        return data.popopxBase64URL
    }

    static func decodedGrant(_ payload: String) -> PopopxBadgeGrant? {
        guard payload.count <= PopopxCommerceLimits.maximumSignalPayloadCharacters,
              let data = Data(popopxBase64URL: payload),
              let grant = try? JSONDecoder().decode(PopopxBadgeGrant.self, from: data),
              grant.isSignatureValid
        else { return nil }
        return grant
    }

    static func encodedCreditGrant(_ grant: PopopxCreditsGrant) -> String? {
        guard let data = try? JSONEncoder().encode(grant),
              data.count <= PopopxCommerceLimits.maximumSignalPayloadCharacters else { return nil }
        return data.popopxBase64URL
    }

    /// Decodes and verifies a credit grant in one step, like `decodedGrant`. The two types have disjoint key sets, so handing
    /// a badge ACK to this function (or the reverse) lands on `nil` — the family is not inferred from what failed to parse.
    static func decodedCreditGrant(_ payload: String) -> PopopxCreditsGrant? {
        guard payload.count <= PopopxCommerceLimits.maximumSignalPayloadCharacters,
              let data = Data(popopxBase64URL: payload),
              let grant = try? JSONDecoder().decode(PopopxCreditsGrant.self, from: data),
              grant.isSignatureValid
        else { return nil }
        return grant
    }
}

// MARK: - Local state

/// The entry waiting for `contactConnected`. `signalWire` stores the whole string instead of re-assembling it:
/// assembling once more adds one more place that could differ from what was sent, and these two must be byte-for-byte identical.
struct PopopxPendingRedeem: Codable, Hashable, Sendable {
    let voucherId: String
    let signalWire: String
}

/// The entry whose REQ has been sent and is waiting for the ACK.
struct PopopxInflightRedeem: Hashable, Sendable {
    let voucherId: String
    let deletesContactAfterAck: Bool
}

private enum PopopxSignalingCopy {
    static let waitingForPeer = NSLocalizedString("Redeem request sent — waiting for the other side to confirm", comment: "signaling toast")
    static let genericFailure = NSLocalizedString("Redemption did not complete", comment: "signaling fallback")
    static func redeemed(_ days: Int) -> String { String(format: NSLocalizedString("Redeemed · badge lit for %lld days", comment: "signaling toast"), days) }
    /// Credits are not "lit" — there is no deadline in this sentence, because a compute-credit gift card has none.
    static func redeemedCredits(_ credits: Int) -> String { String(format: NSLocalizedString("Redeemed · %lld Compute Credits added", comment: "signaling toast"), credits) }
}

/// The human sentence inside the outbound text. The card itself is rendered in `PopopxCommerceCards.swift` (item 9),
/// so this only handles "the message that goes out": one line for people, one line for machines, separated by a newline,
/// so the recipient can read it and `PopopxGiftCardPayload.parse(from:)` can also pull it apart token by token.
enum PopopxCommerceCardText {
    static func messageText(gift payload: PopopxGiftCardPayload) -> String {
        let line = payload.note.isEmpty
            ? String(format: NSLocalizedString("🎁 [Gift badge] %lld days", comment: "outgoing gift card line"), payload.period.days)
            : String(format: NSLocalizedString("🎁 [Gift badge] %1$lld days · %2$@", comment: "outgoing gift card line with note"), payload.period.days, payload.note)
        return line + "\n" + payload.wireString
    }

    static func messageText(packet payload: PopopxRedPacketPayload) -> String {
        // The human line must state the same number as the machine line: the share count is on the card, and only then do the books match when it is split apart.
        let head = payload.recipients > 1
            ? String(format: NSLocalizedString("🧧 [Compute Credits packet] %1$lld · split equally into %2$lld shares", comment: "outgoing red packet line"), payload.amount, payload.recipients)
            : String(format: NSLocalizedString("🧧 [Compute Credits packet] %lld", comment: "outgoing red packet line"), payload.amount)
        return payload.note.isEmpty ? head + "\n" + payload.wireString : head + " · " + payload.note + "\n" + payload.wireString
    }

    /// The human line of a compute-credit gift card. The number is the card's face value, the same number the vault signed
    /// and the same number the recipient's wallet will add: three mouths, one figure.
    /// The message comes from the payload for the same reason: what the recipient reads and what the signature covers must be one text.
    static func messageText(creditGift payload: PopopxCreditGiftPayload) -> String {
        let line = payload.note.isEmpty
            ? String(format: NSLocalizedString("🎁 [Compute Credits gift card] %lld", comment: "outgoing credit gift card line"), payload.creditsAmount)
            : String(format: NSLocalizedString("🎁 [Compute Credits gift card] %1$lld · %2$@", comment: "outgoing credit gift card line with note"), payload.creditsAmount, payload.note)
        return line + "\n" + payload.wireString
    }

    /// The plain-language line of the threshold card. The day count is taken straight from `channelTicketSeconds`, the same source as the duration
    /// the members' side writes into the credential after deducting credits: saying "30 days" here while signing out a different number of days there is two mouths stating one price.
    static func messageText(channel payload: PopopxChannelAccessPayload) -> String {
        let days = PopopxCommerceLimits.channelTicketSeconds / 86_400
        return String(format: NSLocalizedString("🔒 [Channel subscription] %1$lld Compute Credits / %2$lld days", comment: "outgoing channel gate line"), payload.price, days) + "\n" + payload.wireString
    }
}
