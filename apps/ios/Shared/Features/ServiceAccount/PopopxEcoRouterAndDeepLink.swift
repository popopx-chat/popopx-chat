//
//  PopopxEcoRouterAndDeepLink.swift
//  POPOPX (iOS)
//
//  Module 2's interception point, the store the cards live in, the uplink for every callback, and the deep-link handlers of module 5.
//  This is the only file in the directory that both *receives* and *sends*, so it is also the only place where the ordering rules of
//  the two directions can be stated once.
//
//  ### Why the observer hangs where it does
//  `PopopxSilentSignalingRouter.observeIncoming` (PopopxSilentSignalingRouter.swift:188) is already called for every inbound message
//  from one site, `Shared/Model/POPOPXAPI.swift:2791`. The brief's "避免重复监听冲突" is satisfied by adding a **second call beside
//  it at the same site** rather than by a second subscription anywhere: one place reads `cItem.content.msgContent?.text`, one place
//  owns the `Task { @MainActor in … }` hop, and a third listener would mean two orderings of the same message that can disagree.
//  The two routers answer different markers (`::popopx_sys::` vs `::POPOPX_ECO::`), so a message is handled by at most one of them.
//
//  ### Why an update frame deletes itself
//  SMP is append-only; there is no "edit that message" primitive a member can use, and `apiEditChatItem` would put an edit notice on
//  the peer's screen. So an in-place card update is: (1) mutate the store, (2) delete this device's row with
//  `.cidmInternal` — the same tier the commerce signalling uses (PopopxSilentSignalingRouter.swift:631) because
//  `.cidmBroadcast` would tell the other side a message was deleted, which writes the control frame's existence back into their
//  timeline. The card bubble re-renders because it reads through `PopopxEcoStore`, which is `@Observable`.
//  Deleting is best-effort and its failure is logged, never shown: a row that stays is suppressed by the gate, so the worst case is
//  an invisible row in the timeline, not a duplicated card.
//
//  ### Uplink
//  `::CB::`, `::REF::` and `::SSO_SCAN::` go out through `PopopxComposerRouting.dispatch` + `PopopxMeshRuntime.shared.router.send`,
//  which is the app's own dual-mode decision table: a 1:1 direct chat whose peer is Cabin-bound and whose text is plain goes over
//  the mesh, everything else is handed back to the host's SMP path (§5 of the brief: one send chain, not two).
//

import Foundation
import Observation
import os
import PopopxMeshKit
import POPOPXChat

// MARK: - Store

/// The cards and menus this device currently knows about.
///
/// Deliberately one observable object rather than a per-conversation model: a card's `cardId` is global (the server mints it), and
/// the bubble that renders it is looked up by that id from a message in a conversation the store has no opinion about.
@MainActor
@Observable
final class PopopxEcoStore {
    static let shared = PopopxEcoStore()

    /// The newest known state of each card. A card the server never updated still appears here, because the store is also what makes
    /// "the bubble shows the latest state after a relaunch" true.
    private(set) var cards: [String: PopopxServiceCard] = [:]
    /// The live menu of each service account, by local contact id.
    private(set) var menus: [Int64: PopopxEcoMenu] = [:]
    /// One-shot notice for the caller that can show a toast. Views drain it in `task`/`onChange`; the router writes it because the
    /// router is the thing that knows a key rotated, and a toast model belongs to a view, not to a singleton.
    private(set) var pendingNotice: PopopxEcoNotice?

    /// Per-action lockout so a double tap cannot fire two callbacks. Cleared when the card itself changes, which is the peer's way of
    /// saying the action landed.
    private var lockedActions: Set<String> = []

