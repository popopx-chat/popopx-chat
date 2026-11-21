//  PopopxBadgeManager.swift
//
//  The single source of truth for the POPOPX dynamic privacy node badge: the three-state machine, the 72-hour pioneer trial badge,
//  the rotation count of the local encrypted relay route, and the smooth downgrade after expiry.
//
//  ### There are only three states, and they do not live in the UI
//  `PopopxBadgePhase` (dormant / 72h trial / formally lit) is derived from `PopopxBadgeRecord` + the current time.
//  Derivation happens only in this file (`recompute(now:)`) and views only read `phase`: any view that computes 'how many days left' itself
//  will drift because the moment it took the time differs, and two views giving two answers is the ugliest kind of bug for a feature like this.
//
//  ### What the expiry downgrade does and does not do
//  Does: clear the badge record, grey out the top bar capsule, stop the local rotation counting.
//  Does not: no touching SMP connections, contacts, chat history, or any single row of SQLite.
//  The badge was never an 'encryption switch' — before and after the downgrade messages still travel over the same SMP connection,
//  and only the UI line 'dynamic routing is on' changes. So the downgrade is lossless:
//  building a paywall behind chat history the user already has is the ugliest form of App Store 3.1.1,
//  and this rule is also written into Docs/app-store-review-notes.md, where the two wordings must match.
//
//  ### What DeviceCheck can do in this architecture (read this before changing the 40 lines below)
//  The prompt asks for `DCDevice.current.generateToken()` as the proof of device uniqueness for the trial badge. This file does call it,
//  but its boundary of effect must be stated clearly, not vaguely called a 'device digest':
//  - the token is **for Apple's servers to verify** (the server side holds the Team ID private key). POPOPX has zero servers and zero accounts,
//    so nobody can verify it, and therefore nobody can revoke an already issued claim because of it.
//  - so in a pure end-to-end form its real role is leaving evidence: `trialGuard` records the token digest,
//    so that a future answer to a review enquiry can state clearly 'this claim is bound to hardware Apple vouched for'.
//  - what actually stops a repeated claim is the Keychain: the `trialGuard` slot + the `installIdentity` slot both carry
//    `ThisDeviceOnly`, so they survive an uninstall and reinstall (same team ID). That is the whole of the anti-abuse defence.
//  When no token can be obtained (simulator, capability not enabled, no network, system unsupported) the claim is **not blocked**;
//  it falls back to the local install digest, and the reason for the fallback goes only into the log, never into the user interface.
//  ⚠️ Getting a real token requires ticking the DeviceCheck capability for this App ID in Xcode;
//  red lines forbid a script from changing project files, so this step belongs to a human, and this file does not pretend it already applies.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. Red lines forbid a script from modifying project.pbxproj.

import Foundation
import os

#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// The wall-clock cap for DeviceCheck (2 seconds). It goes over the network; without this line
/// the claim path on the first entry to the main screen would have the whole first screen dragged behind an Apple-side timeout.
/// A file-level constant rather than a `@MainActor` type member: the child task that fetches the token is not on the main actor,
/// and reading a main-actor-isolated static value from there would be an error under strict concurrency.
private let popopxDeviceCheckTimeoutNanoseconds: UInt64 = 2_000_000_000

@MainActor
@Observable
final class PopopxBadgeManager {
    static let shared = PopopxBadgeManager()

    /// The badge record currently in force; nil = never claimed, or downgraded after expiry.
    private(set) var record: PopopxBadgeRecord?
    /// The only thing a view should read; it updates in the same frame as `record`, so there is no intermediate frame of 'a record exists but the UI says dormant'.
    private(set) var phase: PopopxBadgePhase = .dormant
    /// The real renewal state on Apple's side. nil means 'not queried yet', and the UI must not display it as 'cancelled'.
    private(set) var subscriptionSnapshot: PopopxSubscriptionSnapshot?
    private(set) var lastReconcileAt: Date?

