package chat.popopx.app.commerce

import chat.popopx.common.commerce.PopopxBadgeCreditsError
import chat.popopx.common.commerce.PopopxChannelPaymentReceipt
import chat.popopx.common.commerce.PopopxCosmetic
import chat.popopx.common.commerce.PopopxCreditsEntryKind
import chat.popopx.common.commerce.PopopxCreditsGrant
import chat.popopx.common.commerce.PopopxCreditsWallet
import chat.popopx.common.commerce.PopopxNodeBadgePeriod
import chat.popopx.common.commerce.PopopxVoucherSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The credit ledger's arithmetic and its ordering rules
// (`apps/ios/Shared/Features/BadgeCredits/PopopxCreditsManager.swift`, read end to end).
//
// The three things these tests exist to keep are the ones a "cleanup" gets wrong:
//  - the BALANCE is the account and the LEDGER is a 240-row display window, so a tool must never rebuild a full
//    window from its own sum (`:8-14`, `:100-121`);
//  - a write that fails must roll the balance back, while a ledger row that fails only logs (`:16-26`, `:184`);
//  - every dedupe key is a literal (`claim.`, `refund.`, `creditgift.`, `channel_pay.`, `reverse.`), because a
//    re-delivered message that credits twice is money created.

private const val MONTH = 30L * 86_400_000L

class PopopxCreditsManagerTest {
  @Test
  fun theLedgerWindowDropsItsOldestRowsWithoutTouchingTheBalance() {
    val fixture = CommerceFixture()
    fixture.newIds(400)
    repeat(300) { fixture.manager.claimRedPacket("packet.$it", 1, "one credit") }
    assertEquals(300, fixture.manager.balance)
    assertEquals(240, fixture.manager.entries.size)
    assertEquals(240, fixture.manager.entries.sumOf { it.amount })
    // The rows and the balance can no longer be expected to agree, which is the case the marker exists for, and the
    // only honest answer is "flag it" rather than "rewrite the money".
    fixture.manager.verifyLedgerConsistency()
    assertTrue(fixture.manager.needsReconcile)
    val reopened = fixture.reopened()
    assertEquals(300, reopened.balance)
    assertTrue(reopened.needsReconcile)
  }