    private let defaults: UserDefaults
    private var loaded = false
    /// Bounded so a long-lived process cannot grow the set past the point of usefulness: an action id is 64 characters at most, and a
    /// card with four actions that nobody ever taps would otherwise keep four keys forever.
    private static let maximumLockedActions = 256

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Loading

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let storedCards = PopopxEcoCodec.decode([PopopxServiceCard].self, from: defaults.data(forKey: PopopxEcoKeys.cards)) ?? []
        cards = [:]
        for card in storedCards where card.isSane {
            cards[card.cardId] = card
        }
        // Menus are keyed by a local contact id, which is **not portable**: `ChatInfo.apiId` is a row number in this device's
        // database (the same fact PopopxChannelAccessPayload records for its credential key), so a menu restored under an id that now
        // belongs to a different conversation would hand one contact's buttons to another. They are therefore rebuilt from inbound
        // `menu_config` frames and never persisted.
    }

    // MARK: Reading

    /// The state a bubble should render for the card in this message: the store's newest version when there is one, the payload of
    /// the message that created it otherwise.
    func rendered(card: PopopxServiceCard) -> PopopxServiceCard {
        loadIfNeeded()
        guard let current = cards[card.cardId], current.updatedAtMs >= card.updatedAtMs else { return card }
        return current
    }

    func card(_ cardId: String) -> PopopxServiceCard? {
        loadIfNeeded()
        return cards[cardId]
    }

    func liveMenu(for contactId: Int64) -> PopopxEcoMenu? {
        loadIfNeeded()
        return menus[contactId]
    }

    func isActionLocked(cardId: String, actionId: String) -> Bool {
        lockedActions.contains("\(cardId)\u{1}\(actionId)")
    }

    /// Remember that this action was already fired, so a second tap in the same state does nothing.
    ///
    /// `cardId` and `actionId` are joined with `U{1}` rather than with a printable character because both are server-supplied and
    /// neither is forbidden from containing `-` or `:`; a separator that cannot appear in either half is the only thing that keeps
    /// `("a", "b\U{1}c")` and `("a\U{1}b", "c")` from colliding onto one key. The same join is what `pruneLocks(dropping:)` filters on.
    func lock(cardId: String, actionId: String) {
        if lockedActions.count >= Self.maximumLockedActions { lockedActions.removeAll() }
        lockedActions.insert("\(cardId)\u{1}\(actionId)")
    }

    // MARK: Writing

    /// Apply a decoded frame. Returns what the caller should surface, if anything.
    ///
    /// The card half is a "newest wins" comparison rather than an assignment: frames arrive over SMP in the order the server sent
    /// them, but a device that was offline receives them all at once, and an older progress bar must not repaint a newer one.
    @discardableResult
    func apply(_ frame: PopopxEcoFrame, contactId: Int64) -> PopopxEcoApplyOutcome {
        loadIfNeeded()
        switch frame {
        case let .sessionHandshake(session):
            guard session.isSane else { return .rejected }
            return PopopxEcoSessionStore.save(session, contactId: contactId, defaults: defaults)
                ? .storedSession
                : .keychainFailed

        case let .menuConfig(menu):
            guard menu.isSane else { return .rejected }
            if let existing = menus[contactId],
               let existingRevision = existing.revision,
               let revision = menu.revision,
               revision < existingRevision {
                return .ignoredStale
            }
            menus[contactId] = menu
            return .storedMenu

        case let .serviceCard(card):
            guard card.isSane else { return .rejected }
            let current = cards[card.cardId]
            if let current, current.updatedAtMs > card.updatedAtMs { return .ignoredStale }
            cards[card.cardId] = merged(new: card, old: current)
            // A card change means whatever was in flight either landed or was replaced, so the lockout for that card is lifted.
            pruneLocks(dropping: card.cardId)
            saveCards()
            return card.mode == .create ? .renderedCard : .updatedCard

        case let .channelKeyUpdate(update):
            // `contactId` is safe to record as the issuer here: `observeIncoming` refuses every frame but a card in a group, so on this
            // branch it is always a direct contact id.
            switch ChannelKeyRotationManager.shared.apply(update, issuerContactId: contactId) {
            case let .installed(epoch, revoked):
                pendingNotice = revoked.isEmpty
                    ? .keyRotated(channelId: update.channelId, epoch: epoch, revoked: false)
                    : .keyRotated(channelId: update.channelId, epoch: epoch, revoked: true)
                return .rotatedKey
            case .alreadyCurrent:
                return .ignoredStale
            case .rejected(let reason):
                pendingNotice = .keyRejected(channelId: update.channelId, reason: reason)
                return .rejected
            }
        }
    }

    /// Merge an update into what is on screen.
    ///
    /// Absent sections in an update mean "unchanged", not "cleared": a vote frame that carries only `progress` would otherwise wipe
    /// the title and the buttons, and the user would watch the card they were looking at empty itself out. `fields` and `actions` are
    /// replaced wholesale when present, because a partial grid row is not a meaning anyone can read.
    private func merged(new: PopopxServiceCard, old: PopopxServiceCard?) -> PopopxServiceCard {
        guard var old else { return new }
        if !new.title.isEmpty { old.title = new.title }
        if let body = new.body { old.body = body }
        if !new.fields.isEmpty { old.fields = new.fields }
        if !new.actions.isEmpty { old.actions = new.actions }
        if let progress = new.progress { old.progress = progress }
        if let expiresAtMs = new.expiresAtMs { old.expiresAtMs = expiresAtMs }
        old.style = new.style
        old.updatedAtMs = max(old.updatedAtMs, new.updatedAtMs)
        old.mode = .create
        return old
    }

    private func pruneLocks(dropping cardId: String) {
        let prefix = "\(cardId)\u{1}"
        lockedActions = lockedActions.filter { !$0.hasPrefix(prefix) }
    }

    private func saveCards() {
        // Bounded history: a card whose conversation was deleted would otherwise live in the plist forever, and 200 is far above any
        // number of cards one device can have on screen.
        var keep = Array(cards.values)
        keep.sort { $0.updatedAtMs < $1.updatedAtMs }
        if keep.count > PopopxEcoLimits.maximumStoredCards {
            keep.removeFirst(keep.count - PopopxEcoLimits.maximumStoredCards)
        }
        cards = Dictionary(uniqueKeysWithValues: keep.map { ($0.cardId, $0) })
        guard let data = PopopxEcoCodec.encode(keep) else { return }
        defaults.set(data, forKey: PopopxEcoKeys.cards)
    }

    // MARK: Drain

    func takeNotice() -> PopopxEcoNotice? {
        defer { pendingNotice = nil }
        return pendingNotice
    }

    func raise(_ notice: PopopxEcoNotice) {
        pendingNotice = notice
    }
}

