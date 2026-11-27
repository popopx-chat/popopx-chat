//
//  DiscoverSubscriptionManager.swift
//  POPOPX (iOS / Shared)
//
//  The 30-day cycle engine of the Discover plaza: which services this device has paid
//  Compute Credits for, when each one expires, whether it renews itself, and what happens
//  when the balance cannot cover the next cycle. Plus the local record of the bonded Mac
//  node and the per-service inbox its answers land in.
//
//  Three rules this file exists to enforce, in order of how badly they would hurt if they
//  did not hold:
//
//  1. **A renewal never touches Apple.** The only path that moves money out of the user's
//     pocket is a button the user pressed in `PopopxCreditsStoreView`. Renewal reads
//     `PopopxCreditsManager` and nothing else, and there is no `SK1`/`SK2` call anywhere in
//     this file — an automatic charge that was not consented to is the fastest way to lose
//     both the review (Guideline 3.1.1) and the user.
//  2. **State that survives a relaunch lives in the Keychain**, in this module's own slots
//     (`PopopxCommerceKeychainSlot.discoverSubscriptions` / `discoverNodeBinding`), under
//     `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Not in `UserDefaults`: an expiry
//     timestamp in a plist is a file any sandbox-reader can rewrite to "never expires",
//     and a bonded node's public key is a credential, not a preference.
//  3. **A metered service has no cycle.** `PopopxNodeCycleCost.usageBased` reports
//     `renewalCredits == nil`, and every renewal path starts by asking that question, so
//     the mesh node can never be "renewed" for an invented amount.
//
//  The host's own clocks are not trusted here: the node decides what a job costs when it
//  settles it, and this device decides how long an activation it paid for stays open.
//

import Foundation
import POPOPXChat
import PopopxMeshKit
import UserNotifications
import os

// MARK: - Subscription

/// One activated service, as this device remembers it.
struct PopopxDiscoverSubscription: Codable, Hashable, Identifiable, Sendable {
    let serviceId: PopopxNodeServiceId
    let activatedAtMs: Int64
    var expiresAtMs: Int64
    var autoRenew: Bool
    /// Cycles this device has paid for, the first activation included. It is what makes
    /// "renewed twice, silently" answerable from local data alone.
    var cyclesPaid: Int
    var lastRenewalAtMs: Int64?
    /// The expiry the shortfall notice was already posted for. Keying the notice to the
    /// expiry rather than to "have we ever warned" is what lets one notice fire per cycle
    /// and no more: a service that stays unpaid for a week must not add to the user's
    /// notification list every time they open the app.
    var shortfallNoticeExpiresAtMs: Int64?

    var id: String { serviceId.rawValue }

    init(serviceId: PopopxNodeServiceId, now: Date = Date()) {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        self.serviceId = serviceId
        self.activatedAtMs = nowMs
        self.expiresAtMs = nowMs + Int64(PopopxDiscoverClock.cycleSeconds * 1_000)
        self.autoRenew = true
        self.cyclesPaid = 1
        self.lastRenewalAtMs = nil
        self.shortfallNoticeExpiresAtMs = nil
    }

    var expiresAt: Date { Date(timeIntervalSince1970: Double(expiresAtMs) / 1_000) }

    func isActive(at date: Date = Date()) -> Bool {
        Int64(date.timeIntervalSince1970 * 1_000) < expiresAtMs
    }

    func millisecondsRemaining(at date: Date = Date()) -> Int64 {
        expiresAtMs - Int64(date.timeIntervalSince1970 * 1_000)
    }

    func daysRemaining(at date: Date = Date()) -> Int {
        max(0, Int(Double(millisecondsRemaining(at: date)) / 1_000 / PopopxDiscoverClock.secondsPerDay))
    }

    /// The renewal window: less than a day of validity left, renewals on, and the cycle
    /// still priced in credits. Outside it, `renew` refuses to take money for time the
    /// user already bought.
    func renewalWindowOpen(at date: Date = Date()) -> Bool {
        autoRenew
            && serviceId.cycleCost.renewalCredits != nil
            && isActive(at: date)
            && millisecondsRemaining(at: date) <= Int64(PopopxDiscoverClock.renewalWindowSeconds * 1_000)
    }
}

/// The only place the length of a cycle is written down.
enum PopopxDiscoverClock {
    /// 30 days, spelled the way the rest of the commerce module spells it
    /// (`PopopxCommerceLimits.channelTicketSeconds`, `packetClaimGraceSeconds`) so that
    /// "one month" is one number in this app and not three that happen to agree today.
    static let cycleSeconds: TimeInterval = 30 * 86_400
    static let renewalWindowSeconds: TimeInterval = 24 * 60 * 60
    static let secondsPerDay: TimeInterval = 86_400

