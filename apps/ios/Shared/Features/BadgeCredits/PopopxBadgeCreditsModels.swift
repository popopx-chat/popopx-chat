//  PopopxBadgeCreditsModels.swift
//
//  POPOPX dynamic privacy-node badges + gift-card transfer + the compute-credit ecosystem: the only data layer for them.
//
//  Trust model (written here, because every "signing / verification / double-spend prevention / replay prevention" judgement in this directory cites it):
//  POPOPX has no accounts, no business server and no Bot (see the rulings of the AntiTheftDuress and mesh rounds).
//  So the signatures of this layer are **not an identity chain** — with zero server side there is no CA that could issue certificates. They carry two things, and promise no more:
//  1) Tamper trail: once a gift voucher's amount/period, a red packet's amount, or a redemption code's content is altered, verification must fail;
//  2) Origin check: Apple's `Transaction.jwsRepresentation` is the only external anchor, and a voucher must be minted by a
//     genuine StoreKit transaction that really completed and was not reversed by a chargeback (`PopopxStoreKitManager` owns that).
//  The "spend" in double-spend prevention only holds on this device too: the voucher state machine is an atomic read-modify-write in the local Keychain,
//  and cross-device consistency is guaranteed by "a request only ever returns on the one-time connection that minted this voucher" (see Router).
//  Any copy that describes this as a "global ledger" is untrue; comments and UI wording must both respect that boundary above.
//
//  Iron rule: this file imports no UIKit/SwiftUI, reads no host state outside `UserDefaults.standard`,
//  and makes no network requests. New types always take the `Popopx` prefix — the `Badge*` naming family
//  （`BadgeType`/`BadgeState`/`BadgeStore`/`BadgeLevel`/`BadgePeriod`/`badgeProductIds` …）
//  is already claimed globally by `Shared/Views/Badges/` (the upstream supporter badges), so reusing it means changing somebody else's semantics.

import Foundation
import CryptoKit
import Security
import PopopxMeshKit

// MARK: - Limits and calibrated values

/// The calibration numbers shared by the whole module. Kept in one place so that "the parameter table in the review notes" and the numbers
/// in the code cannot tell two different stories: every number in the docs can be grepped back to here.
enum PopopxCommerceLimits {
    /// The duration of the 72-hour "3-day pioneer node trial badge".
    static let trialSeconds: TimeInterval = 72 * 60 * 60
    /// The longest clock drift allowed to be written when the trial badge expires and falls back to the free public node (guards against forged future times).
    static let maximumClockSkewMs: Int64 = 15 * 60 * 1000
    /// The most vouchers the local voucher wallet may hold (a double ceiling: per-item Keychain size + QR panel readability).
    static let maximumVouchers = 200
    /// How many compute-credit ledger rows are kept at most. Beyond that the oldest are dropped (the balance itself is never lost).
    static let maximumLedgerEntries = 240
    /// The ceiling on the anti-replay sets: red packet ids already claimed / voucher ids already redeemed / transaction hashes already credited.
    static let maximumReplayIdentifiers = 2_000
    /// The balance ceiling. Above it means the data was altered, so the wallet goes straight to `needsReconcile` instead of silently truncating.
    static let maximumCreditBalance = 100_000
    /// The largest amount for a single red packet.
    static let maximumPacketAmount = 10_000
    /// The maximum character count of a red packet / gift-card message (counted as decoded Unicode scalars, not bytes).
    static let maximumNoteCharacters = 60
    /// The payload ceiling for one signalling message. SMP shards on its own, but this layer refuses to parse oversized payloads,
    /// so that a forged enormous base64 blob is never handed down to be decoded.
    static let maximumSignalPayloadCharacters = 1_024
    /// The byte length of the redemption-code checksum.
    static let codeChecksumBytes = 2
    /// The ceiling for a custom profile-page / channel threshold (compute credits).
    static let maximumCreditsThreshold = 100_000
    /// The digits a threshold input may use, the same family of constraint as `PopopxProfilePayload.maximumTTLDigits`.
    static let maximumThresholdDigits = 6
    /// Fixed red-packet amount tiers. Apple's 3.1.1 red line "no random amounts": only definite tiers live here,
    /// and the UI layer is not allowed any free-entry amount field.
    static let redPacketAmounts: [Int] = [10, 50, 100, 500]
    /// The most claimers in a single equal-split group-chat red packet (above that, split it into several).
    static let maximumPacketRecipients = 100
    /// How long an unclaimed-out red packet hangs on the sender's side before the remainder is refunded. There is no server-side reclaim, so only the sender can call it over by time;
    /// 30 days is chosen as the same "one month" as the badge monthly tier, and it also keeps a refund from happening while a share could still be claimed —
    /// refunding early invents credits out of thin air, the worst kind of accounting error in this feature.
    static let packetClaimGraceSeconds = 30 * 86_400
    /// The validity period of a channel subscription credential. 30 days is the same "one month" as the badge monthly tier,
    /// and it makes "x credits per month" mean the same length in both places.
    static let channelTicketSeconds = 30 * 86_400
    /// The duration and price of the top-secret "1-hour ultra-long anti-peeping window".
    static let extendedSecureWindowSeconds = 3_600
    static let extendedSecureWindowCost = 20
    /// The prices of the flowing-light shield avatar frame / dark-gold QR business-card skin.
    static let avatarFrameCost = 150
    static let qrCardSkinCost = 150
    /// The minimum interval for the local counter and the capsule spinner; the real check cadence comes from `PopopxBadgeManager`'s 30-second heartbeat.
    static let nodeRotationSeconds: TimeInterval = 15
}

// MARK: - SKU

/// The badge period. Subscription, gift voucher and compute-credit redemption all reuse it, so no second spelling of "how long" can appear.
enum PopopxNodeBadgePeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case monthly
    case annual

    var id: String { rawValue }

    /// Calendar-day count, used to derive the expiry when issuing locally (not the billing period — the billing period belongs to Apple).
    var days: Int {
        switch self {
        case .monthly: 30
        case .annual: 365
        }
    }

    /// The list price of the same period in compute credits. `100 compute credits = 1 day`: monthly 30×20=600 and yearly 365×20=7300 would be read
    /// as "the yearly is more expensive than $49.99", so the calibrated values are given separately as the credit-denominated result of the actual CNY/USD paid prices,
    /// and only once, here — the redemption page, the store page and the review docs must all come back here for the numbers.
    var creditsCost: Int {
        switch self {
        case .monthly: 600
        case .annual: 4_500
        }
    }

    /// The single-letter form that goes into the URI.
    var wireValue: String {
        switch self {
        case .monthly: "m"
        case .annual: "y"
        }
    }

    static func from(wire raw: String) -> PopopxNodeBadgePeriod? {
        switch raw {
        case "m": .monthly
        case "y": .annual
        default: nil
        }
    }

    var fallbackPriceText: String {
        switch self {
        case .monthly: "$6.99"
        case .annual: "$49.99"
        }
    }
}

/// The semantic tiers of a SKU. On the StoreKit side `Product.productType` has four tiers (consumable / nonConsumable /
/// autoRenewable / nonRenewable), and the business side has four kinds of thing too (self-use renewal, one-off time pack, multi-buy gift vouchers,
/// credit top-ups), so the type is given together with the period/amount and this layer states "how long" itself — `Product` gives no answer of its own:
/// for non-renewing subscriptions Apple does not even compute an expiry (`Transaction.expirationDate` is nil),
/// so "how many days this order grants" can only be a fact owned by this module.
enum PopopxNodeBadgeSkuKind: Hashable, Sendable {
    case subscription(PopopxNodeBadgePeriod)
    /// One-off time pack: pay once, get `period.days` days, **never auto-renews**, and there is no renewal switch on Apple's side either.
    case oneTimePass(PopopxNodeBadgePeriod)
    case giftCard(PopopxNodeBadgePeriod)
    case credits(Int)
    /// A gift card holding Compute Credits: Apple collects the money, this end mints exactly one credit voucher of `amount`.
    /// It is deliberately **not** the same tier as `.credits(Int)` — that one means "the money arrives in this device's wallet",
    /// and `creditedAmount` is what the refund clawback and the ledger both key on. A gift card never touches this device's balance,
    /// so letting the two share one case would make a refund deduct credits this device never received.
    case creditGiftCard(Int)
}

/// The 13 in-app purchase products. `productId` is the only source of truth, and `PopopxStoreKit.storekit` and App Store Connect
/// both have to match these 13 strings character for character.
enum PopopxNodeBadgeSku: String, CaseIterable, Identifiable, Sendable {
    case subscriptionAnnual
    case subscriptionMonthly
    case pass30Days
    case pass365Days
    case giftAnnual
    case giftMonthly
    case credits100
    case credits500
    case credits2000
    /// The fourth, flagship top-up tier (`disvcove_notes.md`, part one.2). Same rules as the other three: a consumable,
    /// a pure face value with no bonus, and the same list price on its gift-card twin — which does not exist for this tier,
    /// because the brief asks for a top-up pack and a card minting the same number would be a second product to keep in sync.
    case credits5000
    case creditsGift100
    case creditsGift500
    case creditsGift2000

    var id: String { rawValue }

    var productId: String {
        switch self {
        case .subscriptionAnnual: "com.popopx.badge.node.annual"
        case .subscriptionMonthly: "com.popopx.badge.node.monthly"
        case .pass30Days: "com.popopx.badge.node.pass.30d"
        case .pass365Days: "com.popopx.badge.node.pass.365d"
        case .giftAnnual: "com.popopx.gift.node.annual"
        case .giftMonthly: "com.popopx.gift.node.monthly"
        case .credits100: "com.popopx.credits.100"
        case .credits500: "com.popopx.credits.500"
        case .credits2000: "com.popopx.credits.2000"
        case .credits5000: "com.popopx.credits.5000"
        case .creditsGift100: "com.popopx.credits.gift.100"
        case .creditsGift500: "com.popopx.credits.gift.500"
        case .creditsGift2000: "com.popopx.credits.gift.2000"
        }
    }

    static let productIds: [String] = PopopxNodeBadgeSku.allCases.map(\.productId)

    static func sku(for productId: String) -> PopopxNodeBadgeSku? {
        allCases.first { $0.productId == productId }
    }

    var kind: PopopxNodeBadgeSkuKind {
        switch self {
        case .subscriptionAnnual: .subscription(.annual)
        case .subscriptionMonthly: .subscription(.monthly)
        case .pass30Days: .oneTimePass(.monthly)
        case .pass365Days: .oneTimePass(.annual)
        case .giftAnnual: .giftCard(.annual)
        case .giftMonthly: .giftCard(.monthly)
        case .credits100: .credits(100)
        case .credits500: .credits(500)
        case .credits2000: .credits(2_000)
        case .credits5000: .credits(5_000)
        case .creditsGift100: .creditGiftCard(100)
        case .creditsGift500: .creditGiftCard(500)
        case .creditsGift2000: .creditGiftCard(2_000)
        }
    }

    var badgePeriod: PopopxNodeBadgePeriod? {
        switch kind {
        case let .subscription(period), let .giftCard(period), let .oneTimePass(period): period
        case .credits, .creditGiftCard: nil
        }
    }

    /// The period of a one-off time pack. Both the payment path and the copy accept only this one criterion, so no second answer to "which ones are passes" can grow outside `kind`.
    var oneTimePassPeriod: PopopxNodeBadgePeriod? {
        if case let .oneTimePass(period) = kind { period } else { nil }
    }

    /// The **credited amount** of a compute-credit top-up pack. Strictly equal to the calibrated value, never boosted with bonuses —
    /// the moment "gift XX compute credits" appears it trips both Apple's 3.1.1 parity rule and the domestic promotion terms.
    var creditedAmount: Int? {
        if case let .credits(amount) = kind { amount } else { nil }
    }

    /// The face value carried by a compute-credit **gift card**. Mirrors `creditedAmount` and is deliberately a separate question:
    /// a gift card is minted into the voucher vault and never enters this device's wallet, so any caller that reads
    /// `creditedAmount` to decide how much to credit (the refund clawback, the ledger note) must not pick up a gift card.
    var giftCreditAmount: Int? {
        if case let .creditGiftCard(amount) = kind { amount } else { nil }
    }

    var isSubscription: Bool {
        if case .subscription = kind { return true }
        return false
    }

    /// Fallback price copy. StoreKit's `displayPrice` is the authority (regional currencies differ);
    /// this only holds the place while `Product.products(for:)` has failed or not returned yet, and during that period "Buy now" is not shown.
    /// A pass and the subscription for the same period are **priced the same**: two payment paths for the same thing (a 30-day badge) should not carry two list prices,
    /// the only difference being "will this path charge again".
    var fallbackPriceText: String {
        switch self {
        case .subscriptionAnnual, .pass365Days, .giftAnnual: "$49.99"
        case .subscriptionMonthly, .pass30Days, .giftMonthly: "$6.99"
        case .credits100, .creditsGift100: "$1.99"
        case .credits500, .creditsGift500: "$8.99"
        case .credits2000, .creditsGift2000: "$29.99"
        case .credits5000: "$69.99"
        }
    }
}