/// What one frame did. The router logs it and the views act only on the ones a user can see.
enum PopopxEcoApplyOutcome: Hashable, Sendable {
    case renderedCard
    case updatedCard
    case storedSession
    case storedMenu
    case rotatedKey
    case ignoredStale
    case rejected
    case keychainFailed
}

/// A one-shot message the router raised and a view is allowed to show.
///
/// An enum rather than a `String` so the sentences come from the copy table at the point of display: a router that formats its own
/// user-facing text would be a module that owns translations it cannot render.
enum PopopxEcoNotice: Hashable, Sendable {
    case keyRotated(channelId: String, epoch: Int, revoked: Bool)
    /// The refusal reason is carried as a value, and the view decides how much of it to say: `signatureInvalid` and `issuerConflict`
    /// are worth a sentence, `outOfRange` is not something a member can act on.
    case keyRejected(channelId: String, reason: PopopxKeyRejection)
    case insufficientCredits(required: Int)
    case actionFailed
}

extension PopopxEcoLimits {
    static let maximumStoredCards = 200
}

// MARK: - Session store

/// The Keychain half of a session handshake.
enum PopopxEcoSessionStore {
    /// Save, or replace. False means the item could not be written, and the caller must not pretend the service is linked.
    @discardableResult
    static func save(_ session: PopopxEcoSession, contactId: Int64, defaults: UserDefaults = .standard) -> Bool {
        guard let secret = session.secretBytes else { return false }
        guard PopopxEcoKeychain.write(secret, account: PopopxEcoKeychain.sessionAccount(contactId: contactId)) else { return false }
        // The pseudonym is not a secret and is needed by the launcher on every open; keeping it beside the secret in the Keychain
        // would make a read of one impossible without a read of the other, and the `open_url` path needs both at different times.
        defaults.set(session.pairwiseUid, forKey: "popopx.eco.session.uid.\(contactId)")
        if let serviceId = session.serviceId {
            defaults.set(serviceId, forKey: "popopx.eco.session.svc.\(contactId)")
        }
        return true
    }

