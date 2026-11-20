//  PopopxP2PVoucherVault.swift
//
//  The local vault for gift-card vouchers + the anti-double-spend arbiter.
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
//  The `PPX1-…` redemption code itself is never written to disk (only `codeDigest` is): that string is a "withdrawal credential",
//  and one backup restore would turn every voucher that was never sent back into a withdrawable state.
//  When a code has to be reproduced, `PopopxSilentSignalingRouter` remints it from the envelope parameters instead of relying on storing the original text.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. A red line forbids scripts from modifying project.pbxproj.

import Foundation

// MARK: - Origin

/// The origin of a voucher. It decides which identifier reconciliation uses, not how much the voucher is worth — the face value is decided only by `period`.
enum PopopxVoucherSource: Hashable, Sendable {
    /// Minted from a signature-verified StoreKit gift-card receipt.
    case receipt(PopopxStoreReceipt)
    /// Minted from a credits ledger entry whose deduction succeeded (`giftVoucherExchange`).
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
    private var loaded = false

    private init() {}

    // MARK: Loading

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        issued = PopopxCommerceKeychain.decode([PopopxNodeVoucher].self, .vouchers) ?? []
        received = PopopxCommerceKeychain.decode([String: PopopxBadgeGrant].self, .grants) ?? [:]
    }

    // MARK: Minting vouchers

    /// Mint `quantity` vouchers in one go. The quantity cap exists for exactly one reason:
    /// the whole voucher table lives in a single Keychain slot, and 200 is the dividing line between a real batch such as "buy 200 gift cards at once"
    /// and "writing 50,000 random numbers into a password string". Exceeding the quantity must go through several receipts, not by raising the cap.
    func mint(period: PopopxNodeBadgePeriod, quantity: Int, source: PopopxVoucherSource) throws -> [PopopxNodeVoucher] {
        loadIfNeeded()
        guard quantity >= 1, quantity <= PopopxCommerceLimits.maximumVouchers else {
            throw PopopxBadgeCreditsError.voucherUnavailable
        }
        guard issued.count + quantity <= PopopxCommerceLimits.maximumVouchers else {
            throw PopopxBadgeCreditsError.voucherUnavailable
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        var minted: [PopopxNodeVoucher] = []
        minted.reserveCapacity(quantity)
        for _ in 0..<quantity {
            minted.append(
                PopopxNodeVoucher(
                    voucherId: UUID().uuidString.lowercased(),
                    period: period,
                    state: .unused,
                    mintedAtMs: nowMs,
                    transactionId: source.transactionId,
                    jwsDigest: source.jwsDigest,
                    codeDigest: nil,
                    redeemedAtMs: nil,
                    grantBase64URL: nil
                )
            )
        }
        issued.append(contentsOf: minted)
        // Persist first, then return the code: if a voucher returned to the UI was never written into the Keychain, the user would see it gone the next time they enter this panel,
        // while that voucher's StoreKit receipt has already been finished — this is the exact shape of "paid and received nothing".
        guard PopopxCommerceKeychain.encode(issued, .vouchers) else {
            issued.removeAll(where: { minted.contains($0) })
            throw PopopxBadgeCreditsError.keychainUnavailable
        }
        return minted
    }

    func vouchers(state: PopopxVoucherState? = nil) -> [PopopxNodeVoucher] {
        loadIfNeeded()
        guard let state else { return issued }
        return issued.filter { $0.state == state }
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

    /// The giver actively voids a voucher that has not been sent out yet ("Delete" in the UI).
    /// A redeemed voucher **cannot** be deleted: that is an entitlement someone else paid for, and deleting the record would not make the other party's badge disappear,
    /// it would only leave reconciliation one row short.
    func discard(voucherId: String) -> Bool {
        loadIfNeeded()
        guard let index = issued.firstIndex(where: { $0.voucherId == voucherId }), issued[index].state == .unused else {
            return false
        }
        issued.remove(at: index)
        return PopopxCommerceKeychain.encode(issued, .vouchers)
    }

    // MARK: Anti-double-spend arbitration

    /// The only redemption entry point. Returns the grant or nil **synchronously**, because an actor's reentrancy points are only at `await`,
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
              issued[index].state == .unused
        else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let period = issued[index].period
        // This line computes "now + N days" on the **giver's** machine; what it enters is the signed payload, and its meaning is "how many days this voucher promises"
        // (`PopopxCommerceSignature.canonical` signs `expiresAtMs` along with it, so the payload cannot be changed).
        // The recipient does **not** use it as their own expiry time: `PopopxBadgeManager.activate(grant:)` takes
        // `grant.period` and recomputes `max(this device's current expiry, now) + days` on the recipient's side —
        // otherwise a voucher sitting in the chat for three days would leave the recipient three days short, and their remaining period would be overwritten by this voucher's date.
        let expiresAtMs = nowMs + Int64(period.days * 86_400) * 1_000
        // Flip the state to redeemed and persist it first, then sign and return. In the reverse order
        // a failed write would leave behind a voucher that is "already granted but still unused" — that is what a double spend really is.
        issued[index].state = .redeemed
        issued[index].redeemedAtMs = nowMs
        issued[index].codeDigest = PopopxCommerceSignature.shortDigest(codeDigestSource)
        guard PopopxCommerceKeychain.encode(issued, .vouchers) else {
            // If the write fails, revoke this grant and return nil: better that the recipient sees "the redemption did not go through, please retry"
            // than that they hold a grant the local record no longer acknowledges.
            issued[index].state = .unused
            issued[index].redeemedAtMs = nil
            return nil
        }
        return grant(voucherId: voucherId, period: period, grantedAtMs: nowMs, expiresAtMs: expiresAtMs)
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
}