// MARK: - Compute-credit cash packs

/// The products of the compute-credit top-up family.
///
/// Since 2026-11-20 this is **the compute-credits page's own table**: the badge paywall (`PopopxBadgePaywallView`) no longer sells cash packs,
/// and the `.credits` family in its layout model `PopopxPaywallSection` was deleted along with it — one page, one kind of product,
/// so a tier table should not be held by another page.
///
/// The amount digits are deliberately **not written here**: `amount` comes from `PopopxNodeBadgeSku.creditedAmount`, and that is
/// the only number inside the SKU's `kind`, and the one `PopopxCreditsManager` actually credits. Writing it again in the table
/// as "500" adds one more place that can fork from the real crediting — and a fork in credit top-ups is money that has to be refunded.
struct PopopxCreditPack: Identifiable, Hashable, Sendable {
    let sku: PopopxNodeBadgeSku
    let amount: Int

    /// Only the amount the SKU itself reports is accepted: pass in something that is not a credit tier and the row cannot be built at all (rather than yielding a "0 credit" tier).
    /// It reads both the top-up and the gift-card amount because one row table serves both pages; which SKU is offered **where** stays in `PopopxCreditPlan`.
    init?(sku: PopopxNodeBadgeSku) {
        guard let amount = sku.creditedAmount ?? sku.giftCreditAmount else { return nil }
        self.sku = sku
        self.amount = amount
    }

    var id: String { sku.productId }

    /// The line shown on screen shares one localized format string with the balance row and the ledger row (`"%lld Compute Credits"`),
    /// so "what this tier is called" and "how many credits this tier has" have exactly one spelling in the catalogue.
    var title: String { String(format: PopopxCommerceCopy.creditsAmountFormat, amount) }
}

enum PopopxCreditPlan {
    /// Four cash-pack tiers, smallest first. The order is a layout fact and lives on this line; the amounts are product facts and live in the SKU.
    /// `compactMap` is not error tolerance: if the SKU ever changes category, this tier disappears from the page instead of drawing a fake number.
    static let packs: [PopopxCreditPack] =
        [PopopxNodeBadgeSku.credits100, .credits500, .credits2000, .credits5000].compactMap(PopopxCreditPack.init)

    /// The three gift-card tiers. Same face values and the same prices as `packs` — the product differs only in who receives the credits,
    /// and a gift card bought for someone else must not look like a discount on buying them for yourself.
    static let giftPacks: [PopopxCreditPack] =
        [PopopxNodeBadgeSku.creditsGift100, .creditsGift500, .creditsGift2000].compactMap(PopopxCreditPack.init)
}

// MARK: - Badge state

/// Where a badge came from. Trial, subscription, one-off time pack, compute-credit redemption, a voucher gifted by someone else — the five sources light up the same badge,
/// and differ only in who owns the renewal and whether restore-purchase can find it back.
enum PopopxBadgeSource: String, Codable, CaseIterable, Sendable {
    case pioneerTrial
    case appleSubscription
    /// One-off time pack (non-renewing subscription): pay once, get a stretch of time, no renewal switch on Apple's side, and it is not part of restore-purchase either.
    case storePass
    case creditsExchange
    case giftedVoucher

    /// Only the subscription tier is auto-renewed by Apple; restore-purchase (`AppStore.sync()`) is meaningful for it alone.
    var renewsAutomatically: Bool { self == .appleSubscription }
}

/// The persisted shape of one badge record. Only `PopopxBadgeManager` ever writes it in the whole module.
struct PopopxBadgeRecord: Codable, Hashable, Sendable {
    var period: PopopxNodeBadgePeriod
    var source: PopopxBadgeSource
    var issuedAtMs: Int64
    var expiresAtMs: Int64
    /// The node-route rotation counter. Before it runs on a real device it is only a local count and stands for no server-side behaviour.
    var rotationIndex: Int
    /// The first 16 hex characters of the source credential's SHA-256 (the JWS text / the redemption record), used for after-the-fact reconciliation.
    var receiptDigest: String?
    /// The trial badge's anti-replay fingerprint (the digest of a DeviceCheck token or of this device's install fingerprint).
    var trialGuard: String?
}

/// The state capsule rendering needs. Kept separate from `PopopxBadgePhase` because the view layer should not be handed dates to compare by itself.
enum PopopxBadgeCapsuleState: String, Hashable, Sendable {
    /// Trial state: cyber-cyan breathing glow.
    case trialPulsing
    /// Fully lit state: emerald green + the node-refresh spin.
    case activeLit
    /// Dormant state: cold-mist grey.
    case dormant
}

/// The badge's three states. `dormant` is not "failure", it is the ordinary "using the free public SMP node" state —
/// UI copy and accessibility descriptions must both use that wording and may not say "expired / not activated".
enum PopopxBadgePhase: Hashable, Sendable {
    case dormant
    case trial(expiresAt: Date)
    case active(source: PopopxBadgeSource, expiresAt: Date)

    var capsuleState: PopopxBadgeCapsuleState {
        switch self {
        case .trial: .trialPulsing
        case .active: .activeLit
        case .dormant: .dormant
        }
    }

    var isLit: Bool {
        switch self {
        case .dormant: false
        case .trial, .active: true
        }
    }

    var remainingSeconds: TimeInterval {
        switch self {
        case .dormant: 0
        case let .trial(expiresAt), let .active(_, expiresAt):
            max(0, expiresAt.timeIntervalSinceNow)
        }
    }

    /// The expiry date; nil in the dormant state, so a caller cannot display a fake expiry such as "0 seconds" or "1970".
    var expiresAt: Date? {
        switch self {
        case .dormant: nil
        case let .trial(expiresAt), let .active(_, expiresAt): expiresAt
        }
    }

    /// Derives the current state from the record. `now` is injected instead of an internal `Date()` so that the "expiry fallback" can be hit by unit tests.
    static func phase(for record: PopopxBadgeRecord?, now: Date = Date()) -> PopopxBadgePhase {
        guard let record else { return .dormant }
        let expiresAt = Date(timeIntervalSince1970: Double(record.expiresAtMs) / 1_000)
        guard expiresAt > now else { return .dormant }
        if record.source == .pioneerTrial { return .trial(expiresAt: expiresAt) }
        return .active(source: record.source, expiresAt: expiresAt)
    }
}

// MARK: - Gift voucher

/// The voucher's lifecycle. `consumed` exists only on the receiving side: the grant the peer returned has already lit this device's badge, so the voucher has landed.
enum PopopxVoucherState: String, Codable, CaseIterable, Sendable {
    case unused
    case redeemed
    case consumed
}

/// A transferable voucher minted locally — a gift badge **or** a compute-credit gift card, one table and one double-spend arbiter for both.
/// `jwsDigest` is the digest of the Apple receipt — the text itself is never stored,
/// because that string carries Apple ID linking information, and keeping it in the Keychain only moves the risk into your own backup.
struct PopopxNodeVoucher: Codable, Hashable, Identifiable, Sendable {
    let voucherId: String
    /// Set only for a badge voucher. Optional **because a credit voucher has no period at all** — and the optionality is what
    /// stops a credit voucher from being turned into a badge code: every badge path has to unwrap it, and the unwrap fails there.
    var period: PopopxNodeBadgePeriod?
    /// Set only for a compute-credit gift card, and always to a pack face value (`PopopxCreditPlan.giftPacks`).
    /// The two value fields are mutually exclusive by construction in the vault (`mint` fills one, `mintCredit` the other);
    /// nothing infers the kind from `period == nil`, it is read from `isCreditVoucher` so a half-filled row cannot pose as either.
    var creditsAmount: Int?
    var state: PopopxVoucherState
    let mintedAtMs: Int64
    let transactionId: String
    let jwsDigest: String
    /// The digest of the redemption code (`PPX1-…` or `PPXC1-…`), for traceability that "this voucher was sent out"; the code itself is not stored.
    var codeDigest: String?
    var redeemedAtMs: Int64?
    /// A field only the receiver has: the authorisation text the peer ACKed back. The sender keeps it nil.
    var grantBase64URL: String?

    var id: String { voucherId }

    var isRedeemable: Bool { state == .unused }

    var isCreditVoucher: Bool { creditsAmount != nil }

    /// The day count the **badge** screens print for this row.
    /// `0` is unreachable there by construction: every one of those lists is fed by `PopopxP2PVoucherVault.badgeVouchers(state:)`,
    /// which drops the credit rows. It still answers a number instead of trapping because a wrong figure in a voucher list is
    /// correctable by the next refresh, while a crash inside `body` leaves the user holding a page that will not open at all.
    /// Anything that *signs* or *spends* must unwrap `period` itself — see `PopopxP2PVoucherVault.authorizeRedemption`.
    var badgeDays: Int { period?.days ?? 0 }

    /// The face value the **credit** screens print for this row — the exact twin of `badgeDays` above, for the exact same reason.
    /// `0` is unreachable: the only lists that reach a row view come from `PopopxP2PVoucherVault.creditVouchers(state:)`, which drops
    /// the badge rows. Anything that *mints a code* or *signs a payload* unwraps `creditsAmount` itself, see `mintCreditCode`.
    var creditFaceValue: Int { creditsAmount ?? 0 }
}

/// The letter of authorisation for a compute-credit gift card — the credit twin of `PopopxBadgeGrant`.
///
/// It is a separate type rather than a grant with an optional period because the two facts they attest are different:
/// a badge grants `expiresAtMs` (a deadline computed from the giver's clock), credits grant a number and **never expire**.
/// Carrying `expiresAtMs = 0` for credits would make "when does this expire" have two answers in one struct,
/// and the signature covers the canonical bytes, so a reused type would also let a badge signature be replayed as a credit grant.
struct PopopxCreditsGrant: Codable, Hashable, Sendable {
    let voucherId: String
    let creditsAmount: Int
    let grantedAtMs: Int64
    /// The x963 public key of the giver's local key (unpadded base64url).
    let giverPublicKey: String
    /// The ECDSA P-256 signature over `canonicalBytes` (DER, unpadded base64url).
    let signature: String

    /// `kind: "credit_grant"` is not interchangeable with `kind: "grant"` — a signature over one canonical form cannot verify as the other.
    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "credit_grant", parts: [voucherId, String(creditsAmount), String(grantedAtMs)])
    }

    var isSignatureValid: Bool {
        PopopxCommerceSignature.verify(signatureBase64URL: signature, for: canonicalBytes, publicKeyBase64URL: giverPublicKey)
    }
}

/// The voucher's letter of authorisation: signed locally by the giver, returned to the redeemer with the ACK, and the redeemer lights the badge from it and files it in the voucher wallet.
/// The signature covers `canonicalBytes`, so if someone changes the period from `m` to `y` it fails verification on the spot.
struct PopopxBadgeGrant: Codable, Hashable, Sendable {
    let voucherId: String
    let period: PopopxNodeBadgePeriod
    let grantedAtMs: Int64
    let expiresAtMs: Int64
    /// The x963 public key of the giver's local key (unpadded base64url).
    let giverPublicKey: String
    /// The ECDSA P-256 signature over `canonicalBytes` (DER, unpadded base64url).
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "grant", parts: [voucherId, period.wireValue, String(grantedAtMs), String(expiresAtMs)])
    }

    var isSignatureValid: Bool {
        PopopxCommerceSignature.verify(signatureBase64URL: signature, for: canonicalBytes, publicKeyBase64URL: giverPublicKey)
    }
}

// MARK: - One-time connection + badge, the two-in-one redemption code

/// What the redemption code holds: a one-time SMP connection link + a voucher's identity + the giver's public key.
struct PopopxRedeemEnvelope: Codable, Hashable, Sendable {
    /// A one-time connection link in `popopx:/…` form (minted by that same `PopopxInviteLink.mintOneTime` interface).
    let inviteLink: String
    let voucherId: String
    let period: PopopxNodeBadgePeriod
    let mintedAtMs: Int64
    /// 16 random bytes. When the same voucher is coded again (the user taps "Regenerate") it tells the two codes apart.
    let nonce: String
    /// The giver's public key (x963 base64url).
    let giverPublicKey: String
    /// The giver's signature over `canonicalBytes`.
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "code", parts: [voucherId, period.wireValue, String(mintedAtMs), nonce, inviteLink])
    }

    var isSignatureValid: Bool {
        PopopxCommerceSignature.verify(signatureBase64URL: signature, for: canonicalBytes, publicKeyBase64URL: giverPublicKey)
    }
}