    static var cycleMilliseconds: Int64 { Int64(cycleSeconds * 1_000) }
}

// MARK: - Outcomes

/// What a renewal attempt reported. Never thrown: a cycle sweep walks ten services and one
/// unpaid balance must not abort the other nine.
enum PopopxDiscoverRenewalOutcome: Hashable, Sendable {
    case renewed(serviceId: PopopxNodeServiceId, credits: Int, expiresAt: Date)
    case notDue(serviceId: PopopxNodeServiceId)
    case balanceShort(serviceId: PopopxNodeServiceId, required: Int, balance: Int)
    case notRenewable(serviceId: PopopxNodeServiceId)

    var serviceId: PopopxNodeServiceId {
        switch self {
        case let .renewed(id, _, _), let .notDue(id), let .balanceShort(id, _, _), let .notRenewable(id): id
        }
    }
}

/// The badge the plaza and the detail sheet both read, derived here so that "is this
/// service running" has one answer.
enum PopopxDiscoverServiceStatus: Hashable, Sendable {
    case notActivated
    case active(autoRenew: Bool)
    case expiringToday(autoRenew: Bool)
    case awaitingBalance(daysOverdue: Int)
    case expired
    case metered

    var label: String {
        switch self {
        case .notActivated: DiscoverCopy.statusNotSubscribed
        case .active(true): DiscoverCopy.statusRunningAutoRenew
        case .active(false): DiscoverCopy.statusRunning
        case .expiringToday: DiscoverCopy.statusExpiringSoon
        case .awaitingBalance: DiscoverCopy.statusNeedsBalance
        case .expired: DiscoverCopy.statusPaused
        case .metered: DiscoverCopy.usageBasedPrice
        }
    }

    /// Whether a menu button may spend a cycle's worth of trust on this service right now.
    /// `awaitingBalance` is deliberately usable-looking only to the badge, never here: the
    /// grace of a lapsed cycle is not a free day of compute.
    var isUsable: Bool {
        switch self {
        case .active, .expiringToday, .metered: true
        case .notActivated, .awaitingBalance, .expired: false
        }
    }
}

// MARK: - Manager

/// What storing one delivered feed envelope decided. `unbonded` is the app-side half of the same
/// chain the wire layer runs: an envelope can be perfectly signed and the sender still not be a Mac
/// this phone agreed to listen to.
enum PopopxNodeFeedIngest: Equatable, Sendable {
    case stored(itemCount: Int)
    case refused(PopopxNodeFeedWire.Refusal)
    case unbonded
}

/// The one answer a user may give one published version, kept so the card cannot be tapped twice.
enum PopopxNodeUpdateDecision: String, Codable, Equatable, Sendable {
    case approved
    case snoozed
}

@MainActor
@Observable
final class DiscoverSubscriptionManager {
    static let shared = DiscoverSubscriptionManager()

    private(set) var subscriptions: [PopopxDiscoverSubscription] = []
    private(set) var binding: PopopxMacNodeBinding?
    /// The answers the node sent back, newest first, capped per service. In memory and in
    /// the same Keychain slot as the subscriptions: a result card that vanishes on
    /// backgrounding would leave the user with no proof the Mac ever ran the job.
    private(set) var inbox: [String: [PopopxNodeResultCard]] = [:]
    /// The content the bonded Mac published, kept exactly as its signed envelope delivered it.
    ///
    /// This is a cache of somebody else's signed statement, not a record this device can vouch for on
    /// its own, so it carries the key it verified under: a relaunch then cannot present content that
    /// was never checked, and an emergency wipe takes it with the binding it belongs to
    /// (`PopopxCommerceKeychain.removeAll()` iterates `allCases`).
    private(set) var feed: PopopxNodeFeedSnapshot?
    /// One entry per version the user already answered, so a card that is re-read from the chat
    /// history cannot offer "Update now" a second time and send a second one-time receipt.
    private(set) var updateDecisions: [String: PopopxNodeUpdateDecision] = [:]
    private(set) var lastSweepAt: Date?
    /// Set by the sweep so the UI can say "the credits ran out" without re-deriving it from
    /// a balance and an expiry on every row.
    private(set) var servicesAwaitingBalance: Set<PopopxNodeServiceId> = []

    private var loaded = false
    /// Read once, never requested. Posting a notification must not be the reason a system
    /// permission dialog appears the first time a cycle lapses.
    @ObservationIgnored private var notificationsAuthorised = false
    @ObservationIgnored private let log = Logger(subsystem: "com.popopxchat.popopx", category: "discover")

