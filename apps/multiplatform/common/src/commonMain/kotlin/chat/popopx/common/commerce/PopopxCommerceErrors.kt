package chat.popopx.common.commerce

/**
 * This module's unified failure type — the Kotlin form of `PopopxBadgeCreditsError`
 * (`apps/ios/Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift:1614-1657`).
 *
 * It carries no message strings. iOS attaches `errorDescription` from `PopopxCommerceCopy`, which is a batch of
 * translated UI text; a message written here would be a second, untranslatable copy of those sentences. The
 * caller already knows which case it got and renders it in its own language.
 *
 * Four cases of the iOS enum (`storeUnavailable`, `productNotFound`, `purchaseFailed`, `purchaseCancelled`)
 * describe a Google Play / App Store purchase round trip and are NOT ported: the billing lane is out of scope for
 * this module by ruling, and a failure no caller can reach is a failure that will be deleted with the caller.
 */
sealed class PopopxBadgeCreditsError : Exception() {
  /** Secure storage is not writable. Nothing that mints, signs or spends may degrade around this. */
  object KeychainUnavailable : PopopxBadgeCreditsError()

  /** `balance` cannot cover `required`. */
  data class InsufficientCredits(val balance: Int, val required: Int) : PopopxBadgeCreditsError()

  /** The badge voucher this action needs is not on this device, or is not `unused`. */
  object VoucherUnavailable : PopopxBadgeCreditsError()

  /**
   * The credit twin of [VoucherUnavailable], kept separate because the sentence a user reads must name the thing
   * they hold (`:1623-1625`): "this gift badge is no longer available" over a compute-credit card sends them to a
   * badge page that was never involved.
   */
  object CreditVoucherUnavailable : PopopxBadgeCreditsError()

  /** This voucher's state was already flipped: the double-spend answer. */
  object VoucherAlreadyRedeemed : PopopxBadgeCreditsError()

  /** The redemption code did not frame-decode, did not check its checksum, or did not parse. */
  object CodeMalformed : PopopxBadgeCreditsError()

  /** No connection to deliver the request over. */
  object ConnectionUnavailable : PopopxBadgeCreditsError()

  /**
   * The signal or the spend combination this layer refuses: a bad payload, an off-whitelist amount, a price of 0,
   * a duplicate unlock, an owned cosmetic. iOS collapses all of these into one case, and the collapse is the point —
   * the reason belongs in a log nobody reads, not in a message that tells a forger which gate they hit.
   */
  object SignalRejected : PopopxBadgeCreditsError()

  /** An activation whose expiry is not strictly after now — nothing is written (`:1630`). */
  object ExpiryInPast : PopopxBadgeCreditsError()

  /**
   * Crediting would push past the balance ceiling. Only the income direction reaches this case; the spending
   * direction is [InsufficientCredits]. Listed apart from a payment failure because the payment SUCCEEDED and the
   * money arrived — this device's wallet simply cannot hold it (`:1631-1634`).
   */
  data class CreditBalanceTooHigh(val maximum: Int) : PopopxBadgeCreditsError()

  /** A signature that had to verify did not. */
  object VerificationFailed : PopopxBadgeCreditsError()
}