/// The credit twin of `PopopxRedeemEnvelope`: a one-time SMP connection link + a credit voucher's identity + the giver's public key.
///
/// It has **no `period` field**, which is the type-level half of "a `PPXC1-` code can never light a badge": the badge code path
/// decodes into `PopopxRedeemEnvelope` and cannot build one from these bytes, and the canonical `kind` differs too, so a signature
/// over one envelope never verifies as the other.
struct PopopxCreditRedeemEnvelope: Codable, Hashable, Sendable {
    /// A one-time connection link in `popopx:/…` form, minted the same way as the badge envelope's.
    let inviteLink: String
    let voucherId: String
    let creditsAmount: Int
    let mintedAtMs: Int64
    /// 16 random bytes; tells two codes for the same voucher apart.
    let nonce: String
    /// The giver's public key (x963 base64url).
    let giverPublicKey: String
    /// The giver's signature over `canonicalBytes`.
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "credit_code", parts: [voucherId, String(creditsAmount), String(mintedAtMs), nonce, inviteLink])
    }

    var isSignatureValid: Bool {
        PopopxCommerceSignature.verify(signatureBase64URL: signature, for: canonicalBytes, publicKeyBase64URL: giverPublicKey)
    }
}

/// Codec for both redemption code families: `PPX1-…` (badge) and `PPXC1-…` (compute credits).
///
/// Why the code carries a checksum: `decode` verifies two bytes before parsing the JSON, so one mistyped character
/// lands straight on "checksum failed" instead of "parsed some unreadable JSON" — the first can prompt the user to retry, the second can only report an internal error.
///
/// The two families share the framing (checksum ‖ sorted-key JSON, base64url) on purpose: it is the fragile part, and a fix
/// applied to one and not the other is a code that stops decoding. What stays separate is the prefix and the envelope type,
/// so the framing helper is private and nothing here is generic over "which family" — the caller names it.
enum PopopxRedeemCode {
    static let prefix = "PPX1-"
    /// The compute-credit prefix differs from the badge prefix at the third character, so `hasPrefix` on either can never
    /// match a code of the other family; a mistyped `C` fails the checksum rather than silently crossing over.
    static let creditPrefix = "PPXC1-"

    /// Every prefix this codec recognises, used by `normalized` and `grouped` only. Adding a family means adding one string here.
    static let prefixes = [prefix, creditPrefix]

    /// The group width used for split display (8 characters per group, 5 groups fit one screen exactly).
    static let displayGroupWidth = 8

    static func encode(_ envelope: PopopxRedeemEnvelope) -> String? { framed(envelope, prefix: prefix) }

    static func encode(_ envelope: PopopxCreditRedeemEnvelope) -> String? { framed(envelope, prefix: creditPrefix) }

    static func decode(_ code: String) -> PopopxRedeemEnvelope? { unframed(code, prefix: prefix, as: PopopxRedeemEnvelope.self) }

    /// Named apart from `decode(_:)` on purpose: two overloads differing only in return type leave `if let envelope = decode(code)`
    /// to the type checker, and a call site that stops compiling because an inference changed is a worse trade than one more name.
    static func decodeCredit(_ code: String) -> PopopxCreditRedeemEnvelope? { unframed(code, prefix: creditPrefix, as: PopopxCreditRedeemEnvelope.self) }

    /// Which family a (normalised) code belongs to, or nil when it is neither.
    static func prefix(of code: String) -> String? { prefixes.first { code.hasPrefix($0) } }

    private static func framed<E: Encodable>(_ envelope: E, prefix: String) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(envelope), body.count <= 4_096 else { return nil }
        var payload = Data(capacity: PopopxCommerceLimits.codeChecksumBytes + body.count)
        payload.append(PopopxCommerceSignature.digest(body).prefix(PopopxCommerceLimits.codeChecksumBytes))
        payload.append(body)
        return prefix + payload.popopxBase64URL
    }

    private static func unframed<E: Decodable>(_ code: String, prefix: String, as type: E.Type) -> E? {
        let stripped = normalized(code)
        guard stripped.hasPrefix(prefix) else { return nil }
        let body = String(stripped.dropFirst(prefix.count))
        guard !body.isEmpty, let payload = Data(popopxBase64URL: body) else { return nil }
        guard payload.count > PopopxCommerceLimits.codeChecksumBytes else { return nil }
        let checksum = payload.prefix(PopopxCommerceLimits.codeChecksumBytes)
        let json = payload.dropFirst(PopopxCommerceLimits.codeChecksumBytes)
        guard PopopxCommerceSignature.digest(json).starts(with: checksum) else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json))
    }

    /// Normalisation. It removes **only** whitespace and prefix case differences: the base64url alphabet itself contains `-`,
    /// so deleting `-` as a separator would silently corrupt the payload; whitespace is therefore the only possible separator and the UI must display to that constraint.
    static func normalized(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        var text = String(String.UnicodeScalarView(stripped))
        // The two prefixes are case-insensitively distinct too, so at most one branch can fire.
        for known in prefixes where text.uppercased().hasPrefix(known.uppercased()) {
            text = known + String(text.dropFirst(known.count))
        }
        return text
    }

    /// The grouped form a human copies by hand (`PPX1-ABCD1234 EFGH…`).
    static func grouped(_ code: String) -> String {
        let head = prefix(of: code)
        let body = head.map { String(code.dropFirst($0.count)) } ?? code
        guard !body.isEmpty else { return code }
        var groups: [String] = []
        var rest = Substring(body)
        while !rest.isEmpty {
            let take = min(displayGroupWidth, rest.count)
            groups.append(String(rest.prefix(take)))
            rest = rest.dropFirst(take)
        }
        return (head ?? "") + groups.joined(separator: " ")
    }

    /// The whole code copied for the user: prefix + ungrouped original text (grouping is only for the screen, a copy must paste directly).
    static func clipboardValue(_ code: String) -> String { code }
}

// MARK: - Conversation-stream URIs (popopx://gift, popopx://redpacket and popopx://channel)

/// The payload of the gift-card bubble.
///
/// Field naming stays in the same family as the `loc`/`sec`/`profile` branches (single letters, values that never need escaping):
/// `note` may contain any character, so before it enters the URI it is base64url rather than percent-encoding —
/// the parsing side can therefore always split on `&` and divide at the first `=`, exactly the same premise as those three branches.
struct PopopxGiftCardPayload: Codable, Hashable, Sendable {
    static let scheme = "popopx"
    static let host = "gift"
    static let fieldNames: Set<String> = ["v", "p", "n", "t", "s"]
    /// A voucher id is `UUID().uuidString.lowercased()` — 36 characters. The cap has to sit above that or every card
    /// this module mints fails its own parser; it was 22 until 2026-11-21, which silently disabled the in-chat gift card.
    static let maximumVoucherIdCharacters = 40
    static let maximumSignatureCharacters = 180

    let voucherId: String
    let period: PopopxNodeBadgePeriod
    let note: String
    let mintedAtMs: Int64
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "gift", parts: [voucherId, period.wireValue, String(mintedAtMs)]) + Data(note.utf8)
    }

    var isSignatureValid: Bool {
        // The card does not carry the giver's public key (in a conversation stream a public key belongs to the privacy face), so this branch is only decidable when "this side is the giver";
        // authenticity on the receiving side is judged on the `PopopxBadgeGrant` that comes back in the ACK, not here.
        PopopxCommerceSignature.verifySelfIssued(signatureBase64URL: signature, for: canonicalBytes)
    }

    init(voucherId: String, period: PopopxNodeBadgePeriod, note: String, mintedAtMs: Int64, signature: String) {
        self.voucherId = voucherId
        self.period = period
        self.note = note
        self.mintedAtMs = mintedAtMs
        self.signature = signature
    }

    /// Mint: sign once, encode once. Failure = this device's identity key could not be fetched, and the caller must give visible feedback.
    static func make(voucherId: String, period: PopopxNodeBadgePeriod, note: String, mintedAtMs: Int64) -> PopopxGiftCardPayload? {
        let trimmed = String(note.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        let body = PopopxCommerceSignature.canonical(kind: "gift", parts: [voucherId, period.wireValue, String(mintedAtMs)]) + Data(trimmed.utf8)
        guard let signature = PopopxCommerceSignature.signatureBase64URL(for: body) else { return nil }
        return PopopxGiftCardPayload(voucherId: voucherId, period: period, note: trimmed, mintedAtMs: mintedAtMs, signature: signature)
    }

    var wireString: String {
        let noteField = Data(note.utf8).popopxBase64URL
        return "\(Self.scheme)://\(Self.host)?v=\(voucherId)&p=\(period.wireValue)&n=\(noteField)&t=\(mintedAtMs)&s=\(signature)"
    }

    /// The same criteria as `PopopxLocationPayload.parse`: split on whitespace, start trying from the last token,
    /// check scheme+host together, field-name allow-list, required fields present, length capped.
    static func parse(from text: String) -> PopopxGiftCardPayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) { return payload }
        }
        return nil
    }

    static func parseToken(_ token: String) -> PopopxGiftCardPayload? {
        guard let components = URLComponents(string: token),
              components.scheme == scheme,
              components.host == host
        else { return nil }
        var fields: [String: String] = [:]
        for pair in (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fieldNames.contains(key), fields[key] == nil else { continue }
            fields[key] = String(parts[1])
        }
        guard
            let voucherId = fields["v"],
            voucherId.count <= maximumVoucherIdCharacters,
            !voucherId.isEmpty,
            let periodRaw = fields["p"],
            let period = PopopxNodeBadgePeriod.from(wire: periodRaw),
            let rawTime = fields["t"],
            rawTime.allSatisfy(\.isNumber),
            !rawTime.isEmpty,
            rawTime.count <= 15,
            let mintedAtMs = Int64(rawTime),
            let signature = fields["s"],
            signature.count <= maximumSignatureCharacters,
            !signature.isEmpty
        else { return nil }
        let noteField = fields["n"] ?? ""
        let note: String
        if noteField.isEmpty {
            note = ""
        } else if let data = Data(popopxBase64URL: noteField), let decoded = String(data: data, encoding: .utf8) {
            note = String(decoded.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        } else {
            return nil
        }
        return PopopxGiftCardPayload(
            voucherId: voucherId,
            period: period,
            note: note,
            mintedAtMs: mintedAtMs,
            signature: signature
        )
    }
}

/// The payload of the compute-credit gift-card bubble — the credit twin of `PopopxGiftCardPayload`, on its **own host** `creditgift`.
///
/// A separate host rather than a field on `gift` because the two cards grant different things, and a recipient must be able to tell
/// which one it is holding *before* it parses the value: one host with an optional amount would make "is this a badge or credits"
/// a runtime question, and mis-answering it is a voucher redeemed against the wrong ledger.
///
/// The amount in this card is **display only**. What gets credited comes from the signed `PopopxCreditsGrant` in the ACK,
/// which the giver's vault derives from its own stored voucher — so a hand-edited `a=` can lie about the face value on screen
/// but cannot mint a single credit.
struct PopopxCreditGiftPayload: Codable, Hashable, Sendable {
    static let scheme = "popopx"
    static let host = "creditgift"
    static let fieldNames: Set<String> = ["v", "a", "n", "t", "s"]
    static let maximumVoucherIdCharacters = 40
    static let maximumAmountDigits = 6
    static let maximumSignatureCharacters = 180

