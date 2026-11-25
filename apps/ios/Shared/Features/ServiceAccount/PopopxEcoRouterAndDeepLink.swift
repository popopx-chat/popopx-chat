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
//  "Uplink" is not the same thing as "invisible", and it was not true until this round. These three lines are **plain text** — no
//  `::POPOPX_ECO::` marker — so `PopopxEcoMarker.isControlText` never matched them and they rendered as an ordinary sent bubble, in the
//  chat list preview and in a notification (`PopopxSysMarker.isSignalText` is the only criterion, and it is consulted by all three
//  gates). `PopopxEcoUplink` now defines the three prefixes once and answers for the gate, and every line is built through its
//  `wireString`, so a line that can be sent is a line that is suppressed on screen. The row still exists in the timeline: an inbound
//  control frame is deleted with `.cidmInternal` because a later reload would re-apply it, while an outbound line carries no state to
//  re-apply, so render suppression is the whole job and a second FFI round trip per send is not.
//
//  ### Which handshake may collect a scanned link
//  A `popopx://service?uri=…&ref=…` scan can only be completed after the peer's `session_handshake`, and that frame arrives on *any*
//  direct chat, so the held intent must be able to refuse. Two facts make the refusal possible: the set of direct contact ids that
//  already existed when the link was scanned, and — when `planAndConnect` recognised the link's address for an existing contact — that
//  contact's id, which is the only place in the app where an address and a `contactId` are seen together. A bound intent goes to the
//  contact it is bound to and nobody else; an unbound one goes only to a contact that was *not* in the snapshot, because the
//  connection a scan makes is a new contact — one the user already had is handled synchronously by `reachedExistingContact` and never
//  reaches this branch. Both answers expire after `PopopxEcoLimits.pendingIntentLifetimeSeconds`, and an intent whose connection was
//  cancelled is dropped rather than left to be collected later. What remains unprovable is stated on `Intent.accepts(contactId:)`.
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
    static let shared = PopopxEcoRouter(store: .shared)

    /// A follow-up that can only be delivered once a connection exists: `::REF::` and `::SSO_SCAN::` both need a contact id, and a
    /// deep link that opens a service account for the first time has none yet.
    ///
    /// Held in memory and keyed by the service's own SMP address rather than persisted: an intent that survives a relaunch would be a
    /// silent message sent without the user having touched anything since, and `::SSO_SCAN::` authorises a login on a third-party site.
    ///
    /// `deliverPendingIntent` is called by *every* direct handshake, so the intent carries the three facts that let it tell the
    /// handshake it was recorded for from an unrelated one: when it was recorded, which contacts already existed then, and — when the
    /// app recognised an existing contact for the link's address — which contact id that was.
    struct Intent: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// Send `::REF::<articleId>` into the service account the link opened.
            case reference(String)
            /// Send `::SSO_SCAN::<sessionId>`: the QR of a third-party site, already scanned by this device's camera.
            case ssoScan(String)
        }

        var kind: Kind
        /// The invite address from the link's `uri=` parameter: what the connection flow is handed, and the only stable identity of
        /// the service account the link named. **Never logged and never shown whole** — the address carries the secret that
        /// authorises the connection (`#h=` on an SMP contact link, `#key=` on a channel link; see `PopopxChannelPublicURI`'s
        /// "why the fragment is the whole design"). Nothing compares it against a local record, because no local record keeps a peer
        /// address: that is why `knownContactIds` and `boundContactId` exist.
        var serviceURI: String
        /// The link's `ref`/`session` value is also kept so the confirmation sheet can name what it is about to send.
        var displayValue: String
        /// Stamped by `recordPendingIntent`, not by the caller, so a hand-built intent cannot be made to look newborn.
        var recordedAt: Date = Date()
        /// Every direct contact id the app had at that moment: a contact *not* in this set is one this link created.
        var knownContactIds: Set<Int64> = []
        /// Set once the connection flow reports the contact it already knew for this exact address — the strongest evidence the app
        /// can get, and it makes the identity question moot for that contact.
        var boundContactId: Int64?

        /// A link scanned and left is dead rather than queued: delivering it later is the mis-delivery this whole type exists to avoid.
        func isStale(now: Date) -> Bool {
            now.timeIntervalSince(recordedAt) > PopopxEcoLimits.pendingIntentLifetimeSeconds
        }

        /// Whether the handshake from `contactId` may consume this intent.
        ///
        /// Bound: only that contact, which is exact. Unbound: only a contact that did *not* exist when the link was scanned, because
        /// the connection a scan makes is a new contact — a contact the user already had is answered synchronously by
        /// `reachedExistingContact` and never waits here. Refusing the known ones is the point: it stops a `::SSO_SCAN::` meant for the
        /// account in the link from landing in whichever service account handshakes next.
        ///
        /// The two directions this cannot close, and which way each fails. A *new* contact created by something other than this link,
        /// inside the window, can still collect the intent. And a contact the link did name whose `filterKnownContact` never fired is
        /// refused — the intent is consumed and dropped rather than delivered on a guess. That false negative is the safe half of the
        /// trade: the user re-scans, whereas a false positive authorises a login on the wrong account.
        func accepts(contactId: Int64) -> Bool {
            if let boundContactId { return boundContactId == contactId }
            return !knownContactIds.contains(contactId)
        }
    }

    private(set) var pendingIntent: Intent?
    /// Which channel an `open_channel` action asked to see, read by `ContentView`'s sheet and cleared when it closes.
    ///
    /// A request rather than a push: `ChannelKeyManagementView.swift:61` carries its own `NavigationStack`, and a self-stacked page
    /// mounted inside another stack is the double navigation bar `MainTabView.swift:161` records avoiding for exactly this reason.
    var channelPageRequest: PopopxEcoChannelPageRequest?
    /// The card whose pay-for flow is waiting on the user in the credit store. One at a time, because the sheet it jumps to is
    /// itself a single-instance sheet.
    private(set) var creditTopUpRequest: PopopxEcoCreditRequest?

    private let store: PopopxEcoStore
    /// The same subsystem the commerce router logs under, its own category, so an eco frame and a `::popopx_sys::` frame can be told
    /// apart in Console without filtering on the message text.
    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "eco")

    @MainActor
    init(store: PopopxEcoStore) {
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
            // Unreachable: every uplink this class builds goes through `PopopxEcoUplink.wireString`, which refuses an empty payload
            // before there is a line to send.
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
    ///
    /// Every uplink line is built by `PopopxEcoUplink.wireString`, never by spelling the prefix here: that is the same function the
    /// render-suppression gate consults, so a line that can be sent is a line that can be hidden, and neither end can be updated alone.
    func sendCallback(payload: String, toContactId contactId: Int64) async -> PopopxEcoSendOutcome {
        await sendUplink(PopopxEcoUplink.wireString(prefix: PopopxEcoUplink.callbackPrefix, payload: payload), toContactId: contactId)
    }

    func sendReference(_ articleId: String, toContactId contactId: Int64) async -> PopopxEcoSendOutcome {
        await sendUplink(PopopxEcoUplink.wireString(prefix: PopopxEcoUplink.referencePrefix, payload: articleId), toContactId: contactId)
    }

    func sendSSOScan(_ sessionId: String, toContactId contactId: Int64) async -> PopopxEcoSendOutcome {
        await sendUplink(PopopxEcoUplink.wireString(prefix: PopopxEcoUplink.ssoScanPrefix, payload: sessionId), toContactId: contactId)
    }

    private func sendUplink(_ wire: String?, toContactId contactId: Int64) async -> PopopxEcoSendOutcome {
        guard let wire else { return .failed(reason: .malformedPayload) }
        return await send(wire, toContactId: contactId)
    }

    // MARK: Pending intents

    /// Take custody of an intent for one handshake window.
    ///
    /// The three target-facts are stamped here rather than by the caller: a caller that could choose `recordedAt` could choose a
    /// future one and keep the intent alive indefinitely, and the contact snapshot has to be taken at the same instant for the
    /// before/after comparison in `accepts(contactId:)` to mean anything.
    func recordPendingIntent(_ intent: Intent) {
        var intent = intent
        intent.recordedAt = Date()
        intent.boundContactId = nil
        intent.knownContactIds = directContactIds()
        pendingIntent = intent
    }

    /// The direct contacts this device has right now, as ids only.
    ///
    /// `Contact` is not `Sendable` and `createdAt`/`updatedAt` are internal to `POPOPXChat`, so what can cross this boundary is the
    /// id and nothing else — which is also all the set-difference needs.
    private func directContactIds() -> Set<Int64> {
        Set(ChatModel.shared.chats.compactMap { chat in
            guard case let .direct(contact) = chat.chatInfo else { return nil }
            return contact.contactId
        })
    }

    /// Pin a held intent to a contact id, from the one place in the app that maps an invite address to a contact: `planAndConnect`'s
    /// `filterKnownContact`, which is handed the contact it recognised for *that address*. After this, `accepts(contactId:)` is exact.
    func bindPendingIntent(contactId: Int64) {
        guard var intent = pendingIntent else { return }
        intent.boundContactId = contactId
        pendingIntent = intent
    }

    /// Drop the intent when the connection it was waiting for was abandoned.
    ///
    /// Wired to `planAndConnect`'s `cleanup`, which fires on cancel, on a refused link *and* after a chat opened
    /// (`openKnownChat` calls it from `loadOpenChat`'s completion, NewChatView.swift:1734-1745), so "cleanup ran" is not evidence of
    /// anything on its own. The two tests that separate abandoned from succeeded: nothing is in progress any more, and no contact
    /// exists that the snapshot did not already have. An intent already bound to a contact is left alone, because that contact is
    /// connected and the handshake — not this cleanup — owns its delivery.
    ///
    /// The caller defers this by one main-actor turn (`Task { @MainActor in … }`): `cancelConnectProgress()` runs its handler
    /// **before** clearing the flag (ChatModel.swift:317-320), so read in the same turn `isInProgress` would still say yes.
    func discardPendingIntentIfConnectionAborted() {
        guard let intent = pendingIntent, intent.boundContactId == nil else { return }
        guard !ConnectProgressManager.shared.isInProgress else { return }
        guard directContactIds().subtracting(intent.knownContactIds).isEmpty else { return }
        pendingIntent = nil
        log.info("eco: pending intent dropped, the connection it waited for was cancelled")
    }

    /// Deliver the held intent to the contact that just completed an eco handshake, if it is that contact.
    ///
    /// Two refusals, then one shot: this app cannot map an invite address to a `contactId` before a connection completes, so the
    /// strongest available evidence is the bound id from `bindPendingIntent`, falling back to "a contact this link cannot have
    /// created is not the one it named" plus the lifetime ceiling. A refused or expired intent is still consumed, because leaving it
    /// in the slot would hand it to the next handshake instead — the exact mis-delivery these tests exist to prevent.
    private func deliverPendingIntent(contactId: Int64) async {
        guard let intent = pendingIntent else { return }
        pendingIntent = nil
        if intent.isStale(now: Date()) {
            log.info("eco: pending intent older than \(Int(PopopxEcoLimits.pendingIntentLifetimeSeconds), privacy: .public)s — not delivered")
            return
        }
        guard intent.accepts(contactId: contactId) else {
            log.error("eco: pending intent refused, the handshake is not the service account the link named")
            return
        }
        switch intent.kind {
        case .reference(let articleId):
            _ = await sendReference(articleId, toContactId: contactId)
        case .ssoScan(let sessionId):
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
        // Proved before the debit, not after: the payload half of the callback line is server-supplied, and a payload `wireString`
        // would refuse is a payment that takes the credits and then cannot deliver the confirmation naming them.
        let callbackPayload = action.payload ?? card.cardId
        guard PopopxEcoUplink.isSendablePayload(callbackPayload) else { return .failed(.malformedPayload) }
        // The ledger note is the amount plus the title the user was actually shown. `action.target` is deliberately NOT used here: it
        // is a server-supplied string that never appeared on screen, and a ledger row nobody can account for is worse than a terse one.
        // `card.title` is bounded by `PopopxServiceCard.isSane`, so the note cannot be padded out by a peer.
        let note = "\(String(format: PopopxEcoCopy.creditsPaidFormat, amount)) · \(card.title)"
        do {
            let entry = try manager.payForService(amount: amount, note: note)
            let outcome = await sendUplink(
                PopopxEcoUplink.wireString(
                    prefix: PopopxEcoUplink.callbackPrefix,
                    payload: "\(callbackPayload):paid_\(entry.id)"
                ),
                toContactId: contactId
            )
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
        store: PopopxEcoStore,
        router: PopopxEcoRouter
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
            // Parsed once here for the *shape* (a malformed payload is `.ignored`, not a failure the user is told about) and the text
            // is passed along, because the unjoined branch needs the fragment the parsed value deliberately drops.
            guard let payload = action.payload, let uri = PopopxChannelPublicURI.parse(payload) else { return .ignored }
            return PopopxEcoDeepLinkHandler.openChannel(uri, sourceText: payload) ? .openedChannel : .sendFailed
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

// MARK: - Deep link

/// `popopx://service?uri=<service address>&ref=<article id>` and
/// `popopx://sso?uri=<service address>&session=<sso session id>` (`service_office.md:91-92`).
///
/// ### Why this is not `URLComponents`, unlike `PopopxChannelPublicURI`
/// The `uri=` parameter holds a connection address, and a connection address carries `#`, `&` and `=` of its own
/// (`smp://host/connId#key=…&auth=…`). Percent-encoded by the producer, that is an ordinary query parameter. Left raw — which is what a
/// QR generator that concatenates strings produces — it turns the address's own `&auth=` into a parameter *after* a fragment, and a
/// whole-query split on `&` cuts the address in half and loses it. So this parser locates the two parameters it knows by name at
/// parameter boundaries and treats **everything between them** as the address, in either order.
///
/// The cost of that choice, stated rather than hidden: unlike `PopopxChannelPublicURI.parse` (`PopopxEcoModels.swift:791`) this cannot
/// reject unrecognised keys, because an unescaped address is indistinguishable from a pile of unrecognised keys. What makes the value
/// safe instead is the two checks at the end — the address must be one printable-ASCII token free of quoting metacharacters, and the id
/// must be the single token `PopopxEcoUplink` requires — plus the fact that the address is never interpreted here: it goes to
/// `planAndConnect`, which asks the core, exactly as pasting a link in "Connect" does.
struct PopopxEcoLink: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A channel article's "handle the business in this service account" link; sends `::REF::`.
        case service
        /// A third-party site's login QR, already scanned by this camera; sends `::SSO_SCAN::`.
        case sso

        /// The literal that claims the link, `?` included.
        var prefix: String {
            switch self {
            case .service: return "popopx://service?"
            case .sso: return "popopx://sso?"
            }
        }

        /// The parameter that carries the value the service needs back.
        var parameter: String {
            switch self {
            case .service: return "ref"
            case .sso: return "session"
            }
        }

        fileprivate init?(_ text: String) {
            if text.hasPrefix(Kind.service.prefix) { self = .service }
            else if text.hasPrefix(Kind.sso.prefix) { self = .sso }
            else { return nil }
        }
    }

    /// The service account's own address, percent-decoded, as it will be handed to the connection flow.
    var serviceURI: String
    var kind: Kind
    /// The article id or the SSO session id — whichever parameter the kind names. This is what travels as the uplink payload.
    var payload: String

    private static let addressParameter = "uri"

    static func parse(_ text: String) -> PopopxEcoLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= PopopxEcoLimits.maximumURLCharacters, let kind = Kind(trimmed) else { return nil }
        let queryStart = trimmed.index(trimmed.startIndex, offsetBy: kind.prefix.count)
        let query = trimmed[queryStart...]

        // One walk over `&`-delimited segments. A parameter counts only at the start of the query or straight after a `&`, which is what
        // stops an `xref=` inside an address value from being read as the article id.
        var uriNameAt: String.Index?
        var uriValueAt: String.Index?
        var anchorNameAt: String.Index?
        var anchorValue: Substring?
        var index = query.startIndex
        while index < query.endIndex {
            guard let equals = query[index...].firstIndex(of: "=") else { break }
            let name = String(query[index..<equals])
            let valueAt = query.index(after: equals)
            let valueEnd = query[valueAt...].firstIndex(of: "&") ?? query.endIndex
            if name == addressParameter {
                if uriNameAt != nil { return nil }
                uriNameAt = index
                uriValueAt = valueAt
            } else if name == kind.parameter {
                if anchorNameAt != nil { return nil }
                anchorNameAt = index
                anchorValue = query[valueAt..<valueEnd]
            }
            guard valueEnd < query.endIndex else { break }
            index = query.index(after: valueEnd)
        }
        guard let uriNameAt, let uriValueAt, let anchorNameAt, let anchorValue else { return nil }

        // The address is the whole span between the two anchors, separators included, so an unescaped `#key=…&auth=…` survives.
        let addressRaw: Substring
        if uriNameAt < anchorNameAt {
            let separator = query.index(before: anchorNameAt)
            guard anchorNameAt > uriValueAt, query[separator] == "&" else { return nil }
            addressRaw = query[uriValueAt..<separator]
        } else {
            addressRaw = query[uriValueAt...]
        }

        guard let address = decoded(addressRaw), isAddressToken(address),
              let payload = decoded(anchorValue), PopopxEcoUplink.isSendablePayload(payload)
        else { return nil }
        return PopopxEcoLink(serviceURI: address, kind: kind, payload: payload)
    }

    /// Percent-decodes only what was percent-encoded. A `%` has no other meaning in either value, so a malformed escape is a broken
    /// link rather than a literal percent, and `removingPercentEncoding` refusing to answer is the right failure.
    private static func decoded(_ value: Substring) -> String? {
        let text = String(value)
        guard !text.isEmpty else { return nil }
        return text.contains("%") ? text.removingPercentEncoding : text
    }

    /// The same predicate the mesh bridge applies before it puts a link on a `/_connect` command line
    /// (`PopopxOfflineBridge.swift:229-234`, whose `forbiddenLinkCharacters` this reuses): 0x21…0x7E only, and none of the quoting or
    /// expansion metacharacters. A space would split the argument; a newline does that *and* ends the command.
    private static func isAddressToken(_ address: String) -> Bool {
        guard !address.isEmpty, address.count <= PopopxOfflineBridge.maxInviteLinkCharacters else { return false }
        guard !address.contains(where: { PopopxOfflineBridge.forbiddenLinkCharacters.contains($0) }) else { return false }
        return address.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }
}

// MARK: - Channel page request

/// Which channel an `open_channel` action asked to see, and what the page should offer when this device is not a member of it.
///
/// `Identifiable` so the host can present it with `.sheet(item:)` the way `ContentView` already presents its one notices sheet: a new
/// request replaces whatever page is showing rather than queueing a second sheet, and clearing the request closes.
///
/// Two fields rather than one URI, because the two outcomes of the lookup open different halves of the same page and only one of them
/// has something to prefill.
struct PopopxEcoChannelPageRequest: Identifiable, Hashable, Sendable {
    /// Non-nil opens that channel's detail directly; nil opens the list, which is where the import field lives.
    var channelId: String?
    /// The tapped link — fragment and read key included — waiting in the import field. Nothing here sends it: `importPublicURI` is the
    /// only reader, and it stores locally.
    var importURI: String?

    var id: String { channelId ?? "import:\(importURI ?? "")" }
}

// MARK: - Deep link dispatch

/// Turns an eco deep link into either an opened service-account conversation carrying the uplink, or a connection request plus the
/// one-shot intent that the peer's handshake collects.
///
/// ### Why it mounts where it does
/// `ContentView.connectViaUrl_` is the single funnel for `.onOpenURL` (`POPOPXApp.swift:165`), for universal links and for every in-app
/// writer of `chatModel.appOpenUrl` (a link tapped in a bubble, in a rendered file, from a share sheet). Mounting there instead of on
/// `.onOpenURL` buys two things for nothing: in-app taps reach the same code, and a cold-launch link keeps the funnel's existing
/// deferral (`appOpenUrlLater`, drained once the app is active) rather than trying to present a sheet into a locked screen. Before this
/// branch existed an eco link fell through to the `else` of that function and the user was told their own QR is "URL is invalid".
///
/// Each scanner is asked **before** its own classification. `PopopxAddFriendView` sends every `popopx://` string to the offline invite
/// gate, because `PopopxOfflineBridge.normalizedInviteLink` deliberately accepts the hand-typed `popopx://` form — without the
/// pre-empting branch an SSO QR becomes a mesh pairing attempt.
///
/// ### What is deliberately not here
/// No second send path: `PopopxEcoRouter` owns the only one, and its uplinks are now suppressed at render by `PopopxEcoUplink`
/// (`PopopxBadgeCreditsModels.swift`, `PopopxSysMarker.isSignalText`) rather than by a gate of this module's. No address-to-contact
/// lookup of the app's own: a `Contact` stores no address and `Connection` stores no link, so the branch that cannot recognise the
/// address records an intent instead of guessing a destination (`deliverPendingIntent`, and the notes on `Intent` for what the two
/// admission tests can and cannot prove). The one address-to-id fact the core *does* report — `filterKnownContact` naming the contact
/// it matched for this address — is captured as `bindPendingIntent`.
///
/// No confirmation before scanning. `::SSO_SCAN::` goes out silently, which is what the QR promises: the user's action *is* the
/// authorisation, and a dialog on top of it would be the pattern every phishing QR trains users to tap through. What was ruled out is
/// a *second* prompt, not the guard: the send is bound to the address that was scanned, expires, and is refused by any handshake that
/// does not match it.
@MainActor
enum PopopxEcoDeepLinkHandler {
    private static let log = Logger(subsystem: "com.popopxchat.popopx", category: "eco")

    /// The scanner entry: a scanned string that is not an eco link is reported as unhandled and the caller continues with whatever it
    /// was already going to do with the text.
    @discardableResult
    static func handle(text: String) -> Bool {
        guard let link = PopopxEcoLink.parse(text) else { return false }
        dispatch(link)
        return true
    }

    /// The URL entry. `absoluteString` rather than a re-serialisation on purpose: it is the characters the producer wrote, so the
    /// unescaped-address form above survives the handover from `.onOpenURL`.
    @discardableResult
    static func handle(url: URL) -> Bool {
        handle(text: url.absoluteString)
    }

    private static func dispatch(_ link: PopopxEcoLink) {
        let router = PopopxEcoRouter.shared
        switch link.kind {
        case .service:
            router.recordPendingIntent(PopopxEcoRouter.Intent(kind: .reference(link.payload), serviceURI: link.serviceURI, displayValue: link.payload))
        case .sso:
            router.recordPendingIntent(PopopxEcoRouter.Intent(kind: .ssoScan(link.payload), serviceURI: link.serviceURI, displayValue: link.payload))
        }
        log.info("eco: deep link \(link.kind == .service ? "service" : "sso", privacy: .public) handed to the connection flow")
        planAndConnect(link.serviceURI, theme: AppTheme.shared, dismiss: true,
                       cleanup: {
            // Deferred one turn on purpose — see `discardPendingIntentIfConnectionAborted`. The Task is also what makes calling a
            // `@MainActor` method from this plain `(() -> Void)?` legal.
            Task { @MainActor in PopopxEcoRouter.shared.discardPendingIntentIfConnectionAborted() }
        },
                       filterKnownContact: { contact in
            // Scalars only leave this closure — `Contact` is not Sendable, and the commerce router is fed `connectionId`/`contactId`
            // for the same reason (PopopxSilentSignalingRouter.swift:166-170).
            let contactId = contact.contactId
            Task { @MainActor in await reachedExistingContact(contactId: contactId, link: link) }
        })
    }

    /// The branch the core reports as "this address is somebody you already know": switch to that conversation, and send now if the
    /// peer has already identified itself as a service account.
    private static func reachedExistingContact(contactId: Int64, link: PopopxEcoLink) async {
        let router = PopopxEcoRouter.shared
        guard let chat = ChatModel.shared.getContactChat(contactId) else {
            // A contact with no chat row is nowhere to send and nothing to open. Dropping the intent is the honest answer: keeping it
            // would leave a silent authorisation line waiting for the *next* handshake, from an unrelated service account.
            router.clearPendingIntent()
            log.error("eco: deep link matched contact :\(contactId, privacy: .public) but it has no chat; intent dropped")
            return
        }
        openKnownChat(chat.id, dismiss: true, cleanup: nil)
        guard PopopxEcoSessionStore.hasSession(for: contactId) else {
            // Connected, not yet identified: the app's own definition of a service account is a completed eco handshake
            // (`PopopxContactsView.swift:425-431`), so the intent stays and `handle(...)` delivers it when that frame arrives — and now
            // stays *bound*, because this closure is the only place in the app that ever saw the address and the contact id together.
            router.bindPendingIntent(contactId: contactId)
            log.info("eco: contact :\(contactId, privacy: .public) has no eco session yet; intent held and bound")
            return
        }
        router.clearPendingIntent()
        switch link.kind {
        case .service:
            _ = await router.sendReference(link.payload, toContactId: contactId)
        case .sso:
            _ = await router.sendSSOScan(link.payload, toContactId: contactId)
        }
    }

    /// `open_channel` on a card button or a menu item: show this device's page for that channel, or offer the link for import.
    ///
    /// "Joined" is the narrow, provable thing: this device holds key material for that `channelId`
    /// (`ChannelKeyRotationManager.channel(_:)`), which is the only local index keyed by the id the URI carries. A channel paid for
    /// through the credits flow whose keys never arrived has no such row, and opening a detail page of empty rows for it is worse than
    /// the guidance below — the guidance is also what an unjoined channel needs, because keys arrive *from* the link.
    ///
    /// Unjoined therefore opens the same page's list with the tapped link already in its import field: that field's submit path is
    /// `importPublicURI`, which is where a channel key is meant to enter this device, and without the prefill the user cannot recover
    /// a link they tapped rather than copied. `sourceText` is kept whole rather than re-serialised from `uri` because the fragment is
    /// the read key, and it never leaves this device either way.
    ///
    /// Surfaced as a sheet rather than pushed: `ChannelKeyManagementView` carries its own `NavigationStack`, and a self-stacked page
    /// inside another stack is the double navigation bar `MainTabView.swift:161` records avoiding for exactly this reason.
    @discardableResult
    static func openChannel(_ uri: PopopxChannelPublicURI, sourceText: String) -> Bool {
        let joined = ChannelKeyRotationManager.shared.channel(uri.channelId) != nil
        PopopxEcoRouter.shared.channelPageRequest = PopopxEcoChannelPageRequest(
            channelId: joined ? uri.channelId : nil,
            importURI: joined ? nil : sourceText
        )
        log.info("eco: open_channel \(joined ? "opened a joined channel" : "offered the link for import", privacy: .public)")
        return true
    }

    /// The menu form: a menu item payload is text. One that is not a channel URI is not this action's business, and saying so is what
    /// lets `BotMenuBarView` report `.unreachable` rather than presenting an empty page.
    @discardableResult
    static func openChannel(_ text: String) -> Bool {
        guard let uri = PopopxChannelPublicURI.parse(text) else { return false }
        return openChannel(uri, sourceText: text)
    }
}