    private init() {}

    // MARK: Loading

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        subscriptions = PopopxCommerceKeychain.decode([PopopxDiscoverSubscription].self, .discoverSubscriptions) ?? []
        binding = PopopxCommerceKeychain.decode(PopopxMacNodeBinding.self, .discoverNodeBinding)
        inbox = PopopxCommerceKeychain.decode([String: [PopopxNodeResultCard]].self, .discoverInbox) ?? [:]
        feed = PopopxCommerceKeychain.decode(PopopxNodeFeedSnapshot.self, .discoverFeed)
        updateDecisions = PopopxCommerceKeychain.decode([String: PopopxNodeUpdateDecision].self, .discoverUpdateDecisions) ?? [:]
        refreshNotificationAuthorization()
    }

    func start() {
        loadIfNeeded()
        sweep(now: Date())
    }

    /// The launch and foreground hook. Called from `MainTabView` on `.task` and on every
    /// `scenePhase == .active`, which is the requirement's own wording: a phone that was
    /// closed for two days must not need the user to open the Discover tab for the cycle
    /// engine to notice.
    func onSceneActive(now: Date = Date()) {
        loadIfNeeded()
        sweep(now: now)
    }

    private func save() {
        if subscriptions.isEmpty {
            _ = PopopxCommerceKeychain.remove(.discoverSubscriptions)
        } else {
            _ = PopopxCommerceKeychain.encode(subscriptions, .discoverSubscriptions)
        }
        _ = PopopxCommerceKeychain.encode(inbox, .discoverInbox)
    }

    private func saveBinding() {
        if let binding {
            _ = PopopxCommerceKeychain.encode(binding, .discoverNodeBinding)
        } else {
            _ = PopopxCommerceKeychain.remove(.discoverNodeBinding)
        }
    }

    // MARK: Reading state

    func subscription(for serviceId: PopopxNodeServiceId) -> PopopxDiscoverSubscription? {
        loadIfNeeded()
        return subscriptions.first { $0.serviceId == serviceId }
    }

    func status(for serviceId: PopopxNodeServiceId, now: Date = Date()) -> PopopxDiscoverServiceStatus {
        loadIfNeeded()
        guard let row = subscriptions.first(where: { $0.serviceId == serviceId }) else {
            return serviceId.cycleCost.isRenewable ? .notActivated : .metered
        }
        if row.isActive(at: now) {
            let soon = row.millisecondsRemaining(at: now) <= Int64(PopopxDiscoverClock.renewalWindowSeconds * 1_000)
            return soon ? .expiringToday(autoRenew: row.autoRenew) : .active(autoRenew: row.autoRenew)
        }
        // Past expiry, two different failures look the same until you ask whether the user
        // wanted a renewal at all: "I stopped it" and "it could not be paid" are not one
        // message, and only the second one is allowed to nag about balance.
        guard row.autoRenew, row.serviceId.cycleCost.renewalCredits != nil else { return .expired }
        let overdueDays = Int(Double(-row.millisecondsRemaining(at: now)) / 1_000 / PopopxDiscoverClock.secondsPerDay)
        return servicesAwaitingBalance.contains(serviceId) ? .awaitingBalance(daysOverdue: max(0, overdueDays)) : .expired
    }

    var activeCount: Int {
        loadIfNeeded()
        return subscriptions.filter { $0.isActive() }.count
    }

    /// How many running services sit behind each plaza filter chip, so the number next to a
    /// shelf name means "what you have", not "what we sell" — the catalogue size is the same
    /// for every user and would be noise on a chip. A filter with nothing live returns nil
    /// rather than 0, and the chip shows nothing: a zero on four chips says nothing a
    /// glance cannot already see.
    var activeCountByFilter: [PopopxDiscoverFilter: Int] {
        loadIfNeeded()
        let live = subscriptions.filter { $0.isActive() }.map(\.serviceId)
        guard !live.isEmpty else { return [:] }
        var counts: [PopopxDiscoverFilter: Int] = [.all: live.count]
        for filter in [PopopxDiscoverFilter.productivity, .compute, .sanctuary] {
            let matching = live.filter { filter.matches($0.section) }.count
            if matching > 0 { counts[filter] = matching }
        }
        return counts
    }

    // MARK: Activating

    /// Buys the first 30-day cycle. The debit and the row are written in that order and the
    /// row is written second: if the ledger accepted the debit, an activation row that
    /// cannot be persisted would mean the user paid for nothing, which is the one failure
    /// mode worth panicking over — so a failed save throws back instead of reporting success.
    func activate(_ serviceId: PopopxNodeServiceId, now: Date = Date()) throws {
        loadIfNeeded()
        guard subscription(for: serviceId) == nil else { return }
        guard serviceId.cycleCost.isRenewable, let credits = serviceId.cycleCost.renewalCredits else {
            // A metered service has no cycle to buy: the settlement engine prices each job,
            // so giving the mesh node a nominal activation figure would print a price that
            // nothing ever charges and a balance that nothing ever debits.
            throw PopopxDiscoverError.activationNotSupported(serviceTitle: serviceId.title)
        }
        _ = try PopopxCreditsManager.shared.payForService(
            amount: credits,
            note: DiscoverLedgerCopy.activation(serviceTitle: serviceId.title, days: DiscoverCopy.cycleDays)
        )
        var rows = subscriptions.filter { $0.serviceId != serviceId }
        rows.append(PopopxDiscoverSubscription(serviceId: serviceId, now: now))
        subscriptions = rows
        servicesAwaitingBalance.remove(serviceId)
        guard PopopxCommerceKeychain.encode(subscriptions, .discoverSubscriptions) else {
            // The credit leg is already committed and this layer cannot roll it back
            // (`PopopxCreditsManager` owns the wallet), so the row stays in memory for this
            // session and the failure is reported instead of hidden: the next launch
            // re-reads the truth from the Keychain, and the ledger still shows the debit.
            log.error("discover: activation row for \(serviceId.rawValue, privacy: .public) could not reach the keychain")
            throw PopopxDiscoverError.persistenceFailed
        }
        log.info("discover: activated \(serviceId.rawValue, privacy: .public) for \(credits, privacy: .public) credits")
    }

    func setAutoRenew(_ enabled: Bool, for serviceId: PopopxNodeServiceId) {
        loadIfNeeded()
        guard let index = subscriptions.firstIndex(where: { $0.serviceId == serviceId }) else { return }
        subscriptions[index].autoRenew = enabled
        if enabled { subscriptions[index].shortfallNoticeExpiresAtMs = nil }
        save()
    }

    /// Stops renewing and drops the row, keeping the inbox: a person who cancels a service
    /// still wants the results their Mac already produced.
    func stop(_ serviceId: PopopxNodeServiceId) {
        loadIfNeeded()
        subscriptions.removeAll { $0.serviceId == serviceId }
        servicesAwaitingBalance.remove(serviceId)
        save()
    }

    // MARK: The cycle sweep

    /// Renews everything inside its window and remembers everything that could not pay.
    ///
    /// Safe to call on every foreground: a service only renews while it is still active and
    /// inside the last 24 hours, so a second call in the same session moves nothing. The
    /// window closes behind the renewal by construction — the new expiry is 30 days out.
    @discardableResult
    func sweep(now: Date = Date()) -> [PopopxDiscoverRenewalOutcome] {
        loadIfNeeded()
        lastSweepAt = now
        var outcomes: [PopopxDiscoverRenewalOutcome] = []
        var rows = subscriptions
        var changed = false
        for index in rows.indices {
            let row = rows[index]
            guard let credits = row.serviceId.cycleCost.renewalCredits else {
                outcomes.append(.notRenewable(serviceId: row.serviceId))
                continue
            }
            guard row.renewalWindowOpen(at: now) else {
                outcomes.append(.notDue(serviceId: row.serviceId))
                continue
            }
            let balance = PopopxCreditsManager.shared.balance
            guard balance >= credits else {
                outcomes.append(.balanceShort(serviceId: row.serviceId, required: credits, balance: balance))
                servicesAwaitingBalance.insert(row.serviceId)
                changed = true
                postShortfallNotice(for: row, required: credits, balance: balance, &rows[index])
                continue
            }
            do {
                _ = try PopopxCreditsManager.shared.payForService(
                    amount: credits,
                    note: DiscoverLedgerCopy.renewal(serviceTitle: row.serviceId.title, days: DiscoverCopy.cycleDays)
                )
            } catch {
                // `payForService` checked the balance again and refused. Same user-visible
                // outcome as a short balance, reached by a different route, so it is
                // recorded as one rather than as a crash nobody can explain.
                outcomes.append(.balanceShort(serviceId: row.serviceId, required: credits, balance: PopopxCreditsManager.shared.balance))
                servicesAwaitingBalance.insert(row.serviceId)
                changed = true
                continue
            }
            var renewed = row
            renewed.expiresAtMs = max(row.expiresAtMs, Int64(now.timeIntervalSince1970 * 1_000)) + PopopxDiscoverClock.cycleMilliseconds
            renewed.lastRenewalAtMs = Int64(now.timeIntervalSince1970 * 1_000)
            renewed.cyclesPaid += 1
            renewed.shortfallNoticeExpiresAtMs = nil
            rows[index] = renewed
            servicesAwaitingBalance.remove(row.serviceId)
            changed = true
            outcomes.append(.renewed(serviceId: row.serviceId, credits: credits, expiresAt: renewed.expiresAt))
            log.info("discover: renewed \(row.serviceId.rawValue, privacy: .public), cycle \(renewed.cyclesPaid, privacy: .public)")
        }
        if changed {
            subscriptions = rows
            save()
        }
        return outcomes
    }

    // MARK: Notices

    private func refreshNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorised = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in self.notificationsAuthorised = authorised }
        }
    }

    /// One local notice per lapse, then silence. The notice points at the top-up page and
    /// nothing harsher: no repeating banner, no badge, and certainly no
    /// re-charge attempt that would look like a subscription Apple did not approve.
    private func postShortfallNotice(
        for row: PopopxDiscoverSubscription,
        required: Int,
        balance: Int,
        _ target: inout PopopxDiscoverSubscription
    ) {
        guard target.shortfallNoticeExpiresAtMs != target.expiresAtMs else { return }
        target.shortfallNoticeExpiresAtMs = target.expiresAtMs
        servicesAwaitingBalance.insert(row.serviceId)
        guard notificationsAuthorised else {
            log.info("discover: shortfall notice suppressed for \(row.serviceId.rawValue, privacy: .public), notifications not authorised")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = DiscoverCopy.shortfallNoticeTitle
        content.body = String(
            format: DiscoverCopy.shortfallNoticeBodyFormat,
            row.serviceId.title,
            required,
            balance
        )
        content.sound = .default
        content.categoryIdentifier = PopopxDiscoverNotice.categoryIdentifier
        content.userInfo = ["serviceId": row.serviceId.rawValue]
        let request = UNNotificationRequest(
            identifier: "popopx.discover.shortfall.\(row.serviceId.rawValue).\(row.expiresAtMs)",
            content: content,
            // Fires immediately: by the time the sweep notices, the cycle is already inside
            // its last day, and a scheduled trigger would be allowed to land after expiry —
            // a warning that arrives after the service stopped is not a warning.
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let self, error != nil else { return }
            // A notice this device could not post must not be retried forever, and must not
            // be reported as posted: the in-app badge still tells the truth.
            self.log.error("discover: shortfall notice could not be posted")
        }
    }

    // MARK: Inbox

    /// Records one node answer and hands back the card the room renders.
    ///
    /// `fromPairedNode` is the whole safety story of the unmarked path: the shape test in
    /// `PopopxNodeResultCard.detect` is allowed to be a heuristic because it is only ever
    /// consulted for the single contact the user bonded, and a nil return means the message
    /// renders exactly as it arrived.
    @discardableResult
    func recordInbound(text: String, fromPairedNode: Bool, now: Date = Date()) -> PopopxNodeResultCard? {
        loadIfNeeded()
        guard let card = PopopxNodeResultCard.detect(text: text, fromPairedNode: fromPairedNode, now: now) else { return nil }
        return store(card)
    }

    /// A marked `NODE_CMD` that arrived from the wire (a re-sync, or a host that starts
    /// answering in its own marker). Suppressed from the bubble by the router, so the inbox
    /// is the only place it can still be read.
    @discardableResult
    func recordInbound(command: PopopxNodeCmd, now: Date = Date()) -> PopopxNodeResultCard {
        loadIfNeeded()
        return store(PopopxNodeResultCard.decode(command: command, now: now))
    }

    private func store(_ card: PopopxNodeResultCard) -> PopopxNodeResultCard {
        var rows = inbox[card.serviceId.rawValue] ?? []
        rows.insert(card, at: 0)
        if rows.count > PopopxDiscoverClock.maximumInboxRows {
            rows.removeLast(rows.count - PopopxDiscoverClock.maximumInboxRows)
        }
        inbox[card.serviceId.rawValue] = rows
        save()
        return card
    }

    func results(for serviceId: PopopxNodeServiceId) -> [PopopxNodeResultCard] {
        loadIfNeeded()
        return inbox[serviceId.rawValue] ?? []
    }

    // MARK: Node feed

    /// Whether this contact **is** the bonded Mac — the conversation the user attached to it.
    ///
    /// `handshakeConfirmed` is deliberately *not* part of this test, although the pairing UI sets it
    /// and the plaza reads it as "connected": it records that a command this phone sent was taken by
    /// SMP, which says nothing about who may send content, and a node that publishes a feed before the
    /// user ever opens the plaza would otherwise have its first feed dropped with no reason anywhere.
    /// The strictness that matters is elsewhere — the envelope is signed, that key is pinned on first
    /// success, and the bytes only ever come from this one contact.
    func nodeFeedSenderBound(contactId: Int64) -> Bool {
        loadIfNeeded()
        return binding?.contactId == contactId
    }

    /// Whether the delivered bytes of one row are the bonded Mac's feed artifact.
    ///
    /// Three surfaces ask this and must not disagree: the row gate on the chat page, the conversation
    /// list preview, and the notification path. The **bond** is part of the answer, not just the file
    /// name — a predicate on `feed.json` alone would let any contact make one of their own messages
    /// disappear from this device by naming it that.
    func nodeArtifactRow(_ cInfo: ChatInfo, _ cItem: ChatItem) -> Bool {
        guard cInfo.chatType == .direct, let file = cItem.file,
              file.fileProtocol == .xftp,
              PopopxNodeFeedWire.isArtifact(fileName: file.fileName, byteCount: file.fileSize)
        else { return false }
        return nodeFeedSenderBound(contactId: cInfo.apiId)
    }

    /// Whether one row may not become a banner.
    ///
    /// The artifact's content is already in the Discover data source by the time its transfer
    /// completes, and an update card is answered from inside the session, so a banner for either adds
    /// nothing but the raw marker line. Deliberately kept separate from `PopopxSysMarker.isSignalText`:
    /// that predicate also drives the row gate, and a card has to stay renderable, so folding these in
    /// would delete the very message the user is meant to answer.
    func suppressesNotification(_ cInfo: ChatInfo, _ cItem: ChatItem) -> Bool {
        if nodeArtifactRow(cInfo, cItem) { return true }
        guard cInfo.chatType == .direct else { return false }
        return PopopxNodeUpdateWire.isUpdateCard(cItem.content.msgContent?.text ?? "")
    }

    /// The rows the bonded Mac published, in the order its envelope signed them.
    ///
    /// Nothing in the app may edit these: the digest that verified is the digest of the row as
    /// written (`PopopxNodeFeedWire.canonicalItemBody`), so a local rewrite would turn stored
    /// content into content no key ever signed, and the next feed would be compared against that.
    var feedItems: [PopopxNodeFeedItem] { feed?.items ?? [] }

    /// The key the stored feed verified under — nil until the first envelope is accepted.
    var pinnedFeedPublicKey: String? { feed?.publicKey }

    /// Set when an envelope arrived under a key other than the pinned one. Persisted and surfaced,
    /// because the refusal repeats on every later feed: without a reason the panel is just wrong,
    /// quietly, forever.
    var feedKeyChangedAtMs: Int64? { feed?.keyChangedAtMs }

    /// The `generatedAt` of the stored snapshot — the node's own clock, not this device's.
    var feedGeneratedAt: String? { feed?.generatedAt }

    /// Folds one delivered `feed.json` into the data source.
    ///
    /// Silent by contract: every rejection leaves the stored snapshot as it was, and neither a
    /// success nor a refusal posts a notification. This is the node republishing content the user
    /// opted into by pairing, not a message addressed to the user. The caller deletes the bytes
    /// either way; only the signature survives.
    ///
    /// The bond is re-checked here rather than trusted from the call site: the envelope declares its
    /// own key, so with no conversation the user opened, any key at all verifies against itself.
    @discardableResult
    func ingest(feedData: Data, now: Date = Date()) -> PopopxNodeFeedIngest {
        loadIfNeeded()
        guard binding?.contactId != nil else {
            log.warning("discover: node feed ignored — no bonded Mac is attached to a conversation")
            return .unbonded
        }
        switch PopopxNodeFeedWire.ingest(feedData, into: feed, now: now) {
        case let .stored(snapshot):
            feed = snapshot
            saveFeed()
            log.info("discover: stored node feed, \(snapshot.items.count, privacy: .public) items")
            return .stored(itemCount: snapshot.items.count)
        case let .refused(reason, state):
            // A refusal writes only when the wire layer stamped a key change into the old snapshot.
            if let state, state != feed {
                feed = state
                saveFeed()
            }
            log.warning("discover: node feed refused: \(reason.rawValue, privacy: .public)")
            return .refused(reason)
        }
    }

    private func saveFeed() {
        if let feed {
            _ = PopopxCommerceKeychain.encode(feed, .discoverFeed)
        } else {
            _ = PopopxCommerceKeychain.remove(.discoverFeed)
        }
    }

    // MARK: Update decisions

    /// The answer this device already sent for one version, if any. A card reads this to render
    /// itself spent: the receipt the node minted is single-use, so a second `approve=` would be a
    /// second install decision the user did not make.
    func updateDecision(forVersion version: String) -> PopopxNodeUpdateDecision? {
        loadIfNeeded()
        return updateDecisions[version]
    }

    /// Records the tap that is about to go out, not the delivery that may never come back — SMP
    /// will not tell this device whether the Mac accepted the receipt, and a card that flipped back
    /// to "Update now" after a failed send invites exactly the duplicate the receipt forbids.
    @discardableResult
    func recordUpdateDecision(_ decision: PopopxNodeUpdateDecision, version: String) -> Bool {
        loadIfNeeded()
        guard updateDecisions[version] == nil else { return false }
        updateDecisions[version] = decision
        saveUpdateDecisions()
        return true
    }

    /// Answers one update notice, once.
    ///
    /// The command goes out exactly as the node wrote it — no re-encoding, see
    /// `PopopxSilentSignalingRouter.sendNodeText`. The decision is recorded *before* the send so a
    /// second tap while SMP is being asked finds the guard and does nothing; if SMP refuses, the
    /// record is removed again, because a card that can never be tapped again would leave the
    /// version unanswerable. What makes that removal safe is the node's own rule: the receipt is
    /// single-use there, so a command that left this device and only *reported* failure is refused as
    /// a replay rather than installing anything twice.
    func answerUpdate(_ decision: PopopxNodeUpdateDecision, notice: PopopxNodeUpdateWire.Notice) async -> Bool {
        loadIfNeeded()
        guard updateDecisions[notice.version] == nil, let contactId = nodeContactId else { return false }
        recordUpdateDecision(decision, version: notice.version)
        let delivered = await PopopxSilentSignalingRouter.shared.sendNodeText(
            decision == .approved ? notice.approveCommand : notice.snoozeCommand,
            toContactId: contactId
        )
        if !delivered {
            updateDecisions[notice.version] = nil
            saveUpdateDecisions()
        }
        return delivered
    }

    private func saveUpdateDecisions() {
        if updateDecisions.isEmpty {
            _ = PopopxCommerceKeychain.remove(.discoverUpdateDecisions)
        } else {
            _ = PopopxCommerceKeychain.encode(updateDecisions, .discoverUpdateDecisions)
        }
    }

    // MARK: Node command path

    /// The contact the node answers on, when this device knows it.
    var nodeContactId: Int64? {
        loadIfNeeded()
        return binding?.contactId
    }

    /// Sends one menu action to the bonded Mac.
    ///
    /// Refuses before it touches SMP when the service is not paid for, when no Mac is
    /// bonded, or when the command would not survive the host's own parser. The third
    /// check is not defensive padding: `PopopxNodeCmd` can be built by anything, and a
    /// command the host answers with `unsupported(...)` is a bug the user would have to
    /// discover by reading a card in another language.
    func dispatch(_ action: PopopxNodeMenuAction, now: Date = Date()) async -> Bool {
        loadIfNeeded()
        let command = action.command
        guard command.isAcceptedByNode, let contactId = nodeContactId else { return false }
        if action.serviceId.cycleCost.renewalCredits != nil, !status(for: action.serviceId, now: now).isUsable {
            return false
        }
        let delivered = await PopopxSilentSignalingRouter.shared.sendNodeCommand(command, toContactId: contactId)
        if delivered { confirmHandshake() }
        return delivered
    }

    /// The bond-time probe: an accepted, model-free command whose answer proves the Mac is
    /// listening on this contact. It deliberately does **not** use the `system::pair_ack`
    /// form the requirement names — the host's parser (`NodeWire.parseCommand`,
    /// `MacNodeModels.swift:127-128`) rejects any serviceId that is not one of its ten engines,
    /// so `system` could never be acknowledged. `edge_compute_mesh::status` is the
    /// equivalent: real, engine-known, and it reads no model and no argument.
    func sendHandshake(now: Date = Date()) async -> Bool {
        loadIfNeeded()
        guard let contactId = nodeContactId else { return false }
        let delivered = await PopopxSilentSignalingRouter.shared.sendNodeCommand(
            PopopxNodeCmd(serviceId: .edgeComputeMesh, action: "status", payload: "{\"probe\":\"pairing\"}"),
            toContactId: contactId
        )
        if delivered { confirmHandshake() }
        return delivered
    }

    // MARK: Bonding

    func bond(_ offer: PopopxNodePairingOffer, now: Date = Date()) {
        loadIfNeeded()
        binding = PopopxMacNodeBinding(offer: offer, now: now)
        saveBinding()
        log.info("discover: bonded node \(offer.nodeId.prefix(8), privacy: .public)")
    }

    /// Attaches the conversation the user just opened with the node. Explicit by design:
    /// nothing on this device can tell "the chat I created for the Mac" apart from "the chat
    /// I created for a person" without asking, and a wrong guess would send control signals
    /// into somebody's private thread.
    func attach(contactId: Int64, displayName: String) {
        loadIfNeeded()
        guard var binding else { return }
        binding.contactId = contactId
        binding.contactDisplayName = displayName
        self.binding = binding
        saveBinding()
    }

    func renameBinding(_ label: String) {
        loadIfNeeded()
        guard var binding else { return }
        binding.deviceLabel = label
        self.binding = binding
        saveBinding()
    }

    func confirmHandshake() {
        loadIfNeeded()
        guard var binding, !binding.handshakeConfirmed else { return }
        binding.handshakeConfirmed = true
        self.binding = binding
        saveBinding()
    }

    func unbind() {
        loadIfNeeded()
        binding = nil
        // The feed is content that machine published under its own key; leaving it behind a deleted
        // bond would keep showing somebody's headlines with nothing left to verify them against.
        feed = nil
        saveBinding()
        saveFeed()
    }

    /// Clears everything this module owns — called by the commerce emergency wipe through
    /// `PopopxCommerceKeychain.removeAll()`, which covers these slots because they are cases
    /// of that enum. Kept here for the "clear my data" path that is not a duress wipe.
    func eraseLocalState() {
        subscriptions = []
        inbox = [:]
        binding = nil
        servicesAwaitingBalance = []
        feed = nil
        updateDecisions = [:]
        save()
        saveBinding()
        saveFeed()
        saveUpdateDecisions()
    }
}