    let voucherId: String
    let creditsAmount: Int
    let note: String
    let mintedAtMs: Int64
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "creditgift", parts: [voucherId, String(creditsAmount), String(mintedAtMs)]) + Data(note.utf8)
    }

    var isSignatureValid: Bool {
        // Same limitation as the badge card: the card carries no public key, so only the giver can verify it. Authenticity for the recipient
        // is the ACK's `PopopxCreditsGrant`, never this signature.
        PopopxCommerceSignature.verifySelfIssued(signatureBase64URL: signature, for: canonicalBytes)
    }

    init(voucherId: String, creditsAmount: Int, note: String, mintedAtMs: Int64, signature: String) {
        self.voucherId = voucherId
        self.creditsAmount = creditsAmount
        self.note = note
        self.mintedAtMs = mintedAtMs
        self.signature = signature
    }

    /// Mint: sign once, encode once. `kind: "creditgift"` differs from the badge card's `"gift"`, so neither card's signature can be replayed as the other's.
    static func make(voucherId: String, creditsAmount: Int, note: String, mintedAtMs: Int64) -> PopopxCreditGiftPayload? {
        guard creditsAmount > 0 else { return nil }
        let trimmed = String(note.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        let body = PopopxCommerceSignature.canonical(kind: "creditgift", parts: [voucherId, String(creditsAmount), String(mintedAtMs)]) + Data(trimmed.utf8)
        guard let signature = PopopxCommerceSignature.signatureBase64URL(for: body) else { return nil }
        return PopopxCreditGiftPayload(voucherId: voucherId, creditsAmount: creditsAmount, note: trimmed, mintedAtMs: mintedAtMs, signature: signature)
    }

    var wireString: String {
        let noteField = Data(note.utf8).popopxBase64URL
        return "\(Self.scheme)://\(Self.host)?v=\(voucherId)&a=\(creditsAmount)&n=\(noteField)&t=\(mintedAtMs)&s=\(signature)"
    }

    static func parse(from text: String) -> PopopxCreditGiftPayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) { return payload }
        }
        return nil
    }

    static func parseToken(_ token: String) -> PopopxCreditGiftPayload? {
        guard let components = URLComponents(string: token),
              components.scheme == scheme,
              components.host == host
        else { return nil }
        var fields: [String: String] = [:]
        for pair in (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fieldNames.contains(key), fields[key] == nil else { continue }
            fields[key] = String(parts[1])
        }
        guard
            let voucherId = fields["v"],
            !voucherId.isEmpty,
            voucherId.count <= maximumVoucherIdCharacters,
            let rawAmount = fields["a"],
            !rawAmount.isEmpty,
            rawAmount.allSatisfy(\.isNumber),
            rawAmount.count <= maximumAmountDigits,
            let creditsAmount = Int(rawAmount),
            creditsAmount > 0,
            let rawTime = fields["t"],
            rawTime.allSatisfy(\.isNumber),
            !rawTime.isEmpty,
            rawTime.count <= 15,
            let mintedAtMs = Int64(rawTime),
            let signature = fields["s"],
            !signature.isEmpty,
            signature.count <= maximumSignatureCharacters
        else { return nil }
        let noteField = fields["n"] ?? ""
        let note: String
        if noteField.isEmpty {
            note = ""
        } else if let data = Data(popopxBase64URL: noteField), let decoded = String(data: data, encoding: .utf8) {
            note = String(decoded.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        } else {
            return nil
        }
        return PopopxCreditGiftPayload(
            voucherId: voucherId,
            creditsAmount: creditsAmount,
            note: note,
            mintedAtMs: mintedAtMs,
            signature: signature
        )
    }
}

/// The payload of the compute-credit red packet bubble. The spec lists the fields `id`/`amount`/`note`/`sig`; here there is exactly **one** extra `n` (share count):
/// in an equal group-chat split the claiming side has to know how large its own share is, and only this card can show that field —
/// without `n` you either make the recipient divide by the headcount itself (someone else can change that), or write the share count into `note` (that is user text, not an accounting entry).
/// So `n` goes into the signed text, and altering the share count is just as much a "verification failed" as altering the amount. A 1:1 chat is `n=1`, and a missing value parses as 1 too.
struct PopopxRedPacketPayload: Codable, Hashable, Sendable {
    static let scheme = "popopx"
    static let host = "redpacket"
    static let fieldNames: Set<String> = ["id", "amount", "note", "sig", "n"]
    /// Same class as `PopopxGiftCardPayload.maximumVoucherIdCharacters`: a packet id is the ledger entry id, a 36-character UUID string.
    /// The previous 32 rejected every packet this module sent, on the sender's own screen as much as the recipient's.
    static let maximumPacketIdCharacters = 40
    static let maximumAmountDigits = 6
    static let maximumRecipientsDigits = 3
    static let maximumSignatureCharacters = 180

    let packetId: String
    let amount: Int
    let recipients: Int
    let note: String
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "rp", parts: [packetId, String(amount), String(recipients)]) + Data(note.utf8)
    }

    var isSelfSignatureValid: Bool {
        PopopxCommerceSignature.verifySelfIssued(signatureBase64URL: signature, for: canonicalBytes)
    }

    /// The amount must land back on one of the calibrated tiers: the UI only offers fixed tiers, but **the criterion cannot live only in the UI** —
    /// a red-packet text with an altered amount can perfectly well be pasted into a conversation, and this layer must refuse it.
    var isAmountAuthorized: Bool {
        PopopxCommerceLimits.redPacketAmounts.contains(amount)
    }

    /// The amount one person is owed. A payload that does not divide evenly is always treated as forged: it cannot be an "equal split",
    /// and crediting it rounded down silently swallows the difference, money that nobody can reconcile.
    var amountPerRecipient: Int? {
        guard recipients >= 1, amount % recipients == 0 else { return nil }
        return amount / recipients
    }

    init(packetId: String, amount: Int, recipients: Int, note: String, signature: String) {
        self.packetId = packetId
        self.amount = amount
        self.recipients = recipients
        self.note = note
        self.signature = signature
    }

    static func make(packetId: String, amount: Int, recipients: Int, note: String) -> PopopxRedPacketPayload? {
        guard PopopxCommerceLimits.redPacketAmounts.contains(amount),
              recipients >= 1,
              recipients <= PopopxCommerceLimits.maximumPacketRecipients,
              amount % recipients == 0
        else { return nil }
        let trimmed = String(note.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        let body = PopopxCommerceSignature.canonical(kind: "rp", parts: [packetId, String(amount), String(recipients)]) + Data(trimmed.utf8)
        guard let signature = PopopxCommerceSignature.signatureBase64URL(for: body) else { return nil }
        return PopopxRedPacketPayload(packetId: packetId, amount: amount, recipients: recipients, note: trimmed, signature: signature)
    }

    var wireString: String {
        let noteField = Data(note.utf8).popopxBase64URL
        return "\(Self.scheme)://\(Self.host)?id=\(packetId)&amount=\(amount)&n=\(recipients)&note=\(noteField)&sig=\(signature)"
    }

    static func parse(from text: String) -> PopopxRedPacketPayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) { return payload }
        }
        return nil
    }

    static func parseToken(_ token: String) -> PopopxRedPacketPayload? {
        guard let components = URLComponents(string: token),
              components.scheme == scheme,
              components.host == host
        else { return nil }
        var fields: [String: String] = [:]
        for pair in (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fieldNames.contains(key), fields[key] == nil else { continue }
            fields[key] = String(parts[1])
        }
        guard
            let packetId = fields["id"],
            !packetId.isEmpty,
            packetId.count <= maximumPacketIdCharacters,
            let rawAmount = fields["amount"],
            rawAmount.allSatisfy(\.isNumber),
            !rawAmount.isEmpty,
            rawAmount.count <= maximumAmountDigits,
            let amount = Int(rawAmount),
            amount > 0,
            let signature = fields["sig"],
            !signature.isEmpty,
            signature.count <= maximumSignatureCharacters
        else { return nil }
        // The share count defaults to 1: that is the only legal value for a "1:1 chat red packet", and also what a payload minted before `n` existed should look like.
        let rawRecipients = fields["n"] ?? "1"
        guard rawRecipients.allSatisfy(\.isNumber), !rawRecipients.isEmpty,
              rawRecipients.count <= maximumRecipientsDigits,
              let recipients = Int(rawRecipients), recipients >= 1,
              recipients <= PopopxCommerceLimits.maximumPacketRecipients
        else { return nil }
        let noteField = fields["note"] ?? ""
        let note: String
        if noteField.isEmpty {
            note = ""
        } else if let data = Data(popopxBase64URL: noteField), let decoded = String(data: data, encoding: .utf8) {
            note = String(decoded.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        } else {
            return nil
        }
        return PopopxRedPacketPayload(packetId: packetId, amount: amount, recipients: recipients, note: note, signature: signature)
    }
}

/// The payload of the channel subscription threshold card bubble. It is a **visible** message, not silent signalling:
/// the threshold is "the price the channel owner wants members to know", and hiding it would mean making members pay for a number they cannot see.
///
/// ### Why it must travel as a message rather than "keep a copy on this device"
/// There is no server and no address book of the channel owner's: the only source of truth on a member's device is this line published in the channel.
/// So publishing = sending a message (`PopopxSilentSignalingRouter.sendChannelAccess`),
/// and the subscription panel's price = the `p` decoded out of that message. Neither side invents a number.
///
/// ### Fields
/// The same family as `gift`/`redpacket` (single letters, values need no escaping): `p` = threshold (compute credits per tile, 0 is allowed but no card can be sent,
/// see `make`), `t` = publish moment (milliseconds), `e` = publisher's public key (x963 unpadded base64url), `s` = signature.
/// The channel itself **does not go into the payload**: the credential key on the member's side is the local conversation id (`GroupInfo.id`),
/// which is stable on one device and was never portable across devices (credentials are only written to this device's keychain — the sentence in section 4).
/// Signing the local id into the message would only create a key that "does not exist at all on the other party's device".
struct PopopxChannelAccessPayload: Codable, Hashable, Sendable {
    static let scheme = "popopx"
    static let host = "channel"
    static let fieldNames: Set<String> = ["p", "t", "e", "s"]
    static let maximumPriceDigits = 6
    static let maximumPublicKeyCharacters = 120
    static let maximumSignatureCharacters = 180

    let price: Int
    let publishedAtMs: Int64
    let issuerPublicKeyBase64URL: String
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "chan", parts: [String(price), String(publishedAtMs), issuerPublicKeyBase64URL])
    }

    /// The re-check on the issuing device itself (the same level of use as `PopopxRedPacketPayload.isSelfSignatureValid`).
    var isSelfSignatureValid: Bool {
        PopopxCommerceSignature.verifySelfIssued(signatureBase64URL: signature, for: canonicalBytes)
    }

    /// Authenticity on the member's side: the public key is right here in this message, so it **does not need** the two sides to be contacts and does not depend on a local key.
    /// This is not decoration: altering `p` once is one failed verification, and the threshold directly decides how much money is deducted.
    var isIssuerSignatureValid: Bool {
        PopopxCommerceSignature.verify(
            signatureBase64URL: signature,
            for: canonicalBytes,
            publicKeyBase64URL: issuerPublicKeyBase64URL
        )
    }

    /// The threshold must be a number inside the criterion's range: `0` is legal (a free channel), negatives and anything above 100,000 are not,
    /// and the criterion sits in this layer rather than only in the input field because this URI can be pasted into any conversation.
    var isPriceAuthorized: Bool {
        price >= 0 && price <= PopopxCommerceLimits.maximumCreditsThreshold
    }

    init(price: Int, publishedAtMs: Int64, issuerPublicKeyBase64URL: String, signature: String) {
        self.price = price
        self.publishedAtMs = publishedAtMs
        self.issuerPublicKeyBase64URL = issuerPublicKeyBase64URL
        self.signature = signature
    }

    /// Publish: sign once, encode once. If the local key cannot be fetched it returns nil, and the caller must give visible feedback.
    /// `make` refuses `price == 0`: that tile neither deducts credits nor leaves a ledger row, so sending it is only noise (the branch in the panel already explained this).
    /// `localPublicKeyBase64URL()` returns an **empty string** when the key cannot be fetched, so empties are screened out here before signing —
    /// a card signed with a key that does not exist only gives the member a "verification failed", while the real reason is "this device has no key".
    static func make(price: Int, publishedAtMs: Int64) -> PopopxChannelAccessPayload? {
        guard price >= 1, price <= PopopxCommerceLimits.maximumCreditsThreshold else { return nil }
        let publicKey = PopopxCommerceSignature.localPublicKeyBase64URL()
        guard !publicKey.isEmpty else { return nil }
        let body = PopopxCommerceSignature.canonical(kind: "chan", parts: [String(price), String(publishedAtMs), publicKey])
        guard let signature = PopopxCommerceSignature.signatureBase64URL(for: body) else { return nil }
        return PopopxChannelAccessPayload(price: price, publishedAtMs: publishedAtMs, issuerPublicKeyBase64URL: publicKey, signature: signature)
    }

    var wireString: String {
        "\(Self.scheme)://\(Self.host)?p=\(price)&t=\(publishedAtMs)&e=\(issuerPublicKeyBase64URL)&s=\(signature)"
    }

    /// The same criteria as `PopopxRedPacketPayload.parse`: split on whitespace, start trying from the last token,
    /// check scheme+host together, field-name allow-list, required fields present, length capped.
    static func parse(from text: String) -> PopopxChannelAccessPayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) { return payload }
        }
        return nil
    }

    static func parseToken(_ token: String) -> PopopxChannelAccessPayload? {
        guard let components = URLComponents(string: token),
              components.scheme == scheme,
              components.host == host
        else { return nil }
        var fields: [String: String] = [:]
        for pair in (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fieldNames.contains(key), fields[key] == nil else { continue }
            fields[key] = String(parts[1])
        }
        guard
            let rawPrice = fields["p"],
            rawPrice.allSatisfy(\.isNumber),
            !rawPrice.isEmpty,
            rawPrice.count <= maximumPriceDigits,
            let price = Int(rawPrice),
            price >= 0,
            price <= PopopxCommerceLimits.maximumCreditsThreshold,
            let rawTime = fields["t"],
            rawTime.allSatisfy(\.isNumber),
            rawTime.count <= 15,
            let publishedAtMs = Int64(rawTime),
            let publicKey = fields["e"],
            !publicKey.isEmpty,
            publicKey.count <= maximumPublicKeyCharacters,
            let signature = fields["s"],
            !signature.isEmpty,
            signature.count <= maximumSignatureCharacters
        else { return nil }
        return PopopxChannelAccessPayload(
            price: price,
            publishedAtMs: publishedAtMs,
            issuerPublicKeyBase64URL: publicKey,
            signature: signature
        )
    }
}

