//  PopopxP2PVoucherVault.swift
//
//  The local vault for gift-card vouchers + the anti-double-spend arbiter.
//  It holds **two families in one table**: badge vouchers (worth `period`) and compute-credit gift cards (worth `creditsAmount`).
//  One table is a deliberate choice, not a shortcut: the double-spend defence is "one actor, one flip per voucher", and a second vault
//  would be a second copy of the persist-first/rollback/undo logic — the part that must not ever disagree between the two families.
//  What stays separate is the value field, the grant type, the Keychain grant slot and the redemption-code prefix, so no code path
//  can read a credit voucher as a badge or the other way round.
//
//  ### Why an actor rather than a MainActor class
//  Flipping one voucher's state from `unused` to `redeemed` must be **serial and completed before the grant is returned**,
//  otherwise two concurrent redemption requests for the same voucher would each read `unused` and each obtain a grant. The actor's
//  isolation is exactly what turns this into a language guarantee: inside `authorizeRedemption(voucherId:)` the "check state + write state + sign"
//  three steps can never have a second call interleaved between them. This is the only real double-spend defence in this feature (the other one is
//  at `PopopxSilentSignalingRouter`: a redemption request can only ever come back to the device that minted the voucher).
//
//  ### The anti-double-spend boundary stated plainly (no overclaiming)
//  What it holds against: concurrent redemptions on the same device, replaying the same code, redeeming again after a lost ACK.
//  What it does not: the giver screenshotting/forwarding the voucher code to several people and redeeming **on another device** at the same time — that would need a server
//  keeping a global ledger, and zero bots / zero servers is the premise of this feature. The engineering practice that presses the risk down to what is acceptable is:
//  a voucher is sent only once, the code expires immediately after the ACK, and the "redeemed" state is visible to the user in the voucher list (`state == .redeemed`).
//  This sentence is at the same time the answer in the review documentation to "why double-spend is prevented without a server".
//
//  ### What does not go into the Keychain
//  The `PPX1-…` / `PPXC1-…` redemption code itself is never written to disk (only `codeDigest` is): that string is a "withdrawal credential",
//  and one backup restore would turn every voucher that was never sent back into a withdrawable state.
//  When a code has to be reproduced, `PopopxSilentSignalingRouter` remints it from the envelope parameters instead of relying on storing the original text.
//  Two facts follow for the message the giver types: it is not a field of the redemption code at all (the code carries link, voucher id, value, time, nonce,
//  key, signature), and the text that does carry it — the `popopx://gift` / `popopx://creditgift` card link — is only ever assembled at send time.
//  So a card reopened from the wallet list has nothing left to read the message out of, and the message needs its own Keychain slot
//  (`popopx.commerce.voucher-notes`), keyed by voucher id. The voucher rows keep the encoding they had before: the message sits next to the record, not in it.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. A red line forbids scripts from modifying project.pbxproj.

import Foundation

// MARK: - Origin

/// The origin of a voucher. It decides which identifier reconciliation uses, not how much the voucher is worth — the face value is decided only by `period` or `creditsAmount`.
enum PopopxVoucherSource: Hashable, Sendable {
    /// Minted from a signature-verified StoreKit receipt (a badge gift card or a compute-credit gift card).
    case receipt(PopopxStoreReceipt)
    /// Minted from a credits ledger entry whose deduction succeeded (`giftVoucherExchange` / `creditGiftSent`).
    case creditEntry(id: String)

    var transactionId: String {
        switch self {
        case let .receipt(receipt): receipt.digest
        case let .creditEntry(id): id
        }
    }

    var jwsDigest: String {
        switch self {
        case let .receipt(receipt): PopopxCommerceSignature.shortDigest(receipt.jwsRepresentation)
        case let .creditEntry(id): PopopxCommerceSignature.shortDigest("credit.\(id)")
        }
    }
}

// MARK: - Vault