// MARK: - Supporting constants

extension PopopxDiscoverClock {
    /// Per-service history ceiling, the same reasoning as the credits ledger's cap: the room
    /// is a receipt tray, not an archive, and a Keychain blob of growing cards is a write
    /// that gets slower forever.
    static let maximumInboxRows = 40
}

enum PopopxDiscoverNotice {
    static let categoryIdentifier = "popopx.discover.shortfall"
}

enum PopopxDiscoverError: LocalizedError {
    case persistenceFailed
    case stateLost
    case noNodeBonded
    case activationNotSupported(serviceTitle: String)
    case insufficientCredits(serviceTitle: String, required: Int, balance: Int)

    var errorDescription: String? {
        switch self {
        case .persistenceFailed:
            NSLocalizedString("This device could not store the activation. The credits were not spent twice; reopen Discover.", comment: "discover error")
        case .stateLost:
            NSLocalizedString("This device could not rewrite its Discover records. Nothing was charged again.", comment: "discover error")
        case .noNodeBonded:
            NSLocalizedString("No Mac node is bonded, so there is nothing to run this on.", comment: "discover error")
        case let .activationNotSupported(serviceTitle):
            String(
                format: NSLocalizedString("%@ is settled per job, so there is no 30-day activation to buy.", comment: "discover error"),
                serviceTitle
            )
        case let .insufficientCredits(serviceTitle, required, balance):
            String(
                format: NSLocalizedString("%1$@ costs %2$lld Compute Credits and this wallet holds %3$lld.", comment: "discover balance alert"),
                serviceTitle,
                required,
                balance
            )
        }
    }
}

/// Ledger remarks for the two legs this module writes. Kept out of `DiscoverCopy` because
/// they are stored data: the sentence is frozen at the moment of the charge, and a later
/// translation must not rewrite what the user was told they paid for.
enum DiscoverLedgerCopy {
    static func activation(serviceTitle: String, days: Int) -> String {
        String(
            format: NSLocalizedString("Activated %1$@ for %2$lld days", comment: "discover ledger remark"),
            serviceTitle,
            days
        )
    }

    static func renewal(serviceTitle: String, days: Int) -> String {
        String(
            format: NSLocalizedString("Renewed %1$@ for %2$lld days from the credit balance", comment: "discover ledger remark"),
            serviceTitle,
            days
        )
    }
}

extension DiscoverCopy {
    static let shortfallNoticeTitle = NSLocalizedString("Compute credits are not enough", comment: "discover local notice")
    static let shortfallNoticeBodyFormat = NSLocalizedString(
        "%1$@ renews in less than a day and costs %2$lld credits. This wallet holds %3$lld.",
        comment: "discover local notice body"
    )
}