// MARK: - Invisible signalling

/// The kinds of signalling. The strings line up with the spec character for character (`::popopx_sys::` + upper-case name + `::` + payload).
enum PopopxCommerceSignalKind: String, CaseIterable, Sendable {
    case externalRedeemRequest = "EXT_REDEEM_REQ"
    case externalRedeemAcknowledge = "EXT_REDEEM_ACK"
    case chatRedeemRequest = "CHAT_REDEEM_REQ"
    case chatRedeemAcknowledge = "CHAT_REDEEM_ACK"
    case redPacketClaimed = "REDPACKET_CLAIMED"
    /// The profile-card unlock receipt. The prompt writes it and the channel redemption receipt as "silent notifications", but none of the five names covers them,
    /// so this entry is **the sixth kind added because the requirement asked for it**, and `Docs/app-store-review-notes.md` has a separate item on why it exists.
    /// It only comes in and never goes out: the receiving side deletes the row and touches no UI, because "who viewed your profile page" stops being silent the moment it becomes a durable record.
    case profileUnlocked = "PROFILE_UNLOCKED"
    /// The redemption receipt of a channel subscription. The payload is the two parts `{chatInfoId}::{expiresAtMs}`, split on the **last** pair of `::`,
    /// because the conversation key itself looks like `#<local row number>` and only the trailing part is guaranteed to be a number.
    /// The name was fixed by a product ruling (round 2, item 2), and so was the field order: on this device, "which channel, which period expires".
    case channelSubscriptionAcknowledge = "CHANNEL_SUB_ACK"
    /// Channel payment receipt: member pays → channel owner credits. Payload format: `{channelId}:{credits}:{txHash}`.
    /// The txHash provides replay protection: the owner's wallet records it, and a second receipt with the same hash is ignored.
    case channelPaymentReceipt = "CHANNEL_PAY_RCPT"
    /// The four compute-credit legs, named as the spec names them. They are **separate kinds** rather than a flag inside the badge payload
    /// because the ACK carries a different signed type (`PopopxCreditsGrant` instead of `PopopxBadgeGrant`): the kind is what tells the
    /// receiving side which JSON to decode, and one payload shape with an optional period would let a badge grant be applied as credits.
    /// The REQ payload is the voucherId; the ACK payload is the grant's base64url — the same shapes as the badge legs, one level over.
    case creditExternalRedeemRequest = "CREDIT_EXT_REDEEM_REQ"
    case creditExternalRedeemAcknowledge = "CREDIT_EXT_REDEEM_ACK"
    case creditChatRedeemRequest = "CREDIT_CHAT_REDEEM_REQ"
    case creditChatRedeemAcknowledge = "CREDIT_CHAT_REDEEM_ACK"
    /// A command to, or a receipt from, the user's own Mac node (`disvcove_notes.md`, part one.1).
    /// The payload keeps the host's own three-part shape `{serviceId}::{action}::{payload}`, i.e. the full wire is
    /// `::popopx_sys::NODE_CMD::shadow_cos::briefing::{...}`; `parse` splits on the **first** `::` only, so the two
    /// inner separators belong to the payload and arrive unmangled.
    /// It is a control signal in both directions, which is why it lives here rather than in the Discover module:
    /// the three render-suppression sites all call `PopopxSysMarker.isSignalText`, and a marker parsed only inside
    /// Discover would leave the command text visible in a bubble — the one outcome the requirement forbids.
    /// `acceptedInGroup` deliberately does **not** include it: a node command addresses one machine, and a stray
    /// one in a group would push somebody's Mac around in front of an audience.
    case nodeCmd = "NODE_CMD"

    /// Only these two signalling kinds may be picked up inside a group/channel. The reason for the criterion is not "signalling cannot be received in a group",
    /// but that `awaitingAcks` keeps its books per chatId: a redemption ACK from a third person in the group would settle somebody else's entry
    /// (the router's `observeIncoming` section). Red packet receipts and channel redemption receipts are recorded per packetId / conversation key,
    /// never through `awaitingAcks`, so they are safe in a group.
    var acceptedInGroup: Bool {
        self == .redPacketClaimed || self == .channelSubscriptionAcknowledge || self == .channelPaymentReceipt
    }
}

/// One parsed signalling message.
struct PopopxCommerceSignal: Hashable, Sendable {
    let kind: PopopxCommerceSignalKind
    /// Payload: a voucherId, or the grant's base64url, or a packetId.
    let payload: String

    var isRequest: Bool {
        switch kind {
        case .externalRedeemRequest, .chatRedeemRequest, .creditExternalRedeemRequest, .creditChatRedeemRequest: true
        case .externalRedeemAcknowledge, .chatRedeemAcknowledge, .redPacketClaimed, .profileUnlocked,
             .channelSubscriptionAcknowledge, .channelPaymentReceipt, .creditExternalRedeemAcknowledge, .creditChatRedeemAcknowledge,
             .nodeCmd: false
        }
    }
}

/// Codec for `::popopx_sys::`.
///
/// Why `parse` requires whole-string equality rather than contains: `contains` would turn a sentence like
/// "look at this screenshot of ::popopx_sys::" into an executable signalling message. Whole-string equality is the only safe parsing boundary,
/// and the renderer's suppression logic shares it — there is only one copy of the criterion.
enum PopopxSysMarker {
    static let marker = "::popopx_sys::"

    static func wireString(for signal: PopopxCommerceSignal) -> String {
        "\(marker)\(signal.kind.rawValue)::\(signal.payload)"
    }

    static func parse(wholeText text: String) -> PopopxCommerceSignal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else { return nil }
        let rest = String(trimmed.dropFirst(marker.count))
        // Split on the **first** `::` only: a type name can never contain a colon, nor can a grant's base64url.
        // Using split(maxSplits:) would also accept `EXT_REDEEM_REQ:abc` (a single colon) as a legal form,
        // and after slicing out a type name that does not exist the offset would then be forced into the payload — the easiest place to slip silently out of alignment.
        guard let separator = rest.range(of: "::") else { return nil }
        let kindText = String(rest[..<separator.lowerBound])
        let payload = String(rest[separator.upperBound...])
        guard
            let kind = PopopxCommerceSignalKind(rawValue: kindText),
            !payload.isEmpty,
            payload.count <= PopopxCommerceLimits.maximumSignalPayloadCharacters
        else { return nil }
        return PopopxCommerceSignal(kind: kind, payload: payload)
    }

    /// The entry point of render suppression: a hit means the whole line never reaches a bubble, a preview, or being read aloud.
    ///
    /// It also answers for `::POPOPX_ECO::`, which is why the service-account module has no gates of its own: a second criterion in a
    /// second place is how one of the three sites ends up showing a frame the other two hide. Only a frame that *mutates this device*
    /// is suppressed here — a newly created service card is content the user must see, and `PopopxEcoMarker.isControlText` is what tells
    /// those two apart (`PopopxEcoModels.swift`, `PopopxServiceCard.isSane` / `PopopxEcoFrame.isControlFrame`).
    ///
    /// And it answers for the three eco **uplink** lines (`::CB::`, `::REF::`, `::SSO_SCAN::`), which carry no marker at all and so were
    /// invisible to both of the above: they went out as plain text and came back as a bubble that looks like the user typed a machine
    /// command. `PopopxEcoUplink` is a whole-line test by the same rule as `parse(wholeText:)` above — the prefixes are the ones the
    /// sender builds its wire from, so the two ends cannot drift apart.
    ///
    /// The fourth term is the signed server-cluster pair (`::popopx_sys::SERVER_CFG_V1` / `SERVER_CFG_ACK`), and it is a separate test
    /// rather than two more `PopopxCommerceSignalKind` cases for one reason: `parse` above refuses any payload over
    /// `maximumSignalPayloadCharacters`, and a four-hostname cluster frame with its signature is larger than that ceiling. A kind that
    /// will not parse is not a kind, so the frame would arrive as an ordinary message — which is precisely the line this mechanism must
    /// never show. `PopopxServerConfigWire.isControlText` judges the same prefix-and-no-whitespace shape as the
    /// others but without their two limits, and judges it **without** consulting the signature: an unsigned,
    /// malformed, empty or over-long frame is hidden exactly like a valid one, since it is deleted on arrival.
    ///
    /// The fifth term is a signed agent receipt (`::POPOPX_AGENT_RCPT::v1::…`). It is the answer this device
    /// sends to an agent, so it must never come back as a bubble looking like something the user typed; the
    /// whole-string prefix test lives in `PopopxAgentReceiptWire.isReceiptText`.
    static func isSignalText(_ text: String) -> Bool {
        parse(wholeText: text) != nil || PopopxEcoMarker.isControlText(text) || PopopxEcoUplink.isUplinkText(text)
            || PopopxServerConfigWire.isControlText(text) || PopopxAgentReceiptWire.isReceiptText(text)
    }
}

// MARK: - Compute-credit value types

/// The ledger categories. `sign` is defined once here, and the UI's plus/minus signs and colours both derive from it.
enum PopopxCreditsEntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case storePurchase
    case badgeExchange
    case giftVoucherExchange
    /// Paying credits to mint a compute-credit gift card (the credit twin of `giftVoucherExchange`). A spend, and nothing in this module
    /// ever reverses it: an unredeemed card keeps its credits off the balance until the peer redeems it, exactly as a badge voucher does.
    case creditGiftSent
    /// Receiving credits from someone else's gift card. Income, and the only credit leg this device can get without Apple collecting money here.
    case creditGiftReceived
    case redPacketSent
    case redPacketReceived
    case redPacketRefund
    case channelSubscription
    /// Paying a service account for something it sells through a card button (`pay_credits`): an appointment, a vote entry, an
    /// outsourced job. A spend, and deliberately NOT `channelSubscription` — that leg mints a local ticket with an expiry, while this
    /// one only produces a ledger entry whose id goes into the `::CB::…:paid_<id>` callback. Conflating them would either mint a
    /// ticket nobody asked for or lose the receipt the callback names.
    case servicePayment
    case profileUnlock
    case secureWindow
    case cosmetic
    case adjustment

    var id: String { rawValue }

    /// Income is positive, spending negative. `adjustment` can go either way, so it returns nil and the entry carries its own sign.
    var sign: Int? {
        switch self {
        case .storePurchase, .redPacketReceived, .adjustment: nil
        case .badgeExchange, .giftVoucherExchange, .creditGiftSent, .redPacketSent, .channelSubscription,
             .servicePayment, .profileUnlock, .secureWindow, .cosmetic: -1
        case .redPacketRefund, .creditGiftReceived: 1
        }
    }

    /// Listed case by case, with no `default`: a new ledger category has to be answered for here, the same way `sign` does.
    var isIncome: Bool {
        switch self {
        case .storePurchase, .redPacketReceived, .redPacketRefund, .creditGiftReceived: true
        case .badgeExchange, .giftVoucherExchange, .creditGiftSent, .redPacketSent, .channelSubscription,
             .servicePayment, .profileUnlock, .secureWindow, .cosmetic, .adjustment: false
        }
    }
}

/// One ledger row. `id` is the transaction hash used for replay prevention, so it is at once the accounting primary key and the dedup key.
struct PopopxCreditsEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let amount: Int
    let kind: PopopxCreditsEntryKind
    let note: String
    let timestampMs: Int64
    /// The balance snapshot after the entry. The default is for older entries (written before the upgrade), and for the default the UI hides the "balance" line.
    var balanceAfter: Int?
}

/// The wallet itself. It lives in the Keychain, not in a file: if the balance on this device is tampered with by a jailbreak tool,
/// what is being tampered with is a blob of `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` ciphertext, a smaller risk surface than a plaintext plist.
struct PopopxCreditsWallet: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var balance: Int
    var updatedAtMs: Int64
    /// Set to true when the balance and the ledger disagree. Better to show the user "needs reconcile" than to silently spend a wrong book as a balance.
    var needsReconcile: Bool
}

/// A red packet that has not been fully claimed (held by the sender, used to check ACKs and refund).
struct PopopxPendingRedPacket: Codable, Hashable, Identifiable, Sendable {
    let packetId: String
    let amount: Int
    let note: String
    let recipientCount: Int
    var claimedCount: Int
    let createdAtMs: Int64
    /// The amount one person is owed in an equal group split; for a one-person red packet it equals `amount`.
    let amountPerRecipient: Int
    var settled: Bool
    /// The group members who have already ACKed this red packet (the string form of `GroupMember.groupMemberId`). Optional and defaulting to nil
    /// because: one, a direct red packet has no notion of a "member", and a single share is naturally deduped by the claiming side's ledger;
    /// two, the decoding side uses `decodeIfPresent` for missing keys, so a field added later will not read an absent value as an empty array and conclude "nobody claimed".
    /// It is only a **dedup set**; the refund amount is computed from `claimedCount` — the two are equal in a group, and in a 1:1 chat only the latter has a value.
    var claimKeys: [String]?