    private var ticker: Task<Void, Never>?
    private var deliveryToken: UUID?
    /// Digests of one-time pass receipts already lit inside this process. It stops the same pass being delivered twice and adding the time twice
    /// (the comment on `applyPass` states how it divides the work with the `record.receiptDigest` guard).
    private var appliedPassDigests: Set<String> = []
    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "badge")

    private init() {
        record = PopopxCommerceKeychain.decode(PopopxBadgeRecord.self, .badgeRecord)
        phase = PopopxBadgePhase.phase(for: record)
        if record == nil, PopopxCommerceKeychain.contains(.trialGuard) {
            log.info("badge: replay guard present without a record — pioneer trial already consumed on this device")
        }
    }

    // MARK: Lifecycle

    /// Called from the app launch path: takes over StoreKit delivery, starts the time heartbeat, reconciles with Apple entitlements.
    func start() async {
        guard deliveryToken == nil else { return }
        deliveryToken = PopopxStoreKitManager.shared.attachDelivery { [weak self] receipt in
            await self?.apply(storeReceipt: receipt)
        }
        PopopxStoreKitManager.shared.startObservingTransactions()
        startTicker()
        // Order: first recover the passes that were 'paid but not credited' (only unfinished, see `recoverUnsettledPasses`),
        // then reconcile with Apple's subscription entitlements — the latter lights overwritingly by the expiry time Apple gives; both steps, when writing the same badge
        // record, take the 'later expiry', so the order only affects how smoothly the log reads and never swallows any stretch of time.
        await recoverUnsettledPasses()
        await reconcileWithStore()
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        if let deliveryToken {
            PopopxStoreKitManager.shared.detachDelivery(deliveryToken)
            self.deliveryToken = nil
        }
    }

    /// Every 30 seconds rather than 1: the finest display granularity on the badge is 'X hours left',
    /// and a 1-second heartbeat would needlessly redraw the top bar 86400 times a day; the real second-level countdown is rendered by the view itself.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                self?.recompute(now: Date())
                self?.rotateNodeIfNeeded(now: Date())
            }
        }
    }

    // MARK: State derivation

    /// The only derivation entry. On expiry it performs the downgrade, and it clears the Keychain only on expiry.
    func recompute(now: Date = Date()) {
        guard let existing = record else {
            if phase != .dormant { phase = .dormant }
            return
        }
        let next = PopopxBadgePhase.phase(for: existing, now: now)
        guard next.isLit else {
            demoteExpired(existing)
            return
        }
        if phase != next { phase = next }
    }

    private func demoteExpired(_ expired: PopopxBadgeRecord) {
        record = nil
        phase = .dormant
        subscriptionSnapshot = nil
        _ = PopopxCommerceKeychain.remove(.badgeRecord)
        // `trialGuard` is kept: its only purpose is 'this device has claimed it', and deleting it along with the badge would amount to allowing a re-claim.
        log.info("badge: demoted to free public relays; expired source was \(String(describing: expired.source))")
    }

    // MARK: Claiming and lighting

    /// Claim the 72-hour pioneer node trial badge. Succeeds once, only when 'this device has never claimed it'.
    ///
    /// One call site: the main screen's `.task`. The eligibility decision lives here rather than in the popup view,
    /// because 'claimed or not' is a Keychain-level fact, and a view guessing it is sure to produce a second popup.
    func issuePioneerTrialIfNeeded(now: Date = Date()) async -> PopopxBadgeRecord? {
        guard record == nil, !PopopxCommerceKeychain.contains(.trialGuard) else { return nil }

        let guardToken = Data(await Self.pioneerTrialGuardToken().utf8)
        // Write the anti-replay marker first, then the badge. The other way round gives 'badge lit but the marker never written',
        // and if that crashes right after or the write fails, a restart yields a second 72 hours — this ordering is the anti-abuse defence itself.
        guard PopopxCommerceKeychain.write(guardToken, .trialGuard) else {
            log.error("badge: pioneer trial refused — replay guard could not be written")
            return nil
        }
        do {
            return try activate(
                period: .monthly,
                source: .pioneerTrial,
                expiresAtMs: Int64(now.timeIntervalSince1970 * 1_000)
                    + Int64(PopopxCommerceLimits.trialSeconds * 1_000),
                receiptDigest: nil,
                trialGuard: PopopxCommerceSignature.shortDigest(guardToken),
                now: now
            )
        } catch {
            // The badge was not issued but the marker was already written: better that the user misses the trial this time (they had not received it anyway),
            // than leaving a 'retry until it succeeds' hole.
            log.error("badge: pioneer trial guard written but activation failed")
            return nil
        }
    }

    /// The expiry instant used for stacking time: `max(this device's current expiry, now) + period.days`.
    ///
    /// The three 'buy another stretch' legs (one-time time pack / credit redemption / received gift voucher) share this one place, because the UI line
    /// 'redeeming this tier again adds N days' must be the result of one and the same formula, not three approximations written separately. The start takes
    /// `max(existing, now)` rather than `now`: buying 30 days while 200 days remain expires 230 days from now;
    /// only when the badge has already expired (or this device never lit one) does `existing` not hold, and it falls back to counting from now.
    func stackedExpiryMs(period: PopopxNodeBadgePeriod, now: Date = Date()) -> Int64 {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return max(nowMs, record?.expiresAtMs ?? 0) + Int64(period.days) * 86_400_000
    }

    /// Light the badge. Five sources (trial / Apple subscription / one-time time pack / credit redemption / received gift voucher)
    /// all converge here, and this is also the only place that writes `.badgeRecord`.
    ///
    /// 'From which day the validity counts' has two answers here, and must have two: the subscription family listens to Apple
    /// (`apply(storeReceipt:)` uses the expiry time from the receipt directly), while the other three 'buy another stretch' legs listen to
    /// `stackedExpiryMs`. The `max(passed-in, existing)` below is not a third answer, it only covers
    /// calls where the passed-in expiry is earlier than the existing one (the trial branch is exactly that), guaranteeing that no leg can shorten already bought time.
    @discardableResult
    func activate(
        period: PopopxNodeBadgePeriod,
        source: PopopxBadgeSource,
        expiresAtMs: Int64,
        receiptDigest: String?,
        trialGuard: String? = nil,
        now: Date = Date()
    ) throws -> PopopxBadgeRecord {
        let issuedAtMs = Int64(now.timeIntervalSince1970 * 1_000)
        guard expiresAtMs > issuedAtMs else { throw PopopxBadgeCreditsError.expiryInPast }
        // Stacking entitlements takes the 'later expiry', not the 'later issue': when the user spends 4500 credits to renew another year,
        // the 200 days left by the previous annual voucher must not be wiped out. This rule makes 'renewing early' always a gain, never a loss.
        let candidate = PopopxBadgeRecord(
            period: period,
            source: source,
            issuedAtMs: min(issuedAtMs, record?.issuedAtMs ?? issuedAtMs),
            expiresAtMs: max(expiresAtMs, record?.expiresAtMs ?? 0),
            rotationIndex: record?.rotationIndex ?? 0,
            receiptDigest: receiptDigest,
            trialGuard: trialGuard ?? record?.trialGuard
        )
        guard PopopxCommerceKeychain.encode(candidate, .badgeRecord) else {
            throw PopopxBadgeCreditsError.keychainUnavailable
        }
        record = candidate
        phase = PopopxBadgePhase.phase(for: candidate, now: now)
        log.info("badge: lit, source \(String(describing: source)) period \(period.rawValue)")
        return candidate
    }

    /// StoreKit delivery callback: exhaustive over `kind`, settling in one place 'whose badge does this receipt light'.
    ///
    /// Vouchers and credit top-up packs are credited by `PopopxCreditsManager.apply(storeReceipt:)`; this touches not one of those cells;
    /// subscriptions and one-time passes light the badge. The pass family **must** also have a branch here: the paywall's leg that lights on the spot
    /// runs only when `purchase()` returns `.purchased` synchronously, and on a real device two settlement paths never pass through it at all —
    /// Ask to Buy / family-approval decisions granted later (that call returns `.pending`), and the process being killed after payment succeeded but before lighting
    /// (the receipt stays in `Transaction.unfinished`). After either of those is paid, nothing but this place lights it,
    /// and missing this branch means 'the money can be taken, the goods never ship'.
    func apply(storeReceipt receipt: PopopxStoreReceipt) async {
        if receipt.isRevoked {
            await handleRevocation(receipt)
            return
        }
        guard let sku = receipt.sku else { return }
        switch sku.kind {
        case let .subscription(period):
            // Subscriptions prefer the expiry time Apple gives; only when it cannot be obtained (theoretically it should not happen) does it fall back to the period's days.
            let expiresAtMs = receipt.expiresAtMs
                ?? Int64(nowAddingDays(period.days).timeIntervalSince1970 * 1_000)
            do {
                try activate(period: period, source: .appleSubscription, expiresAtMs: expiresAtMs, receiptDigest: receipt.digest)
                await PopopxStoreKitManager.shared.finish(receipt)
            } catch {
                log.error("badge: subscription activation failed; leaving the transaction unfinished for redelivery")
            }
        case let .oneTimePass(period):
            await applyPass(receipt, period: period)
        case .giftCard, .credits, .creditGiftCard:
            return
        }
    }

    /// Lighting from a one-time pass (non-renewing subscription). The time goes through `stackedExpiryMs`, the same formula as credit redemption and gift vouchers:
    /// `max(this device's current expiry, now) + period.days`, and it never overwrites the time that is left.
    ///
    /// Two guards against re-delivery, both indispensable:
    /// 1. `PopopxStoreKitManager.deliver` already de-duplicates by transaction id (within the same process, when `Transaction.updates`
    ///    and a foreground purchase give the same transaction it is delivered only once), so the paywall's on-the-spot lighting will not run again here.
    /// 2. This function's `appliedPassDigests` + a comparison against `record.receiptDigest`: the former blocks repeat deliveries inside this process,
    ///    the latter blocks 'lighting succeeded but `finish` never landed, so a cold start re-delivers the same receipt from unfinished'.
    ///    Taking the digest on the current badge record instead of building a ledger of our own is because `PopopxCommerceKeychainSlot`
    ///    is not this file's to extend: opening one more secret-string slot for this fallback would cost the whole module's keyring one more slot that must be backed up.
    private func applyPass(_ receipt: PopopxStoreReceipt, period: PopopxNodeBadgePeriod) async {
        let digest = receipt.digest
        guard !appliedPassDigests.contains(digest), record?.receiptDigest != digest else {
            // This one already lit: add no more time, but finish the transaction so it does not stay in unfinished being re-delivered forever.
            await PopopxStoreKitManager.shared.finish(receipt)
            return
        }
        do {
            try activate(period: period, source: .storePass, expiresAtMs: stackedExpiryMs(period: period), receiptDigest: digest)
            appliedPassDigests.insert(digest)
            await PopopxStoreKitManager.shared.finish(receipt)
        } catch {
            log.error("badge: one-time pass activation failed; leaving the transaction unfinished for redelivery")
        }
    }

    /// Cold-start fallback: recover and light the pass receipts where 'the money was paid but nothing was credited locally'.
    ///
    /// It only drains the `Transaction.unfinished` sequence and **never** puts passes into `reconcileWithStore()`:
    /// non-consumables stay long in `currentEntitlements` (Apple does not reclaim non-renewing subscriptions by elapsed time),
    /// so using them as the basis for reconciliation = giving away 30/365 days on every cold start. That path stays reserved for subscriptions (Apple decides the expiry).
    private func recoverUnsettledPasses() async {
        for receipt in await PopopxStoreKitManager.shared.unfinishedReceipts() {
            guard !receipt.isRevoked, let sku = receipt.sku, case let .oneTimePass(period) = sku.kind else { continue }
            await applyPass(receipt, period: period)
        }
    }

    /// Refund / revocation: the badge is treated as expired — services already enjoyed are not retroactive,
    /// but this receipt's digest is no longer allowed to light anything (the next reconciliation will finish it as an unfamiliar receipt).
    private func handleRevocation(_ receipt: PopopxStoreReceipt) async {
        guard record?.receiptDigest == receipt.digest else { return }
        record = nil
        phase = .dormant
        _ = PopopxCommerceKeychain.remove(.badgeRecord)
        await PopopxStoreKitManager.shared.finish(receipt)
        log.info("badge: cleared because its source receipt was revoked")
    }

    /// Lighting after a gift card is received and its signature verifies. The voucher's state machine lives in `PopopxP2PVoucherVault`;
    /// this function only answers 'can this lighting be written down'.
    ///
    /// Here `grant.expiresAtMs` is deliberately **not** used: that instant was computed on the **giver**'s device
    /// (`authorizeRedemption`'s `now + period.days`); it is only a signed promise of 'how many days this voucher gives',
    /// not the recipient's expiry date. Lighting directly from it produces two errors: a voucher lying in the chat for three days loses three days,
    /// and it bypasses the time the recipient has left of their own. The days are re-landed by `stackedExpiryMs` on the recipient's side,
    /// and not one signed byte has to change.
    func activate(grant: PopopxBadgeGrant) throws -> PopopxBadgeRecord {
        try activate(
            period: grant.period,
            source: .giftedVoucher,
            expiresAtMs: stackedExpiryMs(period: grant.period),
            receiptDigest: PopopxCommerceSignature.shortDigest(grant.voucherId)
        )
    }

    /// Lighting from a credit redemption. The days come from the period itself, avoiding two places each writing their own 30/365;
    /// the start goes through `stackedExpiryMs`, the same formula as passes and gift vouchers — a button that spends credits says 'add N days',
    /// so it can only ever add N days, never 'reset the remaining time to N days'.
    @discardableResult
    func activate(withCredits period: PopopxNodeBadgePeriod, now: Date = Date()) throws -> PopopxBadgeRecord {
        try activate(
            period: period,
            source: .creditsExchange,
            expiresAtMs: stackedExpiryMs(period: period, now: now),
            receiptDigest: nil,
            now: now
        )
    }

    private func nowAddingDays(_ days: Int) -> Date {
        Date().addingTimeInterval(TimeInterval(days * 86_400))
    }

    // MARK: Reconciliation

    /// Recompute the badge with Apple's entitlements as the truth: a device change, a renewal on another machine, a restore of purchases all come here.
    func reconcileWithStore() async {
        let receipts = await PopopxStoreKitManager.shared.currentEntitlementReceipts()
        // `for … where` takes only one condition (comma-separated multiple conditions are a syntax error here), so the criteria go inside the loop body.
        for receipt in receipts {
            guard receipt.sku?.isSubscription == true, !receipt.isRevoked else { continue }
            await apply(storeReceipt: receipt)
        }
        await refreshSubscriptionStatus()
        lastReconcileAt = Date()
        recompute()
    }

    /// The badge detail page's 'check the renewal state again' button.
    func refreshSubscriptionStatus() async {
        guard let existing = record, existing.source == .appleSubscription else {
            subscriptionSnapshot = nil
            return
        }
        subscriptionSnapshot = await PopopxStoreKitManager.shared.subscriptionSnapshot(for: existing.period)
    }

    // MARK: Local route rotation (presentation-layer semantics)

    /// The counter increments **at most** once every `nodeRotationSeconds` (the decision only happens inside the 30-second heartbeat).
    ///
    /// Today it is **only a local count**: actually moving one SMP connection to another relay node takes the Haskell side's
    /// invited/AD flow for connections, and until that step is verified on hardware nobody may claim 'switched'.
    /// So views render it as a 'node refresh' animation, and no copy may contain perfect-tense assertions like 'switched to a new node'.
    func rotateNodeIfNeeded(now: Date) {
        guard var existing = record, PopopxBadgePhase.phase(for: existing, now: now).isLit else { return }
        let due = TimeInterval(existing.rotationIndex) * PopopxCommerceLimits.nodeRotationSeconds
        let elapsed = now.timeIntervalSince1970 - Double(existing.issuedAtMs) / 1_000
        guard elapsed >= due else { return }
        existing.rotationIndex += 1
        guard PopopxCommerceKeychain.encode(existing, .badgeRecord) else { return }
        record = existing
    }

    // MARK: Short lines for the UI to read

    /// One sentence of remaining time. The dormant state returns nil, so the caller shows no countdown instead of showing '0 seconds'.
    var remainingDescription: String? {
        guard let expiresAt = phase.expiresAt else { return nil }
        return PopopxBadgeCopy.remaining(expiresAt: expiresAt, source: record?.source)
    }

    /// Whether the trial badge can still be claimed — the popup's only source of eligibility.
    var canClaimPioneerTrial: Bool { record == nil && !PopopxCommerceKeychain.contains(.trialGuard) }

    // MARK: Clearing the field

    /// Wipe all of this module's local state (badge, vouchers, credits, transaction log, signing keys, trial marker).
    ///
    /// It is **deliberately not wired to any automatic trigger**, including the triple-tap-Logo emergency self-destruct: that path would also delete unspent credit balances,
    /// which binds 'emergency escape' to 'property loss'. Wiring it would require an explicit user decision plus a separately designed irrevocable confirmation.
    static func eraseAllCommerceState() {
        PopopxCommerceKeychain.removeAll()
    }
}