    static func session(for contactId: Int64, defaults: UserDefaults = .standard) -> PopopxEcoSession? {
        guard let secret = PopopxEcoKeychain.read(PopopxEcoKeychain.sessionAccount(contactId: contactId)),
              let uid = defaults.string(forKey: "popopx.eco.session.uid.\(contactId)"),
              !uid.isEmpty
        else { return nil }
        return PopopxEcoSession(
            pairwiseUid: uid,
            secretHex: PopopxEcoHex.encode(secret),
            serviceId: defaults.string(forKey: "popopx.eco.session.svc.\(contactId)")
        )
    }

    static func hasSession(for contactId: Int64) -> Bool {
        PopopxEcoKeychain.contains(PopopxEcoKeychain.sessionAccount(contactId: contactId))
    }

    static func remove(contactId: Int64, defaults: UserDefaults = .standard) {
        PopopxEcoKeychain.remove(PopopxEcoKeychain.sessionAccount(contactId: contactId))
        defaults.removeObject(forKey: "popopx.eco.session.uid.\(contactId)")
        defaults.removeObject(forKey: "popopx.eco.session.svc.\(contactId)")
    }
}

// MARK: - Router

/// The inbound half, the outbound half, and the deep links, in one type: they are the same three ends of one protocol and the
/// ordering between them is the part that is easy to get wrong.
@MainActor
@Observable
final class PopopxEcoRouter {
    static let shared = PopopxEcoRouter()