    var id: String { packetId }

    var isFullyClaimed: Bool { claimedCount >= recipientCount || settled }

    /// The earliest moment this side may decide "this order is over, refund the remainder". Never refund before it is claimed out:
    /// once the remainder is refunded, the shares still left in the group can be claimed, and those credits would be created out of nothing.
    var claimGraceEndsAtMs: Int64 { createdAtMs + Int64(PopopxCommerceLimits.packetClaimGraceSeconds * 1_000) }

    /// The refund amount of the unclaimed part (only this side can compute it, because no server holds a fallback ledger).
    var refundableAmount: Int {
        max(0, amount - claimedCount * amountPerRecipient)
    }
}

/// A channel subscription credential. The channel owner sets the threshold themselves, and a member who has credited locally holds a ticket with an expiry time.
struct PopopxChannelSubscriptionTicket: Codable, Hashable, Identifiable, Sendable {
    let channelId: String
    let channelTitle: String
    let price: Int
    let paidAtMs: Int64
    let expiresAtMs: Int64
    let transactionId: String
    /// The publisher key of the card this ticket was signed against. **Optional** is for compatibility with tickets written before the upgrade: that generation's JSON has no such key,
    /// and non-optional would fail decoding of the whole keychain array, so everybody's "subscribed" state would turn overnight into never having subscribed.
    /// Old tickets missing this field never take part in the anti-impersonation comparison (criterion: `PopopxCreditsManager.channelIssuerConflict`).
    var issuerPublicKeyBase64URL: String?

    var id: String { transactionId }

    func isValid(at now: Date) -> Bool {
        expiresAtMs > Int64(now.timeIntervalSince1970 * 1_000)
    }
}

/// The receipt left after unlocking an encrypted profile page (held by the payer, for looking back at "who I viewed" and for reconciliation).
struct PopopxProfileUnlockReceipt: Codable, Hashable, Identifiable, Sendable {
    let profileId: String
    let chatId: Int64
    let itemId: Int64
    let price: Int
    let unlockedAtMs: Int64
    let transactionId: String

    var id: String { transactionId }
}

/// Channel payment receipt: sent from member to channel owner when credits are consumed for subscription.
/// The txHash provides replay protection on the owner's side.
struct PopopxChannelPaymentReceipt: Codable, Hashable, Sendable {
    let channelId: Int64
    let credits: Int
    let txHash: String
    let paidAtMs: Int64

    /// Parse from wire format: `{channelId}:{credits}:{txHash}`
    static func parse(from payload: String) -> PopopxChannelPaymentReceipt? {
        let parts = payload.split(separator: ":", maxSplits: 2)
        guard parts.count == 3,
              let channelId = Int64(parts[0]),
              let credits = Int(parts[1]) else { return nil }
        let txHash = String(parts[2])
        return PopopxChannelPaymentReceipt(
            channelId: channelId,
            credits: credits,
            txHash: txHash,
            paidAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Encode to wire format
    var wireString: String {
        "\(channelId):\(credits):\(txHash)"
    }
}

/// High-tier appearance redemptions. Applied by local rendering, never uploaded and never verified, so all that is needed here is "when it was unlocked".
enum PopopxCosmetic: String, Codable, CaseIterable, Identifiable, Sendable {
    case auroraShieldAvatarFrame
    case darkGoldQRCardSkin

    var id: String { rawValue }

    var cost: Int {
        switch self {
        case .auroraShieldAvatarFrame: PopopxCommerceLimits.avatarFrameCost
        case .darkGoldQRCardSkin: PopopxCommerceLimits.qrCardSkinCost
        }
    }
}

/// The anti-replay sets: red packet ids claimed, voucher ids redeemed, transaction hashes credited.
/// The three sets share one ceiling; over the ceiling the oldest are dropped FIFO — the transaction that oldest row stands for finished long ago.
struct PopopxReplayGuard: Codable, Hashable, Sendable {
    var claimedPacketIds: [String] = []
    var redeemedVoucherIds: [String] = []
    var creditedTransactionHashes: [String] = []

    mutating func claim(packetId: String) { append(packetId, to: \.claimedPacketIds) }
    mutating func redeem(voucherId: String) { append(voucherId, to: \.redeemedVoucherIds) }
    mutating func credit(transactionHash: String) { append(transactionHash, to: \.creditedTransactionHashes) }

    func hasClaimed(packetId: String) -> Bool { claimedPacketIds.contains(packetId) }
    func hasRedeemed(voucherId: String) -> Bool { redeemedVoucherIds.contains(voucherId) }
    func hasCredited(transactionHash: String) -> Bool { creditedTransactionHashes.contains(transactionHash) }

    private mutating func append(_ value: String, to keyPath: WritableKeyPath<PopopxReplayGuard, [String]>) {
        guard !self[keyPath: keyPath].contains(value) else { return }
        self[keyPath: keyPath].append(value)
        let overflow = self[keyPath: keyPath].count - PopopxCommerceLimits.maximumReplayIdentifiers
        if overflow > 0 { self[keyPath: keyPath].removeFirst(overflow) }
    }
}

// MARK: - Keychain

/// Keychain item slots. Every name carries the `popopx.commerce.` prefix, kept apart from
/// the `kcDatabasePassword`/`kcSelfDestructPassword` family and duress's own `popopx.duress.*`,
/// so the three account namespaces never overwrite each other.
enum PopopxCommerceKeychainSlot: String, CaseIterable, Sendable {
    case badgeRecord = "popopx.commerce.badge"
    case trialGuard = "popopx.commerce.trial"
    case vouchers = "popopx.commerce.vouchers"
    case wallet = "popopx.commerce.wallet"
    case ledger = "popopx.commerce.ledger"
    case replayGuard = "popopx.commerce.replay"
    case signingKey = "popopx.commerce.signing-key"
    case pendingPackets = "popopx.commerce.pending-packets"
    case channelTickets = "popopx.commerce.channel-tickets"
    case profileReceipts = "popopx.commerce.profile-receipts"
    case receivedPaymentTxHashes = "popopx.commerce.received-payment-txhashes"
    case cosmetics = "popopx.commerce.cosmetics"
    case ephemeralConnections = "popopx.commerce.ephemeral-connections"
    /// This device's install fingerprint (the second half of the trial badge's replay prevention). Its own slot, never shared with the temporary connection:
    /// that one gets overwritten repeatedly by the redemption flow, and overwriting the fingerprint once means the trial badge can be claimed without limit.
    case installIdentity = "popopx.commerce.install-identity"
    /// The authorisation text (grant) whose signature the receiving side verified. Its own slot, not borrowing `profileReceipts`:
    /// that slot holds the receipts for unlocking profile cards, and having the redemption flow overwrite it would wipe somebody else's unlock credentials along with it.
    case grants = "popopx.commerce.grants"
    /// The credit twins of `grants`, and for the same reason it cannot share that slot: the two hold different types under the same
    /// voucher-id keys, so writing one table over the other would make a verified authorisation unreadable.
    case creditGrants = "popopx.commerce.credit-grants"
    /// The gift message the giver typed for one card, keyed by voucher id.
    ///
    /// It is its own slot rather than a field of `PopopxNodeVoucher` on purpose: that row's encoding is the double-spend record, and
    /// a free-text column cannot be added to it without a migration. Nor can the message ride on the stored redemption code: the
    /// `PPX1-` / `PPXC1-` envelope has no message field, and only its digest is kept, so there is nothing to decode it back from.
    /// A card minted before this slot existed has no note row, which is
    /// exactly the state it is in today — nothing old has to be rewritten. Being a case of this enum also means `removeAll()` wipes it
    /// together with the rest, so no gift message survives an emergency wipe.
    case voucherNotes = "popopx.commerce.voucher-notes"
    /// Discover's 30-day service subscriptions, the bonded Mac node and the receipts each service
    /// collected. Three slots rather than one because they fail differently: a subscription list that
    /// cannot be decoded would take the node binding down with it (and the user would have to re-pair),
    /// while the transcript is disposable history. Being cases of this enum is also what makes the
    /// emergency wipe cover them — `PopopxCommerceKeychain.removeAll()` iterates `allCases`, so no
    /// activated service and no Mac address survives a duress wipe.
    case discoverSubscriptions = "popopx.commerce.discover-subscriptions"
    case discoverNodeBinding = "popopx.commerce.discover-node-binding"
    case discoverInbox = "popopx.commerce.discover-inbox"
    /// The content the bonded Mac published, together with the key it verified under, and the one
    /// answer per version that keeps an update card from being tapped twice. Their own slots, and
    /// still cases of this enum: being one is what makes the emergency wipe erase them, and the
    /// feed is exactly the kind of thing a duress wipe is for — headlines this device read from a
    /// machine that is no longer with the user.
    case discoverFeed = "popopx.commerce.discover-feed"
    case discoverUpdateDecisions = "popopx.commerce.discover-update-decisions"
    /// The Ed25519 seed this device signs agent receipts with, and the one answer per task id that
    /// keeps an approval card from being tapped twice. Cases of this enum for the same reason as
    /// the three above: `removeAll()` is the emergency wipe, and a signing identity plus a trail of
    /// what the user approved is exactly what must not survive it.
    case agentReceiptKey = "popopx.commerce.agent-receipt-key"
    case agentReceipts = "popopx.commerce.agent-receipts"
}

/// Keychain reads and writes.
///
/// Accessibility uses `AfterFirstUnlockThisDeviceOnly` (named and required by the spec): badges and balance must be readable when signalling arrives on the lock screen,
/// while ThisDeviceOnly also keeps it out of iCloud Keychain — a voucher sitting on somebody else's device,
/// if it were synced over, would make a double spend true on two machines at once, which is the worst possible outcome.
/// accessGroup is only attached on a real device: on the simulator a `SecItemAdd` carrying a group fails outright,
/// and this copies the existing practice of `POPOPXChat/KeyChain.swift:118-126`.
enum PopopxCommerceKeychain {
    static let service = "popopx.commerce"
    static let accessGroup = "PDBA6XRBQT.com.popopxchat.popopx"

    static func read(_ slot: PopopxCommerceKeychainSlot) -> Data? {
        var query = lookupQuery(slot)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Write. `SecItemUpdate` first, then `SecItemAdd`, and **accessibility hangs only on the add branch**:
    /// `SecItemUpdate` cannot change the accessibility of an existing item, and putting it into the query conditions instead
    /// would make older items (written with a different accessibility) fail to match, so the update silently fails and degrades into "add another copy".
    /// The upgrade path that needs an accessibility change is "delete first, then write", done explicitly by the caller; this does not pretend it can overwrite it.
    static func write(_ data: Data, _ slot: PopopxCommerceKeychainSlot) -> Bool {
        if SecItemUpdate(lookupQuery(slot) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return true
        }
        var add = lookupQuery(slot)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ slot: PopopxCommerceKeychainSlot) -> Bool {
        let status = SecItemDelete(lookupQuery(slot) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func contains(_ slot: PopopxCommerceKeychainSlot) -> Bool {
        read(slot) != nil
    }

    static func decode<T: Decodable>(_ type: T.Type, _ slot: PopopxCommerceKeychainSlot) -> T? {
        guard let data = read(slot) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T, _ slot: PopopxCommerceKeychainSlot) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return false }
        return write(data, slot)
    }

    /// Wipes every trace this module left in the Keychain (both emergency self-destruct and "clear my data" call it).
    static func removeAll() {
        for slot in PopopxCommerceKeychainSlot.allCases { _ = remove(slot) }
    }

    /// The attribute set used for lookup: it contains no accessibility, so both new and old items match.
    private static func lookupQuery(_ slot: PopopxCommerceKeychainSlot) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue
        ]
        #if os(iOS) && !targetEnvironment(simulator)
        query[kSecAttrAccessGroup as String] = accessGroup
        #endif
        return query
    }
}

// MARK: - Local signing identity

/// The single entry point for CryptoKit P-256 signatures.
///
/// Why ECDSA P-256 rather than Ed25519: this module has to share CryptoKit's existing usage with the `PopopxSecurePayload` branch
/// (AES-GCM + SHA256), and signing only needs "a local key + a tamper trail",
/// while both P-256 representations, x963 and DER, are APIs that have been stable since iOS 13;
/// `compressedRepresentation` is not guaranteed available on `P256.Signing.PublicKey`, so x963 was chosen.
enum PopopxCommerceSignature {
    /// Fetch (or mint on first use) this device's signing key. The private key is stored in the Keychain as PEM,
    /// and every call parses it again — key material never enters a static variable, because a static variable would keep it in memory until the process ends.
    ///
    /// If it cannot be stored, return nil, **do not return a throwaway key**: with a silent downgrade, the redemption codes issued last time
    /// would all fail verification at the next launch because "the key was swapped", and what the user sees is "my code stopped working",
    /// while the real reason hides in a log line nobody reads. Better to report "secure storage unavailable" on the spot.
    static func signingKey() -> P256.Signing.PrivateKey? {
        if let data = PopopxCommerceKeychain.read(.signingKey),
           let pem = String(data: data, encoding: .utf8),
           let existing = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return existing
        }
        let minted = P256.Signing.PrivateKey()
        guard PopopxCommerceKeychain.write(Data(minted.pemRepresentation.utf8), .signingKey) else { return nil }
        return minted
    }