// MARK: - Device attestation

private extension PopopxBadgeManager {
    /// The raw text of the trial badge's anti-replay digest: on a real device with DeviceCheck available it takes the Apple token, otherwise the local install digest.
    /// The return value is always readable text — the part that lands in the Keychain never contains message bodies, only identifiers.
    static func pioneerTrialGuardToken() async -> String {
        if let token = await deviceCheckToken() {
            return "dc.\(token.popopxBase64URL)"
        }
        return localInstallFingerprint()
    }

    /// `generateToken` with a wall-clock cap. All failure reasons (unsupported / capability not enabled / timeout / no network)
    /// collapse into nil: the only correct behaviour at every level above is 'use the local digest', and telling the reasons apart only adds a log nobody reads.
    nonisolated private static func deviceCheckToken() async -> Data? {
        #if canImport(DeviceCheck) && os(iOS)
        guard DCDevice.current.isSupported else { return nil }
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                guard let token = try? await DCDevice.current.generateToken(), !token.isEmpty else { return nil }
                return token
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: popopxDeviceCheckTimeoutNanoseconds)
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
        #else
        return nil
        #endif
    }

    /// The local install digest: a self-minted UUID stored in the Keychain's `installIdentity` slot.
    ///
    /// `identifierForVendor` is not used: that identifier changes once 'every app from the same vendor has been deleted',
    /// and whether it changes is worth nothing to us — the property we actually need is 'still the same value after an uninstall and reinstall',
    /// and the Keychain (ThisDeviceOnly) provides exactly that. If it cannot be read, mint a new one and write it down;
    /// a failed write still returns as normal, because turning 'one Keychain hiccup' into 'never able to claim the trial' would be the worse outcome,
    /// and the first anti-replay guard (`trialGuard`) has already decided once earlier on that path.
    static func localInstallFingerprint() -> String {
        if let stored = PopopxCommerceKeychain.read(.installIdentity),
           let text = String(data: stored, encoding: .utf8),
           text.hasPrefix("popopx.install.") {
            return text
        }
        let minted = "popopx.install.\(UUID().uuidString)"
        _ = PopopxCommerceKeychain.write(Data(minted.utf8), .installIdentity)
        return minted
    }
}