  @Test
  fun aCompleteHistoryThatDisagreesIsRebuiltFromTheLedger() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    // Only the wallet is rewritten, so the ledger below is still a complete history of the account.
    assertTrue(
      fixture.store.writeWallet(
        PopopxCreditsWallet(PopopxCreditsWallet.CURRENT_VERSION, 7, fixture.nowMs(), false)
      )
    )
    val reopened = fixture.reopened()
    assertEquals(1_000, reopened.balance)
    assertFalse(reopened.needsReconcile)
  }

  @Test
  fun aFullWindowIsNeverRebuiltFromItsOwnSum() {
    val fixture = CommerceFixture()
    fixture.newIds(400)
    repeat(240) { fixture.manager.claimRedPacket("packet.$it", 1, "one credit") }
    assertTrue(
      fixture.store.writeWallet(
        PopopxCreditsWallet(PopopxCreditsWallet.CURRENT_VERSION, 500, fixture.nowMs(), false)
      )
    )
    val reopened = fixture.reopened()
    assertEquals(500, reopened.balance)
    assertEquals(240, reopened.entries.sumOf { it.amount })
  }

  @Test
  fun creditingPastTheCeilingRefusesTheIncomeAndBooksNothing() {
    val fixture = CommerceFixture()
    fixture.seed(100_000)
    assertEquals(100_000, fixture.manager.balance)
    val error = assertFailsWith<PopopxBadgeCreditsError.CreditBalanceTooHigh> {
      fixture.manager.claimRedPacket("packet.over", 1, "one credit too many")
    }
    assertEquals(100_000, error.maximum)
    assertEquals(100_000, fixture.manager.balance)
    assertEquals(1, fixture.manager.entries.size)
    // The replay marker is written AFTER the credit, so a refused credit stays retryable instead of vanishing.
    assertFalse(fixture.manager.hasClaimed("packet.over"))
  }

  @Test
  fun spendingMoreThanTheBalanceRefusesAndMovesNothing() {
    val fixture = CommerceFixture()
    fixture.seed(10)
    val error = assertFailsWith<PopopxBadgeCreditsError.InsufficientCredits> {
      fixture.manager.purchaseExtendedSecureWindow("too dear")
    }
    assertEquals(10, error.balance)
    assertEquals(20, error.required)
    assertEquals(10, fixture.manager.balance)
    assertNull(fixture.manager.payForService(101, "a service"))
    assertEquals(10, fixture.manager.balance)
  }

  @Test
  fun thePolarityOfAnAmountComesFromItsCategoryAlone() {
    // `debit` refuses a kind with no sign or a positive one, and `credit` ignores the sign entirely; the three
    // income kinds therefore carry a null sign on purpose, which is what stops a second source of polarity.
    assertNull(PopopxCreditsEntryKind.STORE_PURCHASE.sign)
    assertNull(PopopxCreditsEntryKind.RED_PACKET_RECEIVED.sign)
    assertNull(PopopxCreditsEntryKind.ADJUSTMENT.sign)
    assertEquals(-1, PopopxCreditsEntryKind.SERVICE_PAYMENT.sign)
    assertEquals(1, PopopxCreditsEntryKind.RED_PACKET_REFUND.sign)
    assertEquals(-1, PopopxCreditsEntryKind.CHANNEL_SUBSCRIPTION.sign)
  }

  // MARK: Red packets (`:368-514`)

  @Test
  fun anUnevenSplitIsRefusedRatherThanRounded() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    assertFailsWith<PopopxBadgeCreditsError.SignalRejected> {
      fixture.manager.sendRedPacket(100, 3, "congratulations", "sent")
    }
    assertFailsWith<PopopxBadgeCreditsError.SignalRejected> {
      fixture.manager.sendRedPacket(11, 1, "an off-menu amount", "sent")
    }
    assertFailsWith<PopopxBadgeCreditsError.SignalRejected> {
      fixture.manager.sendRedPacket(100, 0, "nobody", "sent")
    }
    assertEquals(1_000, fixture.manager.balance)
    assertEquals(1, fixture.manager.entries.size)
  }

  @Test
  fun sendingDebitsTheWholeAmountAndHoldsTheSplit() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    val packet = fixture.manager.sendRedPacket(100, 5, "congratulations", "sent")
    assertEquals("id.1", packet.packetId)
    assertEquals(20, packet.amountPerRecipient)
    assertEquals(100, packet.refundableAmount)
    assertFalse(packet.settled)
    assertEquals(900, fixture.manager.balance)
    assertEquals(100, fixture.manager.pendingPacketTotal)
    assertEquals(packet, fixture.manager.pendingPacket("id.1"))
    assertNull(fixture.manager.pendingPacket("somebody.elses.packet"))
    val row = fixture.manager.entries.last()
    assertEquals(-100, row.amount)
    assertEquals(PopopxCreditsEntryKind.RED_PACKET_SENT, row.kind)
  }

  @Test
  fun aClaimedShareCreditsOncePerPacket() {
    val fixture = CommerceFixture()
    assertTrue(fixture.manager.claimRedPacket("packet.a", 20, "received"))
    assertEquals(20, fixture.manager.balance)
    assertFalse(fixture.manager.claimRedPacket("packet.a", 20, "received again"))
    assertEquals(20, fixture.manager.balance)
    assertEquals(1, fixture.manager.entries.size)
    assertEquals("claim.packet.a", fixture.manager.entries.first().id)
    assertTrue(fixture.manager.hasClaimed("packet.a"))
  }

  @Test
  fun theSenderCountsEachMemberOnceAndStopsAtTheShareCount() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    val packet = fixture.manager.sendRedPacket(50, 2, "two shares", "sent")
    fixture.manager.recordClaim(packet.packetId, "member.a")
    fixture.manager.recordClaim(packet.packetId, "member.a")
    assertEquals(1, fixture.manager.pendingPacket(packet.packetId)!!.claimedCount)
    fixture.manager.recordClaim(packet.packetId, "member.b")
    fixture.manager.recordClaim(packet.packetId, "member.c")
    assertEquals(2, fixture.manager.pendingPacket(packet.packetId)!!.claimedCount)
    // The count is what the refund is computed from, so a replayed ACK must not be able to push it past the split.
    assertEquals(950, fixture.manager.balance)
    assertEquals(0, fixture.manager.refundSettledPackets())
  }

  @Test
  fun anUnclaimedPacketRefundsOnlyAfterTheGracePeriodAndOnlyOnce() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    val packet = fixture.manager.sendRedPacket(100, 5, "congratulations", "sent")
    // Refunding while shares are still outstanding would let those shares be claimed against money already
    // returned, so the grace period is a correctness gate and not a courtesy.
    assertEquals(0, fixture.manager.refundSettledPackets())
    assertEquals(900, fixture.manager.balance)
    fixture.advanceMs(31L * 86_400_000L)
    assertEquals(100, fixture.manager.refundSettledPackets())
    assertEquals(1_000, fixture.manager.balance)
    assertEquals(0, fixture.manager.pendingPacketTotal)
    assertEquals(0, fixture.manager.refundSettledPackets())
    assertEquals(1_000, fixture.manager.balance)
    val rows = fixture.manager.entries
    assertEquals(3, rows.size)
    assertEquals("refund.${packet.packetId}", rows.last().id)
    assertEquals(100, rows.last().amount)
    assertEquals(PopopxCreditsEntryKind.RED_PACKET_REFUND, rows.last().kind)
  }

  @Test
  fun aPartiallyClaimedPacketRefundsTheRemainder() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    val packet = fixture.manager.sendRedPacket(500, 5, "five shares", "sent")
    repeat(3) { fixture.manager.recordClaim(packet.packetId, "member.$it") }
    fixture.advanceMs(31L * 86_400_000L)
    assertEquals(200, fixture.manager.refundSettledPackets())
    assertEquals(700, fixture.manager.balance)
  }

  // MARK: Channel subscription, member side (`:516-570`)

  @Test
  fun aTicketStacksTheDaysAlreadyPaidFor() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    val first = fixture.manager.subscribeToChannel("ch.1", "Some Channel", 30, "pubkey.a", "subscribed")
    assertEquals("id.1", first.transactionId)
    assertEquals(fixture.nowMs() + MONTH, first.expiresAtMs)
    val second = fixture.manager.subscribeToChannel("ch.1", "Some Channel", 30, "pubkey.a", "renewed")
    assertEquals(first.expiresAtMs + MONTH, second.expiresAtMs)
    assertEquals(940, fixture.manager.balance)
    assertNotNull(fixture.manager.validTicket("ch.1"))
    assertNull(fixture.manager.validTicket("ch.2"))
    assertFailsWith<PopopxBadgeCreditsError.SignalRejected> {
      fixture.manager.subscribeToChannel("ch.3", "Free Channel", 0, "pubkey.a", "a zero row would be a fake entry")
    }
  }

  @Test
  fun onePaidTicketPinsOnePublisherKeyEvenAfterItExpires() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    fixture.manager.subscribeToChannel("ch.1", "Some Channel", 30, "pubkey.a", "subscribed")
    assertFalse(fixture.manager.channelIssuerConflict("ch.1", "pubkey.a"))
    assertTrue(fixture.manager.channelIssuerConflict("ch.1", "pubkey.b"))
    // MEASURED: an expired subscription still pins the key it was paid against, because the question this answers is
    // "who has this user already paid", not "is the access live".
    val later = fixture.nowMs() + 12L * MONTH
    assertNull(fixture.manager.validTicket("ch.1", later))
    assertTrue(fixture.manager.channelIssuerConflict("ch.1", "pubkey.b"))
    // With no declared issuer there is nothing to conflict with, which is why an empty key stores as null (`:539`).
    fixture.manager.subscribeToChannel("ch.2", "Anonymous Channel", 30, "", "subscribed")
    assertFalse(fixture.manager.channelIssuerConflict("ch.2", "pubkey.b"))
  }

  @Test
  fun aChannelPaymentIsKeyedOnTheTxHashAndBooksANegativeRow() {
    val fixture = CommerceFixture()
    val receipt = PopopxChannelPaymentReceipt(channelId = 7L, credits = 50, txHash = "0xdeadbeef", paidAtMs = fixture.nowMs())
    assertTrue(fixture.manager.receiveChannelPayment(receipt))
    assertEquals(50, fixture.manager.balance)
    assertTrue(fixture.manager.hasReceivedPayment("0xdeadbeef"))
    assertFalse(fixture.manager.receiveChannelPayment(receipt))
    assertEquals(50, fixture.manager.balance)
    assertEquals(1, fixture.manager.entries.size)
    val row = fixture.manager.entries.first()
    assertEquals("channel_pay.0xdeadbeef", row.id)
    // MEASURED: an incoming payment is booked under `servicePayment`, a spend category whose sign is -1, but
    // `credit` never consults the sign, so the stored amount is POSITIVE like any other income row and the window
    // still sums to the balance. The category name is the only place the spend-side label survives; pinned so a
    // future "consistency fix" that negates this row is caught rather than shipped.
    assertEquals(50, row.amount)
    assertEquals(50, row.balanceAfter)
    assertEquals(PopopxCreditsEntryKind.SERVICE_PAYMENT, row.kind)
  }

  @Test
  fun thePaymentHashSetKeepsTheNewestThousandHashes() {
    val fixture = CommerceFixture()
    val total = 1_002
    repeat(total) {
      assertTrue(
        fixture.manager.receiveChannelPayment(
          PopopxChannelPaymentReceipt(channelId = 7L, credits = 1, txHash = "tx.$it", paidAtMs = fixture.nowMs())
        )
      )
    }
    assertEquals(total, fixture.manager.balance)
    assertFalse(fixture.manager.hasReceivedPayment("tx.0"))
    assertFalse(fixture.manager.hasReceivedPayment("tx.1"))
    assertTrue(fixture.manager.hasReceivedPayment("tx.${total - 1}"))
    // The window is full at this point, so no reload may rebuild the balance from its sum: 762 of the 1002 rows
    // have already been dropped, and a sum-based "repair" would print a balance smaller than the money.
    assertEquals(total, fixture.reopened().balance)
  }

  // MARK: Profile cards, cosmetics, the secure window (`:572-622`)

  @Test
  fun unlockingAProfileCardIsKeyedOnAllThreeFieldsTogether() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    val receipt = fixture.manager.unlockProfile("profile.1", 11L, 21L, 25, "unlocked")
    assertEquals("id.1", receipt.transactionId)
    assertEquals(25, receipt.price)
    assertTrue(fixture.manager.hasUnlocked("profile.1", 11L, 21L))
    // Cards are forwardable and can appear several times in one conversation, so a profile-level key would turn
    // "unlocked in conversation A" into "free in conversation B".
    assertFailsWith<PopopxBadgeCreditsError.SignalRejected> {
      fixture.manager.unlockProfile("profile.1", 11L, 21L, 25, "again")
    }
    assertFalse(fixture.manager.hasUnlocked("profile.1", 11L, 22L))
    assertFalse(fixture.manager.hasUnlocked("profile.1", 12L, 21L))
    assertEquals(975, fixture.manager.balance)
  }

  @Test
  fun aCosmeticIsBoughtOnceAndSurvivesARestart() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    assertFalse(fixture.manager.owns(PopopxCosmetic.AURORA_SHIELD_AVATAR_FRAME))
    fixture.manager.purchase(PopopxCosmetic.AURORA_SHIELD_AVATAR_FRAME)
    assertEquals(850, fixture.manager.balance)
    assertFailsWith<PopopxBadgeCreditsError.SignalRejected> {
      fixture.manager.purchase(PopopxCosmetic.AURORA_SHIELD_AVATAR_FRAME)
    }
    assertEquals(850, fixture.manager.balance)
    assertTrue(fixture.reopened().owns(PopopxCosmetic.AURORA_SHIELD_AVATAR_FRAME))
    assertFalse(fixture.reopened().owns(PopopxCosmetic.DARK_GOLD_QR_CARD_SKIN))
  }

  @Test
  fun theSecureWindowSellsTheDurationAndNotTheDeadline() {
    val fixture = CommerceFixture()
    fixture.seed(100)
    assertEquals(3_600L, fixture.manager.purchaseExtendedSecureWindow())
    assertEquals(80, fixture.manager.balance)
    assertEquals(PopopxCreditsEntryKind.SECURE_WINDOW, fixture.manager.entries.last().kind)
  }

  // MARK: Exchanging credits, and the two seams (`:311-349`, `:624-652`)

  @Test
  fun aFailedMintRefundsTheDebitAsItsOwnReplayProofRow() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    fixture.vault.mint(PopopxNodeBadgePeriod.MONTHLY, 200, PopopxVoucherSource.CreditEntry("filled"))
    assertFailsWith<PopopxBadgeCreditsError.VoucherUnavailable> {
      fixture.manager.exchangeCreditsForVoucher(PopopxNodeBadgePeriod.MONTHLY, 1, "the vault is full")
    }
    assertEquals(1_000, fixture.manager.balance)
    val rows = fixture.manager.entries
    assertEquals(3, rows.size)
    assertEquals(-600, rows[1].amount)
    assertEquals(PopopxCreditsEntryKind.GIFT_VOUCHER_EXCHANGE, rows[1].kind)
    assertEquals(600, rows[2].amount)
    assertEquals("reverse.${rows[1].id}", rows[2].id)
    assertEquals(PopopxCreditsEntryKind.ADJUSTMENT, rows[2].kind)
  }

  @Test
  fun aCreditGiftCardIsRefusedOffTheDenominationsAndCreditedOnThem() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    assertFailsWith<PopopxBadgeCreditsError.SignalRejected> {
      fixture.manager.exchangeCreditsForCreditVoucher(400, 1, "not a tier")
    }
    assertEquals(1_000, fixture.manager.balance)
    val minted = fixture.manager.exchangeCreditsForCreditVoucher(500, 1, "a gift card")
    assertEquals(500, fixture.manager.balance)
    assertEquals(1, minted.size)
    assertEquals(500, minted.first().creditsAmount)
    assertEquals("id.1", minted.first().transactionId)
    val grant = PopopxCreditsGrant(
      voucherId = minted.first().voucherId,
      creditsAmount = 500,
      grantedAtMs = fixture.nowMs(),
      giverPublicKey = "pubkey.a",
      signature = "sig",
    )
    assertTrue(fixture.manager.creditGiftCard(grant))
    assertEquals(1_000, fixture.manager.balance)
    assertFalse(fixture.manager.creditGiftCard(grant))
    assertEquals("creditgift.${grant.voucherId}", fixture.manager.entries.last().id)
    assertEquals(500, fixture.manager.entries.last().amount)
    assertTrue(fixture.manager.hasRedeemed(grant.voucherId))
  }

  @Test
  fun theEcoSeamHandsBackTheLedgerIdAndTheDiscoverSeamABoolean() {
    val fixture = CommerceFixture()
    fixture.seed(500)
    val entryId = fixture.manager.payForService(120, "unlock a service")
    assertNotNull(entryId)
    assertEquals(entryId, fixture.manager.entries.last().id)
    assertEquals(-120, fixture.manager.entries.last().amount)
    assertEquals(380, fixture.manager.balance)
    val discover = fixture.manager.discoverLedger()
    assertEquals(380, discover.balance)
    assertFalse(discover.payForService(1_000, "more than there is"))
    assertEquals(380, fixture.manager.balance)
    assertTrue(discover.payForService(80, "an edge service"))
    assertEquals(300, fixture.manager.balance)
    assertNull(fixture.manager.payForService(0, "a zero row would be a fake entry"))
  }

  @Test
  fun theRecentRowsAreInReverseTimeOrder() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    fixture.manager.payForService(20, "first service")
    fixture.manager.payForService(30, "second service")
    assertEquals(
      listOf(
        PopopxCreditsEntryKind.SERVICE_PAYMENT,
        PopopxCreditsEntryKind.SERVICE_PAYMENT,
        PopopxCreditsEntryKind.RED_PACKET_RECEIVED,
      ),
      fixture.manager.recentEntries.map { it.kind }
    )
    assertEquals(listOf(950, 980, 1_000), fixture.manager.recentEntries.map { it.balanceAfter })
  }

  @Test
  fun wipingForgetsTheWholeWallet() {
    val fixture = CommerceFixture()
    fixture.seed(1_000)
    fixture.manager.unlockProfile("profile.1", 11L, 21L, 25, "unlocked")
    fixture.manager.wipe()
    assertEquals(0, fixture.manager.balance)
    assertEquals(0, fixture.manager.entries.size)
    assertFalse(fixture.manager.hasUnlocked("profile.1", 11L, 21L))
    assertFalse(fixture.manager.hasClaimed("seed.1"))
    assertFalse(fixture.reopened().needsReconcile)
    assertEquals(0, fixture.reopened().balance)
  }
}