actor PopopxP2PVoucherVault {
    static let shared = PopopxP2PVoucherVault()

    private var issued: [PopopxNodeVoucher] = []
    /// Receiving side: the grant text brought back inside the ACK. The key is voucherId and the value is written only after a successful redemption,
    /// then one copy is kept for reconciliation after it has been handed to `PopopxBadgeManager.activate(grant:)`.
    private var received: [String: PopopxBadgeGrant] = [:]
    /// The credit twin of `received`, kept in its own Keychain slot because the two tables hold different types under the same
    /// voucher-id keys — one dictionary written over the other would make a verified authorisation unreadable.
    private var receivedCredits: [String: PopopxCreditsGrant] = [:]
    /// The message the giver typed for one card, keyed by voucher id. Its own slot, so this table's rows keep the byte-for-byte
    /// encoding they had before it existed and nothing written earlier has to be converted.
    /// Why the message needs a table at all: it is not a field of the redemption code, and neither that code text nor the card link
    /// which does carry it is ever stored (only `codeDigest` — file header), so a reopened card has nothing else to read it from.
    /// A card minted before this table existed simply has no row here, and an absent row reads as an empty message,
    /// which is exactly what such a card shows today.
    private var notes: [String: String] = [:]
    private var loaded = false

    private init() {}

    // MARK: Loading

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        issued = PopopxCommerceKeychain.decode([PopopxNodeVoucher].self, .vouchers) ?? []
        received = PopopxCommerceKeychain.decode([String: PopopxBadgeGrant].self, .grants) ?? [:]
        receivedCredits = PopopxCommerceKeychain.decode([String: PopopxCreditsGrant].self, .creditGrants) ?? [:]
        notes = PopopxCommerceKeychain.decode([String: String].self, .voucherNotes) ?? [:]
    }

    // MARK: Minting vouchers

    /// Mint `quantity` vouchers in one go. The quantity cap exists for exactly one reason:
    /// the whole voucher table lives in a single Keychain slot, and 200 is the dividing line between a real batch such as "buy 200 gift cards at once"
    /// and "writing 50,000 random numbers into a password string". Exceeding the quantity must go through several receipts, not by raising the cap.
    func mint(period: PopopxNodeBadgePeriod, quantity: Int, source: PopopxVoucherSource) throws -> [PopopxNodeVoucher] {
        loadIfNeeded()
        let nowMs = try preparedBatch(quantity: quantity, unavailable: .voucherUnavailable)
        let minted = (0 ..< quantity).map { _ in
            PopopxNodeVoucher(
                voucherId: Self.newVoucherId(),
                period: period,
                creditsAmount: nil,
                state: .unused,
                mintedAtMs: nowMs,
                transactionId: source.transactionId,
                jwsDigest: source.jwsDigest,
                codeDigest: nil,
                redeemedAtMs: nil,
                grantBase64URL: nil
            )
        }
        return try commit(minted, unavailable: .voucherUnavailable)
    }

    /// Mint `quantity` compute-credit gift cards. Same batching, same persist-first rule, and the same arbiter as a badge voucher —
    /// which is the point: one voucher id can only ever be flipped once no matter which family it belongs to, so a code cannot be
    /// redeemed twice by trying it first as a badge and then as credits.
    ///
    /// `creditsAmount` is a pack face value (`PopopxCreditPlan.giftPacks`), never a number typed by a user: a freely typed amount
    /// would turn a gift card into a money-transfer instrument, which is exactly the 3.1.1 line the red packet feature stays under.
    func mintCredit(creditsAmount: Int, quantity: Int, source: PopopxVoucherSource) throws -> [PopopxNodeVoucher] {
        loadIfNeeded()
        guard creditsAmount > 0 else { throw PopopxBadgeCreditsError.creditVoucherUnavailable }
        let nowMs = try preparedBatch(quantity: quantity, unavailable: .creditVoucherUnavailable)
        let minted = (0 ..< quantity).map { _ in
            PopopxNodeVoucher(
                voucherId: Self.newVoucherId(),
                period: nil,
                creditsAmount: creditsAmount,
                state: .unused,
                mintedAtMs: nowMs,
                transactionId: source.transactionId,
                jwsDigest: source.jwsDigest,
                codeDigest: nil,
                redeemedAtMs: nil,
                grantBase64URL: nil
            )
        }
        return try commit(minted, unavailable: .creditVoucherUnavailable)
    }

    /// The batch gates both mints share, returning the mint timestamp.
    private func preparedBatch(quantity: Int, unavailable: PopopxBadgeCreditsError) throws -> Int64 {
        guard quantity >= 1, quantity <= PopopxCommerceLimits.maximumVouchers else { throw unavailable }
        guard issued.count + quantity <= PopopxCommerceLimits.maximumVouchers else { throw unavailable }
        return Int64(Date().timeIntervalSince1970 * 1_000)
    }

    /// Append rows to the table and persist them. Persist first, then return the code: if a voucher returned to the UI was never
    /// written into the Keychain, the user would see it gone the next time they enter this panel,
    /// while that voucher's StoreKit receipt has already been finished — this is the exact shape of "paid and received nothing".
    private func commit(_ minted: [PopopxNodeVoucher], unavailable: PopopxBadgeCreditsError) throws -> [PopopxNodeVoucher] {
        issued.append(contentsOf: minted)
        guard PopopxCommerceKeychain.encode(issued, .vouchers) else {
            issued.removeAll(where: { minted.contains($0) })
            throw PopopxBadgeCreditsError.keychainUnavailable
        }
        return minted
    }

    private static func newVoucherId() -> String { UUID().uuidString.lowercased() }

    /// The unused vouchers of one family. Both mints write one table, so a list that shows only credits (or only badges) has to ask
    /// by family — filtering by `state` alone would offer a credit card to the badge gift sheet and vice versa.
    func creditVouchers(state: PopopxVoucherState? = nil) -> [PopopxNodeVoucher] {
        loadIfNeeded()
        return issued.filter { $0.isCreditVoucher && (state == nil || $0.state == state) }
    }

    func vouchers(state: PopopxVoucherState? = nil) -> [PopopxNodeVoucher] {
        loadIfNeeded()
        if let state { return issued.filter { $0.state == state } }
        return issued
    }

    /// Badge vouchers only — the entry point every badge call site uses, so "which rows may become a `PPX1-` code"
    /// is answered in one place instead of at each `.filter { $0.period != nil }`.
    func badgeVouchers(state: PopopxVoucherState? = nil) -> [PopopxNodeVoucher] {
        loadIfNeeded()
        return issued.filter { !$0.isCreditVoucher && (state == nil || $0.state == state) }
    }

    func voucher(voucherId: String) -> PopopxNodeVoucher? {
        loadIfNeeded()
        return issued.first { $0.voucherId == voucherId }
    }

    /// Record the digest carried inside the code, used for "this voucher was sent out". The code itself is not stored; the reason is in the file header.
    func recordCodeDigest(_ digest: String, forVoucherId voucherId: String) {
        loadIfNeeded()
        guard let index = issued.firstIndex(where: { $0.voucherId == voucherId }) else { return }
        issued[index].codeDigest = digest
        _ = PopopxCommerceKeychain.encode(issued, .vouchers)
    }

    /// The giver's message for one card, or "" when nothing was stored. Every reader asks by the id of a row it already has,
    /// so the two families share this one answer: a badge card and a compute-credit card are told apart by `isCreditVoucher`, not here.
    func note(forVoucherId voucherId: String) -> String {
        loadIfNeeded()
        return notes[voucherId] ?? ""
    }

    /// Attach one message to a batch of freshly minted cards and persist it before returning: a message that only reached the UI
    /// would be gone at the next launch while the cards it belongs to stayed, and the card the user re-shares would then read
    /// "no message" although the giver paid for one — the same persist-first rule as `commit`.
    ///
    /// A batch takes one message on purpose (`quantity` cards cut from the balance, or several tiers bought at once): the text
    /// belongs to the purchase, and nothing here guesses a different sentence per card.
    /// Ids that have no row are skipped rather than written, so a table can never outlive the vouchers it describes and
    /// grow keys no list will ever read — the notes table stays bounded by `maximumVouchers` through the rows, not on its own.
    /// An empty message deletes the row instead of storing "", which keeps "the giver typed nothing" and "this card predates
    /// the table" the same readable state.
    @discardableResult
    func recordNote(_ note: String, forVoucherIds voucherIds: [String]) -> Bool {
        loadIfNeeded()
        let clipped = String(note.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        let ids = Set(voucherIds.filter { id in issued.contains(where: { $0.voucherId == id }) })
        guard !ids.isEmpty else { return false }
        let rollback = notes
        for id in ids {
            if clipped.isEmpty { notes[id] = nil } else { notes[id] = clipped }
        }
        guard PopopxCommerceKeychain.encode(notes, .voucherNotes) else {
            notes = rollback
            return false
        }
        return true
    }

    /// The giver actively voids a voucher that has not been sent out yet ("Delete" in the UI).
    /// A redeemed voucher **cannot** be deleted: that is an entitlement someone else paid for, and deleting the record would not make the other party's badge disappear,
    /// it would only leave reconciliation one row short.
    /// The message goes with the row: leaving it behind would keep somebody's gift text in the Keychain under an id no list can ever reach again.
    /// Both tables are written only after both in-memory changes succeeded, and either failure puts both back — half a delete persisted
    /// is a card that came back with its message gone, or a message that outlived its card.
    func discard(voucherId: String) -> Bool {
        loadIfNeeded()
        guard let index = issued.firstIndex(where: { $0.voucherId == voucherId }), issued[index].state == .unused else {
            return false
        }
        let rollbackVouchers = issued
        let rollbackNotes = notes
        issued.remove(at: index)
        notes[voucherId] = nil
        if PopopxCommerceKeychain.encode(issued, .vouchers), PopopxCommerceKeychain.encode(notes, .voucherNotes) {
            return true
        }
        issued = rollbackVouchers
        notes = rollbackNotes
        _ = PopopxCommerceKeychain.encode(issued, .vouchers)
        _ = PopopxCommerceKeychain.encode(notes, .voucherNotes)
        return false
    }

    // MARK: Anti-double-spend arbitration

    /// The badge redemption entry point — one of the two, and the only place a badge voucher's state may ever be flipped.
    /// Returns the grant or nil **synchronously**, because an actor's reentrancy points are only at `await`,
    /// and this function never awaits — checking the state, flipping the state, persisting and signing all complete inside one isolated execution.
    ///
    /// `codeDigestSource` is supplied by the caller: a one-time-link redemption passes "the nonce in the code + the invite link",
    /// an in-session gift-card redemption passes that signaling text verbatim. Both are only evidence of "which code redeemed this voucher"; neither takes part in the liveness decision.
    ///
    /// Note that it is not `async throws`: the meaning of nil for the caller (`PopopxSilentSignalingRouter`)
    /// is "this voucher has already been redeemed", which is not an exception but an answer that has to be reported back to the other side honestly.
    func authorizeRedemption(voucherId: String, codeDigestSource: String) -> PopopxBadgeGrant? {
        loadIfNeeded()
        guard let index = issued.firstIndex(where: { $0.voucherId == voucherId }),
              issued[index].state == .unused,
              // A credit voucher has no period, so it cannot be authorised as a badge — the guard is the second lock,
              // the first being that a `PPXC1-` code never decodes into a `PopopxRedeemEnvelope` at all.
              let period = issued[index].period
        else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        // This line computes "now + N days" on the **giver's** machine; what it enters is the signed payload, and its meaning is "how many days this voucher promises"
        // (`PopopxCommerceSignature.canonical` signs `expiresAtMs` along with it, so the payload cannot be changed).
        // The recipient does **not** use it as their own expiry time: `PopopxBadgeManager.activate(grant:)` takes
        // `grant.period` and recomputes `max(this device's current expiry, now) + days` on the recipient's side —
        // otherwise a voucher sitting in the chat for three days would leave the recipient three days short, and their remaining period would be overwritten by this voucher's date.
        let expiresAtMs = nowMs + Int64(period.days * 86_400) * 1_000
        guard markRedeemed(index: index, nowMs: nowMs, codeDigestSource: codeDigestSource) else { return nil }
        return grant(voucherId: voucherId, period: period, grantedAtMs: nowMs, expiresAtMs: expiresAtMs)
    }

    /// The credit twin of `authorizeRedemption`, and the same single non-suspending actor turn: check, flip, persist, sign.
    /// There is no expiry field at all — Compute Credits do not expire, and inventing `expiresAtMs = 0` here would give
    /// "when does this run out" a second answer for the one family that has none.
    func authorizeCreditRedemption(voucherId: String, codeDigestSource: String) -> PopopxCreditsGrant? {
        loadIfNeeded()
        guard let index = issued.firstIndex(where: { $0.voucherId == voucherId }),
              issued[index].state == .unused,
              let amount = issued[index].creditsAmount
        else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        guard markRedeemed(index: index, nowMs: nowMs, codeDigestSource: codeDigestSource) else { return nil }
        return signedCreditGrant(voucherId: voucherId, creditsAmount: amount, grantedAtMs: nowMs)
    }

    /// Flip one row to `redeemed` and persist it before anything is signed. In the reverse order
    /// a failed write would leave behind a voucher that is "already granted but still unused" — that is what a double spend really is.
    /// Returns false when the row was reverted, meaning the caller must hand back nil.
    private func markRedeemed(index: Int, nowMs: Int64, codeDigestSource: String) -> Bool {
        issued[index].state = .redeemed
        issued[index].redeemedAtMs = nowMs
        issued[index].codeDigest = PopopxCommerceSignature.shortDigest(codeDigestSource)
        guard PopopxCommerceKeychain.encode(issued, .vouchers) else {
            // If the write fails, revoke this grant and return nil: better that the recipient sees "the redemption did not go through, please retry"
            // than that they hold a grant the local record no longer acknowledges.
            issued[index].state = .unused
            issued[index].redeemedAtMs = nil
            return false
        }
        return true
    }

    /// The grant text: the canonical string of `grant` contains only four fields (voucher id / period / issued at / expires at),
    /// free-form copy and invite links never enter `parts` — once a signature covers mutable text,
    /// one character changed by the other party stops matching, and that is a perfectly legitimate content change.
    private func grant(voucherId: String, period: PopopxNodeBadgePeriod, grantedAtMs: Int64, expiresAtMs: Int64) -> PopopxBadgeGrant? {
        // An empty public-key string = this device's signing key could not be fetched from the Keychain (the failure shape of `localPublicKeyBase64URL`).
        // At that point you must never sign a grant whose "public key field is empty": verification on the recipient's side fails every time,
        // and the user sees only "the other party did not confirm this redemption", while what is actually broken is this device's storage.
        let publicKey = PopopxCommerceSignature.localPublicKeyBase64URL()
        guard !publicKey.isEmpty,
              let signature = PopopxCommerceSignature.signatureBase64URL(
                  for: PopopxCommerceSignature.canonical(
                      kind: "grant",
                      parts: [voucherId, period.wireValue, String(grantedAtMs), String(expiresAtMs)]
                  )
              )
        else { return nil }
        return PopopxBadgeGrant(
            voucherId: voucherId,
            period: period,
            grantedAtMs: grantedAtMs,
            expiresAtMs: expiresAtMs,
            giverPublicKey: publicKey,
            signature: signature
        )
    }

    /// The credit twin of `grant(...)`: three fields (voucher id / amount / issued at), and `kind: "credit_grant"` so a signature
    /// taken over a badge grant can never verify as one over credits. The same empty-public-key rule applies.
    private func signedCreditGrant(voucherId: String, creditsAmount: Int, grantedAtMs: Int64) -> PopopxCreditsGrant? {
        let publicKey = PopopxCommerceSignature.localPublicKeyBase64URL()
        guard !publicKey.isEmpty,
              let signature = PopopxCommerceSignature.signatureBase64URL(
                  for: PopopxCommerceSignature.canonical(
                      kind: "credit_grant",
                      parts: [voucherId, String(creditsAmount), String(grantedAtMs)]
                  )
              )
        else { return nil }
        return PopopxCreditsGrant(
            voucherId: voucherId,
            creditsAmount: creditsAmount,
            grantedAtMs: grantedAtMs,
            giverPublicKey: publicKey,
            signature: signature
        )
    }

    // MARK: Receiving side

    /// After the ACK arrives, verify the signature first and then store. If verification fails, drop it outright: a forged grant that entered the local record
    /// would let the later `activate(grant:)` light up a badge nobody ever paid for.
    @discardableResult
    func record(_ grant: PopopxBadgeGrant) -> Bool {
        loadIfNeeded()
        guard grant.isSignatureValid else { return false }
        received[grant.voucherId] = grant
        return PopopxCommerceKeychain.encode(received, .grants)
    }

    func grant(voucherId: String) -> PopopxBadgeGrant? {
        loadIfNeeded()
        return received[voucherId]
    }

    /// All valid grants on the receiving side (verified once when they came in, never verified again, kept only for reconciliation display).
    func receivedGrants() -> [PopopxBadgeGrant] {
        loadIfNeeded()
        return received.values.sorted { $0.grantedAtMs > $1.grantedAtMs }
    }

    /// Find a redeemed-in grant by voucherId, for the reconciliation line that says "which voucher did this badge come from".
    func sourceOfBadge(voucherId: String) -> (period: PopopxNodeBadgePeriod, grantedAt: Date)? {
        guard let grant = received[voucherId] else { return nil }
        return (grant.period, Date(timeIntervalSince1970: Double(grant.grantedAtMs) / 1_000))
    }

    /// Storing a credit grant: verify first, then write, same rule as `record(_:)` — a forged grant that gets into the local record
    /// would let the later crediting add balance nobody paid for, and this time the thing at stake is the number itself.
    @discardableResult
    func recordCredit(_ grant: PopopxCreditsGrant) -> Bool {
        loadIfNeeded()
        guard grant.isSignatureValid else { return false }
        receivedCredits[grant.voucherId] = grant
        return PopopxCommerceKeychain.encode(receivedCredits, .creditGrants)
    }

    func creditGrant(voucherId: String) -> PopopxCreditsGrant? {
        loadIfNeeded()
        return receivedCredits[voucherId]
    }

    /// All valid credit grants on the receiving side, for the reconciliation list.
    func receivedCreditGrants() -> [PopopxCreditsGrant] {
        loadIfNeeded()
        return receivedCredits.values.sorted { $0.grantedAtMs > $1.grantedAtMs }
    }
}