// MARK: - Copy

/// Short UI phrases inside the badge feature. The batch of amounts, refunds and renewal promises lives in `PopopxCommerceCopy`
/// (that batch has to be written into all 17 `.lproj` directories); this batch stays inside the file like the rest of this feature's files,
/// keeping the same practice as the earlier POPOPX features.
enum PopopxBadgeCopy {
    static let capsuleTitle = NSLocalizedString("Privacy node", comment: "badge capsule title")
    static let trialBadgeName = NSLocalizedString("Pioneer Node Trial Badge", comment: "trial badge display name")
    static let formalBadgeName = PopopxCommerceCopy.badgeProductName

    /// One sentence of remaining time. The trial state says 'trial', the formal state says 'expires'; the two levels do not share the word 'remaining',
    /// so that users do not take the trial badge and a subscription for the same kind of thing.
    static func remaining(expiresAt: Date, source: PopopxBadgeSource?) -> String {
        let clock = remainingClock(expiresAt.timeIntervalSinceNow)
        if source == .pioneerTrial { return String(format: NSLocalizedString("Pioneer trial · %@ left", comment: "badge remaining, trial tier"), clock) }
        return String(format: NSLocalizedString("Encrypted routing is on · expires %1$@ (%2$@ left)", comment: "badge remaining, paid tier"), expiresAt.popopxBadgeExpiresText, clock)
    }

    static func remainingClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = total % 86_400 / 3_600
        let minutes = total % 3_600 / 60
        if days > 0 { return String(format: NSLocalizedString("%1$lld days %2$lld hours", comment: "badge remaining clock"), days, hours) }
        if hours > 0 { return String(format: NSLocalizedString("%1$lld hours %2$lld minutes", comment: "badge remaining clock"), hours, minutes) }
        return String(format: NSLocalizedString("%lld minutes", comment: "badge remaining clock"), minutes)
    }
}

private extension Date {
    /// The expiry date renders in the system locale format; hard-coding `yyyy-MM-dd` is the wrong style in both German and Chinese locales.
    var popopxBadgeExpiresText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }
}