    /// A follow-up that can only be delivered once a connection exists: `::REF::` and `::SSO_SCAN::` both need a contact id, and a
    /// deep link that opens a service account for the first time has none yet.
    ///
    /// Held in memory and keyed by the service's own SMP address rather than persisted: an intent that survives a relaunch would be a
    /// silent message sent without the user having touched anything since, and `::SSO_SCAN::` authorises a login on a third-party site.
    struct Intent: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// Send `::REF::<articleId>` into the service account the link opened.
            case reference(String)
            /// Send `::SSO_SCAN::<sessionId>`: the QR of a third-party site, already scanned by this device's camera.
            case ssoScan(String)
        }

        var kind: Kind
        /// The invite address from the link's `uri=` parameter, used to recognise the contact this intent belongs to.
        var serviceURI: String
        /// The link's `ref`/`session` value is also kept so the confirmation sheet can name what it is about to send.
        var displayValue: String
    }

    private(set) var pendingIntent: Intent?
    /// The card whose pay-for flow is waiting on the user in the credit store. One at a time, because the sheet it jumps to is
    /// itself a single-instance sheet.
    private(set) var creditTopUpRequest: PopopxEcoCreditRequest?

    private let store: PopopxEcoStore
    /// The same subsystem the commerce router logs under, its own category, so an eco frame and a `::popopx_sys::` frame can be told
    /// apart in Console without filtering on the message text.
    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "eco")

    init(store: PopopxEcoStore = .shared) {
        self.store = store
    }

    // MARK: Mount point · a message arrived

    /// Called from `POPOPXAPI.swift` beside the commerce router. See the header for why this is a second call and not a second listener.
    ///
    /// In a group only `service_card` is accepted. The other three frames are per-person or per-channel secrets and a group has neither:
    /// a `menu_config` would attach one member's private menu to a conversation shared with everybody, a `session_handshake` would
    /// store one member's pairwise identity under the group's id, and a `channel_key_update` would push an epoch key to people who are
    /// not members of that channel. This is the same refusal the commerce router makes for redemption signalling
    /// (PopopxSilentSignalingRouter.swift:184).
    func observeIncoming(chatType: ChatType, chatId: Int64, itemId: Int64, text: String) {
        guard chatType == .direct || chatType == .group else { return }
        guard let frame = PopopxEcoMarker.parse(controlText: text) else { return }
        switch (chatType, frame) {
        case (.direct, _), (.group, .serviceCard):
            break
        case (.group, _):
            log.info("eco: frame of kind \(String(describing: frame), privacy: .public) refused in a group")
            return
        default:
            return
        }
        Task { await handle(frame, chatType: chatType, chatId: chatId, itemId: itemId, wire: text) }
    }

    private func handle(
        _ frame: PopopxEcoFrame,
        chatType: ChatType,
        chatId: Int64,
        itemId: Int64,
        wire: String
    ) async {
        // `chatId` here is `cInfo.apiId`, which is what the send path and the session index both use.
        let outcome = store.apply(frame, contactId: chatId)
        switch outcome {
        case .rejected, .keychainFailed:
            log.info("eco: frame refused on chat :\(chatId, privacy: .public) (\(String(describing: outcome), privacy: .public))")
        case .ignoredStale:
            log.debug("eco: stale frame ignored")
        case .renderedCard:
            // The row stays: it is the bubble the user reads. Everything below is a frame that must not leave a visible row.
            break
        case .updatedCard, .storedSession, .storedMenu, .rotatedKey:
            await eraseControlRow(chatType: chatType, chatId: chatId, itemId: itemId)
        }
        // A handshake is also the moment a pending deep-link intent can finally be delivered: this device just met a service account,
        // and this is the only point in the app that knows it happened.
        if case .sessionHandshake = frame, case .direct = chatType {
            await deliverPendingIntent(contactId: chatId)
        }
    }

    /// Delete this device's row of a control frame. `.cidmInternal` and nothing else — see the header.
    private func eraseControlRow(chatType: ChatType, chatId: Int64, itemId: Int64) async {
        let model = ChatModel.shared
        guard let chat = model.chats.first(where: { $0.chatInfo.apiId == chatId }) else {
            log.error("eco: no chat for apiId :\(chatId, privacy: .public); the control row stays in memory")
            return
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
            }
        } catch {
            log.error("eco: delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Uplink

    /// Send one eco uplink line (`::CB::…`, `::REF::…`, `::SSO_SCAN::…`) into a direct conversation.
    ///
    /// Through the app's own routing decision table rather than a direct `apiSendMessages`: §5 of the brief asks for the dual-mode
    /// path, and `apiSendMessages` alone bypasses `PopopxMessageRouter` entirely, which would mean a callback to a Cabin-bound service
    /// account silently never arrives while that contact's ordinary messages do.
    ///
    /// The host fallback is the *same* text, sent the ordinary way: an eco uplink is plain text by construction, so nothing about it
    /// needs a second code path, and that is exactly why `PopopxComposerRouting` can treat it like any other message.
    func send(_ text: String, toContactId contactId: Int64) async -> PopopxEcoSendOutcome {
        let eligibility = await PopopxInputBarModel.resolveFromRuntime(contactId: Optional(contactId))
        switch PopopxComposerRouting.dispatch(
            text: text,
            context: .directContact(contactId),
            eligibility: eligibility,
            ttlSeconds: nil
        ) {
        case let .routeViaMesh(message):
            let routed = await PopopxMeshRuntime.shared.router.send(message)
            switch routed.outcome {
            case .smpAcknowledged, .smpUnacknowledgedMeshParallel, .smpUnacknowledgedNoMesh, .meshSent:
                // All four mean "the text left this device". The two `smpUnacknowledged` verdicts are not failures here: an SMP
                // timeout window measures a *reply*, not a request, so the send is still live and refusing it would make the caller
                // believe an outgoing callback had died when it is only unconfirmed.
                return .sent
            case let .queuedOffline(reason):
                // Held in the mesh queue and retried, so nothing is lost, but the peer has not received it yet.
                return .queuedOffline(reason: reason)
            case .refusedUnboundStranger, .duplicate, .nothingToReroute:
                return .failed(reason: .noRoute)
            }
        case let .hostShouldSend(reason):
            // The host's own SMP send. A callback is a whole-line text with no attachments, no quote and no TTL, which is what every
            // one of these reasons is about except "the feature is off".
            if await sendViaSMP(text, contactId: contactId) {
                return .sent
            }
            log.info("eco: SMP uplink failed (host path was chosen for \(String(describing: reason), privacy: .public))")
            return .failed(reason: .sendRefused)
        case .ignoreEmptyDraft:
            // Unreachable: every uplink this class builds is a prefix plus a payload that `isSingleToken` already proved non-empty.
            return .failed(reason: .emptyDraft)
        }
    }

    /// The plain `apiSendMessages` text send, following `PopopxSilentSignalingRouter.send(text:to:)`
    /// (PopopxSilentSignalingRouter.swift:597-625) rather than inventing a third spelling of the same FFI call.
    ///
    /// `apiSendMessages` does not throw — a refusal pops an app-layer prompt and returns nothing — so "nil or an empty array" is the
    /// failure signal, and the returned items must be pushed into `ChatModel` by hand or the row exists on the server and in the
    /// database but not in the open conversation.
    private func sendViaSMP(_ text: String, contactId: Int64) async -> Bool {
        guard let chat = ChatModel.shared.getContactChat(contactId) else {
            log.error("eco: contact chat :\(contactId, privacy: .public) not found")
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
            log.error("eco: uplink returned no chat item")
            return false
        }
        for item in items {
            ChatModel.shared.addChatItem(chat.chatInfo, item)
        }
        return true
    }

    /// The callback a card button fires. The `::CB::` prefix and the payload are concatenated without escaping, so a payload
    /// containing whitespace would look like two commands; the parser rejects those before anything is sent.
    func sendCallback(payload: String, toContactId contactId: Int64) async -> PopopxEcoSendOutcome {
        guard isSingleToken(payload) else { return .failed(reason: .malformedPayload) }
        return await send("::CB::\(payload)", toContactId: contactId)
    }

    func sendReference(_ articleId: String, toContactId contactId: Int64) async -> PopopxEcoSendOutcome {
        guard isSingleToken(articleId) else { return .failed(reason: .malformedPayload) }
        return await send("::REF::\(articleId)", toContactId: contactId)
    }

    func sendSSOScan(_ sessionId: String, toContactId contactId: Int64) async -> PopopxEcoSendOutcome {
        guard isSingleToken(sessionId) else { return .failed(reason: .malformedPayload) }
        return await send("::SSO_SCAN::\(sessionId)", toContactId: contactId)
    }

    private func isSingleToken(_ text: String) -> Bool {
        !text.isEmpty
            && text.count <= PopopxEcoLimits.maximumPayloadCharacters
            && text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && !text.contains("::")
    }

    // MARK: Pending intents

    func recordPendingIntent(_ intent: Intent) {
        pendingIntent = intent
    }

    /// Deliver the held intent, if the contact it belongs to is the one it was recorded against.
    ///
    /// The check is deliberately weak in exactly one direction and strong in the other: this app has no way to map an invite address
    /// to a `contactId` before the connection completes, so the match is "the service account that just identified itself with an eco
    /// handshake". That is strong enough to prevent sending an SSO authorisation to an unrelated contact, and it is why an intent is
    /// dropped rather than guessed when no handshake ever arrives.
    private func deliverPendingIntent(contactId: Int64) async {
        guard let intent = pendingIntent else { return }
        switch intent.kind {
        case .reference(let articleId):
            pendingIntent = nil
            _ = await sendReference(articleId, toContactId: contactId)
        case .ssoScan(let sessionId):
            pendingIntent = nil
            _ = await sendSSOScan(sessionId, toContactId: contactId)
        }
    }

    func clearPendingIntent() {
        pendingIntent = nil
    }

    // MARK: Credits

    /// A card button that spends compute credits.
    ///
    /// The order matters twice over: the balance is checked *before* anything is written to the ledger, and the callback is sent only
    /// after the debit succeeded — a `::CB::<payload>:paid_<txHash>` that names a transaction which does not exist would be a
    /// payment confirmation the server has no way to refuse and no way to honour.
    /// When the debit succeeds but the callback does not reach the peer, the entry is kept and the hash is returned anyway: the user
    /// paid, the ledger is the record, and a second tap on a locked button must not charge them twice.
    func payForCard(_ card: PopopxServiceCard, action: PopopxEcoAction, toContactId contactId: Int64) async -> PopopxCreditPayment {
        guard let amount = action.amount,
              amount >= PopopxEcoLimits.minimumAmount,
              amount <= PopopxEcoLimits.maximumCreditAmount
        else { return .failed(.malformedPayload) }
        let manager = PopopxCreditsManager.shared
        guard manager.balance >= amount else {
            return .insufficientBalance(required: amount, available: manager.balance)
        }
        // The ledger note is the amount plus the title the user was actually shown. `action.target` is deliberately NOT used here: it
        // is a server-supplied string that never appeared on screen, and a ledger row nobody can account for is worse than a terse one.
        // `card.title` is bounded by `PopopxServiceCard.isSane`, so the note cannot be padded out by a peer.
        let note = "\(String(format: PopopxEcoCopy.creditsPaidFormat, amount)) · \(card.title)"
        do {
            let entry = try manager.payForService(amount: amount, note: note)
            let outcome = await send("::CB::\(action.payload ?? card.cardId):paid_\(entry.id)", toContactId: contactId)
            return .paid(transactionId: entry.id, delivered: outcome.wasSent)
        } catch let error as PopopxBadgeCreditsError {
            log.error("eco: payment refused: \(String(describing: error), privacy: .public)")
            return .failed(.ledger(error))
        } catch {
            log.error("eco: payment failed")
            return .failed(.ledger(nil))
        }
    }

    /// Remember that the user should be sent to the credit store, and by how much they are short.
    func requestCreditTopUp(required: Int, available: Int) {
        creditTopUpRequest = PopopxEcoCreditRequest(required: required, available: available)
    }

    func takeCreditTopUpRequest() -> PopopxEcoCreditRequest? {
        defer { creditTopUpRequest = nil }
        return creditTopUpRequest
    }
}

// MARK: - Send outcome

enum PopopxEcoSendOutcome: Hashable, Sendable {
    case sent
    /// Bluetooth took a copy and will retry it. Nothing is lost, but the peer has not received it, so no UI may claim a delivery.
    /// `PopopxQueueReason` is module 5's own vocabulary and is carried through unchanged rather than re-spelled here.
    case queuedOffline(reason: PopopxQueueReason)
    case failed(reason: PopopxEcoSendFailure)

    var wasSent: Bool { self == .sent }
}

enum PopopxEcoSendFailure: Hashable, Sendable {
    /// `apiSendMessages` came back with nothing, which is how that call reports a refusal (it does not throw).
    case sendRefused
    /// Module 5 refused to route it anywhere: the peer is an unbound stranger.
    case noRoute
    /// A payload that would have looked like two commands. Rejected before the send, so nothing went out.
    case malformedPayload
    /// An empty line reached the decision table. Unreachable from this class by construction; kept so the switch is exhaustive
    /// on `PopopxComposerDispatch` rather than on the cases this class happens to expect.
    case emptyDraft
}

enum PopopxCreditPayment: Hashable, Sendable {
    /// The debit landed. `delivered` says whether the confirmation callback reached the peer, which the card shows as a
    /// "waiting for a reply" row rather than as a failure — the credits are gone either way.
    case paid(transactionId: String, delivered: Bool)
    case insufficientBalance(required: Int, available: Int)
    case failed(PopopxEcoPaymentFailure)
}

enum PopopxEcoPaymentFailure: Hashable, Sendable {
    case malformedPayload
    case ledger(PopopxBadgeCreditsError?)
}

struct PopopxEcoCreditRequest: Hashable, Sendable {
    var required: Int
    var available: Int
    var shortfall: Int { max(required - available, 0) }
}

// MARK: - Card action dispatch

/// What a card button does, decided in one place so the bubble, the menu bar and the deep link cannot each invent a half of it.
enum PopopxEcoActionRunner {
    /// The lockout is keyed on `cardId + actionId`, which means the *card* decides when the lock is released (any change to it clears
    /// its own locks, `PopopxEcoStore.merged`). A timer-based lock would release while the peer was still silent.
    @MainActor
    static func run(
        _ action: PopopxEcoAction,
        on card: PopopxServiceCard,
        contactId: Int64,
        store: PopopxEcoStore = .shared,
        router: PopopxEcoRouter = .shared
    ) async -> PopopxEcoActionResult {
        guard !store.isActionLocked(cardId: card.cardId, actionId: action.id) else { return .locked }
        guard card.isLive(nowMs: Int64(Date.now.timeIntervalSince1970 * 1_000)) else { return .expired }
        guard action.isLive else { return .ignored }
        store.lock(cardId: card.cardId, actionId: action.id)
        switch action.kind {
        case .callback:
            guard let payload = action.payload else { return .ignored }
            let outcome = await router.sendCallback(payload: payload, toContactId: contactId)
            return outcome.wasSent ? .sentCallback : .sendFailed
        case .payCredits:
            let payment = await router.payForCard(card, action: action, toContactId: contactId)
            switch payment {
            case .paid(_, let delivered):
                return delivered ? .sentCallback : .paidAwaitingReply
            case let .insufficientBalance(required, available):
                router.requestCreditTopUp(required: required, available: available)
                return .needsCredits(required: required, available: available)
            case .failed:
                return .sendFailed
            }
        case .openURL:
            guard let url = action.url, PopopxEcoAction.isHttpURL(url) else { return .ignored }
            guard let session = PopopxEcoSessionStore.session(for: contactId) else {
                return .noSession
            }
            return PopopxH5Launcher.present(url: url, session: session) ? .openedH5 : .sendFailed
        case .openChannel:
            guard let payload = action.payload, let uri = PopopxChannelPublicURI.parse(payload) else { return .ignored }
            return PopopxEcoDeepLinkHandler.openChannel(uri) ? .openedChannel : .sendFailed
        case .sendCommand, .none:
            // A card carries commands only through a menu button; a card action of this kind is a server that meant the menu layer.
            return .ignored
        }
    }
}

/// The outcome a bubble turns into a line of copy and a haptic. Nothing here is a sentence: the view owns the wording.
enum PopopxEcoActionResult: Hashable, Sendable {
    case sentCallback
    case paidAwaitingReply
    case needsCredits(required: Int, available: Int)
    case openedH5
    case openedChannel
    case locked
    case expired
    case ignored
    case noSession
    case sendFailed
}

// MARK: - Deep Link Handler Stub

/// Stub handler for eco deep links. The brief mentions SSO scan routing and channel opening, but does not specify the handler's implementation.
/// This stub returns `false` for all operations, which the caller treats as `.sendFailed`. A real implementation would integrate with
/// the app's deep-link router and SSO flow.
enum PopopxEcoDeepLinkHandler {
    static func openChannel(_ uri: PopopxChannelPublicURI) -> Bool {
        // TODO: integrate with the app's channel-joining flow
        return false
    }
}