    /// This device's public key (x963, unpadded base64url). The redemption code and the letter of authorisation carry exactly this string.
    static func localPublicKeyBase64URL() -> String {
        signingKey()?.publicKey.x963Representation.popopxBase64URL ?? ""
    }

    /// Signs a stretch of canonicalised bytes and returns the DER signature as unpadded base64url.
    static func signatureBase64URL(for canonical: Data) -> String? {
        guard let key = signingKey() else { return nil }
        guard let signature = try? key.signature(for: canonical) else { return nil }
        return signature.derRepresentation.popopxBase64URL
    }

    /// Strict verification: a public key that will not decode, a signature that will not decode, and a failed check are all false, without distinguishing the reason.
    static func verify(signatureBase64URL: String, for canonical: Data, publicKeyBase64URL: String) -> Bool {
        guard
            !signatureBase64URL.isEmpty, !publicKeyBase64URL.isEmpty,
            let signatureData = Data(popopxBase64URL: signatureBase64URL),
            let keyData = Data(popopxBase64URL: publicKeyBase64URL),
            let publicKey = try? P256.Signing.PublicKey(x963Representation: keyData),
            let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData)
        else { return false }
        return publicKey.isValidSignature(signature, for: canonical)
    }

    /// Self-signature check: only meaningful under the premise "this payload was minted on this device" (the giver looking at their own outgoing card locally).
    /// Named differently from `verify` so that a call site can never read "self-signed passed" as "the other side confirmed it".
    static func verifySelfIssued(signatureBase64URL: String, for canonical: Data) -> Bool {
        verify(signatureBase64URL: signatureBase64URL, for: canonical, publicKeyBase64URL: localPublicKeyBase64URL())
    }

    /// The canonical bytes. Field order is fixed, segments are separated by `|`, and the first segment is the payload type name:
    /// take gift's canonical result and verify it as a redpacket and it fails to match right at the start.
    ///
    /// Keeping **only one** input shape (`[String]`) is deliberate: two shapes would sooner or later evolve into
    /// "two canonicalisation paths for the same payload", which is exactly where the "tamper trail" promise breaks down.
    /// Free text (the message) does not go into `parts` but is appended at the end as in the places below —
    /// a message may contain `|`, and as long as it is always the last segment it cannot push the earlier fields out of position.
    static func canonical(kind: String, parts: [String]) -> Data {
        Data((["popopx", kind] + parts).joined(separator: "|").utf8)
    }

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func digest(_ text: String) -> Data { digest(Data(text.utf8)) }

    /// The first 16 hex characters, used for posting entries and for reconciliation display.
    static func shortDigest(_ data: Data) -> String {
        digest(data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func shortDigest(_ text: String) -> String { shortDigest(Data(text.utf8)) }
}

// MARK: - Errors

/// This module's unified failure type. Centralised in one place so that the catch branches
/// in the 6 view files do not each invent an incompatible error enum.
enum PopopxBadgeCreditsError: Error, LocalizedError, Hashable {
    case storeUnavailable
    case productNotFound(String)
    case purchaseFailed(String)
    case purchaseCancelled
    case verificationFailed
    case keychainUnavailable
    case insufficientCredits(balance: Int, required: Int)
    case voucherUnavailable
    /// The credit twin of `voucherUnavailable`. Separate because the sentence a user reads must name the thing they hold:
    /// "this gift badge is no longer available" shown over a compute-credit gift card sends them looking for a badge page that was never involved.
    case creditVoucherUnavailable
    case voucherAlreadyRedeemed
    case codeMalformed
    case connectionUnavailable
    case signalRejected
    case expiryInPast
    /// Crediting would push past the balance ceiling. **Only the income direction can reach this case** (the spending direction is handled by `insufficientCredits`).
    /// Listed separately instead of reusing `purchaseFailed`: that one implies "something went wrong with the payment",
    /// whereas here the payment succeeded and the money arrived — this device's wallet simply cannot hold it, and what the user should do is spend some first before claiming.
    case creditBalanceTooHigh(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .storeUnavailable: PopopxCommerceCopy.errorStoreUnavailable
        case let .productNotFound(id): String(format: PopopxCommerceCopy.errorProductUnavailableFormat, id)
        case let .purchaseFailed(reason): String(format: PopopxCommerceCopy.errorPurchaseFailedFormat, reason)
        case .purchaseCancelled: PopopxCommerceCopy.errorPurchaseCancelled
        case .verificationFailed: PopopxCommerceCopy.errorVerificationFailed
        case .keychainUnavailable: PopopxCommerceCopy.errorKeychainUnavailable
        case let .insufficientCredits(balance, required):
            String(format: PopopxCommerceCopy.errorInsufficientCreditsFormat, required, balance)
        case .voucherUnavailable: PopopxCommerceCopy.errorVoucherUnavailable
        case .creditVoucherUnavailable: PopopxCommerceCopy.errorCreditVoucherUnavailable
        case .voucherAlreadyRedeemed: PopopxCommerceCopy.errorVoucherAlreadyRedeemed
        case .codeMalformed: PopopxCommerceCopy.errorCodeMalformed
        case .connectionUnavailable: PopopxCommerceCopy.errorConnectionUnavailable
        case .signalRejected: PopopxCommerceCopy.errorSignalRejected
        case .expiryInPast: PopopxCommerceCopy.errorExpiryInPast
        case let .creditBalanceTooHigh(maximum):
            String(format: PopopxCommerceCopy.errorCreditBalanceTooHighFormat, maximum)
        }
    }
}

// MARK: - Commerce copy (all languages)

/// Only "the few sentences that touch money" go through NSLocalizedString. Catalogue as it stands: 17 `.lproj` directories under `apps/ios`.
/// `en.lproj` gets none of them — it is the development region (`developmentRegion = en`), and this repo's convention there is to store only
/// entries whose value ≠ key; when a key is not found `NSLocalizedString` returns the source text, so the English path already reads the source.
/// Before real-device round 8 · task three, all the keys below had values in the 16 translation directories; the 4 source lines newly written this round
/// (`"POPOPX Badge"` and the three result sentences of compute-credit top-up) are not in the catalogues yet — this round's red line forbids touching `.lproj`,
/// so until they are added non-English languages will read the English source sentence; that is a known, deliberately left intermediate state, not a missing translation.
/// The remaining in-feature copy keeps using each file's own `private enum Copy` Chinese constants,
/// consistent with the last four POPOPX features; the dividing line between the two conventions is "does this sentence appear in payment/refund/compliance evidence".
///
/// The source text must be unique inside this feature: the catalogue is one app-level shared table, and the same key necessarily shares one translation.
/// There was an idea to reuse "History" (already present in all 16 languages); measured, de renders it as "Nachrichtenverlauf" (message history)
/// and zh-Hans renders "For me" as "only myself" — both are another page's semantics, so these three source texts were each changed to an unambiguous wording.
/// Three more, "Credits" / "Fixed amounts only" / "History", were deleted after a census (`PopopxCommerceCopy.<name>`
/// 0 references outside its declaration): keeping a "compliance sentence" that can never reach the screen is worse than not writing it.
/// The reverse of the same criterion holds too: a sentence identical in both source text and semantics may reuse an existing entry directly —
/// `"Top up Compute Credits"` is exactly the entry the "me" page row already uses, so no new wording is opened here.
enum PopopxCommerceCopy {
    static let badgeProductName = NSLocalizedString("POPOPX Dynamic Privacy Node Badge", comment: "product name")
    static let trialBadgeName = NSLocalizedString("3-Day Pioneer Node Trial Badge", comment: "trial product name")
    static let creditsName = NSLocalizedString("POPOPX Compute Credits", comment: "virtual currency name")
    static let nodeClusterTerm = NSLocalizedString("dynamic SMP relay node cluster", comment: "never VPN")

    static let paywallTitle = NSLocalizedString("Light up a privacy node", comment: "paywall title")
    // The section heading no longer says "for whom" (the source text used to be "For myself"): after the paywall and the compute-credit top-up were split into two
    // flow paths, this page sells only badges, and the heading has to name which product it sells rather than point vaguely at a person.
    // Deliberately not called "For me" / "Restore purchases": those two keys already belong to other pages in the catalogues of 11 languages,
    // and reusing them means letting another page's translation decide this feature's sentence. Unique source text → one entry in the catalogue, and what is read is what is written here.
    static let paywallBadgeTab = NSLocalizedString("POPOPX Badge", comment: "segment: badge plans bought for this device")
    static let paywallGiftTab = NSLocalizedString("Gift badge", comment: "segment")
    static let paywallRestore = NSLocalizedString("Restore badge purchases", comment: "button")
    static let paywallRedeemEntry = NSLocalizedString("Enter a code or scan", comment: "button")
    static let paywallUseCredits = NSLocalizedString("Exchange with Compute Credits", comment: "button")
    static let pricePerYear = NSLocalizedString("/ year", comment: "price suffix")
    static let pricePerMonth = NSLocalizedString("/ month", comment: "price suffix")
    static let savePercentFormat = NSLocalizedString("Save %lld%% off", comment: "annual badge savings, computed from the two live display prices")
    static let creditsAmountFormat = NSLocalizedString("%lld Compute Credits", comment: "credit pack amount")

    // The group of one-off time packs (non-renewing subscriptions). The two purchase paths must each state clearly, on the same page, "will money be charged again",
    // so this family of sentences is compliance text at the same level as the 3.1.2(c) sentence above, and goes into all 16 translation catalogues together.
    static let paywallAutoRenewGroupTitle = NSLocalizedString("Auto-renewing subscriptions", comment: "paywall section heading")
    static let paywallOneTimeGroupTitle = NSLocalizedString("One-time passes", comment: "paywall section heading")
    static let passTierTitleFormat = NSLocalizedString("%lld-day pass", comment: "one-time pass tier title")
    static let passActionTitle = NSLocalizedString("Buy pass", comment: "paywall button on a one-time pass tier")
    /// The non-renewing disclaimer. Placed in the same slot as the 3.1.2(c) sentence of the subscription tier: each tier states its own renewal fact.
    static let oneTimePurchaseStatement = NSLocalizedString("This is a one-time purchase. It never renews automatically and no further payment is taken.", comment: "Apple non-renewing purchase disclosure")
    /// The granted day count is passed in by the caller from `PopopxNodeBadgePeriod.days`. It says "more days" rather than "expires on such-and-such date":
    /// a pass stacks on top of the time currently left (`PopopxBadgeManager.activate`'s merge rule), so the day count is the stable fact.
    static let passGrantedFormat = NSLocalizedString("Badge lit for %lld more days.", comment: "purchase result")
    /// The "go pick a tier" exit in the trial panel and the detail page: both only bring up the same paywall, so the wording follows each context.
    static let choosePlanAction = NSLocalizedString("Choose a plan", comment: "trial panel exit into the paywall")
    static let renewOrChangePlanAction = NSLocalizedString("Renew or change plan", comment: "badge detail exit into the paywall")
    static let passSourceName = NSLocalizedString("One-time pass", comment: "badge provenance row")

    static let renewalStatement = NSLocalizedString("Payment will be charged to your Apple Account at confirmation of purchase. Subscriptions renew automatically unless they are cancelled at least 24 hours before the end of the current period. You can manage or cancel subscriptions in App Store settings at any time.", comment: "Apple 3.1.2(c) auto-renewable disclosure")
    static let noGiftBackStatement = NSLocalizedString("Compute Credits are added at the exact amount shown. No bonus credits are granted.", comment: "no promotional top-up")

    static let creditsBalance = NSLocalizedString("Compute Credits balance", comment: "wallet label")
    // The group of compute-credit cash packs (real-device round 8 · task three: the whole top-up flow moved to the compute-credits page).
    /// The card title. The source text is character-identical to the "me" page row (`PopopxMeView`'s `"Top up Compute Credits"`):
    /// same destination, same thing, so the catalogue should share that one entry which already has 16 translations rather than open a new wording.
    static let creditsTopUpTitle = NSLocalizedString("Top up Compute Credits", comment: "credits pack card title")
    /// The amount is passed in by the caller from `PopopxCreditPack.amount` — which comes from the SKU's `creditedAmount`,
    /// i.e. the number that is actually credited. Hard-coding it into the sentence would make it a second source of truth.
    static let creditsTopUpGrantedFormat = NSLocalizedString("Added %lld Compute Credits to your balance.", comment: "credits pack purchase result")
    /// The Ask to Buy / family-approval tier: no money charged yet and no credits arrived either. This sentence must not be written as "already credited".
    static let creditsTopUpPending = NSLocalizedString("Apple is still confirming this purchase. The Compute Credits appear in your balance as soon as it is confirmed.", comment: "credits pack purchase pending")
    /// The payment completed but this device's ledger was not written (Keychain write failed, or the balance ceiling blocked it).
    /// This sentence must exist, otherwise "paid and nothing changed on screen" becomes the hardest incident in this family to reproduce and to explain.
    static let creditsTopUpNotCredited = NSLocalizedString("Apple took the payment, but this device could not add the credits to your balance yet. They are credited the next time the secure store can be written.", comment: "credits pack paid but not credited locally")

    // MARK: Compute-credit gift cards (the "gift" half of the compute-credits page)
    //
    // A credit gift card is the credit twin of a badge gift card: Apple collects the money, this end mints exactly one transferable
    // voucher, and **nothing lands on this device's balance**. That difference is why these sentences are separate from the top-up group
    // above — a top-up sentence says "added to your balance", and over a gift card that would simply be false.
    // Face values are the bare amounts (100 / 500 / 2_000) at the same list prices as the matching top-up packs, and no sentence here
    // may promise bonus credits: `noGiftBackStatement` above is the compliance line both halves of the page share.
    static let creditsRechargeTab = NSLocalizedString("Recharge", comment: "compute-credits page segment: buying credits for this device")
    static let creditsGiftTab = NSLocalizedString("Gift Credits", comment: "compute-credits page segment: buying a credit gift card for someone else")
    static let creditsGiftAction = NSLocalizedString("Buy gift card", comment: "compute-credit gift card tier button")
    /// The mint result. It says "created", never "delivered": the card only becomes the other person's balance when they redeem it.
    static func creditsGiftCreated(_ amount: Int) -> String {
        String(format: NSLocalizedString("Gift card created · %lld Compute Credits", comment: "compute-credit gift card purchase result"), amount)
    }
    static let creditsGiftPending = NSLocalizedString("Apple is still confirming this purchase. The gift card appears as soon as it is confirmed.", comment: "compute-credit gift card purchase pending")
    /// The payment completed but the voucher could not be minted (Keychain write failed, or the vault is full). Same reason for existing as `creditsTopUpNotCredited`.
    static let creditsGiftNotCreated = NSLocalizedString("Apple took the payment, but this device could not create the gift card yet. It is created the next time the secure store can be written.", comment: "compute-credit gift card paid but not minted")
    /// What the recipient sees after a successful redemption. The number comes from the **signed grant**, not from the card text.
    static let creditsGiftReceivedFormat = NSLocalizedString("Received %lld Compute Credits from a gift card.", comment: "compute-credit gift card redeemed")
    static let errorCreditVoucherUnavailable = NSLocalizedString("This Compute Credits gift card is no longer available.", comment: "error")
    /// The card face title, and the QR poster's own heading. The amount comes from the voucher, so this can never disagree with the record.
    static func creditsGiftCardTitle(_ amount: Int) -> String {
        String(format: NSLocalizedString("%lld Compute Credits gift card", comment: "compute-credit gift card face title"), amount)
    }
    /// Credit twin of `PopopxGiftBadgeCardSheet`'s badge footnote, and it differs in exactly one load-bearing place: **case**.
    /// The body of a `PPXC1-` code is base64url, which contains `-` and is case-sensitive, so "the case does not matter" would send users
    /// to retype a string that then fails its signature check.
    static let creditsGiftCodeFootnote = NSLocalizedString(
        "Paste this whole string where the app asks for a redemption code: the grouping is only for readability and spaces make no difference, "
        + "but it is case-sensitive — paste or scan it, do not retype it character by character.",
        comment: "compute-credit gift card code footnote"
    )
    /// The gift tab's statement of who is credited. It must not read like a top-up sentence: the buyer's own balance never moves here.
    static let creditsGiftPackFootnote = NSLocalizedString(
        "A gift card adds nothing to your own balance. The credits belong to the device that redeems the code.",
        comment: "compute-credit gift card tier footnote"
    )
    static let creditsGiftWalletTitle = NSLocalizedString("Gift cards on this device", comment: "compute-credit gift card inventory section")
    static let creditsGiftWalletEmpty = NSLocalizedString(
        "No gift cards yet. Buy one above, or create one from the credits you already have.",
        comment: "compute-credit gift card inventory empty state"
    )
    /// The credit twin of the badge page's `credits` exchange section. Buying with Apple is not the only way a gift card exists,
    /// and `PopopxCreditsManager.exchangeCreditsForCreditVoucher` otherwise has no caller at all.
    static let creditsGiftFromBalanceTitle = NSLocalizedString("Or pay with the credits you already have", comment: "compute-credit gift card exchange section")
    /// Three positional specifiers on purpose — quantity, face value, total cost — because the denomination list and the quantity are both
    /// chosen by the user, and a button that reads a rounded "about" number is how a money mismatch starts.
    static func creditsGiftFromBalance(_ quantity: Int, _ amount: Int, _ cost: Int) -> String {
        String(format: NSLocalizedString("Create %1$lld gift cards of %2$lld Compute Credits · %3$lld credits", comment: "compute-credit gift card exchange button"), quantity, amount, cost)
    }
    static func creditsGiftFromBalanceCreated(_ quantity: Int, _ amount: Int) -> String {
        String(format: NSLocalizedString("Created %1$lld gift cards of %2$lld Compute Credits", comment: "compute-credit gift card exchange result"), quantity, amount)
    }
    /// The debit cleared but the cards were not written. Same reason for existing as `creditsGiftNotCreated`, and the number is what
    /// `reconcileNote` will keep showing until the vault can be written.
    static let creditsGiftFromBalanceNotCreated = NSLocalizedString(
        "Your balance was reduced, but this device could not create the gift cards yet. They appear the next time the secure store can be written.",
        comment: "compute-credit gift card exchange failed after the debit"
    )
    static let redPacketTitle = NSLocalizedString("Send Compute Credits", comment: "sheet title")
    /// Compliance statement: this sentence has to appear in all 17 languages; it is what the review reads.
    static let redPacketFixedAmountsStatement = NSLocalizedString("Only the fixed amounts listed here can be sent. Nowhere in this feature can you type a custom amount.", comment: "Apple 3.1.1 no random amounts")
    /// The refund promise. The day count is not a hard-coded string: the caller must pass in `PopopxCommerceLimits.packetClaimGraceSeconds`,
    /// otherwise the constant changes while the copy still says 30 days, and that is a false promise.
    static let redPacketRefundStatementFormat = NSLocalizedString("Credits nobody claims are returned to the sender %lld days after the packet was sent.", comment: "refund promise")
    static let channelSubscriptionTitle = NSLocalizedString("Subscribe to this channel", comment: "sheet title")
    /// How long one period is gets passed in by the caller from `PopopxCommerceLimits.channelTicketSeconds` and is not written into the copy string.
    static let channelSubscriptionPeriodFormat = NSLocalizedString("Each purchase is valid for %lld days.", comment: "channel subscription period")
    static let channelSubscriptionStackFormat = NSLocalizedString("Subscribing again adds %lld days to the time you already have.", comment: "renewal is cumulative, money promise")

    // MARK: Debug settlement (only Debug builds can ever put these sentences on screen)
    //
    // Why these exist: a StoreKit test configuration is only read when something **tells the process to read it** — Xcode's scheme does that through
    // the `StoreKitConfigurationFileReference` of `POPOPX (iOS).xcscheme`. The `.storekit` file sits in the app's Resources build phase, so a package
    // installed onto a real device with `xcrun devicectl device install app` carries the bytes, but nothing points at them. Launched from the
    // home-screen icon `Product.products(for:)` hits the real store instead. Measured on device: of the 12 SKUs this enum declares, the 5 newest ones
    // (the two one-time passes and the three compute-credit gift cards) are not in App Store Connect yet, so they come back missing
    // while the older seven still load — the tier that reads as "this product is unavailable" is the tier the user just paid attention to,
    // and the tier that reads as a price with a dead button is worse.
    // The answer is that `PopopxStoreKitManager.purchase(_:)` itself settles such a SKU locally in Debug, so **the buy button on the tier** walks
    // the commercial main path "payment → lit up → written to Keychain → still there after restart"; there is deliberately no second, Debug-only
    // button anywhere (there was: a dashed "Sandbox purchase" row under each card, deleted because a side button tests a path Release does not contain).
    //
    // These sentences still go into the 16 catalogues and are not skipped because they "only appear in Debug": real-device screenshots get used as troubleshooting evidence,
    // and a card showing untranslated English is harder to explain than no card at all; while "this charge never really took money" is **a factual statement about money**,
    // which by the dividing line at the top of this enum (whether it can appear in payment/refund evidence) belongs here anyway.
    //
    // The whole block is wrapped in `#if DEBUG`, the same gate as the code it serves: a Release archive has not only no such path,
    // it should not even keep the wording that "a sandbox path exists" — a sentence lying in the binary that nobody can ever trigger,
    // "Sandbox purchase", is the hardest kind of residue to explain in the next compliance enquiry.
    // The catalogues are unaffected: the keys of `.strings` are determined by the source strings themselves, and this repo's 16 catalogues are hand-written.
    // That is also why dropping the "Sandbox purchase" action label above moved no catalogue line — `POPOPXChat/ChatTypes.swift:488` asks for that same
    // source text for the same fact about the same kind of purchase, and is the only reason those 16 entries are not residue either.
    #if DEBUG
    /// Debug delivery of a one-off pass. The day count is passed in by the caller from `PopopxNodeBadgePeriod.days`,
    /// the same source as the real delivery sentence (`passGrantedFormat`), so 30/365 is not written a second time.
    static let sandboxPassGrantedFormat = NSLocalizedString("Sandbox purchase: the badge was lit for %lld more days on this device. No payment was taken.", comment: "DEBUG-only purchase result")
    /// Debug delivery for the remaining tiers (auto-renewing subscriptions, gift vouchers, compute-credit packs). Those families do not deliver "days"
    /// on the real path, so this promises no concrete entitlement at all and only says "a test purchase was recorded on this device, no money charged".
    static let sandboxPurchaseGranted = NSLocalizedString("Sandbox purchase recorded on this device. No payment was taken by Apple.", comment: "DEBUG-only purchase result")
    /// The note at the top of a price screen: why a product line did not come back, and that the button above it now settles on the device.
    /// It speaks only the condition ("the store did not return every item here"), never a button of its own — the sentence has to stay true
    /// now that the tier's own CTA is the sandbox entry, and it would be a lie if it pointed at a second control.
    static let sandboxPaywallNote = NSLocalizedString("This build is not running with a StoreKit configuration, so the App Store did not return every item here. A sandbox purchase is minted on this device and runs the same delivery code as a real purchase. No payment is taken.", comment: "DEBUG-only paywall note")
    #endif

    static let errorStoreUnavailable = NSLocalizedString("The store is not available right now.", comment: "error")
    static let errorProductUnavailableFormat = NSLocalizedString("This item is not available (%@).", comment: "error")
    static let errorPurchaseFailedFormat = NSLocalizedString("Purchase failed: %@", comment: "error")
    static let errorPurchaseCancelled = NSLocalizedString("Purchase cancelled.", comment: "error")
    static let errorVerificationFailed = NSLocalizedString("The receipt could not be verified.", comment: "error")
    static let errorKeychainUnavailable = NSLocalizedString("Secure storage is unavailable on this device.", comment: "error")
    static let errorInsufficientCreditsFormat = NSLocalizedString("This needs %1$lld Compute Credits and you have %2$lld.", comment: "error")
    static let errorVoucherUnavailable = NSLocalizedString("This gift badge is no longer available.", comment: "error")
    static let errorVoucherAlreadyRedeemed = NSLocalizedString("This code has already been redeemed.", comment: "error")
    static let errorCodeMalformed = NSLocalizedString("The code is not valid. Check it and try again.", comment: "error")
    static let errorConnectionUnavailable = NSLocalizedString("The secure exchange could not be started.", comment: "error")
    static let errorSignalRejected = NSLocalizedString("The sender did not confirm this exchange.", comment: "error")
    static let errorExpiryInPast = NSLocalizedString("This badge has already expired.", comment: "error")
    static let errorCreditBalanceTooHighFormat = NSLocalizedString("Your Compute Credits balance cannot go above %lld. Spend some credits first.", comment: "error")
}
